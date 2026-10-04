#!/usr/bin/env bash
# scripts/dev/data-check.sh, the `data` gate (T-M2-01), on a scratch copy of
# config/ and schemas/: the shipped data passes; an unverified node a hard
# gate reads fails (a minor, a removed extension behind a $ref, a PHP
# version), and so does a version value without its source (the two roadmap
# "done when" faults), an unresolved $ref, a pattern matched only before a
# trailing newline, an announced or unverified blocking catalog entry, a removed-no-rule rule that does not cite php.net, a broken forbidden
# route, a minor of the wrong major and a missing core file. An unverified
# advisory note (namespace_moves) is allowed.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
r="$T_TMP/tree"; mkdir -p "$r"
cp -R "$T_REPO/config" "$T_REPO/schemas" "$r/"
# dc -> "<exit>|<check>: <detail>" of the first failing check.
dc() {
  local o rc=0
  o="$("$T_SH" "$T_REPO/scripts/dev/data-check.sh" --root "$r" --json 2>/dev/null)" || rc=$?
  printf '%s|%s' "$rc" "$(printf '%s' "$o" | jq -r '[.checks[] | select(.status != "pass") | "\(.check): \(.detail)"][0] // ""' 2>/dev/null)"
}
# edit FILE FILTER: apply a jq filter to a data file of the copy (backed up once).
edit() { [[ -f "$r/config/$1.bak" ]] || cp "$r/config/$1" "$r/config/$1.bak"; jq "$2" "$r/config/$1.bak" > "$r/config/$1"; }
undo() { mv "$r/config/$1.bak" "$r/config/$1"; }

assert_eq "the shipped data passes" "$(dc)" "0|"
edit targets/11.json '.minors["11.3"].verified = false'
assert_match "an unverified minor (php_supported_for reads it) fails" "$(dc)" '^1\|hard-gate: \$\.minors\.11\.3: feeds a hard gate but is not verified'
edit targets/11.json '.minors["11.4"] |= del(.src)'
assert_match "a version cell without src fails" "$(dc)" '^1\|schema: \$\.minors\.11\.4: matches no anyOf branch'
edit targets/11.json '.minors["11.4"].src = ""'
assert_match "an empty src is no source" "$(dc)" '^1\|'
edit targets/11.json '.minors["11.4"].php_src = null'
assert_match "a PHP support list without php_src fails" "$(dc)" '^1\|provenance: minors\.11\.4: PHP support list without php_src'
edit targets/11.json '.namespace_moves[0].verified = false'
assert_eq "an unverified advisory note passes" "$(dc)" "0|"
edit targets/11.json '.minors["12.0"] = .minors["11.4"]'
assert_match "a minor of another major fails" "$(dc)" '^1\|coherence: minor 12\.0 is not of major 11'
undo targets/11.json

edit targets/12.json '.upgrade_from_min.verified = false'
assert_match "an unverified upgrade floor fails" "$(dc)" '^1\|hard-gate: \$\.upgrade_from_min'
edit targets/12.json '.removed_libraries[0].verified = false'
assert_match "an unverified removed library fails" "$(dc)" '^1\|hard-gate: \$\.removed_libraries\[0\]'
edit targets/12.json '.removed_extensions[0].verified = false'
assert_match "an unverified removed extension (a \$ref next to the annotation) fails" "$(dc)" '^1\|hard-gate: \$\.removed_extensions\[0\]'
edit targets/12.json '.as_of = "2026-10-04\n"'
assert_match "a value that matches a pattern only before a trailing newline fails" "$(dc)" '^1\|schema: \$\.as_of: .* does not match'
undo targets/12.json
edit php/versions.json '.versions["8.5"].verified = false'
assert_match "an unverified PHP version (its core floor drives php_supported_for) fails" "$(dc)" '^1\|hard-gate: \$\.versions\.8\.5'
undo php/versions.json
cp "$r/schemas/target.schema.json" "$T_TMP/target.schema.json"
jq '.properties.as_of = {"$ref": "#/$defs/no_such_def"}' "$T_TMP/target.schema.json" > "$r/schemas/target.schema.json"
assert_match "a \$ref that does not resolve fails" "$(dc)" '^1\|schema-refs: properties\.as_of: unresolved \$ref #/\$defs/no_such_def'
jq '.properties.eol.properties.date.anyOf[1]["$ref"] = "#/$defs/no_such_date"' "$T_TMP/target.schema.json" > "$r/schemas/target.schema.json"
assert_match "... also inside an anyOf branch no value reaches" "$(dc)" '^1\|schema-refs: properties\.eol\.properties\.date\.anyOf\.1: unresolved'
cp "$T_TMP/target.schema.json" "$r/schemas/target.schema.json"
# The hard-gate walker on a synthetic schema: the annotation on a matching
# anyOf branch counts (inline or next to a $ref), a branch the value does not
# match is not walked, and a node annotated twice is reported once.
cat > "$T_TMP/s1.json" <<'JSON'
{"type":"object","properties":{"a":{"anyOf":[{"type":"null"},{"x-drupilot-hard-gate":true,"$ref":"#/$defs/g"}]},"b":{"anyOf":[{"type":"null"},{"x-drupilot-hard-gate":true,"type":"object"}]},"c":{"anyOf":[{"type":"null"},{"$ref":"#/$defs/ga"}]},"d":{"x-drupilot-hard-gate":true,"anyOf":[{"$ref":"#/$defs/ga"}]}},"$defs":{"g":{"type":"object"},"ga":{"x-drupilot-hard-gate":true,"type":"object"}}}
JSON
assert_eq "hard(): matching branches only, annotations on branches read, no duplicate" \
  "$(printf '%s' '{"a":{"verified":false},"b":{"verified":false},"c":null,"d":{"verified":true}}' \
     | jq -c --slurpfile s "$T_TMP/s1.json" "$(cat "$T_REPO/scripts/dev/jsonschema.jq") . as \$d | \$s[0] as \$r | [[\$d | hard(\$r; \$r; \"\$\")] | unique_by(.path)[] | .path]")" \
  '["$.a","$.b","$.d"]'

edit php/rules.json '(.rules[] | select(.id == "removed-each") | .src) = "02-F9"'
assert_match "a verified removed-no-rule rule must cite php.net" "$(dc)" '^1\|coherence: removed-each: a verified removed-no-rule rule must cite php\.net'
edit php/rules.json '(.rules[] | select(.id == "p84-implicit-nullable") | .deprecated_in) = null'
assert_match "a rule with neither deprecated_in nor removed_in fails" "$(dc)" '^1\|schema: \$\.rules\[0\]: matches no anyOf branch'
undo php/rules.json

edit paths/graph.json '.forbidden[0].route = ["7-11"]'
assert_match "a forbidden route that does not reach its target fails" "$(dc)" '^1\|coherence: forbidden 7->12: its route does not go from 7 to 12'
undo paths/graph.json

mkdir -p "$r/config/catalog"
jq '.entries[0].verified = false' "$T_REPO/schemas/examples/catalog.example.json" > "$r/config/catalog/example.json"
assert_match "an unverified blocking catalog entry fails" "$(dc)" '^1\|hard-gate: entry core-backbone: blocking but not verified'
cp "$T_REPO/schemas/examples/catalog.example.json" "$r/config/catalog/example.json"
assert_eq "a valid catalog passes" "$(dc)" "0|"
rm -rf "$r/config/catalog"

mv "$r/config/php/versions.json" "$T_TMP/versions.json"
assert_match "a missing core data file fails" "$(dc)" '^1\|schema: missing'
mv "$T_TMP/versions.json" "$r/config/php/versions.json"
assert_eq "back to green" "$(dc)" "0|"
t_done
