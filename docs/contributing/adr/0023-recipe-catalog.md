# 0023 — The recipe catalog v1

- **Status:** accepted
- **Date:** 2026-10-06
- **Decided by:** the 1.0 working session (R-AUTO-3), during M4 (T-M4-06)

## Context

AR-11 and 05-R4 define `config/recipes.json` (`drupilot.recipes/1`). Its entries are
`{id, version, matches, applies_when, kind, engine, template|params, postconditions, fixtures}`. The file is
generated from `config/deprecations.json` and the catalogs, so there is one source of truth (CC-33). The
engines for 1.0 are `ere-replace`, `info-yml`, `attributes`, `yaml-edit`, `php-script` and `rector-rule`, the
last only under ADR 0002's `--only` limits. Every Docker-free recipe has `before/`, `after/` and
`expect.json` fixtures.

The plan leaves six points open:
1. where a codemod's engine parameters live, since the catalogs only hold explanations;
2. what a recipe matches in `findings.json`;
3. how its `version` is kept;
4. where the metadata lint's checks come from, since `lint-extension-metadata.sh` reads no catalog;
5. which engines get an executor now;
6. which findings get a codemod in v1.

## Decision

**One source, an optional `recipe` block.** An entry of a catalog becomes a recipe. The catalogs are
`deprecations.json` (`deprecations`, `signature_changes`, `lifecycle`), `port-checks.json` (`checks`) and the
new `config/metadata-checks.json`. A catalog entry may carry a `recipe` block that turns it into a codemod or
changes its lane:

```json
"recipe": {"lane": "codemod", "engine": "ere-replace", "params": {...}, "applies_when": {...}, "postconditions": [...]}
```

The scripts that read the catalogs pick their own fields and ignore the block, so their outputs and the
CC-33 goldens are unchanged. `scripts/dev/gen-recipes.sh` writes `config/recipes.json`. Its `--check` mode
(part of the `data` gate) fails on any drift, so the generated file is never edited by hand.

**Ids and matching.**

| Source | Recipe id | Matches | Lane by default |
|---|---|---|---|
| `deprecations[]` (not a `[tag]` explainer) | `dep.<slug of symbol>` | `message_ere` (the entry's pattern, case-insensitive), plus the `symbols` of the `lifecycle` entries the pattern matches | `ai-templated` |
| `signature_changes[]` | `sig.<id>` | `rule: signature:<id>` | `ai-templated` |
| `port-checks.json` `checks` | `safety.<check>` | `rule: port-safety:<check>` | `ai-templated` |
| `metadata-checks.json` `checks` | `meta.<check>` | `rule: metadata:<check>` | `human` |
| a `lifecycle[]` entry no pattern matches | `life.<symbol>` | `symbols: [<symbol>]` | `ai-templated` |

A deprecations entry whose pattern is a tag (`\[plugin-di\]`, `\[signature:...\]`) explains a port-safety or
signature finding. It is not a recipe of its own. It is the template of the `safety.*` recipe whose tag it
matches. A `sig.*` recipe takes its template from its own entry's `why`, `fix` and `d10_compat`.

The classifier (T-M4-07) tries a finding's recipes in this order: rule, then symbol, then message, then id.
It also honors `applies_when`.

**`version`** is the first 12 hex of the sha256 of the recipe's canonical content. The content is every field
but `version`, `source` and `fixtures`. It changes exactly when what the recipe does or says changes, with no
hand-kept counter. It is the `recipe@version` of the AI cache key (05 §R8).

**`applies_when`** holds:
- `core_min`: the lowest core the recipe's output runs on. The classifier never applies a recipe above the
  declared floor F.
- `file_ere`: the finding's file must match.
- `severity`: the finding severities the recipe fixes.

**Metadata checks.** `config/metadata-checks.json` lists the lint's check ids, with their description, lane
and optional `recipe`. A unit test keeps the list equal to the lint's `ALL_CHECKS`. The lint itself is
unchanged.

**Executors.** `scripts/ai/apply-recipe.sh` applies one recipe to one finding. In v1 it has the three
Docker-free engines:
- `ere-replace`: a `sed -E` substitution on the finding's line, or on the whole file;
- `yaml-edit`: a line-oriented fixed-string replacement on the finding's line, with named captures from the
  finding's message;
- `info-yml`: `set-core-requirement.sh` with the subject's own plan's `range.constraint`. It runs on a copy
  of the physical tree, so a symlinked subject is never edited through the link, and only the finding's file
  is written. A requirement whose floor is above the main `.info.yml`'s is `not-applicable`: no recipe raises
  the declared floor. The upgrade stage sets the main `.info.yml` first, so the codemods (S6) see the
  ported floor.

`params.captures` (`{name: ERE}`, matched on the finding's line before the change) gives `{name}` to the
postconditions. Postconditions apply to the line, the file, the file's code lines but the finding's
(`file-except-line`), or the body of the function the finding's line declares (`function-body`, up to the
`}` at the signature's indentation); comment lines are not code there. An unresolved `{placeholder}` or an
empty capture fails the postcondition, and `gen-recipes.sh` names a placeholder no capture defines. A file
without a final newline keeps none.

`attributes`, `php-script` and `rector-rule` stay in the schema's engine list. They get their executors with
the first recipe that needs one: no v1 recipe does. A recipe whose replacement is not exact reports
`no-match`, changes nothing, and its item falls to the next lane.

**The v1 codemods:**
- `sig.hook-entity-operation` and `sig.hook-entity-operation-alter` (`ere-replace`): a required
  `CacheableMetadata` parameter becomes `?CacheableMetadata $x = NULL`. The catalog's `d10_compat` says an
  optional parameter works on every core. That holds only when the body does not use the parameter (it is
  NULL on older cores), so a postcondition rejects the change when the parameter appears in the function's
  body. The finding then goes to the AI with the template.
- `safety.class-case` (`yaml-edit`): in a `.yml` file, the class name gets the case of the file that exists.
  The class is `Drupal\<extension>\` plus its path under `src/`.
- `meta.submodule-core-req` (`info-yml`): the submodule's `core_version_requirement` becomes the plan's
  range, as `/drupilot-port` already does.

## Consequences

- A new codemod is a `recipe` block on its catalog entry, fixtures under `tests/fixtures/recipes/<id>/`, and
  a regeneration. Facts in the block follow the catalog's rule: verified against core source.
- The AI lanes get the catalog text as their template, and the lifecycle facts (`deprecated_in`,
  `removed_in`, `replacement`, `replacement_since`) when they exist.
- A project overlay `<root>/.drupilot/recipes.json` is read by the classifier (T-M4-07), not by the generator.
