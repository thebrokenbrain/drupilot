---
name: php-target-tuning
description: >-
  Use this skill whenever a PHP version target matters for the port — i.e.
  deciding or changing DRUPILOT_PHP_TARGET, and translating it into the
  PHPStan level/expectations, the PHPCS sniffs, the DDEV php_version and the
  ceiling of Rector's PHP floor. It is the single source of truth for how one variable
  (DRUPILOT_PHP_TARGET, default 8.3) flows through the whole toolchain, and for
  the PHP 8.5 caveat (8.5 needs Drupal 11.3 or later, and no Rector php85 set is
  assumed — check the core minor, never hardcode). Invoke it from /drupilot-setup,
  /drupilot-assess, /drupilot-port and /drupilot-refactor before configuring any
  tool, and whenever the user asks to target a specific PHP version.
allowed-tools: Bash, Read, Edit
---

# PHP target tuning

The PHP target P (`DRUPILOT_PHP_TARGET`) is the one knob behind every
PHP-version-dependent setting. The upgrade plan turns it into the **PHP window**:
every PHP from the floor L to P that the ported code must run on. This skill
reads the window from the plan and never restates a version itself: every
version below comes from the plan block or from the version data
(`config/targets/<major>.json`, `config/php/*.json`).

**The upgrade plan.** Every version this procedure needs (target major, test-bed
core, declared range, PHP floor and target, Rector sets, names) comes from it,
never from the examples below (AR-26). The block is the working directory's: when it
names no module, or a module other than the subject, run `plan show --subject <subject_dir>`:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/drupilot.sh" plan show 2>/dev/null || true`

If no "drupilot plan" block appears above, run: bash "${CLAUDE_PLUGIN_ROOT}/scripts/drupilot.sh" plan show

## 1. Read the window from the plan

The plan's `php` block holds:

| Field | What it is |
|---|---|
| `floor` (L) | the lowest PHP the declared core range admits, raised to what the code needs (see 5) |
| `final` (P) | the PHP target |
| `window` | every PHP minor from L to P |
| `require_php` | the composer `require.php` the port declares (`>=L` when the range keeps a previous major, else none) |
| `phpstan_phpversion` | PHPStan's `phpVersion {min, max}`, the window as `PHP_VERSION_ID`s |
| `phpcompat_testversion` | `L-P`, a record only: `run-phpcompat.sh` checks L to the window's top U (`plan_php_top`, ADR 0003) |

A plan that is not frozen yet is a draft: `/drupilot-setup` resolves it, and
`upgrade-path.sh --subject <path> --phase draft --root <drupal_root> --json`
shows it without freezing.

## 2. Resolve and check the target

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/detect-php.sh" --json
# -> {host_php, ddev_php, target, supported, unconfirmed}
```

The shell helpers (from `scripts/lib/common.sh`) answer the rest:

- `resolve_php_target`: P (the environment wins over `.drupilot.json` and the
  defaults); `resolve_php_target_for T`: the default of target major T
  (`php_defaults` in `config/targets/<T>.json`).
- `php_supported_for MINOR VER`: `yes`, `no` or `unknown` for a core minor,
  from drupal.org's PHP requirements as the version data records them. An
  unlisted minor is `unknown`: never assume it.
- `target_get T '.minors["<minor>"].php_supported'`: the whole list of a minor.
- `php_target_unconfirmed VER`: true for a PHP whose Rector level set is not
  assumed (`rector_php_set_arg` then falls back to the highest confirmed set,
  with a warning).

**The PHP 8.5 caveat.** Drupal supports PHP 8.5 only from the core minor whose
`php_supported` lists it: check with `php_supported_for`, never from memory. When
the target is 8.5, say so: `ddev-up.sh` warns when the pinned or installed core is
older, and no Rector `php85` set is assumed. Never emit a set or image the data
does not confirm; detect it at runtime and degrade.

## 3. How the window flows into each tool

### Rector — the floor, not the target (`rector.php`, ADR 0002, ADR 0019)

The ported code must keep running on L, so the main pass targets L:
`->withPhpVersion(PhpVersion::PHP_<L>)` and `->withPhpSets(php<L>: true)`
(`rector_floor_tokens`). Rector drops every version-bound rule above L, and the
level sets stop there. A deprecation fix whose output still runs on L (the
implicitly nullable parameter, `"${var}"`, backticks, ...) runs in a second,
narrow pass, `rector-compat.php`, when the plan's `rector.compat_rules`,
checked against the installed Rector's rule audit
(`scripts/analysis/rector-rule-audit.sh`, `rector_compat_list`, ADR 0030), is
not empty (`rector_compat_needed`). The polyfills every core of the range ships
(the plan's `rector.polyfills`) are handed to the main pass, so its polyfill
rules never follow the test-bed's `composer.json`. The rules that
would break Drupal (the `deny` rows of `config/php/rules.json`: first-class
callables in Form API callbacks, `readonly`, `#[\Override]` while the range spans
a previous major, `__sleep` → `__serialize`) are skipped by the template. The
Drupal sets come from the plan's `rector` block. Render the configs only through
`scripts/env/render-templates.sh` (or let `run-rector.sh` do it): an untouched
render follows the plan, a hand-edited one is kept with a warning.

### PHPStan — `phpstan.neon` (ADR 0020)

The template renders `phpVersion: {min, max}` from `php.phpstan_phpversion`, so
PHPStan judges the code for every PHP of the window. The level is
`DRUPILOT_PHPSTAN_LEVEL` in Phase 1 and `DRUPILOT_PHPSTAN_LEVEL_REFACTOR` in Phase
2 (the refactor profile).

### PHPCS — `testVersion`

`run-phpcs.sh` passes `--runtime-set testVersion <P>-` (override with
`DRUPILOT_PHPCS_TEST_VERSION`), which only matters to a ruleset that references
PHPCompatibility; a ruleset's own `<config name="testVersion">` is never
overridden. The subject's own ruleset wins when it loads
(`DRUPILOT_PHPCS_RULESET=auto`).

### DDEV — `php_version`

`ddev-up.sh` configures the test-bed with `--php-version=$(resolve_php_target)`:
the test suite runs on P. A reconfigure needs `ddev restart`.

## 4. The php stage: the whole window, checked

The pipeline's `php` stage (`docs/concepts/php-and-core-target.md`) checks every
PHP of the window, not only the test-bed's:

- `scripts/analysis/php-target.sh` finds, in the code only (comments and
  strings blanked), the constructs of `config/php/rules.json` a PHP of the window
  removed or deprecated (`removed-blocking`, `report-only`);
- `scripts/analysis/php-lint-window.sh` runs `php -l` on each PHP of the window,
  in throwaway `php:X.Y-cli` containers (skipped without Docker);
- `scripts/analysis/run-phpcompat.sh` runs PHPCompatibility (an alpha, from its
  own Composer tree in the test-bed, ADR 0003) with `testVersion` L-U and the
  polyfill rulesets of the range; a `config/php/rules.json` row covers some of
  its findings, the rest never block, and when it degrades the heuristic floor
  scan stands in;
- they become `human` worklist items: `removed-in-target-php` and
  `does-not-compile` block (and a file the floor's PHP does not compile), while
  `fix-needs-php-above-floor`, `deprecated-no-rule` and PHPCompatibility's
  findings (`deprecated-in-php-window` among them) are reported.
  `port-summary.sh --strict` exits 3 while a blocking one is open.

Never rewrite a removed construct on your own: tell the developer, who fixes it
or raises the floor.

## 5. The floor: what the code needs

`scripts/analysis/detect-php-floor.sh` is a heuristic scan of the code for
constructs newer than the floor. For syntax the `php -l` legs are authoritative;
a function missing on the floor is caught only by this scan and by the test suite
on the floor's PHP (the `PHP_LOW` leg). `DRUPILOT_REQUIRE_PHP_FLOOR` decides how it
is used: `detect` (default) widens `require.php` down to what the code needs
when the port keeps a previous major; `target` keeps it at P.

**Polyfills (ADR 0029).** A function a newer PHP adds does not raise the floor
when every core the range admits ships the `symfony/polyfill-phpXY` package that
defines it: `core_range_polyfills '<range>'` lists those packages and functions,
and `detect-php-floor.sh --subject <path> --range '<range>' --json` marks such a
signal `polyfilled`. A range that still admits a core without the polyfill (a
previous major, an early minor) gets none: the floor rises, which is right.

**Target compatibility.** `target_compatible` is false when the code uses a
construct newer than P and no polyfill of the declared range provides it: it
fatals on the test-bed. Raise P or remove the construct. `core-strategy.sh` and
the plan both judge it with the range's polyfills.

## 6. Changing the target

The setup froze P in the plan; the port never changes it (`/drupilot-port --php
X.Y` checks X.Y against the plan's `php.final` and stops on a mismatch). To
retarget, re-plan: `/drupilot-setup <path> --php X.Y` (or `upgrade-path.sh
--phase draft --freeze` with `DRUPILOT_PHP_TARGET=X.Y` exported). The templates
follow the frozen plan (`render-templates.sh --root <drupal_root>
--subject-path <path> --force` re-renders untouched copies), and DDEV needs
`ddev config --php-version=X.Y` then `ddev restart`. Keep the four in lockstep:
a mismatch between Rector's floor, PHPStan's window, PHPCS and the runtime gives
inconsistent findings.

## Gotchas

- **One PHP level set per run.** The main pass uses the floor's set only.
- **Never hardcode a PHP version** in a prompt, a config or a report: read the
  plan, `php_supported_for`, `php_target_unconfirmed` and the version data.
- An exported `DRUPILOT_PHP_TARGET` always wins over `.drupilot.json` and the
  defaults: check the environment when a target seems wrong.
