#!/usr/bin/env bash
# The backwards-compatible rewrites and the floor (lab L-1.0-D9, optimizedb):
# - rector_bc_block: a plan whose rector.bc is off (a range admitting a core
#   older than 10.1.3, where DeprecationHelper does not exist) turns
#   drupal-rector's own default off, so no DeprecationHelper call is written;
#   on, from min_core; no rector.bc (the render fallback), nothing (0.9);
# - php_bc_fallback_calls: each call of the given functions with the version
#   of the DeprecationHelper fallback closure that holds it, read at its line
#   and column after a comment or a heredoc; a call in the current callable,
#   outside the call, or in a first-class callable passed as the fallback is
#   in none; methods, statics, declarations and longer names are not calls;
#   named arguments are skipped;
# - run-phpstan.sh --json marks a "Function X not found." only when every call
#   of X on its line is in a fallback, with their highest version, and no
#   more messages name X there than calls were found (a call inside an
#   interpolated string is not seen); a trait's key is marked too;
# - classify-deprecations.sh: a marked one whose deprecated version is below
#   T.0.0 is guarded (reported, not blocking), else it stays blocking; a
#   symbol with both kinds of occurrence gets a row per class;
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

# php_bc_fallback_calls: every call of the names, with the version of the
# fallback closure that holds it ("-": in none). The comment and the heredoc
# before the calls shorten lines in the blanked copy: the version is still
# read at its line and column.
M="$T_TMP/root/web/modules/custom/m"; mkdir -p "$M/src" "$T_TMP/root/web/core/lib" "$T_TMP/root/vendor/bin"
printf 'name: M\ntype: module\ncore_version_requirement: ^10.2 || ^11\n' > "$M/m.info.yml"
cat > "$M/src/A.php" <<'EOF'
<?php
// A line comment that the blanked copy cuts off.
$s = <<<TXT
A heredoc body.
TXT;
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
  $g = DeprecationHelper::backwardsCompatibleCall(\Drupal::VERSION, '10.2.0', fn() => ByteSizeMarkup::create($a), fn() => format_size($a)) . ' / ' . format_size($b);
  $h = DeprecationHelper::backwardsCompatibleCall(\Drupal::VERSION, '10.2.0', fn() => n1(), fn() => twice()) . DeprecationHelper::backwardsCompatibleCall(\Drupal::VERSION, '11.2.0', fn() => n2(), fn() => twice());
  $i = DeprecationHelper::backwardsCompatibleCall(\Drupal::VERSION, '10.2.0', ByteSizeMarkup::create(...), fcc_api(...));
  $j = DeprecationHelper::backwardsCompatibleCall(\Drupal::VERSION, '11.0.0', fn() => n3(), fn() => exact_api());
  $k = $o->format_size(1) . Foo::format_size(2) . format_size_local(3);
  $l = DeprecationHelper::backwardsCompatibleCall(\Drupal::VERSION, '10.2.0', fn() => strlen($a), fn() => interp_api($a)) . "{$this->wrap(interp_api($b))}";
}
function format_size($x) {}
EOF
php_code_lines "$M/src/A.php" > "$T_TMP/a.blank"
assert_eq "php_bc_fallback_calls: each call and the version of the fallback holding it" \
  "$(php_bc_fallback_calls "$T_TMP/a.blank" "$M/src/A.php" "format_size old_api new_api both twice fcc_api exact_api" | LC_ALL=C sort | tr '\t' '|' | tr '\n' ' ')" \
  "12|new_api|- 14|old_api|12.1.0 18|both|- 18|both|10.3.0 19|format_size|- 20|format_size|- 20|format_size|10.2.0 21|twice|10.2.0 21|twice|11.2.0 22|fcc_api|- 23|exact_api|11.0.0 8|format_size|10.3.0 "

# run-phpstan.sh --json: the marks.
mk_bin() { printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
STUBS="$T_TMP/stubs"; mkdir -p "$STUBS"
mk_bin "$STUBS/php" 'case "$1" in -r) echo 8.3.30;; -v) echo "PHP 8.3.30 (cli)";; esac; exit 0'
mk_bin "$STUBS/composer" 'echo "Composer version 2.8.0 2025-01-01 00:00:00"; exit 0'
r="$T_TMP/root"
printf '{"name":"x/root"}\n' > "$r/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$r/web/core/lib/Drupal.php"
F="/var/www/html/web/modules/custom/m/src/A.php"
nf() { printf '{"message": "Function %s not found.", "line": %s, "identifier": "function.notFound"}' "$1" "$2"; }
{ printf '{"totals": {"errors": 0, "file_errors": 12}, "files": {"%s": {"errors": 12, "messages": [' "$F"
  nf format_size 8; printf ','; nf new_api 12; printf ','; nf old_api 14; printf ','; nf both 18; printf ','; nf both 18; printf ','
  nf format_size 19; printf ','; nf format_size 20; printf ','; nf format_size 20; printf ','; nf twice 21; printf ','; nf twice 21; printf ','
  nf fcc_api 22; printf ','; nf exact_api 23; printf ','; nf interp_api 25; printf ','; nf interp_api 25; printf ']},'
  printf '"%s (in context of class Drupal\\\\m\\\\Foo)": {"errors": 1, "messages": [' "$F"; nf format_size 8; printf ']}}, "errors": []}\n'; } > "$T_TMP/stan.json"
mk_bin "$r/vendor/bin/phpstan" "cat '$T_TMP/stan.json'; exit 1"
t_run env PATH="$STUBS:$PATH" DRUPILOT_DETERMINISTIC=false "$T_SH" "$T_REPO/scripts/analysis/run-phpstan.sh" \
  --subject "$M" --json
assert_eq "run-phpstan: findings, exit 1" "$T_RC" "1"
jq '.' "$T_OUT" > "$T_TMP/marked.json"
assert_eq "  marked: a message whose every call on its line is in a fallback, with the highest version" \
  "$(jq -c --arg f "$F" '[.files[$f].messages[] | [.line, (.drupilot_guard.deprecated_version // null)]]' "$T_TMP/marked.json")" \
  '[[8,"10.3.0"],[12,null],[14,"12.1.0"],[18,null],[18,null],[19,null],[20,null],[20,null],[21,"11.2.0"],[21,"11.2.0"],[22,null],[23,"11.0.0"],[25,null],[25,null]]'
assert_eq "  a trait's key (its class context written with backslashes) is marked too" \
  "$(jq -c --arg f "$F (in context of class Drupal\\m\\Foo)" '[.files[$f].messages[] | (.drupilot_guard.deprecated_version // null)]' "$T_TMP/marked.json")" '["10.3.0"]'

# classify-deprecations.sh.
t_run "$T_SH" "$T_REPO/scripts/analysis/classify-deprecations.sh" --file "$T_TMP/marked.json" --target-major 11 --json
assert_eq "classify T 11: only the 10.3.0 fallback is guarded (11.2.0 and 11.0.0 run on 11.x, the 11.0.0 one on its betas)" \
  "$(jq -c '[.blocking, .counts.guarded, ([.guarded[] | [.symbol, .line, .action]] | unique)]' "$T_OUT")" \
  '[13,2,[["format_size",8,"report"]]]'
assert_eq "  a symbol guarded at one place and blocking at another: one row per class" \
  "$(jq -c '[.symbols[] | select(.symbol == "format_size") | [.class, .occurrences]]' "$T_OUT")" '[["hard",3],["guarded",2]]'
t_run "$T_SH" "$T_REPO/scripts/analysis/classify-deprecations.sh" --file "$T_TMP/marked.json" --target-major 12 --json
assert_eq "  T 12: below 12.0.0 is guarded (10.3.0, 11.2.0, 11.0.0), 12.1.0 still blocks" "$(jq -c '[.counts.guarded, .blocking]' "$T_OUT")" '[5,10]'
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
  "$(jq -c '[.findings[] | select(.class == "guarded") | [.symbol, .line, .severity]]' "$T_OUT")" '[["format_size",8,"info"]]'
jq '.' "$T_OUT" > "$T_TMP/findings.json"
t_run "$T_SH" "$T_REPO/scripts/ai/classify.sh" --findings "$T_TMP/findings.json" --json
assert_eq "  classify: deferred, not blocking" \
  "$(jq -c --slurpfile f "$T_TMP/findings.json" '([$f[0].findings[] | select(.class == "guarded") | .id]) as $g
     | [.items[] | select(.finding_ids | any(.[]; . as $x | $g | index($x))) | [.lane, .blocking]]' "$T_OUT")" '[["deferred",false]]'
t_done
