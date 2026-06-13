#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/ddev-add-ons.sh
# Install the DDEV add-ons used by the porting workflow:
#   --contrib   ddev/ddev-drupal-contrib   (isolated contrib/custom development:
#               provides `ddev phpunit`, `ddev phpcs`, `ddev phpstan`, etc.)
#   --selenium  ddev/ddev-selenium-standalone-chrome  (v2, for
#               FunctionalJavascript tests — PROMPT 2.5)
# With no flags, both are installed.
#
# After installing add-ons we `ddev restart` so they take effect.
#
# Behaviour (PROMPT 5.2 / 7.7 / 7.8):
#   - Idempotent: detects already-installed add-ons (`ddev add-on list`) and
#     skips them; only restarts if something actually changed.
#   - Selenium failures are SOFT: warn and continue (JS tests will be skipped),
#     never fail the script.
#   - Gates the 'setup' profile first (needs Docker + DDEV).
#
# Usage:
#   ddev-add-ons.sh [--contrib] [--selenium] [--subject DIR] [--dir DIR] [-h|--help]
#
# Exit codes:
#   0 -> requested add-ons installed (or already present); Selenium failure is
#        non-fatal.
#   2 -> a hard 'setup' requirement is missing, or no DDEV project found.
#   1 -> usage/internal error, or a required (contrib) add-on failed.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

WANT_CONTRIB=0
WANT_SELENIUM=0
SUBJECT=""
PROJECT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --contrib) WANT_CONTRIB=1; shift;;
    --selenium) WANT_SELENIUM=1; shift;;
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --dir) PROJECT_DIR="${2:-}"; shift 2;;
    --dir=*) PROJECT_DIR="${1#*=}"; shift;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

# No flags -> install both.
if [[ "$WANT_CONTRIB" == "0" && "$WANT_SELENIUM" == "0" ]]; then
  WANT_CONTRIB=1
  WANT_SELENIUM=1
fi

PLUGIN_ROOT_DIR="$(plugin_root)"

CONTRIB_ADDON="ddev/ddev-drupal-contrib"
SELENIUM_ADDON="ddev/ddev-selenium-standalone-chrome"

# ---------------------------------------------------------------------------
# GATE: setup profile (Docker daemon + DDEV). No side effects before this.
# ---------------------------------------------------------------------------
log_step "Checking environment requirements (profile: setup)"
if ! bash "$PLUGIN_ROOT_DIR/scripts/env/preflight.sh" --profile setup; then
  die "Cannot install DDEV add-ons: a hard requirement is missing (see report above). Run /drupilot-doctor." 2
fi

# ---------------------------------------------------------------------------
# Resolve the DDEV project directory.
# ---------------------------------------------------------------------------
if [[ -z "$PROJECT_DIR" ]]; then
  PROJECT_DIR="$(find_drupal_root "${SUBJECT:-$PWD}" 2>/dev/null || true)"
fi
[[ -z "$PROJECT_DIR" ]] && PROJECT_DIR="$PWD"
if [[ ! -f "$PROJECT_DIR/.ddev/config.yaml" ]]; then
  die "No DDEV project found at '$PROJECT_DIR'. Run 'ddev-up.sh' first to create the environment." 2
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
log_info "DDEV project: $PROJECT_DIR"

# Docroot (used to locate <docroot>/modules/custom); read from the generated
# config rather than assuming "web".
DOCROOT="$(grep -E '^[[:space:]]*docroot:' "$PROJECT_DIR/.ddev/config.yaml" 2>/dev/null \
  | head -n1 | sed -E 's/.*docroot:[[:space:]]*//; s/["'\'' ]//g')"
[[ -n "$DOCROOT" ]] || DOCROOT="web"

# Ensure the project is running before touching add-ons.
if ! ddev_running "$PROJECT_DIR"; then
  log_step "Starting the DDEV project"
  ( cd "$PROJECT_DIR" && ddev start ) \
    || die "'ddev start' failed. Check the Docker daemon and 'ddev logs'." 1
fi

# ---------------------------------------------------------------------------
# Detect already-installed add-ons (idempotency).
# `ddev add-on list --installed` lists what is present; we match by name.
# ---------------------------------------------------------------------------
INSTALLED_LIST=""
INSTALLED_LIST="$( ( cd "$PROJECT_DIR" && ddev add-on list --installed 2>/dev/null ) || true )"

addon_installed() {
  # addon_installed <full-name> -> 0 if the add-on appears installed.
  local full="$1" short="${1##*/}"
  # Match the short name (ddev-drupal-contrib) or the org/name form.
  printf '%s' "$INSTALLED_LIST" | grep -Eq "(^|[[:space:]/])${short}([[:space:]]|$)" && return 0
  printf '%s' "$INSTALLED_LIST" | grep -Fq "$full" && return 0
  return 1
}

# neutralize_contrib_symlink — in the recommended-project layout (Drupal at the
# repo root, the subject under <docroot>/modules/custom), ddev-drupal-contrib's
# symlink-project step finds no *.info.yml at the repo root, derives a name from
# the DDEV project, and creates a spurious <docroot>/modules/custom/<project>/
# full of symlinks back to the project's composer.json/.ddev/etc. Disable that
# post-start hook (idempotently, BEFORE the restart so the dir is never created)
# and remove any dir an earlier run already produced. Skipped when a *.info.yml
# IS at the repo root — that is the module-at-root layout the add-on is built
# for, and its symlink behavior is correct there.
neutralize_contrib_symlink() {
  local cfg="$PROJECT_DIR/.ddev/config.contrib.yaml"
  [[ -f "$cfg" ]] || return 0
  if ls "$PROJECT_DIR"/*.info.yml >/dev/null 2>&1; then
    return 0
  fi
  if grep -q 'ddev symlink-project' "$cfg" 2>/dev/null; then
    log_step "Disabling ddev-drupal-contrib symlink-project (recommended-project layout)"
    sed -i 's#ddev symlink-project#: # symlink-project disabled by drupilot (recommended-project layout)#' "$cfg"
    CHANGED=1
    log_ok "symlink-project hook neutralized in config.contrib.yaml."
  fi
  # Remove a spurious symlink dir from earlier runs: a dir under modules/custom
  # with NO *.info.yml whose composer.json or .ddev entry is a symlink.
  local custom="$PROJECT_DIR/$DOCROOT/modules/custom" d
  if [[ -d "$custom" ]]; then
    for d in "$custom"/*/; do
      [[ -d "$d" ]] || continue
      if ! ls "$d"*.info.yml >/dev/null 2>&1 && { [[ -L "${d}composer.json" ]] || [[ -L "${d}.ddev" ]]; }; then
        log_warn "Removing spurious symlink dir from symlink-project: ${d%/}"
        rm -rf "${d%/}"
        CHANGED=1
      fi
    done
  fi
}

CHANGED=0

# ---------------------------------------------------------------------------
# Contrib add-on (HARD: failure aborts).
# ---------------------------------------------------------------------------
if [[ "$WANT_CONTRIB" == "1" ]]; then
  if addon_installed "$CONTRIB_ADDON"; then
    log_ok "Add-on already installed: $CONTRIB_ADDON — skipping."
  else
    log_step "Installing add-on: $CONTRIB_ADDON"
    if ( cd "$PROJECT_DIR" && ddev add-on get "$CONTRIB_ADDON" ); then
      log_ok "Installed $CONTRIB_ADDON."
      CHANGED=1
    else
      die "Failed to install the required add-on '$CONTRIB_ADDON'. See 'ddev logs' and https://github.com/ddev/ddev-drupal-contrib" 1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Selenium add-on (SOFT: failure warns and continues).
# ---------------------------------------------------------------------------
SELENIUM_OK=1
if [[ "$WANT_SELENIUM" == "1" ]]; then
  if addon_installed "$SELENIUM_ADDON"; then
    log_ok "Add-on already installed: $SELENIUM_ADDON — skipping."
  else
    log_step "Installing add-on: $SELENIUM_ADDON (for FunctionalJavascript tests)"
    if ( cd "$PROJECT_DIR" && ddev add-on get "$SELENIUM_ADDON" ); then
      log_ok "Installed $SELENIUM_ADDON."
      CHANGED=1
    else
      SELENIUM_OK=0
      log_warn "Could not install '$SELENIUM_ADDON'. Continuing without it."
      log_warn "FunctionalJavascript tests will be SKIPPED until Selenium is available."
      log_warn "Retry later: (cd '$PROJECT_DIR' && ddev add-on get $SELENIUM_ADDON && ddev restart)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Neutralize ddev-drupal-contrib's symlink-project in the recommended-project
# layout. Must run BEFORE the restart so the spurious symlink dir is never
# created (it is generated by the add-on's post-start hook).
# ---------------------------------------------------------------------------
if [[ "$WANT_CONTRIB" == "1" ]]; then
  neutralize_contrib_symlink
fi

# ---------------------------------------------------------------------------
# Restart only if something changed (idempotent).
# ---------------------------------------------------------------------------
if [[ "$CHANGED" == "1" ]]; then
  log_step "Restarting DDEV so the new add-ons take effect"
  if ! ( cd "$PROJECT_DIR" && ddev restart ); then
    log_warn "'ddev restart' reported a problem. Run it manually inside '$PROJECT_DIR' and check 'ddev logs'."
  else
    log_ok "DDEV restarted."
  fi
else
  log_ok "No add-on changes — restart not needed."
fi

# ---------------------------------------------------------------------------
# Reminder: read the generated config for the real webdriver host (PROMPT 2.5).
# ---------------------------------------------------------------------------
if [[ "$WANT_SELENIUM" == "1" && "$SELENIUM_OK" == "1" ]]; then
  log_info "When configuring MINK_DRIVER_ARGS_WEBDRIVER, read the generated DDEV YAML for the real"
  log_info "webdriver host instead of assuming 'selenium-chrome' (PROMPT 2.5 / 7.1)."
fi

# Record the installed add-on versions in the reproducibility lockfile (best-effort).
bash "$PLUGIN_ROOT_DIR/scripts/env/lock-sync.sh" --dir "$PROJECT_DIR" >/dev/null 2>&1 || true

hr
if [[ "$WANT_SELENIUM" == "1" && "$SELENIUM_OK" == "0" ]]; then
  log_warn "Add-ons installed except Selenium (soft failure). JS tests are unavailable for now."
else
  log_ok "DDEV add-ons are ready."
fi
exit 0
