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

**`manual`** counts, among the `scope: current` findings:
- each PHPStan occurrence of a deprecation of class `hard` or `unknown` that no Drupal Rector rule changes in
  the same function or method. normalize-findings.sh merges the calls of one symbol in one function into a
  finding with one source per call, and 0.9 counted each call, so the occurrences are counted. A Drupal
  Rector rule is a `DrupalRector\` rule, or one of the `Renaming`, `Transform`, `Arguments` and `Removing`
  rules drupal-rector configures for Drupal deprecations. A PHP-level rule (the PHP sets, the compat pass)
  covers nothing. A file-level anchor (`{file}`) covers nothing either, and neither does any anchor when the
  anchors were unavailable: those name no function. `soft` never counts, whatever
  `DRUPILOT_SOFT_DEPRECATIONS` says;
- each catalog `signature` or `port-safety` finding of severity `error`. These are 0.9's "mechanical edits
  Rector cannot make", now from deterministic checks. PHPStan's other errors (class `analysis`) are not
  counted: at the configured level most of them are not porting work. They are worklist items.

They are listed as `manual_items`, each with its finding id and its occurrences.

**The digests layer is not part of the assessment.** 0.9 counted a deprecation a digests rule covers as
automatic. The assess stage runs no digests pass (its rules are reviewed per port, ADR 0026 and 05-R6), so
such a deprecation counts as manual. The verdict can only be higher for it.

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

**No verdict from a tool.** When Rector, PHPStan, the port-safety checks or the signature scan gave no
verdict (`findings.json` `tools`: `failed` or `missing`), the counts are incomplete. The result then goes to
`assess-provisional.json`, with `provisional: true` and `no_verdict` naming the tools, and the report says
so. It is never written to `assess.json`, which the router and the state snapshot take as an assessment.
The `assessed` stage is not recorded, and the script exits 3.

**Coverage, precisely.** A deprecation counts as covered when a rule of drupal-rector's Drupal sets changes
the same function: a `DrupalRector\` rule, or one of the generic rules those sets configure or import:
`Renaming`, `Transform`, `Arguments`, `Removing`, and the `Symfony`, `PHPUnit` and `Twig` sets. Rector's PHP
sets also use a few generic rules. One of those, at the same anchor, would count as coverage, an
over-match the rubric accepts.

**What `assess.sh` owns.** It runs the assess stage itself: `extract.sh`, `normalize-findings.sh`,
`classify.sh`, `core-strategy.sh` and `deps-status.sh`. It needs the test-bed's Drupal root, like
`extract.sh`, and reads its settings from that root wherever it is run from. With `--findings` and `--worklist` it reads given ones
instead, which is how the goldens run without Docker. It writes `assess.json` (schema 1, with `findings_hash`,
`worklist_hash` and `subject_digest`; its time goes in `meta`) and renders `viability-report.md` from
`templates/viability-report.md.tmpl`. It records the `assessed` stage with its effort; `--no-record` skips
that. The staged plan (`port-plan.md`) stays the skill's narrative, written from these fields.

## Consequences

- The same tree, lock and drupal.org answers give the same `assess.json` outside `meta` (07-R4).
- A deprecation is counted as covered only where Rector changes the same function. That is a closer reading
  of "no rule covers it" than 0.9's prose, which compared the dry-run by eye.
- The skill keeps no `grep`: `grep -c 'grep ' skills/viability-assessment/SKILL.md` is 0.
- On `legacy_widgets`, `manual` is 3, as in the 0.9 sample, with one different item. 0.9's third item was a
  PHPStan class-declaration error; it is now the port-safety class-case error.
