#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/tests/run-phpunit.sh
# Run a Drupal extension's PHPUnit suite inside the DDEV environment.
#
# Gates the 'test' profile first (Docker + daemon + DDEV). Runs PHPUnit against
# the Drupal core configuration (web/core) for the selected test group(s),
# using the drupal_runner prefix ('ddev exec' when the environment is up). For
# JavaScript tests it verifies the Selenium add-on is reachable. With
# --coverage it adds text + HTML coverage reports.
#
# Failures are NEVER silenced: the failing PHPUnit output is surfaced and the
# script exits non-zero so callers (the /drupilot-test command, the
# drupal-test-engineer agent) know to iterate.
#
# Usage:
#   run-phpunit.sh --subject DIR
#                  [--type unit|kernel|functional|js|all]
#                  [--coverage] [--filter EXPR]
#
# Output:
#   The PHPUnit output streams through to STDOUT/STDERR unmodified, followed by
#   a short English pass/fail summary on STDERR.
#
# Exit codes:
#   0  -> all selected test groups passed (or there was nothing to run).
#   1  -> usage/internal error.
#   2  -> a hard 'test' requirement is missing (preflight gate failed).
#   3  -> at least one test group failed.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
TYPE="all"
COVERAGE=0
FILTER=""

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --type) TYPE="${2:-all}"; shift 2;;
    --type=*) TYPE="${1#*=}"; shift;;
    --coverage) COVERAGE=1; shift;;
    --filter) FILTER="${2:-}"; shift 2;;
    --filter=*) FILTER="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

[[ -n "$SUBJECT" ]] || die "Missing --subject DIR (path to the module/theme under test)." 1
[[ -d "$SUBJECT" ]] || die "Subject directory not found: $SUBJECT" 1
SUBJECT="$(cd "$SUBJECT" 2>/dev/null && pwd)" || die "Cannot resolve subject path: $SUBJECT" 1

case "$TYPE" in
  unit|kernel|functional|js|all) : ;;
  *) die "Invalid --type '$TYPE' (use unit|kernel|functional|js|all)." 1;;
esac

# ---------------------------------------------------------------------------
# Gate: the 'test' profile (Docker + daemon + DDEV).
# Abort cleanly with the actionable report and no side effects if it fails.
# ---------------------------------------------------------------------------
PREFLIGHT="$(plugin_root)/scripts/env/preflight.sh"
if [[ -x "$PREFLIGHT" || -f "$PREFLIGHT" ]]; then
  if ! bash "$PREFLIGHT" --profile test; then
    die "Cannot run tests: the 'test' requirements are not satisfied (see the report above)." 2
  fi
else
  die "preflight.sh not found at $PREFLIGHT — cannot verify the test environment." 1
fi

# ---------------------------------------------------------------------------
# Locate the Drupal root and the runner. PHPUnit needs the core tree (web/core)
# and the environment to be up.
# ---------------------------------------------------------------------------
DRUPAL_ROOT="$(find_drupal_root "$SUBJECT" 2>/dev/null || true)"
[[ -n "$DRUPAL_ROOT" ]] || die "No Drupal root found above $SUBJECT (run /drupilot-setup first)." 1

cd "$DRUPAL_ROOT" || die "Cannot enter Drupal root: $DRUPAL_ROOT" 1

if ! ddev_running "$DRUPAL_ROOT"; then
  die "The DDEV environment for $DRUPAL_ROOT is not running. Start it with: ddev start" 2
fi

# shellcheck disable=SC2206  # intentional word-split: runner is a command prefix.
RUNNER=( $(drupal_runner "$DRUPAL_ROOT") )

# PHPUnit lives in core; use the core configuration explicitly.
PHPUNIT=( vendor/bin/phpunit -c web/core )
if [[ ! -f "$DRUPAL_ROOT/web/core/phpunit.xml.dist" && ! -f "$DRUPAL_ROOT/web/core/phpunit.xml" ]]; then
  log_warn "No phpunit.xml(.dist) under web/core — PHPUnit may need configuration; continuing with -c web/core."
fi

# Subject path relative to the Drupal root: resolves identically on host and in
# the container, which is what drupal_runner relies on.
SUBJECT_REL="${SUBJECT#"$DRUPAL_ROOT"/}"

# ---------------------------------------------------------------------------
# Build the list of test groups to run, in the canonical fast-to-slow order.
# Each group maps to its tests/src/<Dir> directory under the subject.
# ---------------------------------------------------------------------------
declare -a GROUPS=()
case "$TYPE" in
  unit)       GROUPS=(Unit);;
  kernel)     GROUPS=(Kernel);;
  functional) GROUPS=(Functional);;
  js)         GROUPS=(FunctionalJavascript);;
  all)        GROUPS=(Unit Kernel Functional FunctionalJavascript);;
esac

needs_selenium() {
  local g="$1"
  [[ "$g" == "FunctionalJavascript" ]]
}

# selenium_ready -> 0 if a Selenium/Chrome service answers inside the container.
# Best-effort: we check the add-on config and the container DNS. We never hard
# fail here for non-js runs; the per-group guard below decides whether to skip.
selenium_ready() {
  # The add-on advertises a 'selenium-chrome' service; its config file lands in
  # .ddev/. If the service container resolves from the web container, JS tests
  # can reach the webdriver. Read the generated YAML rather than assuming hosts.
  local cfg
  if ls "$DRUPAL_ROOT"/.ddev/docker-compose.selenium-standalone-chrome.yaml >/dev/null 2>&1 \
     || ls "$DRUPAL_ROOT"/.ddev/*selenium* >/dev/null 2>&1; then
    : # add-on is installed
  else
    return 1
  fi
  # Confirm the web container can resolve the selenium service host.
  "${RUNNER[@]}" sh -c 'getent hosts selenium-chrome >/dev/null 2>&1 || nc -z selenium-chrome 4444 2>/dev/null' \
    >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Coverage flags. Coverage needs a driver (Xdebug/PCOV) in the container; if it
# is unavailable PHPUnit reports it — we surface that rather than hiding it.
# ---------------------------------------------------------------------------
declare -a COVERAGE_ARGS=()
if [[ "$COVERAGE" == "1" ]]; then
  COV_HTML_DIR="$(project_state_dir "$SUBJECT")/coverage-html"
  mkdir -p "$COV_HTML_DIR" 2>/dev/null || true
  # The HTML path must be valid inside the runner's view of the filesystem.
  # project_state_dir is on the host; when running via 'ddev exec' write the
  # HTML report under the project (mounted at /var/www/html) instead.
  if [[ ${#RUNNER[@]} -gt 0 ]]; then
    # Inside the container the host state dir is not visible, so place the
    # report relative to the Drupal root (mounted at /var/www/html).
    COV_HTML_REL=".drupilot-coverage/${SUBJECT_REL//\//_}"
    mkdir -p "$DRUPAL_ROOT/$COV_HTML_REL" 2>/dev/null || true
    COVERAGE_ARGS=(--coverage-text "--coverage-html=$COV_HTML_REL")
    log_info "Coverage HTML will be written under: $DRUPAL_ROOT/$COV_HTML_REL"
  else
    COVERAGE_ARGS=(--coverage-text "--coverage-html=$COV_HTML_DIR")
    log_info "Coverage HTML will be written to: $COV_HTML_DIR"
  fi
fi

declare -a FILTER_ARGS=()
[[ -n "$FILTER" ]] && FILTER_ARGS=(--filter "$FILTER")

# ---------------------------------------------------------------------------
# Run each group. Never silence failures: stream output and record the result.
# ---------------------------------------------------------------------------
RAN=0
PASSED=0
FAILED=0
SKIPPED=0
declare -a FAILED_GROUPS=()
declare -a SKIPPED_GROUPS=()

run_group() {
  local group="$1"
  local path="$SUBJECT_REL/tests/src/$group"

  if [[ ! -d "$DRUPAL_ROOT/$path" ]]; then
    log_info "No $group tests under $SUBJECT_REL — skipping group."
    return 0
  fi

  if needs_selenium "$group"; then
    if ! selenium_ready; then
      log_warn "Selenium add-on not reachable — skipping FunctionalJavascript tests."
      log_warn "Install it with: ddev add-on get ddev/ddev-selenium-standalone-chrome && ddev restart"
      SKIPPED=$((SKIPPED + 1))
      SKIPPED_GROUPS+=("$group")
      return 0
    fi
  fi

  log_step "Running $group tests ($path)"
  RAN=$((RAN + 1))

  # Assemble the full command. PHPUnit's own exit code drives pass/fail; we do
  # not redirect or swallow its output.
  local -a cmd=("${RUNNER[@]}" "${PHPUNIT[@]}" "${COVERAGE_ARGS[@]}" "${FILTER_ARGS[@]}" "$path")

  # Temporarily relax errexit around the test run so a failing group does not
  # abort the script before we summarise it.
  set +e
  "${cmd[@]}"
  local rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    log_ok "$group: passed"
    PASSED=$((PASSED + 1))
  else
    log_err "$group: FAILED (phpunit exit $rc) — see the output above"
    FAILED=$((FAILED + 1))
    FAILED_GROUPS+=("$group")
  fi
  return 0
}

for g in "${GROUPS[@]}"; do
  run_group "$g"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
hr
log_plain "PHPUnit summary for $(subject_machine_name "$SUBJECT" 2>/dev/null || basename "$SUBJECT"):"
log_plain "  groups run: $RAN   passed: $PASSED   failed: $FAILED   skipped: $SKIPPED"
if [[ "$SKIPPED" -gt 0 ]]; then
  log_warn "Skipped (documented, not silenced): ${SKIPPED_GROUPS[*]}"
fi
if [[ "$FAILED" -gt 0 ]]; then
  log_err "Failing groups: ${FAILED_GROUPS[*]}"
  log_err "Tests did not pass. Review the output above and iterate — failures are never hidden."
  exit 3
fi

if [[ "$RAN" -eq 0 ]]; then
  log_warn "No test groups were executed for the selected --type '$TYPE'."
  exit 0
fi

log_ok "All executed test groups passed."
exit 0
