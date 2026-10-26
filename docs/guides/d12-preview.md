# Drupal 12 preview

!!! warning "Experimental"
    The Drupal 12 preview is experimental in drupilot 1.0, and not part of its release criteria. It is off unless
    you opt in, and its behaviour and outputs may change in a 1.x release. Official Drupal 12 support follows
    Drupal 12's stable release.

Drupal 12 has no stable release yet. drupilot can still port a module or theme to it, as a **preview** on the
newest pre-release core, which is 12.0.0-beta2 at the time of writing. Use it to see what Drupal 12 asks of your
code, and to get it ready before 12.0.0 ships. A preview port is not a release of your module for Drupal 12. The
versions it relies on are re-verified at the release candidate and at the stable release.

## Opt in

The target major is Drupal 11 unless you ask for 12. Asking for a pre-release needs an explicit opt-in:

- in a guided run, `/drupilot-setup --target 12` (or `/drupilot --target 12`) shows the **Pre-release** tab.
  The default is *No*, which ports to Drupal 11; *Yes* plans the port to Drupal 12;
- in an autonomous run there is no tab. Set `DRUPILOT_ALLOW_PRERELEASE=true` (or the pre-answer
  `DRUPILOT_CHOICE_ALLOW_PRERELEASE=yes`) with `DRUPILOT_TARGET_MAJOR=12`. Without it the plan refuses and nothing
  is written.

The answer is kept in the project's `.drupilot.json` once the draft plan resolves.

## What the plan says

`/drupilot-setup` freezes the [upgrade plan](../concepts/upgrade-paths.md) of the port. For Drupal 12 it usually
gives:

- the declared range `^11.3 || ^12`, so the module keeps Drupal 11.3 and later. 11.3 is the oldest release Drupal 12
  updates from. For `^12` alone, set `DRUPILOT_CORE_TARGET_STRATEGY=target-only` before the setup: the port shows
  no Core target tab for a preview, because that tab's options are Drupal 11's;
- the PHP window 8.3..8.5. Drupal 12 needs PHP 8.5, and the floor follows the range;
- the Rector sets of the 11.x minors, the 11.x breaking sets up to the floor, and `Drupal12SetList::DRUPAL_120`;
- the **core removals**: what your code still takes from core that Drupal 12 removes. That covers modules that moved
  to contrib (Contact, History, Ban, ...), Claro and Olivero, `migrate_drupal`, Backbone and Underscore. See
  [Core removals](../concepts/upgrade-paths.md#core-removals).

`bash "$CLAUDE_PLUGIN_ROOT/scripts/drupilot.sh" plan show` prints it.

## The Drupal 12 test-bed

`ddev-up.sh` builds the bed from the toolchain cell `12` (`config/toolchain-reference.json`,
[ADR 0004](../contributing/adr/0004-d12-bed.md)):

- its own test-bed, `<name>-d12` next to a loose checkout. A site on Drupal 11 is never used in place: drupilot
  never upgrades a site's core, so set `DRUPILOT_WORKSPACE_DIR` to a new directory for a module that lives in one;
- a DDEV `drupal12` project on the plan's PHP (8.5), created with the plan's pre-release core;
- **no drush**: no drush release installs on Drupal 12 yet. drupilot installs no site on the bed (the kernel and
  functional tests install their own), and Upgrade Status, which analyses through drush, is skipped;
- `drupal/core` **from source**. Drupal 12's packaged core leaves out its tests, and PHPStan and PHPUnit need them;
- the cell's pinned toolchain: Rector 2.6.1, PHPStan 2.2.16, phpstan-drupal 2.2.2, coder 9.0.1 (PHPCS 4), and
  PHPUnit 12 from `drupal/core-dev`.

## What the port changes

- **PHPUnit attributes.** PHPUnit 12 no longer reads annotations such as `@dataProvider`, `@covers` or `@group`.
  - drupal-rector's own rule (in `Drupal11SetList::DRUPAL_110`) converts `@group`, `@dataProvider`, `@depends` and
    `@testWith`. For a range that keeps Drupal 11 it also keeps each annotation, because Drupal 11's
    `run-tests.sh` groups tests by `@group`.
  - The plan adds Rector's `PHPUnitSetList::ANNOTATIONS_TO_ATTRIBUTES` for the rest, such as `@covers`, `@before`,
    `@test` and `@requires` ([ADR 0032](../contributing/adr/0032-tests-pass-as-a-plan-set.md)). It skips the set's
    rules for the four annotations drupal-rector converts, and adds nothing that changes what a test checks.
  - drupal-rector's `DRUPAL_114` set adds `#[RunTestsInSeparateProcesses]` to kernel and functional test classes.
- **Symfony 8.** `DRUPAL_120` adds the `mixed` and `void` types Symfony 8 requires on a constraint validator's
  `validate()`.
- **Core removals** become worklist items for a person:
  - a removed base theme is a decision: a new base theme, or the contrib theme;
  - a removed module with a contrib release that covers your range is a dependency to rewrite: `contact:contact`
    plus `composer require drupal/contact`;
  - a removal with no replacement, such as `migrate_drupal` or a removed library, is a hard break.

  An open hard break keeps the port `blocked` in `port-summary.sh`.

## Limits of the preview

- The Drupal 11 half of the range (`^11.3`) is declared, not verified: the port's core matrix step
  (`verify-core-matrix.sh`) checks a kept Drupal 10 half, and a preview's range has none.
- `@backupGlobals`, `@backupStaticAttributes`, `@preserveGlobalState`, `@uses` and `@testDox` stay annotations,
  which PHPUnit 12 ignores: their Rector rule also converts `@group` and `@depends`, so the plan skips it. Convert
  them by hand where a test needs them.
- PHPUnit 12 reports a mock that sets no expectation as a notice, and the notice fails the group. Use
  `createStub()`, or `#[AllowMockObjectsWithoutExpectations]`, as a test adaptation.
- The dependency rewrite under H8 is not automatic yet: the item says what to change.
- The pre-release data (the removals, the toolchain) is re-verified at 12.0.0-rc1 and at 12.0.0.
