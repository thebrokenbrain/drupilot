#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/tests/install-smoke.sh
# Install smoke check for a subject that ships no PHPUnit test (training run
# modules 03, 06 and 14: their ports had no runtime evidence at all). It
# renders templates/install-smoke-test.php.tmpl into
# <drupal_root>/.drupilot/smoke/<machine_name>/DrupilotInstallSmokeTest.php
# and runs it with the bed's PHPUnit: a BrowserTestBase site installs the
# subject (core's strict config schema check included), serves the front page
# as anonymous and as an administrator plus admin/config, uninstalls it and
# serves the front page again. The test lives outside the subject, so it is
# never part of the patch, and it is NOT a test of the module's behaviour:
# preservation stays not-verified-no-tests; this only adds install evidence.
#
# Gates the 'test' profile (Docker + daemon + DDEV) like run-phpunit.sh and
# starts a stopped DDEV project. The test runs in its own database prefix:
# the bed's site is never touched.
#
# Usage:
#   install-smoke.sh --subject DIR [--dry-run] [--no-record] [--json] [-h|--help]
#   --subject DIR  the placed module/theme
#   --dry-run      render the test and print the command; PHPUnit is not run
#   --no-record    do not write install-smoke.json to the state dir
#   --json         {status, machine_name, type, core, test_file, phpunit_rc,
#                   deprecations, excerpt} on STDOUT; status: passed | failed |
#                   blocked | dry-run (deprecations: the runtime deprecations
#                   PHPUnit counted, core's own included, which the static
#                   analysis may not see: read them in phpunit.log;
#                   excerpt: the tail of PHPUnit's output on failure)
#
# The result is recorded in the subject's hidden state dir (install-smoke.json,
# with subject_digest/digest_algo, so a later change of the sources makes it
# stale).
#
# Exit codes: 0 passed (or dry-run) · 1 usage error · 2 blocked (the 'test'
#             requirements, no Drupal root, DDEV down, PHPUnit missing) ·
#             3 failed (the subject does not install, or a page fails).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
DRY=0
RECORD=1
AS_JSON=0
usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --dry-run) DRY=1; shift;;
    --no-record) RECORD=0; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done

[[ -n "$SUBJECT" ]] || die "--subject DIR is required." 1
[[ -d "$SUBJECT" ]] || die "Subject directory not found: '$SUBJECT'." 1
have_cmd jq || die "jq is required." 2
SUBJECT="$(cd "$SUBJECT" && pwd)"
MN="$(subject_machine_name "$SUBJECT" 2>/dev/null || true)"
TYP="$(subject_type "$SUBJECT" 2>/dev/null || true)"
[[ -n "$MN" ]] || die "No *.info.yml in $SUBJECT: not a Drupal module or theme." 1
case "$TYP" in
  module|theme) ;;
  *) die "install-smoke.sh checks a module or a theme, not a '${TYP:-unknown}'." 1;;
esac

STATUS=""; RC=""; EXCERPT=""; CORE=""; TEST_REL=""; DEPR=""
emit() {
  if [[ "$AS_JSON" == "1" ]]; then
    jq -n -c --arg s "$STATUS" --arg mn "$MN" --arg t "$TYP" --arg core "$CORE" --arg f "$TEST_REL" \
      --arg rc "$RC" --arg ex "$EXCERPT" --arg dp "$DEPR" \
      '{status: $s, machine_name: $mn, type: $t, core: (if $core == "" then null else $core end),
        test_file: (if $f == "" then null else $f end), phpunit_rc: ($rc | tonumber? // null),
        deprecations: ($dp | tonumber? // null), excerpt: (if $ex == "" then null else $ex end)}'
  fi
  return 0
}
blocked() { STATUS="blocked"; EXCERPT="$1"; log_err "$1"; emit; exit 2; }

DRUPAL_ROOT="$(find_drupal_root "$SUBJECT" 2>/dev/null || true)"
[[ -n "$DRUPAL_ROOT" ]] || blocked "No Drupal root found above $SUBJECT (run /drupilot-setup first)."
CORE="$(drupal_core_version "$DRUPAL_ROOT" 2>/dev/null || true)"
TEST_REL=".drupilot/smoke/$MN/DrupilotInstallSmokeTest.php"
mkdir -p "$DRUPAL_ROOT/.drupilot/smoke/$MN"
render_template "$(plugin_root)/templates/install-smoke-test.php.tmpl" "$DRUPAL_ROOT/$TEST_REL" \
  "MACHINE_NAME=$MN" "SUBJECT_TYPE=$TYP" || die "Cannot render $TEST_REL." 1

if [[ "$DRY" == "1" ]]; then
  STATUS="dry-run"
  log_info "[dry-run] would run: $(drupal_runner "$DRUPAL_ROOT" 2>/dev/null || true) vendor/bin/phpunit -c web/core $TEST_REL"
  emit; exit 0
fi

PREFLIGHT="$(plugin_root)/scripts/env/preflight.sh"
bash "$PREFLIGHT" --profile test --subject "$SUBJECT" >&2 \
  || blocked "The 'test' requirements are not satisfied (see the report above)."
cd "$DRUPAL_ROOT" || die "Cannot enter Drupal root: $DRUPAL_ROOT" 1
ddev_ensure_running "$DRUPAL_ROOT" && ddev_running "$DRUPAL_ROOT" \
  || blocked "The DDEV environment for $DRUPAL_ROOT is not running and could not be started (ddev start)."
[[ -f vendor/bin/phpunit ]] \
  || blocked "PHPUnit is not installed (vendor/bin/phpunit missing): install $(core_dev_requirement "$DRUPAL_ROOT") with ddev composer require --dev -W."

# shellcheck disable=SC2206,SC2207  # intentional word-split: runner is a command prefix.
RUNNER=( $(drupal_runner "$DRUPAL_ROOT") )
# A Functional test from the web container: the add-ons' http://web base URL
# is for Selenium; this one reaches the site at http://localhost (as
# run-phpunit.sh's non-JavaScript groups).
ENVV=()
if [[ ${#RUNNER[@]} -gt 0 ]]; then
  _sbu="$("${RUNNER[@]}" printenv SIMPLETEST_BASE_URL < /dev/null 2> /dev/null | tr -d '\r' | sed -n '1p' || true)"
  [[ "$_sbu" == "http://web" ]] && ENVV=(env SIMPLETEST_BASE_URL=http://localhost)
fi

LOG="$DRUPAL_ROOT/.drupilot/smoke/$MN/phpunit.log"
log_step "Install smoke: $MN ($TYP) on core ${CORE:-?}"
RC=0
if [[ ${#RUNNER[@]} -gt 0 ]]; then
  run_dropping_ddev_failure_line ${RUNNER[@]+"${RUNNER[@]}"} ${ENVV[@]+"${ENVV[@]}"} vendor/bin/phpunit -c web/core "$TEST_REL" > "$LOG" 2>&1 || RC=$?
else
  vendor/bin/phpunit -c web/core "$TEST_REL" > "$LOG" 2>&1 || RC=$?
fi
# "OK (1 test, ...)" or "OK, but there were issues!" (deprecations): passed.
DEPR="$(grep -o -E '(^|[^t] )Deprecations: [0-9]+' "$LOG" | grep -o -E '[0-9]+$' | sed -n '1p' || true)"
if [[ "$RC" -eq 0 ]] && grep_q -E '^OK( \(|,)' "$LOG"; then
  STATUS="passed"
  log_ok "$MN installs, serves its pages and uninstalls on core ${CORE:-?} (install evidence only: no test of its behaviour ran)."
  [[ -z "$DEPR" ]] || log_warn "$DEPR runtime deprecation(s) were triggered (soft unless the analysis says otherwise): see $LOG"
elif [[ "$RC" -eq 126 || "$RC" -eq 127 ]]; then
  blocked "PHPUnit could not be executed (exit $RC)."
else
  STATUS="failed"
  # The first error or failure block, else the tail of the output.
  EXCERPT="$(awk '/^There w(as|ere) [0-9]+ (error|failure)/ { on = 1 } on && NF { print; if (++n == 15) on = 0 }' "$LOG" | cut -c1-300)"
  [[ -n "$EXCERPT" ]] || EXCERPT="$(grep -v -E '^[[:space:]]*$' "$LOG" | tail -n 15 | cut -c1-300 || true)"
  log_err "Install smoke FAILED for $MN (phpunit exit $RC): see $LOG"
  printf '%s\n' "$EXCERPT" >&2
fi

if [[ "$RECORD" == "1" ]]; then
  SD="$(project_state_dir "$SUBJECT")"
  jq -n --arg s "$STATUS" --arg mn "$MN" --arg t "$TYP" --arg core "$CORE" --arg rc "$RC" --arg ex "$EXCERPT" --arg dp "$DEPR" \
    --arg d "$(subject_digest "$SUBJECT")" --argjson a "$(subject_digest_algo)" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{status: $s, machine_name: $mn, type: $t, core: (if $core == "" then null else $core end),
      phpunit_rc: ($rc | tonumber? // null), deprecations: ($dp | tonumber? // null),
      excerpt: (if $ex == "" then null else $ex end), subject_digest: $d, digest_algo: $a, meta: {generated_at: $now}}' > "$SD/install-smoke.json.tmp" \
    && mv "$SD/install-smoke.json.tmp" "$SD/install-smoke.json"
fi
emit
[[ "$STATUS" == "passed" ]] || exit 3
exit 0
