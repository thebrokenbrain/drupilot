#!/usr/bin/env bash
# manifest.sh (T-M4-10, AR-10, 01-R9, ADR 0027): the port manifest generated
# from the scripts' records.
# - the golden (tests/golden/manifest/legacy_widgets.json): the lab's
#   legacy_widgets port (its golden patch applied on a git repository of the
#   fixture), the findings and worklist goldens, a Rector record and a
#   decision, byte for byte outside meta; it validates against
#   schemas/port-manifest.schema.json, and a second run gives the same bytes;
# - the rationale is the model's only input: keyed by worklist item id, an
#   unknown id refused, the previous rationale kept for the ids still there;
# - a codemod in effect is listed and is not a manual edit;
# - port-report.sh renders the lane x status table and the rationale; the
#   state snapshot reads the time from meta;
# - the usage errors. Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
MF="$T_REPO/scripts/ai/manifest.sh"
G="$T_REPO/tests/golden/manifest"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$G/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
export GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z
valid() { jq -r --slurpfile schema "$T_REPO/schemas/port-manifest.schema.json" \
  "$(cat "$T_REPO/scripts/dev/jsonschema.jq")"' . as $doc | $schema[0] as $root | $doc | chk($root; $root; "$")' "$1" 2>&1; }

# The scenario: a Drupal root, the fixture in its own repository, the lab's
# golden port patch applied, the state of the assess stage.
R="$T_TMP/site"; S="$R/web/modules/custom/legacy_widgets"
mkdir -p "$R/web/core/lib" "$R/web/modules/custom"
printf '{"name":"x/site"}\n' > "$R/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$R/web/core/lib/Drupal.php"
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$S"
g() { git -C "$S" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
g init -q; g add -A; g commit -qm base
g apply "$T_REPO/tests/fixtures/legacy_widgets.golden/golden/port-to-drupal-11.patch"
SD="$(project_state_dir "$S")"
cp "$T_REPO/tests/golden/findings/legacy_widgets/findings.json" "$SD/findings.json"
mkdir -p "$SD/raw"; cp "$T_REPO/tests/golden/findings/legacy_widgets/raw/"* "$SD/raw/"
cp "$T_REPO/tests/golden/worklist/legacy_widgets.json" "$SD/worklist.json"
jq -n '{tool: "run-rector", changed_files: 1, files: ["web/modules/custom/legacy_widgets/src/Form/WidgetImportForm.php"], digests_sha: null,
        rule_hits: {official: {FunctionFirstClassCallableRector: 1}}, meta: {generated_at: "2026-01-01T00:00:00Z", subject: "x"}}' > "$SD/rector-rules.json"
t_run "$T_SH" "$T_REPO/scripts/analysis/log-decision.sh" --subject "$S" --kind behavior-change --what "The import form keeps its callback" --why "FAPI callbacks must stay serializable"
I1="$(jq -r '.items[0].id' "$SD/worklist.json")"; I2="$(jq -r '.items[1].id' "$SD/worklist.json")"
jq -n --arg id "$I1" '{($id): "Rector rewrote the callback; it stays an array callable."}' > "$T_TMP/r1.json"
mf() { t_run "$T_SH" "$MF" --subject "$S" "$@"; }

mf --rationale "$T_TMP/r1.json" --json
assert_eq "manifest.sh: exit 0" "$T_RC" "0"
jq 'del(.meta)' "$T_OUT" | canon_json > "$T_TMP/m.json"
assert_file_eq "  port-manifest.json, byte for byte outside meta" "$T_TMP/m.json" "$G/legacy_widgets.json"
assert_eq "  it validates against schemas/port-manifest.schema.json" "$(valid "$T_OUT")" ""
assert_file_eq "  the state dir holds the same document" "$SD/port-manifest.json" "$T_OUT"
assert_eq "  what it was built from" \
  "$(jq -c '[.files_changed, [.files[].path], [.manual_edits[].edit], .rector_official_files, .decisions.count, .d10_support, .worklist.by_lane_status.rector.open]' "$T_OUT")" \
  '[3,["legacy_widgets.info.yml","modules/legacy_widgets_extra/legacy_widgets_extra.info.yml","src/Form/WidgetImportForm.php"],["legacy_widgets.info.yml","modules/legacy_widgets_extra/legacy_widgets_extra.info.yml"],1,1,"declared-not-verified",1]'
mf --json
assert_eq "a second run without --rationale: the same document outside meta, the rationale kept" \
  "$(jq -c 'del(.meta)' "$T_OUT")" "$(jq -c . "$G/legacy_widgets.json")"

# The rationale: merged by id; an unknown id is refused.
jq -n --arg id "$I2" '{($id): "The second item."}' > "$T_TMP/r2.json"
mf --rationale "$T_TMP/r2.json" --json
assert_eq "a new rationale is merged with the previous one" "$(jq -c '.rationale | keys' "$T_OUT")" "$(jq -n -c --arg a "$I1" --arg b "$I2" '[$a, $b] | sort')"
assert_eq "  and shown on its item" "$(jq -r --arg id "$I2" '.worklist.items[] | select(.id == $id) | .rationale' "$T_OUT")" "The second item."
printf '{"W-000000000000": "nope"}\n' > "$T_TMP/rbad.json"
mf --rationale "$T_TMP/rbad.json"
assert_eq "an id the worklist does not have: exit 1" "$T_RC" "1"
assert_match "  it names it" "$(t_err)" "W-000000000000"
printf '["not", "an", "object"]\n' > "$T_TMP/rarr.json"
mf --rationale "$T_TMP/rarr.json"
assert_eq "a rationale that is not an object of texts: exit 1" "$T_RC" "1"
jq --arg id "$I2" '.items |= map(select(.id != $id))' "$T_REPO/tests/golden/worklist/legacy_widgets.json" > "$SD/worklist.json"
mf --json
assert_eq "an item gone from the worklist: its rationale is dropped" "$(jq -c '.rationale | keys' "$T_OUT")" "[\"$I1\"]"
cp "$T_REPO/tests/golden/worklist/legacy_widgets.json" "$SD/worklist.json"

# A codemod in effect: listed, not a manual edit.
jq -n -c --arg h "$(file_hash "$S/legacy_widgets.info.yml")" \
  '{kind: "recipe-apply", finding_id: "F-000000000001", recipe: "meta.x", version: "000000000001", status: "applied", file: "legacy_widgets.info.yml", input_hash: "sha256:x", output_hash: $h}' > "$SD/actions.jsonl"
mf --json
assert_eq "a codemod in effect: listed, and its file is not a manual edit" \
  "$(jq -c '[[.codemods[] | [.recipe, .file]], [.manual_edits[].edit], (.inputs.actions_hash | test("^sha256:"))]' "$T_OUT")" \
  '[[["meta.x","legacy_widgets.info.yml"]],["modules/legacy_widgets_extra/legacy_widgets_extra.info.yml"],true]'
cp "$S/legacy_widgets.info.yml" "$T_TMP/info.keep"; printf 'name: changed\n' >> "$S/legacy_widgets.info.yml"
mf --json
assert_eq "  its file changed since: no longer in effect" "$(jq -c '[(.codemods | length), (.manual_edits | length)]' "$T_OUT")" '[0,2]'
cp "$T_TMP/info.keep" "$S/legacy_widgets.info.yml"
: > "$SD/actions.jsonl"

# The attribute pass's record: its rules join rector_rules, its files are not
# manual edits.
jq -n '{tool: "attributes", changed_files: 1, files: ["web/modules/custom/legacy_widgets/legacy_widgets.info.yml"],
        rule_hits: {attributes: {AnnotationToAttributeRector: 1}}, meta: {generated_at: "x", subject: "y"}}' > "$SD/attributes-rules.json"
mf --no-write --json
assert_eq "the attribute pass: its rules in rector_rules, its files not manual edits" \
  "$(jq -c '[(.rector_rules | keys), [.manual_edits[].edit]]' "$T_OUT")" '[["attributes","official"],["modules/legacy_widgets_extra/legacy_widgets_extra.info.yml"]]'
rm -f "$SD/attributes-rules.json"

# --no-write; the report; the state snapshot.
cp "$SD/port-manifest.json" "$T_TMP/before.json"
mf --no-write --json
assert_eq "--no-write: printed, not written" "$T_RC|$(cmp -s "$SD/port-manifest.json" "$T_TMP/before.json" && echo kept)" "0|kept"
t_run "$T_SH" "$T_REPO/scripts/analysis/port-report.sh" --subject "$S" --manifest "$SD/port-manifest.json"
REP="$(cat "$(t_out)" 2> /dev/null || true)"
assert_match "port-report.sh: the lane x status table" "$REP" '\| `ai-free` \| 0 \| 12 \|'
assert_match "  the rationale" "$REP" "Rector rewrote the callback"
assert_eq "the state snapshot reads the manifest's time from meta" \
  "$(state_snapshot_json "$S" | jq -c --slurpfile m "$SD/port-manifest.json" '.port_at == $m[0].meta.generated_at')" "true"

# Usage errors.
mkdir -p "$T_TMP/empty"; printf 'name: E\ntype: module\n' > "$T_TMP/empty/empty.info.yml"
t_run "$T_SH" "$MF" --subject "$T_TMP/empty"
assert_eq "no findings.json: exit 1" "$T_RC" "1"
mf --phase other
assert_eq "a phase that is not port or refactor: exit 1" "$T_RC" "1"
mf --base no-such-ref
assert_eq "a base that does not exist: exit 1" "$T_RC" "1"
mf --bogus
assert_eq "an unknown flag: exit 1" "$T_RC" "1"
t_done
