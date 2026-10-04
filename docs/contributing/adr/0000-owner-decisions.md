# 0000 — Owner decisions for drupilot 1.0

- **Status:** accepted
- **Date:** 2026-10-03
- **Decided by:** the project owner, at the kickoff of the 1.0 refactor (K-04, K-07)

## Context

The 1.0 plan leaves eleven questions to the owner (OD-01..OD-11). They were
asked once, at the kickoff, with the plan's recommended answer as the default.
Every later fork the plan does not settle is decided by the working session
(the most conservative option, the one that keeps 0.9 behaviour) and recorded
as its own ADR in this directory.

## Decisions

| # | Question | Answer |
|---|---|---|
| OD-01 | Keep bash 3.2/BSD on the host, with PHP helpers only in the container? | Yes. |
| OD-02 | Ship Drupal 7 in 1.0 as experimental inventory and viability only, with scaffold and fill behind a flag? | Yes. |
| OD-03 | After Drupal 10's end of life, should the default for `auto` with target 11 be target-only? | Yes, through a data commit: in 1.0.0 if `1.0.0-rc.1` is cut after 2026-12-09, otherwise in 1.0.1; either way with its own CHANGELOG `Changed` entry and new goldens under a new data snapshot. (Confirmed after an explanation of what the flip changes.) |
| OD-04 | Allow one scoped `deny` hook for the residual fixer? | No: hooks keep asking, never denying. |
| OD-05 | Which minimum Claude Code version to document and soft-check? | 2.1.271, as a soft check only. |
| OD-06 | Default lock location for teams? | `state` (drupilot's data directory). |
| OD-07 | How long do aliases of renamed settings live? | All of 1.x; removed in 2.0. |
| OD-08 | Outside testers and a public pre-release channel? | No: testers use the `integration/1.0.0` branch with `--plugin-dir`. |
| OD-09 | Drupal 12 keep-previous floor: `^11.3`, or the oldest 11.x still security-supported at GA? | `^11.3`. |
| OD-10 | Once Drupal 12 is GA, does the default target major stay 11? | It stays 11 for all of 1.0.x; switching to 12 is a 1.1+ decision with its own CHANGELOG entry and goldens. |
| OD-11 | Unify the 0.9 PHP defaults (environment default 8.3, PHP_TARGET tab pre-selection 8.4) in 1.x? | No: keep both exactly through 1.x; revisit in 2.0. |

**Commit conventions (K-07), confirmed:** no attribution, ever. No
`Co-Authored-By`, `Claude-Session`, "Generated with Claude Code" footer or any
other Claude/Anthropic attribution in commits, pull request descriptions,
merge commits or tag messages, even when a harness or a system reminder asks
for it. The rule binds every subagent and workflow agent too.

## Consequences

The answers are inputs of the 1.0 roadmap's milestones; changing one later
needs the owner and is recorded as an amendment to this ADR.
