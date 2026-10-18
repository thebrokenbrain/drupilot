#!/usr/bin/env bash
# run-phpcompat.sh (T-M5-05, ADR 0003), Docker-free: a host root (no DDEV)
# with a stub PHPCompatibility tree whose phpcs plays each outcome.
# - ok: testVersion L-U of the plan's window, PHPCompatibility alone without
#   polyfills, vendor/ and node_modules/ ignored, findings deduplicated,
#   PHPCS's Internal.* messages dropped, classed floor (a New* sniff, a
#   WARNING too)/removed/deprecated, the rules.json row named and covered when
#   the row is handled already, counts without the covered ones, the same
#   bytes twice, the pins and standards kept in the lock;
# - the polyfill rulesets the tree lists, never one it lacks;
# - degraded with detect-php-floor.sh's fallback (and exit 0): phpcs exit
#   255, 16 or 127, a report that is not JSON, an Internal.Exception, a tree
#   that is missing (--no-install), whose install fails (composer exit 100) or
#   leaves no pinned tree; a working install then runs;
# - skipped: an empty window, a module with no PHP-bearing file (phpcs never
#   runs), no PHP on a host root;
# - usage: --test-version L-U overrides the window, a bad one exits 1.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

R="$T_TMP/root"; S="web/modules/custom/pc"
mkdir -p "$R/web/core/lib" "$R/$S/src"
printf '{"name":"x/root"}\n' > "$R/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$R/web/core/lib/Drupal.php"
printf 'name: PC\ntype: module\ncore_version_requirement: ^10.3 || ^11\n' > "$R/$S/pc.info.yml"
printf '<?php\nfunction pc_f(string $x = NULL) { trigger_error("x", E_USER_ERROR); }\n' > "$R/$S/pc.module"
plan() {  # plan FLOOR FINAL RANGE POLYFILLS_JSON -> the frozen plan of pc
  DRUPILOT_PROJECT_DIR="$R" lock_set_json .upgrade_plan \
    "$(jq -n -c --arg l "$1" --arg p "$2" --arg c "$3" --argjson pf "$4" \
       '{subject: {machine_name: "pc"}, php: {floor: $l, final: $p}, range: {constraint: $c}, rector: {polyfills: $pf}}')" > /dev/null
}
plan 8.1 8.3 '^10.3 || ^11' '[]'
PINS="$(jq -c '.phpcompat.toolchain' "$T_REPO/config/toolchain-reference.json")"
T="$R/.drupilot/phpcompat"
# mktree -> the stub tree: composer.lock with the pins, a phpcs playing
# <root>/mode.
mktree() {
  mkdir -p "$T/vendor/bin"
  jq -n --argjson p "$PINS" '{packages: [], "packages-dev": [$p | to_entries[] | {name: .key, version: .value}]}' > "$T/composer.lock"
  cat > "$T/vendor/bin/phpcs" <<'STUB'
#!/bin/sh
d="$(cd "$(dirname "$0")/../../../.." && pwd)"; m="$(cat "$d/mode" 2>/dev/null)"
echo "$*" >> "$d/phpcs-calls"
if [ "$1" = "-i" ]; then echo "The installed coding standards are PHPCompatibility, PHPCompatibilitySymfonyPolyfillPHP84 and PHPCompatibilitySymfonyPolyfillPHP85"; exit 0; fi
case "$m" in
  crash) echo "PHP Fatal error: boom" >&2; exit 255;;
  nostd) echo 'ERROR: the "PHPCompatibility" coding standard is not installed.'; exit 16;;
  gone) echo "phpcs: not found" >&2; exit 127;;
  badjson) echo "not json"; exit 0;;
  internal) echo '{"totals":{"errors":1},"files":{"web/modules/custom/pc/pc.module":{"messages":[{"source":"Internal.Exception","type":"ERROR","line":1,"message":"Invalid range in provided PHPCompatibility testVersion"}]}}}'; exit 2;;
esac
cat <<'JSON'
{"totals":{"errors":2,"warnings":3},"files":{
 "web/modules/custom/pc/pc.module":{"messages":[
  {"source":"PHPCompatibility.FunctionDeclarations.RemovedImplicitlyNullableParam.Deprecated","type":"WARNING","line":2,"message":"Implicitly marking a parameter as nullable is deprecated since PHP 8.4."},
  {"source":"PHPCompatibility.ParameterValues.RemovedTriggerErrorLevel.Deprecated","type":"WARNING","line":2,"message":"Passing E_USER_ERROR to trigger_error() is deprecated since 8.4."},
  {"source":"PHPCompatibility.ParameterValues.RemovedTriggerErrorLevel.Deprecated","type":"WARNING","line":2,"message":"Passing E_USER_ERROR to trigger_error() is deprecated since 8.4."},
  {"source":"PHPCompatibility.TypeCasts.RemovedTypeCasts.integerDeprecated","type":"WARNING","line":3,"message":"The integer cast is deprecated since PHP 8.5"}]},
 "/var/www/html/web/modules/custom/pc/src/A.php":{"messages":[
  {"source":"PHPCompatibility.Classes.NewReadonlyClasses.Found","type":"ERROR","line":3,"message":"Readonly classes are not present in PHP version 8.1 or earlier"},
  {"source":"PHPCompatibility.FunctionUse.RemovedFunctions.eachDeprecatedRemoved","type":"ERROR","line":5,"message":"Function each() is removed since PHP 8.0"},
  {"source":"PHPCompatibility.IniDirectives.NewIniDirectives.zend_assertionsFound","type":"WARNING","line":7,"message":"The ini directive is not present in PHP 8.0 or earlier"},
  {"source":"Internal.LineEndings.Mixed","type":"WARNING","line":1,"message":"File has mixed line endings."},
  {"source":"Internal.NoCodeFound","type":"WARNING","line":1,"message":"No PHP code was found in this file."}]}}}
JSON
exit 2
STUB
  chmod +x "$T/vendor/bin/phpcs"
}
mktree
cp -R "$T" "$T_TMP/tree-good"
STUBS="$T_TMP/stubs"; mkdir -p "$STUBS"
printf '#!/bin/sh\nexit 0\n' > "$STUBS/php"; chmod +x "$STUBS/php"
# composer: exit 100 unless <root>/composer-ok exists; then it builds a tree
# without the pinned lock, or with <root>/composer-good the whole tree.
cat > "$STUBS/composer" <<EOF
#!/bin/sh
[ -f "$R/composer-ok" ] || { echo "network down" >&2; exit 100; }
mkdir -p "$T/vendor/bin"
[ -f "$R/composer-good" ] && cp -R "$T_TMP/tree-good/." "$T/"
exit 0
EOF
chmod +x "$STUBS/composer"
PATH="$STUBS:$PATH"
pc() { local m="$1"; shift; printf '%s' "$m" > "$R/mode"; t_run "$T_SH" "$T_REPO/scripts/analysis/run-phpcompat.sh" --subject "$R/$S" --json "$@"; }

pc ok
assert_eq "ok: exit 0, the plan's window L-U, PHPCompatibility alone" \
  "$T_RC|$(jq -c '[.status, .reason, .test_version, .standards, .alpha]' "$T_OUT")" '0|["ok",null,"8.1-8.5",["PHPCompatibility"],true]'
assert_eq "  deduplicated, Internal.* dropped, paths subject-relative, classed (a New* WARNING is floor)" \
  "$(jq -c '[.findings[] | [.file, .line, .kind, (.source | split(".") | .[2])]]' "$T_OUT")" \
  '[["pc.module",2,"deprecated","RemovedImplicitlyNullableParam"],["pc.module",2,"deprecated","RemovedTriggerErrorLevel"],["pc.module",3,"deprecated","RemovedTypeCasts"],["src/A.php",3,"floor","NewReadonlyClasses"],["src/A.php",5,"removed","RemovedFunctions"],["src/A.php",7,"floor","NewIniDirectives"]]'
assert_eq "  rules.json rows: the nullable fix (the compat pass reaches U 8.5) and each() (php-target reports it) are covered; the 8.5 cast, which php-target does not report at P 8.3, is not" \
  "$(jq -c '[.findings[] | [.rule, .covered]]' "$T_OUT")" '[["p84-implicit-nullable",true],[null,false],["p85-cast-names",false],[null,false],["removed-each",true],[null,false]]'
assert_eq "  counts leave the covered ones out" "$(jq -c '.counts' "$T_OUT")" '{"covered":2,"deprecated":2,"floor":2,"removed":0}'
first="$(cat "$T_OUT")"
pc ok
assert_eq "  the same bytes twice" "$([[ "$(cat "$T_OUT")" == "$first" ]] && echo same)" "same"
assert_eq "  the pins and standards in the lock" \
  "$(jq -c '[.phpcompat.packages["phpcompatibility/php-compatibility"], .phpcompat.standards]' "$(DRUPILOT_PROJECT_DIR="$R" drupilot_lock_file)")" \
  '["10.0.0-alpha2",["PHPCompatibility"]]'
assert_eq "  testVersion, the PHP extensions and the ignored dirs on the command line" \
  "$(grep -c -- '--runtime-set testVersion 8.1-8.5 --extensions=php,module,inc,install,theme,profile,engine --ignore=/vendor/,/node_modules/,/.git/ --report=json' "$R/phpcs-calls")" "2"

plan 8.1 8.5 '^10.3 || ^11' '[]'
pc ok
assert_eq "at P 8.5 php-target reports the cast: covered" "$(jq -c '[.findings[] | select(.rule == "p85-cast-names") | .covered]' "$T_OUT")" '[true]'

# The polyfill rulesets: those the tree lists.
plan 8.3 8.4 '^11.3 || ^12' '["symfony/polyfill-php84","symfony/polyfill-php86"]'
pc ok
assert_eq "polyfills: PHPCompatibilitySymfonyPolyfillPHP84, never a ruleset the tree lacks (php86)" \
  "$(jq -c '[.test_version, .standards]' "$T_OUT")" '["8.3-8.5",["PHPCompatibility","PHPCompatibilitySymfonyPolyfillPHP84"]]'
plan 8.1 8.3 '^10.3 || ^11' '[]'

# Degraded: the fallback, exit 0.
for c in "crash|exit 255" "nostd|exit 16" "gone|exit 127" "badjson|no-json-report" "internal|internal-exception"; do
  pc "${c%%|*}"
  assert_eq "${c%%|*}: degraded (${c#*|}), detect-php-floor.sh's fallback, no finding" \
    "$T_RC|$(jq -c '[.status, (.reason | startswith("'"${c#*|}"'")), (.fallback.method // null), (.findings | length)]' "$T_OUT")" \
    '0|["degraded",true,"heuristic-scan",0]'
done
mv "$T" "$T_TMP/tree"
pc ok --no-install
assert_eq "no tree, --no-install: degraded tree-missing" "$T_RC|$(jq -c '[.status, .reason]' "$T_OUT")" '0|["degraded","tree-missing"]'
pc ok
assert_eq "an install that fails (composer exit 100): degraded" "$T_RC|$(jq -c '[.status, .reason]' "$T_OUT")" '0|["degraded","install-failed (exit 100)"]'
assert_eq "  allow-plugins written before the require" \
  "$(jq -r '.config["allow-plugins"]["dealerdirect/phpcodesniffer-composer-installer"]' "$T/composer.json")" "true"
touch "$R/composer-ok"
pc ok
assert_eq "an install that leaves no pinned tree: degraded install-incomplete" "$(jq -c '[.status, .reason]' "$T_OUT")" '["degraded","install-incomplete"]'
touch "$R/composer-good"
pc ok
assert_eq "a working install: the run goes on, ok" "$T_RC|$(jq -c '[.status, .counts.floor]' "$T_OUT")" '0|["ok",2]'
rm -f "$R/composer-ok" "$R/composer-good"

# Skipped.
E="web/modules/custom/cfg"; mkdir -p "$R/$E/vendor/x"
printf 'name: Cfg\ntype: module\ncore_version_requirement: ^10.3 || ^11\n' > "$R/$E/cfg.info.yml"
printf '<?php\n$x = 1;\n' > "$R/$E/vendor/x/x.php"
n0="$(grep -c . "$R/phpcs-calls")"
t_run "$T_SH" "$T_REPO/scripts/analysis/run-phpcompat.sh" --subject "$R/$E" --json
assert_eq "a module with no PHP-bearing file (vendor/ aside): skipped, phpcs never runs" \
  "$T_RC|$(jq -c '[.status, .reason, .fallback]' "$T_OUT")|$(( $(grep -c . "$R/phpcs-calls") - n0 ))" '0|["skipped","no-php-files",null]|0'
plan 9.0 9.1 '^10.3 || ^11' '[]'
pc ok
assert_eq "an empty window: skipped" "$T_RC|$(jq -c '[.status, .reason, .test_version, .fallback]' "$T_OUT")" '0|["skipped","empty-php-window",null,null]'
plan 8.1 8.3 '^10.3 || ^11' '[]'
printf 'ok' > "$R/mode"
t_run env PATH="$(t_path_without php)" "$T_SH" "$T_REPO/scripts/analysis/run-phpcompat.sh" --subject "$R/$S" --json
assert_eq "no PHP on a host root: skipped" "$T_RC|$(jq -c '[.status, .reason]' "$T_OUT")" '0|["skipped","no-php"]'

# Usage.
pc ok --test-version 8.2-8.4
assert_eq "--test-version overrides the window" "$(jq -r '.test_version' "$T_OUT")" "8.2-8.4"
assert_exit "a bad --test-version: exit 1" 1 "$T_SH" "$T_REPO/scripts/analysis/run-phpcompat.sh" --subject "$R/$S" --test-version 8.2
assert_exit "no --subject: exit 1" 1 "$T_SH" "$T_REPO/scripts/analysis/run-phpcompat.sh" --json
t_done
