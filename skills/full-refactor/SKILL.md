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

**The upgrade plan.** Every version this procedure needs (target major, test-bed
core, declared range, PHP floor and target, Rector sets, names) comes from it,
never from the examples below (AR-26). The block is the working directory's: when it
names no module, or a module other than the subject, run `plan show --subject <subject_dir>`:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/drupilot.sh" plan show 2>/dev/null || true`

If no "drupilot plan" block appears above, run: bash "${CLAUDE_PLUGIN_ROOT}/scripts/drupilot.sh" plan show

## 0. Golden rules

- **Phase 1 must be complete first.** If the module still has blocking
  deprecations, go back to `minimal-port`. Do not mix phases.
- **Keep tests green throughout.** Refactor in small, verifiable steps; run the
  suite after each meaningful change. If a test goes red, fix it before moving
  on. Never silence a failing test.
- **Explain every significant change.** Phase 2 changes architecture; the user
  must understand each one. Nothing changes silently.
- **Log every divergence the moment it happens** (as in `minimal-port` §0):
  a Rector change reverted or rewritten by hand, a script's verdict
  overridden, a prescribed step skipped, a fix made after a gate or a test
  caught a problem, a test whose form changed, a behavior change a reviewer
  must check. A divergence that is not logged is a defect.

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/log-decision.sh" --subject <path> \
    --kind <rector-revert|post-port-fix|script-divergence|skip|manual-override|tooling-deviation|test-adaptation|behavior-change|preexisting-bug> \
    --what "<what you did>" --why "<why>" [--rule <Rector rule>] [--file <path>] \
    [--script <script>] [--detected-by <tool>] [--review-hint "<how to review>"] --phase refactor
  ```
- **Raise the bar deliberately.** Use `DRUPILOT_PHPSTAN_LEVEL_REFACTOR`
  (default `6`) for this phase, not the Phase 1 default of 2.
- **Respect the PHP target.** Modern syntax (attributes, typed properties,
  constructor property promotion) is gated by `DRUPILOT_PHP_TARGET`; see the
  `php-target-tuning` skill (and the PHP 8.5 caveat: it needs Drupal 11.3 or
  later, and no Rector `php85` set is assumed).
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
  Do it with the deterministic pass of §1a, not by hand; hand-convert only what
  it reports as unsupported, skipped or restored.
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

## 1a. Annotations → attributes: the deterministic pass (`attributes` scope)

`scripts/analysis/convert-attributes.sh` (also `run-rector.sh --attributes`)
runs drupal-rector's `AnnotationToAttributeRector` (shipped by
palantirnet/drupal-rector 1.1.x, as by 0.21.x, but configured in no set) with a config it
renders from `templates/rector-attributes.php.tmpl` into
`<root>/.drupilot/rector-attributes.php`. Dry run first, review, then apply:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/convert-attributes.sh" --subject "<path>" --mode strip --json
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/convert-attributes.sh" --subject "<path>" --mode strip --apply --json
```

- **Mode follows the core target (§1b).** `strip` (remove the annotation) when the
  requirement is `^11`; a type whose attribute class is newer than the declared
  floor keeps its annotation next to the attribute (`action: keep`, listed with
  the reason) — the pass never raises the floor on its own. `--raise-floor`
  strips those too and rewrites `core_version_requirement` in every `*.info.yml`
  to `recommended_requirement` (e.g. `^11.1` once an entity type is converted):
  only with the developer's explicit agreement, it is a BC break. When `^10 || ^11`
  is deliberately kept, use `--mode keep` (attributes added, annotations kept,
  BC) and apply the `recommended_requirement` it reports so the declared floor
  covers the attribute classes (PHPStan on an older core reports them unknown).
- **Supported core types** (`config/plugin-attributes.json`, each verified
  against drupal/core source with the minor that ships its attribute class and
  makes its manager discover it): `Action`, `Block` (10.2); `Archiver`,
  `Condition`, `DisplayVariant`, `PageDisplayVariant`, `EntityReferenceSelection`,
  `FieldFormatter`, `FieldWidget`, `FieldType`, `ImageToolkit`,
  `ImageToolkitOperation`, `Layout`, `Mail`, `QueueWorker`, `RenderElement`,
  `FormElement`, `DataType`, `Constraint`, `Editor`, `Filter`, `HelpSection`,
  `ImageEffect`, `LanguageNegotiation`, `SectionStorage`, `MediaSource`,
  `MigrateDestination`, `MigrateProcessPlugin` → `#[MigrateProcess]`,
  `MigrateField`, `RestResource`, `SearchPlugin` → `#[Search]`, `WorkflowType`
  and every `Views*` plugin type (10.3); `EntityType`, `ContentEntityType`,
  `ConfigEntityType` (11.1); `MigrateSource` (11.2). `CKEditor5Plugin` is not
  supported (nested annotation objects): convert it by hand.
- **Custom plugin types** (project or contrib, e.g. `ExtraFieldDisplay`): declare
  them in `DRUPILOT_ATTRIBUTE_PLUGIN_TYPES` (env or `.drupilot.json`) as
  `Annotation=Fully\Qualified\AttributeClass[@MAJOR.MINOR]`, comma-separated.
  A custom type is converted only when its attribute class exists under the
  Drupal root, and stripped only when a plugin manager references the class
  (an annotation-only manager would no longer find the plugin).
- **What the pass guards.** Attributes are printed fully qualified; a file
  already carrying a short-named attribute with a converted type's short name
  is skipped (`skipped_files`: finish it by hand), because the rule takes any
  attribute of that short name for the converted one;
  so is a file whose annotation has a key the attribute constructor does not
  declare (e.g. `source_module` on `@MigrateSource`: core's MigrateSource
  attribute takes only id, requirements_met, minimum_version and deriver, so
  the attribute would fatal at discovery — the annotation is kept, as core does;
  the parameters are read from the attribute class in the test-bed core and in
  the cached reference cores); after `--apply` a duplicate attribute, a `php -l`
  failure or a PHPStan level-0 error naming a converted attribute class restores
  the file from a pre-run backup (`restored_files`, `phpstan_check`); a class constant the annotation named
  by a namespace-relative qualified name (`type = Drupal\filter\Plugin\FilterInterface::TYPE_…`)
  is fully qualified (`\Drupal\…`), otherwise PHP resolves it inside the
  plugin's namespace and plugin discovery fatals. A re-run is a no-op.
- Afterwards, `run-phpcs.sh --fix` removes the now-unused annotation `use`
  statements; report the JSON's `rule_hits` in the summary (the pass keeps no
  state file).

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

Then refreeze the final upgrade plan for the range you applied, so the PHP floor
of `rector.php` and `phpstan.neon` follows it (ADR 0018, ADR 0020; `^11` raises
the floor to the target's PHP):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/upgrade-path.sh" --subject "<path>" --phase final \
  --range "<the core_version_requirement you applied>" --root "<drupal_root>" --freeze --json
```

Exit 2 (`final-changes-frozen`: another target, PHP target or test-bed) means the
refactor would change what the setup planned: stop and say so.

## 2. Refactor loop

Before the first change, freeze the post-port suite as the refactor's baseline,
so a later red test is classified as a regression of the refactor or as a failure
that already existed (`pre-existing-failures`):

```bash
# Promote the last (post-port) run; or take a fresh one with --baseline.
bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/run-phpunit.sh" --subject "<path>" --baseline-from-last
```

Then check the subject against the project's learned-pattern catalog — the
pitfalls earlier ports and refactors of this project hit (read-only, exit 0;
`--catalog <file>` when a batch context passes one):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/patterns.sh" scan --subject "<path>" --json
```

Every hit is a must-check item for this refactor (the recorded fix is the
starting point, the golden rules still decide). Nothing to keep for the
manifest: the learned patterns live in the project's catalog (`patterns.sh
list`).

Work one concern at a time. After each change, re-run the validate loop and the
relevant tests:

```bash
# Coding standards: auto-fix then verify (must end clean):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpcs.sh" --subject "<path>" --fix

# phpstan.neon's refactor profile, once per refactor (every phpstan-drupal rule;
# Phase 1's compat profile leaves its opinion rules off; exit 3 = a hand-edited
# phpstan.neon, kept as it is):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/render-templates.sh" --subject "<path>" --only phpstan --profile refactor

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
`--no-verify`, and any substitution kept by `git-hooks.sh --run-equivalents` in
`hooks-substitution.json`, which `port-report.sh` reads. `run-phpstan.sh` runs against the
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
  `ineffective` test is strengthened and re-controlled, never accepted. The
  script keeps every result in `negative-controls.json` (state dir), which
  `port-report.sh` reads; `port-report.md` lists them.
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
  one does); it keeps its verdict in `core-matrix.json`, from which
  `manifest.sh` takes `d10_support` and which `port-report.sh` reads.
- `classify-deprecations.sh --file <phpstan.json> --subject <path> --phase refactor
  --json` reports `blocking: 0` and every soft item fixed, or documented with its
  `defer` reason (no replacement usable at the declared core floor).
- The full applicable test suite **green** (anything skipped is documented). Because
  Phase 2 changes more code, this is the **preservation gate**: the same tests that
  passed after Phase 1 must still pass, unchanged in what they verify. If the module
  has no tests, state that preservation is **not verified** for the refactor and
  recommend adding tests before/with it.
  Against the post-port baseline the verdict must not be `regression`; a
  `pre-existing-failures` or `not-verified-unbaselined` verdict is reported with
  its list, never presented as green.
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

**Record what this refactor learned** (before the report), exactly as
`minimal-port` §8: `patterns.sh harvest --subject "<path>" --json` lists the
candidates, each pitfall worth preventing gets a detector matching the
pre-refactor code (a POSIX ERE and/or `port-safety:<check>` /
`signature:<id>`), and `patterns.sh add --subject "<path>" --id <slug> --kind
<kind> --pattern '<ERE>' [--rule <ref>] --why "<why>" --fix "<fix>"` records
it (the command asks which; an autonomous run records only detectors it
checked and lists their ids).

**The fixpoint gate.** Run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/fixpoint.sh" --subject "<path>" --stage refactor --json`
before the report: Rector, the codemods and the processed lanes must have
nothing left (`DRUPILOT_FIXPOINT`: `warn` reports, `enforce` exits 3).

**Refresh the didactic report.** Tee the Phase 2 Rector + final PHPStan
deprecation output into `<state_dir>/change-log.txt` (under `$HOME`, never in the
project tree), regenerate `<state_dir>/port-manifest.json` with
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/ai/manifest.sh" --subject "<path>" --phase refactor --rationale "<state_dir>/rationale.json"`
(it builds every field from the scripts' records; your only input is the why of
the items you changed by hand, `{"<worklist item id>": "why"}`; every
architectural change a reviewer must check is a `behavior-change` entry of
`log-decision.sh`), and
re-render with `port-report.sh --subject <path> --manifest <manifest>
--changes-log <state_dir>/change-log.txt` so `port-report.md` in the visible
`.drupilot/` dir reflects Phase 2 and its "changes, explained" section (it
also refreshes the machine summary `port-summary.json`; `manifest.sh` fills `files_changed`).

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
