#!/usr/bin/env bash
# extract.sh (T-M4-05, ADR 0022) with stub analysis scripts in a copy of the
# plugin: every report is kept canonical as raw/<NN>-<stage>-<tool>.json
# (sorted keys, the root stripped from its paths, its own timestamps moved
# under meta), a tool that prints no JSON gets an error record, the anchors of
# every (file, line) the reports name in a PHP file (Rector's hunks included)
# are asked of anchor.php once (a stub php here), {"unavailable": true}
# without PHP, the index names each tool's exit code, Rector's or PHPStan's
# exit 3 is the script's, and only the stage's previous raw files are
# replaced. Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

P="$T_TMP/plugin"; mkdir -p "$P/scripts/ai" "$P/scripts/analysis" "$P/scripts/php"
cp -R "$T_REPO/scripts/lib" "$P/scripts/"; cp -R "$T_REPO/config" "$P/"
cp "$T_REPO/scripts/ai/extract.sh" "$P/scripts/ai/"; cp "$T_REPO/scripts/php/"*.php "$P/scripts/php/"
R="$T_TMP/site"; S=web/modules/custom/m
mkdir -p "$R/web/core/lib" "$R/$S/src"
printf '{"name":"x/site"}\n' > "$R/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$R/web/core/lib/Drupal.php"
printf 'name: M\ntype: module\ncore_version_requirement: ^11\n' > "$R/$S/m.info.yml"

# stub NAME -> scripts/analysis/NAME.sh prints $R/out.NAME (a report the test
# writes) and exits with $R/rc.NAME (default 0), wherever extract.sh runs it.
stub() {
  printf '#!/bin/sh\ncat "%s/out.%s"\nexit "$(cat "%s/rc.%s" 2>/dev/null || echo 0)"\n' "$R" "$1" "$R" "$1" > "$P/scripts/analysis/$1.sh"
}
for t in run-rector run-phpstan run-phpcs check-port-safety scan-signature-changes lint-extension-metadata; do stub "$t"; done
jq -n --arg s "$S" '{status: "ok", tool: "rector",
  file_diffs: [{file: ($s + "/src/A.php"), diff: "@@ -10,3 +10,3 @@\n ctx\n-a\n+b\n", applied_rectors: ["Rector\\Foo"]}]}' > "$R/out.run-rector"
jq -n --arg s "$R/$S" '{totals: {errors: 0, file_errors: 2}, files: {($s + "/src/A.php"): {messages: [{message: "Boom", line: 12}]},
  ($s + "/m.module"): {messages: [{message: "Bang", line: 3}]}}}' > "$R/out.run-phpstan"
jq -n --arg s "$S" '{totals: {errors: 1}, files: {($s + "/src/A.php"): {messages: [{source: "X.Y", message: "Style", line: 12}]}}}' > "$R/out.run-phpcs"
printf '%s\n' '{"findings":[{"check":"di","file":"src/A.php","line":20,"message":"m"}],"ok":false}' > "$R/out.check-port-safety"
printf '%s\n' '{"findings":[],"ok":true}' > "$R/out.scan-signature-changes"
printf '%s\n' '{"zeta":1,"alpha":2,"generated_at":"2026-01-01T00:00:00Z","findings":[{"check":"c","file":"m.info.yml","line":2,"message":"x"}]}' > "$R/out.lint-extension-metadata"
# A stub php: anchor.php's answer is "A::f<line>" for every request.
STUBS="$T_TMP/stubs"; mkdir -p "$STUBS"
printf '#!/bin/sh\njq -c "[.[] | . + {anchor: (\\"A::f\\" + (.line | tostring))}]"\n' > "$STUBS/php"; chmod +x "$STUBS/php"

ex() { t_run env CLAUDE_PLUGIN_ROOT="$P" PATH="$STUBS:$PATH" "$T_SH" "$P/scripts/ai/extract.sh" "$@"; }
RAW="$(project_state_path "$R/$S")/raw"
ex --subject "$R/$S" --json
assert_eq "exit 0; the index on STDOUT" "$T_RC|$(jq -c '[.stage, .subject, .target_major]' "$T_OUT")" \
  '0|["assess",{"machine_name":"m","path":"web/modules/custom/m"},11]'
assert_eq "  each tool's file and exit code" "$(jq -c '[.tools[] | [.tool, .file, .exit_code]]' "$T_OUT")" \
  '[["rector","04-assess-rector.json",0],["phpstan","04-assess-phpstan.json",0],["phpcs","04-assess-phpcs.json",0],["port-safety","04-assess-port-safety.json",0],["signatures","04-assess-signatures.json",0],["metadata","04-assess-metadata.json",0]]'
assert_eq "the raw files of stage assess (NN = its place in config/pipeline.json)" \
  "$(cd "$RAW" && printf '%s ' *.json)" \
  "04-assess-anchors.json 04-assess-index.json 04-assess-metadata.json 04-assess-phpcs.json 04-assess-phpstan.json 04-assess-port-safety.json 04-assess-rector.json 04-assess-signatures.json "
assert_eq "a report's paths are relative to the Drupal root" \
  "$(jq -c '.files | keys' "$RAW/04-assess-phpstan.json")" '["web/modules/custom/m/m.module","web/modules/custom/m/src/A.php"]'
assert_eq "its keys are sorted, its own timestamp moved under meta" \
  "$(jq -c 'keys_unsorted' "$RAW/04-assess-metadata.json")|$(jq -c '.meta' "$RAW/04-assess-metadata.json")" \
  '["alpha","findings","meta","zeta"]|{"generated_at":"2026-01-01T00:00:00Z"}'
assert_eq "the anchors: every (file, line) of a PHP file, once, sorted (Rector's hunk at its first changed line)" \
  "$(jq -c '[.[] | [.file, .line, .anchor]]' "$RAW/04-assess-anchors.json")" \
  '[["web/modules/custom/m/m.module",3,"A::f3"],["web/modules/custom/m/src/A.php",11,"A::f11"],["web/modules/custom/m/src/A.php",12,"A::f12"],["web/modules/custom/m/src/A.php",20,"A::f20"]]'
assert_eq "  the runtime is staged at the root" "$([[ -f "$R/.drupilot/runtime/anchor.php" ]] && echo yes)" "yes"

# Two runs of the same tree: the same bytes outside meta.
for f in "$RAW"/*.json; do canon_json_hashable < "$f"; done > "$T_TMP/run1"
ex --subject "$R/$S"
for f in "$RAW"/*.json; do canon_json_hashable < "$f"; done > "$T_TMP/run2"
assert_file_eq "a second run: the same raw files outside meta" "$T_TMP/run2" "$T_TMP/run1"
assert_no_stdout "  without --json, nothing on STDOUT"

# No PHP: the anchors are unavailable.
NOPHP="$(t_path_without php)"
t_run env CLAUDE_PLUGIN_ROOT="$P" PATH="$NOPHP" "$T_SH" "$P/scripts/ai/extract.sh" --subject "$R/$S"
assert_eq "no PHP: exit 0, anchors unavailable, with a warning" \
  "$T_RC|$(jq -c . "$RAW/04-assess-anchors.json")|$(grep -c 'No PHP to compute anchors' "$T_ERR" || true)" '0|{"unavailable":true}|1'

# A tool that prints no JSON; Rector's exit 3.
printf 'not json\n' > "$R/out.scan-signature-changes"; printf '2' > "$R/rc.scan-signature-changes"
printf '3' > "$R/rc.run-rector"
ex --subject "$R/$S" --json
assert_eq "Rector exit 3: extract exit 3, every report still written" \
  "$T_RC|$(jq -c '[.tools[] | .exit_code]' "$T_OUT")|$(find "$RAW" -name '04-assess-*.json' | grep -c . || true)" '3|[3,0,0,0,2,0]|8'
assert_eq "  no JSON from a tool: an error record with its exit code" \
  "$(jq -c . "$RAW/04-assess-signatures.json")" '{"error":"the tool printed no JSON report","exit_code":2}'
rm -f "$R/rc.run-rector"; printf '3' > "$R/rc.run-phpstan"
ex --subject "$R/$S"
assert_eq "PHPStan exit 3: extract exit 3" "$T_RC" "3"
rm -f "$R/rc.run-phpstan"; printf '1' > "$R/rc.run-phpstan"
ex --subject "$R/$S"
assert_eq "PHPStan exit 1 (errors found): exit 0" "$T_RC" "0"

# Another stage: its own NN; the assess files stay; a stage's old files go.
printf '{}\n' > "$RAW/04-assess-stale.json"
ex --subject "$R/$S" --stage validate
assert_eq "--stage validate: its own files, the assess ones kept" \
  "$T_RC|$(find "$RAW" -name '10-validate-*.json' | grep -c . || true)|$(find "$RAW" -name '04-assess-*.json' | grep -c . || true)" '0|8|9'
ex --subject "$R/$S"
assert_eq "  only the stage's tool files are replaced: another file is left alone" "$([[ -e "$RAW/04-assess-stale.json" ]] && echo kept || echo removed)" "kept"
rm -f "$RAW/04-assess-stale.json"

# The stage's raw files from another NN (the stage moved in pipeline.json) go
# too; a stage whose id merely starts with another's is left alone.
printf '{}\n' > "$RAW/02-assess-rector.json"; printf '{}\n' > "$RAW/02-assess-x-rector.json"
ex --subject "$R/$S"
assert_eq "an old NN of the stage is removed, another stage's file kept" \
  "$([[ -e "$RAW/02-assess-rector.json" ]] && echo kept || echo removed)|$([[ -e "$RAW/02-assess-x-rector.json" ]] && echo kept || echo removed)" "removed|kept"

# A PHPStan error in a trait: its key names the class context; the anchor is
# asked for the trait's file.
jq -n --arg s "$R/$S" '{totals: {errors: 0, file_errors: 1}, files: {($s + "/src/T.php (in context of class M\\A)"): {messages: [{message: "Boom", line: 7}]}}}' > "$R/out.run-phpstan"
ex --subject "$R/$S"
assert_eq "a trait error: the anchor request names the trait's file" \
  "$(jq -c '[.[] | select(.line == 7) | .file]' "$RAW/04-assess-anchors.json")" '["web/modules/custom/m/src/T.php"]'

# Rector gave no report at all (exit 2, no JSON): no verdict, exit 3.
printf 'not json\n' > "$R/out.run-rector"; printf '2' > "$R/rc.run-rector"
ex --subject "$R/$S"
assert_eq "Rector printed no report: exit 3" "$T_RC" "3"
rm -f "$R/rc.run-rector"
jq -n '{status: "error", tool: "rector", errors: [{pass: 1, exit_code: 1, message: "boom"}], file_diffs: []}' > "$R/out.run-rector"
ex --subject "$R/$S"
assert_eq "Rector's report says error (exit 0): exit 3" "$T_RC" "3"

# The index's target major comes from the Drupal root's settings, not the caller's.
printf '{"DRUPILOT_TARGET_MAJOR": "12"}\n' > "$R/.drupilot.json"
jq -n --arg s "$S" '{status: "ok", tool: "rector", file_diffs: []}' > "$R/out.run-rector"
ex --subject "$R/$S" --json
assert_eq "the target major of the root's .drupilot.json" "$(jq -c '.target_major' "$T_OUT")" "12"
rm -f "$R/.drupilot.json"

# Usage errors.
ex --subject "$R/$S" --stage nope
assert_eq "an unknown stage: exit 1" "$T_RC" "1"
ex
assert_eq "no --subject: exit 1" "$T_RC" "1"
mkdir -p "$T_TMP/loose"
ex --subject "$T_TMP/loose"
assert_eq "no Drupal root: exit 2" "$T_RC" "2"
ex --subject "$R/$S" --bogus
assert_eq "an unknown flag: exit 1" "$T_RC" "1"
t_done
