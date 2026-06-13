# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`drupilot` is **not an application** — it is a **Claude Code plugin** that ports Drupal 9/10 modules and themes to Drupal 11. There is no build step, package manager, or compiled output: the plugin is composed of markdown (commands, agents, skills), JSON (manifests, config, hooks) and a Bash script library. End-user documentation lives in `README.md` (English) / `README_es.md` (Spanish translation). The authoritative product spec is `../PROMPT.md` — its §1 carries verified (June 2026) ecosystem versions and toolchain commands; treat those as facts rather than re-researching.

## Language convention (important — overrides PROMPT.md)

All **functional content** of the plugin is **English only**: comments, log lines, user-facing messages, prompts, reports, frontmatter `description` fields. `PROMPT.md` §0/§7 specifies Spanish output, but that was **explicitly reversed by the user**. The single exception is `README_es.md`, the Spanish translation of `README.md` — if you change `README.md`, mirror it there. Never reintroduce Spanish into any other file. Code identifiers, package names and shell commands stay in their original form.

## Developing / validating the plugin

There is no test runner for the plugin itself. The verification gates are:

```bash
claude plugin validate .            # manifest + command/agent/skill frontmatter + hooks.json
bash -n path/to/script.sh           # syntax-check a shell script (shellcheck is not assumed present)
chmod +x scripts/*/*.sh hooks/scripts/*.sh   # scripts and hook scripts must be executable
```

Smoke-test a script directly (set `CLAUDE_PLUGIN_ROOT` so path/config resolution works outside an installed plugin):

```bash
export CLAUDE_PLUGIN_ROOT="$PWD"
bash scripts/env/preflight.sh --profile all          # human report
bash scripts/env/preflight.sh --profile setup --json # JSON + exit-code gate (0 ok / 2 missing hard req)
bash scripts/env/detect-php.sh --json
```

Most scripts support `-h/--help`, validate their args (clean English error + non-zero exit on misuse), and have a `--json` and/or `--dry-run` mode.

To exercise the plugin end-to-end, install it locally: `/plugin marketplace add .` then `/plugin install drupilot@drupilot`, and start a new session (hooks load at SessionStart).

## Architecture — how the pieces compose

The flow is **command → (gate) → skill + subagent → scripts → templates**, all reading one config and one shell library.

- **`scripts/lib/common.sh` is the contract everything depends on.** Every script sources it (group scripts via `../lib/common.sh`; hook scripts via `../../scripts/lib/common.sh`). It provides logging (`log_info/ok/warn/err/step`, `die`), tool/version detection (`have_cmd`, `tool_version`, `version_ge`, `docker_daemon_up`, `ddev_running`), config access, subject detection (`find_drupal_root`, `subject_type`, `subject_machine_name`, ...), and the path/cache helpers. **Do not reinvent these in individual scripts.**

- **stdout/stderr discipline:** all `log_*` output goes to **stderr**; **stdout is reserved for parseable payloads** (JSON, file lists). Anything a command parses from a script comes from stdout.

- **Config resolution (`config/defaults.json` + `config_get`):** every `DRUPILOT_*` key can be overridden by an environment variable of the same name, and **the env var always wins**. `DRUPILOT_PHP_TARGET` (default `8.3`) drives all tuning (Rector php sets, PHPStan level, PHPCS, DDEV `php_version`); read it via `resolve_php_target`, never hardcode a version. Versions flagged uncertain (notably PHP 8.5) are gated through `php_target_unconfirmed` and detected at runtime — never assumed.

- **`scripts/env/preflight.sh` is the requirements gate engine**, reused three ways: the `/drupilot-doctor` command, the SessionStart hook, and a per-command gate. It validates only what a profile needs (`analyze` → git+jq+composer/php; `setup`/`test` → Docker+daemon+DDEV; `contribute` → git+SSH/PAT), prints a human table or `--json`, and exits `0` (ready) / `2` (a hard requirement is missing) — `profile=all` always exits 0. Commands call it first and abort with the actionable report and **no side effects** when it fails.

- **Host vs. DDEV execution (`drupal_runner`):** analysis/test scripts `cd` to the Drupal root and prefix toolchain calls with `$(drupal_runner)`, which yields `ddev exec` when the DDEV environment is up and an empty string (host `vendor/bin`) otherwise. Relative paths like `web/modules/custom/foo` resolve identically inside the container and on the host — this is why scripts must cd to the root and use relative subject paths.

- **Hooks are fail-safe by contract** (`hooks/hooks.json` + `hooks/scripts/*.sh`): they read JSON on stdin, **never use `set -e`**, **never exit non-zero**, guard every optional tool with `|| true`, and act only by printing `{"hookSpecificOutput":{...}}` on stdout (fail-safe default = exit 0 with no JSON). `PreToolUse`/`guard-contrib.sh` returns `permissionDecision: "ask"` for outward-facing git push/MR commands in `semi` mode.

- **Two-phase porting philosophy:** Phase 1 (`/drupilot-port`, skill `minimal-port`) makes the code D11-compatible with the smallest diff, preserving original behavior; Phase 2 (`/drupilot-refactor`, skill `full-refactor`) is an opt-in "Drupal 11 way" rewrite. A viability assessment (`/drupilot-assess`) always runs first as a decision gate and still emits a staged plan even when effort is high.

- **Run modes of the `/drupilot` router:** `next` (default) summarizes + recommends one step; `status` is read-only; `full` runs the whole pipeline **with** confirmations and leaves refactor/contribute opt-in; `auto` (≡ `DRUPILOT_AUTONOMOUS=true`) runs `setup→assess→port→refactor→test` **hands-off** — no initial confirmation, `DRUPILOT_GENERATE_RULES` treated as `auto`, and it **never** does anything outward-facing (no push/MR/contribute, even in `auto` contribution mode). `auto` only relaxes drupilot's own gates; the Claude Code permission mode still governs Bash/Edit/Write.

- **Two patch kinds, one script (`scripts/contrib/make-patch.sh`):** `--local` writes an offline preview patch `MODULE-port-to-drupal-11.patch` next to the module (git-only, no rebase, no `contribute` gate; new files captured via a throwaway `GIT_INDEX_FILE` so the real index is untouched) — emitted automatically at the end of port/refactor. The legacy/contribution mode (with `--issue`/`--comment`) rebases onto `origin/BASE` and is now produced **always alongside the MR**, not only as the unmigrated-project fallback.

- **The `dbuytaert/drupal-digests` layer** is third-party, AI-generated, and **unlicensed**: it is cloned into a runtime cache (`digests_cache_dir`, under `${CLAUDE_PLUGIN_DATA}`) and referenced by path — **never vendored or committed**. It runs after official `drupal-rector`, always dry-run → review → apply → validate, and is filtered by the target `core_version_requirement` so it does not silently raise the minimum to 11.2+. Toggle with `DRUPILOT_USE_DIGESTS_RULES`.

- **Plugin layout rule:** only `plugin.json` belongs in `.claude-plugin/`; all component directories (`commands/`, `agents/`, `skills/`, `hooks/`, `scripts/`, `templates/`) live at the plugin root. `marketplace.json` also sits in `.claude-plugin/` and resolves plugin `source` (`"./"`) relative to the repo root. Hook/command paths use the `"${CLAUDE_PLUGIN_ROOT}"`-prefixed form.

## Conventions when adding or editing

- **New shell script:** `#!/usr/bin/env bash`, then `set -euo pipefail` (hook scripts excepted — see above), source `common.sh` at the correct `../` depth, parse args with a `while/case` loop, gate heavy/destructive operations through `preflight.sh`, keep it idempotent (detect-and-skip), English messages only, and `chmod +x` it. Reference the script's documented CLI from any command/skill that calls it.
- **New command:** `commands/<name>.md` with YAML frontmatter (`description`, `argument-hint`, `allowed-tools`; add `disable-model-invocation: true` for outward-facing/destructive commands like `drupilot-contribute`). Body is a prompt template that gates requirements, loads the relevant skill, drives scripts, and summarizes in English.
- **New skill/subagent:** `skills/<dir>/SKILL.md` / `agents/<name>.md` — embed the relevant versions/commands from `../PROMPT.md` §1–§3 so they never re-research.
- **Templates** (`templates/*.tmpl`) use `{{PLACEHOLDER}}` tokens substituted at setup time and are parameterized by the PHP target.

## Changelog and releases

Record **every notable change in `CHANGELOG.md`** under the `[Unreleased]` section as you make it (Keep a Changelog format: `Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security`). This is the running log of improvements — do not skip it.

On a release, keep the version in sync across three places: rename `[Unreleased]` to the new version with a date in `CHANGELOG.md`, bump `version` in `.claude-plugin/plugin.json` **and** the `drupilot` entry in `.claude-plugin/marketplace.json` to match, then tag the commit `vX.Y.Z` (the `CHANGELOG.md` compare/tag links assume those tags exist). Follow Semantic Versioning.
