#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/ai/apply-recipes.sh
# Pipeline steps S6 and S7 (T-M4-07, 05-R6, ADR 0024): apply every open codemod
# item of the subject's worklist.json, finding by finding, with
# scripts/ai/apply-recipe.sh, then classify again so the result shows in the
# worklist; with --reextract, run the re-extraction first (extract.sh,
# normalize-findings.sh, classify.sh on the new tree): the residual worklist.
#
# Each application is one line of the subject's actions log,
# <state>/actions.jsonl (DET-9; the machine record of what the recipes and,
# later, the AI did, kept apart from the human decisions.jsonl of
# log-decision.sh): {schema, kind: "recipe-apply", item_id, finding_id,
# recipe, version, file, line, status, input_hash, output_hash,
# findings_hash, at}; a crash of apply-recipe.sh is status error, and after the
# re-extraction a codemod applied now whose finding is still there gets a
# not-cleared line. classify.sh reads it: a codemod that gave no change,
# failed or did not clear its finding moves the finding to ai-templated, and
# an item whose codemods were all applied on the current findings (their
# output still in the file) is `applied`. The recipes are the plugin's with
# the project overlay (<root>/.drupilot/recipes.json), as classify.sh uses
# them; an application already in effect is not run again.
#
# Usage:
#   apply-recipes.sh --subject DIR [--reextract] [--dry-run] [--json]
#                    [-h|--help]
#     --subject DIR   the module/theme (inside its Drupal root)
#     --reextract     S7: re-run extract.sh (the worklist's stage),
#                     normalize-findings.sh and classify.sh after applying
#     --dry-run       report what each codemod would change; write nothing,
#                     log nothing
#     --json          {subject, stage, dry_run, applications: [{item_id,
#                      finding_id, recipe, file, line, status}], applied,
#                      not_applied, reextracted, worklist: {counts}} on STDOUT
#
# Exit codes: 0 done · 1 usage error, no worklist.json or findings.json, a
# recipe catalog that is not one, or a re-extraction step that failed · 3 a
# codemod was rejected (a postcondition failed: that file is unchanged), or the
# re-extraction gave no verdict (extract.sh exit 3).
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""; REEXTRACT=0; DRY=0; AS_JSON=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --reextract) REEXTRACT=1; shift;;
    --dry-run) DRY=1; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ -n "$SUBJECT" ]] || die "Pass --subject DIR (see --help)." 1
[[ -d "$SUBJECT" ]] || die "Subject '$SUBJECT' is not a directory." 1
have_cmd jq || die "jq is required (run /drupilot-doctor)." 1
SUBJECT="$(cd "$SUBJECT" && pwd)"
SD="$(project_state_dir "$SUBJECT")"
WL="$(worklist_file "$SUBJECT")"; FJ="$SD/findings.json"; ACT="$SD/actions.jsonl"
[[ -f "$WL" ]] || die "No worklist.json for $SUBJECT (run scripts/ai/classify.sh first)." 1
[[ -f "$FJ" ]] || die "No findings.json for $SUBJECT (run scripts/ai/normalize-findings.sh first)." 1
S="$(plugin_root)/scripts"
STAGE="$(jq -r '.stage // "assess"' "$WL")"
FLOOR="$(jq -r '.floor // empty' "$WL")"
FHASH="$(jq -r '.meta.findings_hash // empty' "$FJ")"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-apply.XXXXXX")"
trap 'rm -rf "$TMP" 2> /dev/null || true' EXIT
# The recipes in effect, the ones classify.sh used: the project overlay
# replaces the plugin's by id.
ROOT="$(subject_project_root "$SUBJECT" 2> /dev/null || true)"
OVERLAY=""; [[ -n "$ROOT" && -f "$ROOT/.drupilot/recipes.json" ]] && OVERLAY="$ROOT/.drupilot/recipes.json"
recipes_effective "$(plugin_root)/config/recipes.json" "$OVERLAY" "$TMP/recipes.json" \
  || die "The recipes${OVERLAY:+ (with the overlay $OVERLAY)} are not a recipe catalog." 1
# Applications already in effect (applied, the file still holds the last
# applied output) are not run again, at the same recipe version.
actions_state "$ACT" "$SUBJECT" "$TMP/actions.json"
# One line per (item, finding, recipe) of an open codemod item, with the
# finding's file, line, message and severity.
jq -c --slurpfile f "$FJ" --slurpfile asf "$TMP/actions.json" --slurpfile rc "$TMP/recipes.json" "$(actions_jq_defs)"'
  ($f[0].findings | map({key: .id, value: .}) | from_entries) as $byid
  | ($rc[0].recipes | map({key: .id, value: .version}) | from_entries) as $ver
  | $asf[0] as $st
  | .items[] | select(.lane == "codemod" and .status == "open") | . as $it
  | .finding_ids[] | . as $fid | ($it.recipe_of[$fid] // null) as $r | select($r != null)
  | ($st.last["\($fid)\u001f\($r)\u001f\($ver[$r])"]) as $a
  | select(($a != null and $a.status == "applied" and ($a | in_effect($st))) | not)
  | $byid[$fid] as $x | select($x != null)
  | {item_id: $it.id, finding_id: $fid, recipe: $r, file: $x.file, line: $x.line, message: $x.message, severity: $x.severity}' \
  "$WL" > "$TMP/todo.jsonl"

: > "$TMP/apps.jsonl"; REJECTED=0
while IFS= read -r t; do
  [[ -n "$t" ]] || continue
  tq() { jq -r "$1 // empty" <<< "$t"; }
  set -- --recipe "$(tq .recipe)" --recipes "$TMP/recipes.json" --subject "$SUBJECT" --file "$(tq .file)" --json
  [[ -n "$(tq .line)" ]] && set -- "$@" --line "$(tq .line)"
  [[ -n "$(tq .message)" ]] && set -- "$@" --message "$(tq .message)"
  [[ -n "$(tq .severity)" ]] && set -- "$@" --severity "$(tq .severity)"
  [[ -n "$FLOOR" ]] && set -- "$@" --core-floor "$FLOOR"
  [[ "$DRY" == "1" ]] && set -- "$@" --dry-run
  rc=0
  res="$(bash "$S/ai/apply-recipe.sh" "$@" < /dev/null)" || rc=$?
  # (-s: jq 1.6 exits 0 on an empty input with -e.) A crash is recorded as an
  # error of this recipe version, so classify.sh moves the finding on.
  if ! jq -e -s 'length == 1 and (.[0] | has("status"))' <<< "$res" > /dev/null 2>&1; then
    res="$(jq -n -c --arg r "$(tq .recipe)" --slurpfile rc "$TMP/recipes.json" --arg ih "$(file_hash "$SUBJECT/$(tq .file)")" \
      '{recipe: $r, status: "error", version: ([$rc[0].recipes[] | select(.id == $r) | .version] | .[0] // null), input_hash: $ih, output_hash: $ih}')"
  fi
  [[ "$rc" == "3" ]] && REJECTED=1
  app="$(jq -c --argjson t "$t" --arg fh "$FHASH" '{schema: 1, kind: "recipe-apply", item_id: $t.item_id, finding_id: $t.finding_id,
           recipe: $t.recipe, version: .version, file: $t.file, line: $t.line, status: .status,
           input_hash: .input_hash, output_hash: .output_hash, findings_hash: (if $fh == "" then null else $fh end)}' <<< "$res")"
  printf '%s\n' "$app" >> "$TMP/apps.jsonl"
  if [[ "$DRY" != "1" ]]; then
    jq -c --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {at: $at}' <<< "$app" >> "$ACT" || die "Could not write $ACT." 1
  fi
done < "$TMP/todo.jsonl"
N_APPLIED="$(jq -s '[.[] | select(.status == "applied" or .status == "would-apply")] | length' "$TMP/apps.jsonl")"
N_NOT="$(jq -s '[.[] | select(.status != "applied" and .status != "would-apply")] | length' "$TMP/apps.jsonl")"
log_ok "apply-recipes: $N_APPLIED codemod change(s)$([[ "$DRY" == "1" ]] && echo ' (dry-run)'), $N_NOT not applied (they fall to the AI lane)."

# The worklist again: on the same findings (the applied items show as
# applied, the rest fall to their next lane), or on a re-extraction (S7).
REX=false; RC=0
if [[ "$DRY" != "1" ]]; then
  if [[ "$REEXTRACT" == "1" ]]; then
    REX=true
    bash "$S/ai/extract.sh" --subject "$SUBJECT" --stage "$STAGE" < /dev/null || { rc=$?; [[ "$rc" == "3" ]] && RC=3 || die "extract.sh failed (exit $rc)." 1; }
    bash "$S/ai/normalize-findings.sh" --subject "$SUBJECT" --stage "$STAGE" < /dev/null || die "normalize-findings.sh failed." 1
    # Every codemod applied and still in effect (this run or an earlier one)
    # whose finding the new extraction still has did not clear it: recorded,
    # so it is not tried again.
    NEWFH="$(jq -r '.meta.findings_hash // empty' "$FJ")"
    actions_state "$ACT" "$SUBJECT" "$TMP/actions2.json"
    jq -c --slurpfile f "$FJ" --arg fh "$NEWFH" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(actions_jq_defs)"'
      . as $st | ([$f[0].findings[].id]) as $ids
      | .last[] | select(.status == "applied" and in_effect($st)) | select(.finding_id as $i | $ids | index($i))
      | . + {status: "not-cleared", findings_hash: (if $fh == "" then null else $fh end), at: $at}' "$TMP/actions2.json" >> "$ACT" \
      || die "Could not write $ACT." 1
  fi
  bash "$S/ai/classify.sh" --subject "$SUBJECT" < /dev/null || die "classify.sh failed." 1
fi
[[ "$REJECTED" == "1" ]] && RC=3

if [[ "$AS_JSON" == "1" ]]; then
  jq -n --arg s "$SUBJECT" --arg st "$STAGE" --argjson dry "$([[ "$DRY" == "1" ]] && echo true || echo false)" \
    --argjson rex "$REX" --slurpfile apps "$TMP/apps.jsonl" --slurpfile wl "$WL" '
    {subject: $s, stage: $st, dry_run: $dry,
     applications: [$apps[] | {item_id, finding_id, recipe, file, line, status}],
     applied: ([$apps[] | select(.status == "applied" or .status == "would-apply")] | length),
     not_applied: ([$apps[] | select(.status != "applied" and .status != "would-apply")] | length),
     reextracted: $rex, worklist: {counts: $wl[0].counts}}'
fi
exit "$RC"
