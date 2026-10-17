#!/usr/bin/env bash
# The Rector rule audit and the compat pass it feeds (T-M5-03, T-M5-04,
# AR-11, ADR 0030), Docker-free with a stub php:
# - rector-rule-audit.sh runs scripts/php/rule-audit.php once per Rector
#   version, keeps the result in the root's lock (.rector_rule_audit), prints
#   the same bytes from the lock, runs again for another version or with
#   --refresh, lists the rules.json rows the PHP sets do not register, and
#   refuses a root without Rector (2) or a failing helper (2, nothing kept);
# - U is bounded leg by leg (range_php_ceiling); a frozen plan gets today's
#   skips next to its own;
# - rector_compat_list drops what the audit does not know and what the
#   floor's level set already runs; rector_compat_php_id takes the audited
#   min_php, else the deprecation;
# - rector_polyfills_block lists the plan's polyfills, or an explicit empty
#   list;
# - without rector/rector in composer.lock, the VersionResolver's version keys
#   the cache; lock_show prints the audit as its version and rule count.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

R="$T_TMP/root"; mkdir -p "$R/vendor/rector/rector"
lockv() { jq -n --arg v "$1" '{packages: [], "packages-dev": [{name: "rector/rector", version: $v}]}' > "$R/composer.lock"; }
lockv 2.6.1
NULLABLE='Rector\Php84\Rector\Param\ExplicitNullableParamTypeRector'
SETACC='Rector\Php81\Rector\MethodCall\RemoveReflectionSetAccessibleCallsRector'
# A stub php: the audit of a Rector with two rules; every call is counted.
STUBS="$T_TMP/stubs"; mkdir -p "$STUBS"
jq -n -c --arg n "$NULLABLE" --arg s "$SETACC" '{rector_version: "2.6.1", rules: [
  {rule: $n, sets: ["PHP_84"], min_php: "8.4", polyfill: null, interfaces: ["Rector\\VersionBonding\\Contract\\MinPhpVersionInterface"]},
  {rule: $s, sets: ["PHP_81"], min_php: "8.1", polyfill: null, interfaces: []}]}' > "$T_TMP/audit.json"
cat > "$STUBS/php" <<EOF
#!/bin/sh
echo x >> "$T_TMP/php-calls"
[ -f "$T_TMP/php-fail" ] && { echo "boom" >&2; exit 255; }
cat "$T_TMP/audit.json"
EOF
chmod +x "$STUBS/php"
PATH="$STUBS:$PATH"
calls() { if [[ -f "$T_TMP/php-calls" ]]; then grep -c . "$T_TMP/php-calls"; else echo 0; fi; }
au() { t_run "$T_SH" "$T_REPO/scripts/analysis/rector-rule-audit.sh" --root "$R" "$@"; }

au --json
assert_eq "first run: the helper runs once, exit 0" "$T_RC|$(calls)" "0|1"
first="$(cat "$T_OUT")"
assert_eq "the audit's rules and version" "$(jq -c '[.tool, .rector_version, [.rules[].min_php]]' "$T_OUT")" '["rector-rule-audit","2.6.1",["8.4","8.1"]]'
assert_eq "the helper is staged at the root" "$([[ -f "$R/.drupilot/runtime/rule-audit.php" ]] && echo yes)" "yes"
assert_eq "the lock keeps it for its Rector" "$(jq -c '[.rector_rule_audit.rector_version, (.rector_rule_audit.rules | length)]' "$(DRUPILOT_PROJECT_DIR="$R" drupilot_lock_file)")" '["2.6.1",2]'
assert_eq "missing: the rules.json rows the PHP sets do not register" \
  "$(jq -c '[.missing[] | select(.id == "p84-implicit-nullable" or .id == "deny-sleep-to-serialize") | .id]' "$T_OUT")" '["deny-sleep-to-serialize"]'
au --json
assert_eq "second run: from the lock, the same bytes, no php" "$T_RC|$(calls)|$([[ "$(cat "$T_OUT")" == "$first" ]] && echo same)" "0|1|same"
au --refresh --json
assert_eq "--refresh audits again, the same bytes" "$T_RC|$(calls)|$([[ "$(cat "$T_OUT")" == "$first" ]] && echo same)" "0|2|same"
au
assert_eq "the text form" "$(sed -n '1p' "$T_OUT")" "Rector 2.6.1: 2 rules in its PHP sets"
lockv 2.6.2
assert_eq "another Rector: the lock's audit does not count" "$(rector_audit_cached "$R")" ""
au --json
assert_eq "  and the helper runs for it" "$T_RC|$(calls)|$(jq -r '.rector_rule_audit.rector_version' "$(DRUPILOT_PROJECT_DIR="$R" drupilot_lock_file)")" "0|3|2.6.2"
touch "$T_TMP/php-fail"; lockv 2.7.0
au --json
assert_eq "a failing helper: exit 2, nothing kept" "$T_RC|$(jq -r '.rector_rule_audit.rector_version' "$(DRUPILOT_PROJECT_DIR="$R" drupilot_lock_file)")" "2|2.6.2"
rm -f "$T_TMP/php-fail"; lockv 2.6.1
# composer.lock without rector/rector: the version Rector's VersionResolver
# declares keys the cache.
jq -n '{packages: []}' > "$R/composer.lock"
mkdir -p "$R/vendor/rector/rector/src/Application"
printf "<?php\nfinal class VersionResolver {\n    public const PACKAGE_VERSION = '2.6.1';\n}\n" > "$R/vendor/rector/rector/src/Application/VersionResolver.php"
assert_eq "rector_installed_version: the VersionResolver's" "$(rector_installed_version "$R")" "2.6.1"
au --json
assert_eq "  the audit is kept under it" "$T_RC|$(jq -r '.rector_rule_audit.rector_version' "$(DRUPILOT_PROJECT_DIR="$R" drupilot_lock_file)")" "0|2.6.1"
c0="$(calls)"; au --json
assert_eq "  and read back from the lock (no php)" "$T_RC|$(( $(calls) - c0 ))" "0|0"
lockv 2.6.1
# /drupilot-status prints the lock: the audit only as its version and count.
assert_eq "lock_show: the audit summarized" "$(lock_show "$R" | jq -c '.rector_rule_audit')" '{"rector_version":"2.6.1","rules":2}'
E="$T_TMP/norector"; mkdir -p "$E"
t_run "$T_SH" "$T_REPO/scripts/analysis/rector-rule-audit.sh" --root "$E" --json
assert_eq "a root without Rector: exit 2" "$T_RC" "2"
assert_exit "no --root: exit 1" 1 "$T_SH" "$T_REPO/scripts/analysis/rector-rule-audit.sh" --json

# The compat list (L 8.1, U 8.5): the plan's rules, minus what the audit does
# not know or puts at or below the floor's level set.
au --json
A="$(rector_audit_cached "$R")"
PLAN='{"php":{"floor":"8.1","final":"8.3"},"range":{"constraint":"^10.3 || ^11"},"rector":{"compat_rules":null,"polyfills":null}}'
short() { jq -r 'map(split("\\") | last) | join(",")'; }
assert_eq "without the audit: config/php/rules.json alone" "$(rector_compat_list "$PLAN" 8.1 8.5 | jq 'length > 4')" "true"
L="$(rector_compat_list "$PLAN" 8.1 8.5 "$A")"
assert_eq "with it: only the rules it knows, not the one php81 holds" "$(printf '%s' "$L" | short)" "ExplicitNullableParamTypeRector"
assert_eq "withPhpVersion: the audited min_php" "$(rector_compat_php_id "$L" "$A")" "PHP_84"
assert_eq "  the audit wins over the deprecation (setAccessible: 8.1 audited, 8.5 deprecated)" \
  "$(rector_compat_php_id "[\"${SETACC//\\/\\\\}\"]" "$A")" "PHP_81"
assert_eq "  without the audit, the deprecation (8.5 for the setAccessible fix)" \
  "$(rector_compat_php_id "[\"${SETACC//\\/\\\\}\"]")" "PHP_85"
assert_eq "  an empty list has none" "$(rector_compat_php_id '[]' || echo none)" "none"
assert_eq "a plan's own compat_rules win" "$(rector_compat_list '{"rector":{"compat_rules":["X\\Y"]}}' 8.1 8.5)" '["X\\Y"]'
assert_eq "rector_compat_needed: a list with a rule" "$(rector_compat_needed "$L" && echo yes)|$(rector_compat_needed '[]' || echo no)" "yes|no"
assert_eq "the rules block: one quoted FQCN per line, backslashes doubled" "$(rector_compat_rules_block "$L")" \
  "  'Rector\\\\Php84\\\\Rector\\\\Param\\\\ExplicitNullableParamTypeRector',"

# U leg by leg (range_php_ceiling): a leg the data does not hold (^9.5) never
# hides the others, so the plan keeps the 8.4/8.5 fixes.
assert_eq "range_php_ceiling: ^9.5 || ^10 || ^11 reaches 8.5" "$(range_php_ceiling '^9.5 || ^10 || ^11')" "8.5"
assert_eq "  a range with no known leg: none" "$(range_php_ceiling '^9')" ""
M="$T_TMP/m95"; mkdir -p "$M"
printf 'name: M\ntype: module\ncore_version_requirement: ^9.5 || ^10 || ^11\n' > "$M/m95.info.yml"
printf '<?php\nfunction m95_f(string $x = NULL) { return $x; }\n' > "$M/m95.module"
DRUPILOT_PHP_TARGET=8.3 t_run "$T_SH" "$T_REPO/scripts/analysis/upgrade-path.sh" --subject "$M" --phase draft --json
assert_eq "a ^9.5 || ^10 || ^11 plan at P 8.3 keeps the implicit-nullable fix" \
  "$T_RC|$(jq -c '[.range.constraint, (.rector.compat_rules | index("Rector\\Php84\\Rector\\Param\\ExplicitNullableParamTypeRector") != null)]' "$T_OUT")" \
  '0|["^9.5 || ^10 || ^11",true]'

# A frozen plan's skips: its own, then today's it lacks (the deny list is a
# floor), so the polyfills an old plan now opens never run a denied rule.
DEP='DeprecatedAnnotationToDeprecatedAttributeRector'
assert_eq "an old frozen plan: the new deny row is skipped too" \
  "$(rector_skip_block '{"range":{"constraint":"^11.3"},"rector":{"skip":["Rector\\Php81\\Rector\\Array_\\ArrayToFirstClassCallableRector"],"polyfills":null}}' | grep -c "$DEP")" "1"
assert_eq "  a plan's own skip comes first, today's follow, none twice" \
  "$(rector_skip_block '{"rector":{"skip":["A\\B","Rector\\Php85\\Rector\\Class_\\SleepToSerializeRector"],"polyfills":[]}}' | sed -n '1p')|$(rector_skip_block '{"rector":{"skip":["A\\B","Rector\\Php85\\Rector\\Class_\\SleepToSerializeRector"],"polyfills":[]}}' | grep -c SleepToSerializeRector)|$(rector_skip_block '{"rector":{"skip":["A\\B"],"polyfills":[]}}' | grep -c "$DEP")" \
  "  'A\\\\B',|1|1"

# The polyfills block.
assert_eq "^10.3 || ^11: an explicit empty list" "$(rector_polyfills_block "$PLAN" | grep -c 'polyfillPackages(\[\]);')" "1"
assert_eq "^11.3 || ^12: php84 and php85" \
  "$(rector_polyfills_block '{"range":{"constraint":"^11.3 || ^12"}}' | sed -n "s/^      '\(.*\)',\$/\1/p" | tr '\n' ' ')" \
  "symfony/polyfill-php84 symfony/polyfill-php85 "
assert_eq "the plan's own list wins" \
  "$(rector_polyfills_block '{"range":{"constraint":"^10.3 || ^11"},"rector":{"polyfills":["symfony/polyfill-php84"]}}' | grep -c "'symfony/polyfill-php84',")" "1"
assert_eq "guarded: a Rector without polyfillPackages() keeps its own" "$(rector_polyfills_block "$PLAN" | grep -c "method_exists(\$rectorConfig, 'polyfillPackages')")" "1"
t_done
