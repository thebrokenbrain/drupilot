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
#   info-yml     scripts/analysis/set-core-requirement.sh, on a copy of the
#                subject's physical tree, with params.requirement
#                (plan:<path> reads the subject's own frozen upgrade plan,
#                e.g. plan:range.constraint; --param overrides it); only the
#                finding's file is written, and a requirement whose floor is
#                above the main info.yml's (the declared floor) is
#                not-applicable
# params.captures ({name: ERE}, matched on the finding's line before the
# change) give {name} to the postconditions, e.g. "the parameter made optional
# is not used elsewhere in the file". The change is written only when it is
# exact and every postcondition holds on the result (absent-ere / absent-fixed
# / present-fixed on the line, the file, the file's code lines but the
# finding's (file-except-line), or the body of the function the finding's line
# declares (function-body); comment lines are not code there. An unresolved
# {placeholder} or an empty capture fails the postcondition. rescan is
# left to apply-recipes.sh's re-extraction). A file without a final newline
# keeps none. A replacement that does not apply is `no-match`, and nothing
# changes: the item falls to its next lane. applies_when is honored: file_ere,
# severity (with --severity) and core_min (with --core-floor, else the
# subject's own plan's range.floor).
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
  [[ -n "$FLOOR" ]] || FLOOR="$(plan_get_own "$SUBJECT" .range.floor)"
  if [[ -z "$FLOOR" ]]; then STATUS="not-applicable"; REASON="it needs core $CMIN and the core floor is unknown"; finish 0; fi
  if ! version_ge "$FLOOR" "$CMIN"; then STATUS="not-applicable"; REASON="it needs core $CMIN, above the floor $FLOOR"; finish 0; fi
fi

# line N of a file, without its newline.
line_of() { sed -n "${2}p" "$1"; }
# params.captures: {name: ERE} matched on the finding's line before the
# change; the first group of each is {name} in the postconditions.
CAPS='{}'
if [[ -n "$LINE" ]] && jq -e '(.captures // {}) | length > 0' <<< "$P" > /dev/null 2>&1; then
  CAPS="$(jq -c --arg l "$(line_of "$F" "$LINE")" '(.captures // {}) | map_values(. as $re | [$l | match($re).captures[0].string] | .[0] // "")' <<< "$P" 2> /dev/null || printf '{}')"
fi
# post FILE -> 0 when every line/file postcondition holds on FILE.
post() {
  local f="$1" n i t w x text k v
  n="$(jq '(.postconditions // []) | length' <<< "$R")"
  i=0
  while [[ "$i" -lt "$n" ]]; do
    t="$(jq -r --argjson i "$i" '.postconditions[$i].type' <<< "$R")"
    w="$(jq -r --argjson i "$i" '.postconditions[$i].where // "line"' <<< "$R")"
    x="$(jq -r --argjson i "$i" '.postconditions[$i].ere // .postconditions[$i].text // ""' <<< "$R")"
    x="${x//\{from\}/$FROM}"; x="${x//\{to\}/$TO}"
    for k in $(jq -r 'keys[]' <<< "$CAPS"); do
      v="$(jq -r --arg k "$k" '.[$k]' <<< "$CAPS")"
      # An empty capture would make the check vacuous: fail closed.
      if [[ -z "$v" && "$x" == *"{$k}"* ]]; then REASON="the capture {$k} matched nothing on line $LINE"; return 1; fi
      x="${x//\{$k\}/$v}"
    done
    # A placeholder left unresolved (a typo, an undefined capture), or an ERE
    # that does not compile (grep exits 2): fail closed.
    if printf '%s\n' "$x" | grep_q -E '\{[A-Za-z_][A-Za-z0-9_-]*\}'; then REASON="a postcondition placeholder is unresolved ($x)"; return 1; fi
    if [[ "$t" == "absent-ere" ]]; then
      _erc=0; grep -E -- "$x" <<< "x" > /dev/null 2>&1 || _erc=$?
      if [[ "$_erc" -ge 2 ]]; then REASON="a postcondition ERE does not compile ($x)"; return 1; fi
    fi
    case "$w" in
      line) if [[ -n "$LINE" ]]; then text="$(line_of "$f" "$LINE")"; else text="$(cat "$f")"; fi;;
      # The file's code lines but the finding's: comment lines (a docblock's
      # @param names the parameter too) are not code.
      file-except-line) text="$(awk -v n="${LINE:-0}" 'NR != n && $0 !~ /^[ \t]*(\*|\/\*|\/\/|#)/' "$f")";;
      # The function whose signature is the finding's line, over-approximated
      # on purpose (a "}" inside a string or a heredoc never ends it early):
      # what follows the "{" on that line, then every code line up to the
      # next function declared at the signature's indentation, or the end of
      # the file. Comments are left out: // and # lines, and /* ... */
      # blocks (a line starting with "*" outside one is code). A heredoc or
      # nowdoc body is kept whole and never ends the function.
      function-body) text="$(awk -v n="${LINE:-0}" -v q="'" '
          { sub(/\r$/, "") }
          NR == n { ind = $0; sub(/[^ \t].*$/, "", ind); i = index($0, "{"); if (i > 0) print substr($0, i + 1); on = 1; next }
          !on { next }
          hd != "" { print; t = $0; sub(/^[ \t]*/, "", t); if (index(t, hd) == 1 && substr(t, length(hd) + 1) !~ /^[A-Za-z0-9_]/) hd = ""; next }
          inc { j = index($0, "*/"); if (j > 0) { inc = 0; print substr($0, j + 2) }; next }
          (ind == "" || index($0, ind) == 1) && substr($0, length(ind) + 1) ~ /^((public|protected|private|static|final|abstract)[ \t]+)*function[ \t]/ { exit }
          $0 ~ /^[ \t]*(\/\/|#)/ { next }
          $0 ~ /^[ \t]*\/\*/ { r = $0; sub(/^[ \t]*\/\*/, "", r); j = index(r, "*/"); if (j > 0) print substr(r, j + 2); else inc = 1; next }
          { print
            if (match($0, "<<<[ \t]*[\"" q "]?[A-Za-z_][A-Za-z0-9_]*")) { hd = substr($0, RSTART + 3, RLENGTH - 3); gsub("[ \t\"" q "]", "", hd) } }' "$f")";;
      *) text="$(cat "$f")";;
    esac
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
    if [[ "$REQ" == plan:* ]]; then REQ="$(plan_get_own "$SUBJECT" ".${REQ#plan:}")"; fi
    [[ -n "$REQ" ]] || die "Recipe $RECIPE needs the core requirement: no upgrade plan of this module gives it (pass --param requirement=...)." 1
    # Never above the declared floor: the main info.yml's requirement.
    MAIN_REQ="$(sed -n 's/^core_version_requirement[[:space:]]*:[[:space:]]*//p' "$SUBJECT/$(subject_machine_name "$SUBJECT" 2> /dev/null || basename "$SUBJECT").info.yml" 2> /dev/null | sed -n '1p' | tr -d "'\"")"
    if [[ -n "$MAIN_REQ" ]]; then
      _rf="$(core_floor_from_requirement "$REQ" 2> /dev/null || true)"; _mf="$(core_floor_from_requirement "$MAIN_REQ" 2> /dev/null || true)"
      if [[ -n "$_rf" && -n "$_mf" ]] && ! version_ge "$_mf" "$_rf"; then
        STATUS="not-applicable"; REASON="$REQ would raise the declared floor $_mf (core_version_requirement: $MAIN_REQ)"; finish 0
      fi
    fi
    # set-core-requirement.sh works on the whole subject; it runs on a copy of
    # the physical tree (a symlinked subject would be edited through the link),
    # and only the finding's file is written below, like the other engines.
    mkdir -p "$TMP/subject" && cp -R "$(cd "$SUBJECT" && pwd -P)/." "$TMP/subject/" || die "Could not copy the subject." 1
    bash "$(plugin_root)/scripts/analysis/set-core-requirement.sh" --subject "$TMP/subject" --requirement "$REQ" > /dev/null 2>&1 < /dev/null \
      || die "set-core-requirement.sh failed on the subject." 1
    cp "$TMP/subject/$FILE" "$NEW"
    TO="$REQ"
    ;;
  attributes|php-script|rector-rule) die "Engine $ENGINE has no executor yet (no v1 recipe uses it; ADR 0023)." 1;;
  *) die "Recipe $RECIPE has no codemod engine ($ENGINE): it is applied by its lane, not here." 1;;
esac

# A file without a final newline keeps none (awk always ends with one).
if [[ -s "$F" && -n "$(tail -c 1 "$F")" && -s "$NEW" && -z "$(tail -c 1 "$NEW")" ]]; then
  awk 'NR > 1 { print prev } { prev = $0 } END { if (NR > 0) printf "%s", prev }' "$NEW" > "$NEW.nl" && mv -f "$NEW.nl" "$NEW"
fi
if cmp -s "$NEW" "$F"; then STATUS="no-match"; REASON="the replacement changes nothing"; finish 0; fi
post "$NEW" || { STATUS="rejected"; log_warn "apply-recipe: $RECIPE on $FILE: $REASON; nothing is written."; finish 3; }
OUT_HASH="$(file_hash "$NEW")"; CHANGED=true
if [[ "$DRY" == "1" ]]; then STATUS="would-apply"; finish 0; fi
cat "$NEW" > "$F" || die "Could not write $FILE." 1
STATUS="applied"
finish 0
