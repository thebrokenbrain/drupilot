#!/usr/bin/env bash
# The port-safety check test-phpunit-metadata (lab L-PC, preserve_changed):
# the digests rule AddRunTestsInSeparateProcessesAttributeRector gave a test
# class its first PHPUnit attribute, and PHPUnit 10+ then ignored the class
# doc-comment: the test lost its @group (group "default") and a method's
# relative @covers ::preSave was invalid without the ignored
# @coversDefaultClass.
# - php_phpunit_hidden_metadata: a class or a method whose PHPUnit attribute
#   hides annotations with no twin there (a twin, e.g. #[Group('x')] next to
#   @group x, clears it); a relative @covers of a method is reported with the
#   class whose @coversDefaultClass is hidden; the attribute names resolve
#   through a single import, a group use, a namespace alias or the fully
#   qualified name, and an attribute of another namespace hides nothing;
#   a multi-line attribute counts;
# - check-port-safety.sh: an error when the port added the attribute, a
#   warning when it was already there; the twins to add, keeping the
#   annotations while the range admits Drupal 10; off for a range with no
#   Drupal 11 and later.
# Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
# shellcheck source=../../scripts/lib/php-scan.sh
. "$T_REPO/scripts/lib/php-scan.sh"
scan() { php_phpunit_hidden_metadata "$1" | tr '\t' '|'; }

# The test the port left (lab L-PC), and the test stage's repair.
cat > "$T_TMP/ported.php" <<'EOF'
<?php

namespace Drupal\Tests\preserve_changed\Kernel;

use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;
use Drupal\KernelTests\KernelTestBase;

/**
 * Tests the PreservedChangedItem field item class.
 *
 * @group preserve_changed
 *
 * @coversDefaultClass \Drupal\preserve_changed\PreservedChangedItem
 */
#[RunTestsInSeparateProcesses]
class PreservedChangedItemTest extends KernelTestBase {

  /**
   * {@inheritdoc}
   */
  protected static $modules = ['preserve_changed'];

  /**
   * @covers ::preSave
   */
  public function testPreservedChangedItem(): void {
  }

}
EOF
assert_eq "the ported test: the lost @group, its twin, the relative @covers" "$(scan "$T_TMP/ported.php")" \
  "15|PreservedChangedItemTest|@group preserve_changed|#[Group('preserve_changed')]|@covers ::preSave (line 24)"
sed -e 's/^use PHPUnit\\Framework\\Attributes\\RunTestsInSeparateProcesses;/use PHPUnit\\Framework\\Attributes\\Group;\
use PHPUnit\\Framework\\Attributes\\RunTestsInSeparateProcesses;/' \
  -e "s/^#\[RunTestsInSeparateProcesses\]/#[Group('preserve_changed')]\\
#[RunTestsInSeparateProcesses]/" \
  -e 's/@covers ::preSave/@covers \\Drupal\\preserve_changed\\PreservedChangedItem::preSave/' "$T_TMP/ported.php" > "$T_TMP/repaired.php"
assert_eq "  repaired (the twin, the @covers in full): nothing" "$(scan "$T_TMP/repaired.php")" ""
grep -v -e 'RunTestsInSeparateProcesses' "$T_TMP/ported.php" > "$T_TMP/plain.php"
assert_eq "  no attribute at all: nothing (PHPUnit reads the annotations)" "$(scan "$T_TMP/plain.php")" ""

# Method level, the import forms, a multi-line attribute.
cat > "$T_TMP/forms.php" <<'EOF'
<?php
namespace Drupal\Tests\m\Unit;
use PHPUnit\Framework\Attributes\{DataProvider, Group as G};
use PHPUnit\Framework\Attributes as PA;
use Drupal\Tests\UnitTestCase;
/**
 * @group m
 * @coversDefaultClass \Drupal\m\Foo
 */
#[
  G('m'),
  PA\Small,
]
class FormsTest extends UnitTestCase {
  /**
   * @dataProvider provider
   * @group slow
   */
  #[DataProvider('provider')]
  public function testA($x): void {}
  /**
   * @depends testA
   * @ticket 123
   */
  #[\PHPUnit\Framework\Attributes\Depends('testA')]
  #[\Drupal\Some\Other]
  public function testB(): void {}
  /**
   * @covers ::bar
   */
  #[\Drupal\Some\Other]
  public function testC(): void {}
  public static function provider(): array { return []; }
}
EOF
assert_eq "method level: a twinned @dataProvider is fine, @group slow and @ticket 123 are hidden; the class's relative @covers" \
  "$(scan "$T_TMP/forms.php" | tr '\n' ' ')" \
  "10|FormsTest|||@covers ::bar (line 29) 19|FormsTest::testA|@group slow|#[Group('slow')]| 25|FormsTest::testB|@ticket 123|#[Ticket('123')]| "

# check-port-safety.sh: attribution and the range.
M="$T_TMP/m"; mkdir -p "$M/tests/src/Kernel"
printf 'name: M\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$M/m.info.yml"
cp "$T_TMP/plain.php" "$M/tests/src/Kernel/PreservedChangedItemTest.php"
g() { git -C "$M" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
g init -q; g add -A; g commit -qm base
cp "$T_TMP/ported.php" "$M/tests/src/Kernel/PreservedChangedItemTest.php"
PS="$T_REPO/scripts/analysis/check-port-safety.sh"
t_run "$T_SH" "$PS" --subject "$M" --checks test-phpunit-metadata --json
assert_eq "check-port-safety: the port added the attribute, an error (exit 3)" \
  "$T_RC|$(jq -c '[.findings[] | [.check, .severity, .file, .line, .introduced]]' "$T_OUT")" \
  '3|[["test-phpunit-metadata","error","tests/src/Kernel/PreservedChangedItemTest.php",15,true]]'
assert_match "  the message names the lost @group, the invalid @covers and the twin to add next to the kept annotation" \
  "$(jq -r '.findings[0].message' "$T_OUT")" \
  "@group preserve_changed .*group \"default\".*@covers ::preSave \(line 24\) is invalid.*Keep the annotations for the PHPUnit of Drupal 10 and before.*#\[Group\('preserve_changed'\)\]"
t_run "$T_SH" "$PS" --subject "$M" --checks test-phpunit-metadata --core-req '^11' --json
assert_match "  ^11: add the twins, no annotation to keep" "$(jq -r '.findings[0].message' "$T_OUT")" "\. Add their twins: #\[Group"
t_run "$T_SH" "$PS" --subject "$M" --checks test-phpunit-metadata --core-req '^10' --json
assert_eq "  ^10 (PHPUnit 9 only): off" "$T_RC|$(jq -c '.findings' "$T_OUT")" "0|[]"
g add -A; g commit -qm ported
t_run "$T_SH" "$PS" --subject "$M" --checks test-phpunit-metadata --base HEAD --json
assert_eq "  already there before the port: a warning (exit 0)" \
  "$T_RC|$(jq -c '[.findings[] | [.severity, .introduced]]' "$T_OUT")" '0|[["warn",false]]'
cp "$T_TMP/repaired.php" "$M/tests/src/Kernel/PreservedChangedItemTest.php"
t_run "$T_SH" "$PS" --subject "$M" --json
assert_eq "  repaired: every check passes" "$T_RC|$(jq -c '[.errors, .warnings]' "$T_OUT")" "0|[0,0]"
t_done
