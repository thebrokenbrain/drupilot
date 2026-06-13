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

## 1. What "Drupal 11 way" means

Apply these where they fit the code (do not force them where they do not):

- **PHP 8 attributes for plugins** instead of doc-block annotations. Examples:
  `#[Block(...)]`, `#[FieldType(...)]`, `#[FieldFormatter(...)]`,
  `#[FieldWidget(...)]`, `#[Action(...)]`, `#[QueueWorker(...)]`,
  `#[EntityType(...)]`. Move the metadata from the `@Annotation` doc block into
  the attribute; remove the now-unused `use Drupal\...\Annotation\...;`.
- **Dependency injection** instead of `\Drupal::service('...')` calls. Implement
  `ContainerFactoryPluginInterface::create()` for plugins or
  `ContainerInjectionInterface` for controllers/forms; inject services through
  the constructor. Use **constructor property promotion** to keep it tidy.
- **Strict types and typing.** Add `declare(strict_types=1);`, type method
  parameters and return types, type class properties. Use `final` on classes not
  designed for extension. Replace `array` blobs with value objects/enums where it
  clarifies intent — but stay behavior-preserving.
- **Modern APIs.** Replace anything deprecated through D11.4 with its current
  equivalent (entity query `->accessCheck()`, the messenger service, typed config,
  the current routing/event APIs, etc.). Target **zero** deprecations.
- **Twig 3 / CKEditor 5 / jQuery** — finish any non-mechanical migration deferred
  from Phase 1 (custom Twig extensions, editor plugins, JS without jQuery UI).

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
- The full applicable test suite **green** (anything skipped is documented).
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
