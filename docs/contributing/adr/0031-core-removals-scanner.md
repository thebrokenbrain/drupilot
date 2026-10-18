# 0031 — The core-removals scanner and where its results go

- **Status:** accepted
- **Date:** 2026-10-18
- **Decided by:** the 1.0 working session (R-AUTO-3), during M6 (T-M6-01, T-M6-04, T-M6-07)

## Context

Drupal 12 removes core extensions and libraries (`config/targets/12.json` `removed_extensions` and
`removed_libraries`, verified at 12.0.0-beta1). Drupal 11.0 did the same for some others (`11.json`). The plan asks
for a scanner, `scan-removals.sh`, "driven by `removed_extensions`/`removed_libraries`". It covers dependencies,
`base theme:`, libraries and composer requires. The plan also has rule H8: never rewrite a removed-module dependency
unless a contrib release covers the declared range C (04 §2.7, 04-R14). The upgrade plan already reserves
`core_removals` and `hard_breaks` for it. Five questions were left open:

1. Which detectors does the scanner run? The data has two vocabularies. `12.json` `hard_break_detectors` lists
   `base-theme-removed`, `dependency-removed`, `migrate-drupal-usage`, `phpunit-annotations`,
   `symfony8-constraint-validator` and `library-removed`. `paths/graph.json` lists the 11-12 edge's `detectors`.
2. How does the scanner tell a core dependency from a contrib one with the same name? Contact moved to a contrib
   project called `contact`.
3. Where does the network answer (H8) live? The plan must stay deterministic, and the findings must hash the same
   on two runs of the same tree (DET-2).
4. How do the results reach the plan, the findings, the worklist and the assessment? The acceptance check reads
   `assess.json` `.hard_breaks | map(.id)`, but `hard_breaks` there has been a list of category ids (strings) since
   M4.
5. How does a person opt in to a pre-release target (`ALLOW_PRERELEASE`, CC-15)?

The release feeds were read on 2026-10-18:

| Project | Release | `core_compatibility` |
|---|---|---|
| `contact` | 1.0.0 | `>11.3` |
| `history` | 1.0.0 | `>11.3` |
| `ban` | 1.1.0 | `^11.2 \|\| ^12` |
| `claro` | 3.0.0 | `^11.5 \|\| ^12` |
| `text_with_summary` | 1.0.0 | `^11.5 \|\| ^12` |

So for C = `^11.3 || ^12`, H8 allows rewriting `contact`, `history` and `ban`. It does not allow `claro` or
`text_with_summary`.

## Decision

1. **Five detectors, one vocabulary.** `scripts/analysis/scan-removals.sh` emits the ids of
   `12.json` `hard_break_detectors` that removal data can drive:
   - `dependency-removed`;
   - `migrate-drupal-usage`: a dependency on `migrate_drupal` or `migrate_drupal_ui`, or code that names their
     namespace. A module with only its own `migrate` source plugins is not flagged;
   - `base-theme-removed`;
   - `library-removed`: a list item or a key in a `*.info.yml` or `*.libraries.yml`, or a quoted name in PHP or
     Twig;
   - `namespace-move`: a class of `targets/<T>.json` `namespace_moves` used in its old namespace. This is an
     announced note and never a hard break (X4).

   It scans the majors in (S, T] of the plan. `phpunit-annotations` and `symfony8-constraint-validator` are not
   the scanner's: the Rector passes that fix them report them (`Drupal12SetList::DRUPAL_120`, and the tests-only
   pass of T-M6-05). The graph's per-edge `detectors` stay as they are; they name what a hop looks for.

2. **`drupal:NAME` and a bare `NAME` are core's.** `PROJECT:NAME` with another project already names the contrib
   module, so it is not reported. A dependency whose replacement project is already a `drupal/PROJECT` require in
   the subject's `composer.json` is `composer-required`, an info note: declare it as `PROJECT:NAME`.

3. **The network answer is per stage, frozen per root, never in the plan.**
   - Each finding gets an action:
     - `rewrite`: a covering release exists;
     - `blocked`: the feed was read and no release covers C;
     - `verify`: unknown;
     - `composer-required`;
     - `decision`: a base theme;
     - `hard-break`;
     - `note`.
   - A release covers C when it is published, is not a `-dev` branch, and is stable. While T is a pre-release
     (a preview), alpha, beta and RC releases count as well. Its `core_compatibility` must also admit every
     verified core minor C admits (`release_covering`).
   - The feed is cached for a day (`release_history_fetch`).
   - In deterministic mode, a known answer (true or false) is frozen in the root's lock under
     `.replacements.<project>`, together with the range it answered for. It is reused until C changes or
     `lock-sync.sh --refresh` drops it.
   - `upgrade-path.sh` always runs the scanner `--offline`. Its `core_removals` keep only the network-free facts
     (detector, name, kind, `removed_in`, `rewrite`, replacement project, core alternative, hard break,
     files). The plan resolves the same way with or without a network.

4. **Plan: objects. Findings: one class. Assessment: ids.**
   - The plan's `core_removals` is one object per (detector, name). Its `hard_breaks` is
     `[{id: <detector>, name, files}]`, for the actions `decision` and `hard-break`.
   - `extract.sh` keeps the scanner's report as the raw tool `removals`. It runs online with the frozen plan's S, T
     and C.
   - `normalize-findings.sh` makes one finding per hit:
     - `tool: catalog`, `class: removal`;
     - `rule: removal:<detector>:<action>`, `symbol`: the removed name;
     - the scanner's severity: error for `decision`, `hard-break` and `blocked`, warning for `rewrite` and
       `verify`, info for `composer-required` and `note`.
   - `classify.sh` sends a removal finding to `human` with a reason:
     - `base-theme-removed`;
     - `removed-from-core`;
     - `removed-dependency-no-release`;
     - `removed-dependency-unverified`;
     - `removed-dependency-replaceable`.

     Info findings are `deferred`. The rewrite itself, a codemod under H8, comes with the Drupal 12 test-bed.
   - `assess.sh` keeps `hard_breaks` as a list of ids. It adds the detectors of the open hard-break removals to
     the catalog categories, so they count in the rubric. It adds their files to `hard_break_categories`, and
     counts each `blocked` dependency in `blocking_deps`. A new `core_removals` field lists them for the report.
     The acceptance check therefore reads `.hard_breaks | index("base-theme-removed")`, not `map(.id)`: the
     plan's objects carry the details, and the 1.0 `assess.json` shape stays additive.
   - `port-summary.sh` blocks a ported subject while a blocking removal item is open (source `core-removals`).

5. **`ALLOW_PRERELEASE` is a tab only after someone asks for a pre-release.**
   - When T resolves to a pre-release major without the opt-in, `/drupilot-setup` asks "Port to Drupal T as a
     preview?". The answers are `no` (the default: Drupal 11, the supported major) and `yes`.
   - The tab is never shown in an autonomous run. There, the refusal `prerelease-not-opted-in` stops the run with
     nothing written.
   - It can be pre-answered with `DRUPILOT_CHOICE_ALLOW_PRERELEASE` (registry `config/choices.json`).
   - `yes` persists `DRUPILOT_ALLOW_PRERELEASE=true` once the draft plan resolves.
   - The refusal's choice now names the tab. The router passes a `--target N` on to `/drupilot-setup`. A frozen
     plan fixes T for the stages after it.

## Consequences

- Every plan now carries `core_removals` and `hard_breaks`; `[]` replaces `null`. The T=11 plan goldens change
  that way. The template goldens follow, because `phpstan.neon`'s `tmpDir` is keyed by the plan hash. This is an
  intended golden change, recorded in the CHANGELOG. The D10→D11 patch (H10) does not change.
- `deps-status.sh` still calls a removed core module `core`. Its list predates the removals data; the scanner's
  findings are the authority for a removed module.
- A port to Drupal 12 still stops after the draft plan until the Drupal 12 test-bed lands (T-M6-03). The removals
  and the opt-in work now, and the scanner already serves Drupal 11 ports (the 11.0 removals).
