#!/usr/bin/env bash
# scripts/dev/schema-check.sh (T-M1-08, T-M1-09) on a scratch copy, with the jq
# engine (the one every CI leg has): every 0.9 instance validates; a missing
# required key, an unexpected key under additionalProperties:false, a wrong
# enum value and a schema without an instance each fail. The check-jsonschema
# engine is checked the same way by hand (--mode docker), never here.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
r="$T_TMP/tree"; mkdir -p "$r/tests"
for d in scripts config hooks schemas .claude-plugin; do cp -R "$T_REPO/$d" "$r/"; done
cp -R "$T_REPO/tests/baseline" "$r/tests/"
mkdir -p "$r/tests/golden"; cp -R "$T_REPO/tests/golden/findings" "$T_REPO/tests/golden/worklist" "$r/tests/golden/"
S="$r/tests/baseline/v0.9.0/samples"
# sc -> "<exit>|<first failing check>" of schema-check.sh --mode jq.
sc() {
  local o rc=0
  o="$("$T_SH" "$r/scripts/dev/schema-check.sh" --mode jq --json 2>/dev/null)" || rc=$?
  printf '%s|%s' "$rc" "$(printf '%s' "$o" | jq -r '[.checks[] | select(.status != "pass") | "\(.schema): \(.detail)"][0] // ""' 2>/dev/null)"
}
assert_eq "every 0.9 instance validates (jq)" "$(sc)" "0|"

cp "$S/last-test.json" "$T_TMP/lt.bak"
jq 'del(.preservation)' "$T_TMP/lt.bak" > "$S/last-test.json"
assert_match "a missing required key fails" "$(sc)" '^1\|last-test\.schema\.json: \$: missing required key preservation'
jq '.preservation = "green"' "$T_TMP/lt.bak" > "$S/last-test.json"
assert_match "a value outside the enum fails" "$(sc)" '^1\|last-test\.schema\.json: \$\.preservation: "green" is not one of'
jq '.extra = 1' "$T_TMP/lt.bak" > "$S/last-test.json"
assert_match "an unexpected key under additionalProperties:false fails" "$(sc)" '^1\|last-test\.schema\.json: \$: unexpected key extra'
: > "$S/last-test.json"
assert_match "an empty instance fails (jq exits 0 on empty input)" "$(sc)" '^1\|last-test\.schema\.json: not exactly one JSON value'
cp "$T_TMP/lt.bak" "$S/last-test.json"
cp "$T_TMP/lt.bak" "$S/last-test.json"

cp "$S/drupilot-lock.json" "$T_TMP/lock.bak"
jq '.phpstan_level = "two"' "$T_TMP/lock.bak" > "$S/drupilot-lock.json"
assert_match "a wrong type fails" "$(sc)" '^1\|lock\.schema\.json: \$\.phpstan_level: string is not integer'
cp "$T_TMP/lock.bak" "$S/drupilot-lock.json"

printf '{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object"}\n' > "$r/schemas/orphan.schema.json"
assert_match "a schema with no instance fails" "$(sc)" '^1\|orphan\.schema\.json: no instance validates this schema'
rm -f "$r/schemas/orphan.schema.json"
assert_eq "back to green" "$(sc)" "0|"
t_done
