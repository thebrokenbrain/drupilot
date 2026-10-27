# 0007 — The lab goldens live next to their fixture, not inside it

- **Status:** accepted
- **Date:** 2026-10-04
- **Decided by:** the 1.0 working session (R-AUTO-3), during M1 (T-M1-04, T-M1-05)

## Context

The roadmap names `tests/fixtures/legacy_widgets/{raw,golden}/` for the
recorded port of the `legacy_widgets` fixture. But `tests/fixtures/legacy_widgets/`
is the module itself: the smoke tests, the v0.9.0 baseline and every lab bed
copy that directory as-is. A `golden/` or `raw/` directory inside it would
become part of every port the goldens record — PHPCS lints `.md` files, a
README would show up in its findings, and the recorded port would no longer
be the port of the fixture.

## Decision

Golden outputs recorded in the lab live in `tests/fixtures/<fixture>.golden/`
(`golden/port-to-drupal-11.patch`, `raw/*.json`, a `README.md` with the
environment and the exact commands, and the `golden.json` manifest that pins
every file by sha256). `scripts/dev/golden.sh` discovers every
`tests/fixtures/*.golden/` directory.

## Consequences

The fixture stays byte-identical to what the baseline and the lab copy. A new
fixture's golden follows the same naming. The lab golden is a determinism
reference (byte-identical across runs and across v0.9.0 and 0.9.1), not a
complete port: the scripted R-LAB-8 sequence leaves the manual fixes to the
model-driven flow.
