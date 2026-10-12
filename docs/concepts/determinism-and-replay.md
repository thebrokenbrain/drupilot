# Determinism and replay

!!! note "Summary"
    The same module, plan and lock give the same port. drupilot gets there
    with four parts: pinned inputs, canonical artifacts, a fixpoint check, and
    (in a later pre-release) a replay cache for the AI's answers. This page
    covers the first three.

## Pinned inputs

Everything a port depends on is resolved once and frozen in the project's
lock (`drupilot-lock.json`):
- the upgrade plan;
- the Drupal core of the test-bed and the dev toolchain;
- the digests commit, the drupal-rector list of rules it already implements,
  and your verdicts on the digests rules;
- the DDEV add-ons.

A later run reuses them. `DRUPILOT_DETERMINISTIC=false` resolves them again
and refreshes the lock.

A tool that is not the version the lock pins does not run: the script stops
and says which version it found. Each report records the runner, the PHP
version and the tool version it ran with.

## Canonical artifacts

Every file drupilot computes is written in one canonical form:
- keys sorted;
- paths relative to the module, with the test-bed's root and the container's
  `/var/www/html/` removed;
- line endings normalized;
- timestamps, versions and run ids kept under a top-level `meta`.

Two runs on the same inputs give files that are byte-identical outside
`meta`. Their hashes (`findings_hash`, `worklist_hash`, the module's digest)
say what each file was computed from.

The finding ids follow the same rule. An id is a hash of the tool, the rule,
the file, the function it is in, the symbol and the normalized message, never
the line number. Moving code keeps its findings' ids, and a codemod that
fixed a finding can be told apart from one that did not.

## The fixpoint check

A deterministic step that is run again on its own output must change
nothing. At the end of a port the validate stage runs the extraction again,
and the fixpoint gate checks that Rector, the codemods and the deterministic
lanes have nothing left (see [the pipeline](pipeline.md#the-fixpoint-gate)).
Its result is `fixpoint.json`, with the exact items when it does not
converge.

## Run records

Each run of the pipeline or the fixpoint gate is recorded in
`runs/<run_id>/run-manifest.json`, in the module's hidden state dir. The
record keeps the hashes the run started from and the ones it produced, so
two runs can be compared, and its run id and times sit under `meta`.
`DRUPILOT_RUNS_KEEP` (default 10) sets how many runs are kept.

The stages also keep `stages.json`, with the digest each one started from
and the one it left. A stage whose output is the current state is not run
again, so an interrupted port resumes where it stopped.

## What is not deterministic yet

The AI's edits are not deterministic yet. Until the replay cache arrives,
two ports of the same module can differ where the AI wrote code, and the
manifest's rationale records why it changed what it changed. The tools'
part of the port (Rector, the codemods and every verdict) is deterministic
already.
