# 0008 — Live router evals deny every tool through a hook

- **Status:** accepted
- **Date:** 2026-10-04
- **Decided by:** the 1.0 working session (R-AUTO-3), during M1 (T-M1-17)

## Context

The live layer of the router evals (`scripts/dev/evals.sh --live`) runs the
real commands through `claude -p --plugin-dir` and asks the model to report
the mode or the tabs instead of acting. The plan suggests PATH-stubbed
scripts. Measured with Claude Code 2.1.289:

- `--disallowedTools Bash` makes Claude Code refuse a command's load-time
  `!` lines, so the run ends with no model turn at all;
- a plugin loaded with `--plugin-dir` is namespaced (`/drupilot:<command>`),
  and an installed `drupilot@…` plugin is loaded next to it;
- the commands' `allowed-tools` grant `Bash` without restriction, so a
  misbehaving run could execute anything a PATH stub does not cover.

## Decision

A live run invokes `/drupilot:<command>` with a `--settings` file whose
`PreToolUse` hook denies every tool call (checked: the model's `Bash` and
`Write` attempts were denied and their marker files never appeared), which
also disables every installed `drupilot@*` plugin for that run only. The
load-time lines still run (they are read-only), with `DRUPILOT_HOME` and
`XDG_DATA_HOME` in a temp directory.

## Consequences

No tool call of the model can run, whatever a prompt says; no PATH stub list
to keep complete. The developer's installed plugin is never modified. Results
(10 runs per case): v0.9.0 110/110, the M1 branch 110/110.

`/drupilot-status` cannot run under `claude -p` at all: Claude Code refuses
its core-matrix load-time line (the inline `jq` program in a `bash -c`
string) as a "shell -c script that runs rm" it cannot check, even with
`bypassPermissions`, and asks for approval interactively. No eval case uses
it; the line is a candidate for the 0.9.x hotfix list.
