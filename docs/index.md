# drupilot

![drupilot — Code. Fly. Conquer.](assets/drupilot.png)

drupilot is a Claude Code plugin that ports Drupal 9/10 modules and themes to
Drupal 11, deterministic tools first: a non-destructive viability assessment,
a minimal port that preserves behaviour (Phase 1), an opt-in "Drupal 11 way"
refactor (Phase 2), the module's own test suite run in DDEV as the proof, and
an optional, always-confirmed contribution back to Drupal.org.

!!! note "This site is being built"
    The user guide still lives in the
    [README](https://github.com/thebrokenbrain/drupilot#readme) while the
    getting-started, guide and concept pages are written. The reference pages
    below are generated from the plugin's own sources and are always current.

## Reference

- [Commands](reference/commands.md) — every slash command, its arguments and tools.
- [Configuration](reference/configuration.md) — every `DRUPILOT_*` setting, its default and how it resolves.
- [Choices](reference/choices.md) — the tabbed decisions and how to pre-answer them.
- [Scripts](reference/scripts.md) — the usage of every script.
- [Skills and agents](reference/skills-and-agents.md) — what the commands load.
- [Toolchain](reference/toolchain.md) — the verified development toolchain.
- [Drupal deprecations](reference/deprecations.md) — what the deprecation explainer knows.
- [Per-module state](reference/state.md) — the `state.json` record behind `/drupilot-status`.

## Contributing

[How drupilot is developed](contributing/index.md): the checks, the docs and
the architecture decision records.
