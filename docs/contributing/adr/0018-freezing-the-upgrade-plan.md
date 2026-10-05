# 0018 — Freezing the upgrade plan in the lock

- **Status:** accepted
- **Date:** 2026-10-05
- **Decided by:** the 1.0 working session (R-AUTO-3), during M3 (T-M3-04)

## Context

AR-06 says the upgrade plan is frozen in the lock "with `lock_resolve`" at
`.upgrade_plan` + `.upgrade_plan_hash` + `.upgrade_plan_phase`, and that
readers get any version only through `plan_get`. It does not say:
- who writes it;
- whether one lock holds one plan or one per module;
- what makes a frozen plan stale;
- how a reader avoids creating state for a root it only looked at;
- what the final phase may change.

`lock_resolve` freezes one string per key, which does not fit a whole plan.

## Decision

1. **The resolver freezes, on request.** `scripts/analysis/upgrade-path.sh
   --freeze` is the only writer. It writes after a successful resolution
   (exit 0) only; a refusal writes nothing. Without `--freeze` the resolver
   stays pure. The four keys go in one atomic write:
   - `upgrade_plan`: the whole plan, meta included, so `plan_frozen` prints
     what was resolved byte for byte;
   - `upgrade_plan_hash`;
   - `upgrade_plan_phase`;
   - `data_hash`.

   This goes through `lock_merge_json` (`scripts/lib/lock.sh`), which keeps
   every other key and stamps `drupilot_version`. It creates `{"schema": 1}`
   only for a missing lock. A 0.9 lock is never given a schema
   (ADR 0015; `migrate.sh` does that in M9).
2. **One plan per Drupal root.** The plan uses the top-level keys of AR-14,
   and the lock is keyed by the root as before. A frozen plan of another
   subject (another `subject.machine_name`) is stale. A map keyed by module,
   with lock schema 2, waits for `/drupilot-layers` to need per-module plans.
3. **The hash and its canonical form.**
   - `upgrade_plan_hash` is `sha256:` plus the hex digest of `jq -S -c
     'del(.meta)'`, newline included (`canon_json_hashable | json_hash`). Two
     runs that resolve the same plan give the same hash, whatever the time
     or the drupilot version.
   - The plan and the lock write hashes as `sha256:<hex>`; `golden.json` and
     the snapshot directory names keep bare hex.
4. **Reuse and staleness in deterministic mode.** A frozen plan is reused,
   printed as it was frozen and with nothing written, when:
   - its subject is the same;
   - its phase is at least the requested one (final ≥ draft);
   - the requested T, P, strategy, explicit range and pre-release opt-in are
     the frozen `target.major`, `php.final`, `range.strategy`,
     `range.constraint` (explicit only) and `target.preview`.

   A change of the version data does **not** make a plan stale: the plan
   keeps naming the versions it was resolved with until the developer asks
   for another one. A P that is only the target's data default is the frozen
   P; a re-resolution keeps the frozen bed core while the lock records none,
   and the frozen toolchain cell. A frozen final plan is reused for a later
   final request too, its analyzer evidence included. A lock that records
   another core minor for the test-bed than the frozen plan's (the setup
   installed it) re-plans the draft. Any other request resolves afresh.
   `DRUPILOT_DETERMINISTIC=false` always resolves afresh and refreezes,
   without the final guard below (INV8).
5. **What the final phase may change.** A final plan resolved over a frozen
   draft (in deterministic mode) may only:
   - add hops (a lower S);
   - raise F.

   It must keep T, P and `toolchain_cell`, and `bed_core` at minor
   granularity; over a frozen final plan only these four are kept (its hops
   and F may move with the code). Otherwise it is refused as
   `final-changes-frozen`, with the choices to keep the frozen value or to
   re-ask the tab (`PHP_TARGET`, `TARGET_MAJOR`, `CORE_TARGET` for a lowered
   F), or to re-run the setup.
6. **A lock is never clobbered.** `lock_merge_json` starts a missing, empty
   or blank lock as `{"schema": 1}`, refuses to touch one that is not a single
   JSON object, and moves its temp file over the lock only when that file is
   one. **Readers create nothing.** `lock_path` (`scripts/lib/lock.sh`) is the
   lock's path without the `mkdir` of `drupilot_lock_file`.
   - `plan_get JQPATH [ROOT]` prints one value: a string raw, `false` and
     numbers kept, null as nothing. It returns 1 when the lock holds no
     plan.
   - `plan_frozen [ROOT]` prints the plan.

   AR-14's rule "readers only through `drupilot_lock_file`" is amended to
   allow `lock_path`.
7. **A loose subject's draft** is frozen under the root it will have:
   `resolve-workspace.sh`'s pure answer, the same path `ddev-up.sh` builds
   the test-bed at.

## Consequences

- `lock_resolve` and its INV8 test are unchanged.
- Two concurrent writers race, and the last `mv` wins, as in 0.9.
- `hard_breaks` that M5 appends to a frozen plan will need either a refreeze
  or a worklist of their own; M5 decides.
