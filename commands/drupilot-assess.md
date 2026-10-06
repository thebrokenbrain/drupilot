---
description: Run a non-destructive Drupal 9/10 to 11 viability assessment in the Drupal test-bed (assess.sh computes an S/M/L/XL verdict from the Rector --dry-run, PHPStan and PHPCS findings into assess.json and a viability-report.md), then narrate it and write a phased porting plan. Use when the user wants to know how hard a module/theme is to port before touching any code.
argument-hint: "[module-or-theme-path]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, Skill, AskUserQuestion
---

# /drupilot-assess — Drupal 11 viability assessment (read-only)

You are assessing how hard it is to port a Drupal 9/10 module or theme to Drupal 11.
This command performs **only static, non-destructive analysis**: it never writes to
the subject's source files. `scripts/analysis/assess.sh` computes the effort
verdict (S/M/L/XL) deterministically into `assess.json`, renders
`viability-report.md`, and caches the result so `/drupilot-status` and later
commands do not recompute it; you narrate it and write the phased porting plan.

Subject path argument: `$1` (fallback: the current working directory).

## Step 0 — Gate (profile `analyze`)

Before doing anything, run the requirements gate. If it exits non-zero, show the
report verbatim and STOP — do not run any analysis and do not write any files.

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile analyze && bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; copy_legacy_state_once'
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
  ROOT="$(subject_project_root "$SUBJECT" 2>/dev/null || true)"; IN=no; \
  if [[ -n "$ROOT" && "$SUBJECT/" == "$ROOT"/* ]]; then IN=yes; fi; \
  PLACED=""; if [[ -n "$ROOT" && "$IN" == no ]]; then for t in modules themes profiles; do \
    if [[ -d "$ROOT/web/$t/custom/$(basename "$SUBJECT")" ]]; then PLACED="$ROOT/web/$t/custom/$(basename "$SUBJECT")"; fi; done; fi; \
  echo "drupal_root=${ROOT:-<none>}"; echo "subject_in_root=$IN"; echo "placed=${PLACED:-<none>}"; \
  echo "php_target=$(resolve_php_target)"; echo "drupal_target=$(resolve_drupal_target)"; \
  [[ "$IN" == yes ]] || ROOT=""; \
  echo "viability_threshold=$(DRUPILOT_PROJECT_DIR="$ROOT" config_get DRUPILOT_VIABILITY_THRESHOLD medium)"' \
  -- "$1"
```

`viability_threshold` is the resolved `DRUPILOT_VIABILITY_THRESHOLD` (env >
`.drupilot.json` > defaults); the effort verdict compares against it.

If the subject is not a Drupal extension directory (no `*.info.yml`), say so and
ask the user for the correct path. Note whether `core_version_requirement` is
present — a missing one is a blocking `info.yml` finding.

`assess.sh` runs Rector and PHPStan in the subject's Drupal root (the test-bed,
`drupal_root`), so the subject must be inside it (`subject_in_root=yes`).
Otherwise: when `placed` names a path, setup placed the module there (the
original may even be gone, moved): offer to assess that path instead. With no
placed copy, STOP: tell the user to **run `/drupilot-setup` first**, then
`/drupilot-assess` again. Run no analysis and write no file.

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
**Continue independently** (assess fresh anyway). A pre-answer skips the tab:
when `bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/choice.sh" --key EXISTING_WORK --subject "$1" --json`
returns a `value` (`existing` / `independent`), act on it and say so in one line.
Skip this for a non-contrib /
custom module, and never let a blocked network stop the assessment — the URL is
the fallback.

## Step 2 — Load the operating procedure

Invoke the **viability-assessment** skill: it explains every field of
`assess.json` and how to narrate it. Then delegate the narration and the plan to
the **drupal-viability-analyst** subagent (via the Task tool): it reads the
verdict `assess.sh` computed, never a verdict of its own.

## Step 3 — Run the assessment (one script, read-only for the code)

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/assess.sh" --subject "<subject>" --json
```

(`<subject>` is the `subject=` of Step 1, or the placed copy you agreed to assess.)

`assess.sh` runs the assess stage's deterministic tools (the official Rector
dry-run, PHPStan, PHPCS, the port-safety checks, the signature scan and the
metadata lint, through `scripts/ai/extract.sh`), normalizes and classifies their
findings, asks `core-strategy.sh` and `deps-status.sh`, and computes the
**S/M/L/XL verdict from three counts** (ADR 0025). It writes `assess.json` to the
hidden state dir, renders `viability-report.md` into the visible `.drupilot/`
dir, records the `assessed` stage with its effort, and prints `assess.json` on
STDOUT. The same tree, lock and drupal.org answers give the same `assess.json`
outside `meta`. Exit codes:

- **0** — assessed: go on to Step 4.
- **1** — a usage error, not a Drupal extension (no `<machine_name>.info.yml`),
  no Drupal root to run the assess stage in (run `/drupilot-setup` first), or
  no findings to assess. Relay its message and stop.
- **2** — `jq` is missing: tell the user to run `/drupilot-doctor`, and stop.
- **3** — **provisional**: Rector, PHPStan, the port-safety checks or the
  signature scan gave no verdict. The result is `assess-provisional.json` (never
  `assess.json`), with `provisional: true` and `no_verdict` naming the tool; the counts are
  incomplete and the `assessed` stage is not recorded. Report it as a
  **blocker**, never as zero findings or a final verdict. A crash (e.g. a
  Rector `[ERROR] Could not detect twig set.`): show the diagnostic it prints
  and repair the toolchain with
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/install-toolchain.sh" --dir <drupal_root> --source reference`
  (or `/drupilot-setup`), then re-run. A message starting `DET-1:` is not a
  crash: DDEV is down for a root with a DDEV project, or a tool differs from the
  lock's pins. Start DDEV, or restore the pins (`install-toolchain.sh --dir
  <drupal_root>`) or accept the installed versions (`lock-sync.sh --dir
  <drupal_root>`), never `--source reference` for it, then re-run.

The digests layer is not part of the assessment: a deprecation only a digests
rule fixes counts as manual, and its candidate rules are reviewed in
`/drupilot-port`.
**Upgrade Status** (optional context, only when Drupal is installed; not part
of `assess.json`): on a Drupal 11 bed it reports the *next* major's issues, so
they never count toward the verdict:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-upgrade-status.sh" --module <machine_name>
```

## Step 4 — Narrate the verdict and write the plan

Hand `assess.json` to the analyst (it reads that file and does not run
`assess.sh` again). Never recompute or override its numbers: narrate them.

- **Verdict**: `verdict`, with the three counts and the matched rule from
  `rubric` (quote `rubric.rule` verbatim), and `above_threshold` against
  `viability_threshold`. drupilot never refuses: even above the threshold it
  delivers the staged plan. With `provisional: true`, say the verdict is
  provisional and name the tool to repair.
- **Manual work**: `manual_items` (each with its finding id and occurrences):
  the hard and unknown deprecations no Drupal Rector rule changes in the same
  function or method, plus the signature and port-safety errors.
- **Auto-fixable**: `auto_fixable` (the official Rector files and rules).
- **Hard breaks**: `hard_break_categories` (Twig 3, CKEditor 5, jQuery UI,
  Symfony 7) with the files that matched. A Symfony 7 hit is the most likely
  to be harmless: say whether PHPStan flags a real type or signature error
  there.
- **Soft deprecations**: `soft_deprecations` with the policy
  `soft_deprecations_policy`; they never count.
- **`info.yml`** and the core target: `info_yml`, `core_target`
  (recommended requirement, `require.php`, version bump, warnings).
- **Contrib dependencies**: `dependencies` (offline, contrib ones are
  `unknown`; a blocker counts as `blocking_deps`).
- **Pre-existing hygiene**: `hygiene` and the metadata findings; they never
  count.

Write the staged **`port-plan.md`** from `@${CLAUDE_PLUGIN_ROOT}/templates/port-plan.md.tmpl`
into the same `.drupilot/` dir as the report, from these fields (Phase 1
minimal port vs. Phase 2 opt-in refactor); a provisional assessment gets a plan
marked provisional, whose first step repairs the failing tool. It is the only
file this command writes by hand: never edit `assess.json` or
`viability-report.md`. You may consult the AI-written core
change summaries in the digests cache (`issues/*.md`) for why an API changed;
never copy that text into the plugin repository (it is unlicensed).

## Step 5 — Summarize in chat

End with a concise English summary:

- Subject (machine name + type) and the effective PHP / Drupal target.
- The **S/M/L/XL verdict**, whether it crosses the configured threshold, and
  whether it is provisional (then the tool to repair comes first).
- The three counts and the matched rule (`rubric`).
- The top hard breaks and the `info.yml` / contrib-dependency status.
- The **phased plan** at a glance: Phase 1 (minimal port via `/drupilot-port`)
  vs. Phase 2 (optional full refactor via `/drupilot-refactor`), and what is
  explicitly deferred to Phase 2.
- The next suggested command (`/drupilot-setup` if no environment yet, otherwise
  `/drupilot-port`), and the path to the visible `.drupilot/viability-report.md`.

Never modify the subject's source during assessment. This command is read-only.
