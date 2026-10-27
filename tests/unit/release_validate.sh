#!/usr/bin/env bash
# scripts/dev/release.sh's real run on a scratch repository, with a stub
# `claude` and a stub check.sh: only the warnings of `claude plugin validate`'s
# result block a release (the known CLAUDE.md-at-root one aside). The plugin
# directory's own checks a newer CLI prints after the result (ICON_MISSING,
# "About these checks") are shown and never block; a warning of the result
# itself still refuses the release with nothing committed, with the directory
# section present too and in the CLI's ASCII figures (">"); with a CLAUDE.md
# at the root, a result without its warning was not understood: refused.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
unset GITHUB_BASE_REF GITHUB_REF_NAME GITHUB_REF_TYPE RELEASE_FROM
r="$T_TMP/repo"
mkdir -p "$r/scripts/dev" "$r/scripts/lib" "$r/config" "$r/.claude-plugin" "$T_TMP/bin"
cp "$T_REPO/scripts/dev/release.sh" "$r/scripts/dev/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$r/scripts/dev/check.sh"; chmod +x "$r/scripts/dev/check.sh"
cp "$T_REPO"/scripts/lib/*.sh "$r/scripts/lib/"
cp "$T_REPO"/config/*.json "$r/config/"
jq '.version = "0.9.1"' "$T_REPO/.claude-plugin/plugin.json" > "$r/.claude-plugin/plugin.json"
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
g() { git -C "$r" "$@"; }
g init -q -b main 2>/dev/null || { g init -q && g checkout -q -b main; }
g config user.name t; g config user.email t@example.invalid; g config commit.gpgsign false; g config tag.gpgsign false
g add -A && g commit -qm base && g checkout -q -b integration/1.0.0
HEAD0="$(g rev-parse HEAD)"
# The stub claude prints what CLAUDE_STUB_OUT holds and passes.
printf '#!/bin/sh\ncat "$CLAUDE_STUB_OUT"\nexit 0\n' > "$T_TMP/bin/claude"; chmod +x "$T_TMP/bin/claude"
rel() { PATH="$T_TMP/bin:$PATH" CLAUDE_STUB_OUT="$1" "$T_SH" "$r/scripts/dev/release.sh" "$2" --date 2026-10-27 --json \
  > "$T_OUT" 2> "$T_ERR" < /dev/null && echo 0 || echo $?; }

# A result warning other than CLAUDE.md's: refused, nothing written.
cat > "$T_TMP/bad.out" <<'OUT'
Validating plugin: /x

⚠ Found 2 warnings:

  ❯ root: CLAUDE.md at the plugin root is not loaded as project context. To ship context with your plugin, use a skill (skills/<name>/SKILL.md) instead.
  ❯ commands/x.md: frontmatter: description is empty

✔ Validation passed with warnings
OUT
assert_eq "a warning of the result: refused" "$(rel "$T_TMP/bad.out" 1.0.0-alpha.1)" "1"
assert_match "  with the reason" "$(t_err)" "a warning other than the known CLAUDE.md-at-root one"
untouched() { printf '%s|%s|%s' "$(g rev-parse HEAD)" "$(g tag -l | wc -l | tr -d ' ')" "$(g status --porcelain | wc -l | tr -d ' ')"; }
assert_eq "  nothing committed or tagged, the tree clean" "$(untouched)" "$HEAD0|0|0"

# The 2.1.311 output: the CLAUDE.md warning, then the plugin directory's checks.
cat > "$T_TMP/dir.out" <<'OUT'
Validating marketplace manifest: /x/.claude-plugin/marketplace.json

Validating plugin: /x/CLAUDE.md

⚠ Found 1 warning:

  ❯ root: CLAUDE.md at the plugin root is not loaded as project context. To ship context with your plugin, use a skill (skills/<name>/SKILL.md) instead.

Plugin directory checks for /x. The plugin directory is the catalog that plugins are submitted to; this is a subset of what it runs.

⚠ Found 1 plugin directory warning:

  ❯ .claude-plugin/plugin.json icon: No icon (ICON_MISSING). No icon found in the plugin.

About these checks:

  ❯ This folder also holds a marketplace manifest. The plugin directory treats such a folder as a plugin, so these checks cover only the plugin in this folder.

These plugin directory checks do not change the result below.

✔ Validation passed with warnings
OUT
# A result warning before the directory section, and in ASCII figures: refused.
awk '{ print } /^  ❯ root: CLAUDE.md/ { print "  ❯ author: No author information provided" }' "$T_TMP/dir.out" > "$T_TMP/dir-bad.out"
assert_eq "a result warning with the directory section present: refused" "$(rel "$T_TMP/dir-bad.out" 1.0.0-alpha.1)" "1"
assert_eq "  nothing committed or tagged" "$(untouched)" "$HEAD0|0|0"
sed 's/^  ❯ /  > /' "$T_TMP/dir-bad.out" > "$T_TMP/dir-ascii.out"
assert_eq "  the same in the CLI's ASCII figures: refused" "$(rel "$T_TMP/dir-ascii.out" 1.0.0-alpha.1)" "1"
# With a CLAUDE.md at the root, its warning must be in the result.
printf '# x\n' > "$r/CLAUDE.md"; g add CLAUDE.md && g commit -qm claude; HEAD0="$(g rev-parse HEAD)"
grep -v 'CLAUDE.md at the plugin root' "$T_TMP/dir.out" > "$T_TMP/dir-noclaude.out"
assert_eq "a CLAUDE.md at the root and no warning about it in the result: refused" "$(rel "$T_TMP/dir-noclaude.out" 1.0.0-alpha.1)" "1"
assert_match "  as not understood" "$(t_err)" "output was not understood"
assert_eq "  nothing committed or tagged" "$(untouched)" "$HEAD0|0|0"

assert_eq "the plugin directory's checks: released" "$(rel "$T_TMP/dir.out" 1.0.0-alpha.1)" "0"
assert_eq "  the release commit and the tag" "$(g log -1 --format=%s)|$(g tag -l)" "chore(release): 1.0.0-alpha.1|v1.0.0-alpha.1"
assert_match "  the directory's checks are shown" "$(t_err)" "ICON_MISSING"
assert_json_eq "  the --json summary" "$(jq -c '{ok, version, dry_run, tag}' "$T_OUT")" \
  '{"ok":true,"version":"1.0.0-alpha.1","dry_run":false,"tag":"v1.0.0-alpha.1"}'
t_done
