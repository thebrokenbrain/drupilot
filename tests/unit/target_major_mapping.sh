#!/usr/bin/env bash
# DRUPILOT_TARGET_MAJOR and the 0.9 DRUPILOT_DRUPAL_TARGET agree (T-M3-06,
# X12 as ADR 0021 narrows it, CC-08): the setting stays the test-bed's core
# constraint and the highest major it admits (lower-bound operands only) is
# T; only a constraint admitting two or more majors is also a declared-range
# override (strategy explicit), unless DRUPILOT_CORE_TARGET_STRATEGY itself is
# set (a DRUPILOT_KEEP_D10 boolean does not count); a one-major or dev form
# only pins the bed, as in 0.9. An explicit TARGET_MAJOR wins and, without a
# DRUPAL_TARGET, gives the test-bed constraint ^T. With neither set, 0.9's
# defaults: 11 and ^11. A draft frozen with the range and a final plan given
# the same range with --range agree (ADR 0018). DRUPILOT_PHP_TARGET keeps its
# name and meaning (X11).
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
assert_eq "an upper bound is not admitted: >=11 <12 is 11, no range" "$(tm 'DRUPILOT_DRUPAL_TARGET=>=11 <12')" "11|>=11 <12|"
assert_eq ">=10.3 <12 admits 10 and 11: T 11, a declared range" "$(tm 'DRUPILOT_DRUPAL_TARGET=>=10.3 <12' | cut -d'|' -f1,3)" "11|>=10.3 <12"
assert_eq "constraint_majors: ^10.3 || ^11 / >=11 <12.1 / <=12 / >=10" \
  "$(constraint_majors '^10.3 || ^11' | tr '\n' ' ')/$(constraint_majors '>=11 <12.1' | tr '\n' ' ')/$(constraint_majors '<=12' | tr '\n' ' ')/$(constraint_majors '>=10' | tr '\n' ' ')" \
  "10 11 /11 12 //10 "
for v in '^11.2' '~11.2.0' '11.x-dev' '^11 || ^11.2@dev'; do
  assert_eq "one-major or dev form $v: only the bed, T 11" "$(tm "DRUPILOT_DRUPAL_TARGET=$v")" "11|$v|"
done
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
up 'DRUPILOT_DRUPAL_TARGET=^10.3 || ^11' DRUPILOT_KEEP_D10=true
assert_eq "  a KEEP_D10 boolean is not a set strategy: the range stays, no false warning" \
  "$T_RC|$(jq -c '[.range.strategy, .range.constraint]' "$T_OUT")|$(t_err | grep -c 'not used as the declared range' || true)" '0|["explicit","^10.3 || ^11"]|0'
up DRUPILOT_DRUPAL_TARGET=^11
assert_eq "  a bare ^11: the strategy as usual (auto)" "$T_RC|$(jq -c '[.range.strategy, .range.constraint]' "$T_OUT")" '0|["auto","^10 || ^11"]'
up DRUPILOT_DRUPAL_TARGET=~11.2.0
assert_eq "  a one-major ~11.2.0: the strategy as usual, as in 0.9" "$T_RC|$(jq -c '[.range.strategy, .range.constraint]' "$T_OUT")" '0|["auto","^10 || ^11"]'
# The draft frozen with the range, the final plan given the same range (the
# port's path, ADR 0021): no final-changes-frozen.
R2="$T_TMP/root2"; mkdir -p "$R2/web/core/lib" "$R2/web/modules/custom"; printf '{"name":"x/root"}\n' > "$R2/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$R2/web/core/lib/Drupal.php"
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$R2/web/modules/custom/legacy_widgets"
t_run env 'DRUPILOT_DRUPAL_TARGET=^10.3 || ^11' "$T_SH" "$T_REPO/scripts/analysis/upgrade-path.sh" --subject "$R2/web/modules/custom/legacy_widgets" --root "$R2" --phase draft --freeze --json
assert_eq "draft frozen with the explicit range" "$T_RC|$(plan_get .range.strategy "$R2") $(plan_get .range.constraint "$R2")" "0|explicit ^10.3 || ^11"
t_run env 'DRUPILOT_DRUPAL_TARGET=^10.3 || ^11' "$T_SH" "$T_REPO/scripts/analysis/upgrade-path.sh" --subject "$R2/web/modules/custom/legacy_widgets" --root "$R2" --phase final --range "$(plan_get .range.constraint "$R2")" --freeze --json
assert_eq "  the final plan with --range that range: frozen" "$T_RC|$(plan_get .meta.phase "$R2") $(plan_get .range.constraint "$R2")" "0|final ^10.3 || ^11"
up DRUPILOT_DRUPAL_TARGET=^12
assert_eq "  a bare ^12: T 12, refused without the pre-release opt-in" "$T_RC|$(jq -r '.violations[0].id // .violations[0].code // empty' "$T_OUT")" "2|prerelease-not-opted-in"
t_done
