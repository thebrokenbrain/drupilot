#!/usr/bin/env bash
# manifest.sh (T-M4-10, AR-10, 01-R9, ADR 0027): the port manifest generated
# from the scripts' records.
# - the golden (tests/golden/manifest/legacy_widgets.json): the lab's
#   legacy_widgets port (its golden patch applied on a git repository of the
#   fixture), the findings and worklist goldens, a Rector record and a
#   decision, byte for byte outside meta; it validates against
#   schemas/port-manifest.schema.json, and a second run gives the same bytes;
# - the rationale is the model's only input: keyed by worklist item id (an
#   item the port resolved, kept in worklist-resolved.json by classify.sh,
#   included) or by a manual edit's path (its why), an
#   unknown id refused, the previous rationale kept for the ids still there;
# - a codemod in effect is listed and is not a manual edit;
# - port-report.sh renders the lane x status table and the rationale; the
#   state snapshot reads the time from meta;
# - php_window from the php-target and php-lint reports, and its section
#   in port-report.md;
# - version_bump: the assessment's for a port whose final requirement is the
#   one it recommended, else core_version_bump from the requirement before
#   the port (assess.json or the provisional one, else the info.yml at the
#   port's base; unknown: null); a refactor is always a major;
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

# Scans of other sources than the module now are refused.
IDX="$SD/raw/04-assess-index.json"; cp "$IDX" "$T_TMP/idx.keep"
jq '.subject_digest = "0000"' "$T_TMP/idx.keep" > "$IDX"
mf --no-write
assert_eq "an extraction of other sources (its subject_digest): refused, exit 1" "$T_RC" "1"
assert_match "  it says to extract the ported tree" "$(t_err)" "extract on the ported tree first"
jq --arg d "$(subject_digest "$S")" '.subject_digest = $d' "$T_TMP/idx.keep" > "$IDX"
mf --no-write --json
assert_eq "  of the module as it is: accepted" "$T_RC" "0"
cp "$T_TMP/idx.keep" "$IDX"
# A tool that printed no report is never embedded as a clean scan.
cp "$SD/raw/04-assess-port-safety.json" "$T_TMP/ps.keep"
printf '{"error": "the tool printed no JSON report", "exit_code": 2}\n' > "$SD/raw/04-assess-port-safety.json"
mf --no-write --json
assert_eq "a port-safety crash placeholder: no port_safety section (never 0 errors)" "$T_RC|$(jq -c 'has("port_safety")' "$T_OUT")" "0|false"
cp "$T_TMP/ps.keep" "$SD/raw/04-assess-port-safety.json"
# The local-environment residue make-patch.sh --local leaves out, and a
# non-ASCII name.
mkdir -p "$S/vendor/x" "$S/node_modules/y" "$S/.ddev"
printf 'x\n' > "$S/vendor/x/a.php"; printf 'x\n' > "$S/node_modules/y/i.js"; printf 'x\n' > "$S/.ddev/config.yaml"; printf 'x\n' > "$S/se"$'\303\261'"al.txt"
mf --no-write --json
assert_eq "residue left out, a non-ASCII name kept as it is" "$(jq -c '[.files[].path]' "$T_OUT")" \
  '["legacy_widgets.info.yml","modules/legacy_widgets_extra/legacy_widgets_extra.info.yml","señal.txt","src/Form/WidgetImportForm.php"]'
rm -rf "$S/vendor" "$S/node_modules" "$S/.ddev" "$S/se"$'\303\261'"al.txt"
# A missing rationale file is no rationale this time.
mf --no-write --rationale "$T_TMP/nope.json" --json
assert_eq "a --rationale file that does not exist: a warning, the earlier rationale kept" "$T_RC|$(jq -c '.rationale | length' "$T_OUT")" "0|1"

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

# The PHP window: the stage's php-target and php-lint reports and the human
# items of its constructs; port-report.sh renders them.
jq -n '{tool: "php-target", floor: "8.1", target: "8.4", findings: [{id: "removed-each", class: "removed-blocking", file: "legacy_widgets.module", line: 3}]}' > "$SD/raw/04-assess-php-target.json"
jq -n '{tool: "php-lint", window: ["8.1", "8.4"], status: "pass", legs: [
  {php: "8.1", image: "php:8.1-cli", status: "pass", errors: 0, deprecations: 0, messages: []},
  {php: "8.4", image: "php:8.4-cli", status: "pass", errors: 0, deprecations: 1,
   messages: [{kind: "deprecated", file: "src/A.php", line: 5, message: "Implicitly marking parameter $x as nullable is deprecated"}]}]}' > "$SD/raw/04-assess-php-lint.json"
cp "$SD/findings.json" "$T_TMP/f.keep"; cp "$SD/worklist.json" "$T_TMP/w.keep"
jq '.findings += [{id: "F-0000000000p1", tool: "catalog", rule: "php-removed:removed-each", file: "legacy_widgets.module", line: 3,
      anchor: "{file}", symbol: null, message: "each() is removed in PHP 8.0", occurrence: 0, severity: "error", scope: "current",
      class: "php-target", sources: []}]' "$T_TMP/f.keep" > "$SD/findings.json"
jq '.items += [{id: "W-0000000000p1", lane: "human", file: "legacy_widgets.module", anchor: "{file}", finding_ids: ["F-0000000000p1"],
      recipes: [], blocking: true, reason: "removed-in-target-php", status: "open"}]' "$T_TMP/w.keep" > "$SD/worklist.json"
mf --no-write --json
assert_eq "php_window: the bounds, the legs, the deprecations and the item" \
  "$(jq -c '.php_window | [.floor, .target, .window, [.lint.legs[] | [.php, .status]], (.lint.deprecations | length), [.items[] | [.id, .blocking, .reason, .findings[0].rule]]]' "$T_OUT")" \
  '["8.1","8.4",["8.1","8.4"],[["8.1","pass"],["8.4","pass"]],1,[["W-0000000000p1",true,"removed-in-target-php","php-removed:removed-each"]]]'
assert_eq "  it validates against the schema" "$(valid "$T_OUT")" ""
cp "$T_OUT" "$T_TMP/pw-manifest.json"
t_run "$T_SH" "$T_REPO/scripts/analysis/port-report.sh" --subject "$S" --manifest "$T_TMP/pw-manifest.json"
REP="$(cat "$(t_out)" 2> /dev/null || true)"
assert_match "port-report.sh: the PHP window section" "$REP" '### PHP window'
assert_match "  the legs" "$REP" '\| 8\.4 \| pass \| 0 \| 1 \|'
assert_match "  the blocking item with its finding" "$REP" '\*\*blocking\*\* `legacy_widgets.module` \(removed-in-target-php; open\)'
assert_match "  the compile-time deprecation" "$REP" 'PHP 8\.4 `src/A.php:5`'
rm -f "$SD/raw/04-assess-php-target.json" "$SD/raw/04-assess-php-lint.json"
cp "$T_TMP/f.keep" "$SD/findings.json"; cp "$T_TMP/w.keep" "$SD/worklist.json"
mf --no-write --json
assert_eq "  no PHP-window report: no php_window" "$(jq -c 'has("php_window")' "$T_OUT")" "false"

# The SemVer bump of the final requirement (lab L-1.0-D9: a port that drops
# Drupal 8 and 9 said "n/a" when the final range was not the assessment's).
mf --no-write --json
assert_eq "version_bump without assess.json: from the info.yml at the port's base (^10 -> ^10 || ^11: minor)" \
  "$(jq -r .version_bump "$T_OUT")" "minor"
jq -n '{current_core_version_requirement: "^8 || ^9", recommended_core_version_requirement: "^10 || ^11", version_bump: "major"}' > "$SD/assess.json"
mf --no-write --json
assert_eq "  the final range is the recommended one: the assessment's own bump" "$(jq -r .version_bump "$T_OUT")" "major"
jq '.recommended_core_version_requirement = "^10.3 || ^11" | .version_bump = "minor"' "$SD/assess.json" > "$T_TMP/as.json" && mv "$T_TMP/as.json" "$SD/assess.json"
mf --no-write --json
assert_eq "  another final range: recomputed from the requirement before the port (^8 || ^9 -> ^10 || ^11: major)" \
  "$(jq -r .version_bump "$T_OUT")" "major"
jq '.current_core_version_requirement = "^10"' "$SD/assess.json" > "$T_TMP/as.json" && mv "$T_TMP/as.json" "$SD/assess.json"
mf --no-write --phase refactor --json
assert_eq "  a refactor is a BC break: major" "$(jq -r .version_bump "$T_OUT")" "major"
jq '.recommended_core_version_requirement = "^10 || ^11" | .version_bump = "minor"' "$SD/assess.json" > "$T_TMP/as.json" && mv "$T_TMP/as.json" "$SD/assess.json"
mf --no-write --phase refactor --json
assert_eq "  a refactor that ends on the recommended range is still a major (the assessment's bump is the port's)" \
  "$(jq -r .version_bump "$T_OUT")" "major"
jq '.current_core_version_requirement = "^8 || ^9"' "$SD/assess.json" > "$SD/assess-provisional.json" && rm -f "$SD/assess.json"
mf --no-write --json
assert_eq "  the provisional assessment counts too (^8 || ^9 -> ^10 || ^11: major, where the git base says minor)" \
  "$(jq -r .version_bump "$T_OUT")" "major"
rm -f "$SD/assess-provisional.json"
mv "$S/.git" "$T_TMP/git.keep"
mf --no-write --json
assert_eq "  no assessment and no git base: the requirement before the port is unknown, so is the bump" \
  "$(jq -c .version_bump "$T_OUT")" "null"
mf --no-write --phase refactor --json
assert_eq "  a refactor is a major even then" "$(jq -r .version_bump "$T_OUT")" "major"
mv "$T_TMP/git.keep" "$S/.git"

# The rationale of what the port resolved (lab L-PC): the model writes it
# against the worklist it saw, and the extraction after its fix drops the
# item; a manual edit's why is keyed by its path.
cp "$SD/worklist.json" "$T_TMP/w.keep"
jq '.items += [{id: "W-00000000000a", lane: "ai-free", file: "src/Form/WidgetImportForm.php", anchor: "{file}",
      finding_ids: [], recipes: [], blocking: true, reason: null, status: "open"}]' "$T_TMP/w.keep" > "$SD/worklist.json"
cp "$SD/findings.json" "$T_TMP/f0.keep"; jq '.stage = "validate"' "$T_TMP/f0.keep" > "$SD/findings.json"
t_run "$T_SH" "$T_REPO/scripts/ai/classify.sh" --subject "$S" --core-floor 10.0
cp "$T_TMP/f0.keep" "$SD/findings.json"
assert_eq "classify.sh: the item the new worklist drops is kept in worklist-resolved.json" \
  "$T_RC|$(jq -c '[.items[] | [.id, .lane, .file]]' "$(worklist_resolved_file "$S")")" \
  '0|[["W-00000000000a","ai-free","src/Form/WidgetImportForm.php"]]'
assert_eq "  the new worklist is the findings' own" "$(jq -c '[.items[].id] | index("W-00000000000a")' "$SD/worklist.json")" "null"
jq -n '{"W-00000000000a": "Fixed by hand: the callback became a static method.",
        "legacy_widgets.info.yml": "core_version_requirement raised to the recommended range."}' > "$T_TMP/rres.json"
mf --rationale "$T_TMP/rres.json" --json
assert_eq "a rationale naming a resolved item and a manual edit: accepted" "$T_RC" "0"
assert_eq "  the resolved item, with its why, under worklist.resolved" \
  "$(jq -c '[.worklist.resolved[] | [.id, .lane, .file, .rationale]]' "$T_OUT")" \
  '[["W-00000000000a","ai-free","src/Form/WidgetImportForm.php","Fixed by hand: the callback became a static method."]]'
assert_eq "  the manual edit's why" "$(jq -r '.manual_edits[] | select(.edit == "legacy_widgets.info.yml") | .why' "$T_OUT")" \
  "core_version_requirement raised to the recommended range."
assert_eq "  it validates against the schema" "$(valid "$T_OUT")" ""
t_run "$T_SH" "$T_REPO/scripts/analysis/port-report.sh" --subject "$S" --manifest "$SD/port-manifest.json"
REP="$(cat "$(t_out)" 2> /dev/null || true)"
assert_match "port-report.sh: the resolved item's why" "$REP" '`W-00000000000a` \(resolved by the port; ai-free, `src/Form/WidgetImportForm.php`\): Fixed by hand'
assert_match "  the manual edit's why" "$REP" '- legacy_widgets.info.yml — _why:_ core_version_requirement raised'
mf --json
assert_eq "  a later run without --rationale keeps both" \
  "$(jq -c '[(.worklist.resolved | length), (.manual_edits[] | select(.edit == "legacy_widgets.info.yml") | .why != null)]' "$T_OUT")" '[1,true]'
printf '{"src/Nope.php": "a file the port never changed"}\n' > "$T_TMP/rnope.json"
mf --rationale "$T_TMP/rnope.json"
assert_eq "  a file the port did not change: refused, exit 1" "$T_RC" "1"
assert_match "  it names it" "$(t_err)" "src/Nope.php"
# A file a tool changed too: kept, and shown under "Also explained".
printf '{"src/Form/WidgetImportForm.php": "After Rector, the callback was made static by hand."}\n' > "$T_TMP/rrector.json"
mf --rationale "$T_TMP/rrector.json" --json
assert_eq "a file Rector changed too: accepted, not a manual edit" \
  "$T_RC|$(jq -c '[.manual_edits[].edit] | index("src/Form/WidgetImportForm.php")' "$T_OUT")" "0|null"
t_run "$T_SH" "$T_REPO/scripts/analysis/port-report.sh" --subject "$S" --manifest "$SD/port-manifest.json"
REP="$(cat "$(t_out)" 2> /dev/null || true)"
assert_match "  port-report.sh shows its why under Also explained" "$REP" '^_Also explained:_$'
assert_match "  (the line)" "$REP" '^- `src/Form/WidgetImportForm.php` \(changed by Rector, the attribute pass or a codemod too\) — _why:_ After Rector'
# A why given before its file changed is flagged; a reopened item loses its why.
assert_eq "  the manifest keeps the hash of each explained file" "$(jq -c '.rationale_hashes | keys' "$SD/port-manifest.json")" \
  '["legacy_widgets.info.yml","src/Form/WidgetImportForm.php"]'
cp "$S/legacy_widgets.info.yml" "$T_TMP/info2.keep"; printf '# edited later\n' >> "$S/legacy_widgets.info.yml"
mf --json
assert_eq "a file changed since its why was given: the why is kept, flagged as given before the change" \
  "$(jq -c '[(.rationale | has("legacy_widgets.info.yml")), .rationale_stale]' "$T_OUT")" '[true,["legacy_widgets.info.yml"]]'
assert_eq "  it validates against the schema" "$(valid "$T_OUT")" ""
t_run "$T_SH" "$T_REPO/scripts/analysis/port-report.sh" --subject "$S" --manifest "$SD/port-manifest.json"
assert_match "  port-report.sh says so" "$(cat "$(t_out)" 2> /dev/null)" \
  '^- legacy_widgets.info.yml — _why:_ core_version_requirement raised to the recommended range\. _\(given before the file last changed\)_'
cp "$T_TMP/info2.keep" "$S/legacy_widgets.info.yml"
mf --json
assert_eq "  the file back as it was: not flagged" "$(jq -c '.rationale_stale' "$T_OUT")" "null"
jq '.items += [{id: "W-00000000000a", lane: "ai-free", file: "src/Form/WidgetImportForm.php", anchor: "{file}",
      finding_ids: [], recipes: [], blocking: true, reason: null, status: "open"}]' "$T_TMP/w.keep" > "$SD/worklist.json"
mf --json
assert_eq "  a resolved item open again (a revert): its why is dropped" \
  "$(jq -c '[(.rationale | has("W-00000000000a")), (.worklist | has("resolved"))]' "$T_OUT")" '[false,false]'
cp "$T_TMP/w.keep" "$SD/worklist.json"
# No git history: any file of the module may be named.
mv "$S/.git" "$T_TMP/git2.keep"
printf '{"legacy_widgets.info.yml": "Raised to the recommended range."}\n' > "$T_TMP/rnogit.json"
mf --rationale "$T_TMP/rnogit.json" --json
assert_eq "no git: a file of the module is accepted (manual edits unknown)" \
  "$T_RC|$(jq -c '[.manual_edits, .rationale["legacy_widgets.info.yml"]]' "$T_OUT")" '0|[null,"Raised to the recommended range."]'
t_run "$T_SH" "$T_REPO/scripts/analysis/port-report.sh" --subject "$S" --manifest "$SD/port-manifest.json"
assert_match "  port-report.sh shows it" "$(cat "$(t_out)" 2> /dev/null)" '- `legacy_widgets.info.yml` — _why:_ Raised to the recommended range\.'
mf --rationale "$T_TMP/rnope.json"
assert_eq "  a file that does not exist: refused, exit 1" "$T_RC" "1"
assert_match "  saying there is no git history" "$(t_err)" 'no git history.*src/Nope\.php'
mv "$T_TMP/git2.keep" "$S/.git"
# A new assessment starts a new port: the resolved record starts empty.
t_run "$T_SH" "$T_REPO/scripts/ai/classify.sh" --subject "$S" --core-floor 10.0
assert_eq "classify.sh at the assess stage: worklist-resolved.json emptied" \
  "$T_RC|$(jq -c '.items' "$(worklist_resolved_file "$S")")" '0|[]'
# The upgrade stage (a re-port without a new assessment) keeps only what it drops now.
printf '{"schema": 1, "items": [{"id": "W-0000000000bb", "lane": "ai-free", "file": "old.php", "anchor": "{file}", "reason": null, "stage": "validate"}]}\n' \
  > "$(worklist_resolved_file "$S")"
jq '.items += [{id: "W-0000000000cc", lane: "ai-free", file: "src/Form/WidgetImportForm.php", anchor: "{file}",
      finding_ids: [], recipes: [], blocking: true, reason: null, status: "open"}]' "$T_TMP/w.keep" > "$SD/worklist.json"
cp "$SD/findings.json" "$T_TMP/f1.keep"; jq '.stage = "upgrade"' "$T_TMP/f1.keep" > "$SD/findings.json"
t_run "$T_SH" "$T_REPO/scripts/ai/classify.sh" --subject "$S" --core-floor 10.0
cp "$T_TMP/f1.keep" "$SD/findings.json"
assert_eq "classify.sh at the upgrade stage: only the items it drops now" \
  "$T_RC|$(jq -c '[.items[].id]' "$(worklist_resolved_file "$S")")" '0|["W-0000000000cc"]'
cp "$T_TMP/w.keep" "$SD/worklist.json"

# deprecations_remaining counts the scan's deprecations PHPStan cannot see.
mf --no-write --json
N0="$(jq -r .deprecations_remaining "$T_OUT")"
cp "$SD/findings.json" "$T_TMP/f.keep"
jq '.findings += [{id: "F-0000000000d1", tool: "catalog", rule: "runtime-deprecation:entity-original-property", file: "legacy_widgets.module",
      line: 3, anchor: "{file}", symbol: "EntityBase::$original", message: "Getting the original property is deprecated", occurrence: 0,
      severity: "error", scope: "current", class: "hard",
      sources: [{tool: "catalog", rule: "runtime-deprecation:entity-original-property", line: 3},
                {tool: "catalog", rule: "runtime-deprecation:entity-original-property", line: 4}]}]' "$T_TMP/f.keep" > "$SD/findings.json"
mf --no-write --json
assert_eq "deprecations_remaining takes a hard runtime-deprecation finding, each of its occurrences" "$(jq -r .deprecations_remaining "$T_OUT")" "$((N0 + 2))"
cp "$T_TMP/f.keep" "$SD/findings.json"

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
# Training run 03 (like_dislike): the official pass changed nothing, the
# digests pass changed one file, and that rule was then rejected and its
# change reverted: the official count is 0 and the rule is rejected only.
jq -n '{tool: "run-rector", changed_files: 1, files: ["web/modules/custom/legacy_widgets/tests/src/FooTest.php"],
        official_files: [], digests_files: ["web/modules/custom/legacy_widgets/tests/src/FooTest.php"], digests_sha: "abc",
        rule_hits: {digests: {AddRunTestsInSeparateProcessesAttributeRector: 1}}, meta: {generated_at: "2026-01-01T00:00:00Z", subject: "x"}}' > "$SD/rector-rules.json"
jq -n '{schema: 1, decisions: [
  {at: "2026-01-01T00:00:02Z", by: "auto", digests_sha: "abc", input_hash: "h2", rule: "AddRunTestsInSeparateProcessesAttributeRector", verdict: "reject"},
  {at: "2026-01-01T00:00:01Z", by: "auto", digests_sha: "abc", input_hash: "h1", rule: "AddRunTestsInSeparateProcessesAttributeRector", verdict: "accept"},
  {at: "2026-01-01T00:00:01Z", by: "auto", digests_sha: "abc", input_hash: "h1", rule: "OtherRector", verdict: "reject"},
  {at: "2026-01-01T00:00:03Z", by: "developer", digests_sha: "abc", input_hash: "h3", rule: "OtherRector", verdict: "accept"}]}' > "$SD/digests-decisions.json"
mf --no-write --json
assert_eq "a digests-only change: the official pass changed 0 files; a rule rejected after it was applied is rejected only, one accepted after a rejection is not" \
  "$(jq -c '[.rector_official_files, .digests.applied, [.digests.rejected[].rule]]' "$T_OUT")" \
  '[0,[],["AddRunTestsInSeparateProcessesAttributeRector"]]'

t_done
