#!/usr/bin/env bash
# classify.sh and apply-recipes.sh (T-M4-07, AR-10, 05-R4/R6, ADR 0024):
# - the worklist goldens (tests/golden/worklist/<case>.json) are what
#   classify.sh makes of the findings goldens, byte for byte outside
#   meta.generated_at, and validate against schemas/worklist.schema.json;
# - no next-major finding is in an ai-* or test-adapt lane (X18), and every
#   finding is in exactly one item;
# - the lanes: rector, a codemod, a codemod that does not apply (ai-templated
#   with its template), core_min against the floor, a test file
#   (test-adapt), info / style / next-major (deferred), a catalog finding
#   without a recipe (human), the project overlay;
# - apply-recipes.sh applies the open codemods, logs each in actions.jsonl,
#   and the worklist shows an applied item as applied and a codemod that gave
#   no change as ai-templated; after a re-extraction (a new findings_hash) a
#   finding an applied codemod left behind falls to ai-templated too.
# Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
CL="$T_REPO/scripts/ai/classify.sh"; AP="$T_REPO/scripts/ai/apply-recipes.sh"
G="$T_REPO/tests/golden/worklist"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/findings/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
valid() { jq -r --slurpfile schema "$T_REPO/schemas/worklist.schema.json" \
  "$(cat "$T_REPO/scripts/dev/jsonschema.jq")"' . as $doc | $schema[0] as $root | $doc | chk($root; $root; "$")' "$1" 2>&1; }

while IFS="$(printf '\t')" read -r c fl; do
  [[ -n "$c" ]] || continue
  F="$T_REPO/tests/golden/findings/$c/findings.json"
  t_run "$T_SH" "$CL" --findings "$F" --core-floor "$fl" --json
  jq 'del(.meta.generated_at)' "$T_OUT" | canon_json > "$T_TMP/$c.json"
  assert_file_eq "$c: worklist.json, byte for byte outside meta.generated_at" "$T_TMP/$c.json" "$G/$c.json"
  assert_eq "  it validates against schemas/worklist.schema.json" "$(valid "$T_OUT")" ""
  assert_eq "  no next-major finding in an ai-* or test-adapt lane" \
    "$(jq -c --slurpfile f "$F" '([$f[0].findings[] | select(.scope == "next-major") | .id]) as $nm
      | [.items[] | select(.lane | IN("ai-templated", "ai-free", "test-adapt")) | .finding_ids[] | select(. as $i | $nm | index($i))]' "$T_OUT")" "[]"
  assert_eq "  every finding in exactly one item" \
    "$(jq -c --slurpfile f "$F" '[.items[].finding_ids[]] | sort == ([$f[0].findings[].id] | sort)' "$T_OUT")" "true"
  t_run "$T_SH" "$CL" --findings "$F" --core-floor "$fl" --json
  assert_eq "  idempotent: the same input, the same worklist_hash" "$(jq -r .meta.worklist_hash "$T_OUT")" "$(jq -r .meta.worklist_hash "$G/$c.json")"
done < "$G/cases.tsv"
assert_eq "the legacy_widgets lanes" "$(jq -c '.counts.by_lane' "$G/legacy_widgets.json")" \
  '{"ai-free":12,"ai-templated":5,"codemod":2,"deferred":7,"human":6,"rector":1,"test-adapt":6}'

# Synthetic findings for the lane rules.
mkf() {  # mkf FILE: findings.json from the JSON array of findings on STDIN
  jq '{schema: 1, stage: "assess", subject: {machine_name: "m", path: "web/modules/custom/m"},
       target: {major: 11, soft_policy: "report", runner: null, php_version: null}, anchors: "php",
       tools: {}, counts: {}, findings: ., meta: {findings_hash: "sha256:\("0" * 64)"}}' > "$1"
}
fnd() {  # fnd ID TOOL RULE FILE LINE SEVERITY SCOPE CLASS [SYMBOL] [MESSAGE]
  jq -n -c --arg id "$1" --arg t "$2" --arg r "$3" --arg f "$4" --argjson l "$5" --arg s "$6" --arg sc "$7" --arg c "$8" --arg sym "${9:-}" --arg m "${10:-a message}" \
    '{id: $id, tool: $t, rule: $r, file: $f, line: $l, anchor: "M\\A::f\($l)", symbol: (if $sym == "" then null else $sym end),
      message: $m, occurrence: 0, severity: $s, scope: $sc, class: $c, sources: [{tool: $t, rule: $r, line: $l}]}'
}
{
  fnd F-000000000001 rector 'Rector\X' src/A.php 3 info current rector
  fnd F-000000000002 catalog signature:hook-entity-operation m.module 14 error current signature
  fnd F-000000000003 catalog port-safety:class-case src/A.php 9 error current safety
  fnd F-000000000004 phpstan function.deprecated src/A.php 5 error current hard user_roles
  fnd F-000000000005 phpstan method.notFound tests/src/Kernel/T.php 7 error current analysis
  fnd F-000000000006 phpstan function.deprecated src/A.php 6 error next-major soft user_load_by_mail
  fnd F-000000000007 catalog signature:hook-entity-operation m.module 20 info current signature
  fnd F-000000000008 phpcs Drupal.Commenting.X src/A.php 8 warning current style
  fnd F-000000000009 phpstan method.notFound src/A.php 10 error current analysis
  fnd F-00000000000a catalog metadata:services-arity m.services.yml 3 warning current metadata
  fnd F-00000000000b phpstan x.y src/A.php 11 error current analysis "" "Call to drupal_set_message() here."
  fnd F-00000000000c phpstan function.deprecated tests/src/Unit/T.php 12 error next-major soft user_load_by_mail
  fnd F-00000000000d phpstan method.notFound modules/sub/tests/src/Kernel/S.php 13 error current analysis
  fnd F-00000000000e phpcs PHPCompatibility.FunctionUse.X src/A.php 15 error current php-target
} | jq -s . | mkf "$T_TMP/f.json"
t_run "$T_SH" "$CL" --findings "$T_TMP/f.json" --core-floor 10.3 --json
lane() { jq -r --arg id "$1" '.items[] | select(.finding_ids | index($id)) | "\(.lane)|\(.recipe_of[$id] // "-")|\(.reason // "-")|\(.status)"' "$T_OUT"; }
assert_eq "rector: its lane" "$(lane F-000000000001)" "rector|-|-|open"
assert_eq "a codemod that applies (error severity)" "$(lane F-000000000002)" "codemod|sig.hook-entity-operation|-|open"
assert_eq "a codemod whose conditions do not hold (class-case in a PHP file): ai-templated with its template" \
  "$(lane F-000000000003)" "ai-templated|safety.class-case|the recipe's conditions do not hold|open"
assert_eq "  the template comes along" "$(jq -r '.items[] | select(.finding_ids | index("F-000000000003")) | .templates["safety.class-case"].why | length > 0' "$T_OUT")" "true"
assert_eq "a deprecation matched by symbol: its recipe" "$(lane F-000000000004)" "ai-templated|dep.user-roles|-|open"
assert_eq "a file under tests/: test-adapt" "$(lane F-000000000005)" "test-adapt|-|-|open"
assert_eq "next-major: deferred, never an AI lane" "$(lane F-000000000006)" "deferred|-|next-major|deferred"
assert_eq "info: deferred" "$(lane F-000000000007)" "deferred|-|info|deferred"
assert_eq "style: deferred (Phase 1 keeps the diff minimal)" "$(lane F-000000000008)" "deferred|-|style|deferred"
assert_eq "an analysis error no recipe matches: ai-free" "$(lane F-000000000009)" "ai-free|-|-|open"
assert_eq "a metadata finding: human" "$(lane F-00000000000a)" "human|meta.services-arity|-|open"
assert_eq "a message matched by a recipe's pattern" "$(lane F-00000000000b)" "ai-templated|dep.drupal-set-message|-|open"
assert_eq "a next-major finding under tests/: deferred, never test-adapt" "$(lane F-00000000000c)" "deferred|-|next-major|deferred"
assert_eq "a submodule's tests/: test-adapt" "$(lane F-00000000000d)" "test-adapt|-|-|open"
assert_eq "a PHP target finding: ai-free" "$(lane F-00000000000e)" "ai-free|-|-|open"
assert_eq "blocking: the items with an error finding outside deferred (the metadata warning is not)" \
  "$(jq -c '[.items[] | select(.blocking) | .lane] | sort' "$T_OUT")" \
  '["ai-free","ai-free","ai-templated","ai-templated","ai-templated","codemod","test-adapt","test-adapt"]'
assert_eq "items sorted by lane priority, then file and anchor" \
  "$(jq -c '["rector","rector-custom","codemod","ai-templated","ai-free","test-adapt","human","deferred"] as $o
     | [.items[] | [(.lane as $l | $o | index($l)), .file, .anchor]] | . == sort' "$T_OUT")" "true"
# The findings of one file, anchor and lane are one item.
{
  fnd F-0000000000d1 phpstan method.notFound src/B.php 4 error current analysis
  fnd F-0000000000d2 phpstan x.y src/B.php 4 error current analysis "" "Another message."
  fnd F-0000000000d3 phpstan function.deprecated src/B.php 4 error current hard user_roles
} | jq -s 'map(.anchor = "M\\B::run")' | mkf "$T_TMP/g.json"
t_run "$T_SH" "$CL" --findings "$T_TMP/g.json" --json
assert_eq "one file and anchor: one ai-free item with two findings, one ai-templated item" \
  "$(jq -c '[.items[] | [.lane, (.finding_ids | length), .recipes]]' "$T_OUT")" '[["ai-templated",1,["dep.user-roles"]],["ai-free",2,[]]]'
# core_min above the floor; the overlay.
jq '.recipes |= map(if .id == "sig.hook-entity-operation" then .applies_when.core_min = "11.3" else . end)' "$T_REPO/config/recipes.json" > "$T_TMP/r.json"
t_run "$T_SH" "$CL" --findings "$T_TMP/f.json" --recipes "$T_TMP/r.json" --core-floor 10.3 --json
assert_eq "core_min 11.3 above the floor 10.3: the codemod is not applied" "$(lane F-000000000002)" "ai-templated|sig.hook-entity-operation|the recipe's conditions do not hold|open"
t_run "$T_SH" "$CL" --findings "$T_TMP/f.json" --recipes "$T_TMP/r.json" --json
assert_eq "  no floor known: not applied either" "$(lane F-000000000002 | cut -d'|' -f1)" "ai-templated"
printf '{"recipes": [{"id": "meta.services-arity", "lane": "ai-free", "kind": "template", "engine": "template", "matches": {"rule": "metadata:services-arity"}, "applies_when": {}, "template": {"why": "project rule"}, "postconditions": [{"type": "rescan"}], "version": "000000000000"}]}\n' > "$T_TMP/ov.json"
t_run "$T_SH" "$CL" --findings "$T_TMP/f.json" --overlay "$T_TMP/ov.json" --core-floor 10.3 --json
assert_eq "the project overlay replaces a recipe by id" "$(lane F-00000000000a)" "ai-free|meta.services-arity|-|open"
assert_eq "  and keeps the plugin's other recipes" "$(lane F-000000000002)" "codemod|sig.hook-entity-operation|-|open"
printf '{"recipes": [{"id": "x", "lane": "nowhere", "kind": "template", "version": "000000000000", "matches": {}, "template": {"why": "w"}}]}\n' > "$T_TMP/ov-bad.json"
t_run "$T_SH" "$CL" --findings "$T_TMP/f.json" --overlay "$T_TMP/ov-bad.json"
assert_eq "an overlay recipe in an unknown lane: exit 1" "$T_RC" "1"

# apply-recipes.sh on a Drupal root: the class-case codemod and a hook that no
# longer matches (its parameters over several lines).
R="$T_TMP/site"; S="$R/web/modules/custom/m"; mkdir -p "$R/web/core/lib" "$S"
printf '{"name":"x/site"}\n' > "$R/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$R/web/core/lib/Drupal.php"
cp -R "$T_REPO/tests/fixtures/recipes/safety.class-case/before/." "$S/"
cp "$T_REPO/tests/fixtures/recipes/sig.hook-entity-operation/multi-line/before/m.module" "$S/m.module"
printf 'name: M\ntype: module\ncore_version_requirement: ^10.3 || ^11\n' > "$S/m.info.yml"
SD="$(project_state_dir "$S")"
MSG="'Drupal\\m\\WidgetLookUp' does not match the real file 'src/WidgetLookup.php' (case differs): works on a case-insensitive filesystem, fatals on Linux."
{
  fnd F-0000000000c1 catalog port-safety:class-case m.services.yml 3 error current safety "" "$MSG"
  fnd F-0000000000c2 catalog signature:hook-entity-operation m.module 14 error current signature
} | jq -s . | mkf "$SD/findings.json"
t_run "$T_SH" "$CL" --subject "$S" --core-floor 10.3
assert_eq "classify --subject: worklist.json in the state dir, two open codemods" \
  "$T_RC|$(jq -c '[.items[] | select(.lane == "codemod" and .status == "open")] | length' "$SD/worklist.json")" "0|2"
t_run "$T_SH" "$AP" --subject "$S" --dry-run --json
assert_eq "apply-recipes --dry-run: would-apply and no-match, nothing written or logged" \
  "$T_RC|$(jq -c '[.applications[].status] | sort' "$T_OUT")|$(grep -c 'WidgetLookUp' "$S/m.services.yml")|$([[ -e "$SD/actions.jsonl" ]] && echo logged || echo none)" \
  '0|["no-match","would-apply"]|1|none'
t_run "$T_SH" "$AP" --subject "$S" --json
assert_eq "apply-recipes: the class-case codemod applied, the hook one gave no change" \
  "$T_RC|$(jq -c '[.applied, .not_applied]' "$T_OUT")|$(grep -c 'class: Drupal\\m\\WidgetLookup$' "$S/m.services.yml")" '0|[1,1]|1'
assert_eq "  two recipe-apply actions, with the hashes and the findings_hash" \
  "$(jq -s -c '[.[] | [.kind, .finding_id, .status, (.input_hash | test("^sha256:")), .findings_hash != null]] | sort' "$SD/actions.jsonl")" \
  '[["recipe-apply","F-0000000000c1","applied",true,true],["recipe-apply","F-0000000000c2","no-match",true,true]]'
lanew() { jq -r --arg id "$1" '.items[] | select(.finding_ids | index($id)) | "\(.lane)|\(.reason // "-")|\(.status)"' "$SD/worklist.json"; }
assert_eq "  the worklist: the applied codemod's item is applied" "$(lanew F-0000000000c1)" "codemod|-|applied"
assert_eq "  the codemod that gave no change: ai-templated" "$(lanew F-0000000000c2)" "ai-templated|the codemod gave no change|open"
t_run "$T_SH" "$AP" --subject "$S" --json
assert_eq "  a second run: nothing left to apply" "$T_RC|$(jq -c '.applications | length' "$T_OUT")" '0|0'
# A revert of the applied change: the codemod is open again (it is tried again).
cp "$T_REPO/tests/fixtures/recipes/safety.class-case/before/m.services.yml" "$S/m.services.yml"
t_run "$T_SH" "$CL" --subject "$S" --core-floor 10.3
assert_eq "the file no longer holds the codemod's output: open again" "$(lanew F-0000000000c1)" "codemod|-|open"
t_run "$T_SH" "$AP" --subject "$S" --json
assert_eq "  applied again" "$T_RC|$(jq -c '[.applications[] | [.finding_id, .status]]' "$T_OUT")" '0|[["F-0000000000c1","applied"]]'
# A re-extraction (another findings_hash) that still finds the class-case finding.
jq '.meta.findings_hash = "sha256:\("1" * 64)"' "$SD/findings.json" > "$T_TMP/f2.json" && cp "$T_TMP/f2.json" "$SD/findings.json"
t_run "$T_SH" "$CL" --subject "$S" --core-floor 10.3
assert_eq "after a re-extraction the applied codemod left its finding: ai-templated" \
  "$(lanew F-0000000000c1)" "ai-templated|the codemod did not clear the finding|open"

# A codemod that fails (info-yml with no plan of this module and no
# requirement): status error with the recipe's version, then ai-templated.
S2="$R/web/modules/custom/n"; cp -R "$T_REPO/tests/fixtures/recipes/meta.submodule-core-req/before" "$S2"
mv "$S2/m.info.yml" "$S2/n.info.yml"
DRUPILOT_PROJECT_DIR="$R" lock_set_json .upgrade_plan '{"subject": {"machine_name": "other"}, "range": {"constraint": "^11.2", "floor": "11.2"}, "source": {"major": 9}}' > /dev/null
SD2="$(project_state_dir "$S2")"
fnd F-0000000000e1 catalog metadata:submodule-core-req modules/m_extra/m_extra.info.yml 5 warning current metadata | jq -s . | mkf "$SD2/findings.json"
t_run "$T_SH" "$CL" --subject "$S2"
assert_eq "another module's plan in the lock: no floor, no era" "$(jq -c '[.floor, .items[0].era, .items[0].lane]' "$SD2/worklist.json")" '[null,null,"codemod"]'
t_run "$T_SH" "$AP" --subject "$S2" --json
assert_eq "apply-recipe.sh fails: an error action with the recipe's version" \
  "$T_RC|$(jq -s -c '[.[] | [.status, (.version | test("^[0-9a-f]{12}$"))]]' "$SD2/actions.jsonl")" '0|[["error",true]]'
assert_eq "  the finding falls to ai-templated" "$(jq -r '.items[0] | "\(.lane)|\(.reason)"' "$SD2/worklist.json")" "ai-templated|the codemod failed"

# S7 with stub extract.sh / normalize-findings.sh in a copy of the plugin.
P="$T_TMP/plugin"; mkdir -p "$P/scripts"; cp -R "$T_REPO/scripts/lib" "$T_REPO/scripts/ai" "$T_REPO/scripts/analysis" "$P/scripts/"; cp -R "$T_REPO/config" "$P/"
printf '#!/bin/sh\nexit "${STUB_EXTRACT_RC:-0}"\n' > "$P/scripts/ai/extract.sh"
printf '#!/bin/sh\ncp "$STUB_FINDINGS" "%s/findings.json"\n' "$SD" > "$P/scripts/ai/normalize-findings.sh"
cp "$T_REPO/tests/fixtures/recipes/safety.class-case/before/m.services.yml" "$S/m.services.yml"
: > "$SD/actions.jsonl"
{ fnd F-0000000000c1 catalog port-safety:class-case m.services.yml 3 error current safety "" "$MSG"; } | jq -s . | mkf "$SD/findings.json"
t_run env CLAUDE_PLUGIN_ROOT="$P" "$T_SH" "$P/scripts/ai/classify.sh" --subject "$S" --core-floor 10.3
jq '.meta.findings_hash = "sha256:\("2" * 64)"' "$SD/findings.json" > "$T_TMP/f-next.json"
t_run env CLAUDE_PLUGIN_ROOT="$P" STUB_FINDINGS="$T_TMP/f-next.json" "$T_SH" "$P/scripts/ai/apply-recipes.sh" --subject "$S" --reextract --json
assert_eq "S7: applied, re-extracted; the finding is still there: not-cleared, ai-templated" \
  "$T_RC|$(jq -c '[.reextracted, .applied]' "$T_OUT")|$(jq -s -c '[.[] | .status]' "$SD/actions.jsonl")|$(lanew F-0000000000c1)" \
  '0|[true,1]|["applied","not-cleared"]|ai-templated|the codemod did not clear the finding|open'
cp "$T_REPO/tests/fixtures/recipes/safety.class-case/before/m.services.yml" "$S/m.services.yml"; : > "$SD/actions.jsonl"
{ fnd F-0000000000c1 catalog port-safety:class-case m.services.yml 3 error current safety "" "$MSG"; } | jq -s . | mkf "$SD/findings.json"
t_run env CLAUDE_PLUGIN_ROOT="$P" "$T_SH" "$P/scripts/ai/classify.sh" --subject "$S" --core-floor 10.3
jq '.findings = [] | .meta.findings_hash = "sha256:\("3" * 64)"' "$SD/findings.json" > "$T_TMP/f-clear.json"
t_run env CLAUDE_PLUGIN_ROOT="$P" STUB_FINDINGS="$T_TMP/f-clear.json" "$T_SH" "$P/scripts/ai/apply-recipes.sh" --subject "$S" --reextract --json
assert_eq "S7: the finding is gone: no codemod item left, no not-cleared logged" \
  "$T_RC|$(jq -c '.counts.by_lane' "$SD/worklist.json")|$(jq -s -c '[.[].status]' "$SD/actions.jsonl")" '0|{}|["applied"]'
# S6 and S7 in two runs: the S7 run marks the earlier application not-cleared.
cp "$T_REPO/tests/fixtures/recipes/safety.class-case/before/m.services.yml" "$S/m.services.yml"; : > "$SD/actions.jsonl"
{ fnd F-0000000000c1 catalog port-safety:class-case m.services.yml 3 error current safety "" "$MSG"; } | jq -s . | mkf "$SD/findings.json"
t_run env CLAUDE_PLUGIN_ROOT="$P" "$T_SH" "$P/scripts/ai/classify.sh" --subject "$S" --core-floor 10.3
t_run env CLAUDE_PLUGIN_ROOT="$P" "$T_SH" "$P/scripts/ai/apply-recipes.sh" --subject "$S"
cp "$SD/findings.json" "$T_TMP/f-same.json"
t_run env CLAUDE_PLUGIN_ROOT="$P" STUB_FINDINGS="$T_TMP/f-same.json" "$T_SH" "$P/scripts/ai/apply-recipes.sh" --subject "$S" --reextract --json
assert_eq "S6 then S7 alone (same findings_hash): the earlier application is not-cleared, ai-templated" \
  "$T_RC|$(jq -c '.applications | length' "$T_OUT")|$(jq -s -c '[.[].status]' "$SD/actions.jsonl")|$(lanew F-0000000000c1)" \
  '0|0|["applied","not-cleared"]|ai-templated|the codemod did not clear the finding|open'
# S6, then a revert, then S7 alone: the reverted application is not in effect,
# so it is not marked not-cleared and the codemod is open again.
cp "$T_REPO/tests/fixtures/recipes/safety.class-case/before/m.services.yml" "$S/m.services.yml"; : > "$SD/actions.jsonl"
{ fnd F-0000000000c1 catalog port-safety:class-case m.services.yml 3 error current safety "" "$MSG"; } | jq -s . | mkf "$SD/findings.json"
t_run env CLAUDE_PLUGIN_ROOT="$P" "$T_SH" "$P/scripts/ai/classify.sh" --subject "$S" --core-floor 10.3
t_run env CLAUDE_PLUGIN_ROOT="$P" "$T_SH" "$P/scripts/ai/apply-recipes.sh" --subject "$S"
cp "$T_REPO/tests/fixtures/recipes/safety.class-case/before/m.services.yml" "$S/m.services.yml"
cp "$SD/findings.json" "$T_TMP/f-rev.json"
t_run env CLAUDE_PLUGIN_ROOT="$P" STUB_FINDINGS="$T_TMP/f-rev.json" "$T_SH" "$P/scripts/ai/apply-recipes.sh" --subject "$S" --reextract --json
assert_eq "S6, a revert, then S7: no not-cleared for the reverted application; the codemod is open again" \
  "$T_RC|$(jq -s -c '[.[].status]' "$SD/actions.jsonl")|$(lanew F-0000000000c1)" '0|["applied"]|codemod|-|open'
t_run env CLAUDE_PLUGIN_ROOT="$P" STUB_EXTRACT_RC=3 STUB_FINDINGS="$T_TMP/f-clear.json" "$T_SH" "$P/scripts/ai/apply-recipes.sh" --subject "$S" --reextract
assert_eq "S7: the re-extraction gives no verdict: exit 3" "$T_RC" "3"
# The overlay's version of a codemod is the one applied and logged.
cp "$T_REPO/tests/fixtures/recipes/safety.class-case/before/m.services.yml" "$S/m.services.yml"; : > "$SD/actions.jsonl"
mkdir -p "$R/.drupilot"; jq '{recipes: [.recipes[] | select(.id == "safety.class-case") | .version = "0000000000aa"]}' "$T_REPO/config/recipes.json" > "$R/.drupilot/recipes.json"
{ fnd F-0000000000c1 catalog port-safety:class-case m.services.yml 3 error current safety "" "$MSG"; } | jq -s . | mkf "$SD/findings.json"
t_run "$T_SH" "$CL" --subject "$S" --core-floor 10.3
t_run "$T_SH" "$AP" --subject "$S" --json
assert_eq "the project overlay's recipe is the one applied (its version logged)" \
  "$T_RC|$(jq -s -c '[.[] | [.status, .version]]' "$SD/actions.jsonl")|$(lanew F-0000000000c1)" '0|[["applied","0000000000aa"]]|codemod|-|applied'
rm -f "$R/.drupilot/recipes.json"

# Two codemods on one file: both stay in effect.
cp "$T_REPO/tests/fixtures/recipes/safety.class-case/two-lines/before/m.services.yml" "$S/m.services.yml"; : > "$SD/actions.jsonl"
{ fnd F-0000000000f1 catalog port-safety:class-case m.services.yml 3 error current safety "" "$MSG"
  fnd F-0000000000f2 catalog port-safety:class-case m.services.yml 6 error current safety "" "$MSG"; } | jq -s . | mkf "$SD/findings.json"
t_run "$T_SH" "$CL" --subject "$S" --core-floor 10.3
t_run "$T_SH" "$AP" --subject "$S" --json
assert_eq "two codemods on one file: both applied and both items applied" \
  "$T_RC|$(jq -c '[.applications[].status]' "$T_OUT")|$(lanew F-0000000000f1)|$(lanew F-0000000000f2)" '0|["applied","applied"]|codemod|-|applied|codemod|-|applied'
jq '.items |= map(.status = "open")' "$SD/worklist.json" > "$T_TMP/w.json" && cp "$T_TMP/w.json" "$SD/worklist.json"
t_run "$T_SH" "$AP" --subject "$S" --json
assert_eq "  a worklist left open (an interrupted run): the applications in effect are not run again" "$T_RC|$(jq -c '.applications | length' "$T_OUT")" '0|0'
# A new recipe version (here through the overlay) is tried again.
mkdir -p "$R/.drupilot"; jq '{recipes: [.recipes[] | select(.id == "safety.class-case") | .version = "0000000000bb"]}' "$T_REPO/config/recipes.json" > "$R/.drupilot/recipes.json"
t_run "$T_SH" "$CL" --subject "$S" --core-floor 10.3
t_run "$T_SH" "$AP" --subject "$S" --json
assert_eq "a new recipe version: tried again (no stale skip)" "$T_RC|$(jq -c '[.applications[] | .status] | length' "$T_OUT")" '0|2'
rm -f "$R/.drupilot/recipes.json"
# An overlay recipe without a version or a kind is refused.
printf '{"recipes": [{"id": "x", "lane": "codemod", "kind": "codemod", "engine": "ere-replace", "matches": {"rule": "port-safety:x"}, "template": {"why": "w"}}]}\n' > "$T_TMP/ov-nov.json"
t_run "$T_SH" "$CL" --findings "$T_TMP/f.json" --overlay "$T_TMP/ov-nov.json"
assert_eq "an overlay recipe without a version: exit 1" "$T_RC" "1"
printf '{"recipes": [{"id": "x", "lane": "codemod", "kind": "template", "version": "000000000000", "matches": {"rule": "port-safety:x"}, "template": {"why": "w"}}]}\n' > "$T_TMP/ov-kind.json"
t_run "$T_SH" "$CL" --findings "$T_TMP/f.json" --overlay "$T_TMP/ov-kind.json"
assert_eq "  in the codemod lane without a codemod kind: exit 1" "$T_RC" "1"
printf '{"recipes": [{"id": "x", "lane": "ai-free", "kind": "template", "version": "000000000000", "matches": {"rule": "port-safety:x"}, "template": {}}]}\n' > "$T_TMP/ov-why.json"
t_run "$T_SH" "$CL" --findings "$T_TMP/f.json" --overlay "$T_TMP/ov-why.json"
assert_eq "  without template.why: exit 1" "$T_RC" "1"
printf '{"recipes": [{"id": "x", "lane": "ai-free", "kind": "template", "version": "v2", "matches": {"rule": "port-safety:x"}, "template": {"why": "w"}}]}\n' > "$T_TMP/ov-ver.json"
t_run "$T_SH" "$CL" --findings "$T_TMP/f.json" --overlay "$T_TMP/ov-ver.json"
assert_eq "  a version that is not 12 hex digits: exit 1" "$T_RC" "1"
printf '{"recipes": [{"id": "x", "lane": "ai-free", "kind": "template", "version": "000000000000", "matches": {"message_ere": "foo("}, "template": {"why": "w"}}]}\n' > "$T_TMP/ov-re.json"
t_run "$T_SH" "$CL" --findings "$T_TMP/f.json" --overlay "$T_TMP/ov-re.json"
assert_eq "  a message_ere that does not compile: exit 1" "$T_RC" "1"
printf '{"recipes": [{"id": "x", "lane": "ai-free", "kind": "template", "version": "000000000000", "matches": {"rule": "port-safety:x"}, "applies_when": {"file_ere": "[a-"}, "template": {"why": "w"}}]}\n' > "$T_TMP/ov-fre.json"
t_run "$T_SH" "$CL" --findings "$T_TMP/f.json" --overlay "$T_TMP/ov-fre.json"
assert_eq "  a file_ere that does not compile: exit 1" "$T_RC" "1"
# --findings mode reads no file: an applied action counts as in effect.
t_run "$T_SH" "$CL" --findings "$SD/findings.json" --actions "$SD/actions.jsonl" --core-floor 10.3 --json
assert_eq "--findings with --actions: the applied items are applied" "$(jq -c '[.items[] | .status] | unique' "$T_OUT")" '["applied"]'
# A truncated last line of the log loses only that line.
printf '{"kind": "recipe-apply", "finding_id": "F-0000000000f1", "sta' >> "$SD/actions.jsonl"
t_run "$T_SH" "$CL" --subject "$S" --core-floor 10.3
assert_eq "a truncated line in actions.jsonl: the other records still count" "$T_RC|$(lanew F-0000000000f2)" '0|codemod|-|applied'
# "tests/" is a directory, not a name ending in "tests".
{ fnd F-0000000000a1 phpstan method.notFound mytests/X.php 3 error current analysis; } | jq -s . | mkf "$T_TMP/ft.json"
t_run "$T_SH" "$CL" --findings "$T_TMP/ft.json" --json
assert_eq "mytests/ is not a tests directory: ai-free" "$(jq -c '[.items[].lane]' "$T_OUT")" '["ai-free"]'

# Usage errors.
t_run "$T_SH" "$CL" --findings "$T_TMP/nope.json"
assert_eq "classify: no findings.json: exit 1" "$T_RC" "1"
printf '{"recipes": 1}\n' > "$T_TMP/bad.json"
t_run "$T_SH" "$CL" --findings "$T_TMP/f.json" --overlay "$T_TMP/bad.json"
assert_eq "classify: an overlay that is not a recipe catalog: exit 1" "$T_RC" "1"
t_run "$T_SH" "$CL" --findings "$T_TMP/f.json" --core-floor 11
assert_eq "classify: a floor that is not MAJOR.MINOR: exit 1" "$T_RC" "1"
mkdir -p "$T_TMP/empty"
t_run "$T_SH" "$AP" --subject "$T_TMP/empty"
assert_eq "apply-recipes: no worklist: exit 1" "$T_RC" "1"
t_run "$T_SH" "$AP" --subject "$S" --bogus
assert_eq "apply-recipes: an unknown flag: exit 1" "$T_RC" "1"
t_done
