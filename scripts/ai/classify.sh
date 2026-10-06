#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/ai/classify.sh
# Turn findings.json into worklist.json (pipeline step S4; T-M4-07, AR-10, ADR
# 0024): every finding gets a lane, and the findings of one file, anchor and
# lane become one item. The lanes, in priority order: rector > rector-custom >
# codemod > ai-templated > ai-free > test-adapt > human > deferred.
#
#   deferred      a next-major finding (it never reaches an AI lane: X18), an
#                 info one (nothing to change), a PHPCS style one (Phase 1
#                 keeps the diff minimal: phpcbf only touches changed lines)
#   rector        a Rector finding (its pass applies it)
#   <recipe lane> the first recipe of config/recipes.json (plus the project
#                 overlay <root>/.drupilot/recipes.json, whose ids replace
#                 the plugin's) that matches the finding — by rule, then
#                 symbol, then message, then id — and whose applies_when
#                 holds (file, severity, core_min against the declared floor
#                 F: a recipe never applies above F). A codemod that does not
#                 apply, that already gave no change on this finding, or that
#                 was applied on an earlier extraction and left the finding
#                 there (the actions log of scripts/ai/apply-recipes.sh),
#                 falls to ai-templated with its template. A codemod applied
#                 on these very findings (same findings_hash) makes its item
#                 `applied` until the re-extraction.
#   ai-free       an analysis error or deprecation no recipe matches
#   human         a catalog finding no recipe matches
#   test-adapt    an ai-templated or ai-free finding in a file under tests/
#
# Idempotent: the same findings.json, recipes, floor and actions give the same
# worklist.json outside meta (DET-2).
#
# Usage:
#   classify.sh (--subject DIR | --findings FILE) [--recipes FILE]
#               [--overlay FILE] [--core-floor X.Y] [--actions FILE]
#               [--out FILE] [--json] [-h|--help]
#     --subject DIR     the module/theme: findings.json, actions.jsonl and
#                       worklist.json in its hidden state dir; the floor from
#                       its upgrade plan (range.floor); the overlay from its
#                       Drupal root
#     --findings FILE   classify this findings.json (a golden's); with no
#                       --subject, nothing is written unless --out is given
#     --recipes FILE    default config/recipes.json
#     --overlay FILE    a project overlay (same shape); default
#                       <root>/.drupilot/recipes.json when it exists
#     --core-floor X.Y  the declared core floor F (default: the plan's)
#     --actions FILE    the actions log (default <state>/actions.jsonl)
#     --out FILE        where to write worklist.json
#     --json            print worklist.json on STDOUT
#
# Exit codes: 0 written (or printed) · 1 usage error, no findings.json, or a
# recipes file that is not a recipe catalog · 2 jq or a sha256 tool missing.
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""; FINDINGS=""; RECIPES=""; OVERLAY=""; FLOOR=""; ACTIONS=""; OUT=""; AS_JSON=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --findings) FINDINGS="${2:-}"; shift 2 || die "--findings needs a value" 1;;
    --recipes) RECIPES="${2:-}"; shift 2 || die "--recipes needs a value" 1;;
    --overlay) OVERLAY="${2:-}"; shift 2 || die "--overlay needs a value" 1;;
    --core-floor) FLOOR="${2:-}"; shift 2 || die "--core-floor needs a value" 1;;
    --actions) ACTIONS="${2:-}"; shift 2 || die "--actions needs a value" 1;;
    --out) OUT="${2:-}"; shift 2 || die "--out needs a value" 1;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ -n "$SUBJECT" || -n "$FINDINGS" ]] || die "Pass --subject DIR or --findings FILE (see --help)." 1
[[ -z "$FLOOR" || "$FLOOR" =~ ^[0-9]+\.[0-9]+$ ]] || die "--core-floor must be MAJOR.MINOR." 1
have_cmd jq || die "jq is required (run /drupilot-doctor)." 2
[[ -n "$(printf 'x' | sha256_hex)" ]] || die "A sha256 tool (sha256sum or shasum) is required." 2

ROOT=""
if [[ -n "$SUBJECT" ]]; then
  [[ -d "$SUBJECT" ]] || die "Subject '$SUBJECT' is not a directory." 1
  SUBJECT="$(cd "$SUBJECT" && pwd)"
  ROOT="$(subject_project_root "$SUBJECT" 2> /dev/null || true)"
  [[ -n "$FINDINGS" ]] || FINDINGS="$(project_state_dir "$SUBJECT")/findings.json"
  [[ -n "$ACTIONS" ]] || ACTIONS="$(project_state_dir "$SUBJECT")/actions.jsonl"
  [[ -n "$OUT" ]] || OUT="$(worklist_file "$SUBJECT")"
  [[ -n "$FLOOR" ]] || FLOOR="$(plan_get .range.floor "${ROOT:-$SUBJECT}" 2> /dev/null || true)"
  if [[ -z "$OVERLAY" && -n "$ROOT" && -f "$ROOT/.drupilot/recipes.json" ]]; then OVERLAY="$ROOT/.drupilot/recipes.json"; fi
fi
[[ -f "$FINDINGS" ]] || die "No findings.json at $FINDINGS (run scripts/ai/normalize-findings.sh first)." 1
jq -e '.schema == 1 and (.findings | type) == "array"' "$FINDINGS" > /dev/null 2>&1 || die "$FINDINGS is not a findings.json (schema 1)." 1
[[ -n "$RECIPES" ]] || RECIPES="$(plugin_root)/config/recipes.json"
for r in "$RECIPES" ${OVERLAY:+"$OVERLAY"}; do
  jq -e '(.recipes | type) == "array" and all(.recipes[]; (.id | type) == "string" and (.lane | type) == "string" and (.matches | type) == "object")' "$r" > /dev/null 2>&1 \
    || die "$r is not a recipe catalog (a recipes array of {id, lane, matches, ...})." 1
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-classify.XXXXXX")"
trap 'rm -rf "$TMP" 2> /dev/null || true' EXIT
# The recipes in effect: the overlay's ids replace the plugin's.
if [[ -n "$OVERLAY" ]]; then
  jq -s '{recipes: ((.[0].recipes | map({key: .id, value: .}) | from_entries) + (.[1].recipes | map({key: .id, value: .}) | from_entries)
          | to_entries | map(.value) | sort_by(.id))}' "$RECIPES" "$OVERLAY" > "$TMP/recipes.json"
else
  jq '{recipes: (.recipes | sort_by(.id))}' "$RECIPES" > "$TMP/recipes.json"
fi
# What apply-recipes.sh already did per (finding, recipe, version): the last
# recipe-apply action, with the findings_hash it was applied on.
FHASH="$(jq -r '.meta.findings_hash // empty' "$FINDINGS")"
if [[ -n "$ACTIONS" && -f "$ACTIONS" ]]; then
  jq -c -s '[.[] | select(.kind == "recipe-apply")] | map({key: "\(.finding_id)\u001f\(.recipe)\u001f\(.version)", value: {status, findings_hash}})
            | from_entries' "$ACTIONS" > "$TMP/done.json" 2> /dev/null || printf '{}\n' > "$TMP/done.json"
else
  printf '{}\n' > "$TMP/done.json"
fi
ERA=""
if [[ -n "$SUBJECT" ]]; then ERA="$(plan_get .source.major "${ROOT:-$SUBJECT}" 2> /dev/null || true)"; fi

# Every finding with its lane, recipe and reason; then the items.
jq -c --slurpfile rc "$TMP/recipes.json" --slurpfile dn "$TMP/done.json" --arg floor "$FLOOR" --arg era "$ERA" --arg fh "$FHASH" '
  ["rector", "rector-custom", "codemod", "ai-templated", "ai-free", "test-adapt", "human", "deferred"] as $order
  | $rc[0].recipes as $recipes | $dn[0] as $done
  | (if $floor == "" then null else $floor end) as $F
  | def vnum: split(".") | map(tonumber? // 0);
    def applies($f):
      (.applies_when // {}) as $w
      | ($w.file_ere == null or ($w.file_ere as $re | $f.file | test($re)))
        and ($w.severity == null or ($w.severity | index($f.severity)) != null)
        and ($w.core_min == null or ($F != null and ($F | vnum) >= ($w.core_min | vnum)));
    def rank($f):
      if .matches.rule != null and .matches.rule == $f.rule then 0
      elif $f.symbol != null and ((.matches.symbols // []) | index($f.symbol)) != null then 1
      elif .matches.message_ere != null and (.matches.message_ere as $re | $f.message | test($re; "i")) then 2
      else 9 end;
    # A codemod that gave no change on this finding, or that was applied on an
    # earlier extraction and the finding is still there, is not tried again.
    def action($f): $done["\($f.id)\u001f\(.id)\u001f\(.version)"];
    def failed($f): action($f) as $a
      | $a != null and (($a.status | IN("no-match", "not-applicable", "rejected"))
                        or ($a.status == "applied" and $a.findings_hash != $fh));
    def applied($f): action($f) as $a | $a != null and $a.status == "applied" and $a.findings_hash == $fh;
    def lane_of:
      . as $f
      | if $f.scope == "next-major" then {lane: "deferred", recipe: null, reason: "next-major"}
        elif $f.tool == "rector" then {lane: "rector", recipe: null, reason: null}
        elif $f.severity == "info" then {lane: "deferred", recipe: null, reason: "info"}
        elif $f.class == "style" then {lane: "deferred", recipe: null, reason: "style"}
        else
          ([$recipes[] | {r: ., k: rank($f)} | select(.k < 9)] | sort_by([.k, .r.id]) | map(.r)) as $cands
          | [$cands[] | select(applies($f) and (failed($f) | not))] as $ok
          | if ($ok | length) > 0 then {lane: $ok[0].lane, recipe: $ok[0].id, reason: null, applied: ($ok[0] | applied($f))}
            elif ($cands | length) > 0 then
              $cands[0] as $c
              | {lane: (if $c.kind == "codemod" then "ai-templated" else $c.lane end), recipe: $c.id,
                 reason: (if ($c | failed($f)) then (if ($c | action($f)).status == "applied" then "the codemod did not clear the finding" else "the codemod gave no change" end)
                          else "the recipe'"'"'s conditions do not hold" end)}
            elif $f.tool == "catalog" then {lane: "human", recipe: null, reason: "no recipe"}
            else {lane: "ai-free", recipe: null, reason: null} end
        end
      | if (.lane == "ai-templated" or .lane == "ai-free") and ($f.file | startswith("tests/")) then .lane = "test-adapt" else . end;
    ($recipes | map({key: .id, value: .}) | from_entries) as $byid
  | [.findings[] | . + {c: lane_of}]
  | group_by([.file, .anchor, .c.lane])
  | map(. as $g | $g[0] as $h
      | ([$g[] | .c.recipe | select(. != null)] | unique) as $rs
      | ([$g[] | .c.recipe | select(. != null)] | .[0]) as $first
      | ($byid[$first // ""].template // {}) as $t
      | {lane: $h.c.lane, file: $h.file, anchor: $h.anchor,
         finding_ids: ([$g[].id] | sort),
         recipes: $rs,
         recipe_of: ([$g[] | {key: .id, value: .c.recipe}] | from_entries),
         templates: ([$rs[] | {key: ., value: $byid[.].template}] | from_entries),
         allowed_files: [$h.file],
         era: (if $era == "" then null else "d" + $era end),
         category: ($t.category // $h.class),
         explanation: ($t.why // $h.message),
         change_record_search_url: ($t.change_record_search_url // null),
         blocking: ($h.c.lane != "deferred" and any($g[]; .severity == "error")),
         reason: ([$g[] | .c.reason | select(. != null)] | unique | if length == 0 then null else join("; ") end),
         status: (if $h.c.lane == "deferred" then "deferred" elif all($g[]; .c.applied == true) then "applied" else "open" end)})
  | sort_by([(.lane as $l | $order | index($l)), .file, .anchor])' "$FINDINGS" > "$TMP/items.json"

# Item ids: "W-" + 12 hex of sha256(file 0x1f anchor 0x1f lane), one hasher run.
SEP="$(printf '\037')"
jq -r --arg sep "$SEP" '.[] | "\(.file)\($sep)\(.anchor)\($sep)\(.lane)"' "$TMP/items.json" > "$TMP/keys.txt"
sha256_lines "$TMP/keys.txt" "$TMP/h" \
  | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: ((.[0] | tonumber) - 1 | tostring), value: ("W-" + .[1][0:12])}) | from_entries' \
  > "$TMP/ids.json"

DOC="$TMP/worklist.json"
jq -c --slurpfile ids "$TMP/ids.json" --slurpfile f "$FINDINGS" --arg floor "$FLOOR" '
  ["rector", "rector-custom", "codemod", "ai-templated", "ai-free", "test-adapt", "human", "deferred"] as $order
  | to_entries | map({id: $ids[0]["\(.key)"]} + .value) as $items
  | {schema: 1, stage: $f[0].stage, subject: $f[0].subject, target: $f[0].target,
     floor: (if $floor == "" then null else $floor end),
     counts: {items: ($items | length),
              open: ([$items[] | select(.status == "open")] | length),
              blocking: ([$items[] | select(.blocking)] | length),
              by_lane: ($items | group_by(.lane) | map({key: .[0].lane, value: length}) | from_entries)},
     items: $items}' "$TMP/items.json" | canon_json > "$DOC"
jq -e '.schema == 1' "$DOC" > /dev/null 2>&1 || die "Could not build worklist.json from $FINDINGS." 1

# meta: the inputs' hashes and the time (not hashed: DET-2).
jq --arg fh "$(jq -r '.meta.findings_hash // empty' "$FINDINGS")" --arg rh "$(canon_json_hashable < "$TMP/recipes.json" | json_hash)" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg wh "$(canon_json_hashable < "$DOC" | json_hash)" \
  '. + {meta: {worklist_hash: $wh, findings_hash: (if $fh == "" then null else $fh end), recipes_hash: $rh, generated_at: $at}}' "$DOC" \
  | canon_json > "$DOC.meta"

if [[ -n "$OUT" ]]; then
  if [[ -n "$SUBJECT" && "$OUT" == "$(worklist_file "$SUBJECT")" ]]; then
    worklist_set "$SUBJECT" < "$DOC.meta" || die "Could not write $OUT." 1
  else
    mkdir -p "$(dirname "$OUT")" 2> /dev/null || true
    cp "$DOC.meta" "$OUT.tmp.$$" && mv -f "$OUT.tmp.$$" "$OUT" || die "Could not write $OUT." 1
  fi
  log_ok "worklist.json: $(jq -r '.counts.items' "$DOC") item(s), $(jq -r '.counts.open' "$DOC") open ($OUT)."
fi
[[ "$AS_JSON" == "1" ]] && cat "$DOC.meta"
exit 0
