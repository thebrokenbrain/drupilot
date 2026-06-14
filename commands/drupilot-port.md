---
description: Phase 1 minimal port of a Drupal 9/10 module/theme to Drupal 11 — apply official drupal-rector, then the version-filtered digests layer, then ad-hoc rules, plus the minimal manual changes (core_version_requirement etc.), and validate with phpcbf/phpcs/phpstan. Use when the user wants the subject to run on D11 with its original behavior intact, without architectural refactoring.
argument-hint: "[module-or-theme-path]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, Skill, AskUserQuestion
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
`core_version_requirement`** with the helper (not a static flag); use `--json` so
you can show the consequences:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/core-strategy.sh" --subject "$1" --phase port --json
```

**Decision point — let the developer own the core target (G4/G5).** This is one
of the most consequential choices in the port, so surface it as a tab with
**AskUserQuestion** (header "Core target") *unless* the run is autonomous
(`DRUPILOT_AUTONOMOUS=true`) or `DRUPILOT_CORE_TARGET_STRATEGY` /
`DRUPILOT_CHOICE_CORE_TARGET` is already pinned. Make the **helper's
recommendation the first/default option**, and show the consequence of each from
the JSON (`recommended_core_version_requirement`, `require_php`, `version_bump`):

- **Keep Drupal 10 + 11** (`^10 || ^11`) — widest support; declares a
  `require.php` floor (`<require_php>`); Drupal 10 compatibility is
  *declared, not verified*.
- **Drupal 11 only** (`^11`) — simplest; no `require.php`; drops D10 (a **major**
  version bump if it was supported).
- **Let drupilot decide** — apply the helper's `strategy` verdict as-is.

Persist the answer so later runs don't re-ask: write the chosen strategy with
`prefs_set DRUPILOT_CORE_TARGET_STRATEGY <auto|keep-d10|d11-only>` (env still
wins). Then apply the resolved `recommended_core_version_requirement` in Step 6.
When it returns a `require.php` (for `^10 || ^11`, since Drupal 10 allows PHP 8.1
while the port needs a higher floor), add `"require": { "php": "<require_php>" }`
to `composer.json` using the **exact** `require_php` value the helper returns
(`DRUPILOT_REQUIRE_PHP_FLOOR=detect`, the default, derives the real floor such as
`>=8.1`; `target` keeps `>=<target>`). Also relay `php_floor_target_compatible`
(false → the code uses a construct newer than the target) and the
`declared-not-verified` Drupal 10 status. Note the `version_bump` verdict for the
final summary. This target also drives which digests rules are safe (see Pass 2).
The legacy `DRUPILOT_KEEP_D10` still works as an explicit override.

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

Procedure: **dry-run → participatory review → apply → validate**. Never apply
blind — this is unlicensed AI-generated code touching the developer's module, so
they decide.

```bash
# Dry-run first (clones/updates the digests cache, checks out DRUPILOT_DIGESTS_REF):
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "$1" --digests
# Structured view of what it would touch (pass2 = digests):
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "$1" --digests --json
```

**Decision point — the developer owns the digests pass (G5).** Read the dry-run
diff and, for each change, note the **rule** and the **API/min-version** it
targets; **pre-flag** any rule whose target API was added *after* the floor you
are keeping (from Step 1 — e.g. an 11.2+ API while keeping `^10 || ^11`), since
applying it silently raises the effective `core_version_requirement`. Present the
review and a tab with **AskUserQuestion** (header "Digests rules", default
"Review and pick") — skip it only in an autonomous run, where the safe default is
to **skip** flagged rules:

- **Review and pick** — show the per-rule list (rule → target → files, flagged
  ones marked) and apply only the rules the developer keeps.
- **Apply all (unflagged)** — apply every rule that is not pre-flagged.
- **Skip the digests pass** — apply nothing from this layer.

Before applying, suggest a git checkpoint (`git add -A && git commit`) so a
disliked digests pass can be dropped cleanly. Then apply the accepted subset:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "$1" --digests --apply
```

If the developer picked a subset (not "apply all"), apply the kept rules via an
explicit `--config` pointing at a trimmed rule set, or apply all then revert the
unwanted hunks — never silently apply a flagged rule they did not accept.

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
  `"require": { "php": "<require_php>" }` to `composer.json` using the exact value
  the helper returned, so a D10 + low-PHP site is blocked at install, not at
  runtime.
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
module subtree, new files included). The same script can name the patch with the
Drupal.org **issue-comment** convention — still offline, no push, no gate — if the
developer wants to attach it to an issue and test it now, contributing the Merge
Request later: pass `--issue ID [--comment N]` (this is what `/drupilot-patch`
does). The merge-verified patch (rebased onto `origin/BASE` and hard-gated to
apply cleanly) is the separate thing produced by `/drupilot-contribute`.

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

**Write the port report card (the trust artifact).** Record the decisions you made
as a small manifest JSON and render the human report next to the module, so the
developer (and a future maintainer reviewing the change) can see what changed and
why at a glance. Build the manifest from what you actually did and write it to the
project state dir, then render:

```bash
# Write <state_dir>/port-manifest.json with: machine_name, type, phase ("port"),
# core_version_requirement, require_php, php_target, version_bump,
# rector_official_files, digests {applied, rejected:[{rule,reason}], skipped},
# manual_edits[], deprecations_remaining, deferred_to_phase2[], patch, d10_support.
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/port-report.sh" --subject "$1" --manifest "<state_dir>/port-manifest.json"
```

It writes `port-report.md` next to the module (and pulls the `preservation`
verdict from `last-test.json` and the assessment verdict from `assess.json`).
`SendUserFile` it so it surfaces as a deliverable. Every field is optional — the
report still renders from partial data, and never invents a value.

## Step 10 — What next? (developer chooses)

Phase 1 is done. **Unless the run is autonomous** (`DRUPILOT_AUTONOMOUS=true` —
then just print the recommendation and stop, doing nothing outward-facing), put
the developer back in control with an **AskUserQuestion** fork (header "Next
step", default = the recommended option). Offer the relevant subset of:

- **Run the tests** (`/drupilot-test`) — recommended: the green suite is the
  evidence behavior was preserved.
- **Get the local patch** (`/drupilot-patch`) — a `.patch` to test on another
  checkout now.
- **Patch for a Drupal.org issue** (`/drupilot-patch` → issue-comment option) —
  an issue-named patch to attach and test, contributing later.
- **Refactor to the Drupal 11 way** (`/drupilot-refactor`) — opt-in Phase 2.
- **Contribute upstream** (`/drupilot-contribute`) — opt-in; only offer for a
  contrib project on drupal.org, and **never** in an autonomous run.
- **Done for now** — stop here.

Act on the chosen option (route to the matching command). Phase 1 keeps behavior
identical and D11-compatible. When in doubt, defer rather than refactor.
