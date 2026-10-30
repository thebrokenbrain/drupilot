#!/usr/bin/env bash
# Two port-safety checks from the training run (modules 05 fotorama_gallery
# and 08 pbf), Docker-free:
# - test-abstract-suffix: an abstract class in a tests/ file named *Test.php
#   while the range admits Drupal 11 (PHPUnit 10+ throws "Class X is
#   abstract"); a *TestBase.php file and a concrete *Test.php pass; off for a
#   range with no Drupal 11;
# - test-field-ui-display-path: a tests/ path ending in /display given to
#   drupalGet() (literal, interpolated, concatenated) while the range admits
#   Drupal 11 (an overview from 11.4); .../display/default, /form-display, a
#   comment and a module's own admin/config/m/display route pass, a path after
#   a variable prefix ($bundle_path . '/display') is flagged; off for ^9 || ^10.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
PS="$T_REPO/scripts/analysis/check-port-safety.sh"

M="$T_TMP/m"; mkdir -p "$M/tests/src/Functional"
printf 'name: M\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$M/m.info.yml"
cat > "$M/tests/src/Functional/MBaseTest.php" <<'EOF'
<?php

namespace Drupal\Tests\m\Functional;

use Drupal\Tests\BrowserTestBase;

abstract class MBaseTest extends BrowserTestBase {

}
EOF
cat > "$M/tests/src/Functional/MTestBase.php" <<'EOF'
<?php

namespace Drupal\Tests\m\Functional;

abstract class MTestBase extends MBaseTest {

}
EOF
cat > "$M/tests/src/Functional/MDisplayTest.php" <<'EOF'
<?php

namespace Drupal\Tests\m\Functional;

/**
 * @group m
 */
class MDisplayTest extends MBaseTest {

  public function testDisplay(): void {
    $this->drupalGet('admin/structure/types/manage/gallery/display');
    $this->drupalGet("admin/structure/types/manage/$this->type/display");
    $this->drupalGet('admin/structure/types/manage/' . $type . '/display');
    $this->drupalGet('admin/structure/types/manage/gallery/display/default');
    $this->drupalGet('admin/structure/types/manage/gallery/form-display');
    // $this->drupalGet('admin/structure/types/manage/gallery/display');
    $this->drupalGet('admin/config/m/display');
    $this->drupalGet($bundle_path . '/display');
    $this->drupalGet("$bundle_path/display");
  }

}
EOF
t_run "$T_SH" "$PS" --subject "$M" --checks test-abstract-suffix,test-field-ui-display-path --json
assert_eq "^10 || ^11: the abstract *Test.php and the five Field UI /display paths (two after a variable prefix), warnings without git" \
  "$T_RC|$(jq -c '[.findings[] | [.check, .file, .line, .severity]]' "$T_OUT")" \
  '0|[["test-abstract-suffix","tests/src/Functional/MBaseTest.php",7,"warn"],["test-field-ui-display-path","tests/src/Functional/MDisplayTest.php",11,"warn"],["test-field-ui-display-path","tests/src/Functional/MDisplayTest.php",12,"warn"],["test-field-ui-display-path","tests/src/Functional/MDisplayTest.php",13,"warn"],["test-field-ui-display-path","tests/src/Functional/MDisplayTest.php",18,"warn"],["test-field-ui-display-path","tests/src/Functional/MDisplayTest.php",19,"warn"]]'
assert_match "  the abstract message names the class and the fix" \
  "$(jq -r '.findings[] | select(.check == "test-abstract-suffix") | .message' "$T_OUT")" \
  "^MBaseTest is abstract in a file named \*Test\.php: from PHPUnit 10 \(Drupal 11\.0 and later\).*Name the class and its file \*TestBase"
assert_match "  the display message names 11.4 and the portable path" \
  "$(jq -r '[.findings[] | select(.check == "test-field-ui-display-path")][0].message' "$T_OUT")" \
  "from Drupal 11\.4\.0 Field UI serves an overview.*display/default, which serves the default display form on every core"
t_run "$T_SH" "$PS" --subject "$M" --checks test-abstract-suffix,test-field-ui-display-path --core-req '^9 || ^10' --json
assert_eq "^9 || ^10: both off" "$T_RC|$(jq -c '.findings' "$T_OUT")" "0|[]"
t_done
