#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/run-phpstan.sh
# Run PHPStan (with phpstan-drupal + deprecation rules) against a module/theme.
#
# Level defaults to DRUPILOT_PHPSTAN_LEVEL (2 = deprecation detection, the level
# that drupal-check fixes). The refactor phase raises it to 5-6
# (DRUPILOT_PHPSTAN_LEVEL_REFACTOR). PHPStan needs the Drupal core tree present
# but does NOT bootstrap a database.
#
# Usage:
#   run-phpstan.sh --subject DIR [--level N] [--json]
#
# Options:
#   --subject DIR   Path to the module/theme to analyse (relative to the Drupal
#                   root or absolute). Required.
#   --level N       PHPStan rule level (default: DRUPILOT_PHPSTAN_LEVEL).
#   --json          Emit PHPStan's native JSON (`--error-format=json`) on STDOUT —
#                   `{totals:{errors,file_errors}, files:{...}}` — for a reproducible
#                   count the viability analyst can read instead of estimating.
#   -h, --help      Show this help.
#
# Gate: `analyze` profile (git + jq + composer/php).
# Output: status/logging on STDERR; PHPStan's own report (or JSON) on STDOUT.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
LEVEL=""
AS_JSON=0

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --level) LEVEL="${2:-}"; shift 2;;
    --level=*) LEVEL="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

[[ -n "$SUBJECT" ]] || die "Missing --subject DIR (the module/theme to analyse)." 1

# Resolve the level (CLI > config). Warn when the level comes from the
# environment (DRUPILOT_PHPSTAN_LEVEL), since that changes results vs the project
# default and is a common silent source of divergence between machines.
if [[ -z "$LEVEL" ]]; then
  if [[ -n "${DRUPILOT_PHPSTAN_LEVEL:-}" ]]; then
    log_warn "PHPStan level '$DRUPILOT_PHPSTAN_LEVEL' comes from the environment (DRUPILOT_PHPSTAN_LEVEL), overriding the project default; unset it to use the configured default."
  fi
  LEVEL="$(config_get DRUPILOT_PHPSTAN_LEVEL "2")"
fi
case "$LEVEL" in
  [0-9]|max) : ;;
  *) die "Invalid --level '$LEVEL' (expected 0-9 or 'max')." 1;;
esac

# --- Gate: analyze --------------------------------------------------------
PREFLIGHT="$(plugin_root)/scripts/env/preflight.sh"
if ! bash "$PREFLIGHT" --profile analyze --quiet >/dev/null 2>&1; then
  log_err "The 'analyze' requirements are not satisfied; cannot run PHPStan."
  bash "$PREFLIGHT" --profile analyze || true
  exit 2
fi

# --- Locate the Drupal root and resolve the subject relative to it --------
DRUPAL_ROOT="$(find_drupal_root "$SUBJECT" 2>/dev/null || find_drupal_root "$PWD" 2>/dev/null || true)"
[[ -n "$DRUPAL_ROOT" ]] || die "Could not locate a Drupal root (web/core or .ddev/config.yaml) from '$SUBJECT'. Run /drupilot-setup first." 2

SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
if [[ -z "$SUBJECT_ABS" ]]; then
  SUBJECT_ABS="$(cd "$DRUPAL_ROOT/$SUBJECT" 2>/dev/null && pwd || true)"
fi
[[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1

case "$SUBJECT_ABS" in
  "$DRUPAL_ROOT"/*) SUBJECT_REL="${SUBJECT_ABS#"$DRUPAL_ROOT"/}";;
  "$DRUPAL_ROOT")   SUBJECT_REL=".";;
  *) die "Subject '$SUBJECT_ABS' is outside the Drupal root '$DRUPAL_ROOT'." 1;;
esac

cd "$DRUPAL_ROOT"
RUNNER="$(drupal_runner "$DRUPAL_ROOT")"
PHP_TARGET="$(resolve_php_target)"

log_info "Drupal root : $DRUPAL_ROOT"
log_info "Subject     : $SUBJECT_REL"
log_info "Level       : $LEVEL"
log_info "PHP target  : $PHP_TARGET"
if [[ -n "$RUNNER" ]]; then
  log_info "Runner      : DDEV ($RUNNER)"
else
  log_info "Runner      : host (vendor/bin)"
fi

# --- Verify the PHPStan binary is present ---------------------------------
if [[ ! -f "$DRUPAL_ROOT/vendor/bin/phpstan" ]]; then
  die "vendor/bin/phpstan is missing. Install the toolchain first (e.g. via /drupilot-setup: 'composer require --dev phpstan/phpstan phpstan/extension-installer mglaman/phpstan-drupal phpstan/phpstan-deprecation-rules')." 2
fi

# --- Build the command ----------------------------------------------------
# Config precedence (deterministic): phpstan.neon > phpstan.neon.dist > extension
# defaults. Prefer the phpstan.neon at the Drupal root (extension-installer
# autoloads the Drupal + deprecation rules). If neither exists, PHPStan still runs
# with the extension defaults; warn so the user knows the analysis context.
declare -a CMD=()
[[ -n "$RUNNER" ]] && read -r -a CMD <<<"$RUNNER"
CMD+=(vendor/bin/phpstan analyse --no-progress --level "$LEVEL")
[[ "$AS_JSON" == "1" ]] && CMD+=(--error-format=json)

if [[ -f "$DRUPAL_ROOT/phpstan.neon" ]]; then
  CMD+=(--configuration phpstan.neon)
  log_ok "Using phpstan.neon at the Drupal root."
elif [[ -f "$DRUPAL_ROOT/phpstan.neon.dist" ]]; then
  CMD+=(--configuration phpstan.neon.dist)
  log_ok "Using phpstan.neon.dist at the Drupal root."
else
  log_warn "No phpstan.neon at the Drupal root; running with extension defaults. Run /drupilot-setup to write one."
fi

CMD+=("$SUBJECT_REL")

log_step "PHPStan: ${CMD[*]}"

# Run; PHPStan exits non-zero when it finds errors. Surface the output and the
# real exit status (never silence findings). In --json mode, capture stdout so it
# stays pure JSON (all logging is on stderr) and re-emit it.
set +e
if [[ "$AS_JSON" == "1" ]]; then
  OUT="$("${CMD[@]}" 2>/dev/null)"
  RC=$?
  [[ -n "$OUT" ]] && printf '%s\n' "$OUT"
else
  "${CMD[@]}"
  RC=$?
fi
set -e

hr
if [[ "$RC" -eq 0 ]]; then
  log_ok "PHPStan reported no issues at level $LEVEL for $SUBJECT_REL."
else
  log_warn "PHPStan found issues at level $LEVEL (exit $RC). Review the report above."
fi
exit "$RC"
