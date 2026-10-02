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
#   a short English pass/fail summary on STDERR. The verdict is persisted to
#   last-test.json in the subject's state dir (see "preservation" below).
#
# PHPUnit itself comes from drupal/core-dev, which a plain recommended-project
# does not ship. When the subject has tests but vendor/bin/phpunit is missing,
# the run is recorded as `not-verified-blocked` (never as a false regression)
# and the actionable install command is printed, matched to the installed core
# (core_dev_requirement in common.sh), e.g.:
#   ddev composer require --dev "drupal/core-dev:~11.4.8" -W
#
# Exit codes:
#   0  -> all selected test groups passed (or there was nothing to run).
#   1  -> usage/internal error.
#   2  -> a hard 'test' requirement is missing: the preflight gate failed, DDEV
#         is down, or PHPUnit (drupal/core-dev) is not installed.
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
  # The human preflight report is diagnostics: STDERR, never mixed into the
  # PHPUnit stream on STDOUT.
  if ! bash "$PREFLIGHT" --profile test >&2; then
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

# Tests need the DDEV stack (DB, Selenium): start a stopped project explicitly.
ddev_ensure_running "$DRUPAL_ROOT" \
  || die "The DDEV environment for $DRUPAL_ROOT is not running and could not be started. Start it with: ddev start" 2
if ! ddev_running "$DRUPAL_ROOT"; then
  die "The DDEV environment for $DRUPAL_ROOT is not running. Start it with: ddev start" 2
fi

# shellcheck disable=SC2206,SC2207  # intentional word-split: runner is a command prefix.
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
# NOTE: never name this array GROUPS — that is a bash special variable (the
# user's group IDs) and assignments to it are silently ignored, which once made
# this loop iterate over GIDs and run no test at all. scripts/dev/check.sh's
# special-vars gate guards against the whole class.
declare -a TEST_GROUPS=()
case "$TYPE" in
  unit)       TEST_GROUPS=(Unit);;
  kernel)     TEST_GROUPS=(Kernel);;
  functional) TEST_GROUPS=(Functional);;
  js)         TEST_GROUPS=(FunctionalJavascript);;
  all)        TEST_GROUPS=(Unit Kernel Functional FunctionalJavascript);;
esac
# Self-check: the list must hold test-group names, nothing else.
for _g in "${TEST_GROUPS[@]}"; do
  case "$_g" in
    Unit|Kernel|Functional|FunctionalJavascript) : ;;
    *) die "Internal error: unexpected test group '$_g' (the group list was clobbered)." 1;;
  esac
done

# group_has_tests <group> -> 0 when tests/src/<group> holds at least one *Test.php.
group_has_tests() {
  local d="$SUBJECT/tests/src/$1"
  [[ -d "$d" ]] || return 1
  [[ -n "$(find "$d" -type f -name '*Test.php' 2>/dev/null | head -n1)" ]]
}

# Whether the subject ships ANY PHPUnit test (any group), independent of
# --type: lets the report tell "no tests in the selected scope" apart from "the
# subject ships no tests" (F14).
SUBJECT_HAS_TESTS="false"
if [[ -d "$SUBJECT/tests/src" ]] \
   && [[ -n "$(find "$SUBJECT/tests/src" -type f -name '*Test.php' 2>/dev/null | head -n1)" ]]; then
  SUBJECT_HAS_TESTS="true"
fi

# The selected groups that actually contain tests.
declare -a GROUPS_WITH_TESTS=()
for _g in "${TEST_GROUPS[@]}"; do
  group_has_tests "$_g" && GROUPS_WITH_TESTS+=("$_g")
done

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
  ${RUNNER[@]+"${RUNNER[@]}"} sh -c "getent hosts '$host' >/dev/null 2>&1 || nc -z '$host' 4444 2>/dev/null" \
    >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Coverage flags. Coverage needs a driver (Xdebug/PCOV) in the container; if it
# is unavailable PHPUnit reports it — we surface that rather than hiding it.
# ---------------------------------------------------------------------------
declare -a COVERAGE_ARGS=()
if [[ "$COVERAGE" == "1" ]]; then
  # Coverage HTML is a developer-facing output, so it goes to the single visible,
  # gitignored .drupilot/ artifacts dir at the Drupal root (project_artifacts_dir).
  # Because that dir is under the root (mounted at /var/www/html in DDEV), the same
  # relative '.drupilot/coverage/...' path resolves on the host and in the container.
  COV_HTML_REL=".drupilot/coverage/${SUBJECT_REL//\//_}"
  if [[ ${#RUNNER[@]} -gt 0 ]]; then
    # Inside the container: a path relative to the Drupal root.
    mkdir -p "$DRUPAL_ROOT/$COV_HTML_REL" 2>/dev/null || true
    COVERAGE_ARGS=(--coverage-text "--coverage-html=$COV_HTML_REL")
    log_info "Coverage HTML will be written under: $DRUPAL_ROOT/$COV_HTML_REL"
  else
    # Host run: the absolute artifacts dir (project_artifacts_dir resolves the
    # Drupal root from its argument, landing in $DRUPAL_ROOT/.drupilot/coverage).
    COV_HTML_DIR="$(project_artifacts_dir "$DRUPAL_ROOT")/coverage/${SUBJECT_REL//\//_}"
    mkdir -p "$COV_HTML_DIR" 2>/dev/null || true
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
BLOCKED_REASON=""
PHPUNIT_MISSING=0
ENV_BLOCKED=0   # PHPUnit missing / not executable: an environment blocker (exit 2)
declare -a FAILED_GROUPS=()
declare -a SKIPPED_GROUPS=()

# ---------------------------------------------------------------------------
# PHPUnit availability. drupal/recommended-project does not ship PHPUnit; it
# comes from drupal/core-dev. Without it every group would "fail" with exit 127
# and be recorded as a false regression — so detect it up front and record an
# honest not-verified-blocked verdict with the actionable install command.
# Only checked when there is something to run.
# ---------------------------------------------------------------------------
if [[ ${#GROUPS_WITH_TESTS[@]} -gt 0 ]] && ! phpunit_available "$DRUPAL_ROOT"; then
  PHPUNIT_MISSING=1; ENV_BLOCKED=1
  CORE_DEV_REQ="$(core_dev_requirement "$DRUPAL_ROOT")"
  BLOCKED_REASON="PHPUnit is not installed (vendor/bin/phpunit missing): install drupal/core-dev matching the installed core with: ddev composer require --dev \"$CORE_DEV_REQ\" -W"
  log_err "PHPUnit is not installed in $DRUPAL_ROOT (vendor/bin/phpunit is missing)."
  log_err "It ships with drupal/core-dev, which must match the installed core ($(drupal_core_version "$DRUPAL_ROOT" || true))."
  log_plain "  Install it (inside DDEV), then re-run:"
  log_plain "    (cd \"$DRUPAL_ROOT\" && ddev composer require --dev \"$CORE_DEV_REQ\" -W)"
  log_plain "    bash \"$(plugin_root)/scripts/env/lock-sync.sh\" --dir \"$DRUPAL_ROOT\"   # freeze it in the lock"
fi

run_group() {
  local group="$1"
  local path="$SUBJECT_REL/tests/src/$group"

  if ! group_has_tests "$group"; then
    log_info "No $group tests under $SUBJECT_REL — skipping group."
    return 0
  fi

  if [[ "$PHPUNIT_MISSING" == "1" ]]; then
    log_warn "$group: not run — PHPUnit is not installed (external blocker, see above)."
    SKIPPED=$((SKIPPED + 1))
    SKIPPED_GROUPS+=("$group")
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
  local -a cmd=(${RUNNER[@]+"${RUNNER[@]}"} "${PHPUNIT[@]}" ${COVERAGE_ARGS[@]+"${COVERAGE_ARGS[@]}"} ${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"} "$path")

  # Temporarily relax errexit around the test run so a failing group does not
  # abort the script before we summarise it.
  set +e
  "${cmd[@]}"
  local rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    log_ok "$group: passed"
    PASSED=$((PASSED + 1))
  elif [[ "$rc" -eq 126 || "$rc" -eq 127 ]]; then
    # The runner could not execute PHPUnit at all (not found / not executable):
    # an environment blocker, not a behavioral failure — never a regression.
    RAN=$((RAN - 1)); ENV_BLOCKED=1
    log_err "$group: PHPUnit could not be executed (exit $rc) — environment blocker, not a test failure."
    [[ -n "$BLOCKED_REASON" ]] || BLOCKED_REASON="PHPUnit could not be executed (exit $rc): check vendor/bin/phpunit inside the DDEV web container (drupal/core-dev: $(core_dev_requirement "$DRUPAL_ROOT"))."
    SKIPPED=$((SKIPPED + 1))
    SKIPPED_GROUPS+=("$group")
  else
    log_err "$group: FAILED (phpunit exit $rc) — see the output above"
    FAILED=$((FAILED + 1))
    FAILED_GROUPS+=("$group")
  fi
  return 0
}

for g in "${TEST_GROUPS[@]}"; do
  run_group "$g"
done
[[ -z "$BLOCKED_REASON" && -n "$SELENIUM_NOTE" ]] && BLOCKED_REASON="$SELENIUM_NOTE"

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
#   not-verified-blocked  -> tests exist but none could run (e.g. Selenium absent,
#                            PHPUnit/drupal-core-dev not installed); see blocked_reason.
#   not-verified-no-tests -> no test exists in the selected --type scope, so
#                            preservation cannot be proven (drupilot never fabricates
#                            tests in Phase 1). subject_has_tests tells whether the
#                            subject ships tests in OTHER groups (a narrower --type)
#                            or none at all.
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
    --arg blocked_reason "$BLOCKED_REASON" \
    --argjson subject_has_tests "$SUBJECT_HAS_TESTS" \
    --argjson groups_with_tests "$(arr_to_json ${GROUPS_WITH_TESTS[@]+"${GROUPS_WITH_TESTS[@]}"})" \
    --argjson cov_requested "$COV_REQUESTED" --arg cov_html "$COV_HTML_PATH" \
    '{type:$type, status:$status, preservation:$preservation,
      ran:$ran, passed:$passed, failed:$failed,
      skipped:$skipped, failed_groups:$failed_groups, skipped_groups:$skipped_groups,
      js_skipped_reason: ($js_skipped_reason | select(. != "") // null),
      blocked_reason: ($blocked_reason | select(. != "") // null),
      subject_has_tests:$subject_has_tests, groups_with_tests:$groups_with_tests,
      coverage: {requested:$cov_requested, html: ($cov_html | select(. != "") // null), percent: null}}' \
    > "$STATE_DIR/last-test.json" 2>/dev/null || true
fi

if [[ "$FAILED" -gt 0 ]]; then
  log_err "Failing groups: ${FAILED_GROUPS[*]}"
  log_err "Tests did not pass. Review the output above and iterate — failures are never hidden."
  exit 3
fi

if [[ "$ENV_BLOCKED" == "1" ]]; then
  log_err "Test groups were blocked: $BLOCKED_REASON"
  log_err "Preservation is NOT verified for the blocked groups — fix the environment (see above) and re-run."
  exit 2
fi

if [[ "$RAN" -eq 0 ]]; then
  if [[ -n "$BLOCKED_REASON" ]]; then
    log_warn "No test groups were executed for --type '$TYPE': $BLOCKED_REASON"
  elif [[ "$SUBJECT_HAS_TESTS" == "true" ]]; then
    log_warn "No tests in the selected --type '$TYPE' scope (the subject has tests in other groups; try --type all)."
  else
    log_warn "No test groups were executed: the subject ships no PHPUnit tests."
  fi
  exit 0
fi

log_ok "All executed test groups passed."
exit 0
