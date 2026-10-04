#!/usr/bin/env bash
# scripts/dev/release.sh (T-M1-11, 09-R4) on a scratch repository: --dry-run
# exits 0 and leaves `git status --porcelain` empty; a version that is not
# newer (SemVer precedence, pre-releases included), a malformed one, a
# pre-release on `main`, an existing tag and an empty [Unreleased] are
# refused before anything is written. (The real run needs claude and the full
# check.sh --ci, so it is exercised by hand on a release branch.)
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
unset GITHUB_BASE_REF GITHUB_REF_NAME GITHUB_REF_TYPE
r="$T_TMP/repo"
mkdir -p "$r/scripts/dev" "$r/scripts/lib" "$r/config" "$r/.claude-plugin"
cp "$T_REPO/scripts/dev/check.sh" "$T_REPO/scripts/dev/release.sh" "$r/scripts/dev/"
cp "$T_REPO/scripts/lib/common.sh" "$r/scripts/lib/"
cp "$T_REPO"/config/*.json "$r/config/"
cp "$T_REPO/.claude-plugin/plugin.json" "$r/.claude-plugin/"
# A CHANGELOG with an [Unreleased] entry, a released 0.9.1 and its links.
cat > "$r/CHANGELOG.md" <<'MD'
# Changelog

## [Unreleased]

### Added
- Something.

## [0.9.1] - 2026-10-03

### Fixed
- Something else.

[Unreleased]: https://github.com/thebrokenbrain/drupilot/compare/v0.9.1...HEAD
[0.9.1]: https://github.com/thebrokenbrain/drupilot/compare/v0.9.0...v0.9.1
MD
jq '.version = "0.9.1"' "$T_REPO/.claude-plugin/plugin.json" > "$r/.claude-plugin/plugin.json"
g() { git -C "$r" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
g init -q -b main 2>/dev/null || { g init -q && g checkout -q -b main; }
g add -A && g commit -qm base && g checkout -q -b integration/1.0.0

rel() { "$T_SH" "$r/scripts/dev/release.sh" "$@" --dry-run --json --date 2026-10-04 > "$T_OUT" 2> "$T_ERR" < /dev/null && echo 0 || echo $?; }
setcur() {
  jq --arg v "$1" '.version = $v' "$r/.claude-plugin/plugin.json" > "$T_TMP/p" && mv "$T_TMP/p" "$r/.claude-plugin/plugin.json"
  sed "s/^## \[0.9.1\] - 2026-10-03/## [$1] - 2026-10-03/" "$T_TMP/cl" > "$r/CHANGELOG.md"
}
cp "$r/CHANGELOG.md" "$T_TMP/cl"

assert_eq "--dry-run 1.0.0-alpha.1 exits 0" "$(rel 1.0.0-alpha.1)" "0"
assert_json_eq "... and reports the release it would make" "$(jq -c '{ok, version, previous, dry_run, tag}' "$T_OUT")" \
  '{"ok":true,"version":"1.0.0-alpha.1","previous":"0.9.1","dry_run":true,"tag":"v1.0.0-alpha.1"}'
"$T_SH" "$r/scripts/dev/release.sh" 1.0.0-alpha.1 --dry-run > /dev/null 2>&1 < /dev/null || true
assert_eq "... and leaves git status --porcelain empty" "$(git -C "$r" status --porcelain)" ""
assert_eq "the same version is refused" "$(rel 0.9.1)" "1"
assert_eq "a lower version is refused" "$(rel 0.9.0)" "1"
assert_eq "a malformed version is refused" "$(rel 1.0)" "1"
g checkout -q main
assert_eq "a pre-release on main is refused" "$(rel 1.0.0-alpha.1)" "1"
assert_match "... with the reason" "$(t_err)" "never goes on main"
assert_eq "a release on main is accepted" "$(rel 0.9.2)" "0"
g checkout -q integration/1.0.0
g tag v1.0.0-alpha.1
assert_eq "an existing tag is refused" "$(rel 1.0.0-alpha.1)" "1"
g tag -d v1.0.0-alpha.1 > /dev/null

# SemVer precedence, pre-releases included.
setcur 1.0.0-alpha.2
assert_eq "alpha.10 is newer than alpha.2 (numeric identifiers)" "$(rel 1.0.0-alpha.10)" "0"
assert_eq "alpha.1 is older than alpha.2" "$(rel 1.0.0-alpha.1)" "1"
assert_eq "beta.1 is newer than alpha.2" "$(rel 1.0.0-beta.1)" "0"
assert_eq "the release is newer than its pre-releases" "$(rel 1.0.0)" "0"
setcur 1.0.0-rc.1
assert_eq "beta.9 is older than rc.1" "$(rel 1.0.0-beta.9)" "1"
setcur 1.0.0
assert_eq "rc.2 is older than the release" "$(rel 1.0.0-rc.2)" "1"
assert_eq "1.0.1-alpha.1 is newer than 1.0.0" "$(rel 1.0.1-alpha.1)" "0"
setcur 1.0.0-alpha
assert_eq "alpha.1 is newer than alpha (a longer list wins)" "$(rel 1.0.0-alpha.1)" "0"

# Nothing to release.
cp "$T_TMP/cl" "$r/CHANGELOG.md"
awk '/^### Added/ { skip = 1; next } skip && /^- Something\.$/ { skip = 0; next } { print }' "$T_TMP/cl" > "$r/CHANGELOG.md"
jq '.version = "0.9.1"' "$r/.claude-plugin/plugin.json" > "$T_TMP/p" && mv "$T_TMP/p" "$r/.claude-plugin/plugin.json"
assert_eq "an empty [Unreleased] is refused" "$(rel 0.9.2)" "1"
assert_match "... with the reason" "$(t_err)" "\\[Unreleased\\] is empty"
t_done
