#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/drupilot.sh
# The headless dispatcher (AR-22, X9). Until it gains its other verbs (M10), it
# answers one: `plan show`, the "drupilot plan" block a skill or command
# renders with a load-time !`...` span, and the fallback such a prompt points
# to when the span did not run (AR-26).
#
# `plan show` prints the upgrade plan of the subject: the plan frozen in its
# Drupal root's lock when it is the subject's (plan_for_subject), else a fresh
# draft from scripts/analysis/upgrade-path.sh (nothing is written). Without a
# subject or a plan (the resolver refuses), it says so in one line. Read-only.
#
# Usage:
#   drupilot.sh plan show [--subject DIR] [--root DIR] [--json]
#     --subject DIR  the module/theme (default, or when DIR is not a directory:
#                    the current directory)
#     --root DIR     its Drupal root (default: the one the subject runs in)
#     --json         the plan itself on STDOUT (the upgrade-plan JSON; {} when
#                    none resolves) instead of the block
#
# Output: the block (or the JSON) on STDOUT; logs on STDERR.
# Exit codes: 0 ok, also when no plan resolves · 1 usage error.
# =============================================================================
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() { print_usage "$0"; }

VERB="${1:-}"; SUB="${2:-}"
case "$VERB" in
  -h|--help) usage; exit 0;;
  plan) shift; [[ "$SUB" == "show" ]] || die "Unknown plan action '${SUB}' (this drupilot.sh answers: plan show)." 1; shift;;
  "") usage >&2; die "Missing a verb (this drupilot.sh answers: plan show)." 1;;
  *) die "Unknown verb '$VERB' (this drupilot.sh answers: plan show; the others arrive with drupilot 1.0)." 1;;
esac

SUBJECT=""; ROOT=""; AS_JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --root) ROOT="${2:-}"; shift 2 || die "--root needs a value" 1;;
    --root=*) ROOT="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)." 1;;
  esac
done

# A value that is not a directory (a router mode word passed as $1) falls back
# to the current directory, as next-step.sh does.
[[ -n "$SUBJECT" && -d "$SUBJECT" ]] || SUBJECT="$PWD"
SUBJECT="$(cd "$SUBJECT" 2> /dev/null && pwd || printf '%s' "$SUBJECT")"
PLAN=""
if [[ -d "$SUBJECT" ]] && is_drupal_extension_dir "$SUBJECT"; then
  [[ -n "$ROOT" ]] || ROOT="$(subject_project_root "$SUBJECT" 2> /dev/null || true)"
  PLAN="$(plan_for_subject "$ROOT" "$SUBJECT" 2> /dev/null || true)"
fi

if [[ "$AS_JSON" == "1" ]]; then
  if [[ -n "$PLAN" ]]; then printf '%s\n' "$PLAN" | jq -S .; else printf '{}\n'; fi
  exit 0
fi

if [[ -z "$PLAN" ]]; then
  if [[ -d "$SUBJECT" ]] && is_drupal_extension_dir "$SUBJECT"; then
    printf 'drupilot plan: none resolves for %s (run scripts/analysis/upgrade-path.sh --subject "%s" for the reason).\n' \
      "$(basename "$SUBJECT")" "$SUBJECT"
  else
    printf 'drupilot plan: no module or theme here (%s); pass --subject DIR.\n' "$SUBJECT"
  fi
  exit 0
fi

# The block: the facts a prompt needs, from the plan only (H4).
printf '%s\n' "$PLAN" | jq -r --arg frozen "$([[ -n "$ROOT" && "$(plan_frozen "$ROOT" 2> /dev/null | jq -r '.subject.machine_name // empty' 2> /dev/null)" == "$(printf '%s' "$PLAN" | jq -r '.subject.machine_name')" ]] && echo yes || echo no)" '
  def j(a): (a // []) | map(tostring) | join(" ");
  "drupilot plan (\(if $frozen == "yes" then "frozen, \(.meta.phase // "draft")" else "a draft, not frozen" end)):",
  "  subject: \(.subject.machine_name) (\(.subject.type)), source Drupal \(.source.major) (\(.source.track))",
  "  target: Drupal \(.target.major) (\(.target.status)\(if .target.preview then ", preview" else "" end)), test-bed core \(.target.bed_core // "unknown"), DDEV \(.target.ddev_type // "unknown")",
  "  declared range: \(.range.constraint) (\(.range.strategy) -> \(.range.resolved_strategy)), core floor \(.range.floor // "none")",
  "  PHP: floor \(.php.floor), target \(.php.final), window \(j(.php.window)), require.php \(.php.require_php // "none")",
  "  hops: \(j(.hops) | if . == "" then "none" else . end); Rector sets: \(j(.rector.drupal_sets + .rector.breaking_sets) | if . == "" then "none" else . end)",
  "  PHPStan: profile \(.phpstan.profile), level \(.phpstan.level), phpVersion \(.php.phpstan_phpversion.min)..\(.php.phpstan_phpversion.max)",
  "  names: \(.patch_name), test-bed suffix \(.workspace_suffix)"'
exit 0
