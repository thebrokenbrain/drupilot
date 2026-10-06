#!/usr/bin/env bash
# fixpoint.sh (T-M4-11, AR-16, 05-R9, DET-8): at the end of a stage, Rector,
# the codemods and the processed lanes (rector, rector-custom, codemod) have
# nothing left.
# - legacy_widgets after its port (the findings golden without its one Rector
#   change, the worklist computed from it): converged;
# - an injected non-convergent case lists the exact items: a Rector change, a
#   codemod that would still apply, an open item in a processed lane; a
#   digests rule the developer rejected never counts; the AI lanes are not
#   processed yet;
# - DRUPILOT_FIXPOINT: warn reports and exits 0, enforce exits 3, off skips;
#   a tool with no verdict never converges;
# - fixpoint.json and the run manifest (<state>/runs/<run_id>/), of which
#   DRUPILOT_RUNS_KEEP are kept;
# - the live path (extraction again, the codemods in dry-run) with stub tools.
# Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
FX="$T_REPO/scripts/analysis/fixpoint.sh"
CL="$T_REPO/scripts/ai/classify.sh"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/findings/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
S="$T_TMP/legacy_widgets"; cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$S"
SD="$(project_state_dir "$S")"

# legacy_widgets after its port: its one Rector change applied, nothing else
# for the deterministic lanes (the AI lanes stay open: not processed yet).
jq '.findings |= map(select(.tool != "rector")) | .stage = "validate"' "$T_REPO/tests/golden/findings/legacy_widgets/findings.json" > "$T_TMP/fp.json"
jq '.findings |= map(select(.class != "signature" and .class != "safety" and .class != "metadata"))' "$T_TMP/fp.json" > "$T_TMP/fp2.json"
t_run "$T_SH" "$CL" --findings "$T_TMP/fp2.json" --core-floor 10.0 --json
cp "$T_OUT" "$T_TMP/wp.json"
t_run "$T_SH" "$FX" --subject "$S" --findings "$T_TMP/fp2.json" --worklist "$T_TMP/wp.json" --json
assert_eq "legacy_widgets after its port: converged, exit 0" "$T_RC|$(jq -c '[.converged, .mode, (.rector | length), (.codemods | length), (.open_items | length)]' "$T_OUT")" '0|[true,"warn",0,0,0]'
assert_eq "  fixpoint.json in the state dir" "$(jq -c '.converged' "$SD/fixpoint.json")" "true"
valid() { jq -r --slurpfile schema "$T_REPO/schemas/$1.schema.json" \
  "$(cat "$T_REPO/scripts/dev/jsonschema.jq")"' . as $doc | $schema[0] as $root | $doc | chk($root; $root; "$")' "$2" 2>&1; }
assert_eq "  it validates against schemas/fixpoint.schema.json" "$(valid fixpoint "$SD/fixpoint.json")" ""
assert_eq "  the run manifest against schemas/run-manifest.schema.json" "$(valid run-manifest "$(ls "$SD"/runs/*/run-manifest.json)")" ""
assert_eq "  the AI lanes are not processed yet" "$(jq -c '.processed_lanes' "$T_OUT")" '["rector","rector-custom","codemod"]'
assert_eq "  one run recorded, with its input and output hashes" \
  "$(ls "$SD/runs" | wc -l | tr -d ' ')|$(jq -c '[.tool, .inputs.findings_hash != null, (.outputs.fixpoint_hash | test("^sha256:")), .outputs.converged]' "$SD"/runs/*/run-manifest.json)" \
  '1|["fixpoint",true,true,true]'

# An injected non-convergent case: the golden as extracted (its Rector change
# and both codemods still open).
F="$T_REPO/tests/golden/findings/legacy_widgets/findings.json"; W="$T_REPO/tests/golden/worklist/legacy_widgets.json"
t_run "$T_SH" "$FX" --subject "$S" --findings "$F" --worklist "$W" --json
assert_eq "not converged in warn mode: exit 0, the exact items listed" \
  "$T_RC|$(jq -c '[.converged, [.rector[].rule], [.open_items[] | [.lane, .file]]]' "$T_OUT")" \
  '0|[false,["Rector\\CodingStyle\\Rector\\FuncCall\\FunctionFirstClassCallableRector"],[["codemod","legacy_widgets.services.yml"],["codemod","modules/legacy_widgets_extra/legacy_widgets_extra.info.yml"],["rector","src/Form/WidgetImportForm.php"]]]'
assert_match "  the warning names them" "$(t_err)" "not converged: 1 Rector change\(s\), 3 open item\(s\) in a processed lane"
DRUPILOT_FIXPOINT=enforce t_run "$T_SH" "$FX" --subject "$S" --findings "$F" --worklist "$W"
assert_eq "enforce: exit 3" "$T_RC" "3"
DRUPILOT_FIXPOINT=off t_run "$T_SH" "$FX" --subject "$S" --findings "$F" --worklist "$W" --json
assert_eq "off: nothing runs, exit 0" "$T_RC|$(jq -c '[.mode, .converged]' "$T_OUT")" '0|["off",null]'
# A digests rule the developer rejected never counts.
jq '.findings += [.findings[] | select(.tool == "rector") | .id = "F-000000000099" | .rule = "ReplaceDigestsThingRector" | .anchor = "x"]' "$T_TMP/fp2.json" > "$T_TMP/fd.json"
printf '{"schema": 1, "decisions": [{"rule": "ReplaceDigestsThingRector", "digests_sha": "x", "input_hash": "y", "verdict": "reject", "by": "developer", "at": "z"}]}\n' > "$(digests_decisions_file "$S")"
t_run "$T_SH" "$FX" --subject "$S" --findings "$T_TMP/fd.json" --worklist "$T_TMP/wp.json" --json
assert_eq "a rejected digests rule still proposing its change: not counted" "$T_RC|$(jq -c '[.converged, (.rector | length)]' "$T_OUT")" '0|[true,0]'
rm -f "$(digests_decisions_file "$S")"
# A tool with no verdict never converges.
jq '.tools.phpstan = "failed"' "$T_TMP/fp2.json" > "$T_TMP/fnv.json"
DRUPILOT_FIXPOINT=enforce t_run "$T_SH" "$FX" --subject "$S" --findings "$T_TMP/fnv.json" --worklist "$T_TMP/wp.json" --json
assert_eq "PHPStan with no verdict: not converged (enforce: exit 3)" "$T_RC|$(jq -c '[.converged, .no_verdict]' "$T_OUT")" '3|[false,true]'

# DRUPILOT_RUNS_KEEP: the oldest runs go.
for _ in 1 2 3 4; do
  DRUPILOT_RUNS_KEEP=3 t_run "$T_SH" "$FX" --subject "$S" --findings "$T_TMP/fp2.json" --worklist "$T_TMP/wp.json"
done
assert_eq "DRUPILOT_RUNS_KEEP=3: three runs kept" "$(ls "$SD/runs" | wc -l | tr -d ' ')" "3"

# The live path, with stub tools in a copy of the plugin: the extraction runs
# again and the codemods run in dry-run.
P="$T_TMP/plugin"; mkdir -p "$P/scripts"; cp -R "$T_REPO/scripts/lib" "$T_REPO/scripts/ai" "$T_REPO/scripts/analysis" "$P/scripts/"; cp -R "$T_REPO/config" "$P/"
printf '#!/bin/sh\necho "$*" >> "%s/calls"\nexit "${STUB_EXTRACT_RC:-0}"\n' "$T_TMP" > "$P/scripts/ai/extract.sh"
printf '#!/bin/sh\ncp "%s" "%s/findings.json"\n' "$F" "$SD" > "$P/scripts/ai/normalize-findings.sh"
printf '#!/bin/sh\ncp "%s" "%s/worklist.json"\n' "$W" "$SD" > "$P/scripts/ai/classify.sh"
printf '#!/bin/sh\necho "{\\"applications\\": [{\\"item_id\\": \\"W-1\\", \\"recipe\\": \\"safety.class-case\\", \\"file\\": \\"legacy_widgets.services.yml\\", \\"status\\": \\"would-apply\\"}, {\\"item_id\\": \\"W-2\\", \\"recipe\\": \\"sig.x\\", \\"file\\": \\"m.module\\", \\"status\\": \\"no-match\\"}]}"\n' > "$P/scripts/ai/apply-recipes.sh"
t_run env CLAUDE_PLUGIN_ROOT="$P" "$T_SH" "$P/scripts/analysis/fixpoint.sh" --subject "$S" --json
assert_eq "live: extracted again at the validate stage, the codemod that would apply listed" \
  "$T_RC|$(grep -c -- '--stage validate' "$T_TMP/calls")|$(jq -c '[.converged, [.codemods[] | [.recipe, .file]]]' "$T_OUT")" \
  '0|1|[false,[["safety.class-case","legacy_widgets.services.yml"]]]'
t_run env CLAUDE_PLUGIN_ROOT="$P" STUB_EXTRACT_RC=3 "$T_SH" "$P/scripts/analysis/fixpoint.sh" --subject "$S" --stage refactor --json
assert_eq "  an extraction with no verdict (exit 3): not converged; --stage passed on" \
  "$T_RC|$(jq -c '[.converged, .no_verdict, .stage]' "$T_OUT")|$(grep -c -- '--stage refactor' "$T_TMP/calls")" '0|[false,true,"refactor"]|1'
t_run env CLAUDE_PLUGIN_ROOT="$P" STUB_EXTRACT_RC=2 "$T_SH" "$P/scripts/analysis/fixpoint.sh" --subject "$S"
assert_eq "  an extraction that fails: exit 1" "$T_RC" "1"

# Usage errors.
t_run "$T_SH" "$FX" --subject "$S" --findings "$F"
assert_eq "--findings without --worklist: exit 1" "$T_RC" "1"
t_run "$T_SH" "$FX" --subject "$S" --findings "$W" --worklist "$W"
assert_eq "a file that is not a findings.json: exit 1" "$T_RC" "1"
t_run "$T_SH" "$FX" --bogus
assert_eq "an unknown flag: exit 1" "$T_RC" "1"
t_done
