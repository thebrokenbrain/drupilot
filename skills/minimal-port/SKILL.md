---
name: minimal-port
description: >-
  Use this skill for Phase 1 — minimal Drupal 9/10 → Drupal 11 compatibility — i.e.
  when running /drupilot-port or when the user asks to "port", "make it work on
  Drupal 11", "fix deprecations", or "apply rector". It performs the three Rector
  passes (official palantirnet/drupal-rector, then the optional AI-generated
  drupal-digests layer filtered by the Drupal target, then optional ad-hoc rule
  generation), applies the minimal manual changes Rector cannot make
  (core_version_requirement, mechanical Twig/CKEditor/jQuery fixes), and runs the
  validate loop (phpcbf → phpcs → phpstan) until the module compiles with no
  blocking deprecations. It preserves the original functionality and does NOT
  refactor or collide with Drupal 11 native APIs. Do NOT use it for the
  "Drupal 11 way" rewrite — that is the full-refactor skill (Phase 2).
allowed-tools: Bash, Read, Edit, Write
---

# Phase 1 — minimal port

Goal: make the module/theme run on Drupal 11 with **identical functionality**,
the smallest set of changes, and **no architectural rewrite**. Do not collide
with APIs Drupal 11 now provides natively. Anything bigger is deferred to Phase 2
(`full-refactor`). Everything is driven through the leaf scripts under
`${CLAUDE_PLUGIN_ROOT}/scripts/analysis/`.

**The upgrade plan.** Every version this procedure needs (target major, test-bed
core, declared range, PHP floor and target, Rector sets, names) comes from it,
never from the examples below (AR-26). The block is the working directory's: when it
names no module, or a module other than the subject, run `plan show --subject <subject_dir>`:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/drupilot.sh" plan show 2>/dev/null || true`

If no "drupilot plan" block appears above, run: bash "${CLAUDE_PLUGIN_ROOT}/scripts/drupilot.sh" plan show

## 0. Golden rules

- **Gate `analyze` first.** Static port needs git + jq + (composer OR php ≥
  target). Heavier passes that run in DDEV inherit the environment from
  `ddev-environment`.
- **Dry-run → review the diff → apply → validate.** Never apply Rector (and
  *especially* never apply digests rules) blind.
- **Preserve behavior.** Phase 1 changes APIs, not architecture. Do not introduce
  DI refactors, attributes, strict types, or `final` here.
- **Resolve the PHP and Drupal targets** via `resolve_php_target` /
  `resolve_drupal_target` (see the `php-target-tuning` skill). Rector's PHP
  level follows the floor of the declared core range and `require.php`, never
  above the target (ADR 0002).
- **Log every divergence the moment it happens.** Whenever you revert or
  hand-edit a change Rector made, ignore or override a script's verdict, skip
  a step this flow prescribes, fix something validation caught after the port,
  change a test's form, leave a pre-existing bug unfixed, or introduce a
  behavior difference a reviewer must check, record it with WHAT and WHY. A
  divergence that is not logged is a defect: the report would present the
  tool's output as kept.

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/log-decision.sh" --subject <path> \
    --kind <rector-revert|post-port-fix|script-divergence|skip|manual-override|tooling-deviation|test-adaptation|behavior-change|preexisting-bug> \
    --what "<what you did>" --why "<why>" [--rule <Rector rule>] [--file <path>] \
    [--script <script>] [--detected-by <tool>] [--review-hint "<how to review>"]
  ```

  It appends to `<root>/.drupilot/decisions.jsonl` and regenerates
  `decisions.md` beside it; `port-report.sh` and `layer-report.sh` read it.

### Port-safety rules (each one broke a real port)

- **Never remove `implements ContainerFactoryPluginInterface`** (or
  `ContainerInjectionInterface`) from a class that defines `create()`, and never
  assume a `*Base` class implements it for you. `QueueWorkerBase`, `BlockBase`,
  `FilterBase`, `ActionBase`, `ConditionPluginBase` and core `PluginBase` do
  **not** (`FormatterBase`, `WidgetBase`, views' `PluginBase`, `FormBase` and
  `ControllerBase` do). Removing it = `ArgumentCountError` at runtime (cron,
  filters). Verify in the core tree, not from memory.
- **Never remove a `use` statement** without grepping that its short name is no
  longer referenced in the file (code *and* PHPDoc types).
- **Never change `new static(` to `new self(`** in a `create()` factory (or
  anywhere) — not even to silence the sandbox PHPStan "Unsafe usage of new
  static()". Leave it and note it (Phase 2 may make the class `final`).
- **Never turn Form/Render API callbacks into closures.** `[$this, 'method']`,
  `[static::class, 'method']`, `'::method'` and function-name strings stay as
  they are under `#ajax` `callback`, `#submit`, `#validate`, `#element_validate`,
  `#process`, `#pre_render`, `#after_build`, `#value_callback`, `#lazy_builder`
  ...: a first-class callable `$this->method(...)` is a closure, closures are not
  serializable, and a cached form (AJAX, form state cache) fatals.
- **No `private`/`readonly` properties in serialized classes** (forms, plugins —
  anything using `DependencySerializationTrait`): keep injected services
  `protected` and non-readonly.
- **No `#[\Override]` in Phase 1.** While `core_version_requirement` still spans
  Drupal 10 (or an older 11.x minor), the parent method may not exist there
  (e.g. `ContentEntityStorageBase::buildRevisionCacheId()` exists only from 11.3)
  and PHP 8.3+ fatals at compile time ("has #[\Override] attribute, but no
  matching parent method exists"). Rector judges it against the ONE sandbox core,
  so it cannot see this. `#[\Override]` on a method that exists only in some of
  the declared cores breaks the others — Drupal 10 first. The core matrix (§6a)
  is what proves it: PHPStan on a real Drupal 10 core reports "has #[\Override]
  attribute but does not override any method".
- **Core signature changes are fixed in the module, D10-safely.** A
  `ConfigFormBase` subclass forwards `TypedConfigManagerInterface` (required from
  11.0: pass `$container->get('config.typed')`; PHP ignores the extra argument on
  older 10.x), a `ContentTranslationController` subclass forwards `TimeInterface`,
  a hook gaining a parameter in a later minor (`hook_entity_operation()` /
  `_alter()` get `CacheableMetadata $cacheability` from 11.3) only ever gets it as
  an OPTIONAL parameter while the floor is lower, and a module method whose name
  core later adds (`getOriginal()`/`setOriginal()` from 11.2,
  `buildRevisionCacheId()` from 11.3) is renamed (callers updated) unless the
  override is intended. `scan-signature-changes.sh` (§6) lists every collision
  with the verified catalog.
- **A sandbox PHPStan finding is never "fixed" by changing semantics** unless the
  original project tolerates the change. Findings caused by the sandbox itself
  (missing contrib/custom dependencies, classes from modules that are not
  installed) are documented in the report as *sandbox-only*, not patched. No
  casts/guards added only to satisfy the sandbox level.
- **Symbols newer than the kept core floor only through
  `DeprecationHelper::backwardsCompatibleCall()`** (it exists on the 10.1.x
  branch and later, not in 10.0 — a floor below 10.1 cannot use it). When
  keeping `^10 || ^11`, a replacement API that does not exist on the lowest
  declared core (e.g. the `TextSummary` service, `getOriginal()` from 11.2)
  breaks Drupal 10; wrap it, or leave the soft-deprecated call and report it.
- **Soft deprecations follow one policy, `DRUPILOT_SOFT_DEPRECATIONS`
  (`report` default | `defer` | `fix`).** `classify-deprecations.sh` (§6) splits
  what PHPStan reports: **hard** = removed in a major ≤ the target major (e.g.
  `user_roles()`/`user_role_names()`, removed in 11.0.0 — PHPStan then says
  "Function user_roles not found.") — always fixed, Phase 1 is not done while one
  is left; **soft** = removed in a later major (e.g. `user_load_by_name()`,
  `user_load_by_mail()`, `text_summary()`, `check_markup()`,
  `user_cookie_save()`: deprecated in 11.4.0, removed from 13.0.0) — they keep
  working on every Drupal 11 core. `report` leaves soft calls untouched and lists
  them in the report; `defer` lists them under "deferred to Phase 2"; `fix` follows
  each item's `action`: `fix` (replacement exists at the declared core floor, e.g.
  `loadByProperties()`), `fix-guarded` (replacement only on newer cores, e.g. the
  `TextSummary` service from 11.4 → `DeprecationHelper::backwardsCompatibleCall()`)
  or `defer` (no replacement usable at the floor). Never "fix" a soft deprecation
  in a way that breaks a core the module still declares, and never silence one
  (no baseline/ignore entries). An **unknown** item (removal version unreadable,
  or a missing symbol the catalog does not date) is blocking until reviewed.

The template `rector.php` already skips the Rector rules behind several of these
(`ArrayToFirstClassCallableRector`, `AddOverrideAttributeToOverriddenMethodsRector`,
`ReadOnlyPropertyRector`, `ReadOnlyClassRector`,
`NullToStrictStringFuncCallArgRector`); the digests pass and your own edits do not
inherit those skips, so `check-port-safety.sh` (§6) re-checks the result.

## 1. Gate

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile analyze
```

Exit `2` → show the report and stop, no side effects.

**Pre-port test baseline.** Before Pass 1 touches anything, record the suite on
the untouched code (skip it when the subject ships no tests):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/run-phpunit.sh" --subject "<path>" --type all --baseline
```

It writes `test-baseline.json` (state dir; `last-test.json` is untouched) and
exits `0` even when red. Every later run then classifies each failing test as
`pre-existing` (red before the port too) or a `regression` (green before), and
the verdict becomes `pre-existing-failures` when no test regressed. A test the
baseline could not meaningfully run (the un-ported module refused on Drupal 11
— "incompatible with this version of Drupal core" — or a crashed group) is
`not-baselined`, never pre-existing, and keeps the verdict at
`not-verified-unbaselined`. Exit `2`
(the test environment is not up) never blocks the port: report that no baseline
was taken (every later failure then counts as a regression).

**Learned patterns (prevention).** Before Pass 1, check the subject against the
project's catalog of pitfalls earlier ports already hit (`patterns.sh`; one
catalog per project at `<Drupal root>/.drupilot/patterns.json`, shared by a
`/drupilot-layers` set — pass `--catalog <file>` when the batch context gives
one):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/patterns.sh" scan --subject "<path>" --json
```

Read-only, always exit `0`. Each hit (`hits[]`: `id`, `file:line`, `why`, `fix`,
`via` = the ERE or the `port-safety:`/`signature:` rule that matched) is a
**must-check item**: keep it in your running list, apply the recorded fix where
it fits as you go (the fix is the starting point, not an automatic edit — the
golden rules above still decide), and confirm each one is resolved before §8.
No catalog yet, or no hit, is normal for the first module. Keep the JSON for the
manifest (`learned_patterns.scan`, §8).

## 2. Pass 1 — official Rector (palantirnet/drupal-rector)

The stable, community-maintained pass. Covers deprecations D10.0 → D11.4. Always
runs first.

```bash
# Dry-run (default — writes nothing):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "<path>"

# Review the printed diff/summary, then apply:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "<path>" --apply
```

**Exit 3 = the official Rector pass or the compat pass after it crashed** (`errors[].pass` 1 or 3;
a compat-only crash points at `rector-compat.php` first — regenerate it with
`render-templates.sh --only rector-compat --force`) (e.g. `[ERROR] Could not detect twig set.` from an
incompatible `rector/rector`, a PHP fatal, or per-file processing errors): the
`--json` payload has `status: "error"` and `errors[]` with the message, and there
is **no verdict** — never read it as "0 files would change". Stop, show the
diagnostic (installed vs known-good versions), repair the toolchain with
`install-toolchain.sh --dir <drupal_root> --source reference` (or fix `rector.php`
when the toolchain already matches the known-good set), and re-run.
A message that starts with `DET-1:` (exit 3; `errors[].pass` 0 for Rector, `.drupilot.crash` for
PHPStan, `.drupilot.error` for PHPCS) is not a crash: the tool did not run, because DDEV is down for a
root that has a DDEV project, or an installed tool differs from the version the lock pins. Start DDEV,
or restore the pins (`install-toolchain.sh --dir <drupal_root>`) or accept the installed versions
(`lock-sync.sh --dir <drupal_root>`), then re-run; `DRUPILOT_DETERMINISTIC=false` accepts the run as it is.

`run-rector.sh` `cd`s to the Drupal root, uses `RUNNER=$(drupal_runner)`
(`ddev exec` when the env is up), and ensures a `rector.php` exists at the root
(rendered from the plugin's `rector.php.tmpl`; the vendor example is only a
legacy fallback). The config uses the upgrade plan's Drupal sets
(`rector.drupal_sets` and `rector.breaking_sets`: each hop's set family per minor up to the test-bed's minor, plus the edge's always and breaking sets (ADR 0019; for a port from Drupal 10 to 11, `DRUPAL_100` to `DRUPAL_103`): read them from the plan block) and the PHP floor L
of the declared core range and `require.php` (`->withPhpVersion()` and the level
sets stop at L: 8.1 for `^10 || ^11`), minus the risky modernization rules
listed in §0. When L is below 8.4, a narrow compat pass (`rector-compat.php`)
runs right after it and fixes only implicitly nullable parameters (`Foo $x =
NULL` -> `?Foo $x = NULL`, valid on L); its hits are `rule_hits.compat`. A
`rector.php` generated by an older drupilot template, or an untouched render
for another floor, is backed up to `.drupilot/backups/` and regenerated; a
hand-written one is never replaced. Reference commands:

```bash
cp vendor/palantirnet/drupal-rector/rector.php .
vendor/bin/rector process web/modules/custom/MODULE --dry-run
vendor/bin/rector process web/modules/custom/MODULE
```

Rector needs the Drupal core tree present (no database). Review the summary of
changed files / rule hits before applying.

## 3. Pass 2 — complementary digests layer (optional, filtered by target)

Only when `DRUPILOT_USE_DIGESTS_RULES=true`. The `dbuytaert/drupal-digests` repo
is a **Git repo, not a Composer package**: 177 AI-generated rules
(`rector/rules/*.php`, one per core issue) aggregated by `rector/all.php`.

```bash
# Always dry-run first; digests run AFTER official rector. run-rector.sh resolves
# the ref itself (default 'main', frozen per-project in the lockfile when
# deterministic); pass --digests-ref only to force a specific commit/tag:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" \
  --subject "<path>" --digests

# Review the diff carefully, then:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" \
  --subject "<path>" --digests --apply
```

`run-rector.sh --digests` clones/updates the repo into `digests_cache_dir`,
checks out the resolved ref/SHA and **verifies** it (recloning rather than
silently reusing a stale cache), stages it under the Drupal root and runs a
filtered `all.php`: without the rules the official pass already applies
(drupal-rector's `implemented-digests.yml`, frozen in the lock: an entry whose
classes a set of your `rector.php` registers) and without the rules rejected
for this module. drupal-rector's Drupal 11 sets are not loaded on a port to 11,
so the digests rules it implements there still run here. In deterministic mode the SHA that `main` first resolved is
frozen in the per-project lockfile and reused on later runs, so the same project
always applies the same digests rules.

**Verdicts are recorded and replayed.** The `--json` dry-run's `digests_review`
gives each rule's verdict (`accept`, `reject`, `pending`). Review only the
pending ones; record every answer with
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/digests-decisions.sh" --subject <path> --accept <Rule,...> --reject <Rule,...>`.
A later port of the same module with the same digests SHA has no pending rule
and asks nothing; `digests-decisions.sh --clear` (or `/drupilot-clean`)
forgets the verdicts. An autonomous run's recorded defaults are replayed only
by another autonomous run. Record the verdicts before the module changes: an
`--apply` on changed sources refuses the digests pass (exit 4) until a new
dry-run.

**Mandatory handling (PROMPT §2.1.1) — these are non-negotiable:**

1. **No license** → never copy/vendor the rules into the plugin or the project.
   Clone at runtime into the cache and reference by path; allow `git pull` to
   update.
2. **AI-generated, experimental** ("some rules will have bugs, others miss edge
   cases") → dry-run, human-review the diff, apply, then validate with phpstan +
   the test suite. Never apply blind.
3. **Edge-targeting** → many digests rules migrate APIs deprecated in 11.2+ and
   removed in 12.0, which can **raise the effective `core_version_requirement`**
   (breaking 11.0/11.1). **Filter by the declared Drupal target:** if the module
   must support 11.0–11.1 (e.g. `core_version_requirement: ^10 || ^11`), exclude
   rules whose target API does not exist there. When in doubt, prefer not
   applying a rule that would lift the floor above what the project promises.
4. **Order** → official `drupal-rector` first, digests second.

**Exit 4 means only the digests pass crashed** (`status: "partial"`, `digests_status: "error"` with `--json`; e.g. a broken upstream rule file): the official result stands, the toolchain is fine — do **not** reinstall it. Pin a known-good digests commit (`--digests-ref <sha>` / `DRUPILOT_DIGESTS_REF`) or skip the layer (`DRUPILOT_USE_DIGESTS_RULES=false`); the broken SHA is never frozen in the lockfile.

The `issues/*.md` summaries in the repo explain *why* an API changed — useful
context when reviewing a diff, but they are not rules.

**Make the review participatory (G5).** The `/drupilot-port` command renders the
review as a tab (Review and pick / Apply all unflagged / Skip). To support it,
run `run-rector.sh --subject <path> --digests --json` for the structured
`{pass2_files, ...}` view, present a per-rule list (rule → target API/min-version
→ files) with floor-exceeding rules **pre-flagged**, and apply only what the
developer keeps. Before applying, suggest a **git checkpoint**
(`git add -A && git commit -m "wip: before digests"`) so a disliked pass can be
dropped with a single `git reset --hard`. The checkpoint commit runs the
repository's own git hooks like any other commit (see below). In an autonomous
run the safe default is to skip the pre-flagged rules and report them.

**Repository git hooks — never normalize `--no-verify`.** Before any commit
(a checkpoint or the contribution), run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/git-hooks.sh" --subject "<path>" --json`.
It reports the hook managers (GrumPHP, husky, lefthook, pre-commit, CaptainHook,
`core.hooksPath`, plain `.git/hooks` scripts), the commit hooks git would really
run (`active_hooks`), each task's drupilot equivalent and the tasks with none
(`uncovered`). When hooks exist, commit normally and let them run; a slow hook
gets a longer Bash timeout or a background run, not `--no-verify`. Only when a
hook cannot complete in this context: run `git-hooks.sh --subject "<path>"
--run-equivalents`, fix every failure (exit 3), and commit with `--no-verify`
only when `all_green` is true. The PreToolUse guard asks the developer to
confirm that commit (`DRUPILOT_HOOKS_GUARD`), so an autonomous run never skips a
hook: it keeps a hook-free checkpoint with `make-patch.sh --local` instead.
Record what replaced the hook as `verification.commit_hooks` in
`port-manifest.json` (the JSON `--run-equivalents` printed, also kept in
`hooks-substitution.json`), uncovered tasks included; when the hooks simply ran,
record `{"bypassed": false, "note": "hooks ran on commit"}`.

## 4. Pass 3 — ad-hoc rule generation (optional, the "Dries approach")

For deprecations **no** source covers, honor `DRUPILOT_GENERATE_RULES`
(default `ask`):

- `ask` → confirm (use `confirm`) before doing anything outward of reporting.
- `auto` → read the change record / drupal.org issue and either generate a
  reusable ad-hoc Rector rule or apply the change manually with that context.
- `off` → only report the deprecation; touch nothing.

Keep any generated rule minimal and behavior-preserving.

## 5. Minimal manual changes (what Rector cannot do)

Apply only the mechanical, behavior-preserving fixes:

- **`*.info.yml` + composer core target:** decide the target with the helper
  instead of a static flag:

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/core-strategy.sh" --subject "<path>" --phase port --json
  ```

  `/drupilot-port` then freezes the final upgrade plan with the answered strategy
  (`upgrade-path.sh --phase final --root "<drupal_root>" --freeze --json`, or
  `--range '<the draft's .range.constraint>'` and no tab when the draft's range is
  `explicit`, ADR 0021; exit 2: back to `/drupilot-setup`), and the value to apply
  is the plan's, read with
  `plan_get .range.constraint "<drupal_root>"` (and `plan_get .php.require_php`
  for composer's `require.php`): core-strategy shows each option's consequences,
  the plan decides. That range is core-strategy's
  `recommended_core_version_requirement` for the same strategy (`auto` → `^10 || ^11` for a
  BC-preserving port — `^10.N || ^11` when a minor floor was declared (`^10.3`
  stays `^10.3 || ^11`) or the code uses a plugin attribute class that exists only
  from 10.N; `^11.N` when such a class exists only in Drupal 11 — or `^11` on a BC break / `d11-only`) to the main `info.yml`
  **and every submodule's** — a submodule left on `^8.8 || ^9 || ^10` cannot be
  installed on Drupal 11 (core marks it `core_incompatible`):

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/set-core-requirement.sh" --subject "<path>" --requirement '<value>' --dry-run --json
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/set-core-requirement.sh" --subject "<path>" --requirement '<value>' --json
  ```

  It removes the obsolete `core: 8.x` key, adds a missing
  `core_version_requirement` (a hard blocker otherwise), and bumps a test module
  only when it does not admit Drupal 11 (`package: Testing` without the key is
  exempt in core). The other pre-existing metadata problems
  (`lint-extension-metadata.sh`: config schema, `configure:` route, orphan
  services, service arity, undeclared dependencies) are **reported, not fixed** in
  Phase 1 — they go into the port report's "Pre-existing hygiene" table.

  **Two compatibility floors the helper now reasons about — keep them honest:**

  - **PHP floor (`require_php`).** When it is non-null (i.e. keeping `^10 || ^11`),
    add it to the project's `composer.json`: `"require": { "php": "<require_php>" }`.
    Drupal 10 allows PHP 8.1 but the port targets ≥ 8.3, so this blocks a
    D10 + low-PHP site at install instead of fataling at runtime. The helper runs
    `detect-php-floor.sh` (a heuristic scan) and, with `DRUPILOT_REQUIRE_PHP_FLOOR=detect`
    (default), **widens the floor to the detected one** (e.g. `>=8.1` when the code
    uses no 8.2/8.3 constructs) for genuine D10 support; relay any warning that the
    lowered floor is best-effort and should be confirmed with PHPCompatibility. If
    `has_composer_json` is false, the floor **cannot be enforced** — surface that
    warning and add a composer.json or drop to `^11`. For `^11` no `require_php` is
    needed (core enforces it). The same scan also reports
    `php_floor_target_compatible`: if **false**, the code uses a construct newer than
    the target (e.g. an 8.4 feature with target 8.3) that would fatal on Drupal 11 —
    raise `DRUPILOT_PHP_TARGET` or remove it, and do not call the port done. The
    authoritative check that the port runs on the target is the test suite executing
    on the target PHP version (the preservation gate).
  - **Drupal-minor floor (`d10_support`).** A `^10 || ^11` port is emitted as
    `declared-not-verified` until the **core matrix** (§6a) checks it: Rector's
    standard replacements usually exist across all of Drupal 10, but only an
    analysis against a real Drupal 10 core proves it. Relay the helper's
    `warnings` (if the port uses an API added in a later minor, it should be
    `^10.3 || ^11`; if absent from D10, `^11`), run §6a, and report the verdict it
    returns (`verified-static` / `verified-static-above-floor` / `failed` / still `declared-not-verified` when it
    could not run). Carry the helper's `suggested_remaining_tasks` into the
    contribution issue (`make-issue.sh --d10-unverified`; it reads the matrix and
    narrows the item to "run the suite on Drupal 10" once the static check passed).
    The helper's `verify_cores` lists the legs the matrix will check.

  State the chosen `core_version_requirement`, the `require_php` (and its detected
  floor), the `d10_support` status and the `version_bump` verdict in the chat
  summary. Do not silently overwrite a `core_version_requirement` the user already
  hand-tuned — if it differs from the recommendation, say so and confirm.
- **Twig 3:** removed filters/functions; the `{% spaceless %}` tag is gone (use
  whitespace control, `{%- -%}` / `{{- -}}`; never the `spaceless` filter, which
  is deprecated since Twig 3.12) — only when mechanical.
- **CKEditor 5:** CKEditor 4 was removed in D10; migrate config/text-format
  references mechanically where possible.
- **jQuery / jQuery UI:** `core/jquery.ui.*` libraries were removed/externalized;
  update library dependencies.
- Symfony 7 / Guzzle 7 / PHPUnit 10-11 signature touch-ups when purely
  mechanical; anything that needs real redesign is **deferred to Phase 2**.

Do not add features or change behavior. If a fix would require architectural
change, note it for Phase 2 instead of doing it here.

**Optional — plugin annotations → attributes (opt-in, `/drupilot-port` Step 6b).**
Annotations still work on Drupal 11, so this is never part of a minimal port by
default. The developer may opt in through a tab (default: skip; an autonomous
run skips): `convert-attributes.sh --mode keep --max-since 10.3 --raise-floor
--apply --json` adds `#[...]` attributes next to the kept annotations for the
types whose attribute class exists on Drupal 10.3 and **raises
`core_version_requirement` explicitly** to its `recommended_requirement`
(`'^10 || ^11'` → `'^10.3 || ^11'`; `Block`/`Action` alone need 10.2), because
PHPStan on an older core reports the attribute classes as unknown. Strip mode is
Phase 2 only (`full-refactor` §1a). The raised floor is a BC break: re-read the
version bump from `core-strategy.sh` and let §6a verify the new floor.

## 6. The validate loop (after each batch of changes)

Run until clean — never silence findings:

```bash
# 1. Auto-fix coding standards in the files the port changed, then re-check
#    the whole subject (report only for the untouched files):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpcs.sh" --subject "<path>" --fix --fix-scope changed

# 2. Static analysis at the deprecation level (default 2):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpstan.sh" --subject "<path>" \
  --level "$(config_get DRUPILOT_PHPSTAN_LEVEL 2)"

# 3. Deterministic port-safety checks (gate: must exit 0):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/check-port-safety.sh" --subject "<path>" --json

# 4. Core signature changes vs the declared core floor (gate: must exit 0):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/scan-signature-changes.sh" --subject "<path>" --json

# 5. Hard vs soft deprecations under DRUPILOT_SOFT_DEPRECATIONS (gate: blocking == 0):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpstan.sh" --subject "<path>" --json \
  > "<state_dir>/phpstan.json" || true
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/classify-deprecations.sh" \
  --file "<state_dir>/phpstan.json" --subject "<path>" --json

# 6. Pre-existing metadata hygiene (report only, always exit 0; after §5's bump
#    `submodule-core-req` must have no warning — the rest goes into the report):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/lint-extension-metadata.sh" --subject "<path>" --json
```

`classify-deprecations.sh` (read-only, no toolchain) reads PHPStan's JSON (or
plain text), takes deprecated-in/removed-in from each message and the
replacement, its first core and the effort from the verified `lifecycle` catalog
in `config/deprecations.json`, and returns `{policy, blocking, counts, symbols,
hard, soft, unknown}`. **`blocking` must be 0** (no hard or unknown item left);
the soft items are handled per their `action` (see §0) — under the default
`report` they stay as they are. Run it again after any fix, and keep its JSON for
the manifest (§8).

`check-port-safety.sh` (read-only, no toolchain) flags: a `create()` without
`ContainerFactoryPluginInterface`/`ContainerInjectionInterface` in the class or
its real ancestry (read from the Drupal root's core/contrib), a `use` the port
removed while still referenced, `new self(` in `create()`, first-class
callables/closures under Form/Render API callback keys, `private`/`readonly`
properties in `DependencySerializationTrait` classes, `#[\Override]` while the
core range spans Drupal 10, and services/routing class names whose case differs
from the file. Each finding says whether the port **introduced** it (diff against
the same pre-port git base as the local patch; `--base REF` to override) and gets
its severity from `config/port-checks.json`. **Exit 3 = error findings: the stage
is not done** — fix them (restore the interface/`use`/`new static`/array
callable, make the property `protected`, drop an added `#[\Override]`), never suppress them. Warnings are
reviewed and listed in the report. Exit 0 with warnings is fine. An `#[\Override]`
on a method the signature catalog dates (e.g. `buildRevisionCacheId()`, 11.3) is
an error whenever the declared floor is below that minor, even for `^11`.

`scan-signature-changes.sh` (read-only, no toolchain) checks the subject against
the verified catalog of Drupal 10 → 11 **signature** changes
(`.signature_changes` in `config/deprecations.json`), judged against the core
FLOOR of the declared `core_version_requirement` (`^10 || ^11` → 10.0,
`^10.3 || ^11` → 10.3; `--core-floor X.Y` overrides): a constructor passing too
few arguments to `ConfigFormBase`/`ContentTranslationController` (error), a
method that collides with one core added later (`getOriginal()`/`setOriginal()`
11.2, `buildRevisionCacheId()` 11.3: error when its signature is incompatible or
it carries `#[\Override]` below the floor, warn when it silently becomes an
override), a `hook_entity_operation()`/`_alter()` implementation that REQUIRES
the 11.3 parameter while the floor is lower (error), and calls of APIs newer than
the floor (warn). **Exit 3 = error findings: fix them** with each entry's `fix`
(D10-safe, see §0); `info` findings (e.g. a one-parameter
`hook_entity_operation()`) need no change. Tee the human output
(`[signature:<id>] ...` lines) into `change-log.txt` so the report explains it.

`--fix-scope changed` limits `phpcbf` to the files that differ from the
pre-port git base (the same base as the local patch) plus new files, so Phase 1
never reformats a file the port did not touch (trailing commas, an EOF newline in
a config YAML): those violations are pre-existing and stay in the report. Run the
validate loop after a batch of edits is complete, not between an added `use` and
the code that needs it — `phpcbf` removes a `use` it sees as unused (the
post-edit hook, which runs after every edit, skips the unused-use sniffs in
Phase 1 for that reason). Without git
the autofix is skipped (report only). Phase 2 (`full-refactor`) keeps the
default `--fix-scope all`.

`run-phpcs.sh --fix` runs `phpcbf` first then `phpcs` with
the subject's **own** PHPCS ruleset when it ships one (`.phpcs.xml`,
`phpcs.xml`, `.phpcs.xml.dist` or `phpcs.xml.dist`, found from the subject up to
the Drupal root, its git top level, or the origin checkout of a copy placement;
drupilot's generated `phpcs.xml.dist` never counts), else
`--standard=Drupal,DrupalPractice` with the extension list from PROMPT §2.3
(`php,module,inc,install,test,profile,theme,info,txt,md,yml`). It always passes
`--runtime-set testVersion <target>-` (PHPCompatibility otherwise fails with
"trim(): Passing null" when a ruleset declares testVersion as a `<property>`
inside a `<rule>`), never overriding a ruleset's own `<config name="testVersion">`.
A project ruleset PHPCS cannot load (e.g. it references PHPCompatibility, not
installed in the test-bed) is reported and the run falls back to
Drupal,DrupalPractice. `--json` says which one was used (`.drupilot.source`:
project / explicit / drupilot / fallback); **report it** and record it as
`verification.phpcs_ruleset` in the manifest. If the project ruleset makes
`--fix` reformat lines the port did not touch, revert those hunks (smallest
diff) or run that pass with `--ruleset drupilot`. `run-phpstan.sh`
runs `$RUNNER vendor/bin/phpstan analyse --level N <subject>` against the
`phpstan.neon` at the Drupal root. Exit 3 means PHPStan crashed or could
not analyse (invalid config, fatal error): there is no verdict — fix the cause
shown on stderr, never read it as "issues found" or as clean. Reference commands:

```bash
# Phase 1 autofix: only the files the port changed (never the whole module).
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpcs.sh" --subject web/modules/custom/MODULE --fix --fix-scope changed
vendor/bin/phpcs  --standard=Drupal,DrupalPractice \
  --extensions=php,module,inc,install,test,profile,theme,info,txt,md,yml \
  web/modules/custom/MODULE
vendor/bin/phpstan analyse --level 2 web/modules/custom/MODULE
```

Iterate: read remaining violations, apply the smallest fix, re-run. A PHPStan
error that only exists because of the sandbox (a class from a module that is not
installed here, an unknown contrib type) is documented as *sandbox-only*, not
patched — see §0. Phase 1 is done when the module compiles with **no blocking
deprecations** at level 2 (`classify-deprecations.sh` → `blocking: 0`; soft ones
handled per `DRUPILOT_SOFT_DEPRECATIONS`), no *real* PHPStan errors (sandbox-only ones
documented), PHPCS is clean (or remaining items are explicitly noted as
out-of-scope) and `check-port-safety.sh` and `scan-signature-changes.sh` exit 0. If a
running Drupal site exists, `run-upgrade-status.sh --module NAME` gives a
complementary view (it soft-skips when Drupal is not installed).

## 6a. Core matrix — verify every declared core (when `^10` is kept)

The validate loop only sees the Drupal 11 test-bed. When the final
`core_version_requirement` still admits Drupal 10 (`verify_cores` from
`core-strategy.sh --json` contains a `10…` leg) and `DRUPILOT_VERIFY_CORES` is not
`off`, run the matrix once the loop is clean:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/verify-core-matrix.sh" --subject "<path>" --json
```

It runs the same PHPStan analysis (phpstan-drupal + deprecation rules, the
test-bed's exact versions, level `DRUPILOT_PHPSTAN_LEVEL`) and `php -l` against a
cached reference core per extra leg (10.0.x — the declared floor — and the latest
Drupal 10 for `^10 || ^11`, 10.3.x for `^10.3 || ^11`), built once through `ddev exec composer` in
`<drupal_root>/.drupilot/cores/` (≈200 MB, ~1 min the first time, needs network;
its version is frozen in the lockfile under `.verify_cores`), and compares each leg
with the Drupal 11 baseline. `php -l` also runs on the leg's lowest PHP (Drupal
10's own minimum, 8.1, or the `require.php` floor if higher) in a `php:X.Y-cli`
container, which checks the detected PHP floor for real.

- **Exit 3 / `verdict: fail`** — a leg found an incompatibility: an error that
  core does not have on the other leg (`kind: incompatible`), e.g. an
  `#[\Override]` on `buildRevisionCacheId()` (only 11.3+ core declares it), a class
  only Drupal 11 ships (`RequirementSeverity`, 11.2+), or a PHP 8.2/8.3 construct
  under a `>=8.1` floor (lint). **Decision point** (AskUserQuestion, header "Drupal
  10 check", default first) unless autonomous:
  - **Fix the code (keep `^10 || ^11`)** — the Drupal 10-safe way (drop the
    `#[\Override]`, guard the newer API with `DeprecationHelper::backwardsCompatibleCall()`,
    use the older construct), then re-run the matrix;
  - **Raise the floor** to the minor that has the API (e.g. `^10.3 || ^11`) and
    re-run (the leg becomes 10.3);
  - **Drop to `^11`** (`prefs_set DRUPILOT_CORE_TARGET_STRATEGY d11-only`; a major
    bump if Drupal 10 was supported);
  - **Keep it declared-not-verified** — record the failure in the report.
  An autonomous run takes the safe default: fix the code; if that is not
  mechanical, recommend dropping to `^11` in the report (no tab).
  `DRUPILOT_CHOICE_D10_CHECK` (`fix` / `raise-floor` / `d11-only` / `declared`,
  resolved by `scripts/env/choice.sh --key D10_CHECK --persist --json`) answers
  the tab in advance, also in an autonomous run.
- **`d10_support: verified-static`** — PHPStan + `php -l` are clean on Drupal 10,
  including the declared floor minor; report it as *static*: the runtime (the
  test suite on Drupal 10) is not exercised.
- **`d10_support: verified-static-above-floor`** — clean only on a 10.x newer than
  the declared floor (`d10_floor`; `^10` resolves to the newest 10.x): say the
  floor itself was not checked (an API added after it still fatals there) and
  offer `--cores <floor>,11` or raising the floor to the checked minor.
- **A leg `skipped`** (no network, a core that cannot install on the container
  PHP) — exit 0, `d10_support` stays `declared-not-verified`; report the reason.
  Never block the port on it.
- Findings of kind `deprecation`, `sandbox_missing_dependency` (a contrib module
  the reference core does not have — documented, never "fixed"), `test_only`
  (tests/ on an older core: its test API typing differs), `advisory`
  (phpstan-drupal best-practice rules) and `tolerated` (PHP accepts it at
  runtime: MORE arguments than an older core's method takes, or the result of
  a method a newer core declares `: void` used — review it, never "fix" it
  by dropping the argument the newer core needs) never fail a leg. When the
  Drupal 11 baseline leg errors, the other legs are `skipped`, not `failed`.

The result persists to `<state_dir>/core-matrix.json`; put it in the manifest as
`verification.core_matrix` and set `d10_support` from it. `--dry-run` prints the
plan (which legs, whether a reference core would be built) without touching
anything.

## 7. Local patch (preview / test before contributing)

When the subject validates, write a local `.patch` of the whole port so the
developer can review it, apply it elsewhere, or test it before deciding to
contribute. Offline, no rebase, git-only; it skips with a warning (never an
error) if the module is not under version control:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/make-patch.sh" --local --subject "<path>"
```

This writes `MODULE-port-to-drupal-11.patch` next to the module (diff scoped to
the module subtree, new files included, the developer's git index untouched).

Two more things to remember:

- This is a **standalone, anytime** action, decoupled from contribution — the
  developer can ask for it at any point via the **`/drupilot-patch`** command (no
  `contribute` gate, no SSH/PAT, no push, no network).
- Passing `--issue ID [--comment N]` names it with the Drupal.org **issue-comment**
  convention (`[module]-[desc]-[issue]-[comment].patch`) while still being produced
  the offline way — for attaching to an issue to test now and contributing later.
  The **merge-verified** contribution patch (rebased onto `origin/BASE`, hard-gated
  to apply cleanly) is the separate thing `drupal-contribution` produces alongside
  the Merge Request — see §5 there.

At the end of the stage, put the developer back in control of what comes next with
a tabbed choice (the `/drupilot-port` command renders it): run the tests, get the
patch (local or issue-comment), refactor (opt-in), or contribute (opt-in).

## 8. Report and hand off

Summarize (in English): the diff, which rules were applied (official / digests /
ad-hoc), the manual changes made, the resulting `core_version_requirement`, the
phpcs/phpstan state, the **local patch path** (or that it was skipped), and what
was **deferred to Phase 2** (any architectural work, DI, attributes, strict
types, missing tests).

**Record what this port learned (before the report).** Every pitfall that cost
a fix here — a Rector change you reverted, a post-port fix, a signature change,
a hygiene defect that bit the tests — is worth a detector so the next module is
checked before it is ported. List the candidates from the manifest's
`rector_reversions` / `post_port_fixes` and the decision log:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/patterns.sh" harvest --subject "<path>" --json
```

Each candidate needs a detector that matches the **pre-port** code (so a scan
finds it before the next port): a POSIX ERE (`--pattern`, `grep -E`, no `\d` or
lookarounds; `--files '*.php'` narrows it) and/or a deterministic checker
(`--rule port-safety:<check>` from `check-port-safety.sh`, or
`--rule signature:<id>` from `.signature_changes` in `config/deprecations.json`).
The command asks which ones to keep (multi-select); then record each, with its
fix and why (an existing id is upserted: `hits` + 1, the module appended to
`seen_in`):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/patterns.sh" add --subject "<path>" \
  --id <slug> --kind <rector-reversion|post-port-fix|signature-change|port-safety|hygiene|other> \
  --pattern '<ERE>' [--rule <ref>] --why "<why>" --fix "<the fix that worked>" [--layer <N>] --json
```

Prove an ERE before keeping it: it must match the PRE-port line, read without
touching the working tree (`git show <base>:<file> | grep -nE '<ERE>'`, where
`<base>` is the ref the local patch diffs against), and an ERE that matches
every line is refused by `add`. A
module with nothing new to teach records nothing. In autonomous mode, record
only candidates with a detector you proved and list the recorded ids in the
summary for review (the catalog is local, self-gitignored, and
`patterns.sh remove --id <id>` undoes an entry).

**Write the report card (trust + teaching artifact).** While the passes ran you
should have **tee'd** the official Rector output, the digests pass output and the
final validate-loop PHPStan deprecation report into `<state_dir>/change-log.txt`
(`<state_dir>` is `project_state_dir`, under `$HOME` — never in the project tree,
so it never leaks into a patch). Then write `<state_dir>/port-manifest.json`
(shape per `port-report.sh`: `machine_name`, `type`, `phase: "port"`,
`core_version_requirement`, `rector_official_files`, `digests`, `manual_edits`
[each a string or `{edit, why, change_record}`], `deprecations_remaining`,
`deferred_to_phase2`, `patch`, `port_safety` and `signature_changes` — the JSON
of `check-port-safety.sh --json` / `scan-signature-changes.sh --json` —,
`metadata_lint` — the JSON of `lint-extension-metadata.sh --json` run after the
port (§6), rendered as "Pre-existing hygiene (not fixed in Phase 1)" — and
`soft_deprecations`, the final `classify-deprecations.sh --json`; add every soft
symbol whose `action` is `defer` to `deferred_to_phase2`, and count only the hard
and unknown ones in `deprecations_remaining`; `d10_support` from the core matrix
(§6a) when it ran; and `verification`: `{core_matrix, phpcs_ruleset,
commit_hooks}` — the JSON of `verify-core-matrix.sh --json`, the `.drupilot`
object of `run-phpcs.sh --json` and the hook record from §3; all fall back to the
state files the scripts write; and the **structured outcome fields** that
aggregate across modules and layers: `rector_rules` (the `rule_hits` of the
applying `run-rector.sh --json`; falls back to the `rector-rules.json` it
keeps), `rector_reversions` `[{rule, file, why}]`, `post_port_fixes`
`[{fix, file, why, detected_by}]`, `preexisting_bugs` `[{issue, file, note}]`,
`behavior_changes` `[{change, why, review_hint}]`, `tooling_deviations`
`[{what, why}]`, `validation` (strings: how the result was validated) and
`learned_patterns` `{scan: <the patterns.sh scan --json of §1>, recorded: [ids]}`
(rendered as "Learned patterns"). The
entries you logged with `log-decision.sh` are merged in (deduplicated), so a
decision logged there need not be repeated in the manifest) and render the report:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/port-report.sh" \
  --subject "<path>" --manifest "<state_dir>/port-manifest.json" \
  --changes-log "<state_dir>/change-log.txt"
```

It writes `port-report.md` into the visible `.drupilot/` dir at the Drupal root,
adding a "Drupal 9/10 → 11 changes, explained" section (each recognized change
grouped by migration area with what changed, the fix and a change-record link).
`--changes-log` already defaults to that path, so teeing the file is enough.
It also refreshes `port-summary.json` beside the report (`port-summary.sh`: the
versioned JSON summary wrappers read); record `files_changed` (files the port
changed) in the manifest for it.

**Preservation gate.** Phase 1 is not "done" until `test-adaptation` reports the
adapted suite **green** (or its red tests documented as external blockers) — that
green is the evidence the original behavior is preserved. If the module ships
**no tests**, say so plainly: preservation is **not verified**, the changes rest
on Rector's equivalences + the minimal diff, and adding tests is recommended
(drupilot does not fabricate them in Phase 1). A `not-verified-unbaselined`
verdict lists failures the baseline never meaningfully ran: report them as
possible regressions, never as pre-existing. A `pre-existing-failures` verdict
(every red test was already red in the pre-port baseline) is reported with its
list, never as green: those failures prove nothing either way, and one that
now fails with a different message is reviewed as a possible regression. Then hand off to `test-adaptation`,
and offer `full-refactor` if the user opts into Phase 2.

## Gotchas

- Default is dry-run; `--apply` is required to write. Never skip the diff review,
  especially for `--digests`.
- Digests rules are unlicensed and AI-generated — clone-at-runtime only, filter
  by the Drupal target, validate with phpstan + tests.
- Do not let digests silently raise `core_version_requirement` above what the
  project supports.
- Rector/PHPStan need the core tree (no DB); upgrade_status needs an installed
  site.
- Preserve functionality — Phase 1 is not the place for refactors.
- Rector's PHP sets are not Drupal-aware: without the template's skip list they
  turn `[$this, 'method']` FAPI callbacks into closures, add `#[\Override]`
  against the sandbox core only, make properties `readonly`, add `(string)`
  casts and rewrite `__sleep()`/`__wakeup()`. A project-owned `rector.php` must
  skip them too, and set `->withPhpVersion()` to the floor (run-rector.sh
  warns).

