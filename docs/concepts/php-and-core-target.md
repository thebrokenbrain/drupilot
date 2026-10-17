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
  what the code itself needs (for `^10.3 || ^11`, 8.1; see
  [Polyfills](#polyfills));
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
| `apply-compat` | Deprecated or removed at or below P, and its fix is safe for Drupal and runs on L | Rector: the level set at L, or else the compat pass (see [The compat pass](#the-compat-pass)) |
| `report-only` | Deprecated at or below P, but its fix needs a PHP above L or is not safe for Drupal | Reported for a person |
| `not-applicable` | Deprecated and removed above P | Nothing |

`php_rule_class` in `scripts/lib/plan.sh` computes the class. The same row can
change class with the window: the `(integer)` cast, deprecated in PHP 8.5, is
`not-applicable` up to 8.4 and `report-only` from 8.5 on.

## The compat pass

Rector's main pass stops at the floor L, so a deprecation fix for a newer PHP
of the window runs in a second, narrow pass, `rector-compat.php`, right after
it ([ADR 0002](../contributing/adr/0002-rector-compat-pass.md),
[ADR 0030](../contributing/adr/0030-rule-audit-and-generated-compat-pass.md)).
It runs only the fixes whose output still runs on L, such as an implicitly
nullable parameter `Foo $x = NULL` becoming `?Foo $x = NULL`. Its rules come
from two sides:

- **The plan** (`rector.compat_rules`) lists the compat rows of
  `config/php/rules.json` that are safe for Drupal, deprecated up to the top of
  the window, and above the floor's level set. The top of the window is the
  higher of P and the highest PHP a core of your range supports, because the
  module must run on every one of them.
- **The rule audit** (`scripts/analysis/rector-rule-audit.sh`) reflects the
  PHP sets of the Rector installed in the test-bed. It is run once per Rector
  version and kept in the lock. It drops the rules that Rector does not have and
  the rules its floor level set already runs. It also sets the PHP version the
  pass declares, so that Rector keeps every listed rule.

A row the audit finds unsafe stays out: `ord($s)` → `ord($s[0])` warns on an
empty string, so it is reported and never applied. Rules that would break Drupal
(`deny`) are skipped by both passes.

## The php stage

The `php` stage of [the pipeline](pipeline.md) runs on every plan, a module
already on the target major included. It extracts again, with two
PHP-window tools besides the analyzers:

- **The construct scan** (`scripts/analysis/php-target.sh`). It searches the
  module's PHP files for the `removed-blocking` and `report-only` constructs
  still in the code: `each()`, `create_function()`, the `mysql_*` and `ereg*`
  functions, the old cast names, the `PDO::MYSQL_ATTR_*` constants,
  `strftime()`, and the others the data has a pattern for. Rector's level
  sets rewrite some forms of a few of them during `upgrade`; whatever is left
  is reported here. Only the code is searched: comments, the contents of
  strings, heredocs and inline HTML are blanked first, and `vendor/` is left
  out. The rules of those classes without a pattern are listed as not
  searched in the report.
- **`php -l` on each PHP of the window** (`scripts/analysis/php-lint-window.sh`).
  Each minor runs in a throwaway official `php:X.Y-cli` container. The module
  is streamed in with no network and no bind mount. A file one of those PHPs
  does not compile fails that leg. The compiler's deprecations are reported,
  such as an implicitly nullable parameter from PHP 8.4. Without a Docker
  daemon the legs are skipped, and the report says so; a stage whose legs did
  not all run is run again next time.

Their findings reach the [worklist](../reference/state.md#worklist) as
`human` items, each with a reason:

| Reason | Found by | Blocks |
|---|---|---|
| `removed-in-target-php` | the scan (a removed construct), or a leg that fails only on the higher PHP | yes |
| `does-not-compile` | no PHP of the window that ran compiles the file | yes |
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
  module is ported, and only while the item's file is still the one it was
  found in: an edited file is reported with a warning until the `php` stage
  runs again.
- **The issue text** (`make-issue.sh`) lists each open item as a remaining
  task, and marks one whose file changed since for a re-check.

## Polyfills

A function a newer PHP adds, such as `array_find()` (PHP 8.4), does not make
your module need that PHP when every Drupal core it declares ships a
`symfony/polyfill-phpXY` package that defines it. drupilot keeps that as
version data ([ADR 0029](../contributing/adr/0029-core-polyfills-as-version-data.md)):

- which polyfills every release of a core minor requires;
- which functions each polyfill defines on every PHP, leaving out those that
  need an extension core does not require, such as `mb_trim()` (ext-mbstring).

The floor counts a function as available only when every core minor of the
declared range provides it: Drupal 11.2 and later ship `polyfill-php84`, but no
Drupal 10 minor does. So `array_find()` raises the floor to 8.4 for
`^10.3 || ^11`, and not for `^11.2`. Rector's main pass gets the same list
(`rector.polyfills`, through `polyfillPackages()`): its polyfill rules, such as
a `foreach` becoming `array_find()`, run below their PHP only for those
packages, never because of what the test-bed's `composer.json` lists. The one
that turns `@deprecated` into `#[\Deprecated]` is skipped: from PHP 8.4 it
makes every call emit a deprecation on top of Drupal's own. The heuristic scan that finds such
constructs, `detect-php-floor.sh`, also knows the PHP 8.5 additions (the pipe
operator, the `(void)` cast, `array_first()`), searched in the code only. For
syntax, the `php -l` legs are the real check. A function missing on the floor is
caught only by this scan and by your tests run on the floor's PHP.

## Tests on the floor's PHP

Your test suite runs on the test-bed's PHP. When the window starts lower (the
plan's `PHP_LOW` leg: the lowest PHP of the window the test-bed's core supports),
`/drupilot-test` runs the Unit and Kernel groups again on that PHP, with the PHP
binary the DDEV container already has. A failure there means the port breaks on
the PHP it declares: it is compared with the pre-port baseline like any other
failure, and the suite is never green while it lasts. Functional tests are not part of
that leg: their site is served by the test-bed's own PHP. A previous major (a
kept Drupal 10) is checked statically by the core matrix.

## Choosing the PHP target

`/drupilot-setup` asks for the PHP target, or takes it from `--php X.Y`, and
freezes it in the plan. `/drupilot-port` accepts `--php X.Y` too, but only to
check it against the frozen plan: the port never changes the PHP target, and a
different one (or no frozen plan) stops it and sends you back to the setup to
re-plan.

## Not yet in this pre-release

These arrive in a later 1.0 pre-release:

- the PHPCompatibility check (ADR 0003).
