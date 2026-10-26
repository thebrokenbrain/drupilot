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

The lab runs on 12.0.0-beta2 showed five facts:

- Most of the set's rules act only on PHPUnit test classes: a class Rector can tell extends `TestCase`. One does
  not: `AnnotationToAttributeRector` converts the bare tags (`@test`, `@before`, `@after`, `@small`,
  `@runInSeparateProcess`, ...) wherever they appear, once the attribute class exists. Those tags only mean
  something to PHPUnit, so in practice that is test code.
- Rector can tell a test class only with drupal-rector's `config/drupal-phpunit-bootstrap-file.php`. Without the
  file it does not know that `UnitTestCase` is a `TestCase`, and it converts nothing. `rector.php` already registers
  that file whenever it has a set.
- drupal-rector converts some of the same annotations itself:
  - its `PhpUnitTestAnnotationToAttributeRector` (`Drupal11SetList::DRUPAL_110`) adds `#[Group]`, `#[DataProvider]`,
    `#[Depends]` and `#[TestWith]`. It keeps each annotation when backward-compatible rewrites are on (the plan's
    `rector.bc`, for a range that keeps Drupal 11) and the installed core is below 12.0.0, and removes it otherwise;
  - its `PhpUnitAddRunTestsInSeparateProcessesAttributeRector` (`DRUPAL_114`) adds `#[RunTestsInSeparateProcesses]` to
    every kernel and functional test class, unless the class already has the attribute.
- Rector runs a node's rules in the order they were registered, which is the order of the sets. Two of the set's
  rules then add a second attribute when they run after drupal-rector's: `AnnotationWithValueToAttributeRector`
  (`@group`) and `AnnotationToAttributeRector` (`@runTestsInSeparateProcesses`); `TestWithAnnotationToAttributeRector`
  does the same for a kept `@testWith`. A second `#[RunTestsInSeparateProcesses]` is an error: the attribute is not
  repeatable, and PHPUnit 12 refuses the class. The rules for `@dataProvider` and `@depends` never add one: the first
  checks for an existing attribute, and the second converts on the class node, before the method rules run.
- Drupal's `run-tests.sh` reads `@group` only on 11.0 and 11.1 (`TestDiscovery`). From 11.2 it uses PHPUnit's own
  discovery (`PhpUnitTestDiscovery`), which reads the attributes.

A rule-order probe on the lab bed (Rector 2.6.1, drupal-rector 1.1.3, a kernel test with each annotation) showed it:
with the PHPUnit set after the Drupal sets, `#[Group]`, `#[RunTestsInSeparateProcesses]` and `#[TestWith]` came out
twice; with it first and the `@group` rule skipped, every attribute came out once and `@group` stayed.

## Decision

1. **No sibling config.** When the plan enables `rector.tests_pass`, its sets join `rector.php`'s set list
   (`{{RECTOR_SETS}}`, `rector_sets_block`). They are written as `Rector\PHPUnit\Set\PHPUnitSetList::...` and
   filtered with `defined()` like the rest.
   - There is one config, one pass, and the same dry-run, review and apply cycle.
   - There is no second render to keep in step with the plan, and no fourth pass in `run-rector.sh`.
   - Their hits count under the official pass (`rule_hits.official`).
2. **The PHPUnit sets come first.** Their rules convert before drupal-rector's, which then find the attribute or no
   annotation left, so no attribute is added twice.
   - They join the list only when the plan's first Drupal set resolves. Rector bundles the PHPUnit sets, so
     `defined()` is always true for them, and `rector.php`'s "no Drupal set resolves" stop must still fire when
     drupal-rector is missing. Their rules need drupal-rector's bootstrap file anyway.
3. **`@group` stays with drupal-rector.** `rector.tests_pass.skip` lists `AnnotationWithValueToAttributeRector`, and
   `rector_skip_block` adds it to `rector.php`'s `withSkip()`. That rule removes `@group`, which a floor of 11.0 or
   11.1 still needs; drupal-rector's rule keeps it for such a range.
   - The same rule also converts `@backupGlobals`, `@backupStaticAttributes`, `@preserveGlobalState`, `@uses` and
     `@testDox`. Those stay annotations, which PHPUnit 12 ignores: a test adaptation item where a test needs them.
   - Every other rule of the set runs: data providers, depends, test-with, covers, requires, ticket and the bare
     tags.
4. **When it is on.** `plan_tests_pass BED F` reads `phpunit_constraint` from the version data of two minors.
   - It enables the pass when the test-bed core's lowest admitted PHPUnit major is 12 or more: annotations are no
     longer read there.
   - It also requires that the floor F's lowest admitted PHPUnit major is 10 or more: every core of the declared
     range must read attributes.
   - A minor without that data counts as unknown: the pass stays off.
   - So a Drupal 12 port (bed 12.0, F 11.3) has it, and every Drupal 11 plan (bed PHPUnit 11) keeps
     `tests_pass: null`. Its `rector.php` is byte-identical, and H10 holds.
   - A range down to Drupal 10 (PHPUnit 9) never gets it, because PHPUnit 9 does not read attributes.
5. **Only `ANNOTATIONS_TO_ATTRIBUTES`.** 03-R10's exclusions stand. The set emits fully qualified attribute names
   (`#[\PHPUnit\Framework\Attributes\DataProvider(...)]`), and PHPCS's style pass leaves them as they are.

## Consequences

- No template-version bump: the tokens were already there, and a Drupal 11 render does not change. A frozen
  Drupal 12 plan from 1.0.0-alpha.6 has `tests_pass: null` and keeps it until it is re-planned.
- The T=12 plan and template goldens change. The T=11 ones do not.
- `rector-compat.php` shares the skip list, so the tests pass's skips appear there too. That pass loads no PHPUnit
  set, so they change nothing there.
- On a 12.0.0 bed (Drupal 12's stable release, 1.1) drupal-rector removes `@group` even for a range that keeps
  Drupal 11. Only a floor of 11.0 or 11.1 needs it; the re-verification at GA decides whether such a range needs
  its own handling.
