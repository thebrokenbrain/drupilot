#!/usr/bin/env bash
# =============================================================================
# drupilot — hooks/scripts/guard-contrib.sh
# PreToolUse hook for Bash (outward-facing action guard, PROMPT 5.9).
#
# Inspects the Bash command about to run. When it is an outward-facing
# contribution action (git push, push to git.drupal.org / issue/ remotes,
# `glab mr ...`, or a curl to a GitLab API) it returns permissionDecision "ask"
# with an English reason so the developer confirms before anything leaves the
# machine. Precedence: DRUPILOT_AUTONOMOUS=true ALWAYS asks (an autonomous run
# must never push on its own, even in 'auto' contribution mode); otherwise
# DRUPILOT_CONTRIB_MODE=semi asks and 'auto' allows. Everything else is a no-op.
#
# Fail-safe contract (CONTRACT 5.4):
#   * never `set -e`, never exit non-zero;
#   * print JSON on STDOUT to act, nothing to no-op (the safe default);
#   * parsing guarded with `|| true`.
# =============================================================================
set -uo pipefail

# shellcheck source=../../scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh" 2>/dev/null || true

# emit_decision <allow|deny|ask> <reason> — prints the PreToolUse payload, exits 0.
emit_decision() {
  local decision="$1" reason="$2"
  if have_cmd jq; then
    jq -n --arg d "$decision" --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}' 2>/dev/null || true
  fi
  exit 0
}

# --- Read hook input ---------------------------------------------------------
INPUT="$(cat 2>/dev/null || true)"

# Without jq we cannot reliably inspect the command -> no-op (default allow).
have_cmd jq || exit 0

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[[ -z "$CMD" ]] && exit 0

# --- Is this an outward-facing contribution action? --------------------------
# Match on the resolved GitLab hosts from defaults.json (with sane fallbacks)
# plus the generic push / MR / GitLab-API patterns.
GITLAB_SSH_HOST="$(config_json .contrib.gitlab_host "git.drupal.org" 2>/dev/null || true)"
GITLAB_HTTPS_HOST="$(config_json .contrib.gitlab_https_host "git.drupalcode.org" 2>/dev/null || true)"
[[ -z "$GITLAB_SSH_HOST" ]] && GITLAB_SSH_HOST="git.drupal.org"
[[ -z "$GITLAB_HTTPS_HOST" ]] && GITLAB_HTTPS_HOST="git.drupalcode.org"

OUTWARD=0
REASON=""

# git push (to any remote — this is the classic outward action).
if printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+([^;&|]*[[:space:]])?push([[:space:]]|$)'; then
  OUTWARD=1
  REASON="This command runs 'git push', which publishes commits to a remote."
fi

# Any reference to the Drupal GitLab hosts or an issue fork remote.
if printf '%s' "$CMD" | grep -qE "${GITLAB_SSH_HOST//./\\.}|${GITLAB_HTTPS_HOST//./\\.}|git@git\.drupal\.org:issue/|/issue/"; then
  OUTWARD=1
  [[ -z "$REASON" ]] && REASON="This command targets the Drupal.org GitLab (issue fork remote)."
fi

# glab mr ... (open/manage a Merge Request via the GitLab CLI).
if printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])glab[[:space:]]+([^;&|]*[[:space:]])?mr([[:space:]]|$)'; then
  OUTWARD=1
  REASON="This command uses 'glab mr', which opens or manages a Merge Request."
fi

# curl to a GitLab API endpoint (.../api/v4/...), typically MR creation.
if printf '%s' "$CMD" | grep -qiE '(^|[;&|[:space:]])curl([[:space:]]|$)' \
   && printf '%s' "$CMD" | grep -qE '/api/v[0-9]+/'; then
  OUTWARD=1
  REASON="This command calls a GitLab API endpoint with curl (likely to open/manage an MR)."
fi

# Not outward-facing -> let it through silently.
[[ "$OUTWARD" == "1" ]] || exit 0

# --- Autonomy override (enforces the documented promise) ---------------------
# An autonomous run (DRUPILOT_AUTONOMOUS=true) must NEVER perform an outward-facing
# action — not even in 'auto' contribution mode. The orchestrator does not issue
# these commands in autonomous mode; this backstop enforces the promise if one
# ever slips through, by requiring a human confirmation that an unattended run
# cannot give. It takes precedence over DRUPILOT_CONTRIB_MODE.
if config_bool DRUPILOT_AUTONOMOUS 0; then
  emit_decision "ask" "drupilot is in AUTONOMOUS mode, which never performs outward-facing actions on its own. ${REASON} A human must confirm this — an unattended run will not proceed. To contribute, run /drupilot-contribute yourself. You can get a local patch any time with /drupilot-patch (no push, no network)."
fi

# --- Decide based on the contribution mode -----------------------------------
MODE="$(config_get DRUPILOT_CONTRIB_MODE "semi" 2>/dev/null || true)"
[[ -z "$MODE" ]] && MODE="semi"

case "${MODE,,}" in
  auto)
    # Fully-automated mode: allow outward-facing actions (no extra prompt).
    emit_decision "allow" "drupilot contribution mode is 'auto': outward-facing action allowed (${REASON})"
    ;;
  semi|*)
    # Semi-automated mode (default): require explicit confirmation.
    emit_decision "ask" "drupilot is in 'semi' contribution mode. ${REASON} Confirm before it leaves your machine. Reminder: credit on Drupal.org is granted by maintainers via the issue's Contribution Record. Prefer a dry run first? /drupilot-patch writes a local patch with no push. Set DRUPILOT_CONTRIB_MODE=auto to skip these confirmations."
    ;;
esac
