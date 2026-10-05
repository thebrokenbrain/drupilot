#!/usr/bin/env bash
# The alias layer of config_get (config/migrations.json env_aliases): an old
# name resolves to the new key with one warning per process; the environment
# still wins over every file tier (env > env alias > .drupilot.json >
# .drupilot.json alias > defaults.json); a KEY=value row aliases one value; a
# `when` row applies only while its condition holds without aliases. The rows
# are read only when needed (a renamed key looked up, an old name in use), so
# a hook never forks jq for them. The rows are synthetic, in a temp plugin
# root; the shipped ones are checked last.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
pr="$T_TMP/plugin"; mkdir -p "$pr/config" "$T_TMP/root"
cp "$T_REPO/config/defaults.json" "$pr/config/"
cat > "$pr/config/migrations.json" <<'JSON'
{"schema": 1,
 "env_aliases": [
   {"old": "DRUPILOT_OLD_PHP", "new": "DRUPILOT_PHP_TARGET", "since": "1.0.0", "remove_in": "2.0.0", "note": "synthetic"},
   {"old": "DRUPILOT_OLD_MODE", "new": "DRUPILOT_CONTRIB_MODE", "since": "1.0.0", "remove_in": "2.0.0", "note": "synthetic"},
   {"old": "DRUPILOT_KEEP_D10=true", "new": "DRUPILOT_CORE_TARGET_STRATEGY=keep-previous", "since": "1.0.0", "remove_in": "2.0.0",
    "note": "synthetic", "when": {"key": "DRUPILOT_CORE_TARGET_STRATEGY", "equals": "auto"}},
   {"old": "DRUPILOT_OLD_GEN", "new": "DRUPILOT_GENERATE_RULES", "since": "1.0.0", "remove_in": "2.0.0",
    "note": "synthetic", "when": {"key": "DRUPILOT_AUTONOMOUS", "equals": false}},
   {"old": "DRUPILOT-BAD-NAME", "new": "DRUPILOT_SESSION_CONTEXT", "since": "1.0.0", "remove_in": "2.0.0", "note": "an invalid name"}
 ],
 "value_aliases": [], "removed": []}
JSON
export CLAUDE_PLUGIN_ROOT="$pr" DRUPILOT_PROJECT_DIR="$T_TMP/root"
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

assert_eq "no row is read at source time while no old name is in use (no jq fork)" "$_DRUPILOT_ALIAS_N|$_DRUPILOT_ALIAS_PENDING" "0|1"
assert_eq "  the scan knows the renamed keys" "$_DRUPILOT_ALIAS_NEW" "|DRUPILOT_PHP_TARGET|DRUPILOT_CONTRIB_MODE|DRUPILOT_CORE_TARGET_STRATEGY|DRUPILOT_GENERATE_RULES|DRUPILOT_SESSION_CONTEXT|"
config_get DRUPILOT_HOOKS_GUARD x > /dev/null
assert_eq "  a key no row renames reads none" "$_DRUPILOT_ALIAS_N|$_DRUPILOT_ALIAS_PENDING" "0|1"
config_get DRUPILOT_PHP_TARGET x > /dev/null
assert_eq "  the first lookup of a renamed key reads them, once (the invalid name ignored)" "$_DRUPILOT_ALIAS_N|$_DRUPILOT_ALIAS_PENDING" "4|0"
assert_eq "no alias in use: defaults.json" "$(config_get DRUPILOT_PHP_TARGET x)" "8.3"

# One warning per process: two lookups in this shell, one warning.
export DRUPILOT_OLD_PHP=8.4
config_get DRUPILOT_PHP_TARGET x > "$T_TMP/v1" 2> "$T_TMP/e1"
config_get DRUPILOT_PHP_TARGET x > "$T_TMP/v2" 2>> "$T_TMP/e1"
assert_eq "an env alias resolves the new key" "$(cat "$T_TMP/v1")|$(cat "$T_TMP/v2")" "8.4|8.4"
assert_eq "it warns once per process" "$(grep -c 'DRUPILOT_OLD_PHP is deprecated since 1.0.0 and will be removed in 2.0.0; use DRUPILOT_PHP_TARGET' "$T_TMP/e1")" "1"
assert_eq "the new env name wins over its alias" "$(DRUPILOT_PHP_TARGET=8.5 config_get DRUPILOT_PHP_TARGET x 2>/dev/null)" "8.5"
printf '{"DRUPILOT_PHP_TARGET":"8.2","DRUPILOT_OLD_MODE":"auto"}\n' > "$T_TMP/root/.drupilot.json"
assert_eq "an env alias beats .drupilot.json (env wins over every tier)" "$(config_get DRUPILOT_PHP_TARGET x 2>/dev/null)" "8.4"
unset DRUPILOT_OLD_PHP
assert_eq "without it, .drupilot.json" "$(config_get DRUPILOT_PHP_TARGET x 2>/dev/null)" "8.2"
assert_eq "a .drupilot.json alias beats defaults.json" "$(config_get DRUPILOT_CONTRIB_MODE x 2>/dev/null)" "auto"
assert_eq "the env beats a .drupilot.json alias" "$(DRUPILOT_CONTRIB_MODE=semi config_get DRUPILOT_CONTRIB_MODE x 2>/dev/null)" "semi"
printf '{"DRUPILOT_CONTRIB_MODE":"manual","DRUPILOT_OLD_MODE":"auto"}\n' > "$T_TMP/root/.drupilot.json"
assert_eq "the new name in .drupilot.json beats its alias there" "$(config_get DRUPILOT_CONTRIB_MODE x 2>/dev/null)" "manual"
assert_eq "config_enum validates the aliased value" \
  "$(rm -f "$T_TMP/root/.drupilot.json"; DRUPILOT_OLD_MODE=bogus config_enum DRUPILOT_CONTRIB_MODE semi semi auto 2>/dev/null || echo rejected)" "rejected"

# A KEY=value row with a `when` condition (the legacy boolean honored only
# while the strategy is still auto).
rm -f "$T_TMP/root/.drupilot.json"
assert_eq "when holds: KEEP_D10=true -> keep-previous" "$(DRUPILOT_KEEP_D10=true config_get DRUPILOT_CORE_TARGET_STRATEGY x 2>/dev/null)" "keep-previous"
assert_eq "the value is compared case-insensitively" "$(DRUPILOT_KEEP_D10=TRUE config_get DRUPILOT_CORE_TARGET_STRATEGY x 2>/dev/null)" "keep-previous"
assert_eq "another value of the old key: no alias" "$(DRUPILOT_KEEP_D10=false config_get DRUPILOT_CORE_TARGET_STRATEGY x 2>/dev/null)" "auto"
assert_eq "unset: the default" "$(config_get DRUPILOT_CORE_TARGET_STRATEGY x 2>/dev/null)" "auto"
printf '{"DRUPILOT_CORE_TARGET_STRATEGY":"d11-only"}\n' > "$T_TMP/root/.drupilot.json"
assert_eq "when fails: an explicit strategy in .drupilot.json wins" "$(DRUPILOT_KEEP_D10=true config_get DRUPILOT_CORE_TARGET_STRATEGY x 2>/dev/null)" "d11-only"
rm -f "$T_TMP/root/.drupilot.json"
assert_eq "an explicit env strategy wins" "$(DRUPILOT_KEEP_D10=true DRUPILOT_CORE_TARGET_STRATEGY=keep-d10 config_get DRUPILOT_CORE_TARGET_STRATEGY x 2>/dev/null)" "keep-d10"

# `equals: false` matches a JSON false of defaults.json (DRUPILOT_AUTONOMOUS).
assert_eq "when equals false: the alias applies while the key is false" "$(DRUPILOT_OLD_GEN=off config_get DRUPILOT_GENERATE_RULES x 2>/dev/null)" "off"
assert_eq "... and not when it is true" "$(DRUPILOT_AUTONOMOUS=true DRUPILOT_OLD_GEN=off config_get DRUPILOT_GENERATE_RULES x 2>/dev/null)" "ask"
assert_eq "a row with an invalid variable name never breaks a lookup" "$(config_get DRUPILOT_SESSION_CONTEXT x 2>/dev/null)" "on"

# Once per process, through the $(config_get ...) subshells scripts use: the
# row in use is warned about when common.sh is sourced, in the main shell.
n="$(env DRUPILOT_OLD_PHP=8.4 "$T_SH" -c '. "$1"; a="$(config_get DRUPILOT_PHP_TARGET x)"; b="$(config_get DRUPILOT_PHP_TARGET x)"; c="$(config_enum DRUPILOT_PHP_TARGET 8.3 8.3 8.4)"; printf "%s %s %s\n" "$a" "$b" "$c" >&2' _ "$T_LIB" 2>&1 | grep -c 'DRUPILOT_OLD_PHP is deprecated')"
assert_eq "three reads through command substitution: one warning" "$n" "1"
printf '{"DRUPILOT_OLD_MODE":"auto"}\n' > "$T_TMP/root/.drupilot.json"
n="$("$T_SH" -c '. "$1"; a="$(config_get DRUPILOT_CONTRIB_MODE x)"; b="$(config_get DRUPILOT_CONTRIB_MODE x)"' _ "$T_LIB" 2>&1 | grep -c 'DRUPILOT_OLD_MODE is deprecated')"
assert_eq "a .drupilot.json alias: one warning too" "$n" "1"
rm -f "$T_TMP/root/.drupilot.json"
assert_eq "an alias not in use: no warning" "$("$T_SH" -c '. "$1"; a="$(config_get DRUPILOT_PHP_TARGET x)"' _ "$T_LIB" 2>&1 | grep -c 'deprecated' || true)" "0"

# A malformed .drupilot.json never stops a `set -e` script that sources
# common.sh (the pre-warning reads it), nor a directory in its place.
printf '{"DRUPILOT_PHP_TARGET": "8.3",}\n' > "$T_TMP/root/.drupilot.json"
assert_eq "a malformed .drupilot.json: a set -e script still runs" \
  "$("$T_SH" -c 'set -euo pipefail; . "$1"; printf reached' _ "$T_LIB" 2>/dev/null)" "reached"
rm -f "$T_TMP/root/.drupilot.json"; mkdir "$T_TMP/root/.drupilot.json"
assert_eq "a directory named .drupilot.json: a set -e script still runs" \
  "$("$T_SH" -c 'set -euo pipefail; . "$1"; printf reached' _ "$T_LIB" 2>/dev/null)" "reached"
rmdir "$T_TMP/root/.drupilot.json"

# The shipped file holds the eight DRUPILOT_KEEP_D10 rows (T-M3-07, one per 0.9
# boolean spelling); a key no row names is unchanged.
assert_eq "the shipped migrations.json: eight KEEP_D10 rows, other keys unchanged" \
  "$(env CLAUDE_PLUGIN_ROOT="$T_REPO" DRUPILOT_OLD_PHP=8.4 "$T_SH" -c '. "$1"; config_get DRUPILOT_CORE_TARGET_STRATEGY x > /dev/null; printf "%s|%s" "$_DRUPILOT_ALIAS_N" "$(config_get DRUPILOT_PHP_TARGET x)"' _ "$T_LIB" 2>&1)" "8|8.3"
assert_eq "  an old name in use is warned about at source time" \
  "$(env CLAUDE_PLUGIN_ROOT="$T_REPO" DRUPILOT_KEEP_D10=yes "$T_SH" -c '. "$1"; printf "%s" "$_DRUPILOT_ALIAS_N"' _ "$T_LIB" 2>&1 | tr '\n' ' ')" \
  "$(printf '⚠️  DRUPILOT_KEEP_D10=yes is deprecated since 1.0.0 and will be removed in 2.0.0; use DRUPILOT_CORE_TARGET_STRATEGY=keep-previous\n8' | tr '\n' ' ')"
t_done
