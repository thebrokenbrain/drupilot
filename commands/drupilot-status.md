---
description: Read-only status summary for a Drupal port - environment readiness, effective PHP target, DDEV state, current phase, last cached assessment, and last test result, plus the suggested next step. No side effects (never mutates anything, never runs the toolchain). Use for "/drupilot-status", "where am I", "what's the state of this port".
argument-hint: "[subject-path]"
allowed-tools: Bash, Read
---

# drupilot — status (read-only summary)

You produce a concise English status report. **This command has no side effects:** only
read cached state and run detection in report/JSON mode. Never start DDEV, never run
Rector/PHPStan/PHPCS/PHPUnit, never write files, never touch a remote.

## Step 1 — Environment readiness (report-only)

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile all --json`

Parse `php_target` and `ready.{analyze,setup,test,contribute}` from the JSON. The `all`
profile is report-only and always exits 0.

## Step 2 — Subject, Drupal/DDEV state, and effective PHP target

!`bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; SUBJ="${1:-$PWD}"; [[ -d "$SUBJ" ]] || SUBJ="$PWD"; ROOT="$(find_drupal_root "$SUBJ" 2>/dev/null || true)"; printf "subject_dir=%s\n" "$SUBJ"; printf "machine_name=%s\n" "$(subject_machine_name "$SUBJ" 2>/dev/null || echo -)"; printf "subject_type=%s\n" "$(subject_type "$SUBJ" 2>/dev/null || echo -)"; printf "core_requirement=%s\n" "$(subject_core_requirement "$SUBJ" 2>/dev/null || echo -)"; printf "drupal_root=%s\n" "${ROOT:--}"; printf "ddev_config=%s\n" "$([[ -n "$ROOT" && -f "$ROOT/.ddev/config.yaml" ]] && echo yes || echo no)"; printf "ddev_running=%s\n" "$(ddev_running "$ROOT" 2>/dev/null && echo yes || echo no)"; printf "php_target=%s\n" "$(resolve_php_target)"; printf "php_unconfirmed=%s\n" "$(php_target_unconfirmed "$(resolve_php_target)" && echo yes || echo no)"; printf "deterministic=%s\n" "$(config_get DRUPILOT_DETERMINISTIC true)"; printf "state_dir=%s\n" "$(project_state_dir "$SUBJ")"; printf "lockfile=%s\n" "$(LF="$(DRUPILOT_PROJECT_DIR="${ROOT:-$SUBJ}" drupilot_lock_file 2>/dev/null)"; [[ -f "$LF" ]] && echo "$LF" || echo -)"' _ "$1"`

## Step 3 — Cached assessment, phase, and last test result

In the reported `state_dir`, read these if they exist (do not recompute anything):

- `@<state_dir>/assess.json` and `@<state_dir>/viability-report.md` — verdict, effort
  (S/M/L/XL), auto-fixable vs manual counts, and the assessment timestamp.
- `@<state_dir>/phase` — the current phase marker (e.g. setup / assessed / ported /
  refactored / tested / contributed).
- `@<state_dir>/last-test.json` — the last PHPUnit run (groups run, pass/fail counts,
  timestamp, any coverage figure).
- the `lockfile` path reported in Step 2 (if any) — the reproducibility lock:
  frozen Drupal core, dev-toolchain versions, DDEV add-ons and the digests SHA a
  deterministic re-run reuses.

If a file is absent, report that part as "not done yet" rather than inventing a value.

## Step 4 — Print the summary and the suggested next step

Render an English summary covering:

- **Subject:** machine name, type, `core_version_requirement`.
- **Environment:** readiness per profile (analysis / setup+tests / contribution) and
  DDEV state (configured? running?).
- **PHP target:** the effective value; explicitly flag it if it is **unconfirmed**
  (e.g. 8.5) — never claim an unconfirmed version is supported.
- **Reproducibility:** deterministic mode on/off, and if a lockfile exists, the
  frozen Drupal core and digests SHA it pins (what a re-run will reuse).
- **Current phase:** from the phase marker (or "not assessed yet").
- **Last assessment:** verdict + effort + counts + when, or "none cached".
- **Last test result:** pass/fail summary + when, or "tests not run yet".

End with a single **suggested next step** as a slash command, using this order:
`/drupilot-doctor` if analysis is not ready; else `/drupilot-setup` if no DDEV
environment; else `/drupilot-assess` if no cached assessment; else `/drupilot-port` if
assessed but not ported; else `/drupilot-refactor` (opt-in) or `/drupilot-test` if tests
are not green; else `/drupilot-contribute` (opt-in) for a contrib subject. Present this
as a suggestion only — this command never acts on it.
