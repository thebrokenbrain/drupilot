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

`run-rector.sh` `cd`s to the Drupal root, uses `RUNNER=$(drupal_runner)`
(`ddev exec` when the env is up), and ensures a `rector.php` exists at the root
(copied from `vendor/palantirnet/drupal-rector/rector.php` or the plugin's
`rector.php.tmpl`). The config uses `Drupal10SetList::DRUPAL_10` +
`Drupal11SetList::DRUPAL_11` and the PHP set for the target. Reference commands:

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
# Always dry-run first; digests run AFTER official rector:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" \
  --subject "<path>" --digests --digests-ref "$(config_get DRUPILOT_DIGESTS_REF main)"

# Review the diff carefully, then:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" \
  --subject "<path>" --digests --apply
```

`run-rector.sh --digests` clones/updates the repo into `digests_cache_dir`
(`git clone --depth 1 <repo_url>` or `git -C <cache> pull --ff-only`, checking out
`DRUPILOT_DIGESTS_REF`) and runs `vendor/bin/rector process <path> --config
<cache>/rector/all.php --dry-run`.

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
  **When the helper returns a non-null `require_php`** (it always does for
  `^10 || ^11`, because the port's PHP floor is the target while Drupal 10 itself
  allows PHP 8.1), add it to the project's `composer.json`:
  `"require": { "php": ">=<target>" }` — this blocks a D10 + PHP<target site at
  install instead of fataling at runtime. For `^11` no `require.php` is needed
  (core enforces it). State the chosen `core_version_requirement`, the
  `require.php`, and the `version_bump` verdict in the chat summary. Do not
  silently overwrite a `core_version_requirement` the user already hand-tuned —
  if it differs from the recommendation, say so and confirm.
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
```

`run-phpcs.sh --fix` runs `phpcbf` first then `phpcs` with
`--standard=Drupal,DrupalPractice` and the extension list from PROMPT §2.3
(`php,module,inc,install,test,profile,theme,info,txt,md,yml`). `run-phpstan.sh`
runs `$RUNNER vendor/bin/phpstan analyse --level N <subject>` against the
`phpstan.neon` at the Drupal root. Reference commands:

```bash
vendor/bin/phpcbf --standard=Drupal,DrupalPractice web/modules/custom/MODULE
vendor/bin/phpcs  --standard=Drupal,DrupalPractice \
  --extensions=php,module,inc,install,test,profile,theme,info,txt,md,yml \
  web/modules/custom/MODULE
vendor/bin/phpstan analyse --level 2 web/modules/custom/MODULE
```

Iterate: read remaining violations, apply the smallest fix, re-run. Phase 1 is
done when the module compiles with **no blocking deprecations** at level 2 and
PHPCS is clean (or remaining items are explicitly noted as out-of-scope). If a
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
the module subtree, new files included, the developer's git index untouched). It
is distinct from the **contribution** patch (named `[module]-[desc]-[issue]-[comment].patch`)
that `drupal-contribution` produces alongside the Merge Request — see §5 there.

## 8. Report and hand off

Summarize (in English): the diff, which rules were applied (official / digests /
ad-hoc), the manual changes made, the resulting `core_version_requirement`, the
phpcs/phpstan state, the **local patch path** (or that it was skipped), and what
was **deferred to Phase 2** (any architectural work, DI, attributes, strict
types, missing tests). Then hand off to `test-adaptation` to get the suite green,
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
