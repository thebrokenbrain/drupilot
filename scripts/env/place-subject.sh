#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/place-subject.sh
# Place a LOOSE module/theme into its Drupal 11 test-bed at
# web/{modules,themes,profiles}/custom/<machine_name>, so the subject is never
# scaffolded on top of (see resolve-workspace.sh for the WHERE; this is the HOW).
# Idempotent (detect-and-skip when already placed) and non-destructive by design:
# it refuses to overwrite a non-empty destination.
#
# Placement modes (DRUPILOT_PLACEMENT, or --placement):
#   move    (default) relocate the checkout into the test-bed. Non-lossy: it stays
#           a git repo, just at a new path. The original directory ends up empty.
#   symlink keep the checkout where it is and symlink it into the test-bed (you
#           keep editing your original path). Slightly more fragile with
#           ddev-drupal-contrib; fine for a host-side port.
#   copy    duplicate the checkout into the test-bed; the original is untouched.
#
# Runs AFTER the Drupal root exists (composer create needs an empty root, so the
# subject is placed once Drupal is scaffolded). Persists the resolved root as
# DRUPILOT_WORKSPACE_DIR (.drupilot.json) so every later find_drupal_root agrees,
# and ensures the root's .gitignore covers drupilot's artifacts.
#
# Usage:
#   place-subject.sh [--subject DIR] [--placement move|symlink|copy]
#                    [--dry-run] [--yes] [-h|--help]
#
# Output: the destination path on STDOUT; logging on STDERR.
# Exit codes: 0 ok (placed or already placed) · 1 usage/error/refused · 2 the
#             Drupal root does not exist yet (run /drupilot-setup first).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
PLACEMENT_OVERRIDE=""
DRY=0
ASSUME=0
usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --placement) PLACEMENT_OVERRIDE="${2:-}"; shift 2;;
    --placement=*) PLACEMENT_OVERRIDE="${1#*=}"; shift;;
    --dry-run) DRY=1; shift;;
    --yes|-y) ASSUME=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

have_cmd jq || die "jq is required for place-subject.sh." 1

SUBJECT="${SUBJECT:-$PWD}"
SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
if [[ -z "$SUBJECT_ABS" || ! -d "$SUBJECT_ABS" ]]; then
  # The subject path is gone. The usual reason is a successful 'move' on a prior
  # run — so before failing, check whether it is already placed in the default
  # sibling test-bed. This restores the documented detect-and-skip idempotency for
  # a 'move' re-run keyed on the (now-empty) original path.
  _base="$(basename "$SUBJECT")"
  _parent="$(cd "$(dirname "$SUBJECT")" 2>/dev/null && pwd || true)"
  if [[ -n "$_parent" && -n "$_base" ]]; then
    for _sub in modules themes profiles; do
      _cand="$_parent/${_base}-d11/web/$_sub/custom/$_base"
      if [[ -d "$_cand" ]] && is_drupal_extension_dir "$_cand"; then
        log_ok "Subject already placed at: $_cand (idempotent — the original path was relocated)."
        printf '%s\n' "$_cand"
        exit 0
      fi
    done
  fi
  die "Subject directory not found: '$SUBJECT'." 1
fi

[[ -n "$PLACEMENT_OVERRIDE" ]] && export DRUPILOT_PLACEMENT="$PLACEMENT_OVERRIDE"

# --- Resolve the plan (single source of truth) -----------------------------
RESOLVER="$(plugin_root)/scripts/env/resolve-workspace.sh"
[[ -r "$RESOLVER" ]] || die "resolve-workspace.sh not found: $RESOLVER" 1
PLAN="$(bash "$RESOLVER" --subject "$SUBJECT_ABS" --json 2>/dev/null || true)"
[[ -n "$PLAN" ]] || die "Could not resolve the workspace plan for '$SUBJECT_ABS'." 1

pget() { printf '%s' "$PLAN" | jq -r "$1 // empty" 2>/dev/null; }
LOOSE="$(pget '.loose')"
ROOT="$(pget '.drupal_root')"
ROOT_EXISTS="$(pget '.drupal_root_exists')"
DEST_REL="$(pget '.subject_dest_rel')"
DEST_ABS="$(pget '.subject_dest_abs')"
PLACEMENT="$(pget '.placement')"
ALREADY="$(pget '.already_placed')"
MACHINE="$(pget '.machine_name')"

# --- Idempotent / no-op cases ----------------------------------------------
if [[ "$LOOSE" == "false" ]]; then
  log_ok "Subject already lives inside a Drupal root ($ROOT/$DEST_REL) — nothing to place."
  printf '%s\n' "$SUBJECT_ABS"
  exit 0
fi
if [[ "$ALREADY" == "true" ]]; then
  log_ok "Subject already placed at: $DEST_ABS (idempotent — no change)."
  printf '%s\n' "$DEST_ABS"
  exit 0
fi

# --- Preconditions ----------------------------------------------------------
if [[ "$ROOT_EXISTS" != "true" ]]; then
  log_err "The Drupal test-bed root does not exist yet: $ROOT"
  log_plain "Run /drupilot-setup first — it creates the sibling Drupal 11 site (ddev-up),"
  log_plain "then placement moves the module into '$DEST_REL'."
  exit 2
fi

# Refuse to clobber a non-empty, unrelated destination.
if [[ -L "$DEST_ABS" ]]; then
  if [[ "$(readlink "$DEST_ABS")" == "$SUBJECT_ABS" ]]; then
    log_ok "Destination is already a symlink to the subject: $DEST_ABS (idempotent)."
    printf '%s\n' "$DEST_ABS"
    exit 0
  fi
  die "Destination exists as a symlink to something else: $DEST_ABS. Remove it or set DRUPILOT_WORKSPACE_DIR." 1
fi
if [[ -e "$DEST_ABS" ]]; then
  die "Destination already exists and is not this module: $DEST_ABS. Remove it or set DRUPILOT_WORKSPACE_DIR." 1
fi

# --- Dry-run ----------------------------------------------------------------
if [[ "$DRY" == "1" ]]; then
  log_step "[dry-run] Would place '$MACHINE' ($PLACEMENT)"
  log_plain "  from : $SUBJECT_ABS"
  log_plain "  to   : $DEST_ABS"
  exit 0
fi

# --- Confirm a relocating move when interactive ----------------------------
# A 'move' relocates the developer's checkout, so it is confirmed when running
# directly in an interactive terminal. In the guided flow the workspace tab
# already captured consent and the command passes --yes; in an autonomous /
# non-TTY run confirm() proceeds on its default-yes branch (the move is
# non-lossy — the checkout stays a git repo, just at the new path, and the
# old -> new relocation is logged below).
if [[ "$PLACEMENT" == "move" && "$ASSUME" == "0" ]]; then
  if ! confirm "Move '$SUBJECT_ABS' into '$DEST_ABS' (it stays a git repo at the new path)?" 1; then
    die "Placement cancelled. Re-run with --placement symlink|copy, or --yes to proceed." 1
  fi
fi

mkdir -p "$(dirname "$DEST_ABS")" 2>/dev/null \
  || die "Could not create the destination parent: $(dirname "$DEST_ABS")" 1

log_step "Placing '$MACHINE' into the Drupal test-bed ($PLACEMENT)"
case "$PLACEMENT" in
  move)
    mv "$SUBJECT_ABS" "$DEST_ABS" || die "Move failed: $SUBJECT_ABS -> $DEST_ABS" 1
    log_ok "Moved the checkout: $SUBJECT_ABS -> $DEST_ABS (the original path is now empty)."
    ;;
  copy)
    cp -a "$SUBJECT_ABS" "$DEST_ABS" || die "Copy failed: $SUBJECT_ABS -> $DEST_ABS" 1
    log_ok "Copied the checkout to $DEST_ABS (the original is untouched)."
    ;;
  symlink)
    ln -s "$SUBJECT_ABS" "$DEST_ABS" || die "Symlink failed: $DEST_ABS -> $SUBJECT_ABS" 1
    log_ok "Symlinked $DEST_ABS -> $SUBJECT_ABS (edit your original path as usual)."
    ;;
  *)
    die "Unknown placement mode: '$PLACEMENT' (expected move|symlink|copy)." 1
    ;;
esac

# --- Persist the resolved root + placement, and protect the tree -----------
# For copy/symlink the loose checkout survives, so ALSO record the chosen
# workspace at the SUBJECT side: a loose re-run starts from there and cannot read
# the root-side .drupilot.json (no Drupal root above the subject yet) —
# resolve-workspace.sh reads this back so the re-run reuses the same root instead
# of deriving a fresh sibling. (make-patch.sh excludes .drupilot.json from any
# generated patch, so this marker never leaks into a contribution.)
if [[ "$PLACEMENT" == "copy" || "$PLACEMENT" == "symlink" ]]; then
  ( export DRUPILOT_PROJECT_DIR="$SUBJECT_ABS"; prefs_set DRUPILOT_WORKSPACE_DIR "$ROOT" ) 2>/dev/null || true
fi

# Every later script resolves find_drupal_root from $DEST_ABS up to $ROOT, but
# pinning DRUPILOT_WORKSPACE_DIR keeps the choice stable and self-documenting.
export DRUPILOT_PROJECT_DIR="$ROOT"
prefs_set DRUPILOT_WORKSPACE_DIR "$ROOT" 2>/dev/null || true
prefs_set DRUPILOT_PLACEMENT "$PLACEMENT" 2>/dev/null || true

GITIGNORE="$(plugin_root)/scripts/env/ensure-gitignore.sh"
[[ -r "$GITIGNORE" ]] && bash "$GITIGNORE" --root "$ROOT" >&2 || true

printf '%s\n' "$DEST_ABS"
exit 0
