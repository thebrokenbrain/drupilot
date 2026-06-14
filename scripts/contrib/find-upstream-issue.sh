#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/contrib/find-upstream-issue.sh
# Before porting a contrib project, check whether someone is ALREADY porting it
# to Drupal 11 on drupal.org — so the developer can join/base on existing work
# (an open issue + merge request) instead of duplicating it.
#
# It resolves the project node id via the drupal.org api-d7 feed, fetches a few
# pages of the project's issue queue, and surfaces issues whose title looks like a
# Drupal 11 compatibility effort. The title scan is BEST-EFFORT (an issue deep in
# the queue may be missed), so the authoritative deliverable is always the
# pre-filtered issue-queue URL the developer can open. Read-only, no credentials.
#
# Usage:
#   find-upstream-issue.sh --project NAME [--json] [--pages N]
#     --project  drupal.org project machine name (required).
#     --pages    issue-queue pages to scan via the API (default 3, 50/page).
#     --json     emit a JSON object instead of the human report.
#
# Output: a human report on STDERR; the search URL (+ matches) on STDOUT, or a
#         JSON object with --json.
# Exit codes: 0 ok (matches or not — both are valid) · 1 usage/error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PROJECT=""
AS_JSON=0
PAGES=3
usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2;;
    --project=*) PROJECT="${1#*=}"; shift;;
    --pages) PAGES="${2:-3}"; shift 2;;
    --pages=*) PAGES="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

[[ -n "$PROJECT" ]] || die "Missing --project NAME (the drupal.org project machine name)." 1
[[ "$PAGES" =~ ^[0-9]+$ ]] || PAGES=3
have_cmd jq || die "jq is required." 1

API="https://www.drupal.org/api-d7/node.json"
SEARCH_URL="https://www.drupal.org/project/issues/${PROJECT}?text=Drupal+11&status=All"

# The reliable, always-valid deliverable: the pre-filtered issue-queue URL.
emit_min() {
  local reason="$1"
  if [[ "$AS_JSON" == "1" ]]; then
    jq -n --arg project "$PROJECT" --arg url "$SEARCH_URL" --arg note "$reason" \
      '{project:$project, checked:false, note:$note, search_url:$url, matches:[]}'
  else
    log_warn "$reason"
    log_plain "  Check by hand: $SEARCH_URL"
    printf '%s\n' "$SEARCH_URL"
  fi
  exit 0
}

have_cmd curl || emit_min "curl is unavailable — cannot query the drupal.org API."

# --- Resolve the project node id ---------------------------------------------
NID=""
for t in project_module project_theme project_distribution; do
  NID="$(curl -fsS --max-time 10 "${API}?type=${t}&field_project_machine_name=${PROJECT}" 2>/dev/null \
    | jq -r '.list[0].nid // empty' 2>/dev/null || true)"
  [[ -n "$NID" ]] && break
done
[[ -n "$NID" ]] || emit_min "Could not resolve '${PROJECT}' on drupal.org (network blocked, or not a hosted project)."

# --- Scan the issue queue for Drupal 11 efforts ------------------------------
# Status map (api-d7 field_issue_status): 1 active, 2 fixed, 8 needs review,
# 13 RTBC, 14 reviewed&tested, 4 postponed, 16 postponed(maintainer), 7 closed...
status_label() { case "$1" in 1) echo "Active";; 2) echo "Fixed";; 3) echo "Closed(dup)";; 4) echo "Postponed";; 5) echo "Closed(won't fix)";; 6) echo "Closed(works)";; 7) echo "Closed(fixed)";; 8) echo "Needs review";; 13) echo "RTBC";; 14) echo "Reviewed&tested";; 15) echo "Patch(to be ported)";; 16) echo "Postponed(maintainer)";; 18) echo "Needs work";; *) echo "status:$1";; esac; }

MATCHES='[]'
page=0
while (( page < PAGES )); do
  RESP="$(curl -fsS --max-time 12 "${API}?type=project_issue&field_project=${NID}&limit=50&page=${page}" 2>/dev/null || true)"
  [[ -z "$RESP" ]] && break
  PAGE_MATCHES="$(printf '%s' "$RESP" | jq -c '
    [ .list[]?
      | select((.title // "") | test("(?i)drupal *-? *11\\b|\\bd11\\b|\\b11\\.x\\b|drupal 11 compat"))
      | {nid: .nid, title: .title, status: (.field_issue_status // ""), url: ("https://www.drupal.org/node/" + (.nid|tostring))} ]' 2>/dev/null || echo '[]')"
  MATCHES="$(jq -c -n --argjson a "$MATCHES" --argjson b "$PAGE_MATCHES" '$a + $b' 2>/dev/null || echo "$MATCHES")"
  # Stop early if a page returned fewer than a full set (last page).
  CNT="$(printf '%s' "$RESP" | jq -r '.list | length' 2>/dev/null || echo 0)"
  (( CNT < 50 )) && break
  page=$((page+1))
done

# Annotate status labels.
MATCHES="$(printf '%s' "$MATCHES" | jq -c 'map(. + {status_label: (.status|tostring)})' 2>/dev/null || echo "$MATCHES")"
COUNT="$(printf '%s' "$MATCHES" | jq 'length' 2>/dev/null || echo 0)"

if [[ "$AS_JSON" == "1" ]]; then
  jq -n --arg project "$PROJECT" --arg url "$SEARCH_URL" --argjson matches "$MATCHES" \
    --argjson count "$COUNT" '{project:$project, checked:true, count:$count, search_url:$url, matches:$matches}'
  exit 0
fi

hr
log_plain "Upstream Drupal 11 issue search — $PROJECT"
hr
if [[ "$COUNT" -gt 0 ]]; then
  log_warn "Found $COUNT issue(s) that look like a Drupal 11 effort — consider basing on existing work:"
  printf '%s' "$MATCHES" | jq -r '.[] | "  #\(.nid)  [\(.status)]  \(.title)\n     \(.url)"' >&2
else
  log_ok "No obvious Drupal 11 issue found in the first $PAGES page(s) of the queue."
fi
log_plain ""
log_info "The title scan is best-effort — confirm in the full filtered queue:"
log_plain "  $SEARCH_URL"
printf '%s\n' "$SEARCH_URL"
exit 0
