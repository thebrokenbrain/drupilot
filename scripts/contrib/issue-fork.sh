#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/contrib/issue-fork.sh
# Modern Drupal.org contribution flow: clone a project and set up the issue-fork
# remote + working branch (PROMPT 3.2).
#
# Steps performed (idempotent):
#   1. Clone https://git.drupalcode.org/project/NAME.git into <workdir>/NAME
#      (skip if the clone already exists).
#   2. Add the issue-fork remote NAME-ID -> git@git.drupal.org:issue/NAME-ID.git
#      (skip / update if already present).
#   3. git fetch the issue remote.
#   4. Checkout the existing tracking branch, or create a new ID-description branch.
#
# The issue fork itself must be created on the web first ("Create issue fork" +
# "Get push access" on the issue page). This script does NOT push and does NOT
# touch credentials.
#
# Usage:
#   issue-fork.sh --project NAME --issue ID
#                 [--branch BRANCH] [--base BASE_VERSION] [--workdir DIR]
#
#   --project   drupal.org project machine name (e.g. token, pathauto).
#   --issue     numeric issue id (e.g. 3982435).
#   --branch    branch to check out / create. Defaults to a new
#               'ID-port-to-drupal-11' branch when --base is not given.
#   --base      base version branch on the issue remote to track (e.g. 11.x,
#               2.0.x). When given, checks out a tracking branch from it.
#   --workdir   parent directory for the clone (default: current directory).
#
# Exit codes: 0 ok · 1 usage/error · 2 hard requirement missing (preflight gate).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PROJECT=""
ISSUE=""
BRANCH=""
BASE=""
WORKDIR="$PWD"

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2;;
    --project=*) PROJECT="${1#*=}"; shift;;
    --issue) ISSUE="${2:-}"; shift 2;;
    --issue=*) ISSUE="${1#*=}"; shift;;
    --branch) BRANCH="${2:-}"; shift 2;;
    --branch=*) BRANCH="${1#*=}"; shift;;
    --base) BASE="${2:-}"; shift 2;;
    --base=*) BASE="${1#*=}"; shift;;
    --workdir) WORKDIR="${2:-}"; shift 2;;
    --workdir=*) WORKDIR="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

[[ -n "$PROJECT" ]] || die "Missing --project NAME" 1
[[ -n "$ISSUE" ]]   || die "Missing --issue ID" 1
[[ "$ISSUE" =~ ^[0-9]+$ ]] || die "Issue id must be numeric: '$ISSUE'" 1

# ---------------------------------------------------------------------------
# Gate: contribution requirements (git + SSH/PAT). Abort cleanly if not ready.
# ---------------------------------------------------------------------------
PREFLIGHT="$(plugin_root)/scripts/env/preflight.sh"
if [[ -r "$PREFLIGHT" ]]; then
  if ! bash "$PREFLIGHT" --profile contribute --quiet >&2; then
    log_err "Contribution requirements are not met. Run /drupilot-doctor or scripts/contrib/check-prereqs.sh and resolve the issues above."
    exit 2
  fi
else
  have_cmd git || die "git is not installed." 1
fi

# ---------------------------------------------------------------------------
# URLs / remote names (from .contrib.*)
# ---------------------------------------------------------------------------
HTTPS_HOST="$(config_json .contrib.gitlab_https_host "git.drupalcode.org")"
SSH_HOST="$(config_json .contrib.gitlab_host "git.drupal.org")"
CLONE_URL="https://$HTTPS_HOST/project/$PROJECT.git"
ISSUE_REMOTE="$PROJECT-$ISSUE"
ISSUE_SSH_URL="git@$SSH_HOST:issue/$PROJECT-$ISSUE.git"

CLONE_DIR="$WORKDIR/$PROJECT"

log_step "Issue fork setup: $PROJECT (issue #$ISSUE)"

# ---------------------------------------------------------------------------
# 1. Clone (idempotent: reuse an existing checkout of the same project).
# ---------------------------------------------------------------------------
if [[ -d "$CLONE_DIR/.git" ]]; then
  log_info "Reusing existing clone at $CLONE_DIR"
elif [[ -e "$CLONE_DIR" ]]; then
  die "Path '$CLONE_DIR' exists but is not a git checkout. Move it aside or pass a different --workdir." 1
else
  mkdir -p "$WORKDIR"
  log_info "Cloning $CLONE_URL ..."
  git clone "$CLONE_URL" "$CLONE_DIR" >&2 || die "git clone failed for $CLONE_URL. Check the project name and your network." 1
  log_ok "Cloned into $CLONE_DIR"
fi

cd "$CLONE_DIR"

# ---------------------------------------------------------------------------
# 2. Issue-fork remote (idempotent: add, or update URL if it changed).
# ---------------------------------------------------------------------------
if git remote get-url "$ISSUE_REMOTE" >/dev/null 2>&1; then
  CUR_URL="$(git remote get-url "$ISSUE_REMOTE" 2>/dev/null || true)"
  if [[ "$CUR_URL" != "$ISSUE_SSH_URL" ]]; then
    git remote set-url "$ISSUE_REMOTE" "$ISSUE_SSH_URL"
    log_info "Updated remote '$ISSUE_REMOTE' -> $ISSUE_SSH_URL"
  else
    log_info "Remote '$ISSUE_REMOTE' already configured."
  fi
else
  git remote add "$ISSUE_REMOTE" "$ISSUE_SSH_URL"
  log_ok "Added remote '$ISSUE_REMOTE' -> $ISSUE_SSH_URL"
fi

# ---------------------------------------------------------------------------
# 3. Fetch the issue remote (this is where a missing web-side fork surfaces).
# ---------------------------------------------------------------------------
log_info "Fetching '$ISSUE_REMOTE' ..."
if ! git fetch "$ISSUE_REMOTE" >&2; then
  log_warn "Could not fetch '$ISSUE_REMOTE'."
  log_plain "   The issue fork may not exist yet. On the issue page at"
  log_plain "   https://www.drupal.org/project/$PROJECT/issues/$ISSUE"
  log_plain "   click 'Create issue fork' and 'Get push access', then re-run."
  # Not fatal: the remote is configured; the user can create the fork and re-run.
fi

# ---------------------------------------------------------------------------
# 4. Branch selection / checkout (idempotent).
# ---------------------------------------------------------------------------
remote_branch_exists() { git show-ref --verify --quiet "refs/remotes/$ISSUE_REMOTE/$1"; }
local_branch_exists()  { git show-ref --verify --quiet "refs/heads/$1"; }

CHECKED_OUT=""

if [[ -n "$BASE" ]]; then
  # Track the issue remote's base-version branch (existing issue work).
  TRACK_BRANCH="${BRANCH:-$BASE}"
  if local_branch_exists "$TRACK_BRANCH"; then
    git checkout "$TRACK_BRANCH" >&2
    log_ok "Switched to existing local branch '$TRACK_BRANCH'."
  elif remote_branch_exists "$BASE"; then
    git checkout -b "$TRACK_BRANCH" --track "$ISSUE_REMOTE/$BASE" >&2
    log_ok "Created tracking branch '$TRACK_BRANCH' from $ISSUE_REMOTE/$BASE."
  else
    log_warn "Base branch '$BASE' not found on '$ISSUE_REMOTE'. Falling back to a new feature branch."
    BASE=""   # fall through to the new-branch path below
  fi
  CHECKED_OUT="$TRACK_BRANCH"
fi

if [[ -z "$CHECKED_OUT" ]]; then
  # New feature branch: ISSUEID-description (PROMPT 3.2 naming convention).
  NEW_BRANCH="${BRANCH:-$ISSUE-port-to-drupal-11}"
  if local_branch_exists "$NEW_BRANCH"; then
    git checkout "$NEW_BRANCH" >&2
    log_ok "Switched to existing branch '$NEW_BRANCH'."
  elif remote_branch_exists "$NEW_BRANCH"; then
    git checkout -b "$NEW_BRANCH" --track "$ISSUE_REMOTE/$NEW_BRANCH" >&2
    log_ok "Created tracking branch '$NEW_BRANCH' from $ISSUE_REMOTE/$NEW_BRANCH."
  else
    git checkout -b "$NEW_BRANCH" >&2
    log_ok "Created new branch '$NEW_BRANCH'."
  fi
  CHECKED_OUT="$NEW_BRANCH"
fi

# ---------------------------------------------------------------------------
# Next steps
# ---------------------------------------------------------------------------
hr
log_ok "Issue fork ready in $CLONE_DIR (branch '$CHECKED_OUT')."
log_info "Next steps:"
log_plain "   1. Make your changes, then: git add -A"
log_plain "   2. Commit with the Core format, e.g.:"
log_plain "        git commit -m \"fix: #$ISSUE One-line summary\""
log_plain "   3. Open the merge request with:"
log_plain "        scripts/contrib/open-mr.sh --project $PROJECT --issue $ISSUE --branch $CHECKED_OUT"
log_plain "   Reminder: credit is assigned by maintainers via the issue's Contribution Record."

# Machine-readable summary on STDOUT (path + branch + remote).
printf '%s\t%s\t%s\n' "$CLONE_DIR" "$CHECKED_OUT" "$ISSUE_REMOTE"
exit 0
