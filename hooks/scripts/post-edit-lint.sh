#!/usr/bin/env bash
# =============================================================================
# drupilot — hooks/scripts/post-edit-lint.sh
# PostToolUse hook for Write|Edit (incremental Drupal lint, PROMPT 5.9).
#
# When the just-edited file is a Drupal source file inside a Drupal extension,
# run phpcbf (autofix) then phpcs (Drupal,DrupalPractice) best-effort through
# `drupal_runner`. If violations remain, return them as English
# `additionalContext` so the model can fix them. Skip silently when phpcs is
# unavailable or the file is not applicable.
#
# Fail-safe contract (CONTRACT 5.4):
#   * never `set -e`, never exit non-zero;
#   * print JSON on STDOUT to act, nothing to no-op (the safe default);
#   * every optional tool guarded with `|| true`.
# =============================================================================
set -uo pipefail

# shellcheck source=../../scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh" 2>/dev/null || true

# Emit an additionalContext payload and exit cleanly. No-op without jq.
emit_context() {
  local ctx="$1"
  if have_cmd jq; then
    jq -n --arg ctx "$ctx" \
      '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}' 2>/dev/null || true
  fi
  exit 0
}

# --- Read hook input ---------------------------------------------------------
INPUT="$(cat 2>/dev/null || true)"

# jq is required to safely parse tool_input and build output; without it, no-op.
have_cmd jq || exit 0

FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
[[ -z "$FILE" ]] && exit 0
[[ -f "$FILE" ]] || exit 0

# --- Only act on Drupal source files -----------------------------------------
case "$FILE" in
  *.php|*.module|*.theme|*.inc|*.install|*.yml|*.twig) : ;;
  *) exit 0 ;;
esac

# --- The file must live inside a Drupal extension -----------------------------
FILE_DIR="$(dirname "$FILE" 2>/dev/null || true)"
[[ -z "$FILE_DIR" ]] && exit 0

# Walk up from the file's directory looking for a *.info.yml (extension root).
EXT_DIR=""
probe="$(cd "$FILE_DIR" 2>/dev/null && pwd || true)"
while [[ -n "$probe" && "$probe" != "/" ]]; do
  if is_drupal_extension_dir "$probe" 2>/dev/null; then EXT_DIR="$probe"; break; fi
  probe="$(dirname "$probe")"
done
[[ -z "$EXT_DIR" ]] && exit 0

# --- Locate the Drupal root and the toolchain runner --------------------------
DRUPAL_ROOT="$(find_drupal_root "$EXT_DIR" 2>/dev/null || true)"
[[ -z "$DRUPAL_ROOT" ]] && DRUPAL_ROOT="$EXT_DIR"

RUNNER="$(drupal_runner "$DRUPAL_ROOT" 2>/dev/null || true)"

# phpcbf/phpcs are resolved via the Drupal root's vendor/bin. If neither the
# runner can reach them nor a host binary exists, skip silently.
PHPCS_BIN="vendor/bin/phpcs"
PHPCBF_BIN="vendor/bin/phpcbf"

if [[ -z "$RUNNER" ]]; then
  # No DDEV runner -> need host binaries present at the Drupal root.
  if [[ ! -x "$DRUPAL_ROOT/$PHPCS_BIN" ]]; then
    if have_cmd phpcs; then PHPCS_BIN="phpcs"; PHPCBF_BIN="phpcbf"; else exit 0; fi
  fi
fi

STD="Drupal,DrupalPractice"
EXTS="php,module,inc,install,test,profile,theme,info,txt,md,yml"

# --- Behavior toggle + phase awareness ---------------------------------------
# DRUPILOT_POST_EDIT_LINT: autofix (default) | report (run phpcs, never modify
# files) | off (do nothing). The developer stays in control of in-place edits.
MODE="$(config_get DRUPILOT_POST_EDIT_LINT autofix 2>/dev/null || echo autofix)"
case "${MODE,,}" in off) exit 0;; report|autofix) : ;; *) MODE="autofix";; esac

# Phase-aware strictness: during Phase 1 (minimal port) surface only ERRORS
# (compatibility), not DrupalPractice WARNINGS — premature style nagging belongs
# to Phase 2. In the refactor phase, surface both.
PHASE="$(tr -d '[:space:]' < "$(project_state_dir "$EXT_DIR" 2>/dev/null)/phase" 2>/dev/null || true)"

# Run from the Drupal root so relative paths resolve identically on host/in DDEV.
REL="$FILE"
case "$FILE" in
  "$DRUPAL_ROOT"/*) REL="${FILE#"$DRUPAL_ROOT"/}" ;;
esac

# --- phpcbf (autofix, only in autofix mode), then phpcs (report) --------------
# In autofix mode, report whether phpcbf actually changed the file on disk, so
# the in-place edit is never silent.
CHANGED_NOTE=""
if [[ "$MODE" == "autofix" ]]; then
  BEFORE="$(cksum "$FILE" 2>/dev/null || true)"
  ( cd "$DRUPAL_ROOT" 2>/dev/null && $RUNNER "$PHPCBF_BIN" --standard="$STD" "$REL" >/dev/null 2>&1 ) || true
  AFTER="$(cksum "$FILE" 2>/dev/null || true)"
  [[ -n "$BEFORE" && "$BEFORE" != "$AFTER" ]] && \
    CHANGED_NOTE="phpcbf auto-corrected coding-standard issues in ${REL} (the file on disk was modified). "
fi

PHPCS_OUT="$(cd "$DRUPAL_ROOT" 2>/dev/null && $RUNNER "$PHPCS_BIN" --standard="$STD" --extensions="$EXTS" --report=full --no-colors "$REL" 2>/dev/null || true)"

# Nothing from phpcs -> only surface an autofix note, if any.
if [[ -z "$PHPCS_OUT" ]] || ! printf '%s' "$PHPCS_OUT" | grep -qiE 'ERROR|WARNING'; then
  [[ -n "$CHANGED_NOTE" ]] && emit_context "$CHANGED_NOTE"
  exit 0
fi

# Phase 1: if only WARNINGS remain (no ERROR), do not nag — just note any autofix.
# Match ERROR case-SENSITIVELY: phpcs prints the severity column in uppercase, so
# this avoids a WARNING whose message text says "error" tripping the error gate.
if [[ "$PHASE" != "refactor" ]] && ! printf '%s' "$PHPCS_OUT" | grep -qE '\bERROR\b'; then
  [[ -n "$CHANGED_NOTE" ]] && emit_context "$CHANGED_NOTE"
  exit 0
fi

NOTE="The remaining violations below need a manual fix"
[[ "$PHASE" != "refactor" ]] && NOTE="The remaining ERRORS below need a manual fix (Phase 1 surfaces compatibility errors only; DrupalPractice style warnings are deferred to /drupilot-refactor)"
MSG="drupilot incremental lint on ${REL}. ${CHANGED_NOTE}${NOTE}:
${PHPCS_OUT}"

emit_context "$MSG"
