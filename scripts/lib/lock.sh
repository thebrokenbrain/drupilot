#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/lock.sh
# Determinism mode and the per-project lockfile (drupilot-lock.json).
#
# Part of the shared library: scripts/lib/common.sh sources it with the other
# domain libs (never source it alone); see common.sh for the conventions.
# =============================================================================

# ---------------------------------------------------------------------------
# Determinism mode + per-project lockfile (drupilot-lock.json)
# ---------------------------------------------------------------------------
# drupilot is reproducible BY DEFAULT: it freezes the versions/refs it resolves
# (Drupal core, the dev toolchain, the digests SHA, DDEV add-ons) into a
# per-project lockfile and reuses them on later runs, so porting the same module
# twice converges on the same toolchain. Set DRUPILOT_DETERMINISTIC=false (the
# escape hatch) to always resolve fresh (the legacy floating behavior) and
# refresh the lock. This only governs drupilot's own resolution; it is unrelated
# to the Claude Code permission mode.
deterministic_mode() { config_bool DRUPILOT_DETERMINISTIC 1; }

# drupilot_lock_file [project_dir] -> path to this project's lockfile. The lock
# lives under the per-project state dir (like assess.json / last-test.json), so it
# never contaminates the user's project tree. Scripts that already know the
# Drupal root can export DRUPILOT_PROJECT_DIR; otherwise $PWD is used (analysis
# scripts cd into the Drupal root first, so $PWD is the project there).
drupilot_lock_file() {
  local base="${1:-${DRUPILOT_PROJECT_DIR:-$PWD}}"
  printf '%s/drupilot-lock.json' "$(project_state_dir "$base")"
}

# lock_path [project_dir] -> the same path as drupilot_lock_file, WITHOUT
# creating the state dir: for a reader that must leave nothing behind for a
# root it only looked at (plan_get, upgrade-path.sh).
lock_path() {
  local base="${1:-${DRUPILOT_PROJECT_DIR:-$PWD}}"
  printf '%s/drupilot-lock.json' "$(project_state_path "$base")"
}

# lock_merge_json <json-object> [project_dir] -> merge the object's top-level
# keys into the lockfile in ONE atomic write (temp file + mv), stamping
# .drupilot_version. A missing or empty lock starts as {"schema": 1}; an
# existing one is never given a schema it lacks (a 0.9 lock stays schema 0:
# CC-10, ADR 0015). Returns 1 without jq, for a value that is not a JSON
# object, or when the write fails.
lock_merge_json() {
  local obj="${1:-}" f tmp
  have_cmd jq || return 1
  printf '%s' "$obj" | jq -e -s 'length == 1 and (.[0] | type == "object")' > /dev/null 2>&1 || return 1
  f="$(drupilot_lock_file "${2:-${DRUPILOT_PROJECT_DIR:-$PWD}}")"
  [[ -s "$f" ]] || printf '{"schema": 1}\n' > "$f" 2> /dev/null || return 1
  tmp="$(mktemp "${f}.XXXXXX" 2> /dev/null)" || return 1
  if jq --argjson o "$obj" --arg pv "$(plugin_version)" '. + $o | .drupilot_version = $pv' "$f" > "$tmp" 2> /dev/null; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp" 2> /dev/null || true; return 1
  fi
}

# lock_get <jq-path> [default] -> read a value from the lockfile. <jq-path> is a
# jq filter beginning with '.', e.g. '.digests.sha'. Returns the default when the
# lock, jq or the key is absent. STDOUT only (no logging).
lock_get() {
  local path="$1" def="${2:-}" f
  f="$(drupilot_lock_file)"
  if [[ -r "$f" ]] && have_cmd jq; then
    local v; v="$(jq -r "${path} // empty" "$f" 2>/dev/null)"
    if [[ -n "$v" && "$v" != "null" ]]; then printf '%s' "$v"; return 0; fi
  fi
  printf '%s' "$def"
}

# lock_set <jq-path> <value> -> set a STRING value at <jq-path>, creating the
# lock (and any intermediate objects) if absent: a lock drupilot 1.0 creates
# starts as {"schema": 1}, so one with no schema was created by 0.9 (schema
# 0). Atomic (temp file + mv). No-op (return 1) without jq. <jq-path> is
# plugin-controlled, never user input.
# Every lock write also stamps `.drupilot_version` (plugin.json's version), so
# the lock names the drupilot that last wrote it, not only the one that ran
# lock-sync.sh at setup.
lock_set() {
  local path="$1" value="$2" f tmp
  have_cmd jq || return 1
  f="$(drupilot_lock_file)"
  [[ -f "$f" ]] || printf '{"schema": 1}\n' > "$f" 2>/dev/null || return 1
  tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 1
  if jq --arg v "$value" --arg pv "$(plugin_version)" "${path} = \$v | .drupilot_version = \$pv" "$f" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp" 2>/dev/null || true; return 1
  fi
}

# lock_set_json <jq-path> <json-value> -> like lock_set but for a raw JSON value
# (number, boolean, object, array), e.g. lock_set_json .phpstan_level 2.
lock_set_json() {
  local path="$1" value="$2" f tmp
  have_cmd jq || return 1
  f="$(drupilot_lock_file)"
  [[ -f "$f" ]] || printf '{"schema": 1}\n' > "$f" 2>/dev/null || return 1
  tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 1
  if jq --argjson v "$value" --arg pv "$(plugin_version)" "${path} = \$v | .drupilot_version = \$pv" "$f" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp" 2>/dev/null || true; return 1
  fi
}

# lock_resolve <jq-path> <fresh-cmd...> -> resolve-and-freeze, the core pattern.
# Deterministic mode: if the lock already has <jq-path>, echo it (no fresh work);
# otherwise run <fresh-cmd...> (its STDOUT is the value), freeze it, echo it.
# Non-deterministic mode: always run <fresh-cmd...>, refresh the lock, echo it.
# Returns non-zero (and echoes nothing) if the fresh resolver yields nothing.
lock_resolve() {
  local path="$1"; shift
  local cached fresh
  if deterministic_mode; then
    cached="$(lock_get "$path" "")"
    if [[ -n "$cached" ]]; then printf '%s' "$cached"; return 0; fi
  fi
  fresh="$("$@")" || return 1
  [[ -n "$fresh" ]] || return 1
  lock_set "$path" "$fresh" 2>/dev/null || true
  printf '%s' "$fresh"
}

# lock_show [project_dir] -> pretty-print the lockfile JSON to STDOUT so the
# developer can inspect the frozen toolchain. Returns 1 (with a note on stderr)
# when there is no lock yet. Read-only.
lock_show() {
  local f; f="$(drupilot_lock_file "${1:-}")"
  if [[ -r "$f" ]] && have_cmd jq; then jq . "$f" 2>/dev/null || cat "$f"; return 0; fi
  log_info "No lockfile yet at $f."
  return 1
}

# lock_clear [project_dir] -> delete the lockfile so the next run resolves fresh
# and re-freezes (the deterministic escape hatch, per-project, without flipping
# DRUPILOT_DETERMINISTIC globally).
lock_clear() {
  local f; f="$(drupilot_lock_file "${1:-}")"
  if [[ -f "$f" ]]; then rm -f "$f" && log_ok "Cleared lockfile: $f"; else log_info "No lockfile to clear at $f."; fi
}
