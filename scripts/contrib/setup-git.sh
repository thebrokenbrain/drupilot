#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/contrib/setup-git.sh
# Configure the git identity used for Drupal.org contributions (PROMPT 3.1).
#
# Sets git global user.name / user.email. Idempotent: if both are already set it
# reports them and does nothing (unless explicit --name/--email override them).
# When a value is missing and a TTY is available it prompts; without a TTY it
# leaves the missing value alone and prints guidance (never blocks).
#
# Usage:
#   setup-git.sh [--name NAME] [--email EMAIL]
#
# Notes:
#   • The email should be the one linked to your drupal.org account.
#   • This touches only the GLOBAL git config; it writes no credentials.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

NAME=""
EMAIL=""

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2;;
    --name=*) NAME="${1#*=}"; shift;;
    --email) EMAIL="${2:-}"; shift 2;;
    --email=*) EMAIL="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

have_cmd git || die "git is not installed. Install it first (see /drupilot-doctor)." 1

CUR_NAME="$(git config --global user.name 2>/dev/null || true)"
CUR_EMAIL="$(git config --global user.email 2>/dev/null || true)"

log_step "git identity for Drupal.org contributions"

if [[ -n "$CUR_NAME" || -n "$CUR_EMAIL" ]]; then
  log_info "Current global identity: ${CUR_NAME:-<unset>} <${CUR_EMAIL:-unset}>"
fi

# Resolve the desired name: explicit arg > existing value > prompt (if TTY).
prompt_value() {
  # prompt_value <label> <default>
  local label="$1" def="$2" ans=""
  if [[ ! -r /dev/tty ]]; then
    printf '%s' "$def"; return 0
  fi
  if [[ -n "$def" ]]; then
    printf 'Enter %s [%s]: ' "$label" "$def" >&2
  else
    printf 'Enter %s: ' "$label" >&2
  fi
  read -r ans </dev/tty || true
  ans="$(trim "$ans")"
  [[ -z "$ans" ]] && ans="$def"
  printf '%s' "$ans"
}

# Determine target values without clobbering when nothing new is provided.
TARGET_NAME="${NAME:-$CUR_NAME}"
TARGET_EMAIL="${EMAIL:-$CUR_EMAIL}"

if [[ -z "$TARGET_NAME" ]]; then
  TARGET_NAME="$(prompt_value "your real name" "")"
fi
if [[ -z "$TARGET_EMAIL" ]]; then
  TARGET_EMAIL="$(prompt_value "the email linked to your drupal.org account" "")"
fi

CHANGED=0

# Apply user.name (idempotent: only writes if it differs).
if [[ -n "$TARGET_NAME" ]]; then
  if [[ "$TARGET_NAME" != "$CUR_NAME" ]]; then
    git config --global user.name "$TARGET_NAME"
    log_ok "Set user.name = $TARGET_NAME"
    CHANGED=1
  else
    log_info "user.name already set to '$CUR_NAME' (unchanged)."
  fi
else
  log_warn "user.name not set. Run: git config --global user.name \"Real Name\""
fi

# Apply user.email (idempotent).
if [[ -n "$TARGET_EMAIL" ]]; then
  if [[ "$TARGET_EMAIL" != "$CUR_EMAIL" ]]; then
    git config --global user.email "$TARGET_EMAIL"
    log_ok "Set user.email = $TARGET_EMAIL"
    CHANGED=1
  else
    log_info "user.email already set to '$CUR_EMAIL' (unchanged)."
  fi
else
  log_warn "user.email not set. Run: git config --global user.email <email-linked-to-drupal.org>"
fi

hr
if [[ -n "$TARGET_NAME" && -n "$TARGET_EMAIL" ]]; then
  log_ok "git identity ready: $TARGET_NAME <$TARGET_EMAIL>"
  [[ "$CHANGED" == "0" ]] && log_info "Nothing to change (already configured)."
  exit 0
else
  log_warn "git identity incomplete. Commits to Drupal.org need both a real name and the email linked to your account."
  exit 0
fi
