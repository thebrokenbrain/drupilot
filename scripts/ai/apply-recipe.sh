#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/ai/apply-recipe.sh
# Apply one codemod recipe of config/recipes.json (AR-11, ADR 0023) to one
# finding: the primitive scripts/ai/apply-recipes.sh runs per worklist item,
# and the recipe fixtures (tests/fixtures/recipes/<id>/) run on their own. The
# Docker-free engines:
#   ere-replace  a `sed -E` substitution (params.search -> params.replace,
#                back-references \1..\9) on the finding's line (scope line) or
#                on every line of the file (scope file)
#   yaml-edit    op replace-on-line: on the finding's line, the fixed string
#                `from` becomes `to`; each is a capture (the first group of an
#                ERE on the finding's message) or, for `to`, a transform of
#                one (class-from-file: Drupal\<extension>\ plus the class's
#                path under src/, for a class name whose case differs)
#   info-yml     scripts/analysis/set-core-requirement.sh on the subject with
#                params.requirement (plan:<path> reads the upgrade plan,
#                e.g. plan:range.constraint; --param overrides it)
# The change is written only when it is exact and every postcondition holds on
# the result (absent-ere / absent-fixed / present-fixed on the line or file;
# rescan is left to apply-recipes.sh's re-extraction). A replacement that does
# not apply is `no-match`, and nothing changes: the item falls to its next
# lane. applies_when is honored: file_ere, severity (with --severity) and
# core_min (with --core-floor, else the plan's range.floor).
#
# Usage:
#   apply-recipe.sh --recipe ID --subject DIR --file REL [--line N]
#                   [--message TEXT] [--severity S] [--core-floor X.Y]
#                   [--param KEY=VALUE]... [--recipes FILE] [--dry-run]
#                   [--json] [-h|--help]
#     --recipe ID      a recipe id of config/recipes.json (or --recipes FILE)
#     --subject DIR    the module/theme; --file is relative to it
#     --line N         the finding's line (scope line, yaml-edit)
#     --message TEXT   the finding's message (yaml-edit captures)
#     --severity S     the finding's severity (applies_when.severity)
#     --core-floor X.Y the declared core floor (applies_when.core_min)
#     --param K=V      override params.K (a fixture's requirement, ...)
#     --dry-run        report would-apply; write nothing
#     --json           {recipe, version, engine, file, line, status, changed,
#                       input_hash, output_hash, from, to, reason} on STDOUT
#                       (status: applied | would-apply | no-match |
#                       not-applicable | rejected)
#
# Exit codes: 0 a status was reached (applied, would-apply, no-match or
# not-applicable) · 1 usage error, an unknown recipe or an engine without an
# executor (attributes, php-script, rector-rule: no v1 recipe uses them) · 3
# rejected: the change was computed but a postcondition fails on it, so
# nothing is written.
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

RECIPE=""; SUBJECT=""; FILE=""; LINE=""; MESSAGE=""; SEVERITY=""; FLOOR=""; RECIPES=""; DRY=0; AS_JSON=0
PARAMS='{}'
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --recipe) RECIPE="${2:-}"; shift 2 || die "--recipe needs a value" 1;;
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --file) FILE="${2:-}"; shift 2 || die "--file needs a value" 1;;
    --line) LINE="${2:-}"; shift 2 || die "--line needs a value" 1;;
    --message) MESSAGE="${2:-}"; shift 2 || die "--message needs a value" 1;;
    --severity) SEVERITY="${2:-}"; shift 2 || die "--severity needs a value" 1;;
    --core-floor) FLOOR="${2:-}"; shift 2 || die "--core-floor needs a value" 1;;
    --recipes) RECIPES="${2:-}"; shift 2 || die "--recipes needs a value" 1;;
    --param)
      [[ "${2:-}" == *=* ]] || die "--param needs KEY=VALUE" 1
      PARAMS="$(jq -c --arg k "${2%%=*}" --arg v "${2#*=}" '. + {($k): $v}' <<< "$PARAMS")"; shift 2;;
    --dry-run) DRY=1; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ -n "$RECIPE" && -n "$SUBJECT" && -n "$FILE" ]] || die "Pass --recipe, --subject and --file (see --help)." 1
[[ -z "$LINE" || "$LINE" =~ ^[1-9][0-9]*$ ]] || die "--line must be a positive integer." 1
[[ -d "$SUBJECT" ]] || die "Subject '$SUBJECT' is not a directory." 1
have_cmd jq || die "jq is required (run /drupilot-doctor)." 1
SUBJECT="$(cd "$SUBJECT" && pwd)"
case "$FILE" in /*|../*|*/../*) die "--file must be relative to the subject, inside it." 1;; esac
F="$SUBJECT/$FILE"
[[ -f "$F" ]] || die "No file $FILE in the subject." 1
[[ -n "$RECIPES" ]] || RECIPES="$(plugin_root)/config/recipes.json"
R="$(jq -c --arg id "$RECIPE" '.recipes[] | select(.id == $id)' "$RECIPES" 2> /dev/null || true)"
[[ -n "$R" ]] || die "No recipe '$RECIPE' in $RECIPES." 1
rq() { jq -r "$1 // empty" <<< "$R"; }
ENGINE="$(rq .engine)"; VERSION="$(rq .version)"
P="$(jq -c --argjson o "$PARAMS" '(.params // {}) + $o' <<< "$R")"
pq() { jq -r "$1 // empty" <<< "$P"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-recipe.XXXXXX")"
trap 'rm -rf "$TMP" 2> /dev/null || true' EXIT
IN_HASH="$(file_hash "$F")"
STATUS=""; REASON=""; FROM=""; TO=""; OUT_HASH="$IN_HASH"; CHANGED=false
finish() {
  if [[ "$AS_JSON" == "1" ]]; then
    jq -n --arg r "$RECIPE" --arg v "$VERSION" --arg e "$ENGINE" --arg f "$FILE" --arg l "$LINE" --arg s "$STATUS" \
      --argjson c "$CHANGED" --arg ih "$IN_HASH" --arg oh "$OUT_HASH" --arg fr "$FROM" --arg to "$TO" --arg why "$REASON" \
      '{recipe: $r, version: $v, engine: $e, file: $f, line: (if $l == "" then null else ($l | tonumber) end),
        status: $s, changed: $c, input_hash: $ih, output_hash: $oh,
        from: (if $fr == "" then null else $fr end), to: (if $to == "" then null else $to end),
        reason: (if $why == "" then null else $why end)}'
  fi
  case "$STATUS" in
    applied) log_ok "apply-recipe: $RECIPE applied to $FILE${LINE:+:$LINE}.";;
    would-apply) log_info "apply-recipe: $RECIPE would change $FILE${LINE:+:$LINE} (dry-run).";;
    *) log_info "apply-recipe: $RECIPE on $FILE${LINE:+:$LINE}: $STATUS${REASON:+ ($REASON)}.";;
  esac
  exit "${1:-0}"
}

# applies_when.
FERE="$(rq .applies_when.file_ere)"
if [[ -n "$FERE" ]] && ! printf '%s\n' "$FILE" | grep_q -E -- "$FERE"; then
  STATUS="not-applicable"; REASON="the file does not match $FERE"; finish 0
fi
if [[ -n "$SEVERITY" ]] && jq -e '(.applies_when.severity // []) | length > 0' <<< "$R" > /dev/null 2>&1 \
   && ! jq -e --arg s "$SEVERITY" '.applies_when.severity | index($s)' <<< "$R" > /dev/null 2>&1; then
  STATUS="not-applicable"; REASON="severity $SEVERITY is not one it fixes"; finish 0
fi
CMIN="$(rq .applies_when.core_min)"
if [[ -n "$CMIN" ]]; then
  ROOT="$(subject_project_root "$SUBJECT" 2> /dev/null || true)"
  [[ -n "$FLOOR" ]] || FLOOR="$(plan_get .range.floor "${ROOT:-$SUBJECT}" 2> /dev/null || true)"
  if [[ -z "$FLOOR" ]]; then STATUS="not-applicable"; REASON="it needs core $CMIN and the core floor is unknown"; finish 0; fi
  if ! version_ge "$FLOOR" "$CMIN"; then STATUS="not-applicable"; REASON="it needs core $CMIN, above the floor $FLOOR"; finish 0; fi
fi

# line N of a file, without its newline.
line_of() { sed -n "${2}p" "$1"; }
# post FILE -> 0 when every line/file postcondition holds on FILE.
post() {
  local f="$1" n i t w x text
  n="$(jq '(.postconditions // []) | length' <<< "$R")"
  i=0
  while [[ "$i" -lt "$n" ]]; do
    t="$(jq -r --argjson i "$i" '.postconditions[$i].type' <<< "$R")"
    w="$(jq -r --argjson i "$i" '.postconditions[$i].where // "line"' <<< "$R")"
    x="$(jq -r --argjson i "$i" '.postconditions[$i].ere // .postconditions[$i].text // ""' <<< "$R")"
    x="${x//\{from\}/$FROM}"; x="${x//\{to\}/$TO}"
    if [[ "$w" == "line" && -n "$LINE" ]]; then text="$(line_of "$f" "$LINE")"; else text="$(cat "$f")"; fi
    case "$t" in
      absent-ere) if printf '%s\n' "$text" | grep_q -E -- "$x"; then REASON="postcondition absent-ere fails"; return 1; fi;;
      absent-fixed) if printf '%s\n' "$text" | grep_q -F -- "$x"; then REASON="postcondition absent-fixed fails"; return 1; fi;;
      present-fixed) if ! printf '%s\n' "$text" | grep_q -F -- "$x"; then REASON="postcondition present-fixed fails"; return 1; fi;;
      *) ;;
    esac
    i=$((i + 1))
  done
  return 0
}

NEW="$TMP/new"
case "$ENGINE" in
  ere-replace)
    SEARCH="$(pq .search)"; REPL="$(jq -r '.replace // ""' <<< "$P")"; SCOPE="$(pq .scope)"; SCOPE="${SCOPE:-line}"
    D="$(printf '\001')"
    if [[ "$SCOPE" == "line" ]]; then
      [[ -n "$LINE" ]] || die "Recipe $RECIPE works on the finding's line: pass --line." 1
      if ! line_of "$F" "$LINE" | grep_q -E -- "$SEARCH"; then STATUS="no-match"; REASON="line $LINE does not match the search"; finish 0; fi
      sed -E "${LINE}s${D}${SEARCH}${D}${REPL}${D}" "$F" > "$NEW" || die "sed failed on $FILE." 1
    else
      if ! grep_q -E -- "$SEARCH" "$F"; then STATUS="no-match"; REASON="the file does not match the search"; finish 0; fi
      sed -E "s${D}${SEARCH}${D}${REPL}${D}g" "$F" > "$NEW" || die "sed failed on $FILE." 1
    fi
    ;;
  yaml-edit)
    [[ "$(pq .op)" == "replace-on-line" ]] || die "Recipe $RECIPE: unknown yaml-edit op '$(pq .op)'." 1
    [[ -n "$LINE" ]] || die "Recipe $RECIPE works on the finding's line: pass --line." 1
    cap() { jq -n -r --arg m "$MESSAGE" --arg re "$1" '[$m | match($re).captures[0].string] | .[0] // empty' 2> /dev/null || true; }
    FROM="$(pq .from)"; [[ "$FROM" == "{"* ]] && FROM="$(cap "$(jq -r '.from.capture // empty' <<< "$P")")"
    TO="$(jq -r '.to | if type == "string" then . else empty end' <<< "$P")"
    if [[ -z "$TO" ]]; then
      TV="$(cap "$(jq -r '.to.capture // empty' <<< "$P")")"
      case "$(jq -r '.to.transform // empty' <<< "$P")" in
        class-from-file)
          # Drupal\<extension>\ + the path under the last src/, .php dropped.
          if [[ -n "$FROM" && "$TV" == *src/*.php ]]; then
            _rel="${TV##*src/}"; _rel="${_rel%.php}"
            _ext="$(printf '%s' "$FROM" | awk -F'\\' '{ print $1 "\\" $2 }')"
            TO="$_ext\\$(printf '%s' "$_rel" | tr '/' '\\')"
          fi;;
        "") TO="$TV";;
        *) die "Recipe $RECIPE: unknown transform." 1;;
      esac
    fi
    if [[ -z "$FROM" || -z "$TO" ]]; then STATUS="no-match"; REASON="the message gives no from/to"; finish 0; fi
    # class-from-file only fixes a letter case.
    if [[ "$(jq -r '.to.transform // empty' <<< "$P")" == "class-from-file" ]] \
       && [[ "$FROM" == "$TO" || "$(lc "$FROM")" != "$(lc "$TO")" ]]; then
      STATUS="no-match"; REASON="$TO is not a case-only change of $FROM"; finish 0
    fi
    if ! line_of "$F" "$LINE" | grep_q -F -- "$FROM"; then STATUS="no-match"; REASON="line $LINE does not contain $FROM"; finish 0; fi
    # From the environment: awk -v would read the backslashes as escapes.
    RA="$FROM" RB="$TO" awk -v n="$LINE" 'NR == n { a = ENVIRON["RA"]; i = index($0, a); if (i > 0) $0 = substr($0, 1, i - 1) ENVIRON["RB"] substr($0, i + length(a)) } { print }' "$F" > "$NEW" \
      || die "awk failed on $FILE." 1
    ;;
  info-yml)
    REQ="$(pq .requirement)"
    if [[ "$REQ" == plan:* ]]; then
      ROOT="$(subject_project_root "$SUBJECT" 2> /dev/null || true)"
      REQ="$(plan_get ".${REQ#plan:}" "${ROOT:-$SUBJECT}" 2> /dev/null || true)"
    fi
    [[ -n "$REQ" ]] || die "Recipe $RECIPE needs the core requirement: no upgrade plan gives it (pass --param requirement=...)." 1
    # set-core-requirement.sh works on the whole subject; the result is read
    # from a copy, so the finding's file is written below like the others.
    cp -R "$SUBJECT" "$TMP/subject"
    bash "$(plugin_root)/scripts/analysis/set-core-requirement.sh" --subject "$TMP/subject" --requirement "$REQ" > /dev/null 2>&1 < /dev/null \
      || die "set-core-requirement.sh failed on the subject." 1
    cp "$TMP/subject/$FILE" "$NEW"
    TO="$REQ"
    ;;
  attributes|php-script|rector-rule) die "Engine $ENGINE has no executor yet (no v1 recipe uses it; ADR 0023)." 1;;
  *) die "Recipe $RECIPE has no codemod engine ($ENGINE): it is applied by its lane, not here." 1;;
esac

if cmp -s "$NEW" "$F"; then STATUS="no-match"; REASON="the replacement changes nothing"; finish 0; fi
post "$NEW" || { STATUS="rejected"; log_warn "apply-recipe: $RECIPE on $FILE: $REASON; nothing is written."; finish 3; }
OUT_HASH="$(file_hash "$NEW")"; CHANGED=true
if [[ "$DRY" == "1" ]]; then STATUS="would-apply"; finish 0; fi
cat "$NEW" > "$F" || die "Could not write $FILE." 1
STATUS="applied"
finish 0
