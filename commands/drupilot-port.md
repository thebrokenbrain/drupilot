---
description: Phase 1 minimal port of a Drupal 9/10 module/theme to Drupal 11 — apply official drupal-rector, then the version-filtered digests layer, then ad-hoc rules, plus the minimal manual changes (core_version_requirement etc.), and validate with phpcbf/phpcs/phpstan. Use when the user wants the subject to run on D11 with its original behavior intact, without architectural refactoring.
argument-hint: "[module-or-theme-path]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, Skill
---

# /drupilot-port — Phase 1: minimal compatibility port

Goal: make the subject **work on Drupal 11 while preserving its original
functionality**, with the *minimum* changes. This is **not** a refactor — no
architecture changes, no API modernization for its own sake. Anything beyond
mechanical compatibility is explicitly deferred to Phase 2 (`/drupilot-refactor`).

Subject path argument: `$1` (fallback: the current working directory).

## Step 0 — Gate (profile `analyze`)

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile analyze
```

If it exits `2`, show the report, point to `/drupilot-doctor`, and STOP with no
side effects. Rector/PHPStan/PHPCS need the dev toolchain; if it is not installed,
tell the user to run `/drupilot-setup` first and stop.

## Step 1 — Resolve subject, target, and current core requirement

```bash
!bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; \
  SUBJECT="${1:-$PWD}"; SUBJECT="$(cd "$SUBJECT" 2>/dev/null && pwd || echo "$SUBJECT")"; \
  echo "subject=$SUBJECT"; \
  echo "machine_name=$(subject_machine_name "$SUBJECT" 2>/dev/null || echo "?")"; \
  echo "type=$(subject_type "$SUBJECT" 2>/dev/null || echo "?")"; \
  echo "core_requirement=$(subject_core_requirement "$SUBJECT" 2>/dev/null || echo "<missing>")"; \
  echo "php_target=$(resolve_php_target)"; \
  echo "drupal_target=$(resolve_drupal_target)"; \
  echo "core_strategy=$(config_get DRUPILOT_CORE_TARGET_STRATEGY auto)"; \
  echo "use_digests=$(config_get DRUPILOT_USE_DIGESTS_RULES true)"; \
  echo "digests_ref=$(config_get DRUPILOT_DIGESTS_REF main)"; \
  echo "generate_rules=$(config_get DRUPILOT_GENERATE_RULES ask)"' \
  -- "$1"
```

If a cached `viability-report.md` exists for this project, read it first
(`project_state_dir`) so you know what to expect. Decide the **target
`core_version_requirement`** with the helper (not a static flag):

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/core-strategy.sh" --subject "$1" --phase port
```

Apply its `recommended_core_version_requirement` (`auto` → `^10 || ^11` for a
BC-preserving port, or `^11` on a BC break) in Step 6. When it returns a
`require.php` (always for `^10 || ^11`, since the port's PHP floor is the target
while Drupal 10 itself allows PHP 8.1), add `"require": { "php": ">=<target>" }`
to `composer.json`. Note the `version_bump` verdict for the final summary. This
target also drives which digests rules are safe (see Pass 2). The legacy
`DRUPILOT_KEEP_D10` still works as an explicit override.

## Step 2 — Load the procedure

Invoke the **minimal-port** skill for the exact commands, the three-pass order,
and the digests caveats. Keep a running list of which rules/changes get applied so
you can report it at the end.

## Step 3 — Pass 1: official `palantirnet/drupal-rector` (apply)

The stable, maintained layer first. Always dry-run, let the user (or you, on their
behalf) review the diff, then apply. The script ensures a `rector.php` exists at
the Drupal root (copying the official one or the plugin template) and uses the
`DRUPAL_10` + `DRUPAL_11` sets plus the PHP set for the resolved target.

```bash
# Review what it would change:
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "$1"
# Then apply:
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "$1" --apply
```

## Step 4 — Pass 2: complementary digests layer (apply, version-filtered)

Only if `DRUPILOT_USE_DIGESTS_RULES` is true. These rules are **AI-generated,
experimental, and unlicensed** (PROMPT 2.1.1): clone-on-demand into the plugin
cache (never vendored), run them **after** the official pass, and **filter out**
any rule whose target API does not exist in the lowest core version you must
support — applying a rule that migrates a 11.2+ API would silently raise the
effective `core_version_requirement` and break on 11.0/11.1. When the target is
`^10 || ^11`, be especially conservative.

Procedure: **dry-run → human review of the diff → apply → validate**. Never apply
blind.

```bash
# Dry-run first (clones/updates the digests cache, checks out DRUPILOT_DIGESTS_REF):
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "$1" --digests
```

Review the proposed diff. Drop any rule that targets an API newer than the
supported floor. Then apply the accepted subset:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "$1" --digests --apply
```

## Step 5 — Pass 3: ad-hoc rules / manual fixes (per `DRUPILOT_GENERATE_RULES`)

For deprecations that **no** layer covers, behave according to
`DRUPILOT_GENERATE_RULES`:

- `ask` (default) — for each uncovered deprecation, read the relevant drupal.org
  change record / issue, then **confirm** with the user before either generating
  a small reusable ad-hoc Rector rule or applying the change manually.
- `auto` — generate the ad-hoc rule or apply the mechanical change without asking,
  but still report each one.
- `off` — only **report** the uncovered deprecation; do not touch the code.

Keep ad-hoc rules minimal and mechanical; do not slip refactoring in here.

## Step 6 — Minimal manual changes Rector cannot do

Apply only the mechanical compatibility edits, preserving behavior:

- **`info.yml` + `composer.json`**: set `core_version_requirement` to the target
  decided in Step 1 (e.g. `^10 || ^11`). Remove the obsolete `core: 8.x` key if
  present. A missing `core_version_requirement` is blocking — fix it. When Step 1
  reported a `require.php` (i.e. keeping Drupal 10), add
  `"require": { "php": ">=<target>" }` to `composer.json` so a D10 + PHP<target
  site is blocked at install, not at runtime.
- **Twig 3**: replace removed filters/functions and `{% spaceless %}` with their
  mechanical equivalents (e.g. the `spaceless` filter / `~` handling) only where
  the change is unambiguous.
- **CKEditor 5 / jQuery UI**: adjust libraries/usages where the migration is
  mechanical; if it requires real rework, **defer it to Phase 2** and record it.
- Anything that would change architecture, signatures broadly, or behavior →
  **defer to Phase 2**, do not do it here.

## Step 7 — Validate after each batch of changes

Run the formatter/autofixer, then the linters, then the deprecation-level
analyzer. Leave the subject compiling with no blocking deprecations.

```bash
# Autofix coding standards, then check what remains:
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpcs.sh" --subject "$1" --fix
# Deprecation-level static analysis (DRUPILOT_PHPSTAN_LEVEL, default 2):
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpstan.sh" --subject "$1"
```

If PHPStan still reports blocking deprecations, iterate (back to the relevant
pass) until they are resolved or clearly attributable to something deferred to
Phase 2 (and recorded as such). Do not silence findings.

## Step 8 — Write the local patch (preview / test locally)

Once the subject compiles and validates, write a local `.patch` of the whole
port so the user can review it, apply it elsewhere, or test it before deciding to
contribute. This is offline (no network, no rebase) and only needs the module to
be under git version control; if it is not, the script warns and skips without
breaking the flow.

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/make-patch.sh" --local --subject "$1"
```

It writes `MODULE-port-to-drupal-11.patch` next to the module (diff scoped to the
module subtree, new files included). This is **not** the contribution patch — the
issue-ready patch with the `issue-comment` name is produced later by
`/drupilot-contribute`, alongside the Merge Request.

## Step 9 — Report

Summarize in English:

- **Applied**: which official-rector rules, which accepted digests rules (and
  which were filtered out and why), which ad-hoc rules / manual edits — with the
  final `core_version_requirement`.
- **Validation**: phpcbf/phpcs and phpstan status after the work (clean vs. what
  remains and why).
- **Deferred to Phase 2**: anything non-mechanical (architecture, CKEditor 5 /
  jQuery UI rework, deeper API modernization) explicitly listed for
  `/drupilot-refactor`.
- A short, reviewable summary of the diff (files touched, nature of changes).
- **Local patch**: the path to the `MODULE-port-to-drupal-11.patch` written in
  Step 8 (or a note that it was skipped because the module is not under git).
- Next suggested step: `/drupilot-test` to adapt and run the test suite, then
  optionally `/drupilot-refactor`.

Phase 1 keeps behavior identical and D11-compatible. When in doubt, defer rather
than refactor.
