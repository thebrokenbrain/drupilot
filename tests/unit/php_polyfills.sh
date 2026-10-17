#!/usr/bin/env bash
# Core polyfills (T-M5-08, ADR 0029) and detect-php-floor.sh's 8.5 row:
# - core_range_polyfills: the symfony/polyfill-phpXY packages every core minor
#   of a range provides (required by every tag of the minor, or native at the
#   minor's minimum PHP) and their unconditional functions: none for
#   ^10.3 || ^11, php84 from ^11.2, php84 and php85 for ^11.3 || ^12 (12.0
#   needs PHP 8.5: native there), php86 too for ^12; a range with no data
#   minor gives none;
# - detect-php-floor.sh: without --range its output keeps the 0.9 shape; with
#   --range, a polyfilled function's signal is kept, marked polyfilled, and
#   does not raise the floor, while one no polyfill provides does; the mb_*
#   functions (polyfilled only with ext-mbstring) always count;
# - core-strategy.sh and the plan's L judge the floor with the range's polyfills;
# - functions are searched as calls in the code only (a comment or a string
#   naming one is no call; a path with a colon is kept);
# - the 8.5 row: the pipe operator and the (void) cast in the code only (a
#   regex, a string or a comment is no signal), array_first(); an attribute
#   (an older PHP ignores it), a method call, a static call, a definition and a
#   function the module defines itself are no signal; mb_str_pad() is 8.3.
#   Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

p() { core_range_polyfills "$1" | jq -c '.packages'; }
assert_eq "^10.3 || ^11: no polyfill every core requires" "$(p '^10.3 || ^11')" '[]'
assert_eq "^11.2: php84" "$(p '^11.2')" '["symfony/polyfill-php84"]'
assert_eq "^11.3 || ^12: php84 and php85 (native on 12.0's PHP 8.5)" "$(p '^11.3 || ^12')" '["symfony/polyfill-php84","symfony/polyfill-php85"]'
assert_eq "^12: php86 too" "$(p '^12')" '["symfony/polyfill-php84","symfony/polyfill-php85","symfony/polyfill-php86"]'
assert_eq "^9 (no data minor): none" "$(core_range_polyfills '^9')" '{"functions":[],"packages":[]}'
assert_eq "^9.5 || ^11.2 (a major with no data): none" "$(core_range_polyfills '^9.5 || ^11.2')" '{"functions":[],"packages":[]}'
assert_eq "^11.2: the unconditional functions only (no mb_*)" "$(core_range_polyfills '^11.2' | jq -c '.functions')" \
  '["array_all","array_any","array_find","array_find_key","fpow"]'

S="$T_TMP/m"; mkdir -p "$S"
printf 'name: M\ntype: module\n' > "$S/m.info.yml"
printf '<?php\nfunction m_f(array $a) { return array_find($a, fn ($x) => $x > 1); }\n' > "$S/m.module"
df() { t_run "$T_SH" "$T_REPO/scripts/analysis/detect-php-floor.sh" --subject "$S" --json "$@"; }
df
assert_eq "no --range: array_find() raises the floor to 8.4, the 0.9 keys only" \
  "$T_RC|$(jq -c '[.floor, (keys | sort), [.signals[] | keys | sort]]' "$T_OUT")" \
  '0|["8.4",["floor","method","scanned_files","signals","target","target_compatible"],[["location","pattern","version"]]]'
df --range '^11.2'
assert_eq "^11.2: array_find() is polyfilled: floor 8.1, the signal kept and marked" \
  "$(jq -c '[.floor, .range, .polyfills, [.signals[] | [.version, .location, .polyfilled]]]' "$T_OUT")" \
  '["8.1","^11.2",["symfony/polyfill-php84"],[["8.4","m.module:2",true]]]'
df --range '^10.3 || ^11'
assert_eq "^10.3 || ^11: no polyfill, floor 8.4" "$(jq -r '.floor' "$T_OUT")" "8.4"
printf '<?php\nfunction m_t(string $s) { return mb_trim($s); }\n' > "$S/t.php"
df --range '^11.2'
assert_eq "mb_trim() (polyfilled only with ext-mbstring) still counts: floor 8.4 at t.php" \
  "$(jq -c '[.floor, [.signals[] | select(.version == "8.4") | [.location, (.polyfilled // false)]]]' "$T_OUT")" \
  '["8.4",[["t.php:2",false]]]'
rm -f "$S/t.php"

# The 8.5 row: the syntax in the code only; an attribute, a method call, a
# definition and a function the module defines are no signal; mb_str_pad()
# is PHP 8.3.
printf '<?php\n$ok = $a || $b;\n' > "$S/or.php"
df
assert_eq "a || operator is no pipe operator" "$(jq -r '.floor' "$T_OUT")" "8.4"
for c in '$n = "x" |> strlen(...);' '(void) m_f([]);' '$f = array_first([1]);'; do
  printf '<?php\n%s\n' "$c" > "$S/n.php"
  df --range '^11.3'
  assert_eq "8.5: $c" "$(jq -c '[.floor, ([.signals[] | select(.version == "8.5") | .location] | length)]' "$T_OUT")" '["8.5",1]'
done
for c in '$re = "/(\\s|>)|>=/";' '// a |> b in a comment' "\$t = 'x |> y';" '/** (void) nothing to return */' \
         '#[\NoDiscard]' '$o->array_first([1]);' 'Foo::array_last([1]);'; do
  printf '<?php\n%s\n' "$c" > "$S/n.php"
  df --range '^11.3'
  assert_eq "no 8.5 signal: $c" "$(jq -c '[.floor, ([.signals[] | select(.version == "8.5")] | length)]' "$T_OUT")" '["8.1",0]'
done
printf '<?php\nfunction array_first(array $a) { return $a[0] ?? null; }\n$x = array_first([1]);\n' > "$S/n.php"
df --range '^11.3'
assert_eq "a function the module defines itself provides it" "$(jq -c '[.floor, ([.signals[] | select(.version == "8.5")] | length)]' "$T_OUT")" '["8.1",0]'
# Not hidden: a docblock naming the function, a class method of the same
# name; counted: a call after => or a ternary colon; fpow() and mb_ucfirst()
# are 8.4; a pipe into a string or an array callable is 8.5.
rm -f "$S/n.php" "$S/or.php"
printf '<?php\n/**\n * Finds the first item, with the PHP 8.4 function array_find().\n */\nclass U { public function array_find(array $a, $c) { return \\array_find($a, $c); } }\n' > "$S/u.php"
df --range '^10.3 || ^11'
assert_eq "a docblock and a class method of the same name hide no call: floor 8.4" "$(jq -r '.floor' "$T_OUT")" "8.4"
rm -f "$S/u.php"; printf '<?php\n$f = 1;\n' > "$S/m.module"
for c in "\$x = ['k'=>array_find(\$a, fn (\$v) => \$v)];" '$y = $c ?: array_any($a, fn ($v) => $v);' '$z = fpow(2, 3);' '$w = mb_ucfirst("a");'; do
  printf '<?php\n%s\n' "$c" > "$S/n.php"
  df --range '^10.3 || ^11'
  assert_eq "8.4: $c" "$(jq -r '.floor' "$T_OUT")" "8.4"
done
for c in "\$r = \"Hello\" |> 'strtoupper';" '$r = $s |> [$this, "m"];'; do
  printf '<?php\n%s\n' "$c" > "$S/n.php"
  df --range '^11.3'
  assert_eq "8.5: $c" "$(jq -r '.floor' "$T_OUT")" "8.5"
done
printf '<?php\n$p = mb_str_pad("x", 3);\n' > "$S/n.php"
df --range '^11.3'
assert_eq "mb_str_pad() is PHP 8.3" "$(jq -c '[.floor, [.signals[] | select(.pattern == "mb_str_pad()") | .version]]' "$T_OUT")" '["8.3",["8.3"]]'
printf '<?php\nset_error_handler(fn () => true);\n$h = get_error_handler();\n' > "$S/n.php"
df --range '^11.3'
assert_eq "get_error_handler() on ^11.3 (polyfill-php85): no 8.5 floor" "$(jq -c '[.floor, [.signals[] | select(.version == "8.5") | .polyfilled]]' "$T_OUT")" '["8.1",[true]]'
# A function named in a comment or a string is no call; a path with ':' keeps
# its calls.
printf '<?php\n// Finds it with array_find() on PHP 8.4.\n$s = "array_find($a, $f)";\n/* array_any($a, $f) */\n' > "$S/n.php"
df --range '^10.3 || ^11'
assert_eq "a comment or a string naming array_find() is no call" "$(jq -c '[.floor, (.signals | length)]' "$T_OUT")" '["8.1",0]'
printf '<?php\n// Validates it with json_validate() and str_increment() on PHP 8.3.\n$j = "json_validate($s)";\n' > "$S/n.php"
df --range '^10.3 || ^11'
assert_eq "  the 8.3/8.2 stdlib rows too (json_validate, str_increment)" "$(jq -c '[.floor, (.signals | length)]' "$T_OUT")" '["8.1",0]'
mkdir -p "$S/a:b"; printf '<?php\n\n$x = array_find([1], fn ($v) => $v);\n' > "$S/a:b/c.php"
df --range '^10.3 || ^11'
assert_eq "a call in a file whose path holds ':'" "$(jq -c '[.floor, [.signals[].location]]' "$T_OUT")" '["8.4",["a:b/c.php:3"]]'
printf '<?php\n\nreadonly class C {}\n' > "$S/a:b/c.php"
df
assert_eq "  a syntax signal there too" "$(jq -c '[.signals[].location]' "$T_OUT")" '["a:b/c.php:3"]'
printf '<?php\n\n$y = \\Drupal::service("x"); $x = array_find([1], fn ($v) => $v);\n' > "$S/a:b/c.php"
df
assert_eq "  a backslash on the line keeps the call" "$(jq -c '[.floor, [.signals[].location]]' "$T_OUT")" '["8.4",["a:b/c.php:3"]]'
rm -rf "$S/a:b"

# The consumers judge the floor with the range's polyfills: core-strategy.sh
# (its second scan, with the recommended range) and the plan's L.
P="$T_TMP/p"; mkdir -p "$P"
printf 'name: P\ntype: module\ncore_version_requirement: ^11.2\n' > "$P/p.info.yml"
printf '<?php\nfunction p_f(array $a) { return array_find($a, fn ($x) => $x > 1); }\n' > "$P/p.module"
DRUPILOT_PHP_TARGET=8.3 DRUPILOT_CORE_TARGET_STRATEGY=auto t_run "$T_SH" "$T_REPO/scripts/analysis/core-strategy.sh" --subject "$P" --json
assert_eq "core-strategy, declared ^11.2: array_find() is polyfilled, PHP 8.3 is compatible" \
  "$(jq -c '[.recommended_core_version_requirement, .php_floor_detected, .php_floor_target_compatible]' "$T_OUT")" '["^11.2","8.1",true]'
DRUPILOT_PHP_TARGET=8.3 DRUPILOT_CORE_TARGET_STRATEGY=d11-only t_run "$T_SH" "$T_REPO/scripts/analysis/core-strategy.sh" --subject "$P" --json
assert_eq "core-strategy, ^11 (11.0 ships no polyfill-php84): floor 8.4, PHP 8.3 is not compatible" \
  "$(jq -c '[.recommended_core_version_requirement, .php_floor_detected, .php_floor_target_compatible]' "$T_OUT")" '["^11","8.4",false]'
for r in '^11.2;8.3' '^10.3 || ^11;8.4'; do
  DRUPILOT_PHP_TARGET=8.4 t_run "$T_SH" "$T_REPO/scripts/analysis/upgrade-path.sh" --subject "$P" --phase draft --range "${r%;*}" --json
  assert_eq "the plan's L on ${r%;*}: ${r#*;}" "$(jq -r '.php.floor' "$T_OUT")" "${r#*;}"
done
t_done
