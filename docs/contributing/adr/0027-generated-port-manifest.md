# 0027 — The generated port manifest

- **Status:** accepted
- **Date:** 2026-10-06
- **Decided by:** the 1.0 working session (R-AUTO-3), during M4 (T-M4-10)
- **Amended:** 2026-10-28, for 1.0.2 (see "Amendments" at the end)

## Context

AR-10 and 01-R9 make `port-manifest.json` script-generated. It is built from `findings.json`,
`worklist.json`, `decisions.jsonl`, Rector's `applied_rectors` and the git diff. The model may fill only
the rationale, keyed by item id. In 0.9 the model wrote the whole manifest at the end of a port, pasting
the JSON of about ten scripts into it and filling about ten free-text lists. Three points needed a decision:
1. which 0.9 fields the script can rebuild, and from what;
2. where the 0.9 free-text fields go;
3. how the rationale is kept across runs.

## Decision

**`scripts/ai/manifest.sh --subject DIR [--phase port|refactor] [--rationale FILE]`** writes
`port-manifest.json`, schema 1. Each field comes from a record a script keeps:

| Field | From |
|---|---|
| `worklist` (`by_lane_status`, items) | `worklist.json` |
| `codemods` | `actions.jsonl`: the applications still in effect |
| `rector_official_files`, `rector_rules` | `rector-rules.json`, which `run-rector.sh --apply` keeps. It now also lists the files, and the files of the official and compat passes apart from the digests pass (`official_files`, `digests_files`): `rector_official_files` counts the former (training run 03 reported a digests change as the official pass's). The digests rules applied and rejected follow each rule's latest verdict in `digests-decisions.json`. The attribute pass keeps `attributes-rules.json` (`convert-attributes.sh --apply`): its rules join `rector_rules`. |
| `digests` | the applying run's digests rules, and the verdicts rejected for its SHA |
| `files_changed`, `files`, `manual_edits` | `git diff` against `git_port_base_ref`, the base `make-patch.sh --local` uses. A manual edit is a file that neither Rector, the attribute pass nor a codemod changed. |
| `deprecations_remaining`, `deferred_to_phase2` | `findings.json`, the current hard and unknown PHPStan occurrences and the next-major symbols |
| `port_safety`, `signature_changes`, `metadata_lint` | the stage's raw reports, the scripts' own `--json` |
| `soft_deprecations` | `classify-deprecations.sh --json` on the stage's raw PHPStan report |
| `core_version_requirement`, `require_php`, `version_bump`, `d10_support` | `info.yml`, `composer.json`, `assess.json` (the bump it recommended for that requirement; since 1.0.1, only for a port: any other final requirement, or a refactor, gets `core_version_bump` from the requirement before the port, read from `assess.json`, `assess-provisional.json` or the `info.yml` at the port's base; a port whose earlier requirement is unknown gets null, a refactor is always a major), `core-matrix.json` when fresh |
| `decisions` | the decision log, as a count per kind |

**The free-text fields leave the manifest.**
- Rector reversions, post-port fixes, behavior changes, pre-existing bugs, tooling deviations and test
  adaptations are entries of `log-decision.sh`, logged as they happen. `port-report.sh` already merges them
  (`port_record_json`).
- `verification` comes from the state files the scripts write: `core-matrix.json`, `phpcs-ruleset.json`,
  `hooks-substitution.json` and `negative-controls.json`.
- The learned patterns stay in the project's catalog (`patterns.sh`).
- The free-text `validation` list is dropped. The preservation and verification sections show the evidence.

**The rationale** is `{"<worklist item id>": "why"}`. An id the worklist does not have is refused (exit
1). A later run keeps the earlier rationale for the ids still in the worklist, so regenerating the manifest
never loses it.

**Determinism.** The same records and tree give the same manifest outside `meta`. `inputs` names the
`findings_hash`, the `worklist_hash`, the actions log's hash and the git base commit it was built from.
Readers of a 0.9 manifest are unchanged: every field stays optional, and `meta.generated_at` is read after
`generated_at` and `recorded_at`.

## Consequences

- `/drupilot-port` and `/drupilot-refactor` run `manifest.sh` and render the report. The model writes only
  `rationale.json`.
- `port-report.sh` renders the lane × status table, the codemods applied and the rationale per item.
- A manifest golden (`tests/golden/manifest/`) pins the generator on the lab's `legacy_widgets` port.

## Amendments

1.0.2 (2026-10-28, lab L-PC): the rationale could not explain a manual edit. The model writes it against the
worklist it saw, the extraction after its fix drops the item it fixed, and `manifest.sh` refused the id
(exit 1): the pipeline's report stage failed, ran again without a rationale, and `manual_edits[].why` stayed
null, since no input reached it.

- **Resolved items.** `classify.sh` keeps, each time it writes the worklist, the items the new one no longer
  has in `worklist-resolved.json` (`worklist_resolved_update`). A rationale may name them; the manifest
  lists the ones it names, with their why, under `worklist.resolved`, and `port-report.sh` renders them
  as resolved by the port.
- **Manual edits.** A key may also be the path of a file the port changed, relative to the module: its
  text is that manual edit's `why`, and the why of a file Rector, the attribute pass or a codemod changed
  too is shown under "Also explained". With no git history there is no diff, so any file of the module
  may be named.
- **No silent stale why.** The manifest records the hash each named file had when its why was given
  (`rationale_hashes`) and lists the files changed since (`rationale_stale`); the report shows their why as
  given before the change, so the test stage's later edits never erase the port's explanations. An item
  the previous manifest listed as resolved loses its why when it is open again (a revert). A port starts
  `worklist-resolved.json` afresh: the assess stage's worklist empties it, and the upgrade stage's keeps
  only what it drops, so an earlier port's items never name this one's.
- Any other key is still refused (exit 1).
