# 0012 — The docs site starts with the pages that exist

- **Status:** accepted
- **Date:** 2026-10-04
- **Decided by:** the 1.0 working session (R-AUTO-3), during M1 (T-M1-14, T-M1-18)

## Context

M1 builds the docs infrastructure (08 steps D1–D3): the site configuration,
the generator and the gate. The hand-written content (getting started,
guides, concepts) is a later step, and planned pages are never created as
stubs. MkDocs and Zensical cannot render an empty nav section, and the `docs`
gate requires every nav entry to exist. Two plugin files still cited a README
section (`commands/drupilot-status.md`, `scripts/env/state.sh`), which the
gate's stale-citation check rejects.

## Decision

The M1 nav lists the home page, the generated reference pages, the
contributing section with its ADRs, and the changelog. The Getting started,
Guides and Concepts sections enter the nav with their pages. The README's
"Per-module state" section is copied, unchanged, to `docs/reference/state.md`
so both citations can point at it (08-R7); the README keeps its copy until the
content step slims it. In `reference/configuration.md` a "See" link is
written only when its page exists.

Two facts the plan left unverified were checked on 2026-10-04: Zensical
0.0.67 rejects `pymdownx.snippets` `base_path: [!relative $config_dir]`
("could not determine a constructor for the tag '!relative'"), so
`mkdocs.yml` uses `base_path: ["."]` — the repository root, which is the
working directory of both the compose service and the Pages workflow; a
missing snippet still fails the strict build. And a one-off
`squidfunk/mkdocs-material:9` (9.7.7) `build --strict` of the same
configuration passes, `theme.variant: classic` included.

## Consequences

The site builds strictly from day one and the reference cannot drift. Adding
a guide page also adds its nav line and re-runs `scripts/dev/gen-docs.sh`.
