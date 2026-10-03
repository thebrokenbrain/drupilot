#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/resolve-workspace.sh
# Decide WHERE the Drupal 11 test-bed lives and WHERE the subject module/theme is
# placed inside it — WITHOUT mutating anything (a pure resolver, like
# core-strategy.sh). It is the single source of truth that ddev-up.sh and
# place-subject.sh consult so a LOOSE checkout is never scaffolded on top of.
#
# The problem it solves: when drupilot is pointed at a module/theme that is NOT
# already inside a Drupal site, the old fallback scaffolded Drupal (composer.json,
# web/, vendor/, .ddev/) into the module's own directory, intermixing the two and
# polluting the module's composer.json. Instead, this resolver targets a sibling
# Drupal root and a clean web/{modules,themes,profiles}/custom/<name> destination.
#
# Resolution of the Drupal ROOT (first match wins):
#   1. An existing Drupal root found by walking up from the subject (the module is
#      already inside a site) -> use it, placement 'in-place', loose=false.
#   2. DRUPILOT_WORKSPACE_DIR (env / .drupilot.json) -> that explicit path.
#   3. A sibling directory '<parent-of-subject>/<machine_name>-d11'.
# Placement mode comes from DRUPILOT_PLACEMENT (move|symlink|copy, default move).
#
# Usage:
#   resolve-workspace.sh [--subject DIR] [--workspace DIR] [--json] [-h|--help]
#     --subject DIR  Module/theme directory (default: current directory).
#     --workspace DIR  The test-bed root for a loose subject; the same as
#                    DRUPILOT_WORKSPACE_DIR (the flag wins over the variable).
#     --json         Print only the JSON payload (suppress the human table).
#
# Output: a human table on STDERR; the recommendation JSON on STDOUT:
#   { subject_src, machine_name, type, loose, drupal_root, drupal_root_exists,
#     subject_dest_rel, subject_dest_abs, placement, already_placed,
#     residue, residual_ddev }
# residue lists untracked local-environment leftovers at the top of the subject
# (.ddev/, vendor/, node_modules/, .phpstan-cache/, .drupilot/) and symlinks
# whose target escapes it. residual_ddev is true when the Drupal "root" is the
# module itself only because of an UNTRACKED .ddev/config.yaml with no core
# (a leftover module-at-root sandbox). Both are report-only: they never change
# the loose/root decision (ddev-drupal-contrib's module-at-root layout is
# legitimate).
# Read-only and ungated. Exit codes: 0 ok · 1 usage/error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
JSON_ONLY=0
usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --json) JSON_ONLY=1; shift;;
    --workspace) [[ -n "${2:-}" ]] || die "--workspace needs a directory" 1; export DRUPILOT_WORKSPACE_DIR="$2"; shift 2;;
    --workspace=*) export DRUPILOT_WORKSPACE_DIR="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

have_cmd jq || die "jq is required for resolve-workspace.sh." 1

# A directory we may treat as an existing Drupal/drupilot test-bed root (vs. an
# unrelated dir that merely shares the '<name>-d11' name).
_is_drupal_rootish() {
  [[ -f "$1/.ddev/config.yaml" || -f "$1/web/core/lib/Drupal.php" || -f "$1/core/lib/Drupal.php" ]]
}

SUBJECT="${SUBJECT:-$PWD}"
SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
[[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1

MACHINE="$(subject_machine_name "$SUBJECT_ABS" 2>/dev/null || basename "$SUBJECT_ABS")"
TYPE="$(subject_type "$SUBJECT_ABS" 2>/dev/null || echo module)"
case "$TYPE" in
  theme)   DEST_SUB="themes";;
  profile) DEST_SUB="profiles";;
  *)       DEST_SUB="modules";;
esac

# Placement mode (validated). A misconfigured value is reported on stderr (the
# config_enum error is NOT suppressed — only stdout matters for the payload), but
# we still default to 'move' so the resolver always yields a plan.
PLACEMENT="$(config_enum DRUPILOT_PLACEMENT move move symlink copy || echo move)"

# --- 1) Is the subject already inside a Drupal site? -----------------------
EXISTING_ROOT="$(find_drupal_root "$SUBJECT_ABS" 2>/dev/null || true)"

LOOSE="true"
ROOT=""
DEST_REL=""
PLACEMENT_OUT="$PLACEMENT"
ALREADY="false"

if [[ -n "$EXISTING_ROOT" ]]; then
  # The module lives inside a resolvable Drupal root already: keep today's layout
  # untouched (back-compat). Nothing to move.
  LOOSE="false"
  ROOT="$EXISTING_ROOT"
  PLACEMENT_OUT="in-place"
  ALREADY="true"
  case "$SUBJECT_ABS" in
    "$ROOT"/*) DEST_REL="${SUBJECT_ABS#"$ROOT"/}";;
    "$ROOT")   DEST_REL=".";;
    *)         DEST_REL="$SUBJECT_ABS";;
  esac
else
  # Loose checkout: target an explicit workspace, else a clearly-named sibling.
  WORKSPACE_OVERRIDE="$(config_get DRUPILOT_WORKSPACE_DIR "")"
  # Honor a workspace pinned at the SUBJECT side by a prior copy/symlink run:
  # config_get cannot reach it (a loose subject has no Drupal root above it, so
  # drupilot_prefs_file resolves nothing), so read the subject-side file directly.
  if [[ -z "$WORKSPACE_OVERRIDE" && -r "$SUBJECT_ABS/.drupilot.json" ]]; then
    WORKSPACE_OVERRIDE="$(jq -r '.DRUPILOT_WORKSPACE_DIR // empty' "$SUBJECT_ABS/.drupilot.json" 2>/dev/null || true)"
  fi
  if [[ -n "$WORKSPACE_OVERRIDE" ]]; then
    # Absolute-ize relative overrides against the subject's parent.
    case "$WORKSPACE_OVERRIDE" in
      /*) ROOT="$WORKSPACE_OVERRIDE";;
      *)  ROOT="$(dirname "$SUBJECT_ABS")/$WORKSPACE_OVERRIDE";;
    esac
  else
    # Default sibling. Reuse an existing drupilot test-bed at the canonical name
    # (idempotent re-run), but NEVER silently adopt an UNRELATED pre-existing dir
    # of the same name — bump to the next free name instead.
    _parent="$(dirname "$SUBJECT_ABS")"
    ROOT="$_parent/${MACHINE}-d11"
    _n=2
    while [[ -e "$ROOT" ]] && ! _is_drupal_rootish "$ROOT"; do
      ROOT="$_parent/${MACHINE}-d11-$_n"; _n=$((_n+1))
    done
  fi
  DEST_REL="web/$DEST_SUB/custom/$MACHINE"
fi

# Normalize ROOT (without requiring it to exist yet). drupal_root_exists means
# "a Drupal site is already scaffolded there" (the precondition place-subject.sh
# needs), NOT merely that the directory exists.
[[ -d "$ROOT" ]] && ROOT="$(cd "$ROOT" && pwd)"
ROOT_EXISTS="false"
_is_drupal_rootish "$ROOT" && ROOT_EXISTS="true"
DEST_ABS="$ROOT/$DEST_REL"

# Already placed? (loose case only — the destination holds this module already.)
if [[ "$LOOSE" == "true" && -d "$DEST_ABS" ]] && is_drupal_extension_dir "$DEST_ABS" 2>/dev/null; then
  ALREADY="true"
fi

# --- Residue report (read-only) --------------------------------------------
RESIDUE=()
_tracked() { git -C "$SUBJECT_ABS" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && [[ -n "$(git -C "$SUBJECT_ABS" ls-files -- "$1" 2>/dev/null | head -n1)" ]]; }
for _n in .ddev vendor node_modules .phpstan-cache .drupilot; do
  if [[ -e "$SUBJECT_ABS/$_n" ]] && ! _tracked "$_n"; then RESIDUE+=("$_n/"); fi
done
while IFS= read -r _l; do
  [[ -n "$_l" ]] || continue
  _rel="${_l#"$SUBJECT_ABS"/}"
  symlink_escapes "$SUBJECT_ABS" "$_rel" && RESIDUE+=("$_rel")
done < <(find "$SUBJECT_ABS" \( -name .git -o -name node_modules -o -name vendor -o -name .ddev \) -prune -o -type l -print 2>/dev/null || true)
RESIDUAL_DDEV="false"
if [[ "$ROOT" == "$SUBJECT_ABS" && -f "$SUBJECT_ABS/.ddev/config.yaml" ]] \
   && is_drupal_extension_dir "$SUBJECT_ABS" 2>/dev/null \
   && [[ ! -f "$SUBJECT_ABS/web/core/lib/Drupal.php" && ! -f "$SUBJECT_ABS/core/lib/Drupal.php" ]] \
   && ! _tracked ".ddev/config.yaml"; then
  RESIDUAL_DDEV="true"
fi
RESIDUE_JSON="$(arr_to_json ${RESIDUE[@]+"${RESIDUE[@]}"})"

JSON="$(jq -c -n \
  --arg subject_src "$SUBJECT_ABS" \
  --arg machine_name "$MACHINE" \
  --arg type "$TYPE" \
  --argjson loose "$LOOSE" \
  --arg drupal_root "$ROOT" \
  --argjson drupal_root_exists "$ROOT_EXISTS" \
  --arg subject_dest_rel "$DEST_REL" \
  --arg subject_dest_abs "$DEST_ABS" \
  --arg placement "$PLACEMENT_OUT" \
  --argjson already_placed "$ALREADY" \
  --argjson residue "$RESIDUE_JSON" \
  --argjson residual_ddev "$RESIDUAL_DDEV" \
  '{subject_src:$subject_src, machine_name:$machine_name, type:$type, loose:$loose,
    drupal_root:$drupal_root, drupal_root_exists:$drupal_root_exists,
    subject_dest_rel:$subject_dest_rel, subject_dest_abs:$subject_dest_abs,
    placement:$placement, already_placed:$already_placed,
    residue:$residue, residual_ddev:$residual_ddev}')"

# Residue warnings are useful even in --json mode (they go to STDERR).
if [[ "${#RESIDUE[@]}" -gt 0 ]]; then
  log_warn "Local-environment residue in the subject (untracked, not part of the module): ${RESIDUE[*]}"
fi
if [[ "$RESIDUAL_DDEV" == "true" ]]; then
  log_warn "The subject itself looks like a leftover module-at-root DDEV sandbox (untracked .ddev/config.yaml, no Drupal core)."
  log_plain "  It is treated as the Drupal root. If that is stale, remove its .ddev/ or set DRUPILOT_WORKSPACE_DIR."
fi

if [[ "$JSON_ONLY" -eq 0 ]]; then
  log_step "Workspace resolution — $MACHINE ($TYPE)"
  if [[ "$LOOSE" == "true" ]]; then
    log_plain "  Subject is LOOSE (not inside a Drupal site)."
    log_plain "  Drupal test-bed root : $ROOT $( [[ "$ROOT_EXISTS" == "true" ]] && echo '(exists)' || echo '(to be created)')"
    log_plain "  Place subject at     : $DEST_REL"
    log_plain "  Placement mode       : $PLACEMENT_OUT"
    [[ "$ALREADY" == "true" ]] && log_plain "  Status               : already placed (idempotent)"
    log_plain ""
    log_plain "  Your checkout stays intact; Drupal + .ddev live in the sibling root above,"
    log_plain "  so the module is never scaffolded on top of. Run place-subject.sh to apply."
  else
    log_plain "  Subject already lives inside a Drupal root — keeping the existing layout."
    log_plain "  Drupal root          : $ROOT"
    log_plain "  Subject (relative)   : $DEST_REL"
  fi
  hr
fi

printf '%s\n' "$JSON"
exit 0
