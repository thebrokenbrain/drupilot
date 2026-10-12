# 0029 — Core polyfills are version data

- **Status:** accepted
- **Date:** 2026-10-12
- **Decided by:** the 1.0 working session (R-AUTO-3), during M5 (T-M5-08, T-M5-04)

## Context

A function a newer PHP adds (`array_find()` in 8.4) does not make a module need that PHP when every Drupal core
the module declares ships a `symfony/polyfill-phpXY` package defining it. Two consumers need to know which
polyfills a declared core range guarantees:

- `detect-php-floor.sh`, whose floor feeds the plan's PHP floor L;
- the Rector main pass (03-R2, ADR 0002 Decision 6), which should be given the list explicitly.

The plan's 03-R2 says to read the `core/composer.json` of each reference core **at runtime** and cache it,
"never a table". But AR-06 and ADR 0017/0018 make the upgrade plan a pure function of the version data:
the same data gives the same plan. A runtime read would put the network, and what happens to be in a cache,
into the plan. The reference cores also exist only after `verify-core-matrix.sh` has built them.

The facts were read on 2026-10-12 from Packagist's `drupal/core` metadata, expanded from its minified p2
form:
- no 10.x minor, and neither 11.0 nor 11.1, requires a PHP polyfill directly;
- every 11.2 release requires `symfony/polyfill-php84`, every 11.3 release `-php84` and `-php85`, and every
  11.4 release those two and `-php86`;
- the 12.0 pre-releases require only `-php86`, because they need PHP 8.5, where the 8.4 and 8.5 functions
  are native.

The plan's own fact F-D5 placed `polyfill-php84` at 11.3; Packagist shows it in every 11.2 release.

## Decision

**The polyfills are version data, derived, sourced and refreshed like the other generated fields.**

- `config/targets/<major>.json` `minors[].polyfills` lists the `symfony/polyfill-phpXY` packages that
  **every** tag of the minor requires directly. `scripts/dev/refresh-data.sh` derives it from the Packagist
  metadata it already reads: a pre-release major's alpha, beta and rc tags count, a supported major's do
  not. A transitive requirement is not counted, because a dependency may drop it.
- `config/php/polyfills.json` lists, for each package, the functions its `bootstrap.php` defines
  unconditionally, at the lowest version a core release requires. That is `^1.32` for `-php84` and `-php85`,
  and `^1.37` for `-php86`. A function defined only when an extension core does not require is loaded is
  listed as conditional and never counted on: `mb_trim()` needs `ext-mbstring`. (`-php86` defines
  `grapheme_strrev()` on PHP 8 only from 1.43.0, with `ext-intl`: not at the 1.37.0 core requires.)
- `core_range_polyfills C` (`scripts/lib/plan.sh`) intersects, over every verified minor C admits, the
  packages the minor **provides**: those it requires, plus those whose PHP is at or below the minor's own
  minimum PHP (native there). A verified minor without the data provides none, and a major C reaches
  with no data file at all (Drupal 9) makes the intersection empty: the conservative answer. A minor not
  released yet (an unverified `detect` entry) is left out: a later release of a major only adds
  polyfills or raises its minimum PHP.
- `detect-php-floor.sh --range C` keeps the signal of a polyfilled function, marked `polyfilled: true`, but
  it does not raise the floor. `upgrade-path.sh` computes L with the range it decided. Its strategy decision
  still uses the plain floor.
- 03-R2's runtime read is not implemented. The data is refreshed by a developer and checked by the `data`
  gate: every package a minor names must be described in `php/polyfills.json`.

## Consequences

- `^10.3 || ^11` gets no polyfill: `array_find()` still raises L to 8.4, which is right, since Drupal 10.3
  on PHP 8.1 has no `array_find()`.
- `^11.2` and above keep L at 8.3 for those functions.
- The Rector main pass gets the same list through `polyfillPackages()` (03-R2) when the compat-list
  generation lands (T-M5-03, T-M5-04).
- A new core minor's polyfills arrive with the next `refresh-data.sh` run. Until then the minor is a
  `detect` entry, which the intersection leaves out.
