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

The lab runs on 12.0.0-beta2 showed four facts:

- Most of the set's rules act only on PHPUnit test classes: a class Rector can tell extends `TestCase`. One does
  not: `AnnotationToAttributeRector` converts the bare tags (`@test`, `@before`, `@after`, `@small`,
  `@runInSeparateProcess`, ...) wherever they appear, once the attribute class exists. Those tags only mean
  something to PHPUnit, so in practice that is test code.
- Rector can tell a test class only with drupal-rector's `config/drupal-phpunit-bootstrap-file.php`. Without the
  file it does not know that `UnitTestCase` is a `TestCase`, and it converts nothing. `rector.php` already registers
  that file whenever it has a set.
- drupal-rector already converts four annotations itself. Its `PhpUnitTestAnnotationToAttributeRector`
  (`Drupal11SetList::DRUPAL_110`) adds `#[Group]`, `#[DataProvider]`, `#[Depends]` and `#[TestWith]`. It keeps each
  annotation when backward-compatible rewrites are on (the plan's `rector.bc`, for a range that keeps Drupal 11)
  and the installed core is below 12.0.0: Drupal 11's `run-tests.sh` groups tests by `@group` (11.2 to 11.4 put a
  test with only `#[Group]` under `##no-group-annotations`). Otherwise it removes the annotation. Rector's rules
  for the same annotations then convert a kept annotation a second time, and they do not check for an attribute
  already there: the lab bed's test class got two `#[Group('d11_for_d12')]`.
- drupal-rector's `DRUPAL_114` set adds `#[RunTestsInSeparateProcesses]` to kernel and functional test classes
  (`PhpUnitAddRunTestsInSeparateProcessesAttributeRector`), and every Drupal 12 plan lists that set.

## Decision

1. **No sibling config.** When the plan enables `rector.tests_pass`, its sets join `rector.php`'s set list
   (`{{RECTOR_SETS}}`, `rector_sets_block`), after the Drupal sets. They are written as
   `Rector\PHPUnit\Set\PHPUnitSetList::...` and filtered with `defined()` like the rest.
   - There is one config, one pass, and the same dry-run, review and apply cycle.
   - There is no second render to keep in step with the plan, and no fourth pass in `run-rector.sh`.
   - Their hits count under the official pass (`rule_hits.official`).
   - They join the list only when the plan's first Drupal set resolves. Rector bundles the PHPUnit sets, so
     `defined()` is always true for them, and `rector.php`'s "no Drupal set resolves" stop must still fire when
     drupal-rector is missing. Their rules need drupal-rector's bootstrap file anyway.
2. **drupal-rector's own rule wins for its four annotations.** `rector.tests_pass.skip` lists the set's rules
   that convert them a second time, and `rector_skip_block` adds them to `rector.php`'s `withSkip()`:
   `AnnotationWithValueToAttributeRector`, `DataProviderAnnotationToAttributeRector`,
   `DependsAnnotationWithValueToAttributeRector` and `TestWithAnnotationToAttributeRector`.
   - `AnnotationWithValueToAttributeRector` also converts `@backupGlobals`, `@backupStaticAttributes`,
     `@preserveGlobalState`, `@uses` and `@testDox`. Those stay annotations, which PHPUnit 12 ignores: a test
     adaptation item where a test needs them.
   - The other rules of the set stay: covers, requires, ticket, and the bare tags.
3. **When it is on.** `plan_tests_pass BED F` reads `phpunit_constraint` from the version data of two minors.
   - It enables the pass when the test-bed core's lowest admitted PHPUnit major is 12 or more: annotations are no
     longer read there.
   - It also requires that the floor F's lowest admitted PHPUnit major is 10 or more: every core of the declared
     range must read attributes. Drupal's own test discovery reads `@group`, which drupal-rector keeps for such a
     range, so a floor of 11.0 or 11.1 is fine.
   - A minor without that data counts as unknown: the pass stays off.
   - So a Drupal 12 port (bed 12.0, F 11.3) has it, and every Drupal 11 plan (bed PHPUnit 11) keeps
     `tests_pass: null`. Its `rector.php` is byte-identical, and H10 holds.
   - A range down to Drupal 10 (PHPUnit 9) never gets it, because PHPUnit 9 does not read attributes.
4. **Only `ANNOTATIONS_TO_ATTRIBUTES`.** 03-R10's exclusions stand. The set emits fully qualified attribute names
   (`#[\PHPUnit\Framework\Attributes\DataProvider(...)]`), and PHPCS's style pass leaves them as they are.

## Consequences

- No template-version bump: the tokens were already there, and a Drupal 11 render does not change. A frozen
  Drupal 12 plan from 1.0.0-alpha.6 has `tests_pass: null` and keeps it until it is re-planned.
- The T=12 plan and template goldens change. The T=11 ones do not.
- `rector-compat.php` shares the skip list, so the tests pass's skips appear there too. That pass loads no PHPUnit
  set, so they change nothing there.
- On a 12.0.0 bed (Drupal 12's stable release, 1.1) drupal-rector removes the annotations even for a range that
  keeps Drupal 11. The re-verification at GA decides whether that range needs its own handling.
