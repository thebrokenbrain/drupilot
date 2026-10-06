---
name: viability-assessment
description: >-
  Produce a Drupal 9/10 to Drupal 11 viability report and a phased port plan for
  a module or theme. USE THIS when assessing portability before porting (the
  /drupilot-assess flow, the drupal-viability-analyst agent), when the user asks
  "is this worth porting / how big is the effort / what will break", or whenever
  you need an effort estimate (S/M/L/XL) before touching code. Runs
  scripts/analysis/assess.sh, which computes the whole assessment
  deterministically in the Drupal test-bed (the official Rector dry-run,
  PHPStan, PHPCS, the signature/port-safety/metadata checks, the core-target
  decision and contrib dependency readiness) into assess.json and renders
  viability-report.md; the skill then narrates assess.json (the S/M/L/XL verdict
  and its rubric counts, manual items, hard breaks such as Twig 3, CKEditor 5,
  jQuery UI and Symfony 7, info.yml and core target, dependencies, hygiene) and
  always writes a phased port-plan.md, even when the effort exceeds the
  configured threshold.
allowed-tools: Bash, Read, Write, Grep, Glob
user-invocable: true
---

# Viability assessment (Drupal 9/10 -> 11)

This skill estimates the effort of porting a single Drupal **module** or **theme**
to the target major. `scripts/analysis/assess.sh` computes the assessment
deterministically: it writes `assess.json` and renders the human-readable
`viability-report.md`. This skill runs it, explains `assess.json`, and writes the
staged `port-plan.md`. It is **read-only** for the subject: every analysis runs in
dry-run / report mode and nothing in the subject is modified.

**The upgrade plan.** Every version this procedure needs (target major, test-bed
core, declared range, PHP floor and target, Rector sets, names) comes from it,
never from the examples below (AR-26). The block is the working directory's: when it
names no module, or a module other than the subject, run `plan show --subject <subject_dir>`:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/drupilot.sh" plan show 2>/dev/null || true`

If no "drupilot plan" block appears above, run: bash "${CLAUDE_PLUGIN_ROOT}/scripts/drupilot.sh" plan show

The gate decision (PROMPT 0.2) is: drupilot **never refuses**. If the effort is
above `DRUPILOT_VIABILITY_THRESHOLD` it says so loudly, but it still produces a
phased plan that preserves the original functionality without colliding with
the target major.

## 0. Conventions and source of truth

- All output is **English**. Reports, chat summaries, log lines — English only.
- Version facts come from the plan block above and from `assess.json`
  (`drupal_target`, `php_target`, `core_target`). Do not re-research them and
  never take them from the examples in this skill.
- The PHP target is `DRUPILOT_PHP_TARGET` (`resolve_php_target`), the Drupal
  target `resolve_drupal_target`; `assess.json` records both. A PHP target no
  Rector PHP set is assumed for is flagged by `php_target_unconfirmed`, never
  hardcoded.
- Resolve the plugin root with `${CLAUDE_PLUGIN_ROOT}` (or `plugin_root` from
  common.sh). All leaf scripts live under `${CLAUDE_PLUGIN_ROOT}/scripts/...`.
- drupilot splits where it writes. The **human-readable** `viability-report.md`
  (and the `port-plan.md` you write) go into the visible `.drupilot/` artifacts
  dir at the Drupal root (helper `project_artifacts_dir`) — the folder a
  developer opens. The **machine-readable** `assess.json`, with the
  `findings.json`, `worklist.json` and `raw/` tool reports it is computed from,
  stays in the hidden per-project state dir (helper `project_state_dir`, under
  drupilot's data dir, never in the project tree, so it cannot leak into a
  contribution); `/drupilot-status` and later steps read it so they do not
  recompute. Resolve each with
  `bash -c '. "$1/scripts/lib/common.sh"; project_artifacts_dir "$2"' _ "$ROOT" "$SUBJECT"`
  and `bash -c '. "$1/scripts/lib/common.sh"; project_state_dir "$2"' _ "$ROOT" "$SUBJECT"`.
- The field reference is `schemas/assess.schema.json`; the rubric's decision
  record is ADR 0025; the script's header documents its CLI.

## 1. Gate first (no side effects if a hard requirement is missing)

The assessment is a static (`analyze`) operation. Gate before doing anything:

```bash
ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$ROOT/scripts/env/preflight.sh" --profile analyze
```

- Exit `0` -> proceed. Exit `2` -> show the printed report and **stop**; the
  hard requirements for `analyze` are `git` + `jq` + (`composer` OR `php` >=
  target). Suggest `/drupilot-doctor` for assisted install. Do not run any tool.
- `assess.sh` runs Rector and PHPStan in the subject's **Drupal root** (the
  test-bed `/drupilot-setup` builds). With none it exits `1` and says to run
  `/drupilot-setup` first: relay that and stop. Never improvise the counts by
  hand without it.

## 2. Identify the subject

Resolve the subject directory (the argument, else the cwd). It must hold a
`<machine_name>.info.yml` (otherwise `assess.sh` exits `1`: ask for the right
path) and sit inside the Drupal root the stage runs in (the test-bed):

```bash
SUBJECT="$(cd "${1:-$PWD}" && pwd)"
bash -c '. "$1/scripts/lib/common.sh"; subject_project_root "$2"' _ "$ROOT" "$SUBJECT"   # the test-bed's root
```

When the subject is not under that root, `/drupilot-setup` placed a copy at
`<root>/web/{modules,themes,profiles}/custom/<machine_name>` (the original may
be gone, moved): assess that path. With no root, run `/drupilot-setup` first. The subject's identity
(`machine_name`, `type`, `current_core_version_requirement`, `php_target`,
`drupal_target`) is in `assess.json`; do not compute it by hand.

## 3. Run the static analyses (all non-destructive)

One script runs them all and computes the verdict of §5:

```bash
bash "$ROOT/scripts/analysis/assess.sh" --subject "$SUBJECT" --json
# --offline    deps-status.sh without the network (every contrib dependency unknown)
# --no-record  do not record the assessed stage in state.json
```

It writes `assess.json` (schema 1) to the hidden state dir, renders
`viability-report.md` into the visible `.drupilot/` dir, records the `assessed`
stage with its effort, and with `--json` prints `assess.json` on STDOUT. The
same tree, lock and drupal.org answers give the same `assess.json` outside
`meta`. Nothing is applied to the subject. Exit codes:

- `0` — assessed.
- `1` — a usage error, not a Drupal extension (no `<machine_name>.info.yml`), no
  Drupal root to run the assess stage in (run `/drupilot-setup` first), or no
  findings to assess. Relay the message and stop.
- `2` — `jq` is missing: run `/drupilot-doctor`.
- `3` — **provisional**: Rector, PHPStan, the port-safety checks or the
  signature scan gave no verdict. The result goes to `assess-provisional.json`
  (never `assess.json`, which the router would take as an assessment), with
  `provisional: true` and `no_verdict` naming the failing tool; the `assessed`
  stage is not recorded. Report it as a **blocker**, never as zero findings or a clean
  module: the counts are incomplete. The tool's raw report
  (`raw/<NN>-assess-rector.json` / `-phpstan.json` in the state dir) holds the
  reason. A crash (e.g. `[ERROR] Could not detect twig set.` from an
  incompatible `rector/rector`, a PHP fatal, an invalid PHPStan config): repair
  the toolchain with `install-toolchain.sh --dir <drupal_root> --source
  reference` (or fix `rector.php` / `phpstan.neon` when the toolchain already
  matches the known-good set). A message starting `DET-1:` is not a crash: the
  tool did not run because DDEV is down for a root with a DDEV project, or a
  tool differs from the lock's pins; start DDEV, or restore the pins
  (`install-toolchain.sh --dir <drupal_root>`) or accept the installed versions
  (`lock-sync.sh --dir <drupal_root>`), never `--source reference` for it. Then
  run `assess.sh` again.

The **digests layer is not part of the assessment**: a deprecation only a
digests rule fixes counts as manual; its rules are reviewed in `/drupilot-port`.

The subsections below are a field guide to `assess.json`: what each field means
and which script produced it. The leaf scripts they name stay available for a
**closer look** at one finding; their output never replaces a field of
`assess.json`.

### 3.1 The pipeline and the tool verdicts

`assess.sh` runs the assess stage itself:

1. `scripts/ai/extract.sh` runs the deterministic extractors with `--json` —
   `run-rector.sh` (dry-run), `run-phpstan.sh`, `run-phpcs.sh`,
   `check-port-safety.sh`, `scan-signature-changes.sh` and
   `lint-extension-metadata.sh` — and keeps each report as
   `raw/<NN>-assess-<tool>.json` in the state dir;
2. `scripts/ai/normalize-findings.sh` turns them into `findings.json`: one
   finding per tool, rule, file and anchor (the function or method of the line),
   each with a `class` and a `scope`;
3. `scripts/ai/classify.sh` turns those into `worklist.json`, the port's work
   queue (one item per file, anchor and lane);
4. `core-strategy.sh` and `deps-status.sh` answer the core target and the
   dependencies.

Fields:

- `tools` — each extractor's verdict (`ok` | `partial` | `failed` | `missing`).
  Rector, PHPStan, port-safety or signatures neither `ok` nor `partial` makes
  the result `provisional`.
- `worklist` — the worklist's `items`, `open` and `by_lane` counts: what the port
  stage will work through, not an input of the verdict.
- `subject`, `machine_name`, `type`, `drupal_target`, `php_target`,
  `current_core_version_requirement` — the subject's identity and targets.
- `findings_hash`, `worklist_hash`, `subject_digest` (`digest_algo`) — what the
  assessment was computed on; `meta` (`generated_at`, `drupilot_version`) is the
  only part that changes between two runs of the same tree.

### 3.2 Auto-fixable: the official Rector dry-run

- `auto_fixable.rector_official_files` — the files the official drupal-rector
  dry-run (with its compat pass) would change; `auto_fixable.rector_official_rules`
  — `{rule message: files}`. Context only: it does not change the verdict. When
  `tools.rector` is neither `ok` nor `partial`, there is no auto-fixable
  answer — never present it as "0 files would change".
- Coverage is per function: a hard or unknown deprecation counts as covered when
  a Drupal Rector rule (a `DrupalRector\` rule, or a Renaming / Transform /
  Arguments / Removing rule drupal-rector configures) changes the same function
  or method. A file-level anchor, or anchors that could not be computed, never
  count as covered.

Closer look (dry-run by default; never `--apply` here):

```bash
bash "$ROOT/scripts/analysis/run-rector.sh" --subject "$SUBJECT" --json
# {status, ok, errors, changed_files, files, ...}; exit 3 = Rector crashed
```

### 3.3 Deprecations: hard, soft and unknown

PHPStan runs at the deprecation level (`DRUPILOT_PHPSTAN_LEVEL`, default 2, what
drupal-check pins). `normalize-findings.sh` classifies each deprecation:

- **hard** — removed in a Drupal major at or below the target major (e.g.
  `user_roles()`, which PHPStan reports as "Function user_roles not found." on a
  core of the target major). Phase 1 must fix it.
- **soft** — removed only in a later major (e.g. `user_load_by_name()`,
  `text_summary()`, `check_markup()`): it still works on every core of the
  target major. It follows `DRUPILOT_SOFT_DEPRECATIONS` (`report` by default,
  `defer`, or `fix` without breaking the declared floor) and never counts.
- **unknown** — no readable removal version; counted like a hard one.

Fields: `deprecations_hard`, `deprecations_soft`, `deprecations_unknown` (PHPStan
occurrences); `soft_deprecations` — one row per symbol with `deprecated_in`,
`removed_in`, `effort` and `replacement_since` from the `lifecycle` catalog of
`config/deprecations.json` (`null` when the catalog has none: say so, never
invent a value); `soft_deprecations_policy`; `phpstan.deprecations` and
`phpstan.count` (every PHPStan finding, including the analysis errors, which go
to the worklist and never count). When `tools.phpstan` is neither `ok` nor
`partial`, the counts are unknown, not zero.

Closer look, and a teaching aid for the narrative (what changed, the modern fix,
a drupal.org change-records link):

```bash
bash "$ROOT/scripts/analysis/run-phpstan.sh" --subject "$SUBJECT" --json   # drupilot.status: clean | findings | crashed
bash "$ROOT/scripts/analysis/run-phpstan.sh" --subject "$SUBJECT" \
  | bash "$ROOT/scripts/analysis/explain-deprecations.sh"                  # --json for structured output
```

Use the explanations so the developer understands *why* each manual item is
needed, not just that it is.

### 3.4 Manual items: what Rector does not fix

`manual_items` lists the work the rubric counts as `rubric.manual`, each with
`id` (`M1`, ...), `finding_id` (its `findings.json` id), `file`, `line`,
`occurrences`, `source` (`tool:rule`) and `what`. Three kinds of finding land
there:

- the hard and unknown PHPStan deprecations no Drupal Rector rule covers (§3.2),
  each item with its PHPStan `occurrences` (`rubric.manual` is their sum);
- the **signature** findings of severity `error` (`scan-signature-changes.sh`).
  Rector and PHPStan judge the module against the ONE core in the test-bed; the
  module declares a RANGE. The catalog (`.signature_changes` in
  `config/deprecations.json`, each entry checked against core source) covers,
  for example, a `ConfigFormBase` or `ContentTranslationController` subclass
  whose `parent::__construct()` passes too few arguments (ArgumentCountError), a
  module method that core adds later with an incompatible signature or an
  `#[\Override]` below the floor (`entity-get-original`, `entity-set-original`,
  `revision-cache-id`; a compatible one is only a warning: it silently becomes an
  override), and a `hook_entity_operation(_alter)` implementation that requires
  the newer `$cacheability` parameter (keep any new parameter optional). Never
  plan an `#[\Override]` on a method that exists only in some of the declared
  cores;
- the **port-safety** findings of severity `error` (`check-port-safety.sh`, data
  in `config/port-checks.json`): a DI interface that does not match `create()`,
  a removed `use` still referenced, `new self(` in `create()`, closures under
  Form/Render API callback keys, private/readonly properties in a
  `DependencySerializationTrait` class, `#[\Override]` while the core range spans
  the previous major, class-name case.

Soft and next-major findings never count; neither do PHPStan's non-deprecation
analysis errors. Signature and port-safety warnings are review items for the
plan, not manual items.

Closer look:

```bash
bash "$ROOT/scripts/analysis/scan-signature-changes.sh" --subject "$SUBJECT" --json   # --core-floor X.Y to judge at another floor
bash "$ROOT/scripts/analysis/check-port-safety.sh" --subject "$SUBJECT" --json
# exit 3 = error findings: expected before a port, not an assessment failure
```

### 3.5 Hard breaks

`config/catalog/hard-breaks.json` holds four categories — Twig 3 (`twig3`),
CKEditor 5 (`ckeditor5`), jQuery UI (`jquery_ui`), Symfony 7 (`symfony7`) — each
a POSIX ERE over the files its globs name (`vendor/`, `node_modules/` and `.git/`
left out), each fact verified in core. `hard_break_categories.<id>` lists the
matching files, `hard_breaks` the categories present, and `rubric.hard_breaks`
their number (0–4).

**Symfony 7** is the most false-positive-prone (having an event subscriber is
common and may not break): it still counts for the verdict, but say in the
narrative whether PHPStan flags a real type or signature error in those files
(the manual items, or `run-phpstan.sh`); if it does not, call it "no real work".

### 3.6 Core target and `info.yml`

From `core-strategy.sh --json` (phase `port`):

- `core_target` — `strategy`, `recommended_core_version_requirement`,
  `composer_core_constraint`, `require_php`, `version_bump`, `bc_break`,
  `d10_support`, `php_floor_detected`, `php_floor_target_compatible`,
  `rationale`, `warnings`; `recommended_core_version_requirement`, `require_php`
  and `version_bump` are repeated at the top level.
- The strategy is `DRUPILOT_CORE_TARGET_STRATEGY` (`auto` | `keep-d10` |
  `d11-only`; the 1.0 names `keep-previous` / `target-only` are accepted).
  `auto` keeps the widest BC-preserving range and drops the previous major (a
  **major** version bump) on a BC break. Keeping the previous major carries a
  composer `require.php` floor, since the previous major allows an older PHP:
  `DRUPILOT_REQUIRE_PHP_FLOOR` (`detect` by default: the real floor the code
  needs; `target`: the PHP target). `php_floor_target_compatible` is false when
  the code uses a construct newer than the target. A kept previous-major leg is
  `d10_support: declared-not-verified`: the port's core matrix
  (`verify-core-matrix.sh`) checks it statically later; the assessment builds no
  older core.
- `info_yml` — `core_version_requirement_present`, `d11_compatible` (the current
  requirement admits the target major) and `submodules_d11_compatible`. A
  missing `core_version_requirement` (or a legacy `core: 8.x`) is **blocking**:
  flag it. Phase 1 sets the requirement of the main and every submodule
  `info.yml` (`set-core-requirement.sh`).

Closer look: `core-strategy.sh --subject "$SUBJECT" --phase port --json` (an
opt-in Phase 2 refactor, `--phase refactor`, would recommend the target major
only and a major bump).

### 3.7 Contrib dependencies and pre-existing hygiene

- `dependencies` — from `deps-status.sh --json`: `ready`, `blockers`, `unknown`,
  `offline` and `list` (`{project, d11, url}`; `d11` is `ready`, `not-ready`,
  `not-on-drupalorg`, `unknown` or `core`, checked against the drupal.org
  release-history feed, never guessed). `blockers` is `rubric.blocking_deps`: a
  dependency with no release for the target major is an external blocker —
  document it, never fake green. Whether an alternative is viable is your
  judgement for the plan, not for the count. With `offline: true` every contrib
  dependency is `unknown` and none blocks: say the dependencies were not
  checked, not that they are ready.
- `hygiene` — `{error, warn, info}`, the totals of the metadata findings
  (`lint-extension-metadata.sh`): config without a schema, plugin settings
  without one, a `configure:` route defined nowhere, an orphan service class or
  a letter-case mismatch, service `arguments:` vs the constructor, a nested
  `*.info.yml` that does not admit the target major, undeclared dependencies
  (with the proposed `<project>:<module>` entry). They **never feed the rubric**;
  the report's "Pre-existing hygiene" table lists them. Phase 1 only bumps the
  submodules' requirement; the rest is a follow-up or Phase 2.

Closer look:

```bash
bash "$ROOT/scripts/analysis/deps-status.sh" --subject "$SUBJECT" --json        # --offline: no network
bash "$ROOT/scripts/analysis/lint-extension-metadata.sh" --subject "$SUBJECT" --json --no-write
bash "$ROOT/scripts/analysis/run-phpcs.sh" --subject "$SUBJECT" --json          # never --fix here
```

`phpcs.count` (the PHPCS findings) gauges the coding-standard distance, which
matters to a Phase 2 estimate, not to Phase 1 viability.

**Upgrade Status** is optional context, outside `assess.json`: only when Drupal
is installed in the test-bed,
`run-upgrade-status.sh --module <machine_name>` corroborates the findings. On a
bed of the target major it reports the *next* major's issues, so they never
count. Its absence never blocks the assessment.

## 5. Estimate effort (S / M / L / XL) — computed by `assess.sh`

The verdict comes from three integer counts (ADR 0025), so two assessments of
the same module reach the same verdict. Never recompute or override it:

- `rubric.manual`: the PHPStan occurrences of the scope-current `hard` and
  `unknown` deprecations no Drupal Rector rule changes in the same function or
  method, plus the signature and port-safety findings of severity `error`
  (`manual_items`, §3.4). Soft and next-major ones never count, whatever
  `DRUPILOT_SOFT_DEPRECATIONS` says.
- `rubric.hard_breaks`: the hard-break categories present (0–4, §3.5).
- `rubric.blocking_deps`: the dependencies drupal.org has no release of the
  target major for (`deps-status.sh` blockers, §3.7).

`rubric.rule` is the first matching row, quoted verbatim in the report:

| Verdict | Condition (first match wins) |
|---|---|
| **XL** | `blocking_deps >= 1`  OR  `hard_breaks >= 3`  OR  `manual > 40` |
| **L**  | `hard_breaks == 2`  OR  `manual > 15` |
| **M**  | `hard_breaks == 1`  OR  `manual >= 5` |
| **S**  | otherwise |

`above_threshold` compares it with `viability_threshold`
(`DRUPILOT_VIABILITY_THRESHOLD`, default `medium`). **Even above the threshold,
still produce the phased plan** — never withhold it. The auto-fixable share
(`auto_fixable`) is context; it does not change the verdict.

With `provisional: true` the counts are incomplete (a tool of `tools` gave no
verdict): present the verdict as provisional and the failing tool as a blocker
to repair, never as zero findings.

## 6. Produce the artifacts

`assess.sh` writes the machine-readable `assess.json` to the hidden per-project
state dir and renders the human-readable `viability-report.md` from
`templates/viability-report.md.tmpl` into the visible `.drupilot/` dir, both
from the same numbers, and records the `assessed` stage with its effort (not
when provisional). Never edit either file. You write only the staged
**`port-plan.md`** (from `templates/port-plan.md.tmpl`, in the same `.drupilot/`
dir), from the fields of `assess.json` — its verdict, core target, auto-fixable
count and hard-break files are the JSON's, never re-derived: stages, per-stage
effort, risks, what preserves the original functionality without colliding with
the target major (Phase 1), and what is **deferred to Phase 2**. The plan must
exist even for an XL/above-threshold verdict; a provisional one is marked
provisional, with the repair of the failing tool as its first step.

Suggested phasing to encode in the plan:

1. **Stage 0 — Environment**: `/drupilot-setup` (DDEV + add-ons + toolchain).
2. **Stage 1 — info.yml + official Rector**: bump `core_version_requirement`
   in the main and every submodule `info.yml` (`set-core-requirement.sh`),
   apply `palantirnet/drupal-rector` (dry-run -> review -> apply -> validate).
3. **Stage 2 — Manual items + hard breaks**: the `manual_items`, then Twig 3,
   CKEditor 5, jQuery UI, Symfony 7, in risk order; optionally the filtered
   digests layer of the port.
4. **Stage 3 — Tests green**: adapt + run the full suite (`test-adaptation`).
5. **Phase 2 (opt-in) — Refactor**: "the target major's way", PHPStan 5-6,
   clean PHPCS, added tests. Deferred unless the developer opts in.

## 7. Report in chat (concise English)

After the artifacts exist, give a short summary from `assess.json`: subject +
type, PHP/Drupal target, the **core-target recommendation** (recommended
`core_version_requirement`, the `require.php` it implies, and the
**version-bump verdict** — e.g. "new major: drops the previous major" or
"minor: adds the target major"), the verdict with its three counts and
`rubric.rule`, whether it crosses the threshold, whether it is provisional (and
which tool to repair), the headline auto-fixable vs manual split, the hard
breaks found, `info.yml` status, any unported dependency (or that they were
checked offline), and the path to both artifacts. Offer the next step
(`/drupilot-port` for Phase 1) — never decide for the developer.

## 8. Gotchas

- Never run Rector/PHPCS in write mode here. Assessment is read-only.
- Never present a provisional verdict as final, or a failed tool as zero
  findings.
- Never recount a field of `assess.json` from a closer-look command: a
  difference means the tree changed since the assessment, so run `assess.sh`
  again.
- Long analyses on large modules should run in the background and notify on
  completion rather than blocking the session (PROMPT 6).
- With no Drupal root there is no assessment: `assess.sh` needs the core tree
  of the test-bed. Point the developer to `/drupilot-setup`.
