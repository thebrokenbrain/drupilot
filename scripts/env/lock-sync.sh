#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/lock-sync.sh
# Capture / refresh the per-project reproducibility lockfile (drupilot-lock.json).
#
# drupilot is reproducible BY DEFAULT (DRUPILOT_DETERMINISTIC, see common.sh):
# the EXACT versions/refs resolved on first setup are frozen here and reused on
# later runs, so porting the same module twice converges on the same toolchain.
# This script reads what is actually installed and records it:
#
#   - php_target              effective DRUPILOT_PHP_TARGET
#   - drupal.core             exact drupal/core version (from composer.lock)
#   - toolchain.<pkg>         exact version of each .packages.* dev tool
#   - ddev_addons.<addon>     installed DDEV add-on version (best-effort)
#   - phpstan_level / core_strategy   the effective config knobs
#   - drupilot_version / created / updated
#
# It does NOT touch digests.{ref,sha} (run-rector.sh owns those), except that
# --refresh drops digests.sha so the next Rector run re-resolves the live ref.
#
# Fail-safe: if there is no composer.lock yet (setup not run) or DDEV is down,
# it records what it can and exits 0 — it never blocks a flow.
#
# Usage:
#   lock-sync.sh [--subject DIR | --dir PROJECT_DIR] [--json] [--refresh]
#                [--dry-run] [-h|--help]
#
# Options:
#   --subject DIR   A module/theme path; the Drupal root is derived from it.
#   --dir DIR       The Drupal project root directly.
#   --json          Print the resulting lockfile (JSON) on STDOUT.
#   --refresh       Re-capture and drop the frozen digests SHA (re-resolve next).
#   --dry-run       Show what would be written; change nothing.
#   -h, --help      Show this help.
#
# Output: logs on STDERR; with --json, the lockfile JSON on STDOUT.
# Exit codes: 0 always (degrades gracefully); 1 only on usage error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

OUTPUT_JSON=0
DO_REFRESH=0
DRY_RUN=0
SUBJECT=""
PROJECT_DIR=""

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --dir) PROJECT_DIR="${2:-}"; shift 2;;
    --dir=*) PROJECT_DIR="${1#*=}"; shift;;
    --json) OUTPUT_JSON=1; shift;;
    --refresh) DO_REFRESH=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

have_cmd jq || { log_warn "jq is required for the lockfile; skipping lock-sync."; exit 0; }

# --- Resolve the project directory ----------------------------------------
if [[ -z "$PROJECT_DIR" ]]; then
  PROJECT_DIR="$(find_drupal_root "${SUBJECT:-$PWD}" 2>/dev/null || true)"
fi
[[ -z "$PROJECT_DIR" ]] && PROJECT_DIR="$PWD"
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd || printf '%s' "$PROJECT_DIR")"
export DRUPILOT_PROJECT_DIR="$PROJECT_DIR"

LOCKFILE="$(drupilot_lock_file)"
COMPOSER_LOCK="$PROJECT_DIR/composer.lock"

log_step "Syncing the drupilot lockfile"
log_info "Project   : $PROJECT_DIR"
log_info "Lockfile  : $LOCKFILE"
[[ "$DRY_RUN" == "1" ]] && log_info "Mode      : dry-run (no writes)"

# --- Write helpers (respect --dry-run) ------------------------------------
lset_str() {
  local path="$1" val="$2"
  [[ -n "$val" ]] || return 0
  if [[ "$DRY_RUN" == "1" ]]; then log_info "[dry-run] $path = \"$val\""; return 0; fi
  if lock_set "$path" "$val"; then log_info "lock: $path = $val"; else log_warn "Could not set $path."; fi
}
lset_json() {
  local path="$1" val="$2"
  [[ -n "$val" ]] || return 0
  if [[ "$DRY_RUN" == "1" ]]; then log_info "[dry-run] $path = $val"; return 0; fi
  if lock_set_json "$path" "$val"; then log_info "lock: $path = $val"; else log_warn "Could not set $path."; fi
}

# composer.lock package version (searches packages + packages-dev).
composer_pkg_version() {
  local name="$1"
  [[ -f "$COMPOSER_LOCK" ]] || { printf ''; return 1; }
  jq -r --arg n "$name" \
    '((.packages // []) + (."packages-dev" // [])) | map(select(.name==$n)) | (.[0].version // empty)' \
    "$COMPOSER_LOCK" 2>/dev/null
}

# --- Metadata -------------------------------------------------------------
[[ -z "$(lock_get .created "")" ]] && lset_str .created "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
lset_str .updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
lset_str .drupilot_version "$(plugin_version)"
lset_str .php_target "$(resolve_php_target)"
lset_json .phpstan_level "$(config_get DRUPILOT_PHPSTAN_LEVEL 2)"
lset_str .core_strategy "$(config_get DRUPILOT_CORE_TARGET_STRATEGY auto)"

# --- Drupal core + dev toolchain (from composer.lock) ---------------------
if [[ -f "$COMPOSER_LOCK" ]]; then
  CORE_VER="$(composer_pkg_version "drupal/core")"
  [[ -z "$CORE_VER" ]] && CORE_VER="$(composer_pkg_version "drupal/core-recommended")"
  lset_str ".drupal.core" "$CORE_VER"

  # Each tool declared in defaults.json .packages.* (strip the :constraint).
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    spec="$(config_json ".packages.$key" "")"
    name="${spec%%:*}"
    [[ -n "$name" ]] || continue
    ver="$(composer_pkg_version "$name")"
    [[ -n "$ver" ]] && lset_str ".toolchain.\"$name\"" "$ver"
  done < <(jq -r '.packages | keys[]' "$(drupilot_config_file)" 2>/dev/null)
else
  log_warn "No composer.lock at $PROJECT_DIR yet — skipping core/toolchain capture (run /drupilot-setup first)."
fi

# --- DDEV add-ons (best-effort; secondary, never blocks) ------------------
if have_cmd ddev && ddev_running "$PROJECT_DIR"; then
  ADDONS_RAW="$( ( cd "$PROJECT_DIR" && ddev add-on list --installed 2>/dev/null ) || true )"
  for addon in ddev-drupal-contrib ddev-selenium-standalone-chrome; do
    if printf '%s' "$ADDONS_RAW" | grep -q "$addon"; then
      ver="$(printf '%s' "$ADDONS_RAW" | grep "$addon" | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)"
      lset_str ".ddev_addons.\"$addon\"" "${ver:-installed}"
    fi
  done
else
  log_info "DDEV not running — skipping add-on version capture (optional)."
fi

# --- Refresh: drop the frozen digests SHA so the next run re-resolves ------
if [[ "$DO_REFRESH" == "1" && "$DRY_RUN" != "1" && -f "$LOCKFILE" ]]; then
  tmp="$(mktemp "${LOCKFILE}.XXXXXX" 2>/dev/null)" || tmp=""
  if [[ -n "$tmp" ]] && jq 'del(.digests.sha)' "$LOCKFILE" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$LOCKFILE"
    log_info "Refresh: dropped the frozen digests SHA (next Rector run re-resolves the live ref)."
  else
    [[ -n "$tmp" ]] && rm -f "$tmp" 2>/dev/null || true
  fi
fi

hr
if [[ "$DRY_RUN" == "1" ]]; then
  log_ok "Dry-run complete (no changes written)."
else
  log_ok "Lockfile synced: $LOCKFILE"
fi

# STDOUT: the lockfile JSON when requested.
if [[ "$OUTPUT_JSON" == "1" ]]; then
  if [[ -f "$LOCKFILE" ]]; then jq . "$LOCKFILE"; else printf '{}\n'; fi
fi
exit 0
