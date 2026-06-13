---
description: drupilot router and guided flow. Detects the current state of a Drupal module/theme port (environment, cached assessment, phase) and recommends the next logical step; can run the full setup->assess->port->[refactor]->test->[contribute] flow by delegating to the orchestrator, or run it hands-off with the `auto` mode word (unattended setup->assess->port->refactor->test that writes the local patch and never performs any outward-facing contribution). Use as the main entry point when the user says "port this module to Drupal 11", "what's next", or just "/drupilot".
argument-hint: "[subject-path] [full|auto|status|next]"
allowed-tools: Bash, Read, Task
---

# drupilot — router and guided flow

You are the entry point for the drupilot plugin. Your job is to **detect the current
state**, **summarize it in English**, and **recommend the next logical step** — and,
only when the user asks for it, drive the whole flow end to end.

## Hard rules

- **English only** in everything you print.
- **Never act before stating what you will do.** Always show a short plan first, then
  proceed. For anything that mutates the system, environment, or a remote, confirm
  intent explicitly.
- Treat the scripts as the source of truth for detection — do not guess versions or
  state from memory.
- `$ARGUMENTS` may carry a subject path (a module/theme directory) and/or a mode
  word: `full`, `auto`, `status`, or `next` (default: `next`). The env var
  `DRUPILOT_AUTONOMOUS=true` is equivalent to the `auto` mode word: when it is set
  and no explicit `status`/`next` is requested, the effective mode is `auto`.

## Step 1 — Detect the environment (gates, no side effects)

Run the preflight engine in report mode and parse the JSON. This never mutates
anything:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile all --json`

From that object read `php_target` and `ready.{analyze,setup,test,contribute}`.

## Step 2 — Detect the subject and the Drupal/DDEV state

Resolve the subject directory: use `$1` if it points at a Drupal extension, otherwise
detect it from the current directory. Then collect facts via common.sh helpers and the
detect-php script (all read-only):

!`bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; SUBJ="${1:-$PWD}"; [[ -d "$SUBJ" ]] || SUBJ="$PWD"; ROOT="$(find_drupal_root "$SUBJ" 2>/dev/null || true)"; printf "subject_dir=%s\n" "$SUBJ"; printf "is_extension=%s\n" "$(is_drupal_extension_dir "$SUBJ" && echo yes || echo no)"; printf "machine_name=%s\n" "$(subject_machine_name "$SUBJ" 2>/dev/null || echo -)"; printf "subject_type=%s\n" "$(subject_type "$SUBJ" 2>/dev/null || echo -)"; printf "core_requirement=%s\n" "$(subject_core_requirement "$SUBJ" 2>/dev/null || echo -)"; printf "drupal_root=%s\n" "${ROOT:--}"; printf "ddev_config=%s\n" "$([[ -n "$ROOT" && -f "$ROOT/.ddev/config.yaml" ]] && echo yes || echo no)"; printf "ddev_running=%s\n" "$(ddev_running "$ROOT" 2>/dev/null && echo yes || echo no)"; printf "state_dir=%s\n" "$(project_state_dir "$SUBJ")"; printf "lockfile=%s\n" "$(LF="$(DRUPILOT_PROJECT_DIR="${ROOT:-$SUBJ}" drupilot_lock_file 2>/dev/null)"; [[ -f "$LF" ]] && echo "$LF" || echo -)"' _ "$1"`

Then detect the effective PHP target and whether it is confirmed:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/detect-php.sh" --json`

Also read the autonomous flag and the contribution mode (so the summary and the
flow honor them):

!`bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; printf "autonomous=%s\n" "$(config_get DRUPILOT_AUTONOMOUS false)"; printf "contrib_mode=%s\n" "$(config_get DRUPILOT_CONTRIB_MODE semi)"; printf "generate_rules=%s\n" "$(config_get DRUPILOT_GENERATE_RULES ask)"; printf "deterministic=%s\n" "$(config_get DRUPILOT_DETERMINISTIC true)"'`

## Step 3 — Read the cached assessment (if any)

Look in the `state_dir` reported above for a cached assessment so you do not recompute
it. Read `@<state_dir>/assess.json` and `@<state_dir>/viability-report.md` if present;
note the verdict, effort (S/M/L/XL), auto-fixable vs manual counts, and the timestamp.
Also note the last test result (`<state_dir>/last-test.json`) and the current phase
marker (`<state_dir>/phase`) if those files exist. If none exist, the project has not
been assessed yet. If Step 2 reported a `lockfile` path, read it and note the
frozen toolchain (Drupal core, key tool versions, the digests SHA) — that is what
a deterministic re-run reuses.

## Step 4 — Summarize and recommend

Print a concise English summary:

- Subject: machine name, type (module/theme/profile), `core_version_requirement`.
- PHP target (and a clear note if it is **unconfirmed**, e.g. 8.5 — never claim it is
  supported).
- **Reproducibility:** whether deterministic mode is on (`deterministic`), and if a
  lockfile exists, the frozen Drupal core / digests SHA it pins.
- Environment readiness per profile (analysis / setup+tests / contribution).
- DDEV state (configured? running?).
- Assessment state (assessed? verdict + effort, or "not assessed yet").

Then recommend exactly one **next step** as a concrete slash command, using this
decision order:

1. If `ready.analyze` is false (or, for an environment task, `ready.setup` is false):
   recommend `/drupilot-doctor` to fix requirements first.
2. Else if there is no DDEV environment and the user wants to run the dynamic toolchain
   or tests: recommend `/drupilot-setup`.
3. Else if there is no cached assessment: recommend `/drupilot-assess`.
4. Else if assessed but not ported: recommend `/drupilot-port`.
5. Else if ported and the user opted into the "Drupal 11 way": recommend
   `/drupilot-refactor`.
6. Else if ported/refactored but tests not green: recommend `/drupilot-test`.
7. Else, if the subject is a contrib project: recommend `/drupilot-contribute`.

Note that `refactor` (Phase 2) and `contribute` are **opt-in** and only suggested, not
forced.

## Step 5 — Run the flow (`full`) or hands-off (`auto`)

Resolve the effective mode: the `$ARGUMENTS` mode word wins; otherwise, if
`autonomous=true` (from Step 2), the effective mode is `auto`; otherwise it is
`next`.

### `full` — guided, with confirmations

If the mode is `full` (or the user explicitly asks to "do the whole thing"):

1. State the plan in English: the ordered phases you will run
   (setup -> assess -> port -> [refactor if opted in] -> test -> [contribute if opted
   in]), which are gated, and that heavy work may run in the background.
2. **Confirm with the user before starting.**
3. Delegate the orchestration to the **drupal-port-orchestrator** subagent via the Task
   tool, passing the subject directory, the detected PHP target, the environment
   readiness, the cached assessment state, and whether the user opted into refactor
   and/or contribution. Let the orchestrator decide when to delegate to the other
   subagents and when to gate.

### `auto` — hands-off, unattended

If the mode is `auto` (the `auto` mode word, or `DRUPILOT_AUTONOMOUS=true`):

1. State the plan briefly, then **proceed without an initial confirmation** — that
   is the point of this mode. (drupilot's own gates are relaxed here, but the
   Claude Code permission mode still governs Bash/Edit/Write prompts; for a truly
   unattended run the user launches with `acceptEdits` or a headless bypass.)
2. Delegate to **drupal-port-orchestrator** with an explicit `autonomous=true`
   instruction so it:
   - runs **setup -> assess -> port -> refactor -> test** in order, gating each
     heavy stage and skipping work already done (idempotent);
   - treats `DRUPILOT_GENERATE_RULES` as `auto` **unless it is explicitly `off`**;
   - writes the local `.patch` at the end of the port (and again after refactor);
   - **never** performs any outward-facing action — no `git push`, no Merge
     Request, no `/drupilot-contribute`. Contribution stays opt-in: if the subject
     is contrib, the orchestrator only *suggests* `/drupilot-contribute` at the end.
3. If a hard requirement is missing for a stage, the orchestrator stops that stage
   with the actionable report and no side effects, exactly as in guided mode.

Honor `DRUPILOT_VIABILITY_THRESHOLD`: if the assessment exceeds it, the
orchestrator still ports (it never refuses) but says so plainly in the final
summary.

### `status` / `next`

If the mode is `status`, just print the summary from Step 4 and stop (defer to
`/drupilot-status` for the canonical no-side-effects report). If the mode is `next`
(default when autonomous is off), print the summary and the single recommended
next step, and stop without acting.
