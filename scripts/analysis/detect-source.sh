#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/detect-source.sh
# Detect the SOURCE era S of a module/theme: the oldest Drupal major whose APIs
# the code still uses (AR-05). It drives the upgrade plan's hops and its track
# (d7-assisted for Drupal 7). Read-only and pure: it reads the subject and
# paths/eras.json of the version data (config/, or DRUPILOT_VERSION_DATA_DIR),
# never a bed, the network or state.
#
# Signals, in order (AR-05, 04-R8):
#   1  a Drupal 7 .info with `core = 7.x`                     -> S = 7 (d7-assisted)
#   2  a .info.yml with `core: 8.x` and no
#      core_version_requirement                             -> S <= 8
#   3  the declared core_version_requirement of the subject's own .info.yml
#      (informational: it decides S only when no code signal does, see below)
#   4  (--full only) recorded analyzer output: PHPStan messages "removed from
#      drupal:X" (and unknown symbols the config/deprecations.json lifecycle
#      catalog dates)                                       -> S <= X - 1.
#      In 1.0 it reads a PHPStan --error-format=json file given with
#      --phpstan; the bed-driven per-era scan comes later (M9). It may only
#      lower S; its evidence keeps the hits of the oldest era (at most 20).
#   5  the SimpleTest scan (eras.json kind test-api of era 8: WebTestBase)  -> S <= 8
#   6  the test-API era (eras.json kind test-api of era 7: Drupal(Web|Unit)TestCase) -> S <= 7
# Signals 5 and 6 grep every .php/.module/.inc/.install/.test/.theme/.profile
# file under the subject (vendor/, node_modules/ and .git/ aside), nested
# modules included, with the ERE each eras.json signal declares (at most 20
# hits of each in the evidence).
#
# S is the minimum over the code signals (1, 2, 4, 5, 6) and the lowest major
# the declared constraint admits (3): a lower S only adds hops whose rules find
# nothing, a higher one would skip APIs the code still uses (ADR 0016).
# confidence: high when a code signal sets S; medium when the declaration
# does (no code signal is as old); low when the subject declares nothing (S
# defaults to 8, the oldest standard-track era).
#
# Usage:
#   detect-source.sh [--subject DIR] [--static | --full [--phpstan FILE]] [--json]
#
# Options:
#   --subject DIR    The module/theme directory (default: the current one).
#   --static         Signals 1-3, 5 and 6; no bed (the default; plan-draft).
#   --full           Also signal 4 (plan-final).
#   --phpstan FILE   With --full: a PHPStan --error-format=json output of the
#                    subject to read for signal 4.
#   --json           Print only the JSON on STDOUT (no human summary on
#                    STDERR).
#   -h, --help       Show this help.
#
# Output (STDOUT, canonical: keys sorted, evidence ordered by era, signal,
# file and line; paths relative to the subject):
#   {source_major, track, confidence, signals_used: [1, 2, 3, ...],
#    evidence: [{signal, id, era, file?, line?, detail}]}
#
# Exit codes: 0 ok · 1 usage error, or the directory holds no .info.yml and
# no Drupal 7 .info.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
MODE="static"
PHPSTAN_FILE=""
JSON_ONLY=0

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a directory" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --static) MODE="static"; shift;;
    --full) MODE="full"; shift;;
    --phpstan) PHPSTAN_FILE="${2:-}"; shift 2 || die "--phpstan needs a file" 1;;
    --phpstan=*) PHPSTAN_FILE="${1#*=}"; shift;;
    --json) JSON_ONLY=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)." 1;;
  esac
done

have_cmd jq || die "jq is required for detect-source.sh." 1
SUBJECT="${SUBJECT:-$PWD}"
SUBJ="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
[[ -n "$SUBJ" && -d "$SUBJ" ]] || die "Subject directory not found: '$SUBJECT'." 1
if [[ -n "$PHPSTAN_FILE" ]]; then
  [[ "$MODE" == "full" ]] || die "--phpstan is read only with --full (signal 4 needs a bed's output)." 1
  [[ -r "$PHPSTAN_FILE" ]] || die "PHPStan output not found: '$PHPSTAN_FILE'." 1
fi
ERAS="$(version_data_dir)/paths/eras.json"
[[ -r "$ERAS" ]] || die "The era signals are missing: $ERAS." 1

INFO_YML="$(subject_info_file "$SUBJ" 2>/dev/null || true)"
INFO_D7=""
[[ -n "$INFO_YML" ]] || INFO_D7="$(subject_d7_info_file "$SUBJ" 2>/dev/null || true)"
[[ -n "$INFO_YML" || -n "$INFO_D7" ]] \
  || die "No *.info.yml (nor a Drupal 7 .info) in '$SUBJ': not a module or theme." 1

# Evidence, one JSON object per line.
EV=""
add_ev() { EV="$EV$1"$'\n'; }
rel() { local p="$1"; printf '%s' "${p#"$SUBJ"/}"; }

# --- Signals 1 and 2: the info file ------------------------------------------
if [[ -n "$INFO_D7" ]]; then
  core7="$(info_value_d7 "$INFO_D7" core)"
  if [[ "$core7" == "7.x" ]]; then
    add_ev "$(jq -nc --arg f "$(rel "$INFO_D7")" '{signal: 1, id: "info-core-7x", era: 7, file: $f, detail: "core = 7.x"}')"
  else
    die "'$(rel "$INFO_D7")' is a .info file without 'core = 7.x' (core = '${core7}'): not a Drupal 7 module drupilot can read." 1
  fi
else
  DECLARED="$(subject_core_requirement "$SUBJ" 2>/dev/null || true)"
  core8="$(grep -E '^[[:space:]]*core:' "$INFO_YML" 2>/dev/null | head -n 1 \
    | sed -E 's/^[[:space:]]*core:[[:space:]]*//; s/[[:space:]]*$//' | tr -d "\"'" || true)"
  if [[ "$core8" == "8.x" && -z "$DECLARED" ]]; then
    add_ev "$(jq -nc --arg f "$(rel "$INFO_YML")" '{signal: 2, id: "info-core-8x", era: 8, file: $f, detail: "core: 8.x without core_version_requirement"}')"
  fi
  # --- Signal 3: the declared constraint (informational) ---------------------
  if [[ -n "$DECLARED" ]]; then
    fl="$(core_floor_from_requirement "$DECLARED")"
    if [[ -n "$fl" ]]; then
      add_ev "$(jq -nc --arg f "$(rel "$INFO_YML")" --arg c "$DECLARED" --argjson e "${fl%%.*}" \
        '{signal: 3, id: "declared", era: $e, file: $f, detail: ("core_version_requirement: " + $c)}')"
    fi
  fi
fi

# --- Signals 5 and 6: the test APIs (eras.json kind test-api) ------------------
# One "<era>\t<id>\t<ere>" per test-api signal, era 8 (SimpleTest) as signal 5,
# era 7 (the D7 test cases) as signal 6.
while IFS=$'\t' read -r era id ere; do
  [[ -n "$id" ]] || continue
  sig=5; [[ "$era" -lt 8 ]] && sig=6
  hits="$(find "$SUBJ" \( -name vendor -o -name node_modules -o -name .git \) -prune -o -type f \
      \( -name '*.php' -o -name '*.module' -o -name '*.inc' -o -name '*.install' -o -name '*.test' \
         -o -name '*.theme' -o -name '*.profile' \) -exec grep -HnE "$ere" {} + 2>/dev/null \
    | LC_ALL=C sort -t: -k1,1 -k2,2n | head -n 20 || true)"
  [[ -n "$hits" ]] || continue
  while IFS= read -r h; do
    f="${h%%:*}"; rest="${h#*:}"; ln="${rest%%:*}"
    add_ev "$(jq -nc --argjson s "$sig" --arg id "$id" --argjson e "$era" --arg f "$(rel "$f")" \
      --argjson l "$ln" --arg d "$(printf '%s' "${rest#*:}" | sed -E 's/^[[:space:]]+//' | cut -c1-120)" \
      '{signal: $s, id: $id, era: $e, file: $f, line: $l, detail: $d}')"
  done <<EOF
$hits
EOF
done <<EOF
$(jq -r '.eras | to_entries[] | .key as $e | .value.signals[]
  | select(.kind == "test-api" and ((.match // "") | startswith("ere:")))
  | "\($e)\t\(.id)\t\(.match | ltrimstr("ere:"))"' "$ERAS")
EOF

# --- Signal 4 (--full): recorded PHPStan output ---------------------------------
if [[ "$MODE" == "full" && -n "$PHPSTAN_FILE" ]]; then
  CATALOG="$(plugin_root)/config/deprecations.json"
  s4="$(jq -c --slurpfile cat "$CATALOG" '
      ([$cat[0].lifecycle // [] | .[] | select(.symbol != null and .removed_in != null)
        | {key: (.symbol | ascii_downcase), value: .removed_in}] | from_entries) as $rm
      | [(.files // {}) | to_entries[] | .key as $f | .value.messages[]? | . as $m
         | ($m.message // "") as $t
         | ( ($t | capture("removed from drupal:(?<v>[0-9]+)\\.") | .v | tonumber),
             ($t | capture("(?:Function|Class|Interface|Trait) (?<s>[A-Za-z0-9_\\\\]+) not found")
                 | .s | ascii_downcase | ltrimstr("\\") | $rm[.] // empty | split(".")[0] | tonumber)
           ) as $rmaj
         | {signal: 4, id: "phpstan-removed", era: ($rmaj - 1), file: $f, line: ($m.line // 0),
            detail: ($t | split("\n")[0] | .[0:120])}]
      | unique_by([.era, .file, .line])
      | (map(.era) | min) as $low | map(select(.era == $low)) | .[0:20][]' "$PHPSTAN_FILE" 2>/dev/null || true)"
  [[ -n "$s4" ]] && add_ev "$s4"
fi

# --- S, track, confidence ----------------------------------------------------------
USED='[1, 2, 3, 5, 6]'
[[ "$MODE" == "full" ]] && USED='[1, 2, 3, 4, 5, 6]'
JSON="$(printf '%s' "$EV" | jq -s -S -c --argjson used "$USED" --slurpfile eras "$ERAS" '
  map(select(type == "object"))
  | map(if .file then .file |= sub("^/+"; "") else . end)
  | unique | sort_by([.era, .signal, (.file // ""), (.line // 0), .id])
  | . as $ev
  | ([$ev[] | select(.signal != 3) | .era] | min) as $code
  | ([$ev[] | select(.signal == 3) | .era] | min) as $decl
  | (if $code != null and ($decl == null or $code <= $decl) then {s: $code, c: "high"}
     elif $decl != null then {s: $decl, c: "medium"}
     else {s: 8, c: "low"} end) as $r
  | {source_major: $r.s, confidence: $r.c,
     track: ($eras[0].eras[($r.s | tostring)].track // "standard"),
     signals_used: $used, evidence: $ev}')"

if [[ "$JSON_ONLY" != "1" ]]; then
  log_info "Subject      : $SUBJ"
  log_info "Source era S : $(printf '%s' "$JSON" | jq -r '.source_major') (track $(printf '%s' "$JSON" | jq -r '.track'), confidence $(printf '%s' "$JSON" | jq -r '.confidence'))"
  printf '%s' "$JSON" | jq -r '.evidence[] | "   signal \(.signal) \(.id) -> era \(.era)\(if .file then " (" + .file + (if .line then ":" + (.line | tostring) else "" end) + ")" else "" end)"' >&2
fi
printf '%s\n' "$JSON" | jq -S .
