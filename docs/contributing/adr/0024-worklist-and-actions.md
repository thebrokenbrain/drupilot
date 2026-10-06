# 0024 — The worklist and the actions log

- **Status:** accepted
- **Date:** 2026-10-06
- **Decided by:** the 1.0 working session (R-AUTO-3), during M4 (T-M4-07)

## Context

AR-10 fixes how `worklist.json` is built. It groups the `scope: current` findings into items by
`(file, anchor, lane)`. The lanes, in priority order, are `rector`, `rector-custom`, `codemod`,
`ai-templated`, `ai-free`, `test-adapt`, `human` and `deferred`. The item shape is
`{id, lane, finding_ids[], file, anchor, allowed_files[], recipe?, template?, era, category, explanation,
change_record_search_url, blocking, reason?, status}`. DET-9 records every recipe or AI action in
`decisions.jsonl` with `finding_id`, `item_id`, `input_hash` and `output_hash`. The 05 pipeline (S6, S7)
applies the codemods and re-extracts.

Five points were open:
1. which lane a finding without a recipe gets;
2. what an item holds when its findings have different recipes;
3. where the recipe and AI actions are recorded;
4. how the classifier learns that a codemod failed, so the re-extraction does not send the finding back to
   the codemod lane forever;
5. what happens to the `next-major` findings, which AR-10 groups only from `current` ones.

## Decision

**Every finding is in one item.** `next-major` findings are items too, in the `deferred` lane (X18: never an
AI lane), so the worklist accounts for the whole of `findings.json`. A finding's lane is decided in this
order:

1. `next-major` → `deferred`.
2. A Rector finding → `rector`.
3. An `info` finding → `deferred`: nothing to change; the hook catalog says "works on every core", for
   instance.
4. A PHPCS style finding → `deferred`. Phase 1 keeps the diff minimal: phpcbf only touches the lines that
   were changed (05-R7).
5. The first recipe that matches (rule, then symbol, then message, then id) and whose `applies_when` holds.
   `core_min` is checked against the declared floor F, which is unknown without a plan, so such a recipe
   does not apply then.
6. A matching codemod that does not apply → `ai-templated`, with its template. Another recipe that does not
   apply → its own lane.
7. No recipe: a catalog finding → `human`; anything else → `ai-free`.
8. Finally, an `ai-templated` or `ai-free` finding in a file under `tests/` → `test-adapt`.

**The item.** An item's findings may come from several recipes. `recipe`/`template` become:
- `recipes`: the sorted ids;
- `recipe_of`: each finding's recipe or null;
- `templates`: each recipe's template.

`reason` joins the findings' reasons. `era` is `d<source major>` of the plan. `blocking` is true when an
item outside `deferred` has an `error` finding. `status` is one of:
- `open`;
- `applied`: every codemod of the item was applied on the current findings;
- `deferred`.

The id is `W-` + hex12(sha256(file␟anchor␟lane)), so the same work keeps its id across runs.

**The actions log.** Recipe actions, and later the AI's, go to the subject's hidden state dir, in
`actions.jsonl`. The human `decisions.jsonl` of `log-decision.sh` stays as it is. `port-report.sh` reads every
entry there as a divergence from the prescribed flow, and a recipe applied by the flow is not one. An action
line is `{schema, kind: "recipe-apply", item_id, finding_id, recipe, version, file, line, status, input_hash,
output_hash, findings_hash, at}`. The port manifest (T-M4-10) reads both logs.

**The classifier reads the log.** A codemod is not tried again on a finding:
- after it gave no change (`no-match`, `not-applicable`, `rejected`) at the same recipe version;
- after it was `applied` on an earlier extraction (another `findings_hash`) and the finding is still there.

The finding then goes to `ai-templated`. An item whose codemods were all applied on the current findings
(the same `findings_hash`) is `applied` until the re-extraction (S7) removes its findings.

**Overlay.** `<root>/.drupilot/recipes.json` has the shape of `config/recipes.json`. Its recipes replace the
plugin's by id. Its hash is part of the worklist's `meta.recipes_hash`.

## Consequences

- `classify.sh` is a pure function of `findings.json`, the recipes, the floor and the actions log. The
  worklist goldens are computed Docker-free from the findings goldens.
- The AI stages (M5+) read only `open` items of `ai-templated`, `ai-free` and `test-adapt`, and only their
  `allowed_files` (DET-3).
- The fixpoint check (T-M4-11) can say "no open `rector` or `codemod` item after S7" from the worklist alone.
