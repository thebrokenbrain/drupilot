# The pipeline

!!! note "Summary"
    A port is a fixed sequence of **stages**. Each one reads the plan, the lock
    and your module's sources, does one job, and records what it saw and what
    it left. Deterministic tools do the work they can do the same way every
    time; the AI only touches what they leave. Every stage can be checked,
    skipped when it is up to date, and undone when it fails.

## The stages

The list is `config/pipeline.json`. Its ids are public and stable: they name
the stages in the records, in these docs and in the progress view. The
[pipeline reference](../reference/pipeline.md) lists each stage with its
inputs, outputs and the gate to leave it.

In order, for a port of a Drupal 10 module to Drupal 11:

1. **doctor**: the requirements of the next stage are there.
2. **plan-draft**: the target and the PHP are chosen, and the upgrade plan is
   drafted (see [upgrade paths](upgrade-paths.md)).
3. **setup**: the test-bed, the toolchain and the configs.
4. **assess**: the tools run once, read-only, and the viability verdict is
   computed from their findings.
5. **plan-final**: the core range is chosen, and the plan is frozen.
6. **upgrade**: the official Rector pass, the codemods, and the digests rules
   you reviewed.
7. **php**: the PHP-target rules (a placeholder in this pre-release).
8. **residual**: the AI fixes what the tools left (arrives in a later 1.0
   pre-release; until then the port command drives these fixes).
9. **validate**: the checks, ending with the fixpoint gate.
10. **test**: the test suite, and the preservation verdict.
11. **report**: the manifest, the report card and the local patch.

`refactor` and `contribute` run only when you ask for them. The
`d7-rewrite` stage is the experimental Drupal 7 track.

## From findings to changes

The deterministic core works the same way at every stage:

1. **Extract.** Each tool runs once and its report is kept, cleaned of paths
   and timestamps, as `raw/<NN>-<stage>-<tool>.json` in the module's hidden
   state dir.
2. **Normalize.** The reports become `findings.json`: one finding per
   problem, with a stable id that does not depend on line numbers.
3. **Classify.** Each finding gets a lane in `worklist.json`: Rector, a
   codemod, the AI with a recipe's text, the AI on its own, a test to
   adapt, a person, or nothing to do in this port.
4. **Apply.** The codemods run, each logged in `actions.jsonl` with the
   file's hash before and after, and the tools run again on the new tree.

The [state reference](../reference/state.md) describes each file.

## The stage contract

`scripts/ai/pipeline.sh` runs the deterministic stages under one contract.
`/drupilot-port` uses it for `upgrade`, then for `php`, `validate` and
`report` at the end (see [ADR 0028](../contributing/adr/0028-pipeline-stage-contract.md)).

- **A checkpoint first.** Before each stage, the module's tree is recorded as
  a git ref under `refs/drupilot/stages/<run>/<stage>`. Your index, your HEAD
  and your branches are never touched.
- **Undone on failure.** A stage that fails puts the tree back at its
  checkpoint and stops the run, so the next run starts from a known state.
- **Skipped when up to date.** A stage records the digest of the plan, the
  lock and the sources it started from and the one it left. When the state
  is still the one it left, the stage is up to date and does not run again.
  An interrupted port resumes at the stage that did not finish.
- **Same-major.** A plan with no hop between majors skips `upgrade`.

## The fixpoint gate

At the end of a port or a refactor, `validate` runs the extraction once more
and checks that the deterministic lanes have nothing left: no Rector change,
no codemod that would still apply, no open item in the `rector` or `codemod`
lanes. A tool that gave no verdict never counts as a pass.

`DRUPILOT_FIXPOINT` decides what a failure does:
- `warn`, the default through the betas, reports the items and goes on;
- `enforce`, the default from the release candidate, stops the stage;
- `off` skips the gate.

## Where the AI fits

The AI never decides what to fix. It gets the worklist items the tools
could not close, one at a time, with the recipe's text when one exists, and
its changes are checked like any other change. The verdicts that matter (the
viability rubric, the fixpoint, the preservation of behavior) are computed by
scripts. Until the residual stage arrives, the port command drives these
fixes, and you explain them in a rationale keyed by worklist item.
