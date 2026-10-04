# 0013 — What the config-keys gate scans, and the comment limit

- **Status:** accepted
- **Date:** 2026-10-04
- **Decided by:** the 1.0 working session (R-AUTO-3), during M1 (T-M1-13)

## Context

`config/config-reference.json` must declare every `DRUPILOT_*` key any
script, hook, command, skill or agent reads, and `check.sh` limits the length
of the `_*_comment` prose of `config/defaults.json` until it moves to the docs
(M11). A plain grep also finds names that are not reads: words in shell
comments, the private `_DRUPILOT_*` shell variables of `common.sh`, and the
developer tools' own strings (`scripts/dev/`).

## Decision

The gate scans the non-comment lines of `scripts/*/*.sh` (but `scripts/dev/`)
and `hooks/scripts/*.sh`, and all of `commands/`, `skills/` and `agents/`,
for `DRUPILOT_` names not preceded by an identifier character. Names read by
prefix are declared as patterns (`DRUPILOT_CHOICE_*`, `DRUPILOT_ISSUE_*`,
`DRUPILOT_TPL_*`). Declaration findings warn until M11. A `_*_comment` longer
than 1800 characters fails: the longest one, `_verify_cores_comment`, has
1779.

## Consequences

The comments can be edited but not grow; the reference stays the place to
describe a setting.
