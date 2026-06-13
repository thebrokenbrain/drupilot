#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/contrib/check-prereqs.sh
# Contribution prerequisites check (PROMPT 3.1 / 5.7).
#
# Runs the preflight 'contribute' profile (git + SSH key OR PAT), then layers on
# contribution-specific guidance: git identity, drupal.org account / GitLab ToS
# reminder, and — with --project — whether the project exists on drupal.org.
#
# This is a READ-ONLY check: it never pushes, never writes credentials, and never
# prints the PAT. It tells the user what is missing and how to fix it, then stops.
#
# Usage:
#   check-prereqs.sh [--json] [--project NAME]
#
# Output:
#   --json   -> a single JSON object on STDOUT:
#               { ready, project, project_exists, git_identity:{name,email,ok},
#                 ssh_key, pat, api_helper, preflight:{...} }
#   default  -> a human-readable English report (STDOUT) + guidance (STDERR).
#
# Exit codes:
#   0  -> ready to contribute (hard requirements satisfied).
#   2  -> a hard requirement is missing (mirrors preflight).
#   1  -> usage/internal error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

AS_JSON=0
PROJECT=""

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) AS_JSON=1; shift;;
    --project) PROJECT="${2:-}"; shift 2;;
    --project=*) PROJECT="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

PREFLIGHT="$(plugin_root)/scripts/env/preflight.sh"
[[ -r "$PREFLIGHT" ]] || die "preflight.sh not found at $PREFLIGHT" 1

# ---------------------------------------------------------------------------
# Run the contribute-profile preflight (captures the structured report).
# Exit status tells us whether hard requirements are satisfied.
# ---------------------------------------------------------------------------
PF_JSON=""
PF_RC=0
PF_JSON="$(bash "$PREFLIGHT" --profile contribute --json --quiet 2>/dev/null)" || PF_RC=$?

if [[ -z "$PF_JSON" ]]; then
  die "Could not run the contribution preflight. Is jq installed?" 1
fi

READY="$(printf '%s' "$PF_JSON" | jq -r '.ready.contribute')"
SSH_OK="$(printf '%s' "$PF_JSON" | jq -r '.checks[] | select(.id=="ssh_key")  | .ok')"
PAT_OK="$(printf '%s' "$PF_JSON" | jq -r '.checks[] | select(.id=="pat")      | .ok')"
API_OK="$(printf '%s' "$PF_JSON" | jq -r '.checks[] | select(.id=="api_helper") | .ok')"

# ---------------------------------------------------------------------------
# Git identity (also surfaced by preflight, repeated here for actionable output)
# ---------------------------------------------------------------------------
GIT_NAME="$(git config --global user.name 2>/dev/null || true)"
GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
GIT_ID_OK="false"
[[ -n "$GIT_NAME" && -n "$GIT_EMAIL" ]] && GIT_ID_OK="true"

# ---------------------------------------------------------------------------
# Contribution links (from .contrib.*)
# ---------------------------------------------------------------------------
REGISTER_URL="$(config_json .contrib.register_url "https://www.drupal.org/user/register")"
DRUPALCODE_ACCESS_URL="$(config_json .contrib.drupalcode_access_url "https://www.drupal.org/user/me/edit")"
SSH_KEYS_URL="$(config_json .contrib.ssh_keys_url "https://git.drupalcode.org/-/user_settings/ssh_keys")"
PAT_URL="$(config_json .contrib.pat_url "https://git.drupalcode.org/-/user_settings/personal_access_tokens")"
PAT_ENV_VAR="$(config_json .contrib.pat_env_var "DRUPILOT_GITLAB_PAT")"
SSH_TEST_TARGET="$(config_json .contrib.ssh_test_target "git@git.drupal.org")"

# ---------------------------------------------------------------------------
# Optional: does the project exist on drupal.org? (HEAD request, best-effort)
# ---------------------------------------------------------------------------
PROJECT_EXISTS="unknown"
if [[ -n "$PROJECT" ]]; then
  if have_cmd curl; then
    if curl -fsI "https://www.drupal.org/project/$PROJECT" >/dev/null 2>&1; then
      PROJECT_EXISTS="true"
    else
      PROJECT_EXISTS="false"
    fi
  else
    PROJECT_EXISTS="unknown"
  fi
fi

# ---------------------------------------------------------------------------
# JSON output
# ---------------------------------------------------------------------------
if [[ "$AS_JSON" == "1" ]]; then
  jq -n \
    --argjson ready "$READY" \
    --arg project "$PROJECT" \
    --arg project_exists "$PROJECT_EXISTS" \
    --arg gname "$GIT_NAME" --arg gemail "$GIT_EMAIL" --argjson gok "$GIT_ID_OK" \
    --argjson ssh "$SSH_OK" --argjson pat "$PAT_OK" --argjson api "$API_OK" \
    --argjson preflight "$PF_JSON" \
    '{ready:$ready,
      project:$project,
      project_exists:$project_exists,
      git_identity:{name:$gname,email:$gemail,ok:$gok},
      ssh_key:$ssh, pat:$pat, api_helper:$api,
      preflight:$preflight}'
  [[ "$READY" == "true" ]] && exit 0 || exit 2
fi

# ---------------------------------------------------------------------------
# Human report
# ---------------------------------------------------------------------------
badge() { [[ "$1" == "true" ]] && printf '✅' || printf '❌'; }
soft_badge() { [[ "$1" == "true" ]] && printf '✅' || printf '⚠️'; }

log_step "Drupal.org contribution prerequisites"

printf '  %s git available + authentication (SSH key or PAT)\n' "$(badge "$READY")" >&2
printf '  %s SSH key on disk\n' "$(soft_badge "$SSH_OK")" >&2
printf '  %s GitLab PAT in $%s (HTTPS / API alternative)\n' "$(soft_badge "$PAT_OK")" "$PAT_ENV_VAR" >&2
printf '  %s git identity (user.name + user.email)\n' "$(soft_badge "$GIT_ID_OK")" >&2
if [[ "$GIT_ID_OK" == "true" ]]; then
  log_plain "       ↳ $GIT_NAME <$GIT_EMAIL>"
fi
printf '  %s glab/curl for the GitLab API (optional, degradable)\n' "$(soft_badge "$API_OK")" >&2

if [[ -n "$PROJECT" ]]; then
  case "$PROJECT_EXISTS" in
    true)    log_ok "Project '$PROJECT' exists on drupal.org (https://www.drupal.org/project/$PROJECT)";;
    false)   log_warn "Could not find project '$PROJECT' on drupal.org. Double-check the machine name; only existing contrib projects can receive issue forks / MRs.";;
    unknown) log_warn "Cannot check whether '$PROJECT' exists on drupal.org (curl not available).";;
  esac
fi

hr
# Actionable guidance for what is missing.
if [[ "$SSH_OK" != "true" && "$PAT_OK" != "true" ]]; then
  log_err "No authentication configured. You need ONE of:"
  log_plain "   • SSH (recommended for push): ssh-keygen -t ed25519, upload the public key at $SSH_KEYS_URL, then test: ssh -T $SSH_TEST_TARGET"
  log_plain "   • HTTPS + PAT: create a token at $PAT_URL (scopes: read_repository, write_repository; add 'api' for MR creation), then export $PAT_ENV_VAR=... (never commit it)."
fi
if [[ "$GIT_ID_OK" != "true" ]]; then
  log_warn "Configure your git identity before committing:"
  log_plain "   git config --global user.name \"Real Name\""
  log_plain "   git config --global user.email <email-linked-to-drupal.org>"
  log_plain "   (or run: scripts/contrib/setup-git.sh)"
fi

log_info "Account checklist (cannot be verified automatically):"
log_plain "   • A drupal.org account with a confirmed email and your real name: $REGISTER_URL"
log_plain "   • Accept the GitLab Terms of Service in your profile's 'DrupalCode access' tab: $DRUPALCODE_ACCESS_URL"
log_plain "Reminder: contribution credit is assigned by maintainers via the issue's Contribution Record — it is not granted by the commit itself."

hr
if [[ "$READY" == "true" ]]; then
  log_ok "Ready to contribute."
  printf 'ready\n'
  exit 0
else
  log_err "Not ready to contribute — resolve the items above first."
  printf 'not-ready\n'
  exit 2
fi
