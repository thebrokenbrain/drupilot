# 0017 — What the upgrade-plan resolver decides where AR-04/AR-06 are silent

- **Status:** accepted
- **Date:** 2026-10-05
- **Decided by:** the 1.0 working session (R-AUTO-3), during M3 (T-M3-01, T-M3-03)

## Context

AR-04 and AR-06 define the upgrade plan: the hops from the source era S to
the target major T, their Rector sets, the PHP window W = [L..P], the test
legs and the assertions a plan must pass. Several questions are left open:
which keep-previous range is the default, when backwards-compatible Rector
rewrites are on, which sets a hop brings when the data or the test-bed does
not know a family, what "every minor in C" covers, how an unknown answer
counts, how a refusal looks and what a field nobody computes yet holds.
The building blocks live in `scripts/lib/plan.sh`; `scripts/analysis/upgrade-path.sh`
assembles them.

## Decision

1. **The keep-previous default range is the data's.** For T = 11 it is
   `targets/11.json .default_ranges["keep-previous"]`, `^10 || ^11`: the
   0.9 range (H10, CC-11), not AR-06's `^10.3 || ^11` example. T's
   `upgrade_from_min` (11.3 for 12) constrains a site's update, not a
   module, and is already the floor of T = 12's default range
   (`^11.3 || ^12`).
2. **Backwards-compatible rewrites** (`rector.bc`) are on when the range
   admits more than one minor and the lowest core it admits is at least
   10.1.3, where `DeprecationHelper` first exists (03-F-D6): `^10.1.3 || ^11`
   qualifies, `^10.1 || ^11` does not. `min_core` is then F. Below 10.1.3
   they are off. M3 neither raises F nor refuses for it, so `^10 || ^11`
   keeps its 0.9 result; M6 (T-M6-06) revisits it.
3. **A hop brings its edge's set family, per minor, never T's own sets.**
   `rector_sets_for_plan` takes each rector edge's `set_family` (the 10-11
   hop brings `Drupal10SetList`, not `Drupal11SetList`), per minor
   (`DRUPAL_100`, never the `DRUPAL_10` aggregate), up to the bed core's
   minor (12.0.0-beta1 counts as 12.0). T's own sets would rewrite to APIs
   the kept previous major lacks.
4. **Where the constants come from.** With a test-bed holding drupal-rector,
   from its `src/Set/<Family>.php` (static reading, no PHP); else from the
   verified `targets/<N>.json .rector_sets`; else the family is recorded in
   `sets_skipped` with reason `no-fallback-data` (Drupal8SetList and
   Drupal9SetList before a bed exists). A family the bed's drupal-rector
   lacks is `missing-family`; an `always_sets` entry it does not declare is
   `missing-constant`. A skipped set is visible, never silently dropped.
5. **Breaking sets** (`DRUPAL_<N><m>_BREAKING`) apply only on an edge that
   declares `breaking_sets`: for m ≤ F's minor when F's major is N, and all
   of them up to the bed when F's major is above N (no N.x core is kept, so
   none of them can break a supported core).
6. **A range is read as composer/semver reads it** (Drupal checks
   `core_version_requirement` with `Semver::satisfies`): a bare `11` is the
   single release 11.0.0, `11.x` the whole major, `!=`/`<>` exclude one
   release, a stability flag or a pre-release suffix is dropped, and
   `11.x-dev` (the development branch) admits no release.
   `tests/unit/core_requirement_minors.sh` pins the minors and the lowest
   version of 43 constraints against composer/semver's answers.
   **"Every minor in C" means every verified minor of a major ≤ T that C
   admits.** A minor whose PHP list is unknown, or that is not verified, is
   not checked, and a major above T (a kept `^12` on a T = 11 port) stays
   declared-not-verified. `minor-php-disjoint` fires only when every PHP of
   W answers "no" for that minor (`php_supported_for`); an "unknown" answer
   is never a violation. A "no" may come from a PHP's verified
   `drupal_core_floor` (PHP 8.5 needs 11.3), so a W of {8.5} on
   `^10.3 || ^11` lists 10.3 to 11.2, not only the minors with a table row.
7. **The plan's L is not clamped.** L is the highest of the kept minor's
   `php_min`, the detected PHP floor and the subject's `require.php` floor
   (L = P with `DRUPILOT_REQUIRE_PHP_FLOOR=target`). L above P is the
   `floor-above-final` refusal; core-strategy, a view, keeps its 0.9 clamp
   and warning.
8. **Assertions are listed in a fixed order and never fixed silently:**
   `source-above-target`, `prerelease-not-opted-in`, `floor-above-final`,
   `php-not-supported` (P against M, the newest released minor, or the
   pre-release minor in preview), `minor-php-disjoint`, `three-majors` (the
   range reaches three majors while it is neither explicit nor a kept
   declaration). `floor-below-api` is the attribute floor `strategy_decide`
   already raises in M3; M6 extends it. A refusal exits 2 with
   `{schema_version, status: "refused", phase, code, message, violations[],
   choices[{id, label, tab, set}]}` on stdout; `code` is the first
   violation.
9. **Deferred fields are null.** Every key of the plan is always present:
   null means a later milestone computes it (`rector.compat_rules`,
   `polyfills`, `tests_pass`, `core_removals`, `hard_breaks`,
   `automation_estimate`), `[]` means computed and empty.
10. **The test matrix and the CI flags are computed in M3** (a pure
    formula; M5 runs the legs). Every leg carries `mode`. CURRENT and
    PHP_LOW name the bed's exact core; PREVIOUS_MAJOR names the newest
    released verified minor of T-1 the range admits, at the higher of L and
    that minor's `php_min`. `OPT_IN_TEST_MAX_PHP` is keyed to the bed core's
    minor, as AR-06 says (PHP_LOW is computed against the bed too), not to
    M: they differ when the lock pins an older bed.
11. **The bed core** is the lock's core when it is a version of T (a leading
    `v` dropped), else the data's latest release of M.
12. **The 7 → 12 route is allowed.** `paths/graph.json` lists it as
    forbidden as a direct edge only; `plan_hops` walks `7-11` then `11-12`,
    the route the file names, and the pre-release opt-in still applies.
13. **auto keeps the previous major only while it is supported.** When
    `targets/<T-1>.json` says `eol` (a data commit flips it, X15), auto
    declares T only; a kept declaration (keep-current) and an explicit
    strategy are not affected. P for the decision is T's own default
    (`php_defaults.env`: 8.5 for 12) unless one is set.
14. **D7 in auto.** A d7-assisted source under `--auto` or
    `DRUPILOT_AUTONOMOUS=true` is refused in both phases with AR-07's exact
    message (code `d7-auto`), before anything is written. Its range keeps
    the 0.9 result until M7.

## Consequences

- H10 holds: for T = 11 the range, the PHP floor and the sets are the 0.9
  ones; the plan only names them.
- The 11.x breaking sets and the D8/D9 families reach a run only where a
  bed or the data proves them.
- The 1.0 plan's golden expectation for `acme_api` with W = {8.5} (G15)
  listed only 10.4 to 10.6; the data makes 10.3, 11.0, 11.1 and 11.2 fail
  too, and the golden records that.
