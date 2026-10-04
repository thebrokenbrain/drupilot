#!/usr/bin/env bash
# Data-snapshot pinning of the goldens (T-M2-15, AR-29), on a scratch copy:
# a golden is checked against the vendored snapshot its data_hash names,
# never against the live config/, so an edit of config/targets/11.json leaves
# golden.sh --check green, while an edited snapshot, a missing one and an
# unpinned golden fail; --update vendors the live data as a new snapshot and
# repins; baseline-0.9.sh gets the pinned snapshot as its data dir; a full
# --check fails on a snapshot no golden uses and a full --update removes it;
# a partial snapshot of the live data is refused.
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
assert_eq "the old snapshot, now unused, fails a full --check" \
  "$(printf '%s' "$o" | jq -r --arg h "$H" '[.goldens[] | select(.name == "data-snapshots" and .status == "fail") | select(.detail | contains($h))] | length')" "1"

# The baseline-0.9 golden runs baseline-0.9.sh with the pinned snapshot as its
# data dir (a stub records what it receives).
mkdir -p "$r/tests/baseline/v0.9.0"
jq -n --arg h "$H2" '{data_hash: $h}' > "$r/tests/baseline/v0.9.0/golden.json"
cat > "$r/scripts/dev/baseline-0.9.sh" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do [[ "$1" == "--data-dir" ]] && printf '%s' "$2" > "${T_REC:?}"; shift; done
printf '{"ok": true, "files": []}\n'
STUB
T_REC="$T_TMP/rec" CLAUDE_PLUGIN_ROOT="$r" "$T_SH" "$r/scripts/dev/golden.sh" --check --only baseline-0.9 > /dev/null 2>&1 || true
assert_eq "baseline-0.9.sh gets the pinned snapshot as --data-dir" "$(cat "$T_TMP/rec" 2>/dev/null)" "$r/tests/fixtures/data-snapshots/$H2"

# A full --update removes the snapshots no golden is pinned to any more.
CLAUDE_PLUGIN_ROOT="$r" "$T_SH" "$r/scripts/dev/golden.sh" --update > /dev/null 2>&1
assert_eq "a full --update removes the unused snapshot" "$([[ -d "$r/tests/fixtures/data-snapshots/$H" ]] && echo kept || echo removed)" "removed"
assert_eq "... and keeps the pinned one" "$([[ -d "$r/tests/fixtures/data-snapshots/$H2" ]] && echo kept || echo removed)" "kept"

# An existing but partial snapshot of the live data is refused (an interrupted
# vendoring): vendor one, damage it, then --update again.
jq '.as_of = "2099-02-02"' "$T_REPO/config/targets/11.json" > "$r/config/targets/11.json"
CLAUDE_PLUGIN_ROOT="$r" "$T_SH" "$r/scripts/dev/golden.sh" --update --only legacy_widgets > /dev/null 2>&1
H3="$(jq -r .data_hash "$G")"
rm -f "$r/tests/fixtures/data-snapshots/$H3/targets/11.json"
rc=0; CLAUDE_PLUGIN_ROOT="$r" "$T_SH" "$r/scripts/dev/golden.sh" --update --only legacy_widgets > /dev/null 2> "$T_TMP/err" || rc=$?
assert_eq "--update refuses a partial snapshot of the live data" "$rc" "1"
assert_match "... and says how to recover" "$(cat "$T_TMP/err")" 'does not hold the live data'
t_done
