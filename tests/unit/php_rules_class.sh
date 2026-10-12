#!/usr/bin/env bash
# The PHP-window classes (T-M5-02, AR-03) and the php-target scan (T-M5-07):
# - php_rule_class puts a php/rules.json row in exactly one class for the
#   floor L and the target P (deny, removed-blocking, apply-modernize,
#   apply-compat, report-only, not-applicable), versions compared as numbers;
# - php_rules_classified classifies every row of the shipped data;
# - php-target.sh finds the removed-blocking and report-only constructs of the
#   window, skips comment lines, a row's exclude and vendor/, reads L and P
#   from the module's own frozen plan, prints the same bytes twice, and
#   refuses a bad bound. Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

c() { php_rule_class "$1" "$2" "$3"; }
assert_eq "deny is always deny" "$(c '{"kind":"deny","deprecated_in":null}' 8.1 8.5)" "deny"
assert_eq "removed-no-rule removed below P: removed-blocking" "$(c '{"kind":"removed-no-rule","removed_in":"8.0"}' 8.1 8.3)" "removed-blocking"
assert_eq "removed-no-rule removed above P: not-applicable" "$(c '{"kind":"removed-no-rule","removed_in":"9.0"}' 8.1 8.5)" "not-applicable"
assert_eq "modernize at or below L: apply-modernize" "$(c '{"kind":"modernize","php_level":"8.1"}' 8.1 8.5)" "apply-modernize"
assert_eq "modernize above L: not-applicable" "$(c '{"kind":"modernize","php_level":"8.2"}' 8.1 8.5)" "not-applicable"
assert_eq "compat deprecated above P: not-applicable" "$(c '{"kind":"compat","deprecated_in":"8.4","drupal_safe":true}' 8.1 8.3)" "not-applicable"
NULLABLE='"rule":"Rector\\Php84\\Rector\\Param\\ExplicitNullableParamTypeRector"'
assert_eq "compat in the window, safe, its rule in the compat pass: apply-compat" \
  "$(c '{"kind":"compat",'"$NULLABLE"',"deprecated_in":"8.4","output_min_php":"7.1","drupal_safe":true}' 8.1 8.4)" "apply-compat"
assert_eq "compat deprecated above L, its rule in no pass: report-only" \
  "$(c '{"kind":"compat","rule":"Rector\\X","deprecated_in":"8.4","output_min_php":"7.1","drupal_safe":true}' 8.1 8.4)" "report-only"
assert_eq "compat deprecated at or below L (the level set runs it; no output_min_php runs anywhere)" \
  "$(c '{"kind":"compat","rule":"Rector\\X","deprecated_in":"8.2","drupal_safe":true}' 8.2 8.3)" "apply-compat"
assert_eq "RECTOR_COMPAT_RULES is the list templates/rector-compat.php.tmpl runs" \
  "$(sed -n '/^\$drupilotCompatRules = /,/class_exists/p' "$T_REPO/templates/rector-compat.php.tmpl" | sed -n "s/^ *'\(.*\)',\$/\1/p" | sed 's/\\\\/\\/g')" \
  "$RECTOR_COMPAT_RULES"
assert_eq "compat whose fix needs a PHP above L: report-only" \
  "$(c '{"kind":"compat","deprecated_in":"8.4","output_min_php":"8.4","drupal_safe":true}' 8.1 8.5)" "report-only"
assert_eq "compat not safe for Drupal: report-only" \
  "$(c '{"kind":"compat","deprecated_in":"8.1","output_min_php":"7.0","drupal_safe":false}' 8.1 8.5)" "report-only"
assert_eq "compat removed by P with no applicable fix: removed-blocking" \
  "$(c '{"kind":"compat","deprecated_in":"8.0","removed_in":"8.4","output_min_php":"8.4","drupal_safe":true}' 8.1 8.4)" "removed-blocking"
assert_eq "report-only removed by P: removed-blocking" "$(c '{"kind":"report-only","deprecated_in":"8.1","removed_in":"8.4"}' 8.1 8.4)" "removed-blocking"
assert_eq "report-only deprecated by P: report-only" "$(c '{"kind":"report-only","deprecated_in":"8.5"}' 8.1 8.5)" "report-only"
assert_eq "report-only deprecated above P: not-applicable" "$(c '{"kind":"report-only","deprecated_in":"8.5"}' 8.1 8.4)" "not-applicable"
assert_eq "versions compare as numbers (8.10 is above 8.9)" "$(c '{"kind":"report-only","deprecated_in":"8.10"}' 8.1 8.9)" "not-applicable"
assert_exit "a bound that is not X.Y" 1 php_rule_class '{"kind":"deny"}' 8 8.5
assert_exit "a row that is not an object" 1 php_rule_class '[1]' 8.1 8.5

rows="$(jq '.rules | length' "$T_REPO/config/php/rules.json")"
cls="$(php_rules_classified 8.1 8.3)"
assert_eq "every shipped row is classified once" "$(jq 'length' <<< "$cls")" "$rows"
assert_eq "every class is a known one" \
  "$(jq -c '[.[].class] - ["deny","removed-blocking","apply-modernize","apply-compat","report-only","not-applicable"]' <<< "$cls")" "[]"
assert_eq "8.1..8.3: the removed rows without a rule block" \
  "$(jq -c '[.[] | select(.class == "removed-blocking") | .id] | sort' <<< "$cls")" \
  '["removed-create-function","removed-each","removed-ereg-ext","removed-mysql-ext"]'
assert_eq "8.1..8.3: the 8.5 deprecations are not applicable" \
  "$(jq -r '[.[] | select(.id == "p85-cast-names" or .id == "p85-noop-close") | .class] | unique | join(",")' <<< "$cls")" "not-applicable"
assert_eq "8.1..8.5: the 8.5 deprecations are reported" \
  "$(php_rules_classified 8.1 8.5 | jq -r '[.[] | select(.id == "p85-cast-names" or .id == "p85-noop-close") | .class] | unique | join(",")')" "report-only"
assert_eq "a bad bound classifies nothing" "$(php_rules_classified 8 8.5)" "[]"

# A loose module: hits in code, a comment, a declaration the exclude drops, a
# method call, and vendor/.
S="$T_TMP/pt"; mkdir -p "$S/src" "$S/vendor/x"
printf 'name: PT\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$S/pt.info.yml"
cat > "$S/pt.module" <<'EOF'
<?php
// strftime('%Y') in a comment.
function pt_x($arr) {
  $a = strftime('%Y');
  $b = (integer) "3";
  $c = each($arr);
  mysql_query("x");
  # $d = lcg_value();
  $e = lcg_value();
}
EOF
cat > "$S/src/Foo.php" <<'EOF'
<?php
namespace Drupal\pt;
#[\Attribute]
class Foo {
  public function each($x) { return create_function('$a', 'return 1;'); }
  public function y() { return $this->strftime(); }
}
EOF
printf '<?php\nmysql_query("v");\n' > "$S/vendor/x/x.php"
pt() { t_run "$T_SH" "$T_REPO/scripts/analysis/php-target.sh" --subject "$S" "$@"; }
pt --floor 8.1 --target 8.3 --json
assert_eq "8.1..8.3: exit 0" "$T_RC" "0"
assert_eq "8.1..8.3: the removed constructs and strftime, nothing in comments, vendor or excludes" \
  "$(jq -r '.findings[] | "\(.file):\(.line):\(.id):\(.severity)"' "$T_OUT" | tr '\n' ' ')" \
  "pt.module:4:p81-strftime:warning pt.module:6:removed-each:error pt.module:7:removed-mysql-ext:error src/Foo.php:5:removed-create-function:error "
assert_eq "8.1..8.3: counts" "$(jq -c '.counts' "$T_OUT")" '{"removed_blocking":3,"report_only":1}'
assert_eq "8.1..8.3: the bounds" "$(jq -r '"\(.tool) \(.floor) \(.target)"' "$T_OUT")" "php-target 8.1 8.3"
first="$(cat "$T_OUT")"
pt --floor 8.1 --target 8.3 --json
assert_eq "the same bytes twice" "$(cat "$T_OUT")" "$first"
pt --floor 8.1 --target 8.5 --json
assert_eq "8.1..8.5: the 8.4/8.5 deprecations too" \
  "$(jq -r '[.findings[] | select(.class == "report-only") | .id] | join(",")' "$T_OUT")" "p81-strftime,p85-cast-names,p84-lcg-value"
# The plan is in the lock of the module's root (its sibling test-bed).
ROOT="$(subject_project_root "$S")"
DRUPILOT_PROJECT_DIR="$ROOT" lock_set_json .upgrade_plan '{"subject": {"machine_name": "pt"}, "php": {"floor": "8.1", "final": "8.5"}}' > /dev/null
pt --json
assert_eq "the bounds come from the module's own plan" "$(jq -r '"\(.floor) \(.target) \(.counts.report_only)"' "$T_OUT")" "8.1 8.5 3"
DRUPILOT_PROJECT_DIR="$ROOT" lock_set_json .upgrade_plan '{"subject": {"machine_name": "other"}, "php": {"floor": "8.1", "final": "8.5"}}' > /dev/null
pt --json
assert_eq "another module's plan is not read: the PHP target" "$(jq -r '"\(.floor) \(.target)"' "$T_OUT")" "$(resolve_php_target) $(resolve_php_target)"
pt --floor 8.1 --target 8.3
assert_eq "the text form: one line per finding" "$(sed -n '1p' "$T_OUT")" "warning	pt.module:4	[p81-strftime] strftime()/gmstrftime()"
printf '<?php\n$o = [\\PDO::MYSQL_ATTR_SSL_CA => "x"];\n' > "$S/src/Pdo.php"
pt --floor 8.1 --target 8.5 --json
assert_eq "fix_at_floor: the PDO constants' fix needs 8.4, above the floor 8.1; a cast name's runs anywhere" \
  "$(jq -c '[.findings[] | select(.id == "p85-pdo-mysql-constants" or .id == "p85-cast-names") | [.id, .fix_at_floor]]' "$T_OUT")" \
  '[["p85-cast-names",true],["p85-pdo-mysql-constants",false]]'
pt --floor 8.4 --target 8.5 --json
assert_eq "  on the floor 8.4 the PDO constants' fix runs" "$(jq -c '[.findings[] | select(.id == "p85-pdo-mysql-constants") | .fix_at_floor]' "$T_OUT")" '[true]'
rm -f "$S/src/Pdo.php"
# Only the code is searched: a block comment, a string (inline JS, UI text), a
# trailing comment, a heredoc and inline HTML hide nothing; PHP function and
# cast names match regardless of case; a path with ':' and a Latin-1 byte on
# the line change nothing; the rows without a pattern are listed.
Q="$T_TMP/q"; mkdir -p "$Q/src/a:b"
cat > "$Q/q.module" <<'PHP'
<?php
/*
 Old D6 implementation:
 while (list($k, $v) = each($items)) {
*/
$a = ['#markup' => '<script>jQuery(".q").each(function () {});</script>'];
$b = t('Set a value for each (enabled) language.'); // each($x)
$c = <<<EOT
 heredoc each(
 EOT;
$d = Each($list);
$e = ( INTEGER ) $v;
?>
<p>each( in HTML</p>
PHP
printf '<?php
$y = each($x);
' > "$Q/src/a:b/c.php"
printf '<?php
$t = each($a); // año
' > "$Q/src/latin1.php"
t_run "$T_SH" "$T_REPO/scripts/analysis/php-target.sh" --subject "$Q" --floor 8.1 --target 8.5 --json
assert_eq "the code only: Each( and ( INTEGER ) in code, a ':' path, a Latin-1 line" \
  "$T_RC|$(jq -r '[.findings[] | "\(.file):\(.line):\(.id)"] | join(" ")' "$T_OUT")" \
  "0|q.module:11:removed-each q.module:12:p85-cast-names src/a:b/c.php:2:removed-each src/latin1.php:2:removed-each"
assert_eq "the rows without a pattern are listed as unsearched" \
  "$(jq -c '[(.unsearched | index("p84-csv-escape") != null), (.unsearched | index("removed-each"))]' "$T_OUT")" '[true,null]'
E="$T_TMP/empty"; mkdir -p "$E"
t_run "$T_SH" "$T_REPO/scripts/analysis/php-target.sh" --subject "$E" --floor 8.1 --target 8.5 --json
assert_eq "a module with no PHP file: no finding" "$T_RC|$(jq -c '.findings' "$T_OUT")" "0|[]"
assert_exit "a bound that is not X.Y" 1 "$T_SH" "$T_REPO/scripts/analysis/php-target.sh" --subject "$S" --floor 8 --target 8.5
assert_exit "no --subject" 1 "$T_SH" "$T_REPO/scripts/analysis/php-target.sh" --json
t_done
