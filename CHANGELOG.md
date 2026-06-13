# Changelog

All notable changes to **drupilot** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add every notable change under **[Unreleased]** as you make it (grouped under
`Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security`). On
release, rename `[Unreleased]` to the new version with a date, bump `version`
in `.claude-plugin/plugin.json` (and the `marketplace.json` entry) to match, and
tag the commit `vX.Y.Z`.

## [0.3.0] - 2026-06-13

### Added
- Hands-off **autonomous mode**: the `auto` mode word (`/drupilot <subject> auto`)
  and the `DRUPILOT_AUTONOMOUS` config key run **setup → assess → port → refactor →
  test** unattended — no initial confirmation, `DRUPILOT_GENERATE_RULES` treated as
  `auto` (unless `off`), the local patch written at the end. It **never** performs
  any outward-facing action (no `git push` / Merge Request / contribute), even in
  `auto` contribution mode; contribution stays an explicit, separate step. Wired
  through the `/drupilot` router and the `drupal-port-orchestrator`, and documented
  in both READMEs (including how it combines with the Claude Code permission mode
  for a fully headless run).
- Local **preview patch**: `scripts/contrib/make-patch.sh --local` writes
  `MODULE-port-to-drupal-11.patch` next to the module (offline, git-only, no rebase),
  including new/untracked files via a throwaway git index so the developer's real
  index is never touched. `/drupilot-port` (and `/drupilot-refactor`) generate and
  refresh it automatically.

### Changed
- The Drupal.org contribution flow now **always** produces a `.patch` alongside the
  Merge Request (`[module]-[short-description]-[issue]-[comment].patch`), not only as
  the legacy fallback for unmigrated projects — it is conventional to attach one to
  the issue. Updated `/drupilot-contribute`, the `drupal-contribution` skill and the
  `drupal-contrib-publisher` agent.
- `make-patch.sh` gained `--local` and `--subject` (auto-detects the machine name
  from the subject directory); the legacy issue/comment flow is unchanged. The local
  mode skips the `contribute` gate (it needs only git, no SSH/PAT).

## [0.2.0] - 2026-06-13

### Added
- `ddev_project_name` helper in `scripts/lib/common.sh`: sanitizes a directory
  basename into a hostname-safe DDEV project name (lowercase, invalid runs → `-`,
  trimmed), with a `drupal-project` fallback.

### Changed
- `templates/ddev-web-environment.yaml.tmpl` is now written to a **separate**
  `.ddev/config.testing.yaml` and reduced to `MINK_DRIVER_ARGS_WEBDRIVER` +
  `SYMFONY_DEPRECATIONS_HELPER` — ddev-drupal-contrib already supplies
  `SIMPLETEST_*`, `BROWSERTEST_*`, `DTT_*` and `DRUPAL_TEST_WEBDRIVER_*`, so the
  fragment now merges cleanly instead of clobbering `SIMPLETEST_BASE_URL`.
- `/drupilot-setup` and the `ddev-environment` skill now document the
  recommended-project subject placement (move the extension into
  `web/modules/custom` after Drupal is created), register all three coder PHPCS
  `installed_paths`, and write the testing env to `config.testing.yaml`.

### Fixed
- `ddev-up.sh` derived the DDEV project name from the directory basename
  verbatim, so a path containing `_`, uppercase or dots (e.g.
  `upgrade-to-d11-file_version`) made `ddev config` fail with "is not a valid
  project name". The name is now sanitized to a hostname-safe label.
- `ddev-up.sh` now detects a non-clean project root (a stray module dir or a
  downloaded tarball) before `ddev composer create` and aborts with actionable
  guidance, instead of letting composer fail cryptically with "is not allowed to
  be present".
- `ddev-add-ons.sh` now disables ddev-drupal-contrib's `symlink-project` hook in
  the recommended-project layout (before the restart, so it never runs) and
  removes the spurious `web/modules/custom/<project>/` symlink dir it would
  otherwise create from the project's `composer.json`/`.ddev`.
- The testing `MINK_DRIVER_ARGS_WEBDRIVER` value broke `ddev start` ("did not
  find expected key") because DDEV serializes `web_environment` values into the
  generated docker-compose wrapped in double quotes WITHOUT escaping the inner
  quotes. The template value is now pre-escaped (`\"` inside YAML single quotes).
- PHPCS setup registered only `coder_sniffer` in `installed_paths`; coder's
  Drupal standard also references `phpcs-variable-analysis` and
  `slevomat/coding-standard`, so `phpcs --standard=Drupal` failed with
  "Referenced sniff ... does not exist". All three are now documented/registered.
- `/drupilot-doctor` and `/drupilot-setup` no longer fail at command load: the
  installer/DDEV step examples were written as `` !`…` `` command injections, so
  Claude Code tried to execute them at load time. The `install-deps.sh` example
  carried the literal `<tools...>` placeholder, which the shell parsed as an
  invalid redirection (`syntax error near unexpected token 'newline'`). These
  three step templates (`install-deps.sh`, `ddev-up.sh`, `ddev-add-ons.sh`) are
  now plain code blocks the model runs via the Bash tool, not load-time
  injections. Only read-only context probes remain as `` !`…` ``.

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

[Unreleased]: https://github.com/thebrokenbrain/drupilot/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/thebrokenbrain/drupilot/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/thebrokenbrain/drupilot/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/thebrokenbrain/drupilot/releases/tag/v0.1.0
