#!/usr/bin/env bash
# The deprecations PHPStan cannot see (lab L-PC, preserve_changed): a read of
# the magic property $entity->original (deprecated in drupal:11.2.0, removed
# from drupal:12.0.0, where a read returns NULL with no error) gave "0
# deprecations" in the assessment and the port report.
# - php_magic_property_lines: every ->original access, nullsafe too, with its
#   operation (get, set, isset/empty, unset); a method call, a longer name, a
#   comment, a string and $this->original of a class that declares the
#   property are not;
# - run-phpstan.sh --json: drupilot.runtime_deprecations lists them (the
#   lifecycle entry's scan block, core's runtime notice per operation),
#   PHPStan's own totals and files untouched; no key when there is none;
# - classify-deprecations.sh: soft for target 11 (reported), hard for 12
#   (blocking); a pasted runtime notice names the same symbol; the fix policy
#   guards it from a 10.3 floor and defers it below 10.1.3;
# - normalize-findings.sh: a catalog finding runtime-deprecation:<id>,
#   classified (soft: next-major under the report policy), with the anchor
#   extract.sh gives it; classify.sh defers it; the PHPStan report alone
#   (no PHPStan message) is enough to classify it;
# (manifest.sh's deprecations_remaining: tests/unit/manifest_generate.sh.)
# Docker-free: stub php, composer and phpstan.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
# shellcheck source=../../scripts/lib/php-scan.sh
. "$T_REPO/scripts/lib/php-scan.sh"

# php_magic_property_lines.
cat > "$T_TMP/magic.php" <<'EOF'
<?php
class Foo {
  protected $original;
  public function a($entity) {
    $x = $entity->original;
    $y = $entity?->original?->id();
    $entity->original = NULL;
    $entity->original ??= $x;
    if (isset($entity->original)) {}
    if (empty($entity->original->foo)) {}
    unset($entity->original);
    $z = $this->original;
    $w = $entity->originalValue;
    $v = $entity->original();
    // $entity->original in a comment
    $s = "$entity->original in a string";
    if ($entity->original == $x) {}
  }
}
EOF
php_code_lines "$T_TMP/magic.php" > "$T_TMP/magic.blank"
assert_eq "php_magic_property_lines: each access and its operation" \
  "$(php_magic_property_lines "$T_TMP/magic.blank" original | tr '\t' '|' | tr '\n' ' ')" \
  "5|get 6|get 7|set 8|set 9|isset 10|isset 11|unset 17|get "
sed 's/protected \$original;/protected $other;/' "$T_TMP/magic.php" > "$T_TMP/magic2.php"
php_code_lines "$T_TMP/magic2.php" > "$T_TMP/magic2.blank"
assert_match "  \$this->original counts when the class declares no such property" \
  "$(php_magic_property_lines "$T_TMP/magic2.blank" original | tr '\t' '|' | tr '\n' ' ')" "12\|get"
assert_eq "  a property name that is not an identifier: nothing" "$(php_magic_property_lines "$T_TMP/magic.blank" 'or.ginal')" ""

# run-phpstan.sh --json: the scan, next to a clean PHPStan report.
mk_bin() { printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
STUBS="$T_TMP/stubs"; mkdir -p "$STUBS"
mk_bin "$STUBS/php" 'case "$1" in -r) echo 8.3.30;; -v) echo "PHP 8.3.30 (cli)";; esac; exit 0'
mk_bin "$STUBS/composer" 'echo "Composer version 2.8.0 2025-01-01 00:00:00"; exit 0'
r="$T_TMP/root"; M="$r/web/modules/custom/m"
mkdir -p "$M/src" "$M/tests/src/Kernel" "$r/web/core/lib" "$r/vendor/bin"
printf '{"name":"x/root"}\n' > "$r/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$r/web/core/lib/Drupal.php"
printf 'name: M\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$M/m.info.yml"
cat > "$M/src/Item.php" <<'EOF'
<?php
namespace Drupal\m;
class Item {
  public function preSave($entity) {
    $original = $entity->original;
    unset($entity->original);
  }
}
EOF
printf '<?php\n// nothing here\n' > "$M/tests/src/Kernel/ATest.php"
printf '{"totals": {"errors": 0, "file_errors": 0}, "files": {}, "errors": []}\n' > "$T_TMP/clean.json"
mk_bin "$r/vendor/bin/phpstan" "cat '$T_TMP/clean.json'; exit 0"
t_run env PATH="$STUBS:$PATH" DRUPILOT_DETERMINISTIC=false "$T_SH" "$T_REPO/scripts/analysis/run-phpstan.sh" --subject "$M" --json
assert_eq "run-phpstan: PHPStan clean, exit 0" "$T_RC" "0"
jq '.' "$T_OUT" > "$T_TMP/stan.json"
assert_eq "  PHPStan's totals and files untouched" "$(jq -c '[.totals, .files]' "$T_TMP/stan.json")" '[{"errors":0,"file_errors":0},{}]'
assert_eq "  drupilot.runtime_deprecations: each access, sorted, root-relative" \
  "$(jq -c '[.drupilot.runtime_deprecations[] | [.file, .line, .id, .symbol, .operation, .identifier]]' "$T_TMP/stan.json")" \
  '[["web/modules/custom/m/src/Item.php",5,"entity-original-property","EntityBase::$original","get","drupilot.runtimeDeprecation"],["web/modules/custom/m/src/Item.php",6,"entity-original-property","EntityBase::$original","unset","drupilot.runtimeDeprecation"]]'
assert_match "  the message is core's runtime notice of the operation" \
  "$(jq -r '.drupilot.runtime_deprecations[1].message' "$T_TMP/stan.json")" \
  '^Unsetting the original property is deprecated in drupal:11\.2\.0 and is removed from drupal:12\.0\.0\. .*\(drupilot source scan: '
cp "$M/src/Item.php" "$T_TMP/item.keep"
cat > "$M/src/Item.php" <<'EOF'
<?php
namespace Drupal\m;
use Drupal\Component\Utility\DeprecationHelper;
class Item {
  public function preSave($entity) {
    $original = DeprecationHelper::backwardsCompatibleCall(\Drupal::VERSION, '11.2.0', fn() => $entity->getOriginal(), fn() => $entity->original);
  }
}
EOF
t_run env PATH="$STUBS:$PATH" DRUPILOT_DETERMINISTIC=false "$T_SH" "$T_REPO/scripts/analysis/run-phpstan.sh" --subject "$M" --json
assert_eq "  the deprecated callable of a DeprecationHelper call (drupal-rector's BC form) is left out" \
  "$(jq -c '.drupilot | has("runtime_deprecations")' "$T_OUT")" "false"
# Hundreds of accesses: the records never go through one argv string.
{ printf '<?php\nnamespace Drupal\\m;\nclass Many {\n  public function f($entity) {\n'
  i=0; while [[ $i -lt 400 ]]; do printf '    $x%s = $entity->original;\n' "$i"; i=$((i + 1)); done
  printf '  }\n}\n'; } > "$M/src/Many.php"
t_run env PATH="$STUBS:$PATH" DRUPILOT_DETERMINISTIC=false "$T_SH" "$T_REPO/scripts/analysis/run-phpstan.sh" --subject "$M" --json
assert_eq "  400 accesses: exit 0, every one reported" "$T_RC|$(jq -c '.drupilot.runtime_deprecations | length' "$T_OUT")" "0|400"
rm -f "$M/src/Many.php"
cp "$T_TMP/item.keep" "$M/src/Item.php"
sed_inplace "$M/src/Item.php" -e 's/\$entity->original/$entity->getOriginal()/' -e '/unset/d'
t_run env PATH="$STUBS:$PATH" DRUPILOT_DETERMINISTIC=false "$T_SH" "$T_REPO/scripts/analysis/run-phpstan.sh" --subject "$M" --json
assert_eq "  none left: no runtime_deprecations key" "$(jq -c '.drupilot | has("runtime_deprecations")' "$T_OUT")" "false"

# classify-deprecations.sh.
CD="$T_REPO/scripts/analysis/classify-deprecations.sh"
t_run "$T_SH" "$CD" --file "$T_TMP/stan.json" --core-req '^10 || ^11' --target-major 11 --json
assert_eq "classify T 11: soft, reported, not blocking" \
  "$(jq -c '[.blocking, .counts.soft, ([.symbols[] | [.symbol, .class, .action, .occurrences, .replacement_since]])]' "$T_OUT")" \
  '[0,2,[["EntityBase::$original","soft","report",2,"11.2"]]]'
t_run "$T_SH" "$CD" --file "$T_TMP/stan.json" --core-req '^11.2 || ^12' --target-major 12 --json
assert_eq "  T 12: hard, blocking, its replacement at the floor" \
  "$(jq -c '[.blocking, .counts.hard, ([.symbols[] | [.class, .action, .replacement_at_floor]])]' "$T_OUT")" '[2,2,[["hard","fix",true]]]'
printf '  1x: Getting the original property is deprecated in drupal:11.2.0 and is removed from drupal:12.0.0. Use \\Drupal\\Core\\Entity\\EntityInterface::getOriginal() instead.\n' > "$T_TMP/notice.txt"
cg() { "$T_SH" "$CD" --file "$T_TMP/notice.txt" --core-req "$1" --policy fix --target-major 11 --json 2> /dev/null | jq -r '[.symbols[0].symbol, .soft[0].action] | join("|")'; }
assert_eq "  a pasted runtime notice names the same symbol; fix guards it from 10.3, defers below 10.1.3" \
  "$(cg '^10.3 || ^11') $(cg '^10 || ^11')" 'EntityBase::$original|fix-guarded EntityBase::$original|defer'

# normalize-findings.sh, with the anchor extract.sh gives the record.
RAW="$T_TMP/raw"; mkdir -p "$RAW"
jq -n '{stage: "assess", subject: {machine_name: "m", path: "web/modules/custom/m"}, target_major: 11,
  tools: [{tool: "phpstan", file: "04-assess-phpstan.json", exit_code: 0}]}' > "$RAW/04-assess-index.json"
cp "$T_TMP/stan.json" "$RAW/04-assess-phpstan.json"
printf '[{"file": "web/modules/custom/m/src/Item.php", "line": 5, "anchor": "Drupal\\\\m\\\\Item::preSave"}]\n' > "$RAW/04-assess-anchors.json"
t_run "$T_SH" "$T_REPO/scripts/ai/normalize-findings.sh" --raw-dir "$RAW" --target-major 11 --soft-policy report --json
assert_eq "normalize: catalog findings, classified, next-major" \
  "$(jq -c '[.findings[] | select(.rule | startswith("runtime-deprecation:")) | [.tool, .rule, .file, .line, .anchor, .symbol, .class, .scope]]' "$T_OUT")" \
  '[["catalog","runtime-deprecation:entity-original-property","src/Item.php",5,"Drupal\\m\\Item::preSave","EntityBase::$original","soft","next-major"],["catalog","runtime-deprecation:entity-original-property","src/Item.php",6,"{file}","EntityBase::$original","soft","next-major"]]'
jq '.' "$T_OUT" > "$T_TMP/findings.json"
t_run "$T_SH" "$T_REPO/scripts/ai/classify.sh" --findings "$T_TMP/findings.json" --json
assert_eq "  classify: deferred, not blocking" "$(jq -c '[.items[] | [.lane, .blocking]] | unique' "$T_OUT")" '[["deferred",false]]'
t_run "$T_SH" "$T_REPO/scripts/ai/normalize-findings.sh" --raw-dir "$RAW" --target-major 12 --soft-policy report --json
assert_eq "  T 12: hard and current" "$(jq -c '[.findings[] | select(.rule | startswith("runtime-deprecation:")) | [.class, .scope]] | unique' "$T_OUT")" '[["hard","current"]]'
t_done
