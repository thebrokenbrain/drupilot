# Changelog

All notable changes to **drupilot** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add every notable change under **[Unreleased]** as you make it (grouped under
`Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security`). On
release, rename `[Unreleased]` to the new version with a date, bump `version`
in `.claude-plugin/plugin.json` (and the `marketplace.json` entry) to match, and
tag the commit `vX.Y.Z`.

## [Unreleased]

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
### Changed
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

### Fixed
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
  found: <drupal_root>"), and even a valid root would have written `.gitignore`
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
- **A Rector dry run that found changes printed a red "Failed to execute
  command ... exit status 2"** from `ddev exec` on stderr, although exit 2 is
  Rector's normal "changes found" result. `run-rector.sh` drops that wrapper
  line when the run finished normally; a real crash keeps it.

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

[Unreleased]: https://github.com/thebrokenbrain/drupilot/compare/v0.8.4...HEAD
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
