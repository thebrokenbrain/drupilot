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

## 0. Golden rules

- **Gate `analyze` first.** Static port needs git + jq + (composer OR php ≥
  target). Heavier passes that run in DDEV inherit the environment from
  `ddev-environment`.
- **Dry-run → review the diff → apply → validate.** Never apply Rector (and
  *especially* never apply digests rules) blind.
- **Preserve behavior.** Phase 1 changes APIs, not architecture. Do not introduce
  DI refactors, attributes, strict types, or `final` here.
- **Resolve the PHP and Drupal targets** via `resolve_php_target` /
  `resolve_drupal_target` (see the `php-target-tuning` skill). The PHP set is
  chosen from the target.

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
  and PHP 8.3+ fatals at compile time.
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

## 2. Pass 1 — official Rector (palantirnet/drupal-rector)

The stable, community-maintained pass. Covers deprecations D10.0 → D11.4. Always
runs first.

```bash
# Dry-run (default — writes nothing):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "<path>"

# Review the printed diff/summary, then apply:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "<path>" --apply
```

**Exit 3 = Rector crashed** (e.g. `[ERROR] Could not detect twig set.` from an
incompatible `rector/rector`, a PHP fatal, or per-file processing errors): the
`--json` payload has `status: "error"` and `errors[]` with the message, and there
is **no verdict** — never read it as "0 files would change". Stop, show the
diagnostic (installed vs known-good versions), repair the toolchain with
`install-toolchain.sh --dir <drupal_root> --source reference` (or fix `rector.php`
when the toolchain already matches the known-good set), and re-run.

`run-rector.sh` `cd`s to the Drupal root, uses `RUNNER=$(drupal_runner)`
(`ddev exec` when the env is up), and ensures a `rector.php` exists at the root
(rendered from the plugin's `rector.php.tmpl`; the vendor example is only a
legacy fallback). The config uses `Drupal10SetList::DRUPAL_10` (D9/D10 APIs
removed in D11; `DRUPAL_11` is deliberately not included) and the PHP set for the
target, minus the risky modernization rules listed in §0. A `rector.php`
generated by an older drupilot template is backed up to `.drupilot/backups/` and
regenerated; a hand-written one is never replaced. Reference commands:

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
silently reusing a stale cache), then runs `vendor/bin/rector process <path>
--config <cache>/rector/all.php --dry-run`. In deterministic mode the SHA that
`main` first resolved is frozen in the per-project lockfile and reused on later
runs, so the same project always applies the same digests rules.

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

The `issues/*.md` summaries in the repo explain *why* an API changed — useful
context when reviewing a diff, but they are not rules.

**Make the review participatory (G5).** The `/drupilot-port` command renders the
review as a tab (Review and pick / Apply all unflagged / Skip). To support it,
run `run-rector.sh --subject <path> --digests --json` for the structured
`{pass2_files, ...}` view, present a per-rule list (rule → target API/min-version
→ files) with floor-exceeding rules **pre-flagged**, and apply only what the
developer keeps. Before applying, suggest a **git checkpoint**
(`git add -A && git commit -m "wip: before digests"`) so a disliked pass can be
dropped with a single `git reset --hard`. In an autonomous run the safe default
is to skip the pre-flagged rules and report them.

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

  Apply its `recommended_core_version_requirement` (`auto` → `^10 || ^11` for a
  BC-preserving port, or `^11` on a BC break / `d11-only`). The old `core: 8.x`
  key no longer exists; a missing `core_version_requirement` is a hard blocker.

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
    `declared-not-verified`: Rector's standard replacements usually exist across all
    of Drupal 10, but drupilot does not verify it in Phase 1. **Report it as
    declared, not verified** (mirroring the preservation gate), relay the helper's
    `warnings` (if the port uses an API added in a later minor, it should be
    `^10.3 || ^11`; if absent from D10, `^11`), and carry its
    `suggested_remaining_tasks` into the contribution issue (`make-issue.sh
    --d10-unverified`).

  State the chosen `core_version_requirement`, the `require_php` (and its detected
  floor), the `d10_support` status and the `version_bump` verdict in the chat
  summary. Do not silently overwrite a `core_version_requirement` the user already
  hand-tuned — if it differs from the recommendation, say so and confirm.
- **Twig 3:** removed filters/functions; `spaceless` is gone (use
  `{% apply spaceless %}` or whitespace control) — only when mechanical.
- **CKEditor 5:** CKEditor 4 was removed in D10; migrate config/text-format
  references mechanically where possible.
- **jQuery / jQuery UI:** `core/jquery.ui.*` libraries were removed/externalized;
  update library dependencies.
- Symfony 7 / Guzzle 7 / PHPUnit 10-11 signature touch-ups when purely
  mechanical; anything that needs real redesign is **deferred to Phase 2**.

Do not add features or change behavior. If a fix would require architectural
change, note it for Phase 2 instead of doing it here.

## 6. The validate loop (after each batch of changes)

Run until clean — never silence findings:

```bash
# 1. Auto-fix coding standards, then re-check:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpcs.sh" --subject "<path>" --fix

# 2. Static analysis at the deprecation level (default 2):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpstan.sh" --subject "<path>" \
  --level "$(config_get DRUPILOT_PHPSTAN_LEVEL 2)"

# 3. Deterministic port-safety checks (gate: must exit 0):
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/check-port-safety.sh" --subject "<path>" --json
```

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
callable, make the property `protected`), never suppress them. Warnings are
reviewed and listed in the report. Exit 0 with warnings is fine.

`run-phpcs.sh --fix` runs `phpcbf` first then `phpcs` with
`--standard=Drupal,DrupalPractice` and the extension list from PROMPT §2.3
(`php,module,inc,install,test,profile,theme,info,txt,md,yml`). `run-phpstan.sh`
runs `$RUNNER vendor/bin/phpstan analyse --level N <subject>` against the
`phpstan.neon` at the Drupal root. Exit 3 means PHPStan crashed or could
not analyse (invalid config, fatal error): there is no verdict — fix the cause
shown on stderr, never read it as "issues found" or as clean. Reference commands:

```bash
vendor/bin/phpcbf --standard=Drupal,DrupalPractice web/modules/custom/MODULE
vendor/bin/phpcs  --standard=Drupal,DrupalPractice \
  --extensions=php,module,inc,install,test,profile,theme,info,txt,md,yml \
  web/modules/custom/MODULE
vendor/bin/phpstan analyse --level 2 web/modules/custom/MODULE
```

Iterate: read remaining violations, apply the smallest fix, re-run. A PHPStan
error that only exists because of the sandbox (a class from a module that is not
installed here, an unknown contrib type) is documented as *sandbox-only*, not
patched — see §0. Phase 1 is done when the module compiles with **no blocking
deprecations** at level 2, no *real* PHPStan errors (sandbox-only ones
documented), PHPCS is clean (or remaining items are explicitly noted as
out-of-scope) and `check-port-safety.sh` exits 0. If a
running Drupal site exists, `run-upgrade-status.sh --module NAME` gives a
complementary view (it soft-skips when Drupal is not installed).

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

**Write the report card (trust + teaching artifact).** While the passes ran you
should have **tee'd** the official Rector output, the digests pass output and the
final validate-loop PHPStan deprecation report into `<state_dir>/change-log.txt`
(`<state_dir>` is `project_state_dir`, under `$HOME` — never in the project tree,
so it never leaks into a patch). Then write `<state_dir>/port-manifest.json`
(shape per `port-report.sh`: `machine_name`, `type`, `phase: "port"`,
`core_version_requirement`, `rector_official_files`, `digests`, `manual_edits`
[each a string or `{edit, why, change_record}`], `deprecations_remaining`,
`deferred_to_phase2`, `patch`) and render the report:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/port-report.sh" \
  --subject "<path>" --manifest "<state_dir>/port-manifest.json" \
  --changes-log "<state_dir>/change-log.txt"
```

It writes `port-report.md` into the visible `.drupilot/` dir at the Drupal root,
adding a "Drupal 9/10 → 11 changes, explained" section (each recognized change
grouped by migration area with what changed, the fix and a change-record link).
`--changes-log` already defaults to that path, so teeing the file is enough.

**Preservation gate.** Phase 1 is not "done" until `test-adaptation` reports the
adapted suite **green** (or its red tests documented as external blockers) — that
green is the evidence the original behavior is preserved. If the module ships
**no tests**, say so plainly: preservation is **not verified**, the changes rest
on Rector's equivalences + the minimal diff, and adding tests is recommended
(drupilot does not fabricate them in Phase 1). Then hand off to `test-adaptation`,
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
  against the sandbox core only, make properties `readonly` and add `(string)`
  casts. A project-owned `rector.php` must skip them too (run-rector.sh warns).

