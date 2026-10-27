# 0002 — PHP compat rules run in a second, narrow Rector pass

- **Status:** accepted
- **Date:** 2026-10-04
- **Decided by:** the 1.0 working session (R-AUTO-3), spike AR-40 (T-M2-08)

## Context

drupilot 0.9 renders `->withPhpSets(<P>: true)` from the PHP target P and
never sets Rector's PHP version. Rector then takes that version from the
`require.php` of the bed root `composer.json` (a drupal/recommended-project
root has none) or from the container PHP. On a bed with PHP 8.3, a module
that keeps `^10.3 || ^11` (PHP floor L = 8.1) therefore gets PHP 8.2 and 8.3
rewrites (03-G1). The AR-03 classes need the opposite:

- `apply-modernize`: only the level sets up to L (H1: never a set above L);
- `apply-compat`: a deprecation fix whose output is valid on L, such as
  `ExplicitNullableParamTypeRector` (`Foo $x = NULL` -> `?Foo $x = NULL`);
- `deny`: `SleepToSerializeRector` and `WakeupToUnserializeRector` (H2).

Three things were unknown: whether a rule passed with `withRules()` still
goes through `PhpVersionedFilter` (03-OQ-3), whether the pinned Rector has an
explicit polyfill API (03-OQ-2), and whether `--only` works (05-Q12). This
ADR blocks every Rector-config change: `withPhpVersion` and the compat rule
(T-M2-13), the skip-list additions (T-M2-14) and the `rector-rule` recipe
engine (AR-11). Both candidate pins were tested: rector/rector 2.5.2 and
2.6.1 (palantirnet/drupal-rector 1.1.3 conflicts with `>=2.6.2`).

## Decision

**Two passes.** One pass cannot do it on either pin (see Evidence). A rule
added with `withRules()` goes through `PhpVersionedFilter` like any set rule,
so with the PHP version at L the compat rule is dropped. With the PHP version
at P, `ForeachToArrayFindRector` from the `PHP_POLYFILLS` set (which
`withPhpSets()` always adds) emits `array_find()`. `--only` cannot help,
because it is applied after the filter. The two passes are:

1. **Main pass** (`rector.php`, unchanged invocation): the Drupal sets, the
   skip list, `->withPhpVersion(PhpVersion::PHP_<L>)` and
   `->withPhpSets(php<L>: true)`. The level sets stop at L, not at P: this
   supersedes "keep `withPhpSets` at the target" in 03-R1, because a set
   above L also registers configured rules that are not version-bound (the
   php85 set's `RenameClassConstFetchRector` rewrote `\PDO::MYSQL_ATTR_*` to
   the PHP 8.4 class `\Pdo\Mysql` with the PHP version set to 8.1).
2. **Compat pass** (`rector-compat.php`, a new config rendered next to
   `rector.php`), run right after the official pass with
   `vendor/bin/rector process <subject> --config rector-compat.php
   --clear-cache [--dry-run]`. It registers only the compat rules, with
   `withRules()`, and loads no set at all (so not `SetList::PHP_POLYFILLS`
   either). Its `withPhpVersion()` only opens `PhpVersionedFilter` for the
   listed rules: it is the highest `provideMinPhpVersion()` among them
   (`PHP_84` for `ExplicitNullableParamTypeRector`). Which rules are listed
   is the AR-03 classification; the classification, not Rector's filter, is
   what keeps the output valid on L. Paths, skips and file extensions are
   the same as in `rector.php`.
3. The compat pass is **not run** when its list is empty (for T-M2-13: when
   L >= 8.4, since the php84 set of the main pass already holds the rule).
   Rector with no rule exits 0 with `[WARNING] Register rules or sets in
   your "rector.php" config` and no `[OK]` line, which `rector_output_ok()`
   reads as a crash.
4. **Skips stay filtered with `class_exists()`**: a skipped rule class that
   does not exist is still fatal on both pins. The compat list is filtered
   the same way: an unknown class in `withRules()` is fatal too. T-M2-14
   adds the three FQCNs below; they exist on both pins.
5. **`--only` is usable** for the AR-11 `rector-rule` engine on both pins,
   with three limits: one rule per run; the rule must be registered in the
   config given (else exit 1, `Rule "..." was not found`); and it is applied
   **after** `PhpVersionedFilter`, so it never revives a filtered rule — a
   registered rule above the config's PHP version gives exit 0 and zero
   changes without any message. The engine runs `--only` against a config
   whose PHP version admits the rule (the compat config, or a per-recipe
   one), and an apply that changes nothing after a dry-run that announced a
   change is an error, as for the other passes.
6. **Polyfills:** no builder method exists on either pin. The only explicit
   API is `RectorConfig::polyfillPackages(array)`, marked `@internal` /
   `@api only for testing`; it works when `rector.php` returns a closure
   that invokes the builder and then calls it. It does not matter for the
   compat pass (no compat candidate implements `RelatedPolyfillInterface`,
   and the pass loads no set). It matters for the main pass only when the
   Drupal root `composer.json` `require` lists a `symfony/polyfill-php8x`:
   then `ForeachToArrayFindRector` emits `array_find()` at L = 8.1. A bed
   built by `ddev-up.sh` lists none, so T-M2-13 does not pin the list; 03-R2
   uses the closure form below (or its scratch-cwd `composer.json`
   fallback).

Both pins behave the same for everything above, so the mechanism does not
depend on the AR-38 pin choice.

### Template snippets (T-M2-13 and T-M2-14)

`templates/rector.php.tmpl` (bump `drupilot-template-version` to 4). New
tokens: `{{PHP_FLOOR}}` (`8.1`), `{{PHP_FLOOR_ID}}` (`PHP_81`) and
`{{PHP_FLOOR_SET}}` (`php81`). `{{PHP_SET}}` (from P) is no longer used here.

```php
use DrupalRector\Set\Drupal10SetList;
use Rector\Config\RectorConfig;
use Rector\ValueObject\PhpVersion;

// Rules skipped on purpose (see the header). String FQCNs + class_exists keep
// this config loadable on any Rector 2.x.
$drupilotRiskySkips = array_values(array_filter([
  'Rector\\Php81\\Rector\\Array_\\ArrayToFirstClassCallableRector',
  'Rector\\Php83\\Rector\\ClassMethod\\AddOverrideAttributeToOverriddenMethodsRector',
  'Rector\\Php81\\Rector\\Property\\ReadOnlyPropertyRector',
  'Rector\\Php82\\Rector\\Class_\\ReadOnlyClassRector',
  'Rector\\Php81\\Rector\\FuncCall\\NullToStrictStringFuncCallArgRector',
  // Never rewrite __sleep/__wakeup (DependencySerializationTrait defines
  // them), never add #[\Override] to properties (H2, 03-R6).
  'Rector\\Php85\\Rector\\Class_\\SleepToSerializeRector',
  'Rector\\Php85\\Rector\\Class_\\WakeupToUnserializeRector',
  'Rector\\Php85\\Rector\\Property\\AddOverrideAttributeToOverriddenPropertiesRector',
], 'class_exists'));
```

and, replacing `->withPhpSets({{PHP_SET}}: true)`:

```php
  // The PHP floor L = {{PHP_FLOOR}} (declared core range + require.php).
  // Rector drops every version-bound rule above L, and the level sets stop
  // at L (H1). Compat fixes for newer PHP run in rector-compat.php.
  ->withPhpVersion(PhpVersion::{{PHP_FLOOR_ID}})
  ->withPhpSets({{PHP_FLOOR_SET}}: true)
```

New `templates/rector-compat.php.tmpl` (rendered to `<root>/rector-compat.php`
only when L < 8.4 in T-M2-13; M5 replaces the literal list and `PHP_84` with
generated tokens):

```php
<?php

/**
 * drupilot — rector-compat.php
 * drupilot-template-version: 1
 *
 * The narrow compat pass (ADR 0002). run-rector.sh runs it right after the
 * official pass:
 *   vendor/bin/rector process {{SUBJECT_PATH}} --config rector-compat.php
 * It registers only PHP deprecation fixes whose output is valid on the PHP
 * floor {{PHP_FLOOR}}, and no set. withPhpVersion() only lets Rector's
 * PhpVersionedFilter keep the listed rules: it is the highest
 * provideMinPhpVersion() among them.
 */

declare(strict_types=1);

use Rector\Config\RectorConfig;
use Rector\ValueObject\PhpVersion;

// The same skip list as rector.php.
$drupilotRiskySkips = array_values(array_filter([
  'Rector\\Php81\\Rector\\Array_\\ArrayToFirstClassCallableRector',
  'Rector\\Php83\\Rector\\ClassMethod\\AddOverrideAttributeToOverriddenMethodsRector',
  'Rector\\Php81\\Rector\\Property\\ReadOnlyPropertyRector',
  'Rector\\Php82\\Rector\\Class_\\ReadOnlyClassRector',
  'Rector\\Php81\\Rector\\FuncCall\\NullToStrictStringFuncCallArgRector',
  'Rector\\Php85\\Rector\\Class_\\SleepToSerializeRector',
  'Rector\\Php85\\Rector\\Class_\\WakeupToUnserializeRector',
  'Rector\\Php85\\Rector\\Property\\AddOverrideAttributeToOverriddenPropertiesRector',
], 'class_exists'));

// Compat rules (AR-03 class apply-compat).
$drupilotCompatRules = array_values(array_filter([
  'Rector\\Php84\\Rector\\Param\\ExplicitNullableParamTypeRector',
], 'class_exists'));

return RectorConfig::configure()
  ->withPaths([
    '{{SUBJECT_PATH}}',
  ])
  ->withSkip(array_merge([
    '*/vendor/*',
    '*/node_modules/*',
  ], $drupilotRiskySkips))
  ->withPhpVersion(PhpVersion::PHP_84)
  ->withRules($drupilotCompatRules)
  ->withFileExtensions([
    'php',
    'module',
    'theme',
    'install',
    'inc',
    'profile',
    'engine',
  ]);
```

The polyfill form for 03-R2 (not part of T-M2-13), verified on the bed:

```php
$drupilotBuilder = RectorConfig::configure()
  // ... the whole main-pass chain ...
  ;
return static function (RectorConfig $rectorConfig) use ($drupilotBuilder): void {
  $drupilotBuilder($rectorConfig);
  $rectorConfig->polyfillPackages([/* the polyfill floor of the range */]);
};
```

## Evidence

Lab: `$LAB/m2/ar40` (`notes.md` has every command; raw output in `logs/`).
Two Composer projects, `rector-2.5.2` (with phpstan/phpstan 2.2.2) and
`rector-2.6.1` (with 2.2.6), installed with `composer:2`
(`sha256:af98f42d…`) and run with `php:8.3-cli` (`sha256:f1ed6d1f…`, PHP
8.3.35):

```bash
tools/run.sh <version> <config> <composer-variant> [rector args]
# = copy configs/<config>.php to rector.php, composer.<variant>.json to
#   composer.json, a fresh fixture/src, then
#   vendor/bin/rector process src --dry-run --clear-cache --output-format=json
tools/two-pass.sh <version> q5-main-L81 q5-compat   # apply both, php -l on 8.1
```

The fixture has one file per construct. Rules and their
`provideMinPhpVersion()` read from the installed source (the same on both
pins): `ExplicitNullableParamTypeRector` returns
`PhpVersionFeature::DEPRECATE_IMPLICIT_NULLABLE_PARAM_TYPE` = `PHP_84`;
`AddTypeToConstRector` `TYPED_CLASS_CONSTANTS` = `PHP_83`;
`NewMethodCallWithoutParenthesesRector` `PHP_84`; `ForeachToArrayFindRector`
`ARRAY_FIND` = `PHP_84` plus polyfill `symfony/polyfill-php84`;
`VariableInStringInterpolationFixerRector` `PHP_82`;
`ShellExecFunctionCallOverBackticksRector` `DEPRECATE_BACKTICKS` = `PHP_85`.

| Config (rules via `withRules` unless noted) | Composer | Fired, 2.5.2 and 2.6.1 |
|---|---|---|
| `withPhpVersion(PHP_81)` + the 6 rules | none | nothing |
| the 6 rules, no version | `php >=8.1` | nothing |
| the 6 rules, no version | none (runtime 8.3) | 8.2 interpolation, 8.3 typed const |
| `PHP_81` + `withPhpSets(php81: true)` + the 6 rules | none | php80/81 set rules only |
| `PHP_81` + `withPhpSets()` + the 6 rules | `php >=8.1` | php80/81 set rules only |
| `PHP_81` + `withPhpSets()` | none | fatal: no composer PHP version |
| `withPhpSets(php81: true)` + the 6 rules, no version | none | set rules + 8.2/8.3 rules |
| `PHP_81` + `withPhpSets(php85: true)`, no rules | none | set rules + `RenameCastRector` + `RenameClassConstFetchRector` (`\Pdo\Mysql`) |
| `PHP_81` + `withPhpSets(php81: true)` | + polyfill-php84 | set rules + `ForeachToArrayFindRector` |
| same, closure + `polyfillPackages([])` | + polyfill-php84 | set rules only |
| `PHP_84` + `withPhpSets(php81: true)` + nullable (one pass at P) | none | set rules + nullable + `ForeachToArrayFindRector` |
| `PHP_84` + nullable only (compat pass) | none / + polyfill | nullable only |
| `PHP_81` + 6 rules, `--only=ExplicitNullableParamTypeRector` | none | nothing, exit 0 |
| `withSkip` of a class that does not exist (value or key) | none | exit 1, "These rules from ... skip() do not exist" |
| `withRules([])` / `withRules([missing])` | none | exit 0 + "Register rules or sets", no `[OK]` / exit 1 |

"Set rules" means `StrContainsRector` and `FunctionFirstClassCallableRector`;
2.5.2's php81 set also has `NullToStrictStringFuncCallArgRector`, which
2.6.1's no longer lists (the class still exists). `--only` takes a FQCN or a
unique short name on both pins (`process --help`: `--only=ONLY  Fully
qualified rule class name`). Two-pass apply: `?Foo $x = NULL` and
`?string $s = NULL`, every construct above 8.1 untouched, `php -l` clean on
PHP 8.1.34.

Source read in `vendor/rector/rector` at both pins:
`src/VersionBonding/PhpVersionedFilter.php` (identical);
`src/PhpParser/NodeTraverser/RectorNodeTraverser.php::prepareNodeVisitors()`
filters every registered rule — sets, `withRules`, configured rules — by PHP
version, then composer constraints, then `--only`;
`src/Php/PhpVersionProvider.php`; `src/Php/PolyfillPackagesProvider.php`
(cwd `composer.json` `require` only);
`src/Configuration/RectorConfigBuilder.php` (no polyfill method;
`withPhpSets()` sets no PHP version);
`src/Config/RectorConfig.php::polyfillPackages()`;
`src/Configuration/OnlyRuleResolver.php`;
`src/Validation/RectorConfigValidator.php::ensureRectorRulesExist()`. A
reflection of the php80..php86 and php-polyfills sets
(`tools/rule-audit.php`, `logs/rule-audit-*.tsv`) shows that the php85 set
registers seven configured rules without `MinPhpVersionInterface`.
Versions from repo.packagist.org/p2: rector/rector 2.5.2 (2026-06-22,
`phpstan/phpstan ^2.2.2`) and 2.6.1 (2026-08-03, `^2.2.6`);
palantirnet/drupal-rector 1.1.3 (`rector/rector ^2`, conflict `>=2.6.2`).

Real Drupal context, DDEV bed `dpl-m2-rcompat-d11` (deleted afterwards):

```bash
DRUPILOT_PHP_TARGET=8.3 bash $CLAUDE_PLUGIN_ROOT/scripts/env/ddev-up.sh \
  --name dpl-m2-rcompat-d11 --dir $LAB/m2/ar40/dpl-m2-rcompat-d11 --json
ddev composer require --dev -W palantirnet/drupal-rector:1.1.3 \
  rector/rector:2.5.2 phpstan/phpstan:2.2.2      # later 2.6.1 + 2.2.6
# tests/fixtures/legacy_widgets + src/Ar40Compat.php -> web/modules/custom/
DRUPILOT_PHP_TARGET=8.3 bash $CLAUDE_PLUGIN_ROOT/scripts/env/render-templates.sh \
  --subject .../web/modules/custom/legacy_widgets --only rector --force --json
ddev exec vendor/bin/rector process web/modules/custom/legacy_widgets --clear-cache
ddev exec vendor/bin/rector process web/modules/custom/legacy_widgets \
  --config rector-compat.php --clear-cache
```

Drupal 11.4.8, PHP 8.3, DDEV 1.25.4, L = 8.1 (`^10.3 || ^11`, fixture
`require.php >=8.1`). The template as rendered today (v3) applied
`AddTypeToConstRector` (a typed constant is a parse error on 8.1) and the 8.2
interpolation rule to the extra file. With the snippets above (hand-edited
into the bed copy only), on both pins: the main pass changed only
`array_map('trim', ...)` -> `array_map(trim(...), ...)` (8.1, in
`WidgetImportForm.php`); the compat pass changed only the two implicit
nullables; the typed constant, `"${var}"`, `(new X())->y()` and the foreach
stayed; `php -l` on PHP 8.1 was clean. drupal-rector 1.1.3 has three
version-bound rules (`AnnotationToAttributeRector` and two PHPUnit
attribute rules), all `PHP_81`, so L >= 8.1 keeps them.

## Consequences

- **T-M2-13** renders both files and bumps the template marker. Its
  test-first golden asserts that `rector.php` contains
  `withPhpVersion(PhpVersion::PHP_81)` and `withPhpSets(php81: true)` and
  that `rector-compat.php` lists `ExplicitNullableParamTypeRector` with
  `withPhpVersion(PhpVersion::PHP_84)` (for `^10.3 || ^11`).
  `render-templates.sh` gains a `rector-compat` target; `run-rector.sh`
  gains the compat pass between the official and digests passes, with its
  own dry-run record and its own `rule_hits` key, and the same marker-based
  regeneration as
  `rector.php`. For `^11` with P = 8.4 the main sets drop from php84 to
  php83, and the compat pass keeps the implicit-nullable fix.
- **Which PHP admits a compat rule** (decided here, R-AUTO-3): AR-03 makes a
  rule compat when `deprecated_in <= P`. The code must run on every PHP of
  the window W = [L..ceiling], where the ceiling is the highest PHP some core
  minor of the declared range supports (`php_bounds_for_range` in
  `scripts/lib/plan.sh`: `^10.3 || ^11` gives 8.1..8.5), not only on the
  test-bed's P. The condition is therefore `deprecated_in <= max(P,
  ceiling)` (02 §A1), with `output_min_php <= L` and `drupal_safe`
  unchanged. With the default P = 8.3 it admits
  `ExplicitNullableParamTypeRector` for `^10.3 || ^11`, which is what L-M2-3
  expects; T-M2-13 renders the compat config whenever the list is not empty.
  M5 follows the same bound U = max(P, ceiling): T-M5-02's
  `php_rule_class` classifies against U (not P), and T-M5-03 audits the
  Rector PHP sets up to U.
- **T-M2-14** adds the three skips. The `run-rector.sh` parser fix lands
  earlier, with the toolchain switch of T-M2-10 (ADR 0001), so that neither
  the skips nor the compat pass (whose config carries the same skip list)
  are misread: `run-rector.sh` (l.526-541) must stop reading the
  ` * <FQCN>` lines of Rector's
  `[WARNING] These skipped rules are never registered` block as applied
  rules: on the bed it reported `ReadOnlyClassRector`,
  `SleepToSerializeRector`, `WakeupToUnserializeRector` and
  `AddOverrideAttributeToOverriddenPropertiesRector` as applied, and
  `rule_hits` feeds the port manifest. Read the rules from
  `--output-format=json` (`applied_rectors`), or only inside "Applied
  rules:" blocks. The same misreading already happens on 2.6.1 with the v3
  template: Rector prints `[WARNING] This skipped rule is never registered`
  for `NullToStrictStringFuncCallArgRector`, which 2.6.1's php81 set no
  longer lists (`logs/v3-like-never-registered.txt`).
- **M5 (php stage):** the compat list comes from `rector-rule-audit`.
  Configured rules such as `RenameCastRector` (`(integer)` -> `(int)`,
  valid on every PHP) are not version-bound and go into the compat config
  with `withConfiguredRule()`; `\PDO::MYSQL_ATTR_*` stays report-only below
  8.4.
- **AR-11:** the `rector-rule` engine may use `--only` under the limits in
  Decision 5.
- **03-R2:** use `polyfillPackages()` through the closure, and make the
  toolchain smoke test cover it, because the method is `@internal`.
- **Recheck** when the Rector pin moves: rerun `tools/run.sh` on the q1, q3,
  q4 and q5 configs and diff `PhpVersionedFilter.php`, the
  `prepareNodeVisitors()` order and
  `RectorConfigValidator::ensureRectorRulesExist()`.
