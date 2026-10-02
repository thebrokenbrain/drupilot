---
name: test-adaptation
description: >-
  Adapt and run a Drupal module/theme's automated test suite on Drupal 11 with
  PHPUnit 10/11, and iterate until green. USE THIS for the /drupilot-test flow
  and the drupal-test-engineer agent, when the user asks to "run the tests / fix
  the failing tests / get the suite green / add missing tests / report coverage",
  or after a port/refactor when tests must be validated. Discovers and classifies
  Unit/Kernel/Functional/FunctionalJavascript tests, modernizes deprecated test
  APIs (namespaces, traits, PHPUnit 10/11 changes), runs every suite inside DDEV
  (with Selenium for JS tests), iterates to all-green, adds missing tests in
  Phase 2 for maximum coverage and reports coverage, and NEVER silences failures
  — external blockers (e.g. a contrib dependency without D11 support) are
  documented explicitly instead of skipped.
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
user-invocable: true
---

# Test adaptation and execution (Drupal 11 / PHPUnit 10/11)

This skill takes a module/theme's existing tests, adapts them to Drupal 11 and
PHPUnit 10/11, runs the full applicable suite inside DDEV, and iterates until
everything that *can* pass is green. The declared goal (PROMPT 5.6) is **complete
coverage and a green suite**. Failures are never silenced: anything that cannot
pass for an external reason is documented, not hidden.

## 0. Conventions and source of truth

- All output is **English**.
- Verified facts (PROMPT 1.x): Drupal core 11.3, **PHPUnit 10/11**, **Guzzle 7**,
  **Drush 13**, Selenium **v2** add-on for D11 JS tests. Treat as ground truth.
- Tests run inside DDEV via the runner from common.sh: `RUNNER=$(drupal_runner)`
  resolves to `ddev exec` when the environment is up. Always `cd` to the Drupal
  root first so relative paths resolve identically in the container and on host.
- `${CLAUDE_PLUGIN_ROOT}` is the plugin root; leaf scripts live under
  `${CLAUDE_PLUGIN_ROOT}/scripts/...`.
- Two phases (PROMPT 0.1): **Phase 1** = make existing tests pass on D11; **Phase
  2** (opt-in) = add missing tests for maximum coverage. Adding tests is a Phase 2
  activity unless the developer asked for it.

## 1. Gate first (no side effects if a hard requirement is missing)

Running tests is a `test` operation (needs DDEV + Docker daemon):

```bash
ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$ROOT/scripts/env/preflight.sh" --profile test
```

- Exit `0` -> proceed. Exit `2` -> show the report and **stop** (hard reqs:
  Docker with daemon up + DDEV). Point to `/drupilot-setup` / `/drupilot-doctor`.
- Selenium is a **soft** requirement: its absence does not block; it only means
  FunctionalJavascript tests are skipped, which must be reported, not silenced.

## 2. Discover and classify the tests

```bash
. "$ROOT/scripts/lib/common.sh"
SUBJECT="$(cd "${1:-$PWD}" && pwd)"
bash "$ROOT/scripts/tests/discover-tests.sh" --subject "$SUBJECT" --json
```

`discover-tests.sh` classifies the test classes under
`tests/src/{Unit,Kernel,Functional,FunctionalJavascript}` and returns JSON:
`{unit,kernel,functional,javascript,total,files:[...]}`. Use it to plan run order
(fast to slow: Unit -> Kernel -> Functional -> FunctionalJavascript) and to know
whether Selenium is needed at all.

If `total` is 0: report that the subject has no tests. In Phase 1 that is a
finding (nothing to validate beyond a smoke check); in Phase 2 it becomes the
mandate to write tests (see §6).

## 3. Adapt the tests to Drupal 11 / PHPUnit 10/11

Before running, modernize the test code. Common D9/10 -> D11 + PHPUnit 10/11
changes to look for (Grep + Edit, minimal and explained):

- **Namespaces / discovery**: tests must live under
  `tests/src/{Unit,Kernel,Functional,FunctionalJavascript}` with namespace
  `Drupal\Tests\<module>\<Group>\...`. Fix misplaced or mis-namespaced classes.
- **Base classes**: `UnitTestCase`, `KernelTestBase`, `BrowserTestBase`,
  `WebDriverTestBase` (JS). Replace any removed/relocated base classes.
- **`$modules`**: every Kernel/Functional test must declare `protected static
  $modules = [...]`. Older non-static `$modules` is removed.
- **`$defaultTheme`**: BrowserTestBase requires `protected $defaultTheme =
  'stark';` since D9 — fill in if missing.
- **PHPUnit 10/11 API**: data providers must be `public static`; removed
  assertions (`assertFileNotExists` -> `assertFileDoesNotExist`,
  `assertRegExp` -> `assertMatchesRegularExpression`, `assertContains` on strings
  -> `assertStringContainsString`); `setUp(): void` / `tearDown(): void` return
  types; `expectException` patterns; deprecated `withConsecutive`; annotations
  (`@dataProvider`, `@group`) still valid, but prefer attributes only in Phase 2.
- **Deprecated test traits / helpers**: e.g. removed `getMock`, deprecated
  `AssertLegacyTrait` methods, `drupalPostForm` -> `submitForm`,
  `assertResponse`/`assertText` -> `assertSession()->...`.
- **JS tests**: ensure they extend `WebDriverTestBase` and use
  `getSession()`/`assertSession()`; the Mink webdriver config comes from the DDEV
  `web_environment` (see §4).

Keep adaptations **minimal and behavior-preserving** (mirror the port
philosophy). The suite is the **preservation gate**, so a test adaptation may
change only the *form* of a test, never *what it verifies*:

- **Allowed** (mechanical API updates that preserve the test's intent):
  namespaces / base-class relocations, `static $modules`, `$defaultTheme`, renamed
  assertions (`assertFileNotExists`→`assertFileDoesNotExist`,
  `assertRegExp`→`assertMatchesRegularExpression`, `assertContains`-on-string→
  `assertStringContainsString`), `setUp(): void` return types, `public static`
  data providers, `drupalPostForm`→`submitForm`,
  `assertResponse`/`assertText`→`assertSession()->...`.
- **Forbidden** (this fakes the green bar and breaks the preservation guarantee):
  changing an expected value, weakening/removing/commenting a behavioral
  assertion, deleting test cases, widening tolerances, or using
  `markTestSkipped` / `@group legacy` to hide a real failure.

If a behavioral test fails after porting, that is a **production-code regression**
— fix the code (via the port/refactor skills), never the test (see the decision
tree in §5).

## 4. Ensure the JS test prerequisites (Selenium + Mink)

FunctionalJavascript tests need the Selenium add-on (v2), which supplies
`MINK_DRIVER_ARGS_WEBDRIVER` (with `"w3c":true`) itself; ddev-drupal-contrib
supplies `SIMPLETEST_BASE_URL=http://web` and the DB/browsertest vars, and
drupilot's separate `.ddev/config.testing.yaml` adds only
`SYMFONY_DEPRECATIONS_HELPER`. Do not override the MINK value there: Drupal
11.4 forces `w3c` to false when it is missing and every JS session then fails
with "No nodes support the capabilities in the request". If JS tests exist:

```bash
bash "$ROOT/scripts/env/ddev-add-ons.sh" --selenium
```

- The add-on install is idempotent and soft (it warns, does not fail, if Selenium
  cannot install).
- **Read `.ddev/docker-compose.selenium-chrome.yaml`** for the real webdriver
  host (e.g. `selenium-chrome:4444`) rather than assuming — the hostname depends
  on the add-on/DDEV version (PROMPT 2.5 warning). If Selenium is absent,
  proceed with the non-JS suites and record that JS tests were skipped for a
  missing dependency (an external blocker, §7).

## 5. Run the suites and iterate to green

Run with the leaf script, fastest first, capturing full output:

```bash
bash "$ROOT/scripts/tests/run-phpunit.sh" --subject "$SUBJECT" --type unit
bash "$ROOT/scripts/tests/run-phpunit.sh" --subject "$SUBJECT" --type kernel
bash "$ROOT/scripts/tests/run-phpunit.sh" --subject "$SUBJECT" --type functional
bash "$ROOT/scripts/tests/run-phpunit.sh" --subject "$SUBJECT" --type js
# or, once stable, the whole suite:
bash "$ROOT/scripts/tests/run-phpunit.sh" --subject "$SUBJECT" --type all
# narrow while iterating:
bash "$ROOT/scripts/tests/run-phpunit.sh" --subject "$SUBJECT" --type kernel --filter SomeTest
```

`run-phpunit.sh` runs `$RUNNER vendor/bin/phpunit -c web/core <paths>` for the
selected group, ensures Selenium for `js`, and **never silences failures** — it
surfaces the failing output. A group runs only when `tests/src/<Group>` holds at
least one `*Test.php`. Exit codes: `0` passed (or nothing to run) · `2` blocked by
the environment (preflight failed, DDEV down, or PHPUnit missing) · `3` a group
failed (also when every failure pre-exists the port: read `preservation`). Each
group also writes PHPUnit's JUnit log, so the record lists every executed test;
a group that executed no test (a `--filter` matching nothing) counts as `empty`,
never as passed. **PHPUnit comes from `drupal/core-dev`**, which `drupal/recommended-project`
does not ship: when it is missing the script records `not-verified-blocked` (with
`blocked_reason`) and prints the install command matched to the installed core
(`core_dev_requirement`, e.g. `ddev composer require --dev "drupal/core-dev:~11.4.8" -W`)
— install it and re-run; it is an environment blocker, never a regression and
never a reason to touch a test. Iteration loop:

1. Run the fastest group with a failure.
2. Read the failing output and classify it with this DECISION TREE (first match
   wins) — do not guess:
   a. Message matches `Class .* not found` / a removed PHPUnit assertion /
      `must ... return type ... void` / a namespace, `static $modules` or
      `$defaultTheme` problem → **adaptation gap**: fix the TEST per §3.
   b. Message names a module with **no D11 release** (verify on drupal.org), or
      Selenium is unreachable → **external blocker** (§7): document it; do not
      work around it.
   c. Otherwise (an assertion about behavior, or an exception thrown from the
      module's own code) → **production-code bug**: fix the CODE via the
      port/refactor skills, never the assertion.
3. Re-run the narrowed `--filter`, then the group, then move on.
4. Repeat up to all four groups, then a final `--type all` to confirm no
   cross-suite regressions.

**Pre-existing failures vs regressions (the baseline).** The port flow records
the suite BEFORE Rector touches the code:

```bash
bash "$ROOT/scripts/tests/run-phpunit.sh" --subject "$SUBJECT" --type all --baseline
# or promote the last run (e.g. the green post-port run, before a refactor):
bash "$ROOT/scripts/tests/run-phpunit.sh" --subject "$SUBJECT" --baseline-from-last
```

It writes `test-baseline.json` (state dir; `last-test.json` untouched) and exits
`0` even when red. Every later run compares each failing test with it: failed
before AND now → `pre-existing`; passed before and fails now → `regression`; a
failing test the baseline never ran → `regression` (it cannot be shown to
pre-exist), unless its whole baseline group crashed. When every failure is
pre-existing the verdict is `pre-existing-failures`. That is not green and not
proof of preservation: a pre-existing failure is still fixed in the code or
documented, and one flagged `message_changed` (it fails differently now — e.g.
before the port the module could not even install) must be reviewed as a
possible regression. `--no-baseline` ignores the baseline for one run.

**Stop condition (objective):** done when, for every applicable group, each test
is either (i) passing or (ii) recorded as an external blocker (with its cause) in
`last-test.json` and the report. Never stop on an unexplained red, and never use
`markTestSkipped` to hide a real failure.

Long suites should run in the background and notify on completion (PROMPT 6)
rather than blocking the session.

## 6. Add missing tests (Phase 2 only)

When the developer opted into Phase 2 / refactor, raise coverage:

- Identify untested code paths (controllers, services, plugins, forms, access
  logic). Prefer Kernel tests for services/plugins, Functional for routes/forms,
  FunctionalJavascript only for genuinely JS-dependent behavior.
- Write Drupal 11 / PHPUnit 11-native tests (proper namespaces, `static
  $modules`, attributes where the project uses them). Keep them deterministic.
- Re-run §5 until the new tests are green too.
- Give every new test a **negative control** (§6.1) before it counts.

### 6.1 Negative control (every new test)

A new test proves nothing until it has been seen to fail. For each test drupilot
writes (Phase 2, or a regression test requested for a fix), run:

```bash
# It guards a specific change: undo that change from git.
bash "$ROOT/scripts/tests/negative-control.sh" --subject "$SUBJECT" --type kernel \
  --filter testFoo --revert-to <ref-before-the-change> --path src/Foo.php \
  --label "what it guards" --json
# Otherwise: a minimal mutation of the covered production code (flip a
# condition or a return) in <drupal_root>/.drupilot/negative-controls/<test>.patch
bash "$ROOT/scripts/tests/negative-control.sh" --subject "$SUBJECT" --type kernel \
  --filter testFoo --mutation-patch "$DRUPAL_ROOT/.drupilot/negative-controls/testFoo.patch" --json
```

The script backs up and hashes the target files, undoes the change, runs the
test (it must go **red**), restores the files and checks they are byte-identical
(`git hash-object`), then runs the test again (it must go **green**). It traps
EXIT/INT/TERM so the code is restored even on an error or Ctrl-C (a SIGKILL —
e.g. a Bash-tool timeout on a slow Functional run — cannot be trapped: the
backup dir keeps a manifest, the next control refuses to start over it, and
`negative-control.sh --subject "$SUBJECT" --recover` restores each file whose
hash is still the recorded mutation), refuses any
path under `tests/` (mutating the test is not a control), and runs PHPUnit with
`--no-record`, so `last-test.json` and the baseline are never touched. Verdicts:
`effective` (exit 0) · `ineffective` (exit 4 — the test stayed green: strengthen
it and re-run; never accept it) · `error` (exit 1 — the filter ran no test, the
restored code is not green, or the restore was not identical) · exit 2 when the
environment is blocked. Results go to `negative-controls.json` (state dir),
into `last-test.json`'s `negative_controls` summary and into `port-report.md`.
Never mutate code by hand for a control. Adapted EXISTING tests are exempt (§3
keeps their intent), and Phase 1 still fabricates no tests.

## 7. Coverage and reporting (never silence anything)

```bash
bash "$ROOT/scripts/tests/run-phpunit.sh" --subject "$SUBJECT" --type all --coverage
```

`--coverage` adds `--coverage-text` / `--coverage-html`. Coverage needs a driver
(Xdebug/PCOV) in the DDEV PHP image; if absent, report that coverage could not be
measured and how to enable it (`ddev xdebug on` or a PCOV add-on) — do not fake a
number.

Final report (English, concise) must state:

- **Preservation status** (the headline): `verified` when the full applicable
  suite is green (state how many tests) — that green is the evidence the original
  functionality is respected; `not verified — no tests` when no test exists in
  the selected scope — say "the module ships no tests" only when
  `subject_has_tests` is `false` (recommend adding them; drupilot does not
  fabricate them here); `not verified — blocked` when tests exist but could not
  run (`blocked_reason`: PHPUnit/core-dev missing, Selenium unreachable);
  `regression` if a behavioral test is red (blocking — fix the code, not the test);
  `pre-existing failures` when, against the pre-port baseline, every red test was
  already red before the port (list them; not proof of preservation either way).
- Discovered counts per group and how many were adapted.
- Pass/fail per group; for the whole suite, the green/red status.
- Coverage figures (or an explicit "not measured" with the reason).
- **External blockers, explicitly**: any test that cannot pass for a reason
  outside the subject — e.g. a contrib dependency without a D11 release, a
  Selenium that would not install, an environment limitation. Name the test, the
  cause, and the unblock path. This is the hard rule (PROMPT 5.6 / 7.8): a red or
  skipped test is **documented, never hidden** behind `markTestSkipped` used to
  paper over a real failure, and never removed to make the bar green.

`run-phpunit.sh` already writes the machine-readable summary to `last-test.json`
in `project_state_dir "$SUBJECT"` for `/drupilot-status` and the flow: `type`,
`status`, the **`preservation`** verdict (`verified` / `verified-partial` /
`regression` / `pre-existing-failures` / `not-verified-blocked` /
`not-verified-no-tests`), per-group counts, `tests` (every executed test with
its status) and `group_results`, the `baseline` comparison (`regressions`,
`pre_existing`, `fixed`; `null` without a baseline), the `negative_controls`
summary,
`failed_groups` / `skipped_groups`, the `js_skipped_reason`, `blocked_reason` (why
tests that exist could not run), `subject_has_tests` / `groups_with_tests` (whether
the subject ships tests at all / in the selected scope), and a `coverage`
object (`requested`, `html` path, `percent` — `percent` is `null`: Phase 1 does
not compute a coverage figure, so never invent one). Read that file rather than
re-running; do not write a second record under a different name.

## 8. Gotchas

- `KernelTestBase` needs the modules' dependencies installed in the test DB
  schema; a missing `static $modules` entry is the most common Kernel failure.
- JS tests fail without the right `MINK_DRIVER_ARGS_WEBDRIVER` — check it with
  `ddev exec printenv MINK_DRIVER_ARGS_WEBDRIVER`: it must carry `"w3c":true` and
  the host from the generated YAML (never assume `selenium-chrome` vs
  `selenium-chrome-2`).
- `SYMFONY_DEPRECATIONS_HELPER=disabled` (PROMPT 2.5) keeps deprecation notices
  from failing the run while you port; do not rely on it to mask *your* new
  deprecations — those belong to the port/refactor skills to remove.
- PHPUnit 10/11 fails (not just warns) on some legacy patterns (non-static data
  providers, void return-type omissions). Fix the test, do not pin an old
  PHPUnit.
