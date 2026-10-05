#!/usr/bin/env bash
# The canonical JSON and hashes of the upgrade plan (T-M3-03, AR-13, ADR
# 0017): canon_json_hashable sorts keys, compacts and drops only the top-level
# "meta"; json_hash / sha256_hex hash STDIN's bytes with sha256sum or shasum
# and print nothing without either; version_data_hash names every vendored
# data snapshot (the hash scripts/dev/golden.sh pins in golden.json).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

assert_eq "keys sorted, compact, meta dropped" \
  "$(printf '{"b":1,"meta":{"generated_at":"x"},"a":{"d":2,"c":[3,1]}}' | canon_json_hashable)" '{"a":{"c":[3,1],"d":2},"b":1}'
assert_eq "a nested meta is kept" "$(printf '{"x":{"meta":1}}' | canon_json_hashable)" '{"x":{"meta":1}}'
assert_eq "a non-object passes through" "$(printf '[{"b":1,"a":2}]' | canon_json_hashable)" '[{"a":2,"b":1}]'
h1="$(printf '{"b":1,"a":2,"meta":{"t":1}}' | canon_json_hashable | json_hash)"
h2="$(printf '{"a":2,"meta":{"t":2},"b":1}' | canon_json_hashable | json_hash)"
assert_match "json_hash: sha256:<64 hex>" "$h1" '^sha256:[0-9a-f]{64}$'
assert_eq "the same plan in another key order and meta hashes the same" "$h1" "$h2"
assert_eq "json_hash of the canonical form, LF included" "$h1" "sha256:$(printf '{"a":2,"b":1}\n' | sha256_hex)"
assert_eq "sha256_hex of the empty input" "$(printf '' | sha256_hex)" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
if have_cmd shasum; then
  assert_eq "sha256_hex without sha256sum (shasum)" \
    "$(printf '' | PATH="$(t_path_without sha256sum)" sha256_hex)" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
fi
assert_eq "no hasher: json_hash prints nothing" "$(printf '{}' | PATH="$(t_path_without sha256sum shasum)" json_hash)" ""

n=0
for d in "$T_REPO"/tests/fixtures/data-snapshots/*/; do
  d="${d%/}"
  assert_eq "version_data_hash names the snapshot ${d##*/}" "$(version_data_hash "$d")" "${d##*/}"
  n=$((n + 1))
done
assert_eq "at least one snapshot was checked" "$([[ "$n" -gt 0 ]] && echo yes)" "yes"
SNAP="$(ls -d "$T_REPO"/tests/fixtures/data-snapshots/*/ | head -n 1)"; SNAP="${SNAP%/}"
assert_eq "version_data_hash defaults to version_data_dir" \
  "$(DRUPILOT_VERSION_DATA_DIR="$SNAP" version_data_hash)" "${SNAP##*/}"
mkdir -p "$T_TMP/empty" "$T_TMP/edited"
assert_eq "a directory with no data: nothing" "$(version_data_hash "$T_TMP/empty")" ""
assert_eq "a missing directory: nothing" "$(version_data_hash "$T_TMP/nope")" ""
cp -R "$SNAP"/. "$T_TMP/edited/"
printf ' ' >> "$T_TMP/edited/php/versions.json"
assert_eq "one edited byte changes the hash" "$([[ "$(version_data_hash "$T_TMP/edited")" != "${SNAP##*/}" ]] && echo changed)" "changed"
printf '{}' > "$T_TMP/edited/README.json"
assert_eq "a JSON file outside targets/php/paths does not count" \
  "$(version_data_hash "$T_TMP/edited")" "$(rm "$T_TMP/edited/README.json"; version_data_hash "$T_TMP/edited")"
t_done
