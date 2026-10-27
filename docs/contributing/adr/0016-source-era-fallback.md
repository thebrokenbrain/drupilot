# 0016 — The source era when no code signal decides, and its confidence

- **Status:** accepted
- **Date:** 2026-10-05
- **Decided by:** the 1.0 working session (R-AUTO-3), during M3 (T-M3-02)

## Context

AR-05 makes the source era S "the minimum over the code signals" and calls
the declared `core_version_requirement` informational: S is "computed, never
taken from `core_version_requirement` alone". Most modules carry no code
signal, though. The info and test-API signals fire only for a Drupal 7
`.info`, a `core: 8.x` `.info.yml` or SimpleTest tests, and the bed-driven
signal 4 lands in M9. AR-05 also leaves `confidence` undefined. Without a
rule, a plain Drupal 10 module would have no S at all.

## Decision

1. **S is the minimum over the code signals and the lowest major the
   declared constraint admits.** The declaration (signal 3) caps S from
   above; it never raises it over a code signal. `^10` gives 10,
   `^8.8 || ^9 || ^10` gives 8, and `^10.3 || ^11 || ^12` (keep-current)
   gives 10.

   A lower S only adds hops whose Rector sets find nothing in modern code.
   A higher one would skip APIs that the code may still use and that no
   static signal catches. The lowest admitted major is the conservative
   reading of "informational".
2. **`confidence`:**
   - `high` when a code signal sets S;
   - `medium` when the declaration does, because no code signal is as old;
   - `low` when the subject declares nothing (an `.info.yml` without
     `core:` or `core_version_requirement`). S then defaults to 8, the
     oldest standard-track era.
3. **Only the subject's own `.info.yml` declares.** Nested modules count
   for the code scans (their files are part of the port) but not for
   signal 3.
4. **Signal 4 in 1.0 reads a recorded PHPStan JSON given with `--phpstan`**
   (`detect-source.sh --full`):
   - every "removed from drupal:X" message;
   - every unknown function or class that the `config/deprecations.json`
     lifecycle catalog dates with a `removed_in`.

   It only caps the static S from above (S = min(static S, X - 1)): a
   removal in drupal:13 on an undeclared module leaves S at the default 8.
   Nothing writes that file yet; M9 makes the bed produce it. The evidence
   keeps the hits of the oldest era only (at most 20), with paths from the
   subject's directory on.
5. **The signals come from the data.** Signals 5 and 6 are the `test-api`
   EREs of `config/paths/eras.json`: WebTestBase and JavascriptTestBase
   (deprecated in 8.6.0, removed from 9.0.0, verified on
   git.drupalcode.org) for era 8, and the Drupal 7 test cases for era 7.
   Signals 1 and 2 are the two `info` signals there. A signal 04-R8 lists
   that `eras.json` does not hold yet (`src/Tests/` as such, `*.test` files
   in a D8+ module, `prophesize(`, `@expectedException`) is added to the
   data, verified, before the script uses it.
6. **The Drupal 7 track needs a Drupal 7 `.info`.** The era-7 test cases are
   read for a `.info` subject only: an `.info.yml` module never loads such a
   class, so a leftover `.test` or a mention in a comment is dead code, not
   an API the code uses. The track is `d7-assisted` exactly when signal 1
   fired. The subject is scanned through its physical path, so a symlinked
   placement is read as well.

## Consequences

- `plan-draft` gets a stable S for every module. `plan-final` may still
  lower it through signal 4.
- A module that declares older majors than its code really needs gets
  extra, empty hops (`legacy_widgets_extra`: S = 8). They cost time, not
  correctness, and the report shows `confidence: medium` with the
  declaration as the evidence.
- The goldens in `tests/golden/detect-source/` pin the result for every
  fixture (`tests/unit/detect_source.sh`).
