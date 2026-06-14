#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/ensure-gitignore.sh
# Idempotently ensure the Drupal root's .gitignore ignores drupilot's generated
# artifacts (.phpstan-cache/, .drupilot-coverage/, .drupilot.json), so they can
# never leak into a contribution patch / MR or be committed by accident.
#
# The ignore lines live in a marker-delimited "managed block" (see
# templates/gitignore.tmpl). This script MERGES that block into an existing
# .gitignore (Drupal's composer template already ships one) rather than
# overwriting it: it strips any previous managed block and appends the current
# one, leaving every other line untouched. Re-running is a no-op once present.
#
# Usage:
#   ensure-gitignore.sh [--root DIR] [--dry-run]
#     --root     Drupal project root (default: detected from $PWD).
#     --dry-run  print what would change; write nothing.
#
# Exit codes: 0 ok (changed or already current) · 1 usage/error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ROOT=""
DRY=0
usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2;;
    --root=*) ROOT="${1#*=}"; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

[[ -n "$ROOT" ]] || ROOT="$(find_drupal_root 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "No Drupal root given or detected. Pass --root DIR." 1
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
log_ok "Ensured drupilot's ignore block in $GI (.phpstan-cache/, .drupilot-coverage/, .drupilot.json)."
exit 0
