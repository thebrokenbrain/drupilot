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
#           a git repo, just at a new path. The original directory no longer
#           exists afterwards (it was moved, not emptied).
#   symlink keep the checkout where it is and symlink it into the test-bed (you
#           keep editing your original path). A target outside the Drupal root
#           is NOT visible inside the DDEV container (only the root is mounted),
#           so 'ddev exec' tooling cannot see it — warned at placement; fine
#           for a host-side port.
#   copy    duplicate the checkout into the test-bed; the original is untouched.
#           Local environment residue is NOT copied: .ddev/, vendor/,
#           .drupilot/, .drupilot.json, .phpstan-cache/, .drupilot-coverage/
#           (top level) and node_modules/ (anywhere). Symlinks whose target
#           escapes the checkout are dropped from the copy (the origin keeps
#           them). Anything git tracks is part of the module and is always
#           copied (e.g. a bundled vendor/ library, a committed symlink).
#           --no-exclude restores the old verbatim copy.
#
# Origin hygiene: before placing, the origin's git status is recorded with
# origin-hygiene.sh --snapshot (hidden state, keyed by the Drupal root) so a
# later `origin-hygiene.sh --check` can prove drupilot left nothing behind. When
# the subject-side .drupilot.json is written (copy/symlink), it is hidden through
# the subject repo's LOCAL .git/info/exclude, never its tracked .gitignore.
#
# Runs AFTER the Drupal root exists (composer create-project needs an empty root, so the
# subject is placed once Drupal is scaffolded). Persists the resolved root as
# DRUPILOT_WORKSPACE_DIR (.drupilot.json) so every later find_drupal_root agrees,
# and ensures the root's .gitignore covers drupilot's artifacts.
#
# Usage:
#   place-subject.sh [--subject DIR] [--placement move|symlink|copy]
#                    [--no-exclude] [--dry-run] [--yes] [-h|--help]
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
NO_EXCLUDE=0
# Copy-mode exclusions: top-level local-environment residue, plus node_modules
# at any depth. (vendor/ is top-level only: a module may ship js/vendor/.)
COPY_EXCLUDE_TOP=(.ddev vendor .drupilot .drupilot.json .phpstan-cache .drupilot-coverage)
usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --placement) PLACEMENT_OVERRIDE="${2:-}"; shift 2;;
    --placement=*) PLACEMENT_OVERRIDE="${1#*=}"; shift;;
    --dry-run) DRY=1; shift;;
    --no-exclude) NO_EXCLUDE=1; shift;;
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
  # run — so before failing, check whether it is already placed in the pinned or default
  # sibling test-bed. This restores the documented detect-and-skip idempotency for
  # a 'move' re-run keyed on the (now-gone) original path; DRUPILOT_WORKSPACE_DIR
  # (env or prefs) is checked before the default sibling.
  _base="$(basename "$SUBJECT")"
  _parent="$(cd "$(dirname "$SUBJECT")" 2>/dev/null && pwd || true)"
  _ws="$(config_get DRUPILOT_WORKSPACE_DIR "")"
  if [[ -n "$_parent" && -n "$_base" ]]; then
    for _cand in "${_ws:+$_ws/web/modules/custom/$_base}" "${_ws:+$_ws/web/themes/custom/$_base}" \
                 "${_ws:+$_ws/web/profiles/custom/$_base}" \
                 "$_parent/${_base}-d11/web/modules/custom/$_base" \
                 "$_parent/${_base}-d11/web/themes/custom/$_base" \
                 "$_parent/${_base}-d11/web/profiles/custom/$_base"; do
      [[ -n "$_cand" ]] || continue
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

# --- Residue in the origin --------------------------------------------------
# Untracked local-environment leftovers in the checkout (e.g. a .ddev/ from an
# earlier module-at-root sandbox). Reported, never deleted; a copy skips them.
# residue_list -> one top-level name per line (untracked or not a git checkout).
residue_list() {
  local n
  for n in "${COPY_EXCLUDE_TOP[@]}" node_modules; do
    [[ -e "$SUBJECT_ABS/$n" || -L "$SUBJECT_ABS/$n" ]] || continue
    if git -C "$SUBJECT_ABS" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
       && [[ -n "$(git -C "$SUBJECT_ABS" ls-files -- "$n" 2>/dev/null | head -n1)" ]]; then
      continue   # tracked: part of the module, not residue
    fi
    printf '%s\n' "$n"
  done
  return 0
}
# escaping_links <tree> -> relative paths of symlinks under <tree> whose target
# lies outside it (skipping the excluded residue dirs).
escaping_links() {
  local tree="$1" l rel
  find "$tree" \( -name .git -o -name node_modules \) -prune -o -type l -print 2>/dev/null \
    | while IFS= read -r l; do
        rel="${l#"$tree"/}"
        symlink_escapes "$tree" "$rel" && printf '%s\n' "$rel"
      done
  return 0
}
RESIDUE="$(residue_list)"
if [[ -n "$RESIDUE" ]]; then
  log_warn "The checkout contains local-environment residue (untracked): $(printf '%s' "$RESIDUE" | tr '\n' ' ')"
  case "$PLACEMENT" in
    copy) [[ "$NO_EXCLUDE" == "1" ]] \
            && log_plain "  --no-exclude: it WILL be copied into the test-bed." \
            || log_plain "  It is not copied into the test-bed (the origin keeps it untouched).";;
    *)    log_plain "  It travels with the checkout ($PLACEMENT); remove it from the origin if it is stale.";;
  esac
fi

# --- Dry-run ----------------------------------------------------------------
if [[ "$DRY" == "1" ]]; then
  log_step "[dry-run] Would place '$MACHINE' ($PLACEMENT)"
  log_plain "  from : $SUBJECT_ABS"
  log_plain "  to   : $DEST_ABS"
  if [[ "$PLACEMENT" == "copy" && "$NO_EXCLUDE" != "1" ]]; then
    log_plain "  excluded from the copy (untracked only) : ${COPY_EXCLUDE_TOP[*]} (top level), node_modules/ (anywhere)"
    _esc="$(escaping_links "$SUBJECT_ABS")"
    [[ -n "$_esc" ]] && log_plain "  symlinks escaping the tree, dropped from the copy: $(printf '%s' "$_esc" | tr '\n' ' ')"
  fi
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

# Record the origin's state BEFORE drupilot places it (report-only baseline for
# origin-hygiene.sh --check). After a move the origin lives at DEST. --force:
# a placement is about to happen, so any earlier baseline for this root is stale.
HYGIENE="$(plugin_root)/scripts/env/origin-hygiene.sh"
if [[ -r "$HYGIENE" ]]; then
  _rec="$SUBJECT_ABS"; [[ "$PLACEMENT" == "move" ]] && _rec="$DEST_ABS"
  bash "$HYGIENE" --snapshot --force --subject "$SUBJECT_ABS" --root "$ROOT" \
    --record-origin "$_rec" --placement "$PLACEMENT" >/dev/null 2>&1 \
    || log_warn "Could not record the origin hygiene baseline (non-fatal)."
fi

# copy_filtered <src> <dest> — copy without local-environment residue, then drop
# symlinks escaping the copied tree. Top-level exclusions are applied by naming
# only the kept top-level entries (tar --exclude anchoring differs between GNU
# tar, bsdtar and busybox: bsdtar's './vendor' also drops js/vendor/);
# node_modules is excluded at any depth. The prune afterwards is the safety net.
# Same rule as residue_list: an entry git TRACKS is part of the module (e.g. a
# bundled vendor/ library, a committed symlink) and is always copied; only
# untracked residue is excluded.
src_tracks() {
  local src="$1" path="$2"
  git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  [[ -n "$(git -C "$src" ls-files -- "$path" 2>/dev/null | head -n1)" ]]
}
copy_filtered() {
  local src="$1" dest="$2" n l e skip nm_tracked=0
  local -a keep=() excl=() tarx=()
  if git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && git -C "$src" ls-files 2>/dev/null | grep -qE '(^|/)node_modules/'; then
    nm_tracked=1
  fi
  for n in "${COPY_EXCLUDE_TOP[@]}"; do
    src_tracks "$src" "$n" || excl+=("$n")
  done
  if [[ "$nm_tracked" == "1" ]]; then
    log_warn "The checkout tracks files under node_modules/; copying node_modules as-is."
  else
    excl+=(node_modules); tarx=(--exclude=node_modules)
  fi
  for e in "$src"/* "$src"/.[!.]* "$src"/..?*; do
    [[ -e "$e" || -L "$e" ]] || continue
    n="${e##*/}"; skip=0
    for l in ${excl[@]+"${excl[@]}"}; do [[ "$n" == "$l" ]] && skip=1; done
    [[ "$skip" == "1" ]] || keep+=("./$n")
  done
  mkdir -p "$dest" || return 1
  if [[ "${#keep[@]}" -gt 0 ]]; then
    ( cd "$src" && tar -cf - ${tarx[@]+"${tarx[@]}"} "${keep[@]}" ) | ( cd "$dest" && tar -xpf - ) || return 1
  fi
  for n in ${excl[@]+"${excl[@]}"}; do
    [[ "$n" == "node_modules" ]] && continue
    if [[ -e "$dest/$n" || -L "$dest/$n" ]]; then rm -rf "${dest:?}/$n"; fi
  done
  if [[ "$nm_tracked" != "1" ]]; then
    find "$dest" -name node_modules -prune -type d -exec rm -rf {} + 2>/dev/null || true
  fi
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    if src_tracks "$src" "$l"; then
      log_warn "Kept a tracked symlink that escapes the checkout (it may not resolve in the test-bed): $l"
      continue
    fi
    rm -f "${dest:?}/$l"
    log_warn "Dropped from the copy (untracked symlink escapes the checkout): $l"
  done < <(escaping_links "$dest")
  return 0
}

log_step "Placing '$MACHINE' into the Drupal test-bed ($PLACEMENT)"
case "$PLACEMENT" in
  move)
    mv "$SUBJECT_ABS" "$DEST_ABS" || die "Move failed: $SUBJECT_ABS -> $DEST_ABS" 1
    log_ok "Moved the checkout: $SUBJECT_ABS -> $DEST_ABS (the original directory no longer exists; it was moved)."
    ;;
  copy)
    if [[ "$NO_EXCLUDE" == "1" ]]; then
      cp -a "$SUBJECT_ABS" "$DEST_ABS" || die "Copy failed: $SUBJECT_ABS -> $DEST_ABS" 1
    else
      copy_filtered "$SUBJECT_ABS" "$DEST_ABS" || { rm -rf "${DEST_ABS:?}"; die "Copy failed: $SUBJECT_ABS -> $DEST_ABS" 1; }
    fi
    log_ok "Copied the checkout to $DEST_ABS (the original is untouched)."
    ;;
  symlink)
    ln -s "$SUBJECT_ABS" "$DEST_ABS" || die "Symlink failed: $DEST_ABS -> $SUBJECT_ABS" 1
    log_ok "Symlinked $DEST_ABS -> $SUBJECT_ABS (edit your original path as usual)."
    case "$SUBJECT_ABS" in
      "$ROOT"/*) : ;;
      *) log_warn "The symlink target is outside the Drupal root, which is the only directory DDEV mounts:"
         log_plain "  'ddev exec' tooling (Rector, PHPStan, PHPUnit) cannot see the subject through it."
         log_plain "  Prefer --placement move|copy for a DDEV run, or add a DDEV mount for $SUBJECT_ABS.";;
    esac
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
  # The marker must not show up as an untracked file in the origin repo: hide it
  # through the repo's LOCAL exclude file (the tracked .gitignore stays as is).
  git_local_exclude "$SUBJECT_ABS" '.drupilot.json' '.drupilot/'
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
