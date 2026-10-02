#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/next-step.sh
# Single source of truth for the "what should I do next?" ladder, so the router
# (/drupilot) and /drupilot-status recommend the SAME step instead of each
# restating the rules in prose (which drift apart).
#
# It reads the per-project state (assess.json, the phase marker, last-test.json,
# the lockfile) and the subject facts (extension? type? DDEV configured?), and
# the four readiness booleans — either passed in by a caller that already ran
# `preflight --json`, or read by this script itself with --from-preflight. It
# emits the single recommended next step + a human reason.
#
# Ladder (PROMPT 4.4): doctor -> setup -> assess -> port -> [refactor] -> test
#                      -> [contribute]. refactor and contribute are opt-in.
#
# Usage:
#   next-step.sh --subject DIR
#                [--ready-analyze BOOL] [--ready-setup BOOL]
#                [--ready-test BOOL] [--ready-contribute BOOL]
#                [--from-preflight] [--json|--human]
#   BOOL is true|false (also 1/0, yes/no, on/off).
#   --subject DIR     defaults to the current directory; a value that is not a
#                     directory (e.g. a router mode word such as "auto" passed
#                     as $1) falls back to it with a warning on STDERR.
#   --from-preflight  run `preflight.sh --profile all --json` once (~0.5 s) and
#                     take every readiness value NOT given explicitly from its
#                     `.ready` object. Use it from a load-time !`...` line, where
#                     the caller cannot substitute values it parsed earlier.
#                     (`--ready-from-preflight` is an accepted alias.)
#   An unparseable BOOL (e.g. an unsubstituted "<ready.analyze>" placeholder) is
#   treated as unknown: a warning goes to STDERR and the value is filled from
#   preflight as if --from-preflight had been given. Readiness that stays
#   unknown (no flag, or preflight/jq unavailable) defaults to true (the ladder
#   then just skips the /drupilot-doctor recommendation).
#
# Output:
#   --json (default) -> {next, command, reason, phase, assessed, ddev_configured,
#                        ddev_running, tests, preservation, is_extension, type}
#   --human          -> a one-line "Next: <command> — <reason>" on STDOUT.
#
# Exit codes: 0 ok · 1 usage/error. (Read-only: never mutates anything.)
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
# Readiness starts empty (= not given); see the defaulting below.
R_ANALYZE=""; R_SETUP=""; R_TEST=""; R_CONTRIBUTE=""
FROM_PREFLIGHT=0
AS_JSON=1

usage() { print_usage "$0"; }
# norm_bool VALUE -> true | false | unknown (anything not boolean-like).
norm_bool() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) printf 'true';;
    0|false|no|off) printf 'false';;
    *) printf 'unknown';;
  esac
}
# ready_arg FLAG VALUE -> the normalized value, warning when it is unparseable.
ready_arg() {
  local v; v="$(norm_bool "$2")"
  if [[ "$v" == "unknown" ]]; then
    log_warn "$1: unparseable readiness value '$2' (an unsubstituted placeholder?) — reading it from preflight instead."
  fi
  printf '%s' "$v"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --ready-analyze) R_ANALYZE="$(ready_arg "$1" "${2:-}")"; shift 2;;
    --ready-setup) R_SETUP="$(ready_arg "$1" "${2:-}")"; shift 2;;
    --ready-test) R_TEST="$(ready_arg "$1" "${2:-}")"; shift 2;;
    --ready-contribute) R_CONTRIBUTE="$(ready_arg "$1" "${2:-}")"; shift 2;;
    --from-preflight|--ready-from-preflight) FROM_PREFLIGHT=1; shift;;
    --json) AS_JSON=1; shift;;
    --human) AS_JSON=0; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

[[ -n "$SUBJECT" ]] || SUBJECT="$PWD"
# The router passes its first argument here, which is often a mode word
# (`/drupilot auto`) or the first word of a request (`/drupilot port this ...`)
# rather than a path. Fall back to the current directory, as the router's own
# state detection does, instead of failing the command load.
if [[ ! -d "$SUBJECT" ]]; then
  log_warn "'$SUBJECT' is not a directory; using the current directory as the subject."
  SUBJECT="$PWD"
fi
SUBJECT="$(cd "$SUBJECT" && pwd)"

# --- Readiness ---------------------------------------------------------------
# Fill the values not given (or unparseable) from one preflight run when asked
# to, or when a caller passed garbage; whatever stays unknown defaults to true.
NEED_PF=0
for _r in "$R_ANALYZE" "$R_SETUP" "$R_TEST" "$R_CONTRIBUTE"; do
  [[ "$_r" == "unknown" ]] && NEED_PF=1
  [[ "$FROM_PREFLIGHT" == "1" && -z "$_r" ]] && NEED_PF=1
done
if [[ "$NEED_PF" == "1" ]]; then
  PF_READY=""
  if have_cmd jq; then
    PF_READY="$(bash "$(plugin_root)/scripts/env/preflight.sh" --profile all --json --quiet 2>/dev/null \
      | jq -r '.ready | [.analyze, .setup, .test, .contribute] | map(if . == null then "-" else tostring end) | join(" ")' 2>/dev/null || true)"
  else
    # No jq: preflight itself would report analyze as not ready (jq is a hard
    # analyze requirement), so say so rather than silently assuming readiness.
    PF_READY="false"
  fi
  if [[ -n "$PF_READY" ]]; then
    # Four space-separated tokens (true/false, or "-" when preflight omitted one).
    # shellcheck disable=SC2086  # intentional word split.
    set -- $PF_READY
    [[ -z "$R_ANALYZE"    || "$R_ANALYZE"    == "unknown" ]] && R_ANALYZE="$(norm_bool "${1:-}")"
    [[ -z "$R_SETUP"      || "$R_SETUP"      == "unknown" ]] && R_SETUP="$(norm_bool "${2:-}")"
    [[ -z "$R_TEST"       || "$R_TEST"       == "unknown" ]] && R_TEST="$(norm_bool "${3:-}")"
    [[ -z "$R_CONTRIBUTE" || "$R_CONTRIBUTE" == "unknown" ]] && R_CONTRIBUTE="$(norm_bool "${4:-}")"
  else
    log_warn "Could not read readiness from preflight; assuming the environment is ready."
  fi
fi
[[ -z "$R_ANALYZE"    || "$R_ANALYZE"    == "unknown" ]] && R_ANALYZE="true"
[[ -z "$R_SETUP"      || "$R_SETUP"      == "unknown" ]] && R_SETUP="true"
# test/contribute readiness is accepted (and filled) for CLI symmetry, but the
# ladder does not branch on it today.
[[ -z "$R_TEST"       || "$R_TEST"       == "unknown" ]] && R_TEST="true"
[[ -z "$R_CONTRIBUTE" || "$R_CONTRIBUTE" == "unknown" ]] && R_CONTRIBUTE="true"

# --- Gather state (read-only) ----------------------------------------------
ROOT="$(find_drupal_root "$SUBJECT" 2>/dev/null || true)"
STATE_DIR="$(project_state_dir "$SUBJECT")"
IS_EXT="$(is_drupal_extension_dir "$SUBJECT" && echo true || echo false)"
TYPE="$(subject_type "$SUBJECT" 2>/dev/null || echo unknown)"

DDEV_CONFIGURED="false"; DDEV_RUNNING="false"
[[ -n "$ROOT" && -f "$ROOT/.ddev/config.yaml" ]] && DDEV_CONFIGURED="true"
ddev_running "$ROOT" 2>/dev/null && DDEV_RUNNING="true"

ASSESSED="false"; [[ -f "$STATE_DIR/assess.json" ]] && ASSESSED="true"

PHASE=""; [[ -f "$STATE_DIR/phase" ]] && PHASE="$(tr -d '[:space:]' < "$STATE_DIR/phase" 2>/dev/null || true)"
PORTED="false"
case "$PHASE" in ported|refactored|tested|contributed) PORTED="true";; esac
REFACTORED="false"
case "$PHASE" in refactored|tested|contributed) REFACTORED="true";; esac

# Test outcome / preservation verdict from the persisted record.
TESTS="unknown"; PRESERVATION="unknown"
if [[ -f "$STATE_DIR/last-test.json" ]] && have_cmd jq; then
  TESTS="$(jq -r '.status // "unknown"' "$STATE_DIR/last-test.json" 2>/dev/null || echo unknown)"
  PRESERVATION="$(jq -r '.preservation // "unknown"' "$STATE_DIR/last-test.json" 2>/dev/null || echo unknown)"
fi

# Did the developer opt into the Phase 2 refactor? (pref / env, default false.)
WANT_REFACTOR="$(config_get DRUPILOT_WANT_REFACTOR false)"; WANT_REFACTOR="$(norm_bool "$WANT_REFACTOR")"
[[ "$WANT_REFACTOR" == "true" ]] || WANT_REFACTOR="false"

# --- The ladder ------------------------------------------------------------
NEXT=""; CMD=""; REASON=""
if [[ "$R_ANALYZE" == "false" ]]; then
  NEXT="doctor"; CMD="/drupilot-doctor"
  REASON="The analysis requirements are not met yet — fix them first."
elif [[ "$R_SETUP" == "true" && "$DDEV_CONFIGURED" == "false" ]]; then
  NEXT="setup"; CMD="/drupilot-setup"
  REASON="No DDEV environment yet — provision Drupal 11 + the toolchain so the port and tests can run."
elif [[ "$ASSESSED" == "false" ]]; then
  NEXT="assess"; CMD="/drupilot-assess"
  REASON="Not assessed yet — measure the effort and get a phased plan before touching code."
elif [[ "$PORTED" == "false" ]]; then
  NEXT="port"; CMD="/drupilot-port"
  REASON="Assessed but not ported — apply the minimal Drupal 11 compatibility port."
elif [[ "$WANT_REFACTOR" == "true" && "$REFACTORED" == "false" ]]; then
  NEXT="refactor"; CMD="/drupilot-refactor"
  REASON="Ported, and you opted into the full Drupal 11 way — run the refactor (opt-in)."
elif [[ "$TESTS" == "failed" && "$PRESERVATION" == "pre-existing-failures" ]]; then
  NEXT="test"; CMD="/drupilot-test"
  REASON="The last run is red only on failures that already failed before the port (no regression against the baseline) — they prove nothing either way: fix them in the code or document them, and review any that now fail differently."
elif [[ "$TESTS" == "failed" ]]; then
  NEXT="test"; CMD="/drupilot-test"
  REASON="The last test run was red — fix the code (never the test) until the suite is green."
elif [[ "$TESTS" == "unknown" ]]; then
  NEXT="test"; CMD="/drupilot-test"
  REASON="Ported but the suite has not been run on Drupal 11 yet — run it to confirm behavior is preserved."
else
  # Tests ran (passed / none-run). Be honest about the preservation verdict: a
  # 'none-run' (no tests) or 'blocked' result is NOT green, so never call it that.
  case "$PRESERVATION" in
    not-verified-no-tests)
      STATE_NOTE="Ported, but the subject ships no tests, so preservation is NOT verified (drupilot does not fabricate them). Adding tests is recommended before relying on it.";;
    not-verified-blocked)
      STATE_NOTE="Ported, but the tests could not run (an external blocker), so preservation is NOT verified — see the documented blocker.";;
    verified-partial)
      STATE_NOTE="Ported; the tests that ran are green, but some groups were skipped (an external blocker), so preservation is only PARTIALLY verified.";;
    *)
      STATE_NOTE="Ported and green — behavior preservation is verified.";;
  esac
  if [[ "$IS_EXT" == "true" ]]; then
    NEXT="contribute"; CMD="/drupilot-contribute"
    REASON="$STATE_NOTE Contributing upstream is opt-in — or get a patch any time with /drupilot-patch."
  else
    NEXT="done"; CMD=""
    REASON="$STATE_NOTE Nothing required next; /drupilot-patch can produce a patch any time."
  fi
fi

# --- Emit ------------------------------------------------------------------
if [[ "$AS_JSON" == "1" ]] && have_cmd jq; then
  jq -n \
    --arg next "$NEXT" --arg command "$CMD" --arg reason "$REASON" \
    --arg phase "$PHASE" --argjson assessed "$ASSESSED" \
    --argjson ddev_configured "$DDEV_CONFIGURED" --argjson ddev_running "$DDEV_RUNNING" \
    --arg tests "$TESTS" --arg preservation "$PRESERVATION" \
    --argjson is_extension "$IS_EXT" --arg type "$TYPE" \
    '{next:$next, command:$command, reason:$reason,
      phase: ($phase | select(. != "") // null),
      assessed:$assessed, ddev_configured:$ddev_configured, ddev_running:$ddev_running,
      tests:$tests, preservation:$preservation, is_extension:$is_extension, type:$type}'
else
  if [[ -n "$CMD" ]]; then printf 'Next: %s — %s\n' "$CMD" "$REASON"
  else printf 'Next: (nothing required) — %s\n' "$REASON"; fi
fi
exit 0
