---
description: Discover, adapt to Drupal 11, and run the full PHPUnit suite (Unit, Kernel, Functional, FunctionalJavascript) inside DDEV with Selenium, iterating until green, and report coverage. Use when the user wants the module/theme test suite passing on Drupal 11. Never silences failures.
argument-hint: "[module-or-theme-path]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, Skill
---

# /drupilot-test — adapt and run the test suite on Drupal 11

Goal: every applicable existing test passes on Drupal 11. Discover the tests,
adapt them to D11 (namespaces, deprecated test APIs, traits, PHPUnit 10/11), run
all four groups inside DDEV (with Selenium for the JavaScript group), and iterate
until the suite is green. In Phase 2 also add missing tests for maximum coverage.

Subject path argument: `$1` (fallback: the current working directory).

## Step 0 — Gate (profile `test`)

Tests run inside DDEV, so this gates on Docker (daemon up) + DDEV.

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile test
```

If it exits `2`, show the report, route the user to `/drupilot-doctor` (and
`/drupilot-setup` to bring up the environment), and STOP with no side effects.
Verify the DDEV environment is actually up for this project:

```bash
!bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; \
  R="$(find_drupal_root "${1:-$PWD}" 2>/dev/null || true)"; \
  if ddev_running "$R"; then echo "ddev=up root=$R"; else echo "ddev=down root=${R:-<none>}"; fi' \
  -- "$1"
```

If DDEV is down, tell the user to run `/drupilot-setup` (or `ddev start`) and stop.

## Step 1 — Discover and classify the tests

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/discover-tests.sh" --subject "$1" --json
```

This classifies the test classes under
`tests/src/{Unit,Kernel,Functional,FunctionalJavascript}` and returns counts plus
the file list. If there are zero tests, say so: there is nothing to run in
Phase 1 (and Phase 2 is where new tests get authored). Report the breakdown.

## Step 2 — Load the procedure and delegate iteration

Invoke the **test-adaptation** skill for the exact DDEV PHPUnit commands, the
Selenium / FunctionalJavascript setup, and the common D11 test-API migrations.

Then delegate the iterate-to-green loop to the **drupal-test-engineer** subagent
(via the Task tool). It is the specialist in PHPUnit / DDEV / Selenium and owns
the adapt-run-fix cycle.

## Step 3 — Adapt the tests to Drupal 11

Before running, adapt the discovered tests for D11 (the skill lists the specifics):

- Update namespaces and base classes that moved or were deprecated.
- Replace deprecated test APIs / traits with their D11 equivalents.
- Align with PHPUnit 10/11 (data providers, attributes vs annotations, setUp
  signatures, deprecated assertions).
- For FunctionalJavascript, ensure the Mink/WebDriver wiring matches the
  environment (read the generated `.ddev/config.yaml` for the real webdriver host;
  do not assume it).

These edits are test-only and must not change the subject's production behavior.

## Step 4 — Run each group inside DDEV, iterate to green

Run the groups in increasing cost order, surfacing real failures. The runner uses
`vendor/bin/phpunit -c web/core` through `ddev exec`; for the JS group it ensures
Selenium is present.

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/run-phpunit.sh" --subject "$1" --type unit
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/run-phpunit.sh" --subject "$1" --type kernel
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/run-phpunit.sh" --subject "$1" --type functional
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/run-phpunit.sh" --subject "$1" --type js
```

For each failure, read the actual PHPUnit output, fix the root cause (test or, if
the port missed something, the relevant code), and re-run that group. **Never**
mark a run green by skipping, mocking away, or suppressing a real assertion.
Iterate until each group passes — or until a failure is provably caused by an
external blocker (e.g. a contrib dependency with no D11 release, or Selenium
unavailable), in which case **document it explicitly** rather than hiding it.

If Selenium could not be installed, the JS group is skipped with a clear note —
that is a documented gap, not a pass.

## Step 5 — Coverage (especially in Phase 2)

When the suite is green, report coverage. In a Phase 2 context, first add tests
for any uncovered behavior, then measure:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/run-phpunit.sh" --subject "$1" --type all --coverage
```

## Step 6 — Report

Summarize in English:

- Discovered vs. run counts per group (Unit / Kernel / Functional /
  FunctionalJavascript).
- Pass/fail result per group, and the adaptations made to reach green.
- Coverage figures (when measured), and any tests added in Phase 2.
- Any test that cannot pass for an external reason, with the explicit cause.
- Next suggested step: `/drupilot-refactor` (if not yet done and the user wants
  it) or `/drupilot-contribute` (for contrib projects).

The declared objective is a fully green, applicable test suite. Failures are
fixed or documented — never silenced.
