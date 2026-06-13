#!/usr/bin/env bash
# =============================================================================
# drupilot — hooks/scripts/session-detect-env.sh
# SessionStart hook (non-blocking environment summary, PROMPT 4.4.4 / 5.9).
#
# Reads the hook JSON on STDIN, runs a lightweight preflight (--profile all),
# and — only when the session's cwd is a Drupal extension — emits English
# `additionalContext` describing the effective PHP target and readiness, and
# suggests /drupilot-doctor when something relevant is missing.
#
# Fail-safe contract (CONTRACT 5.4):
#   * never `set -e`, never exit non-zero;
#   * print JSON on STDOUT to act, nothing to no-op (the safe default);
#   * every optional tool / parse step guarded with `|| true`.
# =============================================================================
set -uo pipefail

# shellcheck source=../../scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh" 2>/dev/null || true

# Emit an additionalContext payload and exit cleanly. No-op if jq is missing
# (we cannot build well-formed JSON safely without it).
emit_context() {
  local ctx="$1"
  if have_cmd jq; then
    jq -n --arg ctx "$ctx" \
      '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' 2>/dev/null || true
  fi
  exit 0
}

# --- Read hook input ---------------------------------------------------------
INPUT="$(cat 2>/dev/null || true)"

CWD=""
if have_cmd jq; then
  CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
[[ -z "$CWD" ]] && CWD="${PWD:-.}"

# --- Only act inside a Drupal extension (module / theme / profile) -----------
# Keep the hook quiet everywhere else so it never adds noise to unrelated work.
if ! is_drupal_extension_dir "$CWD" 2>/dev/null; then
  exit 0
fi

SUBJECT="$(subject_machine_name "$CWD" 2>/dev/null || true)"
SUBJECT_TYPE="$(subject_type "$CWD" 2>/dev/null || true)"
[[ -z "$SUBJECT" ]] && SUBJECT="this extension"
[[ -z "$SUBJECT_TYPE" ]] && SUBJECT_TYPE="extension"

TARGET="$(resolve_php_target 2>/dev/null || true)"
[[ -z "$TARGET" ]] && TARGET="8.3"

PHP_NOTE=""
if php_target_unconfirmed "$TARGET" 2>/dev/null; then
  PHP_NOTE=" (not officially confirmed on Drupal 11 yet — detected at runtime, do not assume support)"
fi

# --- Lightweight preflight (report only, never blocks) -----------------------
PRE_ROOT="$(plugin_root 2>/dev/null || true)"
PRE_JSON=""
if [[ -n "$PRE_ROOT" && -f "$PRE_ROOT/scripts/env/preflight.sh" ]] && have_cmd jq; then
  PRE_JSON="$(bash "$PRE_ROOT/scripts/env/preflight.sh" --profile all --json --quiet 2>/dev/null || true)"
fi

R_ANALYZE="unknown"; R_SETUP="unknown"; R_CONTRIBUTE="unknown"
if [[ -n "$PRE_JSON" ]]; then
  R_ANALYZE="$(printf '%s' "$PRE_JSON" | jq -r '.ready.analyze // "unknown"' 2>/dev/null || true)"
  R_SETUP="$(printf '%s' "$PRE_JSON" | jq -r '.ready.setup // "unknown"' 2>/dev/null || true)"
  R_CONTRIBUTE="$(printf '%s' "$PRE_JSON" | jq -r '.ready.contribute // "unknown"' 2>/dev/null || true)"
  # Prefer the preflight's own resolved target when available.
  PT="$(printf '%s' "$PRE_JSON" | jq -r '.php_target // empty' 2>/dev/null || true)"
  [[ -n "$PT" ]] && TARGET="$PT"
fi

badge() { case "$1" in true) printf 'ready';; false) printf 'not ready';; *) printf 'unknown';; esac; }

# --- Build the English context message --------------------------------------
MSG="drupilot detected a Drupal ${SUBJECT_TYPE} (\"${SUBJECT}\") in the working directory."
MSG="${MSG} Effective PHP target: ${TARGET}${PHP_NOTE}."
MSG="${MSG} Readiness — analysis: $(badge "$R_ANALYZE"); environment+tests (DDEV): $(badge "$R_SETUP"); contribution (Drupal.org): $(badge "$R_CONTRIBUTE")."

# Determinism note: drupilot is reproducible by default (frozen versions/refs).
DET="true"
if declare -f config_get >/dev/null 2>&1; then
  DET="$(config_get DRUPILOT_DETERMINISTIC true 2>/dev/null || echo true)"
fi
case "${DET,,}" in
  1|true|yes|on) MSG="${MSG} Deterministic mode is ON: resolved versions/refs are frozen per-project so the same module ports the same way.";;
  *) MSG="${MSG} Deterministic mode is OFF (DRUPILOT_DETERMINISTIC=${DET}); versions/refs resolve fresh each run.";;
esac

# Suggest the doctor only when something relevant is actually missing.
SUGGEST=0
[[ "$R_ANALYZE" == "false" || "$R_SETUP" == "false" ]] && SUGGEST=1

if [[ "$SUGGEST" == "1" ]]; then
  MSG="${MSG} Some requirements are missing — run /drupilot-doctor for the full report and assisted installation before starting a port."
fi

emit_context "$MSG"
