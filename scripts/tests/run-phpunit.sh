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

# detect_selenium_host -> the webdriver service hostname, READ from the generated
# DDEV compose YAML rather than assumed (the add-on/DDEV version can change it).
# Falls back to the conventional 'selenium-chrome'.
detect_selenium_host() {
  local f host
  for f in "$DRUPAL_ROOT"/.ddev/docker-compose.*selenium*.yaml "$DRUPAL_ROOT"/.ddev/*selenium*.yaml; do
    [[ -f "$f" ]] || continue
    # The service name under 'services:' is the reachable host: grab the first
    # indented "<name>:" line that mentions selenium.
    host="$(grep -oE '^[[:space:]]+[A-Za-z0-9_-]+:' "$f" 2>/dev/null \
      | sed -E 's/[[:space:]:]//g' | grep -i selenium | head -n1)"
    [[ -n "$host" ]] && { printf '%s' "$host"; return 0; }
  done
  printf 'selenium-chrome'
}

# selenium_ready -> 0 if the Selenium service answers inside the container.
# Best-effort: checks the add-on YAML and the container DNS using the host READ
# from the YAML. We never hard fail here for non-js runs; the per-group guard
# below decides whether to skip (and records the reason).
selenium_ready() {
  local f found=0
  for f in "$DRUPAL_ROOT"/.ddev/docker-compose.*selenium*.yaml "$DRUPAL_ROOT"/.ddev/*selenium*; do
    [[ -e "$f" ]] && { found=1; break; }
  done
  [[ "$found" == "1" ]] || return 1
  local host; host="$(detect_selenium_host)"
  "${RUNNER[@]}" sh -c "getent hosts '$host' >/dev/null 2>&1 || nc -z '$host' 4444 2>/dev/null" \
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
SELENIUM_NOTE=""
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
      SELENIUM_NOTE="Selenium add-on not reachable; FunctionalJavascript tests skipped (external blocker)."
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

# Persist a machine-readable record so /drupilot-status and the flow read the
# outcome (and any documented skip) without re-running — a deterministic record.
#
# preservation: the behavior-preservation gate verdict drupilot reports honestly:
#   verified              -> every applicable group ran and passed (nothing skipped).
#   verified-partial      -> the groups that ran passed, but some were skipped (an
#                            external blocker), so part of the behavior is unproven.
#   regression            -> at least one group failed (a production-code defect
#                            to fix in code, never a test relaxed to fake green).
#   not-verified-blocked  -> tests exist but none could run (e.g. Selenium absent).
#   not-verified-no-tests -> the subject ships no tests in the selected scope, so
#                            preservation cannot be proven (drupilot never fabricates
#                            tests in Phase 1).
# coverage records only what was actually collected (requested + the HTML path);
# a percentage is NOT computed in Phase 1, so the field stays honest about that.
if have_cmd jq; then
  STATE_DIR="$(project_state_dir "$SUBJECT")"
  RUN_STATUS="passed"
  [[ "$FAILED" -gt 0 ]] && RUN_STATUS="failed"
  [[ "$RAN" -eq 0 && "$FAILED" -eq 0 ]] && RUN_STATUS="none-run"

  PRESERVATION="verified"
  if [[ "$FAILED" -gt 0 ]]; then
    PRESERVATION="regression"
  elif [[ "$RAN" -eq 0 ]]; then
    [[ "$SKIPPED" -gt 0 ]] && PRESERVATION="not-verified-blocked" || PRESERVATION="not-verified-no-tests"
  elif [[ "$SKIPPED" -gt 0 ]]; then
    # Some groups passed, but others were skipped (an external blocker), so the
    # green is only partial — never report a full 'verified' over a skip.
    PRESERVATION="verified-partial"
  fi

  COV_REQUESTED="false"; COV_HTML_PATH=""
  if [[ "$COVERAGE" == "1" ]]; then
    COV_REQUESTED="true"
    if [[ ${#RUNNER[@]} -gt 0 ]]; then COV_HTML_PATH="$DRUPAL_ROOT/${COV_HTML_REL:-}"; else COV_HTML_PATH="${COV_HTML_DIR:-}"; fi
  fi

  jq -n \
    --arg type "$TYPE" --arg status "$RUN_STATUS" --arg preservation "$PRESERVATION" \
    --argjson ran "$RAN" --argjson passed "$PASSED" \
    --argjson failed "$FAILED" --argjson skipped "$SKIPPED" \
    --argjson failed_groups "$(arr_to_json ${FAILED_GROUPS[@]+"${FAILED_GROUPS[@]}"})" \
    --argjson skipped_groups "$(arr_to_json ${SKIPPED_GROUPS[@]+"${SKIPPED_GROUPS[@]}"})" \
    --arg js_skipped_reason "$SELENIUM_NOTE" \
    --argjson cov_requested "$COV_REQUESTED" --arg cov_html "$COV_HTML_PATH" \
    '{type:$type, status:$status, preservation:$preservation,
      ran:$ran, passed:$passed, failed:$failed,
      skipped:$skipped, failed_groups:$failed_groups, skipped_groups:$skipped_groups,
      js_skipped_reason: ($js_skipped_reason | select(. != "") // null),
      coverage: {requested:$cov_requested, html: ($cov_html | select(. != "") // null), percent: null}}' \
    > "$STATE_DIR/last-test.json" 2>/dev/null || true
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
