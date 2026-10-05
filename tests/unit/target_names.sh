#!/usr/bin/env bash
# The names drupilot derives from the target major (T-M3-08, CC-16, CC-17,
# 09-R10): for T=11 the 0.9 names byte for byte (port-to-drupal-11, -d11,
# drupal11); for T=12 port-to-drupal-12, -d12, drupal12. A loose subject's
# test-bed is <name>-d<T> (--target or DRUPILOT_TARGET_MAJOR), a T=12 local
# patch is <module>-port-to-drupal-12.patch and never embeds an older
# *-port-to-drupal-11*.patch left in the tree, and the managed .gitignore block
# covers every target's patches.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/plans/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
names() { printf '%s|%s|%s|%s' "$(target_patch_desc "$@")" "$(target_workspace_suffix "$@")" "$(target_ddev_type "$@")" "$(target_workspace_suffixes "$@" | tr '\n' ' ')"; }
assert_eq "T 11 (the default): the 0.9 names" "$(names)" "port-to-drupal-11|-d11|drupal11|-d11 "
assert_eq "T 12: its names, a 0.9 -d11 bed still found" "$(names 12)" "port-to-drupal-12|-d12|drupal12|-d12 -d11 "
assert_eq "DRUPILOT_TARGET_MAJOR=12 names them too" "$(DRUPILOT_TARGET_MAJOR=12 target_patch_desc)" "port-to-drupal-12"
assert_eq "an invalid T is 11" "$(names abc | cut -d'|' -f1)" "port-to-drupal-11"
assert_eq "the patch globs: the 0.9 ones and every target's" "$(target_patch_globs | tr '\n' ' ')" \
  "*-port-to-drupal-11.patch *-port-to-drupal-11-*.patch *-port-to-drupal-*.patch "

# A loose subject's test-bed.
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$T_TMP/legacy_widgets"
rw() { "$T_SH" "$T_REPO/scripts/env/resolve-workspace.sh" --subject "$T_TMP/legacy_widgets" --json "$@" 2> /dev/null | jq -r '.drupal_root'; }
assert_eq "resolve-workspace: <name>-d11 by default" "$(rw)" "$T_TMP/legacy_widgets-d11"
assert_eq "  --target 12: <name>-d12" "$(rw --target 12)" "$T_TMP/legacy_widgets-d12"
assert_eq "  DRUPILOT_TARGET_MAJOR=12: <name>-d12" "$(DRUPILOT_TARGET_MAJOR=12 rw)" "$T_TMP/legacy_widgets-d12"
t_run "$T_SH" "$T_REPO/scripts/env/resolve-workspace.sh" --subject "$T_TMP/legacy_widgets" --target x --json
assert_eq "  an invalid --target: exit 1" "$T_RC" "1"

# A T=12 local patch, with a 0.9 patch left in the tree.
if command -v git > /dev/null 2>&1; then
  m="$T_TMP/mod/legacy_widgets"; mkdir -p "$T_TMP/mod"; cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$m"
  G=(git -C "$m" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false)
  "${G[@]}" init -q && "${G[@]}" add -A && "${G[@]}" commit -qm base
  sed_inplace "$m/legacy_widgets.info.yml" 's/^core_version_requirement: .*/core_version_requirement: ^11 || ^12/'
  printf 'old\n' > "$m/legacy_widgets-port-to-drupal-11.patch"
  printf 'old\n' > "$m/legacy_widgets-port-to-drupal-11-123-4.patch"
  t_run env DRUPILOT_TARGET_MAJOR=12 "$T_SH" "$T_REPO/scripts/contrib/make-patch.sh" --local --subject "$m"
  p="$(t_out)"
  assert_eq "make-patch --local for T 12: <module>-port-to-drupal-12.patch" "$T_RC|$(basename "$p")" "0|legacy_widgets-port-to-drupal-12.patch"
  assert_eq "  only the port, no 0.9 patch in it" "$(grep '^diff --git' "$p" 2> /dev/null | tr '\n' ';')" \
    "diff --git a/legacy_widgets.info.yml b/legacy_widgets.info.yml;"
  assert_eq "  every drupilot patch hidden from git status" "$(git -C "$m" status --porcelain -- '*.patch' | grep -c . || true)" "0"
  t_run "$T_SH" "$T_REPO/scripts/contrib/make-patch.sh" --local --subject "$m"
  assert_eq "make-patch --local for T 11: the 0.9 name" "$T_RC|$(basename "$(t_out)")" "0|legacy_widgets-port-to-drupal-11.patch"
fi

# The managed .gitignore block, idempotent.
r="$T_TMP/root"; mkdir -p "$r/web/core/lib"; printf '{"name":"x/root"}\n' > "$r/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$r/web/core/lib/Drupal.php"
"$T_SH" "$T_REPO/scripts/env/ensure-gitignore.sh" --root "$r" > /dev/null 2>&1
"$T_SH" "$T_REPO/scripts/env/ensure-gitignore.sh" --root "$r" > /dev/null 2>&1
assert_eq ".gitignore: every target's patches, the block once" \
  "$(grep -cxF '*-port-to-drupal-*.patch' "$r/.gitignore")|$(grep -cxF '*-port-to-drupal-11.patch' "$r/.gitignore")" "1|1"
t_done
