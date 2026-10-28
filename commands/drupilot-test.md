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
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile test && bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; copy_legacy_state_once'
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
(via the Task tool, in the foreground: wait for its result). It is the specialist in PHPUnit / DDEV / Selenium and owns
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
- Adapt for the declared floor too, not only the bed's core: a removed
  `$defaultTheme` (`seven`) becomes `stark`; a `submitForm()` label or a
  `buttonExists()`/`buttonNotExists()` locator is passed as a string
  (`(string) $this->t('Save')`), because Drupal 10.2.3 to 10.2.x hand a
  `TranslatableMarkup` to Mink's `findButton(string)` (a `TypeError` on those
  cores while the bed is green) and `buttonNotExists()` never casts it.
- A PHPUnit attribute on a class or a method (`#[RunTestsInSeparateProcesses]`
  too) makes PHPUnit 10/11 ignore that level's doc-comment metadata: add each
  annotation's twin next to it (`@group foo` -> `#[Group('foo')]`) and write
  a relative `@covers ::name` in full; keep the annotations while the range
  admits Drupal 10, whose PHPUnit 9 reads only them. Then run the checks:

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/check-port-safety.sh" --subject <DIR> --checks test-label-markup,test-phpunit-metadata
  ```

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

If `run-phpunit.sh` exits `2` with "PHPUnit is not installed", the Drupal root has
no `vendor/bin/phpunit` (`drupal/core-dev` is missing — environments set up by
drupilot 0.8.4 or earlier never installed it). The run is recorded as
`not-verified-blocked`, not as a regression. Run the install command it prints
(core-dev matched to the installed core, with `-W`), refresh the lock with
`lock-sync.sh --dir <drupal_root>`, then re-run the groups.

**Pre-existing failures.** If a pre-port baseline was recorded (`/drupilot-port`
takes it with `run-phpunit.sh --baseline` before Rector), every run compares each
failing test with it. `preservation: pre-existing-failures` (still exit `3`)
means every failure already failed before the port and nothing that passed
before fails now; `baseline.regressions` lists any test that did pass before (or
that the baseline never ran) and makes the verdict `regression`.
`baseline.not_baselined` lists failing tests the baseline never meaningfully
ran (their group crashed then, or the un-ported module could not even be
installed: "incompatible with this version of Drupal core"). They are never
pre-existing: with no regression, they make the verdict
`not-verified-unbaselined` (exit `3`). Treat each as a possible regression and
fix it in the code. Pre-existing
failures are not proof of preservation: fix them in the code or document them,
and review each one flagged as failing with a different message now. A group
whose PHPUnit executed no test (e.g. a `--filter` matching nothing) counts as
`empty`, never as passed.

**The PHP_LOW leg (the floor's PHP).** When the upgrade plan's `test_matrix` has
a `PHP_LOW` leg (the window's lowest PHP the test-bed core supports is below the
bed's own PHP), run the Unit and Kernel groups again on that PHP once they pass on
the bed's:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/run-phpunit.sh" --subject "$1" --type all --leg PHP_LOW
```

It uses that PHP's binary in the DDEV web container and needs no restart. A plan
without the leg makes it a no-op. A Functional test is not part of it: its site is
served by the bed's own PHP. Its failures are classified against the baseline like
any other (regression, not baselined, pre-existing), and its verdict goes to
`last-test.json` `legs.PHP_LOW`; the top-level `preservation` becomes the stronger
of the two legs'. A failure on the low PHP is the port breaking on its declared
floor: fix it in the code, never relax the test. A PHP that is missing, or cannot
load the test-bed's vendor tree, blocks the leg (exit `2`) and turns a `verified`
suite into `verified-partial`: say so, never hide it. Run the suite on the current
sources first: the leg is only recorded over a CURRENT run of the same sources. The
`PREVIOUS_MAJOR` leg is static, checked by the core matrix (`verify-core-matrix.sh`).

## Step 5 — Coverage (especially in Phase 2)

When the suite is green, report coverage. In a Phase 2 context, first add tests
for any uncovered behavior, then measure:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/run-phpunit.sh" --subject "$1" --type all --coverage
```

**Every new test carries a negative control.** Before a test you added counts,
prove it can fail: `negative-control.sh` undoes the production change the test
guards, requires the test to go red, restores the code byte for byte (checked
with `git hash-object`), and requires it to go green again. Use `--revert-to
<ref-before-the-change> --path <file>` when the test guards a specific change, or
a minimal mutation of the covered code saved as
`<drupal_root>/.drupilot/negative-controls/<test>.patch` otherwise:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/negative-control.sh" --subject "$1" \
  --type kernel --filter testFoo --mutation-patch "<patch>" --label "<what it guards>" --json
```

Exit `0` effective · `4` ineffective (the test stayed green: strengthen it and
re-run the control — never accept it) · `1` inconclusive · `2` environment
blocked. Tests under `tests/` are never mutated, and adapted existing tests are
exempt (their intent is unchanged). The control never touches `last-test.json`.
If a control was killed before it could restore the code (SIGKILL, a Bash-tool
timeout), the next control refuses to start: run `negative-control.sh --subject
"$1" --recover` first, which restores each file from the backup manifest while
it still holds the recorded mutation.

## Step 6 — Refresh the port's artifacts

The port wrote its local patch, its core matrix and its report before this
stage adapted the tests. Once the suite has run, bring them up to the module as
it is now:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/refresh-artifacts.sh" --subject "$1" --json
```

It re-runs the core matrix when `core-matrix.json` is of other sources,
regenerates the local patch, extracts again when the worklist is of other
sources (the pipeline's `php,validate,report` stages: the fixpoint gate judges
the adapted tests too), and renders `port-report.md` with this run. A module
drupilot has not ported has nothing to refresh. A step that fails (exit `3`)
is reported with its reason: fix what it found (a finding the fixpoint gate
reports in an adapted test is fixed like any other) and run it again.

## Step 7 — Report

Summarize in English:

- Discovered vs. run counts per group (Unit / Kernel / Functional /
  FunctionalJavascript).
- Pass/fail result per group, and the adaptations made to reach green.
- The verdict of each test leg (`legs` in `last-test.json`: the bed's PHP, and
  the floor's PHP when the plan has a `PHP_LOW` leg), and the aggregate.
- Coverage figures (when measured), and any tests added in Phase 2 with their
  negative-control verdicts.
- With a baseline: regressions, pre-existing failures (and which now fail
  differently), and the tests the port fixed.
- Any test that cannot pass for an external reason, with the explicit cause.
- The refreshed artifacts (Step 6): each step's status, and the patch path.
- The stage: `run-phpunit.sh` already carried this run's verdict into the
  subject's `state.json` and, for a whole-suite run whose preservation is
  `verified` / `verified-partial`, recorded the **tested** stage — never record
  it by hand for a red or partial run.
- Next suggested step: `/drupilot-refactor` (if not yet done and the user wants
  it) or `/drupilot-contribute` (for contrib projects).

The declared objective is a fully green, applicable test suite. Failures are
fixed or documented — never silenced.
