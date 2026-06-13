# Changelog

All notable changes to **drupilot** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add every notable change under **[Unreleased]** as you make it (grouped under
`Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security`). On
release, rename `[Unreleased]` to the new version with a date, bump `version`
in `.claude-plugin/plugin.json` (and the `marketplace.json` entry) to match, and
tag the commit `vX.Y.Z`.

## [Unreleased]

## [0.1.0] - 2026-06-13

### Added
- Initial release of the drupilot Claude Code plugin.
- Two-phase porting workflow: **Phase 1** minimal compatibility (preserve
  behavior) and opt-in **Phase 2** "Drupal 11 way" refactor.
- Nine slash commands: `/drupilot` (router), `/drupilot-doctor`,
  `/drupilot-setup`, `/drupilot-assess`, `/drupilot-port`, `/drupilot-refactor`,
  `/drupilot-test`, `/drupilot-contribute`, `/drupilot-status`.
- Seven skills and four specialist subagents (port orchestrator, viability
  analyst, test engineer, contribution publisher).
- Requirements **preflight engine** with per-operation gates, and
  `/drupilot-doctor` with a per-platform status table and assisted installation.
- DDEV-based Drupal 11 environment setup: add-ons (`ddev-drupal-contrib`,
  Selenium) and the Composer dev toolchain, configured from templates.
- Static analysis: official `palantirnet/drupal-rector` plus the optional,
  runtime-cloned `dbuytaert/drupal-digests` AI-rule layer (filtered by the
  target `core_version_requirement`), PHPStan and PHPCS.
- Full PHPUnit suite (Unit / Kernel / Functional / FunctionalJavascript) in
  DDEV with Selenium for JS, plus coverage reporting.
- Drupal.org contribution flow: issue fork + Merge Request or legacy patch, in
  `semi` and `auto` modes, with graceful GitLab-API degradation; the PAT is
  never persisted or printed.
- Hooks: SessionStart environment detection, PostToolUse incremental
  `phpcbf`/`phpcs`, and a PreToolUse contribution guard.
- Configuration via `config/defaults.json` with environment-variable overrides;
  PHP target defaults to 8.3 and drives all tuning.
- Bilingual documentation (`README.md` / `README_es.md`) and an MIT license.

[Unreleased]: https://github.com/thebrokenbrain/drupilot/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/thebrokenbrain/drupilot/releases/tag/v0.1.0
