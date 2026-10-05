#!/usr/bin/env bash
# detect-source.sh (T-M3-01, T-M3-02, AR-05): the source era S of each fixture
# matches its golden in tests/golden/detect-source/ (static signals, and the
# --full signal 4 from legacy_widgets' recorded PHPStan output); the misuses
# exit 1; the Drupal 7 .info helpers answer only for a directory without a
# .info.yml, so the .info.yml subjects behave as before (CC-22).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
F="$T_REPO/tests/fixtures"; G="$T_REPO/tests/golden/detect-source"
ds() { t_run "$T_SH" "$T_REPO/scripts/analysis/detect-source.sh" "$@"; }

while IFS=: read -r name dir; do
  ds --subject "$F/$dir" --json
  assert_eq "$name: exit 0" "$T_RC" "0"
  assert_file_eq "$name: the golden" "$T_OUT" "$G/$name.json"
done <<EOF
legacy_widgets:legacy_widgets
legacy_widgets_extra:legacy_widgets/modules/legacy_widgets_extra
acme_core:monorepo/web/modules/custom/acme_core
acme_search_ui:monorepo/web/modules/custom/acme_search/modules/acme_search_ui
d7_minimal:d7_minimal
d8_legacy:d8_legacy
d9_module:d9_module
d11_php_only:d11_php_only
keep_current:keep_current
EOF
ds --subject "$F/legacy_widgets" --full --phpstan "$F/legacy_widgets.golden/raw/phpstan.json" --json
assert_file_eq "legacy_widgets --full with its recorded PHPStan output: the golden" "$T_OUT" "$G/legacy_widgets.full.json"
assert_eq "--static is the default" "$(cd "$F/d8_legacy" && "$T_SH" "$T_REPO/scripts/analysis/detect-source.sh" --json | jq -c .signals_used)" "[1,2,3,5,6]"
ds --subject "$F/legacy_widgets"
assert_eq "without --json: the JSON on STDOUT, a summary on STDERR" \
  "$T_RC|$(jq -r .source_major "$T_OUT")|$(grep -c 'Source era S : 10' "$T_ERR")" "0|10|1"

# Signal 4 only lowers S: a removal in drupal:9 makes a D10 module era 8.
printf '%s' '{"files":{"x.php":{"messages":[{"line":3,"message":"Call to deprecated function drupal_set_message():\nin drupal:8.5.0 and is removed from drupal:9.0.0."}]}}}' > "$T_TMP/p.json"
ds --subject "$F/legacy_widgets" --full --phpstan "$T_TMP/p.json" --json
assert_eq "a recorded removal from drupal:9 lowers S to 8 (high)" \
  "$(jq -c '[.source_major, .confidence, [.evidence[] | select(.signal == 4) | .era]]' "$T_OUT")" '[8,"high",[8]]'

# The rules of ADR 0016 on scratch modules: mk NAME INFO_YML [FILE CONTENT].
mk() { mkdir -p "$T_TMP/m/$1"; printf '%b' "$2" > "$T_TMP/m/$1/$1.info.yml"
  if [[ -n "${3:-}" ]]; then mkdir -p "$(dirname "$T_TMP/m/$1/$3")"; printf '%b' "$4" > "$T_TMP/m/$1/$3"; fi; }
sc() { "$T_SH" "$T_REPO/scripts/analysis/detect-source.sh" --subject "$T_TMP/m/$1" --json "${@:2}" 2> /dev/null \
  | jq -c '[.source_major, .confidence, .track, ([.evidence[] | .signal] | unique)]'; }
WT='<?php\nclass T extends WebTestBase {}\n'
mk min "name: m\ntype: module\ncore_version_requirement: ^10\n" src/Tests/T.php "$WT"
assert_eq "a code signal older than the declaration wins (S is the minimum)" "$(sc min)" '[8,"high","standard",[3,5]]'
mk tie "name: m\ntype: module\ncore_version_requirement: ^8.8 || ^9\n" src/Tests/T.php "$WT"
assert_eq "a code signal as old as the declaration: high" "$(sc tie)" '[8,"high","standard",[3,5]]'
mk jtb "name: m\ntype: module\ncore_version_requirement: ^9 || ^10\n" tests/src/J.php '<?php\nuse Drupal\\FunctionalJavascriptTests\\JavascriptTestBase;\n'
assert_eq "JavascriptTestBase is a SimpleTest-era signal (5)" "$(sc jtb)" '[8,"high","standard",[3,5]]'
mk none "name: m\ntype: module\n"
assert_eq "nothing declared, no code signal: 8, low" "$(sc none)" '[8,"low","standard",[]]'
printf '%s' '{"files":{"a.php":{"messages":[{"line":1,"message":"in drupal:11.4.0 and is removed from drupal:13.0.0."}]}}}' > "$T_TMP/p13.json"
assert_eq "signal 4 never raises S (a removal in drupal:13 on an undeclared module)" \
  "$(sc none --full --phpstan "$T_TMP/p13.json")" '[8,"low","standard",[4]]'
printf '%s' '{"files":{"a.php":{"messages":[{"line":1,"message":"in drupal:7.50 and is removed from drupal:8.0.0."}]}}}' > "$T_TMP/p8.json"
assert_eq "... it lowers it, and an .info.yml subject stays on the standard track" \
  "$(sc none --full --phpstan "$T_TMP/p8.json")" '[7,"high","standard",[4]]'
mk d11 "name: m\ntype: module\ncore_version_requirement: ^11\n"
printf '%s' '{"files":{"/var/www/html/web/modules/custom/d11/src/A.php":{"messages":[{"line":3,"message":"Call to static method x() on an unknown class User_Roles."},{"line":4,"message":"Function user_roles not found."}]}}}' > "$T_TMP/pu.json"
assert_eq "unknown symbols the catalog dates (user_roles: removed in 11) lower S; paths from the subject" \
  "$("$T_SH" "$T_REPO/scripts/analysis/detect-source.sh" --subject "$T_TMP/m/d11" --full --phpstan "$T_TMP/pu.json" --json 2>/dev/null \
     | jq -c '[.source_major, .confidence, [.evidence[] | select(.signal == 4) | [.era, .file, .line]]]')" '[10,"high",[[10,"src/A.php",3],[10,"src/A.php",4]]]'
mk c8 "name: m\ntype: module\ncore: '8.x' # a quoted value and a comment\n"
assert_eq "signal 2 reads a quoted core: 8.x with a comment" "$(sc c8)" '[8,"high","standard",[2]]'
mk c8d "name: m\ntype: module\ncore: 8.x\ncore_version_requirement: ^8.8 || ^9\n"
assert_eq "signal 2 needs no core_version_requirement" "$(sc c8d)" '[8,"medium","standard",[3]]'
mk d7left "name: m\ntype: module\ncore_version_requirement: ^10\n" legacy/m.test '<?php\nclass MTestCase extends DrupalWebTestCase {}\n'
assert_eq "a Drupal 7 test left in an .info.yml module is dead code: no signal 6, no d7 track" "$(sc d7left)" '[10,"medium","standard",[3]]'
mk "co:lon" "name: m\ntype: module\ncore_version_requirement: ^10\n" "src/Tests/T:x.php" "$WT"
assert_eq "a ':' in a path keeps the evidence" "$(sc "co:lon")" '[8,"high","standard",[3,5]]'
ln -s "$T_TMP/m/min" "$T_TMP/link"
assert_eq "a symlinked subject is scanned (DRUPILOT_PLACEMENT=symlink)" \
  "$("$T_SH" "$T_REPO/scripts/analysis/detect-source.sh" --subject "$T_TMP/link" --json 2>/dev/null | jq -c '[.source_major, ([.evidence[].signal] | unique)]')" '[8,[3,5]]'
assert_eq "--full without --phpstan does not claim signal 4" \
  "$("$T_SH" "$T_REPO/scripts/analysis/detect-source.sh" --subject "$T_TMP/m/min" --full --json 2>/dev/null | jq -c .signals_used)" '[1,2,3,5,6]'
printf 'not json\n' > "$T_TMP/bad.json"
ds --subject "$T_TMP/m/min" --full --phpstan "$T_TMP/bad.json" --json
assert_eq "a --phpstan file that is not JSON: exit 1" "$T_RC" "1"

# Misuses.
mkdir -p "$T_TMP/empty"
ds --subject "$T_TMP/empty" --json
assert_eq "not a module: exit 1" "$T_RC" "1"
ds --subject "$F/legacy_widgets" --phpstan "$T_TMP/p.json" --json
assert_eq "--phpstan without --full: exit 1" "$T_RC" "1"
mkdir -p "$T_TMP/d6"; printf 'name = Old\ncore = 6.x\n' > "$T_TMP/d6/d6.info"
ds --subject "$T_TMP/d6" --json
assert_eq "a .info without core = 7.x: exit 1" "$T_RC" "1"
ds --bogus
assert_eq "an unknown option: exit 1" "$T_RC" "1"

# The Drupal 7 helpers (subject.sh) and CC-22.
assert_eq "subject_d7_info_file finds <name>.info" "$(subject_d7_info_file "$F/d7_minimal")" "$F/d7_minimal/d7_minimal.info"
mkdir -p "$T_TMP/both"; printf 'name: x\ntype: module\ncore_version_requirement: ^10\n' > "$T_TMP/both/both.info.yml"
printf 'core = 7.x\n' > "$T_TMP/both/both.info"
assert_eq "... never for a directory with a .info.yml" "$(subject_d7_info_file "$T_TMP/both" || echo none)" "none"
assert_eq "is_drupal_extension_dir is unchanged for a .info-only directory" \
  "$(is_drupal_extension_dir "$F/d7_minimal" && echo yes || echo no)" "no"
printf 'name = "Quoted name"\ncore_version = 9\ncore = 7.x\n' > "$T_TMP/q.info"
assert_eq "info_value_d7 strips quotes, and a longer key is not its prefix" \
  "$(info_value_d7 "$T_TMP/q.info" name)|$(info_value_d7 "$T_TMP/q.info" core)|$(info_value_d7 "$T_TMP/q.info" missing)" "Quoted name|7.x|"
mkdir -p "$T_TMP/pick"; printf 'core = 7.x\n' > "$T_TMP/pick/b.info"; printf 'core = 7.x\n' > "$T_TMP/pick/a.info"
assert_eq "without <name>.info, the first .info in a stable order" "$(subject_d7_info_file "$T_TMP/pick")" "$T_TMP/pick/a.info"
printf 'core = 7.x\n' > "$T_TMP/pick/pick.info"
assert_eq "<name>.info first" "$(subject_d7_info_file "$T_TMP/pick")" "$T_TMP/pick/pick.info"
t_done
