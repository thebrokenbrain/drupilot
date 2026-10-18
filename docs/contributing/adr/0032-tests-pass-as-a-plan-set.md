# 0032 — The tests pass is a set of the plan, not a sibling config

- **Status:** accepted
- **Date:** 2026-10-18
- **Decided by:** the 1.0 working session (R-AUTO-3), during M6 (T-M6-05)

## Context

PHPUnit 12, the PHPUnit of Drupal 12's `drupal/core-dev`, no longer reads annotations. A test that names its data
provider with `@dataProvider` fails with `ArgumentCountError`, and `@covers` and `@group` are ignored (ADR 0004
amendment: the `d11_for_d12` unit test on 12.0.0-beta2).

Rector converts these annotations with `PHPUnitSetList::ANNOTATIONS_TO_ATTRIBUTES`. Rector 2 bundles the set.

The plan (10 AR-04, 03-R10) asks for a tests-only pass with that set only, and never `PHPUNIT_CODE_QUALITY`,
`NARROW_ASSERTS` or `MOCK_TO_STUB`, which change what a test verifies. ADR 0019 deferred a sibling template,
`rector-tests.php.tmpl`, until the plan's `rector.tests_pass` existed. The roadmap wires it as the `upgrade` sub
`rector-tests`.

The lab run on 12.0.0-beta2 showed two facts:

- The set's rules only act on PHPUnit test classes: a class Rector can tell extends `TestCase`. Elsewhere they change
  nothing.
- Rector can tell this only with drupal-rector's `config/drupal-phpunit-bootstrap-file.php`. Without the file it does
  not know that `UnitTestCase` is a `TestCase`, and it converts nothing. `rector.php` already registers that file
  whenever it has a set.

## Decision

1. **No sibling config.** When the plan enables `rector.tests_pass`, its sets join `rector.php`'s set list
   (`{{RECTOR_SETS}}`, `rector_sets_block`), after the Drupal sets. They are written as
   `Rector\PHPUnit\Set\PHPUnitSetList::...` and filtered with `defined()` like the rest.
   - The rules only change test classes, so the effect is the tests-only pass the plan describes.
   - There is one config, one pass, and the same dry-run, review and apply cycle.
   - There is no second render to keep in step with the plan, and no fourth pass in `run-rector.sh`.
   - Their hits count under the official pass (`rule_hits.official`).
2. **When it is on.** `plan_tests_pass BED F` reads `phpunit_constraint` from the version data of two minors.
   - It enables the pass when the test-bed core's lowest admitted PHPUnit major is 12 or more: annotations are no
     longer read there.
   - It also requires that the floor F's lowest admitted PHPUnit major is 10 or more: every core of the declared
     range must read attributes.
   - A minor without that data counts as unknown: the pass stays off.
   - So a Drupal 12 port (bed 12.0, F 11.3) has it, and every Drupal 11 plan (bed PHPUnit 11) keeps
     `tests_pass: null`. Its `rector.php` is byte-identical, and H10 holds.
   - A range down to Drupal 10 (PHPUnit 9) never gets it, because PHPUnit 9 does not read attributes.
3. **Only `ANNOTATIONS_TO_ATTRIBUTES`.** 03-R10's exclusions stand. The set emits fully qualified attribute names
   (`#[\PHPUnit\Framework\Attributes\DataProvider(...)]`), and PHPCS's style pass leaves them as they are.

## Consequences

- No template-version bump: the token was already there, and a Drupal 11 render does not change. A frozen Drupal 12
  plan from 1.0.0-alpha.6 has `tests_pass: null` and keeps it until it is re-planned.
- The T=12 plan and template goldens change. The T=11 ones do not.
- Not covered by this pass: Drupal 12 also wants `#[RunTestsInSeparateProcesses]` on kernel and functional test
  classes (ADR 0004). No Rector rule adds it yet, so it stays a test adaptation item.
