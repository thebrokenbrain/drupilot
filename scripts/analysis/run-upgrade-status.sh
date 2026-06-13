#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/run-upgrade-status.sh
# Run the Upgrade Status contrib module against a module/theme.
#
# Unlike Rector/PHPStan/PHPCS, Upgrade Status REQUIRES an installed Drupal site
# (full bootstrap + database), so it runs through Drush inside DDEV:
#     ddev drush en upgrade_status -y
#     ddev drush upgrade_status:analyze NAME   (alias: us-a)
#
# It soft-skips (exit 0, clear message) when DDEV is not running or Drupal is
# not installed — analysis should never hard-fail just because the optional
# site bootstrap is unavailable.
#
# Usage:
#   run-upgrade-status.sh --module NAME
#
# Options:
#   --module NAME   Machine name of the module/theme to analyse. Required.
#   -h, --help      Show this help.
#
# Gate: `setup` profile (Docker daemon + DDEV).
# Output: status/logging on STDERR; Drush's report on STDOUT.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

MODULE=""

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module) MODULE="${2:-}"; shift 2;;
    --module=*) MODULE="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

[[ -n "$MODULE" ]] || die "Missing --module NAME (the machine name to analyse)." 1

# --- Gate: setup (Docker daemon + DDEV) -----------------------------------
PREFLIGHT="$(plugin_root)/scripts/env/preflight.sh"
if ! bash "$PREFLIGHT" --profile setup --quiet >/dev/null 2>&1; then
  log_err "The 'setup' requirements (Docker daemon + DDEV) are not satisfied; Upgrade Status needs a DDEV site."
  bash "$PREFLIGHT" --profile setup || true
  exit 2
fi

# --- Locate the Drupal root ----------------------------------------------
DRUPAL_ROOT="$(find_drupal_root "$PWD" 2>/dev/null || true)"
[[ -n "$DRUPAL_ROOT" ]] || die "Could not locate a Drupal root (.ddev/config.yaml). Run /drupilot-setup first." 2

cd "$DRUPAL_ROOT"

# --- DDEV must be running -------------------------------------------------
if ! ddev_running "$DRUPAL_ROOT"; then
  log_warn "DDEV is not running for this project. Start it with 'ddev start' (or /drupilot-setup)."
  log_warn "Soft-skipping Upgrade Status (it needs a running, installed Drupal site)."
  exit 0
fi

log_info "Drupal root : $DRUPAL_ROOT"
log_info "Module      : $MODULE"

# --- Drupal must be installed (bootstrap + DB) ----------------------------
# `drush status` reports the bootstrap level; "Successful" Connection/Bootstrap
# means an installed, reachable site. Soft-skip otherwise.
set +e
BOOT="$(ddev drush status --field=bootstrap 2>/dev/null)"
DB="$(ddev drush status --field=db-status 2>/dev/null)"
set -e
if [[ "$BOOT" != *Successful* && "$DB" != *Connected* && "$DB" != *Connection* ]]; then
  log_warn "Drupal does not appear to be installed (bootstrap='$BOOT', db='$DB')."
  log_warn "Install it first (e.g. 'ddev drush site:install -y'), then re-run Upgrade Status."
  log_warn "Soft-skipping for now; Rector/PHPStan/PHPCS still cover static analysis."
  exit 0
fi
log_ok "Drupal site is installed and reachable."

# --- Ensure the upgrade_status module is enabled (idempotent) -------------
log_step "Enabling upgrade_status (idempotent)"
set +e
ddev drush en upgrade_status -y
EN_RC=$?
set -e
if [[ "$EN_RC" -ne 0 ]]; then
  log_warn "Could not enable upgrade_status. It may not be installed via Composer."
  log_warn "Add it with:  ddev composer require --dev drupal/upgrade_status"
  log_warn "Soft-skipping Upgrade Status."
  exit 0
fi

# --- Analyse --------------------------------------------------------------
log_step "Upgrade Status: ddev drush upgrade_status:analyze $MODULE"
set +e
ddev drush upgrade_status:analyze "$MODULE"
RC=$?
set -e

hr
if [[ "$RC" -eq 0 ]]; then
  log_ok "Upgrade Status analysis complete for '$MODULE'."
else
  log_warn "Upgrade Status reported problems for '$MODULE' (exit $RC). Review the report above."
fi
exit "$RC"
