#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/interact.sh
# Interaction: TTY checks, confirmation, tabbed choices, patch
# announcements.
#
# Part of the shared library: scripts/lib/common.sh sources it with the other
# domain libs (never source it alone); see common.sh for the conventions.
# =============================================================================

# ---------------------------------------------------------------------------
# Interaction (safe confirmation in non-TTY contexts)
# ---------------------------------------------------------------------------
# confirm <question> [default_yes:0/1] -> 0 if the user accepts.
# Without a TTY: uses DRUPILOT_ASSUME_YES or the default; never blocks forever.
# tty_readable -> 0 only if the controlling terminal can actually be OPENED for
# reading. `[[ -r /dev/tty ]]` is not enough: the device node is read-permissioned
# even with no controlling terminal (e.g. the Claude Code Bash tool, cron, CI),
# where the open() then fails. Opening it for real is the reliable test.
# DRUPILOT_NONINTERACTIVE=1|true (environment only: the switch for wrappers and
# CI) makes it report "no terminal" even when one exists, so confirm() and
# choose_one() never prompt and resolve to their default (the recommended,
# safe answer — never an implicit "yes" to an outward-facing action).
tty_readable() {
  case "$(lc "${DRUPILOT_NONINTERACTIVE:-}")" in 1|true|yes|on) return 1;; esac
  { : </dev/tty; } 2>/dev/null
}

confirm() {
  local q="$1" default_yes="${2:-0}"
  if [[ "${DRUPILOT_ASSUME_YES:-}" == "1" ]]; then return 0; fi
  if ! tty_readable; then
    [[ "$default_yes" == "1" ]] && return 0 || return 1
  fi
  local prompt=" [y/N] "; [[ "$default_yes" == "1" ]] && prompt=" [Y/n] "
  local ans=""
  printf '%s%s' "$q" "$prompt" >&2
  read -r ans </dev/tty || true
  ans="$(lc "$ans")"
  if [[ -z "$ans" ]]; then [[ "$default_yes" == "1" ]] && return 0 || return 1; fi
  case "$ans" in y|yes) return 0;; *) return 1;; esac
}

# choose_one <KEY> <prompt> <opt1> [opt2...] -> the tabbed-choice primitive, the
# multi-option sibling of confirm(). Each <optN> is "value" or "value|Human
# label"; the FIRST option is the default. The chosen VALUE is printed to STDOUT
# (the only thing on stdout); the menu and prompt go to STDERR. Resolution order,
# highest first: (1) DRUPILOT_CHOICE_<KEY> from env/.drupilot.json/defaults — must
# match an option value, else ignored with a warning (also ignored for a fork
# config/choices.json marks 'preanswer': false; scripts/env/choice.sh resolves
# the same variables for the commands' AskUserQuestion tabs); (2) an interactive /dev/tty
# selection (by number or by typing the value); (3) the default (first option)
# when there is no TTY or DRUPILOT_ASSUME_YES=1. Fail-safe: never blocks forever
# and always echoes a valid option value. In Claude Code commands the real tabs
# come from AskUserQuestion; this is the script-side fail-safe fallback.
choose_one() {
  local key="$1" prompt="$2"; shift 2
  local -a values=() labels=()
  local opt v l
  for opt in "$@"; do
    v="${opt%%|*}"; l="${opt#*|}"; [[ "$l" == "$opt" ]] && l="$v"
    values+=("$v"); labels+=("$l")
  done
  [[ ${#values[@]} -gt 0 ]] || return 1
  local default_val="${values[0]}"

  # 1. Config/env override (DRUPILOT_CHOICE_<KEY>), validated against the options.
  # A fork the registry (config/choices.json) marks 'preanswer': false stays a
  # human decision: its variable is ignored with a warning.
  local override; override="$(config_get "DRUPILOT_CHOICE_${key}" "")"
  local reg; reg="$(plugin_root)/config/choices.json"
  if [[ -n "$override" && -r "$reg" ]] && have_cmd jq \
     && [[ "$(jq -r --arg k "$key" '.choices[$k].preanswer != false' "$reg" 2>/dev/null)" == "false" ]]; then
    log_warn "Ignoring DRUPILOT_CHOICE_${key}='$override': this choice cannot be pre-answered."
    override=""
  fi
  if [[ -n "$override" ]]; then
    for v in "${values[@]}"; do
      [[ "$v" == "$override" ]] && { printf '%s' "$v"; return 0; }
    done
    # An old value of the setting the choice persists (migrations.json
    # value_aliases, e.g. CORE_TARGET keep-d10) counts as its new name (CC-07).
    local pk=""
    if [[ -r "$reg" ]] && have_cmd jq; then
      pk="$(jq -r --arg k "$key" '.choices[$k].persist_key // empty' "$reg" 2>/dev/null || true)"
    fi
    if [[ -n "$pk" ]]; then
      value_alias_normalize "$pk" "$override"
      for v in "${values[@]}"; do
        [[ "$v" == "$_DRUPILOT_VALUE_ALIAS" ]] && { printf '%s' "$v"; return 0; }
      done
    fi
    log_warn "Ignoring DRUPILOT_CHOICE_${key}='$override' (not one of: ${values[*]})."
  fi

  # 2/3. Interactive selection, or the default when there is no usable terminal.
  if [[ "${DRUPILOT_ASSUME_YES:-}" == "1" ]] || ! tty_readable; then
    printf '%s' "$default_val"; return 0
  fi

  local i
  printf '%s\n' "$prompt" >&2
  for i in "${!values[@]}"; do
    printf '  %s) %s%s\n' "$((i+1))" "${labels[i]}" \
      "$([[ "${values[i]}" == "$default_val" ]] && printf ' [default]')" >&2
  done
  local ans=""
  printf 'Choose [1-%s] (Enter = default): ' "${#values[@]}" >&2
  read -r ans </dev/tty || true
  [[ -z "$ans" ]] && { printf '%s' "$default_val"; return 0; }
  if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#values[@]} )); then
    printf '%s' "${values[$((ans-1))]}"; return 0
  fi
  for v in "${values[@]}"; do
    [[ "$ans" == "$v" ]] && { printf '%s' "$v"; return 0; }
  done
  log_warn "Unrecognized choice '$ans' — using the default '$default_val'."
  printf '%s' "$default_val"
}

# announce_patch <patch_path> -> a friendly, consistent summary of a generated
# patch (where it is, how to apply it elsewhere). STDERR only, so it never
# pollutes a script's parseable STDOUT (the patch path stays the sole stdout).
announce_patch() {
  local p="$1" name; name="$(basename "$p")"
  hr
  log_ok "Patch ready: $p"
  log_plain "   Apply it on another checkout:  git apply $name   (or: patch -p1 < $name)"
}
