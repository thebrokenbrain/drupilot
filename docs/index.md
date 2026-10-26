# drupilot

![drupilot — Code. Fly. Conquer.](assets/drupilot.png)

drupilot is a Claude Code plugin that ports Drupal 9/10 modules and themes to
Drupal 11, deterministic tools first: a non-destructive viability assessment,
a minimal port that preserves behaviour (Phase 1), an opt-in "Drupal 11 way"
refactor (Phase 2), the module's own test suite run in DDEV as the proof, and
an optional, always-confirmed contribution back to Drupal.org.

drupilot 1.0 plans each port before it touches code (the upgrade plan),
checks every PHP of the window, and records deterministic findings. A Drupal
12 preview is available as an experimental opt-in.

!!! note "This site is being built"
    Most of the user guide still lives in the
    [README](https://github.com/thebrokenbrain/drupilot#readme) while the guide
    pages are written. The install, upgrade and concept pages are here, and the
    reference pages below are generated from the plugin's own sources, so they
    are always current.

## Getting started

- [Install](getting-started/install.md) — requirements, install, update.
- [Upgrading from 0.9 to 1.0](upgrading/0.9-to-1.0.md) — what changes for a project drupilot 0.9 set up.

## Concepts

- [Upgrade paths](concepts/upgrade-paths.md) — the source and target majors, the PHP target and the upgrade plan.
- [PHP and the core target](concepts/php-and-core-target.md) — the PHP window and the declared core range.
- [The pipeline](concepts/pipeline.md) and [Determinism and replay](concepts/determinism-and-replay.md).

## Guides

- [Drupal 12 preview](guides/d12-preview.md) — experimental: port to Drupal 12's newest pre-release.

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
