#!/usr/bin/env bash
# =============================================================================
# drupilot — hooks/scripts/guard-contrib.sh
# PreToolUse hook for Bash (outward-facing action guard, PROMPT 5.9).
#
# Inspects the Bash command about to run. When it is an outward-facing
# contribution action (git push, push to git.drupal.org / issue/ remotes,
# `glab mr ...`, or a curl to a GitLab API) it returns permissionDecision "ask"
# with an English reason so the developer confirms before anything leaves the
# machine. Precedence: DRUPILOT_AUTONOMOUS=true or DRUPILOT_NONINTERACTIVE=1
# (environment, or a prefix of the command) ALWAYS asks (an unattended run
# must never push on its own, even in 'auto' contribution mode); otherwise
# DRUPILOT_CONTRIB_MODE=semi asks and 'auto' allows. Everything else is a no-op.
#
# It also asks before a `git commit` that SKIPS the repository's git hooks
# (--no-verify / -n, or `git -c core.hooksPath=...`) when the repository really
# has an active pre-commit or commit-msg hook (GrumPHP, husky, lefthook, ...).
# drupilot never normalizes skipping hooks: let them run, or substitute their
# tasks with scripts/contrib/git-hooks.sh --run-equivalents and record it. This
# check applies in every contribution mode and in autonomous mode (an unattended
# run cannot confirm, so it does not skip the hooks); DRUPILOT_HOOKS_GUARD=off
# disables it. It only asks, never denies, and changes nothing else.
#
# Fail-safe contract (CONTRACT 5.4):
#   * never `set -e`, never exit non-zero;
#   * print JSON on STDOUT to act, nothing to no-op (the safe default);
#   * parsing guarded with `|| true`.
# =============================================================================
set -uo pipefail

# Only the shared-library domains this hook may reach (scripts/dev/check.sh,
# gate lib-defs, checks the list with a static scan, where a function name in a
# message counts too).
_DRUPILOT_LIBS="core paths config subject git interact"
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

# --- Does a `git commit` skip the repository's hooks? -------------------------
# commit_hook_bypass <cmd> -> prints "<what>\t<git -C dir or empty>" for the first
# `git ... commit` segment that skips hooks, nothing otherwise. The WHOLE command
# is scanned as one buffer, so the quote state carries across lines (a
# `-m "$(cat <<EOF ... EOF)"` message is one blanked string) and a
# backslash-newline continuation joins its lines. Quoted strings are blanked
# (so `-m "-n"` is a message, not a flag), the command is cut at unquoted
# ; & | and newlines, and a segment counts only when `git` is its command word
# (after VAR=value assignments and sudo/command/env/time/exec/nohup or a shell
# keyword), so `echo git commit -n` is not a commit. Each commit's options are
# walked like git does: --no-verify or an unambiguous prefix (--no-veri...), -n
# anywhere in a short cluster before a value-taking letter (m F C c t take the
# rest of the cluster or the next word; u S an attached value), `--` ends the
# options.
commit_hook_bypass() {
  printf '%s\n' "$1" | awk '
    { buf = buf $0 "\n" }
    END {
      out = ""; q = ""; L = length(buf)
      for (i = 1; i <= L; i++) {
        c = substr(buf, i, 1)
        if (q == "\047") { if (c == q) q = ""; continue }
        if (q == "\"") {
          if (c == "\\") { i++; continue }
          if (c == q) q = ""
          continue
        }
        if (c == "\\") {
          # Outside quotes: a backslash-newline is a line continuation; any
          # other escaped character is a literal (never a quote or separator).
          if (substr(buf, i + 1, 1) == "\n") { out = out " " } else { out = out "E" }
          i++; continue
        }
        if (c == "\"" || c == "\047") { q = c; out = out "Q"; continue }
        if (c == ";" || c == "&" || c == "|" || c == "\n") { out = out "\n"; continue }
        out = out c
      }
      nseg = split(out, segs, "\n")
      for (s = 1; s <= nseg; s++) {
        n = split(segs[s], t, /[ \t]+/)
        g = 0
        for (k = 1; k <= n; k++) {
          w = t[k]
          sub(/^[({]+/, "", w)
          if (w == "") continue
          if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
          if (w ~ /^(sudo|command|env|time|exec|nohup|then|do|else|elif|if|while|until|!)$/) continue
          if (w == "git" || w ~ /\/git$/) g = k
          break
        }
        if (!g) continue
        dir = ""; hp = 0; k = g + 1
        while (k <= n && t[k] ~ /^-/) {
          if (t[k] == "-C") { dir = t[k+1]; k += 2; continue }
          if (t[k] == "-c") { if (tolower(t[k+1]) ~ /^core\.hookspath=/) hp = 1; k += 2; continue }
          k++
        }
        if (t[k] != "commit") continue
        if (hp) { print "overrides core.hooksPath\t" dir; exit }
        for (k = k + 1; k <= n; k++) {
          a = t[k]
          if (a == "--") break
          if (a ~ /^--/) {
            if (length(a) >= 9 && index("--no-verify", a) == 1) { print "--no-verify\t" dir; exit }
            if (a !~ /=/ && a ~ /^--(message|file|reuse-message|reedit-message|fixup|squash|author|date|template|cleanup|trailer|pathspec-from-file)$/) k++
            continue
          }
          if (a ~ /^-[A-Za-z]+$/) {
            for (j = 2; j <= length(a); j++) {
              ch = substr(a, j, 1)
              if (ch == "n") { print "-n (--no-verify)\t" dir; exit }
              if (index("mFCct", ch)) { if (j == length(a)) k++; break }
              if (index("uS", ch)) break
            }
          }
        }
      }
    }'
  return 0
}

HOOKS_REASON=""
_hguard="$(config_get DRUPILOT_HOOKS_GUARD ask 2>/dev/null || echo ask)"
if [[ "$(lc "$_hguard")" != "off" ]] && printf '%s' "$CMD" | grep_q -E '(^|[^[:alnum:]_.-])git([[:space:]]|$)'; then
  _bypass="$(commit_hook_bypass "$CMD" 2>/dev/null || true)"
  if [[ -n "$_bypass" ]]; then
    _what="${_bypass%%$'\t'*}"; _cdir="${_bypass#*$'\t'}"
    _cwd="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
    [[ -n "$_cwd" ]] || _cwd="$PWD"
    if [[ -n "$_cdir" ]]; then
      case "$_cdir" in /*) _cwd="$_cdir";; "~"/*) _cwd="$HOME/${_cdir#"~"/}";; *) _cwd="$_cwd/$_cdir";; esac
    fi
    # Only the hooks --no-verify actually skips (pre-commit, commit-msg) matter.
    _active="$(git_active_commit_hooks "$_cwd" 2>/dev/null | grep -E '^(pre-commit|commit-msg)$' | tr '\n' ' ' || true)"
    _active="$(trim "$_active" 2>/dev/null || printf '%s' "$_active")"
    if [[ -n "$_active" ]]; then
      HOOKS_REASON="This 'git commit' skips the repository's git hooks (${_what}; active: ${_active}). drupilot never normalizes skipping them: let the hooks run (use a longer timeout or run the commit in the background if they are slow), or, only if a hook cannot complete here, run scripts/contrib/git-hooks.sh --subject <dir> --run-equivalents and record in the port report which validations replaced it. Set DRUPILOT_HOOKS_GUARD=off to disable this check."
    fi
  fi
fi

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
if printf '%s' "$CMD" | grep_q -E '(^|[;&|[:space:]])git[[:space:]]+([^;&|]*[[:space:]])?push([[:space:]]|$)'; then
  OUTWARD=1
  REASON="This command runs 'git push', which publishes commits to a remote."
fi

# Any reference to the Drupal GitLab hosts or an issue fork remote.
if printf '%s' "$CMD" | grep_q -E "${GITLAB_SSH_HOST//./\\.}|${GITLAB_HTTPS_HOST//./\\.}|git@git\.drupal\.org:issue/|/issue/"; then
  OUTWARD=1
  [[ -z "$REASON" ]] && REASON="This command targets the Drupal.org GitLab (issue fork remote)."
fi

# glab mr ... (open/manage a Merge Request via the GitLab CLI).
if printf '%s' "$CMD" | grep_q -E '(^|[;&|[:space:]])glab[[:space:]]+([^;&|]*[[:space:]])?mr([[:space:]]|$)'; then
  OUTWARD=1
  REASON="This command uses 'glab mr', which opens or manages a Merge Request."
fi

# curl to a GitLab API endpoint (.../api/v4/...), typically MR creation.
if printf '%s' "$CMD" | grep_q -iE '(^|[;&|[:space:]])curl([[:space:]]|$)' \
   && printf '%s' "$CMD" | grep_q -E '/api/v[0-9]+/'; then
  OUTWARD=1
  REASON="This command calls a GitLab API endpoint with curl (likely to open/manage an MR)."
fi

# Not outward-facing -> let it through silently (unless it skips the hooks).
if [[ "$OUTWARD" != "1" ]]; then
  [[ -n "$HOOKS_REASON" ]] && emit_decision "ask" "$HOOKS_REASON"
  exit 0
fi

# --- Autonomy override (enforces the documented promise) ---------------------
# An autonomous run (DRUPILOT_AUTONOMOUS=true) must NEVER perform an outward-facing
# action — not even in 'auto' contribution mode. The orchestrator does not issue
# these commands in autonomous mode; this backstop enforces the promise if one
# ever slips through, by requiring a human confirmation that an unattended run
# cannot give. It takes precedence over DRUPILOT_CONTRIB_MODE.
# A non-interactive wrapper run (`/drupilot --no-confirm`, or the canonical
# DRUPILOT_NONINTERACTIVE=1 in the environment or as a prefix of the command
# itself, which is how the router passes it) promises the same: it is treated
# as autonomous here.
UNATTENDED=0
config_bool DRUPILOT_AUTONOMOUS 0 && UNATTENDED=1
case "$(lc "${DRUPILOT_NONINTERACTIVE:-}")" in 1|true|yes|on) UNATTENDED=1;; esac
if printf '%s' "$CMD" | grep_q -iE '(^|[;&|[:space:]])(env[[:space:]]+)?DRUPILOT_(NONINTERACTIVE|AUTONOMOUS)=["'"'"']?(1|true|yes|on)([^A-Za-z0-9_]|$)'; then
  UNATTENDED=1
fi
if [[ "$UNATTENDED" == "1" ]]; then
  emit_decision "ask" "drupilot is in AUTONOMOUS (or non-interactive) mode, which never performs outward-facing actions on its own. ${REASON} A human must confirm this — an unattended run will not proceed. To contribute, run /drupilot-contribute yourself. You can get a local patch any time with /drupilot-patch (no push, no network).${HOOKS_REASON:+ Also: $HOOKS_REASON}"
fi

# --- Decide based on the contribution mode -----------------------------------
MODE="$(config_get DRUPILOT_CONTRIB_MODE "semi" 2>/dev/null || true)"
[[ -z "$MODE" ]] && MODE="semi"

case "$(lc "$MODE")" in
  auto)
    # Fully-automated mode: allow outward-facing actions (no extra prompt),
    # unless the same command also skips the repository's commit hooks.
    [[ -n "$HOOKS_REASON" ]] && emit_decision "ask" "$HOOKS_REASON ${REASON}"
    emit_decision "allow" "drupilot contribution mode is 'auto': outward-facing action allowed (${REASON})"
    ;;
  semi|*)
    # Semi-automated mode (default): require explicit confirmation.
    emit_decision "ask" "drupilot is in 'semi' contribution mode. ${REASON} Confirm before it leaves your machine. Reminder: credit on Drupal.org is granted by maintainers via the issue's Contribution Record. Prefer a dry run first? /drupilot-patch writes a local patch with no push. Set DRUPILOT_CONTRIB_MODE=auto to skip these confirmations.${HOOKS_REASON:+ Also: $HOOKS_REASON}"
    ;;
esac
