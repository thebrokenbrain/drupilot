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

# Run from the Drupal root so relative paths resolve identically on host/in DDEV.
REL="$FILE"
case "$FILE" in
  "$DRUPAL_ROOT"/*) REL="${FILE#"$DRUPAL_ROOT"/}" ;;
esac

# --- phpcbf (autofix) then phpcs (report), both best-effort -------------------
( cd "$DRUPAL_ROOT" 2>/dev/null && $RUNNER "$PHPCBF_BIN" --standard="$STD" "$REL" >/dev/null 2>&1 ) || true

PHPCS_OUT=""
PHPCS_OUT="$(cd "$DRUPAL_ROOT" 2>/dev/null && $RUNNER "$PHPCS_BIN" --standard="$STD" --extensions="$EXTS" --report=full --no-colors "$REL" 2>/dev/null || true)"

# No output, or phpcs reported a clean file -> nothing to surface.
[[ -z "$PHPCS_OUT" ]] && exit 0
if ! printf '%s' "$PHPCS_OUT" | grep -qiE 'ERROR|WARNING'; then
  exit 0
fi

MSG="drupilot incremental lint ran phpcbf + phpcs (Drupal,DrupalPractice) on ${REL}. Autofixable issues were corrected automatically; the remaining violations below need a manual fix:
${PHPCS_OUT}"

emit_context "$MSG"
