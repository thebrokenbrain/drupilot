<p align="center">
  <img src="assets/drupilot.png" alt="drupilot — Code. Fly. Conquer. A Claude Code plugin to port Drupal 9/10 to Drupal 11" width="100%">
</p>

# drupilot

> A Claude Code plugin that ports Drupal 9/10 modules and themes to **Drupal 11** — it assesses viability, applies the port (minimal compatibility and/or a full "Drupal 11 way" refactor), adapts and runs the **entire** test suite inside DDEV, and helps you **contribute the result back to Drupal.org** (issue fork + Merge Request, or a legacy patch).

*Read this in Spanish: [README_es.md](README_es.md).*

`drupilot` = **Drupal** + **co-pilot**. It is your co-pilot for the D9/10 → D11 journey: it never refuses a hard module — if a full refactor is disproportionate it still hands you a staged, functionality-preserving plan and leaves the final call to you.

---

## Table of contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Commands](#commands)
- [The two-phase porting philosophy](#the-two-phase-porting-philosophy)
- [Hands-off (autonomous) mode](#hands-off-autonomous-mode)
- [Configuration](#configuration)
- [Use cases](#use-cases)
- [How it works (architecture)](#how-it-works-architecture)
- [The drupal-digests complementary layer](#the-drupal-digests-complementary-layer)
- [Safety and conventions](#safety-and-conventions)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## What it does

- **Viability assessment** — a non-destructive static analysis (Rector dry-run, PHPStan, PHPCS, optional Upgrade Status) that estimates how much of the work is auto-fixable vs. manual, classifies the hard breaks (Twig 3, CKEditor 5, jQuery UI, Symfony 7), checks `info.yml` and contrib-dependency D11 readiness, recommends a **core compatibility target** (`^11` vs `^10 || ^11`, the `require.php` it implies, and a SemVer version-bump verdict), and produces a markdown report plus a **staged port plan** with an S/M/L/XL effort verdict.
- **Minimal port (Phase 1)** — the smallest set of changes to make the module/theme run on Drupal 11 while **preserving the original functionality**. Driven by `palantirnet/drupal-rector`, an optional AI-rules layer (`dbuytaert/drupal-digests`), and targeted manual fixes.
- **Full refactor (Phase 2, opt-in)** — a rewrite to modern Drupal 11 best practices: PHP 8 attributes for plugins, dependency injection, strict types, zero deprecations, clean `Drupal` + `DrupalPractice`, and a green test suite.
- **Tests** — discovers, adapts and runs the complete PHPUnit suite (Unit / Kernel / Functional / FunctionalJavascript) inside DDEV (with Selenium for JS), iterating until green and reporting coverage. Failures are **never** silenced.
- **Contribution** — prepares and (optionally) publishes the result to Drupal.org via the modern issue-fork + Merge Request flow, or a legacy patch, with a **semi-automatic** (confirm every outward action) or **fully automatic** mode. A `.patch` is always produced alongside the MR so you can attach it to the issue.
- **Patches** — every port also writes a local `.patch` (`MODULE-port-to-drupal-11.patch`) so you can review the change, apply it elsewhere, or test it locally before contributing — no Drupal.org account required.

The default PHP target is **8.3** and is fully configurable; everything (Rector sets, PHPStan level, PHPCS sniffs, DDEV `php_version`) derives from a single setting.

---

## Requirements

`drupilot` validates only what each operation needs, so you don't need Docker just to run a static analysis. Run `/drupilot-doctor` at any time for a per-platform status table and assisted installation.

| Operation | Hard requirements | Optional / soft |
| --- | --- | --- |
| **Analysis** (`assess`, static `port`) | `git`, `jq`, and `composer` or `php` ≥ target | — |
| **Environment & tests** (`setup`, `test`) | **Docker** (daemon running) + **DDEV** (a version with Drupal 11 support) | Selenium add-on (for FunctionalJavascript), disk space |
| **Contribution** (Drupal.org) | `git`, a drupal.org account + GitLab access, and an **SSH key** or a **PAT** | `glab`/`curl` for the GitLab API (degradable) |

DDEV provides the full Drupal environment (web + database + chromedriver) on top of Docker — **you do not need to set up a LAMP stack yourself**.

---

## Installation

`drupilot` ships as a single-plugin marketplace, so installation is two steps.

**From a local checkout:**

```text
/plugin marketplace add /path/to/drupilot
/plugin install drupilot@drupilot
```

**From GitHub (once published):**

```text
/plugin marketplace add thebrokenbrain/drupilot
/plugin install drupilot@drupilot
```

After installing, restart or start a new session so the hooks load. Then run `/drupilot-doctor` to verify your environment.

> Validate the plugin manifest locally at any time with `claude plugin validate /path/to/drupilot`.

---

## Quick start

```text
# 1. Check what you have and install anything missing (with confirmation)
/drupilot-doctor

# 2. Point drupilot at your module/theme and let it guide you
/drupilot web/modules/custom/my_module

# …or drive the steps yourself:
/drupilot-setup                         # spin up a Drupal 11 DDEV site + toolchain
/drupilot-assess  web/modules/custom/my_module
/drupilot-port    web/modules/custom/my_module
/drupilot-test    web/modules/custom/my_module
/drupilot-refactor web/modules/custom/my_module   # optional Phase 2
/drupilot-contribute web/modules/custom/my_module # contrib projects only
```

---

## Commands

| Command | What it does |
| --- | --- |
| `/drupilot [subject] [full\|auto]` | **Router / guided flow.** Detects the current state (environment, last assessment, phase) and recommends the next step. `full` runs the whole flow with confirmations; `auto` runs it **hands-off** (see below). |
| `/drupilot-doctor [install]` | **Requirements check.** Per-platform status table (Docker + daemon, DDEV, git, composer/php, jq, SSH/PAT) with install instructions and optional assisted installation (with confirmation). |
| `/drupilot-setup` | Spins up a **Drupal 11 DDEV** site, installs the add-ons (`ddev-drupal-contrib`, Selenium) and the Composer dev toolchain, and writes `rector.php` / `phpstan.neon` / `phpcs.xml.dist` / test env from templates. Idempotent. |
| `/drupilot-assess [subject]` | Produces the **viability report** + staged plan with an S/M/L/XL verdict. |
| `/drupilot-port [subject]` | **Phase 1 minimal port.** Official Rector + (optional) digests rules filtered by target + ad-hoc fixes + minimal manual changes; leaves the code compiling with no blocking deprecations. |
| `/drupilot-refactor [subject]` | **Phase 2 full refactor** (opt-in): the "Drupal 11 way", PHPStan level 5–6, clean PHPCS. |
| `/drupilot-test [subject]` | Discovers, adapts and runs **all** test suites in DDEV (Selenium for JS); iterates to green; reports coverage. |
| `/drupilot-contribute [subject] [issue]` | Publishes to **Drupal.org**: issue fork + Merge Request (or legacy patch), in semi or auto mode. User-invocable only; never exposes the PAT. |
| `/drupilot-status` | Read-only summary of environment, PHP target, current phase, last assessment, test status, and the suggested next step. |

---

## The two-phase porting philosophy

1. **Phase 1 — Minimal compatibility (default).** The smallest changes that make the module/theme work on Drupal 11 while respecting the original functionality and **not colliding** with what Drupal 11 already provides. Engine: `drupal-rector` + targeted manual fixes. No architectural changes.
2. **Phase 2 — "Drupal 11 way" refactor (opt-in).** A rewrite to modern best practices: PHP 8 attributes for plugins, dependency injection, strict typing, zero deprecations, zero PHPStan errors at the target level, full `Drupal` + `DrupalPractice` compliance, and complete tests in green.

A **viability assessment** always runs first as a decision gate. If the refactor is disproportionate (a configurable threshold), `drupilot` does not refuse — it still delivers a staged port plan that preserves the original functionality, and leaves the decision to you.

**How "respecting the original functionality" is verified.** The adapted test suite staying **green is the preservation gate** for both phases — that green is the evidence the behavior is preserved. Test adaptations only update a test's *form* (PHPUnit/Drupal API), never *what it verifies*; a behavioral regression is fixed in the code, never by relaxing a test. If the module ships **no tests**, `drupilot` reports preservation as **not verified** and recommends adding them — it does not fabricate them.

---

## Hands-off (autonomous) mode

Just describe what you want in natural language — **"port this module to Drupal 11"** already runs the whole flow (guided, with confirmations) via the `drupal-port-orchestrator`, which delegates to the specialist subagents (`drupal-viability-analyst`, `drupal-test-engineer`) as needed. Want it **fully unattended** (no confirmations at all)? Use the `auto` mode word (or set `DRUPILOT_AUTONOMOUS=true`): it then runs **setup → assess → port → refactor → test** hands-off — no initial confirmation, generating the local `.patch` at the end.

```text
# Natural language is enough — this triggers the orchestrator:
"Port the module in the current directory to Drupal 11, run the whole thing autonomously"

# …or explicitly:
/drupilot web/modules/custom/my_module auto
```

Two things to know — they are deliberate safety boundaries:

1. **It never contributes on its own.** Autonomous mode stops before any outward-facing action: no `git push`, no Merge Request, no `/drupilot-contribute`. If the module is contrib, it only *suggests* contributing at the end. Publishing stays an explicit, separate step you run yourself.
2. **Two layers of "no prompts".** The `auto` mode word only relaxes *drupilot's own* gates. Bash/Edit/Write still go through Claude Code's permission system, so a truly unattended run also needs a permissive permission mode:

```bash
# Interactive but unattended (accepts edits automatically):
claude --permission-mode acceptEdits

# Fully headless (CI / scripts):
export DRUPILOT_AUTONOMOUS=true
export DRUPILOT_GENERATE_RULES=auto    # the orchestrator already treats it as auto in this mode
claude -p "/drupilot web/modules/custom/my_module auto" --permission-mode bypassPermissions
```

In autonomous mode `DRUPILOT_GENERATE_RULES` is treated as `auto` (set it to `off` to keep ad-hoc rule generation report-only). Everything is still gated and idempotent: a missing hard requirement stops that stage cleanly, and re-running skips work already done. By contrast, `full` runs the same pipeline but **pauses for your confirmation** and leaves refactor/contribution opt-in.

---

## Configuration

Defaults live in `config/defaults.json`. **Every `DRUPILOT_*` key can be overridden by an environment variable of the same name** (the environment variable always wins).

| Variable | Default | Effect |
| --- | --- | --- |
| `DRUPILOT_PHP_TARGET` | `8.3` | Target PHP version (drives Rector / PHPStan / PHPCS / DDEV). |
| `DRUPILOT_DRUPAL_TARGET` | `^11` | Target core range. |
| `DRUPILOT_CORE_TARGET_STRATEGY` | `auto` | Core compatibility decision: `auto` (keep `^10 \|\| ^11` while backwards-compatible, switch to `^11` on a BC break / refactor), `d11-only`, or `keep-d10`. Keeping D10 also declares composer `require.php: ">=<target>"`, and the choice yields a SemVer version-bump verdict. |
| `DRUPILOT_KEEP_D10` | _(legacy)_ | Legacy boolean override of the strategy (`true` → keep D10, `false` → D11-only). Honored only when set; prefer `DRUPILOT_CORE_TARGET_STRATEGY`. |
| `DRUPILOT_CODER_CONSTRAINT` | `^8.3` | `drupal/coder` branch (PHPCS 3.x vs 4.x). |
| `DRUPILOT_PHPSTAN_LEVEL` | `2` | Base PHPStan level (deprecation detection). |
| `DRUPILOT_PHPSTAN_LEVEL_REFACTOR` | `6` | PHPStan level used in the refactor phase. |
| `DRUPILOT_VIABILITY_THRESHOLD` | `medium` | Threshold for the "large refactor" warning. |
| `DRUPILOT_CONTRIB_MODE` | `semi` | `semi` (confirm outward actions) or `auto`. |
| `DRUPILOT_USE_DIGESTS_RULES` | `true` | Use the complementary `drupal-digests` layer after official Rector. |
| `DRUPILOT_DIGESTS_REF` | `main` | Commit/tag of the `drupal-digests` repo, for reproducibility. |
| `DRUPILOT_GENERATE_RULES` | `ask` | Generate ad-hoc Rector rules for uncovered deprecations: `ask` / `auto` / `off`. |
| `DRUPILOT_AUTONOMOUS` | `false` | Hands-off mode (same as the `auto` mode word): unattended setup→assess→port→refactor→test, writes the local patch, **never** contributes. See [Hands-off mode](#hands-off-autonomous-mode). |
| `DRUPILOT_DETERMINISTIC` | `true` | Reproducibility (default on): freeze the resolved Drupal core, dev toolchain, digests SHA and DDEV add-ons in a per-project `drupilot-lock.json` and reuse them on later runs. Set to `false` to resolve fresh every time and refresh the lock. See [Determinism](#determinism-reproducible-by-default). |

Other useful environment variables: `DRUPILOT_GITLAB_PAT` (your GitLab Personal Access Token, read only at runtime, never persisted), `DRUPILOT_ASSUME_YES=1` (skip confirmations in non-interactive runs), `NO_COLOR=1`.

Example — target PHP 8.4 and drop Drupal 10 support for one session:

```bash
export DRUPILOT_PHP_TARGET=8.4
export DRUPILOT_CORE_TARGET_STRATEGY=d11-only   # ^11 only (drops Drupal 10)
```

---

## Determinism (reproducible by default)

Porting the same module twice should yield the same result. drupilot is **deterministic by default** (`DRUPILOT_DETERMINISTIC=true`): the first time it resolves the moving parts of a port it **freezes** them in a per-project `drupilot-lock.json` (kept in drupilot's state dir, not your project tree) and **reuses** them on later runs:

- the exact **Drupal core** version and the **dev-toolchain** versions (`drupal-rector`, PHPStan + extensions, `coder`/PHPCS, Drush) read from the generated `composer.lock`;
- the **digests commit (SHA)** that the `main` branch resolved to — so the AI-generated rule layer stays fixed for the project even though its default ref is still `main`;
- the installed **DDEV add-on** versions.

It works like a `composer.lock`: the version ranges in `config/defaults.json` stay flexible, but the lock pins exactly what was used. `scripts/env/lock-sync.sh` captures/updates it (`ddev-up.sh` and `ddev-add-ons.sh` call it automatically).

**Escape hatch:** set `DRUPILOT_DETERMINISTIC=false` to ignore the lock, resolve everything fresh (the newest in each range, the live `main` for digests) and refresh the lock. `lock-sync.sh --refresh` does the same for the digests SHA only.

Beyond versions, drupilot keeps the *process* objective too: stable file ordering, a numeric S/M/L/XL rubric, fixed hard-break greps, and a done bar judged solely by Rector/PHPStan/PHPCS + the test suite.

---

## Use cases

### 1. "Is this module worth porting?" — assessment only

```text
/drupilot-assess web/modules/custom/my_module
```

You get a markdown report (cached for later) classifying every finding as auto-fixable (Rector) or manual, listing the hard breaks, the `info.yml` status and contrib-dependency D11 readiness, and an **S/M/L/XL** verdict with a staged plan. Nothing is modified.

### 2. End-to-end guided port of a custom module

```text
/drupilot web/modules/custom/my_module
```

The router checks your environment, runs the assessment, applies the Phase 1 port, runs the test suite in DDEV, and reports at each step — pausing for your confirmation before anything outward-facing. It tells you exactly what it will do before doing it. When the port finishes it writes a local `MODULE-port-to-drupal-11.patch` so you can review or test the change immediately.

To let the agents run the whole thing without pausing, add `auto` (see [Hands-off mode](#hands-off-autonomous-mode)):

```text
/drupilot web/modules/custom/my_module auto
```

### 3. Minimal port only (Phase 1), no refactor

```text
/drupilot-setup
/drupilot-port web/modules/custom/my_module
/drupilot-test web/modules/custom/my_module
```

Functionality stays identical; the module ends up D11-compatible with no blocking deprecations. Ideal when you want the smallest, safest diff.

### 4. Modernize to the "Drupal 11 way" (Phase 2)

```text
/drupilot-refactor web/modules/custom/my_module
```

Converts annotations to PHP 8 attributes, introduces dependency injection and strict types, removes every deprecation, raises PHPStan to level 5–6, and keeps the suite green. Each significant change is explained.

### 5. Run the full test suite in DDEV

```text
/drupilot-test web/modules/custom/my_module --type all --coverage
```

Runs Unit, Kernel, Functional and FunctionalJavascript (Selenium) inside DDEV and reports coverage. If a test can't pass because of an external cause (e.g. a contrib dependency without D11 support), it is documented explicitly rather than silenced.

### 6. Contribute the fix back to Drupal.org

Semi-automatic (recommended — confirms every push / MR):

```text
/drupilot-contribute web/contrib/some_module 3456789
```

Fully automatic (requires SSH or a PAT configured):

```bash
export DRUPILOT_CONTRIB_MODE=auto
export DRUPILOT_GITLAB_PAT=glpat-xxxxxxxx   # never stored; read at runtime
```
```text
/drupilot-contribute web/contrib/some_module 3456789
```

It creates the issue fork, branch and commit (in the correct format, detecting the project's convention), pushes, opens the Merge Request via the GitLab API — **degrading gracefully** to a one-click MR URL if the API is blocked — and **also writes a `.patch`** (`MODULE-port-to-drupal-11-ISSUEID-COMMENT.patch`) to attach to the issue alongside the MR. It reminds you that **credit is assigned by the maintainers** via the issue's Contribution Record, and it never exposes your PAT.

---

## How it works (architecture)

- **Commands** (`commands/*.md`) are the entry points. Each gates its own requirements via the preflight engine before doing anything.
- **Skills** (`skills/*/SKILL.md`) carry the reusable operating knowledge (DDEV environment, viability assessment, minimal port, full refactor, test adaptation, PHP-target tuning, Drupal contribution).
- **Subagents** (`agents/*.md`) are specialists the commands delegate to: `drupal-port-orchestrator`, `drupal-viability-analyst`, `drupal-test-engineer`, `drupal-contrib-publisher`.
- **Hooks** (`hooks/hooks.json`):
  - `SessionStart` → a lightweight environment detector that summarizes your PHP target and readiness.
  - `PostToolUse` (Write|Edit) → incremental `phpcbf` + `phpcs` on edited Drupal files.
  - `PreToolUse` (Bash) → in `semi` mode, asks for confirmation before any outward-facing git push / MR action.
- **Scripts** (`scripts/`) are a robust, idempotent shell library: a shared `lib/common.sh`, the `env/preflight.sh` requirements engine, and the `analysis/`, `tests/` and `contrib/` wrappers the skills and commands invoke.
- **Templates** (`templates/`) are parameterized configs (`rector.php`, `phpstan.neon`, `phpcs.xml.dist`, DDEV config + test environment, report templates) tuned by the PHP target.

---

## The drupal-digests complementary layer

`dbuytaert/drupal-digests` is an **experimental, AI-generated** set of Rector rules (by Dries Buytaert) that covers very recent deprecations the official `palantirnet/drupal-rector` may not yet include. It is a **Git repository, not a Composer package, and it has no license**, so `drupilot`:

- **never vendors or redistributes** it — it is cloned into a runtime cache and referenced by path (you can pin a ref with `DRUPILOT_DIGESTS_REF`);
- runs it **after** the official Rector pass, always **dry-run → human review of the diff → apply → validate** (PHPStan + tests), never blindly;
- **filters** rules by your target `core_version_requirement` — some rules migrate APIs deprecated in 11.2+ and removed in 12.0, which could raise your effective minimum and break on 11.0/11.1.

Enable/disable it with `DRUPILOT_USE_DIGESTS_RULES` (default `true`).

---

## Safety and conventions

- **Output language is English.** Code identifiers, package names and shell commands stay in their original form.
- **Outward-facing actions are always confirmed** in `semi` mode; the PAT is never persisted in plaintext or printed.
- **Idempotent and fail-safe** scripts and hooks: re-running a step detects existing work and skips it; a missing optional tool never breaks a hook.
- **Test failures are never silenced** — if something can't pass, the reason is documented.
- **Nothing marked uncertain is assumed** (PHP 8.5 support, the webdriver hostname, DDEV image availability): these are detected at runtime and degrade gracefully.
- **Final verification** before a module is considered done: a compatible `info.yml`, `phpstan` with no deprecations at the target level, a clean `phpcs Drupal,DrupalPractice`, and the applicable test suite green.

---

## Troubleshooting

- **A command says a hard requirement is missing.** Run `/drupilot-doctor` — it shows exactly what is missing, the detected vs. required version, and the install command for your platform.
- **Docker is installed but commands still fail.** The daemon must be running (`sudo systemctl start docker` on Linux, or launch Docker Desktop). `drupilot` checks the daemon, not just the binary.
- **FunctionalJavascript tests are skipped.** Install the Selenium add-on: `ddev add-on get ddev/ddev-selenium-standalone-chrome && ddev restart`.
- **The GitLab API is blocked.** Expected — drupalcode's API is restricted by default. `drupilot` degrades to a one-click MR URL; just open it to create the MR.
- **Plugin not loading.** Run `claude plugin validate /path/to/drupilot` to check the manifest and component frontmatter.

---

## License

MIT. Note that the optional `dbuytaert/drupal-digests` rules are third-party, unlicensed, and are never bundled with this plugin — they are fetched at runtime into a local cache.
