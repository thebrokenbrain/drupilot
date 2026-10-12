# PHP and the core target

!!! note "Summary"
    The core range a port declares decides the PHP versions the code must
    run on: the **PHP window**. drupilot checks every PHP of that window, not
    only the one in the test-bed. A construct that PHP removed becomes a
    blocking item for you to fix, and one that is only deprecated is
    reported. Neither is ever dropped silently.

## The window

The [upgrade plan](upgrade-paths.md) gives the window as two bounds:

- **the floor L**: the lowest PHP the declared core range admits, raised to
  what the code itself needs (for `^10.3 || ^11`, 8.1);
- **the target P**: the PHP you port to, set by `DRUPILOT_PHP_TARGET` or the
  setup's PHP tab.

The window is every PHP minor from L to P. The plan records it as
`php.floor`, `php.final` and `php.window`, and every check below reads it from
there.

## Each PHP rule in one class

The PHP changes drupilot knows are the rows of `config/php/rules.json`, each
with the PHP that deprecated it, the PHP that removed it, and the Rector rule
that fixes it when there is one. For a window [L..P], each row lands in
exactly one class, in this order:

| Class | When | What happens |
|---|---|---|
| `deny` | A rule that would break Drupal | Rector never runs it (the `withSkip()` of `rector.php`) |
| `removed-blocking` | Removed at or below P, and no safe fix runs on L | A blocking item for a person |
| `apply-modernize` | A modernizing rule whose PHP is at or below L | Rector's PHP level set at L |
| `apply-compat` | Deprecated or removed at or below P, its fix is safe for Drupal and runs on L | The Rector compat pass (ADR 0002) |
| `report-only` | Deprecated at or below P, but its fix needs a PHP above L or no rule makes it | Reported for a person |
| `not-applicable` | Deprecated and removed above P | Nothing |

`php_rule_class` in `scripts/lib/plan.sh` computes the class. The same row can
change class with the window: the `(integer)` cast, deprecated in PHP 8.5, is
`not-applicable` up to 8.4 and `report-only` from 8.5 on.

## The php stage

The `php` stage of [the pipeline](pipeline.md) runs on every plan, a module
already on the target major included. It extracts again, with two
PHP-window tools besides the analyzers:

- **The construct scan** (`scripts/analysis/php-target.sh`). It searches the
  module's PHP files for the `removed-blocking` and `report-only` constructs
  that no Rector rule fixes: `each()`, `create_function()`, the `mysql_*` and
  `ereg*` functions, the old cast names, the `PDO::MYSQL_ATTR_*` constants,
  `strftime()`, and the others the data lists with a pattern. Comment lines
  and `vendor/` are left out.
- **`php -l` on each PHP of the window** (`scripts/analysis/php-lint-window.sh`).
  Each minor runs in a throwaway official `php:X.Y-cli` container. The module
  is streamed in with no network and no bind mount. A file one of those PHPs
  does not compile fails that leg. The compiler's deprecations are reported,
  such as an implicitly nullable parameter from PHP 8.4. Without a Docker
  daemon the legs are skipped, and the report says so.

Their findings reach the [worklist](../reference/state.md#worklist) as
`human` items, each with a reason:

| Reason | Found by | Blocks |
|---|---|---|
| `removed-in-target-php` | the scan (a removed construct), or a leg that fails only on the higher PHP | yes |
| `does-not-compile` | no PHP of the window compiles the file | yes |
| `fix-needs-php-above-floor` | the scan (a deprecated construct whose fix needs a PHP above L) | no |
| `deprecated-no-rule` | the scan (a deprecated construct whose fix runs on L, but no Rector rule makes it) | no |
| `fix-needs-php-above-floor` | a leg that fails on the floor while a higher PHP compiles it | yes |

The stage fails when a PHP-window finding is in no worklist item: nothing is
dropped silently.

## Where you see them

- **The port report** (`port-report.md`) has a **PHP window** section: the
  bounds, the result of each `php -l` leg, the compile-time deprecations and
  the items left for a person.
- **`port-summary.sh --strict`** exits 3 while an open blocking item of the
  window remains, with a `php-target` blocker. This applies only once the
  module is ported and while the worklist describes the current sources.
- **The issue text** (`make-issue.sh`) lists each open item as a remaining
  task.

## Not yet in this pre-release

These arrive in a later 1.0 pre-release:

- the PHPCompatibility check (ADR 0003);
- the test run on the floor PHP (the `PHP_LOW` leg);
- the `--php` flag of the commands;
- the audit of Rector's PHP rules (which fills `apply-modernize`);
- the polyfills core ships (a PHP 8.4 function such as `array_find()` on a
  lower floor).
