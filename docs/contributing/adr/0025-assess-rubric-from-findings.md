# 0025 — The assessment rubric from findings

- **Status:** accepted
- **Date:** 2026-10-07
- **Decided by:** the 1.0 working session (R-AUTO-3), during M4 (T-M4-09)

## Context

07-R4 and AR-10 move the viability verdict out of the skill. `scripts/analysis/assess.sh --json` computes
the S/M/L/XL rubric from the findings counts and reports the threshold rule that matched; the skill only
narrates. The 0.9 skill defined the three counts in prose:
- `manual`: hard and unknown deprecations no Rector rule covers, plus the error findings of the signature
  scan;
- `hard_breaks`: the categories of four greps present;
- `blocking_deps`: dependencies with no Drupal 11 release and no viable alternative.

Three points needed a decision before they could be computed:
1. what "no Rector rule covers" means on `findings.json`;
2. how a "viable alternative" is decided without a model;
3. what the script owns: the extraction, the report and the stage record.

## Decision

**`manual`** is the number of `scope: current` findings that are:
- a PHPStan deprecation of class `hard` or `unknown` with no Rector finding at the same `(file, anchor)`. The
  Rector dry-run changes that function or method, so its rule covers the deprecation there. `soft` never
  counts, whatever `DRUPILOT_SOFT_DEPRECATIONS` says;
- or a catalog `signature` finding of severity `error`.

They are listed as `manual_items`, each with its finding id.

**`hard_breaks`** is the number of categories of `config/catalog/hard-breaks.json` with at least one matching
file. These are the 0.9 greps, moved into a catalog, with each fact verified in core. `\b` became the POSIX
`([^A-Za-z0-9_]|$)`, which gives the same matches.

**`blocking_deps`** is `deps-status.sh`'s `blockers`: the `drupal/*` dependencies drupal.org has no Drupal 11
release for. A script cannot decide whether an alternative is viable. The developer records that judgement in
the plan, and the verdict reports the dependencies as they are. Offline, every contrib dependency is
`unknown` and does not block: the report says so.

The table is the 0.9 one, first match wins:

| Verdict | Rule |
|---|---|
| XL | `blocking_deps >= 1` or `hard_breaks >= 3` or `manual > 40` |
| L | `hard_breaks == 2` or `manual > 15` |
| M | `hard_breaks == 1` or `manual >= 5` |
| S | otherwise |

The rule that matched is kept verbatim in `rubric.rule`. Next-major findings never count (X18).

**What `assess.sh` owns.** It runs the assess stage itself: `extract.sh`, `normalize-findings.sh`,
`classify.sh`, `core-strategy.sh` and `deps-status.sh`. With `--findings` and `--worklist` it reads given ones
instead, which is how the goldens run without Docker. It writes `assess.json` (schema 1, with `findings_hash`,
`worklist_hash` and `subject_digest`; its time goes in `meta`) and renders `viability-report.md` from
`templates/viability-report.md.tmpl`. It records the `assessed` stage with its effort; `--no-record` skips
that. The staged plan (`port-plan.md`) stays the skill's narrative, written from these fields.

## Consequences

- The same tree, lock and drupal.org answers give the same `assess.json` outside `meta` (07-R4).
- A deprecation is counted as covered only where Rector changes the same function. That is a closer reading
  of "no rule covers it" than 0.9's prose, which compared the dry-run by eye.
- The skill keeps no `grep`: `grep -c 'grep ' skills/viability-assessment/SKILL.md` is 0.
