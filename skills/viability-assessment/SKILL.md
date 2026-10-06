---
name: viability-assessment
description: >-
  Produce a Drupal 9/10 to Drupal 11 viability report and a phased port plan for
  a module or theme. USE THIS when assessing portability before porting (the
  /drupilot-assess flow, the drupal-viability-analyst agent), when the user asks
  "is this worth porting / how big is the effort / what will break", or whenever
  you need an effort estimate (S/M/L/XL) before touching code. Runs the static
  analyses non-destructively (rector --dry-run including the optional digests
  layer, phpstan at deprecation level, phpcs, and upgrade_status when Drupal is
  installed), classifies findings into auto-fixable vs manual and hard breaks
  (Twig 3, CKEditor 5, jQuery UI, Symfony 7), checks info.yml and contrib
  dependency D11 support, and always emits viability-report.md plus a phased
  port-plan even when the effort exceeds the configured threshold.
allowed-tools: Bash, Read, Write, Grep, Glob
user-invocable: true
---

# Viability assessment (Drupal 9/10 -> 11)

This skill estimates the effort of porting a single Drupal **module** or **theme**
to Drupal 11 and delivers two artifacts: a human-readable `viability-report.md`
and a staged `port-plan.md`. It is **read-only**: every analysis runs in
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
Drupal 11.

## 0. Conventions and source of truth

- All output is **English**. Reports, chat summaries, log lines — English only.
- Verified facts (versions, sets, breaks) come from PROMPT 1.x and are treated as
  ground truth (June 2026). Do not re-research them.
- PHP/Drupal targeting derives from a single variable: `DRUPILOT_PHP_TARGET`
  (default `8.3`), resolved with `resolve_php_target`. Drupal target via
  `resolve_drupal_target` (default `^11`). PHP 8.5 needs Drupal 11.3 or later
  (`php_supported_for <minor> 8.5`) and has no assumed Rector `php85` set — branch
  on `php_target_unconfirmed`, never hardcode it.
- Resolve the plugin root with `${CLAUDE_PLUGIN_ROOT}` (or `plugin_root` from
  common.sh). All leaf scripts live under `${CLAUDE_PLUGIN_ROOT}/scripts/...`.
- drupilot splits where it writes. The **human-readable** `viability-report.md`
  goes into the visible `.drupilot/` artifacts dir at the Drupal root (helper
  `project_artifacts_dir`; with no Drupal root yet — assess can run before setup —
  it falls back to `<subject>/.drupilot/`, or to the hidden state dir for a
  module of a larger repository such as a monorepo clone, never written into) —
  the folder a developer opens. The
  **machine-readable** `assess.json` stays in the hidden per-project state dir
  (helper `project_state_dir`, under `$HOME`, never in the project tree, so it
  cannot leak into a contribution) and is what `/drupilot-status` and later steps
  read so they do not recompute. Resolve each with
  `bash -lc '. "$ROOT/scripts/lib/common.sh"; project_artifacts_dir "$SUBJECT"'`
  and `bash -lc '. "$ROOT/scripts/lib/common.sh"; project_state_dir "$SUBJECT"'`.

## 1. Gate first (no side effects if a hard requirement is missing)

The assessment is a static (`analyze`) operation. Gate before doing anything:

```bash
ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$ROOT/scripts/env/preflight.sh" --profile analyze
```

- Exit `0` -> proceed. Exit `2` -> show the printed report and **stop**; the
  hard requirements for `analyze` are `git` + `jq` + (`composer` OR `php` >=
  target). Suggest `/drupilot-doctor` for assisted install. Do not run any tool.
- `upgrade_status` additionally needs a running Drupal (profile `setup`). Treat
  it as optional: if DDEV/Drupal is not up, **soft-skip** it with a clear note in
  the report rather than failing.

## 2. Identify the subject

Resolve the subject directory (the argument, else detect from cwd) and read its
identity from common.sh:

```bash
. "$ROOT/scripts/lib/common.sh"
SUBJECT="$(cd "${1:-$PWD}" && pwd)"
is_drupal_extension_dir "$SUBJECT" || die "No *.info.yml found in $SUBJECT — not a module/theme."
NAME="$(subject_machine_name "$SUBJECT")"
TYPE="$(subject_type "$SUBJECT")"            # module | theme | profile
CORE_REQ="$(subject_core_requirement "$SUBJECT")"   # may be empty
PHP_TARGET="$(resolve_php_target)"
DRUPAL_TARGET="$(resolve_drupal_target)"
```

Record: machine name, type, current `core_version_requirement`, PHP target and
whether it is unconfirmed (`php_target_unconfirmed "$PHP_TARGET"`).

## 3. Run the static analyses (all non-destructive)

`scripts/analysis/assess.sh --subject <path> --json` runs all of this section
(through `scripts/ai/extract.sh`, `normalize-findings.sh` and `classify.sh`),
computes the verdict of §5 and writes the artifacts of §6. Run it, then read
`assess.json`: the subsections below explain where each field comes from; the
individual scripts stay available for a closer look.

Run each leaf script; capture stdout (parseable / summary) and stderr (logs).
**None of these write to the subject.**

### 3.1 Rector dry-run (auto-fixable estimate)

Official pass plus, when enabled, the AI-generated digests layer:

```bash
bash "$ROOT/scripts/analysis/run-rector.sh" --subject "$SUBJECT"
# digests layer (PROMPT 2.1.1) only if DRUPILOT_USE_DIGESTS_RULES is true. The
# script resolves the ref itself (default 'main', frozen in the lockfile when
# deterministic); add --digests-ref only to force a specific commit/tag:
bash "$ROOT/scripts/analysis/run-rector.sh" --subject "$SUBJECT" --digests
```

- Default is dry-run; do **not** pass `--apply` here. The diff/rule-hit summary is
  the basis for "what percentage is auto-fixable".
- Digests rules are **unlicensed, AI-generated, edge-targeting** (PROMPT 2.1.1).
  In assessment they are used only to *estimate*, never applied. Note in the
  report that some digests rules target APIs removed only in 11.2+/12.0, so they
  may overstate the auto-fixable share for a 11.0/11.1 target.
- The script clones/updates `dbuytaert/drupal-digests` into `digests_cache_dir`
  at runtime — never vendored. If the clone fails, soft-skip the digests pass and
  note it.

For a **reproducible** auto-fixable count (instead of eyeballing the diff), add
`--json`: `run-rector.sh --subject "$SUBJECT" --json` emits
`{status, ok, errors, changed_files, files, pass1_files, pass2_files}` — `pass1` =
official rector, `pass2` = digests. Use `changed_files` and the pass split for the
verdict, but only when `status` is `"ok"`.

**Exit 3 = the official Rector pass crashed** (e.g. `[ERROR] Could not detect twig set.` from an
incompatible `rector/rector`, a PHP fatal, or per-file processing errors): the
`--json` payload has `status: "error"` and `errors[]` with the message, and there
is **no auto-fixable verdict** — never read it as "0 files would change". Stop, show the
diagnostic (installed vs known-good versions), repair the toolchain with
`install-toolchain.sh --dir <drupal_root> --source reference` (or fix `rector.php`
when the toolchain already matches the known-good set), and re-run.
In the report, record the Rector line as "not available (toolchain crash)" rather
than an auto-fixable share of 0%. A message starting `DET-1:` (`errors[].pass` 0)
is not a crash: Rector did not run (DDEV down for a root with a DDEV project, or a
tool that differs from the lock's pins); start DDEV, or restore the pins
(`install-toolchain.sh --dir <drupal_root>`) or accept the installed versions
(`lock-sync.sh --dir <drupal_root>`), never `--source reference` for it.

**Exit 4 means only the digests pass crashed** (`status: "partial"`, `digests_status: "error"` with `--json`; e.g. a broken upstream rule file): `pass1_files`/the official count stand, the toolchain is fine — do **not** reinstall it. Pin a known-good digests commit (`--digests-ref <sha>` / `DRUPILOT_DIGESTS_REF`) or skip the layer (`DRUPILOT_USE_DIGESTS_RULES=false`); the broken SHA is never frozen in the lockfile. In the report, record only the digests
line as "not available (digests ruleset crash)".

### 3.2 PHPStan at deprecation level

```bash
bash "$ROOT/scripts/analysis/run-phpstan.sh" --subject "$SUBJECT" \
     --level "$(config_get DRUPILOT_PHPSTAN_LEVEL 2)"
```

Level 2 is the deprecation-detection level (what drupal-check pins). Not every
deprecation message is a "must-fix to run on D11" item: classify them first
(below) — only the **hard** ones (and the **unknown** ones, conservatively) are.
Distinguish the hard deprecations Rector already covers (in §3.1) from those it
does not (manual). For
a reproducible count, add `--json` (PHPStan's native `--error-format=json`) and
read `.totals.file_errors` / `.totals.errors` rather than estimating from the
human report. Check `.drupilot.status` first: `findings` / `clean` are a real
verdict, but `crashed` (exit 3, `totals: null`, reason in `.drupilot.crash`) means
PHPStan could not analyse at all (invalid config, fatal error) — report that as a
blocker to fix, never as "0 deprecations" or "found issues". A crash reason that
starts with `DET-1:` means PHPStan did not run: DDEV is down for a root with a
DDEV project, or a tool differs from the lock's pins (start DDEV, or run
`install-toolchain.sh --dir <drupal_root>` / `lock-sync.sh --dir <drupal_root>`). `.drupilot.notices`
lists PHP/config deprecation notices PHPStan printed (e.g. a stale `drupal_root`).

**Hard vs soft (`DRUPILOT_SOFT_DEPRECATIONS`).** Classify the PHPStan JSON:

```bash
STATE="$(bash -c '. "$1/scripts/lib/common.sh"; project_state_dir "$2"' _ "$ROOT" "$SUBJECT")"
mkdir -p "$STATE"
bash "$ROOT/scripts/analysis/run-phpstan.sh" --subject "$SUBJECT" --json > "$STATE/phpstan.json" || true
bash "$ROOT/scripts/analysis/classify-deprecations.sh" --file "$STATE/phpstan.json" \
  --subject "$SUBJECT" --json
```

**hard** = removed in a Drupal major ≤ the target major (e.g. `user_roles()`,
removed in 11.0.0, which PHPStan reports as "Function user_roles not found.");
**soft** = removed in a later major (e.g. `user_load_by_name()`,
`user_load_by_mail()`, `text_summary()`, `check_markup()`, `user_cookie_save()`:
deprecated in 11.4.0, removed from 13.0.0) — they still work on every Drupal 11
core; **unknown** = no readable Drupal removal version (treated as hard). Only
`counts.hard + counts.unknown` count as deprecations in the verdict (§5); list the
soft ones in the report's "Soft deprecations" table (`symbols[]` with
`class: soft`: symbol, deprecated in, removed in, effort — `n/a` when the catalog
has none, never invented — replacement at the core floor, and the Phase 1
`action` the policy gives: `report` by default). Record `deprecations_hard`,
`deprecations_soft` and `soft_deprecations_policy` in `assess.json`.

Make the deprecations a **teaching aid**, not a wall of red: pipe the analyzer
output through the explainer, which annotates each known deprecated symbol with
what changed, the modern fix, and a drupal.org change-records link:

```bash
bash "$ROOT/scripts/analysis/run-phpstan.sh" --subject "$SUBJECT" \
  | bash "$ROOT/scripts/analysis/explain-deprecations.sh"   # add --json for structured output
```

Include the recognized items (and their fixes) in the report so the developer
understands *why* each change is needed, not just that it is.

### 3.3 PHPCS (style baseline, informational for assessment)

```bash
bash "$ROOT/scripts/analysis/run-phpcs.sh" --subject "$SUBJECT"
```

Do **not** pass `--fix` during assessment. Use the error/warning counts to gauge
code-quality distance to a clean ruleset (relevant to a Phase 2 estimate, not to
Phase 1 viability). The ruleset is the subject's own when it ships a loadable
one, else `Drupal,DrupalPractice`; name the one used in the report (`--json` →
`.drupilot.source` / `.drupilot.ruleset`, or the "Ruleset" log line).
`--json` (PHPCS's `--report=json`) gives the exact `.totals.errors` /
`.totals.warnings` / `.totals.fixable` for the report.

### 3.4 Upgrade Status (only if Drupal is installed)

```bash
if ddev_running "$(find_drupal_root "$SUBJECT")"; then
  bash "$ROOT/scripts/analysis/run-upgrade-status.sh" --module "$NAME"
else
  log_warn "Drupal not installed/running — skipping upgrade_status (run /drupilot-setup to enable it)."
fi
```

`upgrade_status` requires a bootstrapped Drupal (DB + core). It corroborates the
Rector/PHPStan findings and adds environment-level signals (e.g. contrib project
D11 readiness). Its absence must never block the report.

### 3.5 Core compatibility decision (info.yml + composer + SemVer)

Compute the recommended Drupal core target with the dedicated helper. It is
read-only and needs only the subject's `*.info.yml`:

```bash
bash "$ROOT/scripts/analysis/core-strategy.sh" --subject "$SUBJECT" --phase port --json
```

It returns `{ strategy, recommended_core_version_requirement,
composer_core_constraint, require_php, php_floor_detected,
php_floor_target_compatible, d10_support, verify_cores[], version_bump,
rationale[], warnings[], suggested_remaining_tasks[] }`. The strategy comes from
`DRUPILOT_CORE_TARGET_STRATEGY` (`auto` | `d11-only` | `keep-d10`; legacy
`DRUPILOT_KEEP_D10` still overrides). **Policy:** keeping Drupal 10 (`^10 || ^11`)
carries a `require.php` floor — Drupal 10 allows PHP 8.1, so without it a D10 +
low-PHP site would install and then fatal. `DRUPILOT_REQUIRE_PHP_FLOOR` (`detect`
default) sets that floor to the real minimum the code needs (e.g. `>=8.1`); `target`
keeps `>=<target>`. `php_floor_target_compatible` is false when the code uses a
construct newer than the target, and a kept `^10 || ^11` is reported
`declared-not-verified` — relay both (the port's core matrix,
`verify-core-matrix.sh`, later checks the `verify_cores` legs statically on a real
Drupal 10 core; the assessment does not build one). `auto` keeps the widest
BC-preserving set and switches to `^11` (a **major** version bump) on a BC break.
Use `--phase port` for the assessment; an opt-in Phase 2 refactor
(`--phase refactor`) would recommend `^11` + a major bump. Carry every field
(including `version_bump` and the warnings) into the report and `assess.json`.

Build the classification that drives the verdict:

1. **Auto-fixable by Rector** — deprecations covered by `Drupal10SetList` +
   `Drupal11SetList` + the PHP set, confirmed by the dry-run diff. Cheap.
2. **Auto-fixable only by the digests layer** — covered by digests rules but not
   the official rector. Cheap *but* requires human diff review and may raise the
   effective `core_version_requirement` (PROMPT 2.1.1 warning 3). Count
   separately.
3. **Manual changes** — deprecations PHPStan flags that no Rector rule covers,
   plus mechanical edits Rector skips. Medium cost.
4. **Hard breaks** — `assess.sh` scans the four categories of
   `config/catalog/hard-breaks.json` (Twig 3, CKEditor 5, jQuery UI, Symfony 7;
   each a POSIX ERE over the files its globs name, each fact verified in core)
   and lists the matching files in `hard_break_categories`. `hard_breaks` is the
   number of categories present. **Symfony 7** is the most false-positive-prone
   (having a subscriber is common and may not break): it still counts for the
   verdict, but say in the report whether PHPStan actually flags a type or
   signature error there; if it does not, call it "no real work".
5. **info.yml status** — the recommended `core_version_requirement` comes from
   the core-strategy helper (§3.5): `auto` yields `^10 || ^11` for a
   BC-preserving port (paired with a `require.php` floor — see
   `DRUPILOT_REQUIRE_PHP_FLOOR`) or `^11` on a BC break. A missing
   `core_version_requirement` (or a legacy `core: 8.x`) is **blocking** and must
   be flagged.
6. **Contrib dependency D11 support** — use the dependency readiness panel
   instead of eyeballing the lists:

   ```bash
   bash "$ROOT/scripts/analysis/deps-status.sh" --subject "$SUBJECT"
   # --json for {totals:{ready,blockers,unknown}, dependencies:[{project,d11,url}]}
   # --offline to skip the network checks (all contrib deps -> unknown)
   ```

   It reads `dependencies:` in `*.info.yml` and `require` in `composer.json`, then
   checks each non-core `drupal/*` project against the drupal.org release-history
   feed (`ready` / `not-ready` / `not-on-drupalorg` / `unknown` when the network is
   blocked — never guessed). Feed `blockers` into the verdict: an unported **hard**
   dependency with no D11 release is an external blocker that caps viability —
   document it, never fake green. `upgrade_status` is a complementary signal when
   Drupal is installed.

### 3.6 Core signature changes (report-only, no toolchain)

Rector and PHPStan judge the module against the ONE core in the sandbox; the
module declares a RANGE. Check it against the verified catalog of Drupal 10 → 11
signature changes (`.signature_changes` in `config/deprecations.json`, each entry
checked against core source):

```bash
bash "$ROOT/scripts/analysis/scan-signature-changes.sh" --subject "$SUBJECT" --json
# --core-floor 10.3  judge at the floor the recommended target keeps (§3.5),
#                    instead of the floor of the current core_version_requirement
```

It reports `{core_floor, errors, warnings, infos, findings:[{id, severity, file,
line, message, fix, d10_compat, change_record}]}` (exit 3 when there are error
findings — expected for an unported module, not an assessment failure):

- `config-form-base-ctor` / `content-translation-controller-ctor` — a direct
  subclass whose `parent::__construct()` passes too few arguments
  (`TypedConfigManagerInterface` / `TimeInterface` are required from 11.0):
  ArgumentCountError on Drupal 11.
- `entity-get-original` / `entity-set-original` (11.2), `revision-cache-id`
  (11.3) — a module method that core adds later: **error** when its signature is
  incompatible (fatal "Declaration must be compatible") or it carries
  `#[\Override]` below the floor; **warn** when it silently becomes an override.
- `hook-entity-operation` / `hook-entity-operation-alter` (11.3) — an
  implementation that REQUIRES the new `$cacheability` parameter breaks every
  core below 11.3; a one-parameter implementation is `info` (keep any new
  parameter optional).
- `entity-original-accessors-call` — `->getOriginal()`/`->setOriginal()` while
  the floor is below 11.2 (warn: fatal on a core entity there).

Every **error** finding counts as one `manual` item in §5 (Rector does not fix
them) and goes into the plan's Phase 1 with its `fix`; list warnings as review
items. `#[\Override]` on a method that exists only in some of the declared cores
breaks the older ones (PHP 8.3+ compile-time fatal): never plan to add it while
the floor is below the minor that introduced the parent method.

### 3.7 Pre-existing hygiene (report, do not fix in Phase 1)

Metadata problems the module already has, which no analyzer of the validate loop
reports and which keep resurfacing as "pre-existing bugs" during a port. Read-only,
no toolchain:

```bash
bash "$ROOT/scripts/analysis/lint-extension-metadata.sh" --subject "$SUBJECT" --json
# --set-dir DIR  resolve services/routes/plugins of sibling modules (default: the
#                subject's parent when it is a modules|themes|profiles/custom dir)
```

It reports `{checks_run, findings:[{check, severity, extension, file, line,
message, suggestion}], totals:{error, warn, info}}`, always exit 0, and saves it as
`metadata-lint.json` in the subject's state dir (the port report renders it):

- `config-schema` — `config/install|optional/<machine>.*.yml` without a matching
  `config/schema` key (exact or trailing wildcard, as core's
  `TypedConfigManager::getFallbackName()` resolves it): strict schema checks in
  Kernel/Functional tests fail on it.
- `plugin-schema` — a Block/Condition/Filter/FieldFormatter/FieldWidget plugin
  with its own settings and no `block.settings.<id>` / `condition.plugin.<id>` /
  `filter_settings.<id>` / `field.formatter.settings.<id>` /
  `field.widget.settings.<id>` schema.
- `configure-route` — the info.yml `configure:` route is defined nowhere (core's
  modules page silently drops the link: it checks it with `checkNamedRoute()`).
- `services-class` — a service class with no file (orphan) or a letter-case
  mismatch (error).
- `services-arity` — `arguments:` count vs the constructor: fewer than required is
  an ArgumentCountError (error); extra ones are silently ignored by PHP (warn).
- `submodule-core-req` — a nested `*.info.yml` that does not admit Drupal 11
  (core refuses to install it), or has no `core_version_requirement` (core throws
  InfoParserException; `package: Testing` is exempt).
- `undeclared-deps` — a module the code uses (class, service, route, library,
  plugin, config dependency) that `dependencies:` does not declare, with the
  proposed `<project>:<module>` / `drupal:<module>` entry (a guarded, optional use
  is info).

These findings **do not feed the S/M/L/XL rubric** (§5): it stays unchanged, so
the verdict reproduces. List them in the report's "Pre-existing hygiene" section
and the plan: Phase 1 only bumps the submodules' `core_version_requirement`
(`set-core-requirement.sh`, part of the port); everything else is reported, to be
fixed in a follow-up or in Phase 2. Record the totals in `assess.json` as
`hygiene: {error, warn, info}`.

### Optional context: digests issue summaries

When `DRUPILOT_USE_DIGESTS_RULES` is true and the cache is present, the repo's
`issues/*.md` (664 AI summaries of notable core changes) explain *why* an API
changed. Read the relevant ones (match by API name / change-record number) to
justify a finding and shape the plan. They are context only — never
copied/redistributed (unlicensed), never the sole basis for a verdict.

## 5. Estimate effort (S / M / L / XL) — computed by `assess.sh`

The verdict comes from three integer counts (ADR 0025), so two assessments of
the same module reach the same verdict. Never recompute or override it:

- `rubric.manual`: the scope-current PHPStan deprecations of class `hard` or
  `unknown` with no Rector change in the same function (`manual_items`), plus
  the signature findings of severity `error`. Soft ones never count, whatever
  `DRUPILOT_SOFT_DEPRECATIONS` says.
- `rubric.hard_breaks`: the hard-break categories present (0–4).
- `rubric.blocking_deps`: the dependencies drupal.org has no Drupal 11 release
  for (`deps-status.sh` blockers). Whether an alternative is viable is your
  judgement for the plan, not for the count.

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

## 6. Produce the artifacts

`assess.sh` writes the machine-readable `assess.json` to the hidden per-project
state dir and renders the human-readable `viability-report.md` from
`templates/viability-report.md.tmpl` into the visible `.drupilot/` dir, both
from the same numbers, and records the `assessed` stage with its effort. You
write only the staged **`port-plan.md`** (from `templates/port-plan.md.tmpl`, in
the same `.drupilot/` dir): stages, per-stage effort, risks, what preserves the
original functionality without colliding with Drupal 11 (Phase 1), and what is
**deferred to Phase 2**. The plan must exist even for an XL/above-threshold
verdict.

Suggested phasing to encode in the plan:

1. **Stage 0 — Environment**: `/drupilot-setup` (DDEV + add-ons + toolchain).
2. **Stage 1 — info.yml + official Rector**: bump `core_version_requirement`
   in the main and every submodule `info.yml` (`set-core-requirement.sh`),
   apply `palantirnet/drupal-rector` (dry-run -> review -> apply -> validate).
3. **Stage 2 — Manual deprecations + hard breaks**: Twig 3, CKEditor 5, jQuery
   UI, Symfony 7, in risk order; optionally the filtered digests layer.
4. **Stage 3 — Tests green**: adapt + run the full suite (`test-adaptation`).
5. **Phase 2 (opt-in) — Refactor**: "Drupal 11 way", PHPStan 5-6, clean PHPCS,
   added tests. Deferred unless the developer opts in.

## 7. Report in chat (concise English)

After writing the files, give a short summary: subject + type, PHP/Drupal target,
the **core-target recommendation** (recommended `core_version_requirement`, the
`require.php` it implies, and the **version-bump verdict** — e.g. "new major:
drops Drupal 10" or "minor: adds Drupal 11"), the verdict and whether it crosses
the threshold, the headline auto-fixable vs manual split, the hard breaks found,
info.yml status, any unported dependency, and the path to both artifacts. Offer
the next step (`/drupilot-port` for Phase 1) — never decide for the developer.

## 8. Gotchas

- Never run Rector/PHPCS in write mode here. Assessment is read-only.
- Digests percentages can be optimistic for a 11.0/11.1 target (rules target the
  development edge). Always caveat this.
- Long analyses on large modules should run in the background and notify on
  completion rather than blocking the session (PROMPT 6).
- If `find_drupal_root` returns empty, host-only static analysis still works for
  Rector/PHPStan (they need the core tree, which `/drupilot-setup` provides);
  upgrade_status does not. Be explicit in the report about which signals were
  available.
