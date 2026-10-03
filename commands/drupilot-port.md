---
description: Phase 1 minimal port of a Drupal 9/10 module/theme to Drupal 11 — apply official drupal-rector, then the version-filtered digests layer, then ad-hoc rules, plus the minimal manual changes (core_version_requirement etc.), and validate with phpcbf/phpcs/phpstan. Use when the user wants the subject to run on D11 with its original behavior intact, without architectural refactoring.
argument-hint: "[module-or-theme-path]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, Skill, AskUserQuestion
---

# /drupilot-port — Phase 1: minimal compatibility port

Goal: make the subject **work on Drupal 11 while preserving its original
functionality**, with the *minimum* changes. This is **not** a refactor — no
architecture changes, no API modernization for its own sake. Anything beyond
mechanical compatibility is explicitly deferred to Phase 2 (`/drupilot-refactor`).

Subject path argument: `$1` (fallback: the current working directory).

**Decision log — throughout the port.** The moment you revert or hand-edit a
change Rector made, ignore or override a script's verdict (port-safety,
classify, core matrix, a digests rule kept against its flag...), skip a step
this command prescribes, fix something validation or the tests caught after
the port, change a test's form, leave a pre-existing bug unfixed, or introduce
a behavior difference a reviewer must check, record WHAT and WHY:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/log-decision.sh" --subject <subject> \
  --kind <rector-revert|post-port-fix|script-divergence|skip|manual-override|tooling-deviation|test-adaptation|behavior-change|preexisting-bug> \
  --what "<what you did>" --why "<why>" [--rule <Rector rule>] [--file <path>] \
  [--script <script>] [--detected-by <tool>] [--review-hint "<how to review>"]
```

It appends to `<root>/.drupilot/decisions.jsonl` and regenerates `decisions.md`
beside it; the port report and the layer report merge the entries. A divergence
that is not logged is a defect: the report would show the tool's output as kept.

## Step 0 — Gate (profile `analyze`)

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile analyze
```

If it exits `2`, show the report, point to `/drupilot-doctor`, and STOP with no
side effects. Rector/PHPStan/PHPCS need the dev toolchain; if it is not installed,
tell the user to run `/drupilot-setup` first and stop.

## Step 1 — Resolve subject, target, and current core requirement

```bash
!bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; \
  SUBJECT="${1:-$PWD}"; SUBJECT="$(cd "$SUBJECT" 2>/dev/null && pwd || echo "$SUBJECT")"; \
  echo "subject=$SUBJECT"; \
  echo "machine_name=$(subject_machine_name "$SUBJECT" 2>/dev/null || echo "?")"; \
  echo "type=$(subject_type "$SUBJECT" 2>/dev/null || echo "?")"; \
  echo "core_requirement=$(subject_core_requirement "$SUBJECT" 2>/dev/null || echo "<missing>")"; \
  echo "php_target=$(resolve_php_target)"; \
  echo "drupal_target=$(resolve_drupal_target)"; \
  echo "core_strategy=$(config_get DRUPILOT_CORE_TARGET_STRATEGY auto)"; \
  echo "use_digests=$(config_get DRUPILOT_USE_DIGESTS_RULES true)"; \
  echo "digests_ref=$(config_get DRUPILOT_DIGESTS_REF main)"; \
  echo "generate_rules=$(config_get DRUPILOT_GENERATE_RULES ask)"' \
  -- "$1"
```

If a cached `viability-report.md` exists for this project, read it first
(`project_state_dir`) so you know what to expect. Decide the **target
`core_version_requirement`** with the helper (not a static flag); use `--json` so
you can show the consequences:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/core-strategy.sh" --subject "$1" --phase port --json
```

**Decision point — let the developer own the core target (G4/G5).** This is one
of the most consequential choices in the port, so surface it as a tab with
**AskUserQuestion** (header "Core target") *unless* the run is autonomous
(`DRUPILOT_AUTONOMOUS=true`) or `DRUPILOT_CORE_TARGET_STRATEGY` /
`DRUPILOT_CHOICE_CORE_TARGET` is already pinned. Make the **helper's
recommendation the first/default option**, and show the consequence of each from
the JSON (`recommended_core_version_requirement`, `require_php`, `version_bump`):

- **Keep Drupal 10 + 11** (`^10 || ^11`, or `^10.N || ^11` when the module
  already declares a minor floor or its code uses a plugin attribute class that
  only exists from 10.N: the helper never lowers that floor) — widest support; declares a
  `require.php` floor (`<require_php>`); Drupal 10 compatibility is
  *declared* until Step 7b checks it statically on a Drupal 10 core (first run
  builds a cached reference core: ~200 MB, needs network).
- **Drupal 11 only** (`^11`) — simplest; no `require.php`; drops D10 (a **major**
  version bump if it was supported).
- **Let drupilot decide** — apply the helper's `strategy` verdict as-is.

Persist the answer so later runs don't re-ask: write the chosen strategy with
`prefs_set DRUPILOT_CORE_TARGET_STRATEGY <auto|keep-d10|d11-only>` (env still
wins). Then apply the resolved `recommended_core_version_requirement` in Step 6.
When it returns a `require.php` (for `^10 || ^11`, since Drupal 10 allows PHP 8.1
while the port needs a higher floor), add `"require": { "php": "<require_php>" }`
to `composer.json` using the **exact** `require_php` value the helper returns
(`DRUPILOT_REQUIRE_PHP_FLOOR=detect`, the default, derives the real floor such as
`>=8.1`; `target` keeps `>=<target>`). Also relay `php_floor_target_compatible`
(false → the code uses a construct newer than the target) and the
`declared-not-verified` Drupal 10 status (Step 7b checks it). Note the `version_bump` verdict for the
final summary. This target also drives which digests rules are safe (see Pass 2).
The legacy `DRUPILOT_KEEP_D10` still works as an explicit override.

## Step 2 — Load the procedure

Invoke the **minimal-port** skill for the exact commands, the three-pass order,
and the digests caveats. Keep a running list of which rules/changes get applied so
you can report it at the end.

## Step 2b — Record the pre-port test baseline (before any code change)

So that a red test after the port can be told apart from one that was already
red before it (e.g. a kernel suite that fatals on Drupal 11 before the port),
record the suite on the UNTOUCHED code, before Pass 1:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/tests/run-phpunit.sh" --subject "<subject>" --type all --baseline
```

It writes `test-baseline.json` in the state dir (never `last-test.json`) and
exits `0` even when the suite is red. Skip it when the subject ships no tests.
When it exits `2` (DDEV down, PHPUnit not installed — the port only gates
`analyze`), say that no baseline could be taken and continue: the port never
blocks on it, but every later failure will then count as a regression. Re-taking
it after Rector ran would compare the port with itself (the run warns when the
baseline was taken on the current code).

## Step 2c — Check the learned patterns (prevention, before any code change)

Pitfalls earlier ports of this project already hit are recorded in its pattern
catalog (`<Drupal root>/.drupilot/patterns.json`, or `DRUPILOT_PATTERNS_FILE`;
a `/drupilot-layers` set shares one, so what layer N learned is checked on layer
N+1). Scan the untouched subject with it (add `--catalog <file>` when a batch
context passes one):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/patterns.sh" scan --subject "<subject>" --json
```

Read-only, always exit `0`. Show the hits grouped by pattern (`by_pattern`: id,
hits, the fix that worked before, the module/layer it was learned from). Each
hit is a **must-check item** for the steps below: prevent it while porting
instead of repairing it after (the recorded fix is the starting point; the
`minimal-port` golden rules still decide). No catalog or no hit is normal for a
first module. Keep the JSON for the manifest's `learned_patterns.scan` (Step 9).

## Step 3 — Pass 1: official `palantirnet/drupal-rector` (apply)

The stable, maintained layer first. Always dry-run, let the user (or you, on their
behalf) review the diff, then apply. The script ensures a `rector.php` exists at
the Drupal root (rendered from the plugin template; one generated by an older
drupilot template is backed up to `.drupilot/backups/` and regenerated, a
hand-written one is left alone with a warning) and uses the `DRUPAL_10` set plus
the PHP set for the resolved target, minus the risky rules the template skips
(Form API callbacks → closures, `#[\Override]`, `readonly`, `(string)` casts —
see the `minimal-port` skill §0). `--json` lists the applied rule names in
`rules` and counts them per pass in `rule_hits` (`{official: {Rule: files},
digests: {...}}`): copy it into the manifest's `rector_rules` (Step 9); an
`--apply` that changed files also keeps it as `rector-rules.json` in the state
dir, the report's fallback. Undo or rewrite any applied hunk only with a
`--kind rector-revert --rule <Rule>` decision-log entry.

```bash
# Review what it would change:
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "$1"
# Then apply:
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "$1" --apply
```

**Exit 3 means the official Rector pass crashed** (`[ERROR] Could not detect twig set.`, a PHP fatal,
per-file errors): its output is not a "no changes" result and nothing should be
applied on top of it. Show the diagnostic (installed vs known-good toolchain),
repair with `bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/install-toolchain.sh" --dir <drupal_root> --source reference`
(or fix `rector.php` when the toolchain already matches the known-good set), and
re-run the pass. The digests pass is skipped automatically after such a crash.

## Step 4 — Pass 2: complementary digests layer (apply, version-filtered)

Only if `DRUPILOT_USE_DIGESTS_RULES` is true. These rules are **AI-generated,
experimental, and unlicensed** (PROMPT 2.1.1): clone-on-demand into the plugin
cache (never vendored), run them **after** the official pass, and **filter out**
any rule whose target API does not exist in the lowest core version you must
support — applying a rule that migrates a 11.2+ API would silently raise the
effective `core_version_requirement` and break on 11.0/11.1. When the target is
`^10 || ^11`, be especially conservative.

Procedure: **dry-run → participatory review → apply → validate**. Never apply
blind — this is unlicensed AI-generated code touching the developer's module, so
they decide.

```bash
# Dry-run first (clones/updates the digests cache, checks out DRUPILOT_DIGESTS_REF):
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "$1" --digests
# Structured view of what it would touch (pass2 = digests):
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "$1" --digests --json
```

**Decision point — the developer owns the digests pass (G5).** Read the dry-run
diff and, for each change, note the **rule** and the **API/min-version** it
targets; **pre-flag** any rule whose target API was added *after* the floor you
are keeping (from Step 1 — e.g. an 11.2+ API while keeping `^10 || ^11`), since
applying it silently raises the effective `core_version_requirement`. Present the
review and a tab with **AskUserQuestion** (header "Digests rules", default
"Review and pick") — skip it only in an autonomous run, where the safe default is
to **skip** flagged rules:

- **Review and pick** — show the per-rule list (rule → target → files, flagged
  ones marked) and apply only the rules the developer keeps.
- **Apply all (unflagged)** — apply every rule that is not pre-flagged.
- **Skip the digests pass** — apply nothing from this layer.

Before applying, suggest a git checkpoint (`git add -A && git commit`) so a
disliked digests pass can be dropped cleanly. **Never normalize `--no-verify`:**
check the repository's git hooks first —

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/git-hooks.sh" --subject "$1" --json
```

— and when it reports hooks, commit normally and let them run (a longer Bash
timeout or a background run for a slow hook). Only if a hook cannot complete
here, run `git-hooks.sh --subject <path> --run-equivalents`, fix any failure,
commit with `--no-verify` only when `all_green` is true (the guard hook asks the
developer to confirm), and record it as `verification.commit_hooks` in the
manifest. An autonomous run never skips a hook: it keeps a hook-free checkpoint
with `make-patch.sh --local` instead. Then apply the accepted subset:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-rector.sh" --subject "$1" --digests --apply
```

**Exit 4 means only the digests pass crashed** (`status: "partial"`, `digests_status: "error"` with `--json`; e.g. a broken upstream rule file): the official result stands, the toolchain is fine — do **not** reinstall it. Pin a known-good digests commit (`--digests-ref <sha>` / `DRUPILOT_DIGESTS_REF`) or skip the layer (`DRUPILOT_USE_DIGESTS_RULES=false`); the broken SHA is never frozen in the lockfile.

If the developer picked a subset (not "apply all"), apply the kept rules via an
explicit `--config` pointing at a trimmed rule set, or apply all then revert the
unwanted hunks — never silently apply a flagged rule they did not accept.

## Step 5 — Pass 3: ad-hoc rules / manual fixes (per `DRUPILOT_GENERATE_RULES`)

For deprecations that **no** layer covers, behave according to
`DRUPILOT_GENERATE_RULES`:

- `ask` (default) — for each uncovered deprecation, read the relevant drupal.org
  change record / issue, then **confirm** with the user before either generating
  a small reusable ad-hoc Rector rule or applying the change manually.
- `auto` — generate the ad-hoc rule or apply the mechanical change without asking,
  but still report each one.
- `off` — only **report** the uncovered deprecation; do not touch the code.

Keep ad-hoc rules minimal and mechanical; do not slip refactoring in here.

## Step 6 — Minimal manual changes Rector cannot do

Apply only the mechanical compatibility edits, preserving behavior:

- **`info.yml` + `composer.json`**: set `core_version_requirement` to the target
  decided in Step 1 (e.g. `^10 || ^11`) in the main `info.yml` **and every
  submodule's** with the helper (a submodule left on `^8.8 || ^9 || ^10` cannot be
  installed on Drupal 11; it also removes an obsolete `core: 8.x` key and bumps a
  test module only when it does not admit Drupal 11). Dry-run first, show the
  changes, then apply (substitute the requirement):

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/set-core-requirement.sh" --subject "$1" --requirement '<recommended_core_version_requirement>' --dry-run --json
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/set-core-requirement.sh" --subject "$1" --requirement '<recommended_core_version_requirement>' --json
  ```

  A missing `core_version_requirement` is blocking — the helper adds it. When Step 1
  reported a `require.php` (i.e. keeping Drupal 10), add
  `"require": { "php": "<require_php>" }` to `composer.json` using the exact value
  the helper returned, so a D10 + low-PHP site is blocked at install, not at
  runtime.
- **Twig 3**: replace removed filters/functions and `{% spaceless %}` with their
  mechanical equivalents (e.g. the `spaceless` filter / `~` handling) only where
  the change is unambiguous.
- **CKEditor 5 / jQuery UI**: adjust libraries/usages where the migration is
  mechanical; if it requires real rework, **defer it to Phase 2** and record it.
- Anything that would change architecture, signatures broadly, or behavior →
  **defer to Phase 2**, do not do it here.

## Step 6b — Optional: plugin annotations → PHP 8 attributes (opt-in)

Converting plugin annotations is **not** a Drupal 11 requirement (annotations
keep working through Drupal 12), so Phase 1 never does it by default. Preview
what the optional pass would touch (read-only dry run, keep mode, limited to
attribute classes that exist on Drupal 10.3 so Drupal 10 stays reachable):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/convert-attributes.sh" --subject "$1" --mode keep --max-since 10.3 --json
```

If it reports `changed_files` > 0 **and the run is not autonomous**, ask with
**AskUserQuestion** (header "Plugin attributes"; default **Skip**):

- **Skip (recommended for a minimal port)** — leave the annotations; Phase 2
  (`/drupilot-refactor`, "PHP 8 attributes") converts them.
- **Add attributes, keep annotations** — say in the option text that it
  **raises `core_version_requirement`** to the dry run's
  `recommended_requirement` (e.g. `^10.3 || ^11`): the attribute classes only
  exist from Drupal 10.2 (`Block`, `Action`) / 10.3 (the other types), and
  PHPStan on an older core reports them as unknown (runtime is unaffected: older
  cores keep reading the annotation). Raising the floor drops Drupal < 10.3
  sites (a BC break: version bump per `core-strategy.sh`).

Strip mode (removing the annotations) is never offered in Phase 1. An autonomous
run skips this step. On **Add attributes**, apply and raise the floor explicitly:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/convert-attributes.sh" --subject "$1" --mode keep --max-since 10.3 --raise-floor --apply --json
```

Then mirror the new floor in `composer.json` (`require.drupal/core`) when the
module declares one, record the choice (`log-decision.sh --kind manual-override
--what "Added plugin attributes (keep mode), core floor raised to <req>" --why
"<the developer's reason>"`), and merge the JSON's `rule_hits` into the
manifest's `rector_rules`. `restored_files` lists files the pass put back
(duplicate attribute or `php -l` failure) and `skipped_files` those already
half-converted by hand: report both. Step 7 validates the result (and Step 7b
checks the new floor when `^10` is still declared).

## Step 7 — Validate after each batch of changes

Run the formatter/autofixer, then the linters, then the deprecation-level
analyzer, then the port-safety gate. Leave the subject compiling with no blocking
deprecations.

```bash
# Autofix coding standards, then check what remains (uses the subject's own
# PHPCS ruleset when it ships one; the log says which ruleset was used):
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpcs.sh" --subject "$1" --fix
# Deprecation-level static analysis (DRUPILOT_PHPSTAN_LEVEL, default 2):
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpstan.sh" --subject "$1"
# Deterministic port-safety checks (gate):
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/check-port-safety.sh" --subject "$1" --json
# Core signature changes vs the declared core floor (gate):
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/scan-signature-changes.sh" --subject "$1" --json
# Pre-existing metadata hygiene (report only; refreshes the port report's table,
# and submodule-core-req must show no warning after Step 6):
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/lint-extension-metadata.sh" --subject "$1" --json
# Hard vs soft deprecations under DRUPILOT_SOFT_DEPRECATIONS (gate: blocking == 0):
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpstan.sh" --subject "$1" --json | bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/classify-deprecations.sh" --subject "$1" --json
```

**What "blocking" means — the soft-deprecation policy.** `classify-deprecations.sh`
splits PHPStan's deprecations: **hard** = removed in a Drupal major ≤ the target
major (e.g. `user_roles()`, removed in 11.0.0 — PHPStan reports "Function
user_roles not found."), **unknown** = no readable Drupal removal version (treated
as hard), and **soft** = removed in a later major (e.g. `user_load_by_name()`,
`user_load_by_mail()`, `text_summary()`, `check_markup()`, `user_cookie_save()`:
deprecated in 11.4.0, removed from 13.0.0 — they work on every Drupal 11 core).
Hard and unknown ones are blocking (`blocking` must be 0). Soft ones follow
`DRUPILOT_SOFT_DEPRECATIONS` (read it, do not ask): `report` (default) — leave the
code alone, list them in the report; `defer` — list them under deferred to Phase 2;
`fix` — follow each item's `action`: `fix` (the replacement exists at the declared
core floor, e.g. `loadByProperties()`), `fix-guarded` (it exists only on newer
cores, e.g. the `TextSummary` service from 11.4 → wrap it in
`DeprecationHelper::backwardsCompatibleCall()`), `defer` (nothing usable at the
floor). Never break a core the module still declares to remove a soft deprecation.

If PHPStan still reports blocking deprecations, iterate (back to the relevant
pass) until they are resolved or clearly attributable to something deferred to
Phase 2 (and recorded as such). Do not silence findings. **Never "fix" a sandbox
PHPStan finding by changing semantics** (e.g. `new static` → `new self`, a cast or
guard added only for the sandbox level, an API newer than the kept core floor):
if the finding comes from the sandbox itself (a class from a module that is not
installed here), document it as sandbox-only in the report instead.

**Port-safety gate.** `check-port-safety.sh` must exit **0**. Exit 3 means error
findings — a `create()` whose class lost (or never had)
`ContainerFactoryPluginInterface`/`ContainerInjectionInterface`, a removed `use`
still referenced, `new self(` in `create()`, a first-class callable/closure under
a Form/Render API callback key, a `private`/`readonly` property in a serialized
class, or a services/routing class name whose case differs from the file. Fix
each one (restore the interface/`use`/`new static`/array callable, make the
property `protected`) and re-run; in autonomous mode too — never ignore or
suppress them. Each finding says whether this port introduced it (diff against
the same pre-port git base as the local patch; pass `--base REF` if the port
was already committed). Warnings (e.g. `#[\Override]` while the core range
spans Drupal 10, pre-existing private/readonly properties) are reviewed and
listed in the report. An `#[\Override]` on a method the signature catalog dates
(`buildRevisionCacheId()` exists only from 11.3) is an error whenever the declared
floor is below that minor, `^11` included.

**Signature gate.** `scan-signature-changes.sh` must exit **0** too. It checks the
module against the verified catalog of Drupal 10 → 11 signature changes
(`.signature_changes` in `config/deprecations.json`) at the FLOOR of the
`core_version_requirement` you just set (`--core-floor X.Y` overrides): a
`ConfigFormBase` / `ContentTranslationController` subclass passing too few
arguments to `parent::__construct()` (ArgumentCountError on 11.0+), a module
method colliding with one core added later (`getOriginal()`/`setOriginal()` 11.2,
`buildRevisionCacheId()` 11.3) with an incompatible signature or an
`#[\Override]` below the floor, a `hook_entity_operation()`/`_alter()` that
REQUIRES the 11.3 `$cacheability` parameter while the floor is lower. Apply each
finding's `fix` the Drupal 10-safe way (forward `config.typed`; rename the
colliding helper and its callers; make the new hook parameter optional) and
re-run. Warnings (a method that silently becomes an override of core, a call to
an API newer than the floor) are decided and listed in the report; `info`
findings need no change. Tee the human output into `<state_dir>/change-log.txt`.

## Step 7b — Core matrix: verify every declared core (when `^10` is kept)

The validate loop only ever sees the Drupal 11 test-bed. When the requirement set
in Step 6 still admits Drupal 10 (`verify_cores` in the Step 1 JSON has a `10…`
leg) and `DRUPILOT_VERIFY_CORES` is not `off`, verify it statically on a real
Drupal 10 core once the loop is clean (see the `minimal-port` skill §6a):

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/verify-core-matrix.sh" --subject "$1" --json
```

It runs the same PHPStan (the test-bed's exact phpstan-drupal toolchain) and
`php -l` on a cached reference core per extra leg (built once via `ddev exec
composer` in `<drupal_root>/.drupilot/cores/`, frozen in the lockfile), and lints
on the leg's lowest PHP (Drupal 10's own minimum or the `require.php` floor) in a
`php:X.Y-cli` container. Only errors the Drupal 11 baseline does not have count;
deprecations, missing contrib dependencies (sandbox), tests-only typing
differences, phpstan-drupal advisory rules and runtime-tolerated findings (more
arguments than an older core's method takes; the result of a newer core's
`: void` method used) never fail a leg. A baseline leg that cannot be analysed
makes the other legs `skipped` (declared-not-verified), never `failed`.

- **Exit 3 (`verdict: fail`)** — a real Drupal 10 incompatibility (e.g. an
  `#[\Override]` on `buildRevisionCacheId()`, which only 11.3+ core declares; a
  class only Drupal 11 ships; a PHP 8.2+ construct under a `>=8.1` floor).
  **Decision point** — AskUserQuestion (header "Drupal 10 check"), skipped in an
  autonomous run (safe default: fix the code; if that is not mechanical, recommend
  `^11` in the report): **Fix the code (keep `^10 || ^11`)** (default) · **Raise
  the floor** (e.g. `^10.3 || ^11`) · **Drop to `^11`** (persist with
  `prefs_set DRUPILOT_CORE_TARGET_STRATEGY d11-only`) · **Keep it
  declared-not-verified** (recorded in the report). Re-run the matrix after a fix.
- **`d10_support: verified-static`** — report it as a static verification
  (PHPStan + `php -l` on Drupal 10.x.y, including the declared floor minor); the
  runtime is not exercised there.
- **`d10_support: verified-static-above-floor`** — clean, but only on a 10.x
  newer than the declared floor (`d10_floor`; a `^10` leg resolves to the newest
  10.x). Report that the floor itself was not checked: an API added after it
  would still fatal there. Offer `verify-core-matrix.sh --cores <floor>,11`, or
  raising the floor to the checked minor.
- **A skipped leg** (network unavailable, a core that cannot install on the
  container PHP) — exit 0; `d10_support` stays `declared-not-verified`. Never
  block the port on it.

## Step 8 — Write the local patch (preview / test locally)

Once the subject compiles and validates, write a local `.patch` of the whole
port so the user can review it, apply it elsewhere, or test it before deciding to
contribute. This is offline (no network, no rebase) and only needs the module to
be under git version control; if it is not, the script warns and skips without
breaking the flow.

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/make-patch.sh" --local --subject "$1"
```

It writes `MODULE-port-to-drupal-11.patch` next to the module (diff scoped to the
module subtree, new files included). The same script can name the patch with the
Drupal.org **issue-comment** convention — still offline, no push, no gate — if the
developer wants to attach it to an issue and test it now, contributing the Merge
Request later: pass `--issue ID [--comment N]` (this is what `/drupilot-patch`
does). The merge-verified patch (rebased onto `origin/BASE` and hard-gated to
apply cleanly) is the separate thing produced by `/drupilot-contribute`.

## Step 8b — Record what this port learned

List the candidates — the reverted Rector changes and post-port fixes of the
manifest and the decision log:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/patterns.sh" harvest --subject "<subject>" --json
```

For each candidate worth preventing (and any other pitfall the port hit — a
signature change, a hygiene defect that broke the tests), write a detector that
matches the **pre-port** code: a POSIX ERE (`grep -E`; no `\d`, no lookarounds;
check it with `git show <base>:<file> | grep -nE '<ERE>'`) and/or a
deterministic rule (`port-safety:<check>` of `check-port-safety.sh`,
`signature:<id>` of `scan-signature-changes.sh`). **Unless the run is
autonomous**, ask with **AskUserQuestion** (multiSelect, header "Learn"; every
proposed pattern pre-selected, plus "None"): which ones to record. In an
autonomous run, record only those whose detector you checked, and list the ids
in the summary for review. Record each:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/patterns.sh" add --subject "<subject>" \
  --id <slug> --kind <rector-reversion|post-port-fix|signature-change|port-safety|hygiene|other> \
  --pattern '<ERE>' [--files '<globs>'] [--rule <ref>] \
  --why "<why it was needed>" --fix "<the fix that worked>" [--layer <N>] --json
```

A known id is upserted (`hits` + 1, this module appended to `seen_in`). The
catalog is a local, self-gitignored, hand-editable file — never part of a patch;
`patterns.sh remove --id <id>` undoes an entry and `patterns.sh export` prints
entries in `config/deprecations.json` format to propose upstream. Nothing new
learned → record nothing.

## Step 9 — Report

Summarize in English:

- **Applied**: which official-rector rules, which accepted digests rules (and
  which were filtered out and why), which ad-hoc rules / manual edits — with the
  final `core_version_requirement`.
- **Validation**: phpcbf/phpcs and phpstan status after the work (clean vs. what
  remains and why; sandbox-only PHPStan findings listed as such), the
  port-safety result (errors fixed, warnings reviewed), and the core matrix
  verdict per leg (`d10_support`: verified-static / verified-static-above-floor /
  failed / declared-not-verified).
- **Deferred to Phase 2**: anything non-mechanical (architecture, CKEditor 5 /
  jQuery UI rework, deeper API modernization) explicitly listed for
  `/drupilot-refactor`.
- A short, reviewable summary of the diff (files touched, nature of changes).
- **Local patch**: the path to the `MODULE-port-to-drupal-11.patch` written in
  Step 8 (or a note that it was skipped because the module is not under git).
- Next suggested step: `/drupilot-test` to adapt and run the test suite, then
  optionally `/drupilot-refactor`.

**Write the port report card (the trust + teaching artifact).** Record the
decisions you made as a small manifest JSON and render the human report, so the
developer (and a future maintainer reviewing the change) can see what changed and
why at a glance. The report also **teaches**: as the port ran you should have
**tee'd** the official Rector output (pass 1), the digests pass output and the
final validate-loop PHPStan deprecation report into `<state_dir>/change-log.txt`
(under `$HOME`, never in the project tree, so it never leaks into a patch);
`port-report.sh` pipes that through `explain-deprecations.sh` to render a
"Drupal 9/10 → 11 changes, explained" section grouped by migration area. Build
the manifest from what you actually did, write it to the project state dir, then
render:

```bash
# Write <state_dir>/port-manifest.json with: machine_name, type, phase ("port"),
# core_version_requirement, require_php, php_target, version_bump,
# rector_official_files, digests {applied, rejected:[{rule,reason}], skipped},
# manual_edits[], deprecations_remaining, deferred_to_phase2[], patch,
# d10_support (from verify-core-matrix.sh when Step 7b ran, else the Step 1 value),
# port_safety (the JSON printed by check-port-safety.sh --json),
# signature_changes (the JSON printed by scan-signature-changes.sh --json),
# metadata_lint (the JSON printed by lint-extension-metadata.sh --json, Step 7:
# rendered as "Pre-existing hygiene (not fixed in Phase 1)"; port-report.sh falls
# back to the metadata-lint.json it saves),
# soft_deprecations (the JSON printed by classify-deprecations.sh --json; add its
# soft symbols with action "defer" to deferred_to_phase2, and count only hard +
# unknown ones in deprecations_remaining),
# verification {core_matrix (the JSON of verify-core-matrix.sh --json, Step 7b),
# phpcs_ruleset (the .drupilot object of run-phpcs.sh --json:
# which ruleset was used — the project's own, or drupilot's default and why),
# commit_hooks (the JSON of git-hooks.sh --run-equivalents when a hook was
# substituted, else {"bypassed": false, "note": "hooks ran on commit"}),
# negative_controls (the records of negative-control.sh --json, when a test was
# written for a fix; port-report.sh falls back to negative-controls.json)}.
# Each manual_edits item may be a plain string OR an object
# {edit, why?, change_record?} so the report can explain WHY each manual change
# was made (and link its change record).
# Structured outcome fields (aggregated across modules and layers by
# layer-report.sh; the log-decision.sh entries are merged in, deduplicated):
# rector_rules (the rule_hits of the applying run-rector.sh --json),
# rector_reversions [{rule, file, why}], post_port_fixes [{fix, file, why,
# detected_by}], preexisting_bugs [{issue, file, note}], behavior_changes
# [{change, why, review_hint}], tooling_deviations [{what, why}], validation
# [strings: how the result was validated], learned_patterns {scan (the JSON of
# patterns.sh scan --json, Step 2c), recorded [the ids added in Step 8b]}.
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/port-report.sh" --subject "$1" --manifest "<state_dir>/port-manifest.json" --changes-log "<state_dir>/change-log.txt"
```

It writes `port-report.md` into the visible `.drupilot/` artifacts dir at the
Drupal root (and pulls the `preservation` verdict — with the baseline
comparison: regressions, pre-existing failures, tests the port fixed — from
`last-test.json` and the assessment verdict from `assess.json`). `port-report.sh` already defaults
`--changes-log` to `<state_dir>/change-log.txt`, so teeing the analyzer output
there is enough. Given the manifest, it also records the **ported** stage in the
subject's `state.json` (the per-module registry), so `/drupilot-status` and the
router move past `/drupilot-port`. `SendUserFile` it so it surfaces as a deliverable. Every field
is optional — the report still renders from partial data, and never invents a value.
It also refreshes `port-summary.json` beside the report: the versioned machine
summary (`scripts/analysis/port-summary.sh --subject <dir> --json`: status,
effort, files changed, Rector rules, reverted rules, manual fixes, preservation,
core matrix, patch) that wrappers read instead of the Markdown. Add
`files_changed` (the number of files the port changed, e.g. the `diff --git`
entries of the local patch) to the manifest so the summary does not have to
fall back to counting the patch.

## Step 10 — What next? (developer chooses)

Phase 1 is done. **Unless the run is autonomous** (`DRUPILOT_AUTONOMOUS=true` —
then just print the recommendation and stop, doing nothing outward-facing), put
the developer back in control with an **AskUserQuestion** fork (header "Next
step", default = the recommended option). Offer the relevant subset of:

- **Run the tests** (`/drupilot-test`) — recommended: the green suite is the
  evidence behavior was preserved.
- **Get the local patch** (`/drupilot-patch`) — a `.patch` to test on another
  checkout now.
- **Patch for a Drupal.org issue** (`/drupilot-patch` → issue-comment option) —
  an issue-named patch to attach and test, contributing later.
- **Refactor to the Drupal 11 way** (`/drupilot-refactor`) — opt-in Phase 2.
- **Contribute upstream** (`/drupilot-contribute`) — opt-in; only offer for a
  contrib project on drupal.org, and **never** in an autonomous run.
- **Done for now** — stop here.

Act on the chosen option (route to the matching command). Phase 1 keeps behavior
identical and D11-compatible. When in doubt, defer rather than refactor.
