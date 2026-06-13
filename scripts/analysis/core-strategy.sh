#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/core-strategy.sh
# Recommend the Drupal core compatibility target for a module/theme port:
# whether to declare `core_version_requirement: ^11` (Drupal 11 only) or
# `^10 || ^11` (keep Drupal 10), the composer `drupal/core` constraint, the
# composer `require.php` that choice implies, and the SemVer version bump it
# warrants — with a human-readable rationale.
#
# Policy (see config _core_target_comment): a Drupal 11 port's PHP floor is the
# resolved DRUPILOT_PHP_TARGET (>= 8.3). Because Drupal 10 itself allows PHP 8.1,
# keeping D10 ALWAYS declares `require.php: ">=<target>"` so a D10 + PHP<target
# site is blocked at install (composer) instead of fataling at runtime. `^11`
# alone needs no require.php (core enforces its own minimum).
#
# Decision: DRUPILOT_CORE_TARGET_STRATEGY (auto|d11-only|keep-d10), with the
# legacy DRUPILOT_KEEP_D10 boolean honored as an override. `auto` keeps the
# widest BC-preserving set and switches to ^11 on a BC break / Phase 2 refactor.
#
# Usage:
#   core-strategy.sh --subject DIR [--phase port|refactor]
#                    [--bc-break|--no-bc-break] [--json] [-h|--help]
#
# Options:
#   --subject DIR   Module/theme directory (default: current directory).
#   --phase P       port (default) or refactor. `refactor` implies a BC break.
#   --bc-break      Assert a public-API BC break (forces ^11 + major).
#   --no-bc-break   Assert there is no BC break (overrides the phase default).
#   --json          Print only the JSON payload (suppress the human table).
#   -h, --help      Show this help.
#
# Read-only and ungated: it only reads the subject's *.info.yml and config.
# Output: a human table on STDERR; the recommendation JSON on STDOUT.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
PHASE="port"
BC_OVERRIDE="auto"
JSON_ONLY=0

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --phase) PHASE="${2:-}"; shift 2;;
    --phase=*) PHASE="${1#*=}"; shift;;
    --bc-break) BC_OVERRIDE="yes"; shift;;
    --no-bc-break) BC_OVERRIDE="no"; shift;;
    --json) JSON_ONLY=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

# Resolve the subject directory (default cwd).
SUBJECT="${SUBJECT:-$PWD}"
SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
[[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1

case "$PHASE" in
  port|refactor) : ;;
  *) die "Invalid --phase '$PHASE' (expected port|refactor)." 1;;
esac

have_cmd jq || die "jq is required for core-strategy.sh." 1

if ! is_drupal_extension_dir "$SUBJECT_ABS"; then
  log_warn "No *.info.yml in '$SUBJECT_ABS' — treating current core_version_requirement as unknown."
fi

# --- Compute the recommendation (JSON on stdout from the helper) -----------
JSON="$(recommend_core_target "$SUBJECT_ABS" "$PHASE" "$BC_OVERRIDE")"

# --- Human table (stderr) unless --json ------------------------------------
if [[ "$JSON_ONLY" -eq 0 ]]; then
  MACHINE="$(subject_machine_name "$SUBJECT_ABS" 2>/dev/null || echo '?')"
  get() { printf '%s' "$JSON" | jq -r "$1 // \"-\""; }

  log_step "Core compatibility target — $MACHINE (phase: $PHASE)"
  log_plain "  Current core_version_requirement : $(get '.current_core_version_requirement')"
  log_plain "  Strategy                         : $(get '.strategy')"
  log_plain "  Recommended core_version_req     : $(get '.recommended_core_version_requirement')"
  log_plain "  composer drupal/core constraint  : $(get '.composer_core_constraint')"
  log_plain "  composer require.php             : $(get '.require_php')"
  log_plain "  PHP target (policy floor)        : $(get '.php_target')"
  log_plain "  Version bump (SemVer)            : $(get '.version_bump')"

  log_plain ""
  log_plain "  Rationale:"
  printf '%s' "$JSON" | jq -r '.rationale[] | "    - " + .' >&2 || true

  WARN_COUNT="$(printf '%s' "$JSON" | jq -r '.warnings | length')"
  if [[ "$WARN_COUNT" != "0" ]]; then
    log_plain ""
    log_plain "  Warnings:"
    printf '%s' "$JSON" | jq -r '.warnings[] | "    ! " + .' >&2 || true
  fi
  hr
fi

# --- Machine-readable payload (stdout) -------------------------------------
printf '%s\n' "$JSON"
exit 0
