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
scan() { php_phpunit_hidden_metadata "$1" | tr '\037' '|'; }

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
  "15|PreservedChangedItemTest|@group preserve_changed|#[Group('preserve_changed')]|@covers ::preSave (line 24)|0"
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
  "10|FormsTest|||@covers ::bar (line 29)|1 19|FormsTest::testA|@group slow|#[Group('slow')]||- 25|FormsTest::testB|@ticket 123|#[Ticket('123')]||- "

# The twins carry their arguments; a method's @covers, a @testWith next to no
# provider attribute and Drupal's @requires module are not PHPUnit metadata a
# method attribute hides; a helper class after the test keeps its record.
cat > "$T_TMP/cases.php" <<'EOF'
<?php
namespace Drupal\Tests\m\Kernel;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\Attributes\Group;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;
/**
 * @group m
 * @group extra
 * @requires extension apcu
 * @requires module node
 * @coversDefaultClass \Drupal\m\Foo
 */
#[Group('m')]
#[RunTestsInSeparateProcesses]
class CasesTest extends KernelTestBase {
  /**
   * @dataProvider provider
   * @covers ::foo
   * @preserveGlobalState disabled
   * @runInSeparateProcess
   */
  #[DataProvider('provider')]
  public function testA($x): void {}
  /**
   * @testWith [1, 2]
   * @dataProvider \Drupal\Tests\m\Other::provider
   * @depends clone testA
   */
  #[Group('slow')]
  public function testB(): void {}
  /**
   * @covers ::bar
   */
  public function testC(): void {}
  /**
   * @testWith [1, 2]
   */
  #[DataProvider('provider')]
  public function testD(): void {}
}
/**
 * A helper, not a test.
 */
class Helper {
  public function x(): void {}
}
EOF
assert_eq "the twins with their arguments; a helper class after the test" "$(scan "$T_TMP/cases.php" | tr '\n' ' ')" \
  "13|CasesTest|@group extra; @requires extension apcu|#[Group('extra')]; #[RequiresPhpExtension('apcu')]|@covers ::bar (line 32)|1 22|CasesTest::testA|@preserveGlobalState disabled; @runInSeparateProcess|#[PreserveGlobalState(false)]; #[RunInSeparateProcess]||- 29|CasesTest::testB|@dataProvider \\Drupal\\Tests\\m\\Other::provider; @depends clone testA|#[DataProviderExternal(\\Drupal\\Tests\\m\\Other::class, 'provider')]; #[DependsUsingDeepClone('testA')]||- 38|CasesTest::testD|@testWith [1, 2]|#[TestWith(...)]||- "
sed -e "s/^#\[Group('m')\]/#[Group('m')]\\
#[Group('extra')]\\
#[\\\\PHPUnit\\\\Framework\\\\Attributes\\\\RequiresPhpExtension('apcu')]/" "$T_TMP/cases.php" > "$T_TMP/cases2.php"
# Values: a bare @requires version is a minimum; class names fully
# qualified; a class-level relative @covers names the default class, or a
# function without one; an apostrophe survives the twin's quoting.
cat > "$T_TMP/vals.php" <<'EOF'
<?php
namespace Drupal\Tests\m\Unit;
use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;
/**
 * @requires PHP 8.1
 * @requires PHPUnit 10
 * @covers Drupal\m\Foo
 * @covers ::m_function
 * @testdox It's a test
 */
#[RunTestsInSeparateProcesses]
class ValsTest extends UnitTestCase {}
EOF
assert_eq "values: >= for a bare version, a leading backslash, a function for ::name, the apostrophe kept" "$(scan "$T_TMP/vals.php" | cut -d'|' -f4)" \
  "#[RequiresPhp('>= 8.1')]; #[RequiresPhpunit('>= 10')]; #[CoversClass(\\Drupal\\m\\Foo::class)]; #[CoversFunction('m_function')]; #[TestDox('It\\'s a test')]"
sed -e "s/^#\[RunTestsInSeparateProcesses\]/#[RunTestsInSeparateProcesses]\\
#[\\\\PHPUnit\\\\Framework\\\\Attributes\\\\RequiresPhp('>= 8.1')]\\
#[\\\\PHPUnit\\\\Framework\\\\Attributes\\\\RequiresPhpunit('10')]\\
#[\\\\PHPUnit\\\\Framework\\\\Attributes\\\\TestDox('It\\\\'s a test')]/" "$T_TMP/vals.php" > "$T_TMP/vals2.php"
assert_eq "  the >= twin and the escaped TestDox clear theirs; a bare RequiresPhpunit('10') does not" "$(scan "$T_TMP/vals2.php" | cut -d'|' -f3)" \
  "@requires PHPUnit 10; @covers Drupal\\m\\Foo; @covers ::m_function"
printf '%s\n' '<?php' 'namespace Drupal\Tests\m\Unit;' 'use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;' \
  '/**' ' * @group m' ' * @coversDefaultClass \Drupal\m\Bar' ' * @covers ::baz' ' */' '#[RunTestsInSeparateProcesses]' 'class DefTest extends UnitTestCase {}' > "$T_TMP/def.php"
assert_eq "  a relative @covers of the class with a default class: the default class" "$(scan "$T_TMP/def.php" | cut -d'|' -f4)" \
  "#[Group('m')]; #[CoversClass(\\Drupal\\m\\Bar::class)]"
assert_match "  their twins clear them (the class keeps only its relative @covers)" "$(scan "$T_TMP/cases2.php" | sed -n '1p')" \
  "^13\|CasesTest\|\|\|@covers ::bar \(line 34\)\|1$"

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
# The class with its twin, the relative @covers left: the message says to
# write it in full (an empty field is not lost on the way).
sed -e 's/^use PHPUnit\\Framework\\Attributes\\RunTestsInSeparateProcesses;/use PHPUnit\\Framework\\Attributes\\Group;\
use PHPUnit\\Framework\\Attributes\\RunTestsInSeparateProcesses;/' \
  -e "s/^#\[RunTestsInSeparateProcesses\]/#[Group('preserve_changed')]\\
#[RunTestsInSeparateProcesses]/" "$T_TMP/ported.php" > "$M/tests/src/Kernel/PreservedChangedItemTest.php"
t_run "$T_SH" "$PS" --subject "$M" --checks test-phpunit-metadata --base HEAD --json
assert_match "  only the relative @covers left: name the method in full, no lost group" "$(jq -r '.findings[0].message' "$T_OUT")" \
  "its @coversDefaultClass is ignored as well, so @covers ::preSave \(line 26\) is invalid"
assert_eq "  (no claim about the group \"default\")" "$(jq -r '.findings[0].message' "$T_OUT" | grep -c 'group "default"')" "0"
# The base admitted no Drupal 11: the port's range change made it break.
printf 'name: M\ntype: module\ncore_version_requirement: ^9.5 || ^10\n' > "$M/m.info.yml"
cp "$T_TMP/ported.php" "$M/tests/src/Kernel/PreservedChangedItemTest.php"
g add -A; g commit -qm base-d10-only
printf 'name: M\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$M/m.info.yml"
t_run "$T_SH" "$PS" --subject "$M" --checks test-phpunit-metadata --base HEAD --json
assert_eq "  the attribute was there, the port widened the range to Drupal 11: an error" \
  "$T_RC|$(jq -c '[.findings[] | [.severity, .introduced]]' "$T_OUT")" '3|[["error",true]]'
# A class whose hidden list holds a '::' still gets the "default" group
# clause (only a method record is spared it).
M2="$T_TMP/m2"; mkdir -p "$M2/tests/src/Unit"
printf 'name: M2\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$M2/m2.info.yml"
printf '%s\n' '<?php' 'namespace Drupal\Tests\m2\Unit;' 'use PHPUnit\Framework\Attributes\RunTestsInSeparateProcesses;' \
  '/**' ' * @group m2' ' * @covers \Drupal\m2\Foo::bar' ' */' '#[RunTestsInSeparateProcesses]' 'class ColonTest extends UnitTestCase {}' \
  > "$M2/tests/src/Unit/ColonTest.php"
t_run "$T_SH" "$PS" --subject "$M2" --checks test-phpunit-metadata --no-diff --json
assert_match "  a class with '::' in its hidden list keeps the default-group clause" "$(jq -r '.findings[0].message' "$T_OUT")" 'group "default"'
cp "$T_TMP/repaired.php" "$M/tests/src/Kernel/PreservedChangedItemTest.php"
t_run "$T_SH" "$PS" --subject "$M" --json
assert_eq "  repaired: every check passes" "$T_RC|$(jq -c '[.errors, .warnings]' "$T_OUT")" "0|[0,0]"
t_done
