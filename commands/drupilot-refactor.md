---
description: Phase 2 opt-in full refactor to the modern Drupal 11 way — PHP 8 attributes for plugins, dependency injection, strict types, modern APIs, zero deprecations, PHPStan level 5-6, and clean Drupal+DrupalPractice, with the test suite kept green. Use only when the user explicitly opts into refactoring after a Phase 1 minimal port.
argument-hint: "[module-or-theme-path]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, Skill, AskUserQuestion
---

# /drupilot-refactor — Phase 2: full "Drupal 11 way" refactor (opt-in)

This is the **optional** second phase. It rewrites the subject to modern Drupal 11
best practices. It is opt-in by design: only run it when the user explicitly asks.
It assumes Phase 1 (`/drupilot-port`) already left the subject D11-compatible with
behavior intact.

Subject path argument: `$1` (fallback: the current working directory).

## Step 0 — Gate (profile `analyze`) and confirm intent

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile analyze && bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; copy_legacy_state_once'
```

If it exits `2`, show the report, point to `/drupilot-doctor`, and STOP. The dev
toolchain must be installed; if not, route the user to `/drupilot-setup`.

Because this phase deliberately changes architecture and behavior-adjacent code,
**confirm** the user really wants the full refactor (not just the minimal port).
If they have not yet run a Phase 1 port, recommend doing that first so the diff
stays reviewable.

## Step 1 — Resolve subject and the higher quality bar

```bash
!bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; \
  SUBJECT="${1:-$PWD}"; SUBJECT="$(cd "$SUBJECT" 2>/dev/null && pwd || echo "$SUBJECT")"; \
  echo "subject=$SUBJECT"; \
  echo "machine_name=$(subject_machine_name "$SUBJECT" 2>/dev/null || echo "?")"; \
  echo "type=$(subject_type "$SUBJECT" 2>/dev/null || echo "?")"; \
  echo "php_target=$(resolve_php_target)"; \
  ROOT="$(find_drupal_root "$SUBJECT" 2>/dev/null || true)"; \
  echo "phpstan_level_refactor=$(DRUPILOT_PROJECT_DIR="$ROOT" config_get DRUPILOT_PHPSTAN_LEVEL_REFACTOR 6)"; \
  echo "refactor_scope=$(DRUPILOT_PROJECT_DIR="$ROOT" config_get DRUPILOT_REFACTOR_SCOPE "")"' \
  -- "$1"
```

The refactor PHPStan target is `DRUPILOT_PHPSTAN_LEVEL_REFACTOR` (default `6`),
higher than the Phase 1 deprecation level. The PHP target still derives from
`DRUPILOT_PHP_TARGET` (default `8.3`); PHP 8.5 needs Drupal 11.3 or later and
has no assumed Rector `php85` set — branch on the runtime check.

Because a refactor introduces typed / `final` public APIs (a BC break),
re-evaluate the core target in refactor mode:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/core-strategy.sh" --subject "$1" --phase refactor
```

It recommends `^11` (drop Drupal 10) and a **major** version bump — plan a new
`N+1.0.x` branch, not a minor. Apply its `core_version_requirement`; `^11` needs
no `require.php`. Surface the major-bump implication in the final summary.

Then refreeze the final upgrade plan for the range you applied, so the PHP floor
of `rector.php` and `phpstan.neon` follows it (ADR 0018, ADR 0020):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/upgrade-path.sh" --subject "$1" --phase final --range "<the core_version_requirement you applied>" --root "<drupal_root>" --freeze --json
```

Exit 2 (`final-changes-frozen`: another target, PHP target or test-bed) means the
refactor would change what the setup planned: stop and say so.

## Step 2 — Load the procedure and choose the scope

Invoke the **full-refactor** skill for the modernization checklist and the exact
toolchain commands.

**Decision point — the developer picks the modernization scope (G3/G4/G5).** The
"Drupal 11 way / PHP 8.x way" refactor is not all-or-nothing — surface a
**multi-select** with **AskUserQuestion** (header "Modernize", **all pre-selected**
by default, droppable) *unless* the run is autonomous or a scope is already
remembered: a non-empty `refactor_scope` from Step 1 (`DRUPILOT_REFACTOR_SCOPE`,
from the environment or `.drupilot.json`, where an earlier run saved it) is the
answer — skip the tab, use only its valid keys, and say so in one line. Each option has a key, used in the
persisted csv:

- **PHP 8 attributes** (`attributes`) for plugins (annotations → `#[Block(...)]` etc.).
- **Dependency injection** (`di`) (`\Drupal::service()` → constructor injection).
- **Strict types** (`strict-types`) (`declare(strict_types=1)` + parameter/return types).
- **`final` by default** (`final`) on classes not designed for extension — note this can
  break downstream extenders, so it is a deliberate opt-in.
- **Remove all deprecations** (`deprecations`) (adopt current Symfony 7 / Twig 3 / Guzzle 7 idioms).

Plus a single follow-up tab (header "PHPStan level") for the quality bar: **6**
(default, `DRUPILOT_PHPSTAN_LEVEL_REFACTOR`) / **5** / **4** — higher is stricter.

Pre-answers come first, also in an autonomous run — run both:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/choice.sh" --key REFACTOR_SCOPE --subject "$1" --persist --json
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/choice.sh" --key PHPSTAN_LEVEL --subject "$1" --persist --json
```

A non-null `value` answers that tab (a comma-separated subset of the keys above
for the scope; `6` / `5` / `4` for the level): skip the tab, use it, and say so in
one line — the script already persisted it. A null `value` (unset, or invalid and
already warned) means: ask as above.

Persist the choices so a re-run does not re-ask: `prefs_set DRUPILOT_REFACTOR_SCOPE
"<csv of selected keys>"` and `prefs_set DRUPILOT_PHPSTAN_LEVEL_REFACTOR <N>` (env
still wins). Apply **only** the selected modernizations in Step 3, and use the
chosen PHPStan level in Step 5. If the developer dropped "final by default" or
"remove all deprecations", say so in the report (the bar was lowered by choice).

## Step 2b — Check the learned patterns (before the first change)

Phase 2 has its own recurring pitfalls (a promoted service made `private
readonly` in a serialized form, `new static` turned into `new self`, an
`#[\Override]` while Drupal 10 is still declared...). Scan the subject with the
project's pattern catalog (`--catalog <file>` when a batch context passes one):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/patterns.sh" scan --subject "<subject>" --json
```

Read-only, exit `0`. Treat each hit as a must-check item while modernizing (the
recorded fix is the starting point). Nothing to keep for the manifest: the
learned patterns live in the project's catalog (`patterns.sh list`), which
Step 6b extends.

## Step 3 — Modernize, change by change

Apply **only the modernizations selected in Step 2** (`DRUPILOT_REFACTOR_SCOPE`),
**explaining each significant change** as you go (what changed, why, and that
behavior is preserved):

- **PHP 8 attributes** for plugins instead of annotations (e.g. `#[Block(...)]`,
  `#[FieldType(...)]`) — through the deterministic pass, never by hand first
  (`full-refactor` §1a). Dry run, show the diff summary, then apply; the mode
  follows the core target of Step 1 (`strip` for `^11`, `keep` when `^10 || ^11`
  is deliberately kept):

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/convert-attributes.sh" --subject "$1" --mode strip --json
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/convert-attributes.sh" --subject "$1" --mode strip --apply --json
  ```

  If `floor_ok` is false (a type's attribute class is newer than the declared
  floor, e.g. an entity type needs 11.1) and the run is not autonomous, ask with
  **AskUserQuestion** (header "Attribute floor"; default **Keep the annotation**;
  a `value` from `bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/choice.sh" --key ATTRIBUTE_FLOOR --subject "$1" --json`,
  `keep` or `raise-floor`, answers it without the tab, also in an autonomous run):
  **Keep the annotation for those types** (BC, nothing more to do) or **Strip
  them and raise the floor** to `recommended_requirement` (re-run with
  `--raise-floor --apply`; a further BC break — mention it in the version-bump
  summary). An autonomous run keeps them. Hand-convert only what the JSON lists
  as `skipped` / `skipped_files` / `restored_files` or a type it does not know
  (declare project/contrib types in `DRUPILOT_ATTRIBUTE_PLUGIN_TYPES`), and
  report its `rule_hits` in the Step 7 summary (the pass keeps no state file).
- **Dependency injection**: replace `\Drupal::service(...)` static calls with
  constructor-injected services; implement `create()` / `ContainerFactoryPluginInterface`
  where appropriate.
- **Strict typing**: add `declare(strict_types=1);`, parameter/return type hints,
  and `final` on classes not designed for extension where it is safe.
- **Modern APIs**: remove every remaining deprecation; adopt current
  Symfony 7 / Twig 3 / PHPUnit 10-11 / Guzzle 7 idioms.
- Keep the public behavior and the module/theme's contract stable; this is a
  rewrite of *how*, not *what*.

**Log every divergence as it happens** (a Rector change reverted or rewritten,
a script's verdict overridden, a step skipped, a fix a gate or a test forced, a
test whose form changed, a behavior change a reviewer must check — e.g. a
public method that became `final` or private):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/log-decision.sh" --subject <subject> \
  --kind <rector-revert|post-port-fix|script-divergence|skip|manual-override|tooling-deviation|test-adaptation|behavior-change|preexisting-bug> \
  --what "<what you did>" --why "<why>" [--rule <Rector rule>] [--file <path>] \
  [--script <script>] [--detected-by <tool>] [--review-hint "<how to review>"] --phase refactor
```

## Step 4 — Keep the suite green (coordinate with the test engineer)

A refactor is only done when the tests still pass. Before the first change,
freeze the post-port suite as the baseline the refactor is judged against
(`run-phpunit.sh --subject <path> --baseline-from-last`, or `--baseline` for a
fresh run), so a red test afterwards is classified as a refactor regression or
as a failure that already existed. After each meaningful batch of
changes, delegate to the **drupal-test-engineer** subagent (via the Task tool) to
adapt and re-run the relevant tests in DDEV (Unit / Kernel / Functional /
FunctionalJavascript), and iterate until green. In Phase 2 the engineer also
**adds missing tests** to raise coverage, and every new test must carry an
`effective` negative control (`scripts/tests/negative-control.sh`: red with the
guarded change undone, green once the code is restored byte for byte; an
`ineffective` test is strengthened, never accepted). Do not silence failing tests — if
something cannot pass for an external reason (e.g. a contrib dependency without a
D11 release), document it explicitly.

You can drive the test run via `/drupilot-test`, or call the test scripts the
engineer uses; let the subagent own the iteration loop.

## Step 5 — Quality gates: PHPStan 5-6 + clean PHPCS + port safety

Push static analysis to the refactor level and require clean coding standards:

```bash
# Coding standards: autofix, then the result must be clean for Drupal + DrupalPractice:
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpcs.sh" --subject "$1" --fix
# phpstan.neon's refactor profile (every phpstan-drupal rule; Phase 1's compat
# profile leaves its opinion rules off). Exit 3 means the developer edited
# phpstan.neon: it is kept, and PHPStan runs with it.
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/render-templates.sh" --subject "$1" --only phpstan --profile refactor
# Static analysis at the higher refactor level:
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/run-phpstan.sh" --subject "$1" --level "$(bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; config_get DRUPILOT_PHPSTAN_LEVEL_REFACTOR 6')"
```

Then the deterministic port-safety gate (it must exit 0):

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/check-port-safety.sh" --subject "$1" --json
# Core signature changes vs the declared core floor (gate):
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/scan-signature-changes.sh" --subject "$1" --json
```

Iterate until: zero deprecations, PHPStan clean at level 5-6, `phpcs
--standard=Drupal,DrupalPractice` reports no violations, and
`check-port-safety.sh` and `scan-signature-changes.sh` exit 0. The refactor is where most of its findings get
introduced: constructor promotion must stay `protected` (never `private` or
`readonly`) in forms/plugins (`DependencySerializationTrait`), a plugin converted
to attributes keeps `implements ContainerFactoryPluginInterface`, `create()` keeps
`new static(` unless the class is made `final`, Form API callbacks stay array
callables, and `#[\Override]` is only added when the core range is `^11`-only and
the parent method exists in its lowest minor. Never change semantics just to make
the sandbox PHPStan pass; document sandbox-only findings instead.

**Core matrix (only while `^10` is still declared).** A refactor normally moves to
`^11`; if the final `core_version_requirement` still admits Drupal 10 (and
`DRUPILOT_VERIFY_CORES` is not `off`), verify the modernized code statically on a
Drupal 10 core too — attributes, DI and new APIs are exactly what drifts past the
Drupal 10 floor:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/verify-core-matrix.sh" --subject "$1" --json --level "$(bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; config_get DRUPILOT_PHPSTAN_LEVEL_REFACTOR 6')"
```

Exit 3 = a leg failed (an `incompatible` finding, or `php -l` failing on the
leg's PHP floor): fix it the Drupal 10-safe way, raise the floor, or drop to
`^11` — the same "Drupal 10 check" tab and autonomous default as the
`minimal-port` skill §6a. A skipped leg (no network) leaves `d10_support`
`declared-not-verified` and never blocks the refactor. The script keeps its
verdict in `core-matrix.json`: `manifest.sh` takes `d10_support` from it and
`port-report.sh` reads it.

## Step 6 — Refresh the local patch

Phase 2 changes more code, so regenerate the local preview patch to reflect the
refactor (overwrites the Phase 1 one in place):

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/make-patch.sh" --local --subject "$1"
```

It rewrites `MODULE-port-to-drupal-11.patch` next to the module. This stays a
preview/test patch (add `--issue ID` for an issue-comment-named one, as
`/drupilot-patch` does); the merge-verified contribution patch is produced by
`/drupilot-contribute`.

## Step 6b — Record what this refactor learned

Same as `/drupilot-port` Step 8b: list the candidates
(`patterns.sh harvest --subject "<subject>" --json`), write a detector that
matches the pre-refactor code for each pitfall worth preventing (a POSIX ERE
and/or `port-safety:<check>` / `signature:<id>`), ask which to record with
**AskUserQuestion** (multiSelect, header "Learn"; skipped in an autonomous run,
which records only detectors it checked and lists their ids; a `value` from
`choice.sh --key LEARN` answers it as in `/drupilot-port`), and record each
with `patterns.sh add --subject "<subject>" --id <slug> --kind <kind> --pattern
'<ERE>' [--rule <ref>] --why "<why>" --fix "<fix>" --json`.

## Step 7 — Report

Summarize in English:

- The modern patterns applied (attributes, DI, strict types, API updates), with a
  brief rationale for each significant change.
- Final quality state: PHPStan level reached and clean, PHPCS Drupal +
  DrupalPractice clean, zero deprecations, port-safety exit 0 (warnings listed).
- Test status: which groups ran, the pass result, coverage, and any test
  documented as un-passable for an external reason.
- A reviewable summary of the diff.
- **Local patch**: the refreshed `MODULE-port-to-drupal-11.patch` path (Step 6).
- Next suggested step: `/drupilot-test` for a final full green run, then
  `/drupilot-contribute` if the subject is a contrib project the user wants to
  publish.

**Refresh the port report card (trust + teaching).** Regenerate the manifest for
Phase 2 with `scripts/ai/manifest.sh --phase refactor`: it is built from the
findings, the worklist, the codemods, the applying Rector run, the digests
verdicts, the decision log and the git diff, never by hand. Your only input is
the **why** of the items you changed by hand, `<state_dir>/rationale.json`
(`{"<worklist item id>": "why"}`), passed with `--rationale`; every
architectural change a reviewer must check is a `behavior-change` entry of
`log-decision.sh`, logged as it happens. As Phase 2 ran, **tee** the Rector +
final validate-loop PHPStan deprecation output into `<state_dir>/change-log.txt`
(under `$HOME`, never in the project tree) so the report's "Drupal 9/10 → 11
changes, explained" section is populated:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ai/manifest.sh" --subject <path> --phase refactor --rationale <state_dir>/rationale.json --json
```

Then re-render:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/port-report.sh" --subject "$1" --manifest "<state_dir>/port-manifest.json" --changes-log "<state_dir>/change-log.txt"
```

`port-report.sh` defaults `--changes-log` to that path, so teeing the file is
enough; it writes into the visible `.drupilot/` dir at the Drupal root and, given
the manifest (`phase: "refactor"`), records the **refactored** stage in the
subject's `state.json`, and refreshes the machine summary `port-summary.json`
beside the report (`port-summary.sh`; `manifest.sh` fills `files_changed`).
`SendUserFile` the refreshed `port-report.md`.

## Step 8 — What next? (developer chooses)

**Unless the run is autonomous** (`DRUPILOT_AUTONOMOUS=true` — then print the
recommendation and stop), offer a closing **AskUserQuestion** fork (header "Next
step", default = recommended; a `value` from
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/choice.sh" --key NEXT_STEP --subject "$1" --json` answers
it without the tab: `test`, `patch` or `done` — `refactor` does not apply here and
is ignored, so ask): **Run the tests** (`/drupilot-test`), **Get the
local patch** (`/drupilot-patch`), **Patch for a Drupal.org issue**
(`/drupilot-patch` → issue-comment option), **Contribute upstream**
(`/drupilot-contribute`, only for a contrib project and **never** autonomously),
or **Done for now**. Route to the chosen command.

Nothing breaks silently. Every architectural change is explained.
