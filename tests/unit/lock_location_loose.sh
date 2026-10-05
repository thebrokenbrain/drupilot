#!/usr/bin/env bash
# DRUPILOT_LOCK_LOCATION (T-M4-16, AR-14, OD-06, 07-R15): "state" (the
# default) keeps the root's lock in the hidden state dir; "project" keeps it at
# <root>/drupilot-lock.json, committable (not in drupilot's managed ignore
# block), but only for the developer's own root: not for a loose subject's
# test-bed (built, or not built yet: the draft plan is frozen before it
# exists), a root without core, a module repo carrying its own core, or a root
# holding placed subjects; there it warns and behaves as "state". Both
# locations round-trip; a lock kept in the state dir is read until the first
# write moves it to the root, and never again; lock_clear removes both; a
# --dry-run names where the lock would go; readers never create the state dir;
# make-patch.sh never puts the lock in a patch.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

mkroot() {
  mkdir -p "$1/web/core/lib" "$1/web/modules/custom/m"
  printf '{"name":"x/root"}\n' > "$1/composer.json"
  printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$1/web/core/lib/Drupal.php"
  printf 'name: m\ntype: module\ncore_version_requirement: ^10\n' > "$1/web/modules/custom/m/m.info.yml"
}
SITE="$T_TMP/site"; mkroot "$SITE"
STATE_LOCK="$(project_state_path "$SITE")/drupilot-lock.json"

# --- state (the default) -----------------------------------------------------
assert_eq "default: state" "$(lock_location "$SITE")" "state"
assert_eq "  the lock is in the state dir" "$(lock_path "$SITE")" "$STATE_LOCK"
assert_eq "  drupilot_lock_file names the same file" "$(drupilot_lock_file "$SITE")" "$STATE_LOCK"
DRUPILOT_PROJECT_DIR="$SITE" lock_set .drupal.core 11.4.8
assert_eq "  round-trip" "$(DRUPILOT_PROJECT_DIR="$SITE" lock_get .drupal.core)" "11.4.8"
assert_eq "  nothing at the root" "$([[ -e "$SITE/drupilot-lock.json" ]] && echo yes || echo no)" "no"
assert_eq "an invalid value is state" "$(DRUPILOT_LOCK_LOCATION=nowhere lock_location "$SITE")" "state"

# --- project, the developer's own root ---------------------------------------
export DRUPILOT_LOCK_LOCATION=project
assert_eq "project: the developer's own root" "$(lock_location "$SITE")" "project"
assert_eq "  a lock still in the state dir is read until the first write" \
  "$(lock_path "$SITE")|$(DRUPILOT_PROJECT_DIR="$SITE" lock_get .drupal.core)" "$STATE_LOCK|11.4.8"
assert_eq "  lock_path never moves it" "$([[ -e "$SITE/drupilot-lock.json" ]] && echo moved || echo kept)" "kept"
DRUPILOT_PROJECT_DIR="$SITE" lock_set .php_target 8.3
assert_eq "  the first write moves it to <root>/drupilot-lock.json, keeping its keys" \
  "$(jq -c '[.drupal.core, .php_target]' "$SITE/drupilot-lock.json" 2> /dev/null)" '["11.4.8","8.3"]'
assert_eq "  then every reader takes the root's lock" "$(lock_path "$SITE")" "$SITE/drupilot-lock.json"
DRUPILOT_PROJECT_DIR="$SITE" lock_merge_json '{"toolchain_cell":"11"}'
assert_eq "  lock_merge_json writes there too" "$(DRUPILOT_PROJECT_DIR="$SITE" lock_get .toolchain_cell)" "11"
assert_eq "  the state copy is retired (.moved-to-project), never read again" \
  "$([[ -e "$STATE_LOCK" ]] && echo kept)$(jq -r '.drupal.core' "$STATE_LOCK.moved-to-project" 2> /dev/null)" "11.4.8"
mv "$SITE/drupilot-lock.json" "$T_TMP/root-lock.bak"
assert_eq "  a root lock removed (git clean): nothing stale comes back" \
  "$(lock_path "$SITE")|$(DRUPILOT_PROJECT_DIR="$SITE" lock_get .drupal.core none)" "$SITE/drupilot-lock.json|none"
mv "$T_TMP/root-lock.bak" "$SITE/drupilot-lock.json"
assert_eq "  a subject's view finds it (find the root first)" \
  "$(cd "$SITE/web/modules/custom/m" && lock_path "$(find_drupal_root)")" "$SITE/drupilot-lock.json"
assert_eq "  not in drupilot's managed ignore block" "$(grep -c 'drupilot-lock' "$T_REPO/templates/gitignore.tmpl" || true)" "0"
assert_eq "  no warning for the developer's root" "$(lock_location_note "$SITE" 2>&1)" ""
lock_clear "$SITE" 2> /dev/null
assert_eq "  lock_clear removes the root's lock and the state copy" \
  "$([[ -e "$SITE/drupilot-lock.json" ]] && echo root)$([[ -e "$STATE_LOCK" ]] && echo state)" ""
DRUPILOT_PROJECT_DIR="$SITE" lock_set .drupal.core 11.4.8
assert_eq "  a fresh lock starts at the root" "$([[ -f "$SITE/drupilot-lock.json" && ! -e "$STATE_LOCK" ]] && echo root)" "root"
printf '{"DRUPILOT_LOCK_LOCATION": "state"}\n' > "$SITE/.drupilot.json"
assert_eq "  the env wins over .drupilot.json" "$(lock_location "$SITE")" "project"
assert_eq "  .drupilot.json state alone" "$(DRUPILOT_LOCK_LOCATION="" lock_location "$SITE")" "state"
assert_match "  state with a project lock at the root: a warning (it is not read)" \
  "$(DRUPILOT_LOCK_LOCATION="" lock_location_note "$SITE" 2>&1)" 'drupilot-lock\.json is not read'
printf '{"DRUPILOT_LOCK_LOCATION": "project"}\n' > "$SITE/.drupilot.json"
assert_eq "  .drupilot.json project alone" "$(DRUPILOT_LOCK_LOCATION="" lock_location "$SITE")" "project"
assert_eq "  the env state wins over it" "$(DRUPILOT_LOCK_LOCATION=state lock_location "$SITE")" "state"
rm -f "$SITE/.drupilot.json"

# --- dry-run destination -----------------------------------------------------------
DRY="$T_TMP/dry"; mkroot "$DRY"
DRUPILOT_LOCK_LOCATION="" DRUPILOT_PROJECT_DIR="$DRY" lock_set .drupal.core 11.4.8
assert_eq "lock_write_path names the root's lock, moving nothing" \
  "$(lock_write_path "$DRY")|$([[ -f "$(project_state_path "$DRY")/drupilot-lock.json" ]] && echo still-state)" \
  "$DRY/drupilot-lock.json|still-state"
t_run "$T_SH" "$T_REPO/scripts/env/lock-sync.sh" --dir "$DRY" --dry-run
assert_match "  lock-sync.sh --dry-run says it would move it there" "$(t_err)" "would move the lock .*$DRY/drupilot-lock\.json"
assert_eq "  and writes nothing" "$([[ -e "$DRY/drupilot-lock.json" ]] && echo written || echo none)" "none"

# --- roots that are not the developer's own --------------------------------------------
NOCORE="$T_TMP/nocore"; mkdir -p "$NOCORE"; printf '{"name":"x/y"}\n' > "$NOCORE/composer.json"
assert_eq "a root without core: state" "$(lock_location "$NOCORE")" "state"
MOD="$T_TMP/modroot"; mkroot "$MOD"; printf 'name: m\ntype: module\ncore_version_requirement: ^10\n' > "$MOD/modroot.info.yml"
assert_eq "a module repo carrying its own core (ddev-drupal-contrib): state" "$(lock_location "$MOD")" "state"
PL="$T_TMP/placed"; mkroot "$PL"; printf '{"drupilot_testbed":{"subjects":{"m":{"dest":"x","origin":"y"}}}}\n' > "$PL/.drupilot.json"
assert_eq "a root holding placed subjects: state" "$(lock_location "$PL")" "state"

# --- a loose subject: the draft plan is frozen before its test-bed exists ------------------
L="$T_TMP/work/lmod"; mkdir -p "$L"; printf 'name: lmod\ntype: module\ncore_version_requirement: ^10\n' > "$L/lmod.info.yml"
FUT="$T_TMP/work/lmod-d11"
assert_eq "a test-bed not built yet: state" "$(lock_location "$FUT")" "state"
assert_match "  with a warning" "$(lock_location_note "$FUT" 2>&1)" 'not built yet'
t_run "$T_SH" "$T_REPO/scripts/analysis/upgrade-path.sh" --subject "$L" --phase draft --root "$FUT" --freeze --json
assert_eq "  the draft freeze succeeds, in the state dir" \
  "$T_RC|$([[ -f "$(project_state_path "$FUT")/drupilot-lock.json" ]] && echo state)$([[ -e "$FUT/drupilot-lock.json" ]] && echo root)" "0|state"
mkroot "$FUT"; testbed_mark "$FUT" ddev-up.sh
assert_eq "  once the bed is built and marked, the frozen plan is still found" "$(plan_frozen "$FUT" | jq -r '.subject.machine_name')" "lmod"

# --- project, a loose subject's test-bed ---------------------------------------
BED="$T_TMP/m-d11"; mkroot "$BED"
testbed_mark "$BED" ddev-up.sh
BED_STATE="$(project_state_path "$BED")/drupilot-lock.json"
assert_eq "project on a test-bed drupilot built: state" "$(lock_location "$BED")" "state"
assert_match "  with a warning naming why" "$(lock_location_note "$BED" 2>&1)" "DRUPILOT_LOCK_LOCATION=project.*test-bed"
DRUPILOT_PROJECT_DIR="$BED" lock_set .drupal.core 11.4.8
assert_eq "  writes stay in the state dir" \
  "$([[ -f "$BED_STATE" ]] && echo state)$([[ -e "$BED/drupilot-lock.json" ]] && echo root)" "state"
assert_eq "  round-trip" "$(lock_path "$BED")|$(DRUPILOT_PROJECT_DIR="$BED" lock_get .drupal.core)" "$BED_STATE|11.4.8"

# --- readers create nothing ----------------------------------------------------
NEW="$T_TMP/new"; mkroot "$NEW"
unset DRUPILOT_LOCK_LOCATION
lock_path "$NEW" > /dev/null; DRUPILOT_PROJECT_DIR="$NEW" lock_get .x > /dev/null; lock_location "$NEW" > /dev/null
assert_eq "lock_path, lock_get and lock_location create no state dir" \
  "$([[ -e "$(project_state_path "$NEW")" ]] && echo created || echo none)" "none"

# --- the lock never lands in a patch ----------------------------------------------------
if command -v git > /dev/null 2>&1; then
  G=(git -C "$MOD" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false)
  "${G[@]}" init -q && "${G[@]}" add -A && "${G[@]}" commit -qm base
  printf '{}\n' > "$MOD/drupilot-lock.json"
  sed_inplace "$MOD/modroot.info.yml" 's/^core_version_requirement: .*/core_version_requirement: ^10 || ^11/'
  t_run "$T_SH" "$T_REPO/scripts/contrib/make-patch.sh" --local --subject "$MOD"
  assert_eq "make-patch.sh --local leaves drupilot-lock.json out" \
    "$T_RC|$(grep -c 'drupilot-lock' "$(t_out)" 2> /dev/null || true)" "0|0"
fi
t_done
