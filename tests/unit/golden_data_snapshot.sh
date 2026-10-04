#!/usr/bin/env bash
# Data-snapshot pinning of the goldens (T-M2-15, AR-29), on a scratch copy:
# a golden is checked against the vendored snapshot its data_hash names,
# never against the live config/, so an edit of config/targets/11.json leaves
# golden.sh --check green, while an edited snapshot, a missing one and an
# unpinned golden fail; --update vendors the live data as a new snapshot and
# repins, and a snapshot no golden uses is reported.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
r="$T_TMP/tree"; mkdir -p "$r/tests/fixtures"
cp -R "$T_REPO/scripts" "$T_REPO/config" "$r/"
cp -R "$T_REPO/tests/fixtures/legacy_widgets.golden" "$T_REPO/tests/fixtures/data-snapshots" "$r/tests/fixtures/"
H="$(jq -r .data_hash "$r/tests/fixtures/legacy_widgets.golden/golden.json")"
# gs [args] -> "<exit>|<status of legacy_widgets>|<its detail>".
gs() {
  local o rc=0
  o="$(CLAUDE_PLUGIN_ROOT="$r" "$T_SH" "$r/scripts/dev/golden.sh" --check --only legacy_widgets --json 2>/dev/null)" || rc=$?
  printf '%s|%s' "$rc" "$(printf '%s' "$o" | jq -r '.goldens[] | select(.name == "legacy_widgets") | "\(.status)|\(.detail)"' 2>/dev/null)"
}
assert_match "the golden is pinned to a snapshot" "$H" '^[0-9a-f]{64}$'
assert_match "it passes against its snapshot" "$(gs)" '^0\|pass\|'
jq '.minors["11.3"].php_supported = []' "$T_REPO/config/targets/11.json" > "$r/config/targets/11.json"
assert_match "an edit of the live data leaves it green" "$(gs)" '^0\|pass\|'
cp "$T_REPO/config/targets/11.json" "$r/config/targets/11.json"

S="$r/tests/fixtures/data-snapshots/$H"
cp "$S/targets/11.json" "$T_TMP/snap11.json"
jq '.minors["11.3"].php_supported = []' "$T_TMP/snap11.json" > "$S/targets/11.json"
assert_match "an edited snapshot fails" "$(gs)" '^1\|fail\|the data snapshot .* was edited'
cp "$T_TMP/snap11.json" "$S/targets/11.json"
assert_match "restored: green" "$(gs)" '^0\|pass\|'

G="$r/tests/fixtures/legacy_widgets.golden/golden.json"
cp "$G" "$T_TMP/golden.json"
jq '.data_hash = "0000000000000000000000000000000000000000000000000000000000000000"' "$T_TMP/golden.json" > "$G"
assert_match "a missing snapshot fails" "$(gs)" '^1\|fail\|its data snapshot .* is missing'
jq '.data_hash = ""' "$T_TMP/golden.json" > "$G"
assert_match "an unpinned golden fails" "$(gs)" '^1\|fail\|golden.json has no data_hash'
cp "$T_TMP/golden.json" "$G"

# --update after a data change: a new snapshot, the golden repinned to it.
jq '.as_of = "2099-01-01"' "$T_REPO/config/targets/11.json" > "$r/config/targets/11.json"
CLAUDE_PLUGIN_ROOT="$r" "$T_SH" "$r/scripts/dev/golden.sh" --update --only legacy_widgets > /dev/null 2>&1
H2="$(jq -r .data_hash "$G")"
assert_eq "--update repins the golden to a new hash" "$([[ "$H2" != "$H" && "$H2" =~ ^[0-9a-f]{64}$ ]] && echo new)" "new"
assert_eq "--update vendors the live data as that snapshot" \
  "$(cmp "$r/tests/fixtures/data-snapshots/$H2/targets/11.json" "$r/config/targets/11.json" && echo same)" "same"
assert_match "the repinned golden passes" "$(gs)" '^0\|pass\|'
o="$(CLAUDE_PLUGIN_ROOT="$r" "$T_SH" "$r/scripts/dev/golden.sh" --check --json 2>/dev/null || true)"
assert_match "the old snapshot, now unused, is reported" \
  "$(printf '%s' "$o" | jq -r '[.goldens[] | select(.name == "data-snapshots") | .detail][0] // ""')" "$H is not used by any golden"
rc=0; err="$("$T_SH" "$T_REPO/scripts/dev/baseline-0.9.sh" --check --data-dir "$T_TMP/none" 2>&1 >/dev/null)" || rc=$?
assert_eq "baseline-0.9.sh refuses a data dir without targets/: exit 1" "$rc" "1"
assert_match "... and says why" "$err" 'holds no targets/'
t_done
