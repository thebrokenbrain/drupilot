# 0021 — DRUPILOT_DRUPAL_TARGET beside the target major

- **Status:** accepted
- **Date:** 2026-10-05
- **Decided by:** the 1.0 working session (R-AUTO-3), during M3 (T-M3-06)

## Context

X12 keeps the 0.9 setting `DRUPILOT_DRUPAL_TARGET` beside the new
`DRUPILOT_TARGET_MAJOR`:
- a bare `^N` maps to `TARGET_MAJOR=N`;
- "any other constraint is treated as an explicit declared-range override
  (strategy `explicit`)".

CC-08 keeps 0.9's behaviour for Drupal 11.

In 0.9 the setting was only the composer constraint `ddev-up.sh` built the
test-bed's core with. People used one-major forms to pin that core: `^11.2`,
`~11.2.0`, `11.x-dev`. Taken literally, the second half of X12 broke three
things, all reproduced by the review of T-M3-06:
1. A one-major or dev form became the module's declared range, for example a
   `core_version_requirement` of `~11.2.0`, or a range the resolver refuses
   (`11.x-dev`). That is a change of 0.9's meaning, and it blocks the setup.
2. The draft plan froze the explicit range. The port's final plan then took
   the strategy of the core-target tab, which replaced the range, lowered F
   and was refused as `final-changes-frozen` (ADR 0018). Re-running the setup
   looped.
3. A `DRUPILOT_KEEP_D10` boolean counted as a set strategy and silently
   dropped the range.

Reading T from "the highest major" also counted upper bounds: `>=11 <12` gave
12.

## Decision

1. **The setting stays the test-bed's core constraint.** `ddev-up.sh` builds
   with it, as in 0.9.
   - Its target major is the highest major it admits (`constraint_top_major`).
     Each `||` alternative admits from its lower bound's major up to what its
     upper bound leaves (`<12` stops at 11), and `!=` is skipped:
     `^12` → 12, `>=11 <12` → 11, `>=10.3 <12` → 11, `^10.3 || ^11` → 11.
   - An explicit `DRUPILOT_TARGET_MAJOR` wins. With only it set, the
     test-bed's constraint is `^<major>`.
2. **Only a range across majors overrides the strategy.** An explicit value
   that admits two or more majors, such as `^10.3 || ^11` or `>=10.3 <12`, is
   also the declared range (`drupal_target_range`, strategy `explicit`).
   - It is not one when it is a bare `^N`, admits one major, or uses a dev,
     wildcard or stability form (`@`, `-dev`, `.x`, `*`). Such a value only
     pins the test-bed, as in 0.9.
3. **A strategy set by name wins over that range.** Only
   `DRUPILOT_CORE_TARGET_STRATEGY` itself counts, in the environment or
   `.drupilot.json`, read without the alias layer (`config_get_explicit_noalias`).
   - A `DRUPILOT_KEEP_D10` boolean does not count: it is honored only while the
     strategy is `auto` (AR-27), and an explicit range is not `auto`.
   - `--strategy` and `--range` on the command line win over both.
4. **The port keeps the draft's explicit range.** When the frozen draft plan's
   `.range.strategy` is `explicit`, `/drupilot-port` asks no core-target tab
   and resolves the final plan with `--range '<that constraint>'`. The draft
   and the final plan then read the same request. The orchestrator and the
   `minimal-port` skill say the same.

## Consequences

- For Drupal 11 with neither setting, or with `^11`, nothing changes from 0.9:
  T is 11, the test-bed constraint is `^11`, and the strategy decides the
  range.
- A one-major `DRUPILOT_DRUPAL_TARGET` behaves as in 0.9. A range across majors
  gets 1.0's override without the freeze conflict.
- `tests/unit/target_major_mapping.sh` covers:
  - the operand rules;
  - the one-major and dev forms;
  - a `DRUPILOT_KEEP_D10` beside a range;
  - a draft then a final plan with the range.
