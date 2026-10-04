---
description: Read-only status summary for a Drupal port - environment readiness, effective PHP target, DDEV state, current phase, last cached assessment, and last test result, plus the suggested next step; with --all, a portfolio table of every module/workspace drupilot has state for. No side effects (never mutates anything, never runs the toolchain). Use for "/drupilot-status", "where am I", "what's the state of this port", "status of all my ports".
argument-hint: "[subject-path] | --all [dir|registry-file|everything]"
allowed-tools: Bash, Read
---

# drupilot — status (read-only summary)

You produce a concise English status report. **This command has no side effects:** only
read cached state and run detection in report/JSON mode. Never start DDEV, never run
Rector/PHPStan/PHPCS/PHPUnit, never write files, never touch a remote.

## Step 0 — Portfolio mode (`--all`)

If `$ARGUMENTS` contains `--all`, report on **every** subject instead of one and
skip Steps 1-4 (ignore their load-time output, which assumed a single subject).
The argument after `--all` selects the scope:

- a directory (default: the current directory) — every module/theme under it
  that drupilot has state for, e.g. a folder holding several test-bed
  workspaces, plus every recorded subject whose path or origin is under it;
- a registry file — one path per line (a module/theme directory, or a
  directory to scan), `#` comments allowed;
- `--all everything` — every subject with a `state.json` in drupilot's data dir.

Run the read-only registry yourself (substitute the scope; drop `--root` for
`everything`, use `--registry FILE` for a file):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/state.sh" list --root <dir> --from-preflight --json
```

STDOUT is `{count, subjects: [...]}`; each subject carries `machine_name`,
`drupal_root` / `ddev_project`, `stage` and `stages`, `effort`, `git` (branch,
commit, dirty), `toolchain` (Drupal core, PHP target, package versions),
`tests` (status, `preservation`, `fresh`), `core_matrix` (`d10_support`,
`fresh`), `patch` (path, kind, `exists`), `updated` and `next` (the step
`next-step.sh` recommends for it). Render one table row per subject — module,
workspace, stage, effort, preservation, Drupal 10 verdict, branch@commit, core,
updated, next step — mark a `fresh: false` verdict as stale, a missing
directory as missing, and say "not run" for an absent verdict. Never invent a
value. Add a one-line total per stage, and point at
`state.sh show --subject <DIR>` for one subject's details. `count: 0` means
drupilot has no state under that scope: say so and suggest a wider `--all`.

## Step 1 — Environment readiness (report-only)

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile all --json`

Parse `php_target` and `ready.{analyze,setup,test,contribute}` from the JSON. The `all`
profile is report-only and always exits 0.

## Step 2 — Subject, Drupal/DDEV state, and effective PHP target

!`bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; SUBJ="${1:-$PWD}"; [[ -d "$SUBJ" ]] || SUBJ="$PWD"; ROOT="$(find_drupal_root "$SUBJ" 2>/dev/null || true)"; printf "subject_dir=%s\n" "$SUBJ"; printf "machine_name=%s\n" "$(subject_machine_name "$SUBJ" 2>/dev/null || echo -)"; printf "subject_type=%s\n" "$(subject_type "$SUBJ" 2>/dev/null || echo -)"; printf "core_requirement=%s\n" "$(subject_core_requirement "$SUBJ" 2>/dev/null || echo -)"; printf "drupal_root=%s\n" "${ROOT:--}"; printf "ddev_config=%s\n" "$([[ -n "$ROOT" && -f "$ROOT/.ddev/config.yaml" ]] && echo yes || echo no)"; printf "ddev_running=%s\n" "$(ddev_running "$ROOT" 2>/dev/null && echo yes || echo no)"; printf "php_target=%s\n" "$(resolve_php_target)"; printf "php_unconfirmed=%s\n" "$(php_target_unconfirmed "$(resolve_php_target)" && echo yes || echo no)"; printf "deterministic=%s\n" "$(config_get DRUPILOT_DETERMINISTIC true)"; printf "state_dir=%s\n" "$(project_state_path "$SUBJ")"; printf "artifacts_dir=%s\n" "$(project_artifacts_path "$SUBJ")"; printf "lockfile=%s\n" "$(LF="$(project_state_path "${ROOT:-$SUBJ}")/drupilot-lock.json"; [[ -f "$LF" ]] && echo "$LF" || echo -)"' _ "$1"`

## Step 3 — Cached assessment, phase, and last test result

drupilot splits where it writes: the **machine-readable state** (`assess.json`,
`last-test.json`, the lockfile) lives in the hidden per-project `state_dir` under
`$HOME` **by design** — so it survives `git clean` and can never leak into a
contribution — while the **developer-facing reports and outputs** live in the
single visible `artifacts_dir` at `<DRUPAL_ROOT>/.drupilot/` (gitignored, so it
never lands in a patch). That folder holds `viability-report.md`, `port-report.md`,
the `coverage/` HTML and the local preview `*.patch` — it is the directory a
developer opens to see what happened.

Read these if they exist (do not recompute anything):

- `@<state_dir>/assess.json` and `@<artifacts_dir>/viability-report.md` — verdict,
  effort (S/M/L/XL), auto-fixable vs manual counts, and the assessment timestamp.
- `@<state_dir>/state.json` — the per-module record: the stages reached
  (`stage`, the highest one: setup / assessed / ported / refactored / tested /
  contributed, and `stages`, each with the time it was recorded) and a snapshot
  of effort, branch/commit, toolchain, preservation, core matrix and the last
  patch (schema in docs/reference/state.md). `port-report.sh` records ported /
  refactored, `run-phpunit.sh` records tested, the setup / assess / contribute
  commands record theirs through `state.sh record`. An older project may have no
  `state.json` (only the plain-text `<state_dir>/phase` marker, or nothing).
  The merged, current view of the record, read-only:

  !`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/state.sh" show --subject "$1" --no-next --json 2>/dev/null || true`
- `@<state_dir>/last-test.json` — the last PHPUnit run: groups run, pass/fail counts,
  the **`preservation`** verdict (`verified` / `verified-partial` / `regression` /
  `pre-existing-failures` / `not-verified-unbaselined` / `not-verified-blocked` /
  `not-verified-no-tests` — the
  behavior-preservation gate), the `baseline` comparison against the pre-port run
  (`regressions`, `not_baselined`, `pre_existing`, `fixed`; `null` without a baseline), the
  `negative_controls` summary (effective / ineffective / error / stale), and the `coverage`
  object (`requested` / `html` / `percent`; `percent` is `null` in Phase 1, so do
  not invent a figure).
- the `lockfile` path reported in Step 2 (if any) — the reproducibility lock:
  frozen Drupal core, dev-toolchain versions, DDEV add-ons and the digests SHA a
  deterministic re-run reuses. Pretty-print the whole frozen toolchain so it is
  visible, not hidden:

  !`bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; SUBJ="${1:-$PWD}"; [[ -d "$SUBJ" ]] || SUBJ="$PWD"; ROOT="$(find_drupal_root "$SUBJ" 2>/dev/null || echo "$SUBJ")"; DRUPILOT_PROJECT_DIR="$ROOT" lock_show || true' _ "$1"`
- the core matrix — the last `verify-core-matrix.sh` result (static PHPStan +
  `php -l` per declared core; `d10_support` `verified-static` /
  `verified-static-above-floor` / `failed` / `declared-not-verified`), and whether it is still fresh (computed on the
  current sources). Read-only: this never runs the matrix.

  !`bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; SUBJ="${1:-$PWD}"; [[ -d "$SUBJ" ]] || SUBJ="$PWD"; SUBJ="$(cd "$SUBJ" && pwd)"; F="$(core_matrix_file "$SUBJ")"; if [[ -r "$F" ]]; then printf "core_matrix_fresh=%s\n" "$(core_matrix_fresh "$SUBJ" && echo yes || echo no)"; jq -c "{d10_support, verdict, generated_at, legs: [.legs[] | {core: (.version // .core), role, status, reason}]}" "$F"; else echo "core_matrix=none"; fi' _ "$1"`
- `@<state_dir>/port-manifest.json` and `@<artifacts_dir>/port-report.md` if present
  — the per-port "what changed and why" record and its human report card.
- origin hygiene — whether drupilot left anything behind in the developer's origin
  checkout, compared with the baseline taken before placement (read-only; `clean` is
  `null` when no baseline was recorded):

  !`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/origin-hygiene.sh" --check --subject "$1" --json 2>/dev/null || true`

If a file is absent, report that part as "not done yet" rather than inventing a value.

## Step 4 — Print the summary and the suggested next step

Render an English summary covering:

- **Subject:** machine name, type, `core_version_requirement`.
- **Environment:** readiness per profile (analysis / setup+tests / contribution) and
  DDEV state (configured? running?).
- **PHP target:** the effective value; when `php_unconfirmed=yes` (8.5), say that
  it needs Drupal 11.3 or later and that no Rector `php85` set is assumed.
- **Reproducibility:** deterministic mode on/off, and if a lockfile exists, the
  frozen Drupal core and digests SHA it pins (what a re-run will reuse).
- **Current phase:** `stage` from `state.json` (or the legacy phase marker; else
  "not assessed yet").
- **Last assessment:** verdict + effort + counts + when, or "none cached".
- **Last test result:** pass/fail summary, the **preservation** verdict, and when —
  or "tests not run yet". With a baseline, say how many failures are regressions
  and how many pre-exist the port (`pre-existing-failures` is not green), and name
  any `not_baselined` failure (the baseline never meaningfully ran it, so
  `not-verified-unbaselined` is neither green nor pre-existing). Mention
  the negative controls when any exist, and name every `ineffective` one.
- **Core matrix:** one line per core leg (version, pass/fail/skipped and why) and
  the Drupal 10 support verdict; say "stale — re-run verify-core-matrix.sh" when
  `core_matrix_fresh=no`, or "not run" when there is none. `verified-static` means
  PHPStan + `php -l` were clean on that core (including the declared floor
  minor); `verified-static-above-floor` means clean only on a newer 10.x — the
  floor (`d10_floor`) was not checked. Neither is a runtime test.
- **Origin hygiene:** one line — "clean", the drupilot-attributable residue it lists
  (`attributable`), or "no baseline" when `clean` is null. Never suggest deleting
  anything automatically.
- **Artifacts:** point the developer at the visible `<DRUPAL_ROOT>/.drupilot/` folder
  (`artifacts_dir`) for `viability-report.md`, `port-report.md`, `coverage/` and the
  local `*.patch`; note the machine-readable state (`assess.json`, `last-test.json`,
  `drupilot-lock.json`) lives in the hidden per-project state dir under `$HOME` by
  design, so it can never leak into a contribution.

End with a single **suggested next step**. Do not restate the ladder here — use the
same single source of truth the router uses; it reads the readiness booleans from
preflight itself (`--from-preflight`), since a load-time line cannot take values
substituted from Step 1 (this is read-only and never acts on the suggestion):

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/next-step.sh" --subject "$1" --from-preflight --human`

Relay its recommendation as a suggestion only. Add the same one-line aside as the
router: once ported, `/drupilot-patch` produces a `.patch` any time (to test
locally or attach to a Drupal.org issue) **independently** of contributing.
