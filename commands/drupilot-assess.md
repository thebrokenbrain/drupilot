---
description: Run a non-destructive Drupal 9/10 to 11 viability assessment (Rector --dry-run + PHPStan + PHPCS, plus upgrade_status if Drupal is installed) and produce a viability-report.md with an S/M/L/XL verdict and a phased porting plan. Use when the user wants to know how hard a module/theme is to port before touching any code.
argument-hint: "[module-or-theme-path]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, Skill, AskUserQuestion
---

# /drupilot-assess — Drupal 11 viability assessment (read-only)

You are assessing how hard it is to port a Drupal 9/10 module or theme to Drupal 11.
This command performs **only static, non-destructive analysis**: it never writes to
the subject's source files. It produces a `viability-report.md` with an effort
verdict (S/M/L/XL) and a phased porting plan, and caches the result so
`/drupilot-status` and later commands do not recompute it.

Subject path argument: `$1` (fallback: the current working directory).

## Step 0 — Gate (profile `analyze`)

Before doing anything, run the requirements gate. If it exits non-zero, show the
report verbatim and STOP — do not run any analysis and do not write any files.

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile analyze
```

If the exit code is `2`, a hard requirement (git, jq, and composer-or-php) is
missing. Relay the actionable hints and tell the user to run `/drupilot-doctor`,
then stop with no side effects.

## Step 1 — Resolve the subject and the Drupal root

```bash
!bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; \
  SUBJECT="${1:-$PWD}"; SUBJECT="$(cd "$SUBJECT" 2>/dev/null && pwd || echo "$SUBJECT")"; \
  echo "subject=$SUBJECT"; \
  echo "machine_name=$(subject_machine_name "$SUBJECT" 2>/dev/null || echo "?")"; \
  echo "type=$(subject_type "$SUBJECT" 2>/dev/null || echo "?")"; \
  echo "core_requirement=$(subject_core_requirement "$SUBJECT" 2>/dev/null || echo "<missing>")"; \
  echo "drupal_root=$(find_drupal_root "$SUBJECT" 2>/dev/null || echo "<none>")"; \
  echo "php_target=$(resolve_php_target)"; echo "drupal_target=$(resolve_drupal_target)"' \
  -- "$1"
```

If the subject is not a Drupal extension directory (no `*.info.yml`), say so and
ask the user for the correct path. Note whether `core_version_requirement` is
present — a missing one is a blocking `info.yml` finding.

## Step 1.5 — Is someone already porting this? (contrib only)

For a contrib project hosted on drupal.org, check the issue queue before spending
effort, so the developer can build on existing work instead of duplicating it:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/find-upstream-issue.sh" --project "<machine_name>"
```

It surfaces open issues that look like a Drupal 11 effort (best-effort title scan)
and always prints the pre-filtered issue-queue URL. If it finds a likely match,
present a tab with **AskUserQuestion** (header "Existing work"): **Base on the
existing issue/MR** (open the URL, adopt its branch/patch as the starting point) ·
**Continue independently** (assess fresh anyway). Skip this for a non-contrib /
custom module, and never let a blocked network stop the assessment — the URL is
the fallback.

## Step 2 — Load the operating procedure

Invoke the **viability-assessment** skill to load the exact toolchain commands,
the classification rules, and the digests handling caveats. Follow its procedure.

Then delegate the heavy interpretation to the **drupal-viability-analyst**
subagent (via the Task tool): it knows how to read Rector / PHPStan /
upgrade_status output, separate auto-fixable deprecations from manual work, spot
hard breaks (Twig 3, CKEditor 5, jQuery UI, Symfony 7), and estimate effort.

## Step 3 — Run the static analyzers (all read-only)

Run each leaf script with the resolved subject path. These derive the PHP target
from `DRUPILOT_PHP_TARGET` (default `8.3`) and auto-detect whether to run through
`ddev exec` or host binaries.

1. **Rector dry-run — official rules** (never `--apply` here):

   ```bash
   !bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "$1"
   ```

2. **Rector dry-run — complementary digests layer**, only if
   `DRUPILOT_USE_DIGESTS_RULES` is true. This clones/updates the unlicensed,
   AI-generated `dbuytaert/drupal-digests` repo into the plugin cache and runs it
   by `--config`. Treat its hits as *candidate* edge-case deprecations, not
   ground truth (see the skill and PROMPT 2.1.1):

   ```bash
   !bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "$1" --digests
   ```

3. **PHPStan** at the deprecation level (`DRUPILOT_PHPSTAN_LEVEL`, default `2`):

   ```bash
   !bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpstan.sh" --subject "$1"
   ```

4. **PHPCS** (`Drupal` + `DrupalPractice`, no autofix during assessment):

   ```bash
   !bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpcs.sh" --subject "$1"
   ```

5. **Upgrade Status** — only if Drupal is actually installed (needs a running
   DDEV environment + bootstrap + DB). The script soft-skips with a clear message
   when Drupal is not installed; do not treat that skip as a failure:

   ```bash
   !bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-upgrade-status.sh" --module "$(bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; subject_machine_name "${1:-$PWD}"' -- "$1")"
   ```

Capture each tool's raw output for the report appendix. If a tool's prerequisites
are missing (e.g. the dev toolchain is not installed because `/drupilot-setup`
has not run), note it as "not measured" rather than inventing numbers.

## Step 4 — Classify, estimate, and decide

Hand the collected output to the analyst. Produce:

- **Auto-fixable vs manual**: how many findings Rector (official + digests) can
  fix automatically vs. what needs hand work. Express it as a rough percentage.
- **Hard breaks**: Twig 3 (removed filters/functions, `spaceless`), CKEditor 5
  (CKEditor 4 gone), jQuery / jQuery UI (`core/jquery.ui.*` removed), Symfony 7
  (event subscriber / type-hint changes), PHPUnit 10/11, Guzzle 7, Drush 13.
- **`info.yml` status**: is `core_version_requirement` present and D11-compatible?
- **Contrib dependencies**: do the declared `dependencies:` have D11-ready
  releases? Flag any that do not.
- **Effort verdict**: one of **S / M / L / XL**, with a one-paragraph rationale.
  Compare against `DRUPILOT_VIABILITY_THRESHOLD` (default `medium`); if the effort
  exceeds the threshold, say so plainly — but **still deliver a plan**. drupilot
  never refuses: it offers a staged plan that preserves the original behavior
  without colliding with native D11 APIs.

You may consult the AI-written core-change summaries in the digests cache
(`issues/*.md`) for context on *why* an API changed, to make the plan clearer.
Do not copy that text into the plugin repo (the digests repo is unlicensed).

## Step 5 — Write the report (from the template) and cache it

Render the report from the template, substituting the `{{PLACEHOLDER}}` tokens
with the resolved facts and findings:

- Template: `@${CLAUDE_PLUGIN_ROOT}/templates/viability-report.md.tmpl`
- Write the **human-readable** `viability-report.md` into the visible `.drupilot/`
  artifacts dir at the Drupal root (helper `project_artifacts_dir`; when no Drupal
  root exists yet — assess can run before setup — it falls back to
  `<subject>/.drupilot/`). Resolve the directory and write there:

```bash
!bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; \
  SUBJECT="${1:-$PWD}"; printf "%s\n" "$(project_artifacts_dir "$SUBJECT")/viability-report.md"' \
  -- "$1"
```

Write the report to that path with the Write tool. Also write a small companion
**machine-readable** `assess.json` into the hidden per-project **state dir**
(`project_state_dir`, under `$HOME` — never in the project tree, so it cannot leak
into a contribution) capturing the verdict, the auto-fixable percentage, the
hard-break list, and a timestamp, so `/drupilot-status` can show a one-line summary
without re-reading the whole report:

```bash
!bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; \
  SUBJECT="${1:-$PWD}"; printf "%s\n" "$(project_state_dir "$SUBJECT")/assess.json"' \
  -- "$1"
```

The visible `.drupilot/viability-report.md` is the developer-facing copy; the
machine cache in the hidden state dir is what later commands read.

## Step 6 — Summarize in chat

End with a concise English summary:

- Subject (machine name + type) and the effective PHP / Drupal target.
- The **S/M/L/XL verdict** and whether it crosses the configured threshold.
- Auto-fixable vs manual split (rough %).
- The top hard breaks and the `info.yml` / contrib-dependency status.
- The **phased plan** at a glance: Phase 1 (minimal port via `/drupilot-port`)
  vs. Phase 2 (optional full refactor via `/drupilot-refactor`), and what is
  explicitly deferred to Phase 2.
- The next suggested command (`/drupilot-setup` if no environment yet, otherwise
  `/drupilot-port`), and the path to the visible `.drupilot/viability-report.md`.

Never modify the subject's source during assessment. This command is read-only.
