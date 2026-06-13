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
  `resolve_drupal_target` (default `^11`). **Never hardcode "8.5 supported"** —
  branch on `php_target_unconfirmed`.
- Resolve the plugin root with `${CLAUDE_PLUGIN_ROOT}` (or `plugin_root` from
  common.sh). All leaf scripts live under `${CLAUDE_PLUGIN_ROOT}/scripts/...`.
- Cache results so `/drupilot-status` and later steps do not recompute. Use the
  per-project state dir: `bash -lc '. "$ROOT/scripts/lib/common.sh"; project_state_dir "$SUBJECT"'`.

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

### 3.2 PHPStan at deprecation level

```bash
bash "$ROOT/scripts/analysis/run-phpstan.sh" --subject "$SUBJECT" \
     --level "$(config_get DRUPILOT_PHPSTAN_LEVEL 2)"
```

Level 2 is the deprecation-detection level (what drupal-check pins). Count
deprecation messages: those are the "must-fix to run on D11" items. Distinguish
deprecations Rector already covers (in §3.1) from those it does not (manual).

### 3.3 PHPCS (style baseline, informational for assessment)

```bash
bash "$ROOT/scripts/analysis/run-phpcs.sh" --subject "$SUBJECT"
```

Do **not** pass `--fix` during assessment. Use the error/warning counts to gauge
code-quality distance to a clean `Drupal,DrupalPractice` (relevant to a Phase 2
estimate, not to Phase 1 viability).

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
composer_core_constraint, require_php, version_bump, rationale[], warnings[] }`.
The strategy comes from `DRUPILOT_CORE_TARGET_STRATEGY` (`auto` | `d11-only` |
`keep-d10`; legacy `DRUPILOT_KEEP_D10` still overrides). **Policy:** the port's
PHP floor is `DRUPILOT_PHP_TARGET`, so keeping Drupal 10 (`^10 || ^11`) **always**
carries `require.php: ">=<target>"` — Drupal 10 itself allows PHP 8.1, so without
it a D10 + PHP<target site would install and then fatal. `auto` keeps the widest
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
4. **Hard breaks** — detect each category with the EXACT greps below (run all
   four; a category is "present" when its grep returns ≥1 file). This makes
   `hard_breaks` reproducible instead of a judgment call:

   ```bash
   # Twig 3: spaceless tag + removed filters/functions.
   grep -rIlE '\{%[-[:space:]]*spaceless|\|[[:space:]]*(spaceless|convert_encoding)\b' \
     --include='*.twig' "$SUBJECT"
   # CKEditor 4 (removed in D10): editor config + 4-era plugin JS/yml.
   grep -rIlE 'CKEDITOR\.|Drupal\.editors\.ckeditor|editor\.editor\.ckeditor\b' \
     --include='*.yml' --include='*.js' "$SUBJECT"
   # jQuery UI (removed/externalized): library deps + JS usage.
   grep -rIlE 'jquery[._]ui|core/jquery\.ui' \
     --include='*.libraries.yml' --include='*.yml' --include='*.js' "$SUBJECT"
   # Symfony 7 (subscriber/service signature & type changes).
   grep -rIlE 'EventSubscriberInterface|getSubscribedEvents' --include='*.php' "$SUBJECT"
   ```

   `hard_breaks` = the number of the four categories with ≥1 matching file. Record
   the per-category file lists. **Symfony 7** is the most false-positive-prone
   (having a subscriber is common and may not break): keep it counted for the
   verdict, but note in the report whether PHPStan actually flags a
   type/signature error there — if it does not, call it "no real work".
5. **info.yml status** — the recommended `core_version_requirement` comes from
   the core-strategy helper (§3.5): `auto` yields `^10 || ^11` for a
   BC-preserving port (paired with `require.php: ">=<target>"`) or `^11` on a BC
   break. A missing `core_version_requirement` (or a legacy `core: 8.x`) is
   **blocking** and must be flagged.
6. **Contrib dependency D11 support** — read `dependencies:` in `*.info.yml` and
   `require` in any `composer.json`. For each non-core `drupal/*` dependency,
   note whether it has a D11-compatible release. `upgrade_status` reports this
   when available; otherwise mark as "verify on drupal.org" and treat unported
   hard dependencies as an external blocker that caps viability.

### Optional context: digests issue summaries

When `DRUPILOT_USE_DIGESTS_RULES` is true and the cache is present, the repo's
`issues/*.md` (664 AI summaries of notable core changes) explain *why* an API
changed. Read the relevant ones (match by API name / change-record number) to
justify a finding and shape the plan. They are context only — never
copied/redistributed (unlicensed), never the sole basis for a verdict.

## 5. Estimate effort (S / M / L / XL) — deterministic rubric

The verdict is computed from three integer counts (no subjective weighting), so
two assessments of the same module reach the same verdict:

- `manual` — deprecations PHPStan flags that **no** Rector rule (official or
  digests) covers, plus the mechanical edits Rector cannot make. (`info.yml` is
  not counted — it is always required.)
- `hard_breaks` — how many of the four categories are actually present (0–4),
  counted by the fixed greps in §3 step 4.
- `blocking_deps` — `drupal/*` dependencies with **no** D11 release **and no**
  viable alternative. (A dependency that merely needs swapping but has an
  alternative is not "blocking" — count it as one `hard_break` instead.)

Apply the FIRST matching rule, top to bottom. This IS the verdict, not a hint:

| Verdict | Condition (first match wins) |
|---|---|
| **XL** | `blocking_deps >= 1`  OR  `hard_breaks >= 3`  OR  `manual > 40` |
| **L**  | `hard_breaks == 2`  OR  `manual > 15` |
| **M**  | `hard_breaks == 1`  OR  `manual >= 5` |
| **S**  | otherwise (`hard_breaks == 0` AND `manual < 5` AND `blocking_deps == 0`) |

Record the three counts and the matched rule **verbatim** in the report so the
verdict is auditable and reproduces. The auto-fixable share (official vs digests)
is reported separately as context; it does **not** change the verdict — it
measures what is cheap, not the remaining effort.

Compare against `DRUPILOT_VIABILITY_THRESHOLD` (order `S < M < L < XL`; default
`medium`). If the verdict meets or exceeds it, set the "above threshold" flag.
**Even then, still produce the phased plan** — never withhold it.

## 6. Produce the artifacts

Write both files into the per-project state dir (and copy `viability-report.md`
next to the subject if the user expects it there). Substitute the `{{...}}`
tokens in the templates.

```bash
STATE="$(project_state_dir "$SUBJECT")"
REPORT_TMPL="$ROOT/templates/viability-report.md.tmpl"
PLAN_TMPL="$ROOT/templates/port-plan.md.tmpl"
```

- `viability-report.md` (from `templates/viability-report.md.tmpl`): subject +
  type, PHP/Drupal target (note "unconfirmed" if applicable), the **core
  compatibility decision** (strategy, recommended `core_version_requirement`,
  composer constraint, `require.php`, the **version-bump verdict** and rationale,
  and any PHP-floor warning — from §3.5), verdict (S/M/L/XL) with the
  above-threshold flag, auto-fixable vs manual counts (official vs digests broken
  out), the four hard-break sections with concrete findings, `info.yml` status,
  contrib-dependency D11 table, the phased plan summary, and a raw-tool-output
  appendix (the captured rector/phpstan/phpcs/upgrade_status output, lightly
  trimmed). Fill `{{CORE_TARGET_STRATEGY}}`, `{{RECOMMENDED_CORE_REQUIREMENT}}`,
  `{{COMPOSER_CORE_CONSTRAINT}}`, `{{REQUIRE_PHP}}`, `{{VERSION_BUMP}}`,
  `{{CORE_TARGET_RATIONALE}}`, `{{CORE_TARGET_WARNING}}` and
  `{{TARGET_CORE_REQUIREMENT}}` from the helper JSON.
- `port-plan.md` (from `templates/port-plan.md.tmpl`): staged plan — stages,
  per-stage effort, risks, exactly what preserves original functionality without
  colliding with D11 (Phase 1), and what is explicitly **deferred to Phase 2**
  (the refactor). The plan must exist even for an XL/above-threshold verdict.

Suggested phasing to encode in the plan:

1. **Stage 0 — Environment**: `/drupilot-setup` (DDEV + add-ons + toolchain).
2. **Stage 1 — info.yml + official Rector**: bump `core_version_requirement`,
   apply `palantirnet/drupal-rector` (dry-run -> review -> apply -> validate).
3. **Stage 2 — Manual deprecations + hard breaks**: Twig 3, CKEditor 5, jQuery
   UI, Symfony 7, in risk order; optionally the filtered digests layer.
4. **Stage 3 — Tests green**: adapt + run the full suite (`test-adaptation`).
5. **Phase 2 (opt-in) — Refactor**: "Drupal 11 way", PHPStan 5-6, clean PHPCS,
   added tests. Deferred unless the developer opts in.

Cache a small JSON summary (`assess.json`: verdict, counts, ready flags, the
core-target recommendation — strategy, recommended `core_version_requirement`,
`require.php`, `version_bump` — and a timestamp) in `$STATE` for
`/drupilot-status` and the port stage.

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
