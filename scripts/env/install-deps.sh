#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/install-deps.sh
# OS-aware ASSISTED installation of the toolchain (opt-in). Detects the OS via
# os_id and uses its package manager (fedora->dnf, ubuntu/debian->apt-get,
# arch->pacman, macos->brew). Docker and DDEV are installed via their official
# installers.
#
# Privilege escalation:
#   - When SUDO_ASKPASS is set (the doctor command sets it up via the global
#     'sudo-askpass' skill, so sudo works without a TTY) we use `sudo -A`.
#   - Otherwise we fall back to plain `sudo` (needs an interactive terminal).
#   - On macOS, brew runs as the regular user (no sudo).
#
# Safety (PROMPT 4.4.3 / 7.5):
#   - NEVER installs without explicit confirmation, unless --yes or
#     DRUPILOT_ASSUME_YES=1.
#   - Idempotent: tools already present and OK are skipped.
#   - Docker is NOT force-configured: we print the group-add + re-login guidance
#     and leave that step to the user.
#
# Usage:
#   install-deps.sh [git|jq|php|composer|docker|ddev|all]... [--yes] [--dry-run] [-h|--help]
#
# Default selection (no args): all the tools that are currently missing.
#
# Exit codes:
#   0 -> requested installs succeeded or were skipped.
#   1 -> usage error / unsupported OS / an install failed.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ASSUME_YES=0
DRY_RUN=0
REQUESTED=()

[[ "${DRUPILOT_ASSUME_YES:-}" == "1" ]] && ASSUME_YES=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    git|jq|php|composer|docker|ddev|all) REQUESTED+=("$1"); shift;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

OS="$(os_id)"

# ---------------------------------------------------------------------------
# Privilege helper
# ---------------------------------------------------------------------------
# need_root -> 0 on Linux (package managers need root); 1 on macos (brew is user).
need_root() { [[ "$OS" != "macos" ]]; }

# run_root <cmd...> -> run a command with the right privilege escalation.
run_root() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would run: ${*}"
    return 0
  fi
  if ! need_root; then
    "$@"
    return $?
  fi
  if [[ "$(id -u)" == "0" ]]; then
    "$@"
  elif [[ -n "${SUDO_ASKPASS:-}" ]]; then
    sudo -A "$@"
  else
    log_warn "SUDO_ASKPASS is not set; using plain sudo (an interactive terminal may be required)."
    sudo "$@"
  fi
}

# run_user <cmd...> -> run as the current user (brew, official installers).
run_user() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would run: ${*}"
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# Per-tool "already OK?" detection (idempotency)
# ---------------------------------------------------------------------------
tool_ok() {
  case "$1" in
    git|jq|composer) have_cmd "$1";;
    php) have_cmd php;;
    docker) have_cmd docker;;        # daemon state is reported separately
    ddev) have_cmd ddev;;
    *) return 1;;
  esac
}

# ---------------------------------------------------------------------------
# Package-manager mapping for the simple OS packages
# ---------------------------------------------------------------------------
pkg_install() {
  # pkg_install <tool> -> install via the OS package manager. Returns non-zero
  # if the OS/tool combination is not handled here (caller falls back).
  local tool="$1" pkg=""
  case "$OS" in
    fedora)
      case "$tool" in
        git) pkg="git";;
        jq) pkg="jq";;
        php) pkg="php-cli";;
        *) return 3;;
      esac
      run_root dnf install -y "$pkg";;
    ubuntu|debian)
      case "$tool" in
        git) pkg="git";;
        jq) pkg="jq";;
        php) pkg="php-cli";;
        *) return 3;;
      esac
      run_root apt-get update -y && run_root apt-get install -y "$pkg";;
    arch)
      case "$tool" in
        git) pkg="git";;
        jq) pkg="jq";;
        php) pkg="php";;
        *) return 3;;
      esac
      run_root pacman -S --needed --noconfirm "$pkg";;
    macos)
      have_cmd brew || die "Homebrew is required on macOS. Install it from https://brew.sh and retry." 1
      case "$tool" in
        git) pkg="git";;
        jq) pkg="jq";;
        php) pkg="php";;
        *) return 3;;
      esac
      run_user brew install "$pkg";;
    *)
      return 2;;
  esac
}

# ---------------------------------------------------------------------------
# Composer (official installer; or package manager where reliable)
# ---------------------------------------------------------------------------
install_composer() {
  case "$OS" in
    macos)
      have_cmd brew && { run_user brew install composer; return $?; };;
    fedora) run_root dnf install -y composer && return 0;;
    arch) run_root pacman -S --needed --noconfirm composer && return 0;;
  esac
  # Generic official installer (works everywhere PHP is present).
  if ! have_cmd php; then
    log_warn "PHP is required to install Composer via the official installer. Inside DDEV you can use 'ddev composer' instead."
    return 1
  fi
  log_info "Installing Composer via the official installer (https://getcomposer.org)."
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would download and run the Composer installer, then move composer.phar to /usr/local/bin/composer"
    return 0
  fi
  local tmp; tmp="$(mktemp -d)"
  (
    cd "$tmp"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    php composer-setup.php --quiet
  )
  run_root install -m 0755 "$tmp/composer.phar" /usr/local/bin/composer
  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Docker (official Engine on Linux; Desktop/OrbStack/Colima on macOS)
# ---------------------------------------------------------------------------
install_docker() {
  case "$OS" in
    fedora|ubuntu|debian)
      log_info "Installing Docker Engine via the official convenience script (https://get.docker.com)."
      if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[dry-run] would run: curl -fsSL https://get.docker.com | sh"
      else
        if have_cmd curl; then curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        elif have_cmd wget; then wget -qO /tmp/get-docker.sh https://get.docker.com
        else die "Need curl or wget to fetch the Docker installer." 1; fi
        run_root sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
      fi
      ;;
    arch)
      run_root pacman -S --needed --noconfirm docker
      ;;
    macos)
      log_warn "On macOS install a Docker provider manually (Docker Desktop, OrbStack, or Colima):"
      log_plain "  https://docs.docker.com/desktop/install/mac-install/"
      log_plain "  https://orbstack.dev/   |   https://github.com/abiosoft/colima"
      return 0
      ;;
    *)
      log_warn "Unsupported OS for automatic Docker install. See https://docs.docker.com/engine/install/"
      return 1
      ;;
  esac

  # Post-install guidance — never forced (PROMPT 4.4.3).
  if [[ "$OS" != "macos" ]]; then
    log_step "Docker post-install (manual — not done automatically)"
    log_plain "  1) Add your user to the 'docker' group:   sudo usermod -aG docker \"$USER\""
    log_plain "  2) Log out and back in (or run 'newgrp docker') so the new group applies."
    log_plain "  3) Enable + start the daemon:              sudo systemctl enable --now docker"
    log_plain "  Until then 'docker' commands may require sudo or report the daemon is down."
  fi
}

# ---------------------------------------------------------------------------
# DDEV (official installer)
# ---------------------------------------------------------------------------
install_ddev() {
  case "$OS" in
    macos)
      if have_cmd brew; then
        run_user brew install ddev/ddev/ddev
        return $?
      fi
      ;;
  esac
  log_info "Installing DDEV via the official installer (https://ddev.readthedocs.io)."
  if [[ "$DRY_RUN" == "1" ]]; then
    log_info "[dry-run] would run: curl -fsSL https://ddev.com/install.sh | bash"
    return 0
  fi
  if have_cmd curl; then curl -fsSL https://ddev.com/install.sh -o /tmp/ddev-install.sh
  elif have_cmd wget; then wget -qO /tmp/ddev-install.sh https://ddev.com/install.sh
  else die "Need curl or wget to fetch the DDEV installer." 1; fi
  # The DDEV installer escalates with sudo internally as needed.
  bash /tmp/ddev-install.sh
  rm -f /tmp/ddev-install.sh
}

# ---------------------------------------------------------------------------
# Dispatch one tool
# ---------------------------------------------------------------------------
install_one() {
  local tool="$1"
  if tool_ok "$tool"; then
    log_ok "$tool is already installed ($(tool_version "$tool" 2>/dev/null || echo present)) — skipping."
    return 0
  fi
  case "$tool" in
    git|jq|php)
      pkg_install "$tool" || die "Could not install '$tool' on OS '$OS'. Install it manually and retry." 1;;
    composer) install_composer || die "Composer installation failed. See https://getcomposer.org/download/" 1;;
    docker) install_docker || die "Docker installation failed. See https://docs.docker.com/engine/install/" 1;;
    ddev) install_ddev || die "DDEV installation failed. See https://ddev.readthedocs.io/en/stable/users/install/" 1;;
    *) die "Unknown tool: $tool" 1;;
  esac
  if tool_ok "$tool"; then
    log_ok "$tool installed."
  else
    log_warn "$tool may need a new shell / re-login before it is visible on PATH."
  fi
}

# ---------------------------------------------------------------------------
# Build the work list
# ---------------------------------------------------------------------------
ALL_TOOLS=(git jq php composer docker ddev)

SELECTED=()
if [[ ${#REQUESTED[@]} -eq 0 ]]; then
  # No args -> only the tools that are currently missing.
  for t in "${ALL_TOOLS[@]}"; do tool_ok "$t" || SELECTED+=("$t"); done
else
  for r in "${REQUESTED[@]}"; do
    if [[ "$r" == "all" ]]; then SELECTED=("${ALL_TOOLS[@]}"); break; fi
    SELECTED+=("$r")
  done
fi

if [[ ${#SELECTED[@]} -eq 0 ]]; then
  log_ok "Everything requested is already installed. Nothing to do."
  exit 0
fi

case "$OS" in
  fedora|ubuntu|debian|arch|macos) : ;;
  *) die "Unsupported OS '$OS' for assisted install. See /drupilot-doctor for manual instructions." 1;;
esac

# ---------------------------------------------------------------------------
# Confirm and run
# ---------------------------------------------------------------------------
log_step "drupilot — assisted installation"
log_plain "Detected OS: $OS"
log_plain "Will attempt to install: ${SELECTED[*]}"
if need_root && [[ -z "${SUDO_ASKPASS:-}" && "$(id -u)" != "0" ]]; then
  log_warn "SUDO_ASKPASS is not set. Privileged steps will use plain sudo and may prompt on a terminal."
fi

if [[ "$ASSUME_YES" != "1" ]]; then
  if ! confirm "Proceed with installation?" 0; then
    log_info "Aborted by user. Nothing was installed."
    exit 0
  fi
fi

FAILED=()
for t in "${SELECTED[@]}"; do
  log_step "Installing: $t"
  if ! install_one "$t"; then
    FAILED+=("$t")
  fi
done

hr
if [[ ${#FAILED[@]} -gt 0 ]]; then
  log_err "Some installs failed or need attention: ${FAILED[*]}"
  log_plain "Re-run /drupilot-doctor to re-check, and consult the printed install links."
  exit 1
fi
log_ok "Done. Run /drupilot-doctor (or detect-php.sh) to confirm the environment."
exit 0
