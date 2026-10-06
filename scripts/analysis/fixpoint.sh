#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/fixpoint.sh
# The fixpoint gate (T-M4-11, AR-16, 05-R9, DET-8): at the end of a port or a
# refactor, run the extraction again on the tree as it is (extract.sh with
# its Rector dry-run, normalize-findings.sh, classify.sh) and the codemods in
# dry-run (apply-recipes.sh --dry-run), and check that nothing is left for the
# deterministic lanes:
#   rector     no Rector finding (the dry-run would change nothing); a
#              digests rule the developer rejected never counts
#   codemods   no codemod that would still change a file
#   open       no open item in a processed lane (rector, rector-custom,
#              codemod; the AI lanes join when their executor does)
# It writes <state>/fixpoint.json (converged, the exact items of each list)
# and records the run in <state>/runs/<run_id>/run-manifest.json (its input
# and output hashes; DRUPILOT_RUNS_KEEP runs are kept).
#
# DRUPILOT_FIXPOINT: warn (default through the betas): a failure is reported
# and the exit code stays 0 · enforce: a failure exits 3, the stage is not
# done · off: nothing runs.
#
# Usage:
#   fixpoint.sh --subject DIR [--stage S] [--findings F --worklist W]
#               [--json] [-h|--help]
#     --subject DIR   the module/theme (inside its Drupal root)
#     --stage S       the extraction's stage (default: validate)
#     --findings F    read this findings.json and --worklist W instead of
#                     extracting again (a test's; no Docker), and skip the
#                     codemod dry-run
#     --json          print fixpoint.json on STDOUT
#
# Exit codes: 0 converged, or not converged in warn mode, or off · 1 usage
# error, or the extraction failed · 3 not converged in enforce mode, or the
# extraction gave no verdict (Rector or PHPStan).
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""; STAGE="validate"; FINDINGS=""; WORKLIST=""; AS_JSON=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --stage) STAGE="${2:-}"; shift 2 || die "--stage needs a value" 1;;
    --findings) FINDINGS="${2:-}"; shift 2 || die "--findings needs a value" 1;;
    --worklist) WORKLIST="${2:-}"; shift 2 || die "--worklist needs a value" 1;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ -n "$SUBJECT" && -d "$SUBJECT" ]] || die "Pass --subject DIR (an existing directory)." 1
[[ -z "$FINDINGS" && -z "$WORKLIST" || -n "$FINDINGS" && -n "$WORKLIST" ]] || die "Pass --findings and --worklist together." 1
have_cmd jq || die "jq is required (run /drupilot-doctor)." 1
SUBJECT="$(cd "$SUBJECT" && pwd)"
ROOT="$(find_drupal_root "$SUBJECT" 2> /dev/null || true)"
if [[ -n "$ROOT" && -z "${DRUPILOT_PROJECT_DIR:-}" ]]; then export DRUPILOT_PROJECT_DIR="$ROOT"; fi
MODE="$(lc "$(config_get DRUPILOT_FIXPOINT warn)")"
case "$MODE" in enforce|warn|off) ;; *) log_warn "DRUPILOT_FIXPOINT=$MODE is not enforce, warn or off: warn."; MODE="warn";; esac
SD="$(project_state_dir "$SUBJECT")"
S="$(plugin_root)/scripts"
if [[ "$MODE" == "off" ]]; then
  log_info "fixpoint: off (DRUPILOT_FIXPOINT)."
  [[ "$AS_JSON" == "1" ]] && printf '{"schema": 1, "mode": "off", "converged": null}\n'
  exit 0
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-fixpoint.XXXXXX")"
trap 'rm -rf "$TMP" 2> /dev/null || true' EXIT
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The extraction again, on the tree as it is.
NOVERDICT=0
printf '{"applications": []}\n' > "$TMP/apply.json"
if [[ -z "$FINDINGS" ]]; then
  _rc=0; bash "$S/ai/extract.sh" --subject "$SUBJECT" --stage "$STAGE" < /dev/null || _rc=$?
  case "$_rc" in 0) ;; 3) NOVERDICT=1;; *) die "extract.sh failed (exit $_rc)." 1;; esac
  bash "$S/ai/normalize-findings.sh" --subject "$SUBJECT" --stage "$STAGE" < /dev/null || die "normalize-findings.sh failed." 1
  bash "$S/ai/classify.sh" --subject "$SUBJECT" < /dev/null || die "classify.sh failed." 1
  FINDINGS="$SD/findings.json"; WORKLIST="$(worklist_file "$SUBJECT")"
  bash "$S/ai/apply-recipes.sh" --subject "$SUBJECT" --dry-run --json < /dev/null > "$TMP/apply.raw" 2> /dev/null || true
  jq -e '(.applications | type) == "array"' "$TMP/apply.raw" > /dev/null 2>&1 && cp "$TMP/apply.raw" "$TMP/apply.json"
fi
jq -e '.schema == 1 and (.findings | type) == "array"' "$FINDINGS" > /dev/null 2>&1 || die "$FINDINGS is not a findings.json." 1
jq -e '.schema == 1 and (.items | type) == "array"' "$WORKLIST" > /dev/null 2>&1 || die "$WORKLIST is not a worklist.json." 1
jq -e '[.tools.rector, .tools.phpstan] | any(. != "ok" and . != "partial")' "$FINDINGS" > /dev/null 2>&1 && NOVERDICT=1

# The digests rules the developer rejected never count.
DD="$(digests_decisions_file "$SUBJECT")"
[[ -f "$DD" ]] && jq -e 'type == "object"' "$DD" > /dev/null 2>&1 || { printf '{"decisions": []}\n' > "$TMP/dd.json"; DD="$TMP/dd.json"; }
DOC="$TMP/fixpoint.json"
jq -n -c --slurpfile f "$FINDINGS" --slurpfile w "$WORKLIST" --slurpfile a "$TMP/apply.json" --slurpfile dd "$DD" \
  --arg mode "$MODE" --arg stage "$STAGE" --argjson nov "$NOVERDICT" '
  $f[0] as $F | $w[0] as $W
  | ([($dd[0].decisions // [])[] | select(.verdict == "reject") | .rule] | unique) as $rej
  | ["rector", "rector-custom", "codemod"] as $processed
  | ([$F.findings[] | select(.tool == "rector" and .scope == "current")
      | select(((.rule // "") | split("\\") | last) as $r | $rej | index($r) | not)
      | {id, rule, file, anchor}] | sort_by([.file, .anchor, .rule])) as $rx
  | ([$a[0].applications[] | select(.status == "would-apply") | {item_id, recipe, file}] | sort_by([.file, .recipe])) as $cm
  | ([$W.items[] | select(.status == "open" and (.lane as $l | $processed | index($l))) | {id, lane, file, anchor}]
     | sort_by([.lane, .file, .anchor])) as $open
  | {schema: 1, tool: "fixpoint", mode: $mode, stage: $stage, processed_lanes: $processed,
     no_verdict: ($nov == 1),
     converged: ($nov == 0 and ($rx | length) == 0 and ($cm | length) == 0 and ($open | length) == 0),
     rector: $rx, codemods: $cm, open_items: $open,
     findings_hash: ($F.meta.findings_hash // null), worklist_hash: ($W.meta.worklist_hash // null)}' | canon_json > "$DOC"
CONV="$(jq -r '.converged' "$DOC")"
jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {meta: {generated_at: $at}}' "$DOC" | canon_json > "$DOC.meta"
cp "$DOC.meta" "$SD/fixpoint.json.tmp.$$" && mv -f "$SD/fixpoint.json.tmp.$$" "$SD/fixpoint.json" || die "Could not write fixpoint.json." 1
run_manifest_record "$SUBJECT" fixpoint "$STARTED" \
  "$(jq -c '{stage, findings_hash, worklist_hash}' "$DOC")" "$(jq -c --arg h "$(file_hash "$DOC")" '{fixpoint_hash: $h, converged}' "$DOC")" > /dev/null || log_warn "Could not record the run."

RC=0
if [[ "$CONV" == "true" ]]; then
  log_ok "fixpoint: converged (Rector, the codemods and the processed lanes have nothing left)."
else
  _what="$(jq -r '[(if .no_verdict then "Rector or PHPStan gave no verdict" else empty end),
    (if (.rector | length) > 0 then "\(.rector | length) Rector change(s)" else empty end),
    (if (.codemods | length) > 0 then "\(.codemods | length) codemod change(s)" else empty end),
    (if (.open_items | length) > 0 then "\(.open_items | length) open item(s) in a processed lane" else empty end)] | join(", ")' "$DOC")"
  if [[ "$MODE" == "enforce" ]]; then log_err "fixpoint: not converged: $_what (see fixpoint.json)."; RC=3
  else log_warn "fixpoint: not converged: $_what (see fixpoint.json; DRUPILOT_FIXPOINT=warn)."; fi
  jq -r '(.rector[] | "  rector   \(.file) \(.anchor): \(.rule)"), (.codemods[] | "  codemod  \(.file): \(.recipe) (\(.item_id))"),
         (.open_items[] | "  open     \(.id) \(.lane) \(.file) \(.anchor)")' "$DOC" >&2
fi
[[ "$AS_JSON" == "1" ]] && cat "$DOC.meta"
exit "$RC"
