#!/usr/bin/env bash
# assess.sh (T-M4-09, 07-R4, AR-10, ADR 0025):
# - the assess goldens (tests/golden/assess/<case>.json) are what assess.sh
#   makes of the findings and worklist goldens on the case's fixture, offline,
#   byte for byte outside meta; they validate against
#   schemas/assess.schema.json, and a second run gives the same document;
# - viability-report.md is rendered with no token left;
# - the rubric: each threshold of the table, which deprecations count as
#   manual (hard and unknown, not soft, not next-major, not where Rector
#   changes the same function; signature errors, not warnings), the
#   hard-break catalog (vendor/ left out), blocking dependencies, the
#   viability threshold;
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
assert_eq "legacy_widgets: the 0.9 sample's verdict and counts" \
  "$(jq -c '[.verdict, .rubric.manual, .rubric.hard_breaks, .rubric.blocking_deps, [.manual_items[].source]]' "$G/legacy_widgets.json")" \
  '["S",2,0,0,["catalog:signature:entity-get-original","catalog:signature:config-form-base-ctor"]]'

# The rubric on synthetic findings.
SUB="$T_TMP/m"; mkdir -p "$SUB/src" "$SUB/templates" "$SUB/js" "$SUB/vendor/x"
printf "name: M\ntype: module\ncore_version_requirement: ^10\n" > "$SUB/m.info.yml"
printf '<?php\nfunction m_help() {}\n' > "$SUB/m.module"
printf '<?php\nclass S implements EventSubscriberInterface {}\n' > "$SUB/vendor/x/S.php"
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
run() {  # run FINDINGS-ON-STDIN [DEPS] -> T_OUT
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
  fnd F-r1 rector 'Rector\X' m.module 'f1()' info current rector
  fnd F-h1 phpstan function.deprecated m.module 'f1()' error current hard
  fnd F-h2 phpstan function.deprecated m.module 'f2()' error current hard
  fnd F-u1 phpstan function.deprecated m.module 'f3()' error current unknown
  fnd F-s1 phpstan function.deprecated m.module 'f4()' error current soft
  fnd F-n1 phpstan function.deprecated m.module 'f5()' error next-major hard
  fnd F-g1 catalog signature:x m.module 'f6()' error current signature
  fnd F-g2 catalog signature:y m.module 'f7()' warning current signature
} | jq -s . | run
assert_eq "manual: hard and unknown where Rector does not change the function, and signature errors" \
  "$(jq -c '[.manual_items[].finding_id]' "$T_OUT")" '["F-g1","F-h2","F-u1"]'
assert_eq "  the soft count is reported, outside the rubric" "$(jq -c '[.deprecations_hard, .deprecations_soft, .deprecations_unknown]' "$T_OUT")" '[3,1,1]'

# The hard breaks: one category per file kind; vendor/ is left out.
hard 0 | jq -s . | run; assert_eq "no hard break (the vendor/ subscriber does not count)" "$(v)" "S 0 0 0"
printf '{%% spaceless %%}<p>x</p>{%% endspaceless %%}\n' > "$SUB/templates/a.html.twig"
hard 0 | jq -s . | run; assert_eq "one hard break: M" "$(v)" "M 0 1 0"
assert_eq "  its file, relative to the subject" "$(jq -c .hard_break_categories.twig3 "$T_OUT")" '["templates/a.html.twig"]'
printf 'CKEDITOR.replace("x");\n' > "$SUB/js/e.js"
hard 0 | jq -s . | run; assert_eq "two: L" "$(v)" "L 0 2 0"
printf 'm:\n  dependencies:\n    - core/jquery.ui.dialog\n' > "$SUB/m.libraries.yml"
hard 0 | jq -s . | run; assert_eq "three: XL" "$(v)" "XL 0 3 0"
printf '<?php\nclass S implements EventSubscriberInterface {}\n' > "$SUB/src/S.php"
hard 0 | jq -s . | run
assert_eq "four categories, in the catalog's order" "$(jq -c .hard_breaks "$T_OUT")" '["twig3","ckeditor5","jquery_ui","symfony7"]'
assert_eq "  the report says present" "$(grep -c '| present' "$(project_artifacts_dir "$SUB")/viability-report.md" || true)" "4"

# The viability threshold.
rm -f "$SUB/templates/a.html.twig" "$SUB/js/e.js" "$SUB/m.libraries.yml" "$SUB/src/S.php"
hard 5 | jq -s . | run; assert_eq "M within the default threshold (medium)" "$(jq -c '[.viability_threshold, .above_threshold]' "$T_OUT")" '["M",false]'
export DRUPILOT_VIABILITY_THRESHOLD=small
hard 5 | jq -s . | run; assert_eq "M above the small threshold" "$(jq -c '[.viability_threshold, .above_threshold]' "$T_OUT")" '["S",true]'
unset DRUPILOT_VIABILITY_THRESHOLD

# The assessed stage, and its time from meta.
mkf "$T_TMP/f.json" < <(hard 5 | jq -s .)
assert_no_stdout "recorded; without --json, nothing on STDOUT" "$T_SH" "$AS" --subject "$SUB" --findings "$T_TMP/f.json" --worklist "$WL" --deps "$T_TMP/d0.json"
assert_eq "  exit 0" "$T_RC" "0"
assert_eq "  state.json: the assessed stage with effort M" "$(jq -c '[.stage, .effort]' "$(subject_state_file "$SUB")")" '["assessed","M"]'
assert_eq "  the state snapshot reads the time from meta.generated_at" \
  "$(state_snapshot_json "$SUB" | jq -c --slurpfile a "$(project_state_path "$SUB")/assess.json" '[.effort, (.assessed_at == $a[0].meta.generated_at)]')" \
  '["M",true]'

# Misuse.
assert_exit "--findings without --worklist: exit 1" 1 "$T_SH" "$AS" --subject "$SUB" --findings "$T_TMP/f.json"
assert_exit "a file that is not a findings.json: exit 1" 1 "$T_SH" "$AS" --subject "$SUB" --findings "$WL" --worklist "$WL"
assert_exit "an unknown flag: exit 1" 1 "$T_SH" "$AS" --bogus

assert_eq "the viability-assessment skill keeps no grep" "$(grep -c 'grep ' "$T_REPO/skills/viability-assessment/SKILL.md" || true)" "0"
t_done
