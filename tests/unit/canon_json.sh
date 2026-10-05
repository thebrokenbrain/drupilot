#!/usr/bin/env bash
# Canonical JSON (T-M4-01, AR-13, DET-2): canon_json gives one byte form for
# the same document (keys sorted, two-space indent, LF line endings, CRLF
# inside strings made LF, independent of the locale), so a permuted input has
# the same json_hash; a change only under the top-level "meta" keeps the hash
# of the hashable form, and a change anywhere else changes it.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

A='{"b":1,"meta":{"generated_at":"2026-10-05T10:00:00Z"},"a":{"d":[3,1],"c":"x"}}'
B='{"a":{"c":"x","d":[3,1]},"meta":{"generated_at":"2026-10-06T11:00:00Z","host":"h"},"b":1}'
hash_of() { printf '%s' "$1" | canon_json | canon_json_hashable | json_hash; }
assert_eq "canon_json: keys sorted, two-space indent, LF-ended" "$(printf '%s' "$A" | canon_json)" \
  "$(printf '{\n  "a": {\n    "c": "x",\n    "d": [\n      3,\n      1\n    ]\n  },\n  "b": 1,\n  "meta": {\n    "generated_at": "2026-10-05T10:00:00Z"\n  }\n}')"
assert_eq "a permuted input: the same canonical bytes" \
  "$(printf '%s' '{"z":0,"a":{"c":"x","d":[3,1]}}' | canon_json | sha256_hex)" \
  "$(printf '%s' '{"a":{"d":[3,1],"c":"x"},"z":0}' | canon_json | sha256_hex)"
assert_match "json_hash of the hashable form" "$(hash_of "$A")" '^sha256:[0-9a-f]{64}$'
assert_eq "a permuted input with another meta: the same json_hash" "$(hash_of "$A")" "$(hash_of "$B")"
assert_eq "a change outside meta changes the hash" \
  "$([[ "$(hash_of "$A")" != "$(hash_of '{"b":2,"a":{"d":[3,1],"c":"x"}}')" ]] && echo changed)" "changed"
assert_eq "array order is data: [1,3] and [3,1] differ" \
  "$([[ "$(hash_of '{"d":[1,3]}')" != "$(hash_of '{"d":[3,1]}')" ]] && echo differ)" "differ"
assert_eq "CRLF inside a string becomes LF" \
  "$(printf '%s' '{"m":"a\r\nb"}' | canon_json | jq -r .m | od -An -c | tr -s ' ')" "$(printf 'a\nb\n' | od -An -c | tr -s ' ')"
assert_eq "canon_json is idempotent" "$(printf '%s' "$A" | canon_json | canon_json)" "$(printf '%s' "$A" | canon_json)"
assert_eq "the locale does not change the bytes" \
  "$(printf '%s' '{"é":1,"Z":2,"a":3,"_":4}' | LC_ALL=C canon_json)" \
  "$(printf '%s' '{"é":1,"Z":2,"a":3,"_":4}' | LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 canon_json 2> /dev/null)"
assert_eq "invalid JSON: nothing on stdout, still exit 0" \
  "$(printf '{"a":' | canon_json; echo "rc=$?")" "rc=0"
assert_eq "a valid document, then a broken one: nothing" "$(printf '{"a":1} {"b":' | canon_json; echo "rc=$?")" "rc=0"
assert_eq "a valid document, then a log line: nothing" "$(printf '{"a":1}\nDone.\n' | canon_json /tmp)" ""
assert_eq "two valid documents: both" "$(printf '{"b":1}{"a":2}' | canon_json | tr -d ' \n')" '{"b":1}{"a":2}'
assert_eq "canon_json_hashable of invalid JSON: nothing, exit 0" "$(printf '{"a":' | canon_json_hashable; echo "rc=$?")" "rc=0"

# A pretty-printed raw golden is already canonical: canon_json leaves its bytes.
for f in "$T_REPO"/tests/fixtures/legacy_widgets.golden/raw/*.json; do
  assert_eq "canon_json keeps the canonical $(basename "$f") byte for byte" \
    "$(canon_json < "$f" | sha256_hex)" "$(sha256_hex < "$f")"
done
t_done
