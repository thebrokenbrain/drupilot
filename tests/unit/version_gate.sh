#!/usr/bin/env bash
# The `version` gate of scripts/dev/check.sh (09-R4), on a scratch repository
# holding the gate's inputs: plugin.json equals the top released CHANGELOG
# heading; a v* tag on HEAD must be v<version>; no pre-release version on
# `main` (the branch, or GITHUB_BASE_REF / GITHUB_REF_NAME in CI); and
# config/migrations.json rows are coherent.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
unset GITHUB_BASE_REF GITHUB_REF_NAME GITHUB_REF_TYPE
r="$T_TMP/repo"
mkdir -p "$r/scripts/dev" "$r/scripts/lib" "$r/config" "$r/.claude-plugin"
cp "$T_REPO/scripts/dev/check.sh" "$r/scripts/dev/"
cp "$T_REPO/scripts/lib/common.sh" "$r/scripts/lib/"
cp "$T_REPO/config/defaults.json" "$T_REPO/config/migrations.json" "$T_REPO/config/config-reference.json" "$r/config/"
cp "$T_REPO/CHANGELOG.md" "$r/"
cp "$T_REPO/.claude-plugin/plugin.json" "$r/.claude-plugin/"
g() { git -C "$r" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
g init -q -b main 2>/dev/null || { g init -q && g checkout -q -b main; }
g add -A && g commit -qm base
v="$(jq -r .version "$r/.claude-plugin/plugin.json")"

# gate [env...] -> "<status>|<first finding>" of `check.sh --only version`.
gate() {
  env "$@" "$T_SH" "$r/scripts/dev/check.sh" --only version --json 2>/dev/null \
    | jq -r '.gates[0] | "\(.status)|\(.findings[0] // "")"'
}
setver() {
  jq --arg v "$1" '.version = $v' "$r/.claude-plugin/plugin.json" > "$T_TMP/p" && mv "$T_TMP/p" "$r/.claude-plugin/plugin.json"
  awk -v v="$1" 'BEGIN { done = 0 } /^## \[/ && !done && $2 != "[Unreleased]" { print "## [" v "] - 2026-10-04"; print ""; done = 1 } { print }' \
    "$T_REPO/CHANGELOG.md" > "$r/CHANGELOG.md"
}

assert_eq "the released version on main passes" "$(gate)" "pass|"
g checkout -q -b feature
assert_eq "an untagged commit on another branch passes" "$(gate)" "pass|"
g tag "v$v"
assert_eq "HEAD tagged v<version> passes" "$(gate)" "pass|"
g tag v9.9.9
assert_match "HEAD tagged v9.9.9 fails" "$(gate)" "^fail\|.*HEAD is tagged 'v9.9.9'"
g tag -d v9.9.9 "v$v" > /dev/null

setver 1.0.0-alpha.1
assert_eq "a pre-release on another branch passes" "$(gate)" "pass|"
g checkout -q main
assert_match "a pre-release on main fails" "$(gate)" "^fail\|.*pre-release version '1.0.0-alpha.1' on main"
g checkout -q feature
assert_match "a pull request into main (GITHUB_BASE_REF) fails" "$(gate GITHUB_BASE_REF=main GITHUB_REF_NAME=12/merge)" "^fail\|.*pre-release"
assert_match "a CI push to main (GITHUB_REF_NAME) fails" "$(gate GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch)" "^fail\|.*pre-release"
assert_eq "a CI push to integration/1.0.0 passes" "$(gate GITHUB_REF_NAME=integration/1.0.0 GITHUB_REF_TYPE=branch)" "pass|"

jq '.version = "0.9.2"' "$r/.claude-plugin/plugin.json" > "$T_TMP/p" && mv "$T_TMP/p" "$r/.claude-plugin/plugin.json"
assert_match "plugin.json ahead of the CHANGELOG fails" "$(gate)" "^fail\|.*plugin.json version '0.9.2' differs from the highest released"
setver 1.0
assert_match "a malformed version fails" "$(gate)" "^fail\|.*'1.0' is not a valid version"
setver "$v"

row() {
  jq --argjson r "$1" '.env_aliases = [$r]' "$T_REPO/config/migrations.json" > "$r/config/migrations.json"
}
row '{"old":"DRUPILOT_OLD","new":"DRUPILOT_PHP_TARGET","since":"1.0.0","remove_in":"2.0.0","note":"x"}'
assert_eq "a coherent alias row passes" "$(gate)" "pass|"
row '{"old":"DRUPILOT_OLD","new":"DRUPILOT_NO_SUCH_KEY=v","since":"1.0.0","remove_in":"2.0.0","note":"x"}'
assert_match "an aliased key not declared in config-reference.json fails" "$(gate)" "^fail\|.*new key DRUPILOT_NO_SUCH_KEY is not declared in config/config-reference.json"
row '{"old":"DRUPILOT_CHOICE_CORE","new":"DRUPILOT_CHOICE_CORE_TARGET","since":"1.0.0","remove_in":"2.0.0","note":"x"}'
assert_eq "a DRUPILOT_CHOICE_* target (a declared pattern) passes" "$(gate)" "pass|"
row '{"old":"DRUPILOT-OLD","new":"DRUPILOT_PHP_TARGET","since":"1.0.0","remove_in":"2.0.0","note":"x"}'
assert_match "an old name that is not a variable name fails" "$(gate)" "^fail\|.*old and new must be variable names"
row '{"old":"DRUPILOT_OLD","new":"DRUPILOT_PHP_TARGET","since":"1.0.0","remove_in":"2.0.0","note":"x","when":{"key":"DRUPILOT_AUTONOMOUS","equals":{"a":1}}}'
assert_match "a when.equals that is not a scalar fails" "$(gate)" "^fail\|.*when must be"
row '{"old":"DRUPILOT_OLD","new":"DRUPILOT_PHP_TARGET","since":"1.0.0","remove_in":"2.0.0","note":"x","when":{"key":"DRUPILOT_AUTONOMOUS","equals":false}}'
assert_eq "a when.equals false passes" "$(gate)" "pass|"
row '{"old":"DRUPILOT_OLD","new":"DRUPILOT_PHP_TARGET","since":"1.0.0","remove_in":"2.0.0","note":"x","when":{"key":"DRUPILOT_NOPE","equals":"a"}}'
assert_match "a when.key not declared fails" "$(gate)" "^fail\|.*when.key DRUPILOT_NOPE is not declared"
row '{"old":"DRUPILOT_OLD","new":"DRUPILOT_PHP_TARGET","since":"0.9.0","remove_in":"0.10.0","note":"x"}'
assert_match "a remove_in in the current major fails" "$(gate)" "^fail\|.*remove_in 0.10.0, not a later major"
row '{"old":"DRUPILOT_OLD","new":"DRUPILOT_PHP_TARGET"}'
assert_match "a row without since/remove_in fails" "$(gate)" "^fail\|.*needs string old, new, since and remove_in"
cp "$T_REPO/config/migrations.json" "$r/config/migrations.json"

# On the integration branch, a 0.9.x section merged from main and dated after
# the latest pre-release sits above it (09-R5): the highest precedence wins.
setver 1.0.0-alpha.1
awk 'BEGIN { done = 0 } /^## \[/ && !done && $2 != "[Unreleased]" { print "## [0.9.9] - 2026-11-10"; print ""; done = 1 } { print }' \
  "$r/CHANGELOG.md" > "$T_TMP/cl" && mv "$T_TMP/cl" "$r/CHANGELOG.md"
assert_eq "a 0.9.x section above the 1.0 pre-release passes" "$(gate)" "pass|"
# release.sh promoting an rc: HEAD still carries the rc tag while it checks.
setver 1.0.0-rc.1
g add -A && g commit -qm rc1 && g tag v1.0.0-rc.1
setver 1.0.0
assert_match "a promotion on the rc-tagged HEAD fails without RELEASE_FROM" "$(gate)" "^fail\|.*HEAD is tagged 'v1.0.0-rc.1'"
assert_eq "... and passes while release.sh promotes it (RELEASE_FROM)" "$(gate RELEASE_FROM=1.0.0-rc.1)" "pass|"
t_done
