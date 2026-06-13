#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/contrib/make-patch.sh
# Legacy Drupal.org contribution flow: generate a patch file for projects that
# have not migrated to issue forks / merge requests (PROMPT 3.3).
#
# Flow:
#   1. Fetch origin and rebase the current branch onto origin/BASE.
#   2. git diff origin/BASE > MODULE-short-description-ISSUE-COMMENT.patch
#
# Naming convention (PROMPT 3.3): [module]-[short-description]-[issue]-[comment].patch
# This does NOT push and NEVER touches credentials.
#
# Usage:
#   make-patch.sh --module NAME --issue ID
#                 [--comment N] [--base BASE_VERSION] [--description SLUG]
#                 [--output DIR]
#
#   --module       module/theme machine name used as the filename prefix.
#   --issue        numeric issue id.
#   --comment      issue comment number the patch will be attached to (default 1).
#   --base         base version branch to diff against (e.g. 11.x). Defaults to
#                  the upstream tracking branch, then origin/HEAD.
#   --description  short slug for the filename (default: 'port-to-drupal-11').
#   --output       directory to write the patch into (default: current dir).
#
# Exit codes: 0 ok · 1 usage/error · 2 hard requirement missing (gate).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

MODULE=""
ISSUE=""
COMMENT="1"
BASE=""
DESCRIPTION="port-to-drupal-11"
OUTPUT="$PWD"

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

# slugify <string> -> lowercase, hyphen-separated, safe for a filename.
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module) MODULE="${2:-}"; shift 2;;
    --module=*) MODULE="${1#*=}"; shift;;
    --issue) ISSUE="${2:-}"; shift 2;;
    --issue=*) ISSUE="${1#*=}"; shift;;
    --comment) COMMENT="${2:-}"; shift 2;;
    --comment=*) COMMENT="${1#*=}"; shift;;
    --base) BASE="${2:-}"; shift 2;;
    --base=*) BASE="${1#*=}"; shift;;
    --description) DESCRIPTION="${2:-}"; shift 2;;
    --description=*) DESCRIPTION="${1#*=}"; shift;;
    --output) OUTPUT="${2:-}"; shift 2;;
    --output=*) OUTPUT="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

[[ -n "$MODULE" ]] || die "Missing --module NAME" 1
[[ -n "$ISSUE" ]]  || die "Missing --issue ID" 1
[[ "$ISSUE" =~ ^[0-9]+$ ]] || die "Issue id must be numeric: '$ISSUE'" 1
[[ "$COMMENT" =~ ^[0-9]+$ ]] || die "Comment number must be numeric: '$COMMENT'" 1

have_cmd git || die "git is not installed." 1
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "Not inside a git checkout. cd into the project clone first." 1

# ---------------------------------------------------------------------------
# Gate: contribution requirements (git is the hard one for the patch flow).
# ---------------------------------------------------------------------------
PREFLIGHT="$(plugin_root)/scripts/env/preflight.sh"
if [[ -r "$PREFLIGHT" ]]; then
  if ! bash "$PREFLIGHT" --profile contribute --quiet >&2; then
    log_err "Contribution requirements are not met. Run /drupilot-doctor or scripts/contrib/check-prereqs.sh first."
    exit 2
  fi
fi

MODULE_SLUG="$(slugify "$MODULE")"
DESC_SLUG="$(slugify "$DESCRIPTION")"
[[ -n "$DESC_SLUG" ]] || DESC_SLUG="patch"

PATCH_NAME="$MODULE_SLUG-$DESC_SLUG-$ISSUE-$COMMENT.patch"
mkdir -p "$OUTPUT"
# Resolve to an absolute output path so the diff lands where the user expects.
OUTPUT_ABS="$(cd "$OUTPUT" && pwd)"
PATCH_PATH="$OUTPUT_ABS/$PATCH_NAME"

log_step "Legacy patch: $MODULE issue #$ISSUE (comment #$COMMENT)"

# ---------------------------------------------------------------------------
# 1. Resolve the base ref and rebase onto it (PROMPT 3.3).
# ---------------------------------------------------------------------------
if ! git fetch origin >&2; then
  die "git fetch origin failed. Check your network and remote configuration." 1
fi

# Determine the base ref: explicit --base, else the upstream of the current
# branch, else origin/HEAD's default branch.
BASE_REF=""
if [[ -n "$BASE" ]]; then
  BASE_REF="origin/$BASE"
  git show-ref --verify --quiet "refs/remotes/$BASE_REF" \
    || die "origin/$BASE not found. Pass the correct --base (e.g. 11.x, 2.0.x)." 1
else
  UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [[ -n "$UPSTREAM" ]]; then
    BASE_REF="$UPSTREAM"
  else
    DEF="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    [[ -n "$DEF" ]] && BASE_REF="$DEF"
  fi
  [[ -n "$BASE_REF" ]] || die "Could not determine a base branch. Pass --base BASE_VERSION explicitly." 1
  log_info "No --base given; diffing against detected base '$BASE_REF'."
fi

log_info "Rebasing onto $BASE_REF ..."
if ! git rebase "$BASE_REF" >&2; then
  git rebase --abort >/dev/null 2>&1 || true
  log_err "Rebase onto $BASE_REF hit conflicts and was aborted. Resolve manually, then re-run."
  exit 1
fi
log_ok "Rebased onto $BASE_REF."

# ---------------------------------------------------------------------------
# 2. Produce the patch (idempotent: overwrite an existing file of the same name).
# ---------------------------------------------------------------------------
if [[ -f "$PATCH_PATH" ]]; then
  log_info "Overwriting existing $PATCH_NAME"
fi

if ! git diff "$BASE_REF" > "$PATCH_PATH"; then
  rm -f "$PATCH_PATH"
  die "git diff against $BASE_REF failed." 1
fi

if [[ ! -s "$PATCH_PATH" ]]; then
  rm -f "$PATCH_PATH"
  log_warn "No differences against $BASE_REF — nothing to patch. Did you commit your changes?"
  exit 0
fi

hr
log_ok "Patch written: $PATCH_PATH"
log_info "Next steps:"
log_plain "   1. Attach $PATCH_NAME to the issue, add a comment describing the change,"
log_plain "      and set the status to 'Needs review':"
log_plain "        https://www.drupal.org/project/$MODULE/issues/$ISSUE"
log_plain "   2. Bump the --comment number for each new revision you upload."
log_warn "Credit reminder: maintainers assign credit via the issue's Contribution Record."

# Machine-readable: the patch path on STDOUT.
printf '%s\n' "$PATCH_PATH"
exit 0
