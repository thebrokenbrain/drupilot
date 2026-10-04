# 0010 — check-jsonschema validates the schemas in CI, with a jq fallback

- **Status:** accepted
- **Date:** 2026-10-04
- **Decided by:** the 1.0 working session (R-AUTO-3), during M1 (T-M1-09, 07-Q11)

## Context

The schemas of drupilot's persisted artifacts need a real JSON Schema
validator in CI, never at plugin runtime. The candidates were
`check-jsonschema` (Python) and `ajv-cli` (Node). On 2026-10-04 PyPI showed
`check-jsonschema` 0.38.2 (released 2026-09-23, Python >= 3.10, draft
2020-12) and npm showed `ajv-cli` 5.0.0, unchanged for years.

## Decision

`scripts/dev/schema-check.sh` uses `check-jsonschema` 0.38.2: from PATH in
the CI legs that install it, or in `python:3.13-alpine` pinned by digest
(`--mode docker`), which is what the `schemas` gate uses under `--ci` on a
host without it (with neither, `--ci` fails). A jq structural validator that reads the same
schemas always runs, so the bash-only CI legs still check every instance. The
schemas are therefore restricted to the keywords it understands: `type`,
`required`, `properties`, `additionalProperties` (boolean), `items`, `enum`,
`const`, `minimum` and local `$defs`/`$ref`.

## Consequences

One Python tool in CI, no Node. A schema needing `oneOf`, `pattern` or
`format` would first need the jq validator extended.
