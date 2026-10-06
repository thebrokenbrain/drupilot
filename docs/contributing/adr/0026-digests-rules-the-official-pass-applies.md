# 0026 — Digests rules the official pass already applies

- **Status:** accepted
- **Date:** 2026-10-06
- **Decided by:** the 1.0 working session (R-AUTO-3), during M4 (T-M4-08)

## Context

03-R17 removes the double source of a fix: a `drupal-digests` rule that drupal-rector already implements
should not run again in the digests pass. drupal-rector records them in `docs/implemented-digests.yml`, one
entry per drupal.org issue, with `status: implemented` and the classes, or `status: config-only` and no
class.

A first filter skipped every `implemented` entry whose classes exist in `vendor/`, and every `config-only`
entry. The review of T-M4-08 found that this drops rules nobody applies. At drupal-rector 1.1.3, the classes
of the implemented entries are registered only in its Drupal 11 sets (`config/drupal-11/*.php`). A port to 11
renders `rector.php` with the Drupal 10 sets only, so that it never rewrites to an API the kept Drupal 10
lacks (ADR 0019). 112 of the 174 digests rules were then applied by neither pass. One of them is
`Sql::getMigrationPluginManager()`, removed in 11.0.

## Decision

- **A rule is skipped only when the official pass applies it.** drupilot reads the sets the official
  `rector.php` names (`Drupal<N>SetList::CONST`, comment lines left out). It resolves each one to its config
  file in the installed drupal-rector, follows nested sets and `__DIR__` includes, and collects every
  `*Rector::class` those files name (`digests_official_classes`). An `implemented` entry is skipped when
  every class it names is in that set. Otherwise it is `implemented_not_loaded`, and the rule stays in the
  digests pass.
- **`config-only` entries are kept.** The file names no class or config file for them, so drupilot cannot
  show that a loaded set applies them. The digests pass runs them, reviewed like any other rule. Running one
  after an official rule that already rewrote the code finds nothing to change.
- **The filter fails closed.** The pass stops with exit 4, and the official result stands, when:
  - a `require_once` file declares no class that `all.php` registers;
  - a registered class has no file;
  - `all.php` has a directive other than `withFileExtensions` and `withRules`.

  The filtered copy would otherwise drop a rule or a directive without saying so.
- **Verdicts belong to the sources they were given on.** An `--apply` refuses the digests pass when this
  digests SHA has verdicts for other sources and none for the current ones. Otherwise every rejected rule
  would run unreviewed. `digests-decisions.sh` refuses to record verdicts on sources changed since the
  dry-run.
- **An autonomous run's verdicts are its defaults, not the developer's.** They are recorded with
  `by: "auto"`, and only an autonomous run replays them. A guided port asks the developer again (G5).

## Consequences

- On a port to 11, the digests pass keeps the rules drupal-rector implements in its Drupal 11 sets, as 0.9
  did. On a port to 12, where the plan loads those sets, they are skipped.
- A change of layout upstream stops the digests pass until drupilot reads it. The message names what could
  not be read.
- `digests_filter` reports `skipped_implemented`, `implemented_not_loaded`, `config_only`, `rejected` and
  `kept`.
