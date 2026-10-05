# Deprecations of drupilot

This page lists drupilot's own renamed settings, values, fields and flags. For
the Drupal APIs drupilot fixes, see [Deprecations](deprecations.md).

A name drupilot 1.0 renamed keeps working for all of 1.x. It is removed in
2.0.0, which warns when a removed name is still set. Every row below comes from
`config/migrations.json`, which drupilot reads at runtime.

What warns:
- the `DRUPILOT_KEEP_D10` boolean warns once per run and names the new setting;
- an old value in a `DRUPILOT_CHOICE_CORE_TARGET` pre-answer warns once per run
  and names the new value.

The setting `DRUPILOT_CORE_TARGET_STRATEGY` accepts its 0.9 values `keep-d10`
and `d11-only` without a warning, because drupilot itself still writes them for
Drupal 11 (below).

**Drupal 11 keeps the 0.9 words.** For a Drupal 11 target, drupilot still writes
and prints the 0.9 strategy values, `keep-d10` and `d11-only`:
- in `core-strategy.sh --json`;
- in the lock;
- in `state.json`;
- in a persisted `/drupilot-port` core-target answer.

A 0.9 reader therefore sees no difference. The new names are accepted wherever
a value is read, and are what drupilot writes for another target.

## Settings

| Old | New | Since | Removed in | Notes |
| --- | --- | --- | --- | --- |
| `DRUPILOT_KEEP_D10=true` (also `1`, `yes`, `on`) | `DRUPILOT_CORE_TARGET_STRATEGY=keep-previous` | 1.0.0 | 2.0.0 | Only while the strategy is `auto`: an explicit strategy wins, as in 0.9. Read from the environment or `.drupilot.json`. |
| `DRUPILOT_KEEP_D10=false` (also `0`, `no`, `off`) | `DRUPILOT_CORE_TARGET_STRATEGY=target-only` | 1.0.0 | 2.0.0 | As above. |

## Values

| Setting | Old | New | Since | Removed in | Notes |
| --- | --- | --- | --- | --- | --- |
| `DRUPILOT_CORE_TARGET_STRATEGY`, `DRUPILOT_CHOICE_CORE_TARGET` | `d11-only` | `target-only` | 1.0.0 | 2.0.0 | Declares the target major only. Still what drupilot writes for Drupal 11. |
| `DRUPILOT_CORE_TARGET_STRATEGY`, `DRUPILOT_CHOICE_CORE_TARGET` | `keep-d10` | `keep-previous` | 1.0.0 | 2.0.0 | Keeps the previous major too. Still what drupilot writes for Drupal 11. |

The 1.0 strategy `widest` has no 0.9 name. For Drupal 11 it declares the same
range as `keep-previous`, `^10 || ^11`.

The `/drupilot-port` "Drupal 10 check" tab keeps its own `d11-only` option
unchanged (`DRUPILOT_CHOICE_D10_CHECK=d11-only`). It is not a renamed value.

## Fields

| Output | Old | New | Since | Removed in | Notes |
| --- | --- | --- | --- | --- | --- |
| `port-summary --json` | `d10_support` | `prev_major_support` | 1.0.0 | 2.0.0 | Planned: port-summary v2, in a later 1.x release, adds the new field beside the old one. The v1 shape stays as it is. |

## Flags

| Script | Old | New | Since | Removed in |
| --- | --- | --- | --- | --- |
| `scripts/contrib/make-issue.sh` | `--d10-unverified` | `--prev-major-unverified` | 1.0.0 | 2.0.0 |

## Not renamed

- `DRUPILOT_PHP_TARGET` keeps its name and meaning: the PHP the port runs on.
- `DRUPILOT_DRUPAL_TARGET` keeps working beside the 1.0 setting
  `DRUPILOT_TARGET_MAJOR` (ADR 0021):
  - It is still the test-bed's core constraint, and the highest major it
    admits names the target major (`^12` → 12, `>=11 <12` → 11).
  - A constraint that admits two or more majors, such as `^10.3 || ^11`, is
    also the declared core range to use, unless
    `DRUPILOT_CORE_TARGET_STRATEGY` is set too. `/drupilot-port` then asks no
    core-target question.
  - A one-major value (`^11.2`, `~11.2.0`, `11.x-dev`) only pins the test-bed's
    core, as in 0.9.
  - With only `DRUPILOT_TARGET_MAJOR` set, the test-bed's core constraint is
    `^<major>`.
