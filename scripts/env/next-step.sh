#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/next-step.sh
# Single source of truth for the "what should I do next?" ladder, so the router
# (/drupilot) and /drupilot-status recommend the SAME step instead of each
# restating the rules in prose (which drift apart).
#
# It reads the per-project state (assess.json, the phase marker, last-test.json,
# the lockfile) and the subject facts (extension? type? DDEV configured?), and
# the four readiness booleans the caller already computed from `preflight --json`
# (passed in to avoid a second, slow preflight run). It emits the single
# recommended next step + a human reason.
#
# Ladder (PROMPT 4.4): doctor -> setup -> assess -> port -> [refactor] -> test
#                      -> [contribute]. refactor and contribute are opt-in.
#
# Usage:
#   next-step.sh --subject DIR
#                [--ready-analyze BOOL] [--ready-setup BOOL]
#                [--ready-test BOOL] [--ready-contribute BOOL]
#                [--json]
#   BOOL is true|false; unknown readiness defaults to true (the ladder then just
#   skips the /drupilot-doctor recommendation).
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
R_ANALYZE="true"; R_SETUP="true"; R_TEST="true"; R_CONTRIBUTE="true"
AS_JSON=1

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }
norm_bool() { case "${1,,}" in 1|true|yes|on) printf 'true';; *) printf 'false';; esac; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --ready-analyze) R_ANALYZE="$(norm_bool "${2:-}")"; shift 2;;
    --ready-setup) R_SETUP="$(norm_bool "${2:-}")"; shift 2;;
    --ready-test) R_TEST="$(norm_bool "${2:-}")"; shift 2;;
    --ready-contribute) R_CONTRIBUTE="$(norm_bool "${2:-}")"; shift 2;;
    --json) AS_JSON=1; shift;;
    --human) AS_JSON=0; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

[[ -n "$SUBJECT" ]] || SUBJECT="$PWD"
[[ -d "$SUBJECT" ]] || die "Subject directory not found: $SUBJECT" 1
SUBJECT="$(cd "$SUBJECT" && pwd)"

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
