#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/explain-deprecations.sh
# Turn cryptic deprecation / Rector output into a teaching aid: for each known
# deprecated symbol found in the input, print a one-line explanation of what
# changed, the modern replacement, and a drupal.org change-records link — so the
# port is a learning experience, not a wall of red.
#
# It matches the input against the curated map in config/deprecations.json. The
# change-record link is a DETERMINISTIC search URL keyed by the symbol (we never
# hardcode a change-record node id, so the link is always valid). It is a
# best-effort aid, not an exhaustive lint.
#
# Usage:
#   explain-deprecations.sh [--file F | -]   [--json]
#     reads the analysis text from --file, or from STDIN (default / '-').
#     --json  emit a JSON array of {symbol, why, fix, change_record, hits}.
#
# Output: a human explainer on STDOUT (or JSON with --json). Logging on STDERR.
# Exit codes: 0 ok (matches or not) · 1 usage/error. Read-only.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

FILE="-"
AS_JSON=0
usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) FILE="${2:-}"; shift 2;;
    --file=*) FILE="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -) FILE="-"; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

have_cmd jq || die "jq is required for the deprecation explainer." 1

MAP="$(plugin_root)/config/deprecations.json"
[[ -r "$MAP" ]] || die "Deprecation map not found: $MAP" 1

# Read the input text (file or stdin).
INPUT=""
if [[ "$FILE" == "-" ]]; then
  INPUT="$(cat 2>/dev/null || true)"
else
  [[ -r "$FILE" ]] || die "Input file not found: $FILE" 1
  INPUT="$(cat "$FILE" 2>/dev/null || true)"
fi
[[ -n "$INPUT" ]] || { log_info "No input text to scan."; [[ "$AS_JSON" == "1" ]] && echo '[]'; exit 0; }

SEARCH_BASE="$(jq -r '.change_records_search // "https://www.drupal.org/list-changes/drupal?keywords_description="' "$MAP" 2>/dev/null)"

# url_encode <string> -> percent-encode spaces and a few specials for the search URL.
url_encode() { printf '%s' "$1" | sed -E 's/ /%20/g; s/\\/%5C/g; s/:/%3A/g'; }

# Walk each map entry; count how many input lines match its pattern.
RESULTS='[]'
COUNT="$(jq '.deprecations | length' "$MAP" 2>/dev/null || echo 0)"
i=0
while (( i < COUNT )); do
  PATTERN="$(jq -r ".deprecations[$i].pattern" "$MAP" 2>/dev/null || true)"
  SYMBOL="$(jq -r ".deprecations[$i].symbol" "$MAP" 2>/dev/null || true)"
  WHY="$(jq -r ".deprecations[$i].why" "$MAP" 2>/dev/null || true)"
  FIX="$(jq -r ".deprecations[$i].fix" "$MAP" 2>/dev/null || true)"
  i=$((i+1))
  [[ -z "$PATTERN" ]] && continue
  HITS="$(printf '%s' "$INPUT" | grep -icE "$PATTERN" 2>/dev/null || true)"
  [[ -z "$HITS" || "$HITS" -eq 0 ]] && continue
  CR="${SEARCH_BASE}$(url_encode "$SYMBOL")"
  RESULTS="$(jq -c -n --argjson acc "$RESULTS" \
    --arg symbol "$SYMBOL" --arg why "$WHY" --arg fix "$FIX" --arg cr "$CR" --argjson hits "$HITS" \
    '$acc + [{symbol:$symbol, why:$why, fix:$fix, change_record:$cr, hits:$hits}]' 2>/dev/null || echo "$RESULTS")"
done

if [[ "$AS_JSON" == "1" ]]; then
  printf '%s\n' "$RESULTS"
  exit 0
fi

N="$(printf '%s' "$RESULTS" | jq 'length' 2>/dev/null || echo 0)"
if [[ "$N" -eq 0 ]]; then
  log_ok "No known deprecation patterns recognized in the input (the explainer map is best-effort)."
  exit 0
fi
hr
log_plain "Deprecation explainer — $N known pattern(s) found"
hr
printf '%s' "$RESULTS" | jq -r '.[] | "• \(.symbol)  (\(.hits) hit(s))\n    what: \(.why)\n    fix : \(.fix)\n    docs: \(.change_record)\n"'
exit 0
