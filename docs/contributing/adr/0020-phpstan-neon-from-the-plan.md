# 0020 — phpstan.neon is rendered from the upgrade plan

- **Status:** accepted
- **Date:** 2026-10-05
- **Decided by:** the 1.0 working session (R-AUTO-3), during M3 (T-M3-09)

## Context

AR-24 and T-M3-09 give `phpstan.neon.tmpl` template 3 three additions:
- `phpVersion: {min, max}`;
- the profile (`compat|refactor`);
- a `tmpDir` "keyed by the lock hash".

03-R8 details the profiles:
- **compat (Phase 1):** level 2, the deprecation rules, phpstan-drupal's
  bleedingEdge "limited to the deprecated-hooks checks", and the opinion rules
  off: `globalDrupalDependencyInjectionRule`,
  `entityStorageDirectInjectionRule`, `testClassSuffixNameRule` and
  `classExtendsInternalClassRule`;
- **refactor (Phase 2):** level 5–6, every rule on.

Several things are left open:
- which hash keys the cache;
- how a run picks the profile;
- whether those parameters do anything in the pinned phpstan-drupal.

## Decision

1. **The PHP range is the plan's.** `phpVersion: {min, max}` renders the
   plan's `php.phpstan_phpversion`: the `PHP_VERSION_ID` of the floor L and of
   the target P.
   - Without a plan (a refusal), it uses the floor `rector_php_bounds` gives
     and the PHP target (`php_version_id`).
   - PHPStan 2.2.16, the toolchain cell 11 pin, accepts the form
     `anyOf(int, {min, max})` with values 70100..80699. This was read from
     `conf/parametersSchema.neon` in its phar.
2. **The cache is keyed by the plan.** The `tmpDir` is
   `.phpstan-cache/<first 12 hex digits of the plan hash>` (`phpstan_cache_key`).
   This is the `upgrade_plan_hash` form, with `meta` excluded. A fallback plan
   adds the PHP range it renders to what it hashes.
   - The lock's own content is not used: it changes on every `lock-sync`, which
     would re-render `phpstan.neon` with no change to the analysis.
   - The plan hash moves exactly when what PHPStan is configured for moves.
   - PHPStan already invalidates its result cache when the configuration
     changes. A directory per plan only keeps two plans from evicting each
     other, and keeps a stale cache from ever being read.
   - `.phpstan-cache/` stays gitignored and excluded from patches and copies.
3. **The compat profile turns the four opinion rules off.** They ask for
   changes no Drupal version requires, and a minimal port makes none of them.
   - The rule names are those of phpstan-drupal 2.2.2's `extension.neon`.
   - The bleedingEdge deprecated-hook flags (`checkCoreDeprecatedHooksInApiFiles`,
     `checkContribDeprecatedHooksInApiFiles`; the combined
     `checkDeprecatedHooksInApiFiles` is deprecated) are **not** enabled. In
     phpstan-drupal 2.2.2 they only make the autoloader load the `*.api.php`
     files. `DeprecatedHookImplementation` exists but no neon file registers
     it.
   - In the lab, a module implementing `hook_ranking()` (deprecated in
     11.3.0) gave no finding either way. Enabling them would only add load
     time.
   - Revisit this when a pinned phpstan-drupal registers that rule.
4. **The refactor profile keeps every rule as phpstan-drupal ships it.**
   - The level stays a command-line argument. `run-phpstan.sh --level` gets
     `DRUPILOT_PHPSTAN_LEVEL_REFACTOR` in Phase 2, as in 0.9, and the template
     keeps `DRUPILOT_PHPSTAN_LEVEL`.
   - "Every rule on" means phpstan-drupal's defaults:
     `pluginManagerInspectionRule` and `configGetUnknownKeyRule` stay off as it
     ships them.
5. **Picking the profile.**
   - `render-templates.sh` renders the plan's `phpstan.profile` (`compat` from
     the resolver), unless `--profile compat|refactor` names one.
   - The refactor stage (`/drupilot-refactor` Step 5 and the `full-refactor`
     skill) re-renders with `--profile refactor` before its PHPStan run. An
     untouched render is regenerated (its sha256 is in the lock, ADR 0019); a
     hand-edited one stays (exit 3) and PHPStan runs with it.
   - `render-templates.sh --json` reports `phpstan_profile`.
6. **The file follows the plan.** The port freezes the final plan after the
   setup rendered `phpstan.neon` from the draft, and the refactor refreezes it
   for the range it applies (`upgrade-path.sh --phase final --range ...`).
   - `run-phpstan.sh` re-renders an untouched `phpstan.neon` first (its
     sha256 is the one kept in the lock), after a backup and keeping the
     profile of its `drupilot-phpstan-profile` line, as `run-rector.sh` does
     for `rector.php`.
   - Without this, a stale minimum rejects code Rector rightly wrote for the
     new floor. In the lab, PHPStan 2.2.16 with `min: 80100` reported
     `classConstant.nativeTypeNotSupported` for a typed constant (PHP 8.3)
     that the `^11` plan allows.
   - A hand-edited file is used as it is.
   - `render-templates.sh` warns when the plan's PHP target is not the
     configured one: re-planning is the setup's job.

## Consequences

- Phase 1 PHPStan output loses the opinion findings, and nothing else. In the
  lab (H10 bed: core 11.4.8, PHPStan 2.2.16, phpstan-drupal 2.2.2,
  `php:8.3-cli`), template 2 and template 3 compat gave identical findings on
  d8_legacy, d9_module, keep_current and acme_core. They differed only by the
  `globalDrupalDependencyInjection` findings on legacy_widgets (39 → 38),
  acme_search (6 → 5) and a lab module (12 → 10). The refactor profile gave
  template 2's findings (legacy_widgets: 39).
- Existing template-2 copies are upgraded after a backup (marker 2 is older
  than 3). The 0.9 baseline records the new renders (`allowed-diffs.txt`).
- `tests/golden/templates/<plan>/` now pins `phpstan.neon` and
  `phpcs.xml.dist` beside `rector.php`. `rector-compat.php` follows the plan in
  M5 (T-M5-04), and `rector-tests.php` in M6 (T-M6-05).
