---
description: drupilot router and main entry point for porting. Detects the current state of a Drupal module/theme port (environment, cached assessment, phase). When the user asks to PORT/upgrade/modernize a module ('port this module to Drupal 11', 'upgrade this to D11', 'make it work on Drupal 11'), it RUNS the full setup->assess->port->[refactor]->test flow via the drupal-port-orchestrator — guided with confirmations, or hands-off with the `auto` mode word / DRUPILOT_AUTONOMOUS=true (which writes the local patch and never performs outward-facing contribution). For an exploratory ask or a bare '/drupilot' ('what's next', 'where am I', 'status'), it instead summarizes and recommends the single next step. Use it whenever the user wants to port a module/theme to Drupal 11 or asks what to do next.
argument-hint: "[subject-path | --subject DIR] [full|auto|status|next] [--no-confirm] [--workspace DIR] [--json]"
allowed-tools: Bash, Read, Task, AskUserQuestion
---

# drupilot — router and guided flow

You are the entry point for the drupilot plugin. Your job is to **detect the current
state**, **summarize it in English**, and then either **run the porting flow** (when
the user asked you to port/upgrade the module) or **recommend the next logical step**
(for an exploratory ask). Infer which from the request — see Hard rules.

## Hard rules

- **English only** in everything you print.
- **Never act before stating what you will do.** Always show a short plan first, then
  proceed. For anything that mutates the system, environment, or a remote, confirm
  intent explicitly.
- Treat the scripts as the source of truth for detection — do not guess versions or
  state from memory.
- `$ARGUMENTS` may carry a subject path (a module/theme directory) and/or an explicit
  mode word: `full`, `auto`, `status`, or `next`. `DRUPILOT_AUTONOMOUS=true` is
  equivalent to the `auto` mode word.
- **Flag words for wrappers (non-interactive contract).** After the subject,
  `$ARGUMENTS` may also carry these flags, in any order. They are sugar over the
  canonical environment variables (which work without them), and the subject
  stays the first positional word:
  - `--subject DIR` — the subject, as a flag: the same as giving `DIR` as the
    first positional word (`/drupilot --subject ~/mod --no-confirm`). Put it
    first so the load-time probes below see it.
  - `--no-confirm` — the run asks nothing: effective mode **`auto`** (unless an
    explicit `status`/`next` word is given), no AskUserQuestion tab, every fork
    resolved with its recommended default. Prefix **every** script you run with
    `DRUPILOT_NONINTERACTIVE=1` (the scripts' own prompts then take their safe
    default) and pass `autonomous=true` to the orchestrator. It is exactly as
    safe as `auto`: never outward-facing (no push, no MR, no contribute). The
    PreToolUse backstop enforces it: `guard-contrib.sh` asks before a push or
    MR command whenever `DRUPILOT_NONINTERACTIVE=1` is in its environment or
    prefixes the command, exactly as for `DRUPILOT_AUTONOMOUS=true`.
  - `--workspace DIR` — the test-bed root for a loose subject. Pass
    `--workspace DIR` to `resolve-workspace.sh`, `ddev-up.sh` and
    `place-subject.sh` (or prefix any script with `DRUPILOT_WORKSPACE_DIR=DIR`),
    and hand it to the orchestrator so every stage uses it.
  - `--json` — the machine contract: whatever mode runs, your **final message is
    exactly** the output of
    `bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/port-summary.sh" --subject <subject_dir> --json`
    (one JSON object, schema in that script's header), with no prose before or
    after it. Progress and explanations go only into intermediate messages.
  Never take a flag word for the subject path or a mode word. An unknown `--flag`
  is reported in one line and ignored.
- **Mode inference (when no explicit mode word is given) — infer from intent:**
  - An **action / port** request ("port this to Drupal 11", "upgrade this module",
    "make it D11", "do the port", "modernize it") → **run the flow**: effective mode
    **`full`** — or **`auto`** if the user also asked for it unattended ("don't stop",
    "do everything yourself", "automatic") or `DRUPILOT_AUTONOMOUS=true`.
  - An **exploratory** request or a bare `/drupilot` ("what's next", "where am I") →
    **`next`** (summarize + recommend one step; do not act).
  - A **status** request ("status", "how's it going") → **`status`** (read-only).
  - A **set of modules** — the subject is a directory holding several extensions
    (`web/modules/custom`, a folder of modules; `next-step.sh` then returns
    `next: "layers"`), or the request is "port all these modules" → do **not**
    run the single-subject flow on it: recommend
    **`/drupilot-layers <dir> plan`** (the porting order, cycles and undeclared
    dependencies), whose `run` then ports each layer through the normal flow.
  - **Cleanup** is off the ladder: when the subject is ported and tested (or the
    developer asks about disk space or old test-beds), mention
    **`/drupilot-clean`** in one line (it is user-invoked only, never run it).
  An explicit mode word always overrides inference. If intent is genuinely ambiguous,
  present a tab with **AskUserQuestion** (header "How to proceed", default "Just the
  next step"): **Run the full port** (guided, with confirmations) · **Just recommend
  the next step** (read-only) · **Hands-off auto** (unattended, never outward-facing).
  Before showing that tab, check for a pre-answer:
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/choice.sh" --key INTENT --subject "<subject_dir>" --json`.
  When its `value` is not null (`full`, `next` or `auto`), use it as the answer
  without the tab and say so in one line (`DRUPILOT_CHOICE_INTENT=<value>`); when
  it is null, ask (an invalid value was already reported as a warning). It only
  answers this ambiguous-intent tab: an explicit mode word or a clear request wins.
  Do **not** silently fall back to `next` when the user clearly asked you to port.

## Step 1 — Detect the environment (gates, no side effects)

Run the preflight engine in report mode and parse the JSON. This never mutates
anything:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile all --json`

From that object read `php_target` and `ready.{analyze,setup,test,contribute}`.

## Step 2 — Detect the subject and the Drupal/DDEV state

Resolve the subject directory: use `$1` (or the `DIR` of a leading
`--subject DIR`) if it points at a Drupal extension, otherwise detect it from the
current directory. Then collect facts via common.sh helpers and the
detect-php script (all read-only):

!`bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; SUBJ="${1:-}"; case "$SUBJ" in --subject) SUBJ="${2:-}";; --subject=*) SUBJ="${SUBJ#--subject=}";; esac; [[ -n "$SUBJ" && -d "$SUBJ" ]] || SUBJ="$PWD"; ROOT="$(find_drupal_root "$SUBJ" 2>/dev/null || true)"; printf "subject_dir=%s\n" "$SUBJ"; printf "is_extension=%s\n" "$(is_drupal_extension_dir "$SUBJ" && echo yes || echo no)"; printf "machine_name=%s\n" "$(subject_machine_name "$SUBJ" 2>/dev/null || echo -)"; printf "subject_type=%s\n" "$(subject_type "$SUBJ" 2>/dev/null || echo -)"; printf "core_requirement=%s\n" "$(subject_core_requirement "$SUBJ" 2>/dev/null || echo -)"; printf "drupal_root=%s\n" "${ROOT:--}"; printf "ddev_config=%s\n" "$([[ -n "$ROOT" && -f "$ROOT/.ddev/config.yaml" ]] && echo yes || echo no)"; printf "ddev_running=%s\n" "$(ddev_running "$ROOT" 2>/dev/null && echo yes || echo no)"; printf "state_dir=%s\n" "$(project_state_path "$SUBJ")"; printf "artifacts_dir=%s\n" "$(project_artifacts_path "$SUBJ")"; printf "lockfile=%s\n" "$(LF="$(project_state_path "${ROOT:-$SUBJ}")/drupilot-lock.json"; [[ -f "$LF" ]] && echo "$LF" || echo -)"' _ "$1" "$2"`

Then detect the effective PHP target and whether it is confirmed:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/detect-php.sh" --json`

Also read the autonomous flag and the contribution mode (so the summary and the
flow honor them):

!`bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; printf "autonomous=%s\n" "$(config_get DRUPILOT_AUTONOMOUS false)"; printf "contrib_mode=%s\n" "$(config_get DRUPILOT_CONTRIB_MODE semi)"; printf "generate_rules=%s\n" "$(config_get DRUPILOT_GENERATE_RULES ask)"; printf "deterministic=%s\n" "$(config_get DRUPILOT_DETERMINISTIC true)"; printf "viability_threshold=%s\n" "$(config_get DRUPILOT_VIABILITY_THRESHOLD medium)"'`

## Step 3 — Read the cached assessment (if any)

Look in the `state_dir` reported above for a cached assessment so you do not recompute
it. Read `@<state_dir>/assess.json` (machine cache) and the human-readable
`@<artifacts_dir>/viability-report.md` (in the visible `.drupilot/` folder) if present;
note the verdict, effort (S/M/L/XL), auto-fixable vs manual counts, and the timestamp.
Also note the last test result (`<state_dir>/last-test.json`) and the current stage
(`stage` in `<state_dir>/state.json`, or the legacy `<state_dir>/phase` marker) if
those files exist — `state.sh show --subject <DIR>` prints that per-module record
merged with the current verdicts, and `/drupilot-status --all` tabulates every
module/workspace drupilot has state for. If none exist, the project has not
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

Then recommend exactly one **next step** as a concrete slash command. Do **not**
restate the ladder here — use the single source of truth. It runs at load (before
you can substitute anything), so it reads the readiness booleans from preflight
itself (`--from-preflight`, one ~0.5 s run):

!`bash -c 'S="${1:-}"; case "$S" in --subject) S="${2:-}";; --subject=*) S="${S#--subject=}";; -*) S="";; esac; exec bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/next-step.sh" --subject "${S:-$PWD}" --from-preflight' _ "$1" "$2"`

Relay its `command` + `reason`. The ladder it encodes is
`doctor → setup → assess → port → [refactor] → test → [contribute]`; `refactor`
(Phase 2) and `contribute` are **opt-in** and only suggested, not forced.

**Patch is always available (G6).** Whatever the recommended step, add a one-line
aside that once the subject is ported the developer can get a `.patch` any time
with **`/drupilot-patch`** — to test on another checkout or attach to a Drupal.org
issue comment — **independently of contributing** the Merge Request later.

## Step 5 — Run the flow (`full`) or hands-off (`auto`)

Resolve the effective mode in order: (1) an explicit `$ARGUMENTS` mode word wins;
(2) else if `--no-confirm` is in `$ARGUMENTS` or `autonomous=true` (from Step 2) →
`auto`; (3) else infer from the user's
intent per the Hard rules — a port/upgrade request → `full` (or `auto` if they asked
for unattended), an exploratory ask → `next`, a status ask → `status`. So "port this
module to Drupal 11" runs the flow (`full`); it does not stop at recommending the next
step.

Before delegating a `full` or `auto` flow (never in `status`/`next`, which write
nothing), rerun the router's gate and, when it passes, the one-time copy of any
state drupilot 0.9.0 left in Claude Code's per-plugin data dir (copy-only):

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile all --quiet && bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; copy_legacy_state_once'
```

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

Honor `DRUPILOT_VIABILITY_THRESHOLD` (the resolved `viability_threshold` above): if the assessment exceeds it, the
orchestrator still ports (it never refuses) but says so plainly in the final
summary.

### Wrapper output (`--json`)

When `$ARGUMENTS` carries `--json`, end every mode (`full`, `auto`, `status`,
`next`) by running `port-summary.sh --subject <subject_dir> --json` and replying
with its STDOUT verbatim as the whole final message. Wrappers rely on it to read
`status` (`not-started` … `contributed`, or `blocked` with `blockers`),
`effort`, `files_changed`, `rector_rules`, `reverted_rules`, `manual_fixes`,
`preservation`, `matrix` and `patch` without parsing Markdown.

### `status` / `next`

If the mode is `status`, just print the summary from Step 4 and stop (defer to
`/drupilot-status` for the canonical no-side-effects report). If the mode is `next`
(default when autonomous is off), print the summary and the single recommended
next step, and stop without acting.
