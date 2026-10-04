#!/usr/bin/env bash
# The config-keys gate of scripts/dev/check.sh (T-M1-13, AR-27, 08-R4), on a
# scratch copy of the tree it reads: silent on HEAD; it WARNS (not fails) on
# an undeclared DRUPILOT_* read, on a defaults.json key missing from the
# reference and on a README-documented name that is no longer public; a
# comment line is not a read; a defaults.json _*_comment over 1800
# characters FAILS.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
r="$T_TMP/tree"
mkdir -p "$r/scripts" "$r/tests/baseline/v0.9.0"
cp -R "$T_REPO/scripts/dev" "$T_REPO/scripts/lib" "$T_REPO/scripts/env" "$r/scripts/"
cp -R "$T_REPO/config" "$T_REPO/hooks" "$T_REPO/commands" "$T_REPO/skills" "$T_REPO/agents" "$r/"
cp "$T_REPO/tests/baseline/v0.9.0/env-public-v0.9.json" "$r/tests/baseline/v0.9.0/"
# gate -> "<status>|<first finding>"
gate() {
  "$T_SH" "$r/scripts/dev/check.sh" --only config-keys --json 2>/dev/null | jq -r '.gates[0] | "\(.status)|\(.findings[0] // "")"'
}
assert_eq "silent on HEAD" "$(gate | cut -d'|' -f1)" "pass"

printf '\n# a comment that names DRUPILOT_IN_A_COMMENT\n' >> "$r/scripts/env/clean.sh"
assert_eq "a comment line is not a read" "$(gate | cut -d'|' -f1)" "pass"
cp "$r/scripts/env/clean.sh" "$T_TMP/clean.bak"
printf '\nx="${DRUPILOT_X:-}"\n' >> "$r/scripts/env/clean.sh"
assert_eq "an undeclared DRUPILOT_X read warns" "$(gate)" "warn|DRUPILOT_X is read but not declared in config/config-reference.json"
cp "$T_TMP/clean.bak" "$r/scripts/env/clean.sh"
printf 'Set `DRUPILOT_CHOICE_NEW_TAB` to pre-answer it.\n' >> "$r/commands/drupilot-port.md"
assert_eq "a DRUPILOT_CHOICE_* name matches its pattern" "$(gate | cut -d'|' -f1)" "pass"

cp "$r/config/config-reference.json" "$T_TMP/ref.bak"
jq 'del(.keys.DRUPILOT_PLACEMENT)' "$T_TMP/ref.bak" > "$r/config/config-reference.json"
assert_match "a defaults.json key missing from the reference warns" "$(gate)" \
  "^warn\|.*DRUPILOT_PLACEMENT (is read but not declared|is in defaults.json but not in config-reference.json keys)"
jq '.runtime_only.DRUPILOT_NONINTERACTIVE.tier = "internal"' "$T_TMP/ref.bak" > "$r/config/config-reference.json"
assert_eq "a README-documented name that is not public warns" "$(gate)" \
  "warn|DRUPILOT_NONINTERACTIVE is documented by the 0.9 README but not public in config-reference.json"
jq '.keys.DRUPILOT_CONTRIB_MODE.enum = ["auto"]' "$T_TMP/ref.bak" > "$r/config/config-reference.json"
assert_eq "an enum without its default warns" "$(gate)" "warn|DRUPILOT_CONTRIB_MODE: its enum lacks the default"
jq '.keys.DRUPILOT_CONTRIB_MODE.default_ref = "defaults.json#/DRUPILOT_NOPE"' "$T_TMP/ref.bak" > "$r/config/config-reference.json"
assert_match "a default_ref that does not resolve warns" "$(gate)" "^warn\|.*default_ref defaults.json#/DRUPILOT_NOPE does not resolve"
cp "$T_TMP/ref.bak" "$r/config/config-reference.json"

jq --arg c "$(printf 'x%.0s' $(seq 1 1801))" '._placement_comment = $c' "$T_REPO/config/defaults.json" > "$r/config/defaults.json"
assert_match "a _*_comment over 1800 characters fails" "$(gate)" "^fail\|defaults.json _placement_comment is 1801 characters"
t_done
