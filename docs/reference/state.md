# Per-module state

drupilot keeps one record per module/theme, `state.json`, in the same hidden state dir as `assess.json` and `last-test.json`: which stages were reached and when, and a snapshot of what a portfolio view needs. It is machine state, so it is hidden on purpose: it survives `git clean` or a rebuilt test-bed (otherwise the next step would restart at `/drupilot-port`), it can never leak into a patch, and one data dir holds every module's record, so `/drupilot-status --all everything` finds them all without walking your project trees. The visible `.drupilot/` folder keeps the human-facing reports; the record is rendered on demand.

The record is written by the flow, not by memory: `port-report.sh` records `ported` / `refactored` (from the manifest's phase), `run-phpunit.sh` records `tested` after a whole-suite run whose preservation is `verified` or `verified-partial` and carries every recorded run's verdict, `verify-core-matrix.sh` and `make-patch.sh` add their verdict and patch, and `/drupilot-setup`, `/drupilot-assess` and `/drupilot-contribute` record `setup`, `assessed` and `contributed` through `scripts/env/state.sh record`. `next-step.sh` (the router and `/drupilot-status`) and the post-edit hook read it.

| Key | Meaning |
| --- | --- |
| `schema` | Record version (`1`). |
| `subject`, `machine_name`, `type` | The module/theme directory (absolute), its machine name and type. |
| `drupal_root`, `ddev_project` | The test-bed (workspace) it lives in and its DDEV project name. |
| `origin`, `placement` | The developer's checkout a loose subject was placed from, and how (`move` / `symlink` / `copy`). |
| `stage`, `stages` | The highest stage reached (`setup` < `assessed` < `ported` < `refactored` < `tested` < `contributed`; it never goes down without `DRUPILOT_STATE_FORCE`), and the time each stage was last recorded. |
| `effort`, `assessed_at` | The assessment's S/M/L/XL verdict and when it was made. |
| `git` | `branch`, `commit` and `dirty` (uncommitted changes) of the subject's checkout. |
| `toolchain` | From the lock: `drupal_core`, `php_target`, `core_strategy`, `packages` (Rector, drupal-rector, PHPStan, coder, Drush, core-dev versions). |
| `tests` | The last recorded PHPUnit run: `status`, `preservation`, `executed`, `tests_failed`, group counts, `recorded_at`, `fresh` (computed on the current sources) and `stale_reason` (`sources-changed`, or `digest-algorithm` for a record of an older drupilot; see [Freshness](#freshness)). |
| `core_matrix` | The last core matrix: `verdict`, `d10_support`, `generated_at`, `fresh`, `stale_reason`. |
| `patch` | The last patch made: `path`, `kind` (`local` / `issue` / `contribution`), `at`. |
| `portfolio` | Set when the module is ported by `/drupilot-layers`: `dir` (the set) and `layer` (its porting layer), written by `state.sh record --portfolio DIR --layer N` (or `refresh`). |
| `created`, `updated`, `drupilot_version` | Record timestamps and the drupilot that last wrote it. |

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" show --subject web/modules/custom/foo   # one module, merged with the current verdicts
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" list --json                              # every record in drupilot's data dir
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" list --root ~/drupal-ports --json       # every module under a directory of workspaces
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" list --registry ports.txt               # one path per line (module dirs or dirs to scan)
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" record --subject web/modules/custom/foo --stage assessed --effort M
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" refresh --subject web/modules/custom/foo --portfolio web/modules/custom --layer 2
```

`show` and `list` are read-only (they never create a state dir); the table goes to stderr and `--json` puts the payload on stdout. A module ported before this record existed is still listed by `--root` or `--subject`, its stage derived from its older records.


## Freshness

A verdict is only shown as current while the module's sources are the ones it was computed on. Each record tied to a version of the sources — a test run (`last-test.json`) and the pre-port baseline (`test-baseline.json`), a negative control, a core matrix, the metadata lint, the Rector dry-run — keeps the `subject_digest` of those sources and `digest_algo`, the algorithm that computed it. The digest covers the PHP family (`*.php`, `*.module`, `*.inc`, `*.install`, `*.theme`, `*.profile`, `*.engine`), `*.yml`, `composer.json`, `*.twig`, `*.js` and `*.css`, skipping `.git/`, `vendor/` and `node_modules/`; a patch or issue text next to the module does not count. A verdict whose digest differs from the current one is reported stale (`fresh: false` above, "stale" in the port report); a baseline taken on the current code is noted as unable to show what the port changed.

drupilot 1.0 computes algorithm 2, which added Twig, JS and CSS. Every digest recorded by drupilot 0.9 (algorithm 1, no `digest_algo`) differs from it, so after an upgrade those records show as stale once (`stale_reason: "digest-algorithm"`, next to `fresh: false`; a record on changed sources has `"sources-changed"`): re-run the step to refresh them. Until then the next step after a green 0.9 test run is `/drupilot-test`, and a failing 0.9 verdict (a regression, a failed core matrix) keeps blocking `port-summary --strict`, because drupilot cannot tell whether its sources changed; a verdict on sources that did change is reported but never blocks.

Records that are compared or hashed between runs keep their timestamps under a top-level `meta` object, so two runs that compute the same result write the same bytes outside it: `rector-rules.json` keeps `meta.generated_at`, and `last-test.json` keeps when each negative control ran in `meta.negative_controls` (`recorded_at` stays where 0.9 put it).

## Raw reports and findings

drupilot 1.0 does not hand the analyzers' output to the model as it is. A stage first runs its deterministic tools and keeps their reports in the same hidden state dir, under `raw/`. `scripts/ai/extract.sh --subject DIR [--stage S]` writes one file per tool, `raw/<NN>-<stage>-<tool>.json`, where `NN` is the stage's place in [the pipeline](pipeline.md). The tools are Rector (a dry-run), PHPStan, PHPCS, the port-safety checks, the signature-change scan and the metadata lint. Each report is canonical: the Drupal root and the container path are stripped from its paths, its keys are sorted, and its timestamps are moved under `meta`. (The analyzers name files from the Drupal root; the port-safety, signature and metadata reports name them from the module.) Two more files complete the stage:

- `<NN>-<stage>-anchors.json` holds the anchor of every line the reports name in a PHP file, computed once in the test-bed.
- `<NN>-<stage>-index.json` names the subject, the target major and each tool's exit code.

`scripts/ai/normalize-findings.sh` then turns a stage's raw files into `findings.json` (schema `schemas/findings.schema.json`, [ADR 0022](../contributing/adr/0022-findings-shape.md)). Each finding has a stable id, its file relative to the module, its anchor (the innermost `Namespace\Class::method` or function, the class for a line in a class body outside its methods, else `{file}`), its symbol, a normalized message and its occurrence. It also carries a severity, a `scope` and a `class`:

- `scope` is `current`, or `next-major` for a soft deprecation under the `report` or `defer` policy (`DRUPILOT_SOFT_DEPRECATIONS`).
- `class` is a deprecation's `hard`, `soft` or `unknown`, else `analysis`, `safety`, `signature`, `metadata`, `style`, `php-target` or `rector`.

The id never includes the line number, so moving code keeps its findings' ids. Findings of different tools about the same symbol at the same anchor are merged, and `sources[]` lists each tool. `findings.json` also records each tool's verdict in `tools` (`ok`, `partial`, `failed` or `missing`), so a run where PHPStan crashed never reads like a clean one. It is a pure function of the raw files, the target major and the soft policy: the same raw files give the same bytes outside `meta`, which records the raw files' hashes and `findings_hash`.

## Worklist

`scripts/ai/classify.sh` turns `findings.json` into `worklist.json`, in the same hidden state dir (schema `schemas/worklist.schema.json`, [ADR 0024](../contributing/adr/0024-worklist-and-actions.md)). Each finding gets a lane, and the findings of one file, anchor and lane make one item. The lanes are, in priority order:

- `rector`: a Rector change, applied by its pass.
- `rector-custom`: a single Rector rule a recipe names (no recipe uses it yet).
- `codemod`: a deterministic fix from [the recipes](recipes.md).
- `ai-templated`: the AI fixes it following a recipe's text.
- `ai-free`: an error no recipe covers.
- `test-adapt`: either of the two above in a file under a `tests/` directory.
- `human`: a person decides.
- `deferred`: nothing to do in this port: a deprecation removed only in a later major, an info finding, or a style finding (Phase 1 keeps the diff minimal).

A recipe applies only when its conditions hold, its required core included: never above the declared floor. An item lists its findings, their recipes and templates, the files it may change, and whether it blocks the stage (an error finding outside `deferred`). Its status is `open`, `applied` or `deferred`.

`scripts/ai/apply-recipes.sh --subject DIR [--reextract]` applies the open codemods (pipeline step S6). Each application is one line of `actions.jsonl`, the machine record of what the recipes did: the finding, the recipe and its version, the outcome, and the file's hash before and after. Your `decisions.jsonl` of divergences is a separate file. The worklist is then classified again:

- a codemod that changed nothing, or failed, hands its finding to `ai-templated`;
- with `--reextract` (step S7), the tools run again on the new tree, and a finding a codemod could not clear goes to `ai-templated` too;
- a codemod whose change is no longer in the file (you reverted it) is tried again.

The same findings, recipes and actions always give the same worklist outside `meta`.

## Assessment

`scripts/analysis/assess.sh --subject DIR` computes the viability verdict ([ADR 0025](../contributing/adr/0025-assess-rubric-from-findings.md)). It runs the assess stage (extraction, findings and worklist), the core-target decision and the dependency check, then writes `assess.json` to the same hidden state dir (schema `schemas/assess.schema.json`) and `viability-report.md` to the visible `.drupilot/` folder. The verdict comes from three counts:

- `manual`: each call of a current hard or unknown deprecation that no Drupal Rector rule changes in the same function or method, plus the signature and port-safety findings of severity `error`. Each finding is listed in `manual_items` with its finding id and its number of calls. The digests layer is not part of the assessment.
- `hard_breaks`: the categories of `config/catalog/hard-breaks.json` (Twig 3, CKEditor 5, jQuery UI, Symfony 7) that match at least one file of the module.
- `blocking_deps`: the `drupal/*` dependencies with no Drupal 11 release on drupal.org. Offline, a dependency is `unknown` and does not block.

The first rule that matches wins, and `rubric.rule` keeps it:

| Verdict | Rule |
|---|---|
| XL | `blocking_deps >= 1` or `hard_breaks >= 3` or `manual > 40` |
| L | `hard_breaks == 2` or `manual > 15` |
| M | `hard_breaks == 1` or `manual >= 5` |
| S | otherwise |

Soft deprecations and next-major findings never count. When Rector or PHPStan gave no verdict, the verdict is marked `provisional`, the stage is not recorded and the script exits 3. The script needs the test-bed's Drupal root and reads its settings there. `assess.json` also keeps `findings_hash`, `worklist_hash` and the module's digest, so the same tree, lock and drupal.org answers give the same document outside `meta`, which holds its time. The script records the `assessed` stage with the verdict as `effort`.

## Port manifest

`scripts/ai/manifest.sh --subject DIR [--phase port|refactor] [--rationale FILE]` writes `port-manifest.json` to the same hidden state dir (schema `schemas/port-manifest.schema.json`, [ADR 0027](../contributing/adr/0027-generated-port-manifest.md)). It is built from what the scripts recorded, never from memory: the worklist by lane and status, the codemods still in effect, the Rector rules and files of the applying run, the digests verdicts, the decision log, and the git diff against the port's base. A manual edit is a file the diff shows that neither Rector nor a codemod changed. The only input the model gives is the rationale, `{"<worklist item id>": "why"}`. An unknown id is refused, and a later run keeps the rationale of the items still in the worklist. `port-report.sh` renders the manifest with the decision log and the verification records of the state dir. The same records and tree give the same manifest outside `meta`.
