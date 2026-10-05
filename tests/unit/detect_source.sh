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
printf 'name = "Quoted name"\ncore = 7.x\n' > "$T_TMP/q.info"
assert_eq "info_value_d7 strips quotes" "$(info_value_d7 "$T_TMP/q.info" name)|$(info_value_d7 "$T_TMP/q.info" core)|$(info_value_d7 "$T_TMP/q.info" missing)" "Quoted name|7.x|"
t_done
