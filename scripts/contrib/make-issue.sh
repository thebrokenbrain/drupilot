#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/contrib/make-issue.sh
# Generate the Drupal.org "paperwork" for contributing a port (PROMPT 3):
#
#   1. The issue *summary* (rendered from templates/issue-summary.md.tmpl),
#      port-tuned and omitting the sections that do not apply to a
#      behavior-preserving port (Steps to reproduce, UI/API/Data model changes).
#   2. The recommended values for the issue's mandatory *fields* — Title,
#      Category, Priority, Version, Component, Assignee — from the DRUPILOT_ISSUE_*
#      config defaults (env-overridable), with Version derived from --base.
#   3. The short *comment* (templates/issue-comment.md.tmpl) to post when the MR
#      is opened (also usable as the MR description and as the legacy patch
#      comment), referencing the attached .patch.
#
# The Drupal.org issue is created on the WEB (there is no public issue API, and
# the GitLab API is blocked by default), so this script does NOT submit anything
# and needs no credentials or network — it produces ready-to-paste content.
#
# Outputs two files next to the module (or into --output):
#   <module>-issue-summary.md   and   <module>-issue-comment.md
# and prints the recommended field values to stderr. With --json it prints a
# single JSON object on stdout instead.
#
# Usage:
#   make-issue.sh --project NAME [--subject DIR] [--base BASE_VERSION]
#                 [--issue ID] [--comment N] [--description SLUG]
#                 [--patch-name FILE] [--kind mr|patch]
#                 [--title T] [--summary T]
#                 [--problem T] [--resolution T] [--remaining T]
#                 [--output DIR] [--json]
#
#   --project      drupal.org project machine name. Auto-detected from --subject.
#   --subject      module/theme dir (detects the name and the default --output).
#   --base         base version branch (e.g. 4.0.x, 11.x). Drives the Version
#                  field (4.0.x -> 4.0.x-dev) and the comment's apply target.
#   --issue        numeric issue id (for the tracking URL and the patch name).
#   --comment      patch comment number, for the derived patch name (default 1).
#   --description  patch description slug (default 'port-to-drupal-11').
#   --patch-name   explicit patch filename to reference (overrides the derived).
#   --kind         'mr' (default) or 'patch' — wording in the comment.
#   --title        issue title (default: DRUPILOT_ISSUE_TITLE).
#   --summary      one/two-line summary of what the port did (comment body).
#   --problem      Problem/Motivation prose (default: a generic port rationale).
#   --resolution   Proposed resolution prose (default: the minimal-port steps).
#   --remaining    Remaining tasks prose (default: review/test/merge/credit).
#   --d10-unverified  append a "verify Drupal 10 compatibility" item to Remaining
#                  tasks (use when keeping '^10 || ^11' without verifying it).
#   --output       directory for the generated files (default: subject dir/cwd).
#   --json         emit a JSON object on stdout instead of the human report.
#
# Exit codes: 0 ok · 1 usage/error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PROJECT=""
SUBJECT=""
BASE=""
ISSUE=""
COMMENT="1"
DESCRIPTION="port-to-drupal-11"
PATCH_NAME=""
KIND="mr"
TITLE=""
SUMMARY=""
PROBLEM=""
RESOLUTION=""
REMAINING=""
D10_UNVERIFIED=0
OUTPUT=""
JSON=0

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2;;
    --project=*) PROJECT="${1#*=}"; shift;;
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --base) BASE="${2:-}"; shift 2;;
    --base=*) BASE="${1#*=}"; shift;;
    --issue) ISSUE="${2:-}"; shift 2;;
    --issue=*) ISSUE="${1#*=}"; shift;;
    --comment) COMMENT="${2:-}"; shift 2;;
    --comment=*) COMMENT="${1#*=}"; shift;;
    --description) DESCRIPTION="${2:-}"; shift 2;;
    --description=*) DESCRIPTION="${1#*=}"; shift;;
    --patch-name) PATCH_NAME="${2:-}"; shift 2;;
    --patch-name=*) PATCH_NAME="${1#*=}"; shift;;
    --kind) KIND="${2:-}"; shift 2;;
    --kind=*) KIND="${1#*=}"; shift;;
    --title) TITLE="${2:-}"; shift 2;;
    --title=*) TITLE="${1#*=}"; shift;;
    --summary) SUMMARY="${2:-}"; shift 2;;
    --summary=*) SUMMARY="${1#*=}"; shift;;
    --problem) PROBLEM="${2:-}"; shift 2;;
    --problem=*) PROBLEM="${1#*=}"; shift;;
    --resolution) RESOLUTION="${2:-}"; shift 2;;
    --resolution=*) RESOLUTION="${1#*=}"; shift;;
    --remaining) REMAINING="${2:-}"; shift 2;;
    --remaining=*) REMAINING="${1#*=}"; shift;;
    --d10-unverified) D10_UNVERIFIED=1; shift;;
    --output) OUTPUT="${2:-}"; shift 2;;
    --output=*) OUTPUT="${1#*=}"; shift;;
    --json) JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

# Resolve the project machine name from the subject dir when not given.
DETECT_DIR="${SUBJECT:-$PWD}"
if [[ -z "$PROJECT" ]]; then
  PROJECT="$(subject_machine_name "$DETECT_DIR" 2>/dev/null || true)"
fi
[[ -n "$PROJECT" ]] || die "Missing --project NAME (or pass --subject DIR to detect it)." 1

case "$KIND" in
  mr)    KIND_TEXT="merge request";;
  patch) KIND_TEXT="patch";;
  *) die "Invalid --kind '$KIND' (use mr|patch)." 1;;
esac
[[ -z "$ISSUE" || "$ISSUE" =~ ^[0-9]+$ ]] || die "Issue id must be numeric: '$ISSUE'" 1
[[ "$COMMENT" =~ ^[0-9]+$ ]] || die "Comment number must be numeric: '$COMMENT'" 1

MODULE_SLUG="$(slugify "$PROJECT")"

# ---------------------------------------------------------------------------
# Recommended field values (DRUPILOT_ISSUE_* defaults; env overrides win).
# ---------------------------------------------------------------------------
[[ -n "$TITLE" ]] || TITLE="$(config_get DRUPILOT_ISSUE_TITLE "Drupal 11 compatibility")"
CATEGORY="$(config_get DRUPILOT_ISSUE_CATEGORY "Task")"
PRIORITY="$(config_get DRUPILOT_ISSUE_PRIORITY "Normal")"
COMPONENT="$(config_get DRUPILOT_ISSUE_COMPONENT "Code")"
ASSIGNEE_RAW="$(config_get DRUPILOT_ISSUE_ASSIGNEE "self")"
if [[ "${ASSIGNEE_RAW,,}" == "self" ]]; then
  ASSIGNEE="Yourself (the account opening the issue)"
else
  ASSIGNEE="$ASSIGNEE_RAW"
fi

# Version is derived from the base branch: 4.0.x -> 4.0.x-dev.
if [[ -n "$BASE" ]]; then
  VERSION="${BASE%-dev}-dev"
else
  VERSION="(set to the project's current Drupal 11 dev branch, e.g. 4.0.x-dev)"
fi

# Patch name referenced by the comment.
if [[ -z "$PATCH_NAME" ]]; then
  DESC_SLUG="$(slugify "$DESCRIPTION")"; [[ -n "$DESC_SLUG" ]] || DESC_SLUG="patch"
  if [[ -n "$ISSUE" ]]; then
    PATCH_NAME="$MODULE_SLUG-$DESC_SLUG-$ISSUE-$COMMENT.patch"
  else
    PATCH_NAME="$MODULE_SLUG-$DESC_SLUG.patch"
  fi
fi

# Tracking issue URL.
if [[ -n "$ISSUE" ]]; then
  ISSUE_URL="https://www.drupal.org/project/$PROJECT/issues/$ISSUE"
else
  ISSUE_URL="https://www.drupal.org/project/$PROJECT/issues (the issue you create)"
fi

# Comment apply-target wording.
if [[ -n "$BASE" ]]; then
  BASE_TEXT="$BASE"
else
  BASE_TEXT="the project's Drupal 11 dev branch"
fi

# ---------------------------------------------------------------------------
# Default prose (accurate for a Phase 1 minimal port; override via flags).
# ---------------------------------------------------------------------------
[[ -n "$PROBLEM" ]] || PROBLEM="\`$PROJECT\` is not yet compatible with Drupal 11. It uses APIs that were deprecated in Drupal 10 and removed in Drupal 11, and/or its \`*.info.yml\` \`core_version_requirement\` does not allow \`^11\`, so it cannot be installed or run on a Drupal 11 site."

[[ -n "$RESOLUTION" ]] || RESOLUTION="Make \`$PROJECT\` Drupal 11 compatible with the smallest possible change, preserving its current behavior:

- Apply the automated \`drupal-rector\` fixes for the removed/deprecated APIs.
- Update \`core_version_requirement\` to allow \`^11\` (keeping \`^10\` where the code stays backwards compatible).
- Apply the remaining mechanical fixes Rector cannot make (Twig, CKEditor 5, jQuery UI, Symfony 7 where applicable).

This is a Phase 1 minimal port: no architectural refactoring and no behavior change."

[[ -n "$REMAINING" ]] || REMAINING="- [ ] Review the $KIND_TEXT.
- [ ] Run the test suite on Drupal 11.
- [ ] Maintainer review and merge.
- [ ] Assign credit in the Contribution Record."

# When '^10 || ^11' is declared without verifying Drupal 10, make that an explicit
# task so the dual-support claim is not silently trusted.
if [[ "$D10_UNVERIFIED" == "1" ]]; then
  REMAINING="$REMAINING
- [ ] Verify Drupal 10 compatibility (install on a Drupal 10 site, or run the suite against Drupal 10) — the '^10 || ^11' support is declared but not verified."
fi

[[ -n "$SUMMARY" ]] || SUMMARY="It applies the automated \`drupal-rector\` fixes plus the minimal manual changes required for Drupal 11, and updates \`core_version_requirement\` accordingly."

# ---------------------------------------------------------------------------
# Render the templates. Tokens come from exported env vars; a literal,
# index-based substitution avoids any special-character pitfalls and supports
# multi-line values.
# ---------------------------------------------------------------------------
render() {  # render <template_file>
  awk '
    function repl(s, tok, val,   p) {
      p = index(s, tok)
      while (p > 0) { s = substr(s, 1, p - 1) val substr(s, p + length(tok)); p = index(s, tok) }
      return s
    }
    /^[[:space:]]*<!--/ { skip = 1 }            # drop the leading HTML comment
    skip { if ($0 ~ /-->/) skip = 0; next }
    {
      line = $0
      line = repl(line, "{{PROJECT}}",            ENVIRON["T_PROJECT"])
      line = repl(line, "{{PROBLEM_MOTIVATION}}",  ENVIRON["T_PROBLEM"])
      line = repl(line, "{{PROPOSED_RESOLUTION}}", ENVIRON["T_RESOLUTION"])
      line = repl(line, "{{REMAINING_TASKS}}",     ENVIRON["T_REMAINING"])
      line = repl(line, "{{KIND}}",                ENVIRON["T_KIND"])
      line = repl(line, "{{SUMMARY}}",             ENVIRON["T_SUMMARY"])
      line = repl(line, "{{PATCH_NAME}}",          ENVIRON["T_PATCH_NAME"])
      line = repl(line, "{{BASE}}",                ENVIRON["T_BASE"])
      line = repl(line, "{{ISSUE_URL}}",           ENVIRON["T_ISSUE_URL"])
      print line
    }
  ' "$1"
}

export T_PROJECT="$PROJECT" T_PROBLEM="$PROBLEM" T_RESOLUTION="$RESOLUTION" \
       T_REMAINING="$REMAINING" T_KIND="$KIND_TEXT" T_SUMMARY="$SUMMARY" \
       T_PATCH_NAME="$PATCH_NAME" T_BASE="$BASE_TEXT" T_ISSUE_URL="$ISSUE_URL"

TPL_DIR="$(plugin_root)/templates"
SUMMARY_TPL="$TPL_DIR/issue-summary.md.tmpl"
COMMENT_TPL="$TPL_DIR/issue-comment.md.tmpl"
[[ -r "$SUMMARY_TPL" ]] || die "Template not found: $SUMMARY_TPL" 1
[[ -r "$COMMENT_TPL" ]] || die "Template not found: $COMMENT_TPL" 1

SUMMARY_BODY="$(render "$SUMMARY_TPL")"
COMMENT_BODY="$(render "$COMMENT_TPL")"

# ---------------------------------------------------------------------------
# Write the artifacts.
# ---------------------------------------------------------------------------
if [[ -z "$OUTPUT" ]]; then
  if [[ -n "$SUBJECT" && -d "$SUBJECT" ]]; then OUTPUT="$SUBJECT"; else OUTPUT="$PWD"; fi
fi
mkdir -p "$OUTPUT"
OUTPUT_ABS="$(cd "$OUTPUT" && pwd)"
SUMMARY_FILE="$OUTPUT_ABS/$MODULE_SLUG-issue-summary.md"
COMMENT_FILE="$OUTPUT_ABS/$MODULE_SLUG-issue-comment.md"
printf '%s\n' "$SUMMARY_BODY" > "$SUMMARY_FILE"
printf '%s\n' "$COMMENT_BODY" > "$COMMENT_FILE"

# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------
if [[ "$JSON" == "1" ]]; then
  jq -n \
    --arg title "$TITLE" --arg category "$CATEGORY" --arg priority "$PRIORITY" \
    --arg version "$VERSION" --arg component "$COMPONENT" --arg assignee "$ASSIGNEE" \
    --arg summary_file "$SUMMARY_FILE" --arg comment_file "$COMMENT_FILE" \
    --arg summary "$SUMMARY_BODY" --arg comment "$COMMENT_BODY" \
    '{fields: {title:$title, category:$category, priority:$priority,
               version:$version, component:$component, assignee:$assignee},
      summary_file:$summary_file, comment_file:$comment_file,
      summary:$summary, comment:$comment}'
  exit 0
fi

log_step "Issue paperwork for $PROJECT"
hr
log_info "Recommended issue fields (the issue is created on the web; paste these):"
log_plain "   Title:     $TITLE"
log_plain "   Category:  $CATEGORY"
log_plain "   Priority:  $PRIORITY"
log_plain "   Version:   $VERSION"
log_plain "   Component: $COMPONENT   (verify against this project's own component list)"
log_plain "   Assignee:  $ASSIGNEE"
hr
log_ok "Issue summary written: $SUMMARY_FILE"
log_ok "Issue/MR comment written: $COMMENT_FILE"
log_info "Paste the summary into the issue's 'Issue summary' field, and use the"
log_info "comment when you open the merge request (it references the .patch)."
log_warn "Credit reminder: maintainers assign credit via the issue's Contribution Record."

# Machine-readable: the two file paths on STDOUT (tab-separated).
printf '%s\t%s\n' "$SUMMARY_FILE" "$COMMENT_FILE"
exit 0
