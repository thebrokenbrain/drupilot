#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/paths.sh
# Plugin paths and drupilot's data, state and artifacts directories.
#
# Part of the shared library: scripts/lib/common.sh sources it with the other
# domain libs (never source it alone); see common.sh for the conventions.
# =============================================================================

# ---------------------------------------------------------------------------
# Plugin paths and persistent data
# ---------------------------------------------------------------------------
# plugin_root -> plugin root. Uses CLAUDE_PLUGIN_ROOT if set; otherwise derives
# it from this file's location (<root>/scripts/lib/common.sh).
plugin_root() {
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    printf '%s' "$CLAUDE_PLUGIN_ROOT"; return 0
  fi
  ( cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd )
}

drupilot_config_file() { printf '%s/config/defaults.json' "$(plugin_root)"; }

plugin_version() {
  local f; f="$(plugin_root)/.claude-plugin/plugin.json"
  if [[ -r "$f" ]] && have_cmd jq; then
    jq -r '.version // "0.0.0"' "$f" 2>/dev/null || printf '0.0.0'
  else
    printf '0.0.0'
  fi
}

# plugin_revision -> the exact build of a drupilot that runs from a git checkout
# (`git describe --tags --always --dirty`, e.g. v0.8.3-45-gb97266d), since
# plugin.json's version only changes on a release and a development branch keeps
# reporting the last one. Empty for an installed (non-git) copy, or without git.
plugin_revision() {
  local r; r="$(plugin_root)"
  [[ -e "$r/.git" ]] && have_cmd git || return 0
  git -C "$r" describe --tags --always --dirty 2>/dev/null || true
  return 0
}

# data_dir -> drupilot's persistent data directory (state, cache), created.
# DRUPILOT_HOME (an absolute path, read from the environment only: it locates
# the state before any project preference can be read), else
# $XDG_DATA_HOME/drupilot (~/.local/share/drupilot). Never Claude Code's
# per-plugin data dir: Claude Code exports it to hooks but not to the Bash tool,
# so a root derived from it split the state in two (0.9.0), and it is deleted
# when the plugin is uninstalled.
data_dir() {
  local d; d="$(data_dir_path)"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s' "$d"
}
# data_dir_path -> the same path, without creating it (read-only callers).
# A leading '~' of DRUPILOT_HOME is expanded (a quoted export or a settings.json
# env value does not expand it); any other relative DRUPILOT_HOME, and a
# relative XDG_DATA_HOME (invalid per the XDG spec), are ignored: a hook and a
# script run from different directories, so a relative root would split the
# state again and write it into the project tree.
data_dir_path() {
  local h="${DRUPILOT_HOME:-}" x="${XDG_DATA_HOME:-}"
  # shellcheck disable=SC2088  # the literal '~' a quoted value carries is the point
  case "$h" in "~") h="$HOME";; "~/"*) h="$HOME/${h#"~/"}";; esac
  h="${h%/}"
  case "$h" in /*) printf '%s' "$h"; return 0;; esac
  case "$x" in /*) : ;; *) x="$HOME/.local/share";; esac
  printf '%s/drupilot' "${x%/}"
}

# legacy_plugin_data_dir -> the per-plugin data dirs where drupilot 0.9.0 could
# keep state (Claude Code's ~/.claude/plugins/data/drupilot-<install>/, one per
# install id; CLAUDE_CONFIG_DIR moves ~/.claude), one per line, sorted, only
# those with a state/ dir and never the current data root. Read only by
# copy_legacy_state_once (the 1.0 migration takes it over).
legacy_plugin_data_dir() {
  local base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data" d root
  root="$(cd "$(data_dir_path)" 2>/dev/null && pwd -P || printf '%s' "$(data_dir_path)")"
  for d in "$base"/drupilot-*; do
    [[ -d "$d/state" ]] || continue
    [[ "$(cd "$d" && pwd -P)" == "$root" ]] && continue
    printf '%s\n' "$d"
  done
  return 0
}

# copy_legacy_state_once -> one-time, copy-only import of the state 0.9.0 kept
# in a per-plugin data dir (legacy_plugin_data_dir) into data_dir_path: every
# file of <legacy>/state/ missing here is copied (never moved, never
# overwritten; the first legacy dir wins), the copy is logged on STDERR, and the
# marker <data root>/legacy-state-copied makes every later call return at once.
# Each file is copied under a temp name and renamed into place, so a failed
# copy (a full disk) leaves nothing behind. A file that could not be copied, or
# a legacy dir that could not be fully listed, is named in a warning and leaves
# no marker: the next gated command retries only what is still pending (the
# files already imported or kept are listed in legacy-state-copied.partial, so
# one the user removed in between is not imported again).
# Call it ONLY from a command preamble, right after that command's own
# preflight.sh exited 0 (`preflight.sh ... && ... copy_legacy_state_once`):
# never from a hook, from preflight.sh or from a helper, so a failing gate
# changes nothing.
copy_legacy_state_once() {
  local root marker partial srcs src rel list dst tmp n=0 nf=0 failed=""
  root="$(data_dir_path)"; marker="$root/legacy-state-copied"; partial="$marker.partial"
  [[ -e "$marker" ]] && return 0
  srcs="$(legacy_plugin_data_dir)"
  [[ -n "$srcs" ]] || return 0
  if ! mkdir -p "$root/state" 2>/dev/null; then
    log_warn "Could not create $root/state: the state drupilot 0.9.0 left in $(printf '%s' "$srcs" | tr '\n' ' ')was not copied (retried by the next command)."
    return 0
  fi
  # Process substitution, not here-strings: bash < 5.1 backs a here-string
  # with a temp file, and a full /tmp would skip the loop silently. Every
  # listed line must also be seen, or the import does not count as complete.
  local want got want_src got_src=0
  want_src="$(printf '%s\n' "$srcs" | grep -c . || true)"
  while IFS= read -r src; do
    [[ -n "$src" ]] || continue
    got_src=$((got_src + 1))
    if ! list="$(cd "$src/state" 2>/dev/null && find . -type f 2>/dev/null)"; then
      nf=$((nf + 1)); failed="$failed $src/state (not fully readable)"
    fi
    want="$(printf '%s\n' "$list" | grep -c . || true)"; got=0
    while IFS= read -r rel; do
      rel="${rel#./}"
      [[ -n "$rel" ]] || continue
      got=$((got + 1))
      [[ -f "$partial" ]] && grep -qxF -- "$rel" "$partial" 2>/dev/null && continue
      dst="$root/state/$rel"
      if [[ -e "$dst" ]]; then
        printf '%s\n' "$rel" >> "$partial" 2>/dev/null || true
        continue
      fi
      tmp="$dst.drupilot-copy.$$"
      if mkdir -p "$(dirname "$dst")" 2>/dev/null && cp -p "$src/state/$rel" "$tmp" 2>/dev/null \
         && mv -f "$tmp" "$dst" 2>/dev/null; then
        n=$((n + 1)); printf '%s\n' "$rel" >> "$partial" 2>/dev/null || true
      else
        rm -f "$tmp" 2>/dev/null
        nf=$((nf + 1)); failed="$failed $src/state/$rel"
      fi
    done < <(printf '%s\n' "$list" | LC_ALL=C sort)
    if [[ "$got" -ne "$want" ]]; then nf=$((nf + 1)); failed="$failed $src/state (listing not read)"; fi
  done < <(printf '%s\n' "$srcs")
  if [[ "$got_src" -ne "$want_src" ]]; then nf=$((nf + 1)); failed="$failed (the legacy dir list was not read)"; fi
  if [[ "$nf" -gt 0 ]]; then
    log_warn "Copied $n state file(s) of drupilot 0.9.0 into $root/state; $nf could not be copied and will be retried by the next command:$failed"
    return 0
  fi
  { printf 'copied_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'files=%s\n' "$n"
    printf '%s\n' "$srcs" | sed 's#^#from=#; s#$#/state#'
  } > "$marker" 2>/dev/null || true
  rm -f "$partial" 2>/dev/null
  if [[ "$n" -gt 0 ]]; then
    log_info "Copied $n state file(s) of drupilot 0.9.0 into $root/state (the originals stay in: $(printf '%s' "$srcs" | tr '\n' ' '))."
  else
    log_info "Legacy drupilot state found ($(printf '%s' "$srcs" | tr '\n' ' ')): nothing to copy, $root/state already has every file."
  fi
  return 0
}

# project_state_dir [base_dir] -> per-project MACHINE state (assess.json,
# last-test.json, drupilot-lock.json). Kept OUT of the project tree, under
# data_dir/state keyed by the project's absolute path (sanitized), ON PURPOSE:
# it must survive `git clean`, must never leak into a contribution patch / MR,
# and the lockfile's frozen versions must not be wiped by a tree reset. The
# developer-facing OUTPUTS go to project_artifacts_dir() instead (see below).
project_state_dir() {
  local d; d="$(project_state_path "${1:-$PWD}")"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s' "$d"
}

# project_state_path [base_dir] -> the same path as project_state_dir, WITHOUT
# creating it (nor the data dir). For read-only callers (next-step.sh,
# state.sh show/list, /drupilot-status), which must never leave an empty state
# dir behind for a directory they merely looked at.
project_state_path() {
  local base="${1:-$PWD}"
  local abs; abs="$(cd "$base" 2>/dev/null && pwd || printf '%s' "$base")"
  local key; key="$(printf '%s' "$abs" | tr -c 'A-Za-z0-9' '_' )"
  printf '%s/state/%s' "$(data_dir_path)" "$key"
}

# project_artifacts_dir [base_dir] -> the single VISIBLE directory that holds
# drupilot's human-facing outputs for a port (port-report.md, viability-report.md,
# coverage HTML, the local preview patch). Unlike project_state_dir() — machine
# JSON cache + lockfile kept hidden under $HOME so they survive `git clean` and
# can never leak — this lives IN the project tree, at <root>/.drupilot, so the
# developer can open and inspect it. That is exactly why ensure-gitignore.sh
# ignores `.drupilot/` (it never lands in a patch / MR). Because it sits under the
# Drupal root (mounted at /var/www/html in DDEV), the same relative `.drupilot/...`
# path resolves identically on the host and inside the container.
# Resolution: DRUPILOT_ARTIFACTS_DIR override > DRUPILOT_PROJECT_DIR > the Drupal
# root for <base> (drupal_run_root) > <base> itself (a loose subject with no
# Drupal yet) — except when <base> belongs to someone else's repository with no
# usable Drupal root (a module or folder of a monorepo clone, or a sub-directory
# of a larger git repository, before setup): its outputs then go to the hidden
# state dir (<state>/artifacts), so nothing is written into that repository.
# _artifacts_dir_path <base> -> that directory (the override excluded), not created.
_artifacts_dir_path() {
  local base="${1:-$PWD}" root="${DRUPILOT_PROJECT_DIR:-}"
  [[ -z "$root" ]] && root="$(drupal_run_root "$base" 2>/dev/null || true)"
  if [[ -z "$root" ]] && { find_project_root_nocore "$base" >/dev/null 2>&1 \
                           || git_enclosing_repo "$base" >/dev/null 2>&1; }; then
    printf '%s/artifacts' "$(project_state_path "$base")"
    return 0
  fi
  [[ -z "$root" ]] && root="$base"
  root="$(cd "$root" 2>/dev/null && pwd || printf '%s' "$root")"
  printf '%s/.drupilot' "$root"
  return 0
}
project_artifacts_dir() {
  local base="${1:-$PWD}"
  local override; override="$(config_get DRUPILOT_ARTIFACTS_DIR "")"
  if [[ -n "$override" ]]; then
    mkdir -p "$override" 2>/dev/null || true
    ( cd "$override" 2>/dev/null && pwd ) || printf '%s' "$override"
    return 0
  fi
  local d; d="$(_artifacts_dir_path "$base")"
  mkdir -p "$d" 2>/dev/null || true
  # Self-ignore: a .gitignore containing '*' INSIDE the dir makes git treat the
  # whole .drupilot/ as ignored in ANY repo it lands in — the Drupal root, or a
  # loose subject's own nested git repo (assess before setup, or a subject that
  # keeps its .git after a move). The root's .gitignore does NOT reach a nested
  # repo, so this in-dir guard is what actually keeps artifacts out of a
  # contribution patch regardless of which .gitignore git consults.
  [[ -f "$d/.gitignore" ]] || printf '*\n' > "$d/.gitignore" 2>/dev/null || true
  ( cd "$d" 2>/dev/null && pwd ) || printf '%s' "$d"
}
