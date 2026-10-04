# 0006 — Hooks keep `ask`: headless `claude -p` denies it in every permission mode

- **Status:** accepted
- **Date:** 2026-10-04
- **Decided by:** the 1.0 working session (R-AUTO-3), spike AR-44 (T-M8-00)

## Context

drupilot's PreToolUse guards return `permissionDecision: "ask"` and never
`deny` (X10, INV7, owner decision OD-04). Two guarantees rely on that `ask`:

- CC-03 and INV1: `guard-contrib.sh` asks before a push, MR or GitLab API
  call, and always when `DRUPILOT_AUTONOMOUS=true`, so an `auto` run never
  pushes;
- AR-12 and T-M8-05: the planned `guard-worklist.sh` asks before the
  residual fixer writes outside its item.

The headless contract (CC-29) runs `auto` as `claude -p "/drupilot … auto"`.
Nobody is there to answer a prompt. If Claude Code allowed an `ask` call in
some mode, `ask` would not stop anything there. If it waited, the run would
hang. M8 and T-M8-05 wait for this answer.

## Decision

Keep `ask` (OD-04 and INV7 unchanged). With Claude Code 2.1.289,
`claude -p` **denies** a hook's `ask` in every permission mode tested,
including `bypassPermissions` and `--dangerously-skip-permissions`.
It does not hang, and the exit code is 0.
The model gets the hook's `permissionDecisionReason`, word for word, as an
`is_error` tool result, and the call appears in a result event's
`permission_denials` (with a subagent, in an earlier result event than the
last one: a check must gather `permission_denials` over every result event). So `ask` stops the push and fences the residual fixer
in plain headless `auto`, and still lets a human answer in an interactive
session. No fallback is needed. In detail:

- `guard-contrib.sh` stays as it is. `guard-worklist.sh` returns `ask` as
  T-M8-05 plans. As planned, it prints nothing when the agent type is not
  the fixer or no live `active-item.json` exists.
- The reason text is the only thing the model sees after the denial. Write
  it for the model too: say what was blocked, that it must not retry, and
  what to do instead. For the fixer, that means putting the edit in
  `result.json`.
- An *approver* changes the result. An `ask` reaches whoever answers
  permission prompts: a person in an interactive session, or a host that
  runs `--permission-prompt-tool` (`stdio`, as the Agent SDK does, or an
  MCP tool). The approver's answer is final: if it allows, the push runs.
  If it never answers, the call waits until the stream closes. The headless
  contract therefore says: run `auto` as plain `claude -p`. Never put it
  behind a permission handler that approves everything, because that
  approves the push.
- The fallback below is declared but **not adopted**. It needs the owner,
  through an OD-04 amendment. It applies only if a later Claude Code build
  makes the live check below see `ask` allowed headless. In that case,
  `guard-contrib.sh` would return `deny` for the outward-facing case alone
  (push, MR, GitLab API), and only when `DRUPILOT_AUTONOMOUS` or
  `DRUPILOT_NONINTERACTIVE` is set. Every other case keeps `ask`.
  `guard-worklist.sh` would return `deny` only for a write outside the live
  item. That would break INV7 as worded and CC-03's "asks"; both would be
  amended in the same change.
- Hooks do not detect "headless" themselves. A `-p` hook sees
  `CLAUDE_CODE_SESSION_ATTENDED=0` and `CLAUDE_CODE_ENTRYPOINT=sdk-cli`.
  These variables are not documented, and an SDK host that answers
  prompts sees the same values. The hook input's `permission_mode` field
  is documented, but it is the same with or without a person there.

## Evidence

Claude Code 2.1.289 (`claude --version`; `claude_code_version` in every
run's init event), on Fedora (Linux), 2026-10-04. Model: `haiku`
(claude-haiku-4-5-20251001), plus `sonnet` (claude-sonnet-5-5) where noted.
The result did not depend on the model. Lab:
`$LAB/m2/ar44/` (scripts, settings files, raw stream-json in
`logs/runs/<id>.jsonl`, and the exact command of each run in `<id>.cmd`).

**Hooks** (fixed output, no logic):

- S1, guard-contrib shape: matcher `Bash`. It prints
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"drupilot is in AUTONOMOUS …"}}`,
  the same JSON `emit_decision` prints. The prompt makes the model run
  `touch $LAB/m2/ar44/work/s1-<id>`.
- S2, guard-worklist shape: matcher `Edit|Write|MultiEdit|NotebookEdit`,
  returning `ask`. The prompt makes the model `Write`
  `$LAB/m2/ar44/work/s2-<id>.txt`.
- S3: the S2 hook, but the `Write` is made by a subagent (`--agents`,
  `residual-fixer`, tools `Write, Read`). The hook input has
  `agent_type: "residual-fixer"`.
- Controls: the same matchers with no output (exit 0), or with `deny`.

**Settings file** (`--settings`, the `evals.sh` `live_settings` technique,
so the owner's installed plugin never runs):

```json
{"enabledPlugins": {"drupilot@drupilot": false},
 "hooks": {"PreToolUse": [{"matcher": "Bash",
   "hooks": [{"type": "command",
              "command": "$LAB/m2/ar44/hooks/ask-contrib.sh"}]}]}}
```

**Command** (cwd `$LAB/m2/ar44/work`; the parent session's `CLAUDECODE` and
`CLAUDE_CODE_*` variables, `DRUPILOT_CONTRIB_MODE` and `CLAUDE_PLUGIN_DATA`
unset):

```bash
timeout 300 claude -p "<prompt>" --model haiku --settings <file> <case flags> \
  --output-format stream-json --verbose --include-hook-events \
  --no-session-persistence </dev/null
```

**Cases:**

| case | flags | init `permissionMode` |
|---|---|---|
| C1 | none | `default` |
| C2a | `--permission-mode bypassPermissions` | `bypassPermissions` |
| C2b | `--dangerously-skip-permissions` | `bypassPermissions` |
| C3 | `--allowedTools "Bash,Write,Edit,Read"` | `default` |
| C4 | `--permission-mode acceptEdits --allowedTools "Bash,Read,Edit,Write"` | `acceptEdits` |
| C6 | `--permission-mode auto` | `default` on haiku, `auto` on sonnet |
| C7 | `--permission-mode dontAsk --allowedTools "Bash,Write,Edit,Read"` | `dontAsk` |
| C8 | C3 + `--permission-prompts none` | `default` |
| C9 | C2a + `--permission-prompts none` | `bypassPermissions` |
| C10 | `--allowedTools "Bash(touch *)"` (S1 only) | `default` |

C5: `--permission-prompt-tool` is not listed in `--help`, but the CLI
accepts it. It is used in E1. `--permission-prompts host|none` is new
(default `host`).

**Matrix** (runs; "denied" means the side effect is absent, the call is
listed in `permission_denials` and the exit code is 0):

| shape | hook | C1 | C2a | C2b | C3 | C4 | C6 | C7 | C8 | C9 | C10 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| S1 | ask | denied 2/2 | denied 3/3¹ | denied 2/2 | denied 2/2 | denied 2/2 | denied 4/4¹ | denied 2/2 | denied² 2/2 | denied² 2/2 | denied 2/2 |
| S2 | ask | denied 2/2 | denied 2/2 | denied 2/2 | denied 2/2 | denied 3/3¹ | denied 4/4¹ | denied 2/2 | denied² 2/2 | denied² 2/2 | — |
| S3 | ask | denied 2/2 | denied 2/2 | — | denied 2/2 | denied 2/2 | — | — | — | — | — |
| S1 | none | denied³ 2/2 | ran 1/1 | ran 1/1 | ran 2/2 | ran 1/1 | ran on sonnet⁴ | ran 1/1 | ran 1/1 | ran 1/1 | ran 1/1 |
| S2 | none | denied³ 2/2 | ran 1/1 | ran 1/1 | ran 2/2 | ran 1/1 | ran on sonnet⁴ | ran 1/1 | ran 1/1 | ran 1/1 | — |
| S3 | none | — | — | — | — | ran 1/1 | — | — | — | — | — |
| S1, S2 | deny | denied⁵ 2/2 | — | — | denied⁵ 2/2 | — | — | — | — | — | — |

¹ includes sonnet runs. ² The model sees "Permission for this tool use
was denied. It requires approval, and this session has no approval surface
… do not retry it … What required approval: <reason>". ³ The normal
`default`-mode refusal ("… needs approval", "… you haven't granted it yet").
⁴ Haiku stays in `default`, so the normal refusal applies. ⁵ The model
sees "PreToolUse:<Tool> hook error: <reason>".

In plain `-p`, the `ask` runs took 5–13 s. None hung, every exit code was 0,
and `result.subtype` was `success`. Each S1/S2 run made exactly one tool
call: the model reported the reason and did not retry. Each S3 (subagent)
run made two, the `Agent` call and the subagent's denied `Write`; in 5 of
the 8 runs the denial sits in an earlier result event and the last one
shows an empty `permission_denials`. The T-M8-05 live check covers S3 too.

**Extras:**

| id | what | result |
|---|---|---|
| E1 | `--input-format stream-json`, no prompt tool | `ask` denied, as in `-p` |
| E1 | stream-json + `--permission-prompt-tool stdio`, host never answers | the CLI emits `control_request` `can_use_tool` with `decision_reason` = the hook reason, then **blocks**. After 90 s, stdin is closed and the call is denied ("Tool permission stream closed before response received") |
| E1 | same, host answers `allow` (also with `bypassPermissions`, also `Write`) | **the tool ran** (marker created) |
| E1 | same, host answers `deny` | denied with the host's message |
| E1 | `deny` hook + host that would allow | no `control_request`; denied |
| E3 | S1 C2a with the parent Claude Code session's environment inherited | denied. The hook still sees `CLAUDE_CODE_SESSION_ATTENDED=0` and `CLAUDE_CODE_ENTRYPOINT=sdk-cli`, and so does every E1 host run |
| E4 | the **real** `hooks/scripts/guard-contrib.sh` (repo, read-only) on a real `git push` to a local bare remote, `DRUPILOT_AUTONOMOUS=true`, `DRUPILOT_CONTRIB_MODE=auto` | hook `ask`. C1, C2a ×2, C2b, C3, C4 ×2: no ref pushed |
| E4 | same, not autonomous, `DRUPILOT_CONTRIB_MODE=auto` | hook `allow`. C1, C3: ref pushed (the hook's `allow` also skips the `default`-mode prompt) |
| E5 | the S1 `ask` hook from a plugin (`--plugin-dir`) instead of `--settings`, C2a and C4 | denied, as via `--settings` |

**Source read:** code.claude.com/docs/en/hooks, "PreToolUse decision
control". `permissionDecision` is `allow`, `deny`, `ask` or `defer`, and
`permissionDecisionReason` is required for `deny` and `ask`. The page does
not say how `ask` behaves under `-p`, so the matrix above is the evidence.
`defer` (postpone until `/approve` or a permitting mode) was not tested.

## Consequences

- **INV7, OD-04, X10, CC-03:** no change. "Hooks ask, never deny" holds, and
  INV1 is enforced by `ask` in plain headless runs. The owner is not needed
  unless the fallback above is ever triggered.
- **T-M8-05:** `guard-worklist.sh` returns `ask`, as planned. Its reason
  text is addressed to the fixer. Its hook contract tests stay as listed.
- **T-M8-05 also gets a live check.** Add an opt-in `evals.sh --live` case
  (never in CI), "headless ask is denied". It runs S1 and S2 under C2a and
  C4 and asserts that the marker is absent and the call is in
  `permission_denials`. Re-run it whenever the Claude Code version changes,
  and before each release. If it fails, use the declared fallback and ask
  the owner to amend OD-04.
- **CC-29 docs** (the headless page, when written) record the result:
  - `auto` runs as plain `claude -p`;
  - a blocked push is reported as a denial, and the run continues;
  - under an SDK host or a `--permission-prompt-tool`, the host answers
    drupilot's `ask` and must not approve everything;
  - a silent host blocks the run.
- **Interactive `/drupilot … auto`:** the same `ask` stops and waits for the
  person. This is intended: a person must confirm.
- **Recheck** on every Claude Code minor upgrade, using the live check above.
  The scripts and settings files in `$LAB/m2/ar44/` rerun the whole matrix in
  about 3 minutes with haiku.
