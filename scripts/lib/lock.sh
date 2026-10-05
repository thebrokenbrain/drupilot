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

# lock_location [project_dir] -> where the root's lock lives (AR-14, OD-06):
# "project" (<root>/drupilot-lock.json, committable: drupilot's managed ignore
# block leaves it out) when DRUPILOT_LOCK_LOCATION=project and the root is the
# developer's own (_lock_project_root), else "state" (the hidden state dir,
# the default). A test-bed for a loose subject is a throwaway root, so a lock
# committed there means nothing: it stays "state", and lock_location_note says
# so. Silent and read-only; no jq fork while the key is set nowhere (it is
# read on every lock access).
lock_location() {
  local base="${1:-${DRUPILOT_PROJECT_DIR:-$PWD}}" want
  if [[ -z "${DRUPILOT_LOCK_LOCATION:-}" ]] && ! grep -q DRUPILOT_LOCK_LOCATION "$base/.drupilot.json" 2> /dev/null; then
    printf 'state'; return 0
  fi
  want="$(export DRUPILOT_PROJECT_DIR="$base"; config_get DRUPILOT_LOCK_LOCATION state)"
  if [[ "$want" == "project" ]] && _lock_project_root "$base"; then printf 'project'; else printf 'state'; fi
  return 0
}

# _lock_project_root <root> -> 0 when ROOT is the developer's own Drupal
# project, where a committed lock lasts: it exists with an installed core,
# drupilot did not build it (testbed_kind none), it holds no module
# place-subject.sh placed (.drupilot_testbed.subjects), and it is not itself an
# extension (a module repo that carries its own core, ddev-drupal-contrib, whose
# patch must never gain the lock). A root that does not exist yet is the
# test-bed a loose subject will get: not the developer's own.
_lock_project_root() {
  local r="${1:-}"
  [[ -d "$r" ]] && drupal_core_installed "$r" || return 1
  [[ "$(testbed_kind "$r")" == "none" ]] || return 1
  is_drupal_extension_dir "$r" && return 1
  if [[ -r "$r/.drupilot.json" ]] && have_cmd jq \
     && jq -e '((.drupilot_testbed // {}).subjects // {}) | length > 0' "$r/.drupilot.json" > /dev/null 2>&1; then
    return 1
  fi
  return 0
}

# lock_location_note [project_dir] -> a warning on STDERR when the location
# is not what the developer may expect, nothing otherwise: when
# DRUPILOT_LOCK_LOCATION=project cannot apply to the root (_lock_project_root),
# and when the setting is "state" but a project lock lies at the root (it is
# not read). The lock writers call it once, in their main shell (lock-sync.sh,
# upgrade-path.sh --freeze).
lock_location_note() {
  local base="${1:-${DRUPILOT_PROJECT_DIR:-$PWD}}" want loc
  want="$(export DRUPILOT_PROJECT_DIR="$base"; config_get DRUPILOT_LOCK_LOCATION state)"
  loc="$(lock_location "$base")"
  if [[ "$want" == "project" && "$loc" == "state" ]]; then
    log_warn "DRUPILOT_LOCK_LOCATION=project applies to a module already inside your own Drupal root; $base is not one (a test-bed for a loose module, or not built yet), so its lock stays in drupilot's state dir: $(lock_path "$base")"
  elif [[ "$loc" == "state" && -f "$(_lock_files "$base" | sed -n '1p')" ]]; then
    log_warn "$(_lock_files "$base" | sed -n '1p') is not read: DRUPILOT_LOCK_LOCATION is state (set it to project to use that lock)."
  fi
  return 0
}

# _lock_files [project_dir] -> two lines: the root's lock (<root>/drupilot-lock.json)
# and the state dir's (never created here). The only place the lock's file
# name is spelled: every reader and writer goes through lock_path /
# drupilot_lock_file (the hard-rules gate's LOCK rule). A state lock moved to
# the root is renamed <state lock>.moved-to-project, which nothing reads.
_lock_files() {
  local base="${1:-${DRUPILOT_PROJECT_DIR:-$PWD}}" abs
  abs="$(cd "$base" 2> /dev/null && pwd || printf '%s' "$base")"
  printf '%s/drupilot-lock.json\n%s/drupilot-lock.json\n' "$abs" "$(project_state_path "$base")"
  return 0
}

# lock_write_path [project_dir] -> the file a writer writes, WITHOUT creating
# or moving anything (a --dry-run names it): <root>/drupilot-lock.json when
# lock_location is "project", else the state dir's lock.
lock_write_path() {
  local base="${1:-${DRUPILOT_PROJECT_DIR:-$PWD}}"
  if [[ "$(lock_location "$base")" == "project" ]]; then _lock_files "$base" | sed -n '1p'
  else _lock_files "$base" | sed -n '2p'; fi
  return 0
}

# drupilot_lock_file [project_dir] -> path to this project's lockfile, for a
# writer: in the hidden per-project state dir by default (like assess.json /
# last-test.json, so it never touches the project tree; the dir is created),
# or <root>/drupilot-lock.json when lock_location is "project". A lock still in
# the state dir moves there first, so the frozen plan and pins move with it:
# copied whole to a temporary file, linked into place only while the root has
# no lock (two writers never clobber each other), and the state copy renamed
# .moved-to-project. Scripts that already know the Drupal root can export
# DRUPILOT_PROJECT_DIR; otherwise $PWD is used (analysis scripts cd into the
# Drupal root first, so $PWD is the project there).
drupilot_lock_file() {
  local base="${1:-${DRUPILOT_PROJECT_DIR:-$PWD}}" files p s tmp
  if [[ "$(lock_location "$base")" == "project" ]]; then
    files="$(_lock_files "$base")"; p="$(printf '%s\n' "$files" | sed -n '1p')"; s="$(printf '%s\n' "$files" | sed -n '2p')"
    if [[ ! -f "$p" && -f "$s" ]]; then
      tmp="$(mktemp "$p.XXXXXX" 2> /dev/null || true)"
      if [[ -n "$tmp" ]] && cp "$s" "$tmp" 2> /dev/null && ln "$tmp" "$p" 2> /dev/null; then
        mv -f "$s" "$s.moved-to-project" 2> /dev/null || true
        log_info "The lock moved to the project root (DRUPILOT_LOCK_LOCATION=project): $p"
      fi
      [[ -z "$tmp" ]] || rm -f "$tmp" 2> /dev/null || true
    fi
    printf '%s' "$p"; return 0
  fi
  printf '%s/drupilot-lock.json' "$(project_state_dir "$base")"
  return 0
}

# lock_path [project_dir] -> the lock a reader reads (lock_location's), WITHOUT
# creating anything: for a reader that must leave nothing behind for a root it
# only looked at (plan_get, upgrade-path.sh, lock_get). With "project", a lock
# still in the state dir is read until the first write moves it (never once
# moved: the state copy is then renamed).
lock_path() {
  local base="${1:-${DRUPILOT_PROJECT_DIR:-$PWD}}" files p s
  files="$(_lock_files "$base")"; p="$(printf '%s\n' "$files" | sed -n '1p')"; s="$(printf '%s\n' "$files" | sed -n '2p')"
  if [[ "$(lock_location "$base")" == "project" ]] && { [[ -f "$p" ]] || [[ ! -f "$s" ]]; }; then
    printf '%s' "$p"
  else
    printf '%s' "$s"
  fi
  return 0
}

# lock_merge_json <json-object> [project_dir] -> merge the object's top-level
# keys into the lockfile in ONE atomic write (temp file + mv), stamping
# .drupilot_version. A missing, empty or blank lock starts as {"schema": 1};
# an existing one is never given a schema it lacks (a 0.9 lock stays schema
# 0: CC-10, ADR 0015). Returns 1 without jq, for a value that is not a JSON
# object, for a lock that is not one JSON object (left as it is), or when the
# write fails.
lock_merge_json() {
  local obj="${1:-}" f tmp st
  have_cmd jq || return 1
  printf '%s' "$obj" | jq -e -s 'length == 1 and (.[0] | type == "object")' > /dev/null 2>&1 || return 1
  f="$(drupilot_lock_file "${2:-${DRUPILOT_PROJECT_DIR:-$PWD}}")"
  # A lock that holds nothing (absent, empty or blank) starts anew; one that
  # is not a single JSON object is never overwritten.
  st="none"
  if [[ -s "$f" ]]; then
    st="$(jq -r -s 'if length == 0 then "none" elif length == 1 and (.[0] | type == "object") then "ok" else "bad" end' "$f" 2> /dev/null || true)"
  fi
  case "$st" in
    ok) : ;;
    none) printf '{"schema": 1}\n' > "$f" 2> /dev/null || return 1;;
    *) return 1;;
  esac
  tmp="$(mktemp "${f}.XXXXXX" 2> /dev/null)" || return 1
  if jq --argjson o "$obj" --arg pv "$(plugin_version)" '. + $o | .drupilot_version = $pv' "$f" > "$tmp" 2> /dev/null \
     && jq -e -s 'length == 1 and (.[0] | type == "object")' "$tmp" > /dev/null 2>&1; then
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
  f="$(lock_path)"
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
  local f; f="$(lock_path "${1:-}")"
  if [[ -r "$f" ]] && have_cmd jq; then jq . "$f" 2>/dev/null || cat "$f"; return 0; fi
  log_info "No lockfile yet at $f."
  return 1
}

# lock_clear [project_dir] -> delete the lockfile so the next run resolves fresh
# and re-freezes (the deterministic escape hatch, per-project, without flipping
# DRUPILOT_DETERMINISTIC globally). With lock_location "project" it also
# deletes the state dir's copy, which a reader would fall back to.
lock_clear() {
  local base="${1:-${DRUPILOT_PROJECT_DIR:-$PWD}}" f s n=0
  f="$(lock_path "$base")"
  s="$(_lock_files "$base" | sed -n '2p')"
  if [[ -f "$f" ]]; then rm -f "$f" && log_ok "Cleared lockfile: $f" && n=1; fi
  if [[ "$(lock_location "$base")" == "project" && "$s" != "$f" && -f "$s" ]]; then
    rm -f "$s" && log_ok "Cleared the state dir's copy: $s" && n=1
  fi
  [[ "$n" == "1" ]] || log_info "No lockfile to clear at $f."
  return 0
}

# render_sha_record ROOT REL FILE [TEMPLATE] -> keep the sha256 of a config
# drupilot rendered (rector.php, phpstan.neon, ...) in ROOT's lock:
# .templates[REL] = {sha256, template_version}. A later render knows the copy
# is untouched by it (render_sha_matches) and may regenerate it (INV5: a
# hand-edited copy never is). Silent on failure.
render_sha_record() {
  local root="${1:-}" rel="${2:-}" f="${3:-}" tpl="${4:-}" h v
  [[ -n "$root" && -n "$rel" && -f "$f" ]] && have_cmd jq || return 0
  h="$(sha256_hex < "$f" 2> /dev/null || true)"
  [[ -n "$h" ]] || return 0
  v="$(sed -n 's/.*drupilot-template-version: \([0-9][0-9]*\).*/\1/p' "$tpl" 2> /dev/null | sed -n '1p')"
  DRUPILOT_PROJECT_DIR="$root" lock_set_json ".templates[\"$rel\"]" \
    "$(jq -n -c --arg h "sha256:$h" --arg v "$v" '{sha256: $h, template_version: (if $v == "" then null else ($v | tonumber) end)}')" \
    > /dev/null 2>&1 || true
  return 0
}

# render_sha_matches ROOT REL FILE -> 0 when FILE is byte for byte the render
# render_sha_record kept for REL in ROOT's lock. Read-only (lock_path).
render_sha_matches() {
  local root="${1:-}" rel="${2:-}" f="${3:-}" want h
  [[ -f "$f" ]] && have_cmd jq || return 1
  want="$(jq -r --arg r "$rel" '.templates[$r].sha256 // empty' "$(lock_path "$root")" 2> /dev/null || true)"
  [[ -n "$want" ]] || return 1
  h="$(sha256_hex < "$f" 2> /dev/null || true)"
  [[ -n "$h" && "sha256:$h" == "$want" ]]
}
