#!/usr/bin/env bash
# The backwards-compatible rewrites and the floor (lab L-1.0-D9, optimizedb):
# - rector_bc_block: a plan whose rector.bc is off (a range admitting a core
#   older than 10.1.3, where DeprecationHelper does not exist) turns
#   drupal-rector's own default off, so no DeprecationHelper call is written;
#   on, from min_core; no rector.bc (the render fallback), nothing (0.9);
# - php_bc_fallback_spans: each DeprecationHelper::backwardsCompatibleCall()
#   with its fourth argument's lines, its second argument and the functions
#   each callable calls (not a method, a static, a new); named arguments are
#   skipped;
# - run-phpstan.sh --json marks a "Function X not found." that only the
#   fallback calls (drupilot_guard), not one the current callable also calls,
#   nor one outside the call;
# - classify-deprecations.sh: a marked one whose deprecated version is at
#   most T.0.0 is guarded (reported, not blocking), else it stays blocking;
# - normalize-findings.sh: a guarded one is an info finding, deferred by
#   classify.sh;
# - the fix policy guards a soft deprecation with DeprecationHelper only
#   from 10.1.3 (the lowest core the range admits, to the patch).
# Docker-free: stub php, composer and phpstan.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
# shellcheck source=../../scripts/lib/php-scan.sh
. "$T_REPO/scripts/lib/php-scan.sh"

# rector_bc_block.
assert_match "bc off: drupal-rector's backwards compatibility turned off" \
  "$(rector_bc_block '{"rector":{"bc":{"enabled":false,"min_core":null}}}')" 'disableBackwardCompatibility\(\)'
assert_eq "  never on" "$(rector_bc_block '{"rector":{"bc":{"enabled":false,"min_core":null}}}' | grep -c 'enableBackwardCompatibility' || true)" "0"
assert_match "bc on: from min_core" "$(rector_bc_block '{"rector":{"bc":{"enabled":true,"min_core":"10.2"}}}')" \
  "enableBackwardCompatibility\(\)
      ->setMinimumCoreVersionSupported\('10.2.0'\)"
assert_eq "no rector.bc (the render fallback): nothing, drupal-rector's default" \
  "$(rector_bc_block "$(plan_render_fallback 11)")|$(plan_render_fallback 11 | jq -c '.rector.bc')" "|null"

# php_bc_fallback_spans.
M="$T_TMP/root/web/modules/custom/m"; mkdir -p "$M/src" "$T_TMP/root/web/core/lib" "$T_TMP/root/vendor/bin"
printf 'name: M\ntype: module\ncore_version_requirement: ^10.2 || ^11\n' > "$M/m.info.yml"
cat > "$M/src/A.php" <<'EOF'
<?php
use Drupal\Component\Utility\DeprecationHelper;
function f($length) {
  $a = ['size' => DeprecationHelper::backwardsCompatibleCall(\Drupal::VERSION, '10.3.0', fn() => \Drupal\Core\StringTranslation\ByteSizeMarkup::create($length), fn() => format_size($length))];
  $b = \Drupal\Component\Utility\DeprecationHelper::backwardsCompatibleCall(
    \Drupal::VERSION,
    "12.1.0",
    fn() => new_api($x),
    function () use ($x) {
      return old_api($x) . $obj->method() . Foo::bar() . new Baz();
    }
  );
  $c = DeprecationHelper::backwardsCompatibleCall(currentVersion: \Drupal::VERSION, deprecatedVersion: '10.1.0', currentCallable: fn() => x(), deprecatedCallable: fn() => y());
  $d = DeprecationHelper::backwardsCompatibleCall(\Drupal::VERSION, '10.3.0', fn() => both(1), fn() => both(2));
  $e = format_size(3);
}
EOF
php_code_lines "$M/src/A.php" > "$T_TMP/a.blank"
assert_eq "php_bc_fallback_spans: lines, deprecated version, fallback and current functions" \
  "$(php_bc_fallback_spans "$T_TMP/a.blank" "$M/src/A.php" | tr '\t' '|' | tr '\n' ' ')" \
  "4|4|10.3.0|format_size| 9|11|12.1.0|old_api|new_api 14|14|10.3.0|both|both "

# run-phpstan.sh --json: the marks.
mk_bin() { printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
STUBS="$T_TMP/stubs"; mkdir -p "$STUBS"
mk_bin "$STUBS/php" 'case "$1" in -r) echo 8.3.30;; -v) echo "PHP 8.3.30 (cli)";; esac; exit 0'
mk_bin "$STUBS/composer" 'echo "Composer version 2.8.0 2025-01-01 00:00:00"; exit 0'
r="$T_TMP/root"
printf '{"name":"x/root"}\n' > "$r/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$r/web/core/lib/Drupal.php"
F="/var/www/html/web/modules/custom/m/src/A.php"
jq -n --arg f "$F" '{totals: {errors: 0, file_errors: 5}, files: {($f): {errors: 5, messages: [
  {message: "Function format_size not found.", line: 4, identifier: "function.notFound"},
  {message: "Function old_api not found.", line: 10, identifier: "function.notFound"},
  {message: "Function new_api not found.", line: 8, identifier: "function.notFound"},
  {message: "Function both not found.", line: 14, identifier: "function.notFound"},
  {message: "Function format_size not found.", line: 15, identifier: "function.notFound"}]}}, errors: []}' > "$T_TMP/stan.json"
mk_bin "$r/vendor/bin/phpstan" "cat '$T_TMP/stan.json'; exit 1"
t_run env PATH="$STUBS:$PATH" DRUPILOT_DETERMINISTIC=false "$T_SH" "$T_REPO/scripts/analysis/run-phpstan.sh" \
  --subject "$M" --json
assert_eq "run-phpstan: findings, exit 1" "$T_RC" "1"
jq '.' "$T_OUT" > "$T_TMP/marked.json"
assert_eq "  marked: only what a fallback alone calls, with its deprecated version" \
  "$(jq -c --arg f "$F" '[.files[$f].messages[] | [.line, (.drupilot_guard.deprecated_version // null)]]' "$T_TMP/marked.json")" \
  '[[4,"10.3.0"],[8,null],[10,"12.1.0"],[14,null],[15,null]]'

# classify-deprecations.sh.
t_run "$T_SH" "$T_REPO/scripts/analysis/classify-deprecations.sh" --file "$T_TMP/marked.json" --target-major 11 --json
assert_eq "classify: format_size in the 10.3.0 fallback is guarded, the rest blocks" \
  "$(jq -c '[.blocking, .counts.guarded, [.guarded[] | [.symbol, .line, .action]]]' "$T_OUT")" \
  '[4,1,[["format_size",4,"report"]]]'
assert_eq "  a fallback a core of the target runs (12.1.0 on 11) still blocks" \
  "$(jq -c '[.unknown[] | select(.symbol == "old_api") | .class]' "$T_OUT")" '["unknown"]'
t_run "$T_SH" "$T_REPO/scripts/analysis/classify-deprecations.sh" --file "$T_TMP/marked.json" --target-major 12 --json
assert_eq "  T 12: still the 10.3.0 one alone (12.0 runs the 12.1.0 fallback)" "$(jq -c '[.counts.guarded, .blocking]' "$T_OUT")" '[1,4]'
jq --arg f "$F" 'del(.files[$f].messages[0])' "$T_TMP/marked.json" | jq '.files[].messages |= map(del(.drupilot_guard))' > "$T_TMP/plain.json"
t_run "$T_SH" "$T_REPO/scripts/analysis/classify-deprecations.sh" --file "$T_TMP/plain.json" --target-major 11 --json
assert_eq "  no mark: no guarded key, as before" "$(jq -c '[has("guarded"), (.counts | has("guarded"))]' "$T_OUT")" '[false,false]'

# The fix policy guards a soft deprecation only where DeprecationHelper
# exists: from 10.1.3, a patch release ('^10.1 || ^11' admits 10.1.0).
printf '{"files":{"a.php":{"messages":[{"message":"Call to deprecated function text_summary():\\nDeprecated in drupal:11.4.0 and is removed from drupal:13.0.0.","line":3}]}}}' > "$T_TMP/soft.json"
cg() { "$T_SH" "$T_REPO/scripts/analysis/classify-deprecations.sh" --file "$T_TMP/soft.json" --core-req "$1" --policy fix \
  --target-major 11 --json 2> /dev/null | jq -r '.soft[0].action'; }
assert_eq "fix policy: ^10.1 || ^11 defers, ^10.1.3 || ^11 guards" "$(cg '^10.1 || ^11')|$(cg '^10.1.3 || ^11')" "defer|fix-guarded"

# normalize-findings.sh: an info finding, deferred.
RAW="$T_TMP/raw"; mkdir -p "$RAW"
jq -n '{stage: "assess", subject: {machine_name: "m", path: "web/modules/custom/m"}, target_major: 11,
  tools: [{tool: "phpstan", file: "04-assess-phpstan.json", exit_code: 1}]}' > "$RAW/04-assess-index.json"
jq '.files |= with_entries(.key |= sub("^/var/www/html/"; ""))' "$T_TMP/marked.json" > "$RAW/04-assess-phpstan.json"
t_run "$T_SH" "$T_REPO/scripts/ai/normalize-findings.sh" --raw-dir "$RAW" --target-major 11 --soft-policy report --json
assert_eq "normalize: the guarded one is an info finding" \
  "$(jq -c '[.findings[] | select(.class == "guarded") | [.symbol, .line, .severity]]' "$T_OUT")" '[["format_size",4,"info"]]'
jq '.' "$T_OUT" > "$T_TMP/findings.json"
t_run "$T_SH" "$T_REPO/scripts/ai/classify.sh" --findings "$T_TMP/findings.json" --json
assert_eq "  classify: deferred, not blocking" \
  "$(jq -c --slurpfile f "$T_TMP/findings.json" '([$f[0].findings[] | select(.class == "guarded") | .id]) as $g
     | [.items[] | select(.finding_ids | any(.[]; . as $x | $g | index($x))) | [.lane, .blocking]]' "$T_OUT")" '[["deferred",false]]'
t_done
