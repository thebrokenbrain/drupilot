---
description: Phase 2 opt-in full refactor to the modern Drupal 11 way — PHP 8 attributes for plugins, dependency injection, strict types, modern APIs, zero deprecations, PHPStan level 5-6, and clean Drupal+DrupalPractice, with the test suite kept green. Use only when the user explicitly opts into refactoring after a Phase 1 minimal port.
argument-hint: "[module-or-theme-path]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, Skill, AskUserQuestion
---

# /drupilot-refactor — Phase 2: full "Drupal 11 way" refactor (opt-in)

This is the **optional** second phase. It rewrites the subject to modern Drupal 11
best practices. It is opt-in by design: only run it when the user explicitly asks.
It assumes Phase 1 (`/drupilot-port`) already left the subject D11-compatible with
behavior intact.

Subject path argument: `$1` (fallback: the current working directory).

## Step 0 — Gate (profile `analyze`) and confirm intent

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile analyze
```

If it exits `2`, show the report, point to `/drupilot-doctor`, and STOP. The dev
toolchain must be installed; if not, route the user to `/drupilot-setup`.

Because this phase deliberately changes architecture and behavior-adjacent code,
**confirm** the user really wants the full refactor (not just the minimal port).
If they have not yet run a Phase 1 port, recommend doing that first so the diff
stays reviewable.

## Step 1 — Resolve subject and the higher quality bar

```bash
!bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; \
  SUBJECT="${1:-$PWD}"; SUBJECT="$(cd "$SUBJECT" 2>/dev/null && pwd || echo "$SUBJECT")"; \
  echo "subject=$SUBJECT"; \
  echo "machine_name=$(subject_machine_name "$SUBJECT" 2>/dev/null || echo "?")"; \
  echo "type=$(subject_type "$SUBJECT" 2>/dev/null || echo "?")"; \
  echo "php_target=$(resolve_php_target)"; \
  echo "phpstan_level_refactor=$(config_get DRUPILOT_PHPSTAN_LEVEL_REFACTOR 6)"' \
  -- "$1"
```

The refactor PHPStan target is `DRUPILOT_PHPSTAN_LEVEL_REFACTOR` (default `6`),
higher than the Phase 1 deprecation level. The PHP target still derives from
`DRUPILOT_PHP_TARGET` (default `8.3`); never assume PHP 8.5 is supported — branch
on the runtime check.

Because a refactor introduces typed / `final` public APIs (a BC break),
re-evaluate the core target in refactor mode:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/core-strategy.sh" --subject "$1" --phase refactor
```

It recommends `^11` (drop Drupal 10) and a **major** version bump — plan a new
`N+1.0.x` branch, not a minor. Apply its `core_version_requirement`; `^11` needs
no `require.php`. Surface the major-bump implication in the final summary.

## Step 2 — Load the procedure and choose the scope

Invoke the **full-refactor** skill for the modernization checklist and the exact
toolchain commands.

**Decision point — the developer picks the modernization scope (G3/G4/G5).** The
"Drupal 11 way / PHP 8.x way" refactor is not all-or-nothing — surface a
**multi-select** with **AskUserQuestion** (header "Modernize", **all pre-selected**
by default, droppable) *unless* the run is autonomous or
`DRUPILOT_REFACTOR_SCOPE` is already pinned:

- **PHP 8 attributes** for plugins (annotations → `#[Block(...)]` etc.).
- **Dependency injection** (`\Drupal::service()` → constructor injection).
- **Strict types** (`declare(strict_types=1)` + parameter/return types).
- **`final` by default** on classes not designed for extension — note this can
  break downstream extenders, so it is a deliberate opt-in.
- **Remove all deprecations** (adopt current Symfony 7 / Twig 3 / Guzzle 7 idioms).

Plus a single follow-up tab (header "PHPStan level") for the quality bar: **6**
(default, `DRUPILOT_PHPSTAN_LEVEL_REFACTOR`) / **5** / **4** — higher is stricter.

Persist the choices so a re-run does not re-ask: `prefs_set DRUPILOT_REFACTOR_SCOPE
"<csv of selected keys>"` and `prefs_set DRUPILOT_PHPSTAN_LEVEL_REFACTOR <N>` (env
still wins). Apply **only** the selected modernizations in Step 3, and use the
chosen PHPStan level in Step 5. If the developer dropped "final by default" or
"remove all deprecations", say so in the report (the bar was lowered by choice).

## Step 3 — Modernize, change by change

Apply **only the modernizations selected in Step 2** (`DRUPILOT_REFACTOR_SCOPE`),
**explaining each significant change** as you go (what changed, why, and that
behavior is preserved):

- **PHP 8 attributes** for plugins instead of annotations (e.g. `#[Block(...)]`,
  `#[FieldType(...)]`), with the matching `use` statements.
- **Dependency injection**: replace `\Drupal::service(...)` static calls with
  constructor-injected services; implement `create()` / `ContainerFactoryPluginInterface`
  where appropriate.
- **Strict typing**: add `declare(strict_types=1);`, parameter/return type hints,
  and `final` on classes not designed for extension where it is safe.
- **Modern APIs**: remove every remaining deprecation; adopt current
  Symfony 7 / Twig 3 / PHPUnit 10-11 / Guzzle 7 idioms.
- Keep the public behavior and the module/theme's contract stable; this is a
  rewrite of *how*, not *what*.

## Step 4 — Keep the suite green (coordinate with the test engineer)

A refactor is only done when the tests still pass. After each meaningful batch of
changes, delegate to the **drupal-test-engineer** subagent (via the Task tool) to
adapt and re-run the relevant tests in DDEV (Unit / Kernel / Functional /
FunctionalJavascript), and iterate until green. In Phase 2 the engineer also
**adds missing tests** to raise coverage. Do not silence failing tests — if
something cannot pass for an external reason (e.g. a contrib dependency without a
D11 release), document it explicitly.

You can drive the test run via `/drupilot-test`, or call the test scripts the
engineer uses; let the subagent own the iteration loop.

## Step 5 — Quality gates: PHPStan 5-6 + clean PHPCS

Push static analysis to the refactor level and require clean coding standards:

```bash
# Coding standards: autofix, then the result must be clean for Drupal + DrupalPractice:
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpcs.sh" --subject "$1" --fix
# Static analysis at the higher refactor level:
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpstan.sh" --subject "$1" --level "$(bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; config_get DRUPILOT_PHPSTAN_LEVEL_REFACTOR 6')"
```

Iterate until: zero deprecations, PHPStan clean at level 5-6, and `phpcs
--standard=Drupal,DrupalPractice` reports no violations.

## Step 6 — Refresh the local patch

Phase 2 changes more code, so regenerate the local preview patch to reflect the
refactor (overwrites the Phase 1 one in place):

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/make-patch.sh" --local --subject "$1"
```

It rewrites `MODULE-port-to-drupal-11.patch` next to the module. This stays a
preview/test patch (add `--issue ID` for an issue-comment-named one, as
`/drupilot-patch` does); the merge-verified contribution patch is produced by
`/drupilot-contribute`.

## Step 7 — Report

Summarize in English:

- The modern patterns applied (attributes, DI, strict types, API updates), with a
  brief rationale for each significant change.
- Final quality state: PHPStan level reached and clean, PHPCS Drupal +
  DrupalPractice clean, zero deprecations.
- Test status: which groups ran, the pass result, coverage, and any test
  documented as un-passable for an external reason.
- A reviewable summary of the diff.
- **Local patch**: the refreshed `MODULE-port-to-drupal-11.patch` path (Step 6).
- Next suggested step: `/drupilot-test` for a final full green run, then
  `/drupilot-contribute` if the subject is a contrib project the user wants to
  publish.

**Refresh the port report card.** Record the refactor's decisions as a manifest
(`phase: "refactor"`, the modern patterns applied, the new
`core_version_requirement` / `version_bump`, the deferred items now done) and
re-render so the report reflects Phase 2:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/port-report.sh" --subject "$1" --manifest "<state_dir>/port-manifest.json"
```

`SendUserFile` the refreshed `port-report.md`.

## Step 8 — What next? (developer chooses)

**Unless the run is autonomous** (`DRUPILOT_AUTONOMOUS=true` — then print the
recommendation and stop), offer a closing **AskUserQuestion** fork (header "Next
step", default = recommended): **Run the tests** (`/drupilot-test`), **Get the
local patch** (`/drupilot-patch`), **Patch for a Drupal.org issue**
(`/drupilot-patch` → issue-comment option), **Contribute upstream**
(`/drupilot-contribute`, only for a contrib project and **never** autonomously),
or **Done for now**. Route to the chosen command.

Nothing breaks silently. Every architectural change is explained.
