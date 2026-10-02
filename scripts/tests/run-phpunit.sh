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
#                  [--baseline | --baseline-from-last | --no-baseline]
#                  [--no-record] [--result-file FILE]
#
#   --baseline           record this run as the PRE-PORT test baseline
#                        (test-baseline.json in the subject's state dir) instead
#                        of last-test.json. Take it before Rector touches the
#                        code. A red baseline is expected and still exits 0 once
#                        recorded (2 when the environment blocked the run).
#   --baseline-from-last promote the current last-test.json (it must carry
#                        per-test results) to the baseline without running
#                        anything, e.g. the green post-port run before a refactor.
#   --no-baseline        ignore a recorded baseline for this run's verdict.
#   --no-record          write neither last-test.json nor the baseline (used by
#                        negative-control.sh so a deliberate red run never
#                        clobbers the real preservation verdict).
#   --result-file FILE   also write this run's JSON record to FILE (works with
#                        --no-record).
#
# Output:
#   The PHPUnit output streams through to STDOUT/STDERR unmodified, followed by
#   a short English pass/fail summary on STDERR. The verdict is persisted to
#   last-test.json in the subject's state dir (see "preservation" below).
#
# Per-test results: each group also runs with PHPUnit's --log-junit (a scratch
# file under <drupal_root>/.drupilot/phpunit/, removed after parsing), so the
# record lists every executed test as pass/fail/error/skipped. A group whose
# PHPUnit exits 0 but executed no test ("No tests executed!", e.g. a --filter
# that matches nothing in it) counts as EMPTY, never as passed. A group that
# failed without writing any test result (PHPUnit itself died) is "crashed".
#
# Baseline comparison (N6): when test-baseline.json exists (and --no-baseline is
# not given), every failing test is compared with the baseline: a test that
# failed before AND fails now is "pre-existing"; a test that passed before and
# fails now is a regression; a failing test the baseline never ran counts as a
# regression too (it cannot be shown to pre-exist), unless its whole baseline
# group crashed without per-test results. The record's `baseline` object lists
# regressions / pre_existing / fixed, and flags a pre-existing failure whose
# message changed (it may now fail for another reason).
#
# PHPUnit itself comes from drupal/core-dev, which a plain recommended-project
# does not ship. When the subject has tests but vendor/bin/phpunit is missing,
# the run is recorded as `not-verified-blocked` (never as a false regression)
# and the actionable install command is printed, matched to the installed core
# (core_dev_requirement in common.sh), e.g.:
#   ddev composer require --dev "drupal/core-dev:~11.4.8" -W
#
# Exit codes:
#   0  -> all selected test groups passed (or there was nothing to run); with
#         --baseline / --baseline-from-last: the baseline was recorded, even red.
#   1  -> usage/internal error.
#   2  -> a hard 'test' requirement is missing: the preflight gate failed, DDEV
#         is down, or PHPUnit (drupal/core-dev) is not installed.
#   3  -> at least one test group failed (also when every failure is
#         pre-existing: the suite is not green; read `preservation`).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
TYPE="all"
COVERAGE=0
FILTER=""
RECORD=1
BASELINE_MODE=""      # "" | run | from-last
USE_BASELINE=1
RESULT_FILE=""
RECORD_FAILED=0

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --type) TYPE="${2:-all}"; shift 2;;
    --type=*) TYPE="${1#*=}"; shift;;
    --coverage) COVERAGE=1; shift;;
    --filter) FILTER="${2:-}"; shift 2;;
    --filter=*) FILTER="${1#*=}"; shift;;
    --baseline) BASELINE_MODE="run"; shift;;
    --baseline-from-last) BASELINE_MODE="from-last"; shift;;
    --no-baseline) USE_BASELINE=0; shift;;
    --no-record) RECORD=0; shift;;
    --result-file) RESULT_FILE="${2:-}"; shift 2;;
    --result-file=*) RESULT_FILE="${1#*=}"; shift;;
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
[[ -n "$BASELINE_MODE" && "$RECORD" == "0" ]] && die "--baseline/--baseline-from-last record a baseline; they cannot be combined with --no-record." 1
if [[ -n "$BASELINE_MODE" ]] && ! have_cmd jq; then die "jq is required to record a test baseline." 1; fi

STATE_DIR="$(project_state_dir "$SUBJECT")"
BASELINE_FILE="$STATE_DIR/test-baseline.json"

# --baseline-from-last: promote the last recorded run (it must carry per-test
# results, i.e. it was written by this version) to the baseline. No test runs,
# so no gate is needed.
if [[ "$BASELINE_MODE" == "from-last" ]]; then
  have_cmd jq || die "jq is required to promote last-test.json to the baseline." 1
  [[ -r "$STATE_DIR/last-test.json" ]] || die "No last-test.json for $SUBJECT yet: run the suite first (or use --baseline)." 1
  jq -e '(.tests | type) == "array"' "$STATE_DIR/last-test.json" >/dev/null 2>&1 \
    || die "last-test.json has no per-test results (recorded by an older drupilot): re-run with --baseline instead." 1
  jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{source:"last-test", taken_at:$at, recorded_at:(.recorded_at // null),
      subject_digest:(.subject_digest // null), git_head:(.git_head // null),
      type, filter:(.filter // null), status, ran, passed, failed, skipped,
      executed:(.executed // null), group_results:(.group_results // []), tests}' \
    "$STATE_DIR/last-test.json" > "$BASELINE_FILE.tmp" && mv "$BASELINE_FILE.tmp" "$BASELINE_FILE"
  log_ok "Baseline recorded from last-test.json: $BASELINE_FILE ($(jq '.tests | length' "$BASELINE_FILE") test result(s))."
  exit 0
fi

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
# Per-test results. PHPUnit writes a JUnit XML per group under the Drupal root
# (.drupilot/phpunit/, the gitignored artifacts dir) so the same relative path
# resolves on the host and inside the container; it is parsed on the host and
# removed. TESTS_TSV accumulates "group<TAB>id<TAB>status<TAB>message" lines.
# ---------------------------------------------------------------------------
JUNIT_REL=".drupilot/phpunit"
mkdir -p "$DRUPAL_ROOT/$JUNIT_REL" 2>/dev/null || true
[[ -f "$DRUPAL_ROOT/.drupilot/.gitignore" ]] || printf '*\n' > "$DRUPAL_ROOT/.drupilot/.gitignore" 2>/dev/null || true
TESTS_TSV="$(mktemp "${TMPDIR:-/tmp}/drupilot-phpunit.XXXXXX")"
GROUPS_TSV="$(mktemp "${TMPDIR:-/tmp}/drupilot-phpunit-groups.XXXXXX")"
# The per-test JSON (and the baseline comparison built from it) grows with the
# suite: a large one exceeds the kernel's per-argument limit (MAX_ARG_STRLEN,
# 128 KiB on Linux) if passed as `jq --argjson`. Those payloads therefore go
# to jq as files (--slurpfile), never on the command line.
TESTS_JSON_FILE="$(mktemp "${TMPDIR:-/tmp}/drupilot-phpunit-tests.XXXXXX")"
BASELINE_JSON_FILE="$(mktemp "${TMPDIR:-/tmp}/drupilot-phpunit-baseline.XXXXXX")"
_rp_cleanup() { rm -f "$TESTS_TSV" "$GROUPS_TSV" "$TESTS_JSON_FILE" "$BASELINE_JSON_FILE" "$DRUPAL_ROOT/$JUNIT_REL"/junit-$$-*.xml 2>/dev/null; return 0; }
trap _rp_cleanup EXIT

# parse_junit <group> <file> -> TSV lines on stdout, one per <testcase>:
# group, Class::method (data-set suffix kept), pass|fail|error|skipped, and the
# first meaningful line of the failure message (entities decoded, <= 240 chars).
# Line-based on purpose: PHPUnit writes one element per line. mawk/BSD-safe.
parse_junit() {
  [[ -s "$2" ]] || return 0
  awk -v grp="$1" '
    function attr(s, a,   i, r) { i = index(s, " " a "=\""); if (!i) return ""; r = substr(s, i + length(a) + 3); i = index(r, "\""); return substr(r, 1, i - 1) }
    function dec(s) { gsub(/&quot;/, "\"", s); gsub(/&#039;|&apos;/, "\047", s); gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s); gsub(/&#10;/, " ", s); gsub(/&amp;/, "\\&", s); gsub(/\t/, " ", s); return s }
    function flush() { if (cur != "") printf "%s\t%s\t%s\t%s\n", grp, cur, st, substr(msg, 1, 240); cur = ""; inmsg = 0 }
    /<testcase / { flush(); cur = dec(attr($0, "class")) "::" dec(attr($0, "name")); nm = dec(attr($0, "name")); st = "pass"; msg = ""; if ($0 ~ /\/>[ \t]*$/) flush(); next }
    cur == "" { next }
    /<failure|<error/ {
      st = ($0 ~ /<failure/) ? "fail" : "error"
      m = $0; sub(/^[^>]*>/, "", m); sub(/<\/(failure|error)>.*$/, "", m); m = dec(m)
      inmsg = 1
      if (m != "" && index(m, "::" nm) == 0) { msg = m; inmsg = 0 }
      if ($0 ~ /<\/(failure|error)>/) inmsg = 0
      next
    }
    /<skipped/ { if (st == "pass") st = "skipped"; next }
    /<\/testcase>/ { flush(); next }
    inmsg == 1 { m = $0; sub(/<\/(failure|error)>.*$/, "", m); m = dec(m); if (m != "") { msg = m; inmsg = 0 } }
    END { flush() }
  ' "$2"
  return 0
}

# ---------------------------------------------------------------------------
# Run each group. Never silence failures: stream output and record the result.
# ---------------------------------------------------------------------------
RAN=0
PASSED=0
FAILED=0
SKIPPED=0
EMPTY=0
EXECUTED=0
declare -a EMPTY_GROUPS=()
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
    printf '%s\t-\tskipped\t0\n' "$group" >> "$GROUPS_TSV"
    return 0
  fi

  if needs_selenium "$group"; then
    if ! selenium_ready; then
      log_warn "Selenium add-on not reachable — skipping FunctionalJavascript tests."
      log_warn "Install it with: ddev add-on get ddev/ddev-selenium-standalone-chrome && ddev restart"
      SELENIUM_NOTE="Selenium add-on not reachable; FunctionalJavascript tests skipped (external blocker)."
      SKIPPED=$((SKIPPED + 1))
      SKIPPED_GROUPS+=("$group")
      printf '%s\t-\tskipped\t0\n' "$group" >> "$GROUPS_TSV"
      return 0
    fi
  fi

  log_step "Running $group tests ($path)"
  RAN=$((RAN + 1))

  # Assemble the full command. PHPUnit's own exit code drives pass/fail; we do
  # not redirect or swallow its output. --log-junit only adds the per-test file.
  local junit="$JUNIT_REL/junit-$$-$group.xml"
  rm -f "$DRUPAL_ROOT/$junit" 2>/dev/null || true
  local -a cmd=(${RUNNER[@]+"${RUNNER[@]}"} "${PHPUNIT[@]}" --log-junit "$junit" ${COVERAGE_ARGS[@]+"${COVERAGE_ARGS[@]}"} ${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"} "$path")

  # Temporarily relax errexit around the test run so a failing group does not
  # abort the script before we summarise it.
  set +e
  "${cmd[@]}"
  local rc=$?
  set -e

  local executed=0 parsed have_log=0
  [[ -f "$DRUPAL_ROOT/$junit" ]] && have_log=1
  parsed="$(parse_junit "$group" "$DRUPAL_ROOT/$junit")"
  if [[ -n "$parsed" ]]; then
    printf '%s\n' "$parsed" >> "$TESTS_TSV"
    executed="$(printf '%s\n' "$parsed" | grep -c . || true)"
  fi
  rm -f "$DRUPAL_ROOT/$junit" 2>/dev/null || true
  EXECUTED=$((EXECUTED + executed))

  local gstatus
  if [[ "$rc" -eq 0 && "$have_log" == "0" ]]; then
    # PHPUnit passed but left no JUnit log (e.g. the artifacts dir is not
    # writable in the container): keep the exit-code verdict, without per-test data.
    log_ok "$group: passed (no per-test results: PHPUnit wrote no JUnit log to $junit)"
    PASSED=$((PASSED + 1))
    gstatus="passed"
  elif [[ "$rc" -eq 0 && "$executed" -eq 0 ]]; then
    # PHPUnit exits 0 on "No tests executed!" (e.g. a --filter that matches
    # nothing in this group): that proves nothing, so it is not a pass.
    RAN=$((RAN - 1)); EMPTY=$((EMPTY + 1)); EMPTY_GROUPS+=("$group")
    log_warn "$group: no test was executed${FILTER:+ (--filter '$FILTER' matched nothing here)} — not counted as passed."
    gstatus="empty"
  elif [[ "$rc" -eq 0 ]]; then
    log_ok "$group: passed ($executed test(s))"
    PASSED=$((PASSED + 1))
    gstatus="passed"
  elif [[ "$rc" -eq 126 || "$rc" -eq 127 ]]; then
    # The runner could not execute PHPUnit at all (not found / not executable):
    # an environment blocker, not a behavioral failure — never a regression.
    RAN=$((RAN - 1)); ENV_BLOCKED=1
    log_err "$group: PHPUnit could not be executed (exit $rc) — environment blocker, not a test failure."
    [[ -n "$BLOCKED_REASON" ]] || BLOCKED_REASON="PHPUnit could not be executed (exit $rc): check vendor/bin/phpunit inside the DDEV web container (drupal/core-dev: $(core_dev_requirement "$DRUPAL_ROOT"))."
    SKIPPED=$((SKIPPED + 1))
    SKIPPED_GROUPS+=("$group")
    gstatus="blocked"
  else
    log_err "$group: FAILED (phpunit exit $rc) — see the output above"
    FAILED=$((FAILED + 1))
    FAILED_GROUPS+=("$group")
    gstatus="failed"
    # No per-test result at all: PHPUnit died before writing its log.
    [[ "$executed" -eq 0 ]] && gstatus="crashed"
  fi
  printf '%s\t%s\t%s\t%s\n' "$group" "$rc" "$gstatus" "$executed" >> "$GROUPS_TSV"
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
log_plain "  groups run: $RAN   passed: $PASSED   failed: $FAILED   skipped: $SKIPPED   empty: $EMPTY   tests executed: $EXECUTED"
if [[ "$SKIPPED" -gt 0 ]]; then
  log_warn "Skipped (documented, not silenced): ${SKIPPED_GROUPS[*]}"
fi
if [[ "$EMPTY" -gt 0 ]]; then
  log_warn "Executed no test (not counted as passed): ${EMPTY_GROUPS[*]}"
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
#                            With a baseline: a test that passed in the baseline
#                            (or that the baseline never ran) fails now.
#   pre-existing-failures -> tests fail, but every failing test already failed in
#                            the pre-port baseline (test-baseline.json) and nothing
#                            that passed before fails now. The port introduced no
#                            regression the suite can see, but the pre-existing
#                            failures prove nothing either way: they are listed in
#                            `baseline.pre_existing`, never hidden.
#   not-verified-blocked  -> tests exist but none could run (e.g. Selenium absent,
#                            PHPUnit/drupal-core-dev not installed); see blocked_reason.
#   not-verified-no-tests -> no test exists in the selected --type scope, so
#                            preservation cannot be proven (drupilot never fabricates
#                            tests in Phase 1). subject_has_tests tells whether the
#                            subject ships tests in OTHER groups (a narrower --type)
#                            or none at all.
# tests lists every executed test ({group, id, status, message}); group_results
# the per-group outcome (passed/failed/crashed/empty/skipped/blocked).
# negative_controls carries the summary of negative-control.sh's records (or
# null): the proof that new tests can fail, kept next to the verdict.
# coverage records only what was actually collected (requested + the HTML path);
# a percentage is NOT computed in Phase 1, so the field stays honest about that.
if ! have_cmd jq; then
  log_warn "jq not found: the run is not recorded (last-test.json / baseline untouched)."
else
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

  if ! jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
      | {group: .[0], id: .[1], status: .[2],
         message: (if (.[2] == "fail" or .[2] == "error") and ((.[3] // "") != "") then .[3] else null end)})' \
      "$TESTS_TSV" > "$TESTS_JSON_FILE" 2>/dev/null; then
    log_warn "Could not parse the per-test results: the record lists no individual test."
    echo '[]' > "$TESTS_JSON_FILE"
  fi
  GROUPRES_JSON="$(jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
      | {group: .[0], rc: (.[1] | tonumber? // null), status: .[2], executed: (.[3] | tonumber? // 0)})' \
      "$GROUPS_TSV" 2>/dev/null || echo '[]')"
  DIGEST="$(subject_digest "$SUBJECT")"
  GIT_HEAD="$(git -C "$SUBJECT" rev-parse HEAD 2>/dev/null || true)"
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Baseline comparison (N6): classify each failure against the pre-port run.
  BASELINE_JSON="null"
  if [[ -z "$BASELINE_MODE" && "$USE_BASELINE" == "1" && -r "$BASELINE_FILE" ]] \
     && jq -e '(.tests | type) == "array"' "$BASELINE_FILE" >/dev/null 2>&1; then
    BASELINE_JSON="$(jq -c -n --slurpfile b "$BASELINE_FILE" --slurpfile curf "$TESTS_JSON_FILE" --argjson cg "$GROUPRES_JSON" \
        --arg file "$BASELINE_FILE" --arg digest "$DIGEST" '
      def bad: .status == "fail" or .status == "error";
      $curf[0] as $cur
      | $b[0] as $base
      | (reduce ($base.tests // [])[] as $t ({}; .[$t.id] = $t)) as $bm
      | (reduce ($base.group_results // [])[] as $g ({}; .[$g.group] = $g.status)) as $bgs
      | [ $cur[] | select(bad) | . as $t | ($bm[$t.id]) as $p
          | if $p == null then
              (if $bgs[$t.group] == "crashed"
               then {id: $t.id, group: $t.group, class: "pre-existing", basis: "baseline-group-crashed", now: $t.message}
               else {id: $t.id, group: $t.group, class: "regression", basis: "not-in-baseline", now: $t.message} end)
            elif ($p | bad) then
              {id: $t.id, group: $t.group, class: "pre-existing", basis: "test",
               message_changed: (($p.message // "") != ($t.message // "")), before: $p.message, now: $t.message}
            else {id: $t.id, group: $t.group, class: "regression", basis: "passed-before", now: $t.message} end ] as $cls
      | [ $cg[] | select(.status == "failed" or .status == "crashed") | .group as $g
          | select([ $cur[] | select(.group == $g) | select(bad) ] | length == 0)
          | if ($bgs[$g] == "failed" or $bgs[$g] == "crashed")
            then {id: null, group: $g, class: "pre-existing", basis: "group-\(.status)"}
            else {id: null, group: $g, class: "regression", basis: "group-\(.status)"} end ] as $grp
      | ($cls + $grp) as $all
      | {file: $file, source: ($base.source // "run"), taken_at: ($base.taken_at // null),
         type: ($base.type // null), filter: ($base.filter // null),
         same_code: (($base.subject_digest // "") != "" and $base.subject_digest == $digest),
         regressions: [ $all[] | select(.class == "regression") | del(.class) ],
         pre_existing: [ $all[] | select(.class == "pre-existing") | del(.class) ],
         fixed: [ $cur[] | select(.status == "pass") | .id as $i | select(($bm[$i] // {status: "pass"}) | bad) | $i ]}' \
        2>/dev/null || echo null)"
    if [[ "$BASELINE_JSON" != "null" && -n "$BASELINE_JSON" ]]; then
      printf '%s\n' "$BASELINE_JSON" > "$BASELINE_JSON_FILE"
      N_REG="$(printf '%s' "$BASELINE_JSON" | jq '.regressions | length')"
      N_PRE="$(printf '%s' "$BASELINE_JSON" | jq '.pre_existing | length')"
      N_FIX="$(printf '%s' "$BASELINE_JSON" | jq '.fixed | length')"
      log_info "Compared with the baseline ($(printf '%s' "$BASELINE_JSON" | jq -r '.taken_at // "?"')): $N_REG regression(s), $N_PRE pre-existing failure(s), $N_FIX fixed."
      if [[ "$(printf '%s' "$BASELINE_JSON" | jq -r '.same_code')" == "true" ]]; then
        log_warn "The baseline was taken on the current code: it cannot tell what the port changed (take it with --baseline BEFORE porting)."
      fi
      if [[ "$FAILED" -gt 0 && "$N_REG" -eq 0 ]]; then
        PRESERVATION="pre-existing-failures"
        log_warn "Every failing test already failed in the baseline (pre-existing): no regression, but the suite is not green."
      fi
      [[ "$N_REG" -gt 0 ]] && printf '%s' "$BASELINE_JSON" | jq -r '.regressions[] | "  regression: \(.id // ("group " + .group)) (\(.basis))"' >&2
    else
      BASELINE_JSON="null"
      log_warn "Could not compare with the baseline $BASELINE_FILE (unreadable): verdict computed without it."
    fi
  fi

  RECORD_JSON="$(jq -n -c \
    --arg type "$TYPE" --arg status "$RUN_STATUS" --arg preservation "$PRESERVATION" \
    --arg filter "$FILTER" --arg at "$NOW" --arg digest "$DIGEST" --arg head "$GIT_HEAD" \
    --argjson ran "$RAN" --argjson passed "$PASSED" \
    --argjson failed "$FAILED" --argjson skipped "$SKIPPED" \
    --argjson empty "$EMPTY" --argjson executed "$EXECUTED" \
    --argjson failed_groups "$(arr_to_json ${FAILED_GROUPS[@]+"${FAILED_GROUPS[@]}"})" \
    --argjson skipped_groups "$(arr_to_json ${SKIPPED_GROUPS[@]+"${SKIPPED_GROUPS[@]}"})" \
    --argjson empty_groups "$(arr_to_json ${EMPTY_GROUPS[@]+"${EMPTY_GROUPS[@]}"})" \
    --arg js_skipped_reason "$SELENIUM_NOTE" \
    --arg blocked_reason "$BLOCKED_REASON" \
    --argjson subject_has_tests "$SUBJECT_HAS_TESTS" \
    --argjson groups_with_tests "$(arr_to_json ${GROUPS_WITH_TESTS[@]+"${GROUPS_WITH_TESTS[@]}"})" \
    --argjson cov_requested "$COV_REQUESTED" --arg cov_html "$COV_HTML_PATH" \
    --argjson group_results "$GROUPRES_JSON" --slurpfile testsf "$TESTS_JSON_FILE" \
    --slurpfile baselinef "$BASELINE_JSON_FILE" \
    --argjson negative_controls "$(negative_controls_summary "$SUBJECT")" \
    '{type:$type, status:$status, preservation:$preservation,
      ran:$ran, passed:$passed, failed:$failed,
      skipped:$skipped, failed_groups:$failed_groups, skipped_groups:$skipped_groups,
      empty:$empty, empty_groups:$empty_groups, executed:$executed,
      js_skipped_reason: ($js_skipped_reason | select(. != "") // null),
      blocked_reason: ($blocked_reason | select(. != "") // null),
      subject_has_tests:$subject_has_tests, groups_with_tests:$groups_with_tests,
      coverage: {requested:$cov_requested, html: ($cov_html | select(. != "") // null), percent: null},
      filter: ($filter | select(. != "") // null), recorded_at:$at,
      subject_digest: ($digest | select(. != "") // null), git_head: ($head | select(. != "") // null),
      baseline: ($baselinef[0] // null), negative_controls:$negative_controls,
      group_results:$group_results, tests: ($testsf[0] // [])}' 2>/dev/null || true)"
  if [[ -z "$RECORD_JSON" ]]; then
    # Never fall through silently: an empty record would leave last-test.json
    # stale and write an empty baseline / result file.
    log_err "Could not build the run record (jq failed): last-test.json, the baseline and --result-file are NOT updated."
    [[ "$BASELINE_MODE" == "run" ]] && exit 1
    RECORD_FAILED=1
  fi

  if [[ -n "$RESULT_FILE" && -n "$RECORD_JSON" ]]; then
    printf '%s\n' "$RECORD_JSON" > "$RESULT_FILE" 2>/dev/null || log_warn "Could not write --result-file $RESULT_FILE"
  fi

  if [[ "$BASELINE_MODE" == "run" ]]; then
    if [[ "$RAN" -eq 0 && "$FAILED" -eq 0 ]]; then
      log_err "No test executed, so no baseline was recorded${BLOCKED_REASON:+: $BLOCKED_REASON}."
      [[ "$ENV_BLOCKED" == "1" ]] && exit 2
      exit 1
    fi
    printf '%s' "$RECORD_JSON" | jq '{source:"run", taken_at:.recorded_at, recorded_at, subject_digest, git_head,
        type, filter, status, ran, passed, failed, skipped, executed, group_results, tests}' \
      > "$BASELINE_FILE.tmp" && mv "$BASELINE_FILE.tmp" "$BASELINE_FILE"
    log_ok "Baseline recorded: $BASELINE_FILE ($EXECUTED test(s); $(printf '%s' "$RECORD_JSON" | jq '[.tests[] | select(.status == "fail" or .status == "error")] | length') failing before the port)."
    [[ "$SKIPPED" -gt 0 ]] && log_warn "Groups skipped in the baseline (${SKIPPED_GROUPS[*]}): their failures after the port cannot be shown to pre-exist."
    log_info "last-test.json is untouched. Later runs compare every failure with this baseline (--no-baseline to ignore it)."
    exit 0
  fi

  if [[ "$RECORD" == "1" && -n "$RECORD_JSON" ]]; then
    printf '%s\n' "$RECORD_JSON" > "$STATE_DIR/last-test.json" 2>/dev/null || true
  fi
fi

if [[ "$FAILED" -gt 0 ]]; then
  log_err "Failing groups: ${FAILED_GROUPS[*]}"
  if [[ "${PRESERVATION:-}" == "pre-existing-failures" ]]; then
    log_err "Tests did not pass, although every failure pre-exists the port (see the baseline comparison above). They stay documented, never hidden."
  else
    log_err "Tests did not pass. Review the output above and iterate — failures are never hidden."
  fi
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
  elif [[ "$EMPTY" -gt 0 ]]; then
    log_warn "No test was executed for --type '$TYPE'${FILTER:+ with --filter '$FILTER'}: nothing is verified."
  elif [[ "$SUBJECT_HAS_TESTS" == "true" ]]; then
    log_warn "No tests in the selected --type '$TYPE' scope (the subject has tests in other groups; try --type all)."
  else
    log_warn "No test groups were executed: the subject ships no PHPUnit tests."
  fi
  exit 0
fi

if [[ "$RECORD_FAILED" == "1" ]]; then
  log_err "The tests passed, but the run could not be recorded (see above)."
  exit 1
fi
log_ok "All executed test groups passed."
exit 0
