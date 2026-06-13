#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/detect-php.sh
# Detect the host PHP version and (if a DDEV project exists) the configured
# DDEV php_version, then print the EFFECTIVE PHP target and whether it is
# officially supported or unconfirmed for Drupal 11.
#
# The effective target comes from resolve_php_target (DRUPILOT_PHP_TARGET >
# defaults.json, default 8.3). The host PHP and the DDEV php_version are
# reported as context (e.g. so the caller can warn about a mismatch); they do
# NOT override the configured target — that decision belongs to the user.
#
# Per PROMPT 1.2 / 7.1: never hardcode "8.5 supported". Support is derived from
# php_support.* in defaults.json (php_target_supported / php_target_unconfirmed).
#
# Usage:
#   detect-php.sh [--subject DIR] [--json] [--quiet] [-h|--help]
#
# Output:
#   --json   -> a single JSON object on STDOUT, nothing else:
#               {host_php, ddev_php, target, supported, unconfirmed}
#   default  -> a human-readable English summary on STDOUT.
#   Diagnostics/logging always go to STDERR.
#
# Exit code: always 0 (this is a read-only detector; it never gates).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

AS_JSON=0
QUIET=0
SUBJECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) AS_JSON=1; shift;;
    --quiet) QUIET=1; shift;;
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

# ---------------------------------------------------------------------------
# Host PHP
# ---------------------------------------------------------------------------
HOST_PHP=""
if have_cmd php; then
  HOST_PHP="$(tool_version php || true)"
fi

# ---------------------------------------------------------------------------
# DDEV php_version (from the generated .ddev/config.yaml, if present)
# We READ the YAML rather than assume. The Drupal root is located from the
# subject dir (if given) or the current directory.
# ---------------------------------------------------------------------------
DDEV_PHP=""
DROOT="$(find_drupal_root "${SUBJECT:-$PWD}" 2>/dev/null || true)"
DDEV_CONFIG=""
if [[ -n "$DROOT" && -f "$DROOT/.ddev/config.yaml" ]]; then
  DDEV_CONFIG="$DROOT/.ddev/config.yaml"
fi
if [[ -n "$DDEV_CONFIG" ]]; then
  # php_version: "8.3"  (quotes optional). Take the first match, strip quotes.
  DDEV_PHP="$(grep -E '^[[:space:]]*php_version:' "$DDEV_CONFIG" 2>/dev/null \
    | head -n1 \
    | sed -E 's/^[[:space:]]*php_version:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' \
    | tr -d '"'"'"'')"
  DDEV_PHP="$(trim "$DDEV_PHP")"
fi

# ---------------------------------------------------------------------------
# Effective target + support classification (derived at runtime)
# ---------------------------------------------------------------------------
TARGET="$(resolve_php_target)"

SUPPORTED="false"
UNCONFIRMED="false"
php_target_supported "$TARGET"   && SUPPORTED="true"
php_target_unconfirmed "$TARGET" && UNCONFIRMED="true"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ "$AS_JSON" == "1" ]]; then
  jq -n \
    --arg host_php "$HOST_PHP" \
    --arg ddev_php "$DDEV_PHP" \
    --arg target "$TARGET" \
    --argjson supported "$SUPPORTED" \
    --argjson unconfirmed "$UNCONFIRMED" \
    '{host_php:$host_php, ddev_php:$ddev_php, target:$target, supported:$supported, unconfirmed:$unconfirmed}'
  exit 0
fi

if [[ "$QUIET" != "1" ]]; then
  printf '\n%sdrupilot — PHP target%s\n' "$_C_BOLD" "$_C_RESET"
  hr
  if [[ -n "$HOST_PHP" ]]; then
    printf '  Host PHP        : %s\n' "$HOST_PHP"
  else
    printf '  Host PHP        : not found on host (fine — DDEV bundles PHP)\n'
  fi
  if [[ -n "$DDEV_PHP" ]]; then
    printf '  DDEV php_version: %s   %s(read from %s)%s\n' "$DDEV_PHP" "$_C_DIM" "$DDEV_CONFIG" "$_C_RESET"
  else
    printf '  DDEV php_version: %s(no DDEV project detected yet)%s\n' "$_C_DIM" "$_C_RESET"
  fi
  printf '  Effective target: %s%s%s\n' "$_C_BOLD" "$TARGET" "$_C_RESET"
  if [[ "$SUPPORTED" == "true" ]]; then
    printf '  Status          : %s✅ supported%s for Drupal 11\n' "$_C_GREEN" "$_C_RESET"
  elif [[ "$UNCONFIRMED" == "true" ]]; then
    printf '  Status          : %s⚠️  unconfirmed%s — the exact Drupal 11 minor that supports PHP %s\n' "$_C_YELLOW" "$_C_RESET" "$TARGET"
    printf '                    is not officially confirmed. Detect at runtime; consider 8.3 (default) or 8.4.\n'
  else
    printf '  Status          : %s⚠️  not in the known-supported list%s — verify before relying on it.\n' "$_C_YELLOW" "$_C_RESET"
  fi
  # Soft mismatch warning (informational only).
  if [[ -n "$DDEV_PHP" && "$DDEV_PHP" != "$TARGET" ]]; then
    log_warn "DDEV php_version ($DDEV_PHP) differs from the effective target ($TARGET). Run /drupilot-setup or 'ddev-up.sh --php $TARGET' to realign."
  fi
  hr
fi

exit 0
