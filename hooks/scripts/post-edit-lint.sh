#!/usr/bin/env bash
# =============================================================================
# drupilot — hooks/scripts/post-edit-lint.sh
# PostToolUse hook for Write|Edit (incremental Drupal lint, PROMPT 5.9).
#
# When the just-edited file is a Drupal source file inside a Drupal extension,
# run phpcbf (autofix; in Phase 1 without the unused-use sniffs) then phpcs
# best-effort through `drupal_runner`. If violations remain, return them as
# English `additionalContext` so the model can fix them. Skip silently when
# phpcs is unavailable or the file is not applicable.
#
# Ruleset: the one scripts/analysis/run-phpcs.sh resolved and verified for this
# extension (the project's own ruleset when it ships a loadable one), read from
# the phpcs-ruleset.json it records in the hidden state dir, so the hook and the
# validate loop lint with the same rules. The hook never probes or discovers a
# ruleset itself (it runs on every edit): with no record yet, with
# DRUPILOT_PHPCS_RULESET=drupilot, or when the ruleset changed since it was
# recorded, it uses Drupal,DrupalPractice as before.
#
# Fail-safe contract (CONTRACT 5.4):
#   * never `set -e`, never exit non-zero;
#   * print JSON on STDOUT to act, nothing to no-op (the safe default);
#   * every optional tool guarded with `|| true`.
# =============================================================================
set -uo pipefail

# Only the shared-library domains this hook may reach (scripts/dev/check.sh,
# gate lib-defs, checks the list with a static scan, where a function name in a
# message counts too).
_DRUPILOT_LIBS="core paths config subject ddev state"
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
declare -a TV_ARGS=()
RS_JSON="$(project_state_dir "$EXT_DIR" 2>/dev/null || true)/phpcs-ruleset.json"
RS_MODE="$(config_get DRUPILOT_PHPCS_RULESET auto 2>/dev/null || echo auto)"
if [[ "$(lc "$RS_MODE")" != "drupilot" && -r "$RS_JSON" ]]; then
  RS_SRC="$(jq -r '.source // empty' "$RS_JSON" 2>/dev/null || true)"
  RS_FILE="$(jq -r '.ruleset // empty' "$RS_JSON" 2>/dev/null || true)"
  RS_STD="$(jq -r '.standard // empty' "$RS_JSON" 2>/dev/null || true)"
  RS_CK="$(jq -r '.cksum // empty' "$RS_JSON" 2>/dev/null || true)"
  if [[ ( "$RS_SRC" == "project" || "$RS_SRC" == "explicit" ) && -n "$RS_STD" && -f "$RS_FILE" ]] \
     && [[ "$(cksum < "$RS_FILE" 2>/dev/null | awk '{print $1}')" == "$RS_CK" ]]; then
    STD="$RS_STD"
    [[ "$(jq -r '.pass_extensions' "$RS_JSON" 2>/dev/null || true)" == "false" ]] && EXTS=""
    RS_TV="$(jq -r '.test_version // empty' "$RS_JSON" 2>/dev/null || true)"
    RS_TVS="$(jq -r '.test_version_source // empty' "$RS_JSON" 2>/dev/null || true)"
    [[ -n "$RS_TV" && "$RS_TVS" != "ruleset-config" ]] && TV_ARGS=(--runtime-set testVersion "$RS_TV")
  fi
fi
declare -a EXT_ARGS=()
[[ -n "$EXTS" ]] && EXT_ARGS=("--extensions=$EXTS")

# --- Behavior toggle + phase awareness ---------------------------------------
# DRUPILOT_POST_EDIT_LINT: autofix (default) | report (run phpcs, never modify
# files) | off (do nothing). The developer stays in control of in-place edits.
MODE="$(config_get DRUPILOT_POST_EDIT_LINT autofix 2>/dev/null || echo autofix)"
case "$(lc "$MODE")" in off) exit 0;; report|autofix) : ;; *) MODE="autofix";; esac

# Phase-aware strictness: during Phase 1 (minimal port) surface only ERRORS
# (compatibility), not DrupalPractice WARNINGS — premature style nagging belongs
# to Phase 2. In the refactor phase, surface both.
# (Braces so a missing phase file's redirection error is silenced too.)
# The refactor stage comes from state.json (phase_reached reads its .stages,
# falling back to the legacy phase marker, where "refactor" and "refactored"
# both count). Fail-safe: any error leaves Phase 1 strictness.
PHASE="port"
{ phase_reached "$EXT_DIR" refactored; } 2>/dev/null && PHASE="refactor"

# Run from the Drupal root so relative paths resolve identically on host/in DDEV.
REL="$FILE"
case "$FILE" in
  "$DRUPAL_ROOT"/*) REL="${FILE#"$DRUPAL_ROOT"/}" ;;
esac

# --- phpcbf (autofix, only in autofix mode), then phpcs (report) --------------
# In autofix mode, report whether phpcbf actually changed the file on disk, so
# the in-place edit is never silent.
# Phase 1: the hook runs after EVERY edit, so a `use` added one edit before the
# code that needs it looks unused in between; the unused-use sniffs are left
# to the validate loop (run-phpcs.sh --fix --fix-scope changed), which runs
# once a batch of edits is complete. (PHPCS ignores an excluded sniff the
# standard does not register.)
declare -a CBF_ARGS=()
[[ "$PHASE" != "refactor" ]] && CBF_ARGS=("--exclude=Drupal.Classes.UnusedUseStatement,SlevomatCodingStandard.Namespaces.UnusedUses")  # portability-ok: phpcbf options, not grep
CHANGED_NOTE=""
if [[ "$MODE" == "autofix" ]]; then
  BEFORE="$(cksum "$FILE" 2>/dev/null || true)"
  ( cd "$DRUPAL_ROOT" 2>/dev/null && $RUNNER "$PHPCBF_BIN" --standard="$STD" ${TV_ARGS[@]+"${TV_ARGS[@]}"} ${CBF_ARGS[@]+"${CBF_ARGS[@]}"} "$REL" >/dev/null 2>&1 ) || true
  AFTER="$(cksum "$FILE" 2>/dev/null || true)"
  [[ -n "$BEFORE" && "$BEFORE" != "$AFTER" ]] && \
    CHANGED_NOTE="phpcbf auto-corrected coding-standard issues in ${REL} (the file on disk was modified). "
fi

PHPCS_OUT="$(cd "$DRUPAL_ROOT" 2>/dev/null && $RUNNER "$PHPCS_BIN" --standard="$STD" ${EXT_ARGS[@]+"${EXT_ARGS[@]}"} ${TV_ARGS[@]+"${TV_ARGS[@]}"} --report=full --no-colors "$REL" 2>/dev/null || true)"

# Nothing from phpcs -> only surface an autofix note, if any.
if [[ -z "$PHPCS_OUT" ]] || ! printf '%s' "$PHPCS_OUT" | grep_q -iE 'ERROR|WARNING'; then
  [[ -n "$CHANGED_NOTE" ]] && emit_context "$CHANGED_NOTE"
  exit 0
fi

# Phase 1: if only WARNINGS remain (no ERROR), do not nag — just note any autofix.
# Match ERROR case-SENSITIVELY: phpcs prints the severity column in uppercase, so
# this avoids a WARNING whose message text says "error" tripping the error gate.
if [[ "$PHASE" != "refactor" ]] && ! printf '%s' "$PHPCS_OUT" | grep_q -E '\bERROR\b'; then
  [[ -n "$CHANGED_NOTE" ]] && emit_context "$CHANGED_NOTE"
  exit 0
fi

NOTE="The remaining violations below need a manual fix"
[[ "$PHASE" != "refactor" ]] && NOTE="The remaining ERRORS below need a manual fix (Phase 1 surfaces compatibility errors only; DrupalPractice style warnings are deferred to /drupilot-refactor)"
MSG="drupilot incremental lint on ${REL}. ${CHANGED_NOTE}${NOTE}:
${PHPCS_OUT}"

emit_context "$MSG"
