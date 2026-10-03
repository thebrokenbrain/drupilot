#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/port-summary.sh
# The MACHINE SUMMARY of a port: one versioned JSON object a wrapper (another
# skill, a CI job, a script driving `claude -p`) reads instead of parsing the
# Markdown reports or the model's prose. It COMPOSES what drupilot already
# recorded and never computes, guesses or edits anything:
#   * state.json + a fresh snapshot (common.sh state_view_json): stage, effort,
#     git, toolchain, the last test run, the core matrix, the last patch;
#   * the port record (common.sh port_record_json): the port manifest merged
#     with the decision log — Rector rules, reverted rules, manual fixes, ...;
#   * the port manifest's own fields (digests, deferred items, safety gates);
#   * the subject's info.yml / composer.json as they are now.
# Every field is nullable: an unknown value is null, never invented.
#
# Usage:
#   port-summary.sh [--subject DIR] [--json] [--write] [--output DIR] [--strict]
#
# Options:
#   --subject DIR  The module/theme directory (default: current directory).
#   --json         Print only the JSON on STDOUT (the human summary on STDERR is
#                  suppressed). Without it, STDOUT still carries the JSON and a
#                  short human summary goes to STDERR.
#   --write        Also save the JSON as port-summary.json in the visible,
#                  gitignored .drupilot/ artifacts dir at the Drupal root
#                  (port-report.sh refreshes it there after every report).
#   --output DIR   Write port-summary.json into DIR instead (implies --write).
#   --strict       Exit 3 when status is "blocked" (for a wrapper's gate).
#   -h, --help     Show this help.
#
# Output (schema_version 1; additive changes keep the version, a renamed or
# removed key bumps it):
#   {schema_version, drupilot_version, generated_at,
#    subject, machine_name, type, drupal_root, origin,
#    status,          not-started | setup | assessed | ported | refactored |
#                     tested | contributed | blocked
#    stage,           the highest stage recorded (null before any)
#    blockers: [{source, reason}],   why status is "blocked" (empty otherwise)
#    effort, assessed_at,            the viability verdict (S/M/L/XL)
#    core_version_requirement, require_php,   as declared NOW
#    d10_support,     declared-not-verified | verified-static |
#                     verified-static-above-floor | failed | null
#    files_changed,   manifest.files_changed, else the files in the patch
#    rector_rules: [{rule, hits, passes}], rector_rules_source,
#    digests: {applied, rejected, skipped} | null,
#    reverted_rules: [{rule, file, why, ...}],
#    manual_fixes: [{edit, why, change_record}],
#    post_port_fixes, behavior_changes, preexisting_bugs, tooling_deviations,
#    test_adaptations,               (the port record's lists, see common.sh)
#    deferred: [string],             items left for Phase 2
#    deprecations_remaining,
#    preservation: {verdict, status, executed, tests_failed, fresh,
#                   recorded_at} | null,
#    matrix: {verdict, d10_support, fresh, generated_at} | null,
#    safety: {port_safety_errors, signature_errors} | null,
#    patch: {path, kind, at, exists} | null,
#    reports: {port_report, viability_report, decisions, summary},
#    decisions}                      number of decision-log entries
# status is derived deterministically: the stage, except "blocked" once the
# subject is ported and one of these holds — the last test run (on the current
# sources, or of unknown freshness) is regression / not-verified-blocked /
# not-verified-unbaselined; a fresh core matrix failed; the manifest's
# port-safety or signature-change scan recorded errors. A result computed on
# sources that changed since (fresh: false) is reported but never blocks.
#
# Read-only (apart from --write). Ungated: needs only jq.
# Exit codes: 0 ok · 1 usage error / not a module or theme / jq missing ·
#             3 --strict and status is "blocked".
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
AS_JSON=0
WRITE=0
OUTPUT=""
STRICT=0
usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a directory" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    --write) WRITE=1; shift;;
    --output) OUTPUT="${2:-}"; WRITE=1; shift 2 || die "--output needs a directory" 1;;
    --output=*) OUTPUT="${1#*=}"; WRITE=1; shift;;
    --strict) STRICT=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_err "Unknown argument: $1"; usage >&2; exit 1;;
  esac
done

have_cmd jq || die "jq is required for port-summary.sh (run /drupilot-doctor)." 1
[[ -n "$SUBJECT" ]] || SUBJECT="$PWD"
case "$SUBJECT" in \<*\>|*\<*\>*) die "Got the unsubstituted placeholder '$SUBJECT' — pass the real path." 1;; esac
[[ -d "$SUBJECT" ]] || die "Subject directory not found: $SUBJECT" 1
SUBJECT="$(cd "$SUBJECT" && pwd)"
is_drupal_extension_dir "$SUBJECT" || die "Not a module/theme directory (no *.info.yml): $SUBJECT" 1

STATE_DIR="$(project_state_path "$SUBJECT")"
ART_DIR="$(project_artifacts_path "$SUBJECT")"

VIEW="$(state_view_json "$SUBJECT")"
[[ -n "$VIEW" && "$VIEW" != "null" ]] || VIEW='{}'
RECORD="$(port_record_json "$SUBJECT")"
[[ -n "$RECORD" && "$RECORD" != "null" ]] || RECORD='{}'
MANIFEST='{}'
if [[ -r "$STATE_DIR/port-manifest.json" ]]; then
  MANIFEST="$(jq -c 'if type == "object" then . else {} end' "$STATE_DIR/port-manifest.json" 2>/dev/null || true)"
  [[ -n "$MANIFEST" ]] || MANIFEST='{}'
fi

CORE_REQ="$(subject_core_requirement "$SUBJECT" 2>/dev/null || true)"
CORE_REQ="$(printf '%s' "$CORE_REQ" | tr -d "\"'")"
REQ_PHP=""
[[ -r "$SUBJECT/composer.json" ]] && REQ_PHP="$(jq -r '.require.php // empty' "$SUBJECT/composer.json" 2>/dev/null || true)"

# files_changed: the manifest's count (or list), else the files in the patch.
PATCH_FILES=""
PATCH_PATH="$(printf '%s' "$VIEW" | jq -r '.patch.path // empty' 2>/dev/null || true)"
[[ -n "$PATCH_PATH" ]] || PATCH_PATH="$(printf '%s' "$MANIFEST" | jq -r '.patch | if type == "string" then . else empty end' 2>/dev/null || true)"
case "$PATCH_PATH" in ""|/*) ;; *) PATCH_PATH="$SUBJECT/$PATCH_PATH";; esac
if [[ -n "$PATCH_PATH" && -r "$PATCH_PATH" ]]; then
  PATCH_FILES="$(grep -c '^diff --git ' "$PATCH_PATH" 2>/dev/null || true)"
fi

report_path() { [[ -f "$1" ]] && printf '%s' "$1"; return 0; }
R_PORT=""
[[ -n "$OUTPUT" ]] && R_PORT="$(report_path "$(cd "$OUTPUT" 2>/dev/null && pwd || printf '%s' "$OUTPUT")/port-report.md")"
[[ -n "$R_PORT" ]] || R_PORT="$(report_path "$ART_DIR/port-report.md")"
R_VIAB="$(report_path "$ART_DIR/viability-report.md")"
R_DEC="$(report_path "$ART_DIR/decisions.md")"
SUMMARY_DIR="$ART_DIR"
[[ -n "$OUTPUT" ]] && SUMMARY_DIR="$(cd "$OUTPUT" 2>/dev/null && pwd || printf '%s' "$OUTPUT")"
R_SUM=""
if [[ "$WRITE" == "1" ]]; then
  R_SUM="$SUMMARY_DIR/port-summary.json"
else
  R_SUM="$(report_path "$ART_DIR/port-summary.json")"
fi

SUMMARY="$(jq -n \
  --argjson v "$VIEW" --argjson r "$RECORD" --argjson m "$MANIFEST" \
  --arg subject "$SUBJECT" --arg ver "$(plugin_version)" \
  --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg core "$CORE_REQ" --arg php "$REQ_PHP" --arg pfiles "$PATCH_FILES" \
  --arg r_port "$R_PORT" --arg r_viab "$R_VIAB" --arg r_dec "$R_DEC" --arg r_sum "$R_SUM" '
  def nz: if . == "" then null else . end;
  def srank: {"setup":1,"assessed":2,"ported":3,"refactored":4,"tested":5,"contributed":6}[. // ""] // 0;
  def num: if type == "number" then . elif type == "array" then length
           elif type == "string" then (tonumber? // null) else null end;
  ($v.stage // null) as $stage
  | ($v.tests // null) as $t
  | ($v.core_matrix // null) as $cm
  | (($m.d10_support // null) as $md
     | if ($md == null or $md == "declared-not-verified" or $md == "n/a")
          and ($cm != null) and ($cm.fresh == true) and (($cm.d10_support // null) != null)
       then $cm.d10_support else $md end) as $d10
  | ([ (if $t != null and ($t.fresh != false)
          and (($t.preservation // "") | IN("regression", "not-verified-blocked", "not-verified-unbaselined"))
        then {source: "tests", reason: ("preservation: " + $t.preservation)} else empty end),
       (if $cm != null and $cm.fresh == true
          and (($cm.verdict // "") == "fail" or ($cm.d10_support // "") == "failed")
        then {source: "core-matrix", reason: "a declared core leg failed (d10_support: \($cm.d10_support // "n/a"))"} else empty end),
       (if (($m.port_safety.errors // 0) | num // 0) > 0
        then {source: "port-safety", reason: "\($m.port_safety.errors) error finding(s) recorded by check-port-safety.sh"} else empty end),
       (if (($m.signature_changes.errors // 0) | num // 0) > 0
        then {source: "signature-changes", reason: "\($m.signature_changes.errors) error finding(s) recorded by scan-signature-changes.sh"} else empty end)
     ] | if ($stage | srank) >= ("ported" | srank) then . else [] end) as $blockers
  | {schema_version: 1,
     drupilot_version: ($ver | nz),
     generated_at: $now,
     subject: $subject,
     machine_name: ($v.machine_name // $r.machine_name // null),
     type: ($v.type // $m.type // null),
     drupal_root: ($v.drupal_root // null),
     origin: ($v.origin // null),
     status: (if ($blockers | length) > 0 then "blocked" else ($stage // "not-started") end),
     stage: $stage,
     blockers: $blockers,
     effort: ($v.effort // null),
     assessed_at: ($v.assessed_at // null),
     core_version_requirement: ($core | nz),
     require_php: ($php | nz),
     d10_support: $d10,
     files_changed: (($m.files_changed // null | num) // ($pfiles | nz | if . == null then null else tonumber end)),
     rector_rules: ($r.rector_rules // []),
     rector_rules_source: ($r.rector_rules_source // null),
     digests: (if ($m.digests | type) == "object"
               then {applied: ($m.digests.applied // null), rejected: ($m.digests.rejected // null),
                     skipped: ($m.digests.skipped // null)}
               else null end),
     reverted_rules: ($r.rector_reversions // []),
     manual_fixes: ($r.manual_edits // []),
     post_port_fixes: ($r.post_port_fixes // []),
     behavior_changes: ($r.behavior_changes // []),
     preexisting_bugs: ($r.preexisting_bugs // []),
     tooling_deviations: ($r.tooling_deviations // []),
     test_adaptations: ($r.test_adaptations // []),
     deferred: ($m.deferred_to_phase2 // [] | if type == "array" then map(if type == "string" then . else tojson end) else [tostring] end),
     deprecations_remaining: ($m.deprecations_remaining // null | num),
     preservation: (if $t == null then null
                    else {verdict: ($t.preservation // null), status: ($t.status // null),
                          executed: ($t.executed // null), tests_failed: ($t.tests_failed // null),
                          fresh: ($t.fresh // null), recorded_at: ($t.recorded_at // null)} end),
     matrix: (if $cm == null then null
              else {verdict: ($cm.verdict // null), d10_support: ($cm.d10_support // null),
                    fresh: ($cm.fresh // null), generated_at: ($cm.generated_at // null)} end),
     safety: (if ($m.port_safety // null) == null and ($m.signature_changes // null) == null then null
              else {port_safety_errors: ($m.port_safety.errors // null | num),
                    signature_errors: ($m.signature_changes.errors // null | num)} end),
     patch: ($v.patch // null),
     reports: {port_report: ($r_port | nz), viability_report: ($r_viab | nz),
               decisions: ($r_dec | nz), summary: ($r_sum | nz)},
     decisions: ($r.decisions // 0)}')"

if [[ "$WRITE" == "1" ]]; then
  if [[ -n "$OUTPUT" ]]; then
    mkdir -p "$OUTPUT" || die "Cannot create the output directory: $OUTPUT" 1
  else
    SUMMARY_DIR="$(project_artifacts_dir "$SUBJECT")"
  fi
  _tmp="$(mktemp "$SUMMARY_DIR/.port-summary.XXXXXX")" || die "Cannot write into $SUMMARY_DIR" 1
  chmod 0644 "$_tmp" 2>/dev/null || true   # mktemp creates 0600; the file is a shared report
  printf '%s\n' "$SUMMARY" | jq . > "$_tmp" && mv -f "$_tmp" "$SUMMARY_DIR/port-summary.json" \
    || { rm -f "$_tmp"; die "Cannot write $SUMMARY_DIR/port-summary.json" 1; }
  log_ok "Port summary written: $SUMMARY_DIR/port-summary.json"
fi

STATUS="$(printf '%s' "$SUMMARY" | jq -r '.status')"
if [[ "$AS_JSON" != "1" ]]; then
  printf '%s' "$SUMMARY" | jq -r '
    "drupilot port summary — \(.machine_name // "?") (\(.type // "?"))",
    "  status      : \(.status)\(if .stage != null and .status == "blocked" then " (stage: \(.stage))" else "" end)",
    "  effort      : \(.effort // "n/a")",
    "  core        : \(.core_version_requirement // "n/a")  ·  Drupal 10: \(.d10_support // "n/a")",
    "  files       : \(.files_changed // "n/a") changed  ·  Rector rules: \(.rector_rules | length)  ·  reverted: \(.reverted_rules | length)  ·  manual fixes: \(.manual_fixes | length)",
    "  preservation: \(.preservation.verdict // "n/a")",
    "  patch       : \(.patch.path // "none")",
    (.blockers[] | "  blocked by  : [\(.source)] \(.reason)")' >&2 || true
fi
printf '%s\n' "$SUMMARY"

if [[ "$STRICT" == "1" && "$STATUS" == "blocked" ]]; then
  exit 3
fi
exit 0
