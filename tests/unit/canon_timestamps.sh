#!/usr/bin/env bash
# Timestamps of hashed artifacts live only under a top-level "meta" (T-M4-02,
# AR-13, DET-2, 05 G9): negative_controls_summary (last-test.json's
# negative_controls) carries no time; its controls' times are
# negative_controls_times, which last-test.json keeps under meta. A
# last-test.json with meta and digest_algo validates against its schema, and
# one recorded by 0.9 (controls with "at", no meta) still does.
# rector-rules.json's meta: tests/unit/rector_compat_pass.sh.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

S="$T_TMP/mod"; mkdir -p "$S"; printf 'name: m\ntype: module\n' > "$S/mod.info.yml"
D="$(subject_digest "$S")"
mkdir -p "$(project_state_dir "$S")"
jq -n --arg d "$D" '[
  {test: "testA", type: "unit", label: null, mutation: {kind: "revert-to"}, verdict: "effective",
   subject_digest: $d, digest_algo: 2, at: "2026-10-05T10:00:00Z"},
  {test: "testB", type: "kernel", label: "x", mutation: null, verdict: "ineffective",
   subject_digest: "old", at: "2026-10-05T11:00:00Z"}]' > "$(negative_controls_file "$S")"
SUM="$(negative_controls_summary "$S")"
no_ts() { jq -r 'del(.meta) | [.. | strings | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))] | length'; }
assert_eq "the summary: no timestamp" "$(printf '%s' "$SUM" | no_ts)" "0"
assert_eq "... no at key" "$(printf '%s' "$SUM" | jq -c '[.controls[] | has("at")]')" "[false,false]"
assert_eq "... the rest unchanged" \
  "$(printf '%s' "$SUM" | jq -c '[.total, .effective, .ineffective, .stale, [.controls[] | [.test, .verdict, .mutation, .stale]]]')" \
  '[2,1,1,1,[["testA","effective","revert-to",false],["testB","ineffective",null,true]]]'
assert_eq "the times, in the controls' order" "$(negative_controls_times "$S")" \
  '[{"test":"testA","type":"unit","label":null,"at":"2026-10-05T10:00:00Z"},{"test":"testB","type":"kernel","label":"x","at":"2026-10-05T11:00:00Z"}]'
mkdir -p "$T_TMP/none"
assert_eq "no controls: null and null" "$(negative_controls_summary "$T_TMP/none")|$(negative_controls_times "$T_TMP/none")" "null|null"

# last-test.json: the 1.0 shape and the 0.9 one both validate.
JQV="$(cat "$T_REPO/scripts/dev/jsonschema.jq")
. as \$doc | \$schema[0] as \$root | \$doc | chk(\$root; \$root; \"\$\")"
viol() { jq -r --slurpfile schema "$T_REPO/schemas/last-test.schema.json" "$JQV" "$1" 2>&1 | grep -c . || true; }
SAMPLE="$T_REPO/tests/baseline/v0.9.0/samples/last-test.json"
jq --argjson nc "$SUM" --argjson t "$(negative_controls_times "$S")" \
  '.negative_controls = $nc | .digest_algo = 2 | .meta = {negative_controls: $t}' "$SAMPLE" > "$T_TMP/lt10.json"
assert_eq "a 1.0 last-test.json validates" "$(viol "$T_TMP/lt10.json")" "0"
assert_eq "... and has no timestamp outside meta but recorded_at" \
  "$(jq 'del(.recorded_at, .baseline.taken_at)' "$T_TMP/lt10.json" | no_ts)" "0"
jq '.negative_controls = {total: 1, effective: 1, ineffective: 0, error: 0, stale: 0,
    controls: [{test: "t", type: "unit", label: null, verdict: "effective", at: "2026-01-01T00:00:00Z", mutation: null, stale: false}]}' \
  "$SAMPLE" > "$T_TMP/lt09.json"
assert_eq "a 0.9 last-test.json (controls with at) still validates" "$(viol "$T_TMP/lt09.json")" "0"
jq '.meta = {negative_controls: "x"}' "$SAMPLE" > "$T_TMP/ltbad.json"
assert_eq "a malformed meta does not" "$([[ "$(viol "$T_TMP/ltbad.json")" -gt 0 ]] && echo invalid)" "invalid"
t_done
