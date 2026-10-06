#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/digests-decisions.sh
# Record the developer's verdict on each dbuytaert/drupal-digests rule of a
# port (05-R6, T-M4-08), so a later port of the same module replays them and
# asks nothing: digests-decisions.json in the subject's hidden state dir, one
# verdict (accept | reject) per rule, keyed by the rule, the digests SHA and
# the subject's digest before the passes. The key comes from the last digests
# dry-run of run-rector.sh (its record, rector-dryrun.json): run
# `run-rector.sh --subject DIR --digests --json` first. A rejected rule is left
# out of the digests config of every later run with that key; a rule with no
# verdict is pending (run-rector.sh --json, digests_review.pending). A verdict
# recorded in an autonomous run (DRUPILOT_AUTONOMOUS=true) is kept with
# by: "auto": it is that run's safe default, not the developer's review, so
# only an autonomous run replays it (a guided port asks again). Verdicts are
# recorded only for the sources the dry-run saw: a module changed since then
# needs a new dry-run first.
#
# Usage:
#   digests-decisions.sh --subject DIR --list [--json]
#   digests-decisions.sh --subject DIR [--accept R[,R...]]... [--reject R[,R...]]...
#                        [--json]
#   digests-decisions.sh --subject DIR --clear
#     --list     the rules of the last digests dry-run with their verdicts
#     --accept   rules to apply (short class names, as digests_review names them)
#     --reject   rules to leave out
#     --clear    forget every verdict of the subject (/drupilot-clean does it too)
#     --json     {digests_sha, input_hash, rules: [{rule, verdict, by}],
#                pending: [...]} on STDOUT
#
# Exit codes: 0 done · 1 usage error, no digests dry-run to key the verdicts
# on, a module changed since that dry-run, or a rule it did not name.
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""; MODE="record"; ACCEPT=""; REJECT=""; AS_JSON=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --list) MODE="list"; shift;;
    --clear) MODE="clear"; shift;;
    --accept) ACCEPT="$ACCEPT,${2:-}"; shift 2 || die "--accept needs a value" 1;;
    --reject) REJECT="$REJECT,${2:-}"; shift 2 || die "--reject needs a value" 1;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ -n "$SUBJECT" && -d "$SUBJECT" ]] || die "Pass --subject DIR (an existing directory)." 1
have_cmd jq || die "jq is required (run /drupilot-doctor)." 1
SUBJECT="$(cd "$SUBJECT" && pwd)"
DF="$(digests_decisions_file "$SUBJECT")"

if [[ "$MODE" == "clear" ]]; then
  rm -f "$DF"
  log_ok "Forgot every digests verdict of $(basename "$SUBJECT")."
  exit 0
fi

REC="$(project_state_dir "$SUBJECT")/rector-dryrun.json"
jq -e '.digests == true and (.digests_review | type) == "object"' "$REC" > /dev/null 2>&1 \
  || die "No digests dry-run to key the verdicts on: run run-rector.sh --subject <dir> --digests --json first." 1
SHA="$(jq -r '.digests_review.digests_sha' "$REC")"; INP="$(jq -r '.digests_review.input_hash' "$REC")"
AUTO=false; [[ "$(lc "$(config_get DRUPILOT_AUTONOMOUS false)")" == "true" ]] && AUTO=true
BY="developer"; [[ "$AUTO" == "true" ]] && BY="auto"
KNOWN="$(jq -c '[.digests_review.rules[].rule] + .digests_review.rejected | unique' "$REC")"
if [[ "$MODE" == "record" ]]; then
  [[ -n "$ACCEPT$REJECT" ]] || die "Pass --accept, --reject, --list or --clear (see --help)." 1
  [[ "$(subject_digest "$SUBJECT")" == "$INP" ]] \
    || die "The module changed since the last digests dry-run: run run-rector.sh --subject <dir> --digests --json again, then record the verdicts." 1
  LIST="$(jq -n -c --arg a "$ACCEPT" --arg r "$REJECT" '
    def items($s; $v): $s | split(",") | map(gsub("^\\s+|\\s+$"; "") | select(length > 0) | {rule: ., verdict: $v});
    items($a; "accept") + items($r; "reject")')"
  BAD="$(jq -r --argjson k "$KNOWN" '[.[].rule | select(. as $r | $k | index($r) | not)] | unique | join(", ")' <<< "$LIST")"
  [[ -z "$BAD" ]] || die "Not a rule of the last digests dry-run: $BAD (see --list)." 1
  mkdir -p "$(dirname "$DF")" || die "Cannot create $(dirname "$DF")." 1
  base='{"schema": 1, "decisions": []}'
  [[ -f "$DF" ]] && jq -e -s 'length == 1 and (.[0] | type == "object")' "$DF" > /dev/null 2>&1 && base="$(cat "$DF")"
  jq -n -c --argjson b "$base" --argjson l "$LIST" --arg sha "$SHA" --arg inp "$INP" --arg by "$BY" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    ($l | map({key: .rule, value: .verdict}) | from_entries) as $new
    | $b | .schema = 1
    | .decisions = ([(.decisions // [])[] | select((.digests_sha == $sha and .input_hash == $inp and ($new[.rule] != null)) | not)]
                    + [$l[] | {rule, digests_sha: $sha, input_hash: $inp, verdict, by: $by, at: $at}]
                    | sort_by([.digests_sha, .input_hash, .rule]))' | canon_json > "$DF.tmp.$$" \
    && mv -f "$DF.tmp.$$" "$DF" || die "Could not write $DF." 1
  log_ok "Recorded $(jq 'length' <<< "$LIST") digests verdict(s) for $(basename "$SUBJECT")."
fi

# The rules of the last dry-run with their verdicts (record mode: after it).
base='{"decisions": []}'
[[ -f "$DF" ]] && jq -e -s 'length == 1 and (.[0] | type == "object")' "$DF" > /dev/null 2>&1 && base="$(cat "$DF")"
OUTJ="$(jq -n -c --argjson b "$base" --argjson k "$KNOWN" --arg sha "$SHA" --arg inp "$INP" --argjson auto "$AUTO" '
  ([($b.decisions // [])[] | select(.digests_sha == $sha and .input_hash == $inp and ((.by // "developer") != "auto" or $auto))]
   | map({key: .rule, value: {verdict, by: (.by // "developer")}}) | from_entries) as $v
  | {digests_sha: $sha, input_hash: $inp, rules: [$k[] | {rule: ., verdict: ($v[.].verdict // "pending"), by: ($v[.].by // null)}]}
  | . + {pending: [.rules[] | select(.verdict == "pending") | .rule]}')"
if [[ "$AS_JSON" == "1" ]]; then
  printf '%s\n' "$OUTJ"
else
  jq -r '.rules[] | "  \(.verdict)\t\(.rule)\(if .by == "auto" then "  (an autonomous run'"'"'s default)" else "" end)"' <<< "$OUTJ" >&2
  log_info "$(jq '.pending | length' <<< "$OUTJ") rule(s) pending."
fi
exit 0
