# drupilot invariants and their tests

The twelve invariants of drupilot 0.9, each with the test that guards it, or
the milestone of the 1.0 plan that owns it. A guard never runs Docker or a
model unless the table says so. `scripts/dev/check.sh` runs the `unit` and
`smoke` gates that hold them; a test that belongs to a later milestone is
committed as a stub that exits 77 (reported as skipped) until then.

| Invariant | Statement | Guard | Status |
|---|---|---|---|
| INV1 | An autonomous run never pushes, opens an MR or contributes; the guard hook asks even if a prompt misbehaves. | `tests/unit/hooks_contract.sh` (INV1 cases); smoke `hooks`; the router evals: statically, the prompt rules that keep an `auto` run tab-free and push-free (`auto_rules` of `tests/evals/router/tab-sequence.json`, `evals` gate); and, opt-in (`evals.sh --live`, never in CI), a real `auto` run that must answer NO_TABS. | tested |
| INV2 | A failing gate makes no change: preflight exits before any mutation, with no migration or legacy copy. | `tests/unit/inv2_preflight_fail_no_mutation.sh`: for each of the 9 gated commands, the gate line and every load-time `!` span run with a failing preflight (no jq; and no git, or no docker/ddev, per the gate's profile, so preflight runs its whole body and exits 2) and change neither the data dir, nor the legacy plugin data dir, nor the subject; smoke `legacy-state`. | tested |
| INV3 | Tests are never relaxed and verdicts are never fabricated; Phase 1 writes no tests. | `tests/unit/inv3_no_fabricated_verdicts.sh` (stub). The preservation enum is frozen by the M1 contract snapshot; the verdict is checked end to end by the M4 G-E2E skeleton. | owner: M4 |
| INV4 | Never scaffold over a loose checkout; the origin stays clean; `clean.sh` refuses directories it did not create. | `tests/unit/inv4_loose_and_clean.sh`; smoke `monorepo-testbed` and `shared-testbed`. | tested |
| INV5 | A hand-edited generated config is never overwritten without `--force`, and `--force` keeps a backup. | `tests/unit/inv5_template_not_overwritten.sh`. | tested |
| INV6 | Digests are never vendored or applied blindly; only a SHA whose pass finished is frozen. | `tests/unit/inv6_digests_not_vendored.sh` (stub). The runtime cache location was checked in lab L-M0-1. | owner: M8 |
| INV7 | STDOUT carries only parseable output; hooks ask and never deny. | `tests/unit/hooks_contract.sh` (INV7 cases); the STDOUT of the Docker-free analysis, preflight, detect-php and render scripts on the fixtures is frozen byte for byte by `scripts/dev/baseline-0.9.sh` (the `baseline-0.9` golden of the `golden` gate), and the key sets of `preflight`, `port-summary` and `core-strategy` plus every script's exit codes by `scripts/dev/contract.sh` (the `contract` gate). The other STDOUT-payload scripts (`make-patch.sh`, `state.sh`, `clean.sh --json`, `resolve-workspace.sh`, ...) have no frozen output yet. The progress-on/off byte compare (CC-04) arrives with M7. | tested (CC-04 part: M7) |
| INV8 | The lock is reused in deterministic mode; `DRUPILOT_DETERMINISTIC=false` refreshes it. | `tests/unit/lock_resolve.sh`. | tested |
| INV9 | The recorded stage never goes backwards without `DRUPILOT_STATE_FORCE`. | `tests/unit/inv9_stage_monotonic.sh`. | tested |
| INV10 | The contribution patch applies onto `origin/BASE`; the local patch excludes `.ddev/`, `vendor/`, `.phpstan-cache/`, `node_modules/`, `.drupilot/`, `.drupilot.json` and drupilot's own patches. | `tests/unit/inv10_local_patch_excludes.sh` (each exclusion, and the patch applies); smoke `monorepo-testbed`. The `origin/BASE` hard gate needs a remote: covered by the contribution flow's own check. | tested |
| INV11 | After the port, every nested `info.yml` accepts the target core. | `tests/unit/inv11_nested_info_target.sh`; smoke `dry-run`. | tested |
| INV12 | The host side stays portable to bash 3.2 and BSD/BusyBox userland (and mawk, jq 1.6). | the `portability`, `special-vars` and `jq-compat` gates of `scripts/dev/check.sh`, and the CI matrix (macOS stock bash 3.2, Alpine `bash:3.2`, Debian 12 mawk + jq 1.6). | tested |

Other named tests of the plan (`10` AR-31) already in place:
`tests/unit/sessionstart_writes_nothing.sh` (CC-28) and
`tests/unit/keep_current.sh` (CC-36).
