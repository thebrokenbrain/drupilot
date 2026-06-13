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

FunctionalJavascript tests need the Selenium add-on (v2) and the
`MINK_DRIVER_ARGS_WEBDRIVER` environment from PROMPT 2.5, written to a separate
`.ddev/config.testing.yaml -> web_environment` (ddev-drupal-contrib already
supplies `SIMPLETEST_BASE_URL=http://web` and the DB/browsertest vars; keep the
MINK value's escaped-quote form so `ddev start` stays valid). If JS tests exist:

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
surfaces the failing output. Iteration loop:

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
  functionality is respected; `not verified — no tests` when the module ships
  none (recommend adding them; drupilot does not fabricate them here);
  `regression` if a behavioral test is red (blocking — fix the code, not the test).
- Discovered counts per group and how many were adapted.
- Pass/fail per group; for the whole suite, the green/red status.
- Coverage figures (or an explicit "not measured" with the reason).
- **External blockers, explicitly**: any test that cannot pass for a reason
  outside the subject — e.g. a contrib dependency without a D11 release, a
  Selenium that would not install, an environment limitation. Name the test, the
  cause, and the unblock path. This is the hard rule (PROMPT 5.6 / 7.8): a red or
  skipped test is **documented, never hidden** behind `markTestSkipped` used to
  paper over a real failure, and never removed to make the bar green.

Cache a short summary (`tests.json`: per-group pass/fail, coverage, blockers,
timestamp) in `project_state_dir "$SUBJECT"` for `/drupilot-status`.

## 8. Gotchas

- `KernelTestBase` needs the modules' dependencies installed in the test DB
  schema; a missing `static $modules` entry is the most common Kernel failure.
- JS tests are flaky without the right `MINK_DRIVER_ARGS_WEBDRIVER` host — read
  the generated YAML, never assume `selenium-chrome` vs `selenium-chrome-2`.
- `SYMFONY_DEPRECATIONS_HELPER=disabled` (PROMPT 2.5) keeps deprecation notices
  from failing the run while you port; do not rely on it to mask *your* new
  deprecations — those belong to the port/refactor skills to remove.
- PHPUnit 10/11 fails (not just warns) on some legacy patterns (non-static data
  providers, void return-type omissions). Fix the test, do not pin an old
  PHPUnit.
