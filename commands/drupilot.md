---
description: drupilot router and guided flow. Detects the current state of a Drupal module/theme port (environment, cached assessment, phase) and recommends the next logical step; can run the full setup->assess->port->[refactor]->test->[contribute] flow by delegating to the orchestrator. Use as the main entry point when the user says "port this module to Drupal 11", "what's next", or just "/drupilot".
argument-hint: "[subject-path] [full|status|next]"
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
  word: `full`, `status`, or `next` (default: `next`).

## Step 1 — Detect the environment (gates, no side effects)

Run the preflight engine in report mode and parse the JSON. This never mutates
anything:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile all --json`

From that object read `php_target` and `ready.{analyze,setup,test,contribute}`.

## Step 2 — Detect the subject and the Drupal/DDEV state

Resolve the subject directory: use `$1` if it points at a Drupal extension, otherwise
detect it from the current directory. Then collect facts via common.sh helpers and the
detect-php script (all read-only):

!`bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; SUBJ="${1:-$PWD}"; [[ -d "$SUBJ" ]] || SUBJ="$PWD"; ROOT="$(find_drupal_root "$SUBJ" 2>/dev/null || true)"; printf "subject_dir=%s\n" "$SUBJ"; printf "is_extension=%s\n" "$(is_drupal_extension_dir "$SUBJ" && echo yes || echo no)"; printf "machine_name=%s\n" "$(subject_machine_name "$SUBJ" 2>/dev/null || echo -)"; printf "subject_type=%s\n" "$(subject_type "$SUBJ" 2>/dev/null || echo -)"; printf "core_requirement=%s\n" "$(subject_core_requirement "$SUBJ" 2>/dev/null || echo -)"; printf "drupal_root=%s\n" "${ROOT:--}"; printf "ddev_config=%s\n" "$([[ -n "$ROOT" && -f "$ROOT/.ddev/config.yaml" ]] && echo yes || echo no)"; printf "ddev_running=%s\n" "$(ddev_running "$ROOT" 2>/dev/null && echo yes || echo no)"; printf "state_dir=%s\n" "$(project_state_dir "$SUBJ")"' _ "$1"`

Then detect the effective PHP target and whether it is confirmed:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/detect-php.sh" --json`

## Step 3 — Read the cached assessment (if any)

Look in the `state_dir` reported above for a cached assessment so you do not recompute
it. Read `@<state_dir>/assess.json` and `@<state_dir>/viability-report.md` if present;
note the verdict, effort (S/M/L/XL), auto-fixable vs manual counts, and the timestamp.
Also note the last test result (`<state_dir>/last-test.json`) and the current phase
marker (`<state_dir>/phase`) if those files exist. If none exist, the project has not
been assessed yet.

## Step 4 — Summarize and recommend

Print a concise English summary:

- Subject: machine name, type (module/theme/profile), `core_version_requirement`.
- PHP target (and a clear note if it is **unconfirmed**, e.g. 8.5 — never claim it is
  supported).
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

## Step 5 — Run the full flow (only on request)

If the mode word in `$ARGUMENTS` is `full` (or the user explicitly asks to "do the
whole thing"):

1. State the plan in English: the ordered phases you will run
   (setup -> assess -> port -> [refactor if opted in] -> test -> [contribute if opted
   in]), which are gated, and that heavy work may run in the background.
2. Confirm with the user before starting.
3. Delegate the orchestration to the **drupal-port-orchestrator** subagent via the Task
   tool, passing the subject directory, the detected PHP target, the environment
   readiness, the cached assessment state, and whether the user opted into refactor
   and/or contribution. Let the orchestrator decide when to delegate to the other
   subagents and when to gate.

If the mode is `status`, just print the summary from Step 4 and stop (defer to
`/drupilot-status` for the canonical no-side-effects report). If the mode is `next`
(default), print the summary and the single recommended next step, and stop without
acting.
