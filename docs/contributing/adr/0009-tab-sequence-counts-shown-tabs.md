# 0009 — The frozen tab sequence counts the tabs a command shows by header

- **Status:** accepted
- **Date:** 2026-10-04
- **Decided by:** the 1.0 working session (R-AUTO-3), during M1 (T-M1-17)

## Context

The roadmap seeds the 0.9 tab sequence of a guided `full` run from a grep of
`choice.sh --key` calls, and lists `D10_CHECK` only in the port stage. The
live evals showed the model, every time, also listing the "Drupal 10 check"
tab in the refactor stage. It is right: `commands/drupilot-refactor.md`
(already in v0.9.0) reuses that tab when a core-matrix leg fails, naming it
by its header instead of calling `choice.sh`.

## Decision

The static extraction also counts a `config/choices.json` header that a
command shows as a `"<header>" tab`. An agent's mentions narrate the
commands' tabs and are not counted again. The frozen sequence
(`tests/evals/router/tab-sequence.json`, extracted identically from v0.9.0
and from HEAD) is therefore INTENT, PHP_TARGET, PLACEMENT, CONFIG_CONFLICT,
EXISTING_WORK, CORE_TARGET, DIGESTS_RULES, PORT_ATTRIBUTES, D10_CHECK, LEARN,
NEXT_STEP, REFACTOR_SCOPE, PHPSTAN_LEVEL, ATTRIBUTE_FLOOR, D10_CHECK, LEARN,
NEXT_STEP, CONTRIB_MODE, PUSH.

## Consequences

Dropping the refactor stage's reuse of the tab is now caught by the `evals`
gate, as any other change to the 0.9 sequence. New tabs may still only be
inserted.
