#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/contrib/open-mr.sh
# Push an issue-fork branch and open a Merge Request on git.drupalcode.org
# (PROMPT 3.2 / 3.5). Runs from inside the project checkout prepared by
# issue-fork.sh.
#
# Flow:
#   1. Rebase the branch onto origin/BASE (fetch origin first).
#   2. In 'semi' mode, CONFIRM before pushing. Push to the issue remote.
#   3. Try to open the MR via the GitLab API (glab, then curl with the PAT).
#      If the API is blocked/unavailable, DEGRADE GRACEFULLY: print the MR
#      creation URL so the user opens it with one click.
#   4. Remind the user about the Contribution Record (maintainers assign credit).
#
# The PAT is read from the env var named by .contrib.pat_env_var and is NEVER
# printed, echoed, or persisted.
#
# Usage:
#   open-mr.sh --project NAME --issue ID --branch BRANCH
#              [--mode semi|auto] [--base BASE_VERSION]
#              [--description-file FILE]
#
#   --mode   defaults to DRUPILOT_CONTRIB_MODE (semi). 'semi' confirms before
#            push; 'auto' pushes without prompting (requires SSH/PAT configured).
#   --base   base version branch to rebase onto (e.g. 11.x, 2.0.x). If omitted,
#            the current upstream/origin HEAD is used and rebase is skipped.
#   --description-file
#            file whose contents become the MR description (e.g. the comment
#            produced by make-issue.sh). Defaults to a link to the issue.
#
# Exit codes: 0 ok · 1 usage/error · 2 hard requirement missing (gate) ·
#             3 push declined/failed.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PROJECT=""
ISSUE=""
BRANCH=""
MODE=""
BASE=""
DESC_FILE=""

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2;;
    --project=*) PROJECT="${1#*=}"; shift;;
    --issue) ISSUE="${2:-}"; shift 2;;
    --issue=*) ISSUE="${1#*=}"; shift;;
    --branch) BRANCH="${2:-}"; shift 2;;
    --branch=*) BRANCH="${1#*=}"; shift;;
    --mode) MODE="${2:-}"; shift 2;;
    --mode=*) MODE="${1#*=}"; shift;;
    --base) BASE="${2:-}"; shift 2;;
    --base=*) BASE="${1#*=}"; shift;;
    --description-file) DESC_FILE="${2:-}"; shift 2;;
    --description-file=*) DESC_FILE="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

[[ -n "$PROJECT" ]] || die "Missing --project NAME" 1
[[ -n "$ISSUE" ]]   || die "Missing --issue ID" 1
[[ -n "$BRANCH" ]]  || die "Missing --branch BRANCH" 1
[[ "$ISSUE" =~ ^[0-9]+$ ]] || die "Issue id must be numeric: '$ISSUE'" 1

MODE="${MODE:-$(config_get DRUPILOT_CONTRIB_MODE "semi")}"
case "$MODE" in
  semi|auto) : ;;
  *) die "Invalid --mode '$MODE' (use semi|auto)" 1;;
esac

# Must be inside a git checkout.
have_cmd git || die "git is not installed." 1
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "Not inside a git checkout. cd into the issue-fork clone first (see issue-fork.sh)." 1

# ---------------------------------------------------------------------------
# Gate: contribution requirements. Abort cleanly with no side effects.
# ---------------------------------------------------------------------------
PREFLIGHT="$(plugin_root)/scripts/env/preflight.sh"
if [[ -r "$PREFLIGHT" ]]; then
  if ! bash "$PREFLIGHT" --profile contribute --quiet >&2; then
    log_err "Contribution requirements are not met. Run /drupilot-doctor or scripts/contrib/check-prereqs.sh first."
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# Config / URLs (from .contrib.*)
# ---------------------------------------------------------------------------
HTTPS_HOST="$(config_json .contrib.gitlab_https_host "git.drupalcode.org")"
PAT_ENV_VAR="$(config_json .contrib.pat_env_var "DRUPILOT_GITLAB_PAT")"
ISSUE_REMOTE="$PROJECT-$ISSUE"

# The issue fork lives under the 'issue/' group on drupalcode.
# URL-encoded project path for the GitLab API: issue%2FPROJECT-ISSUE
FORK_PATH="issue/$PROJECT-$ISSUE"
FORK_PATH_ENC="issue%2F$PROJECT-$ISSUE"
MR_NEW_URL="https://$HTTPS_HOST/$FORK_PATH/-/merge_requests/new?merge_request%5Bsource_branch%5D=$BRANCH"
ISSUE_URL="https://www.drupal.org/project/$PROJECT/issues/$ISSUE"

# Confirm the issue remote exists (issue-fork.sh adds it).
if ! git remote get-url "$ISSUE_REMOTE" >/dev/null 2>&1; then
  die "Remote '$ISSUE_REMOTE' is not configured. Run scripts/contrib/issue-fork.sh --project $PROJECT --issue $ISSUE first." 1
fi

log_step "Open MR: $PROJECT issue #$ISSUE (branch '$BRANCH', mode '$MODE')"

# ---------------------------------------------------------------------------
# 1. Rebase onto origin/BASE (PROMPT 3.2). Skipped if --base is not given.
# ---------------------------------------------------------------------------
# Make sure we are on the branch we intend to push.
CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [[ "$CUR_BRANCH" != "$BRANCH" ]]; then
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH" >&2
  else
    die "Branch '$BRANCH' does not exist locally. Did you run issue-fork.sh?" 1
  fi
fi

if [[ -n "$BASE" ]]; then
  log_info "Fetching origin and rebasing onto origin/$BASE ..."
  if ! git fetch origin >&2; then
    die "git fetch origin failed. Check your network and remote configuration." 1
  fi
  if ! git show-ref --verify --quiet "refs/remotes/origin/$BASE"; then
    die "origin/$BASE not found. Pass the correct --base (e.g. 11.x, 2.0.x)." 1
  fi
  if ! git rebase "origin/$BASE" >&2; then
    git rebase --abort >/dev/null 2>&1 || true
    log_err "Rebase onto origin/$BASE hit conflicts and was aborted. Resolve manually, then re-run."
    exit 1
  fi
  log_ok "Rebased '$BRANCH' onto origin/$BASE."
else
  log_info "No --base given; skipping rebase. (Pass --base for a clean rebase before MR.)"
fi

# ---------------------------------------------------------------------------
# 2. Push to the issue remote. In 'semi' mode, confirm first.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "semi" ]]; then
  if ! confirm "Push branch '$BRANCH' to '$ISSUE_REMOTE' (this is an outward-facing action)?" 0; then
    log_warn "Push cancelled. No changes were pushed."
    log_plain "   When ready, re-run this command (or push manually): git push $ISSUE_REMOTE $BRANCH"
    exit 3
  fi
fi

log_info "Pushing '$BRANCH' to '$ISSUE_REMOTE' ..."
if ! git push -u "$ISSUE_REMOTE" "$BRANCH" >&2; then
  log_err "git push failed. Verify your SSH key / push access on the issue fork ('Get push access' on the issue page)."
  exit 3
fi
log_ok "Pushed '$BRANCH' to '$ISSUE_REMOTE'."

# ---------------------------------------------------------------------------
# 3. Open the MR via the GitLab API, degrading gracefully if it is blocked.
#    The Drupal Association blocks the GitLab API by default (PROMPT 3.5):
#    treat ANY failure as "degrade to the manual URL".
# ---------------------------------------------------------------------------
MR_TITLE="Issue #$ISSUE: port to Drupal 11"
MR_WEB_URL=""
API_DONE=0

# MR description: the generated comment (make-issue.sh) when provided, else a
# link to the issue. This is the brief description that accompanies the MR.
MR_DESC="See $ISSUE_URL"
if [[ -n "$DESC_FILE" ]]; then
  [[ -r "$DESC_FILE" ]] || die "Description file not found or unreadable: $DESC_FILE" 1
  MR_DESC="$(cat "$DESC_FILE")"
fi

degrade_to_url() {
  local reason="$1"
  log_warn "Could not open the MR via the GitLab API${reason:+ ($reason)}."
  log_plain "   The drupalcode GitLab API is blocked by default — this is expected. Open the MR with one click:"
  log_plain "      $MR_NEW_URL"
}

# Target branch for the MR: the base version if provided, else leave for the UI.
MR_TARGET="${BASE:-}"

# Prefer glab if present and authenticated; otherwise curl with the PAT.
PAT="${!PAT_ENV_VAR:-}"   # read once; never echoed.

if have_cmd glab; then
  log_info "Attempting to open the MR via glab ..."
  # glab works against the fork path on the drupalcode host.
  set +e
  GLAB_OUT="$(GITLAB_HOST="$HTTPS_HOST" glab mr create \
      --repo "$FORK_PATH" \
      --source-branch "$BRANCH" \
      ${MR_TARGET:+--target-branch "$MR_TARGET"} \
      --title "$MR_TITLE" \
      --description "$MR_DESC" \
      --yes 2>&1)"
  GLAB_RC=$?
  set -e
  if [[ "$GLAB_RC" -eq 0 ]]; then
    MR_WEB_URL="$(printf '%s\n' "$GLAB_OUT" | grep -oE 'https://[^ ]*/merge_requests/[0-9]+' | head -n1)"
    API_DONE=1
    log_ok "Merge request created via glab."
  else
    degrade_to_url "glab API call failed"
  fi
fi

if [[ "$API_DONE" -eq 0 && -n "$PAT" ]] && have_cmd curl; then
  log_info "Attempting to open the MR via the GitLab API (curl) ..."
  # Build the request body with jq to avoid quoting issues.
  BODY="$(jq -n \
    --arg sb "$BRANCH" --arg tb "${MR_TARGET:-}" \
    --arg title "$MR_TITLE" --arg desc "$MR_DESC" \
    '{source_branch:$sb, title:$title, description:$desc}
       + (if $tb == "" then {} else {target_branch:$tb} end)')"
  API_ENDPOINT="https://$HTTPS_HOST/api/v4/projects/$FORK_PATH_ENC/merge_requests"
  set +e
  # PRIVATE-TOKEN header carries the PAT; -s keeps it out of any progress output.
  HTTP_BODY="$(curl -sS -X POST \
      -H "PRIVATE-TOKEN: $PAT" \
      -H "Content-Type: application/json" \
      -w '\n%{http_code}' \
      -d "$BODY" \
      "$API_ENDPOINT" 2>/dev/null)"
  CURL_RC=$?
  set -e
  if [[ "$CURL_RC" -eq 0 ]]; then
    HTTP_CODE="$(printf '%s' "$HTTP_BODY" | tail -n1)"
    HTTP_JSON="$(printf '%s' "$HTTP_BODY" | sed '$d')"
    if [[ "$HTTP_CODE" == "201" ]]; then
      MR_WEB_URL="$(printf '%s' "$HTTP_JSON" | jq -r '.web_url // empty' 2>/dev/null || true)"
      API_DONE=1
      log_ok "Merge request created via the GitLab API."
    else
      # Do NOT echo the response verbatim (it could reflect headers); summarize.
      degrade_to_url "HTTP $HTTP_CODE"
    fi
  else
    degrade_to_url "curl error"
  fi
elif [[ "$API_DONE" -eq 0 ]]; then
  if [[ -z "$PAT" ]]; then
    degrade_to_url "no API token in \$$PAT_ENV_VAR"
  else
    degrade_to_url "no API client (glab/curl) available"
  fi
fi

# ---------------------------------------------------------------------------
# 4. Final guidance + Contribution Record reminder (PROMPT 3.5).
# ---------------------------------------------------------------------------
hr
if [[ "$API_DONE" -eq 1 ]]; then
  log_ok "Merge request opened."
  [[ -n "$MR_WEB_URL" ]] && log_plain "   MR: $MR_WEB_URL"
else
  log_info "Branch pushed. Create the MR manually here:"
  log_plain "   $MR_NEW_URL"
fi
log_info "Then, on the issue, post a comment and set the status to 'Needs review':"
log_plain "   $ISSUE_URL"
log_warn "Credit reminder: maintainers assign credit via the issue's Contribution Record. The commit alone does not grant credit — do not try to claim it."

# Machine-readable summary on STDOUT.
if [[ "$API_DONE" -eq 1 && -n "$MR_WEB_URL" ]]; then
  printf '%s\n' "$MR_WEB_URL"
else
  printf '%s\n' "$MR_NEW_URL"
fi
exit 0
