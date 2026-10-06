#!/usr/bin/env bash
# assess.sh (T-M4-09, 07-R4, AR-10, ADR 0025):
# - the assess goldens (tests/golden/assess/<case>.json) are what assess.sh
#   makes of the findings and worklist goldens on the case's fixture, offline,
#   byte for byte outside meta; they validate against
#   schemas/assess.schema.json, and a second run gives the same document;
# - viability-report.md is rendered with no token left;
# - the rubric: each threshold of the table, which deprecations count as
#   manual (the PHPStan occurrences of hard and unknown ones, not soft, not
#   next-major, not where a Drupal Rector rule changes the same function or
#   method; a PHP-level rule, a file-level anchor or unavailable anchors cover
#   nothing; signature and port-safety errors, not warnings), the hard-break
#   catalog (globs never expanded by the shell, vendor/ and node_modules/ left
#   out, case-sensitive), blocking dependencies, the viability threshold;
# - a Rector or PHPStan run with no verdict makes the verdict provisional
#   (exit 3, no stage recorded); the settings come from the subject's root;
# - info.yml: a quoted or open-ended requirement, the submodules;
# - the report escapes | in its table cells;
# - the assessed stage is recorded, and state.json reads its time from meta;
# - the skill keeps no grep (07-R4).
# Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
AS="$T_REPO/scripts/analysis/assess.sh"
G="$T_REPO/tests/golden/assess"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$G/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
valid() { jq -r --slurpfile schema "$T_REPO/schemas/assess.schema.json" \
  "$(cat "$T_REPO/scripts/dev/jsonschema.jq")"' . as $doc | $schema[0] as $root | $doc | chk($root; $root; "$")' "$1" 2>&1; }

cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$T_REPO/tests/fixtures/monorepo" "$T_TMP/"
while IFS="$(printf '\t')" read -r c fx; do
  [[ -n "$c" ]] || continue
  assert_exit "$c: assessed" 0 "$T_SH" "$AS" --subject "$T_TMP/$fx" --findings "$T_REPO/tests/golden/findings/$c/findings.json" \
    --worklist "$T_REPO/tests/golden/worklist/$c.json" --offline --no-record --json
  jq 'del(.meta)' "$T_OUT" | canon_json > "$T_TMP/$c.json"
  assert_file_eq "  assess.json, byte for byte outside meta" "$T_TMP/$c.json" "$G/$c.json"
  assert_eq "  it validates against schemas/assess.schema.json" "$(valid "$T_OUT")" ""
  assert_eq "  meta holds the time" "$(jq -r '.meta.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$T_OUT")" "true"
  assert_file_eq "  the state dir holds the same document" "$(project_state_path "$T_TMP/$fx")/assess.json" "$T_OUT"
  R="$(project_artifacts_dir "$T_TMP/$fx")/viability-report.md"
  assert_eq "  viability-report.md has no token left" "$(grep -c '{{' "$R" 2> /dev/null || true)" "0"
  assert_match "  it shows the verdict" "$(cat "$R")" "Effort estimate: $(jq -r .verdict "$G/$c.json")"
  t_run "$T_SH" "$AS" --subject "$T_TMP/$fx" --findings "$T_REPO/tests/golden/findings/$c/findings.json" \
    --worklist "$T_REPO/tests/golden/worklist/$c.json" --offline --no-record --json
  assert_eq "  a second run: the same document outside meta" "$(jq -c 'del(.meta)' "$T_OUT")" "$(jq -c . "$G/$c.json")"
done < "$G/cases.tsv"
assert_eq "legacy_widgets: the 0.9 sample's verdict and counts (its third manual item is now the port-safety error, not a PHPStan analysis error)" \
  "$(jq -c '[.verdict, .rubric.manual, .rubric.hard_breaks, .rubric.blocking_deps, [.manual_items[].source]]' "$G/legacy_widgets.json")" \
  '["S",3,0,0,["catalog:port-safety:class-case","catalog:signature:entity-get-original","catalog:signature:config-form-base-ctor"]]'
assert_match "  the report escapes the | of the recommended requirement" "$(cat "$(project_artifacts_dir "$T_TMP/legacy_widgets")/viability-report.md")" '`\^10 \\\|\\\| \^11`'

# The rubric on synthetic findings.
SUB="$T_TMP/m"; mkdir -p "$SUB/src" "$SUB/templates" "$SUB/js" "$SUB/vendor/x" "$SUB/node_modules/y"
printf "name: M\ntype: module\ncore_version_requirement: ^10\n" > "$SUB/m.info.yml"
printf '<?php\nfunction m_help() {}\n' > "$SUB/m.module"
printf '<?php\nclass S implements EventSubscriberInterface {}\n' > "$SUB/vendor/x/S.php"
printf 'Drupal.behaviors.x = { attach: function () { jQuery.ui; CKEDITOR.replace("x"); } };\n' > "$SUB/node_modules/y/ui.js"
mkf() {  # mkf FILE: findings.json from the JSON array of findings on STDIN
  jq '{schema: 1, stage: "assess", subject: {machine_name: "m", path: "web/modules/custom/m"},
       target: {major: 11, soft_policy: "report", runner: null, php_version: null}, anchors: "php",
       tools: {rector: "ok", phpstan: "ok"}, counts: {}, findings: ., meta: {findings_hash: "sha256:\("0" * 64)"}}' > "$1"
}
fnd() {  # fnd ID TOOL RULE FILE ANCHOR SEVERITY SCOPE CLASS
  jq -n -c --arg id "$1" --arg t "$2" --arg r "$3" --arg f "$4" --arg a "$5" --arg s "$6" --arg sc "$7" --arg c "$8" \
    '{id: $id, tool: $t, rule: $r, file: $f, line: 3, anchor: $a, symbol: null, message: "a message", occurrence: 0,
      severity: $s, scope: $sc, class: $c, sources: [{tool: $t, rule: $r, line: 3}]}'
}
hard() {  # hard N: N hard deprecations, each in its own function
  local i=0; while [[ "$i" -lt "$1" ]]; do i=$((i + 1)); fnd "F-h$i" phpstan function.deprecated m.module "f$i()" error current hard; done
  return 0
}
WL="$T_TMP/w.json"
printf '{"schema": 1, "items": [], "counts": {"items": 0, "open": 0, "by_lane": {}}, "meta": {"worklist_hash": null}}\n' > "$WL"
printf '{"offline": true, "totals": {"ready": 0, "blockers": 0, "unknown": 0}, "dependencies": []}\n' > "$T_TMP/d0.json"
printf '{"offline": false, "totals": {"ready": 1, "blockers": 1, "unknown": 0}, "dependencies": [{"project": "x", "d11": "no"}]}\n' > "$T_TMP/d1.json"
run() {  # run [DEPS] < FINDINGS-ARRAY -> T_OUT
  mkf "$T_TMP/f.json"
  t_run "$T_SH" "$AS" --subject "$SUB" --findings "$T_TMP/f.json" --worklist "$WL" --deps "$T_TMP/${1:-d0}.json" --no-record --json
}
v() { jq -r '"\(.verdict) \(.rubric.manual) \(.rubric.hard_breaks) \(.rubric.blocking_deps)"' "$T_OUT"; }
hard 4 | jq -s . | run;  assert_eq "manual 4: S" "$(v)" "S 4 0 0"
hard 5 | jq -s . | run;  assert_eq "manual 5: M" "$(v)" "M 5 0 0"
assert_eq "  the rule that matched, verbatim" "$(jq -r .rubric.rule "$T_OUT")" "M: hard_breaks == 1 or manual >= 5"
hard 15 | jq -s . | run; assert_eq "manual 15: M" "$(v)" "M 15 0 0"
hard 16 | jq -s . | run; assert_eq "manual 16: L" "$(v)" "L 16 0 0"
hard 40 | jq -s . | run; assert_eq "manual 40: L" "$(v)" "L 40 0 0"
hard 41 | jq -s . | run; assert_eq "manual 41: XL" "$(v)" "XL 41 0 0"
hard 0 | jq -s . | run d1; assert_eq "a blocking dependency: XL" "$(v)" "XL 0 0 1"
assert_eq "  the dependencies as deps-status.sh gave them" "$(jq -c '.dependencies | [.ready, .blockers, .offline, (.list | length)]' "$T_OUT")" '[1,1,false,1]'
{
  fnd F-r1 rector 'DrupalRector\Drupal10\Rector\Deprecation\X' m.module 'f1()' info current rector
  fnd F-r7 rector 'Rector\Renaming\Rector\FuncCall\RenameFunctionRector' m.module 'f8()' info current rector
  fnd F-r2 rector 'Rector\Php81\Rector\FuncCall\NullToStrictStringFuncCallArgRector' m.module 'f2()' info current rector
  fnd F-r3 rector 'DrupalRector\Drupal10\Rector\Deprecation\X' m.module '{file}' info current rector
  fnd F-h1 phpstan function.deprecated m.module 'f1()' error current hard
  fnd F-h8 phpstan function.deprecated m.module 'f8()' error current hard
  fnd F-h2 phpstan function.deprecated m.module 'f2()' error current hard
  fnd F-h9 phpstan function.deprecated m.module '{file}' error current hard
  fnd F-u1 phpstan function.deprecated m.module 'f3()' error current unknown
  fnd F-s1 phpstan function.deprecated m.module 'f4()' error current soft
  fnd F-n1 phpstan function.deprecated m.module 'f5()' error next-major hard
  fnd F-g1 catalog signature:x m.module 'f6()' error current signature
  fnd F-g2 catalog signature:y m.module 'f7()' warning current signature
  fnd F-p1 catalog port-safety:x m.module 'f9()' error current safety
  fnd F-p2 catalog port-safety:y m.module 'f9()' warning current safety
  fnd F-a1 phpstan method.notFound m.module 'f9()' error current analysis
} | jq -s . | run
assert_eq "manual: hard and unknown no Drupal Rector rule covers (a PHP-level rule and a file-level anchor cover nothing), signature and port-safety errors" \
  "$(jq -c '[.manual_items[].finding_id]' "$T_OUT")" '["F-g1","F-h2","F-h9","F-p1","F-u1"]'
assert_eq "  the soft count is reported, outside the rubric" "$(jq -c '[.deprecations_hard, .deprecations_soft, .deprecations_unknown]' "$T_OUT")" '[5,1,1]'
assert_eq "  the auto-fixable files: every Rector pass" "$(jq -c '.auto_fixable.rector_official_files' "$T_OUT")" '1'
fnd F-h1 phpstan function.deprecated m.module 'f1()' error current hard | jq -c '.sources = [range(5) as $i | {tool: "phpstan", rule: "function.deprecated", line: (3 + $i)}]' | jq -s . | run
assert_eq "five calls merged in one finding: five occurrences, manual 5 (M)" "$(v)|$(jq -c '[.manual_items[0].occurrences, .deprecations_hard]' "$T_OUT")" "M 5 0 0|[5,5]"
{ fnd F-r1 rector 'DrupalRector\Drupal10\Rector\Deprecation\X' m.module 'f1()' info current rector; fnd F-h1 phpstan function.deprecated m.module 'f1()' error current hard; } \
  | jq -s . | mkf "$T_TMP/f.json"; jq '.anchors = "unavailable"' "$T_TMP/f.json" > "$T_TMP/fu.json"
t_run "$T_SH" "$AS" --subject "$SUB" --findings "$T_TMP/fu.json" --worklist "$WL" --deps "$T_TMP/d0.json" --no-record --json
assert_eq "anchors unavailable: nothing counts as covered" "$(v)" "S 1 0 0"

# The hard breaks: one category per file kind; vendor/ and node_modules/ are
# left out, the catalog globs are never expanded in the module's root, the
# EREs are case-sensitive.
printf '<?php\n// The API.\n' > "$SUB/m.api.php"
printf 'module.exports = {};\n' > "$SUB/webpack.config.js"
printf 'var x = ckeditor.instances;\n' > "$SUB/js/lower.js"
hard 0 | jq -s . | run; assert_eq "no hard break (vendor/, node_modules/, a lowercase ckeditor)" "$(v)" "S 0 0 0"
printf '{%% spaceless %%}<p>x</p>{%% endspaceless %%}\n' > "$SUB/templates/a.html.twig"
hard 0 | jq -s . | run; assert_eq "one hard break: M" "$(v)" "M 0 1 0"
assert_eq "  its file, relative to the subject" "$(jq -c .hard_break_categories.twig3 "$T_OUT")" '["templates/a.html.twig"]'
printf 'CKEDITOR.replace("x");\n' > "$SUB/js/e.js"
hard 0 | jq -s . | run; assert_eq "two (a js/ file next to a root webpack.config.js): L" "$(v)" "L 0 2 0"
mkdir -p "$SUB/config/install"; printf 'dependencies:\n  - core/jquery.ui.dialog\n' > "$SUB/config/install/m.settings.yml"
hard 0 | jq -s . | run; assert_eq "three (a config/install yml next to the root info.yml): XL" "$(v)" "XL 0 3 0"
mkdir -p "$SUB/src/EventSubscriber"; printf '<?php\nclass S implements EventSubscriberInterface {}\n' > "$SUB/src/EventSubscriber/S.php"
hard 0 | jq -s . | run
assert_eq "four categories (a subscriber next to a root m.api.php), in the catalog's order" "$(jq -c .hard_breaks "$T_OUT")" '["twig3","ckeditor5","jquery_ui","symfony7"]'
assert_eq "  the report says present" "$(grep -c '| present' "$(project_artifacts_dir "$SUB")/viability-report.md" || true)" "4"
rm -f "$SUB/templates/a.html.twig" "$SUB/js/e.js" "$SUB/config/install/m.settings.yml" "$SUB/src/EventSubscriber/S.php"

# The viability threshold.
hard 5 | jq -s . | run; assert_eq "M within the default threshold (medium)" "$(jq -c '[.viability_threshold, .above_threshold]' "$T_OUT")" '["M",false]'
for th in small:S:true large:L:false xl:XL:false; do
  export DRUPILOT_VIABILITY_THRESHOLD="${th%%:*}"
  hard 5 | jq -s . | run
  assert_eq "M against the ${th%%:*} threshold" "$(jq -c '[.viability_threshold, .above_threshold]' "$T_OUT")" "[\"$(printf '%s' "$th" | cut -d: -f2)\",${th##*:}]"
done
unset DRUPILOT_VIABILITY_THRESHOLD

# Rector or PHPStan with no verdict: provisional, exit 3, no stage recorded.
hard 5 | jq -s . | mkf "$T_TMP/f.json"; jq '.tools.phpstan = "failed"' "$T_TMP/f.json" > "$T_TMP/fp.json"
t_run "$T_SH" "$AS" --subject "$SUB" --findings "$T_TMP/fp.json" --worklist "$WL" --deps "$T_TMP/d0.json" --json
assert_eq "PHPStan failed: exit 3, provisional, the stage not recorded" \
  "$T_RC|$(jq -c '[.verdict, .provisional]' "$T_OUT")|$([[ -f "$(subject_state_file "$SUB")" ]] && jq -r '.stage // "none"' "$(subject_state_file "$SUB")" || echo none)" '3|["M",true]|none'
assert_match "  the report says so" "$(cat "$(project_artifacts_dir "$SUB")/viability-report.md")" "Provisional:.*phpstan failed"

# info.yml: a quoted requirement, an open-ended one; the submodules.
printf "name: M\ntype: module\ncore_version_requirement: '^10.3 || ^11'\n" > "$SUB/m.info.yml"
hard 0 | jq -s . | run
assert_eq "a quoted requirement: read unquoted, it admits 11" "$(jq -c '[.current_core_version_requirement, .info_yml.d11_compatible]' "$T_OUT")" '["^10.3 || ^11",true]'
printf "name: M\ntype: module\ncore_version_requirement: '>=9.5'\n" > "$SUB/m.info.yml"
{ fnd F-m1 catalog metadata:submodule-core-req modules/s/s.info.yml '{file}' info current metadata; } | jq -s . | run
assert_eq "an open-ended >=9.5 admits 11; an info submodule finding keeps the submodules compatible" "$(jq -c '[.info_yml.d11_compatible, .info_yml.submodules_d11_compatible]' "$T_OUT")" '[true,true]'
{ fnd F-m1 catalog metadata:submodule-core-req modules/s/s.info.yml '{file}' warning current metadata; } | jq -s . | run
assert_eq "  a warning one does not" "$(jq -c '.info_yml.submodules_d11_compatible' "$T_OUT")" 'false'
printf "name: M\ntype: module\ncore_version_requirement: ^10\n" > "$SUB/m.info.yml"
assert_eq "constraint_admits_major" \
  "$(for c in '^10' '^10 || ^11' '>=10 <11' '>=10.3 <12' '*' '~11.1'; do constraint_admits_major "$c" 11 && printf y || printf n; done)" "nyny""yy"

# The settings come from the subject's Drupal root, wherever it runs from.
DR="$T_TMP/site"; mkdir -p "$DR/web/core/lib" "$DR/web/modules/custom"
printf '{"name":"x/site"}\n' > "$DR/composer.json"; printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$DR/web/core/lib/Drupal.php"
cp -R "$SUB" "$DR/web/modules/custom/m"; printf '{"DRUPILOT_VIABILITY_THRESHOLD": "small"}\n' > "$DR/.drupilot.json"
hard 5 | jq -s . | mkf "$T_TMP/f.json"
t_run "$T_SH" "$AS" --subject "$DR/web/modules/custom/m" --findings "$T_TMP/f.json" --worklist "$WL" --deps "$T_TMP/d0.json" --no-record --json
assert_eq "run from elsewhere: the root's threshold" "$T_RC|$(jq -c '[.viability_threshold, .above_threshold]' "$T_OUT")" '0|["S",true]'

# The assessed stage, and its time from meta.
assert_no_stdout "recorded; without --json, nothing on STDOUT" "$T_SH" "$AS" --subject "$SUB" --findings "$T_TMP/f.json" --worklist "$WL" --deps "$T_TMP/d0.json"
assert_eq "  exit 0" "$T_RC" "0"
assert_eq "  state.json: the assessed stage with effort M" "$(jq -c '[.stage, .effort]' "$(subject_state_file "$SUB")")" '["assessed","M"]'
assert_eq "  the state snapshot reads the time from meta.generated_at" \
  "$(state_snapshot_json "$SUB" | jq -c --slurpfile a "$(project_state_path "$SUB")/assess.json" '[.effort, (.assessed_at == $a[0].meta.generated_at)]')" \
  '["M",true]'

# Misuse.
assert_exit "--findings without --worklist: exit 1" 1 "$T_SH" "$AS" --subject "$SUB" --findings "$T_TMP/f.json"
assert_exit "a file that is not a findings.json: exit 1" 1 "$T_SH" "$AS" --subject "$SUB" --findings "$WL" --worklist "$WL"
mkdir -p "$T_TMP/noinfo/src"
assert_exit "not a Drupal extension (no info.yml): exit 1" 1 "$T_SH" "$AS" --subject "$T_TMP/noinfo" --findings "$T_TMP/f.json" --worklist "$WL" --deps "$T_TMP/d0.json" --no-record
assert_match "  it says so" "$(t_err)" "not a Drupal extension"
assert_exit "no Drupal root to run the assess stage in: exit 1" 1 "$T_SH" "$AS" --subject "$SUB" --offline --no-record
assert_match "  it says to run setup first" "$(t_err)" "run /drupilot-setup first"
assert_exit "an unknown flag: exit 1" 1 "$T_SH" "$AS" --bogus

assert_eq "the viability-assessment skill keeps no grep" "$(grep -c 'grep ' "$T_REPO/skills/viability-assessment/SKILL.md" || true)" "0"
t_done
