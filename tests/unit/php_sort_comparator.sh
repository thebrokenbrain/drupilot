#!/usr/bin/env bash
# The bool sort comparators (lab L-1.0-D9, optimizedb): PHP 8.0 deprecated a
# usort()/uasort()/uksort() comparator that returns a bool, and no analyzer
# drupilot runs reported it.
# - php_sort_bool_comparator_lines finds the returns of an inline closure and
#   the body of an inline arrow function that return a comparison, true/false
#   or a negation; it leaves <=>, a ternary, an int expression, a closure or
#   arrow function declaring another return type, a named callback, a method
#   called usort, the returns of a nested closure, comments and strings alone;
# - php-target.sh reports each as the report-only row
#   p80-sort-bool-comparator (a warning whose fix runs on the floor); a row
#   naming a scan this drupilot does not have is listed as unsearched.
# Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
# shellcheck source=../../scripts/lib/php-scan.sh
. "$T_REPO/scripts/lib/php-scan.sh"

M="$T_TMP/sorty"; mkdir -p "$M/src"
printf 'name: Sorty\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$M/sorty.info.yml"
cat > "$M/src/Sorter.php" <<'EOF'
<?php
function f(array $tables, $sort) {
  usort($tables, function ($a, $b) use ($sort) {
    if ($sort == 'asc') {
      return $a['size_byte'] > $b['size_byte'];
    }

    return $a['size_byte'] < $b['size_byte'];
  });
  uasort($x, fn($a, $b) => $a['#weight'] >= $b['#weight']);
  uksort($y, static function (string $a, string $b): int { return $a > $b; });
  usort($z, function ($a, $b) { return $a <=> $b; });
  usort($z, function ($a, $b) { return ($a > $b) ? 1 : -1; });
  usort($z, function ($a, $b) { return strcmp($a, $b); });
  usort($z, 'my_cmp');
  usort($z, [$this, 'cmp']);
  $obj->usort($z, function ($a, $b) { return $a > $b; });
  usort($z, function ($a, $b) {
    $g = function ($q) { return $q > 1; };
    return ($a->w == $b->w);
  });
  \usort($z, fn ($a, $b): bool => !$a);
  USORT($z, function ($a, $b) { return TRUE; });
  usort($z, function ($a, $b) { return $a - $b; });
  usort($z, fn($a, $b) => $a->x?->y <=> $b->x?->y);
  // usort($z, function ($a, $b) { return $a > $b; });
  $s = "usort($z, function ($a, $b) { return $a > $b; })";
}
EOF
php_code_lines "$M/src/Sorter.php" > "$T_TMP/blank"
assert_eq "the comparators that return a bool, by line" \
  "$(php_sort_bool_comparator_lines "$T_TMP/blank" | tr '\n' ' ')" "5 8 10 20 22 23 "
assert_eq "a missing file: nothing, exit 0" "$(php_sort_bool_comparator_lines "$T_TMP/none"; echo "rc=$?")" "rc=0"

t_run "$T_SH" "$T_REPO/scripts/analysis/php-target.sh" --subject "$M" --floor 8.1 --target 8.3 --json
assert_eq "php-target: exit 0" "$T_RC" "0"
assert_eq "  one report-only warning per line, its fix runs on the floor" \
  "$(jq -c '[.findings[] | select(.id == "p80-sort-bool-comparator") | [.line, .class, .severity, .fix_at_floor, .deprecated_in]]' "$T_OUT")" \
  '[[5,"report-only","warning",true,"8.0"],[8,"report-only","warning",true,"8.0"],[10,"report-only","warning",true,"8.0"],[20,"report-only","warning",true,"8.0"],[22,"report-only","warning",true,"8.0"],[23,"report-only","warning",true,"8.0"]]'
assert_eq "  the row is searched" "$(jq -c '.unsearched | index("p80-sort-bool-comparator")' "$T_OUT")" "null"

# A scan this drupilot does not have: unsearched, never an error.
DD="$T_TMP/data"; cp -R "$(version_data_dir)" "$DD"
jq '(.rules[] | select(.id == "p80-sort-bool-comparator") | .detect) = "scan:not-yet"' "$DD/php/rules.json" > "$T_TMP/r" \
  && mv "$T_TMP/r" "$DD/php/rules.json"
t_run env DRUPILOT_VERSION_DATA_DIR="$DD" "$T_SH" "$T_REPO/scripts/analysis/php-target.sh" --subject "$M" --floor 8.1 --target 8.3 --json
assert_eq "an unknown scan: no finding, listed as unsearched" \
  "$T_RC|$(jq -c '[([.findings[] | select(.id == "p80-sort-bool-comparator")] | length), (.unsearched | index("p80-sort-bool-comparator") != null)]' "$T_OUT")" \
  '0|[0,true]'
t_done
