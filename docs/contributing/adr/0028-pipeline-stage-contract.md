# 0028 — The pipeline's stage contract

- **Status:** accepted
- **Date:** 2026-10-12
- **Decided by:** the 1.0 working session (R-AUTO-3), during M4 (T-M4-12)

## Context

AR-07 sets the contract every stage follows: a digest of the plan, the lock and the subject; a stage whose
input digest matches a `done` record is skipped on resume; raw reports named `raw/<NN>-<stage>-<tool>.json`; a
failing stage restores the tree to its own checkpoint, a ref `refs/drupilot/stages/<run>/<stage>` made with a
throwaway `GIT_INDEX_FILE`. T-M4-12 implements it in `scripts/ai/pipeline.sh` for the standard track's
deterministic stages. Three points needed a decision:
1. what "skipped on resume" compares;
2. what a checkpoint covers and what a restore removes;
3. what each M4 stage runs.

## Decision

**Up to date means the stage's output is the current state.** A stage is not run again when its last record is
`done` (or `skipped`) and its recorded **output** digest equals the digest now. AR-19's `reconcile` compares
the same thing: the stored output digests against the current subject digest. Comparing the *input* digest
alone would skip a stage whose effect was rolled back (a tree reset to before `upgrade` has `upgrade`'s input
digest) and leave the module unported. For a stage that changes nothing, input and output are equal, so both
readings agree. `--force` runs every stage.

**A checkpoint covers the subject's directory.** It records the tracked and untracked files under the
subject, not the ignored ones, as a commit object at the ref. Its parent is HEAD, and its identity is
drupilot's own. It is never on a branch, and the real index and HEAD are untouched. A restore writes every
file of the checkpoint back and removes the files under the subject that are not in it. Ignored files and
everything outside the subject are left alone. The pipeline needs a git repository: without one it exits 1
with the remedy, and `/drupilot-port` falls back to the 0.9 calls.

**The M4 stages.**
- `upgrade`: the official Rector pass (`run-rector.sh --apply`), the extraction at stage `upgrade`, and the
  codemods (`apply-recipes.sh --reextract`). It is skipped with reason `same-major` when the plan has no hop.
  The digests layer, which the developer reviews, stays in `/drupilot-port`.
- `php`: a placeholder until M5, recorded as `skipped` with reason `placeholder`.
- `validate`: the fixpoint gate (`fixpoint.sh`). Its exit 3 under `DRUPILOT_FIXPOINT=enforce` fails the stage.
- `report`: `manifest.sh` and `port-report.sh`.

A raw report of the stage under another number than its place in `config/pipeline.json` fails the stage. The
records are `stages.json` in the state dir. Each run is a run manifest (`runs/<run_id>/`). Progress reporting
arrives in M7.

## Consequences

- A port interrupted in `validate` resumes there: `upgrade` is up to date.
- A failed stage leaves the tree as the stage found it, so the next run starts from a known state.
- The checkpoint refs accumulate under `refs/drupilot/stages/`. They are local: never pushed, and invisible to
  `git log` and `git status`.
