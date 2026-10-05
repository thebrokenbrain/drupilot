#!/usr/bin/env bash
# tests/contract/allowed-changes.json: an intended change passes once its
# entry (the snapshot and the sha256 contract.sh prints) is added, and a second
# intended change of the same snapshot passes with a second entry; an entry
# whose sha256 does not match allows nothing.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
r="$T_TMP/repo"; mkdir -p "$r/tests"
for d in scripts config commands skills agents hooks templates .claude-plugin; do cp -R "$T_REPO/$d" "$r/"; done
cp -R "$T_REPO/tests/contract" "$T_REPO/tests/fixtures" "$r/tests/"
A="$r/tests/contract/allowed-changes.json"
# check -> "<status>|<sha256 to allow>" of the commands snapshot.
check() {
  "$T_SH" "$r/scripts/dev/contract.sh" --check --only commands --json 2>/dev/null \
    | jq -r '.snapshots[0] | "\(.status)|\(.detail | capture("\"sha256\": \"(?<h>[0-9a-f]+)\"").h? // "")"'
}
allow() { jq --arg h "$1" --arg w "$2" '.changes += [{snapshot: "commands.json", sha256: $h, reason: $w}]' "$A" > "$T_TMP/a" && mv "$T_TMP/a" "$A"; }
hint() { sed "s/^argument-hint: .*/argument-hint: \"$2\"/" "$r/commands/$1.md" > "$T_TMP/c" && mv "$T_TMP/c" "$r/commands/$1.md"; }

# HEAD keeps the 0.9 commands, or adds argument-hint tokens (allowed as is).
assert_match "unchanged: same, or only added tokens" "$(check | cut -d'|' -f1)" '^(same|additions)$'
hint drupilot-setup "[subject-path] [--php-target X.Y]"
first="$(check)"
assert_match "a replaced argument-hint token differs" "$first" '^differs\|[0-9a-f]{64}$'
allow "$(printf '%s' "$first" | cut -d'|' -f2)" "first intended change"
assert_eq "its entry allows it" "$(check | cut -d'|' -f1)" "allowed"
hint drupilot-test "[subject-path-only]"
second="$(check)"
assert_match "a second change of the same snapshot differs" "$second" '^differs\|[0-9a-f]{64}$'
allow "0000000000000000000000000000000000000000000000000000000000000000" "a stale entry"
assert_eq "an entry with another sha256 allows nothing" "$(check | cut -d'|' -f1)" "differs"
allow "$(printf '%s' "$second" | cut -d'|' -f2)" "second intended change"
assert_eq "the second entry allows it" "$(check | cut -d'|' -f1)" "allowed"
t_done
