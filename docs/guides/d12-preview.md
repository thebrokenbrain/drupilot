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
  updates from. Choose `target-only` for `^12` alone;
- the PHP window 8.3..8.5. Drupal 12 needs PHP 8.5, and the floor follows the range;
- the Rector sets of the 11.x minors, the 11.x breaking sets up to the floor, and `Drupal12SetList::DRUPAL_120`;
- the **core removals**: what your code still takes from core that Drupal 12 removes. That covers modules that moved
  to contrib (Contact, History, Ban, ...), Claro and Olivero, `migrate_drupal`, Backbone and Underscore. See
  [Core removals](../concepts/upgrade-paths.md#core-removals).

`bash "$CLAUDE_PLUGIN_ROOT/scripts/drupilot.sh" plan show` prints it.

## The Drupal 12 test-bed

`ddev-up.sh` builds the bed from the toolchain cell `12` (`config/toolchain-reference.json`,
[ADR 0004](../contributing/adr/0004-d12-bed.md)):

- a DDEV `drupal12` project on PHP 8.5, created with the plan's pre-release core;
- **no drush**. No drush release installs on Drupal 12 yet; core's own `vendor/bin/dr` covers what the bed needs
  (`dr ex:install`, `dr cr`, `dr uli`);
- `drupal/core` **from source**. Drupal 12's packaged core leaves out its tests, and PHPStan and PHPUnit need them;
- the cell's pinned toolchain: Rector 2.6.1, PHPStan 2.2.16, phpstan-drupal 2.2.2, coder 9.0.1 (PHPCS 4), and
  PHPUnit 12 from `drupal/core-dev`.

## What the port changes

- **PHPUnit attributes.** PHPUnit 12 no longer reads `@dataProvider`, `@covers` or `@group`. The plan adds Rector's
  `PHPUnitSetList::ANNOTATIONS_TO_ATTRIBUTES` to the Rector run ([ADR 0032](../contributing/adr/0032-tests-pass-as-a-plan-set.md)),
  and only that set: nothing that changes what a test checks.
- **Symfony 8.** `DRUPAL_120` adds the `mixed` and `void` types Symfony 8 requires on a constraint validator's
  `validate()`.
- **Core removals** become worklist items for a person:
  - a removed base theme is a decision: a new base theme, or the contrib theme;
  - a removed module with a contrib release that covers your range is a dependency to rewrite: `contact:contact`
    plus `composer require drupal/contact`;
  - a removal with no replacement, such as `migrate_drupal` or a removed library, is a hard break.

  An open hard break keeps the port `blocked` in `port-summary.sh`.

## Limits of the preview

- upgrade_status does not run on a Drupal 12 bed: it needs drush, and there it would report Drupal 13 readiness.
- Drupal 12 also expects `#[RunTestsInSeparateProcesses]` on kernel and functional tests. No Rector rule adds it yet:
  add it by hand where the test suite asks for it.
- The dependency rewrite under H8 is not automatic yet: the item says what to change.
- The pre-release data (the removals, the toolchain) is re-verified at 12.0.0-rc1 and at 12.0.0.
