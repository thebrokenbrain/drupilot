# 0011 — release.sh validates the plugin without `--strict`

- **Status:** accepted
- **Date:** 2026-10-04
- **Decided by:** the 1.0 working session (R-AUTO-3), during M1 (T-M1-11)

## Context

09-R4 has `release.sh` run `claude plugin validate . --strict`. With Claude
Code 2.1.289 that always fails on one warning: "CLAUDE.md at the plugin root
is not loaded as project context". drupilot's plugin root is the repository
root, and `CLAUDE.md` is the repository's developer guide, so the warning is
permanent; CI already runs `validate` without `--strict` for that reason.

## Decision

`release.sh` runs `claude plugin validate .` and fails on any warning other
than that one. It never runs `claude plugin tag` and never pushes.

## Consequences

Same strength as `--strict` for every other warning. If Claude Code drops
the warning, or the developer guide moves, `--strict` can replace the filter.
