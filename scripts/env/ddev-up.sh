#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/ddev-up.sh
# Create (if absent) and start a Drupal 11 DDEV project, parameterized by the
# effective PHP target (resolve_php_target). Then ensure a Composer project
# exists (drupal/recommended-project:^11) with Drush ^13.
#
# This script GATES the 'setup' profile via preflight: if a hard requirement
# (Docker daemon up, DDEV) is missing it prints the report and exits 2 WITHOUT
# touching anything.
#
# Idempotent (PROMPT 5.2 / 7.7):
#   - If .ddev/config.yaml already exists we do NOT re-run `ddev config`.
#   - If the project is already running we skip `ddev start`.
#   - If composer.json already exists we skip `ddev composer create`.
#   - We READ the generated .ddev/config.yaml for the real values rather than
#     assuming hostnames/images (PROMPT 2.5 / 7.1).
#
# Usage:
#   ddev-up.sh [--php X] [--name NAME] [--subject DIR] [--docroot web]
#              [--dir PROJECT_DIR] [--no-create] [-h|--help]
#
# Exit codes:
#   0 -> project configured and running.
#   2 -> a hard 'setup' requirement is missing (preflight gate).
#   1 -> usage/internal error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PHP_TARGET=""
PROJECT_NAME=""
SUBJECT=""
DOCROOT="web"
PROJECT_DIR=""
DO_CREATE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --php) PHP_TARGET="${2:-}"; shift 2;;
    --php=*) PHP_TARGET="${1#*=}"; shift;;
    --name) PROJECT_NAME="${2:-}"; shift 2;;
    --name=*) PROJECT_NAME="${1#*=}"; shift;;
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --docroot) DOCROOT="${2:-web}"; shift 2;;
    --docroot=*) DOCROOT="${1#*=}"; shift;;
    --dir) PROJECT_DIR="${2:-}"; shift 2;;
    --dir=*) PROJECT_DIR="${1#*=}"; shift;;
    --no-create) DO_CREATE=0; shift;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

# Effective PHP target (flag overrides config; config defaults to 8.3).
[[ -z "$PHP_TARGET" ]] && PHP_TARGET="$(resolve_php_target)"

# Warn (don't block) on an unconfirmed PHP target — DDEV may lack that image.
if php_target_unconfirmed "$PHP_TARGET"; then
  log_warn "PHP target $PHP_TARGET is not officially confirmed for Drupal 11 (PROMPT 1.2)."
  log_warn "DDEV may not provide a PHP $PHP_TARGET image. Consider 8.3 (default) or 8.4 if 'ddev start' fails."
fi

PLUGIN_ROOT_DIR="$(plugin_root)"

# ---------------------------------------------------------------------------
# GATE: setup profile (Docker daemon + DDEV). No side effects before this.
# ---------------------------------------------------------------------------
log_step "Checking environment requirements (profile: setup)"
if ! bash "$PLUGIN_ROOT_DIR/scripts/env/preflight.sh" --profile setup; then
  die "Cannot set up the DDEV environment: a hard requirement is missing (see report above). Run /drupilot-doctor." 2
fi

# ---------------------------------------------------------------------------
# Resolve the project directory.
# Preference: --dir > existing Drupal root from --subject/cwd > current dir.
# ---------------------------------------------------------------------------
if [[ -z "$PROJECT_DIR" ]]; then
  PROJECT_DIR="$(find_drupal_root "${SUBJECT:-$PWD}" 2>/dev/null || true)"
fi
[[ -z "$PROJECT_DIR" ]] && PROJECT_DIR="$PWD"
mkdir -p "$PROJECT_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# Default project name from the directory if not provided.
[[ -z "$PROJECT_NAME" ]] && PROJECT_NAME="$(basename "$PROJECT_DIR")"

DDEV_CONFIG="$PROJECT_DIR/.ddev/config.yaml"

log_info "Project directory : $PROJECT_DIR"
log_info "Project name      : $PROJECT_NAME"
log_info "PHP target        : $PHP_TARGET"
log_info "Docroot           : $DOCROOT"

# ---------------------------------------------------------------------------
# Step 1 — ddev config (idempotent: skip if already configured)
# ---------------------------------------------------------------------------
if [[ -f "$DDEV_CONFIG" ]]; then
  log_ok "DDEV is already configured (.ddev/config.yaml exists) — not re-running 'ddev config'."
  # Reconcile the PHP version if the existing config differs from the target.
  EXISTING_PHP="$(grep -E '^[[:space:]]*php_version:' "$DDEV_CONFIG" 2>/dev/null | head -n1 \
    | sed -E 's/^[[:space:]]*php_version:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' | tr -d '"'"'"'')"
  EXISTING_PHP="$(trim "$EXISTING_PHP")"
  if [[ -n "$EXISTING_PHP" && "$EXISTING_PHP" != "$PHP_TARGET" ]]; then
    log_warn "Existing DDEV php_version ($EXISTING_PHP) differs from the target ($PHP_TARGET). Aligning to $PHP_TARGET."
    ( cd "$PROJECT_DIR" && ddev config --php-version="$PHP_TARGET" >/dev/null )
  fi
else
  log_step "Configuring DDEV (Drupal 11, PHP $PHP_TARGET)"
  ( cd "$PROJECT_DIR" && ddev config \
      --project-name="$PROJECT_NAME" \
      --project-type=drupal11 \
      --docroot="$DOCROOT" \
      --php-version="$PHP_TARGET" ) \
    || die "'ddev config' failed. If PHP $PHP_TARGET is unsupported by this DDEV version, retry with --php 8.3." 1
  log_ok "DDEV configured."
fi

# ---------------------------------------------------------------------------
# Step 2 — ddev start (idempotent: skip if already running)
# ---------------------------------------------------------------------------
if ddev_running "$PROJECT_DIR"; then
  log_ok "DDEV project is already running — skipping 'ddev start'."
else
  log_step "Starting DDEV (this may pull container images on first run)"
  ( cd "$PROJECT_DIR" && ddev start ) \
    || die "'ddev start' failed. Check the Docker daemon and the DDEV logs ('ddev logs')." 1
  log_ok "DDEV started."
fi

# ---------------------------------------------------------------------------
# Step 3 — READ the generated config for the real values (do NOT assume).
# ---------------------------------------------------------------------------
EFFECTIVE_PHP=""
PRIMARY_URL=""
if [[ -f "$DDEV_CONFIG" ]]; then
  EFFECTIVE_PHP="$(grep -E '^[[:space:]]*php_version:' "$DDEV_CONFIG" 2>/dev/null | head -n1 \
    | sed -E 's/^[[:space:]]*php_version:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' | tr -d '"'"'"'')"
  EFFECTIVE_PHP="$(trim "$EFFECTIVE_PHP")"
fi
# The authoritative primary URL comes from `ddev describe` (don't guess the host).
if have_cmd jq; then
  PRIMARY_URL="$( ( cd "$PROJECT_DIR" && ddev describe -j 2>/dev/null ) \
    | jq -r '.raw.primary_url // .raw.httpsurl // empty' 2>/dev/null || true)"
fi
log_info "Generated config  : $DDEV_CONFIG"
[[ -n "$EFFECTIVE_PHP" ]] && log_info "Effective php_version (from YAML): $EFFECTIVE_PHP"
[[ -n "$PRIMARY_URL" ]]   && log_info "Primary URL (from 'ddev describe'): $PRIMARY_URL"

# ---------------------------------------------------------------------------
# Step 4 — Composer project (idempotent: skip if composer.json present)
# ---------------------------------------------------------------------------
DRUPAL_TARGET="$(resolve_drupal_target)"
if [[ -f "$PROJECT_DIR/composer.json" ]]; then
  log_ok "composer.json already present — not running 'ddev composer create'."
else
  log_step "Creating the Drupal $DRUPAL_TARGET Composer project"
  ( cd "$PROJECT_DIR" && ddev composer create --no-interaction "drupal/recommended-project:${DRUPAL_TARGET}" ) \
    || die "'ddev composer create' failed. Check network access and the DDEV web container ('ddev logs -s web')." 1
  log_ok "Composer project created."
fi

# ---------------------------------------------------------------------------
# Step 5 — ensure Drush ^13 (required by Drupal 11)
# ---------------------------------------------------------------------------
DRUSH_CONSTRAINT="$(config_json '.packages.drush' 'drush/drush:^13')"
HAS_DRUSH=0
if [[ -f "$PROJECT_DIR/composer.json" ]] && have_cmd jq; then
  if jq -e '(.require // {}) | has("drush/drush") or has("drush/drush:^13")' "$PROJECT_DIR/composer.json" >/dev/null 2>&1; then
    HAS_DRUSH=1
  fi
fi
if [[ "$HAS_DRUSH" == "1" ]]; then
  log_ok "Drush already required in composer.json — skipping."
else
  log_step "Requiring Drush ($DRUSH_CONSTRAINT)"
  ( cd "$PROJECT_DIR" && ddev composer require --no-interaction "$DRUSH_CONSTRAINT" ) \
    || log_warn "Could not require Drush automatically. Run 'ddev composer require $DRUSH_CONSTRAINT' inside $PROJECT_DIR."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
hr
log_ok "DDEV Drupal $DRUPAL_TARGET environment is ready (PHP ${EFFECTIVE_PHP:-$PHP_TARGET})."
log_plain "Next: 'ddev-add-ons.sh --contrib [--selenium]' to add the contrib + Selenium add-ons,"
log_plain "      then place your module/theme under $DOCROOT/modules/custom or $DOCROOT/themes/custom."
exit 0
