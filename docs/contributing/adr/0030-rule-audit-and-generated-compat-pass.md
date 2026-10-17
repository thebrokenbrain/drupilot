# 0030 — The rule audit and the generated compat pass

- **Status:** accepted
- **Date:** 2026-10-17
- **Decided by:** the 1.0 working session (R-AUTO-3), during M5 (T-M5-03, T-M5-04)

## Context

ADR 0002 split Rector into a main pass at the PHP floor L and a narrow compat pass, and left two things for
M5:

- the compat list was one literal rule (`ExplicitNullableParamTypeRector`), with `PHP_84` written into
  `rector-compat.php`;
- the main pass never received a polyfill list, so Rector read the `require` of the test-bed's root
  `composer.json`, as ADR 0002 Decision 6 describes.

The plan settles the direction: a staged PHP helper reflects the pinned Rector's PHP sets (AR-11), and "combined
with the allowlist" of `config/php/rules.json` it gives the compat list (03-R5). The polyfill list is the
intersection over the declared range (03-R2), which ADR 0029 made version data. Four questions were open:

1. When does the upgrade plan know the compat list? `/drupilot-setup` freezes the plan before the test-bed and
   its Rector exist.
2. Where is the audit kept, and how is the `withPhpVersion()` of the compat pass chosen?
3. Which compat rows does the pass run, now that every safe one can run, not only the literal one?
4. What does handing Rector the polyfills switch on?

The audit was run on the lab bed `dpl-m5-phpwin-d11` (rector/rector 2.6.1, PHP 8.4). Its 15 sets (`PHP_53` to
`PHP_86` and `PHP_POLYFILLS`) register 143 rules. For every compat row of `rules.json`, the audited
`provideMinPhpVersion()` equals the row's `deprecated_in`, with one exception:
`RemoveReflectionSetAccessibleCallsRector` (deprecated in 8.5) sits in the `PHP_81` set at 8.1.
`RectorConfig::polyfillPackages()` stores the list in a parameter, and `PolyfillPackagesProvider` returns that
parameter before it reads `getcwd()/composer.json`, so an explicit list, even an empty one, makes the main pass
independent of the bed.

## Decision

1. **The plan holds the allowlist side; the render applies the audit.** `upgrade-path.sh` writes
   `rector.compat_rules` from the version data alone (`php_compat_pass_rules L U`). These are the compat rows
   classified `apply-compat` for `[L..U]`, minus those deprecated at or below the PHP of the floor's level set,
   which the main pass runs. U is ADR 0002's top: the higher of P and the highest PHP a core of the range
   supports. The plan also writes `rector.polyfills`, the packages of `core_range_polyfills C`. Both fields
   stay pure functions of the data, as AR-06 requires. A plan frozen before them (`null`) computes them when
   it is read (`plan_compat_rules`, `plan_polyfills`).
2. **The audit is cached per Rector version in the root's lock.** `scripts/analysis/rector-rule-audit.sh`
   stages `scripts/php/rule-audit.php` and runs it through `$(drupal_runner) php`. The helper imports each
   PHP set into its own `RectorConfig`, reads the rules each set registered, and reads `min_php` and the
   polyfill package from an instance made without its constructor. The result
   (`{rule, sets, min_php, polyfill, interfaces}`) goes into `.rector_rule_audit` with the composer.lock
   version of `rector/rector`, and is read back from there until that version changes. `run-rector.sh` and
   `render-templates.sh` run it when the lock has none (never with `--dry-run`). When it cannot run (no PHP),
   the pass follows `rules.json` alone, with a warning.
3. **The compat list is the plan's list checked against the audit.** `rector_compat_list` drops the rules the
   installed Rector does not register, and the rules the audit puts in a PHP set at or below the floor's
   level set, which the main pass already runs. `withPhpVersion()` is the highest audited `min_php` among
   the listed rules; without the audit, the rows' `deprecated_in` (else `removed_in`). The value never
   filters a listed rule out, because the audited minimum is never above the deprecation. `rector-compat.php`
   becomes template 2, with tokens `{{COMPAT_RULES}}`, `{{COMPAT_PHP_VERSION}}` and the plan's
   `{{SKIP_RULES}}`. The pass runs whenever the list is not empty, no longer only "when L < 8.4".
4. **Every safe compat row runs; the classification follows.** `php_rule_class` no longer asks whether a
   literal list holds the rule. A compat row that is safe for Drupal, in the window, and whose output runs
   on L is `apply-compat`: the main pass runs it, or else the compat pass does. Reviewing the source of the
   rows that now run for the first time (Rector 2.6.1) changes one: `OrdSingleByteRector` rewrites
   `ord($s)` to `ord($s[0])` for any string-typed argument. On an empty string that raises an
   "Uninitialized string offset" warning on every PHP, where `ord('')` returned 0 silently before 8.5
   (observed on 8.2, 8.4 and 8.5). Its row becomes `drupal_safe: false`: it is reported and skipped.
5. **The main pass gets the polyfills explicitly.** `rector.php` becomes template 6. Its `{{POLYFILLS}}`
   wraps the config in a closure that calls `polyfillPackages()` with the plan's list, guarded by
   `method_exists()` because the method is `@internal`. With `^10.3 || ^11` the list is empty and the
   `PHP_POLYFILLS` rules stay off whatever the bed lists. From `^11.2` on, `polyfill-php84` lets the
   `foreach` → `array_find()` family run below 8.4 (03-R2's acceptance).
   `DeprecatedAnnotationToDeprecatedAttributeRector` is also in that set (and in the php84 level set). It
   turns `@deprecated` into `#[\Deprecated]`, which from PHP 8.4 makes every use emit a native
   `E_USER_DEPRECATED` (php.net), next to the `@trigger_error()` of Drupal's policy. Drupal core 11.4.8 uses no
   `#[\Deprecated]`. It gets a `deny` row: skipped everywhere.

## Consequences

- With the default `^10 || ^11` plan (L 8.1, U 8.5), the compat pass lists ten rules where it listed one, at
  `PHP_85`. None of the fixtures uses the newly listed constructs, so the lab-recorded port patches are
  unchanged.
- The goldens of the plans and the templates change. They move to a new data snapshot, because `rules.json`
  gained a row and a `drupal_safe` change. The 0.9 baseline records the `rector.php` and `phpstan.neon` renders
  as allowed differences.
- `rules.json` stays the allowlist: a rule enters the compat pass only through a verified row, never because the
  audit found it. The audit's `missing` list shows the rows a new Rector no longer registers.
- `php-target.sh` still classifies against P. The compat pass covers `[L..U]` (ADR 0002), so a row deprecated
  above P can be applied without being reported. That is unchanged from ADR 0002.
