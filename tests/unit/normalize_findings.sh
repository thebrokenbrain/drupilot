#!/usr/bin/env bash
# normalize-findings.sh (T-M4-05, AR-10, ADR 0022) on synthetic raw reports of
# every tool: one Rector finding per rule and hunk, PHPStan deprecations
# classified (soft = next-major under report, current under fix; hard and the
# target major), untyped rules from the message's hash, "on line N" dropped,
# PHPCS occurrences, catalog findings, a non-PHP file anchored {file}, the
# same symbol at the same anchor merged (sources[] in precedence order), the
# id's formula, the order, a line shift that keeps every id, anchors
# unavailable, a Rector report without diffs (the other tools' findings stay),
# the meta (raw hashes outside each raw file's meta, findings_hash), the
# --subject/--out modes and the usage errors. Docker-free, PHP-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
NF="$T_REPO/scripts/ai/normalize-findings.sh"
SP=web/modules/custom/m

# mkraw DIR SHIFT -> the raw files of stage assess, every line moved by SHIFT.
mkraw() {
  local d="$1" s="$2"; mkdir -p "$d"
  jq -n --arg sp "$SP" '{stage: "assess", subject: {machine_name: "m", path: $sp}, target_major: 11, tools: []}' > "$d/04-assess-index.json"
  jq -n --arg sp "$SP" --argjson s "$s" '{status: "ok", runner: {runner: "ddev", php_version: "8.3.30", tool_version: "2.2.0"},
    file_diffs: [{file: ($sp + "/src/A.php"),
      diff: "@@ -\(10 + $s),4 +\(10 + $s),4 @@\n ctx\n-old\n+new\n ctx\n@@ -\(30 + $s),3 +\(30 + $s),3 @@\n-x\n+y\n z\n",
      applied_rectors: ["Rector\\A\\FooRector", "Rector\\B\\BarRector"]}]}' > "$d/04-assess-rector.json"
  jq -n --arg sp "$SP" --argjson s "$s" '{totals: {errors: 0, file_errors: 4}, files: {($sp + "/src/A.php"): {errors: 4, messages: [
    {message: "Call to deprecated function user_load_by_mail():\nin drupal:11.4.0 and is removed from drupal:13.0.0.\n  Use X\n  instead.", identifier: "function.deprecated", line: (12 + $s)},
    {message: "Call to deprecated function user_roles():\nin drupal:10.2.0 and is removed from drupal:11.0.0. Use X instead.", identifier: "function.deprecated", line: (14 + $s)},
    {message: "Undefined variable: $x", line: (40 + $s)},
    {message: "Something is wrong on line \(99 + $s)  here.", identifier: "x.wrong", line: (41 + $s)}]}}}' > "$d/04-assess-phpstan.json"
  jq -n --arg sp "$SP" --argjson s "$s" '{totals: {errors: 0, warnings: 2, fixable: 0}, files: {($sp + "/src/A.php"): {messages: [
    {source: "Drupal.Commenting.X", message: "Missing comment", line: (52 + $s), type: "WARNING"},
    {source: "Drupal.Commenting.X", message: "Missing comment", line: (50 + $s), type: "WARNING"}]}}}' > "$d/04-assess-phpcs.json"
  jq -n --argjson s "$s" '{findings: [{id: "user-load", file: "src/A.php", line: (12 + $s), member: "user_load_by_mail", message: "user_load_by_mail() changes.", severity: "warn"}]}' > "$d/04-assess-signatures.json"
  jq -n --argjson s "$s" '{findings: [{check: "di-create", file: "src/A.php", line: (20 + $s), message: "create() passes the wrong service.", severity: "error"}]}' > "$d/04-assess-port-safety.json"
  jq -n --argjson s "$s" '{findings: [{check: "services-arity", file: "m.services.yml", line: (3 + $s), message: "Too many arguments.", severity: "warn"}], meta: {generated_at: "2026-01-01T00:00:00Z"}}' > "$d/04-assess-metadata.json"
  jq -n --arg sp "$SP" --argjson s "$s" '[[11, "run"], [12, "run"], [14, "run"], [20, "create"], [30, "other"], [40, "other"], [41, "other"], [50, "doc"], [52, "doc"]]
    | map({file: ($sp + "/src/A.php"), line: (.[0] + $s), anchor: ("M\\A::" + .[1])})' > "$d/04-assess-anchors.json"
}
nf() { t_run "$T_SH" "$NF" "$@"; }
j() { jq -c "$1" "$T_OUT" 2> /dev/null; }
R0="$T_TMP/raw0"; mkraw "$R0" 0

nf --raw-dir "$R0" --target-major 11 --soft-policy report --json
assert_eq "exit 0, schema 1, php anchors" "$T_RC|$(j '[.schema, .stage, .anchors]')" '0|[1,"assess","php"]'
assert_eq "  the subject and the target" "$(j '[.subject, .target]')" \
  '[{"machine_name":"m","path":"web/modules/custom/m"},{"major":11,"php_version":"8.3.30","runner":"ddev","soft_policy":"report"}]'
cp "$T_OUT" "$T_TMP/f0.json"
assert_eq "  12 findings: 4 Rector, 4 PHPStan (one merged with the signature), 2 PHPCS, 2 catalog" \
  "$(j '[.counts.total, .counts.current, .counts.next_major, .counts.by_tool]')" '[12,11,1,{"catalog":2,"phpcs":2,"phpstan":4,"rector":4}]'
assert_eq "Rector: one finding per applied rule and hunk, at the hunk's first changed line" \
  "$(j '[.findings[] | select(.tool == "rector") | [.line, .message, .anchor, .rule]] | sort')" \
  '[[11,"BarRector","M\\A::run","Rector\\B\\BarRector"],[11,"FooRector","M\\A::run","Rector\\A\\FooRector"],[30,"BarRector","M\\A::other","Rector\\B\\BarRector"],[30,"FooRector","M\\A::other","Rector\\A\\FooRector"]]'
assert_eq "a soft deprecation: next-major under report, merged with the signature finding on its symbol" \
  "$(j '[.findings[] | select(.symbol == "user_load_by_mail") | [.tool, .class, .scope, .file, [.sources[].tool]]]')" \
  '[["phpstan","soft","next-major","src/A.php",["phpstan","catalog"]]]'
assert_eq "a hard deprecation: current" "$(j '[.findings[] | select(.symbol == "user_roles") | [.class, .scope]]')" '[["hard","current"]]'
ut="phpstan:untyped:$(printf '%s' 'Undefined variable: $x' | sha256_hex | cut -c1-8)"
assert_eq "an untyped PHPStan error: its rule from the message's hash, class analysis" \
  "$(j '[.findings[] | select(.message == "Undefined variable: $x") | [.rule, .class]]')" "[[\"$ut\",\"analysis\"]]"
assert_eq "\"on line N\" and repeated blanks are dropped from a message" \
  "$(j '[.findings[] | select(.rule == "x.wrong") | .message]')" '["Something is wrong here."]'
assert_eq "PHPCS: two identical messages in one anchor are occurrences 0 and 1, by line" \
  "$(j '[.findings[] | select(.tool == "phpcs") | [.line, .occurrence, .severity, .class]] | sort')" '[[50,0,"warning","style"],[52,1,"warning","style"]]'
assert_eq "catalog: port-safety and metadata (a YAML file is anchored {file})" \
  "$(j '[.findings[] | select(.tool == "catalog") | [.rule, .file, .anchor, .severity, .class]] | sort')" \
  '[["metadata:services-arity","m.services.yml","{file}","warning","metadata"],["port-safety:di-create","src/A.php","M\\A::create","error","safety"]]'
SEP="$(printf '\037')"
id="F-$(printf '%s' "phpcs${SEP}Drupal.Commenting.X${SEP}src/A.php${SEP}M\\A::doc${SEP}${SEP}Missing comment${SEP}0" | sha256_hex | cut -c1-12)"
assert_eq "the id: F- + 12 hex of sha256(tool, rule, file, anchor, symbol, message, occurrence)" \
  "$(j '[.findings[] | select(.tool == "phpcs" and .occurrence == 0) | .id]')" "[\"$id\"]"
assert_eq "sorted by file, anchor and id" "$(j '[.findings[] | [.file, .anchor, .id]] | . == sort')" 'true'
assert_eq "every id is unique" "$(j '[.findings[].id] | length == (unique | length)')" 'true'
assert_eq "meta: the hash of each raw file and of the findings" \
  "$(j '[(.meta.raw | keys), (.meta.findings_hash | test("^sha256:[0-9a-f]{64}$"))]')" \
  '[["04-assess-anchors.json","04-assess-index.json","04-assess-metadata.json","04-assess-phpcs.json","04-assess-phpstan.json","04-assess-port-safety.json","04-assess-rector.json","04-assess-signatures.json"],true]'
assert_eq "  findings_hash is the hash of the document outside meta" \
  "$(j '.meta.findings_hash')" "\"$(jq 'del(.meta)' "$T_OUT" | canon_json_hashable | json_hash)\""

# valid FILE -> the violations of schemas/findings.schema.json (the jq validator of schema-check.sh).
valid() { jq -r --slurpfile schema "$T_REPO/schemas/findings.schema.json" \
  "$(cat "$T_REPO/scripts/dev/jsonschema.jq")"' . as $doc | $schema[0] as $root | $doc | chk($root; $root; "$")' "$1" 2>&1; }
assert_eq "the document validates against schemas/findings.schema.json" "$(valid "$T_TMP/f0.json")" ""

# Determinism: the same raw files give the same document outside meta.generated_at.
nf --raw-dir "$R0" --target-major 11 --soft-policy report --json
assert_eq "a second run: identical outside meta.generated_at" \
  "$(jq -S -c 'del(.meta.generated_at)' "$T_OUT" | sha256_hex)" "$(jq -S -c 'del(.meta.generated_at)' "$T_TMP/f0.json" | sha256_hex)"
jq '.meta.generated_at = "2030-01-01T00:00:00Z"' "$R0/04-assess-metadata.json" > "$T_TMP/m.json" && cp "$T_TMP/m.json" "$R0/04-assess-metadata.json"
nf --raw-dir "$R0" --target-major 11 --soft-policy report --json
assert_eq "  a raw file's own meta changes no hash" "$(j '.meta.raw')" "$(jq -c '.meta.raw' "$T_TMP/f0.json")"

# A line shift keeps every id.
R7="$T_TMP/raw7"; mkraw "$R7" 7
nf --raw-dir "$R7" --target-major 11 --soft-policy report --json
assert_eq "every line moved by 7: the same ids, the lines moved" \
  "$(j '[[.findings[].id], [.findings[] | select(.tool == "phpcs") | .line] | sort]')" \
  "$(jq -c '[[.findings[].id], [.findings[] | select(.tool == "phpcs") | .line + 7] | sort]' "$T_TMP/f0.json")"

# The soft policy and the target major.
nf --raw-dir "$R0" --target-major 11 --soft-policy fix --json
assert_eq "--soft-policy fix: the soft deprecation is current, its id unchanged" \
  "$(j '[.findings[] | select(.symbol == "user_load_by_mail") | [.scope, .id]]|.[0][0]')|$(j '.target.soft_policy')|$(j '[.findings[].id]')" \
  "\"current\"|\"fix\"|$(jq -c '[.findings[].id]' "$T_TMP/f0.json")"
nf --raw-dir "$R0" --target-major 13 --soft-policy report --json
assert_eq "target 13: user_load_by_mail (removed from 13.0.0) is hard" \
  "$(j '[.findings[] | select(.symbol == "user_load_by_mail") | [.class, .scope]]')|$(j '.target.major')" '[["hard","current"]]|13'

# Anchors unavailable (no PHP when extract.sh ran): every anchor is {file}.
RU="$T_TMP/rawu"; mkraw "$RU" 0; printf '{"unavailable": true}\n' > "$RU/04-assess-anchors.json"
nf --raw-dir "$RU" --target-major 11 --soft-policy report --json
assert_eq "anchors unavailable: every anchor {file}, recorded" \
  "$(j '[.anchors, ([.findings[].anchor] | unique)]')" '["unavailable",["{file}"]]'
assert_eq "  it validates too" "$(valid "$T_OUT")" ""

# A Rector report without diffs: the other tools' findings stay.
RN="$T_TMP/rawn"; mkraw "$RN" 0
jq '.file_diffs = []' "$RN/04-assess-rector.json" > "$T_TMP/r.json" && cp "$T_TMP/r.json" "$RN/04-assess-rector.json"
nf --raw-dir "$RN" --target-major 11 --soft-policy report --json
assert_eq "no Rector diff: the 8 other findings" "$(j '[.counts.total, .counts.by_tool]')" '[8,{"catalog":2,"phpcs":2,"phpstan":4}]'
jq '.file_diffs[0].diff = ""' "$R0/04-assess-rector.json" > "$RN/04-assess-rector.json"
nf --raw-dir "$RN" --target-major 11 --soft-policy report --json
assert_eq "a diff without hunks: one finding per rule, no line, anchored {file}" \
  "$(j '[.findings[] | select(.tool == "rector") | [.line, .anchor]]')" '[[null,"{file}"],[null,"{file}"]]'
# A missing raw file is no error.
rm -f "$RN/04-assess-phpcs.json"
nf --raw-dir "$RN" --target-major 11 --soft-policy report --json
assert_eq "no PHPCS report: exit 0, no PHPCS finding" "$T_RC|$(j '.counts.by_tool.phpcs // 0')" '0|0'

# --subject: reads its raw dir and writes findings.json to its state dir; --out.
SUB="$T_TMP/site/$SP"; mkdir -p "$SUB"
RS="$(project_state_path "$SUB")/raw"; mkdir -p "$RS"; cp "$R7"/*.json "$RS/"
nf --subject "$SUB" --target-major 11 --soft-policy report
assert_eq "--subject: findings.json in the subject's state dir, nothing on STDOUT" \
  "$T_RC|$(jq -c '[.findings[].id]' "$(project_state_dir "$SUB")/findings.json")|$(wc -c < "$T_OUT" | tr -d ' ')" \
  "0|$(jq -c '[.findings[].id]' "$T_TMP/f0.json")|0"
nf --raw-dir "$R0" --target-major 11 --soft-policy report --out "$T_TMP/out/f.json"
assert_eq "--out FILE" "$T_RC|$(jq -c '.counts.total' "$T_TMP/out/f.json")" '0|12'

# Usage errors.
nf --raw-dir "$T_TMP/nope"
assert_eq "a missing raw dir: exit 1" "$T_RC" "1"
nf --raw-dir "$R0" --stage upgrade
assert_eq "no raw index for the stage: exit 1" "$T_RC" "1"
nf --raw-dir "$R0" --soft-policy sometimes
assert_eq "an invalid soft policy: exit 1" "$T_RC" "1"
nf --raw-dir "$R0" --target-major eleven
assert_eq "an invalid target major: exit 1" "$T_RC" "1"
nf --bogus
assert_eq "an unknown flag: exit 1" "$T_RC" "1"
t_done
