---
name: full-refactor
description: >-
  Use this skill for Phase 2 — the opt-in "Drupal 11 way" refactor — i.e. when
  running /drupilot-refactor or when the user explicitly asks to "modernize",
  "refactor to Drupal 11 best practices", "convert annotations to PHP 8
  attributes", "add dependency injection / strict types", or "reach PHPStan
  level 6 / clean PHPCS". It rewrites the already-ported module to modern APIs:
  PHP 8 attributes for plugins, constructor dependency injection, strict types
  and final where appropriate, zero deprecations, PHPStan level 5–6, fully clean
  Drupal + DrupalPractice, while keeping the test suite green. This is the
  OPT-IN second phase — it assumes Phase 1 (minimal-port) already produced a
  D11-compatible module. Do NOT use it for first-pass compatibility; that is the
  minimal-port skill.
allowed-tools: Bash, Read, Edit, Write
---

# Phase 2 — full refactor ("Drupal 11 way")

Opt-in second phase. It assumes Phase 1 (`minimal-port`) already left the module
**compiling on Drupal 11 with no blocking deprecations**. The goal now is
quality: modern Drupal 11 idioms, zero deprecations, PHPStan level 5–6, clean
`Drupal` + `DrupalPractice`, and a green test suite. Coordinate closely with the
`drupal-test-engineer` agent / `test-adaptation` skill — nothing breaks silently.

## 0. Golden rules

- **Phase 1 must be complete first.** If the module still has blocking
  deprecations, go back to `minimal-port`. Do not mix phases.
- **Keep tests green throughout.** Refactor in small, verifiable steps; run the
  suite after each meaningful change. If a test goes red, fix it before moving
  on. Never silence a failing test.
- **Explain every significant change.** Phase 2 changes architecture; the user
  must understand each one. Nothing changes silently.
- **Raise the bar deliberately.** Use `DRUPILOT_PHPSTAN_LEVEL_REFACTOR`
  (default `6`) for this phase, not the Phase 1 default of 2.
- **Respect the PHP target.** Modern syntax (attributes, typed properties,
  constructor property promotion) is gated by `DRUPILOT_PHP_TARGET`; see the
  `php-target-tuning` skill (and the 8.5 caveat — never assume it).
- **The Phase 1 port-safety rules still apply** (`minimal-port` §0): never
  remove `ContainerFactoryPluginInterface`/`ContainerInjectionInterface` from a
  class with `create()` (and do not assume a `*Base` class provides it), never
  drop a `use` that is still referenced, never `new static` → `new self` to
  quiet PHPStan, never turn Form/Render API callbacks into closures, and symbols
  newer than the kept core floor only through
  `DeprecationHelper::backwardsCompatibleCall()`.
- **A PHPStan finding is never fixed by changing semantics** unless the original
  project tolerates the change. Sandbox-only findings (classes from modules that
  are not installed here) are documented, not patched.

## 1. What "Drupal 11 way" means (concrete rules, applied uniformly)

Apply these as **rules with objective triggers**, not as suggestions, so two
refactors of the same module converge. When a rule's trigger is absent it is a
no-op — that is the only discretion.

- **Plugins → PHP 8 attributes.** EVERY plugin class still using a doc-block
  `@Annotation` (`@Block`, `@FieldType`, `@FieldFormatter`, `@FieldWidget`,
  `@Action`, `@QueueWorker`, `@EntityType`, `@RenderElement`, …) is converted:
  move ALL metadata into the matching `#[...]` attribute and drop the now-unused
  `use Drupal\...\Annotation\...;`. Never leave a plugin half-converted.
- **`\Drupal::` → dependency injection.** EVERY `\Drupal::service('x')` and
  `\Drupal::` accessor in a class that can receive services is injected:
  `ContainerFactoryPluginInterface::create()` for plugins,
  `ContainerInjectionInterface::create()` for controllers/forms, a `services.yml`
  argument for services. Use constructor property promotion — **`protected`,
  never `private` or `readonly`, in any class using `DependencySerializationTrait`**
  (forms, plugins): its `__sleep()` runs in the base-class scope and drops private
  child properties, and `__wakeup()` cannot re-initialize a readonly one. Leave
  `\Drupal::` only in procedural `.module`/`.install` hooks where DI is
  unavailable; once a service is injected, use the injected property everywhere
  in that class.
- **`declare(strict_types=1);` in EVERY `.php` file** under `src/` and `tests/`.
  Add parameter, return and property types wherever the type is known and
  unambiguous.
- **`#[\Override]` only when it is true on every declared core.** Add it only
  when `core_version_requirement` is `^11`-only AND the parent method exists in
  the lowest declared 11.x minor (e.g. `ContentEntityStorageBase::buildRevisionCacheId()`
  exists only from 11.3). An `#[\Override]` without a parent method is a
  compile-time fatal on PHP 8.3+. `scan-signature-changes.sh` and the
  `override-attribute` check of `check-port-safety.sh` flag an `#[\Override]` on
  a method the signature catalog dates above the declared floor as an error.
- **Typed signatures must match core on every declared core.** Adding types is
  where a method collides with one core added later: a `getOriginal()` in an
  entity must be `: ?static` (11.2+), a storage `buildRevisionCacheId($id)` must be
  `protected ... : string` (11.3+) — or renamed while the floor is lower. A new
  hook parameter core passes only from a later minor (`$cacheability` of
  `hook_entity_operation()`, 11.3) stays optional until the floor reaches it.
- **`final` by default.** Mark a class `final` UNLESS it is abstract, an
  interface, a `*Base` class, or another class in the module/its tests extends it.
  (Plugins and services are normally `final`.)
- **Zero deprecations.** Replace every API deprecated through D11.4 with its
  current equivalent (entity query `->accessCheck(TRUE)`, the `messenger` service,
  typed config, current routing/event APIs). Target the refactor PHPStan level
  clean with **no** deprecation notices. This includes the **soft** deprecations
  Phase 1 reported or deferred under `DRUPILOT_SOFT_DEPRECATIONS` (removed only in
  a later major, e.g. `user_load_by_name()`/`text_summary()`/`check_markup()`,
  deprecated in 11.4.0): run `classify-deprecations.sh --phase refactor`, which
  turns every soft item into a fix regardless of the Phase 1 policy, and follow
  each item's `action` — `fix` (replacement exists at the declared core floor),
  `fix-guarded` (wrap it in `DeprecationHelper::backwardsCompatibleCall()`, the
  replacement exists only on newer cores, e.g. `TextSummary` from 11.4) or `defer`
  (no replacement usable at the floor: keep it, document it, or raise the floor
  in §1b). The core floor still wins over "zero deprecations".
- **Finish deferred hard breaks.** Complete any Twig 3 / CKEditor 5 / jQuery-UI
  migration left mechanical-only in Phase 1 (custom Twig extensions, editor
  plugins, JS without jQuery UI).

Do **not** introduce value objects/enums or other redesigns unless they are
required to remove a deprecation: Phase 2 modernizes APIs, it does not redesign
behavior.

## 1b. Reconsider the core target (a refactor usually warrants a new major)

Phase 2 introduces modern typed / `final` public APIs, which are
backwards-incompatible. Re-run the core-target helper in refactor mode:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/core-strategy.sh" --subject "<path>" --phase refactor --json
```

`--phase refactor` asserts a BC break, so it recommends `^11` (drop Drupal 10)
and a **major** version bump — cut a new `N+1.0.x` branch rather than a minor on
the existing one. Apply the recommended `core_version_requirement`; for `^11` no
composer `require.php` is needed (core enforces PHP >= the target). If you
deliberately keep `^10 || ^11` (an explicit override), the helper returns a
`require.php` floor (`DRUPILOT_REQUIRE_PHP_FLOOR`: `detect` → the real floor, e.g.
`>=8.1`; `target` → `>=<target>`) — add it to `composer.json`. State the
version-bump implication (new major branch) in the summary.

## 2. Refactor loop

Before the first change, freeze the post-port suite as the refactor's baseline,
so a later red test is classified as a regression of the refactor or as a failure
that already existed (`pre-existing-failures`):

```bash
# Promote the last (post-port) run; or take a fresh one with --baseline.
bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/run-phpunit.sh" --subject "<path>" --baseline-from-last
```

Work one concern at a time. After each change, re-run the validate loop and the
relevant tests:

```bash
# Coding standards: auto-fix then verify (must end clean):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpcs.sh" --subject "<path>" --fix

# Static analysis at the refactor level (5-6):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpstan.sh" --subject "<path>" \
  --level "$(config_get DRUPILOT_PHPSTAN_LEVEL_REFACTOR 6)"

# Deterministic port-safety checks (gate: must exit 0):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/check-port-safety.sh" --subject "<path>" --json

# Core signature changes vs the declared core floor (gate: must exit 0):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/scan-signature-changes.sh" --subject "<path>" --json

# Only while ^10 is still declared: static check on a Drupal 10 core (gate: exit 0;
# a skipped leg, e.g. no network, exits 0 and stays declared-not-verified):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/verify-core-matrix.sh" --subject "<path>" --json \
  --level "$(config_get DRUPILOT_PHPSTAN_LEVEL_REFACTOR 6)"

# Re-run the affected test group(s) (see test-adaptation for the full flow):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/run-phpunit.sh" --subject "<path>" --type all
```

`run-phpcs.sh --fix` runs `phpcbf` then `phpcs` with the subject's own PHPCS
ruleset when it ships a loadable one (else `--standard=Drupal,DrupalPractice`
with the PROMPT §2.3 extension list), always passing `--runtime-set testVersion
<target>-` unless the ruleset sets its own `<config name="testVersion">`; report
which ruleset was used (`--json` → `.drupilot`). "Fully clean" means clean
against that ruleset. Commits follow the repository's git hooks exactly as in
`minimal-port` §3: `scripts/contrib/git-hooks.sh` first, never a normalized
`--no-verify`, and any substitution recorded as `verification.commit_hooks`. `run-phpstan.sh` runs against the
`phpstan.neon` at the Drupal root. Exit 3 means PHPStan crashed or could
not analyse (invalid config, fatal error): there is no verdict — fix the cause
shown on stderr, never read it as "issues found" or as clean. Reference commands:

```bash
vendor/bin/phpstan analyse --level 6 web/modules/custom/MODULE
vendor/bin/phpcs --standard=Drupal,DrupalPractice web/modules/custom/MODULE
```

Increment the PHPStan level gradually if jumping straight to 6 produces an
overwhelming list: tighten one level at a time (2 → 3 → … → 6), clearing findings
at each step. This keeps each batch reviewable and the tests verifiable.

## 3. Tests: green throughout, then maximize coverage

Coordinate with `test-adaptation` / the `drupal-test-engineer` agent:

- Keep every existing test passing as you refactor (Unit + Kernel + Functional +
  FunctionalJavascript, run inside DDEV with Selenium for JS).
- After the refactor lands, **add** missing tests to maximize coverage of the
  modernized code paths (new attribute-driven plugins, injected services).
- **Every new test carries a negative control** before it counts: run
  `scripts/tests/negative-control.sh --subject <path> --type <group> --filter
  <test> (--revert-to <ref> --path <file> | --mutation-patch <file>) --json`
  (see `test-adaptation` §6.1). It must be `effective` (red with the guarded
  change undone, green once the code is restored byte for byte); an
  `ineffective` test is strengthened and re-controlled, never accepted. Record
  the results under `verification.negative_controls` in the manifest (or pass
  `--manifest <manifest>`); `port-report.md` lists them.
- Report coverage with `run-phpunit.sh --coverage` (`--coverage-text` /
  `--coverage-html`).
- If a test cannot pass for an external reason (e.g. a contrib dependency without
  a D11 release), **document it explicitly** — never silence it.

## 4. Definition of done (PROMPT §7.9)

Before declaring the module refactored, all must hold:

- `info.yml` D11-compatible (`core_version_requirement` correct).
- `phpstan analyse --level 5-6` clean — **zero** deprecations, no errors at the
  target level.
- `phpcs --standard=Drupal,DrupalPractice` **clean**.
- `check-port-safety.sh --subject <path>` exits **0** (no error findings: DI
  interfaces in place, no closures under Form/Render API keys, no
  private/readonly properties in serialized classes, no `new self` in
  `create()`); its warnings are reviewed and listed in the report.
- `scan-signature-changes.sh --subject <path>` exits **0** (no collision with a
  core signature change at the declared floor).
- When the result still declares `^10`, `verify-core-matrix.sh --subject <path>`
  exits **0** (no Drupal 10 leg failed; see `minimal-port` §6a for the tab when
  one does) and its `d10_support` goes into the manifest with
  `verification.core_matrix`.
- `classify-deprecations.sh --file <phpstan.json> --subject <path> --phase refactor
  --json` reports `blocking: 0` and every soft item fixed, or documented with its
  `defer` reason (no replacement usable at the declared core floor).
- The full applicable test suite **green** (anything skipped is documented). Because
  Phase 2 changes more code, this is the **preservation gate**: the same tests that
  passed after Phase 1 must still pass, unchanged in what they verify. If the module
  has no tests, state that preservation is **not verified** for the refactor and
  recommend adding tests before/with it.
  Against the post-port baseline the verdict must not be `regression`; a
  `pre-existing-failures` verdict is reported with its list, never presented as
  green.
- Every test added in Phase 2 has an `effective` negative control.
- Plugins use attributes; services are injected; strict types are in place where
  appropriate.

## 5. Refresh the patch, report, and hand off

Phase 2 changes more code, so **refresh the local patch** so it reflects the
refactor (this is a standalone, anytime action, decoupled from contribution — the
`/drupilot-patch` command does the same):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/make-patch.sh" --local --subject "<path>"
```

It rewrites `MODULE-port-to-drupal-11.patch` next to the module; add
`--issue ID [--comment N]` for an issue-comment-named one (still offline). The
merge-verified contribution patch stays the job of `drupal-contribution`.

**Refresh the didactic report.** Tee the Phase 2 Rector + final PHPStan
deprecation output into `<state_dir>/change-log.txt` (under `$HOME`, never in the
project tree), update `<state_dir>/port-manifest.json` (`phase: "refactor"`, `soft_deprecations`
= the final `classify-deprecations.sh --phase refactor --json`), and
re-render with `port-report.sh --subject <path> --manifest <manifest>
--changes-log <state_dir>/change-log.txt` so `port-report.md` in the visible
`.drupilot/` dir reflects Phase 2 and its "changes, explained" section.

Summarize (in English): each significant change and why (annotations →
attributes, `\Drupal::` calls → DI, types/`final` added, deprecated APIs
replaced), the final PHPStan level reached, PHPCS status, the test results +
coverage, the refreshed **local patch path**, and any documented exception. The
module now follows the Drupal 11 way. End by putting the developer back in control
with the closing tabbed choice (the `/drupilot-refactor` command renders it): run
the tests, get the patch, or contribute (opt-in) — a candidate for
`/drupilot-contribute`.

## Gotchas

- Do not start Phase 2 on a module that still has Phase 1 blocking deprecations.
- Annotation → attribute conversion must move **all** metadata and drop the unused
  annotation imports; a half-converted plugin can fail discovery.
- DI via `create()` requires the right interface
  (`ContainerFactoryPluginInterface` for plugins vs `ContainerInjectionInterface`
  for controllers/forms) — mismatching them breaks instantiation. Converting a
  plugin to attributes never removes `implements ContainerFactoryPluginInterface`.
- `declare(strict_types=1);` can surface latent type bugs; run the tests right
  after adding it.
- Jumping straight to PHPStan level 6 can bury you in findings — ratchet up one
  level at a time and keep tests green between steps.
