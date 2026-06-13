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
  argument for services. Use constructor property promotion. Leave `\Drupal::`
  only in procedural `.module`/`.install` hooks where DI is unavailable.
- **`declare(strict_types=1);` in EVERY `.php` file** under `src/` and `tests/`.
  Add parameter, return and property types wherever the type is known and
  unambiguous.
- **`final` by default.** Mark a class `final` UNLESS it is abstract, an
  interface, a `*Base` class, or another class in the module/its tests extends it.
  (Plugins and services are normally `final`.)
- **Zero deprecations.** Replace every API deprecated through D11.4 with its
  current equivalent (entity query `->accessCheck(TRUE)`, the `messenger` service,
  typed config, current routing/event APIs). Target the refactor PHPStan level
  clean with **no** deprecation notices.
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
deliberately keep `^10 || ^11` (an explicit override), the helper returns
`require.php: ">=<target>"` — add it to `composer.json`. State the version-bump
implication (new major branch) in the summary.

## 2. Refactor loop

Work one concern at a time. After each change, re-run the validate loop and the
relevant tests:

```bash
# Coding standards: auto-fix then verify (must end clean):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpcs.sh" --subject "<path>" --fix

# Static analysis at the refactor level (5-6):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpstan.sh" --subject "<path>" \
  --level "$(config_get DRUPILOT_PHPSTAN_LEVEL_REFACTOR 6)"

# Re-run the affected test group(s) (see test-adaptation for the full flow):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/run-phpunit.sh" --subject "<path>" --type all
```

`run-phpcs.sh --fix` runs `phpcbf` then `phpcs --standard=Drupal,DrupalPractice`
with the PROMPT §2.3 extension list. `run-phpstan.sh` runs against the
`phpstan.neon` at the Drupal root. Reference commands:

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
- The full applicable test suite **green** (anything skipped is documented). Because
  Phase 2 changes more code, this is the **preservation gate**: the same tests that
  passed after Phase 1 must still pass, unchanged in what they verify. If the module
  has no tests, state that preservation is **not verified** for the refactor and
  recommend adding tests before/with it.
- Plugins use attributes; services are injected; strict types are in place where
  appropriate.

## 5. Report

Summarize (in English): each significant change and why (annotations →
attributes, `\Drupal::` calls → DI, types/`final` added, deprecated APIs
replaced), the final PHPStan level reached, PHPCS status, the test results +
coverage, and any documented exception. Note that the module now follows the
Drupal 11 way and is a candidate for `/drupilot-contribute`.

## Gotchas

- Do not start Phase 2 on a module that still has Phase 1 blocking deprecations.
- Annotation → attribute conversion must move **all** metadata and drop the unused
  annotation imports; a half-converted plugin can fail discovery.
- DI via `create()` requires the right interface
  (`ContainerFactoryPluginInterface` for plugins vs `ContainerInjectionInterface`
  for controllers/forms) — mismatching them breaks instantiation.
- `declare(strict_types=1);` can surface latent type bugs; run the tests right
  after adding it.
- Jumping straight to PHPStan level 6 can bury you in findings — ratchet up one
  level at a time and keep tests green between steps.
