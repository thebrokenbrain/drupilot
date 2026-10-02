#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/ensure-gitignore.sh
# Idempotently ensure the Drupal root's .gitignore ignores drupilot's generated
# artifacts (the visible .drupilot/ outputs dir, .drupilot.json prefs, the
# .phpstan-cache/ and legacy .drupilot-coverage/ dirs, and the local *.patch
# previews), so they can never leak into a contribution patch / MR or be
# committed by accident.
#
# The ignore lines live in a marker-delimited "managed block" (see
# templates/gitignore.tmpl). This script MERGES that block into an existing
# .gitignore (Drupal's composer template already ships one) rather than
# overwriting it: it strips any previous managed block and appends the current
# one, leaving every other line untouched. Re-running is a no-op once present.
#
# Usage:
#   ensure-gitignore.sh [--root DIR | --subject DIR] [--dry-run]
#     --root     Drupal project root (wins over --subject).
#     --subject  module/theme directory: the root is the Drupal root found by
#                walking up from it, or — for a loose subject not yet placed —
#                the test-bed root resolve-workspace.sh targets.
#     --dry-run  print what would change; write nothing.
#   With neither flag, the root is detected from $PWD.
#   A value that is still an unsubstituted <placeholder> (e.g. "<drupal_root>")
#   is rejected with a clear error instead of being treated as a path.
#
# Exit codes: 0 ok (changed or already current) · 1 usage/error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ROOT=""
SUBJECT=""
DRY=0
usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2;;
    --root=*) ROOT="${1#*=}"; shift;;
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

# Reject a value that still looks like an unsubstituted prompt placeholder.
reject_placeholder() {
  case "$2" in
    \<*\>) die "$1 got the unsubstituted placeholder '$2' — pass the real directory." 1;;
  esac
  return 0
}
reject_placeholder --root "$ROOT"
reject_placeholder --subject "$SUBJECT"

if [[ -z "$ROOT" && -n "$SUBJECT" ]]; then
  [[ -d "$SUBJECT" ]] || die "Subject directory not found: $SUBJECT" 1
  ROOT="$(find_drupal_root "$SUBJECT" 2>/dev/null || true)"
  if [[ -z "$ROOT" ]] && have_cmd jq; then
    # A loose subject: use the test-bed root the workspace resolver targets.
    ROOT="$(bash "$(plugin_root)/scripts/env/resolve-workspace.sh" --subject "$SUBJECT" --json 2>/dev/null \
      | jq -r '.drupal_root // empty' 2>/dev/null || true)"
  fi
fi
[[ -n "$ROOT" ]] || ROOT="$(find_drupal_root 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "No Drupal root given or detected. Pass --root DIR or --subject DIR." 1
[[ -d "$ROOT" ]] || die "Root directory not found: $ROOT" 1

TPL="$(plugin_root)/templates/gitignore.tmpl"
[[ -r "$TPL" ]] || die "Template not found: $TPL" 1

GI="$ROOT/.gitignore"
BEGIN_MARK='# >>> drupilot (managed)'
END_MARK='# <<< drupilot (managed)'

# Everything in the current file EXCEPT a previous managed block.
existing=""
if [[ -f "$GI" ]]; then
  existing="$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) == 1 { skip = 1 }
    skip && index($0, e) == 1 { skip = 0; next }
    !skip { print }' "$GI")"
fi

block="$(cat "$TPL")"

# Strip trailing blank lines from the kept content, then re-join with one blank
# line before the managed block (or nothing if the file was empty).
existing="${existing%$'\n'}"
while [[ "$existing" == *$'\n' ]]; do existing="${existing%$'\n'}"; done

if [[ -n "$existing" ]]; then
  new_content="$existing"$'\n\n'"$block"
else
  new_content="$block"
fi

# Compare against the current file to detect a no-op.
current=""
[[ -f "$GI" ]] && current="$(cat "$GI")"
if [[ "${current%$'\n'}" == "${new_content%$'\n'}" ]]; then
  log_info ".gitignore already ignores drupilot artifacts (no change): $GI"
  exit 0
fi

if [[ "$DRY" == "1" ]]; then
  log_step "[dry-run] Would update $GI with drupilot's managed ignore block:"
  printf '%s\n' "$block" >&2
  exit 0
fi

printf '%s\n' "$new_content" > "$GI"
log_ok "Ensured drupilot's ignore block in $GI (.drupilot/, .drupilot.json, .phpstan-cache/, *-port-to-drupal-11*.patch)."
exit 0
