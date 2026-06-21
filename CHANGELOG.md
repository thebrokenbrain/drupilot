# Changelog

All notable changes to **drupilot** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add every notable change under **[Unreleased]** as you make it (grouped under
`Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security`). On
release, rename `[Unreleased]` to the new version with a date, bump `version`
in `.claude-plugin/plugin.json` (and the `marketplace.json` entry) to match, and
tag the commit `vX.Y.Z`.

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

[Unreleased]: https://github.com/thebrokenbrain/drupilot/compare/v0.8.1...HEAD
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
