#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/contrib/make-patch.sh
# Generate a Drupal patch file. Two modes:
#
#   * legacy (default) — the Drupal.org contribution patch for projects that
#     have not migrated to issue forks / merge requests (PROMPT 3.3). Fetches
#     origin, rebases the current branch onto origin/BASE, and writes
#     git diff origin/BASE > MODULE-short-description-ISSUE-COMMENT.patch.
#     Gated on the `contribute` profile (git). Used by the contribute flow,
#     and ALSO run alongside the Merge Request so the issue gets an attachable
#     patch in addition to the MR.
#
#   * --local — a "test it locally / preview the port" patch. NO issue id, NO
#     network, NO rebase: it diffs the subject subtree against a detected base
#     ref (committed port changes when an upstream exists, otherwise the working
#     tree) and writes MODULE-DESCRIPTION.patch next to the module. New
#     (untracked) files are included via a throwaway index, so the patch is
#     complete without touching the developer's real git index. This is the
#     patch the port/refactor flow writes automatically at the end.
#
# Naming:
#   legacy        -> [module]-[short-description]-[issue]-[comment].patch  (PROMPT 3.3)
#   --local       -> [module]-[short-description].patch
#   --local --issue ID [--comment N]
#                 -> [module]-[short-description]-[issue]-[comment].patch — a patch
#                    NAMED for attaching to a Drupal.org issue comment, but still
#                    produced the offline --local way (no network, no rebase, no
#                    `contribute` gate). This decouples "I want a patch to attach
#                    to an issue and test locally now" from the full contribution
#                    flow: get it here, contribute the MR later.
#
# This script never pushes and NEVER touches credentials.
#
# Usage:
#   make-patch.sh --module NAME --issue ID
#                 [--comment N] [--base BASE_VERSION] [--description SLUG]
#                 [--output DIR] [--subject DIR]
#   make-patch.sh --local [--subject DIR] [--module NAME]
#                 [--base BASE_VERSION] [--description SLUG] [--output DIR]
#                 [--issue ID] [--comment N]
#
#   --module       module/theme machine name used as the filename prefix.
#                  Auto-detected from --subject when omitted.
#   --subject      module/theme directory. Sets the machine name (if --module is
#                  absent) and, in --local mode, the default --output directory.
#   --issue        numeric issue id (required unless --local).
#   --comment      issue comment number the patch will be attached to (default 1).
#   --base         base version branch to diff against (e.g. 11.x). Defaults to
#                  the upstream tracking branch, then origin/HEAD.
#   --description  short slug for the filename (default: 'port-to-drupal-11').
#   --output       directory to write the patch into. Default: the subject dir in
#                  --local mode, else the current directory.
#   --local        local/preview mode (no issue, no network, no rebase).
#
# Exit codes: 0 ok · 1 usage/error · 2 hard requirement missing (gate).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

MODULE=""
SUBJECT=""
ISSUE=""
COMMENT="1"
BASE=""
DESCRIPTION="port-to-drupal-11"
OUTPUT=""
LOCAL=0

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

# slugify <string> -> lowercase, hyphen-separated, safe for a filename.
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# patch_applies_clean <repo> <patch> <baseref>
# Verify the patch applies cleanly onto the TREE of <baseref> — i.e. onto the
# version of the module the patch refers to — exactly as a user would do before
# the change is merged. We check against a throwaway index seeded from <baseref>
# (git apply --cached --check), so the working tree is never touched.
# Returns 0 if it applies, 1 if it does not, 2 if the base could not be read.
patch_applies_clean() {
  local repo="$1" patch="$2" baseref="$3" idx rc
  idx="$(mktemp "${TMPDIR:-/tmp}/drupilot-verify.XXXXXX")"
  if ! GIT_INDEX_FILE="$idx" git -C "$repo" read-tree "$baseref" 2>/dev/null; then
    rm -f "$idx"; return 2
  fi
  GIT_INDEX_FILE="$idx" git -C "$repo" apply --cached --check "$patch" >/dev/null 2>&1
  rc=$?
  rm -f "$idx"
  return "$rc"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module) MODULE="${2:-}"; shift 2;;
    --module=*) MODULE="${1#*=}"; shift;;
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
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
    --local) LOCAL=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

# Resolve the machine name from the subject dir when --module is not given. In
# --local mode the subject defaults to the current directory, so an empty/omitted
# --subject still detects the module from where we are.
DETECT_DIR="$SUBJECT"
[[ -z "$DETECT_DIR" && "$LOCAL" == "1" ]] && DETECT_DIR="$PWD"
if [[ -z "$MODULE" && -n "$DETECT_DIR" ]]; then
  MODULE="$(subject_machine_name "$DETECT_DIR" 2>/dev/null || true)"
fi
[[ -n "$MODULE" ]] || die "Missing --module NAME (or pass --subject DIR to detect it)." 1

have_cmd git || die "git is not installed." 1

MODULE_SLUG="$(slugify "$MODULE")"
DESC_SLUG="$(slugify "$DESCRIPTION")"
[[ -n "$DESC_SLUG" ]] || DESC_SLUG="patch"

# =============================================================================
# LOCAL / PREVIEW MODE — offline diff of the port, no issue, no rebase.
# =============================================================================
if [[ "$LOCAL" == "1" ]]; then
  # Where is the subject? Default to the current directory.
  SUBJ_DIR="${SUBJECT:-$PWD}"
  [[ -d "$SUBJ_DIR" ]] || die "Subject directory not found: $SUBJ_DIR" 1

  # The local patch only needs git — no SSH/PAT, no `contribute` gate. If the
  # subject is not under version control we cannot produce a reliable diff, so
  # we warn and exit 0 (fail-safe: never break the surrounding port flow).
  if ! git -C "$SUBJ_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_warn "The local patch needs the module to be under git version control."
    log_warn "'$SUBJ_DIR' is not inside a git checkout — skipping patch generation."
    exit 0
  fi

  REPO="$(git -C "$SUBJ_DIR" rev-parse --show-toplevel 2>/dev/null)"
  [[ -n "$REPO" ]] || die "Could not resolve the git repository root for $SUBJ_DIR" 1
  # Path of the subject relative to the repo root (trailing slash, empty at root).
  RELPREFIX="$(git -C "$SUBJ_DIR" rev-parse --show-prefix 2>/dev/null || true)"
  PATHSPEC="${RELPREFIX:-.}"

  # Output: default next to the module.
  [[ -n "$OUTPUT" ]] || OUTPUT="$SUBJ_DIR"
  mkdir -p "$OUTPUT"
  OUTPUT_ABS="$(cd "$OUTPUT" && pwd)"

  # Naming: a bare --local patch is named for local testing; passing --issue (and
  # optionally --comment) names it with the Drupal.org issue-comment convention so
  # it is ready to ATTACH to an issue — while still being produced the offline way.
  if [[ -n "$ISSUE" ]]; then
    [[ "$ISSUE" =~ ^[0-9]+$ ]] || die "Issue id must be numeric: '$ISSUE'" 1
    [[ "$COMMENT" =~ ^[0-9]+$ ]] || die "Comment number must be numeric: '$COMMENT'" 1
    PATCH_NAME="$MODULE_SLUG-$DESC_SLUG-$ISSUE-$COMMENT.patch"
  else
    PATCH_NAME="$MODULE_SLUG-$DESC_SLUG.patch"
  fi
  PATCH_PATH="$OUTPUT_ABS/$PATCH_NAME"

  if [[ -n "$ISSUE" ]]; then
    log_step "Local patch for issue #$ISSUE (comment #$COMMENT): $MODULE — offline, no push, scoped to $PATHSPEC"
  else
    log_step "Local patch: $MODULE (preview of the port, scoped to $PATHSPEC)"
  fi

  # Resolve the base ref WITHOUT touching the network or the working tree.
  BASE_REF=""
  if [[ -n "$BASE" ]]; then
    if git -C "$REPO" rev-parse --verify --quiet "origin/$BASE" >/dev/null 2>&1; then
      BASE_REF="origin/$BASE"
    elif git -C "$REPO" rev-parse --verify --quiet "$BASE" >/dev/null 2>&1; then
      BASE_REF="$BASE"
    else
      die "Base '$BASE' not found locally (tried origin/$BASE and $BASE). Pass an existing --base." 1
    fi
  else
    UPSTREAM="$(git -C "$REPO" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
    if [[ -n "$UPSTREAM" ]]; then
      BASE_REF="$UPSTREAM"
    else
      DEF="$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
      if [[ -n "$DEF" ]]; then BASE_REF="$DEF"; else BASE_REF="HEAD"; fi
    fi
  fi
  log_info "Diffing against base '$BASE_REF' (no fetch, no rebase)."

  # Build the diff in a throwaway index so untracked (new) files are included
  # without mutating the developer's real git index.
  TMP_INDEX="$(mktemp "${TMPDIR:-/tmp}/drupilot-index.XXXXXX")"
  cleanup_index() { rm -f "$TMP_INDEX"; }
  trap cleanup_index EXIT
  if ! GIT_INDEX_FILE="$TMP_INDEX" git -C "$REPO" read-tree HEAD 2>/dev/null; then
    # No HEAD yet (unborn branch): start from an empty index.
    GIT_INDEX_FILE="$TMP_INDEX" git -C "$REPO" read-tree --empty 2>/dev/null || true
  fi
  # Exclude the patch file itself AND drupilot's own artifacts (the .drupilot/
  # outputs dir, the .drupilot.json prefs, any previously-written drupilot patch)
  # so a contribution patch never embeds them. The subject is often its OWN git
  # repo (a loose contrib checkout keeps its .git after a move), which the Drupal
  # root's .gitignore does not cover — so we exclude them here regardless.
  EXCLUDES=(
    ":(exclude)${RELPREFIX}${PATCH_NAME}"
    ":(exclude)${RELPREFIX}.drupilot"
    ":(exclude)${RELPREFIX}.drupilot.json"
    ":(exclude)${RELPREFIX}*-port-to-drupal-11.patch"
    ":(exclude)${RELPREFIX}*-port-to-drupal-11-*.patch"
  )
  GIT_INDEX_FILE="$TMP_INDEX" git -C "$REPO" add -A -- "$PATHSPEC" "${EXCLUDES[@]}" 2>/dev/null || true

  if ! GIT_INDEX_FILE="$TMP_INDEX" git -C "$REPO" diff --cached "$BASE_REF" -- "$PATHSPEC" "${EXCLUDES[@]}" > "$PATCH_PATH" 2>/dev/null; then
    rm -f "$PATCH_PATH"
    die "git diff against $BASE_REF failed." 1
  fi

  if [[ ! -s "$PATCH_PATH" ]]; then
    rm -f "$PATCH_PATH"
    log_warn "No differences against $BASE_REF — nothing to patch yet."
    exit 0
  fi

  # Sanity-check that the preview applies onto the base. Warn-only here: the
  # local patch is best-effort and must never break the surrounding port flow.
  if ! patch_applies_clean "$REPO" "$PATCH_PATH" "$BASE_REF"; then
    log_warn "Heads-up: this preview patch does not apply cleanly onto '$BASE_REF'."
    log_warn "It is still written for inspection, but check your base ref before sharing it."
  fi

  announce_patch "$PATCH_PATH"
  if [[ -n "$ISSUE" ]]; then
    log_info "Named for Drupal.org issue #$ISSUE, comment #$COMMENT — attach it there to share/test the fix."
    log_info "This is the OFFLINE patch (no rebase against origin/BASE). When you are ready to open a"
    log_info "Merge Request, run /drupilot-contribute, which also produces the merge-verified patch."
  else
    log_info "Preview of the port for testing locally. For an issue-comment-named patch: add --issue ID."
    log_info "To open a Merge Request later, run /drupilot-contribute (it produces the merge-verified patch)."
  fi

  # Machine-readable: the patch path on STDOUT.
  printf '%s\n' "$PATCH_PATH"
  exit 0
fi

# =============================================================================
# LEGACY / CONTRIBUTION MODE — rebase onto origin/BASE, diff, issue+comment name.
# =============================================================================
[[ -n "$ISSUE" ]]  || die "Missing --issue ID (or pass --local for a preview patch)." 1
[[ "$ISSUE" =~ ^[0-9]+$ ]] || die "Issue id must be numeric: '$ISSUE'" 1
[[ "$COMMENT" =~ ^[0-9]+$ ]] || die "Comment number must be numeric: '$COMMENT'" 1

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

PATCH_NAME="$MODULE_SLUG-$DESC_SLUG-$ISSUE-$COMMENT.patch"
[[ -n "$OUTPUT" ]] || OUTPUT="$PWD"
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

# ---------------------------------------------------------------------------
# 3. Verify the patch applies cleanly onto the version it targets (origin/BASE).
#    A contribution patch is meant to be applied by users before the MR is
#    merged, so a patch that does not apply is unusable: this is a HARD gate —
#    we do NOT emit a broken patch.
# ---------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
if patch_applies_clean "$REPO_ROOT" "$PATCH_PATH" "$BASE_REF"; then
  log_ok "Verified: the patch applies cleanly onto '$BASE_REF'."
else
  rm -f "$PATCH_PATH"
  log_err "The generated patch does NOT apply cleanly onto '$BASE_REF'."
  log_err "A contribution patch must apply onto the version it targets so users can"
  log_err "test the fix before the MR is merged. The broken patch was discarded."
  log_plain "   Re-fetch and rebase the branch onto the correct base, then re-run:"
  log_plain "     git fetch origin && git rebase $BASE_REF"
  exit 1
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
