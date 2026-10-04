# 0015 — How a test-bed finds its toolchain cell, and how a 0.9 lock is read

- **Status:** accepted
- **Date:** 2026-10-04
- **Decided by:** the 1.0 working session (R-AUTO-3), during M2 (T-M2-10, T-M2-11)

## Context

AR-09 turns `config/toolchain-reference.json` into cells (`11`, `12`,
`d7-pre`) plus `legacy_v1`, the set drupilot 0.9 shipped, and asks that a
0.9 lock keep the 0.9 pins until the user refreshes it (CC-10). It says "the
lock records `.toolchain.cell`", but `.toolchain` is the map of installed
packages that `lock-sync.sh` rebuilds from `composer.lock`. Nor does it say
how drupilot tells a 0.9 lock from a fresh 1.0 one: `ddev-up.sh` already
writes `drush/drush` into `.toolchain` before any toolchain is installed.

## Decision

1. **The lock records its cell in a top-level `toolchain_cell`**, which
   `install-toolchain.sh` writes after a successful install and lock sync.
   `.toolchain` stays a package map.
2. **A 0.9 lock is one that 0.9 created and that pins `rector/rector`.** A
   lock drupilot 1.0 creates starts as `{"schema": 1}` (the stamp T-M3-04
   plans, landed here: no schema means 0), so neither a lock that `ddev-up.sh`
   created with only its drush pin nor one that `lock-sync.sh` filled from a
   `composer.lock` drupilot never set up (which may already hold Rector) is
   mistaken for one. The rule is: no `schema`, no `toolchain_cell`, and a
   `rector/rector` pin (only 0.9's `install-toolchain.sh` installed Rector).
   Such a lock is cell `legacy_v1`: in `auto` deterministic mode its own pins are
   installed, as 0.9 did, a notice names the refresh command, and its cell
   is not recorded. `--source reference` (or `range`) refreshes it to the
   cell of the installed core's major and records that cell.
3. **The cell of a test-bed** is, in order: the lock's `toolchain_cell`;
   `legacy_v1` for a 0.9 lock; the `toolchain_cell` that
   `config/targets/<major>.json` names for the installed core's major; `11`.
   A lock's answer that no longer fits the installed core's cell (the root
   was rebuilt on another major, or a 0.9 lock sits under a Drupal 12 core)
   gives way to the core's cell. Reading it never creates drupilot's data
   directory (`preflight.sh` reads it, and its `--extended` checks write
   nothing).
4. **Only a verified cell pins anything.** An unverified cell (12 while
   Drupal 12 is a pre-release) makes `install-toolchain.sh` warn and resolve
   every package from the `.packages` ranges, exit 0. `preflight.sh`
   compares the installed toolchain with the root's cell.
5. **`known_broken` keeps only combinations that install and then crash**,
   because `preflight.sh` matches it against installed versions. The
   install-time conflicts AR-42 found on a Drupal 12 bed (coder 8.3.31 and
   phpstan 2.2.2 next to `drupal/core-dev` 12, drush 13 on core 12) are in
   cell 12's note: Composer already refuses them. `preflight.sh` matches the
   rules against every package a rule or the remediation names, so a broken
   combination is found even on a root whose cell pins nothing.
6. **The PHPCompatibility set of ADR 0003** is a cell-independent
   `phpcompat` entry of the same file, with the same shape as a cell.

## Consequences

A project ported with 0.9 keeps its toolchain, byte for byte, until its
owner refreshes it; a new test-bed gets cell 11 (ADR 0001). The schema of
the file is `schemas/toolchain.schema.json`, and the `data` gate checks it
and that every target's `toolchain_cell` is a cell of the file.
