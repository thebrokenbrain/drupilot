# Changelog

All notable changes to **drupilot** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add every notable change under **[Unreleased]** as you make it (grouped under
`Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security`). On
release, rename `[Unreleased]` to the new version with a date, bump `version`
in `.claude-plugin/plugin.json` (the single version source; `marketplace.json`
carries none) to match, and tag the commit `vX.Y.Z`.

## [Unreleased]

### Added
- **The canonical-artifact helpers** (`scripts/lib/canon.sh`, AR-13,
  T-M4-02), the base of the deterministic pipeline:
  - `canon_json [ROOT]`: keys sorted, two-space indent, LF line endings, a
    CRLF inside a string made LF, the runner paths stripped;
  - `relpath_strip_runner [ROOT]`: removes the container's `/var/www/html/`
    and the host's root (as given and its physical path, also JSON-escaped),
    so the same tree gives the same root-relative paths on the host and in
    DDEV; it gives the M1 raw goldens back byte for byte;
  - `file_hash` (LF-normalized), `finding_norm_message` and `canon_jq_defs`
    (the message part of a finding id: runner paths, "on line N" and
    whitespace noise dropped);
  - `worklist_get` / `worklist_set`: `worklist.json` in the subject's state
    dir, written atomically in its canonical form.
- **`docs/concepts/upgrade-paths.md`**: the upgrade plan for users. It covers
  the three axes (source, target, PHP), the hops, the core-range strategies,
  the draft and final phases, refusals, `plan show` and the names.
- **The `hard-rules` gate** (alias `no-version-literals`, T-M3-12) greps the
  scripts, the PHP templates (comment lines skipped) and the prompts for the
  hard rules:
  - H2: `SleepToSerialize`/`WakeupToUnserialize` outside a skip list;
  - H3: `withComposerBased(`;
  - H5: a drupal.org docs or project releases URL (the HTML pages);
  - H6: a hard-coded "Drupal 12 stable";
  - H7: a three-major range literal in code;
  - H9: a `drush migrate:import`;
  - the forbidden `Drupal10SetList::DRUPAL_10` aggregate;
  - a `drupalNN` DDEV-type literal outside `scripts/lib/plan.sh`;
  - H4: exactly as many version-literal lines per script as recorded, a
    ratchet that only goes down.

  Reasoned exceptions live in `tests/contract/hard-rules-allow.txt`. The
  prompts that still described the `DRUPAL_10` aggregate or a `drupal11` DDEV
  type now describe the plan's per-minor sets and `target_ddev_type`.
- **The `scripts` gate** (AR-22) checks every script but `scripts/dev/`. Each
  sources `common.sh` at its depth, answers `--help` with exit 0 and a Usage
  section, and refuses an unknown flag with exit 1. The probe is
  `--drupilot-no-such-flag --help`, so no script body runs. The 28 scripts of
  0.9 that skip an unknown flag keep their frozen CLI; every new one refuses
  it. AR-22's `--json` check stays with the smoke tests.
- **`scripts/drupilot.sh plan show`** (T-M3-13; the headless dispatcher of
  AR-22, which answers only this verb until M10) prints the "drupilot plan"
  block: the subject's frozen upgrade plan, else a draft.
  - The commands with load-time spans, and the `minimal-port`,
    `php-target-tuning`, `viability-assessment`, `full-refactor` and
    `ddev-environment` skills, render it at load time.
  - Every prompt with a `` !` `` span carries the fixed fallback line
    (`prompt_bang_fallback.sh`).
- **`DRUPILOT_TARGET_MAJOR` and `DRUPILOT_DRUPAL_TARGET` agree** (T-M3-06,
  X12 as ADR 0021 narrows it):
  - `DRUPILOT_DRUPAL_TARGET` is still the test-bed's core constraint, and the
    highest major it admits names the target major (`^12` → 12,
    `>=11 <12` → 11);
  - a constraint that admits two or more majors (e.g. `^10.3 || ^11`) is also
    the declared core range `upgrade-path.sh` uses (strategy `explicit`),
    unless `DRUPILOT_CORE_TARGET_STRATEGY` is set too. `/drupilot-port` then
    asks no core-target question and keeps that range in the final plan;
  - a one-major value (`^11.2`, `~11.2.0`, `11.x-dev`) only pins the test-bed,
    as in 0.9;
  - with only `DRUPILOT_TARGET_MAJOR` set, the test-bed's core constraint is
    `^<major>`.

  With neither set, 0.9's `11` and `^11`.
- **The target major names drupilot's outputs** (T-M3-08, CC-16, CC-17,
  09-R10). For Drupal 11 every name is the 0.9 one, byte for byte:
  - the patch description `port-to-drupal-<T>` (`<module>-port-to-drupal-<T>.patch`
    and its issue-comment and `-repo.patch` forms);
  - the issue-fork branch `<issue>-port-to-drupal-<T>`;
  - a loose subject's test-bed `<name>-d<T>`;
  - the DDEV project type (`config/targets/<T>.json` `.ddev_type`).

  `resolve-workspace.sh --target N` names the test-bed for another major, and
  a bed drupilot 0.9 named `-d11` is still found. The exclusion globs
  (`make-patch.sh`, `git_local_exclude`, `origin-hygiene.sh`, the managed
  `.gitignore` block) cover every target's patches as well as the 0.9 ones,
  so an old patch left in a tree never leaks into a new one.
- **`docs/reference/deprecations-of-drupilot.md`** lists every renamed setting,
  value, field and flag of drupilot (every `config/migrations.json` row; a unit
  test keeps the two in step). The `version` gate also checks the
  `value_aliases` rows.
- **The commands plan before they act** (T-M3-15): `/drupilot-setup` asks
  the new **Target major** tab (`TARGET_MAJOR`: Drupal 11 by default, 12 only as
  a preview with `DRUPILOT_ALLOW_PRERELEASE=true`; `--target N` wins) before the
  PHP target, then freezes the draft upgrade plan in the root's lock
  (`upgrade-path.sh --phase draft --freeze`), persisting both answers only once
  it resolves (into a loose subject's test-bed right after it is created); a
  refusal re-asks the tabs, overriding the value that led to it; a target other
  than 11 stops after the plan, persisting nothing, until T-M3-08; and once the
  toolchain is installed the draft is resolved again, so it re-plans on the
  core the test-bed really runs. The Target major tab shows only when a
  pre-release may be chosen (`DRUPILOT_ALLOW_PRERELEASE=true`); the PHP default
  is the target's own. `/drupilot-port` freezes the final plan with
  the core-target answer and applies the plan's `range.constraint` and
  `php.require_php` (`plan_get`), so core-strategy only shows each option's
  consequences (and refuses a final plan for a target other than 11); the
  orchestrator checks rule D7-AUTO before any stage of an autonomous run and
  freezes the draft and final plans as the commands do. The router
  eval allows a new tab only as `tab-sequence.json` `allowed_insertions` lists
  it (TARGET_MAJOR right before PHP_TARGET).
- **core-strategy is checked as a view of the plan's decision** (T-M3-05,
  CC-11, CC-36): `tests/unit/core_strategy_view.sh` resolves every fixture
  and monorepo module with each strategy through both `core-strategy.sh` and
  `upgrade-path.sh` and requires the same range and resolved strategy, and
  `keep_current.sh` pins the keep-current outcome in both
  (`keep_current_alias`).
- **`sigpipe` gate** in `scripts/dev/check.sh` and **`grep_q`** in
  `scripts/lib/core.sh`: no pipeline in `scripts/` or `hooks/` may end in a
  consumer that stops reading early (`| head`, `| grep -q` / `-m` / `-l`, an
  `| awk` exit); `grep_q` answers like `grep -q` but reads its whole input.
- **`DRUPILOT_TARGET_MAJOR`** (default `11` for all of 1.0.x) and
  **`DRUPILOT_ALLOW_PRERELEASE`** (default `false`), the target Drupal major and
  the opt-in for a major with no stable release yet (T-M3-06), with
  `resolve_target_major`, `resolve_php_target_for` (P from the target's data
  default unless one is set) and `config_get_explicit`. The upgrade plan
  reads them.
- **`scripts/lib/canon.sh`**: `canon_json_hashable`, `json_hash` and
  `sha256_hex`, the canonical form an upgrade plan is hashed in (AR-13).
- **The upgrade-plan building blocks** in `scripts/lib/plan.sh` (T-M3-03,
  AR-04/AR-06, ADR 0017): `plan_target_block` (the target, its bed core and
  the pre-release opt-in), `plan_hops` / `plan_detectors` over
  `paths/graph.json`, `rector_sets_for_plan` (per-minor sets up to the bed,
  breaking sets by the floor, `always_sets`, reflection from a bed's
  drupal-rector, skipped sets recorded with a reason), `plan_rector_skip`,
  `plan_rector_bc`, `plan_php_block`, `plan_test_matrix`, `plan_ci_flags`,
  `plan_assert` (the plan's assertions, never fixed silently) and
  `version_data_hash`; in `scripts/lib/strategy.sh`,
  `core_requirement_minors`, `core_requirement_lowest` and
  `core_requirement_majors` (which core minors, lowest version and majors a
  `core_version_requirement` admits, read as composer/semver reads it and
  checked against its answers). The resolver CLI that assembles them comes
  next.
- **`scripts/analysis/upgrade-path.sh`**, the upgrade-plan resolver (T-M3-01,
  T-M3-03, AR-06, ADR 0017): from the subject (`detect-source.sh`, static in
  the draft phase, with the analyzer signal in the final one), the target
  major, the PHP target, the strategy (the 0.9 names as aliases) or an
  explicit `--range`, the version data and the root's lock, it prints the
  plan (`--json`) or refuses with exit 2 and the choices that resolve it; a
  Drupal 7 source in an autonomous run is refused before anything is written
  (`d7-auto`). It writes nothing. Its goldens are `tests/golden/plans/`.
  The root's `.drupilot.json` and lock are found from the subject's logical
  path (a symlink placement included), never from the cwd; `plan_assert`
  gains `range-excludes-bed` (a range that does not admit the bed core).
- **The upgrade plan is frozen in the lock** (T-M3-04, ADR 0018):
  `upgrade-path.sh --freeze` writes `upgrade_plan`, `upgrade_plan_hash`,
  `upgrade_plan_phase` and `data_hash` to the Drupal root's lock in one write,
  only after a successful resolution; in deterministic mode a later run
  reuses the frozen plan while the request matches, and a final plan may
  only add hops or raise F over it (`final-changes-frozen`). Readers use
  `plan_get JQPATH [ROOT]` / `plan_frozen [ROOT]` (`scripts/lib/plan.sh`)
  and `lock_path` (`scripts/lib/lock.sh`), which create nothing;
  `lock_merge_json` merges several keys in one atomic write and never gives
  a 0.9 lock a schema (nor overwrites a lock that is not one JSON object).
  A data refresh never makes the frozen plan stale (a default P, the bed core
  and the toolchain cell stay the frozen ones), and a loose subject's draft
  freezes under the test-bed root it will have (`--root` of a path that does
  not exist yet). `schemas/lock.schema.json` describes the new keys.
- The `jq-compat` gate also rejects a jq keyword used as a `def` parameter
  (jq 1.6 refuses `def c($label)`).
- **`schemas/upgrade-plan.schema.json`** with an example plan
  (`schemas/examples/upgrade-plan.example.json`), checked by the `schemas`
  gate; the target major and bed core, the PHP floor and final, the range,
  the hops and the toolchain cell are marked as what the hard gates read.
- **ADR 0017**: what the upgrade-plan resolver decides where AR-04/AR-06 are
  silent.
- **Unit goldens pinned to a data snapshot**: `golden.sh` also checks every
  `tests/golden/<name>/` holding a `golden.json`, and the unit tests
  regenerate them against the snapshot it pins (`detect-source`, and the
  168-case `core-strategy` matrix).
- **`scripts/analysis/detect-source.sh`** (T-M3-02, AR-05): the source era
  S of a module or theme, the oldest Drupal major whose APIs it still uses,
  with its track (`d7-assisted` for Drupal 7), a confidence and the evidence:
  a Drupal 7 `.info`, a `core: 8.x` `.info.yml`, the declared constraint, the
  SimpleTest and Drupal 7 test APIs (the `config/paths/eras.json` signals,
  which gain JavascriptTestBase) and, with `--full --phpstan FILE`,
  PHPStan's "removed from drupal:X", which only lowers S. S is the minimum
  of the code signals and the declared floor (ADR 0016).
  `subject_d7_info_file` / `info_value_d7` read a Drupal 7 `.info` without
  changing anything for `.info.yml` subjects. Goldens in
  `tests/golden/detect-source/`, and the source-era fixtures `d7_minimal`,
  `d8_legacy`, `d9_module`, `d11_php_only` and `keep_current`.
- **The `lib-defs` gate**: every function of `scripts/lib/*.sh` is defined in
  exactly one lib, `common.sh` lists each domain lib once, and a hook's
  `_DRUPILOT_LIBS` covers every lib it reaches (a static call scan);
  `check.sh --compare-pre-split=REF` also compares the function set with a git
  ref.
- **Unit tests and the `unit` gate.** `tests/lib/assert.sh` is a portable
  assertion library (bash 3.2, BSD/BusyBox, jq 1.6; no bats) with its own
  self-test; `scripts/dev/unit.sh` runs it and every `tests/unit/*.sh` with the
  same bash, and `scripts/dev/check.sh` runs that as its new `unit` gate
  (`--gate` is now an alias of `--only`). A test passes only with its summary
  line, at least one assertion and no failed one. `t_isolate` sets
  `DRUPILOT_NONINTERACTIVE=1`, so no test can block on one of drupilot's
  prompts on any platform; where `setsid --wait` and `timeout` exist a test
  also runs detached from the terminal and under a 300 s timeout, and Ctrl-C
  stops the run and the running test. The first
  tests freeze 0.9 behaviour: `config_get` precedence, `version_ge`, the
  `project_state_path` key (symlinked paths included), `lock_resolve`,
  `choose_one` pre-answers, the `keep-current` core strategy, the hooks'
  fail-safe contract (malformed stdin, no jq, a HOME no process can write, on
  payloads that reach each hook's real work) and
  the invariant tests INV1, INV2, INV4, INV5, INV7, INV8, INV9, INV10 and INV11
  (INV3 and INV6 are stubs owned by later milestones; `tests/INVARIANTS.md` maps
  all twelve), plus `sessionstart_writes_nothing`.
- **Hook latency baseline.** `scripts/dev/hook-latency.sh` measures each hook's
  p50/p95 on a fixed payload; the 0.9 numbers are recorded in
  `tests/baseline/v0.9.0/hook-latency.json`.
- **Contract snapshots and the `contract` gate.** `scripts/dev/contract.sh`
  freezes the 0.9 public surface in `tests/contract/*.json`: the commands (an
  `argument-hint` token may only be added, in order), skills and agents,
  `config/choices.json`, the key sets of `preflight --json`, the port-summary v1
  and `core-strategy --json`, the generated branch/patch/test-bed names, the
  enums (preservation, stages, `d10_support`, ...), each read from the code
  that emits it, and every script's documented exit codes. An intended change
  is an entry in `tests/contract/allowed-changes.json`, pinned by the sha256 of
  the new snapshot (a snapshot changed twice has two entries).
- **Router evals and the `evals` gate.** `scripts/dev/evals.sh` checks the
  router statically: the ordered tab sequence of a guided `full` run, the
  mode words, the mode-inference rules (each cue bound to the mode its rule
  gives it, a bare `/drupilot` included) and the prompt rules that keep an
  `auto` run tab-free and push-free (`tests/evals/router/`). A command's tabs include the ones it shows by
  header, so the refactor stage's reuse of the port's "Drupal 10 check" tab is
  part of the frozen sequence. `--live` replays the inference cases and each
  command's tab order through `claude -p` with every tool call denied by a
  hook (pass at 90% or more; opt-in, never in CI); an `auto` run must answer
  NO_TABS, and a failed or empty run never counts as a pass.
- **Golden outputs and the optional `golden` gate.** `scripts/dev/golden.sh`
  absorbs `baseline-0.9.sh --check` (the smoke test `baseline` is gone; the
  gate runs with `--smoke`/`--ci`, so on every CI leg) and checks
  `tests/fixtures/legacy_widgets.golden/`: the patch and raw Rector, PHPStan
  and PHPCS JSON of the scripted `legacy_widgets` port recorded in the DDEV lab
  (core 11.4.8, PHP 8.3, digests off), byte-identical with v0.9.0's, each file
  pinned by `sha256` in `golden.json`. `tests/fixtures/autologout.pointer.json`
  pins the autologout 8.x-1.4 corpus by commit and tarball hash.

- **The `version` gate.** `scripts/dev/check.sh` checks that plugin.json
  equals the released CHANGELOG heading of highest SemVer precedence (so a
  0.9.x section merged from main above a 1.0 pre-release is fine), that a `v*`
  tag on HEAD is `v<version>`, that `main` never carries a pre-release version
  (also on a pull request into it, through `GITHUB_BASE_REF`), and that
  `config/migrations.json` is coherent (valid variable names, aliased keys
  declared in `config/config-reference.json`). `semver_gt` in `common.sh`
  compares versions with pre-releases (`version_ge` strips them).
- **`scripts/dev/release.sh`** cuts a release: version checks (SemVer
  precedence, pre-releases included), plugin.json, the CHANGELOG heading and
  compare links, `claude plugin validate` and `check.sh --ci`, then a
  `chore(release)` commit and an annotated `vX.Y.Z` tag. It never pushes;
  `--dry-run` writes nothing. An unchanged pre-release can be promoted to its
  release (`1.0.0-rc.N` -> `1.0.0`) with an empty `[Unreleased]`.
- **Alias layer for renamed settings.** `config/migrations.json` (no row
  yet) lets `config_get` resolve an old key name, or one old value, to the
  new key, from the environment and then from `.drupilot.json`, with one
  deprecation warning per process (decided when `common.sh` is sourced, so
  the `$(config_get ...)` subshells do not repeat it); the environment still
  wins over every file tier.
- **`config/config-reference.json` and the `config-keys` gate.** Every
  `DRUPILOT_*` key the scripts, hooks and prompts read is declared with its
  tier, type, enum, default source and docs page; the gate warns on an
  undeclared read or an inconsistent entry, and fails when a
  `config/defaults.json` comment grows past 1800 characters.

- **The docs site (infrastructure).** `mkdocs.yml` and `docker-compose.yml`
  build an English-only site from `docs/` with Zensical 0.0.67 in Docker
  (`docker compose up docs`; `docker compose --profile build run --rm
  docs-build` for the strict build; it also builds with Material for MkDocs
  9). `scripts/dev/gen-docs.sh` generates its reference pages (commands,
  configuration, choices, scripts, skills and agents, toolchain, Drupal
  deprecations) from the sources, byte-identical on every platform;
  `docs/reference/state.md` documents the per-module state record. The new
  `docs` gate fails on drift, on a page missing from the nav or a nav entry
  missing from `docs/`, on a plugin file citing a README section or a missing
  page, and on a broken link between pages (a root `FLOW*.md` is only
  noted). `.github/workflows/docs.yml`
  builds the site on every pull request and deploys it to GitHub Pages only
  on a release tag (`vX.Y.Z`, never a pre-release such as `v1.0.0-alpha.1`)
  or a manual run.
- **Architecture decision records** in `docs/contributing/adr/`: the owner's
  answers to the 1.0 plan's open questions (0000), the lab spikes of M2 (0001
  toolchain cell 11, 0002 the Rector compat pass, 0003 PHPCompatibility, 0004
  the provisional Drupal 12 cell, 0006 hooks keep `ask` under headless
  `claude -p`) and the decisions taken while building M1 and M2 (0007–0014).
- **JSON Schemas for the persisted artifacts** (`schemas/`): the port
  summary (v1), `assess.json`, `last-test.json`, `port-manifest.json`, the
  lockfile and `preflight --json`, describing 0.9 as it is.
  `scripts/dev/schema-check.sh` validates the 0.9 instances (the baseline
  captures, lab samples in `tests/baseline/v0.9.0/samples/` and a live
  preflight) with `check-jsonschema` 0.38.2 where installed (CI, or a pinned
  Docker image) and always with a jq structural validator; the new `schemas`
  gate runs it.
- **Version data, with its sources.** `config/targets/{10,11,12}.json` (one
  file per Drupal major: status, release and end-of-life dates, the oldest
  core a site must run before it can update, every minor's newest tag, PHP
  floor, recommended PHP, PHP support from drupal.org's requirements table,
  Symfony/Twig majors and PHPUnit/Coder/PHPStan constraints, the core modules,
  themes and libraries each major removed, the per-minor drupal-rector sets),
  `config/php/versions.json` (each PHP minor's lifecycle and tool ids) and
  `config/php/rules.json` (the PHP compat, deny, report-only and
  removed-without-rule entries), `config/paths/eras.json` and `graph.json` (the
  source-era fingerprints and the upgrade hop graph). Every value names its
  source and whether it was verified; an unknown value is `null` or a minor
  `{"status": "detect"}`. Schemas in `schemas/` (target, php-versions,
  php-rules, paths, catalog). The removals follow the core tree at both
  tags: every module (nested ones included, such as
  `node_storage_body_field` and `search_node`), theme and
  `core.libraries.yml` key that disappears at a major's .0 is listed (22
  libraries in 10.0, 14 in 11.0, 3 in 12.0), and
  Migrate Drupal and Migrate Drupal UI are recorded as still shipped in
  12.0.0-beta1 with `lifecycle: obsolete`.
- **`scripts/dev/refresh-data.sh`** (developer only, never run by a port)
  regenerates the derived fields of `config/targets/*.json` from packagist and
  git.drupalcode.org at each minor's newest tag, keeps the hand-maintained
  fields, checks every removed extension and library against the core tree at
  both tags, reports any extension (every `.info.yml` under `core/modules`
  and `core/themes`, nested modules included, listed from a tree-only git
  fetch of each tag) or library that disappears at a major's .0 without
  being listed, and reports a drupal.org page (read
  through api-d7) that changed since it was read. Every fetch is cached;
  `--offline` runs are byte-identical, and nothing is written unless every
  fetch succeeded.
- **The `data` gate** (`scripts/dev/data-check.sh`): the version data and any
  `config/catalog/*.json` match their schema, every value names its source,
  every node a hard gate reads is verified and never "announced", and the
  files agree with each other. The `schemas` gate validates the same files
  with `check-jsonschema` too.
- **`scripts/lib/plan.sh`**, sourced by `common.sh`: `target_get`,
  `php_window`, `php_bounds_for_range` (the PHP window of a declared core
  range: `^10 || ^11` gives 8.1 to 8.5; nothing when a major is not in the
  data) and `core_version_cmp`, which orders
  pre-releases (`12.0.0-beta1` < `12.0.0`) but reads a minor or a branch as
  the whole branch (`12.0.0-beta1` == `12.0`).
- **`docs/reference/version-matrix.md`**, generated from the version data by
  `scripts/dev/gen-docs.sh`.
- **Data snapshots for the goldens.** Each golden's `data_hash` is the
  sha256 of the version data it was computed with, vendored under
  `tests/fixtures/data-snapshots/<hash>/`; `golden.sh` checks the goldens
  against that snapshot (`baseline-0.9.sh --data-dir`), never against the
  live `config/` (the baseline golden's scripts read the snapshot through
  `DRUPILOT_VERSION_DATA_DIR`), so a data commit never changes an existing
  golden. An edited or missing snapshot fails, and so does one no golden is
  pinned to; `golden.sh --update` vendors the live data as a new, verified
  snapshot, repins, and (without `--only`) removes the unused ones.

- **The toolchain matrix.** `config/toolchain-reference.json` (schema 2,
  `schemas/toolchain.schema.json`) holds one cell per Drupal major family:
  cell 11 (ADR 0001), the provisional cell 12 (ADR 0004, not pinned until it
  is re-verified in M6), `d7-pre`, the PHPCompatibility set (ADR 0003), and
  `legacy_v1`, the set drupilot 0.9 shipped. A test-bed uses the cell its
  installed core major names; the lock records it (`toolchain_cell`), and
  `install-toolchain.sh --json` reports it (`cell`). A lock drupilot 1.0
  creates starts as `{"schema": 1}`, which is how a lock 0.9 created is told
  apart. ADR 0015.
- **The Rector compat pass** (ADR 0002). `templates/rector-compat.php.tmpl`
  registers only PHP deprecation fixes whose output still runs on the PHP
  floor (today `ExplicitNullableParamTypeRector`: `Foo $x = NULL` becomes
  `?Foo $x = NULL`) and no set. `run-rector.sh` renders it at the Drupal root
  and runs it right after the official pass when the floor is below PHP 8.4
  and the declared core range runs on 8.4 or later. Its `--json` reports it
  (`compat_status`, `compat_files`, `rule_hits.compat`, errors with `pass: 3`)
  with `php_floor` and `php_ceiling`; its dry-run record holds the compat
  pass's `--apply` to what it announced, and a crash counts as an
  official-pass crash (exit 3), although the rule record of what the
  official pass already applied is kept. `render-templates.sh` gains the
  `rector-compat` target (`--only rector` implies it; `skipped` when no
  compat rule applies) and `php_floor`/`php_ceiling` in its `--json`. New
  helpers: `php_constraint_floor` (`plan.sh`: the lowest PHP a `require.php`
  constraint admits), `rector_php_bounds`, `rector_compat_needed`,
  `rector_floor_tokens`, `rector_config_floor` and `rector_config_pristine`
  (`common.sh`).
- The `data` gate checks that every rule `templates/rector.php.tmpl` skips is
  `drupal_safe: false` in `config/php/rules.json`, and that every rule of
  `templates/rector-compat.php.tmpl` is a `drupal_safe` compat rule there.
- **`DRUPILOT_LOCK_LOCATION=state|project`** (T-M4-16, AR-14, OD-06;
  default `state`). With `project`, the Drupal root's lock lives at
  `<root>/drupilot-lock.json`. drupilot's managed ignore block leaves it out,
  so a team can commit it and share the frozen core, toolchain, digests SHA
  and upgrade plan.
  - It applies only to your own Drupal root with an installed core. It does
    not apply to a test-bed drupilot built or will build for a loose module
    (the draft plan is frozen before the bed exists), a root holding placed
    modules, or a module repo carrying its own core. Those keep the state dir,
    and `lock-sync.sh` and `upgrade-path.sh --freeze` warn about it.
  - The lock moves at its next write: it is linked into place atomically, and
    the state copy is retired as `.moved-to-project`, never read again.
    Until the move the state copy is read; `lock_clear` removes both.
  - With `state`, a lock left at the root is reported, not read.
    `make-patch.sh` never puts `drupilot-lock.json` in a patch.
  - Every reader goes through `lock_path` / `drupilot_lock_file`; the
    `hard-rules` gate's new `LOCK` rule fails on a lock path spelled anywhere
    else. `lock_get` and `lock_show` no longer create the state dir.
- **`config/pipeline.json`, the stage catalog** (T-M4-13, AR-07): the
  ordered stages of a port.
  - The ids are `doctor`, `plan-draft`, `setup`, `assess`, `plan-final`,
    `d7-rewrite`, `upgrade`, `php`, `residual`, `validate`, `test`, `report`,
    `refactor` and `contribute`. They are public and stable from 1.0 on.
  - Each stage carries its label, kind, weight, conditions, skip reason, tabs,
    sub-steps, outputs, gate, the `state.json` coarse stage it records, and
    the skill step that defines its procedure.
  - `schemas/pipeline.schema.json` validates it (the `schemas` gate), and
    `docs/reference/pipeline.md` is generated from it.
- **The staged PHP runtime and `anchor.php`** (T-M4-04, AR-23, 05-R5).
  - `stage_runtime ROOT` (`scripts/lib/cache.sh`) copies the plugin's PHP
    helpers (`scripts/php/*.php`) into `<root>/.drupilot/runtime/`, where the
    bed's container can run them. Every copy is verified by its sha256: a
    tampered or missing one is staged again. The set's hash is kept in the
    lock as `.runtime_hash`.
  - The first helper, `scripts/php/anchor.php`, gives each `{file, line}` its
    anchor: the innermost `Namespace\Class::method` or function (closures,
    arrow functions and anonymous classes are transparent), or `{file}`. It
    uses `token_get_all`, so it needs no dependency.
  - It ran on the `tests/fixtures/anchor` files (traits, enums, interfaces,
    braced namespaces, a mixed `.module`) on PHP 8.1, 8.3 (in the bed) and
    8.5.
  - The local patch never includes `.drupilot/runtime/` (INV10 test).
- **`DRUPILOT_LENIENT_DEPS`** (T-M4-17, AR-08, AR-28; default `off`): a
  comma-separated list of `drupal/<project>` packages lets contrib
  dependencies whose `drupal/core` constraint does not admit the test-bed's
  core install there anyway, so the module's tests can run.
  - `install-toolchain.sh` installs `mglaman/composer-drupal-lenient`
    (`.packages.lenient`, `^2.0`) and adds the packages to the bed's
    `extra.drupal-lenient.allowed-list`.
  - Only on a test-bed drupilot built; a warning skips it on your own project.
  - The list in effect (`lenient_packages`) is kept in the lock
    (`.lenient_packages`), in `install-toolchain.sh --json` and in
    `last-test.json` (`lenient`). The port report names it next to the
    preservation verdict, which it never changes (CC-14).
- **Raw tool reports and `findings.json`** (T-M4-05, AR-10, ADR 0022).
  - `scripts/ai/extract.sh --subject DIR [--stage S]` runs a stage's
    deterministic tools and keeps each report as
    `<state>/raw/<NN>-<stage>-<tool>.json`. The tools are Rector (a dry-run),
    PHPStan, PHPCS, port-safety, the signature scan and the metadata lint.
    Each report has root-relative paths, sorted keys and its timestamps under
    `meta`. The anchor of every reported line is computed once in the bed
    (`anchor.php`) and kept as one more raw file.
  - `scripts/ai/normalize-findings.sh` makes `findings.json` from them. Each
    finding has a stable id that never includes the line, a subject-relative
    file, an anchor, a symbol, a normalized message, an occurrence, a
    severity, a `scope` (`current` or `next-major`) and a `class`. Findings of
    different tools about the same symbol at the same anchor are merged into
    one, with `sources[]`. An error PHPStan reports in a trait (once per class
    that uses it) is one finding in the trait's file. `tools` records each
    tool's verdict (`ok`, `partial`, `failed`, `missing`), so a crashed tool
    never reads like a clean run, and a failing `classify-deprecations.sh`
    stops the script (exit 3) instead of losing the deprecation classes. The
    script needs only jq and a sha256 tool, so the goldens run on every CI
    leg; thousands of findings take seconds.
  - `schemas/findings.schema.json` is the contract (the `schemas` gate).
    `tests/golden/findings/` holds the lab recordings of `legacy_widgets`
    and the monorepo's `acme_core` and `acme_api`. Two recordings of the same
    tree gave the same bytes outside `meta`.
  - `docs/reference/state.md` documents the raw files and the findings.
- **The recipe catalog `config/recipes.json`** (T-M4-06, AR-11, ADR 0023):
  what drupilot does with each kind of finding.
  - `scripts/dev/gen-recipes.sh` generates it from the catalogs, the one
    source of truth (CC-33): `config/deprecations.json`,
    `config/port-checks.json` and the new `config/metadata-checks.json`.
    The `data` gate runs `--check`, so it is never edited by hand.
  - A catalog entry may carry a `recipe` block that turns it into a
    deterministic codemod or changes its lane. The scripts that read the
    catalogs ignore the block, so their outputs are unchanged.
  - 42 recipes: 30 for the AI, with the catalog's text as their template; 8
    for a person; 4 codemods.
  - The codemods:
    - a required `CacheableMetadata` hook parameter made optional
      (`hook_entity_operation`, `_alter`), only when the body does not use it;
    - a class name in a `.yml` file given the case of its file;
    - a submodule's `core_version_requirement` set to the module's own
      plan's range, never above the declared floor.
  - `scripts/ai/apply-recipe.sh` applies one codemod to one finding with the
    `ere-replace`, `yaml-edit` and `info-yml` engines. It writes only an
    exact change whose postconditions hold; anything else is `no-match`, and
    nothing changes.
  - Every codemod has `before/`, `after/` and `expect.json` fixtures in
    `tests/fixtures/recipes/`. `schemas/recipes.schema.json` validates the
    catalog, and `docs/reference/recipes.md` is generated from it.

### Changed
- **`scripts/dev/unit.sh` runs the tests in parallel** (`--jobs N`, default
  the CPUs, at most 8): the unit gate went from 12 minutes to under 2 on a
  developer machine, and the macOS CI leg, which runs the whole gate twice,
  no longer nears its timeout. Results print as each test ends; the `--json`
  summary keeps the tests' order.
  - The default follows the CPUs the process may use (`nproc`, a cgroup CPU
    quota). The per-test timeout grows when `--jobs` exceeds them
    (`--timeout`).
  - Each test runs in its own process group. Ctrl-C or a TERM sends TERM to
    the running tests, then KILL after 3 s, and waits for them: the run ends
    with exit 130 and leaves no process and no temp dir behind.
- **The `config-keys` gate fails** on an undeclared or inconsistent
  `DRUPILOT_*` key instead of warning (T-M3-14). `DRUPILOT_EXPERIMENTAL_D7`,
  which the D7-AUTO message names, is declared (environment only until the
  d7-assisted track lands).
- **rector.php is rendered from the upgrade plan** (T-M3-09, ADR 0019;
  template 5):
  - the plan's per-minor Drupal sets, `defined()`-filtered, with
    drupal-rector's bootstrap file (what its `DRUPAL_10` aggregate registers:
    the same Rector diffs, checked in the lab). When none of them resolves
    (drupal-rector missing), the config stops and `run-rector.sh` reports a
    crash (exit 3), as template 4 did, rather than a pass with nothing to
    change;
  - a backwards-compatibility block only when the plan enables it (`^10.3`
    and later floors: no needless `DeprecationHelper` wrapper);
  - the plan's PHP floor, and the skip list from `config/php/rules.json`.

  `render-templates.sh` and `run-rector.sh` take the subject's frozen plan,
  else a fresh draft (`plan_for_subject`); `render-templates.sh --json`
  reports which (`plan`). The sha256 of every render is kept in the root's
  lock (`.templates`), so an untouched render is regenerated when the plan
  moves and a hand-edited one never is (INV5). A render whose sha256 the lock
  lost counts as hand-edited until it is found equal to the current render
  again (its sha256 is then kept again). The Drupal 8/9 sets stay out until
  their hops are proven (T-M9-03).
- The `sigpipe` gate also flags `| cmp`, which stops reading at the first
  difference.
- **phpstan.neon is rendered from the upgrade plan** (T-M3-09, ADR 0020;
  template 3):
  - `phpVersion: {min, max}`: the plan's floor and PHP target, so PHPStan
    checks the code against every PHP it must run on;
  - `tmpDir: .phpstan-cache/<plan hash>`: one result cache per plan;
  - a profile. `compat` (the plan's, Phase 1) turns off phpstan-drupal's four
    opinion rules (dependency injection, entity storage injection, test class
    suffix, `@internal` parents): a minimal port makes no change they ask
    for, so Phase 1 PHPStan output loses those findings and nothing else
    (checked in the lab). `refactor` keeps every rule as phpstan-drupal ships
    it; `render-templates.sh --profile refactor` renders it, and
    `/drupilot-refactor` does so before its PHPStan run.

  `render-templates.sh --json` gains `phpstan_profile`. An untouched
  `phpstan.neon` follows the plan: `run-phpstan.sh` re-renders it, after a
  backup and with its profile, when the plan moved since (the port's final
  freeze; a refactor refreezes the final plan for the range it applies). A
  template-2 `phpstan.neon`, edited or not, is upgraded after a backup with its
  diff printed; a hand-edited template-3 one is kept.
- **Refactor: the core-target decision is a function of its own.**
  `strategy_decide` computes the decision for any target major (the ranges
  from `config/targets/<T>.json`, the older-major signals as the majors below
  T, the PHP floor never below the kept previous minor's `php_min`), and
  `recommend_core_target` renders `core-strategy.sh`'s JSON from it. For T=11
  every output is byte-identical: a 168-case matrix of subjects and scenarios
  (`tests/unit/core_strategy_matrix.sh`) pins the raw stdout captured before
  the change. For another target major the
  decision uses that target's PHP default (8.5 for 12), and `auto` keeps the
  previous major only while `config/targets/<T-1>.json` does not say `eol`
  (a data commit flips it, X15); the current data changes no output.
- `config/php/rules.json`: the four Rector rules `templates/rector.php.tmpl`
  skips for Drupal reasons (first-class callables, `#[\Override]` on
  methods, readonly properties and classes) are `deny` rows, and
  `p81-null-to-internal` moves from `compat` with `drupal_safe: false` to
  `deny`, so the data lists the whole skip list in the template's order.
- **Refactor: `scripts/lib/common.sh` is split into domain libs** (T-M3-10):
  `core`, `paths`, `config`, `lock`, `cache`, `subject`, `ddev`, `state`,
  `strategy`, `toolchain`, `git`, `interact` and `phpcs`, sourced in a fixed
  order with `plan` by `common.sh`, which every script still sources. The
  move is mechanical: no function is renamed, added, dropped or edited (the
  same 187 function definitions and 18 variables after sourcing, byte for
  byte), and `shellcheck` checks each lib on its own. The hooks source only
  the libs they use (`_DRUPILOT_LIBS`, checked by the `lib-defs` gate), so
  each hook starts faster than in 0.9 (p95 on a developer machine:
  `guard-contrib` 98 ms instead of 108, `post-edit-lint` 156 instead of 163,
  `session-detect-env` 956 instead of 960; T-M3-11).
- **Rector targets the PHP floor of the declared core range, not the PHP
  target** (T-M2-13, ADR 0002). `rector.php` (template marker 4) sets
  `->withPhpVersion(PhpVersion::PHP_<L>)` and `->withPhpSets(php<L>: true)`,
  where L is the lowest PHP the core range `core-strategy.sh` recommends and
  the `require.php` composer will enforce admit, never above
  `DRUPILOT_PHP_TARGET`: usually 8.1 for `^10 || ^11`, 8.3 for `^11`. A
  range leg the version data does not hold (a Drupal 9 leg kept as-is)
  leaves the floor to the enforced `require.php`, else the lowest PHP the
  data knows, with a warning; the compat pass's ceiling comes from the legs
  it does know. 0.9 applied the target's sets, so a port
  that kept Drupal 10 on a PHP 8.3 bed could gain PHP 8.3 syntax (a typed
  class constant, `AddTypeToConstRector`) that its PHP 8.1 sites cannot
  parse. For `^11` with a PHP 8.4 target the sets drop from php84 to php83,
  and the compat pass keeps the implicit-nullable fix. A `rector.php` from an
  older template is backed up and regenerated as before; an untouched
  current render of `rector.php` is also regenerated when its floor moves
  (the core target chosen at port time is not the one setup assumed), and
  one of `rector.php` or `rector-compat.php` (whose only input is the
  subject) when it was rendered for another subject of a shared test-bed
  (0.9 reported that as `differs`, exit 3); a hand-edited one is kept with a
  warning. A project's own `rector.php` without
  `withPhpVersion()` gets a warning.
- **Rector skips three more rules** (T-M2-14): `SleepToSerializeRector` and
  `WakeupToUnserializeRector` (`DependencySerializationTrait` defines
  `__sleep()`/`__wakeup()`) and
  `AddOverrideAttributeToOverriddenPropertiesRector` (`#[\Override]` on a
  property needs PHP 8.5), in both Rector configs, still filtered with
  `class_exists()`.
- `config/php/rules.json`: `p81-null-to-internal`
  (`NullToStrictStringFuncCallArgRector`) is `drupal_safe: false`, as the
  template has always skipped it.
- **The `legacy_widgets` H10 golden is re-recorded** (lab, Drupal 11.4.8, PHP
  8.3, cell 11 toolchain). The port patch, `phpstan.json` and `phpcs.json`
  are byte-identical to the M1 recording, and so is every file with the cell
  11 pins alone; `raw/rector-dryrun.json` gains `compat_files`,
  `compat_status`, `php_floor` and `php_ceiling`. The golden is pinned to a
  new data snapshot (the `rules.json` change above).
- **New test-beds get the cell 11 toolchain:** palantirnet/drupal-rector
  1.1.3, rector/rector 2.6.1 and phpstan/phpstan 2.2.16 (were 0.21.2, 2.5.2
  and 2.2.2); the other pins are unchanged. On `legacy_widgets` and
  autologout 8.x-1.4, on PHP 8.3 and 8.5, every port patch is byte-identical
  to 0.9's (spike AR-38). A project whose lock drupilot 0.9 wrote keeps 0.9's
  set, with a notice, until `install-toolchain.sh --source reference`
  refreshes it. A Drupal 12 test-bed resolves its toolchain from the ranges,
  with a warning, while cell 12 is provisional. `known_broken` now names
  rector 2.5.2 with any phpstan from 2.2.6 on, and drupal-rector 1.1.2 with
  rector 2.6.2 or later. The `drupal_rector` range of `config/defaults.json`
  is now `^1.1.3`, so a fallback to the ranges lands on the same set. With
  1.1.3, `convert-attributes.sh` gives byte-identical results on the
  fixtures, and it now converts a plugin annotation with a keyless value
  (`@FormElement("x")`), which 0.21.2 emitted without its argument and the
  script restored. Because 1.1.x matches an existing attribute by its short
  name, `convert-attributes.sh` now reads every name of an attribute group
  (`#[Cacheable, Block]`, also over several lines) when it decides which
  files to skip, and restores a file whose annotation was removed with no
  attribute added.
- `php_supported_for` reads `config/targets` and `config/php/versions.json`
  instead of a table in `common.sh`. Its answers are unchanged (a unit test
  pins the whole grid). `DRUPILOT_VERSION_DATA_DIR` (internal) points it at
  another copy of the data.
- The jq schema validator moved to `scripts/dev/jsonschema.jq` and learned
  `anyOf`, `pattern`, `propertyNames`, `minItems`, `minLength` and a schema
  as `additionalProperties`. Every `$ref` of every schema must resolve
  (checked once per schema, whatever the instances reach), and a pattern's
  final `$` no longer matches before a trailing newline (as in JSON
  Schema).
- The logo moved from `assets/` to `docs/assets/` (the README image paths
  follow), and `/drupilot-status` and `scripts/env/state.sh` cite
  `docs/reference/state.md` instead of a README section.
- CI installs `check-jsonschema` 0.38.2 on the Ubuntu and macOS legs.
- The `smoke in <image>` CI jobs may run 30 minutes (was 15): debian:12-slim
  runs the unit tests with mawk and jq 1.6, and the resolver's tests made it
  pass 15 minutes.
- The `checks` CI job may run 35 minutes (was 20): on macOS it runs the
  whole gate twice, and the second run hit the limit.
- **`subject_digest` uses algorithm 2** (AR-13, T-M4-02): it also hashes
  `*.twig`, `*.js` and `*.css`, after a header line, so **every existing
  digest changes once**. A test run, negative control, core matrix or
  metadata lint recorded by drupilot 0.9 no longer counts as fresh, until it
  is re-run:
  - `/drupilot-status`, the port report and the layer report show it stale
    (`stale_reason: "digest-algorithm"`);
  - the next step after a green 0.9 run is `/drupilot-test` again;
  - a failing 0.9 verdict (a regression, a failed core matrix) keeps blocking
    `port-summary --strict`, since its sources may be unchanged. A result on
    sources that changed since (`"sources-changed"`) still never blocks.

  `digest_freshness` gives the verdict for one record.
  Every record that keeps a `subject_digest` now keeps `digest_algo: 2` next
  to it (`last-test.json`, `test-baseline.json`, `negative-controls.json`,
  `core-matrix.json`, the Rector dry-run record and
  `lint-extension-metadata.sh --json`, whose v0.9.0 baseline captures list
  the change).
- **No timestamp outside `meta`** in the records drupilot compares or hashes
  (AR-13, DET-2): `rector-rules.json` keeps `generated_at` and the host path
  of the subject under `meta`; the `negative_controls` summary of
  `last-test.json` no longer carries each control's `at`, which moves to
  `meta.negative_controls` (and stays in `negative-controls.json`). The
  `last-test.json` schema accepts both shapes.
- **Deterministic tool invocation** (T-M4-03, 05-R2, DET-1, DET-2).
  - `run-rector.sh` runs every pass with Rector's JSON report
    (`--output-format=json --no-progress-bar`). The changed files and the rule
    hits come from its `file_diffs` and `applied_rectors` instead of parsing
    the console. A person still sees each diff and its rules on STDERR.
  - Its `--json` gains `file_diffs` (`[{pass, file, applied_rectors, diff}]`,
    sorted by file: Rector's parallel jobs end in any order) and `runner`.
    Rector's file errors are sorted too.
  - `run-phpstan.sh` and `run-phpcs.sh` sort their reports (files by path,
    messages by line) and add `drupilot.runner`. `runner` is `{runner:
    ddev|host, php_version, tool_version}`. Every 0.9 key is kept.
  - In deterministic mode, these cases exit 3 (`DRUPILOT_DETERMINISTIC=false`
    accepts them). This also applies to the attributes pass:
    - a tool whose installed version differs from the one the lock pins (the
      message names both remedies: restore the pins with `install-toolchain.sh`,
      or accept the installed versions with `lock-sync.sh`);
    - a host run on a root that has a DDEV project while the ddev CLI is
      there. Without ddev, the analyze profile runs on the host by plan.
  - A DET-1 refusal still prints the documented `--json` shape of exit 3 (Rector
    `errors[].pass` 0, PHPStan `crashed`, PHPCS `drupilot.error`, the attributes
    pass `status: "error"`). The prompts read it as "the tool did not run", not
    as a crash to repair with `--source reference`.
  - Under DDEV the digests checkout is copied under
    `<root>/.drupilot/digests/<sha>/`, so that pass runs in the bed instead of
    on the host's PHP. A config under the root is passed relative to it. An
    explicit `--config` outside the root is staged alone. A failed copy is a
    digests error (partial, exit 4).
  - Two lab runs give byte-identical canonical reports.
- **The `legacy_widgets` raw goldens are re-recorded** (T-M4-03, lab L-M4) with
  the deterministic tools. The H10 patch is unchanged.
  - `rector-dryrun.json` gains `file_diffs` and `runner`.
  - `phpstan.json` and `phpcs.json` gain `drupilot.runner`.
  - PHPStan's messages on one line come in identifier order.

### Deprecated
- **The 0.9 strategy vocabulary** (T-M3-07, CC-07), kept for all of 1.x and
  removed in 2.0.0. The `DRUPILOT_KEEP_D10` boolean and an old value in a
  `DRUPILOT_CHOICE_CORE_TARGET` pre-answer warn once per run. The setting's own
  old values are accepted silently, since drupilot still writes them for
  Drupal 11.
  - `DRUPILOT_KEEP_D10` (any 0.9 spelling of the boolean): use
    `DRUPILOT_CORE_TARGET_STRATEGY` (`keep-previous` / `target-only`). It is
    still honored only while the strategy is `auto`.
  - The strategy values `keep-d10` and `d11-only`: use `keep-previous` and
    `target-only`. For Drupal 11 drupilot still writes and prints the 0.9
    names (`core-strategy.sh --json`, the lock, `state.json`, a persisted
    core-target answer), so a 0.9 reader sees no change.
  - The `CORE_TARGET` tab's options are `auto`, `keep-previous`,
    `target-only` and `widest`. A 0.9 pre-answer
    (`DRUPILOT_CHOICE_CORE_TARGET=keep-d10`) is accepted without re-asking
    (`choice.sh`, `choose_one`); for Drupal 11 `choice.sh` still reports and
    persists it under its 0.9 name. The "Drupal 10 check" tab keeps its own
    `d11-only` option.
  - `make-issue.sh --d10-unverified`: use `--prev-major-unverified`.
  - The `d10_support` field is to get its `prev_major_support` twin in
    port-summary v2 (a later 1.x release).
  - `preflight.sh`'s strategy check accepts both vocabularies.

### Fixed
- **Intermittent wrong results and exit 141 under load** (the baseline-0.9
  flakes of PRs #11, #20 and #22): a pipeline ending in `head`, `grep -q` or
  an awk `exit` stops reading early, and under `pipefail` a producer still
  writing then dies of SIGPIPE, which fails the whole pipeline. That made
  `core-strategy.sh` call a `^10.3` -> `^10.3 || ^11` port a MAJOR bump on
  a busy Linux runner, and `lint-extension-metadata.sh` exit 141 with
  BusyBox `ls`. Every such pipeline (about 160) now reads its whole input.
- `install-toolchain.sh --json` failed with jq 1.6 (Debian 12, Ubuntu
  22.04: "syntax error, unexpected and"), so the command printed no JSON
  there; its `ok` value is now parenthesized. The `jq-compat` gate rejects
  that construct (an object value joined with `and`/`or` outside
  parentheses).
- `run-rector.sh` no longer counts a rule Rector only names in a "[WARNING]
  This skipped rule is never registered" notice as applied: `rules` and
  `rule_hits` (and the port manifest built from them) list the rules of the
  "Applied rules:" blocks only (`rector_applied_rules` in `common.sh`).
  Rector 2.6.1 prints that notice for `NullToStrictStringFuncCallArgRector`,
  which drupilot's template skips and its php81 set no longer lists.
- `tests/fixtures/legacy_widgets.EXPECTED.md` no longer calls the fixture valid
  Drupal 10.3 code without qualification: `WidgetImportForm` redeclares
  `FormBase`'s `$loggerFactory` as `private readonly` and typed, a fatal error
  when the class loads. The fixture is unchanged (part of H12).
- **`classify-deprecations.sh` no longer fails on a large PHPStan report.**
  It passed every message to jq as one argument. Linux caps an argument at
  128 KiB, so a module with a few hundred PHPStan errors stopped the script
  with "Argument list too long". The records now go through a file; the
  output is unchanged.
- **`run-rector.sh` now re-renders `rector-compat.php` for the module it
  runs on** (found by the T-M4-05 lab). On a test-bed shared by several
  modules, the compat pass kept the config rendered for the previous module,
  and Rector stopped the pass once that module's path was gone.
  - An untouched render for another module is now backed up and rendered
    again, as `rector.php` already was. An untouched render is one whose
    sha256 the lock keeps, or one that is byte for byte the template's.
  - A hand-edited copy is kept. A warning names any relative `withPaths()`
    path in it that does not exist.
  - Two config backups within the same second no longer share one name, in
    `run-rector.sh` and `render-templates.sh` alike (`config_backup` in
    `scripts/lib/paths.sh`).

## [0.9.2] - 2026-10-04

### Fixed
- `run-phpcs.sh` no longer exits 1 when PHPCS cannot load a project ruleset
  and its message names no ERROR line: an explicit ruleset is refused (exit
  2) and an auto-detected one falls back to Drupal,DrupalPractice, as
  documented.
- `run-phpunit.sh --coverage` checks for a coverage driver (PCOV, or Xdebug in
  coverage mode) first; without one the tests run without coverage flags,
  instead of a PHPUnit warning that a failOnWarning configuration turned into
  a false `regression` verdict.
- `ddev-up.sh` no longer leaves its saved docroot copy in the temp dir when it
  stops early; if the cached core already replaced the docroot, the copy is
  kept and its path reported.
- `/drupilot-status` loads in `claude -p` and without an approval prompt: its
  core-matrix line now calls `core_matrix_summary` instead of an inline jq
  program, which Claude Code refused as an unverifiable `bash -c` script.
- A port manifest whose patch path is relative to the Drupal root no longer
  makes the patch look missing in `port-summary.sh` and `/drupilot-status`.

## [0.9.1] - 2026-10-03

### Added
- **`DRUPILOT_HOME`** — drupilot's hidden data directory (state, lockfiles,
  caches); empty means `$XDG_DATA_HOME/drupilot` (`~/.local/share/drupilot`).
  Read from the environment only. It is the only new key of the 0.9.x line: it
  comes with the data-directory fix below. A leading `~` is expanded; any other
  relative value, like a relative `XDG_DATA_HOME`, is ignored, so hooks and
  scripts never resolve it against different working directories.
- **The frozen v0.9.0 baseline (`scripts/dev/baseline-0.9.sh`).** `--capture`
  ran the Docker-free scripts of the `v0.9.0` tag (a throwaway `git worktree`)
  on copies of the `legacy_widgets` and `monorepo` fixtures and committed their
  normalized output to `tests/baseline/v0.9.0/`: `lint-extension-metadata`,
  `check-port-safety`, `scan-signature-changes`, `detect-php-floor` and
  `core-strategy` per module, `layers`, `port-summary` on a canned state,
  `classify-`/`explain-deprecations` on a committed PHPStan sample (text and
  JSON), the files `render-templates` writes for PHP 8.3/8.4/8.5, the key sets
  of `preflight --json` and `detect-php --json`, the command frontmatter, the
  choices registry and the public `DRUPILOT_*` names. `--check` (the new smoke
  test `baseline`, so every CI leg) compares the checkout byte for byte; an
  intended difference is listed, pinned by its sha256, in
  `tests/baseline/v0.9.0/allowed-diffs.txt`, and `SHA256SUMS` pins the committed
  baseline files. A small input module with PHP 8.2/8.3/8.4 constructs covers
  the PHP floor scan, which no fixture exercised.

### Changed
- **`.claude-plugin/plugin.json` is the single version source.** The marketplace
  entry and `metadata` no longer repeat the version (Claude Code takes the
  manifest's, which wins anyway, and its docs advise against setting both); a
  release bumps `plugin.json` only.

### Fixed
- **Hooks and scripts kept their state in two different places.** The data
  directory came from `CLAUDE_PLUGIN_DATA` when set and from XDG otherwise, but
  Claude Code exports that variable to hooks and not to the Bash tool: the
  post-edit-lint hook never found the PHPCS ruleset `run-phpcs.sh` recorded, and
  linted with `Drupal,DrupalPractice` instead of the project's ruleset. The
  data directory is now `DRUPILOT_HOME`, else `$XDG_DATA_HOME/drupilot`, for
  both (the digests cache moves with it), and `CLAUDE_PLUGIN_DATA` is never
  read. The commands that write state copy, once, any state 0.9.0 left in
  Claude Code's per-plugin data directory (`copy_legacy_state_once`, right after
  their own preflight gate passes: copy-only, never overwriting, each file
  renamed into place only once fully copied, logged, with a
  `legacy-state-copied` marker written only once every file is copied; a retry
  imports only what is still pending); `/drupilot-status`, `/drupilot-doctor`,
  `/drupilot-patch`, the hooks and `preflight.sh` never copy. The state key of a
  path is unchanged, and the cached base core moves with the data dir too.
  `smoke.sh` no longer exports `CLAUDE_PLUGIN_DATA` (that is what hid the bug)
  and gained the `data-dir` and `legacy-state` tests.
- **The GitLab PAT was on curl's command line.** `open-mr.sh` passed it as
  `-H "PRIVATE-TOKEN: ..."`, visible to any local user through `ps` or `/proc`
  while the request ran. curl now reads that header as a config on STDIN
  (`-K -`, written by the shell's builtin `printf`), or from a mode-0600 temp
  file removed right after when curl cannot read STDIN. A token with a line
  break (a CRLF file, a pasted value) is cut at it, with a warning, so it can
  never add a second config line. A smoke test with a stub curl checks that the
  PAT is on no argv and in no output.
- **PHP 8.5 was described as "not confirmed on any Drupal 11 branch".** Drupal
  supports PHP 8.5 from 11.3 on, not on 11.2 or earlier (drupal.org PHP
  requirements, read through its api-d7 JSON). The new helper
  `php_supported_for <core-minor> <php>` answers `yes`, `no` or `unknown` per
  minor. With an 8.5 target, `/drupilot-setup` (`ddev-up.sh`) now warns, when it
  creates the project, if the lock-pinned core, or else the lowest minor the
  Drupal target admits, is older than 11.3 (a dev branch or stability flag is
  not guessed), and again when the installed core is older. The caveat text of
  the setup tab, the session hook, `detect-php`, `run-rector`, the skills, the
  agents and the READMEs now says "PHP 8.5 needs Drupal 11.3 or later".
  Unchanged: `php_target_unconfirmed` stays true for 8.5 (it now means no Rector
  `php85` set is assumed, so Rector still applies `php84`), `detect-php --json`
  keeps its `unconfirmed` key and values, and the PHP_TARGET tab keeps its
  header, options and default; the rendered `rector.php` is byte-identical.
- **The Twig `spaceless` advice pointed at a deprecated filter.** The
  explainer (`config/deprecations.json`), the `minimal-port` skill and
  `/drupilot-port` suggested `{% apply spaceless %}` / the `spaceless` filter,
  which Twig deprecated in 3.12. They now recommend whitespace control
  (`{%- -%}`, `{{- -}}`) and say not to move to the filter.
- **`detect-php-floor.sh` failed on BusyBox (Alpine).** It selected the PHP
  files with `grep --include`, which BusyBox grep does not have: the script
  exited 2 with no output, so `core-strategy.sh` lost the detected PHP floor
  (`require_php` fell back to the target). The files are now selected with
  `find ... -exec grep ... {} +`, and the first signal is the first hit in path
  and line order instead of the directory walk order. `convert-attributes.sh`
  found no custom plugin manager there for the same reason. The `portability`
  gate of `scripts/dev/check.sh` now rejects any `--include`, `--exclude` or
  `--exclude-dir` option on a line where tar, rsync, curl, phpcs or phpcbf is
  not the command (another tool's option, or a grep pattern after `--`, carries
  `# portability-ok`).

## [0.9.0] - 2026-10-03

### Added
- **`scripts/dev/check.sh` — one local developer gate for the plugin.** Runs
  `claude plugin validate .`, `bash -n` and an executable-bit check on every
  script, `shellcheck -S warning`, a lint that rejects `<placeholder>` literals
  inside `` !`...` `` exec spans of commands/skills/agents (they run at command
  load, before the model can substitute them), renders every template with dummy
  values and runs `xmllint --noout` on the XML outputs, and `jq empty` on every
  JSON manifest/config. `--json` summary, `--only`/`--skip`, `--allow-fail` /
  `--allow-known` for failures already tracked, `--ci` to make missing optional
  tools fatal. Read-only and bash 3.2-compatible.
- **Docker-free smoke tests and CI.** `scripts/dev/smoke.sh` runs the scripts
  that need no Docker, DDEV or PHP against fixtures now shipped in
  `tests/fixtures/` (`legacy_widgets` and a small `monorepo` module set, no
  vendor, with their `*.EXPECTED.md`) and asserts the recorded results: every
  script's `--help`, `preflight --profile analyze --json` (exit consistent with
  `ready.analyze`), `detect-php` (default and overridden target), `next-step`
  (setup/doctor), the hooks' fail-safe contract, `check-port-safety` (the
  pre-existing findings, then a removed `implements
  ContainerFactoryPluginInterface` turns `plugin-di` red and, in diff mode,
  "introduced"), `scan-signature-changes` for two floors,
  `lint-extension-metadata` per module, `layers`, and two `--dry-run`s that
  must write nothing. It works on temp copies with its own `HOME`/plugin data
  and every `DRUPILOT_*` unset, runs each script with the same `$BASH` (so it
  proves stock bash 3.2), and has `--only`/`--skip`/`--list`/`--json`/`--keep`.
  `check.sh` runs it as the optional `smoke` gate (`--smoke`, implied by
  `--ci`). The new `.github/workflows/ci.yml` runs `check.sh --ci` on Ubuntu
  and macOS (again under macOS's stock `/bin/bash` 3.2), `check.sh --smoke` in
  the Alpine `bash:3.2` image (BusyBox tools) and in `debian:12-slim` (mawk,
  jq 1.6 — this leg found the jq 1.6 breakage fixed below), and `claude plugin validate .`
  in its own job after `npm install -g @anthropic-ai/claude-code` (no login
  needed). Why: the portability and analyzer guarantees were only checked by
  hand on one Linux box; a regression on macOS/BSD tools or in a scanner's
  verdict now fails a build instead of a user's port.
- **`.shellcheckrc`** so `shellcheck` resolves `common.sh` from both group
  scripts and hook scripts; no check is disabled globally.
- **Portability helpers in `common.sh`:** `lc` (lowercase, replaces bash 4's
  `${x,,}`), `sed_inplace FILE EXPR...` (temp file + `cat >`, keeps inode and
  mode, leaves the file untouched on failure — replaces `sed -i`, whose argument
  differs between GNU and BSD sed), and `ddev_addons_installed` /
  `ddev_addon_version` (read `ddev add-on list --installed -j`, falling back to
  `.ddev/addon-metadata/*/manifest.yaml`).
- **`portability` gate in `scripts/dev/check.sh`.** Rejects bash 4-only and
  GNU-only constructs in the scripts (`${x,,}`, `declare -A`, `mapfile`,
  `sed -i`, `readlink -f`, `realpath`, `grep -P`, `date -d`, `xargs -r`,
  `stat -c`, `find -printf`, `envsubst`); a line can opt out with a trailing
  `# portability-ok` and a reason.
- **`bash` check in `preflight.sh`** (soft, shown by `/drupilot-doctor`): reports
  the bash version from `BASH_VERSINFO` against the supported minimum 3.2.
- **`scripts/env/render-templates.sh` — deterministic config rendering.** Renders
  `rector.php`, `phpstan.neon`, `phpcs.xml.dist` and `.ddev/config.testing.yaml`
  at the Drupal root from the templates (`--root`/`--subject`/`--subject-path`,
  `--only`, `--set KEY=VALUE`, `--dry-run`, `--json`). Each output is validated
  before it is written (no token left; `xmllint --noout`, or `phpcs --standard=<file>
  -e`, for the ruleset; `php -l` for `rector.php`, inside DDEV when it is up). It is
  idempotent and never clobbers a hand-edited config: a file that differs is left
  alone with its diff on stderr (exit 3) unless `--force`, which backs it up to
  `.drupilot/backups/` first. `{{WEBDRIVER_HOST}}` is read from the Selenium
  add-on's compose file. `/drupilot-setup` Step 4 and the `ddev-environment` skill
  call it instead of substituting tokens model-side.
- **`render_template TPL DEST KEY=VALUE...` in `common.sh`.** Literal token
  substitution (awk, values passed through the environment), so a path containing
  `|`, `&` or a backslash can no longer break the render. `run-rector.sh` uses it
  too (byte-identical output for ordinary paths).
- **`run-phpstan.sh --json` adds a `drupilot` key** — `{status:
  clean|findings|crashed, exit_code, phpstan_exit_code, notices, crash}` — next to
  PHPStan's native report.
- **`special-vars` gate in `scripts/dev/check.sh`.** Rejects any script that
  assigns, declares, `read`s into or loops over a bash special variable (`GROUPS`,
  `RANDOM`, `SECONDS`, `LINENO`, `UID`, `EUID`, `PPID`, `BASHPID`, `HOSTNAME`,
  `PWD`, `PIPESTATUS`, `BASH_SOURCE`, ...), whose assignment bash silently ignores
  or overrides; a line can opt out with a trailing `# special-var-ok` and a reason.
  An audit of every script found no other collision than the one fixed below.
- **Core/test-toolchain helpers in `common.sh`:** `drupal_core_version` (installed
  `drupal/core`, from `composer.lock` or `core/lib/Drupal.php`),
  `core_dev_requirement` (the `drupal/core-dev` requirement matched to it, e.g.
  `drupal/core-dev:~11.4.8`; exact for pre-release/dev cores) and
  `phpunit_available` (checks `vendor/bin/phpunit` through `drupal_runner`).
  `config/defaults.json` lists `.packages.core_dev`, so `lock-sync.sh` now freezes
  its exact version too.
- **`last-test.json` records why and what:** `blocked_reason` (why tests that
  exist could not run), `subject_has_tests` and `groups_with_tests`.
- **`scripts/env/install-toolchain.sh` — deterministic dev-toolchain installer.**
  Replaces the hand-written `ddev composer require --dev ...` of `/drupilot-setup`
  (step 3c) and the `ddev-environment` skill. Installs drupal-rector,
  `rector/rector`, PHPStan + extensions, coder, `drupal/core-dev` (matched to the
  installed core) and optionally upgrade_status in one `ddev composer require
  --dev -W`, pinned to the project lock when it holds the whole known-good set,
  otherwise to the shipped reference set (`--source auto|reference|range`,
  `DRUPILOT_TOOLCHAIN_SOURCE`); retries once with the ranges when the pinned set
  does not resolve. Then runs a smoke test and re-syncs the lock. Idempotent (no
  Composer run when everything is already at its pinned version); `--dry-run`,
  `--smoke-only`, `--json`; exit 3 when the installed toolchain is broken.
- **Known-good toolchain matrix, `config/toolchain-reference.json`** — the
  distributed reference lock: drupal-rector 0.21.2, rector 2.5.2, PHPStan 2.2.2,
  extension-installer 1.4.3, phpstan-drupal 2.2.2, deprecation-rules 2.0.5,
  coder 8.3.31, Drush 13.8.0, upgrade_status 4.3.10, verified together in a fresh
  DDEV Drupal 11.4.8 / PHP 8.3 test-bed (install, smoke test, Rector dry-run on
  autologout 8.x-1.4, PHPStan, PHPCS). A fresh sandbox created after a broken
  upstream release still gets a working set. It also documents the two known
  broken combinations.
- **Toolchain helpers in `common.sh`:** `rector_smoke` (a Rector dry-run of a
  trivial file with the Drupal 10 set + `phpstan --version`, through DDEV),
  `rector_output_ok` / `rector_error_excerpt` (shared Rector crash detection),
  `toolchain_diagnostics` (installed vs known-good versions + the fix),
  `toolchain_reference_version`, `installed_package_version`.
- **`DRUPILOT_TOOLCHAIN_SOURCE`** (`auto` / `reference` / `range`), validated
  non-fatally by `preflight.sh`.
- **`scripts/analysis/check-port-safety.sh` — deterministic post-port safety
  checks** (read-only, no toolchain, bash 3.2 + POSIX awk). Flags a class with
  `create()` that does not implement `ContainerFactoryPluginInterface` (4-arg) /
  `ContainerInjectionInterface` (1-arg) itself or through its real ancestry, read
  from the Drupal root's core/contrib (a small verified fallback list covers a
  missing root); a `use` the port removed while still referenced; `new self(` in
  `create()` of a non-final class; first-class callables/closures under Form/Render
  API callback keys; `private`/`readonly` properties in classes using
  `DependencySerializationTrait`; `#[\Override]` while the core range still spans
  Drupal 10; and services/routing/PSR-4 class names whose case differs from the
  file. Every finding is attributed to the port or marked pre-existing by diffing
  against the same base as `make-patch.sh --local` (`--base REF` overrides), and
  its severity comes from the per-check matrix in the new `config/port-checks.json`.
  Tagged lines or `--json`; exit 3 on error findings. Wired as a gate into
  `/drupilot-port` (Step 7), `/drupilot-refactor` (Step 5), the `minimal-port` /
  `full-refactor` skills and the orchestrator's definition of done.
- **`scripts/lib/php-scan.sh`** — shared PHP class heuristics (namespace, imports,
  class headers, traits, methods with parameter counts, properties incl. promoted
  ones, `new self`/`new static`, `#[\Override]`) for analysis scripts.
- **`git_port_base_ref` in `common.sh`** — the pre-port git base, shared by
  `make-patch.sh --local` and the port-safety checks so both judge the same
  diff. It resolves the fork point (the upstream only when it is an ancestor of
  `HEAD`, else the closest of `origin/HEAD`, the other remote branches and the
  nearest tag); see the "`make-patch.sh --local` diffed against an unrelated
  base" entry under Fixed.
- **Port-safety rules in the prompts** (`minimal-port` §0, `full-refactor`,
  `drupal-port-orchestrator`): never remove `ContainerFactoryPluginInterface` from
  a class with `create()` (`QueueWorkerBase`, `BlockBase`, `FilterBase`,
  `ActionBase`, `ConditionPluginBase`, core `PluginBase` do not provide it), never
  drop a still-referenced `use`, never `new static` → `new self`, never "fix" a
  sandbox PHPStan finding by changing semantics (sandbox-only findings are
  documented), symbols newer than the kept core floor only via
  `DeprecationHelper::backwardsCompatibleCall()`, promoted services `protected`
  (never `private`/`readonly`) in serialized classes, `#[\Override]` only when
  true on every declared core.
- **`run-rector.sh --json` gains `rules`** — the sorted rule names from Rector's
  "Applied rules" sections (existing keys unchanged).
- **Port report: optional `port_safety` manifest section** (the checker's JSON)
  rendered as "Port-safety checks"; `config/deprecations.json` explains the
  checker's tags (new `port-safety` / `serialization` categories).
- **`scripts/env/origin-hygiene.sh` — prove drupilot left the origin checkout
  clean.** `--snapshot` records the origin's `git status --porcelain` (or its
  top-level entries outside git) in the hidden state dir keyed by the Drupal root;
  `--check` reports each new untracked entry as drupilot-attributable (`.ddev/`,
  `vendor/`, `node_modules/`, `.phpstan-cache/`, `.drupilot*`, generated config,
  drupilot patches, symlinks escaping the tree) or other, plus tracked changes
  (unexpected for `copy`). Report-only: exit 0, never deletes anything.
  `place-subject.sh` snapshots before placing, `/drupilot-setup` does it for an
  in-place subject, `/drupilot-status` shows a one-line verdict and the port report
  gains an "Origin hygiene" section (or reads a manifest `origin_hygiene` key).
- **`resolve-workspace.sh` JSON gains `residue` and `residual_ddev`** (additive,
  report-only): untracked `.ddev/`, `vendor/`, `node_modules/`, `.phpstan-cache/`,
  `.drupilot/` and out-of-tree symlinks in the subject, and whether the "root" is
  only a leftover module-at-root `.ddev/` sandbox.
- **`ddev-up.sh --json`** prints `{project_dir, project_name, php_version,
  primary_url, drupal_target}` on stdout; `project_name` is the configured one
  when the project already exists.
- **`place-subject.sh --no-exclude`** restores the old verbatim `copy`.
- **`common.sh`: `git_local_exclude DIR PATTERN...`** (idempotent append to the
  repo's local `.git/info/exclude`) and **`symlink_escapes TREE REL`** (portable,
  lexical out-of-tree symlink test).
- **Catalog of Drupal 10 -> 11 breaking signature changes** (`.signature_changes`
  in `config/deprecations.json`, next to the explainer map so both share the
  change-records search and the `[signature:<id>]` explainer entries). Every
  entry was checked against core source on each branch it names and records the
  file it was verified in: `ConfigFormBase::__construct()` +
  `TypedConfigManagerInterface` (optional 10.2, required 11.0),
  `ContentTranslationController::__construct()` + `TimeInterface` (10.3 / 11.0),
  `EntityInterface::getOriginal(): ?static` and `setOriginal()` (11.2),
  `ContentEntityStorageBase::buildRevisionCacheId($id): string` (11.3), and the
  `$cacheability` parameter of `hook_entity_operation()` and
  `hook_entity_operation_alter()` (11.3), each with its fix and Drupal 10 note.
- **`scripts/analysis/scan-signature-changes.sh`** (`--subject DIR [--core-req
  STR] [--core-floor X.Y] [--drupal-root DIR] [--json]`, read-only, no
  toolchain). Flags a direct subclass passing too few arguments to the changed
  constructor, a module method that collides with one core added later (error if
  incompatible or carrying `#[\Override]` below the floor, warning if it silently
  becomes an override), a hook implementation (procedural or `#[Hook]`) that
  requires a parameter older cores never pass, and calls of APIs newer than the
  floor. Severities follow the floor of the declared `core_version_requirement`,
  so a change that is fine for `^11.3` is an error for `^10 || ^11`. Ancestry is
  read from the Drupal root, else from each entry's verified `known_descendants`.
  Exit 3 on error findings. Wired into `/drupilot-assess` (manual items of the
  plan and the effort count), `/drupilot-port` and `/drupilot-refactor` (gate,
  must exit 0), the minimal-port, viability-assessment and full-refactor skills,
  the orchestrator and analyst agents, and `port-report.sh` (manifest key
  `signature_changes`, plus a "Core signature changes" explainer group).
- **`common.sh`: `core_floor_from_requirement`** (`'^10 || ^11'` -> `10.0`,
  `'^10.3 || ^11'` -> `10.3`, `'^11'` -> `11.0`; empty when unreadable).
- **`php-scan.sh` records `SIG`, `PCALL`, `FUNC` and `HOOK`** (method
  visibility/arity/return type, `parent::m()` argument counts, top-level
  functions, `#[Hook]` methods), and now hosts the class index and ancestry
  resolver (`php_scan_index`, `php_scan_extmap`, `php_class_file`,
  `php_class_records`, `php_chain_has`) that `check-port-safety.sh` had inline,
  so both scanners share one implementation (its output is unchanged).
- **Soft-deprecation policy: `DRUPILOT_SOFT_DEPRECATIONS`** (`report` default |
  `defer` | `fix`; `config/defaults.json`, validated non-fatally by
  `preflight.sh`). A deprecation is *hard* when it is removed in a Drupal major
  <= the target major (e.g. `user_roles()`/`user_role_names()`, removed in
  11.0.0) and *soft* when it is removed only in a later one (e.g.
  `user_load_by_name()`, `user_load_by_mail()`, `text_summary()`,
  `check_markup()`, `user_cookie_save()`/`user_cookie_delete()`: deprecated in
  11.4.0, removed from 13.0.0, so they work on every Drupal 11 core). Hard ones
  are always fixed in Phase 1; soft ones are listed (`report`), deferred to
  Phase 2 (`defer`) or fixed (`fix`) only in a way that keeps the declared core
  floor working: directly when the replacement exists there, through
  `DeprecationHelper::backwardsCompatibleCall()` when it exists only on newer
  cores (the `TextSummary` service is 11.4+), deferred otherwise. Phase 2
  removes soft ones too, still respecting the floor.
- **`scripts/analysis/classify-deprecations.sh`** (`[--file F | -] [--subject
  DIR] [--core-req STR] [--core-floor X.Y] [--target-major N] [--policy P]
  [--phase port|refactor] [--json]`, read-only, no toolchain). Reads PHPStan's
  JSON (or its plain-text table) and returns `{policy, blocking, counts,
  symbols, hard, soft, unknown}` with, per item, deprecated-in/removed-in (from
  the message), the replacement, the first core that has it, whether the
  declared core floor has it, the effort and the Phase 1 action
  (`fix`/`fix-guarded`/`report`/`defer`). A deprecation without a readable Drupal
  removal version, or a missing function the catalog does not date, is
  *unknown* and counted as blocking.
- **`lifecycle` catalog in `config/deprecations.json`** for the classifier:
  replacement, `replacement_since`, effort and removal facts for the eight
  functions above, each checked against core source on 10.3.x-12.0.x and the
  installed 11.4.8 core (PHPStan reports a removed function only as
  "Function user_roles not found.", without versions). Explainer entries for
  them too (groups "Soft deprecations" and "Removed APIs").
- **Soft deprecations in the reports.** `port-report.sh` renders a "Soft
  deprecations (policy: X)" table (symbol, deprecated in, removed in, effort,
  occurrences, action) from the new optional manifest key `soft_deprecations`;
  the viability report template splits the PHPStan count into hard / soft /
  unknown and adds the same table. Wired into the minimal-port,
  viability-assessment and full-refactor skills, the orchestrator and analyst
  agents and `/drupilot-port` / `/drupilot-assess`.
- **Project PHPCS ruleset in `run-phpcs.sh`.** It now lints with the subject's
  own `.phpcs.xml` / `phpcs.xml` / `.phpcs.xml.dist` / `phpcs.xml.dist` (PHPCS's
  discovery order), looked up from the subject to the Drupal root, then to its
  git top level, then in the origin checkout of a copy placement. drupilot's
  generated `phpcs.xml.dist` never counts. A ruleset PHPCS cannot load (e.g. it
  references PHPCompatibility, not installed in the test-bed) is probed with
  `phpcs -e` and falls back to `Drupal,DrupalPractice` with a warning. New
  `--ruleset auto|drupilot|PATH` and `--test-version` options, new keys
  `DRUPILOT_PHPCS_RULESET` (default `auto`; `drupilot` restores the old
  behavior) and `DRUPILOT_PHPCS_TEST_VERSION`. `--json` adds a `drupilot` key
  (`ruleset`, `source`, `location`, `fallback_reason`, `test_version`,
  `test_version_source`); `.totals`/`.files` are unchanged. The resolution is
  kept in the hidden state dir (`phpcs-ruleset.json`). New helpers
  `find_phpcs_ruleset`, `phpcs_ruleset_is_drupilot`, `phpcs_ruleset_value`.
- **`scripts/contrib/git-hooks.sh` — the repository's git hooks.** Detects
  GrumPHP (also via `composer.json` `extra.grumphp.config-default-path`), husky,
  lefthook, pre-commit, CaptainHook, `core.hooksPath` and plain `.git/hooks`
  scripts, the commit hooks git would really run, each task's drupilot
  equivalent and the tasks with none (`uncovered`). `--run-equivalents` runs
  phpcs (with the hook's ruleset file), PHPStan (with the hook's level),
  `php -l` on the changed PHP files and `composer validate` through
  `drupal_runner`, plus PHPUnit with `--with-tests`, and records the outcome in
  `hooks-substitution.json`; exit 3 when one fails. `--dry-run` prints the plan.
  New helpers `git_hooks_dir`, `git_active_commit_hooks`.
- **Hook policy in the flow: never normalize `--no-verify`.** The minimal-port,
  full-refactor and drupal-contribution skills, `/drupilot-port`, the
  orchestrator and the contrib-publisher agent check the hooks before a commit,
  let them run, and substitute them only when a hook cannot complete in the
  session, recording which validations replaced it.
- **`guard-contrib` asks before a commit that skips the git hooks.** A
  `git commit` with `--no-verify`, `-n` in a short-option cluster, or
  `git -c core.hooksPath=…` now gets `permissionDecision: "ask"` when the
  repository has an installed pre-commit or commit-msg hook, in every
  contribution mode and in autonomous mode. Quoted messages are ignored
  (`-m "-n"` is not a flag). New key `DRUPILOT_HOOKS_GUARD` (`ask` | `off`),
  validated by `preflight.sh`. The push / Merge Request guard is unchanged.
- **Verification section in `port-report.md`.** Lists the PHPCS ruleset used
  (project, explicit, drupilot default, or the fallback and why, plus the
  testVersion) and the commit hooks (ran normally, or what substituted them and
  what stayed uncovered), from the new optional manifest key `verification`
  (`phpcs_ruleset`, `commit_hooks`) or the state files the scripts write.
- **Core matrix: `scripts/analysis/verify-core-matrix.sh` verifies the Drupal 10
  half of `^10 || ^11`.** The validate loop only ever saw the Drupal 11 test-bed,
  so a kept `^10` stayed "declared, not verified". The new script runs the same
  PHPStan (phpstan-drupal + deprecation rules + every PHPStan extension of the
  test-bed, at its exact versions) and `php -l` against a cached reference core
  per extra leg — the latest 10.x for `^10`, 10.3.x for `^10.3 || ^11`, or an
  explicit `--cores 10.3,11` — built once through `ddev exec composer` in
  `<drupal_root>/.drupilot/cores/` (drupal/recommended-project +
  core-recommended pinned to the leg, plus the test runtime that core's
  `drupal/core-dev` requires; never the host PHP). Each leg is compared with the
  Drupal 11 baseline: an error only one leg has is an incompatibility (e.g.
  "has #[\Override] attribute but does not override any method" on
  `buildRevisionCacheId()`, which only 11.3+ core declares; `RequirementSeverity`,
  a class only 11.2+ ships), while deprecations, contrib classes the reference
  core lacks (`sandbox_missing_dependency`), test-only typing differences and
  phpstan-drupal advisory rules never fail a leg. `php -l` also runs on each
  leg's lowest PHP (its core's minimum or the subject's `require.php` floor) in a
  `php:X.Y-cli` container, which checks the detected PHP floor for real. The
  reference version is frozen in the lockfile (`.verify_cores`) in deterministic
  mode; no network leaves the leg `skipped` (exit 0) and Drupal 10 support
  `declared-not-verified`. `--json`, `--dry-run`, `--refresh`, `--level`,
  `--lint-floor auto|off`; the result persists to `core-matrix.json` with a
  digest of the subject's sources so later readers can tell when it is stale.
  New key `DRUPILOT_VERIFY_CORES` (`auto` | `off` | a leg list), validated by
  `preflight.sh`. Wired into `/drupilot-port` (Step 7b, with a "Drupal 10 check"
  tab on failure), `/drupilot-refactor` while `^10` is kept, the `minimal-port`
  (§6a) and `full-refactor` skills, the orchestrator and `/drupilot-status`.
- **`d10_support: verified-static` and `failed`.** `core-strategy.sh` adds a
  `verify_cores` field (the legs the recommended requirement declares) and points
  its Drupal 10 warning at the matrix. `port-report.sh` reads
  `verification.core_matrix` (or the state file), renders a "Core matrix" section
  and table row, upgrades a `declared-not-verified` manifest to the matrix verdict
  when the result is fresh, and marks a stale one. `make-issue.sh --d10-unverified`
  narrows the remaining task to "run the suite on Drupal 10" when the static
  check passed and adds a "fix the Drupal 10 incompatibilities, or drop `^10`"
  task when it failed (new `--core-matrix FILE`; `d10_verification` in `--json`).
  New `common.sh` helpers `core_verify_legs`, `subject_digest`,
  `core_matrix_file`, `core_matrix_fresh`.
- **Negative controls for new tests (`scripts/tests/negative-control.sh`).** A
  test only proves something once it has been seen to fail. The script undoes
  the production change a test guards (`--revert-to REF --path FILE...`, or a
  minimal `--mutation-patch`), requires the test to go red, restores the files
  and checks them byte for byte with `git hash-object`, then requires it to go
  green: `effective` (exit 0), `ineffective` (exit 4 — the test stays green
  without its change), `error` (exit 1 — the filter ran no test, the restored
  code is not green, or the restore was not identical), exit 2 when the test
  environment is blocked. It backs up and hashes every target before touching
  it, restores from an EXIT/INT/TERM trap, refuses paths under `tests/`, outside
  the subject or in a git conflict, never overwrites a file someone edited during
  the run, and runs PHPUnit with `--no-record` so `last-test.json` and the
  baseline are never touched. `--json`, `--dry-run`, `--label`, `--manifest`.
  Results go to `negative-controls.json` (state dir), into `last-test.json`'s
  `negative_controls` summary and into a "Negative controls" table and
  Verification row in `port-report.md` (an ineffective control is flagged, a
  control on code that changed since is marked stale). The test-adaptation and
  full-refactor skills, the drupal-test-engineer agent and `/drupilot-test` /
  `/drupilot-refactor` now require an effective control for every new test.
  New `common.sh` helpers `negative_controls_file` and
  `negative_controls_summary`.
- **Pre-existing test failures are told apart from regressions.**
  `run-phpunit.sh --baseline` records the suite on the untouched code as
  `test-baseline.json` (exit 0 even when red; `last-test.json` untouched), and
  `--baseline-from-last` promotes the last run (e.g. before a refactor). Every
  later run compares each failing test with it: failed before and now →
  `pre-existing`, passed before → regression, not in the baseline → regression
  unless its whole baseline group crashed. A new preservation verdict,
  `pre-existing-failures`, applies when tests fail but none regressed; the
  record's `baseline` object lists `regressions`, `pre_existing` (with
  `message_changed` when a test now fails differently) and `fixed`, and
  `port-report.md`, `/drupilot-status` and `next-step.sh` report it as not
  green. `/drupilot-port`, the minimal-port skill and the orchestrator take the
  baseline before Rector. `--no-baseline` ignores it for one run. Existing
  verdict values keep their meaning.
- **Per-test results in `last-test.json`.** Each group runs with PHPUnit's
  `--log-junit` (a scratch file under `<drupal_root>/.drupilot/phpunit/`), so the
  record carries `tests` (every executed test with pass/fail/error/skipped and
  the first line of its failure), `group_results`, `executed`, `filter`,
  `recorded_at`, `subject_digest` and `git_head`. New `--no-record` and
  `--result-file FILE` options.
- **Per-module state registry (`scripts/env/state.sh`) and
  `/drupilot-status --all`.** Each module/theme's `state.json` (hidden state
  dir, next to `assess.json`) now carries, besides the stages, a snapshot of
  `effort`, `git` (branch, commit, dirty), `toolchain` (from the lock),
  `tests` (status, preservation, `fresh`), `core_matrix` (verdict,
  `d10_support`, `fresh`), the last `patch`, `origin`/`placement`,
  `ddev_project` and `created`/`updated` (schema version 1, documented in
  README "Per-module state" and `common.sh`). It stays hidden machine state on
  purpose: it survives `git clean` and a rebuilt test-bed, never leaks into a
  patch, and one data dir lets a portfolio view find every record.
  - `state.sh record --stage S [--effort X] [--force]`, `refresh`, `show` and
    `list [--root DIR]... [--registry FILE] [--subject DIR]...`; `show`/`list`
    are read-only, print a table on stderr and JSON on stdout (`--json`), and
    give each subject the `next` step `next-step.sh` recommends.
  - Writers: `run-phpunit.sh` refreshes the test verdict after every recorded
    run (so a red run after a green one is never shown as green),
    `verify-core-matrix.sh` the matrix verdict, `make-patch.sh` the patch
    (`local` / `issue` / `contribution`); `/drupilot-setup`,
    `/drupilot-assess` and `/drupilot-contribute` (and the orchestrator,
    analyst skill) record `setup`, `assessed` and `contributed`.
  - `/drupilot-status --all [dir|registry-file|everything]` tabulates module,
    workspace, stage, effort, preservation, Drupal 10 verdict, branch@commit,
    core, updated and next step; `/drupilot-status` shows the merged record.
  - A module with only pre-registry records (`assess.json`, `last-test.json`)
    is still listed by `--root`/`--subject`; an assessment on file backfills
    the `assessed` stage.
- **`/drupilot-layers` — port a set of modules in dependency order.**
  `scripts/analysis/layers.sh --dir DIR [--json] [--edges all|declared]
  [--dot]` reads every `*.info.yml` `dependencies:` and `composer.json`
  `drupal/*` requirement of a set (a monorepo's `web/modules/custom`, a folder
  of modules), adds the dependencies the code really uses, and orders the set
  topologically. Layer 0 depends on nothing in the set, and a dependency cycle
  stays together in one layer.
  - Undeclared dependencies are found by scanning `Drupal\X\` classes, `@id`
    services, routes, libraries, plugin ids and config dependencies against what
    the other modules define.
  - Each undeclared dependency gets a proposed entry, with its `file:line`
    evidence: `<project>:<module>` for a module of the set, `drupal:<module>`
    for core, `<module>:<module>` for contrib (flagged "verify the project").
  - A use guarded by `moduleExists()`, `config/optional` or `@?service` is
    optional: it is not proposed and does not order the layers.
  - The `early` list names the modules whose declared dependencies alone would
    have them ported too early.
  - It saves `layers.json` (hidden state) and `layers.md` (`.drupilot/`).
  - The command: `plan` (read-only) presents all of this. `run` ports one
    layer, one module at a time, through the orchestrator's normal flow, with
    autonomy respected: no confirmations in autonomous mode, never a push or a
    contribution, never an `info.yml` edit without confirmation.
  - `scripts/analysis/layer-report.sh --dir DIR [--layer N]` writes the
    consolidated `layer-N-report.md`. It has one row per module (stage, effort,
    preservation, Drupal 10 verdict, hygiene, undeclared dependencies, patch,
    port report), read from the per-module registry, which still finds a module
    after a `move` placement.
  - A loose set chooses one test-bed per module or one shared test-bed
    (`DRUPILOT_LAYERS_SANDBOX`). A set inside a Drupal root is always ported in
    place.
  - `state.sh record|refresh --portfolio DIR --layer N` stores
    `portfolio: {dir, layer}` in the module's `state.json`.
- **Pre-existing extension hygiene lint.**
  `scripts/analysis/lint-extension-metadata.sh --subject DIR [--json]
  [--checks ...] [--set-dir DIR]` checks the subject and its submodules. It
  reports and never fixes, always exits 0, and saves `metadata-lint.json` in
  the subject's state dir. Checks:
  - `config-schema`: own config without a `config/schema` key. Exact keys and
    trailing wildcards are matched the way core's
    `TypedConfigManager::getFallbackName()` resolves them.
  - `plugin-schema`: Block/Condition/Filter/FieldFormatter/FieldWidget settings
    without their `block.settings.<id>` / `condition.plugin.<id>` /
    `filter_settings.<id>` / `field.*.settings.<id>` schema.
  - `configure-route`: a `configure:` route no routing file defines (core's
    modules page drops the link silently). It suggests the closest route.
  - `services-class`: an orphan or wrong-case service class (error).
  - `services-arity`: `arguments:` outside the constructor's [required, total].
    Too few is an error; too many is a warning, since PHP ignores the extras.
    Constructors are followed up parents inside the subject.
  - `submodule-core-req`: a nested `info.yml` that does not admit Drupal 11 (it
    cannot be installed), or that has no key (InfoParserException;
    `package: Testing` is exempt).
  - `undeclared-deps`: shares the scanner with `layers.sh`. Uses of the
    always-enabled core modules (`system`, `user`, `path_alias`: `required:
    true` in core) are not reported, and neither are plugins of a module's own
    plugin type (e.g. `src/Plugin/migrate/` → migrate). `plugin-schema` only
    counts a `defaultConfiguration()`/`defaultSettings()` that returns keyed
    values.
  It is wired in as follows:
  - `/drupilot-assess`, the viability skill (§3.7) and the analyst run it, and
    the viability report gains a "Pre-existing hygiene (not fixed in Phase 1)"
    table. `assess.json` gains `hygiene`. The S/M/L/XL rubric is unchanged.
  - `/drupilot-port` and `minimal-port` run it in the validate loop.
  - `port-report.sh` renders the same table from the manifest's
    `metadata_lint`, or else from the state file, marked stale when the sources
    changed.
  Verified on the legacy_widgets fixture (H22–H28 all reported) and on a new
  9-extension monorepo lab fixture. On the real autologout 8.x-1.4 it reports
  no warning, only two informational migrate-plugin uses.
- **`scripts/analysis/set-core-requirement.sh --subject DIR --requirement C
  [--dry-run] [--json] [--no-tests]`.** Writes `core_version_requirement` into
  the main `info.yml` and every submodule's. It removes `core: 8.x`, adds a
  missing key, and bumps a test module only when the module does not admit
  Drupal 11. It is idempotent and refuses a constraint that admits neither
  Drupal 10 nor 11.
- **Shared helpers.**
  - `common.sh`: `info_yml_value`, `info_yml_dependencies` (block and flow
    lists, constraints stripped), `is_drupal_core_module` and
    `core_requirement_admits <constraint> <major>`.
  - `scripts/lib/ext-scan.sh`: the extension-set scanner (bash + POSIX awk +
    jq, verified with gawk, mawk and busybox awk under bash 3.2).
- **Decision log (`scripts/analysis/log-decision.sh`).** Records, the moment
  it happens, every place a port does not keep a tool's output or does not
  follow the flow, with what and why. Until now these choices only survived in
  hand-written report prose, so a reverted Rector change looked like a kept
  one.
  - Kinds: `rector-revert` (needs `--rule`), `post-port-fix`,
    `script-divergence`, `skip`, `manual-override`, `tooling-deviation`,
    `test-adaptation`, `behavior-change` (with `--review-hint`),
    `preexisting-bug`. `--what` and `--why` are required.
  - Each entry is one JSON line in `<root>/.drupilot/decisions.jsonl` (one log
    per Drupal root, every entry names its subject); `decisions.md` beside it
    is regenerated as a table per module (temp file + `mv`). `--list`,
    `--render`, `--json` and `--dry-run` modes.
  - The minimal-port and full-refactor skills, the orchestrator and test
    engineer agents, and `/drupilot-port` / `/drupilot-refactor` tell the
    agent to log each divergence as it happens.
- **Structured port outcome fields.** The port manifest takes optional
  `rector_rules`, `rector_reversions`, `post_port_fixes`, `preexisting_bugs`,
  `behavior_changes`, `tooling_deviations` and `validation`, so reverted Rector
  rules and post-port fixes aggregate across modules and layers.
  `port_record_json` (common.sh) normalizes them and merges the decision log
  (deduplicated). `port-report.sh` renders a section for each only when it has
  content, so a report from an older manifest is byte-identical.
- **Rector rule counts.** `run-rector.sh --json` adds `rule_hits`
  (`{official: {Rule: files}, digests: {...}}`, from Rector's "Applied rules"
  lines; `{}` when the format is not recognized). An `--apply` that changes
  files keeps it as `rector-rules.json` in the subject's state dir, the
  report's fallback when the manifest has no `rector_rules`.
- **One template for the consolidated layer report.**
  `layer-report.sh` now renders `templates/layer-report.md.tmpl` with fixed
  sections: per-module result, frequent Rector rules with hits and reversions,
  manual changes, post-port fixes, pre-existing bugs, behavior changes to
  review in the PR, tooling and flow deviations, and how it was validated.
  Layer reports used to differ in format from one layer to the next.
  - `--json` keeps every existing key and adds `modules[].port`, an
    `aggregate` object and new totals.
  - `--subject DIR` (repeatable) with `--name LABEL` reports on any set of
    modules, e.g. ported in separate test-beds, without a `layers.json`.
  - `render_template_files` (common.sh) substitutes `{{KEY}}` tokens with file
    contents in one left-to-right pass: values may be multi-line, hold `|`,
    `&` or `\`, exceed the environment's size limit, and are never re-scanned.
- **Learned-pattern catalog (`scripts/analysis/patterns.sh`).** The same
  port failures kept coming back module after module and layer after layer,
  and the lessons lived only in hand-kept FAQs outside drupilot. Each project
  now has one catalog, `<root>/.drupilot/patterns.json` (visible,
  self-gitignored, editable by hand; `DRUPILOT_PATTERNS_FILE` points it at a
  committed file). Each entry holds a detector, the fix that worked, why it was
  needed, its source module/layer and `hits`.
  - Detectors: a POSIX ERE run over the source (`--files` globs,
    `--ignore-case`) and/or a reference to a deterministic rule,
    `port-safety:<check>` (check-port-safety.sh) or `signature:<id>`
    (scan-signature-changes.sh). `add` refuses an invalid ERE, a PCRE
    construct (`\d`, `(?`), an ERE that matches an empty line (it would match
    every line) and an unknown rule.
  - `scan` runs every detector on a subject before it is ported (read-only,
    exit 0; `[pattern:<id>] file:line fix` lines or `--json`). `add` upserts by
    id (`hits` + 1, the module appended to `seen_in`; atomic temp file + `mv`;
    `--dry-run`). `harvest` proposes candidates from the port record
    (reverted Rector changes, post-port fixes). `export` prints the ERE entries
    in `config/deprecations.json` format for upstream (module names only with
    `--with-source`). `list` and `remove` complete it.
  - `patterns_file` (common.sh) resolves one catalog per project: the env/config
    override, then the portfolio recorded in the subject's `state.json` (so a
    `/drupilot-layers` set shares one catalog even with one test-bed per
    module), then the Drupal root's `.drupilot/`, then (no root yet) the
    nearest catalog up to the git toplevel, so a submodule shares its parent's.
  - Flow: `/drupilot-port` (Step 2c scan, Step 8b record), `/drupilot-refactor`
    (Steps 2b and 6b), the minimal-port and full-refactor skills and the
    orchestrator scan before changing code and offer, as a multi-select, to
    record what the port taught. An autonomous run records only detectors it
    checked and lists them. `/drupilot-layers` passes the set's catalog to each
    module and reports what a layer added, so layer N+1 is checked for what
    layer N hit.
  - `port-report.sh` renders a "Learned patterns" section from an optional
    manifest key `learned_patterns {scan, recorded}`. Without it, the report
    is unchanged.
- **`/drupilot-clean` and `scripts/env/clean.sh`.** Test-beds piled up
  DDEV projects and a few hundred MB of Composer trees each, and the only way
  to remove one was a manual `ddev delete` plus `rm -rf`, which with the
  default `move` placement would also have deleted the developer's only
  checkout. The new command removes, by level, the DDEV project (`ddev`:
  `ddev delete -Oy`), the Composer-installed trees (`vendor`, the default:
  vendor/ plus every installer path, never `*/custom`) or the whole derived
  workspace (`workspace`), and keeps the reports, the hidden state and
  lockfile, the local patches and the module's git branches.
  - Default-safe: it prints the plan and acts only after an interactive "yes"
    or `--yes`; `DRUPILOT_ASSUME_YES` and autonomous mode never imply it, and
    without a terminal it only prints the plan. `--dry-run`, `--json`; exit 3
    when a root is refused or an action fails.
  - Ownership: `vendor` and `workspace` act only on a root drupilot built
    (the new `drupilot_testbed` marker in the root's `.drupilot.json`, or a
    pre-marker `<name>-d11[-N]` test-bed whose `DRUPILOT_WORKSPACE_DIR` is
    itself). Any other root allows only `--level ddev --foreign-ok`, with a
    second confirmation.
  - `workspace` first moves a `move`d module back to its recorded origin
    (refused if that path is no longer empty), only unlinks a `symlink`,
    discards a `copy` only when it holds nothing its origin lacks (or with
    `--discard-copies`, keeping its `*.patch` files), copies the test-bed's
    `.drupilot/` reports into the module's own `.drupilot/`, and refuses a
    workspace with its own `.git` or with a module that has no recorded origin.
  - `--all` cleans every test-bed drupilot has state for (plus `--scan DIR`);
    `--core-cache` removes the cached base cores; `--no-ddev` skips
    `ddev delete` when Docker is down.
  - Each module's `state.json` records `environment: {status: "removed",
    level, at}`; `next-step.sh` then recommends `/drupilot-setup`
    (`environment_removed` in its JSON), and `ddev-up.sh` / `place-subject.sh`
    set it back to `ready`.
- **Cached base core for `/drupilot-setup` (`DRUPILOT_CORE_CACHE`).** After a
  fresh `composer create-project` (+ Drush), `ddev-up.sh` stores the tree
  (never `.ddev/`, `settings*.php` or `files/`) under the plugin data dir,
  keyed by PHP target and exact core version, and a later setup of an empty
  root copies it in before `ddev start` (`cp --reflink=auto`, `cp -c` on APFS,
  else a plain copy), then verifies it with `ddev composer install`; a failed
  verification discards the entry and falls back to `create-project`. `auto`
  (default) reuses the lockfile's frozen core version, or the newest entry for
  the same `DRUPILOT_DRUPAL_TARGET` within `DRUPILOT_CORE_CACHE_MAX_AGE_DAYS`
  (7); `locked` only the frozen version; `off` disables it;
  `DRUPILOT_DETERMINISTIC=false` never reuses one. `DRUPILOT_CORE_CACHE_KEEP`
  (3) entries are kept. Measured in the lab (DDEV 1.25.4, Drupal 11.4.8,
  btrfs, warm DDEV Composer cache): `ddev-up.sh` 30 s with `create-project`,
  20 s from the cache. `--json` gains `core_source` (create | cache |
  existing | install) and `core_cache`.
- **Test-bed helpers in `common.sh`:** `testbed_mark`, `testbed_record_subject`,
  `testbed_kind`, `subjects_with_state_under`, `env_status_record`,
  `fast_copy_tree`, `core_cache_dir`, `core_cache_lookup`,
  `core_cache_entries`, `core_cache_prune`.
- **Optional annotation → PHP 8 attribute pass:
  `scripts/analysis/convert-attributes.sh`, also `run-rector.sh --attributes`.**
  Ports needed hand-written Rector configs to convert plugin annotations, because
  `palantirnet/drupal-rector` 0.21.x ships `AnnotationToAttributeRector` but
  configures it in no set. The new pass renders its own config from
  `templates/rector-attributes.php.tmpl` into
  `<drupal_root>/.drupilot/rector-attributes.php` and runs only that rule; the
  default official and digests passes are unchanged.
  - `config/plugin-attributes.json` lists 55 core plugin types with the core
    minor that ships each attribute class and makes its manager discover it,
    verified against drupal/core tags 10.2.0 to 11.3.0: `Action` and `Block`
    10.2; `Condition`, `QueueWorker`, `Filter`, the field, Views, migrate and
    the other plugin types 10.3; `EntityType` / `ContentEntityType` /
    `ConfigEntityType` 11.1; `MigrateSource` 11.2. Annotation names that differ
    from the attribute are mapped (`@MigrateProcessPlugin` → `MigrateProcess`,
    `@SearchPlugin` → `Search`). `CKEditor5Plugin` is listed as unsupported: its
    nested annotation objects are beyond the 0.21.2 rule.
  - `DRUPILOT_ATTRIBUTES_MODE` (`keep`, default, or `strip`; `--mode`). Keep adds
    the attribute next to the annotation, which core keeps reading on older
    cores. Strip removes the annotation, but only for types whose minor is at or
    below the declared core floor; the others keep it and are listed.
    `--raise-floor` strips them too and rewrites `core_version_requirement`
    (`set-core-requirement.sh`) to the new `recommended_requirement` (e.g.
    `^10 || ^11` → `^10.3 || ^11`, `^11.1` with an entity type). Without it the
    pass never raises the floor. `--max-since X.Y`, `--types`, `--floor`.
  - `DRUPILOT_ATTRIBUTE_PLUGIN_TYPES` declares project or contrib plugin types
    (`Annotation=Fully\Qualified\Attribute[@MAJOR.MINOR]`, comma-separated). A
    custom type is converted only when its attribute class exists under the
    Drupal root, and stripped only when a plugin manager references it.
  - Guards: attributes are printed fully qualified, because the 0.21.x rule
    recognises an existing attribute only by its FQCN and would duplicate a
    short imported one on a re-run. A file that already has such an attribute is
    skipped. After `--apply`, a file with a duplicate attribute or a `php -l`
    failure is restored from a pre-run backup. A class constant the annotation
    named relative to its namespace (`type = Drupal\filter\Plugin\FilterInterface::TYPE_…`
    in a `@Filter`) is fully qualified: copied as is, PHP resolves it inside the
    plugin's namespace, PHPStan reports an unknown class and plugin discovery
    fails. Rector runs with `--clear-cache`, because its cache of unchanged
    files ignores rule options and a run after a different mode skipped files.
  - `--json` reports per-type actions, `attribute_floor`, `floor_ok`,
    `recommended_requirement`, `skipped_files`, `restored_files`,
    `qualified_constants` and `rule_hits` for the manifest's `rector_rules`.
  - Flow: `/drupilot-port` Step 6b offers it as an opt-in tab ("Plugin
    attributes", default Skip; skipped in autonomous runs), in keep mode limited
    to the Drupal 10.3 types and with the floor raised explicitly. In
    `/drupilot-refactor` the "PHP 8 attributes" scope runs it in strip mode
    instead of a hand conversion, with an "Attribute floor" tab when a type needs
    a newer core than declared. FLOW.md / FLOW_es.md show both steps.
  - Proved in the lab on the legacy_widgets fixture (Drupal 11.4.8 test-bed):
    the Block, Condition, QueueWorker and Filter plugins get attributes in both
    modes; a re-run is a no-op; PHPStan reports nothing new; the kernel suite
    (9 tests) stays green; and a probe kernel test that discovers each plugin
    through attribute-only discovery fails before the pass and passes after it.
    In strip mode, with the annotations gone, both the suite and the probe stay
    green, including with the entity type converted and the floor at `^11.1`.
- **`core_requirement_raise_floor` in `common.sh`:** raises a
  `core_version_requirement` to a MAJOR.MINOR floor and keeps every higher
  major (`'^10 || ^11'` + 10.3 → `'^10.3 || ^11'`, + 11.1 → `'^11.1'`).
- **A non-interactive contract for wrappers (section 5).** Another skill, a CI
  job or a script driving `claude -p` used to parse the Markdown reports.
  - **`scripts/analysis/port-summary.sh` (new):** one versioned JSON object
    (`schema_version: 1`) with the port's `status` (the stage, or `blocked` with
    `blockers`), `effort`, `files_changed`, `rector_rules`, `reverted_rules`,
    `manual_fixes` (plus the other decision lists), `preservation`, `matrix`,
    `patch` and the report paths. It composes `state.json`, the port manifest,
    the decision log, `last-test.json` and `core-matrix.json`, and never
    invents a value (unknown is `null`). A result computed on sources that
    changed since is shown but never blocks. `--write`/`--output DIR` save
    `port-summary.json`; `--strict` exits 3 when blocked. `port-report.sh`
    refreshes `.drupilot/port-summary.json` next to `port-report.md`.
  - **`DRUPILOT_NONINTERACTIVE=1`:** `tty_readable` reports no terminal, so
    `confirm`/`choose_one` never prompt and take their default (the safe one:
    a push or a destructive clean is never implied, unlike
    `DRUPILOT_ASSUME_YES`). Environment-only.
  - **`--workspace DIR`** on `resolve-workspace.sh`, `ddev-up.sh` and
    `place-subject.sh`: the same as `DRUPILOT_WORKSPACE_DIR`, and the flag wins.
    Without the flag the output is byte-identical to before.
  - **Router flag words** `--no-confirm` (auto mode + no prompts, never
    outward-facing), `--workspace DIR` and `--json` (the final message is the
    `port-summary.sh --json` output). The subject stays the first positional
    word. README "Running under another tool" documents the contract and the
    schema.
- **`preflight.sh --extended` health checks, run by `/drupilot-doctor`
  (section 5).** Report-only rows with `category: "health"` that never change
  `ready` or the exit code: `xmllint` present, the `sed` flavour (info), the
  Drupal root's `phpcs.xml.dist` well-formed (`xmllint --noout`) and its
  `phpstan.neon` free of `drupal_root`, one row per known-good toolchain package
  installed at the root (read from `composer.lock` with jq: no PHP, no DDEV)
  plus `toolchain_combo`, false when the installed set matches a
  `known_broken` entry of `config/toolchain-reference.json`, free disk space
  against the new `requirements.disk_free_min_mb` (5120), and drupilot/DDEV
  residue in the subject's origin checkout (origin-hygiene.sh against its
  baseline, else resolve-workspace.sh's residue scan). `--extended --json` adds
  `extended: true` and a `toolchain` object `{root, installed, known_good,
  match, differs, known_broken}`. New `--subject DIR` picks the module or root
  (default: the current directory). Without `--extended` the output and exit
  codes are byte-identical to before; the SessionStart hook and the command
  gates do not pass it. The doctor shows the installed vs known-good table and
  the `install-toolchain.sh --source reference` repair.
- **Every tabbed choice can be answered in advance with `DRUPILOT_CHOICE_<KEY>`.**
  The variable was documented but no command applied it. Each command now checks
  it before showing a tab, skips the tab when the value is valid, says which
  variable answered it, and remembers the answer in `.drupilot.json` exactly as
  the tab would (for example `DRUPILOT_CHOICE_CORE_TARGET=keep-d10` is saved as
  the core target strategy). It also applies in an autonomous run. Keys cover
  the router intent, PHP target, workspace layout, a hand-edited config, existing
  upstream work, core target, digests rules, plugin attributes, the Drupal 10
  check, learned patterns, the next step, refactor scope and PHPStan level, the
  attribute floor, the patch kind, the contribute mode, the clean level and the
  `/drupilot-layers` tabs. An invalid value is ignored with a warning and the tab
  is asked. The push to Drupal.org, the clean confirmation and what
  `/drupilot-doctor` installs are never pre-answered. The registry is
  `config/choices.json`; the new `scripts/env/choice.sh` resolves a key
  (`--json`, `--persist`) and lists them all (`--list`). The shell fallback
  `choose_one` also ignores a value for a fork that cannot be pre-answered.
- **`DRUPILOT_WANT_REFACTOR` is now a documented setting** (default `false`, in
  `config/defaults.json` and the README). `true` makes the next-step
  recommendation suggest `/drupilot-refactor` right after the port.

### Changed
- **Docs: troubleshooting, a scripts reference and the flow (section 5).**
  README / README_es "Troubleshooting" now opens with a pointer to
  `/drupilot-doctor`'s health checks and adds the macOS bash 3.2 / BSD `sed`
  errors of drupilot <= 0.8.4 (`bad substitution`, `declare: -A`, `invalid
  command code`), FunctionalJavascript sessions refused because Drupal 11.4
  forces `w3c` off without `"w3c":true` (checked in core 11.4.8's
  `WebDriverTestBase::getMinkDriverArgs()`), the `EXECIGNORE` trap of running
  the test-bed's `vendor/bin/composer` through `ddev exec timeout|sh -c`, a
  full disk, and residue in the origin checkout. A new "Scripts reference"
  table lists every script with its purpose. FLOW / FLOW_es show the doctor's
  health checks, the setup scripts, the deterministic gates of the validate
  loop, `port-summary.json`, and a new "Under another tool" diagram (all
  diagrams render with mermaid-cli).
- **The port bumps submodules too.** `/drupilot-port`, `minimal-port` and
  the orchestrator apply the recommended `core_version_requirement` with
  `set-core-requirement.sh` to every nested `info.yml`, not only the main one.
  Before, a submodule stayed on `^8.8 || ^9 || ^10` and Drupal 11 refused to
  install it. The orchestrator's definition of done now requires every nested
  `info.yml` to admit Drupal 11, and its batch context for `/drupilot-layers`
  (portfolio/layer passthrough, per-module `port-report.sh --output`) is
  documented.
- **`next-step.sh` reads the per-module record.** Its JSON adds `effort` and
  `state_file`, and a recorded `assessed` stage counts as assessed. It and the
  other state readers no longer create an empty state dir for a directory they
  only look at (new `project_state_path` / `data_dir_path` helpers).
- **`/drupilot-contribute` and `CLAUDE.md` describe the current hook and Drupal
  10 contracts.** Step 3 of the command now runs `git-hooks.sh --json` before
  committing, lets the hooks run, and allows `--no-verify` only after
  `--run-equivalents` reports `all_green` (recording the substitution), as the
  skill and agent already required. `CLAUDE.md` documents the guard's
  `--no-verify` ask (`DRUPILOT_HOOKS_GUARD`), `verify-core-matrix.sh` and the
  `d10_support` verdicts, the project PHPCS ruleset resolution and
  `git-hooks.sh`, and the DDEV helpers (`ddev_ensure_running_or_host`,
  `ddev_stop_composer`, the `run_with_timeout` caveat).
- **Only hard deprecations count as must-fix work.** The viability assessment
  used to count every PHPStan deprecation message as "must-fix to run on D11",
  which overstated the effort of modules that only use APIs deprecated in 11.4
  (they keep working until Drupal 13). The verdict now counts hard and unknown
  deprecations only, and Phase 1's "no blocking deprecations" means
  `classify-deprecations.sh` reports `blocking: 0`.
- **`check-port-safety.sh` override-attribute uses the signature catalog.** An
  `#[\Override]` on a method the catalog dates above the declared core floor
  (e.g. `buildRevisionCacheId()`, 11.3) is now an error whatever its
  attribution, also for `^11` (floor 11.0), where it used to be skipped or only a
  review warning.
- **Skills document the `#[\Override]` trap and D10-safe signature fixes.** An
  `#[\Override]` on a method that exists only in some of the declared cores is a
  PHP 8.3+ compile-time fatal on the others (Drupal 10 first); constructor
  arguments are forwarded, new hook parameters stay optional, and colliding
  helpers are renamed while the floor is lower.
- **`rector/rector` is an explicit toolchain package** (`.packages.rector`,
  `^2.0 <2.6.2`), so it is installed with a range that excludes the releases that
  break drupal-rector 0.21 and `lock-sync.sh` records its exact version.
- **`ddev-up.sh` uses `ddev composer create-project`** on DDEV >= 1.24.2 (DDEV
  1.25 prints a deprecation warning for `ddev composer create`); older DDEV keeps
  `ddev composer create`. Docs updated to match.
- **The `ddev-environment` skill no longer suggests `envsubst`** (not shipped on
  stock macOS) or hand-written `sed` for rendering templates; it runs
  `render-templates.sh`.
- **`place-subject.sh` copy mode skips local-environment residue** — `.ddev/`,
  `vendor/`, `.drupilot/`, `.drupilot.json`, `.phpstan-cache/`,
  `.drupilot-coverage/` at the top level and `node_modules/` at any depth — and
  drops symlinks whose target escapes the checkout (the origin keeps them). A
  nested `js/vendor/` is still copied. Untracked residue in the checkout is
  warned about for every placement mode.
- **`place-subject.sh` warns when a `symlink` placement points outside the
  Drupal root**: DDEV mounts only the root, so `ddev exec` tooling cannot see the
  subject (verified in the lab).
- **`/drupilot-setup` and the `ddev-environment` skill pass `--name`** to
  `ddev-up.sh` (otherwise the DDEV project is named after the test-bed folder);
  `ddev-up.sh` warns when `--name` is ignored because the project already exists.
- **`make-patch.sh --local` leaves out local-environment residue** (`.ddev/`,
  top-level `vendor/`, `.phpstan-cache/`, `node_modules/` anywhere) when it
  captures untracked files.
- **Patch file names keep the project machine name as-is.** `make-patch.sh`
  (both `--local` and the contribution mode) and `make-issue.sh` used to turn
  underscores into hyphens (`legacy-widgets-port-to-drupal-11.patch`); they now
  follow the Drupal.org convention `[project]-[short-description]-[issue]-[comment].patch`
  with the machine name unchanged (`legacy_widgets-port-to-drupal-11.patch`,
  `legacy_widgets-port-to-drupal-11-123456-3.patch`; the documented example is
  `some_module-some-bug-123456-3.patch`). The issue summary/comment files follow
  (`legacy_widgets-issue-summary.md`). Names without an underscore do not
  change, and the `.git/info/exclude` / `.gitignore` patterns still match. When
  a preview under the old hyphenated name is still next to the module,
  `make-patch.sh --local` warns about it instead of deleting it. New helper:
  `patch_project_slug` in `common.sh`.
- **`post-edit-lint` uses the ruleset `run-phpcs.sh` resolved.** The hook reads
  `phpcs-ruleset.json` and lints with the project's ruleset and testVersion
  when one was recorded and the file has not changed since. It never discovers
  or probes a ruleset itself; otherwise it keeps `Drupal,DrupalPractice`.
- **`run-phpcs.sh` always passes `--runtime-set testVersion`.** The value is
  `<DRUPILOT_PHP_TARGET>-` by default. A ruleset's own
  `<config name="testVersion">` is never overridden, and a testVersion declared
  as a `<property>` inside a `<rule>` is passed through. This avoids
  PHPCompatibility's "trim(): Passing null" failure, and the script warns when
  PHPCS reports a processing error instead of counting it as a violation.
- **`place-subject.sh` records where each subject came from** (origin path,
  placement) under `drupilot_testbed.subjects` in the root's `.drupilot.json`,
  so `/drupilot-clean --level workspace` can move a `move`d checkout back.
- **A rebuilt test-bed honors the lockfile's core version.** In deterministic
  mode, when `ddev-up.sh` has to create the project again for a root whose
  lock already froze a Drupal core release (e.g. after a workspace clean), it
  creates `drupal/recommended-project:<that version>` instead of resolving the
  floating `DRUPILOT_DRUPAL_TARGET`, which could silently move the core.

- **`/drupilot-contribute` remembers the contribute mode** you pick in
  `.drupilot.json`, so the next run pre-selects it, as the README already said.
- **README reorganized.** Quick start keeps only the essential commands and a
  short note on loose checkouts. The reference material moved to its own
  sections: "Workspaces, outputs and state" (loose checkouts and monorepos, the
  `.drupilot/` folder, the decision log, learned patterns, per-module state,
  cleaning up test-beds, and the cached base core, now in its own subsection),
  "Running under another tool" and "Pre-answering tabbed choices". The table of
  contents lists every section and the main subsections, in both languages.
- **The `/drupilot-refactor` scope has named keys** (`attributes`, `di`,
  `strict-types`, `final`, `deprecations`), used in `DRUPILOT_REFACTOR_SCOPE`.

### Fixed

- **`run-phpunit.sh` exited 1 when no Drupal root was found.** The documented
  exit-code convention (and every other test-bed script) treats a missing Drupal
  root as a failed requirement gate, exit 2; `run-phpunit.sh` returned 1, so
  wrappers read it as a usage error and `negative-control.sh` reported an
  inconclusive `error` instead of `blocked`. It now exits 2.
- **README wording.** Both READMEs name `config/port-checks.json` (the
  port-safety checks and their severities) and `config/deprecations.json` in the
  scripts reference, drop the stale "once published" note on the GitHub install,
  and clarify that a stale test result never blocks a port summary;
  `README_es.md` fixes several Spanish spelling and terminology slips.
- **README accuracy (scripts contract and reports).** Both READMEs now say the
  Drupal.org scripts (`find-upstream-issue.sh` / `issue-fork.sh` / `open-mr.sh` /
  `check-prereqs.sh`) take `--project NAME` rather than `--subject DIR`; limit the
  `-h` help claim to `scripts/` (the hooks read JSON on stdin and always exit 0);
  document that a `/drupilot-layers` run writes each module's `port-report.md` /
  `port-summary.json` under `.drupilot/modules/<machine>/`; and narrow the
  "stale result never blocks" note to test and core-matrix results (port-safety /
  signature errors come from the port manifest and still block).
  `README_es.md` uses "capas de portabilidad", "confirmado" and "sobrescribir"
  consistently.
- **README accuracy (flow and verdicts).** Both READMEs now list
  `/drupilot-refactor` before `/drupilot-test` in the Quick start (matching the
  `next-step.sh` ladder); say Phase 2 converts attributes in `strip` mode for a
  `^11` target but `keep` while `^10 || ^11` is deliberately kept; limit the
  `verified-partial` "exit 0" claim to the FunctionalJavascript-without-Selenium
  skip (a group PHPUnit could not execute exits 2); and scope "a viability
  assessment always runs first" to the guided/hands-off flows, adding
  `/drupilot-assess` to the minimal-port use case.
- **A re-run of `/drupilot-refactor` asked the Modernize tab again.** The
  modernization scope you picked is saved in `.drupilot.json`, but the command
  never read it back. A re-run now reuses the remembered scope (or the one set
  with `DRUPILOT_REFACTOR_SCOPE`), skips the tab and says so.
- **A viability threshold set in `.drupilot.json` was not applied.**
  `/drupilot-assess` and the `/drupilot` router now resolve
  `DRUPILOT_VIABILITY_THRESHOLD` the same way as every other setting
  (environment, then `.drupilot.json`, then the default), and the viability
  report's threshold check shows that value.
- **A cached reference core stopped every contrib or custom attribute
  conversion.** The attribute constructor check also reads each reference core
  under `.drupilot/cores` (left there by the core matrix of a module that keeps
  Drupal 10). Those hold core only, so a contrib or custom attribute class (for
  example `web/modules/contrib/foo/src/Attribute/Foo.php`) could not be read
  there and every file of that type kept its annotation with "the constructor
  could not be read". A reference core now only counts for attribute classes
  that ship with core; the test-bed still reads every class.
- **Some outputs still landed inside a monorepo.** For a module or folder of a
  larger repository with no usable Drupal root (a monorepo clone, a folder of
  modules inside another repository), `/drupilot-layers` saved its plan to a
  `.drupilot/` inside the repository (for example
  `web/modules/custom/.drupilot/layers.md`), as did the layer report and an
  assessment run before setup, and `clean.sh --level workspace` copied the
  test-bed's reports and a discarded copy's patches into a `.drupilot/` of each
  module. They were self-ignored, but they were still files in the user's
  repository. These outputs now go to the hidden state dir of that module or
  folder (`<state>/artifacts`); the scripts print the path.
- **The post-edit lint deleted a `use` the port had just added.** During
  Phase 1 the PostToolUse hook runs `phpcbf` after every edit, so a `use` added
  one edit before the code that needs it was removed as unused in between. In
  Phase 1 the hook's `phpcbf` now skips the unused-use sniffs; the validate loop
  (`run-phpcs.sh --fix --fix-scope changed`), which runs after the batch of
  edits, still removes the ones that really are unused. The minimal-port
  reference commands now show that scoped autofix instead of a whole-module
  `phpcbf`.
- **Placing a monorepo module ran the repository's own git hooks.** Reading
  the module out of the origin's last commit for the copy's baseline is a git
  path checkout, which runs the origin's `post-checkout` hook (husky, custom
  scripts), so user code could run and write into the repository during
  placement. That checkout now runs with hooks disabled.
- **Setup steps given a monorepo module could still write into the
  repository.** In a Composer project checkout without installed core that
  carries a committed `.ddev/config.yaml`, `ensure-gitignore.sh`,
  `install-toolchain.sh`, `render-templates.sh` and `lock-sync.sh` resolved
  `--subject` to the repository root, so they edited its tracked `.gitignore`,
  planned `rector.php`/`phpstan.neon`/`phpcs.xml.dist` there and would have run
  `composer require --dev` on the user's `composer.json`. They now resolve the
  subject to the test-bed it is ported in, like the workspace resolver and
  `ddev-up.sh` (and fail cleanly before that test-bed exists);
  `render-templates.sh --subject <origin>` maps a copied module to its copy in
  the test-bed.
- **The core target still claimed Drupal 10 support after raising the floor
  past it.** A module already declaring `^10 || ^11` whose code uses an
  attribute that exists only from Drupal 11 (for example `ContentEntityType`,
  from 11.1) had its requirement raised to `^11.1`, but the recommendation kept
  reporting Drupal 10 as "declared, not verified", a `require.php` floor and a
  "still allows Drupal 10" warning, so the port manifest, the issue text and
  the summary promised Drupal 10 support. The Drupal 10 logic now follows the
  requirement actually recommended: the strategy is `d11-only`, Drupal 10
  support is `n/a`, and the warning says why Drupal 10 cannot be kept.
- **`convert-attributes.sh --raise-floor` could raise the core requirement for
  an attribute it had just undone.** The core floor was computed before the
  checks that restore a file (a duplicate attribute, a `php -l` failure, a
  PHPStan constructor mismatch), so when every file of a type was restored the
  requirement was still raised (for example to `^11.2` for a `MigrateSource`,
  dropping Drupal 10). The floor, the recommended requirement and each type's
  `converted_files` are now recomputed from the files still converted.
- **The Phase 1 autofix reformatted files the port never touched.**
  `run-phpcs.sh --fix` ran `phpcbf` over the whole module, so a minimal port's
  patch also carried trailing commas, removed `use` lines and a missing EOF
  newline in a config YAML from files the port did not change. The new
  `--fix-scope changed` hands `phpcbf` only the files that differ from the
  pre-port git base (the same base as the local patch) plus new files; the
  report pass still covers the whole module, so the untouched files' violations
  stay visible as pre-existing. Without git the autofix is skipped (report
  only). `/drupilot-port` and the minimal-port skill use it; `--fix` alone (the
  refactor phase) still fixes everything.
- **Porting the modules of a monorepo clone left a test-bed inside the
  repository and produced an unusable patch.** A clone of a Composer-based
  Drupal project has no `web/core` (it is gitignored), so it was not
  recognized as a Drupal root and `/drupilot-layers` built the test-bed inside
  the repository (`web/modules/custom-d11`, or `custom/<name>-d11` per module).
  The copied module had no repository of its own, so the local patch was diffed
  against the monorepo and listed the whole module as new files under the
  test-bed path. Now `resolve-workspace.sh` recognizes a **project root without
  installed core** (a `composer.json` requiring `drupal/core-recommended` or
  `drupal/core` with a `web/` docroot; a committed `.ddev/` does not change
  that) and puts one shared test-bed next to the repository,
  `<parent>/<project>-d11`. A module inside any other git repository gets
  `<parent of the repository>/<name>-d11`. A module that is a sub-directory of
  a repository is always copied, never moved out of it, and the copy gets a git
  baseline: its own repository whose first commit is the module as committed in
  the origin. `make-patch.sh --local` then writes the same module-relative
  patch as for a single module, plus `<name>-port-to-drupal-11-repo.patch`
  with paths relative to the repository root (`web/modules/custom/<name>/...`),
  which it checks against the origin commit and which applies at the monorepo
  root with `git apply`. Nothing is written into the origin repository. The
  resolver also reports `layout`, `origin_repo`/`origin_rel`, `shared_root`
  (the test-bed `/drupilot-layers` shares) and warns when an explicit workspace
  lies inside the repository. An in-place port runs on the site's own core:
  the resolver now reports `core_version` and `in_place_ok`, warns when that
  site is still on Drupal 10, and an explicit `DRUPILOT_WORKSPACE_DIR` then
  ports in a Drupal 11 test-bed instead. `ddev-up.sh` follows the resolver for
  every module/theme subject.
- **The setup step that installs the DDEV add-ons could not find the
  project.** `/drupilot-setup` ran `ddev-add-ons.sh` without `--dir`, so run from
  the original checkout of a `copy` placement it stopped with "No DDEV project
  found" (and after a `move` the working directory no longer existed), and
  `--subject <original checkout>` did not find the test-bed either. The setup
  command (and the skill and agent that document the call) now passes
  `--dir <drupal_root>`, and `ddev-add-ons.sh --subject` resolves the project as
  `ddev-up.sh` does: the Drupal root above the subject, the test-bed of a loose
  checkout, or the test-bed that holds a moved-away original path (new
  `subject_project_root` helper). An unsubstituted `<placeholder>` argument is
  refused.
- **`layers.sh --edges declared` replaced the saved porting plan.** It wrote
  over `layers.json`/`layers.md`, and `layer-report.sh` then reported the
  declared-only layering without saying so. A declared-edges run is now saved
  as a variant (`layers-declared.json`/`layers-declared.md`); `layer-report.sh`
  reads the canonical all-edges plan by default, takes `--edges declared` to
  report the variant, recomputes when a saved file was made with other edges,
  and states the mode (`edges` in the JSON, and in the report's header).
- **The metadata lint counted plugins from other copies of the module.**
  The `plugin-schema` check took every plugin with the subject's machine name
  found anywhere in the `--set-dir` (in a shared test-bed: the subject seen a
  second time; with a broad directory: every unrelated copy), so warnings and
  totals were inflated. It now checks only the subject's own plugins; the rest
  of the set still resolves references. The extension scan marks each plugin
  with `own`.
- **`port-summary.sh` could contradict itself.** A recorded `false` (digests
  `applied`/`skipped`, the `fresh` flag of the test run and of the core matrix)
  came out as `null`, and `d10_support` came from the port manifest while the
  blocker came from a newer core matrix, so a summary could say
  `verified-static-above-floor` and be blocked by `d10_support: failed`. A core
  matrix run on the current sources now decides both, and the new
  `d10_support_source` field says which record was used.
- **The core matrix could call a dependency on a sibling module an
  incompatibility.** On a reference core without the sibling module, PHPStan
  reports messages such as `Parameter $x of method Drupal\a\B::f() has
  invalid type Drupal\c\D`; the classifier took the first class in the
  message (the module's own) instead of the missing one, so the finding was
  `incompatible` and the module got `d10_support: failed`. It now reads the
  type the message says is missing (unknown class/interface/trait, invalid
  type, class not found or does not exist, reflection error) and classifies it
  as a missing sandbox dependency.
- **In a shared test-bed every module reported the origin of the last one
  placed.** The origin checkout's baseline was one file per test-bed, so each
  placement overwrote it: `/drupilot-status` showed the wrong origin, the
  hygiene check of the earlier modules had no baseline (`clean: null`), and
  `layer-report.sh` could show another module's Drupal 10 verdict and patch on
  a row. The baseline is now kept per module (an older single baseline is still
  read when it names the same module), `state.sh` falls back to the test-bed's
  own record of each placed module, and `layer-report.sh` matches a row to a
  record by path first and accepts an origin match only for the same module.
- **`/drupilot-status --all` listed only the first module when a test-bed's
  DDEV project was running.** The DDEV status check (`ddev describe`) read
  from its standard input; inside the portfolio loop of `state.sh list` that
  input was the rest of the module list, so the loop ended after the first
  module. Every `ddev`, `docker`, `composer` and version probe in the shared
  helpers now runs with its standard input closed, and so do the `ddev
  describe` in `ddev-up.sh` and the image checks of the core matrix.
- **The recommended core requirement lowered a declared minor floor.** A
  module declaring `^10.3` was recommended `^10 || ^11`, and a module whose
  code uses the Block plugin attribute (core 10.2+) was recommended a floor of
  10.0. `core-strategy.sh` now keeps a declared Drupal 10 minor floor
  (`^10.3` -> `^10.3 || ^11`) and raises the floor to the core minor that ships
  any plugin attribute class the code uses (`^10.2 || ^11` for Block; `^11.1`,
  Drupal 11 only, for an entity type attribute, with a warning). The core
  matrix's default legs now include the declared floor next to the newest 10.x
  (`^10 || ^11` -> 10.0, 10, 11), so an API added after 10.0 fails the 10.0
  leg instead of passing on the newest 10.x; a run that still skipped the floor
  (an explicit `--cores 10,11`) prints `verified-static-above-floor` as a
  warning.
- **The annotation-to-attribute pass could produce attributes that fatal at
  runtime.** The rule copies every annotation key into a named argument, so
  `@MigrateSource(id = "...", source_module = "...")` became a `MigrateSource`
  attribute with a `source_module` argument its constructor does not take, and
  discovery failed with "Unknown named parameter" (`php -l` does not see it).
  `convert-attributes.sh` now reads each attribute class's constructor
  parameters from the test-bed core and from every cached reference core, and
  leaves the annotation alone on a plugin with a key the constructor does not
  take, as Drupal core does for such plugins (`skipped_files`). After
  `--apply`, PHPStan (level 0) also checks the converted files, and a file with
  an error about a converted attribute is restored (`phpstan_check`,
  `restored_files`). A type whose files were all skipped no longer raises the
  recommended core floor.
- **A Rector `--apply` could silently change nothing after another config's
  run.** Rector's file cache is shared by the main `rector.php`, the digests
  ruleset and the attributes pass, and it is not keyed on the rules, so a file
  cached as unchanged by one config was skipped by the next: the apply
  reported "0 file(s) changed" with status ok. `run-rector.sh` now clears the
  cache on every pass, and an `--apply` that changes nothing after a dry-run of
  the same code and `rector.php` announced changes fails (status `error`,
  exit 3; `partial` for the digests pass).
- **The router treated a folder of modules as one subject.** `/drupilot
  web/modules/custom` or "port all these modules" ran (or recommended) the
  single-subject flow; `/drupilot-layers` was reachable only by name.
  `next-step.sh` now returns `next: "layers"` with
  `/drupilot-layers <dir> plan` for a directory that is not an extension, not
  a Drupal root, and holds two or more `*.info.yml`, and the router says so
  for a multi-module request; it also mentions `/drupilot-clean` as the
  off-ladder cleanup.
- **`/drupilot --subject DIR` probed the wrong directory, and a bare
  `/drupilot` left residue.** The router took the subject only as the first
  positional word, so a wrapper's `--subject DIR` reached the load-time
  `next-step.sh` call as the literal `--subject`, and the recommendation was
  computed for `$PWD`. A leading `--subject DIR` (or `--subject=DIR`) is now
  accepted as the subject. The router's Step 2 probe also created
  `<subject>/.drupilot/` and an empty state dir through the creating path
  helpers, like `/drupilot-status` did; it now uses the read-only ones.
- **The macOS CI leg ran the strict ShellCheck gate with whatever Homebrew
  shipped.** The Linux leg pins ShellCheck v0.11.0 because another version
  reports a different warning set; macOS now downloads the same pinned
  release (`darwin.aarch64` / `darwin.x86_64`) instead of `brew install
  shellcheck`, so a new ShellCheck release cannot turn it red on its own.
- **`decisions.md` and `port-summary.json` were written mode 0600.** Both
  went through `mktemp` + `mv`, so unlike the other reports in `.drupilot/`
  (0644) a teammate, a CI artifact upload or a wrapper running as another user
  could not read them. They are now made 0644 before the move, as
  `patterns.json` already was.
- **The layer report dropped the metadata lint of modules not registered
  yet.** `layer-report.sh` read `metadata-lint.json` only for subjects in the
  state registry, so a module linted by a `/drupilot-layers` plan but not
  assessed yet showed hygiene `n/a` and counted 0 errors. It now also reads
  the record of every module of the set where `layers.sh` found it.
- **`/drupilot-clean` could lose work it promises to keep.** At the
  `workspace` level: a `copy` placement was discarded when its HEAD matched the
  origin and its tree was clean, although a copy has its own `.git` — an
  issue-fork branch, an unpushed commit or a stash made in the test-bed was
  deleted with it; it now also requires every local branch, tag and stash of
  the copy to point at a commit the origin has. A root with `.drupilot/`
  reports but no module origin to copy them to lost them while the plan said
  "Always kept"; they now go to the root's hidden state dir
  (`reports-<time>`), shown as a planned action. A `legacy` root (recognized
  only by its `<name>-d11` name and workspace pin, which an existing site
  chosen with `--workspace` also gets) could have its database, Composer
  trees or the whole directory removed; it now needs `--foreign-ok` for
  `ddev`/`vendor`, asks a second time like a foreign root, and is never
  removed at the `workspace` level. A refused or skipped root no longer lists
  actions (the plan showed "delete the DDEV project" under a refused root).
- **The cached base core could overwrite and then delete an existing
  docroot.** `ddev-up.sh` restored the cache whenever the root had no
  `composer.json`, and the clean-root guard lets the docroot through with any
  contents. On a site without Composer laid out as `<root>/web` (or a
  `--dir` / `--workspace` pointing at one) the copy overwrote `web/core`,
  `index.php` and the rest; if `ddev composer install` then failed, the
  rollback ran `rm -rf <root>/web`, deleting custom modules, `settings.php`
  and `sites/default/files`; and on success the root was marked as a drupilot
  test-bed, which a later `/drupilot-clean` treats as disposable. The cache is
  now used only when the docroot is absent or holds nothing but DDEV's
  generated settings files, never over a pre-existing top-level entry; a
  rollback removes only what the copy added and puts the original docroot
  back. A root whose docroot held other files is neither cached nor marked.
- **`/drupilot-status` left residue in the subject it looked at.** Its
  load-time probe resolved `state_dir`, `artifacts_dir` and the lockfile path
  with the creating helpers, so one status call on an untouched module created
  `<module>/.drupilot/` (and an empty state dir) inside the developer's
  checkout, exactly what `origin-hygiene.sh` and the doctor's residue check
  flag. It now uses the non-creating `project_state_path` /
  `project_artifacts_path`; a smoke test runs the probe and `next-step.sh` and
  asserts the tree and the data dir are unchanged.
- **The autonomy backstop missed non-interactive wrapper runs.**
  `guard-contrib.sh` escalated a push or MR command to "ask" only for
  `DRUPILOT_AUTONOMOUS=true`, so a `--no-confirm` / `DRUPILOT_NONINTERACTIVE=1`
  run with `DRUPILOT_CONTRIB_MODE=auto` got "allow", although the router
  promises such a run is as safe as `auto`. `DRUPILOT_NONINTERACTIVE` truthy,
  in the hook's environment or as a prefix of the command (how the router
  passes it), now asks the same way.
- **Undeclared-dependency messages were garbled on bash 3.2 (stock macOS).**
  `lint-extension-metadata.sh` built the message with a `case` inside `$(...)`;
  bash 3.2 ends the substitution at the first pattern's `)`, printed a syntax
  error and put the raw `case` text into the viability and port reports. The
  label is now computed by a plain `case`. The smoke tests now fail a test
  whose script printed a shell-level error (syntax error, unbound variable,
  command not found, ...) on stderr, even when its payload looked right, and
  assert the message text; the `portability` gate rejects a `case` inside
  `$(...)` without leading `(` on its patterns, which `bash -n` cannot see.
- **`patterns.sh add` refused valid EREs with an escaped backslash, such as
  `\\Drupal::`.** The PCRE guard rejected any `\d` / `\D` / `(?` substring, so
  the usual way to match a static `\Drupal::` call (an escaped backslash, then
  `Drupal`) was refused, including three patterns of drupilot's own
  `config/deprecations.json`. An escape now counts only when its backslash is
  not itself escaped (the same for the GNU-escape warning). `patterns.sh list`
  also printed detectors through `@tsv`, which doubles backslashes; it now
  shows the stored ERE verbatim, so it can be copied back into `add`.
- **A tested, contributed or pre-0.9.0 port was sent back to `/drupilot-port`.**
  Once a subject had `state.json`, `phase_reached` accepted a stage only when
  that exact key was in `.stages`, so a subject recorded as `tested` (a
  verified suite run, `state.sh record --stage tested`) or `contributed`
  without a `ported` entry still read as unported, and `next-step.sh` returned
  `port` next to `phase: "tested"`. A port finished by an earlier drupilot,
  whose stage was never recorded, also showed as `assessed` everywhere
  (`next-step.sh`, `state.sh list`, `port-summary.sh`, `layer-report.sh`)
  despite its port manifest and patch. A later stage now implies the earlier
  ones (except the opt-in `refactored`), and the port manifest's `phase`
  (`<state_dir>/port-manifest.json`, written when a port or refactor ends)
  counts as evidence of `ported` / `refactored` in `phase_reached` and in the
  state views, which backfill the stage the same way an assessment backfills
  `assessed`.
- **jq 1.6 (Debian 12, Ubuntu 22.04) no longer breaks preflight, layers and
  the negative-control records.** drupilot declares `jq >= 1.6`, but five jq
  programs used a jq keyword as a variable or a shorthand object key
  (`--arg label` / `$label` in `preflight.sh`, `negative-control.sh`;
  `--arg module` in `patterns.sh add`; `{module, scope}` in `layers.sh`;
  `{test, type, label, ...}` in `negative_controls_summary`), which jq 1.7
  accepts and jq 1.6 rejects as a syntax error. On jq 1.6 `preflight.sh` printed
  an empty check list with every `ready` value false, so each command gate
  and the SessionStart hook reported the environment as not ready; `layers.sh`
  failed with "Could not compute the layers". The variables are renamed
  (`$lbl`, `$mod`) and the keys spelled out (`module: .module`,
  `label: .label`); the output is unchanged. A new `check.sh` gate,
  `jq-compat`, rejects the pattern (opt out per line with
  `# jq-compat-ok` and a reason).
- **`/drupilot-setup` did not restore a missing `vendor/`.** `ddev-up.sh`
  skipped Composer whenever `composer.json` existed, so a root whose `vendor/`
  was gone stayed broken (Rector then died with "vendor/bin/rector is
  missing"). It now runs `ddev composer install` (under
  `DRUPILOT_DDEV_CREATE_TIMEOUT`) when `composer.json` is present but
  `vendor/autoload.php` is not.
- **`/drupilot-status` and the router kept recommending `/drupilot-port` after
  a finished port.** `next-step.sh` treated the port as done only when a
  `<state_dir>/phase` marker existed, and nothing ever wrote it. The two
  readers also disagreed on its words (`refactor` vs `refactored`). New
  per-subject state helpers in `common.sh` (`subject_state_file`,
  `state_get`/`state_set`/`state_set_json`, `stage_rank`,
  `phase_record`/`phase_get`/`phase_reached`) keep a hidden `state.json` with
  the highest stage reached and when each stage was recorded. That stage is
  monotonic; `DRUPILOT_STATE_FORCE=true` allows lowering it. The record also
  keeps the legacy marker in sync. `port-report.sh` records `ported` /
  `refactored` from the manifest's phase. A whole-suite `run-phpunit.sh` run
  with a verified (or partially verified) preservation records `tested`.
  `next-step.sh` and the post-edit hook read the stages, falling back to the
  legacy marker; the hook stays fail-safe.
- **The core matrix corrupted the test-bed's PHPStan setup on its first run.**
  `verify-core-matrix.sh` ran `ddev exec "timeout … composer …"` to build a
  reference core. Under `timeout`, `composer` resolved to the test-bed's own
  `vendor/bin/composer` (drupal/core-dev ships one; the container hides it only
  from the top-level shell, through `EXECIGNORE`). That copy's
  phpstan/extension-installer plugin then rewrote the test-bed's
  `GeneratedConfig.php` with paths into the temporary build dir, and left the
  reference core with the package stub. The test-bed's PHPStan crashed from then
  on, and the Drupal 10 leg ran without phpstan-drupal and reported dozens of
  bogus errors (`d10_support: failed`). Every Composer call now names the
  container's own binary by absolute path (new `ddev_global_composer` helper).
  A new `phpstan_extension_config_problem` check verifies that file in the
  test-bed and in each cached reference core. When it is broken the matrix
  regenerates it with `composer install`, and rebuilds the reference core if
  that is not enough. The rollback `composer install` no longer passes
  `--no-audit`, which `install` does not accept.
- **The preservation verdict counted failures the baseline never really ran
  as pre-existing.** The pre-port baseline runs on the Drupal 11 test-bed, where
  an un-ported `^9 || ^10` module cannot even be installed. Every Functional/JS
  test "failed" there with "module 'x' is incompatible with this version of
  Drupal core", and a crashed Kernel group recorded no test at all. After the
  port, real behavior failures in those tests (for example `Undefined array
  key "Drupal_visitor_autologout_login"`) were all filed as pre-existing, and
  the verdict was `pre-existing-failures` with 0 regressions. Such tests are now
  `not-baselined`, with basis `baseline-not-installable` or
  `baseline-group-crashed`. They are listed in the new `baseline.not_baselined`
  (the changed-message flag is kept) and never count as pre-existing. With no
  regression they make the new verdict `not-verified-unbaselined` (exit 3).
  `--baseline` warns when it records such failures. `port-report.md`,
  `next-step.sh` and the docs name the new bucket.
- **A failed Drupal 11 baseline leg made the Drupal 10 leg "fail".** With no
  baseline, every reference-leg finding counted as an incompatibility, because
  that check ran before the no-baseline check. A reference leg with findings is
  now `skipped`, its reason naming the baseline error, and `d10_support` stays
  `declared-not-verified` (exit 0).
- **The core matrix failed legs on findings PHP tolerates at runtime.** A new
  finding kind, `tolerated`, is reported (counted, listed with `~` in the
  summary and in `port-report.md`) but never fails a leg. It covers
  `arguments.count` with *more* arguments than the callee takes (for example
  the Drupal 11 two-argument `ConfigFormBase::__construct()` call on 10.0.11,
  whose constructor takes one: PHP drops extra arguments to userland code,
  while too few stays incompatible). It also covers `method.void` /
  `staticMethod.void` / `function.void` (for example Symfony 7's
  `SessionInterface::set(): void` result used on the Drupal 11 leg).
- **`render-templates.sh --dry-run --json` reported `restart_needed: false`
  for a testing YAML it would write, replace or upgrade.** The real run then
  said `true`. The dry run now sets `restart_needed` for `would-write` /
  `would-replace` / `would-upgrade` of `.ddev/config.testing.yaml`, so a preview
  announces the `ddev restart` the change will need.
- **The core matrix called a `^10` module "verified-static" after checking only
  the newest 10.x.** A `^10` leg resolves to the latest 10.x (10.6), so a call
  to an API added in 10.1-10.6 passed while 10.0 would fatal, and `--cores
  10.3,11` on a `^10` module printed "verified-static" too. `verify-core-matrix.sh`
  now reports `verified-static` only when a clean leg is the declared floor
  minor; otherwise `d10_support` is the new `verified-static-above-floor`, and
  the JSON adds `d10_floor`, `d10_checked` and `d10_floor_checked`.
  `port-report.md` says the floor was not checked, and `make-issue.sh` keeps a
  "verify the declared Drupal 10 floor" remaining task.
- **A hook's phpcs task could be recorded as passing although its ruleset never
  ran.** An explicit `run-phpcs.sh --ruleset PATH` that PHPCS could not load
  (e.g. it references PHPCompatibility, absent from the test-bed) only warned
  and fell back to `Drupal,DrupalPractice`, so `git-hooks.sh --run-equivalents`
  stored `{kind: phpcs, status: pass}` in `hooks-substitution.json`. An
  explicit ruleset that cannot load is now an error (exit 2); the warn-and-
  fallback stays for auto-detected rulesets, and `git-hooks.sh` marks a phpcs
  run that fell back, or stopped before running PHPCS, as `not-runnable`. A
  phpcs exit 2 from real violations (PHPCS 3 exits 2 for unfixable ones) is now
  `fail` instead of `not-runnable`.
- **`classify-deprecations.sh` dropped hook, service and class deprecations.**
  Only `Call to deprecated <kind> X`, `Function X not found` and `X() is
  deprecated in` were recognized; phpstan-drupal's
  `Function x_foo implements hook_foo which is deprecated in drupal:A and is
  removed from drupal:B` (`deprecatedHookImplementation.*`) and `The "S"
  service is deprecated ...` (`getDeprecatedService.deprecated` /
  `staticServiceDeprecatedService.deprecated`) fell into `other`, so even a
  HARD one never blocked Phase 1; runtime notices (`The X class is deprecated
  ...`, `... without the $x argument is deprecated in drupal:A and it will be
  required in drupal:B`) vanished. These forms are now classified (removal from
  "is removed from" / "will be required in" / "will be removed in" ...), and any
  message or identifier that says "deprecated" but cannot be parsed is
  `unknown` (blocking), never `other`.
- **The hooks guard missed `--no-verify` in common command shapes.** The
  `guard-contrib` parser reset its quote state on every line, so a heredoc
  commit message (`git commit -m "$(cat <<'EOF' ... EOF)" --no-verify`) and a
  backslash-continued flag line skipped the "ask before skipping hooks" check,
  while `echo git commit -n` asked. It now scans the whole command as one
  buffer (quote state across lines, continuations joined) and requires `git` to
  be the segment's command word (after `VAR=value`, `sudo`, `env`, `command`,
  shell keywords ...).
- **`negative-control.sh` kept its state under the physical subject path.**
  It resolved the subject with `cd -P` and keyed `negative-controls.json` and
  the `last-test.json` summary update by it, while `run-phpunit.sh` and
  `port-report.sh` key by the logical path: behind a symlink (symlink placement,
  a symlinked parent) the controls landed in another state dir and the report
  showed "n/a". The logical path now keys the state and is what
  `run-phpunit.sh` receives; the physical one is used only for git and hashes.
- **A killed negative control left mutated production code with no way back.**
  A SIGKILL (e.g. a tool timeout during a long Functional run) skips the
  restore trap; the next control then hashed the mutation as the "original".
  Each backup dir now carries a manifest (index -> path, original and mutated
  hash, pid); a control refuses to start while a dead control's backup exists,
  and the new `--recover` restores every file whose hash is still the recorded
  mutation (leaving anything edited since untouched). The "backup kept"
  message lists the index -> path mapping, and the red/green result temp files
  are removed on every exit path, not only on success.
- **A composer timeout left composer running inside the DDEV container.**
  `run_with_timeout` (GNU `timeout`) only killed the host-side `ddev exec` /
  `ddev composer` client; the process kept running in the web container. After
  a `DRUPILOT_DDEV_CREATE_TIMEOUT` hit, `ddev-up.sh` told the user to delete
  `composer.json`/`vendor/`/`web/` while the orphaned `create-project` kept
  writing them, and `verify-core-matrix.sh` removed a half-built reference core
  that the orphan kept recreating. `ddev-up.sh` now stops the in-container
  composer (new `ddev_stop_composer`) before printing the cleanup advice, and
  `verify-core-matrix.sh` applies its composer limit with the container's own
  `timeout` (the host limit is only a later backstop). `run_with_timeout`
  documents that it does not propagate through `docker exec`.
- **Rector / PHPStan / PHPCS failed instead of using the host toolchain when
  DDEV could not start.** Since the explicit `ddev_ensure_running` start, a
  project with `.ddev/config.yaml` and the Docker daemon down made the analysis
  scripts exit 1, although the `analyze` profile does not require Docker and
  the host `vendor/bin` fallback is documented. They now use the new
  `ddev_ensure_running_or_host`: when DDEV cannot be started and the host has
  `vendor/bin/<tool>` and `php`, they warn and run on the host. PHPUnit, the
  toolchain install and the core matrix still require DDEV.
- **`run-phpunit.sh` stopped recording large suites.** The per-test results
  and the baseline comparison were passed to `jq` as `--argjson` arguments; a
  suite of roughly 1000+ test cases (data sets included) exceeds the kernel's
  per-argument limit (128 KiB), so `jq` failed and, behind `|| true`, nothing
  was written: `last-test.json` kept the previous verdict, `--baseline` wrote an
  EMPTY `test-baseline.json` and still reported success, and `--result-file`
  (read by `negative-control.sh`) came back empty. Those payloads now go to `jq`
  as files (`--slurpfile`); a record that still cannot be built is an error
  (no file is written, `--baseline` exits 1, a green run exits 1) instead of a
  silent skip.
- **`run-phpunit.sh` no longer counts a group that executed no test as
  passed.** PHPUnit exits 0 on "No tests executed!" (e.g. a `--filter` that
  matches nothing in a group); such a group is now `empty`, is not counted in
  `ran`/`passed`, and a run where every group was empty is `not-verified-no-tests`
  instead of `verified`.
- **Rector broke Form API callbacks and Drupal 10 compatibility.** The template
  `rector.php` enabled the whole PHP 8.x level set, whose
  `ArrayToFirstClassCallableRector` turned `[$this, 'method']` under `#ajax`,
  `#submit`, `#validate`, `#element_validate` ... into `$this->method(...)`
  closures (not serializable: cached/AJAX forms fatal),
  `AddOverrideAttributeToOverriddenMethodsRector` added `#[\Override]` against
  the sandbox core only (e.g. `buildRevisionCacheId()`, a parent method only from
  11.3 — a compile-time fatal on Drupal 10 / PHP 8.3+), `ReadOnlyPropertyRector`
  / `ReadOnlyClassRector` made properties readonly (breaks
  `DependencySerializationTrait::__wakeup()`), and `NullToStrictStringFuncCallArgRector`
  added `(string)` casts. These rules are now skipped (class_exists-filtered so the
  config loads on any Rector 2.x); `FunctionFirstClassCallableRector` stays — it
  only rewrites string arguments of PHP built-ins typed `callable`, never a Form
  API array. The template carries `drupilot-template-version: 2`; `run-rector.sh`
  backs up and regenerates a `rector.php` from an older drupilot template, and
  warns when a hand-written one does not skip `ArrayToFirstClassCallableRector`.
- **Doc drift:** the `minimal-port` skill, `/drupilot-port` and the orchestrator
  claimed `Drupal11SetList::DRUPAL_11` was applied; the template uses `DRUPAL_10`
  only.
- **`run-rector.sh` swallowed Rector crashes.** Each pass ran as `... || true`,
  so `[ERROR] Could not detect twig set.` (rector/rector >= 2.6.2 with
  drupal-rector 0.21.2) or a PHP fatal (rector 2.5.2 with PHPStan 2.2.16) was
  reported as "0 file(s) would change", exit 0 — a broken toolchain looked like
  "nothing to port". A pass now only counts when Rector exits 0/2 and prints its
  `[OK]` line; otherwise `--json` reports `status: "error"`, `ok: false` and
  `errors: [{pass, exit_code, message}]`, the installed vs known-good versions are
  printed with the fix, the digests pass is skipped after a crashed official
  pass, and the script exits 3. Successful runs keep exit 0 and their output (plus
  the new `status`/`ok`/`errors` keys).
- **A fresh setup installed a broken toolchain.** The ranges resolved to rector
  2.6.7 + drupal-rector 0.21.2, which cannot run at all; setup now pins the
  known-good set and smoke-tests it.
- **The lock missed `rector/rector` and was never re-synced after the toolchain
  install** (it was only captured by `ddev-up.sh`, before the toolchain existed).
  `install-toolchain.sh` re-syncs it after every install.
- **`run-phpunit.sh` never ran a single test.** It stored the group list in an
  array named `GROUPS`, a bash special variable (the user's group IDs) whose
  assignments bash silently ignores, so the loop iterated over GIDs (`1000 970
  10`), found no `tests/src/1000`, exited 0 and recorded `not-verified-no-tests`
  for every subject — the preservation gate never verified anything. The array is
  now `TEST_GROUPS`, with a self-check that it holds only group names, and the new
  `special-vars` gate keeps the whole class out. On the autologout 8.x-1.4 lab
  subject the Kernel, Functional and FunctionalJavascript suites now really run
  (pre-port: red, `regression`, as the module still declares `^9.2 || ^10`).
- **PHPUnit was never installed, and its absence was reported as a regression.**
  Nothing installed `drupal/core-dev`, which `drupal/recommended-project` does not
  ship, so every group failed with exit 127. `/drupilot-setup` (Step 3c) and the
  `ddev-environment` skill now install `drupal/core-dev` matched to the installed
  core (`core_dev_requirement`, with `-W`). `run-phpunit.sh` detects a missing
  `vendor/bin/phpunit` up front (and treats a PHPUnit exit 126/127 the same way):
  it records `not-verified-blocked` with the reason, prints the exact install
  command, and exits 2 instead of claiming a regression.
- **`run-phpunit.sh` no longer counts an empty test directory as a passing group.**
  A group runs only when `tests/src/<Group>` holds at least one `*Test.php`.
- **The port report no longer claims "the subject ships no tests"** whenever the
  verdict is `not-verified-no-tests`: it says so only when the test run confirmed
  the subject has none, otherwise it names the `--type` scope that held no test
  (and points to `--type all`); `not-verified-blocked` now shows the recorded
  reason.
- **`ddev-add-ons.sh --contrib` aborted on every platform** in the
  recommended-project layout: `sed -i 's#ddev symlink-project#: # ...#'` used `#`
  both as the delimiter and inside the replacement (`unknown option to 's'` on GNU
  sed; BSD sed additionally misreads `-i`). It now uses `sed_inplace` with a `|`
  delimiter, and a failed edit warns instead of aborting the setup.
- **Bash 3.2 (stock macOS) compatibility.** The scripts and hooks used bash 4-only
  syntax, so on `/bin/bash` 3.2 `config_bool` died with `${v,,}: bad substitution`.
  The worst effect: the `guard-contrib.sh` PreToolUse hook crashed before deciding,
  so the "an autonomous run never pushes" backstop never returned `ask`. Fixed by
  replacing every `${x,,}` with `lc` (`common.sh`, `core-strategy.sh`,
  `make-issue.sh`, the three hooks), `declare -A` in `deps-status.sh` with a
  `sort -u`-deduplicated list (same output), and expanding possibly-empty arrays
  with `${arr[@]+"${arr[@]}"}` in `run-phpcs.sh`, `run-phpunit.sh` and
  `install-deps.sh` (a bare `"${arr[@]}"` is "unbound variable" under `set -u`
  before bash 4.4).
- **DDEV add-on detection read a width-truncated table.** `ddev add-on list
  --installed` cuts long names (`ddev-selenium-stand…`), so `ddev-add-ons.sh`
  never saw Selenium and reinstalled it, with a ~47 s `ddev restart`, on every
  run; `lock-sync.sh` never recorded it; and `preflight.sh` always reported the
  Selenium add-on as missing. All three now use `ddev_addons_installed` (JSON
  output). `lock-sync.sh` also captures add-on versions when DDEV is stopped, and
  `preflight.sh` reports the installed Selenium version when it finds a DDEV
  project.
- **The router and `/drupilot-status` always recommended `/drupilot-doctor`.** Their
  load-time `` !`...` `` line passed the literal placeholders `"<ready.analyze>"` etc.
  to `next-step.sh` (a load-time line runs before the model can substitute
  anything), and `next-step.sh` normalized any unrecognized value to `false`. Both
  commands now pass the new `next-step.sh --from-preflight` (alias
  `--ready-from-preflight`), which reads readiness from one `preflight.sh --profile
  all --json` run. `next-step.sh` now treats a non-boolean readiness value as
  *unknown* (warning on stderr, filled from preflight; still `true` if preflight or
  `jq` is unavailable, as documented) instead of `false`; explicit
  `true`/`false`/`1`/`0`/`yes`/`no`/`on`/`off` keep their meaning, and the ladder no
  longer uses the bash 4-only `${x,,}`.
- **`/drupilot-setup` failed to load (Step 4).** Its load-time line ran
  `ensure-gitignore.sh --root "<drupal_root>"` verbatim (exit 1, "Root directory not
  found: `<drupal_root>`"), and even a valid root would have written `.gitignore`
  before the Step 1 gate. It is now a fenced block the model runs with the resolved
  root. `ensure-gitignore.sh` rejects an unsubstituted `<placeholder>` with a clear
  error and gains `--subject DIR` (derives the enclosing Drupal root, or the
  test-bed root `resolve-workspace.sh` targets for a loose subject); `--root` keeps
  precedence and `$PWD` detection is unchanged. `scripts/dev/check.sh`'s
  `bang-lint` gate now passes and is no longer in its known-failing list.
- **`templates/phpcs.xml.dist.tmpl` produced invalid XML.** Its header comment
  contained `--config-set`, and `--` is forbidden inside an XML comment, so any
  bare `phpcs` run at the Drupal root (or an IDE using the ruleset) aborted with
  "Ruleset is not valid". drupilot's own scripts were unaffected because they pass
  `--standard=Drupal,DrupalPractice`. The comment no longer spells out options,
  and now lists all three `installed_paths` that `run-phpcs.sh` registers. The
  `templates` gate of `scripts/dev/check.sh` now passes and is no longer in its
  known-failing list.
- **`templates/phpstan.neon.tmpl` set the deprecated `drupal: drupal_root: web`.**
  phpstan-drupal >= 1.3 ignores it and prints "The drupal_root parameter is
  deprecated" on every run (all versions allowed by `^2.0`). The block is removed;
  the Drupal root is discovered automatically, and findings are unchanged
  (verified with phpstan-drupal 2.2.2). `run-phpstan.sh` points at
  `render-templates.sh --only phpstan --force` when it meets a config generated by
  an older drupilot that still has the parameter.
- **`run-phpstan.sh` discarded PHPStan's stderr and called a crash "found
  issues".** In `--json` mode stderr went to `/dev/null`, so config deprecations
  and crash messages vanished, and since PHPStan exits 1 both for findings and for
  "could not analyse" (invalid config, missing path), a crash with an empty report
  was logged as "PHPStan found issues". stderr is now captured and relayed;
  deprecation notices are surfaced as warnings; a run that produced no report (or
  hit an internal error) exits **3** with the cause, and `--json` then prints
  `{totals: null, files: {}, drupilot: {status: "crashed", crash: [...]}}` instead
  of nothing. Findings still exit 1 and a clean run 0.
- **`post-edit-lint.sh` printed "No such file or directory" on stderr** for every
  edit before a phase was recorded (the redirection error escaped its
  `2>/dev/null`). Harmless, now silent.
- **`make-patch.sh --local` diffed against an unrelated base.** On a local
  branch with no upstream (e.g. one cut from a release tag) it used
  `origin/HEAD`, producing a reverse diff of upstream history (a 43-file,
  3,760-line patch for a one-line port). `git_port_base_ref` now uses the
  upstream only when it is an ancestor of HEAD (merge-base otherwise) and,
  without an upstream, the closest fork point among `origin/HEAD`, the other
  remote branches and the nearest tag (their merge-base when not an ancestor),
  warning whenever it does not use `origin/HEAD` as-is; an explicit `--base`
  that is not an ancestor of HEAD is honored with a warning. A remote-less repo
  keeps the HEAD default. `check-port-safety.sh` shares the same base.
- **The local patch showed up as an untracked file in a nested subject repo**
  (the Drupal root's `.gitignore` does not apply to it). It is now hidden through
  that repo's local `.git/info/exclude` — the filename and location are
  unchanged and the tracked `.gitignore` is never edited. The subject-side
  `.drupilot.json` written by `copy`/`symlink` placement is hidden the same way.
- **`ddev-up.sh` and `run-phpunit.sh` printed the preflight report (and
  `ddev-up.sh` the ddev/composer output) on stdout**, breaking the
  payload-only-stdout rule; it all goes to stderr now.
- **`place-subject.sh` wording:** a `move` removes the original directory; the
  message no longer says it "is now empty". A `move` re-run keyed on the old path
  is also detected when the test-bed comes from `DRUPILOT_WORKSPACE_DIR`.
- Cleared the 12 `shellcheck -S warning` findings with no behavior change: dropped
  the unused `PHP_MIN` (`preflight.sh`) and `PF_RC` (`check-prereqs.sh`), collapsed
  the redundant `drupal/core*|drupal/core-*` pattern (`deps-status.sh`), and
  documented the intentional cases inline (`HAS_*` in `preflight.sh`, the
  compatibility `--ready-test`/`--ready-contribute` flags in `next-step.sh`, the
  runner word-split in `run-phpunit.sh`).
- **`check-port-safety.sh` scanned nothing when the subject was a symlink**
  (`DRUPILOT_PLACEMENT=symlink`): `find` does not descend into a symlinked
  starting point, so the gate reported "0 PHP file(s)" and passed. The subject is
  now scanned (and matched against git) by its physical path; its logical path
  is still used to locate the Drupal root it sits in.
- **A crash of the digests Rector pass failed the whole run and was blamed on the
  toolchain.** A broken upstream `drupal-digests` commit (a rule file without
  `<?php`) made `run-rector.sh --digests` exit 3 with `status: "error"` even
  though the official pass succeeded, printed toolchain-repair advice, and froze
  the broken SHA in the lockfile so every later run crashed the same way. A
  digests-only crash is now `status: "partial"`, `ok: true` (the official result
  stands), `digests_status: "error"` and exit 4, with advice to pin
  `--digests-ref`/`DRUPILOT_DIGESTS_REF` or set `DRUPILOT_USE_DIGESTS_RULES=false`;
  the SHA is frozen only after the digests pass finishes normally. The `--json`
  payload gains `digests_status` and `digests_sha`. Exit 3 now means only that
  the official pass crashed.
- **The Rector crash excerpt dropped the offending class name**: the indented
  continuation lines of a boxed `[ERROR]` message are now joined into it (e.g.
  `Expected an existing class name. Got: "ReplaceDrupalAttachTabledragRector"`).
- **`DRUPILOT_PHP_TARGET` never reached Rector**: the rendered `rector.php`
  always had `->withPhpSets(php83: true)`, so a PHP 8.4 target moved PHPStan,
  PHPCS and DDEV but left Rector on 8.3. The template now uses a `{{PHP_SET}}`
  token that `render-templates.sh` and `run-rector.sh` derive from the target
  through the new `rector_php_set_arg` helper (`8.3` → `php83`, `8.4` → `php84`,
  an unconfirmed `8.5` → `php84` with a warning); `--set PHP_SET=…` overrides
  it. The template marker is now `drupilot-template-version: 3`, so existing
  drupilot-generated copies are backed up and regenerated.
- **Older drupilot `phpstan.neon` / `phpcs.xml.dist` were never healed in an
  autonomous run**: `render-templates.sh` reported them as `differs` (exit 3)
  just like a hand-edited file, and `auto` keeps those. Both templates now
  carry a `drupilot-template-version` marker; a copy with the drupilot header
  but an older (or no) marker is backed up and regenerated without `--force`
  (new status `upgraded`, `would-upgrade` in `--dry-run`). A current-generation
  copy that differs is still treated as hand-edited.
- **Rendered template headers documented their own tokens with the substituted
  values** (`#   2 — analysis level`, `web/modules/custom/foo — the extension to
  check`). The headers of `rector.php`, `phpstan.neon` and `phpcs.xml.dist` now
  describe what is filled in without spelling the tokens.
- **The port-safety serialization check missed every promoted `private` /
  `readonly` property on mawk** (the default awk on Debian 12 / Ubuntu 22.04):
  `php-scan.sh` used a regex interval (`\.{0,3}`) that mawk 1.3.4-20200120
  matches as literal text, so a port that added `private readonly` promoted
  services to a form passed the gate. The pattern no longer uses an interval,
  and the `check.sh` portability gate now rejects regex intervals in awk
  regex literals.
- **`/drupilot auto` (or `next`, `status`, or a natural-language request) broke
  the router's load-time next-step line**: it passes `$1` as `--subject`, and
  `next-step.sh` died with "Subject directory not found: auto". A `--subject`
  that is not a directory now falls back to the current directory with a
  warning, matching the router's own state detection (also covers
  `/drupilot-status`).
- **The port-safety gate passed a port that added `#[\Override]` while the core
  range still includes Drupal 10.** `override-attribute` was a warning even when
  the port introduced it, although both phases forbid adding it then (the parent
  method may exist only on newer cores, and PHP 8.3+ fatals at compile time). A
  port-introduced one is now an error (exit 3); an unattributed one stays a
  review warning and a pre-existing one is still skipped.
- **A `copy` placement dropped files the module ships**: the residue
  exclusions (top-level `vendor/`, `.ddev/`, ..., `node_modules/`, symlinks
  escaping the tree) were applied without checking git, so a module that
  commits a bundled `vendor/` library arrived in the test-bed without it.
  Anything git tracks is now always copied (a tracked escaping symlink is kept
  with a warning); only untracked residue is excluded, the same rule
  `residue_list` already used.
- **`origin-hygiene.sh --check` false positives and misses**: on an origin that
  is not a git checkout, the `.drupilot.json` pointer a copy/symlink placement
  writes on purpose was reported as drupilot residue (`clean: false`); it is now
  listed under a new `expected` field and does not make the origin unclean.
  After a `move`, checking the original (now gone) path reported
  `origin-missing`; the baseline is now found under `DRUPILOT_WORKSPACE_DIR` or
  the `<name>-d11` sibling by its recorded source path, and the moved tree is
  checked.
- **More scripts printed the human preflight report on stdout**: `ddev-add-ons.sh`
  on every run, and `run-rector.sh` / `run-phpstan.sh` / `run-phpcs.sh` /
  `run-upgrade-status.sh` when their gate failed, so a caller parsing `--json`
  got the report instead of a payload. It goes to stderr now, as in
  `ddev-up.sh` and `run-phpunit.sh`.
- **Every FunctionalJavascript test failed to open a browser session** ("No
  nodes support the capabilities in the request"). The rendered
  `.ddev/config.testing.yaml` re-declared `MINK_DRIVER_ARGS_WEBDRIVER` without
  `"w3c":true`; DDEV loads it after the Selenium add-on's config, so it replaced
  the add-on's working value, and Drupal 11.4's `WebDriverTestBase` forces `w3c`
  to false when the value omits it. The template no longer sets the variable
  (the add-on owns it) and only adds `SYMFONY_DEPRECATIONS_HELPER`. It now
  carries `drupilot-template-version: 2`, so `render-templates.sh` upgrades an
  older generated copy on its own (after a backup), and an upgrade now reports
  `restart_needed: true` like a write does. The header no longer prints its own
  substituted Selenium host ("selenium-chrome:4444 is the ... e.g.
  selenium-chrome:4444").
- **Read-only checks started stopped DDEV projects.** `ddev_running` probed with
  `ddev exec true`, which starts a stopped project, so `preflight.sh`,
  `/drupilot-status`, `/drupilot-doctor`, `next-step.sh` and `drupal_runner`
  could bring containers up as a side effect, and `ddev-up.sh` always logged
  "already running — skipping 'ddev start'" for a project it had just woken.
  `ddev_running` now reads the project status from `ddev describe -j` (or
  `docker ps` by the project's labels without jq) and never starts anything;
  the new `ddev_project_status` returns the raw status. The scripts that run the
  toolchain (`run-rector.sh`, `run-phpstan.sh`, `run-phpcs.sh`, `run-phpunit.sh`,
  `run-upgrade-status.sh`, `install-toolchain.sh`) call the new
  `ddev_ensure_running`, which starts a stopped project explicitly and logs it.
- **`ddev-up.sh` could hang for good on `ddev composer create-project`.** The
  step now runs with stdin closed and a wall-clock limit,
  `DRUPILOT_DDEV_CREATE_TIMEOUT` (default 900 s, `0` = no limit, through
  `timeout`/`gtimeout` via the new `run_with_timeout` helper), and stops with
  an actionable error. `ddev start` is a real start of a stopped project, and
  the status is checked again afterwards.
- **`--help` printed far more than the help.** Every script's usage printer
  grepped all `# ` comment lines of the file, so the output carried the
  `# shellcheck source=...` directive, section separators and internal
  comments. A shared `print_usage` helper in `common.sh` now prints only the
  header block between the two `# ====` rules, and every script uses it.
- **The lockfile's `drupilot_version` could not tell which drupilot wrote it.**
  It was set only by `lock-sync.sh` at setup. Every lock write
  (`lock_set`/`lock_set_json`) now refreshes it from `plugin.json`, and
  `lock-sync.sh` adds `drupilot_revision` (new `plugin_revision` helper:
  `git describe --tags --always --dirty`) when drupilot runs from a git
  checkout. A development branch still carries the last released version
  (0.8.4 here) until the release bumps it, so the revision is the field that
  names the exact build. An installed copy drops a stale revision.
- **`run-phpcs.sh` and `run-phpunit.sh` printed `ddev exec`'s red "Failed to
  execute command ...: exit status N"** for every violation or failing test
  run, next to their own verdict. They now run the tool through the new
  `run_dropping_ddev_failure_line` helper, which leaves stdout untouched and
  drops only that wrapper line from stderr. Both scripts still report the exit
  code themselves.
- **A Rector dry run that found changes printed a red "Failed to execute
  command ... exit status 2"** from `ddev exec` on stderr, although exit 2 is
  Rector's normal "changes found" result. `run-rector.sh` drops that wrapper
  line when the run finished normally; a real crash keeps it.

- **README corrections (English and Spanish).** A bare `/drupilot <path>` only
  recommends the next step: the guided port example now uses `full` or a plain
  request, and says it asks for confirmation before starting. The commands table
  shows each command's real arguments (`/drupilot-setup [subject-path] [--php
  X.Y]`, `/drupilot-layers … [--edges all|declared]`, `/drupilot-clean … [--all
  [dir]] … [--core-cache]`, and the others). The test and patch use cases no
  longer pass flags the commands do not accept: `--type`, `--coverage` and
  `--base` are shown as direct script calls. The exit-code legend now lists `4`
  and what each code means. The `verified-partial` test verdict is explained.
  Version notes no longer describe unreleased behavior as a past release.
- **A boolean `false` written in `.drupilot.json` is now honored** instead of
  falling back to the default. For example `"DRUPILOT_DETERMINISTIC": false` or
  `"DRUPILOT_USE_DIGESTS_RULES": false` now turn the feature off, as the string
  `"false"` already did.
- **`/drupilot-clean --level workspace` no longer copies the cached Drupal 10
  reference cores** (`.drupilot/cores/`, about 200 MB each) out of the test-bed
  with the reports. They are a rebuildable cache, so the clean now frees them.
- **The "large refactor" warning uses one rule everywhere.**
  `DRUPILOT_VIABILITY_THRESHOLD` takes `small`, `medium`, `large` or `xl` (the
  S/M/L/XL verdict), and the warning appears only when the verdict is above it:
  with the default `medium`, an M verdict no longer gets the warning in some
  places and not in others.
- **More README corrections (English and Spanish).** By default a loose
  checkout is moved into the test-bed (it was described as left untouched). A
  module inside a repository is never moved, but a `symlink` placement is kept
  and then edits the module in the repository (it was described as always
  copied). A `copy` placement leaves out only untracked residue and symlinks.
  The `.drupilot/` folder lists everything it holds (`port-summary.json`, the
  layer plans, `backups/`, `rector-attributes.php`, `cores/`), and the local
  patch is written next to the module, not there. `DRUPILOT_ASSUME_YES` covers
  the scripts' yes/no confirmations with or without a terminal, takes the
  default of a multi-option choice, and never confirms the `/drupilot-clean`
  deletion. `DRUPILOT_KEEP_D10` applies only while the core target strategy is
  `auto`; `DRUPILOT_CODER_CONSTRAINT` applies only to a fresh toolchain
  resolve. The push/MR guard also asks under `DRUPILOT_NONINTERACTIVE=1`, and
  `DRUPILOT_HOOKS_GUARD` is listed among the hook switches. Not every script
  takes `--subject`; `run-upgrade-status.sh` passes Drush's exit code through;
  the developer gate validates the JSON of `config/`, `hooks/` and
  `.claude-plugin/`; the smoke-test description no longer reads as the full
  list. The attribute conversion and the Drupal 10 verification have their own
  sections, and the table of contents lists them and the eight use cases. The
  Spanish README uses one term for the test-bed ("banco de pruebas") and for
  the known-good toolchain ("verificado").
- **Further README corrections (English and Spanish).** A bare `/drupilot
  <subject>` only recommends the next step unless `DRUPILOT_AUTONOMOUS=true`
  (or `--no-confirm`) is set, which makes it run the whole flow hands-off; the
  Quick start, the commands table, the guided-port use case and the hands-off
  section now say so. The test verdicts are given by their recorded names
  (`verified`, `verified-partial`, `regression`, `pre-existing-failures`,
  `not-verified-unbaselined`, `not-verified-blocked`, `not-verified-no-tests`),
  and the port summary lists them with the ones that block a port. A failing
  test the baseline does not contain counts as a regression, and a missing
  dependency in the baseline also leaves a test not baselined. The Drupal 10
  support values `failed` (a blocker) and `n/a` (no Drupal 10 half) are
  documented. The `tested` stage is recorded after a `verified` or
  `verified-partial` whole-suite run. The exit-code table adds `make-patch.sh`
  (a contribution patch that does not apply is discarded) and
  `run-phpunit.sh --baseline` (nothing ran) to exit `1`. The scripts reference
  lists the shared `lib/` libraries (`common.sh`, `ext-scan.sh`,
  `php-scan.sh`). The contribute examples use a real path
  (`web/modules/contrib/some_module`). The Spanish README fixes several
  translation slips: it no longer turns the staged plan's guarantee into a
  possibility ("aun así"), says what a crashed baseline group is, and uses
  one term each for the baseline, the PHP target and the learned pitfalls.

## [0.8.4] - 2026-06-23

### Fixed
- **`run-rector.sh`: drupilot template now takes precedence over the vendor fallback.**
  The previous priority (`vendor/palantirnet/drupal-rector/rector.php` before the
  template) caused a race condition: if `run-rector.sh` ran after `composer install`
  completed, it would copy the vendor example file — which uses the legacy procedural
  API (`$rectorConfig->sets([…])`) and includes Drupal 8/9 sets not needed for a
  D10→D11 port — instead of the correct drupilot template. Modules set up in that
  window received an incomplete ruleset without any warning.
- **`run-rector.sh`: existing `rector.php` files using the legacy API are automatically
  regenerated.** If a `rector.php` is already present but does not use
  `RectorConfig::configure()`, it is now replaced from the drupilot template instead
  of being left untouched, preventing silent re-runs with an outdated configuration.
  If the template is unavailable in that scenario, the script aborts with an
  actionable error.
- **`rector.php.tmpl`: removed `Drupal11SetList::DRUPAL_11`.** That set does not exist
  in `palantirnet/drupal-rector ^0.21` (the pinned constraint) and belongs to a future
  D12 port, not to porting to D11. Referencing it caused a fatal class-not-found error
  on any sandbox that used the template path. `Drupal10SetList::DRUPAL_10` is the
  correct and sufficient set for a D10→D11 port (covers APIs deprecated in D9/D10
  that are removed in D11).

## [0.8.3] - 2026-06-21

### Fixed
- Align `marketplace.json` `metadata.version` (the marketplace-catalog version) with the released plugin version, so it no longer lags behind the `plugins[]` entry.
- Remove the dangling `[Unreleased]` reference-link from the changelog footer; there is no `[Unreleased]` section between releases, and it is re-added with the next unreleased change.

## [0.8.2] - 2026-06-21

### Changed
- **`FLOW.md` / `FLOW_es.md` diagram wording.** The Phase 1 node now reads "the AI
  **orchestrates** Rector's 3 passes" (was "applies"): passes 1 (official) and 2
  (digests) are run by the deterministic `run-rector` script while the AI reviews
  and decides; only pass 3 (ad-hoc rules / manual fixes) is the AI's own work.
  Added a note on the Drupal-version target per phase — Phase 1 can keep
  `^10 || ^11` or go `^11`-only (Drupal 10 support kept this way is
  declared-not-verified), while Phase 2 is Drupal 11 only (`^11`, new major).

## [0.8.1] - 2026-06-21

### Added
- **README section "What's automatic vs. where the AI decides"** (mirrored in
  `README_es.md`) — documents the split between the deterministic, scripted code
  fixes (official Rector, the frozen digests layer, `phpcbf`, the `PostToolUse`
  hook) and the report-only analyzers (`phpcs`, PHPStan, preflight, detection,
  insight tools), then enumerates where the AI applies judgment and the
  conductor pattern (AI runs a script, reads the result, decides the next),
  including the lone hook exception. Fills a documented gap: the README explained
  the deterministic side well but never stated where the AI acts. Includes a
  **hooks sub-table** framing what a hook is (an automation the harness fires —
  neither the AI nor the user), when each one acts, what it does, and whether its
  output goes to the AI or to the user.
- **`FLOW.md` (mirrored in `FLOW_es.md`)** — a visual, end-to-end Mermaid diagram
  of the flow: which tool runs at each step, where the AI steps in, the two
  porting phases with their result milestones, and the always-on hooks with their
  recipients. `README.md` links to `FLOW.md` and `README_es.md` links to
  `FLOW_es.md` from the architecture section.

## [0.8.0] - 2026-06-20

### Changed
- **Developer-facing outputs now land in the visible `.drupilot/` dir** instead of
  next to the module: `port-report.md` and `viability-report.md` (previously
  written beside the subject or in the hidden state dir) and coverage HTML
  (previously `.drupilot-coverage/` / the hidden state dir) all resolve through
  `project_artifacts_dir()`. The gitignore managed block now ignores `.drupilot/`
  and the local `*-port-to-drupal-11*.patch` previews (closing a leak: those were
  not ignored before and could be committed into a contribution).

### Fixed
- **drupilot's own artifacts can never leak into a contribution patch, even from a
  module's nested git repo.** A loose contrib checkout keeps its own `.git` after a
  `move`, and the Drupal-root `.gitignore` does not reach a nested repo — so the
  `.drupilot/` dir now writes a self-ignoring `.gitignore` (`*`) on creation
  (`project_artifacts_dir`), making it invisible to git in ANY repo it lands in,
  and `make-patch.sh --local` explicitly excludes `.drupilot/`, `.drupilot.json`
  and any `*-port-to-drupal-11*.patch` from the generated diff as a backstop.
- **`resolve-workspace.sh` never silently adopts an unrelated `<name>-d11`.** It
  reuses an existing dir only when it carries a Drupal/drupilot signature
  (`.ddev/config.yaml` or `web/core/lib/Drupal.php`); otherwise it bumps to the
  next free `<name>-d11-N`, so it never runs `ddev`/composer against a directory it
  did not create. `place-subject.sh` is now idempotent on a `move` re-run keyed on
  the (relocated) original path, logs the relocation as `old -> new`, and persists
  a subject-side workspace marker for copy/symlink so a loose re-run reuses the
  same test-bed instead of deriving a fresh sibling.
- **A loose module/theme checkout is no longer scaffolded on top of.** When
  pointed at an extension that is not already inside a Drupal site, `ddev-up.sh`
  used to fall back to `PROJECT_DIR=$PWD` and run `ddev composer create` (or, if
  the module shipped its own `composer.json`, inject the dev toolchain) into the
  module's own directory — intermixing the Drupal scaffold with the module's
  files. It now resolves a sibling test-bed via `resolve-workspace.sh` and leaves
  the checkout pristine until `place-subject.sh` places it.
- **`ddev config` no longer leaves a stray `.ddev/` behind on an aborted create.**
  The "project root is not clean for `ddev composer create`" guard now runs BEFORE
  `ddev config`/`ddev start`, so a dirty root is rejected without first writing a
  `.ddev/` directory into it.
- **`preflight.sh` `analyze` profile now validates the PHP that will actually
  run, not the host's.** The static toolchain (`run-rector`/`run-phpstan`/
  `run-phpcs`) runs through `$(drupal_runner)`, i.e. **inside DDEV** (`ddev exec`)
  whenever the container is up — yet preflight only ever checked the *host* PHP.
  That produced two wrong verdicts: a false "not ready for analysis" when the host
  lacked PHP/Composer but DDEV was up (the toolchain would have run fine via
  `ddev exec`), and a misleading version warning when the host PHP differed from
  DDEV's freely-configurable `php_version`. The `analyze` checks now mirror
  `drupal_runner`: when DDEV is running they validate the DDEV `php_version`
  against the target (Composer is satisfied via `ddev composer`) and surface a
  "realign DDEV to the target" hint on a mismatch; with no running DDEV they fall
  back to the host PHP/Composer checks as before.

### Added
- **Loose-checkout placement is now a real two-script procedure** in the setup
  flow (`/drupilot-setup`, the `ddev-environment` skill and the
  `drupal-port-orchestrator` agent). `resolve-workspace.sh --json` decides WHERE
  the test-bed and subject live (a loose checkout targets a sibling
  `<name>-d11` root, kept pristine; a module already inside a Drupal root reports
  `loose:false` — full back-compat) and `place-subject.sh` places the subject under
  `web/<modules|themes|profiles>/custom/<name>` after Drupal is created, replacing
  the old prose that only described moving files by hand. `/drupilot-setup` adds a
  tabbed **"Workspace layout"** decision — Sibling dir + move (recommended) /
  symlink / in-place (legacy), persisted to `DRUPILOT_PLACEMENT`, non-default
  options gated on `autonomous=false`.
- **Single visible `.drupilot/` artifacts directory** at the Drupal root
  (`project_artifacts_dir()` in `common.sh`, override `DRUPILOT_ARTIFACTS_DIR`).
  It is the one place a developer opens to see what a port did: `port-report.md`,
  `viability-report.md`, coverage HTML under `coverage/`, and the local preview
  `*.patch`. It is gitignored, so it can never leak into a contribution. The
  machine-readable cache (`assess.json`, `last-test.json`) and the determinism
  lockfile stay HIDDEN under `$HOME` on purpose — they must survive `git clean`
  and never enter a patch — so only human-facing outputs moved in-tree.
- **Didactic "Drupal 9/10 → 11 changes, explained" section in the port report.**
  `port-report.sh` gained `--changes-log FILE` (defaulting to the captured
  Rector + PHPStan deprecation log in the state dir); it runs that text through
  `explain-deprecations.sh` and renders each recognized change **grouped by
  migration area** (Entity API, Twig 3, CKEditor 5, jQuery UI, Messenger, …) with
  what changed, the fix and a drupal.org change-record link. `deprecations.json`
  entries gained a `category` field for the grouping, and a manifest `manual_edits`
  item may now be an object `{edit, why, change_record}` so manual changes carry
  their rationale into the report. Every field stays optional (renders from
  partial data, never invents).
- **New config keys** — `DRUPILOT_PLACEMENT` (`move`|`symlink`|`copy`, default
  `move`), `DRUPILOT_WORKSPACE_DIR` (default empty = sibling `<name>-d11`) and
  `DRUPILOT_ARTIFACTS_DIR` (default empty = `<root>/.drupilot`).
- **`preflight.sh --deep`** — when DDEV is up, probe the container's real PHP via
  `ddev exec php` instead of reading `php_version` from `.ddev/config.yaml`. Used
  by `/drupilot-doctor`'s full report; the per-command gate and the SessionStart
  hook stay on the cheap config read (no extra `ddev exec` per gate/session).
- **`ddev_php_version()` helper** in `scripts/lib/common.sh` — reads a project's
  configured DDEV `php_version` from the YAML without starting or exec-ing DDEV
  (cheap and safe in gates/hooks). `detect-php.sh` now reuses it instead of
  duplicating the parse.

## [0.7.1] - 2026-06-14

Correctness fixes from testing the v0.7.0 insight tools against real contrib
modules (file_version, amp_video_embed_field_formatter, token, gin, admin_toolbar,
pathauto). The reasoning these tools feed was giving wrong advice in real cases.

### Fixed
- **Core target no longer regresses an already-Drupal-11-compatible requirement.**
  `recommend_core_target` (core-strategy) was rewriting a precise existing
  declaration to a generic range — e.g. `^11.2` → `^11` (dropping the 11.2 minor
  floor) or `^10.3 || ^11 || ^12` → `^10 || ^11` (dropping the future `^12` and the
  10.3 floor). A new `keep-current` resolution keeps the module's declaration
  unchanged when it is already D11-compatible (auto strategy, no BC break); the
  developer can still narrow it via the core-target choice.
- **Version-bump verdict now flags a MAJOR when the port drops a supported core
  major.** Porting `^8 || ^9` (or `^9 || ^10`, `^9.3 || ^10`) to `^10 || ^11` drops
  Drupal 8/9 support — backwards-incompatible for those sites → MAJOR. The old
  check only caught the `d11-only` path, so the common `keep-d10` port was
  under-reported as MINOR.
- **Dependency panel recognizes Drupal core modules.** `deps-status.sh` no longer
  flags core submodules (`field`, `image`, `menu_link_content`, `toolbar`, `path`,
  …) as "no D11 release" blockers; the drupal.org feed's `<error>` / "no release
  history" response is reported as `not-on-drupalorg` (verify) instead of a hard
  blocker, and only a confirmed contrib project without a D11 release counts as a
  blocker. Verified that a genuine blocker (e.g. `amp`) is still caught.
- **Upstream issue search no longer false-positives** on a title that merely
  mentions `core_version_requirement`; the Drupal-11-effort title match is tighter
  (anchored `11` / `d11` / `11.x`).
- **Deprecation explainer no longer mis-flags `parse_url()`** (and similar) as
  `\Drupal::url()`; the pattern is anchored to `\Drupal::url`.

## [0.7.0] - 2026-06-14

Phase 2 — an exhaustive UX/capability overhaul making the port guided, pleasant
and developer-in-control: tabbed decisions at every consequential fork, a
first-class patch decoupled from contribution, visible state (preservation
verdict, what-changed report card, frozen lock), and new insight tools
(dependency D11 panel, upstream issue search, deprecation explainer).

### Added
- **Tabbed-choice primitive `choose_one()`** in `scripts/lib/common.sh` — the
  multi-option sibling of `confirm()`. Labeled options to stderr, chosen value to
  stdout, `DRUPILOT_CHOICE_<KEY>` override (validated against the options), real
  `/dev/tty` selection, and a fail-safe default when there is no terminal. It is
  the script-side fallback for the `AskUserQuestion` tabs the commands use.
- **Per-project preference tier `.drupilot.json`** at the Drupal root, read by
  `config_get` **between** the env override and `defaults.json` (env still wins),
  written by the new `prefs_set()`. This is how in-flow tabbed answers (core
  target, PHP target, refactor scope, contrib mode) persist across runs.
- **`config_enum()`** in `common.sh` (clean error + non-zero on an out-of-set
  value), wired into `preflight.sh` as a **non-fatal** sanity check that warns
  early on a misconfigured `DRUPILOT_CONTRIB_MODE` / `CORE_TARGET_STRATEGY` /
  `REQUIRE_PHP_FLOOR` / `GENERATE_RULES` (env or `.drupilot.json`).
- **`announce_patch()`** presentation helper for a consistent "patch ready + how
  to apply it" summary (stderr only, stdout stays the patch path).
- **`scripts/env/ensure-gitignore.sh`** + `templates/gitignore.tmpl` — idempotently
  ensures the Drupal root's `.gitignore` ignores drupilot's generated artifacts
  (`.phpstan-cache/`, `.drupilot-coverage/`, `.drupilot.json`) via a
  marker-delimited managed block **merged** into any existing `.gitignore` (never
  overwriting the project's own ignores). Called by `/drupilot-setup`.
- **`/drupilot-patch` command** — a first-class, gate-free way to get the port's
  `.patch` **independently of contributing**: offline, no push, no rebase, no
  `contribute` gate. A tabbed choice produces either a plain local-test patch or
  one named with the Drupal.org issue-comment convention (to attach to an issue and
  test now, contributing the Merge Request later). `make-patch.sh --local` now
  accepts `--issue ID [--comment N]` for that issue-comment naming, still produced
  the offline way.
- **Tabbed decision points (`AskUserQuestion`) at the high-value forks.** Added
  `AskUserQuestion` to the relevant commands and surfaced the consequential choices
  as tabs (recommendation pre-selected, persisted to `.drupilot.json`): the router's
  ambiguous-intent (full port / next step / auto), the **core target** in
  `/drupilot-port` (keep D10+11 / D11-only / let drupilot decide, showing the
  `require.php` floor and SemVer bump), the **PHP target** picker in
  `/drupilot-setup` (8.4 recommended / 8.3 safe / 8.5 unconfirmed), the
  **contribute mode** and a **push** tab in `/drupilot-contribute` (show diff /
  push / local patch only / cancel), the **missing-tools** multi-select in
  `/drupilot-doctor`, and an **end-of-stage "what next?"** fork in `/drupilot-port`
  and `/drupilot-refactor`. Outward-facing options are conditioned on
  `autonomous=false`.
- **`scripts/env/next-step.sh`** — the single source of truth for the
  `doctor → setup → assess → port → [refactor] → test → [contribute]` ladder,
  emitting the recommended next step + reason as JSON/human from the per-project
  state (assess/phase/last-test/lock). It takes the readiness booleans the caller
  already parsed from `preflight --json` (no second preflight run).

- **Structured `--json` from the analyzers (reproducible verdict).** `run-phpstan.sh`
  (`--error-format=json`), `run-phpcs.sh` (`--report=json`) and `run-rector.sh`
  (a `{changed_files, files, pass1_files, pass2_files}` summary) now emit machine
  counts on stdout, so the S/M/L/XL assessment verdict and the auto-fixable share
  are derived from real numbers instead of being estimated from the human report.
  The `viability-assessment` skill and `drupal-viability-analyst` agent prefer them.
- **Participatory digests review.** Because the digests layer is unlicensed,
  AI-generated code touching the developer's module, `/drupilot-port` now reviews
  it rule-by-rule (rule → target API/min-version → files), **pre-flags** rules whose
  target API is newer than the kept `^10 || ^11` floor (which would silently raise
  `core_version_requirement`), and offers a tab (Review and pick / Apply all
  unflagged / Skip) with a git-checkpoint suggestion so a disliked pass can be
  dropped. The autonomous default is to skip flagged rules.
- **Port report card (`port-report.sh`).** A new, human-friendly `port-report.md`
  summarizing what the port did and why — core target, `require.php`, PHP target,
  version bump, the **preservation** verdict, the official-rector file count, the
  digests rules **applied vs rejected (with reason)**, manual edits, remaining
  deprecations, what was deferred to Phase 2, and the patch. Rendered from a
  per-port `port-manifest.json` plus the cached assess/test state; every field is
  optional and never invented. `/drupilot-port` and `/drupilot-refactor` write it.
- **Visible reproducibility lock.** `lock_show` / `lock_clear` in `common.sh` let
  the developer inspect (or reset) the frozen toolchain; `/drupilot-status` now
  pretty-prints the whole lock instead of only naming the core/digests SHA.
- **Granular Phase 2 refactor scope.** `/drupilot-refactor` now offers a
  multi-select (attributes / dependency injection / strict types / `final` by
  default / remove-all-deprecations, all pre-selected) plus a PHPStan level pick
  (6/5/4), persisted to `.drupilot.json` (`DRUPILOT_REFACTOR_SCOPE`,
  `DRUPILOT_PHPSTAN_LEVEL_REFACTOR`). It applies only the chosen modernizations and
  reports when the bar was lowered by choice. `make-issue.sh --phase port|refactor`
  makes the generated issue prose match the actual change-set (a refactor no longer
  claims "no behavior change").
- **Dependency Drupal 11 readiness panel (`deps-status.sh`).** Lists the subject's
  contrib dependencies (from `composer.json` + `*.info.yml`) and checks each against
  the drupal.org release-history feed — `ready` / `not-ready` / `not-on-drupalorg` /
  `unknown` (when the network is blocked — never guessed). Surfaces blockers (a dep
  with no D11 release) before the port stalls on them. Wired into the viability
  assessment.
- **Upstream issue search (`find-upstream-issue.sh`).** Before porting a contrib
  project, checks the drupal.org issue queue for an existing Drupal 11 effort
  (best-effort title scan via the api-d7 feed) so the developer can base on existing
  work; always prints the pre-filtered issue-queue URL as the reliable fallback.
  Offered as a tab in `/drupilot-assess`.
- **Deprecation explainer (`explain-deprecations.sh` + `config/deprecations.json`).**
  Annotates each known deprecated symbol in the analyzer output with what changed,
  the modern fix, and a drupal.org change-records link (a deterministic search URL
  keyed by the symbol — never a hardcoded, fabricatable node id). Turns cryptic red
  output into a learning aid; piped into the viability assessment.

### Changed
- **The router and `/drupilot-status` no longer restate the next-step ladder** in
  prose — both call `next-step.sh`, so they can never drift apart. Both also carry a
  standing aside that `/drupilot-patch` produces a patch any time, decoupled from
  contribution. The patch is now surfaced in the `minimal-port` / `full-refactor`
  skills and the `drupal-contrib-publisher` / `drupal-port-orchestrator` agents too.
- **Phase-aware, controllable post-edit lint.** `DRUPILOT_POST_EDIT_LINT`
  (`autofix` default / `report` / `off`) governs the PostToolUse hook, which now
  **states when phpcbf modified a file** (no more silent in-place edits) and, during
  Phase 1, surfaces compatibility ERRORS only — deferring DrupalPractice style
  WARNINGS to `/drupilot-refactor`. `DRUPILOT_SESSION_CONTEXT=off` silences the
  SessionStart summary.

### Fixed
- **Self-review hardening (pre-release).** A code review of the phase-2 diff caught
  and fixed: `next-step.sh` recommending `/drupilot-contribute` as "green" on a
  `none-run` test result (it now reports preservation honestly as not-verified);
  the digests/deprecation explainer's CKEditor entry using a PCRE lookahead that
  POSIX `grep -E` rejects (entry was silently dead); `find_drupal_root` climbing
  past a `docroot: '.'` project nested in a monorepo (it now checks the directory's
  own markers first); the phase-1 lint gate matching ERROR case-insensitively (a
  WARNING whose text said "error" tripped it); `run-rector.sh --json` word-splitting
  file paths containing spaces; and `run-phpunit.sh` reporting full `verified`
  preservation when some test groups were skipped (now `verified-partial`).
- **Drupal root detection for the standard `docroot: web` layout.**
  `find_drupal_root()` returned the docroot (`.../web`) instead of the
  composer/DDEV project root, because a bare `web/core/lib/Drupal.php` matched at
  `web/` before reaching the real root. That made `$ROOT/.ddev/config.yaml`
  checks miss — so the router and `/drupilot-status` thought DDEV was not
  configured and looped recommending `/drupilot-setup` — and broke host-mode
  relative paths (`vendor/bin`, `web/core`, the subject-relative path). Now it
  prefers project-root signals (`.ddev/config.yaml`, `$dir/web/core`) and resolves
  a bare-core docroot to its composer/DDEV parent. Verified across `docroot: web`,
  `docroot: '.'`, and standing-in-root layouts.
- **Autonomy guard.** `hooks/scripts/guard-contrib.sh` now enforces the documented
  promise that an autonomous run (`DRUPILOT_AUTONOMOUS=true`) never performs an
  outward-facing action **on its own**: it asks for human confirmation regardless
  of `DRUPILOT_CONTRIB_MODE`, so an unattended run cannot push/MR even in `auto`
  contribution mode (previously `auto` contribution mode allowed the push outright).
- **Honest test-state record.** `scripts/tests/run-phpunit.sh` now persists a
  `preservation` verdict (`verified` / `regression` / `not-verified-blocked` /
  `not-verified-no-tests`) and an honest `coverage` object (`requested`, `html`,
  `percent: null` — Phase 1 does not compute a coverage figure) in
  `last-test.json`. Reconciled the record name and shape across
  `skills/test-adaptation/SKILL.md` (which called it `tests.json` and claimed an
  unpersisted coverage field) and the `common.sh` lockfile comment.
- **Reliable terminal detection.** `confirm()` (and the new `choose_one()`) now
  test that `/dev/tty` can actually be **opened**, not merely that the node is
  read-permissioned, so in a non-interactive context (Claude Code Bash tool, cron,
  CI) they fall back to the default silently instead of printing a prompt/menu and
  a `/dev/tty` open error.
- Clarified in `config/defaults.json` that `DRUPILOT_PHP_TARGET` (8.3, the
  conservative default floor) is intentionally distinct from
  `php_support.recommended` (8.4, what the setup picker highlights).

## [0.6.0] - 2026-06-14

### Added
- **Issue paperwork generator** for the contribution flow
  (`scripts/contrib/make-issue.sh` + `templates/issue-summary.md.tmpl` /
  `templates/issue-comment.md.tmpl`): since a Drupal.org issue can only be created
  on the web, drupilot now generates ready-to-paste content — the issue **summary**
  (standard Drupal.org template, but for a behavior-preserving port only the
  applicable sections: Problem/Motivation, Proposed resolution, Remaining tasks;
  Steps to reproduce and UI/API/Data-model changes are omitted) and a brief
  **comment** that references the attached patch — plus the recommended values for
  the mandatory fields (**Title**, **Category**, **Priority**, **Version**,
  **Component**, **Assigned**). New env-overridable defaults
  `DRUPILOT_ISSUE_TITLE`/`CATEGORY`/`PRIORITY`/`COMPONENT`/`ASSIGNEE` (Task / Normal
  / Code / self by convention for a D11 compatibility port); Version is derived from
  the base branch (`4.0.x` → `4.0.x-dev`).

- **Honest dual-core compatibility floors.** When a port keeps `^10 || ^11`,
  drupilot no longer *declares* dual support it has not justified:
  - **PHP floor + target compatibility** — new
    `scripts/analysis/detect-php-floor.sh` (a heuristic scan for PHP
    8.2/8.3/8.4-only constructs) answers two symmetric questions: it lets
    `recommend_core_target` set composer `require.php` to the **real** floor the
    code needs (e.g. `>=8.1` for genuine Drupal 10 support) instead of always
    `>=<target>`, and it reports whether the code is **compatible with the Drupal
    11 PHP target** (`php_floor_target_compatible`) — i.e. it warns when the port
    uses a construct newer than the target (e.g. an 8.4 feature with target 8.3,
    which would fatal on Drupal 11/PHP 8.3). The authoritative proof of "runs on
    the target" remains the test suite, which runs inside DDEV on the target PHP
    version. New `DRUPILOT_REQUIRE_PHP_FLOOR` (`detect` default / `target`
    conservative); a lowered floor is flagged best-effort (confirm with
    PHPCompatibility). If the module has **no composer.json**, the unenforceable
    floor is now warned about.
  - **Drupal-minor floor** — a `^10 || ^11` recommendation is reported as
    `declared-not-verified` (mirroring the preservation gate), with warnings to
    raise the minor (`^10.3 || ^11`) or drop to `^11` if the port uses newer APIs
    (escalated when the digests/AI layer is enabled), plus
    `suggested_remaining_tasks`. `make-issue.sh --d10-unverified` carries the
    "verify Drupal 10 compatibility" task into the contribution issue.
  Surfaced in `core-strategy.sh` output and the `minimal-port` skill.

### Changed
- **The contribution patch is now verified to apply cleanly onto the version it
  targets** (`make-patch.sh`): the patch is checked against a throwaway index
  seeded from `origin/BASE`, and in the contribution flow a patch that does not
  apply is **discarded with a non-zero exit** (hard gate) — users must be able to
  apply it before the MR is merged. The offline `--local` preview patch only warns.
- **The Merge Request now carries a brief description and is always accompanied by
  a comment + the verified patch**: `open-mr.sh` gained `--description-file` so the
  generated comment becomes the MR description (and the issue comment), instead of a
  bare link to the issue. The contribution skill, command and the
  `drupal-contrib-publisher` agent were updated accordingly.

## [0.5.1] - 2026-06-13

### Changed
- The `/drupilot` router now **infers intent**: a natural-language port request
  ("port this module to Drupal 11", "upgrade this to D11") runs the full flow via the
  `drupal-port-orchestrator` (mode `full`, guided with confirmations; `auto` if you
  ask for unattended), instead of only recommending the next step. A bare `/drupilot`
  or an exploratory ask ("what's next") still just summarizes and recommends; an
  explicit mode word always wins.

## [0.5.0] - 2026-06-13

### Added
- **Determinism by default** (`DRUPILOT_DETERMINISTIC`, default `true`) with a
  per-project `drupilot-lock.json`: drupilot freezes the resolved Drupal core,
  dev-toolchain versions, the digests commit SHA and the DDEV add-on versions and
  reuses them on later runs, so porting the same module twice converges on the same
  toolchain and result. `DRUPILOT_DETERMINISTIC=false` (escape hatch) resolves
  fresh and refreshes the lock. New `common.sh` helpers (`deterministic_mode`,
  `lock_get`/`lock_set`/`lock_set_json`/`lock_resolve`, `drupilot_lock_file`) and a
  new `scripts/env/lock-sync.sh` (`--json`/`--refresh`/`--dry-run`) that captures
  versions from `composer.lock` and `ddev add-on list`; `ddev-up.sh` and
  `ddev-add-ons.sh` call it. Surfaced in `/drupilot`, `/drupilot-status` and the
  SessionStart hook.
- **Preservation gate by tests**: a port (and a refactor) only counts as done when
  the adapted test suite is green — that green is the evidence the original behavior
  is preserved. Test adaptations may change only the *form* (PHPUnit/Drupal API),
  never *what is verified*; a behavioral failure is a production-code regression to
  fix in code, never a test to relax. With no tests, drupilot states preservation is
  **not verified** and recommends adding them (it does not fabricate them).
  Reinforced in `test-adaptation`, `minimal-port` and `full-refactor`.

### Changed
- Pinned the dev toolchain to its verified ranges in `config/defaults.json`
  (`palantirnet/drupal-rector:^0.21`, `phpstan/extension-installer:^1.0`; the rest
  already matched PROMPT §1). The exact patch versions are frozen by the lock.
- The digests layer keeps `main` as its default ref but is now **reproducible**:
  `run-rector.sh` resolves `main` to a commit SHA, freezes it in the lock, reuses
  it on later runs, and **verifies** the checked-out SHA — recloning instead of
  silently reusing a stale cache. `DRUPILOT_DETERMINISTIC=false` re-resolves the
  live ref.
- Made the model-driven steps objective: a numeric S/M/L/XL viability rubric and
  fixed hard-break greps (`viability-assessment`), concrete uniform refactor rules
  replacing "where appropriate" (`full-refactor`), and an explicit failure
  decision tree + objective stop condition (`test-adaptation`).
- PHPStan uses a project-local `tmpDir` (`.phpstan-cache`) for reproducible cached
  results; `run-phpstan.sh` warns when the level comes from the environment.
- `run-phpcs.sh` auto-registers the Drupal/DrupalPractice `installed_paths`
  (idempotent) instead of only warning, so results no longer depend on prior setup.

### Fixed
- Non-deterministic file ordering: `discover-tests.sh` and `subject_info_file` now
  sort (`LC_ALL=C`), so the test inventory and the chosen `*.info.yml` are stable
  regardless of filesystem order.
- `run-phpunit.sh` reads the Selenium webdriver host from the generated DDEV YAML
  instead of hardcoding `selenium-chrome`, and writes a machine-readable
  `last-test.json` (per-group result + any documented JS skip).

## [0.4.0] - 2026-06-13

### Added
- Reasoned **Drupal core compatibility target** decision, replacing the static
  `DRUPILOT_KEEP_D10` binary. New `scripts/analysis/core-strategy.sh`
  (`--subject DIR [--phase port|refactor] [--bc-break|--no-bc-break] [--json]`)
  and the `recommend_core_target` helper in `common.sh` recommend, with a
  rationale: the `core_version_requirement` (`^11` vs `^10 || ^11`), the composer
  `drupal/core` constraint, the composer `require.php` that choice implies, and a
  SemVer **version-bump verdict** (major/minor/patch). Wired into assess (report +
  `assess.json`), port and refactor, the report/plan templates, and the
  analyst/orchestrator agents.

### Changed
- Core compatibility is now decided by `DRUPILOT_CORE_TARGET_STRATEGY`
  (`auto` default | `d11-only` | `keep-d10`) instead of the boolean
  `DRUPILOT_KEEP_D10` (kept as a legacy override, honored only when set). Policy:
  a port's PHP floor is `DRUPILOT_PHP_TARGET`, so keeping Drupal 10 — which itself
  allows PHP 8.1 — **always** declares composer `require.php: ">=<target>"` so a
  D10 + PHP<target site is blocked at install rather than fataling at runtime;
  `^11` needs none (core enforces its own minimum).

## [0.3.0] - 2026-06-13

### Added
- Hands-off **autonomous mode**: the `auto` mode word (`/drupilot <subject> auto`)
  and the `DRUPILOT_AUTONOMOUS` config key run **setup → assess → port → refactor →
  test** unattended — no initial confirmation, `DRUPILOT_GENERATE_RULES` treated as
  `auto` (unless `off`), the local patch written at the end. It **never** performs
  any outward-facing action (no `git push` / Merge Request / contribute), even in
  `auto` contribution mode; contribution stays an explicit, separate step. Wired
  through the `/drupilot` router and the `drupal-port-orchestrator`, and documented
  in both READMEs (including how it combines with the Claude Code permission mode
  for a fully headless run).
- Local **preview patch**: `scripts/contrib/make-patch.sh --local` writes
  `MODULE-port-to-drupal-11.patch` next to the module (offline, git-only, no rebase),
  including new/untracked files via a throwaway git index so the developer's real
  index is never touched. `/drupilot-port` (and `/drupilot-refactor`) generate and
  refresh it automatically.

### Changed
- The Drupal.org contribution flow now **always** produces a `.patch` alongside the
  Merge Request (`[module]-[short-description]-[issue]-[comment].patch`), not only as
  the legacy fallback for unmigrated projects — it is conventional to attach one to
  the issue. Updated `/drupilot-contribute`, the `drupal-contribution` skill and the
  `drupal-contrib-publisher` agent.
- `make-patch.sh` gained `--local` and `--subject` (auto-detects the machine name
  from the subject directory); the legacy issue/comment flow is unchanged. The local
  mode skips the `contribute` gate (it needs only git, no SSH/PAT).

## [0.2.0] - 2026-06-13

### Added
- `ddev_project_name` helper in `scripts/lib/common.sh`: sanitizes a directory
  basename into a hostname-safe DDEV project name (lowercase, invalid runs → `-`,
  trimmed), with a `drupal-project` fallback.

### Changed
- `templates/ddev-web-environment.yaml.tmpl` is now written to a **separate**
  `.ddev/config.testing.yaml` and reduced to `MINK_DRIVER_ARGS_WEBDRIVER` +
  `SYMFONY_DEPRECATIONS_HELPER` — ddev-drupal-contrib already supplies
  `SIMPLETEST_*`, `BROWSERTEST_*`, `DTT_*` and `DRUPAL_TEST_WEBDRIVER_*`, so the
  fragment now merges cleanly instead of clobbering `SIMPLETEST_BASE_URL`.
- `/drupilot-setup` and the `ddev-environment` skill now document the
  recommended-project subject placement (move the extension into
  `web/modules/custom` after Drupal is created), register all three coder PHPCS
  `installed_paths`, and write the testing env to `config.testing.yaml`.

### Fixed
- `ddev-up.sh` derived the DDEV project name from the directory basename
  verbatim, so a path containing `_`, uppercase or dots (e.g.
  `upgrade-to-d11-file_version`) made `ddev config` fail with "is not a valid
  project name". The name is now sanitized to a hostname-safe label.
- `ddev-up.sh` now detects a non-clean project root (a stray module dir or a
  downloaded tarball) before `ddev composer create` and aborts with actionable
  guidance, instead of letting composer fail cryptically with "is not allowed to
  be present".
- `ddev-add-ons.sh` now disables ddev-drupal-contrib's `symlink-project` hook in
  the recommended-project layout (before the restart, so it never runs) and
  removes the spurious `web/modules/custom/<project>/` symlink dir it would
  otherwise create from the project's `composer.json`/`.ddev`.
- The testing `MINK_DRIVER_ARGS_WEBDRIVER` value broke `ddev start` ("did not
  find expected key") because DDEV serializes `web_environment` values into the
  generated docker-compose wrapped in double quotes WITHOUT escaping the inner
  quotes. The template value is now pre-escaped (`\"` inside YAML single quotes).
- PHPCS setup registered only `coder_sniffer` in `installed_paths`; coder's
  Drupal standard also references `phpcs-variable-analysis` and
  `slevomat/coding-standard`, so `phpcs --standard=Drupal` failed with
  "Referenced sniff ... does not exist". All three are now documented/registered.
- `/drupilot-doctor` and `/drupilot-setup` no longer fail at command load: the
  installer/DDEV step examples were written as `` !`…` `` command injections, so
  Claude Code tried to execute them at load time. The `install-deps.sh` example
  carried the literal `<tools...>` placeholder, which the shell parsed as an
  invalid redirection (`syntax error near unexpected token 'newline'`). These
  three step templates (`install-deps.sh`, `ddev-up.sh`, `ddev-add-ons.sh`) are
  now plain code blocks the model runs via the Bash tool, not load-time
  injections. Only read-only context probes remain as `` !`…` ``.

## [0.1.0] - 2026-06-13

### Added
- Initial release of the drupilot Claude Code plugin.
- Two-phase porting workflow: **Phase 1** minimal compatibility (preserve
  behavior) and opt-in **Phase 2** "Drupal 11 way" refactor.
- Nine slash commands: `/drupilot` (router), `/drupilot-doctor`,
  `/drupilot-setup`, `/drupilot-assess`, `/drupilot-port`, `/drupilot-refactor`,
  `/drupilot-test`, `/drupilot-contribute`, `/drupilot-status`.
- Seven skills and four specialist subagents (port orchestrator, viability
  analyst, test engineer, contribution publisher).
- Requirements **preflight engine** with per-operation gates, and
  `/drupilot-doctor` with a per-platform status table and assisted installation.
- DDEV-based Drupal 11 environment setup: add-ons (`ddev-drupal-contrib`,
  Selenium) and the Composer dev toolchain, configured from templates.
- Static analysis: official `palantirnet/drupal-rector` plus the optional,
  runtime-cloned `dbuytaert/drupal-digests` AI-rule layer (filtered by the
  target `core_version_requirement`), PHPStan and PHPCS.
- Full PHPUnit suite (Unit / Kernel / Functional / FunctionalJavascript) in
  DDEV with Selenium for JS, plus coverage reporting.
- Drupal.org contribution flow: issue fork + Merge Request or legacy patch, in
  `semi` and `auto` modes, with graceful GitLab-API degradation; the PAT is
  never persisted or printed.
- Hooks: SessionStart environment detection, PostToolUse incremental
  `phpcbf`/`phpcs`, and a PreToolUse contribution guard.
- Configuration via `config/defaults.json` with environment-variable overrides;
  PHP target defaults to 8.3 and drives all tuning.
- Bilingual documentation (`README.md` / `README_es.md`) and an MIT license.

[Unreleased]: https://github.com/thebrokenbrain/drupilot/compare/v0.9.2...HEAD
[0.9.2]: https://github.com/thebrokenbrain/drupilot/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/thebrokenbrain/drupilot/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/thebrokenbrain/drupilot/compare/v0.8.4...v0.9.0
[0.8.4]: https://github.com/thebrokenbrain/drupilot/compare/v0.8.3...v0.8.4
[0.8.3]: https://github.com/thebrokenbrain/drupilot/compare/v0.8.2...v0.8.3
[0.8.2]: https://github.com/thebrokenbrain/drupilot/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/thebrokenbrain/drupilot/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/thebrokenbrain/drupilot/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/thebrokenbrain/drupilot/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/thebrokenbrain/drupilot/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/thebrokenbrain/drupilot/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/thebrokenbrain/drupilot/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/thebrokenbrain/drupilot/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/thebrokenbrain/drupilot/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/thebrokenbrain/drupilot/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/thebrokenbrain/drupilot/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/thebrokenbrain/drupilot/releases/tag/v0.1.0
