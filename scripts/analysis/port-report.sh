#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/port-report.sh
# Render a human-friendly "port report card" (port-report.md) summarizing what a
# port did and why — the at-a-glance trust artifact for the developer (and a
# maintainer reviewing the change). It reads:
#   * a port MANIFEST JSON (written by the port/refactor flow with the decisions
#     it made), and/or
#   * the cached per-project state: assess.json (verdict/effort) and
#     last-test.json (the preservation verdict).
# Every field is optional and defaults to a clear "n/a" — the report renders even
# from partial data, and never invents a value.
#
# The manifest is plain data the flow records; a minimal shape:
#   {
#     "machine_name": "foo", "type": "module", "phase": "port",
#     "core_version_requirement": "^10 || ^11", "require_php": ">=8.1",
#     "php_target": "8.3", "version_bump": "minor",
#     "rector_official_files": 12,
#     "digests": {"applied": ["Rule\\A"], "rejected": [{"rule":"Rule\\B","reason":"targets 11.2 API"}], "skipped": false},
#     "manual_edits": ["info.yml core_version_requirement",
#                      {"edit": "Twig spaceless", "why": "removed in Twig 3", "change_record": "https://..."}],
#     "deprecations_remaining": 0,
#     "deferred_to_phase2": ["CKEditor 5 plugin rewrite"],
#     "patch": "foo-port-to-drupal-11.patch",
#     "d10_support": "declared-not-verified"
#   }
# manual_edits items may be a plain string OR an object {edit, why?, change_record?}.
#
# Didactic "changes explained": when a --changes-log file (captured Rector +
# PHPStan deprecation output) is available, the report adds a section that runs it
# through explain-deprecations.sh and groups each recognized D9/10 -> 11 change by
# migration area (Entity API, Twig 3, CKEditor 5, ...) with what changed, the fix
# and a drupal.org change-record link — turning the report into a teaching aid.
#
# Usage:
#   port-report.sh --subject DIR [--manifest FILE] [--output DIR] [--changes-log FILE]
#
# Output: writes <output>/port-report.md (default: the visible .drupilot/ artifacts
#         dir at the Drupal root) and prints its path on STDOUT. Logging on STDERR.
# Exit codes: 0 ok · 1 usage/error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
MANIFEST=""
OUTPUT=""
CHANGES_LOG=""
usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --manifest) MANIFEST="${2:-}"; shift 2;;
    --manifest=*) MANIFEST="${1#*=}"; shift;;
    --output) OUTPUT="${2:-}"; shift 2;;
    --output=*) OUTPUT="${1#*=}"; shift;;
    --changes-log) CHANGES_LOG="${2:-}"; shift 2;;
    --changes-log=*) CHANGES_LOG="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

have_cmd jq || die "jq is required to render the port report." 1
[[ -n "$SUBJECT" ]] || SUBJECT="$PWD"
[[ -d "$SUBJECT" ]] || die "Subject directory not found: $SUBJECT" 1
SUBJECT="$(cd "$SUBJECT" && pwd)"

NAME="$(subject_machine_name "$SUBJECT" 2>/dev/null || basename "$SUBJECT")"
STATE_DIR="$(project_state_dir "$SUBJECT")"
# Default the output to the single visible, gitignored .drupilot/ artifacts dir
# at the Drupal root, so the report is easy to find and can never leak into a patch.
[[ -n "$OUTPUT" ]] || OUTPUT="$(project_artifacts_dir "$SUBJECT")"
mkdir -p "$OUTPUT"
OUT_ABS="$(cd "$OUTPUT" && pwd)"
REPORT="$OUT_ABS/port-report.md"

# Default the didactic changes-log to the conventional state-dir path (written by
# the flow when it tees Rector + PHPStan output); silently skip if absent.
[[ -n "$CHANGES_LOG" ]] || { [[ -r "$STATE_DIR/change-log.txt" ]] && CHANGES_LOG="$STATE_DIR/change-log.txt"; }

# Load the manifest (or an empty object) and the cached state.
M='{}'
if [[ -n "$MANIFEST" && -r "$MANIFEST" ]]; then
  M="$(jq -c . "$MANIFEST" 2>/dev/null || echo '{}')"
fi
ASSESS='{}'; [[ -r "$STATE_DIR/assess.json" ]] && ASSESS="$(jq -c . "$STATE_DIR/assess.json" 2>/dev/null || echo '{}')"
TEST='{}';   [[ -r "$STATE_DIR/last-test.json" ]] && TEST="$(jq -c . "$STATE_DIR/last-test.json" 2>/dev/null || echo '{}')"

# mget <jq-filter> <default> — read a scalar from the manifest with a fallback.
mget() { local v; v="$(printf '%s' "$M" | jq -r "$1 // empty" 2>/dev/null)"; [[ -n "$v" ]] && printf '%s' "$v" || printf '%s' "$2"; }
# mlist <jq-filter> — newline list of strings (may be empty).
mlist() { printf '%s' "$M" | jq -r "$1 // [] | .[]? | tostring" 2>/dev/null || true; }

TYPE="$(mget '.type' 'module')"
PHASE="$(mget '.phase' 'port')"
CORE="$(mget '.core_version_requirement' "$(printf '%s' "$ASSESS" | jq -r '.recommended_core_version_requirement // empty' 2>/dev/null)")"
[[ -n "$CORE" ]] || CORE="n/a"
REQ_PHP="$(mget '.require_php' 'none')"
PHP_TARGET="$(mget '.php_target' "$(resolve_php_target)")"
BUMP="$(mget '.version_bump' 'n/a')"
RECTOR_FILES="$(mget '.rector_official_files' 'n/a')"
DEPR="$(mget '.deprecations_remaining' 'n/a')"
D10="$(mget '.d10_support' '')"
PATCH="$(mget '.patch' '')"

# Preservation: prefer the manifest, fall back to last-test.json.
PRESERVATION="$(mget '.preservation' "$(printf '%s' "$TEST" | jq -r '.preservation // empty' 2>/dev/null)")"
[[ -n "$PRESERVATION" ]] || PRESERVATION="unknown"
case "$PRESERVATION" in
  verified)              PRES_LINE="✅ **verified** — the adapted test suite is green; behavior is preserved.";;
  verified-partial)      PRES_LINE="🟡 **partially verified** — the groups that ran are green, but some were skipped (an external blocker), so part of the behavior is unproven.";;
  regression)            PRES_LINE="❌ **regression** — a behavioral test is red. Fix the production code (never the test).";;
  not-verified-blocked)  PRES_LINE="⚠️ **not verified (blocked)** — tests exist but could not run (e.g. Selenium). Documented, not hidden.";;
  not-verified-no-tests) PRES_LINE="⚠️ **not verified** — the subject ships no tests, so preservation cannot be proven. drupilot does not fabricate tests.";;
  *)                     PRES_LINE="• preservation: not run yet (run /drupilot-test).";;
esac

VERDICT="$(printf '%s' "$ASSESS" | jq -r '.verdict // .effort // empty' 2>/dev/null || true)"

# Render lists as markdown bullets (or an em dash when empty).
bullets() { local any=0; while IFS= read -r line; do [[ -z "$line" ]] && continue; printf -- '- %s\n' "$line"; any=1; done; [[ "$any" == "0" ]] && printf '_none_\n'; return 0; }

# Didactic "changes explained": run the captured Rector/PHPStan log through the
# deprecation explainer (best-effort; renders nothing when the log is absent or
# matches no known symbol). The array is validated so a malformed payload degrades
# to "no section" instead of breaking the report.
EXPLAINED='[]'
if [[ -n "$CHANGES_LOG" && -r "$CHANGES_LOG" ]]; then
  EXPLAINER="$(plugin_root)/scripts/analysis/explain-deprecations.sh"
  if [[ -r "$EXPLAINER" ]]; then
    EXPLAINED="$(bash "$EXPLAINER" --file "$CHANGES_LOG" --json 2>/dev/null || echo '[]')"
    printf '%s' "$EXPLAINED" | jq empty 2>/dev/null || EXPLAINED='[]'
  fi
fi
EXPLAINED_N="$(printf '%s' "$EXPLAINED" | jq 'length' 2>/dev/null || echo 0)"

{
  printf '# Port report — %s\n\n' "$NAME"
  printf '_Generated by drupilot — the at-a-glance record of what the "%s" phase did and why._\n\n' "$PHASE"

  printf '## Summary\n\n'
  printf '| | |\n|---|---|\n'
  printf '| Subject | `%s` (%s) |\n' "$NAME" "$TYPE"
  printf '| Phase | %s |\n' "$PHASE"
  [[ -n "$VERDICT" ]] && printf '| Assessment verdict | %s |\n' "$VERDICT"
  printf '| `core_version_requirement` | `%s` |\n' "$CORE"
  printf '| composer `require.php` | `%s` |\n' "$REQ_PHP"
  printf '| PHP target | %s |\n' "$PHP_TARGET"
  printf '| Version bump | %s |\n' "$BUMP"
  printf '| Preservation | %s |\n' "$PRESERVATION"
  printf '\n'

  printf '## Preservation gate\n\n%s\n\n' "$PRES_LINE"
  if [[ -n "$D10" ]]; then
    printf '> Drupal 10 compatibility: **%s**. ' "$D10"
    [[ "$D10" == "declared-not-verified" ]] && printf 'The `^10` half is declared, not verified — install/test on Drupal 10 before relying on it.'
    printf '\n\n'
  fi

  printf '## What changed\n\n'
  printf '### Rector (official pass)\n\n%s file(s) changed.\n\n' "$RECTOR_FILES"

  printf '### Digests layer (AI-generated, unlicensed)\n\n'
  if [[ "$(printf '%s' "$M" | jq -r '.digests.skipped // false' 2>/dev/null)" == "true" ]]; then
    printf '_Skipped._\n\n'
  else
    printf '**Applied rules:**\n\n'; mlist '.digests.applied' | bullets; printf '\n'
    printf '**Rejected rules (with reason):**\n\n'
    printf '%s' "$M" | jq -r '.digests.rejected // [] | .[]? | "- `\(.rule // "?")` — \(.reason // "rejected")"' 2>/dev/null | { grep . || printf '_none_\n'; }
    printf '\n'
  fi

  printf '### Manual edits\n\n'
  # Items may be a plain string or an object {edit, why?, change_record?}.
  printf '%s' "$M" | jq -r '
    (.manual_edits // []) | .[]? |
    if type == "string" then "- " + .
    else "- " + (.edit // .what // "edit")
         + (if (.why // "") != "" then " — _why:_ " + .why else "" end)
         + (if (.change_record // "") != "" then " ([change record](" + .change_record + "))" else "" end)
    end
  ' 2>/dev/null | { grep . || printf '_none_\n'; }
  printf '\n'
  printf '### Remaining deprecations\n\n%s\n\n' "$DEPR"

  if [[ "$EXPLAINED_N" -gt 0 ]]; then
    printf '## Drupal 9/10 → 11 changes, explained\n\n'
    printf '_A best-effort teaching aid: each recognized change with what moved, the fix, and a drupal.org change record. Not exhaustive — see the patch for the exact diff._\n\n'
    printf '%s' "$EXPLAINED" | jq -r '
      ({"messenger":"Messenger","routing-url":"Routing & URLs","date":"Date & time formatting",
        "entity-api":"Entity API","database-api":"Database API","time":"Time service",
        "dependency-injection":"Dependency injection","forms":"Forms & controllers","twig":"Twig 3",
        "jquery-ui":"jQuery UI","ckeditor":"CKEditor 5","assertion":"Assertions",
        "phpunit":"PHPUnit 10/11","update-hooks":"Update hooks","other":"Other"}) as $t
      | group_by(.category)[]
      | "### " + ($t[(.[0].category)] // (.[0].category)) + "\n\n"
        + ( map("- **\(.symbol)** (\(.hits) hit(s)) — \(.why)\n    - Fix: \(.fix)\n    - Learn more: \(.change_record)") | join("\n") )
        + "\n"
    ' 2>/dev/null || true
    printf '\n'
  fi

  printf '## Deferred to Phase 2 (the Drupal 11 way)\n\n'; mlist '.deferred_to_phase2' | bullets; printf '\n'

  printf '## Artifacts\n\n'
  if [[ -n "$PATCH" ]]; then
    printf -- '- Patch: `%s` — apply elsewhere with `git apply %s`.\n' "$PATCH" "$PATCH"
  fi
  printf -- '- Regenerate a patch any time (local or issue-comment) with `/drupilot-patch` — no contribution required.\n'
  printf -- '- Run or re-run the suite with `/drupilot-test`; check state with `/drupilot-status`.\n'
} > "$REPORT"

log_ok "Port report written: $REPORT"
printf '%s\n' "$REPORT"
exit 0
