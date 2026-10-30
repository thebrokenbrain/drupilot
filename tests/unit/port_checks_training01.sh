#!/usr/bin/env bash
# Two port-safety checks from the training run's module 01 (filelog):
# - config-schema-sequence: a config schema `sequence:` whose item type is a
#   one-item YAML list (`- type: string`), removed from Drupal 11 (the
#   settings form threw SchemaIncompleteException): an error, before and
#   after the port, also at assess time (target 11 with the old range); off
#   for a Drupal 10 port; comments, blank lines and the mapping form pass;
# - test-phpunit-api: $matcher->numberOfInvocations() (PHPUnit 10+, written by
#   Rector's WithConsecutiveRector) in a test while the range admits Drupal
#   10 (PHPUnit 9 has getInvocationCount()): an error when the port added
#   it, a warning when it was there; comments do not count; off for ^11.
# Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
PS="$T_REPO/scripts/analysis/check-port-safety.sh"

M="$T_TMP/m"; mkdir -p "$M/config/schema" "$M/tests/modules/m_test/config/schema" "$M/tests/src/Unit"
printf 'name: M\ntype: module\ncore_version_requirement: ^9 || ^10\n' > "$M/m.info.yml"
cat > "$M/config/schema/m.schema.yml" <<'EOF'
m.settings:
  type: config_object
  mapping:
    channels:
      type: sequence
      sequence:
        - type: string
    good:
      type: sequence
      sequence:
        type: string
    commented:
      type: sequence
      sequence:  # the item type

        # a comment line
        - type: integer
    flow:
      type: sequence
      sequence: [{type: string}]
EOF
printf 'm_test.x:\n  type: sequence\n  sequence:\n    - type: string\n' > "$M/tests/modules/m_test/config/schema/m_test.schema.yml"
g() { git -C "$M" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
g init -q; g add -A; g commit -qm base

t_run "$T_SH" "$PS" --subject "$M" --checks config-schema-sequence --json
assert_eq "config-schema-sequence: the old range, target 11 (assess time): every list form is an error" \
  "$T_RC|$(jq -c '[.findings[] | [.check, .severity, .file, .line]]' "$T_OUT")" \
  '3|[["config-schema-sequence","error","config/schema/m.schema.yml",7],["config-schema-sequence","error","config/schema/m.schema.yml",17],["config-schema-sequence","error","config/schema/m.schema.yml",20],["config-schema-sequence","error","tests/modules/m_test/config/schema/m_test.schema.yml",4]]'
assert_match "  the message names the removal and the fix" "$(jq -r '.findings[0].message' "$T_OUT")" \
  "deprecated in drupal:8\.0\.0 and removed from drupal:11\.0\.0: from Drupal 11 its items have no type and saving the configuration throws SchemaIncompleteException\. Write the item definition as a mapping"
DRUPILOT_TARGET_MAJOR=10 DRUPILOT_DRUPAL_TARGET='^10' t_run "$T_SH" "$PS" --subject "$M" --checks config-schema-sequence --json
assert_eq "  a Drupal 10 port of a ^9 || ^10 module: off" "$T_RC|$(jq -c '.findings' "$T_OUT")" "0|[]"
DRUPILOT_TARGET_MAJOR=10 DRUPILOT_DRUPAL_TARGET='^10' t_run "$T_SH" "$PS" --subject "$M" --checks config-schema-sequence --core-req '^10 || ^11' --json
assert_eq "  but on when the range itself admits Drupal 11" "$T_RC|$(jq -c '.findings | length' "$T_OUT")" "3|4"
cat > "$M/config/schema/m.schema.yml" <<'EOF'
m.settings:
  type: config_object
  mapping:
    channels:
      type: sequence
      sequence:
        type: string
    flow:
      type: sequence
      sequence: {type: string}
EOF
printf 'm_test.x:\n  type: sequence\n  sequence:\n    type: string\n' > "$M/tests/modules/m_test/config/schema/m_test.schema.yml"
t_run "$T_SH" "$PS" --subject "$M" --checks config-schema-sequence --core-req '^10.1 || ^11' --json
assert_eq "  the mapping form: clean" "$T_RC|$(jq -c '.findings' "$T_OUT")" "0|[]"

# test-phpunit-api
cat > "$M/tests/src/Unit/FooTest.php" <<'EOF'
<?php

namespace Drupal\Tests\m\Unit;

use Drupal\Tests\UnitTestCase;

/**
 * @group m
 */
class FooTest extends UnitTestCase {

  public function testX(): void {
    $matcher = static::exactly(2);
    // $matcher->numberOfInvocations() in a comment.
    $this->token->expects($matcher)->method('generate')->willReturn(1);
  }

}
EOF
printf 'name: M\ntype: module\ncore_version_requirement: ^10.1 || ^11\n' > "$M/m.info.yml"
g add -A; g commit -qm base2
awk '/->willReturn\(1\);/ {
    sub(/->willReturn\(1\);/, "->willReturnCallback(function () use ($matcher) {"); print
    print "      return $matcher->numberOfInvocations() === 1 ? 1 : $matcher -> numberOfInvocations();"
    print "    });"; next
  } { print }' "$M/tests/src/Unit/FooTest.php" > "$T_TMP/foo.php" && mv "$T_TMP/foo.php" "$M/tests/src/Unit/FooTest.php"
t_run "$T_SH" "$PS" --subject "$M" --checks test-phpunit-api --json
assert_eq "test-phpunit-api: the port added numberOfInvocations() while ^10.1 || ^11 admits Drupal 10: an error per call" \
  "$T_RC|$(jq -c '[.findings[] | [.check, .severity, .line, .introduced]]' "$T_OUT")" \
  '3|[["test-phpunit-api","error",16,true]]'
assert_match "  the message names PHPUnit 9's method and the portable fix" "$(jq -r '.findings[0].message' "$T_OUT")" \
  "numberOfInvocations\(\) exists only from PHPUnit 10 \(Drupal 11\.0 and later\).*has getInvocationCount\(\) instead.*local counter"
t_run "$T_SH" "$PS" --subject "$M" --checks test-phpunit-api --core-req '^11' --json
assert_eq "  ^11 (PHPUnit 10+ only): off" "$T_RC|$(jq -c '.findings' "$T_OUT")" "0|[]"
g add -A; g commit -qm ported
t_run "$T_SH" "$PS" --subject "$M" --checks test-phpunit-api --base HEAD --json
assert_eq "  already there before the port: a warning (exit 0)" \
  "$T_RC|$(jq -c '[.findings[] | [.severity, .introduced]]' "$T_OUT")" '0|[["warn",false]]'
t_done
