# 0022 — The shape of findings.json

- **Status:** accepted
- **Date:** 2026-10-06
- **Decided by:** the 1.0 working session (R-AUTO-3), during M4 (T-M4-05)

## Context

AR-10 and 05 §2.4 fix what a finding is made of:
- its id, `F-` + hex12(sha256(tool␟rule␟file␟anchor␟symbol␟norm(message)␟occurrence)), with no line number;
- subject-relative paths;
- the dedupe precedence `rector > phpstan > phpcompat > catalog > upgrade_status > phpcs`, with merged findings
  keeping `sources[]`;
- a `scope` of `current` or `next-major`.

They defer the rest of the record to a research draft that the plan does not carry. Four points needed a
decision before `normalize-findings.sh` could be written:
1. which fields a finding has beyond the id's parts;
2. where the anchors come from, given that `anchor.php` needs PHP and the findings goldens must run Docker-free
   on every CI leg;
3. what counts as "the same finding" from two tools;
4. what `scope` a soft deprecation gets.

## Decision

**The record.** `findings.json` is `{schema: 1, stage, subject: {machine_name, path}, target: {major,
soft_policy, runner, php_version}, counts, findings: [...], meta}`. `meta` holds what changes between two runs
of the same tree (the raw files' hashes, the time) and is left out of `findings_hash` (DET-2). A finding is
`{id, tool, rule, file, line, anchor, symbol, message, occurrence, severity, scope, class, sources}`:
- `tool` is `rector`, `phpstan`, `catalog` or `phpcs` (`phpcompat` and `upgrade_status` join when their
  extractors land);
- `rule` is the Rector FQCN, the PHPStan identifier (`phpstan:untyped:<sha8 of the message>` without one), the
  PHPCS source, or `port-safety:<check>`, `signature:<id>`, `metadata:<check>` for the catalog scans;
- `line` is kept for a person and the AI to find the code, but is never part of the id, so a line shift that
  leaves the anchor and the message alone keeps the id;
- `class` is `hard`, `soft` or `unknown` (a deprecation, as `classify-deprecations.sh` says), `analysis` (any
  other PHPStan error), `safety`, `signature`, `metadata`, `style` (PHPCS), `php-target` (a PHPCompatibility
  sniff) or `rector`.

**Anchors are extracted, not computed while normalizing.** `extract.sh` runs `anchor.php` in the bed once over
every `(file, line)` the raw reports name and stores the answers as one more raw file,
`raw/<NN>-<stage>-anchors.json`. `normalize-findings.sh` then needs only jq and a sha256 tool, so it gives the
same `findings.json` on every platform, and the goldens are recorded in the lab and checked Docker-free. A
non-PHP file is anchored `{file}` (YAML key paths and Twig blocks come with their extractors). Without a PHP
runner, the anchors file says `unavailable` and every anchor is `{file}`. The ids then differ from a run that
had anchors, which DET-11 already allows (ids compare only under the same lock and runner).

**Same finding.** Two findings are the same issue when they share `(file, anchor, symbol)` with a symbol. The
one from the tool that comes first in the precedence keeps its id and fields, and every source is listed in
`sources[]`, sorted by precedence. This holds within one tool too: two calls of the same deprecated function
in one method are one finding with two sources, because they are fixed together. Findings without a symbol
are never merged: Rector's attribution is per file and per hunk, and two PHPCS sniffs on one line are two
findings.

**Scope.** `next-major` is work the current target does not need:
- a soft deprecation (removed after the target major) under `DRUPILOT_SOFT_DEPRECATIONS` `report` or `defer`;
- upgrade_status findings on a bed of the target major (X18), once that extractor lands.

A soft deprecation under `fix`, a hard one and an unknown one are `current`. The policy is recorded in
`target.soft_policy`, so the same raw reports always give the same scopes.

**Order and Rector.** Findings are sorted by `(file, anchor, id)`. A Rector finding is one per applied rule and
hunk of its file's diff, anchored at the hunk's first changed line, with the rule's short name as its message.

## Consequences

- `findings.json` and its hash are a pure function of the raw files, the target major and the soft policy:
  `normalize-findings.sh` is the reference implementation and `schemas/findings.schema.json` its contract.
- The raw files of a golden must include the anchors file. Recording one needs the lab bed (`extract.sh`).
- A new extractor adds a `tool` or a `rule` prefix, a precedence slot and a row in this ADR's lists.
