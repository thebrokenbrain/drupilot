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
- [What's automatic vs. where the AI decides](#whats-automatic-vs-where-the-ai-decides)
- [Hands-off (autonomous) mode](#hands-off-autonomous-mode)
- [Configuration](#configuration)
- [Determinism (reproducible by default)](#determinism-reproducible-by-default)
- [Use cases](#use-cases)
- [How it works (architecture)](#how-it-works-architecture)
- [The drupal-digests complementary layer](#the-drupal-digests-complementary-layer)
- [Safety and conventions](#safety-and-conventions)
- [Troubleshooting](#troubleshooting)
- [Developing drupilot](#developing-drupilot)
- [License](#license)

---

## What it does

- **Viability assessment** — a non-destructive static analysis (Rector dry-run, PHPStan, PHPCS, optional Upgrade Status) that estimates how much of the work is auto-fixable vs. manual, classifies the hard breaks (Twig 3, CKEditor 5, jQuery UI, Symfony 7), checks `info.yml` and contrib-dependency D11 readiness, recommends a **core compatibility target** (`^11` vs `^10 || ^11`, the `require.php` it implies, and a SemVer version-bump verdict), and produces a markdown report plus a **staged port plan** with an S/M/L/XL effort verdict.
- **Minimal port (Phase 1)** — the smallest set of changes to make the module/theme run on Drupal 11 while **preserving the original functionality**. Driven by `palantirnet/drupal-rector`, an optional AI-rules layer (`dbuytaert/drupal-digests`), and targeted manual fixes.
- **Full refactor (Phase 2, opt-in)** — a rewrite to modern Drupal 11 best practices: PHP 8 attributes for plugins, dependency injection, strict types, zero deprecations, clean `Drupal` + `DrupalPractice`, and a green test suite.
- **Tests** — discovers, adapts and runs the complete PHPUnit suite (Unit / Kernel / Functional / FunctionalJavascript) inside DDEV (with Selenium for JS), iterating until green and reporting coverage. Failures are **never** silenced.
- **Contribution** — prepares and (optionally) publishes the result to Drupal.org via the modern issue-fork + Merge Request flow, or a legacy patch, with a **semi-automatic** (confirm every outward action) or **fully automatic** mode. It generates the **issue summary and the recommended values for the mandatory fields** (Title, Category, Priority, Version, Component, Assigned) to paste into the web form, plus a brief **comment**. A `.patch` is always produced alongside the MR and **verified to apply cleanly** onto the version it targets, so you (or anyone) can attach and apply it on the issue before the maintainer merges.
- **Patches, decoupled from contribution** — get the port's `.patch` any time with **`/drupilot-patch`**: offline, no push, no Drupal.org account. Choose a plain local-test patch (`MODULE-port-to-drupal-11.patch`) **or** one named with the issue-comment convention to attach to an issue and test now — and contribute the Merge Request later, as a separate step.
- **You stay in control** — the consequential decisions are **tabbed choices** (core target, PHP target, the digests rules to apply, refactor scope, push-or-not), with the recommendation pre-selected and your answers remembered per project. Nothing important happens silently.
- **Insight, not just output** — a per-port **report card** (`port-report.md`: what changed and why, the preservation verdict), a **dependency D11-readiness panel** (which contrib deps block the port), an **upstream issue search** (is someone already porting this?), and a **deprecation explainer** that turns cryptic output into a fix + a change-records link.

The default PHP target is **8.3** and is fully configurable; everything (Rector sets, PHPStan level, PHPCS sniffs, DDEV `php_version`) derives from a single setting. In-flow choices persist in a per-project `.drupilot.json` (read between environment variables and the defaults).

---

## Requirements

`drupilot` validates only what each operation needs, so you don't need Docker just to run a static analysis. Run `/drupilot-doctor` at any time for a per-platform status table and assisted installation.

| Operation | Hard requirements | Optional / soft |
| --- | --- | --- |
| **Analysis** (`assess`, static `port`) | `git`, `jq`, and `composer` or `php` ≥ target | — |
| **Environment & tests** (`setup`, `test`) | **Docker** (daemon running) + **DDEV** (a version with Drupal 11 support) | Selenium add-on (for FunctionalJavascript), disk space |
| **Contribution** (Drupal.org) | `git`, a drupal.org account + GitLab access, and an **SSH key** or a **PAT** | `glab`/`curl` for the GitLab API (degradable) |

DDEV provides the full Drupal environment (web + database + chromedriver) on top of Docker — **you do not need to set up a LAMP stack yourself**.

**Shell:** the scripts and hooks run on **bash ≥ 3.2** and do not assume GNU tools, so stock macOS (`/bin/bash` 3.2, BSD `sed`/`grep`) works as-is — no Homebrew bash or GNU coreutils needed. `/drupilot-doctor` reports the bash version it found.

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

### Pointing at a loose checkout

You don't need a Drupal site to start. Point drupilot at a bare module/theme checkout and it builds a Drupal 11 **test-bed in a sibling directory** `<parent>/<machine_name>-d11/`, placing the subject under `web/modules/custom/<machine_name>` (themes go to `web/themes/custom/...`). **Your original checkout stays pristine** — drupilot no longer scaffolds Drupal on top of it, so its files and `composer.json` are never intermixed.

```text
parent/
├── my_module/                 # your checkout — untouched
└── my_module-d11/             # the test-bed drupilot builds
    ├── .drupilot/             # visible, gitignored developer outputs
    └── web/modules/custom/my_module
```

How the subject gets there is controlled by `DRUPILOT_PLACEMENT` (`move` / `symlink` / `copy`); the test-bed location by `DRUPILOT_WORKSPACE_DIR` (see [Configuration](#configuration)). A module that is **already inside** a Drupal root keeps that layout in place — this only applies to loose checkouts.

**Origin hygiene.** Before placing, drupilot records the origin checkout's `git status` (hidden state, never in the tree); `scripts/env/origin-hygiene.sh --check` later reports any new untracked entry drupilot is responsible for (`.ddev/`, `vendor/`, `node_modules/`, `.phpstan-cache/`, generated config, patches, symlinks escaping the tree) — report-only, it never deletes anything — and the port report shows the result. A `copy` placement leaves local-environment residue behind (`.ddev/`, `vendor/`, `.drupilot*`, `.phpstan-cache/` at the top, `node_modules/` anywhere) and drops symlinks pointing outside the checkout (`--no-exclude` restores the verbatim copy). drupilot's own files inside your repo (the subject-side `.drupilot.json`, the local patch) are hidden through the repo's **local** `.git/info/exclude`, never its tracked `.gitignore`.

### The `.drupilot/` folder

Developer-facing outputs live in a single **visible, gitignored** `.drupilot/` directory at the Drupal root: the port **report card** (`port-report.md`), the **viability report** (`viability-report.md`), the test-coverage HTML, and the local `.patch`. It is gitignored automatically so it never lands in your patch, and you can point it elsewhere with `DRUPILOT_ARTIFACTS_DIR`. The machine-readable cache and the determinism lockfile deliberately stay **hidden under `$HOME`** so they can't leak into a patch.

---

## Commands

| Command | What it does |
| --- | --- |
| `/drupilot [subject] [full\|auto]` | **Router / guided flow.** Detects the current state (environment, last assessment, phase) and recommends the next step. `full` runs the whole flow with confirmations; `auto` runs it **hands-off** (see below). |
| `/drupilot-doctor [install]` | **Requirements check.** Per-platform status table (Docker + daemon, DDEV, git, composer/php, jq, SSH/PAT) with install instructions and optional assisted installation (with confirmation). |
| `/drupilot-setup` | Spins up a **Drupal 11 DDEV** site, installs the add-ons (`ddev-drupal-contrib`, Selenium) and the Composer dev toolchain (including `drupal/core-dev`, matched to the installed core, which provides PHPUnit), and writes `rector.php` / `phpstan.neon` / `phpcs.xml.dist` / test env from templates. Idempotent. |
| `/drupilot-assess [subject]` | Produces the **viability report** + staged plan with an S/M/L/XL verdict. |
| `/drupilot-port [subject]` | **Phase 1 minimal port.** Official Rector + (optional) digests rules filtered by target + ad-hoc fixes + minimal manual changes; leaves the code compiling with no blocking deprecations. |
| `/drupilot-refactor [subject]` | **Phase 2 full refactor** (opt-in): the "Drupal 11 way", PHPStan level 5–6, clean PHPCS. |
| `/drupilot-test [subject]` | Discovers, adapts and runs **all** test suites in DDEV (Selenium for JS); iterates to green; reports coverage. |
| `/drupilot-patch [subject] [issue]` | **Get the `.patch`, decoupled from contributing.** Offline, no push, no gate: a plain local-test patch, or one named for a Drupal.org issue comment. Test now, contribute the MR later. |
| `/drupilot-contribute [subject] [issue]` | Publishes to **Drupal.org**: issue fork + Merge Request (or legacy patch), in semi or auto mode. User-invocable only; never exposes the PAT. |
| `/drupilot-status` | Read-only summary of environment, PHP target, current phase, last assessment, test status (with the preservation verdict), the frozen reproducibility lock, and the suggested next step. |

---

## The two-phase porting philosophy

1. **Phase 1 — Minimal compatibility (default).** The smallest changes that make the module/theme work on Drupal 11 while respecting the original functionality and **not colliding** with what Drupal 11 already provides. Engine: `drupal-rector` + targeted manual fixes. No architectural changes.
2. **Phase 2 — "Drupal 11 way" refactor (opt-in).** A rewrite to modern best practices: PHP 8 attributes for plugins, dependency injection, strict typing, zero deprecations, zero PHPStan errors at the target level, full `Drupal` + `DrupalPractice` compliance, and complete tests in green.

A **viability assessment** always runs first as a decision gate. If the refactor is disproportionate (a configurable threshold), `drupilot` does not refuse — it still delivers a staged port plan that preserves the original functionality, and leaves the decision to you.

**How "respecting the original functionality" is verified.** The adapted test suite staying **green is the preservation gate** for both phases — that green is the evidence the behavior is preserved. Test adaptations only update a test's *form* (PHPUnit/Drupal API), never *what it verifies*; a behavioral regression is fixed in the code, never by relaxing a test. If the module ships **no tests**, `drupilot` reports preservation as **not verified** and recommends adding them — it does not fabricate them. If tests exist but cannot run (PHPUnit/`drupal/core-dev` missing, Selenium unreachable), it reports **not verified (blocked)** with the reason — never a false regression or a false "no tests".

---

## What's automatic vs. where the AI decides

drupilot splits the work in two. **Deterministic scripts** do the mechanical, repeatable work and measure the result; **the AI (Claude) supplies the judgment** — it reviews, decides what to apply, fixes whatever isn't mechanical, and chains the steps together. The consequential decisions are still yours to approve (the tabbed choices).

**Done by scripts, no AI:**

- *Change code:* official Rector (`palantirnet/drupal-rector`), the digests Rector layer (AI-authored rules, but run as a frozen, version-pinned config), `phpcbf` (auto-fixable coding-standards), and the `PostToolUse` hook (runs `phpcbf` on every Drupal file you edit).
- *Only measure / report:* `phpcs` (reports what `phpcbf` couldn't fix), PHPStan (deprecations + type errors), the preflight requirements gate, PHP/core detection, the dependency-readiness panel, the **port-safety checks** (`check-port-safety.sh`: a `create()` without `ContainerFactoryPluginInterface`/`ContainerInjectionInterface` in its real ancestry, a removed `use` still referenced, `new self(` in `create()`, closures under Form/Render API callback keys, `private`/`readonly` properties in serialized classes, `#[\Override]` while the core range spans Drupal 10, class-name case mismatches — each attributed to the port or pre-existing via git), the **core signature-change scan** (`scan-signature-changes.sh`: the module checked against a verified catalog of Drupal 10 → 11 signature changes at the lowest core it declares — a `ConfigFormBase`/`ContentTranslationController` subclass passing too few constructor arguments, a local `getOriginal()`/`setOriginal()`/`buildRevisionCacheId()` that core adds in 11.2/11.3, a `hook_entity_operation()`/`_alter()` requiring the parameter only 11.3 passes, an `#[\Override]` on a method older declared cores lack), the **deprecation classifier** (`classify-deprecations.sh`: splits PHPStan's deprecations into *hard* — removed in a major ≤ the target, e.g. `user_roles()` gone in 11.0 — and *soft* — removed only in a later major, e.g. `user_load_by_name()`/`text_summary()`/`check_markup()`, deprecated in 11.4 and removed from 13.0 — and says what `DRUPILOT_SOFT_DEPRECATIONS` does with each), and the patch and report generators. These **never touch your code**.

**Where the AI acts:**

- **Reviews each Rector dry-run** and decides whether to apply it — never applies blind.
- **Picks which digests rules to apply**, pre-flagging the ones that would silently raise your core floor.
- **Fixes what Rector doesn't cover** — generates an ad-hoc rule or edits by hand (`DRUPILOT_GENERATE_RULES`).
- **Makes the manual changes Rector can't** — `core_version_requirement`, `require.php`, Twig 3, CKEditor 5, jQuery UI.
- **Drives the validate loop** — reads what `phpcs` / PHPStan report and fixes it until clean.
- **Adapts the tests** to D11; on a behavioral failure it fixes the **code**, never the test.
- **Rewrites to the "Drupal 11 way"** in Phase 2 — attributes, dependency injection, strict types, deprecation removal.
- **Proposes the consequential decisions** (core target, refactor scope, contribute or not) — you choose.

**When the AI acts — the pattern.** The AI is the conductor: the scripts don't call each other. The AI runs one, reads its output, decides the next, and runs it. So it acts **before** every script (decide whether and how to run it) and **after** it (read the result and fix what's left), plus at the decision tabs. The single exception is the **`PostToolUse` hook**, which runs `phpcbf` on its own after each file edit — no AI in the loop.

**The hooks — automatic, triggered by the harness.** Hooks are deterministic scripts that **Claude Code itself fires on an event** — neither the AI nor you invoke them. The hook is the automation; the AI or you are the *recipients* of what it decides:

| Hook | When it acts | What it does | Output goes to |
| --- | --- | --- | --- |
| `session-detect-env` | session start | summarizes your environment + PHP target | the **AI** (as context) |
| `post-edit-lint` | after every file edit (Write/Edit) | runs `phpcbf` → **edits the file**, then reports what's left | the **AI** (to fix the rest) |
| `guard-contrib` | before every Bash command | detects an outward-facing `git push` / MR, or a `git commit` that skips the repository's active git hooks (`--no-verify` / `-n`) | **you** (asks for confirmation) |

So a hook is never AI and never a human decision in itself — it is the automation. `post-edit-lint` is the only piece that changes code entirely on its own; `guard-contrib` is an automation whose whole purpose is to put **you** back in the loop before anything leaves your machine. Toggle them with `DRUPILOT_POST_EDIT_LINT` and `DRUPILOT_SESSION_CONTEXT` (see [Configuration](#configuration)); the contribution guard always asks in `semi` mode and in any autonomous run.

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

Defaults live in `config/defaults.json`. **Every `DRUPILOT_*` key can be overridden by an environment variable of the same name** (the environment variable always wins). A per-project **`.drupilot.json`** at the Drupal root is read **between** the environment and the defaults — this is where the tabbed choices you make (core target, PHP target, refactor scope, contribute mode) are remembered so later runs don't re-ask. It is gitignored automatically so it never lands in a patch.

| Variable | Default | Effect |
| --- | --- | --- |
| `DRUPILOT_PHP_TARGET` | `8.3` | Target PHP version (drives Rector / PHPStan / PHPCS / DDEV). |
| `DRUPILOT_DRUPAL_TARGET` | `^11` | Target core range. |
| `DRUPILOT_CORE_TARGET_STRATEGY` | `auto` | Core compatibility decision: `auto` (keep `^10 \|\| ^11` while backwards-compatible, switch to `^11` on a BC break / refactor), `d11-only`, or `keep-d10`. Keeping D10 also declares a composer `require.php` floor (see `DRUPILOT_REQUIRE_PHP_FLOOR`), and the choice yields a SemVer version-bump verdict. |
| `DRUPILOT_KEEP_D10` | _(legacy)_ | Legacy boolean override of the strategy (`true` → keep D10, `false` → D11-only). Honored only when set; prefer `DRUPILOT_CORE_TARGET_STRATEGY`. |
| `DRUPILOT_REQUIRE_PHP_FLOOR` | `detect` | When keeping `^10 \|\| ^11`, how to set composer `require.php`: `detect` derives the real floor from a heuristic scan of the ported code (e.g. `>=8.1` when it uses no PHP 8.2/8.3 constructs, for genuine Drupal 10 support); `target` keeps the conservative `>=<php target>`. A lowered floor is best-effort — confirm with PHPCompatibility. |
| `DRUPILOT_PLACEMENT` | `move` | How a loose checkout is placed into the sibling test-bed: `move` relocates it (non-lossy — it stays a git repo at the new path), `symlink` keeps your checkout where it is and links it in (a target outside the test-bed is not visible inside the DDEV container, so `ddev exec` tooling cannot see it — use it for host-side work), `copy` duplicates it without local-environment residue (`.ddev/`, `vendor/`, `node_modules/`, …) or symlinks escaping the checkout. |
| `DRUPILOT_WORKSPACE_DIR` | _(empty)_ | Explicit path for the Drupal test-bed root. Empty means a sibling `<parent>/<machine_name>-d11`. |
| `DRUPILOT_ARTIFACTS_DIR` | _(empty)_ | Override for the visible `.drupilot/` outputs directory. Empty means `<root>/.drupilot`. |
| `DRUPILOT_DDEV_CREATE_TIMEOUT` | `900` | Seconds `/drupilot-setup` lets `ddev composer create-project` run before stopping it with a clear error (`0` = no limit). Needs `timeout` (or `gtimeout` on macOS); without it the step is unbounded. |
| `DRUPILOT_CODER_CONSTRAINT` | `^8.3` | `drupal/coder` branch (PHPCS 3.x vs 4.x). |
| `DRUPILOT_PHPSTAN_LEVEL` | `2` | Base PHPStan level (deprecation detection). |
| `DRUPILOT_PHPSTAN_LEVEL_REFACTOR` | `6` | PHPStan level used in the refactor phase. |
| `DRUPILOT_VIABILITY_THRESHOLD` | `medium` | Threshold for the "large refactor" warning. |
| `DRUPILOT_CONTRIB_MODE` | `semi` | `semi` (confirm outward actions) or `auto`. |
| `DRUPILOT_ISSUE_TITLE` | `Drupal 11 compatibility` | Default title for the generated Drupal.org issue. |
| `DRUPILOT_ISSUE_CATEGORY` | `Task` | Default issue Category (`bug report` / `task` / `feature request` / `support request` / `plan`). |
| `DRUPILOT_ISSUE_PRIORITY` | `Normal` | Default issue Priority (`critical` / `major` / `normal` / `minor`). |
| `DRUPILOT_ISSUE_COMPONENT` | `Code` | Default issue Component. The list is **project-specific** — verify it against the project's own components. |
| `DRUPILOT_ISSUE_ASSIGNEE` | `self` | `self` (assign to the account opening the issue) or `unassigned`. |
| `DRUPILOT_USE_DIGESTS_RULES` | `true` | Use the complementary `drupal-digests` layer after official Rector. |
| `DRUPILOT_DIGESTS_REF` | `main` | Commit/tag of the `drupal-digests` repo, for reproducibility. |
| `DRUPILOT_GENERATE_RULES` | `ask` | Generate ad-hoc Rector rules for uncovered deprecations: `ask` / `auto` / `off`. |
| `DRUPILOT_SOFT_DEPRECATIONS` | `report` | What Phase 1 does with *soft* deprecations — removed only in a later Drupal major, so they still work on every Drupal 11 core (e.g. `user_load_by_name()`, `text_summary()`, `check_markup()`: deprecated in 11.4.0, removed from 13.0.0): `report` (list them in the viability and port reports — symbol, deprecated in, removed in, effort — and leave the code alone), `defer` (list them under *deferred to Phase 2*) or `fix` (fix them when the replacement exists at the declared core floor, through `DeprecationHelper::backwardsCompatibleCall()` when it exists only on newer cores, else defer). *Hard* deprecations (removed in a major ≤ the target, e.g. `user_roles()`) are always fixed and only they count in the effort verdict; Phase 2 removes soft ones too. |
| `DRUPILOT_AUTONOMOUS` | `false` | Hands-off mode (same as the `auto` mode word): unattended setup→assess→port→refactor→test, writes the local patch, **never** contributes. See [Hands-off mode](#hands-off-autonomous-mode). |
| `DRUPILOT_DETERMINISTIC` | `true` | Reproducibility (default on): freeze the resolved Drupal core, dev toolchain, digests SHA and DDEV add-ons in a per-project `drupilot-lock.json` and reuse them on later runs. Set to `false` to resolve fresh every time and refresh the lock. See [Determinism](#determinism-reproducible-by-default). |
| `DRUPILOT_TOOLCHAIN_SOURCE` | `auto` | Where `install-toolchain.sh` takes the dev-toolchain versions from: `auto` (the project lock when it pins the whole known-good set, else the shipped known-good reference `config/toolchain-reference.json`; the `.packages` ranges when `DRUPILOT_DETERMINISTIC=false`), `reference` (always the known-good set — the repair path) or `range` (fresh resolve). |
| `DRUPILOT_POST_EDIT_LINT` | `autofix` | The PostToolUse incremental lint: `autofix` (run phpcbf + phpcs, and **say** when a file was modified), `report` (phpcs only, never edits files), or `off`. It is phase-aware — during Phase 1 it surfaces compatibility **errors** only, deferring style warnings to the refactor. It lints with the same ruleset `run-phpcs.sh` last resolved for the extension (see `DRUPILOT_PHPCS_RULESET`). |
| `DRUPILOT_PHPCS_RULESET` | `auto` | Which PHPCS ruleset `run-phpcs.sh` uses: `auto` (the subject's **own** `.phpcs.xml` / `phpcs.xml` / `.phpcs.xml.dist` / `phpcs.xml.dist`, looked up from the subject to the Drupal root, its git top level and the origin checkout of a copy placement — drupilot's generated `phpcs.xml.dist` never counts — else `Drupal,DrupalPractice`), `drupilot` (always `Drupal,DrupalPractice`, the pre-0.9 behavior) or a ruleset file path. A project ruleset PHPCS cannot load (e.g. it references PHPCompatibility, not installed in the test-bed) falls back to `Drupal,DrupalPractice` with a warning. `run-phpcs.sh --json` and `port-report.md` say which one was used. |
| `DRUPILOT_PHPCS_TEST_VERSION` | _(empty)_ | PHPCompatibility `testVersion` passed on every `run-phpcs.sh` run with `--runtime-set` (e.g. `8.1-`). Empty = `<DRUPILOT_PHP_TARGET>-`, except that a ruleset's own `<config name="testVersion">` is never overridden and a testVersion declared as a `<property>` inside a `<rule>` is passed through. |
| `DRUPILOT_HOOKS_GUARD` | `ask` | `ask`: the `guard-contrib` hook asks before a `git commit` that skips the repository's git hooks (`--no-verify`, `-n`, `git -c core.hooksPath=…`) where a pre-commit/commit-msg hook is really installed — in every contribution mode and in autonomous mode. `off` disables that check. It never denies and does not change the push/MR guard. |
| `DRUPILOT_SESSION_CONTEXT` | `on` | `on`/`off` toggle for the SessionStart environment summary. |
| `DRUPILOT_REFACTOR_SCOPE` | _(asked)_ | Persisted set of Phase 2 modernizations to apply (attributes / DI / strict types / final / deprecations). Normally chosen via the `/drupilot-refactor` multi-select and remembered in `.drupilot.json`. |
| `DRUPILOT_CHOICE_<KEY>` | — | Pre-answer a specific tabbed choice non-interactively (e.g. `DRUPILOT_CHOICE_CORE_TARGET`), so it is not asked. |

Other useful environment variables: `DRUPILOT_GITLAB_PAT` (your GitLab Personal Access Token, read only at runtime, never persisted), `DRUPILOT_ASSUME_YES=1` (skip confirmations in non-interactive runs), `NO_COLOR=1`.

Example — target PHP 8.4 and drop Drupal 10 support for one session:

```bash
export DRUPILOT_PHP_TARGET=8.4
export DRUPILOT_CORE_TARGET_STRATEGY=d11-only   # ^11 only (drops Drupal 10)
```

---

## Determinism (reproducible by default)

Porting the same module twice should yield the same result. drupilot is **deterministic by default** (`DRUPILOT_DETERMINISTIC=true`): the first time it resolves the moving parts of a port it **freezes** them in a per-project `drupilot-lock.json` (kept in drupilot's state dir, not your project tree) and **reuses** them on later runs:

- the exact **Drupal core** version and the **dev-toolchain** versions (`drupal-rector` and its engine `rector/rector`, PHPStan + extensions, `coder`/PHPCS, Drush, `drupal/core-dev`) read from the generated `composer.lock`;
- the **digests commit (SHA)** that the `main` branch resolved to — so the AI-generated rule layer stays fixed for the project even though its default ref is still `main`;
- the installed **DDEV add-on** versions.

It works like a `composer.lock`: the version ranges in `config/defaults.json` stay flexible, but the lock pins exactly what was used. `scripts/env/lock-sync.sh` captures/updates it (`ddev-up.sh`, `ddev-add-ons.sh` and `install-toolchain.sh` call it automatically).

**Known-good reference set.** A project that has no lock yet does not resolve the toolchain ranges fresh: `scripts/env/install-toolchain.sh` installs the **known-good matrix** shipped with the plugin, `config/toolchain-reference.json` — exact versions of `drupal-rector`, `rector/rector`, PHPStan + extensions, `coder`, Drush and `upgrade_status` verified together end to end. So a brand-new test-bed created after a broken upstream release (for example `rector/rector` 2.6.2+, which makes `drupal-rector` 0.21 crash) still gets a working set. Every install ends with a **smoke test** (a Rector dry-run with the Drupal 10 set plus `phpstan --version`) and exits 3 with the installed vs known-good versions when the toolchain is broken.

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

### 6. Get the patch — test locally now, contribute later

```text
/drupilot-patch web/modules/custom/my_module
```

Writes `MODULE-port-to-drupal-11.patch` next to the module — offline, no push, no Drupal.org account. Apply it on another checkout with `git apply`. The patch is diffed against your branch's **fork point** — its upstream when it has one; otherwise the closest of `origin/HEAD`, the other remote branches and the nearest tag (e.g. a local branch cut from a release tag) — so it holds exactly the port, committed or not; pass `--base` to choose. It is kept out of `git status` through the repo's local `.git/info/exclude`. Want to attach it to an issue and validate it there before opening a Merge Request? Pass the issue id for an issue-comment-named patch:

```text
/drupilot-patch web/modules/custom/my_module 3456789
```

This is fully **decoupled from contributing**: the upstream Merge Request (which rebases and hard-verifies the patch against `origin/BASE`) stays a separate, opt-in step you run with `/drupilot-contribute` when you are ready.

### 7. Contribute the fix back to Drupal.org

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

When the issue still has to be created, it generates the **issue summary** (the standard Drupal.org template — for a behavior-preserving port only the sections that apply: Problem/Motivation, Proposed resolution, Remaining tasks) and the recommended **field values** (Title, Category `Task`, Priority `Normal`, Version derived from the base branch, Component `Code`, Assigned to you), since the issue can only be created on the web. It then creates the issue fork, branch and commit (in the correct format, detecting the project's convention), pushes, opens the Merge Request — with a brief generated **comment** as its description — via the GitLab API, **degrading gracefully** to a one-click MR URL if the API is blocked. It **always writes a `.patch`** (`MODULE-port-to-drupal-11-ISSUEID-COMMENT.patch`) and **verifies it applies cleanly** onto the version it targets (discarding a patch that does not apply, so you never hand over a broken one) to attach to the issue alongside the MR with the comment. It reminds you that **credit is assigned by the maintainers** via the issue's Contribution Record, and it never exposes your PAT.

---

## How it works (architecture)

- **Commands** (`commands/*.md`) are the entry points. Each gates its own requirements via the preflight engine before doing anything.
- **Skills** (`skills/*/SKILL.md`) carry the reusable operating knowledge (DDEV environment, viability assessment, minimal port, full refactor, test adaptation, PHP-target tuning, Drupal contribution).
- **Subagents** (`agents/*.md`) are specialists the commands delegate to: `drupal-port-orchestrator`, `drupal-viability-analyst`, `drupal-test-engineer`, `drupal-contrib-publisher`.
- **Hooks** (`hooks/hooks.json`):
  - `SessionStart` → a lightweight environment detector that summarizes your PHP target and readiness (silence it with `DRUPILOT_SESSION_CONTEXT=off`).
  - `PostToolUse` (Write|Edit) → incremental `phpcbf` + `phpcs` on edited Drupal files; **phase-aware** (Phase 1 surfaces compatibility errors only) and controllable via `DRUPILOT_POST_EDIT_LINT` (`autofix`/`report`/`off`), and it tells you when it modified a file.
  - `PreToolUse` (Bash) → asks for confirmation before any outward-facing git push / MR action in `semi` mode, and **always** in an autonomous run (which must never push on its own); it also asks before a `git commit` that skips the repository's active git hooks (`DRUPILOT_HOOKS_GUARD`).
- **Scripts** (`scripts/`) are a robust, idempotent shell library: a shared `lib/common.sh`, the `env/preflight.sh` requirements engine, and the `analysis/`, `tests/` and `contrib/` wrappers the skills and commands invoke.
- **Templates** (`templates/`) are parameterized configs (`rector.php`, `phpstan.neon`, `phpcs.xml.dist`, DDEV config + test environment, report templates) tuned by the PHP target.

See **[FLOW.md](FLOW.md)** for a visual, end-to-end diagram of the flow — which tool runs at each step, where the AI steps in, and the two porting phases.

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
- **Final verification** before a module is considered done: a compatible `info.yml`, `phpstan` with no deprecations at the target level, a clean `run-phpcs.sh` (against the subject's own PHPCS ruleset when it ships one, else `Drupal,DrupalPractice`), `check-port-safety.sh` and `scan-signature-changes.sh` with no error findings, and the applicable test suite green.
- **The repository's git hooks are honored, never skipped as a habit.** Before a commit, `scripts/contrib/git-hooks.sh` detects GrumPHP, husky, lefthook, pre-commit, CaptainHook, `core.hooksPath` and `.git/hooks` scripts, and the flow lets them run. Only when a hook cannot complete in the session does it run the hook's tasks separately (`git-hooks.sh --run-equivalents`: phpcs, PHPStan, `php -l`, `composer validate`, and PHPUnit with `--with-tests`, through DDEV) and record in `port-report.md` which validations replaced the hook and which tasks had no equivalent.
- **Rector is not trusted blindly.** The generated `rector.php` skips the PHP-modernization rules that broke real ports (Form API callbacks turned into closures, `#[\Override]` judged against the sandbox core only, `readonly` properties, `(string)` casts); none of them is needed for Drupal 11 compatibility.

---

## Troubleshooting

- **A command says a hard requirement is missing.** Run `/drupilot-doctor` — it shows exactly what is missing, the detected vs. required version, and the install command for your platform.
- **Docker is installed but commands still fail.** The daemon must be running (`sudo systemctl start docker` on Linux, or launch Docker Desktop). `drupilot` checks the daemon, not just the binary.
- **`run-phpunit.sh` exits 2 with "PHPUnit is not installed" (preservation `not-verified-blocked`).** The Drupal root has no `vendor/bin/phpunit`: `drupal/recommended-project` does not ship it. Install `drupal/core-dev` matching your core — the script prints the exact command, e.g. `ddev composer require --dev "drupal/core-dev:~11.4.8" -W` — and re-run. Environments set up by drupilot 0.8.4 or earlier never installed it.
- **FunctionalJavascript tests are skipped.** Install the Selenium add-on: `ddev add-on get ddev/ddev-selenium-standalone-chrome && ddev restart`.
- **A spurious `web/modules/custom/<project>/` symlink folder appears after `ddev restart`.** `ddev-drupal-contrib`'s `symlink-project` hook does this in the recommended-project layout; `ddev-add-ons.sh` disables it in `.ddev/config.contrib.yaml`. That file is `#ddev-generated`, so a later `ddev add-on get ddev/ddev-drupal-contrib` restores the hook — re-run `/drupilot-setup` (or `ddev-add-ons.sh --contrib`) afterwards.
- **The GitLab API is blocked.** Expected — drupalcode's API is restricted by default. `drupilot` degrades to a one-click MR URL; just open it to create the MR.
- **Plugin not loading.** Run `claude plugin validate /path/to/drupilot` to check the manifest and component frontmatter.
- **`phpcs` at the Drupal root fails with "Ruleset … is not valid … Comment must not contain '--'", or PHPStan prints "The drupal_root parameter is deprecated".** Your `phpcs.xml.dist` / `phpstan.neon` were generated by drupilot 0.8.4 or earlier. Regenerate them (the old copies are backed up under `.drupilot/backups/`): `bash "$CLAUDE_PLUGIN_ROOT/scripts/env/render-templates.sh" --root <drupal_root> --subject-path web/modules/custom/<name> --only phpstan,phpcs --force`. Without `--force` it only shows the diff.
- **Rector fails with "[ERROR] Could not detect twig set." (or `MissingPrivatePropertyException … RichParser`), or `run-rector.sh` / `install-toolchain.sh` exit 3.** The installed toolchain is an incompatible combination: `palantirnet/drupal-rector` 0.21 needs `rector/rector` < 2.6.2, and `rector/rector` 2.5.x needs PHPStan 2.2.2. drupilot 0.8.4 and earlier resolved the ranges fresh and could install exactly that, and reported the crash as "0 files would change". Reinstall the known-good set (this also refreshes the lock): `bash "$CLAUDE_PLUGIN_ROOT/scripts/env/install-toolchain.sh" --dir <drupal_root> --source reference`. `run-rector.sh` now reports a crash as `status: "error"` (exit 3) — never as a result. If the toolchain already matches the known-good set, the problem is the Rector config: regenerate `rector.php` with `render-templates.sh --only rector --force`.
- **`run-rector.sh --digests` exits 4 (`status: "partial"`, `digests_status: "error"`), e.g. `[ERROR] Expected an existing class name. Got: "…Rector"`.** Only the AI-generated digests pass crashed — typically a broken rule file in an upstream `drupal-digests` commit. The official pass result stands and the toolchain is fine, so do not reinstall it. Pin a known-good digests commit (`--digests-ref <sha>` or `DRUPILOT_DIGESTS_REF=<sha>`) or skip the layer (`DRUPILOT_USE_DIGESTS_RULES=false`). A digests SHA is frozen in the lockfile only after its pass finishes normally, so a broken commit is never pinned.
- **Rector turned `[$this, 'method']` Form API callbacks into `$this->method(...)`, or added `#[\Override]`, `readonly` or `(string)` casts.** Your `rector.php` predates the risky-rule skip list. `run-rector.sh` regenerates a `rector.php` written by an older drupilot template on its next run (the old copy goes to `.drupilot/backups/`); a hand-written one is left alone with a warning — add the skips from `templates/rector.php.tmpl`. Then revert the converted hunks; `check-port-safety.sh` lists them.
- **`check-port-safety.sh` exits 3.** It found error findings — e.g. a plugin whose `create()` lost `implements ContainerFactoryPluginInterface` (`QueueWorkerBase`, `BlockBase`, `FilterBase`, `ActionBase`, `ConditionPluginBase` do not provide it), `new self(` in `create()`, a closure under `#submit`/`#ajax`/..., or a `readonly`/`private` property in a form or plugin. Each line says the file, line, fix, and whether the port introduced it; fix them and re-run. If the port is already committed, pass `--base <pre-port ref>` so findings are attributed correctly.
- **`scan-signature-changes.sh` exits 3.** The module collides with a core signature change inside the core range it declares — e.g. `parent::__construct($config_factory)` in a `ConfigFormBase` subclass (Drupal 11 requires `TypedConfigManagerInterface` too: forward `$container->get('config.typed')`, which older 10.x cores simply ignore), an entity `getOriginal()` without `: ?static` (fatal on 11.2+), or a `hook_entity_operation()` that requires `$cacheability` while you still declare cores below 11.3 (make it `?CacheableMetadata $cacheability = NULL`). Each finding carries the fix and the Drupal 10-compatible way; the severity follows the declared floor (`^10 || ^11` → 10.0), and `--core-floor X.Y` judges at another one.
- **PHPStan still lists `user_load_by_name()` (or `text_summary()`, `check_markup()`) after the port.** That is a *soft* deprecation: deprecated in 11.4.0, removed from 13.0.0, so it works on every Drupal 11 core, and the default `DRUPILOT_SOFT_DEPRECATIONS=report` deliberately leaves it in place and lists it in `port-report.md`. Set it to `fix` (or run `/drupilot-refactor`) to replace it; drupilot then keeps the declared core floor working — e.g. the `TextSummary` service exists only from 11.4, so with `^10 || ^11` it goes through `DeprecationHelper::backwardsCompatibleCall()`. A *hard* one (removed in 11.0, e.g. `user_roles()`, reported as "Function user_roles not found.") always blocks Phase 1.
- **PHPCS fails with "trim(): Passing null to parameter #1" from a `PHPCompatibility` sniff (often reported as "An error occurred during processing").** The ruleset uses PHPCompatibility but leaves its `testVersion` config unset — typically because it declares `testVersion` as a `<property>` inside `<rule ref="PHPCompatibility">`, which PHPCompatibility does not read. `run-phpcs.sh` always passes `--runtime-set testVersion` (the ruleset's property value, or `<DRUPILOT_PHP_TARGET>-`), so it does not hit this; when you run `phpcs` by hand, add `--runtime-set testVersion 8.3-`, or fix the ruleset with `<config name="testVersion" value="8.3-"/>`.
- **`run-phpcs.sh` warns "Project PHPCS ruleset … cannot be used" and falls back to Drupal,DrupalPractice.** The subject's own ruleset references a standard or sniff the test-bed does not have (e.g. `Referenced sniff "PHPCompatibility" does not exist`). Install it in the Drupal root (e.g. `ddev composer require --dev phpcompatibility/php-compatibility`) to lint with the project's rules, or set `DRUPILOT_PHPCS_RULESET=drupilot` to use drupilot's default on purpose.
- **A `git commit` asks for confirmation about "skips the repository's git hooks".** The command used `--no-verify`/`-n` in a repository with an installed pre-commit or commit-msg hook. Let the hook run (give it a longer timeout), or, if it really cannot run here, run `scripts/contrib/git-hooks.sh --subject <dir> --run-equivalents` first and keep its record for the port report. `DRUPILOT_HOOKS_GUARD=off` disables the check.
- **`run-phpstan.sh` exits 3.** PHPStan crashed or could not analyse (invalid configuration, missing path, fatal error), so there is no verdict; the cause is printed on stderr (and in `drupilot.crash` with `--json`). Fix it and re-run — it is not a count of findings.

---

## Developing drupilot

Run the developer gate before every commit to the plugin itself:

```bash
bash scripts/dev/check.sh          # human report; exit 0 ok / 1 a gate failed
bash scripts/dev/check.sh --json   # machine-readable per-gate summary
```

It validates the plugin manifest, syntax-checks and `shellcheck`s every script, checks the executable bits, rejects bash 4-only / GNU-only constructs (`${x,,}`, `declare -A`, `sed -i`, `readlink -f`, ... — the scripts must run on stock macOS bash 3.2), rejects bash special variables used as plain variables (`GROUPS`, `RANDOM`, `SECONDS`, `UID`, ... — bash silently ignores such assignments), rejects `<placeholder>` literals inside load-time `` !`...` `` lines of commands/skills/agents, checks that the rendered XML templates are well-formed, and validates every JSON file. Optional tools (`claude`, `shellcheck`, `xmllint`) are skipped when absent (`--ci` makes them mandatory). See `--help` for `--only`/`--skip`/`--allow-known`.

---

## License

MIT. Note that the optional `dbuytaert/drupal-digests` rules are third-party, unlicensed, and are never bundled with this plugin — they are fetched at runtime into a local cache.
