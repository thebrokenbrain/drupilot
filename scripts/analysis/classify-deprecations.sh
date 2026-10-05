#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/classify-deprecations.sh
# Split the deprecations an analyzer reported into HARD and SOFT ones and say
# what the configured policy (DRUPILOT_SOFT_DEPRECATIONS) does with each, so the
# criterion is the same for every module and every layer of the flow.
#
#   hard    removed in a Drupal major <= the target major: the call breaks on
#           the target (e.g. user_roles(), removed in 11.0.0). Always fixed in
#           Phase 1 — Phase 1 is not done while one is left.
#   soft    removed in a LATER major: it still works on every core of the target
#           major (e.g. user_load_by_name(), deprecated in 11.4.0 and removed
#           from 13.0.0). Handled per policy:
#             report (default) list it in the reports, leave the code alone
#             defer            list it under "deferred to Phase 2"
#             fix              fix it in Phase 1 — directly when the replacement
#                              exists at the declared core floor, else through
#                              DeprecationHelper::backwardsCompatibleCall()
#                              (core 10.1+), else defer it with the reason
#           Phase 2 (--phase refactor) fixes soft items regardless of the policy
#           ("zero deprecations"), still respecting the core floor.
#   unknown a deprecation whose removal version cannot be read, or belongs to a
#           contrib project, or a symbol PHPStan cannot find that the catalog
#           does not date: treated as BLOCKING (conservative) until reviewed.
#
# Removal versions come from the analyzer message itself (phpstan-deprecation-
# rules echoes core's "in drupal:X and is removed from drupal:Y"). The
# `lifecycle` catalog in config/deprecations.json adds the replacement, the first
# core that has it, the effort, and the facts for a symbol that is already gone
# (PHPStan then only says "Function user_roles not found."). Effort is null
# unless the catalog records one — never invented.
#
# Usage:
#   classify-deprecations.sh [--file F | -] [--subject DIR] [--core-req STR]
#                            [--core-floor X.Y] [--target-major N]
#                            [--policy report|defer|fix] [--phase port|refactor]
#                            [--json]
#   --file F          Analyzer output: PHPStan native JSON (run-phpstan.sh
#                     --json) or plain text, best-effort: PHPStan's table (file
#                     and line kept), or runtime notices such as PHPUnit's
#                     "X() is deprecated in drupal:A and is removed from
#                     drupal:B" (no file/line). Default: STDIN ('-').
#   --subject DIR     Read core_version_requirement from DIR's info.yml.
#   --core-req STR    The declared core range (overrides --subject).
#   --core-floor X.Y  The lowest core kept (overrides the range's floor).
#   --target-major N  Drupal major the port targets (default: the highest major
#                     in DRUPILOT_DRUPAL_TARGET, '^11' -> 11).
#   --policy P        Override DRUPILOT_SOFT_DEPRECATIONS for this run.
#   --phase P         port (default) or refactor.
#   --json            Emit the classification JSON on STDOUT:
#                     {tool, policy, phase, target_major, core_requirement,
#                      core_floor, blocking, counts:{hard,soft,unknown,other},
#                      symbols:[{symbol, class, deprecated_in, removed_in,
#                        replacement, replacement_since, replacement_at_floor,
#                        effort, action, reason, occurrences}],
#                      hard:[..], soft:[..], unknown:[..]}
#                     Items carry {file, line, symbol, class, deprecated_in,
#                     removed_in, message, replacement, replacement_since,
#                     replacement_at_floor, effort, action, reason}.
#                     action: fix | fix-guarded | report | defer.
#   -h, --help        Show this help.
#
# Output: a human table (or JSON with --json) on STDOUT; logging on STDERR.
# Exit codes: 0 classified (whatever was found) · 1 usage/error. Read-only,
# ungated, no toolchain (bash + jq + awk).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

FILE="-"
SUBJECT=""
CORE_REQ=""
FLOOR_OPT=""
TARGET_MAJOR=""
POLICY_OPT=""
PHASE="port"
AS_JSON=0

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) FILE="${2:-}"; shift 2;;
    --file=*) FILE="${1#*=}"; shift;;
    -) FILE="-"; shift;;
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --core-req) CORE_REQ="${2:-}"; shift 2;;
    --core-req=*) CORE_REQ="${1#*=}"; shift;;
    --core-floor) FLOOR_OPT="${2:-}"; shift 2;;
    --core-floor=*) FLOOR_OPT="${1#*=}"; shift;;
    --target-major) TARGET_MAJOR="${2:-}"; shift 2;;
    --target-major=*) TARGET_MAJOR="${1#*=}"; shift;;
    --policy) POLICY_OPT="${2:-}"; shift 2;;
    --policy=*) POLICY_OPT="${1#*=}"; shift;;
    --phase) PHASE="${2:-}"; shift 2;;
    --phase=*) PHASE="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_err "Unknown argument: $1"; usage >&2; exit 1;;
  esac
done

have_cmd jq || die "jq is required for classify-deprecations.sh." 1
CATALOG="$(plugin_root)/config/deprecations.json"
[[ -r "$CATALOG" ]] || die "Missing $CATALOG." 1

case "$PHASE" in port|refactor) : ;; *) die "--phase must be port or refactor, got '$PHASE'." 1;; esac
if [[ -n "$FLOOR_OPT" ]] && ! printf '%s' "$FLOOR_OPT" | grep_q -E '^[0-9]+(\.[0-9]+)?$'; then
  die "--core-floor must be MAJOR.MINOR (e.g. 10.3), got '$FLOOR_OPT'." 1
fi
if [[ -n "$TARGET_MAJOR" ]] && ! printf '%s' "$TARGET_MAJOR" | grep_q -E '^[0-9]+$'; then
  die "--target-major must be a Drupal major number (e.g. 11), got '$TARGET_MAJOR'." 1
fi

# --- Policy: --policy > DRUPILOT_SOFT_DEPRECATIONS (validated) > report -------
if [[ -n "$POLICY_OPT" ]]; then
  case "$POLICY_OPT" in report|defer|fix) POLICY="$POLICY_OPT";;
    *) die "--policy must be report, defer or fix, got '$POLICY_OPT'." 1;; esac
else
  POLICY="$(config_enum DRUPILOT_SOFT_DEPRECATIONS report report defer fix 2>/dev/null || true)"
  if [[ -z "$POLICY" ]]; then
    log_warn "DRUPILOT_SOFT_DEPRECATIONS='$(config_get DRUPILOT_SOFT_DEPRECATIONS "")' is invalid (allowed: report defer fix); using 'report'."
    POLICY="report"
  fi
fi

# --- Target major: --target-major > highest major in DRUPILOT_DRUPAL_TARGET ----
if [[ -z "$TARGET_MAJOR" ]]; then
  TARGET_MAJOR="$(config_get DRUPILOT_DRUPAL_TARGET "^11" | tr -d "\"'" | tr '|' '\n' | awk '
    { n = split($0, parts, /[[:space:],]+/)
      for (i = 1; i <= n; i++) {
        p = parts[i]
        if (p == "" || p ~ /^(<|!=)/) continue
        sub(/^(\^|~|>=|>|==|=|v)+/, "", p)
        if (p !~ /^[0-9]+/) continue
        split(p, v, "."); if (v[1] + 0 > best) best = v[1] + 0
        break } }
    END { if (best > 0) print best }')"
  [[ -n "$TARGET_MAJOR" ]] || TARGET_MAJOR="11"
fi

# --- Core range / floor -----------------------------------------------------
if [[ -z "$CORE_REQ" && -n "$SUBJECT" ]]; then
  [[ -d "$SUBJECT" ]] || die "Subject directory not found: '$SUBJECT'." 1
  CORE_REQ="$(subject_core_requirement "$SUBJECT" 2>/dev/null || true)"
fi
CORE_REQ="$(printf '%s' "$CORE_REQ" | tr -d "\"'")"
if [[ -n "$FLOOR_OPT" ]]; then FLOOR="$FLOOR_OPT"; else FLOOR="$(core_floor_from_requirement "$CORE_REQ")"; fi

# --- Input ------------------------------------------------------------------
TMP="$(mktemp "${TMPDIR:-/tmp}/drupilot-classify.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
if [[ "$FILE" == "-" ]]; then
  [[ -t 0 ]] && die "No input: pass --file F, or pipe the analyzer output (e.g. run-phpstan.sh --json | classify-deprecations.sh)." 1
  cat > "$TMP" 2>/dev/null || true
else
  [[ -r "$FILE" ]] || die "Input file not found: $FILE" 1
  cat "$FILE" > "$TMP"
fi

# Normalize to a JSON array of {file, line, message, identifier}.
RAW='[]'
if [[ -s "$TMP" ]] && jq -e 'type == "object" and has("files")' "$TMP" >/dev/null 2>&1; then
  RAW="$(jq -c '[ (.files // {}) | to_entries[] | .key as $f
                  | (.value.messages // [])[]
                  | {file: $f, line: (.line // null), message: (.message // ""),
                     identifier: (.identifier // null)} ]' "$TMP")"
elif [[ -s "$TMP" ]]; then
  # Plain text (PHPStan table/raw output, upgrade_status, a pasted log): one
  # record per "deprecated <kind> <symbol>" or "Function X not found", with the
  # removal text searched in the next few lines. PHPStan's table format also
  # yields the file (its "Line <file>" header) and the line number.
  # awk emits one TAB-separated record per finding (file, line, message; every
  # whitespace run is already a single space) and jq builds the JSON, so no awk
  # has to escape backslashes (gsub's backslash handling differs between awks).
  RAW="$(awk '
    function flush() { if (msg != "") printf "%s\t%s\t%s\n", cur, ln, msg
                       msg = ""; left = 0 }
    {
      line = $0; gsub(/[|]/, " ", line); gsub(/[[:space:]]+/, " ", line)
      if (line ~ /^ ?Line [^ ]/) { flush(); cur = line; sub(/^ ?Line /, "", cur); sub(/ .*$/, "", cur); next }
      if (line ~ /[Dd]eprecated (function|method|static method|class|interface|trait|constant|class constant|property|static property) / || line ~ /Function [A-Za-z0-9_\\]+ not found/ || line ~ / is deprecated in [a-z0-9_]+:[0-9]/ || line ~ /implements hook_[A-Za-z0-9_]+ which is deprecated/ || line ~ /" service is deprecated/) {
        flush(); msg = line; left = 6; ln = ""
        if (match(line, /^ ?[0-9]+ /)) { ln = substr(line, RSTART, RLENGTH); gsub(/ /, "", ln); sub(/^ ?[0-9]+ /, "", msg) }
        # A one-line notice that already carries both versions is complete.
        if (line ~ / in [a-z0-9_]+:[0-9][0-9.]* and [^.:]* [a-z0-9_]+:[0-9]/) flush()
        next
      }
      if (left > 0) { msg = msg " " line; left--; if (line ~ /is removed from/ || line ~ / and [^.:]* [a-z0-9_]+:[0-9]/) flush() }
    }
    END { flush() }' "$TMP" \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
        | {file: (if .[0] == "" then null else .[0] end), line: (.[1] | tonumber? // null),
           message: (.[2:] | join(" ")), identifier: null})' 2>/dev/null || echo '[]')"
  printf '%s' "$RAW" | jq empty 2>/dev/null || RAW='[]'
fi

RESULT="$(jq -n \
  --argjson raw "$RAW" \
  --slurpfile cat "$CATALOG" \
  --arg policy "$POLICY" --arg phase "$PHASE" \
  --argjson tmaj "$TARGET_MAJOR" \
  --arg req "$CORE_REQ" --arg floor "$FLOOR" '
  def vnum: tostring | split(".") | map(tonumber? // 0) | (. + [0, 0, 0])[:3];
  def major: if . == null then null else (vnum | .[0]) end;
  def norm: sub("^\\\\"; "") | sub("\\(\\)$"; "") | sub(":$"; "");
  ($cat[0].lifecycle // []) as $life
  | ($cat[0].change_records_search // "") as $cr
  | (if $floor == "" then null else $floor end) as $fl
  | def lookup($s): ($life | map(select(.symbol == $s)) | .[0]) // null;
    def classify:
      . as $r
      | ($r.message | gsub("\\s+"; " ")) as $m
      | ($m | capture("[Dd]eprecated (?<kind>function|method|static method|class|interface|trait|constant|class constant|property|static property) (?<sym>[A-Za-z0-9_\\\\:$]+(\\(\\))?)")? // null) as $d
      | ($m | capture("Function (?<sym>[A-Za-z0-9_\\\\]+) not found")? // null) as $nf
      | (if $d == null then ($m | capture("(?<sym>[A-Za-z0-9_\\\\:]+)\\(\\) is deprecated in [a-z0-9_]+:")? // null) else null end) as $rt
      | (if $d == null and $rt != null then {kind: (if ($rt.sym | test("::")) then "method" else "function" end), sym: $rt.sym} else $d end) as $d
      # phpstan-drupal forms (DeprecatedHookImplementation, Get/StaticService-
      # DeprecatedServiceRule) and core runtime notices for classes / arguments.
      | ($m | capture("Function (?<fn>[A-Za-z0-9_]+) implements (?<hook>[A-Za-z0-9_]+) which is deprecated")? // null) as $hk
      | ($m | capture("The \"(?<svc>[^\"]+)\" service is deprecated")? // null) as $sv
      | ($m | capture("The (?<cls>[A-Za-z0-9_\\\\]+)( base)? class is deprecated")? // null) as $cl
      # Anything else that is a deprecation but cannot be parsed is NOT "other":
      # it is classified (unknown -> blocking) so it is never silently dropped.
      | ((($r.identifier // "") | test("deprecat"; "i")) or ($m | test("deprecat"; "i"))) as $isdep
      # Removal: core writes "in drupal:A and is removed from drupal:B", and for
      # arguments/behaviors "... and it will be required in / will be removed in
      # / will be unsupported in drupal:B": B is when the old code stops working.
      | ($m | capture("in (?<p1>[a-z0-9_]+):(?<dep>[0-9][0-9.]*[0-9]) and [^.:]*? ?(?<p2>[a-z0-9_]+):(?<rem>[0-9][0-9.]*[0-9])")? // null) as $v
      | ($m | capture(" of (class|interface|trait) (?<cls>[A-Za-z0-9_\\\\]+)")? // null) as $of
      | (if $d != null then
           (if ($d.kind | test("method")) and $of != null and (($d.sym | test("::")) | not)
            then ($of.cls | norm) + "::" + ($d.sym | norm) else ($d.sym | norm) end)
         elif $nf != null then ($nf.sym | norm)
         elif $hk != null then $hk.hook
         elif $sv != null then $sv.svc
         elif $cl != null then ($cl.cls | norm)
         elif $isdep then
           (($m | capture("(?<s>[A-Za-z0-9_\\\\]+::[A-Za-z0-9_]+\\(\\)|[A-Za-z0-9_\\\\]+\\(\\))")? // null)
            | if . != null then (.s | norm) else ($m | .[0:80]) end)
         else null end) as $sym
      | (if $sym == null then null else lookup($sym) end) as $c
      | (if $d == null and $nf == null and ($isdep | not) then null
         else
           { file: (if $r.file == null then null else ($r.file | sub("^/var/www/html/"; "")) end), line: $r.line, symbol: $sym,
             kind: (if $d != null then $d.kind elif $nf != null then "function" elif $hk != null then "hook"
                    elif $sv != null then "service" elif $cl != null then "class" else "other" end),
             not_found: ($nf != null),
             message: ($r.message | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != "")) | join(" ")),
             project: (if $v != null then $v.p2 else (if $c != null then "drupal" else null end) end),
             deprecated_in: (if $v != null then $v.dep elif $c != null then $c.deprecated_in else null end),
             removed_in: (if $v != null then $v.rem elif $c != null then $c.removed_in else null end),
             replacement: ($c.replacement // null),
             replacement_since: ($c.replacement_since // null),
             no_replacement_entry: ($c != null and ($c | has("replacement_since")) and $c.replacement_since == null),
             effort: ($c.effort // null),
             catalogued: ($c != null),
             change_record: (if $cr != "" and $sym != null then $cr + ($sym | gsub(" "; "%20") | gsub("\\\\"; "%5C") | gsub(":"; "%3A")) else null end) }
         end) ;
    def klass:
      if .not_found and (.catalogued | not) then "unknown"
      elif .project != "drupal" or .removed_in == null then "unknown"
      elif (.removed_in | major) <= $tmaj then "hard"
      else "soft" end;
    # Unknown floor: only a replacement every Drupal 8+ core has counts as present.
    def at_floor:
      if .replacement_since == null then null
      elif $fl == null then (if (.replacement_since | vnum) <= ("8.0" | vnum) then true else null end)
      else (($fl | vnum) >= (.replacement_since | vnum)) end;
    def decide($cls):
      if $cls == "hard" then {action: "fix", reason: "removed in drupal:\(.removed_in), at or below the target major \($tmaj): blocking"}
      elif $cls == "unknown" then {action: "fix", reason: (if .not_found then "symbol not found and not in the lifecycle catalog (removed API or missing dependency): blocking until reviewed" else "removal version not readable as a Drupal core version: blocking until reviewed" end)}
      else
        ( (if $phase == "refactor" then "fix" else $policy end) as $p
        | if $p == "report" then {action: "report", reason: "soft: works on every Drupal \($tmaj) core (removed from drupal:\(.removed_in)); listed, code untouched (policy report)"}
          elif $p == "defer" then {action: "defer", reason: "soft: deferred to Phase 2 (policy defer); works until drupal:\(.removed_in)"}
          elif .no_replacement_entry then {action: "defer", reason: "core offers no replacement on any version; defer to Phase 2"}
          elif .replacement_at_floor == true then {action: "fix", reason: "replacement available at the core floor \($fl)"}
          elif .replacement_since == null then {action: "defer", reason: "not in the lifecycle catalog, so the replacement and the first core that has it are unknown: defer to Phase 2 unless you verify the replacement exists at the core floor (\($fl // "unknown"))"}
          elif $fl != null and (($fl | vnum) < ("10.1" | vnum)) then {action: "defer", reason: "replacement needs core \(.replacement_since) and the floor \($fl) predates DeprecationHelper (10.1): defer, or raise the floor"}
          else {action: "fix-guarded", reason: "replacement exists only from core \(.replacement_since); the core floor (\($fl // "unknown")) is below it: wrap it in DeprecationHelper::backwardsCompatibleCall(\\Drupal::VERSION, \(.deprecated_in), <replacement>, <original call>)"}
          end )
      end;
    [ $raw[] | classify | select(. != null) ] as $all
    | [ $all[] | . + {class: klass} | . + {replacement_at_floor: at_floor} | . as $i | $i + ($i | decide($i.class))
        | del(.no_replacement_entry, .catalogued, .project) ] as $items
    | ($raw | length) as $nraw
    | { tool: "classify-deprecations", policy: $policy, phase: $phase,
        target_major: $tmaj,
        core_requirement: (if $req == "" then null else $req end),
        core_floor: $fl,
        blocking: ([ $items[] | select(.class == "hard" or .class == "unknown") ] | length),
        counts: { hard: ([ $items[] | select(.class == "hard") ] | length),
                  soft: ([ $items[] | select(.class == "soft") ] | length),
                  unknown: ([ $items[] | select(.class == "unknown") ] | length),
                  other: ($nraw - ($items | length)) },
        symbols: ( $items | group_by(.symbol)
                   | map(.[0] as $f | { symbol: $f.symbol, class: $f.class, deprecated_in: $f.deprecated_in,
                                       removed_in: $f.removed_in, replacement: $f.replacement,
                                       replacement_since: $f.replacement_since,
                                       replacement_at_floor: $f.replacement_at_floor, effort: $f.effort,
                                       action: $f.action, reason: $f.reason, change_record: $f.change_record,
                                       occurrences: length,
                                       locations: [ .[] | select(.file != null) | "\(.file):\(.line)" ] })
                   | sort_by(({"hard": 0, "unknown": 1, "soft": 2})[.class], .symbol) ),
        hard: [ $items[] | select(.class == "hard") ],
        soft: [ $items[] | select(.class == "soft") ],
        unknown: [ $items[] | select(.class == "unknown") ] }
')" || die "Could not classify the input (malformed analyzer output?)." 1

if [[ "$AS_JSON" == "1" ]]; then
  printf '%s\n' "$RESULT"
  exit 0
fi

H="$(printf '%s' "$RESULT" | jq -r '.counts.hard')"
S="$(printf '%s' "$RESULT" | jq -r '.counts.soft')"
U="$(printf '%s' "$RESULT" | jq -r '.counts.unknown')"
hr
log_plain "Deprecations — target Drupal ${TARGET_MAJOR}, core floor ${FLOOR:-unknown}, soft policy '${POLICY}' (phase ${PHASE})"
hr
if [[ "$H" == "0" && "$S" == "0" && "$U" == "0" ]]; then
  log_ok "No deprecation recognized in the input."
  exit 0
fi
printf '%s' "$RESULT" | jq -r '
  "| Class | Symbol | Deprecated in | Removed in | Effort | Action | Occurrences |",
  "|---|---|---|---|---|---|---|",
  (.symbols[] | "| \(.class) | `\(.symbol)` | \(.deprecated_in // "?") | \(.removed_in // "?") | \(.effort // "n/a") | \(.action) | \(.occurrences) |"),
  "",
  (.symbols[] | "- \(.symbol): \(.reason)" + (if .replacement then "\n    replacement: \(.replacement)" else "" end))'
exit 0
