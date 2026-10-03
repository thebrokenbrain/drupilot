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
- **Many modules, in order** — **`/drupilot-layers`** takes a whole set (a monorepo's `web/modules/custom`, a folder of modules), computes the **porting layers** from the declared dependencies *and* the ones the code really uses (classes, services, routes, libraries, plugins), reports dependency cycles and **undeclared dependencies** with the `dependencies:` entry to add, and ports layer by layer through the normal flow with a consolidated report per layer.
- **Pre-existing hygiene, reported** — a metadata lint flags config without schema, a `configure:` route that does not exist, orphan services, service arguments that do not match the constructor, submodules left on an obsolete `core_version_requirement` and undeclared dependencies. It is listed in the viability and port reports and never changes the effort verdict. Phase 1 fixes only the submodules' core requirement, which it bumps together with the main `info.yml`.
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

**Health checks.** Besides the requirements, `/drupilot-doctor` runs `preflight.sh --extended`, a set of report-only checks for known pitfalls (they never block a command): `xmllint` present, the `sed` flavour, a well-formed `phpcs.xml.dist` and a `phpstan.neon` without the deprecated `drupal_root` at the Drupal root, the installed dev toolchain against the known-good reference in `config/toolchain-reference.json` (read from `composer.lock`, with a warning for a known-broken combination such as the one behind "Could not detect twig set"), free disk space (`requirements.disk_free_min_mb`, 5 GB by default) and drupilot or DDEV residue in your module's original checkout. Run it from the module or the Drupal root. The JSON (`--extended --json`) adds rows with `category: "health"` and a `toolchain` object; the existing keys are unchanged.

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

Developer-facing outputs live in a single **visible, gitignored** `.drupilot/` directory at the Drupal root: the port **report card** (`port-report.md`), the **viability report** (`viability-report.md`), the test-coverage HTML, the local `.patch`, the consolidated layer reports (`layer-N-report.md`), the **decision log** (`decisions.md`, with its machine twin `decisions.jsonl`) and the **learned-pattern catalog** (`patterns.json`). It is gitignored automatically so it never lands in your patch, and you can point it elsewhere with `DRUPILOT_ARTIFACTS_DIR`. The machine-readable cache and the determinism lockfile deliberately stay **hidden under `$HOME`** so they can't leak into a patch.

### Decision log

Every place a port does not keep what a tool produced, or does not follow the flow, is recorded the moment it happens by `scripts/analysis/log-decision.sh`, with **what** and **why**: a Rector change reverted or rewritten by hand, a script's verdict overridden, a step skipped, a fix made after validation or the tests caught a problem, a test whose form changed, a pre-existing bug left unfixed, a behavior change a reviewer must check. Each entry is one JSON line in `.drupilot/decisions.jsonl` (one log per Drupal root; every entry names its module), and `decisions.md` beside it is regenerated as a table per module. The port report and the layer report merge these entries with the port manifest's structured fields (`rector_rules`, `rector_reversions`, `post_port_fixes`, `preexisting_bugs`, `behavior_changes`, `tooling_deviations`, `validation`), so reverted Rector rules and post-port fixes add up across modules and layers. `log-decision.sh --subject <dir> --list` prints a module's entries.

### Learned patterns

The same pitfalls tend to come back module after module. drupilot keeps one **catalog of learned patterns** per project, `.drupilot/patterns.json` at the Drupal root (`scripts/analysis/patterns.sh`). Each entry is a pitfall an earlier port hit: a **detector** (a POSIX ERE run over the source, and/or a deterministic rule such as `port-safety:fapi-callable` or `signature:entity-get-original` that reuses `check-port-safety.sh` / `scan-signature-changes.sh`), the **fix** that worked, why it was needed, the module and layer it was learned from, and how many times it was recorded (`hits`).

- **Before** a port or a refactor, `patterns.sh scan --subject <dir>` runs every detector on the untouched module; each hit becomes a must-check item, so the pitfall is prevented instead of repaired.
- **At the end**, `patterns.sh harvest` lists candidates (the reverted Rector changes and post-port fixes of the manifest and the decision log), you pick which ones to keep, and `patterns.sh add` records them. An existing id is updated in place: its `hits` go up and the module is added to `seen_in`. Autonomous runs record only detectors they checked and list them for review.
- `/drupilot-layers` shares one catalog for the whole set, so what layer N learned is checked on layer N+1, even with one test-bed per module.
- `patterns.sh export` prints entries in `config/deprecations.json` format, ready to propose upstream (without the module names unless `--with-source`).

The catalog is plain JSON, meant to be read and edited by hand (`patterns.sh list`, `patterns.sh remove --id <id>`). Like the rest of `.drupilot/`, it is gitignored. Point `DRUPILOT_PATTERNS_FILE` at a committed file to share it with a team.

### Per-module state

drupilot keeps one record per module/theme, `state.json`, in the same hidden state dir as `assess.json` and `last-test.json`: which stages were reached and when, and a snapshot of what a portfolio view needs. It is machine state, so it is hidden on purpose: it survives `git clean` or a rebuilt test-bed (otherwise the next step would restart at `/drupilot-port`), it can never leak into a patch, and one data dir holds every module's record, so `/drupilot-status --all` finds them all without walking your project trees. The visible `.drupilot/` folder keeps the human-facing reports; the record is rendered on demand.

The record is written by the flow, not by memory: `port-report.sh` records `ported` / `refactored` (from the manifest's phase), `run-phpunit.sh` records `tested` after a verified whole-suite run and carries every recorded run's verdict, `verify-core-matrix.sh` and `make-patch.sh` add their verdict and patch, and `/drupilot-setup`, `/drupilot-assess` and `/drupilot-contribute` record `setup`, `assessed` and `contributed` through `scripts/env/state.sh record`. `next-step.sh` (the router and `/drupilot-status`) and the post-edit hook read it.

| Key | Meaning |
| --- | --- |
| `schema` | Record version (`1`). |
| `subject`, `machine_name`, `type` | The module/theme directory (absolute), its machine name and type. |
| `drupal_root`, `ddev_project` | The test-bed (workspace) it lives in and its DDEV project name. |
| `origin`, `placement` | The developer's checkout a loose subject was placed from, and how (`move` / `symlink` / `copy`). |
| `stage`, `stages` | The highest stage reached (`setup` < `assessed` < `ported` < `refactored` < `tested` < `contributed`; it never goes down without `DRUPILOT_STATE_FORCE`), and the time each stage was last recorded. |
| `effort`, `assessed_at` | The assessment's S/M/L/XL verdict and when it was made. |
| `git` | `branch`, `commit` and `dirty` (uncommitted changes) of the subject's checkout. |
| `toolchain` | From the lock: `drupal_core`, `php_target`, `core_strategy`, `packages` (Rector, drupal-rector, PHPStan, coder, Drush, core-dev versions). |
| `tests` | The last recorded PHPUnit run: `status`, `preservation`, `executed`, `tests_failed`, group counts, `recorded_at`, and `fresh` (computed on the current sources). |
| `core_matrix` | The last core matrix: `verdict`, `d10_support`, `generated_at`, `fresh`. |
| `patch` | The last patch made: `path`, `kind` (`local` / `issue` / `contribution`), `at`. |
| `portfolio` | Set when the module is ported by `/drupilot-layers`: `dir` (the set) and `layer` (its porting layer), written by `state.sh record\|refresh --portfolio DIR --layer N`. |
| `created`, `updated`, `drupilot_version` | Record timestamps and the drupilot that last wrote it. |

```bash
scripts/env/state.sh show --subject web/modules/custom/foo        # one module, merged with the current verdicts
scripts/env/state.sh list --root ~/drupal-ports --json            # every module under a directory of workspaces
scripts/env/state.sh list --registry ports.txt                    # one path per line (module dirs or dirs to scan)
scripts/env/state.sh record --subject web/modules/custom/foo --stage assessed --effort M
scripts/env/state.sh refresh --subject web/modules/custom/foo --portfolio web/modules/custom --layer 2
```

`show` and `list` are read-only (they never create a state dir); the table goes to stderr and `--json` puts the payload on stdout. A module ported before this record existed is still listed by `--root` or `--subject`, its stage derived from its older records.

### Cleaning up test-beds

A test-bed holds a DDEV project (containers, volumes, a database) and a few hundred MB of Composer trees. `/drupilot-clean` (`scripts/env/clean.sh`) frees them **without losing the work**: the `.drupilot/` reports, the hidden state (`state.json`, `assess.json`, the lockfile), the local patches and the module's git checkout with all its branches are always kept. It shows the plan first and acts only after you confirm (`--yes` in a script; `DRUPILOT_ASSUME_YES` and autonomous mode never imply it).

| Level | Removes |
| --- | --- |
| `ddev` | The DDEV project: `ddev delete -Oy` (containers, volumes, database; no snapshot). The code and `.ddev/` stay. |
| `vendor` (default) | Also `vendor/` and every Composer installer path (core, contrib, libraries, recipes); never a `*/custom` path. |
| `workspace` | Also the whole test-bed. A `move`d module is first moved back to the path it came from (refused if that path is no longer empty), a `symlink` is only unlinked, and a `copy` is discarded only when it holds nothing its origin lacks (same commit, clean tree) or with `--discard-copies`. The test-bed's `.drupilot/` reports are copied to the module's own `.drupilot/` first. |

It only removes `vendor/` or a workspace from a **drupilot test-bed**: a root `ddev-up.sh` built, which it marks in the root's `.drupilot.json` (`drupilot_testbed`, with the origin of every module `place-subject.sh` placed). A test-bed built before that marker existed is recognized by its default `<name>-d11` name and its `DRUPILOT_WORKSPACE_DIR`. On any other Drupal root (your own site) only `--level ddev --foreign-ok` is possible, and it asks again because it deletes that site's database. `--all` cleans every test-bed drupilot has state for (plus those under `--scan DIR`); `--core-cache` also drops the cached base cores.

```bash
scripts/env/clean.sh --subject web/modules/custom/foo --dry-run           # the plan (vendor level)
scripts/env/clean.sh --subject ../foo --level workspace --yes --json      # remove the whole test-bed, move foo back
scripts/env/clean.sh --all --scan ~/drupal-ports --level ddev --dry-run   # every test-bed's DDEV project
```

Afterwards each module's `state.json` records `environment: {status: "removed", level}`, and the next step is `/drupilot-setup`, which rebuilds what was removed: `ddev-up.sh` runs `ddev composer install` when `composer.json` is there but `vendor/` is not, and creates a removed workspace again with the core version the lockfile froze.

**Cached base core.** After a fresh `composer create-project`, `ddev-up.sh` keeps the resulting tree (Composer files, `vendor/`, core, `recipes/`; never `.ddev/`, `settings*.php` or `files/`) in drupilot's data dir, keyed by PHP target and exact core version. The next setup of an empty root copies it in (copy-on-write where the filesystem supports it: `cp --reflink=auto` on btrfs/XFS, `cp -c` on APFS; else a plain copy), then checks it with `ddev composer install`; if that fails, the entry is discarded and the setup runs `create-project` as before. In the lab (DDEV 1.25, Drupal 11.4.8, btrfs, Composer's download cache already warm), `ddev-up.sh` took about 30 s with `create-project` and 20 s from the cache (the copy itself took under 1 s; a plain copy of the 174 MB tree takes about 1.5 s). DDEV's shared Composer cache already avoids the downloads, so the gain is the install and scaffold work. Control it with `DRUPILOT_CORE_CACHE` (see [Configuration](#configuration)). `/drupilot-layers` already offers one shared test-bed for a whole set (`DRUPILOT_LAYERS_SANDBOX=shared`); one shared sandbox per *layer* is not implemented.

---

## Commands

| Command | What it does |
| --- | --- |
| `/drupilot [subject] [full\|auto\|status\|next] [--no-confirm] [--workspace DIR] [--json]` | **Router / guided flow.** Detects the current state (environment, last assessment, phase) and recommends the next step. `full` runs the whole flow with confirmations; `auto` runs it **hands-off** (see below). The flag words are for wrappers: see [Running under another tool](#running-under-another-tool-non-interactive-contract). |
| `/drupilot-doctor [install]` | **Requirements check.** Per-platform status table (Docker + daemon, DDEV, git, composer/php, jq, SSH/PAT) with install instructions and optional assisted installation (with confirmation), plus report-only [health checks](#requirements) (generated configs, toolchain vs known-good, disk space, origin residue). |
| `/drupilot-setup` | Spins up a **Drupal 11 DDEV** site, installs the add-ons (`ddev-drupal-contrib`, Selenium) and the Composer dev toolchain (including `drupal/core-dev`, matched to the installed core, which provides PHPUnit), and writes `rector.php` / `phpstan.neon` / `phpcs.xml.dist` / test env from templates. Idempotent. |
| `/drupilot-assess [subject]` | Produces the **viability report** + staged plan with an S/M/L/XL verdict. |
| `/drupilot-port [subject]` | **Phase 1 minimal port.** Official Rector + (optional) digests rules filtered by target + ad-hoc fixes + minimal manual changes; leaves the code compiling with no blocking deprecations. |
| `/drupilot-refactor [subject]` | **Phase 2 full refactor** (opt-in): the "Drupal 11 way", PHPStan level 5–6, clean PHPCS. |
| `/drupilot-test [subject]` | Discovers, adapts and runs **all** test suites in DDEV (Selenium for JS); iterates to green; reports coverage. |
| `/drupilot-patch [subject] [issue]` | **Get the `.patch`, decoupled from contributing.** Offline, no push, no gate: a plain local-test patch, or one named for a Drupal.org issue comment. Test now, contribute the MR later. |
| `/drupilot-contribute [subject] [issue]` | Publishes to **Drupal.org**: issue fork + Merge Request (or legacy patch), in semi or auto mode. User-invocable only; never exposes the PAT. |
| `/drupilot-layers <dir> [plan\|run] [--layer N]` | **Port a set of modules in dependency order.** `plan` (read-only, the default) shows the porting layers, the dependency cycles, and the undeclared dependencies with a proposed `<project>:<module>` entry and the evidence. `run` ports one layer, module by module, through the normal flow, then writes a consolidated `layer-N-report.md`. It never edits an `info.yml` without your confirmation and never contributes. |
| `/drupilot-clean [subject] [--all] [--level ddev\|vendor\|workspace]` | **Free a test-bed's disk and Docker resources, keep the work.** Deletes the DDEV project, the Composer trees or the whole derived workspace (moving the module back), only on test-beds drupilot built; previews and asks first. User-invocable only. See [Cleaning up test-beds](#cleaning-up-test-beds). |
| `/drupilot-status [subject] \| --all [dir\|file]` | Read-only summary of environment, PHP target, current phase, last assessment, test status (with the preservation verdict), the frozen reproducibility lock, and the suggested next step. `--all` tabulates every module/workspace drupilot has state for (see [Per-module state](#per-module-state)). |

---

## The two-phase porting philosophy

1. **Phase 1 — Minimal compatibility (default).** The smallest changes that make the module/theme work on Drupal 11 while respecting the original functionality and **not colliding** with what Drupal 11 already provides. Engine: `drupal-rector` + targeted manual fixes. No architectural changes.
2. **Phase 2 — "Drupal 11 way" refactor (opt-in).** A rewrite to modern best practices: PHP 8 attributes for plugins, dependency injection, strict typing, zero deprecations, zero PHPStan errors at the target level, full `Drupal` + `DrupalPractice` compliance, and complete tests in green.

A **viability assessment** always runs first as a decision gate. If the refactor is disproportionate (a configurable threshold), `drupilot` does not refuse — it still delivers a staged port plan that preserves the original functionality, and leaves the decision to you.

**How "respecting the original functionality" is verified.** The adapted test suite staying **green is the preservation gate** for both phases — that green is the evidence the behavior is preserved. Test adaptations only update a test's *form* (PHPUnit/Drupal API), never *what it verifies*; a behavioral regression is fixed in the code, never by relaxing a test. If the module ships **no tests**, `drupilot` reports preservation as **not verified** and recommends adding them — it does not fabricate them. If tests exist but cannot run (PHPUnit/`drupal/core-dev` missing, Selenium unreachable), it reports **not verified (blocked)** with the reason — never a false regression or a false "no tests".

**Pre-existing failures are not regressions.** Before Rector touches the code, `/drupilot-port` records the suite as a **baseline** (`run-phpunit.sh --baseline`; `--baseline-from-last` promotes the last run, e.g. before a refactor). Every later run compares each failing test with it: a test that failed before **and** after the port is **pre-existing**, a test that passed before and fails now is a **regression**. A failing test the baseline never *meaningfully* ran is **not baselined**: its group crashed in the baseline, or its baseline failure was only Drupal 11 refusing the un-ported module ("module 'x' is incompatible with this version of Drupal core"). Such a failure may be a regression, so it is never counted as pre-existing, and it makes the verdict **not-verified-unbaselined** (not green, exit 3). When every failure truly pre-exists, the verdict is **pre-existing failures**. That is not green and proves nothing, so the failures are listed in `port-report.md`, and one that now fails with a different message is flagged for review. A group in which PHPUnit executed no test counts as empty, never as passed.

**New tests must be able to fail (negative controls).** Every test drupilot writes (Phase 2, or a regression test for a fix) gets a negative control: `scripts/tests/negative-control.sh` undoes the production change the test guards (`--revert-to REF --path FILE`, or a minimal `--mutation-patch`), requires the test to go **red**, restores the code and checks it is byte-identical (`git hash-object`), then requires it to go **green** again. A test that stays green without its change is **ineffective** and gets strengthened, never accepted. The script never mutates test code, restores the files even on an error or Ctrl-C, never touches the recorded test verdict, and its results appear in `port-report.md` and `/drupilot-status`. A control killed outright (SIGKILL, e.g. a tool timeout) cannot restore anything itself: its backup keeps a manifest, the next control refuses to start over it, and `negative-control.sh --subject DIR --recover` puts the original code back.

**Plugin annotations → PHP 8 attributes.** `scripts/analysis/convert-attributes.sh` (also `run-rector.sh --attributes`) converts `@Block(...)`, `@QueueWorker(...)`, `@Filter(...)` and the other core plugin annotations into attributes with drupal-rector's `AnnotationToAttributeRector`, a rule `palantirnet/drupal-rector` ships but enables in no set. It writes its own config (`<drupal_root>/.drupilot/rector-attributes.php`, from `templates/rector-attributes.php.tmpl`), so the default Rector passes never run it. The supported core types and the core minor each attribute class needs are in `config/plugin-attributes.json`, verified against drupal/core: `Action` and `Block` from 10.2; `Condition`, `QueueWorker`, `Filter`, `FieldFormatter`/`FieldWidget`/`FieldType`, `Layout`, `Mail`, `Constraint`, every `Views*` type and the other plugin types from 10.3; the entity types from 11.1; `MigrateSource` from 11.2. Two modes: **keep** adds the attribute next to the annotation (core reads the attribute from the type's minor on and the annotation before it), **strip** removes the annotation, but only for types the declared core floor already supports. `--raise-floor` rewrites `core_version_requirement` to cover the converted types (e.g. `^10 || ^11` → `^10.3 || ^11`, or `^11.1` once an entity type is stripped). Without it, the script never raises the floor. In Phase 1 the pass is an **opt-in** tab (default: skip), in keep mode and limited to the types Drupal 10.3 has, and it raises the floor explicitly. In Phase 2 it is the "PHP 8 attributes" scope, in strip mode. Project or contrib plugin types (e.g. `ExtraFieldDisplay`) are declared in `DRUPILOT_ATTRIBUTE_PLUGIN_TYPES`. The pass prints attributes fully qualified, skips files someone half-converted by hand, puts back a file that ends up with a duplicate attribute or fails `php -l`, and fully qualifies a class constant the annotation named relative to its namespace (`type = Drupal\filter\Plugin\FilterInterface::TYPE_…`, which PHP would otherwise look up inside the plugin's own namespace). A re-run changes nothing.

**How the Drupal 10 half of `^10 || ^11` is verified.** The test-bed runs Drupal 11 only, so a port that keeps Drupal 10 would otherwise just *declare* it. `scripts/analysis/verify-core-matrix.sh` (run by `/drupilot-port`, and by `/drupilot-refactor` while `^10` is kept) analyses the module on every core its `core_version_requirement` declares: the same PHPStan (phpstan-drupal + deprecation rules, the test-bed's exact versions) and `php -l` against a cached Drupal 10 reference core — the latest 10.x for `^10`, 10.3.x for `^10.3 || ^11` — built once through `ddev exec composer` in `<drupal_root>/.drupilot/cores/` (about 200 MB and a minute the first time; never your host PHP). A Drupal 10 leg **fails** on an error the Drupal 11 baseline does not have — an `#[\Override]` on `buildRevisionCacheId()` (a method only 11.3+ core declares), a class only Drupal 11 ships — and `php -l` also runs on the lowest PHP a Drupal 10 site may use for the module (Drupal 10's own 8.1 minimum, or a higher `require.php` floor) in a `php:X.Y-cli` container. A clean run makes the Drupal 10 support **verified-static**: proven by static analysis, not by running the suite on Drupal 10, and `port-report.md`, the issue text and `/drupilot-status` say exactly that. Because `^10` is checked on the *latest* 10.x, a clean run there is reported as **verified-static-above-floor**: the declared floor (10.0) itself was not checked, so an API added in a later 10.x would still fail on it — check the floor with `--cores 10.0,11`, or declare the minor you rely on (`^10.3 || ^11`), whose 10.3.x leg is the floor. Without network the leg is skipped and the support stays **declared-not-verified**; it never blocks a port.

---

## What's automatic vs. where the AI decides

drupilot splits the work in two. **Deterministic scripts** do the mechanical, repeatable work and measure the result; **the AI (Claude) supplies the judgment** — it reviews, decides what to apply, fixes whatever isn't mechanical, and chains the steps together. The consequential decisions are still yours to approve (the tabbed choices).

**Done by scripts, no AI:**

- *Change code:* official Rector (`palantirnet/drupal-rector`), the digests Rector layer (AI-authored rules, but run as a frozen, version-pinned config), the optional annotation → attribute pass (`convert-attributes.sh`), `phpcbf` (auto-fixable coding-standards), and the `PostToolUse` hook (runs `phpcbf` on every Drupal file you edit).
- *Only measure / report:* `phpcs` (reports what `phpcbf` couldn't fix), PHPStan (deprecations + type errors), the preflight requirements gate, PHP/core detection, the dependency-readiness panel, the **port-safety checks** (`check-port-safety.sh`: a `create()` without `ContainerFactoryPluginInterface`/`ContainerInjectionInterface` in its real ancestry, a removed `use` still referenced, `new self(` in `create()`, closures under Form/Render API callback keys, `private`/`readonly` properties in serialized classes, `#[\Override]` while the core range spans Drupal 10, class-name case mismatches — each attributed to the port or pre-existing via git), the **core signature-change scan** (`scan-signature-changes.sh`: the module checked against a verified catalog of Drupal 10 → 11 signature changes at the lowest core it declares — a `ConfigFormBase`/`ContentTranslationController` subclass passing too few constructor arguments, a local `getOriginal()`/`setOriginal()`/`buildRevisionCacheId()` that core adds in 11.2/11.3, a `hook_entity_operation()`/`_alter()` requiring the parameter only 11.3 passes, an `#[\Override]` on a method older declared cores lack), the **deprecation classifier** (`classify-deprecations.sh`: splits PHPStan's deprecations into *hard* — removed in a major ≤ the target, e.g. `user_roles()` gone in 11.0 — and *soft* — removed only in a later major, e.g. `user_load_by_name()`/`text_summary()`/`check_markup()`, deprecated in 11.4 and removed from 13.0 — and says what `DRUPILOT_SOFT_DEPRECATIONS` does with each), the **core matrix** (`verify-core-matrix.sh`: PHPStan + `php -l` on every core the module declares, e.g. a cached Drupal 10 reference core next to the Drupal 11 test-bed), the **metadata lint** (`lint-extension-metadata.sh`: config without `config/schema`, plugin settings without their schema, a `configure:` route no routing file defines, orphan or wrong-case service classes, `arguments:` that do not match the constructor, submodules whose `core_version_requirement` does not admit Drupal 11, dependencies the code uses but `dependencies:` does not declare), the **porting layers** (`layers.sh`: the topological order of a set of modules, its cycles and undeclared dependencies), and the patch and report generators. These **never touch your code**.
- *Change metadata, deterministically:* `set-core-requirement.sh` writes the chosen `core_version_requirement` into the main `info.yml` **and every submodule's**. It removes an obsolete `core: 8.x` key and bumps a test module only when the module does not admit Drupal 11.

**Where the AI acts:**

- **Reviews each Rector dry-run** and decides whether to apply it — never applies blind.
- **Picks which digests rules to apply**, pre-flagging the ones that would silently raise your core floor.
- **Fixes what Rector doesn't cover** — generates an ad-hoc rule or edits by hand (`DRUPILOT_GENERATE_RULES`).
- **Makes the manual changes Rector can't** — `core_version_requirement`, `require.php`, Twig 3, CKEditor 5, jQuery UI.
- **Drives the validate loop** — reads what `phpcs` / PHPStan report and fixes it until clean.
- **Adapts the tests** to D11; on a behavioral failure it fixes the **code**, never the test.
- **Rewrites to the "Drupal 11 way"** in Phase 2 — attributes, dependency injection, strict types, deprecation removal.
- **Proposes the consequential decisions** (core target, refactor scope, contribute or not) — you choose.
- **Learns from each port** — checks the next module against the pitfalls earlier ports of the project hit, and records new ones with a detector and the fix (`patterns.sh`).
- **Logs every divergence as it happens** — each Rector change it reverts, each script verdict it overrides, each step it skips, with why (`log-decision.sh`), so the report never shows a tool's output as kept when it was not.

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

### Running under another tool (non-interactive contract)

A wrapper (another skill, a CI job, a script that drives `claude -p`) needs stable inputs and a machine-readable result, not prose. The contract:

| Input | Environment variable (canonical) | Router flag word (sugar) | Script flag |
| --- | --- | --- | --- |
| The subject | — | first positional word: `/drupilot <dir> …` | `--subject DIR` (every script) |
| Where a loose subject's test-bed goes | `DRUPILOT_WORKSPACE_DIR=DIR` | `--workspace DIR` | `--workspace DIR` (`resolve-workspace.sh`, `ddev-up.sh`, `place-subject.sh`; the flag wins over the variable) |
| Never prompt | `DRUPILOT_NONINTERACTIVE=1` | `--no-confirm` (also selects `auto`) | — |
| Hands-off pipeline | `DRUPILOT_AUTONOMOUS=true` | `auto` | — |
| Pre-answer one tabbed choice | `DRUPILOT_CHOICE_<KEY>=value` | — | — |
| Machine result | — | `--json` | `port-summary.sh --subject DIR --json` |

- `DRUPILOT_NONINTERACTIVE=1` makes every script behave as if there were no terminal: no prompt is shown and each question takes its **default**, the recommended and safe answer (a move into the test-bed proceeds, a push or a destructive clean does not). `DRUPILOT_ASSUME_YES=1` is different: it answers **yes** to every confirmation, so use it only when that is what you mean.
- `--no-confirm` never makes a run outward-facing: like `auto`, it never pushes, opens a Merge Request or contributes, and the `guard-contrib` hook still asks.
- With `--json`, the router's final message is exactly the JSON of `scripts/analysis/port-summary.sh`. A wrapper can also run that script itself, which is more robust than reading the model's reply.

```bash
# Headless port with a machine-readable result:
export DRUPILOT_NONINTERACTIVE=1
claude -p "/drupilot ~/src/my_module auto --no-confirm --workspace ~/src/my_module-d11 --json" \
  --permission-mode bypassPermissions > result.json

# Or read the result straight from drupilot's records (no model involved):
bash "$CLAUDE_PLUGIN_ROOT/scripts/analysis/port-summary.sh" --subject ~/src/my_module-d11/web/modules/custom/my_module --json
```

`port-summary.sh` only composes what drupilot recorded (the per-module `state.json`, the port manifest, the decision log, the last test run, the core matrix) and never invents a value: anything unknown is `null`. `port-report.sh` also saves it as `.drupilot/port-summary.json` next to `port-report.md`. Its main fields:

| Field | Meaning |
| --- | --- |
| `schema_version` | `1`. New fields may be added within a version; renaming or removing one bumps it. |
| `status` | `not-started`, `setup`, `assessed`, `ported`, `refactored`, `tested`, `contributed`, or `blocked` (see `blockers`). |
| `blockers` | `[{source, reason}]`: why a ported module is `blocked` — a test regression, tests that could not run or were never baselined, a failed core-matrix leg, or port-safety/signature errors. A result computed on older sources is shown but never blocks. |
| `effort` | The assessment verdict: `S`, `M`, `L` or `XL`. |
| `core_version_requirement`, `require_php`, `d10_support` | What the module declares now, and how its Drupal 10 half was verified. |
| `files_changed` | Files the port changed (the manifest's count, else the files in the patch). |
| `rector_rules` | `[{rule, hits, passes}]`: Rector rules that changed files. |
| `reverted_rules` | Rector changes undone by hand, with why. |
| `manual_fixes` | Manual edits, with why and a change record. Also `post_port_fixes`, `behavior_changes`, `preexisting_bugs`, `tooling_deviations`, `test_adaptations`, `deferred`. |
| `preservation` | `{verdict, status, executed, tests_failed, fresh, recorded_at}` of the last test run. |
| `matrix` | `{verdict, d10_support, fresh, generated_at}` of the core matrix. |
| `patch` | `{path, kind, at, exists}` of the last patch. |
| `reports` | Paths of `port-report.md`, `viability-report.md`, `decisions.md` and `port-summary.json`. |

`--strict` makes the script exit 3 when the status is `blocked`, for a CI gate. The full schema is in the script's header.

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
| `DRUPILOT_LAYERS_SANDBOX` | _(asked)_ | Applies to `/drupilot-layers` runs on a **loose** folder of modules (a set inside a Drupal root is always ported in place, in that one site). `per-module` gives each module its own `<name>-d11` test-bed. `shared` uses one test-bed for the whole set, `<parent>/<dir>-d11`, so a module and the modules it depends on are installed together. Empty means the command asks; autonomous runs use `per-module`. The answer is remembered in `.drupilot.json`. |
| `DRUPILOT_ARTIFACTS_DIR` | _(empty)_ | Override for the visible `.drupilot/` outputs directory. Empty means `<root>/.drupilot`. |
| `DRUPILOT_PATTERNS_FILE` | _(empty)_ | The learned-pattern catalog. Empty means `<root>/.drupilot/patterns.json`; a module ported by `/drupilot-layers` uses the set's catalog. A relative path is taken from the Drupal root, so a team can share a committed file. |
| `DRUPILOT_DDEV_CREATE_TIMEOUT` | `900` | Seconds `/drupilot-setup` lets `ddev composer create-project` run (and `ddev composer install`, when `vendor/` is missing) before stopping it with a clear error (`0` = no limit). Needs `timeout` (or `gtimeout` on macOS); without it the step is unbounded. |
| `DRUPILOT_CORE_CACHE` | `auto` | The cached base core of `/drupilot-setup` (see [Cleaning up test-beds](#cleaning-up-test-beds)): `auto` reuses the tree for the core version the lockfile froze, or, when nothing is frozen yet, the newest tree built for the same `DRUPILOT_DRUPAL_TARGET` within `DRUPILOT_CORE_CACHE_MAX_AGE_DAYS` (the lock then freezes that version); `locked` only the frozen version; `off` never reuses or stores one. `DRUPILOT_DETERMINISTIC=false` never reuses a tree but still refreshes the cache. |
| `DRUPILOT_CORE_CACHE_MAX_AGE_DAYS` | `7` | Oldest cached base core `auto` reuses when no core version is frozen yet (`0` = no limit). |
| `DRUPILOT_CORE_CACHE_KEEP` | `3` | Cached base cores kept (newest first); `/drupilot-clean --core-cache` removes them all. |
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
| `DRUPILOT_ATTRIBUTES_MODE` | `keep` | Mode of the annotation → attribute pass (`convert-attributes.sh`): `keep` (add the attribute, keep the annotation: BC with older cores) or `strip` (remove the annotation, only for types the declared core floor supports unless `--raise-floor`). Phase 1 always uses `keep` and Phase 2 `strip`; this sets the script's default. |
| `DRUPILOT_ATTRIBUTE_PLUGIN_TYPES` | _(empty)_ | Project or contrib plugin types for the attribute pass, comma-separated: `Annotation=Fully\Qualified\AttributeClass[@MAJOR.MINOR]` (e.g. `ExtraFieldDisplay=Drupal\extra_field\Attribute\ExtraFieldDisplay`). A type is converted only when its attribute class exists under the Drupal root, and its annotation is removed only when a plugin manager references the class. |
| `DRUPILOT_VERIFY_CORES` | `auto` | Which cores `verify-core-matrix.sh` checks statically (PHPStan + `php -l`): `auto` (the legs `core_version_requirement` declares — `^10 \|\| ^11` → 10 and 11, `^10.3 \|\| ^11` → 10.3 and 11, `^11` → nothing extra), `off` (skip; the Drupal 10 half stays *declared-not-verified*), or an explicit list such as `10,11` or `10.3,11`. Reference cores are cached in `<drupal_root>/.drupilot/cores/` and their exact version is frozen in the lockfile. |
| `DRUPILOT_STATE_FORCE` | `false` | The stage a port has reached (`state.json` in drupilot's state dir: setup < assessed < ported < refactored < tested < contributed, recorded by `port-report.sh`, a verified whole-suite `run-phpunit.sh` run and `state.sh record`; see [Per-module state](#per-module-state)) never goes down, so re-running `/drupilot-port` after a refactor does not undo it. `true` lets a new record lower it, e.g. to restart a port from scratch. |
| `DRUPILOT_AUTONOMOUS` | `false` | Hands-off mode (same as the `auto` mode word): unattended setup→assess→port→refactor→test, writes the local patch, **never** contributes. See [Hands-off mode](#hands-off-autonomous-mode). |
| `DRUPILOT_DETERMINISTIC` | `true` | Reproducibility (default on): freeze the resolved Drupal core, dev toolchain, digests SHA and DDEV add-ons in a per-project `drupilot-lock.json` and reuse them on later runs. Set to `false` to resolve fresh every time and refresh the lock. See [Determinism](#determinism-reproducible-by-default). |
| `DRUPILOT_TOOLCHAIN_SOURCE` | `auto` | Where `install-toolchain.sh` takes the dev-toolchain versions from: `auto` (the project lock when it pins the whole known-good set, else the shipped known-good reference `config/toolchain-reference.json`; the `.packages` ranges when `DRUPILOT_DETERMINISTIC=false`), `reference` (always the known-good set — the repair path) or `range` (fresh resolve). |
| `DRUPILOT_POST_EDIT_LINT` | `autofix` | The PostToolUse incremental lint: `autofix` (run phpcbf + phpcs, and **say** when a file was modified), `report` (phpcs only, never edits files), or `off`. It is phase-aware — during Phase 1 it surfaces compatibility **errors** only, deferring style warnings to the refactor. It lints with the same ruleset `run-phpcs.sh` last resolved for the extension (see `DRUPILOT_PHPCS_RULESET`). |
| `DRUPILOT_PHPCS_RULESET` | `auto` | Which PHPCS ruleset `run-phpcs.sh` uses: `auto` (the subject's **own** `.phpcs.xml` / `phpcs.xml` / `.phpcs.xml.dist` / `phpcs.xml.dist`, looked up from the subject to the Drupal root, its git top level and the origin checkout of a copy placement — drupilot's generated `phpcs.xml.dist` never counts — else `Drupal,DrupalPractice`), `drupilot` (always `Drupal,DrupalPractice`, the pre-0.9 behavior) or a ruleset file path. A project ruleset PHPCS cannot load (e.g. it references PHPCompatibility, not installed in the test-bed) falls back to `Drupal,DrupalPractice` with a warning; an explicit ruleset path that cannot load is an error (exit 2), never a silent fallback. `run-phpcs.sh --json` and `port-report.md` say which one was used. |
| `DRUPILOT_PHPCS_TEST_VERSION` | _(empty)_ | PHPCompatibility `testVersion` passed on every `run-phpcs.sh` run with `--runtime-set` (e.g. `8.1-`). Empty = `<DRUPILOT_PHP_TARGET>-`, except that a ruleset's own `<config name="testVersion">` is never overridden and a testVersion declared as a `<property>` inside a `<rule>` is passed through. |
| `DRUPILOT_HOOKS_GUARD` | `ask` | `ask`: the `guard-contrib` hook asks before a `git commit` that skips the repository's git hooks (`--no-verify`, `-n`, `git -c core.hooksPath=…`) where a pre-commit/commit-msg hook is really installed — in every contribution mode and in autonomous mode. `off` disables that check. It never denies and does not change the push/MR guard. |
| `DRUPILOT_SESSION_CONTEXT` | `on` | `on`/`off` toggle for the SessionStart environment summary. |
| `DRUPILOT_REFACTOR_SCOPE` | _(asked)_ | Persisted set of Phase 2 modernizations to apply (attributes / DI / strict types / final / deprecations). Normally chosen via the `/drupilot-refactor` multi-select and remembered in `.drupilot.json`. |
| `DRUPILOT_CHOICE_<KEY>` | — | Pre-answer a specific tabbed choice non-interactively (e.g. `DRUPILOT_CHOICE_CORE_TARGET`), so it is not asked. |

Other useful environment variables: `DRUPILOT_GITLAB_PAT` (your GitLab Personal Access Token, read only at runtime, never persisted), `DRUPILOT_ASSUME_YES=1` (answer yes to every confirmation in non-interactive runs), `DRUPILOT_NONINTERACTIVE=1` (never prompt: every question takes its safe default; see [Running under another tool](#running-under-another-tool-non-interactive-contract)), `NO_COLOR=1`.

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
- the installed **DDEV add-on** versions;
- the exact **reference Drupal core** each core-matrix leg was built with (`.verify_cores`, e.g. Drupal 10.6.18 for the `10` leg), so `verify-core-matrix.sh` keeps judging against the same core.

The lock also names the drupilot that last wrote it: `drupilot_version` (the `plugin.json` version, refreshed on every lock write) and, when drupilot runs from a git checkout such as a development branch that still carries the last released version, `drupilot_revision` (`git describe`, e.g. `v0.8.3-45-gb97266d`).

It works like a `composer.lock`: the version ranges in `config/defaults.json` stay flexible, but the lock pins exactly what was used. That includes rebuilding a removed test-bed: when `ddev-up.sh` has to create the project again (e.g. after `/drupilot-clean --level workspace`), it asks for `drupal/recommended-project:<frozen core version>` instead of the floating `DRUPILOT_DRUPAL_TARGET`. `scripts/env/lock-sync.sh` captures/updates it (`ddev-up.sh`, `ddev-add-ons.sh` and `install-toolchain.sh` call it automatically).

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

Converts annotations to PHP 8 attributes (with the deterministic `convert-attributes.sh` pass), introduces dependency injection and strict types, removes every deprecation, raises PHPStan to level 5–6, and keeps the suite green. Each significant change is explained.

### 5. Run the full test suite in DDEV

```text
/drupilot-test web/modules/custom/my_module --type all --coverage
```

Runs Unit, Kernel, Functional and FunctionalJavascript (Selenium) inside DDEV and reports coverage. If a test can't pass because of an external cause (e.g. a contrib dependency without D11 support), it is documented explicitly rather than silenced.

To prove a new test guards the change it was written for (a negative control):

```bash
bash scripts/tests/negative-control.sh --subject web/modules/custom/my_module \
  --type kernel --filter testQueueWorker --revert-to HEAD --path src/Plugin/QueueWorker/MyWorker.php --json
```

Exit `0` effective (red with the change undone, green restored) · `4` ineffective · `1` inconclusive · `2` environment blocked.

### 6. Get the patch — test locally now, contribute later

```text
/drupilot-patch web/modules/custom/my_module
```

Writes `MODULE-port-to-drupal-11.patch` next to the module — offline, no push, no Drupal.org account. Apply it on another checkout with `git apply`. The patch is diffed against your branch's **fork point** — its upstream when it has one; otherwise the closest of `origin/HEAD`, the other remote branches and the nearest tag (e.g. a local branch cut from a release tag) — so it holds exactly the port, committed or not; pass `--base` to choose. It is kept out of `git status` through the repo's local `.git/info/exclude`. Want to attach it to an issue and validate it there before opening a Merge Request? Pass the issue id for an issue-comment-named patch:

```text
/drupilot-patch web/modules/custom/my_module 3456789
```

This is fully **decoupled from contributing**: the upstream Merge Request (which rebases and hard-verifies the patch against `origin/BASE`) stays a separate, opt-in step you run with `/drupilot-contribute` when you are ready.

### 7. Port a monorepo's custom modules in layers

```text
/drupilot-layers web/modules/custom
/drupilot-layers web/modules/custom run --layer 0
```

The first call is read-only. It prints and saves `.drupilot/layers.md`, which holds three things:
- the layers (port layer 0 first; a layer only depends on earlier ones);
- the cycles (their modules are ported together);
- every undeclared dependency, with its evidence (`file:line`, class / service / route / library / plugin) and the entry to add: `- acme_core:acme_core` for a module of the set, `- drupal:node` for core, `- pathauto:pathauto` for contrib (verify the project name).

A module that only declares part of what it uses is shown where it really belongs, with a note that its declared dependencies alone would have it ported too early. The proposed entries are never applied without your confirmation.

`run` ports one layer, one module at a time, through the usual setup → assess → port → test flow, and writes `.drupilot/layer-N-report.md` from one template (`templates/layer-report.md.tmpl`), so every layer has the same sections:
1. per-module result: stage, effort, preservation and Drupal 10 verdicts, pre-existing hygiene, undeclared dependencies, Rector files, reverted Rector changes, post-port fixes, patch and a link to the module's port report;
2. frequent Rector rules, with their hits (files changed) **and** how often each was reverted;
3. manual changes;
4. post-port fixes;
5. pre-existing bugs (not fixed);
6. behavior changes to review in the PR;
7. tooling and flow deviations;
8. how it was validated.

Sections 2-8 come from each module's port manifest and decision log, so a rule reverted in several modules stands out. `--json` adds the cross-module `aggregate`.

The whole set shares one [learned-pattern catalog](#learned-patterns). Each module is scanned with it before it is ported, and what its port teaches is recorded there, so later layers are checked for the pitfalls earlier layers hit.

A regression stops the next layer. The scripts also work on their own:

```bash
bash scripts/analysis/layers.sh --dir web/modules/custom --json           # layers, cycles, undeclared deps
bash scripts/analysis/lint-extension-metadata.sh --subject web/modules/custom/acme_api --json
bash scripts/analysis/layer-report.sh --dir web/modules/custom --layer 1  # consolidated report
bash scripts/analysis/patterns.sh scan --subject web/modules/custom/acme_invoice  # pitfalls earlier layers learned
bash scripts/analysis/layer-report.sh --subject ../a-d11/web/modules/custom/a --subject ../b-d11/web/modules/custom/b --name "batch 1"  # any set of modules
```

### 8. Contribute the fix back to Drupal.org

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
- **Scripts** (`scripts/`) are a robust, idempotent shell library: a shared `lib/common.sh`, the `env/preflight.sh` requirements engine, the `env/state.sh` per-module state registry, and the `analysis/`, `tests/` and `contrib/` wrappers the skills and commands invoke.
- **Templates** (`templates/`) are parameterized configs (`rector.php`, `phpstan.neon`, `phpcs.xml.dist`, DDEV config + test environment, report templates) tuned by the PHP target.

See **[FLOW.md](FLOW.md)** for a visual, end-to-end diagram of the flow — which tool runs at each step, where the AI steps in, and the two porting phases.

### Scripts reference

Every script lives under `scripts/` (or `hooks/scripts/` for the hooks), sources `scripts/lib/common.sh`, prints `-h` help from its header, keeps its parseable payload on STDOUT (`--json` where a command reads it) and logs on STDERR. The commands and skills call them for you; you can also run them yourself with `CLAUDE_PLUGIN_ROOT` set. Exit codes: `0` ok, `1` usage error, `2` a requirement gate failed, `3` findings or a broken toolchain (see each header).

| Script | What it does |
| --- | --- |
| **`env/`** | |
| `preflight.sh` | The requirements gate (profiles `analyze`/`setup`/`test`/`contribute`/`all`); `--extended` adds the doctor's health checks. |
| `install-deps.sh` | OS-aware assisted installation of git, jq, PHP, Composer, Docker, DDEV (only after confirmation). |
| `detect-php.sh` | The effective PHP target, and whether Drupal 11 officially supports it. |
| `resolve-workspace.sh` | Where a loose module's test-bed goes (read-only; `--workspace DIR`). |
| `ddev-up.sh` | Creates and starts the Drupal 11 DDEV project (cached base core, frozen core version). |
| `place-subject.sh` | Moves, symlinks or copies a loose module into the test-bed. |
| `ddev-add-ons.sh` | Installs the `ddev-drupal-contrib` and Selenium add-ons. |
| `install-toolchain.sh` | Installs the known-good dev toolchain, smoke-tests it and freezes it in the lock. |
| `render-templates.sh` | Renders `rector.php`, `phpstan.neon`, `phpcs.xml.dist` and the DDEV testing config, validated, never clobbering a hand edit. |
| `lock-sync.sh` | Captures the reproducibility lockfile (`drupilot-lock.json`). |
| `ensure-gitignore.sh` | Keeps drupilot's artifacts out of git at the Drupal root. |
| `origin-hygiene.sh` | Proves the port left your original checkout clean (snapshot before, check after). |
| `state.sh` | The per-module state registry (`record`, `refresh`, `show`, `list` for `/drupilot-status --all`). |
| `next-step.sh` | The single source of the "what next?" ladder. |
| `clean.sh` | Frees a test-bed's DDEV project, Composer trees or whole workspace (`/drupilot-clean`). |
| **`analysis/`** | |
| `core-strategy.sh` | Recommends `^11` or `^10 \|\| ^11`, the `require.php` and the version bump. |
| `deps-status.sh` | Drupal 11 readiness of each contrib dependency (drupal.org release history). |
| `detect-php-floor.sh` | The lowest PHP the code needs (heuristic). |
| `run-rector.sh` | Official drupal-rector, the digests layer (`--digests`) and the attributes pass (`--attributes`), dry-run or apply. |
| `run-phpstan.sh` / `run-phpcs.sh` | PHPStan with phpstan-drupal + deprecation rules; PHPCS/phpcbf with the project's ruleset or Drupal + DrupalPractice. |
| `run-upgrade-status.sh` | Upgrade Status on an installed site. |
| `classify-deprecations.sh` | Splits deprecations into hard and soft (`DRUPILOT_SOFT_DEPRECATIONS`). |
| `explain-deprecations.sh` | Explains each deprecation: what changed, the fix, a change-records link. |
| `check-port-safety.sh` | Deterministic checks for breakages ports introduce (lost DI interfaces, closures in Form API callbacks, ...). |
| `scan-signature-changes.sh` | Collisions with Drupal 10 → 11 core signature changes at the declared floor. |
| `verify-core-matrix.sh` | PHPStan + `php -l` on every core the module declares (the Drupal 10 half of `^10 \|\| ^11`). |
| `set-core-requirement.sh` | Writes `core_version_requirement` into the main and every submodule `info.yml`. |
| `convert-attributes.sh` | Optional plugin annotation → PHP 8 attribute pass. |
| `lint-extension-metadata.sh` | Pre-existing hygiene: config without schema, missing routes, orphan services, undeclared dependencies. |
| `layers.sh` / `layer-report.sh` | Porting layers of a set of modules; the consolidated per-layer report (`/drupilot-layers`). |
| `patterns.sh` | The project's catalog of learned port pitfalls (`scan`, `add`, `harvest`, ...). |
| `log-decision.sh` | The decision log: every divergence from a tool's output, with what and why. |
| `port-report.sh` | The human report card `port-report.md` (also refreshes `port-summary.json`). |
| `port-summary.sh` | The versioned machine summary of a port, for wrappers (`--json`, `--strict`). |
| **`tests/`** | |
| `discover-tests.sh` | Finds and classifies the PHPUnit test classes. |
| `run-phpunit.sh` | Runs the suite in DDEV and records the preservation verdict (with a pre-port baseline). |
| `negative-control.sh` | Proves a new test fails without the change it guards. |
| **`contrib/`** | |
| `make-patch.sh` | The local preview patch (`--local`) or the verified contribution patch. |
| `make-issue.sh` | The Drupal.org issue summary, field values and MR comment. |
| `find-upstream-issue.sh` | Looks for an existing Drupal 11 issue for the project. |
| `check-prereqs.sh` / `setup-git.sh` | Contribution prerequisites; the git identity. |
| `issue-fork.sh` / `open-mr.sh` | The issue-fork remote and branch; push and Merge Request (confirmed first). |
| `git-hooks.sh` | Detects the repository's git hooks and runs their equivalents when a hook cannot run. |
| **`dev/`** | |
| `check.sh` | The developer gate for drupilot itself (see [Developing drupilot](#developing-drupilot)). |
| `smoke.sh` | Docker-free smoke tests with expected results on `tests/fixtures/` (the gate's optional `smoke` step). |
| **`hooks/scripts/`** | |
| `session-detect-env.sh` / `post-edit-lint.sh` / `guard-contrib.sh` | The SessionStart, PostToolUse and PreToolUse hooks (see [What's automatic](#whats-automatic-vs-where-the-ai-decides)). |

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
- **Final verification** before a module is considered done: a compatible `info.yml`, `phpstan` with no deprecations at the target level, a clean `run-phpcs.sh` (against the subject's own PHPCS ruleset when it ships one, else `Drupal,DrupalPractice`), `check-port-safety.sh` and `scan-signature-changes.sh` with no error findings, `verify-core-matrix.sh` with no failed leg while Drupal 10 is declared, and the applicable test suite green.
- **The repository's git hooks are honored, never skipped as a habit.** Before a commit, `scripts/contrib/git-hooks.sh` detects GrumPHP, husky, lefthook, pre-commit, CaptainHook, `core.hooksPath` and `.git/hooks` scripts, and the flow lets them run. Only when a hook cannot complete in the session does it run the hook's tasks separately (`git-hooks.sh --run-equivalents`: phpcs, PHPStan, `php -l`, `composer validate`, and PHPUnit with `--with-tests`, through DDEV) and record in `port-report.md` which validations replaced the hook and which tasks had no equivalent.
- **Rector is not trusted blindly.** The generated `rector.php` skips the PHP-modernization rules that broke real ports (Form API callbacks turned into closures, `#[\Override]` judged against the sandbox core only, `readonly` properties, `(string)` casts); none of them is needed for Drupal 11 compatibility.

---

## Troubleshooting

Run `/drupilot-doctor` first: besides the requirements, its [health checks](#requirements) detect several of the entries below (an invalid `phpcs.xml.dist`, the deprecated `drupal_root`, a known-broken toolchain, low disk space, residue in your checkout).

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
- **`verify-core-matrix.sh` exits 3 ("Drupal 10.x [reference] — FAIL").** The module uses something the Drupal 10 core it declares does not have; each `✗` line names the file and the PHPStan message. Typical cases: `has #[\Override] attribute but does not override any method` (the parent method exists only on newer cores — remove the attribute), `Access to constant … on an unknown class Drupal\Core\…` (an API added in Drupal 11 — guard it with `DeprecationHelper::backwardsCompatibleCall()` or raise the floor), or `php -l` failing on PHP 8.1 (a PHP 8.2+ construct under a `>=8.1` `require.php`). Fix the code the Drupal 10-safe way, raise the floor (e.g. `^10.3 || ^11`), or drop to `^11`. Findings only in `tests/`, deprecations, phpstan-drupal advisory rules, classes of contrib modules the reference core does not have, and findings PHP tolerates at runtime (`~` lines: passing *more* arguments than an older core's method takes, e.g. the two-argument `ConfigFormBase::__construct()` call on 10.0, and using the result of a method a newer core declares `: void`) are reported but never fail a leg. When the Drupal 11 baseline leg itself cannot be analysed, the Drupal 10 leg is `skipped` and the support stays `declared-not-verified` (exit 0), never `failed`.
- **`verify-core-matrix.sh` warns "The PHPStan extension config of … is broken".** An older drupilot ran the test-bed's own `vendor/bin/composer` while building a reference core, which rewrote the test-bed's `vendor/phpstan/extension-installer/src/GeneratedConfig.php` (`run-phpstan.sh` then crashes with `Config file …/.drupilot/cores/.build-…/rules.neon does not exist`). The matrix now always runs the container's own Composer, checks that file in the test-bed and in every cached reference core, and regenerates it with `composer install` (or rebuilds the reference core). If it still reports it broken, run `ddev composer install` in the Drupal root.
- **The Drupal 10 leg is `skipped` and `d10_support` stays `declared-not-verified`.** The reference core could not be built: no network (`composer` could not reach Packagist), or that Drupal minor cannot be installed on the container PHP. It is also `skipped` when the Drupal 11 baseline leg could not be analysed (its status is `error`, e.g. PHPStan crashed on the test-bed): without a baseline, the Drupal 10 findings cannot be told apart from pre-existing ones. Fix `run-phpstan.sh` on the test-bed first. The reason is in the JSON and the summary. Re-run when online (`--dry-run` shows what would be built); `--refresh` rebuilds a cached core. To skip the check on purpose set `DRUPILOT_VERIFY_CORES=off`.
- **`run-phpstan.sh` exits 3.** PHPStan crashed or could not analyse (invalid configuration, missing path, fatal error), so there is no verdict; the cause is printed on stderr (and in `drupilot.crash` with `--json`). Fix it and re-run — it is not a count of findings.
- **On macOS: `bad substitution`, `declare: -A: invalid option`, or `sed: 1: "…": invalid command code`.** drupilot 0.8.4 and earlier used bash 4 syntax and GNU `sed -i`, which stock macOS (`/bin/bash` 3.2, BSD `sed`) rejects. Update the plugin: the scripts and hooks now run on bash 3.2 with BSD tools, and `scripts/dev/check.sh` rejects those constructs. You do not need Homebrew bash; if you installed it, it is used just as well.
- **On Debian 12 or Ubuntu 22.04 (jq 1.6): every command reports the requirements as not met, `/drupilot-doctor` shows no checks, or `layers.sh` fails with "Could not compute the layers".** Older drupilot versions used jq 1.7-only syntax, and jq 1.6 rejected those programs (`jq: error: syntax error, unexpected label` on stderr). Update the plugin; jq 1.6 works again. Installing jq 1.7 also fixes it.
- **Every FunctionalJavascript test fails when the WebDriver session starts, while Unit/Kernel/Functional pass.** Drupal 11.4's `WebDriverTestBase` forces `w3c` to `false` when `MINK_DRIVER_ARGS_WEBDRIVER` asks for Chrome without `"w3c":true` (deprecated in 11.4.0, see https://www.drupal.org/node/3460567), and the current Selenium image refuses such a session. The Selenium add-on sets a working value; it is lost when something overrides it — an older drupilot's `.ddev/config.testing.yaml`, or a value you set by hand. Check it with `ddev exec printenv MINK_DRIVER_ARGS_WEBDRIVER` (it must contain `"w3c":true`), re-render the testing config with `render-templates.sh --root <drupal_root> --only testing --force`, then `ddev restart`.
- **A Composer command run through `ddev exec` breaks the test-bed (e.g. PHPStan then fails with `Config file …/rules.neon does not exist`).** A test-bed with `drupal/core-dev` ships its own `vendor/bin/composer`, which comes first on the container's `PATH`. The web container hides it from the top-level shell only (through `EXECIGNORE`), so `ddev exec "timeout 600 composer …"`, `sh -c 'composer …'` or a nested `bash -c` run the test-bed's copy, on the test-bed's autoloader: its plugins then write into the test-bed's `vendor/` even when you work on another project. Use `ddev composer …`, or call the container's own Composer by its absolute path (`/usr/local/bin/composer`), as drupilot does. If the test-bed was already damaged, `ddev composer install` repairs it.
- **Setup or the core matrix fails with "No space left on device", or Docker gets slow.** Each test-bed holds a DDEV project and a few hundred MB of Composer trees, and the core matrix keeps a reference core per Drupal minor. `/drupilot-clean` frees them without losing the work (reports, state, patches and the module's git branches are kept); `ddev delete -Oy <project>` and `docker system prune` free more. `/drupilot-doctor` reports the free space against `requirements.disk_free_min_mb`.
- **Untracked `.ddev/`, `vendor/`, `.drupilot*` or stray symlinks appear in your module's original checkout.** Something left local-environment residue there (an older drupilot, or a module-at-root DDEV sandbox). `/drupilot-doctor` lists it, and `scripts/env/origin-hygiene.sh --check --subject <dir>` compares the checkout with the state recorded before the port. Look before deleting: `git -C <dir> status --porcelain`, then `git -C <dir> clean -n -- .ddev` (dry run) before `-f`. drupilot never deletes anything in your checkout itself.

---

## Developing drupilot

Run the developer gate before every commit to the plugin itself:

```bash
bash scripts/dev/check.sh          # human report; exit 0 ok / 1 a gate failed
bash scripts/dev/check.sh --json   # machine-readable per-gate summary
bash scripts/dev/check.sh --smoke  # also run the smoke tests (~15 s)
```

It validates the plugin manifest, syntax-checks and `shellcheck`s every script, checks the executable bits, rejects bash 4-only / GNU-only constructs (`${x,,}`, `declare -A`, `sed -i`, `readlink -f`, ... — the scripts must run on stock macOS bash 3.2), rejects bash special variables used as plain variables (`GROUPS`, `RANDOM`, `SECONDS`, `UID`, ... — bash silently ignores such assignments), rejects jq keywords used as jq variables or shorthand keys (`--arg label`, `{module, scope}` — a syntax error on jq 1.6), rejects `<placeholder>` literals inside load-time `` !`...` `` lines of commands/skills/agents, checks that the rendered XML templates are well-formed, and validates every JSON file. Optional tools (`claude`, `shellcheck`, `xmllint`) are skipped when absent (`--ci` makes them mandatory). See `--help` for `--only`/`--skip`/`--allow-known`.

The optional `smoke` gate (`--smoke`, implied by `--ci`) runs `scripts/dev/smoke.sh`: smoke tests that need no Docker, DDEV or PHP and assert the expected results of `preflight`, `detect-php`, `next-step`, the hooks, `check-port-safety`, `scan-signature-changes`, `lint-extension-metadata`, `layers` and two `--dry-run`s on the fixtures in `tests/fixtures/` (`legacy_widgets` and a small `monorepo`; `tests/fixtures/*.EXPECTED.md` documents their planted hazards). It works on copies in a temp dir with its own `HOME`, so it never touches the tree or your drupilot state. Run `bash scripts/dev/smoke.sh --list` for the test names and `--only` to pick some.

GitHub Actions (`.github/workflows/ci.yml`) runs the same gate on Ubuntu and macOS, a second time on macOS under the stock `/bin/bash` 3.2, inside the `bash:3.2` container (BusyBox tools) and the `debian:12-slim` container (mawk, jq 1.6), and runs `claude plugin validate .` in its own job after installing the Claude Code CLI from npm.

---

## License

MIT. Note that the optional `dbuytaert/drupal-digests` rules are third-party, unlicensed, and are never bundled with this plugin — they are fetched at runtime into a local cache.
