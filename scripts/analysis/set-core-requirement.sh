#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/set-core-requirement.sh
# Set core_version_requirement in EVERY *.info.yml of a subject: the main one
# and each submodule (modules/*, themes/*, ... nested at any depth), so a
# submodule is not left on an obsolete constraint (`^8.8 || ^9 || ^10`) that
# Drupal 11 refuses to install. Test modules (under tests/) are bumped only
# when their current constraint does not admit Drupal 11 (they would break the
# suite on Drupal 11); a test module with `package: Testing` and no key is
# exempt in core and left alone. The obsolete `core: 8.x` key is removed.
# Idempotent: a file already at the requirement is reported `unchanged`.
#
# Usage:
#   set-core-requirement.sh --subject DIR --requirement CONSTRAINT
#                           [--no-tests] [--dry-run] [--json] [-h|--help]
#
# Options:
#   --subject DIR             The module/theme directory. Required.
#   --requirement CONSTRAINT  The value to set, e.g. '^10 || ^11' (the
#                             recommended_core_version_requirement of
#                             core-strategy.sh). Required.
#   --no-tests                Never touch info files under tests/.
#   --dry-run                 Report what would change; write nothing.
#   --json                    Print a JSON report on STDOUT:
#                             {subject, requirement, dry_run, changed,
#                              files:[{file, role: main|submodule|test,
#                                      from, to, action:
#                                      updated|added|unchanged|skipped,
#                                      removed_core_key, reason}]}
#   -h, --help                Show this help.
#
# Without --json, STDOUT lists the changed files (one relative path per line).
# Exit codes: 0 ok · 1 usage error or a file could not be written.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
REQ=""
NO_TESTS=0
DRY=0
AS_JSON=0

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --requirement) REQ="${2:-}"; shift 2 || die "--requirement needs a value" 1;;
    --requirement=*) REQ="${1#*=}"; shift;;
    --no-tests) NO_TESTS=1; shift;;
    --dry-run) DRY=1; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_err "Unknown argument: $1"; usage >&2; exit 1;;
  esac
done

[[ -n "$SUBJECT" ]] || die "Missing --subject DIR." 1
[[ -n "$REQ" ]] || die "Missing --requirement CONSTRAINT (e.g. '^10 || ^11')." 1
case "$SUBJECT$REQ" in *"<"*">"*) die "An argument looks like an unsubstituted placeholder." 1;; esac
[[ -d "$SUBJECT" ]] || die "Subject directory not found: $SUBJECT" 1
have_cmd jq || die "jq is required for set-core-requirement.sh." 1
REQ="$(trim "$(printf '%s' "$REQ" | tr -d "\"'")")"
core_requirement_admits "$REQ" 10 || core_requirement_admits "$REQ" 11 \
  || die "'$REQ' admits neither Drupal 10 nor 11: refusing to write it." 1
SUBJECT="$(cd "$SUBJECT" && pwd)"
MAIN="$(subject_info_file "$SUBJECT" 2>/dev/null || true)"
[[ -n "$MAIN" ]] || die "No *.info.yml in $SUBJECT: not a Drupal extension directory." 1

ROWS=()
CHANGED=()
# The value is written unquoted, as core and drupal.org write it.
while IFS= read -r rel; do
  f="$SUBJECT/$rel"
  role="submodule"
  [[ "$f" == "$MAIN" ]] && role="main"
  case "/$rel" in */tests/*) role="test";; esac
  [[ "$role" == "test" && "$NO_TESTS" == "1" ]] && continue
  cur="$(info_yml_value "$f" core_version_requirement)"
  pkg="$(info_yml_value "$f" package)"
  has_core_key=0
  grep -qE '^core:[[:space:]]' "$f" 2>/dev/null && has_core_key=1
  action="updated"; reason=""
  if [[ "$role" == "test" ]]; then
    if [[ -z "$cur" && "$pkg" == "Testing" ]]; then
      action="skipped"; reason="test module in package Testing: exempt from core_version_requirement"
    elif [[ -n "$cur" ]] && core_requirement_admits "$cur" 11; then
      action="skipped"; reason="test module already admits Drupal 11"
    fi
  fi
  if [[ "$action" != "skipped" ]]; then
    if [[ "$cur" == "$REQ" && "$has_core_key" == "0" ]] && grep -qE '^core_version_requirement:[[:space:]]*[^[:space:]"'"'"']' "$f"; then
      action="unchanged"
    elif [[ -z "$cur" ]] && ! grep -qE '^core_version_requirement:' "$f"; then
      action="added"
    fi
  fi
  rm_core=false
  if [[ "$action" == "updated" || "$action" == "added" ]]; then
    [[ "$has_core_key" == "1" ]] && rm_core=true
    if [[ "$DRY" == "0" ]]; then
      tmp="$(mktemp "${f}.XXXXXX")" || die "Cannot write next to $f" 1
      if AWKV_r="$REQ" AWKV_a="$action" awk '
           BEGIN { r = ENVIRON["AWKV_r"]; add = (ENVIRON["AWKV_a"] == "added"); done = 0 }
           /^core:[ \t]/ { next }
           /^core_version_requirement:/ { print "core_version_requirement: " r; done = 1; next }
           { print }
           add && !done && /^type:/ { print "core_version_requirement: " r; done = 1 }
           END { if (add && !done) print "core_version_requirement: " r }' "$f" > "$tmp" \
         && cat "$tmp" > "$f"; then
        rm -f "$tmp"
      else
        rm -f "$tmp"; die "Could not update $f" 1
      fi
    fi
    CHANGED+=("$rel")
  fi
  ROWS+=("$(jq -nc --arg file "$rel" --arg role "$role" --arg from "$cur" --arg to "$REQ" --arg action "$action" \
    --argjson rmc "$rm_core" --arg reason "$reason" \
    '{file: $file, role: $role, from: (if $from == "" then null else $from end),
      to: (if $action == "skipped" then null else $to end), action: $action,
      removed_core_key: $rmc, reason: (if $reason == "" then null else $reason end)}')")
done < <(cd "$SUBJECT" && find . \( -name .git -o -name vendor -o -name node_modules -o -name .ddev -o -name .drupilot \) -prune \
           -o -type f -name '*.info.yml' -print 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort)

REPORT="$(printf '%s\n' "${ROWS[@]+"${ROWS[@]}"}" | jq -s --arg s "$SUBJECT" --arg r "$REQ" --argjson dry "$([[ "$DRY" == "1" ]] && echo true || echo false)" \
  '{subject: $s, requirement: $r, dry_run: $dry,
    changed: ([.[] | select(.action == "updated" or .action == "added" or .removed_core_key)] | length),
    files: .}')"

printf '%s' "$REPORT" | jq -r '.files[] | "  \(if .action == "updated" or .action == "added" then "✎" elif .action == "unchanged" then "=" else "·" end) \(.file) [\(.role)]: \(.from // "(none)") -> \(.to // "(left as is)")\(if .removed_core_key then ", removed core: 8.x" else "" end)\(if .reason then " (" + .reason + ")" else "" end)"' >&2
if [[ "$DRY" == "1" ]]; then
  log_info "Dry run: nothing written."
else
  log_ok "core_version_requirement: $REQ in $(printf '%s' "$REPORT" | jq '.changed') file(s) changed."
fi

if [[ "$AS_JSON" == "1" ]]; then
  printf '%s\n' "$REPORT"
else
  [[ ${#CHANGED[@]} -eq 0 ]] || printf '%s\n' "${CHANGED[@]}"
fi
exit 0
