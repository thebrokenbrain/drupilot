#!/usr/bin/env bash
# DRUPILOT_TARGET_MAJOR and the 0.9 DRUPILOT_DRUPAL_TARGET agree (T-M3-06,
# X12, CC-08): a bare ^N names the target major, any other explicit
# constraint is a declared-range override (strategy explicit, unless a
# strategy is set too) whose highest major is T; an explicit TARGET_MAJOR
# wins and, without a DRUPAL_TARGET, gives the test-bed constraint ^T. With
# neither set, 0.9's defaults: 11 and ^11. DRUPILOT_PHP_TARGET keeps its name
# and meaning (X11).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/plans/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
# tm ENV... -> T | the test-bed constraint | the explicit range ("" when none)
tm() {
  env "$@" "$T_SH" -c '. "$1"; printf "%s|%s|%s" "$(resolve_target_major)" "$(resolve_drupal_target)" "$(drupal_target_range)"' _ "$T_LIB" 2> /dev/null
}
assert_eq "neither set: 0.9's defaults" "$(tm X=1)" "11|^11|"
assert_eq "DRUPAL_TARGET=^11" "$(tm DRUPILOT_DRUPAL_TARGET=^11)" "11|^11|"
assert_eq "DRUPAL_TARGET=^12 names T 12" "$(tm DRUPILOT_DRUPAL_TARGET=^12)" "12|^12|"
assert_eq "  quoted, as a .env might hold it" "$(tm 'DRUPILOT_DRUPAL_TARGET="^12"')" "12|\"^12\"|"
assert_eq "another constraint: a declared range, T its highest major" \
  "$(tm 'DRUPILOT_DRUPAL_TARGET=^10.3 || ^11')" "11|^10.3 || ^11|^10.3 || ^11"
assert_eq "TARGET_MAJOR=12 alone: the test-bed constraint ^12" "$(tm DRUPILOT_TARGET_MAJOR=12)" "12|^12|"
assert_eq "TARGET_MAJOR wins over DRUPAL_TARGET's major" "$(tm DRUPILOT_TARGET_MAJOR=11 DRUPILOT_DRUPAL_TARGET=^12 | cut -d'|' -f1)" "11"
mkdir -p "$T_TMP/root/web/core/lib"; printf '{"name":"x/root"}\n' > "$T_TMP/root/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$T_TMP/root/web/core/lib/Drupal.php"
printf '{"DRUPILOT_DRUPAL_TARGET": "^12"}\n' > "$T_TMP/root/.drupilot.json"
assert_eq "a .drupilot.json DRUPAL_TARGET counts too" "$(tm DRUPILOT_PROJECT_DIR="$T_TMP/root")" "12|^12|"
rm -f "$T_TMP/root/.drupilot.json"

# The resolver: the range override, and an explicit strategy over it.
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$T_TMP/legacy_widgets"
up() { t_run env "$@" "$T_SH" "$T_REPO/scripts/analysis/upgrade-path.sh" --subject "$T_TMP/legacy_widgets" --json; }
up 'DRUPILOT_DRUPAL_TARGET=^10.3 || ^11'
assert_eq "upgrade-path: DRUPAL_TARGET ^10.3 || ^11 is an explicit range" \
  "$T_RC|$(jq -c '[.target.major, .range.strategy, .range.constraint]' "$T_OUT")" '0|[11,"explicit","^10.3 || ^11"]'
up 'DRUPILOT_DRUPAL_TARGET=^10.3 || ^11' DRUPILOT_CORE_TARGET_STRATEGY=target-only
assert_eq "  an explicit strategy wins, with a warning" \
  "$T_RC|$(jq -c '[.range.strategy, .range.constraint]' "$T_OUT")|$(t_err | grep -c 'not used as the declared range')" '0|["target-only","^11"]|1'
up DRUPILOT_DRUPAL_TARGET=^11
assert_eq "  a bare ^11: the strategy as usual (auto)" "$T_RC|$(jq -c '[.range.strategy, .range.constraint]' "$T_OUT")" '0|["auto","^10 || ^11"]'
up DRUPILOT_DRUPAL_TARGET=^12
assert_eq "  a bare ^12: T 12, refused without the pre-release opt-in" "$T_RC|$(jq -r '.violations[0].id // .violations[0].code // empty' "$T_OUT")" "2|prerelease-not-opted-in"
t_done
