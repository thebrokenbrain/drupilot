# 0019 — rector.php is rendered from the upgrade plan

- **Status:** accepted
- **Date:** 2026-10-05
- **Decided by:** the 1.0 working session (R-AUTO-3), during M3 (T-M3-09)

## Context

AR-24 makes `rector.php` plan-driven: `{{RECTOR_SETS}}`, `{{BC_BLOCK}}`,
`{{PHP_VERSION_L}}`, `{{PHP_SETS_L}}`, `{{POLYFILLS}}` and `{{SKIP_RULES}}`,
with the sha256 of each render kept in the lock. Template 4 hard-coded the
`Drupal10SetList::DRUPAL_10` aggregate and the skip list, and took its PHP
floor from `rector_php_bounds`. H10 requires the port of `legacy_widgets` to
stay byte-identical. AR-24 leaves open:
- what replaces the aggregate;
- what `{{BC_BLOCK}}` renders when BC is off;
- which hops' sets are rendered;
- where the plan comes from when none is frozen;
- how an untouched render is recognized.

## Decision

1. **Per-minor sets plus the bootstrap file.** `{{RECTOR_SETS}}` lists the
   plan's `rector.drupal_sets` then `rector.breaking_sets`, by constant name,
   kept only when `defined()`, so a set the installed drupal-rector lacks is
   left out. When the plan names sets and none of them resolves, drupal-rector
   is missing or cannot be autoloaded: the config throws, Rector fails, and
   `run-rector.sh` reports a crash (exit 3), as template 4 did with its
   `DRUPAL_10` constant. It never runs a pass that applies no Drupal rule and
   reports nothing to change.
   - drupal-rector's aggregates (`drupal-10-all-deprecations.php` in 1.1.3)
     also register `config/drupal-phpunit-bootstrap-file.php`: Drupal's test
     namespaces and phpstan-drupal's service map, for type inference. The
     template registers it whenever there is a Drupal set.
   - Lab check (`$LAB/m3/tpl/eqv.sh`): template 4 and template 5 were run
     with `rector process --dry-run` in `php:8.3-cli` on the H10 bed. The
     subjects were legacy_widgets, d8_legacy, d9_module, keep_current,
     acme_core, acme_search and a lab module that uses `system_time_zones()`,
     `watchdog_exception()` and `file_create_url()`.
   - Both templates gave identical diffs and applied rules (for example
     SystemTimeZonesRector, WatchdogExceptionRector, FunctionToStaticRector).
     legacy_widgets matches its H10 recording (FunctionFirstClassCallableRector,
     1 file).
2. **D8/D9 sets stay out until T-M9-03.** Only families of Drupal 10 and
   later are rendered, because 0.9 never ran the Drupal 8/9 sets. This refines
   ADR 0017's D6: a rule of "hops from T−1" would also drop a Drupal 10
   module's own sets for T = 12.
3. **BC block only when the plan enables it.** With `rector.bc.enabled`, the
   template wraps the config to register `DrupalRectorSettings` with
   `enableBackwardCompatibility()` and `setMinimumCoreVersionSupported('<F>.0')`.
   Otherwise it renders nothing, which leaves drupal-rector's default, as in
   0.9: BC on, from 10.1.0.
   - In the lab, `^10.3 || ^11` then rewrites `format_size()` to
     `ByteSizeMarkup::create()` directly, instead of a `DeprecationHelper`
     wrapper, because that API exists from 10.2.
   - The `^10 || ^11` case, where the default wrappers need a core newer than
     10.1.3, is left as it was for M6 (T-M6-06, ADR 0017 item 2).
4. **The floor is the plan's.** `{{PHP_VERSION_L}}` / `{{PHP_SETS_L}}` come
   from the plan's `php.floor`, so `rector.php` and the plan cannot disagree
   (H4). It equals `rector_php_bounds` unless the code itself needs a newer
   PHP than the range's floor, and Rector modernizing up to a PHP the code
   already requires is safe. The ceiling of the compat pass stays with
   `rector_php_bounds` until M5 (AR-03).
5. **Where the plan comes from.** `render-templates.sh` and `run-rector.sh`
   use `plan_for_subject`:
   - the plan frozen in the root's lock when it is the subject's;
   - else a fresh draft from `upgrade-path.sh`, with nothing written;
   - else, when no plan resolves (a refusal), `plan_render_fallback`: the
     verified per-minor sets of Drupal T−1, the skip list, no BC block, and
     the floor `rector_php_bounds` gives.

   `render-templates.sh --json` reports the source (`plan`: `plan` or
   `fallback`).
6. **Untouched renders are known by their sha256.** Every file
   `render-templates.sh` writes or finds up to date (never on a dry run), and
   every `rector.php` `run-rector.sh` writes, has its sha256 kept in the
   root's lock at `.templates[<file>]` (`{sha256, template_version}`).
   - A copy whose sha256 is the kept one is an untouched render and is
     regenerated after a backup when the plan moves, even when the floor stays.
   - A copy with any other content is hand-edited (INV5) and is replaced only
     with `--force`.
   - The template-4 heuristics (`older_drupilot_copy`, `rector_config_pristine`)
     still recognize copies from before the lock kept their sha256.
     `rector_config_pristine` cannot recognize a template-5 `rector.php`: its
     sets, skips and BC block come from the plan, not from the file.
   - So a template-5 `rector.php` whose sha256 the lock no longer keeps (a
     cleared lock, a moved root, another `DRUPILOT_HOME`) counts as
     hand-edited: it is never overwritten without `--force`, and the warning
     says so. Its sha256 is kept again as soon as it is found equal to the
     current render (`render-templates.sh` "unchanged", `run-rector.sh`).
     Losing the record only costs a `--force`; recognizing edits from the file
     alone would have to trust the plan-driven regions.
7. **The skip list is the data's.** `{{SKIP_RULES}}` renders
   `plan_rector_skip`: the `deny` rows of `config/php/rules.json` plus every
   compat row that is not `drupal_safe`, in the file's order. `data-check.sh`
   checks that a skipped rule is `drupal_safe: false`.
8. **Deferred.** The tests-only sibling `rector-tests.php.tmpl` waits for the
   plan's `rector.tests_pass` (M6, T-M6-05), and `{{POLYFILLS}}` stays empty
   until `rector.polyfills` (M5, T-M5-04). `phpstan.neon` template 3
   (`phpVersion {min, max}`, the profile, the cache directory) is ADR 0020.

## Consequences

- H10 holds: the lab run gives identical diffs, and
  `tests/unit/templates_v3_t11_equivalence.sh` pins the configuration
  equivalence statically.
- Existing template-4 `rector.php` files, edited or not, are upgraded
  automatically after a backup, with their diff printed (marker 4 is older
  than 5: the older-marker exception of `render-templates.sh`).
- At the next marker bump, a kept sha256 that no longer matches should win
  over the older-marker exception, so a template-5 copy proven edited is not
  upgraded without `--force`.
- `tests/golden/templates/` pins the render of every resolving golden plan.
