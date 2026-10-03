#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/common.sh
# Shared library: logging, tool/version detection, configuration loading
# (defaults.json + env override), plugin paths and JSON helpers. Sourced by the
# rest of the scripts:
#
#     # shellcheck source=../lib/common.sh
#     . "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#
# Principles: idempotent, fail-safe, does NOT enable `set -e` (each script sets
# its own). All logging goes to STDERR so STDOUT stays clean for parseable
# payloads (JSON, machine output).
# =============================================================================

# Avoid double-sourcing.
if [[ -n "${_DRUPILOT_COMMON_SH:-}" ]]; then
  return 0 2>/dev/null || true
fi
_DRUPILOT_COMMON_SH=1

# ---------------------------------------------------------------------------
# Colors / presentation (respects NO_COLOR and non-TTY output)
# ---------------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  _C_RESET=$'\033[0m'; _C_BOLD=$'\033[1m'; _C_DIM=$'\033[2m'
  _C_RED=$'\033[31m'; _C_GREEN=$'\033[32m'; _C_YELLOW=$'\033[33m'
  _C_BLUE=$'\033[34m'; _C_CYAN=$'\033[36m'
else
  _C_RESET=''; _C_BOLD=''; _C_DIM=''
  _C_RED=''; _C_GREEN=''; _C_YELLOW=''; _C_BLUE=''; _C_CYAN=''
fi

log_info()  { printf '%sℹ%s  %s\n'  "$_C_BLUE"   "$_C_RESET" "$*" >&2; }
log_ok()    { printf '%s✅%s %s\n'   "$_C_GREEN"  "$_C_RESET" "$*" >&2; }
log_warn()  { printf '%s⚠️%s  %s\n'  "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
log_err()   { printf '%s❌%s %s\n'   "$_C_RED"    "$_C_RESET" "$*" >&2; }
log_step()  { printf '\n%s▶ %s%s\n'  "$_C_BOLD$_C_CYAN" "$*" "$_C_RESET" >&2; }
log_plain() { printf '%s\n' "$*" >&2; }
hr()        { printf '%s%s%s\n' "$_C_DIM" "────────────────────────────────────────────────────────" "$_C_RESET" >&2; }

# die <message> [code]
die() { log_err "$1"; exit "${2:-1}"; }

# ---------------------------------------------------------------------------
# Tool and version detection
# ---------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# print_usage <script> -> prints the script's header comment block (the lines
# between its first two "# ====" rules, without the leading "# ") on STDOUT, for
# -h/--help. Only the header is printed: later comments, shellcheck directives
# and the rule lines themselves are not part of the help.
print_usage() {
  awk 'NR == 1 && /^#!/ { next }
       /^# =+[[:space:]]*$/ { if (inhdr) exit; inhdr = 1; next }
       !inhdr { next }
       !/^#/ { exit }
       /^#[[:space:]]*shellcheck[[:space:]]/ { next }
       { sub(/^# ?/, ""); print }' "$1"
}

# extract_semver <string> -> first X.Y(.Z) found
extract_semver() {
  printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1
}

# tool_version <cmd> -> detected version (best-effort), empty if unavailable
tool_version() {
  local cmd="$1" out=""
  have_cmd "$cmd" || { printf ''; return 1; }
  case "$cmd" in
    php)      out="$(php -r 'echo PHP_VERSION;' </dev/null 2>/dev/null || php -v </dev/null 2>&1 | head -n1)";;
    composer) out="$(composer --version </dev/null 2>/dev/null | head -n1)";;
    docker)   out="$(docker --version </dev/null 2>&1 | head -n1)";;
    ddev)     out="$(ddev --version </dev/null 2>&1 | head -n1)";;
    git)      out="$(git --version </dev/null 2>&1 | head -n1)";;
    jq)       out="$(jq --version </dev/null 2>&1 | head -n1)";;
    drush)    out="$(drush --version </dev/null 2>&1 | head -n1)";;
    *)        out="$("$cmd" --version </dev/null 2>&1 | head -n1)";;
  esac
  extract_semver "$out"
}

# version_ge <v1> <v2> -> 0 if v1 >= v2 (lenient semver comparison)
version_ge() {
  local a="${1%%-*}" b="${2%%-*}"          # strip pre-release suffixes (-rc1, etc.)
  a="$(printf '%s' "$a" | tr -cd '0-9.')"   # keep digits and dots only
  b="$(printf '%s' "$b" | tr -cd '0-9.')"
  [[ -z "$a" ]] && a=0
  [[ -z "$b" ]] && b=0
  local IFS=.
  # shellcheck disable=SC2206
  local -a A=($a) B=($b)
  local i max=${#A[@]}
  (( ${#B[@]} > max )) && max=${#B[@]}
  for (( i=0; i<max; i++ )); do
    local x="${A[i]:-0}" y="${B[i]:-0}"
    x=$(( 10#${x:-0} )); y=$(( 10#${y:-0} ))
    (( x > y )) && return 0
    (( x < y )) && return 1
  done
  return 0
}

# docker_daemon_up -> 0 if the Docker daemon responds (not just the binary)
docker_daemon_up() {
  have_cmd docker || return 1
  docker info </dev/null >/dev/null 2>&1
}

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
# A file that could not be copied is named in a warning and leaves no marker,
# so the next gated command tries it again.
# Call it ONLY from a command preamble, right after that command's own
# preflight.sh exited 0 (`preflight.sh ... && ... copy_legacy_state_once`):
# never from a hook, from preflight.sh or from a helper, so a failing gate
# changes nothing.
copy_legacy_state_once() {
  local root marker srcs src rel n=0 failed="" nf=0
  root="$(data_dir_path)"; marker="$root/legacy-state-copied"
  [[ -e "$marker" ]] && return 0
  srcs="$(legacy_plugin_data_dir)"
  [[ -n "$srcs" ]] || return 0
  if ! mkdir -p "$root/state" 2>/dev/null; then
    log_warn "Could not create $root/state: the state drupilot 0.9.0 left in $(printf '%s' "$srcs" | tr '\n' ' ')was not copied (retried by the next command)."
    return 0
  fi
  while IFS= read -r src; do
    [[ -n "$src" ]] || continue
    while IFS= read -r rel; do
      [[ -n "$rel" && ! -e "$root/state/$rel" ]] || continue
      if mkdir -p "$(dirname "$root/state/$rel")" 2>/dev/null \
         && cp -p "$src/state/$rel" "$root/state/$rel" 2>/dev/null; then
        n=$((n + 1))
      else
        nf=$((nf + 1)); failed="$failed $src/state/$rel"
      fi
    done < <(cd "$src/state" 2>/dev/null && find . -type f 2>/dev/null | sed 's#^\./##' | LC_ALL=C sort)
  done <<< "$srcs"
  if [[ "$nf" -gt 0 ]]; then
    log_warn "Copied $n state file(s) of drupilot 0.9.0 into $root/state; $nf could not be copied and will be retried by the next command:$failed"
    return 0
  fi
  { printf 'copied_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'files=%s\n' "$n"
    printf '%s\n' "$srcs" | sed 's#^#from=#; s#$#/state#'
  } > "$marker" 2>/dev/null || true
  if [[ "$n" -gt 0 ]]; then
    log_info "Copied $n state file(s) of drupilot 0.9.0 into $root/state (the originals stay in: $(printf '%s' "$srcs" | tr '\n' ' '))."
  else
    log_info "Legacy drupilot state found ($(printf '%s' "$srcs" | tr '\n' ' ')): nothing to copy, $root/state already has every file."
  fi
  return 0
}

cache_dir() { local d; d="$(data_dir)/cache"; mkdir -p "$d" 2>/dev/null || true; printf '%s' "$d"; }

# digests_cache_dir -> cache for the dbuytaert/drupal-digests repo (cloned at runtime).
digests_cache_dir() { printf '%s/drupal-digests' "$(cache_dir)"; }

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

# ---------------------------------------------------------------------------
# Configuration (env override > .drupilot.json project prefs > defaults.json > caller default)
# ---------------------------------------------------------------------------
# drupilot_prefs_file -> path to the per-project preference file (.drupilot.json)
# at the Drupal ROOT, or non-zero if no root is resolvable. This is the
# persistence tier for in-flow tabbed choices (core target, PHP target, refactor
# scope, contrib mode...): config_get reads it BETWEEN the env override and
# defaults.json (env still wins), and prefs_set writes it. It lives in the
# project tree (gitignored via ensure-gitignore.sh), so it is implicitly keyed by
# the project the developer is working in. Scripts that already know the Drupal
# root can export DRUPILOT_PROJECT_DIR; otherwise it is detected from $PWD.
drupilot_prefs_file() {
  local root="${DRUPILOT_PROJECT_DIR:-}"
  [[ -z "$root" ]] && root="$(find_drupal_root 2>/dev/null || true)"
  [[ -n "$root" ]] || return 1
  printf '%s/.drupilot.json' "$root"
}

# config_get <KEY> [default]
config_get() {
  local key="$1" def="${2:-}"
  local envval="${!key:-}"
  if [[ -n "$envval" ]]; then printf '%s' "$envval"; return 0; fi
  # Project preference tier (.drupilot.json at the Drupal root): remembered
  # tabbed-choice answers, read between the env override and defaults.json.
  # The jq filter keeps a JSON false/0 (jq's `//` would treat false as missing
  # and fall through to the defaults), stringified as the env tier would be.
  local jqf='if type == "object" and has($k) and .[$k] != null then .[$k] | tostring else empty end'
  local pf; pf="$(drupilot_prefs_file 2>/dev/null || true)"
  if [[ -n "$pf" && -r "$pf" ]] && have_cmd jq; then
    local pv; pv="$(jq -r --arg k "$key" "$jqf" "$pf" 2>/dev/null)"
    if [[ -n "$pv" && "$pv" != "null" ]]; then printf '%s' "$pv"; return 0; fi
  fi
  local file; file="$(drupilot_config_file)"
  if [[ -r "$file" ]] && have_cmd jq; then
    local v; v="$(jq -r --arg k "$key" "$jqf" "$file" 2>/dev/null)"
    if [[ -n "$v" && "$v" != "null" ]]; then printf '%s' "$v"; return 0; fi
  fi
  printf '%s' "$def"
}

# prefs_set <KEY> <value> -> persist a preference into .drupilot.json at the
# Drupal root (atomic temp-file + mv). Used to remember a tabbed-choice answer
# across runs. No-op (return 1) without jq or a resolvable root. The env var of
# the same name always still wins over what this writes.
prefs_set() {
  local key="$1" value="$2" f tmp
  have_cmd jq || return 1
  f="$(drupilot_prefs_file 2>/dev/null || true)"
  [[ -n "$f" ]] || return 1
  [[ -f "$f" ]] || printf '{}\n' > "$f" 2>/dev/null || return 1
  tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 1
  if jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$f" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp" 2>/dev/null || true; return 1
  fi
}

# config_enum <KEY> <default> <allowed...> -> resolve KEY via config_get and
# validate it against the allowed set. Echoes the value (STDOUT) when valid;
# logs a clean error and returns non-zero when it is out of the set, so preflight
# can reject a misconfigured enum up front instead of failing deep inside a tool.
config_enum() {
  local key="$1" def="$2"; shift 2
  local v; v="$(config_get "$key" "$def")"
  local a
  for a in "$@"; do [[ "$v" == "$a" ]] && { printf '%s' "$v"; return 0; }; done
  log_err "$key='$v' is invalid. Allowed: $*"
  return 1
}

# config_bool <KEY> [default 0/1] -> 0 (true) / 1 (false) as the return code
config_bool() {
  local v; v="$(config_get "$1" "")"
  if [[ -z "$v" ]]; then
    [[ "${2:-0}" == "1" ]] && return 0 || return 1
  fi
  case "$(lc "$v")" in
    1|true|yes|on) return 0;;
    *) return 1;;
  esac
}

# config_json <jq-filter> [default] -> read an arbitrary path from defaults.json
config_json() {
  local filter="$1" def="${2:-}"
  local file; file="$(drupilot_config_file)"
  if [[ -r "$file" ]] && have_cmd jq; then
    local v; v="$(jq -r "$filter // empty" "$file" 2>/dev/null)"
    if [[ -n "$v" && "$v" != "null" ]]; then printf '%s' "$v"; return 0; fi
  fi
  printf '%s' "$def"
}

# req_version <name> [default] -> requirements.<name> from defaults.json
req_version() { config_json ".requirements.${1}" "${2:-}"; }

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
# lock (and any intermediate objects) if absent. Atomic (temp file + mv). No-op
# (return 1) without jq. <jq-path> is plugin-controlled, never user input.
# Every lock write also stamps `.drupilot_version` (plugin.json's version), so
# the lock names the drupilot that last wrote it, not only the one that ran
# lock-sync.sh at setup.
lock_set() {
  local path="$1" value="$2" f tmp
  have_cmd jq || return 1
  f="$(drupilot_lock_file)"
  [[ -f "$f" ]] || printf '{}\n' > "$f" 2>/dev/null || return 1
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
  [[ -f "$f" ]] || printf '{}\n' > "$f" 2>/dev/null || return 1
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

# ---------------------------------------------------------------------------
# PHP / Drupal target resolution
# ---------------------------------------------------------------------------
resolve_php_target()    { config_get DRUPILOT_PHP_TARGET "8.3"; }
resolve_drupal_target() { config_get DRUPILOT_DRUPAL_TARGET "^11"; }

# php_target_supported <ver> -> 0 if the version is in php_support.supported
php_target_supported() {
  local v="$1" file; file="$(drupilot_config_file)"
  if [[ -r "$file" ]] && have_cmd jq; then
    jq -e --arg v "$v" '.php_support.supported | index($v)' "$file" >/dev/null 2>&1 && return 0
  fi
  [[ "$v" == "8.3" || "$v" == "8.4" ]]
}

# php_target_unconfirmed <ver> -> 0 if the version is in php_support.unconfirmed
# (8.5): no Rector set is assumed for it, so rector_php_set_arg falls back to the
# highest supported set. Which core minors run it is php_supported_for's answer
# (PHP 8.5 needs Drupal 11.3 or later).
php_target_unconfirmed() {
  local v="$1" file; file="$(drupilot_config_file)"
  if [[ -r "$file" ]] && have_cmd jq; then
    jq -e --arg v "$v" '.php_support.unconfirmed | index($v)' "$file" >/dev/null 2>&1 && return 0
  fi
  [[ "$v" == "8.5" ]]
}

# php_supported_for <core-minor> <php> -> "yes", "no" or "unknown": whether
# Drupal core <core-minor> (X.Y) supports PHP <php> (X.Y), per drupal.org's PHP
# requirements page (api-d7 node 2891690, page of 2026-08-04, re-read
# 2026-10-03): 10.4-10.6 run 8.1-8.4; 11.1-11.4 run 8.3 and 8.4, not 8.1/8.2;
# 8.5 runs on 11.3, 11.4 and 12.0 only (never on 11.2 or earlier); 12.0 runs
# nothing older than 8.5; 8.6 runs on none of 10.4-11.3 (11.4 and 12.0 point
# at an open issue). Any other pair (an unlisted or future minor, 8.6 on 11.4
# or 12.0) is "unknown": detect it at runtime, never assume it.
php_supported_for() {
  local minor php
  minor="$(printf '%s' "${1:-}" | sed -n 's/^v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
  php="$(printf '%s' "${2:-}" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
  if [[ -z "$minor" || -z "$php" ]]; then printf 'unknown'; return 0; fi
  case "$minor:$php" in
    10.[456]:8.[1234]|11.[1234]:8.[34]|11.[34]:8.5|12.0:8.5) printf 'yes';;
    10.[456]:8.[56]|11.[12]:8.[1256]|11.3:8.[126]|11.4:8.[12]|12.0:8.[1234]) printf 'no';;
    *:8.5) if version_ge "$minor" "11.3"; then printf 'unknown'; else printf 'no'; fi;;
    *) printf 'unknown';;
  esac
  return 0
}

# rector_php_set_arg [ver] -> the named argument of Rector's ->withPhpSets()
# for a PHP target: 8.3 -> php83, 8.4 -> php84. A target flagged unconfirmed
# (PHP 8.5) or not recognised falls back to the highest confirmed supported
# version (php84 by default) with a warning on STDERR: the matching Rector
# LevelSet may not exist in the installed Rector, so it is never assumed.
rector_php_set_arg() {
  local v="${1:-$(resolve_php_target)}" file best=""
  if [[ "$v" =~ ^8\.[0-9]$ ]] && ! php_target_unconfirmed "$v"; then
    printf 'php%s' "${v//./}"; return 0
  fi
  file="$(drupilot_config_file)"
  if [[ -r "$file" ]] && have_cmd jq; then
    best="$(jq -r '(.php_support.unconfirmed // []) as $u
                   | [(.php_support.supported // [])[] | select(. as $s | $u | index($s) | not)]
                   | sort_by(split(".") | map(tonumber)) | last // empty' "$file" 2>/dev/null || true)"
  fi
  [[ "$best" =~ ^8\.[0-9]$ ]] || best="8.4"
  log_warn "PHP target '$v' is not a confirmed Rector PHP set for Drupal 11; using php${best//./} (PHP $best)."
  printf 'php%s' "${best//./}"
  return 0
}

# ---------------------------------------------------------------------------
# Drupal subject detection (module / theme) and Drupal root
# ---------------------------------------------------------------------------
# find_drupal_root [start] -> path to the Drupal project root, or empty.
# The "root" drupilot wants is the composer/DDEV project (where vendor/, .ddev/
# and composer.json live), NOT the docroot. For the standard `docroot: web`
# layout that is the PARENT of web/. The walk must therefore prefer project-root
# signals (.ddev/config.yaml, $dir/web/core) over a bare $dir/core/lib/Drupal.php
# — the latter means we are standing INSIDE the docroot, so the real root is the
# composer/DDEV parent (or $dir itself when Drupal is installed at the root,
# i.e. docroot is '.'). Getting this wrong returns .../web and makes every
# $ROOT/.ddev and host-relative (vendor/bin, web/core) path miss.
find_drupal_root() {
  local dir; dir="$(cd "${1:-$PWD}" 2>/dev/null && pwd || printf '')"
  [[ -z "$dir" ]] && return 1
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    # Project-root signals: $dir is the composer/DDEV root.
    if [[ -f "$dir/.ddev/config.yaml" || -f "$dir/web/core/lib/Drupal.php" ]]; then
      printf '%s' "$dir"; return 0
    fi
    # Bare core at $dir: either $dir IS the composer/DDEV project (docroot '.'),
    # or we are standing inside a docroot whose root is the parent.
    if [[ -f "$dir/core/lib/Drupal.php" ]]; then
      # Check $dir's OWN markers FIRST: a docroot-'.' project nested under an
      # unrelated parent that merely has a composer.json (a monorepo) must not
      # climb past itself.
      if [[ -f "$dir/.ddev/config.yaml" || -f "$dir/composer.json" ]]; then
        printf '%s' "$dir"; return 0
      fi
      # Otherwise the root is the composer/DDEV parent (a docroot whose own
      # directory has no composer.json), else $dir as a last resort.
      local parent; parent="$(dirname "$dir")"
      if [[ -f "$parent/.ddev/config.yaml" || -f "$parent/composer.json" ]]; then
        printf '%s' "$parent"; return 0
      fi
      printf '%s' "$dir"; return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# drupal_core_installed <root> -> 0 when Drupal core's code is on disk at <root>
# (web/core or a docroot-'.' core), 1 otherwise. A project checkout whose core
# is gitignored and not yet `composer install`ed has none.
drupal_core_installed() {
  [[ -n "${1:-}" ]] || return 1
  [[ -f "$1/web/core/lib/Drupal.php" || -f "$1/core/lib/Drupal.php" ]]
}

# composer_project_docroot <dir> -> the docroot of a Composer-based Drupal
# PROJECT at <dir> (relative, e.g. "web"), or nothing (exit 1) when <dir> is not
# one. A project here is a composer.json whose type is not a Drupal extension
# (drupal-module/theme/profile/library...) that requires drupal/core-recommended,
# drupal/core or drupal/core-composer-scaffold, with an existing docroot
# directory: extra.drupal-scaffold.locations.web-root, else the directory the
# installer-paths send drupal-core to (minus /core), else web/, docroot/ or
# html/. A module's own composer.json (it may require drupal/core too) has no
# docroot directory and a drupal-* type, so it never matches.
composer_project_docroot() {
  local d="${1:-}" f t req=0 c
  f="$d/composer.json"
  [[ -n "$d" && -f "$f" ]] || return 1
  local -a cands=()
  if have_cmd jq; then
    t="$(jq -r '.type // ""' "$f" 2>/dev/null || true)"
    case "$t" in drupal-*) return 1;; esac
    jq -e '((.require // {}) + (."require-dev" // {})) | keys
           | any(. == "drupal/core-recommended" or . == "drupal/core"
                 or . == "drupal/core-composer-scaffold")' "$f" >/dev/null 2>&1 && req=1
    c="$(jq -r '.extra["drupal-scaffold"].locations["web-root"] // empty' "$f" 2>/dev/null || true)"
    [[ -n "$c" ]] && cands+=("$c")
    c="$(jq -r '(.extra["installer-paths"] // {}) | to_entries[]
                | select((.value // []) | index("type:drupal-core")) | .key' "$f" 2>/dev/null | head -n1 || true)"
    [[ -n "$c" ]] && cands+=("${c%/core}")
  else
    grep -qE '"type"[[:space:]]*:[[:space:]]*"drupal-' "$f" 2>/dev/null && return 1
    grep -qE '"drupal/(core-recommended|core|core-composer-scaffold)"[[:space:]]*:' "$f" 2>/dev/null && req=1
  fi
  [[ "$req" == "1" ]] || return 1
  cands+=(web docroot html)
  for c in "${cands[@]}"; do
    c="${c#./}"; c="${c%/}"
    [[ -n "$c" && "$c" != "." && "$c" != /* ]] || continue
    if [[ -d "$d/$c" ]]; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

# find_project_root_nocore [start] -> the nearest Composer-based Drupal project
# root at or above <start> whose core is NOT installed (a monorepo clone: web/core
# and vendor/ are gitignored), or nothing (exit 1). Such a directory is not a
# Drupal root drupilot can run anything in — find_drupal_root only returns it
# when it carries a .ddev/config.yaml — so a module inside it is ported in a
# sibling test-bed (resolve-workspace.sh), never inside the user's repository.
find_project_root_nocore() {
  local dir; dir="$(cd "${1:-$PWD}" 2>/dev/null && pwd || printf '')"
  [[ -n "$dir" ]] || return 1
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    if composer_project_docroot "$dir" >/dev/null 2>&1; then
      drupal_core_installed "$dir" && return 1
      printf '%s' "$dir"; return 0
    fi
    # A Drupal root with core installed above us: not a "no core" project.
    drupal_core_installed "$dir" && return 1
    dir="$(dirname "$dir")"
  done
  return 1
}

# drupal_run_root [start] -> find_drupal_root, except that a Composer project
# checkout WITHOUT installed core (a monorepo clone) is never returned, even
# when it carries a committed .ddev/config.yaml: nothing runs there, and its
# modules are ported in a test-bed outside the repository (resolve-workspace.sh).
# A drupilot test-bed is never discarded (its core may be missing mid-setup).
# Prints nothing (exit 1) when there is no usable root.
drupal_run_root() {
  local start="${1:-$PWD}" r
  r="$(find_drupal_root "$start" 2>/dev/null || true)"
  [[ -n "$r" ]] || return 1
  if ! drupal_core_installed "$r" && find_project_root_nocore "$start" >/dev/null 2>&1 \
     && [[ "$(testbed_kind "$r")" == "none" ]]; then
    return 1
  fi
  printf '%s' "$r"
  return 0
}

# git_enclosing_repo <dir> -> the top level of the git work tree <dir> belongs to
# when that top level is NOT <dir> itself (the module is a sub-directory of a
# larger repository: a project monorepo, a folder of modules), else nothing
# (exit 1). Physical paths are compared, so a symlinked path still matches.
git_enclosing_repo() {
  local d="${1:-}" top phys
  [[ -n "$d" && -d "$d" ]] && have_cmd git || return 1
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$top" ]] || return 1
  top="$(cd "$top" 2>/dev/null && pwd -P || true)"
  phys="$(cd "$d" 2>/dev/null && pwd -P || true)"
  [[ -n "$top" && -n "$phys" && "$top" != "$phys" ]] || return 1
  printf '%s' "$top"
  return 0
}

# patch_project_slug <name> -> the project part of a patch file name. Drupal.org's
# convention is [project]-[short-description]-[issue]-[comment].patch with the
# project machine name kept AS IS, underscores included (the documented example
# is "some_module-some-bug-123456-3.patch", https://www.drupal.org/node/707484).
# So it lowercases and keeps [a-z0-9_]; any other run of characters becomes '-'.
patch_project_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9_]+/-/g; s/^[-_]+//; s/[-_]+$//'
}

# run_with_timeout <seconds> <cmd> [args...] -> runs cmd with a wall-clock limit
# when `timeout` (GNU coreutils) or `gtimeout` (Homebrew coreutils on macOS) is
# available, else runs it unbounded. <seconds> 0 (or empty) means no limit.
# Returns cmd's exit code, or 124 when the limit was hit. stdin is NOT
# redirected; callers that must never wait on input pass </dev/null.
# CAVEAT: the limit does NOT propagate through `ddev exec` / `ddev composer`
# (docker exec): only the host-side client is killed and the process keeps
# running in the web container. Bound in-container work with the container's
# own `timeout` (ddev exec "timeout -k 20 N /usr/local/bin/composer ...": name
# Composer by the absolute path ddev_global_composer returns, since under
# `timeout` a bare `composer` resolves to a test-bed's vendor/bin/composer), or
# stop it after a 124 with ddev_stop_composer before cleaning up the files it
# writes.
run_with_timeout() {
  local secs="${1:-0}"; shift
  local t=""
  if [[ "$secs" =~ ^[0-9]+$ && "$secs" -gt 0 ]]; then
    if have_cmd timeout; then t="timeout"
    elif have_cmd gtimeout; then t="gtimeout"
    fi
  fi
  if [[ -n "$t" ]]; then
    "$t" "$secs" "$@"
  else
    "$@"
  fi
}

# ddev_stop_composer <root> -> best effort: stop every composer process left
# running in the project's web container (e.g. after run_with_timeout killed
# only the host-side `ddev composer` client). TERM, up to ~10 s of grace, then
# KILL. Returns 0 when none is left, 1 otherwise (or when it cannot tell).
# Never starts a stopped project.
ddev_stop_composer() {
  local r="${1:-}" n=0
  ddev_running "$r" || return 0
  # '[c]omposer' matches "composer" but not the pkill/pgrep command line itself.
  ( cd "$r" 2>/dev/null && ddev exec "pkill -TERM -f '[c]omposer' || true" </dev/null >/dev/null 2>&1 ) || true
  while [[ "$n" -lt 10 ]]; do
    if ! ( cd "$r" 2>/dev/null && ddev exec "pgrep -f '[c]omposer' >/dev/null" </dev/null >/dev/null 2>&1 ); then
      return 0
    fi
    sleep 1; n=$((n + 1))
  done
  ( cd "$r" 2>/dev/null && ddev exec "pkill -KILL -f '[c]omposer' || true" </dev/null >/dev/null 2>&1 ) || true
  sleep 1
  if ( cd "$r" 2>/dev/null && ddev exec "pgrep -f '[c]omposer' >/dev/null" </dev/null >/dev/null 2>&1 ); then
    return 1
  fi
  return 0
}

# ddev_global_composer <root> -> echoes the absolute path of the web
# container's OWN composer (normally /usr/local/bin/composer), for a composer
# call that is NOT the first word of the `ddev exec` command line.
# Why: a Drupal test-bed with drupal/core-dev ships vendor/bin/composer, and
# vendor/bin comes first on the container PATH. The ddev-webserver image only
# hides it from the interactive shell through EXECIGNORE, which a wrapper such
# as `timeout N composer ...`, `sh -c` or a child `bash -c` does not inherit.
# That copy runs on the test-bed's autoloader, so its Composer plugins (e.g.
# phpstan/extension-installer, which writes its GeneratedConfig.php next to its
# own class) rewrite the TEST-BED's vendor while working on another project.
# The path is asked from the top-level `ddev exec` shell (where EXECIGNORE
# applies) and rejected when it still points into /var/www/html; the fallback is
# the image's documented location. Never starts a stopped project.
ddev_global_composer() {
  local r="${1:-}" p=""
  if ddev_running "$r"; then
    p="$( cd "$r" 2>/dev/null && ddev exec -d / 'command -v composer' </dev/null 2>/dev/null | tr -d '\r' | tail -n 1 || true)"
  fi
  case "$p" in
    /*) case "$p" in /var/www/html/*) p="";; esac;;
    *) p="";;
  esac
  printf '%s' "${p:-/usr/local/bin/composer}"
  return 0
}

# run_dropping_ddev_failure_line <cmd> [args...] -> runs the command with its
# stdout untouched and its stderr streamed back WITHOUT `ddev exec`'s own red
# "Failed to execute command ...: exit status N" wrapper line, and returns the
# command's exit code. For tools whose non-zero exit is a normal verdict
# (phpcs: violations found; PHPUnit: failing tests), where the caller already
# reports the outcome; the wrapper line only repeats the exit status. Works on
# every DDEV version (filtering, not `ddev exec --quiet`). bash 3.2-safe.
run_dropping_ddev_failure_line() {
  local had_e=0 rc
  case "$-" in *e*) had_e=1;; esac
  set +e
  { "$@" 2>&1 1>&3 3>&- | { grep -vE 'Failed to execute command .*: exit status [0-9]+' || true; } >&2; } 3>&1
  rc=${PIPESTATUS[0]}
  [[ "$had_e" == 1 ]] && set -e
  return "$rc"
}

# phpstan_extension_config_problem <project_dir> -> checks the
# phpstan/extension-installer GeneratedConfig.php of a Composer project (a
# test-bed or a core-matrix reference core). Prints a one-line reason on STDOUT
# and returns 1 when it is broken: an extension include that does not resolve
# (PHPStan resolves `relative_install_path` from the file's directory, then the
# absolute `install_path`), or an installed `phpstan-extension` package the file
# does not list (e.g. the stub the package ships, left in place when another
# Composer's plugin ran instead). Returns 0, printing nothing, when the file is
# sound or the project has no extension-installer. Host-side and read-only.
phpstan_extension_config_problem() {
  local d="${1:-}" src gc listed missing name mount=""
  src="$d/vendor/phpstan/extension-installer/src"
  gc="$src/GeneratedConfig.php"
  [[ -d "$src" ]] || return 0
  if [[ ! -f "$gc" ]]; then printf 'vendor/phpstan/extension-installer/src/GeneratedConfig.php is missing'; return 1; fi
  mount="$(cd "$d" 2>/dev/null && pwd || true)"
  while [[ -n "$mount" && "$mount" != "/" && ! -f "$mount/.ddev/config.yaml" ]]; do mount="$(dirname "$mount")"; done
  [[ "$mount" == "/" ]] && mount=""
  # Each extension entry -> "name<TAB>relative_install_path<TAB>install_path<TAB>include".
  missing="$(awk '
    function val(s,   i) { i = index(s, "=>"); s = substr(s, i + 2); gsub(/^[ \t]*\047|\047,?[ \t]*$/, "", s); return s }
    /^  \047[^\047]+\047 => *$/ { name = $0; sub(/^  \047/, "", name); sub(/\047.*$/, "", name); rel = ""; abs = ""; next }
    name != "" && /\047relative_install_path\047 =>/ { rel = val($0); next }
    name != "" && /\047install_path\047 =>/ { abs = val($0); next }
    name != "" && /^        [0-9]+ => \047/ { printf "%s\t%s\t%s\t%s\n", name, rel, abs, val($0); next }
  ' "$gc" 2>/dev/null | while IFS="$(printf '\t')" read -r name rel abs inc; do
      [[ -n "$inc" ]] || continue
      if [[ -n "$rel" && -f "$src/$rel/$inc" ]]; then continue; fi
      # install_path is a container path (/var/www/html/...): map it to the
      # host through the DDEV project that mounts it.
      case "$abs" in /var/www/html/*) [[ -n "$mount" ]] && abs="$mount/${abs#/var/www/html/}";; esac
      [[ -n "$abs" && -f "$abs/$inc" ]] && continue
      printf '%s (%s)\n' "$name" "$inc"
    done | head -n 3 | tr '\n' ' ' || true)"
  if [[ -n "$missing" ]]; then
    printf 'it points to extension files that do not exist: %s' "$missing"
    return 1
  fi
  if have_cmd jq && [[ -f "$d/vendor/composer/installed.json" ]]; then
    listed="$(grep -oE "^  '[^']+' =>" "$gc" 2>/dev/null | sed -E "s/^  '//; s/' =>\$//" || true)"
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      if ! printf '%s\n' "$listed" | grep -qxF "$name"; then
        printf 'it does not list the installed PHPStan extension %s' "$name"
        return 1
      fi
    done < <(jq -r '(if type == "object" then (.packages // []) else . end)[] | select(.type == "phpstan-extension") | .name' "$d/vendor/composer/installed.json" 2>/dev/null || true)
  fi
  return 0
}

# ddev_project_status [root] -> echoes the DDEV project status for the project
# at root ("running", "stopped", "paused", "unhealthy", ...) or nothing when
# there is no DDEV project / it cannot be determined. READ-ONLY: it asks
# `ddev describe -j` (which never starts a project) and, without jq, falls back
# to `docker ps` filtered by the project's labels. It must never use `ddev exec`
# (that STARTS a stopped project).
ddev_project_status() {
  have_cmd ddev || return 0
  local r="${1:-$(find_drupal_root 2>/dev/null || true)}"
  [[ -n "$r" && -f "$r/.ddev/config.yaml" ]] || return 0
  local st=""
  if have_cmd jq; then
    st="$( (cd "$r" 2>/dev/null && ddev describe -j </dev/null 2>/dev/null) \
      | jq -r 'select(.raw != null) | .raw.status // empty' 2>/dev/null | head -n1 || true)"
  elif have_cmd docker; then
    local name
    name="$(grep -E '^name:' "$r/.ddev/config.yaml" 2>/dev/null | head -n1 \
      | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' | tr -d '"'"'"'')"
    [[ -n "$name" ]] || name="$(basename "$r")"
    if docker ps --filter "label=com.ddev.site-name=$name" \
         --filter "label=com.docker.compose.service=web" --format '{{.ID}}' </dev/null 2>/dev/null \
         | grep -q .; then
      st="running"
    else
      st="stopped"
    fi
  fi
  printf '%s' "$st"
  return 0
}

# ddev_running [root] -> 0 if the DDEV project at root is up: status "running",
# "starting" or "unhealthy" (DDEV's SiteRunning/SiteStarting/SiteUnhealthy —
# the containers exist and run, so `ddev exec` works). Read-only: it never
# starts a stopped or paused project (see ddev_project_status).
ddev_running() {
  local st
  st="$(ddev_project_status "${1:-}")"
  case "$st" in running|starting|unhealthy) return 0;; esac
  return 1
}

# ddev_ensure_running [root] -> for scripts that RUN the toolchain (Rector,
# PHPStan, PHPCS, PHPUnit, Composer): when root has a DDEV project that is not
# up, start it explicitly with `ddev start` (logged on stderr, stdin closed) and
# verify the status afterwards. Returns 0 when the project is running (or there
# is no DDEV project / no ddev at all, so the caller falls back to the host),
# 1 when the start failed. Read-only flows (status, doctor, preflight, hooks)
# must use ddev_running instead and never call this.
ddev_ensure_running() {
  have_cmd ddev || return 0
  local r="${1:-$(find_drupal_root 2>/dev/null || true)}" st
  [[ -n "$r" && -f "$r/.ddev/config.yaml" ]] || return 0
  ddev_running "$r" && return 0
  st="$(ddev_project_status "$r")"
  log_step "Starting the DDEV project at $r (status: ${st:-unknown})"
  if ! ( cd "$r" 2>/dev/null && ddev start </dev/null >&2 ); then
    log_err "'ddev start' failed for $r. Check the Docker daemon and 'ddev logs'."
    return 1
  fi
  if ! ddev_running "$r"; then
    log_err "'ddev start' returned but the project is not running (status: $(ddev_project_status "$r"))."
    return 1
  fi
  return 0
}

# ddev_ensure_running_or_host <root> <vendor/bin tool> -> for the ANALYSIS
# scripts (Rector, PHPStan, PHPCS), which the 'analyze' profile allows without
# Docker: try ddev_ensure_running, and when the project cannot be started (e.g.
# the Docker daemon is down) fall back to the host toolchain instead of failing,
# provided <root>/vendor/bin/<tool> and a host php exist. drupal_runner then
# yields "" and the analysis runs on the host, as documented. Returns 1 only
# when neither DDEV nor the host toolchain can run the tool. Scripts that NEED
# DDEV (PHPUnit, toolchain install, the core matrix) keep ddev_ensure_running.
ddev_ensure_running_or_host() {
  local r="${1:-}" tool="${2:-}"
  ddev_ensure_running "$r" && return 0
  if [[ -n "$tool" && -x "$r/vendor/bin/$tool" ]] && have_cmd php; then
    log_warn "DDEV could not be started for $r: running $tool with the host toolchain (vendor/bin/$tool, host PHP $(tool_version php 2>/dev/null || echo '?'))."
    return 0
  fi
  return 1
}

# drupal_runner [root] -> echoes a command prefix to run the toolchain:
#   "ddev exec"  when the DDEV environment is up, or
#   ""           to run host binaries (vendor/bin/*) directly.
# Callers cd into the Drupal root first; relative paths (web/modules/custom/...)
# resolve identically inside the container and on the host.
drupal_runner() {
  local r="${1:-$(find_drupal_root 2>/dev/null || true)}"
  if ddev_running "$r"; then printf 'ddev exec'; else printf ''; fi
}

# ddev_php_version [root] -> echoes the php_version set in the project's
# .ddev/config.yaml (empty if there is no project or no key). Reads the YAML
# only — it does NOT start or `ddev exec`, so it is cheap and safe in gates and
# hooks. DDEV is freely configurable across PHP minors, so this is the version
# the toolchain actually runs on when the container is up.
ddev_php_version() {
  local r="${1:-$(find_drupal_root 2>/dev/null || true)}"
  local cfg="$r/.ddev/config.yaml" v
  [[ -n "$r" && -f "$cfg" ]] || return 0
  v="$(grep -E '^[[:space:]]*php_version:' "$cfg" 2>/dev/null | head -n1 \
        | sed -E 's/^[[:space:]]*php_version:[[:space:]]*//; s/[[:space:]]*(#.*)?$//')"
  v="${v//\"/}"; v="${v//\'/}"
  trim "$v"
}

# drupal_core_version [root] -> the INSTALLED drupal/core version (e.g. 11.4.8),
# read from the root's composer.lock (jq), else from the VERSION constant in
# core/lib/Drupal.php. Prints nothing when unknown. Read-only, never fatal.
drupal_core_version() {
  local r="${1:-$(find_drupal_root 2>/dev/null || true)}" v="" f
  [[ -n "$r" ]] || return 0
  if [[ -f "$r/composer.lock" ]] && have_cmd jq; then
    v="$(jq -r '((.packages // []) + (."packages-dev" // []))
                | map(select(.name == "drupal/core")) | (.[0].version // empty)' \
          "$r/composer.lock" 2>/dev/null || true)"
  fi
  if [[ -z "$v" ]]; then
    for f in "$r/web/core/lib/Drupal.php" "$r/core/lib/Drupal.php"; do
      [[ -f "$f" ]] || continue
      v="$(sed -nE "s/^[[:space:]]*const VERSION = '([^']+)'.*/\1/p" "$f" 2>/dev/null | head -n1)"
      [[ -n "$v" ]] && break
    done
  fi
  printf '%s' "${v#v}"
  return 0
}

# core_dev_requirement [root] -> the Composer requirement for drupal/core-dev
# (PHPUnit + the Drupal test dependencies) MATCHING the installed core, so the
# test toolchain never drifts from core:
#   11.4.8        -> drupal/core-dev:~11.4.8   (same minor, >= that patch)
#   11.2.0-rc1    -> drupal/core-dev:11.2.0-rc1 (pre-release: exact)
#   11.x-dev      -> drupal/core-dev:11.x-dev   (dev branch: exact)
#   unknown       -> drupal/core-dev:<resolve_drupal_target> (e.g. ^11)
# The package name comes from config .packages.core_dev (default drupal/core-dev).
core_dev_requirement() {
  local r="${1:-$(find_drupal_root 2>/dev/null || true)}" v pkg
  pkg="$(config_json '.packages.core_dev' 'drupal/core-dev')"
  pkg="${pkg%%:*}"; [[ -n "$pkg" ]] || pkg="drupal/core-dev"
  v="$(drupal_core_version "$r")"
  if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s:~%s' "$pkg" "$v"
  elif [[ -n "$v" ]]; then
    printf '%s:%s' "$pkg" "$v"
  else
    printf '%s:%s' "$pkg" "$(resolve_drupal_target)"
  fi
  return 0
}

# phpunit_available [root] -> 0 when vendor/bin/phpunit exists for the project,
# checked through drupal_runner (inside the container when DDEV is up), so a
# mutagen-synced or container-only vendor is seen exactly as PHPUnit would be.
phpunit_available() {
  local r="${1:-$(find_drupal_root 2>/dev/null || true)}" runner
  [[ -n "$r" ]] || return 1
  runner="$(drupal_runner "$r")"
  if [[ -n "$runner" ]]; then
    # shellcheck disable=SC2086  # intentional word-split: runner is a command prefix.
    ( cd "$r" && $runner test -f vendor/bin/phpunit ) >/dev/null 2>&1
  else
    [[ -f "$r/vendor/bin/phpunit" ]]
  fi
}

# ddev_addons_installed [root] -> one line per installed DDEV add-on on STDOUT:
# "<name><TAB><version>" (version may be empty). Sources, in order:
#   1. `ddev add-on list --installed -j` (machine-readable; the human table is
#      truncated to the terminal width, e.g. "ddev-selenium-stand…", so it must
#      never be parsed);
#   2. the project's .ddev/addon-metadata/<name>/manifest.yaml files (no ddev
#      call needed; also covers older DDEV without `add-on list -j`).
# Prints nothing (and returns 0) when there is no DDEV project. Never fatal.
ddev_addons_installed() {
  local r="${1:-$(find_drupal_root 2>/dev/null || true)}"
  [[ -n "$r" && -f "$r/.ddev/config.yaml" ]] || return 0
  local out=""
  if have_cmd ddev && have_cmd jq; then
    out="$( ( cd "$r" 2>/dev/null && ddev add-on list --installed -j </dev/null 2>/dev/null ) \
      | jq -r 'select(type=="object") | (.raw // [])[]? | select(.Name != null) | "\(.Name)\t\(.Version // "")"' 2>/dev/null || true)"
  fi
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out"; return 0
  fi
  [[ -d "$r/.ddev/addon-metadata" ]] || return 0
  local m name ver
  for m in "$r"/.ddev/addon-metadata/*/manifest.yaml; do
    [[ -f "$m" ]] || continue
    name="$(grep -E '^name:' "$m" 2>/dev/null | head -n1 | sed -E 's/^name:[[:space:]]*//; s/["'\'']//g')"
    ver="$(grep -E '^version:' "$m" 2>/dev/null | head -n1 | sed -E 's/^version:[[:space:]]*//; s/["'\'']//g')"
    [[ -n "$name" ]] || name="$(basename "$(dirname "$m")")"
    printf '%s\t%s\n' "$(trim "$name")" "$(trim "$ver")"
  done
  return 0
}

# ddev_addon_version <name> [root] -> version of an installed add-on ("installed"
# when present without a version); returns 1 when it is not installed. <name> is
# the short (ddev-selenium-standalone-chrome) or org/name form.
ddev_addon_version() {
  local short="${1##*/}" name ver
  while IFS=$'\t' read -r name ver; do
    [[ "$name" == "$short" ]] || continue
    printf '%s' "${ver:-installed}"; return 0
  done < <(ddev_addons_installed "${2:-}")
  return 1
}

# subject_info_file <dir> -> first *.info.yml in the directory (non-recursive)
subject_info_file() {
  local dir="${1:-$PWD}" f
  local -a matches=()
  for f in "$dir"/*.info.yml; do
    [[ -e "$f" ]] && matches+=("$f")
  done
  [[ ${#matches[@]} -gt 0 ]] || return 1
  # One *.info.yml is the norm; if a directory unexpectedly has more, pick the
  # first in a STABLE (LC_ALL=C) order so the choice is deterministic regardless
  # of filesystem listing order.
  if [[ ${#matches[@]} -gt 1 ]]; then
    printf '%s' "$(printf '%s\n' "${matches[@]}" | LC_ALL=C sort | head -n1)"
  else
    printf '%s' "${matches[0]}"
  fi
  return 0
}

# is_drupal_extension_dir <dir> -> 0 if it contains a *.info.yml
is_drupal_extension_dir() { subject_info_file "$1" >/dev/null 2>&1; }

# subject_machine_name <dir> -> machine name (basename of the *.info.yml)
subject_machine_name() {
  local f; f="$(subject_info_file "${1:-$PWD}")" || return 1
  basename "$f" .info.yml
}

# subject_type <dir> -> module | theme | profile  (parses info.yml; infers if missing)
subject_type() {
  local dir="${1:-$PWD}" f t
  f="$(subject_info_file "$dir")" || { printf ''; return 1; }
  t="$(grep -E '^[[:space:]]*type:' "$f" 2>/dev/null | head -n1 | sed -E 's/^[[:space:]]*type:[[:space:]]*//; s/[[:space:]]*$//' | tr -d '"'"'"'')"
  if [[ -n "$t" ]]; then printf '%s' "$t"; return 0; fi
  # Infer from artifacts / path
  local mn; mn="$(basename "$f" .info.yml)"
  if [[ -f "$dir/$mn.theme" || "$dir" == */themes/* ]]; then printf 'theme'
  elif [[ -f "$dir/$mn.profile" || "$dir" == */profiles/* ]]; then printf 'profile'
  else printf 'module'; fi
}

# subject_core_requirement <dir> -> value of core_version_requirement or empty
subject_core_requirement() {
  local f; f="$(subject_info_file "${1:-$PWD}")" || return 1
  grep -E '^[[:space:]]*core_version_requirement:' "$f" 2>/dev/null | head -n1 \
    | sed -E 's/^[[:space:]]*core_version_requirement:[[:space:]]*//; s/[[:space:]]*$//'
}

# info_yml_value <info_file> <key> -> the scalar value of a TOP-LEVEL key in an
# *.info.yml (quotes and a trailing ` # comment` stripped), or nothing. Line
# based (no YAML parser is assumed): a flow/block collection prints nothing.
info_yml_value() {
  local f="$1" key="$2"
  [[ -r "$f" ]] || return 0
  AWKV_k="$key" awk '
    BEGIN { k = ENVIRON["AWKV_k"] }
    index($0, k ":") == 1 {
      v = substr($0, length(k) + 2)
      sub(/^[ \t]+/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/[ \t\r]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      if (v ~ /^[\[{|>]/) exit
      print v; exit
    }' "$f"
  return 0
}

# info_yml_dependencies <info_file> -> the `dependencies:` entries of an
# *.info.yml, one per line, normalized: quotes, a `(>=x)` version constraint and
# comments stripped, the `project:module` form kept as written (`drupal:node`,
# `token:token`, a bare `token`). Block lists and one-line flow lists
# (`dependencies: [a, b]`) are read; `test_dependencies` is not. The module is
# the part after the last `:`. Prints nothing for a missing file.
info_yml_dependencies() {
  local f="$1"
  [[ -r "$f" ]] || return 0
  awk '
    function emit(s) {
      gsub(/["\047]/, "", s); sub(/\(.*$/, "", s)
      sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s)
      if (s != "") print s
    }
    /^dependencies:[ \t]*\[/ {
      s = $0; sub(/^dependencies:[ \t]*\[/, "", s); sub(/\].*$/, "", s)
      n = split(s, a, ","); for (i = 1; i <= n; i++) emit(a[i])
      next
    }
    /^dependencies:/ { inb = 1; next }
    inb && /^[^ \t#-]/ { inb = 0 }
    inb && /^[ \t]*-/ { s = $0; sub(/^[ \t]*-[ \t]*/, "", s); sub(/[ \t]+#.*$/, "", s); emit(s) }
  ' "$f"
  return 0
}

# is_drupal_core_module <machine_name> -> 0 when it is a module that ships with
# Drupal 10/11 core (always available, so never a contrib dependency). A rare
# omission degrades to "not core" (verify by hand), never to a false "core".
DRUPAL_CORE_MODULES=" action announcements_feed automated_cron ban basic_auth big_pipe block block_content book breakpoint ckeditor5 comment config config_translation contact content_moderation content_translation contextual datetime datetime_range dblog dynamic_page_cache editor field field_layout field_ui file filter help help_topics history image inline_form_errors jsonapi language layout_builder layout_discovery link locale media media_library menu_link_content menu_ui migrate migrate_drupal migrate_drupal_ui mysql navigation node options package_manager page_cache path path_alias pgsql responsive_image rest search serialization settings_tray shortcut sqlite syslog system taxonomy telephone text toolbar tour update user views views_ui workflows workspaces workspaces_ui "
is_drupal_core_module() { [[ "$DRUPAL_CORE_MODULES" == *" ${1:-} "* ]]; }

# core_requirement_admits <constraint> <major> -> 0 when a Composer-style
# core_version_requirement admits some <major>.x release ('^10 || ^11' admits
# 11; '^8.8 || ^9 || ^10' does not; '>=10' does; '^10.3' does not). A
# heuristic over each `||` alternative's bounds (^, ~, >=, >, <, <=, =, X.*),
# enough to flag an obsolete requirement; an unreadable constraint returns 1.
core_requirement_admits() {
  printf '%s' "${1:-}" | tr -d "\"'" | tr '|' '\n' | AWKV_m="${2:-11}" awk '
    BEGIN { m = ENVIRON["AWKV_m"] + 0; ok = 0 }
    function maj(p,   v) { sub(/^(\^|~|>=|<=|>|<|==|=|v)+/, "", p); split(p, v, "."); return v[1] + 0 }
    {
      n = split($0, parts, /[[:space:],]+/); lo = -1; hi = 999; seen = 0
      for (i = 1; i <= n; i++) {
        p = parts[i]
        if (p == "" || p !~ /[0-9]/) continue
        seen = 1
        if (p ~ /^(\^|~)/) { x = maj(p); if (x > lo) lo = x; if (x < hi) hi = x }
        else if (p ~ /^>/) { x = maj(p); if (x > lo) lo = x }
        else if (p ~ /^<=/) { x = maj(p); if (x < hi) hi = x }
        else if (p ~ /^</) { x = maj(p); q = p; sub(/^</, "", q); if (q ~ /^[0-9]+(\.0)*$/) x = x - 1; if (x < hi) hi = x }
        else { x = maj(p); if (x > lo) lo = x; if (x < hi) hi = x }
      }
      if (seen && lo <= m && m <= hi) ok = 1
    }
    END { exit ok ? 0 : 1 }'
}

# core_floor_from_requirement <constraint> -> the lowest core MAJOR.MINOR the
# Composer-style constraint admits ('^10 || ^11' -> 10.0, '^10.3 || ^11' ->
# 10.3, '^9.2 || ^10' -> 9.2, '>=10.2' -> 10.2, '^11' -> 11.0). Upper bounds
# ('<', '<=', '!=') are ignored. Prints nothing (and returns 0) when no version
# can be read, so callers treat an unknown floor as "unknown", never guess.
core_floor_from_requirement() {
  printf '%s' "${1:-}" | tr -d "\"'" | tr '|' '\n' | awk '
    {
      n = split($0, parts, /[[:space:],]+/)
      for (i = 1; i <= n; i++) {
        p = parts[i]
        if (p == "" || p ~ /^(<|!=)/) continue
        sub(/^(\^|~|>=|>|==|=|v)+/, "", p)
        if (p !~ /^[0-9]+/) continue
        split(p, v, ".")
        maj = v[1] + 0; mn = (v[2] ~ /^[0-9]+$/) ? v[2] + 0 : 0
        if (!have || maj < bmaj || (maj == bmaj && mn < bmin)) { bmaj = maj; bmin = mn; have = 1 }
        break
      }
    }
    END { if (have) printf "%d.%d", bmaj, bmin }'
  return 0
}

# core_requirement_raise_floor <constraint> <MAJOR.MINOR> -> the constraint with
# its lowest admitted core raised to MAJOR.MINOR, keeping every higher major:
# ('^10 || ^11', 10.3) -> '^10.3 || ^11' · ('^10 || ^11', 11.1) -> '^11.1' ·
# ('^10.3 || ^11 || ^12', 10.2) -> unchanged · ('^11', 11.1) -> '^11.1' ·
# ('>=10.2', 10.3) -> '>=10.3' · ('', 10.3) -> '^10.3'. An alternative of a lower major is dropped; one of the
# same major whose minor is lower is replaced by ^MAJOR.MINOR. Used when a
# change needs a newer core than declared (e.g. plugin attributes whose
# annotation is removed: convert-attributes.sh). Pure: STDOUT only.
core_requirement_raise_floor() {
  local req="${1:-}" floor="${2:-}"
  [[ "$floor" =~ ^[0-9]+\.[0-9]+$ ]] || { printf '%s' "$req"; return 0; }
  printf '%s' "$req" | tr -d "\"'" | tr '|' '\n' | AWKV_f="$floor" awk '
    BEGIN { split(ENVIRON["AWKV_f"], f, "."); fmaj = f[1] + 0; fmin = f[2] + 0; out = ""; same = 0 }
    function add(s) { out = (out == "") ? s : out " || " s }
    {
      a = $0; sub(/^[ \t]+/, "", a); sub(/[ \t]+$/, "", a)
      if (a == "") next
      p = a; sub(/^(\^|~|>=|>|==|=|v)+/, "", p)
      if (p !~ /^[0-9]+/) { add(a); next }
      split(p, v, "."); maj = v[1] + 0; mn = (v[2] ~ /^[0-9]+$/) ? v[2] + 0 : 0
      if (maj < fmaj) next
      if (maj == fmaj) {
        same = 1
        if (mn < fmin) a = (a ~ /^>/) ? ">=" fmaj "." fmin : ((fmin > 0) ? "^" fmaj "." fmin : "^" fmaj)
      }
      add(a)
    }
    END {
      fl = (fmin > 0) ? "^" fmaj "." fmin : "^" fmaj
      if (!same) out = (out == "") ? fl : fl " || " out
      printf "%s", out
    }'
  return 0
}

# core_verify_legs <constraint> -> the core "legs" a Composer-style constraint
# asks to verify, one per line, lowest first: the lower bound of each declared
# major, as MAJOR.MINOR when an explicit minor above 0 is given, else MAJOR
# ('^10 || ^11' -> 10, 11 · '^10.3 || ^11' -> 10.3, 11 · '^11' -> 11 ·
# '>=10.2' -> 10.2). Majors below 10 are dropped (drupilot only verifies the
# Drupal 10 / 11 range phpstan-drupal 2.x supports). Upper bounds are ignored.
# Prints nothing when no version can be read. Pure: no I/O besides STDOUT.
core_verify_legs() {
  printf '%s' "${1:-}" | tr -d "\"'" | tr '|' '\n' | awk '
    {
      n = split($0, parts, /[[:space:],]+/)
      for (i = 1; i <= n; i++) {
        p = parts[i]
        if (p == "" || p ~ /^(<|!=)/) continue
        sub(/^(\^|~|>=|>|==|=|v)+/, "", p)
        if (p !~ /^[0-9]+/) continue
        split(p, v, ".")
        maj = v[1] + 0; mn = (v[2] ~ /^[0-9]+$/) ? v[2] + 0 : 0
        if (maj < 10) break
        if (!(maj in best) || mn < best[maj]) best[maj] = mn
        break
      }
    }
    END {
      for (m = 10; m <= 99; m++) {
        if (!(m in best)) continue
        if (best[m] > 0) printf "%d.%d\n", m, best[m]; else printf "%d\n", m
      }
    }'
  return 0
}

# core_matrix_legs <constraint> -> the legs verify-core-matrix.sh checks by
# default (--cores auto): core_verify_legs, plus the FLOOR minor of every
# major declared without a minor that is below the newest declared major or
# below Drupal 11, the test-bed's major ('^10 || ^11' -> 10.0, 10, 11; '^10' ->
# 10.0, 10; '^11' -> 11). A bare '^10' leg resolves to the newest
# 10.x, which cannot see an API added after 10.0 (e.g. the Block attribute,
# 10.2), so the floor is checked too; an explicit minor floor ('^10.3 || ^11'
# -> 10.3, 11) is already its own leg. Pure: STDOUT only.
core_matrix_legs() {
  local legs top
  legs="$(core_verify_legs "${1:-}")"
  [[ -n "$legs" ]] || return 0
  top="$(printf '%s\n' "$legs" | tail -n 1 | cut -d. -f1)"
  printf '%s\n' "$legs" | awk -v top="$top" '
    { split($0, v, "."); if ($0 !~ /\./ && (v[1] + 0 < top + 0 || v[1] + 0 < 11)) print v[1] ".0"; print }'
  return 0
}

# subject_attribute_floor <subject> -> "MAJOR.MINOR<TAB>attribute FQCN": the
# highest core minor that ships a plugin attribute class the subject's code
# uses (an import or a `#[\...]` of a class listed in
# config/plugin-attributes.json, `types` and `unsupported`). The class does not
# exist on an older core, so it is a floor of the code itself (PHPStan reports
# the unknown class there). Prints nothing when none is used or jq is missing.
subject_attribute_floor() {
  local subj="${1:-}" tf used
  tf="$(plugin_root)/config/plugin-attributes.json"
  have_cmd jq || return 0
  [[ -r "$tf" && -d "$subj" ]] || return 0
  used="$(find "$subj" \( -name vendor -o -name node_modules -o -name .git \) -prune -o -type f \
      \( -name '*.php' -o -name '*.module' -o -name '*.inc' -o -name '*.install' -o -name '*.theme' \
         -o -name '*.profile' \) -print 2>/dev/null \
    | while IFS= read -r f; do
        grep -hoE '(^[[:space:]]*use[[:space:]]+|#\[[[:space:]]*)\\?Drupal\\[A-Za-z0-9_\\]+' "$f" 2>/dev/null || true
      done \
    | sed -E 's/^[[:space:]]*use[[:space:]]+//; s/^#\[[[:space:]]*//; s/^\\//' | LC_ALL=C sort -u)"
  [[ -n "$used" ]] || return 0
  jq -r --arg u "$used" '
    ($u | split("\n")) as $used
    | [(.types // [])[], (.unsupported // [])[]]
    | map(select(.attribute as $a | any($used[]; . == $a)))
    | if length == 0 then empty
      else max_by(.since | split(".") | map(tonumber)) | "\(.since)\t\(.attribute)" end' "$tf" 2>/dev/null || true
  return 0
}

# subject_digest <dir> -> SHA-256 over the subject's analysable sources (PHP
# family files, *.yml, composer.json; .git/vendor/node_modules skipped), in a
# stable order. Generated artifacts next to the module (a local .patch, the
# issue markdown) do not change it. Prints nothing when no hasher is available.
subject_digest() {
  local d="${1:-$PWD}" hasher=""
  if have_cmd sha256sum; then hasher="sha256sum"; elif have_cmd shasum; then hasher="shasum -a 256"; else return 0; fi
  ( cd -P "$d" 2>/dev/null || exit 0
    find . \( -name .git -o -name vendor -o -name node_modules \) -prune -o -type f \
      \( -name '*.php' -o -name '*.module' -o -name '*.inc' -o -name '*.install' -o -name '*.theme' \
         -o -name '*.profile' -o -name '*.engine' -o -name '*.yml' -o -name composer.json \) -print 2>/dev/null \
      | LC_ALL=C sort | while IFS= read -r f; do printf '%s\n' "$f"; cat "$f"; done ) \
    | $hasher | cut -d' ' -f1
  return 0
}

# core_matrix_file <subject> -> path of the subject's persisted core-matrix
# result (verify-core-matrix.sh), whether or not it exists yet.
core_matrix_file() { printf '%s/core-matrix.json' "$(project_state_dir "${1:-$PWD}")"; }

# negative_controls_file <subject> -> path of the subject's negative-control
# records (negative-control.sh), whether or not it exists yet. Hidden state,
# like last-test.json: a deliberate red run is never a project artifact.
negative_controls_file() { printf '%s/negative-controls.json' "$(project_state_dir "${1:-$PWD}")"; }

# negative_controls_summary <subject> -> compact JSON summary of the recorded
# negative controls ({total, effective, ineffective, error, stale, controls:
# [{test, type, label, verdict, at, stale}]}), or "null" when none was recorded.
# A control is "stale" when the subject's sources changed after it ran (its
# subject_digest differs), so a report never presents it as current proof.
negative_controls_summary() {
  local s="${1:-$PWD}" f digest
  f="$(negative_controls_file "$s")"
  if [[ ! -r "$f" ]] || ! have_cmd jq; then printf 'null'; return 0; fi
  digest="$(subject_digest "$s")"
  jq -c --arg d "$digest" '
    if (type == "array") and (length > 0) then
      [ .[] | {test, type, label: .label, verdict, at, mutation: (.mutation.kind // null),
               stale: ((.subject_digest // "") != "" and $d != "" and .subject_digest != $d)} ] as $c
      | {total: ($c | length),
         effective: ([ $c[] | select(.verdict == "effective") ] | length),
         ineffective: ([ $c[] | select(.verdict == "ineffective") ] | length),
         error: ([ $c[] | select(.verdict == "error") ] | length),
         stale: ([ $c[] | select(.stale) ] | length),
         controls: $c}
    else null end' "$f" 2>/dev/null || printf 'null'
  return 0
}

# --- Per-subject state (state.json) ------------------------------------------
# One JSON record per subject in its HIDDEN state dir (project_state_dir, next
# to assess.json / last-test.json / core-matrix.json): which porting stages
# were reached and when, plus a snapshot of the facts a portfolio view needs
# (effort, branch/commit, toolchain, preservation, core matrix, patch).
#
# Why hidden and not <root>/.drupilot/: it is machine state like the rest of
# that dir. It must survive `git clean` / a workspace rebuild (the stage
# ladder would otherwise restart at /drupilot-port), it can never leak into a
# patch, and /drupilot-status --all can find every subject's record under one
# data dir without walking project trees. The VISIBLE artifacts dir keeps only
# human-facing outputs; `state.sh show/list` render the record on demand.
#
# Writers (deterministic scripts, so the record never depends on the model
# remembering a step): port-report.sh records ported/refactored from the
# manifest's phase, run-phpunit.sh records tested on a verified whole-suite run
# and refreshes the snapshot after every recorded run, verify-core-matrix.sh and
# make-patch.sh refresh it, and state.sh record/refresh is the CLI the commands
# call (assess -> assessed, setup -> setup, contribute -> contributed).
# Readers: next-step.sh, the post-edit hook, /drupilot-status (and --all).
#
# Schema (version 1; every key but subject/stages may be null or absent):
#   {schema: 1, subject: ABS_PATH, machine_name, type, drupal_root,
#    ddev_project, origin: ABS_PATH (the developer's checkout a loose subject
#    was placed from), placement,
#    created, updated: ISO-8601 UTC,
#    stage: setup|assessed|ported|refactored|tested|contributed,
#    stages: {<stage>: ISO time it was last recorded, ...},
#    effort: S|M|L|XL, assessed_at,
#    git: {branch, commit, dirty},
#    toolchain: {drupal_core, php_target, core_strategy, packages: {name: ver},
#                lock_drupilot_version},
#    tests: {status, preservation, executed, tests_failed, groups_passed,
#            groups_failed, groups_skipped, recorded_at, fresh}  (last-test.json),
#    core_matrix: {verdict, d10_support, generated_at, fresh},
#    patch: {path, kind: local|issue|contribution, at},
#    portfolio: {dir: ABS_PATH, layer} (state.sh record --portfolio, from
#               /drupilot-layers: the set and porting layer the subject is in),
#    drupilot_version}
# `fresh` is true when the result was computed on the subject's current
# sources (subject_digest). `stage` is the highest-ranked stage reached and never
# goes down (re-running /drupilot-port after a refactor does not undo it;
# DRUPILOT_STATE_FORCE=1 lets a record lower it). The legacy plain-text
# `<state_dir>/phase` marker is kept in sync with `stage` for older readers.
# Writers merge and never drop keys they do not own.

# subject_state_file <subject> -> path of the subject's state.json (the
# directory is not created: readers must not leave state dirs behind).
subject_state_file() { printf '%s/state.json' "$(project_state_path "${1:-$PWD}")"; }

# stage_normalize <word> -> the canonical stage name (ported, refactored, ...)
# for the verbs and legacy markers in use (port, refactor, ...); empty when
# unknown.
stage_normalize() {
  case "$(lc "${1:-}")" in
    setup) printf 'setup';;
    assess|assessed) printf 'assessed';;
    port|ported) printf 'ported';;
    refactor|refactored) printf 'refactored';;
    test|tested) printf 'tested';;
    contribute|contributed) printf 'contributed';;
  esac
  return 0
}

# stage_rank <stage> -> its position on the ladder (0 when unknown).
stage_rank() {
  case "$(stage_normalize "${1:-}")" in
    setup) printf 1;; assessed) printf 2;; ported) printf 3;;
    refactored) printf 4;; tested) printf 5;; contributed) printf 6;;
    *) printf 0;;
  esac
}

# state_get <subject> <jq-path> [default] -> a value from state.json (strings
# raw, other JSON compact), or the default. STDOUT only; never fails.
state_get() {
  local f v
  f="$(subject_state_file "${1:-$PWD}")"
  if [[ -r "$f" ]] && have_cmd jq; then
    v="$(jq -r "(${2}) // empty | if type == \"string\" then . else tojson end" "$f" 2>/dev/null || true)"
    if [[ -n "$v" ]]; then printf '%s' "$v"; return 0; fi
  fi
  printf '%s' "${3:-}"
  return 0
}

# state_set <subject> <jq-path> <string> / state_set_json <subject> <jq-path>
# <json> -> set one key in state.json (created when absent) and stamp
# `.updated`, `.subject`, `.schema` and `.created`. Atomic (temp file + mv);
# returns 1 without jq or on a write error. <jq-path> is plugin-controlled,
# never user input.
state_set() { _state_write "${1:-$PWD}" "${2}" "--arg" "${3}"; }
state_set_json() { _state_write "${1:-$PWD}" "${2}" "--argjson" "${3}"; }
_state_write() {
  local subj="$1" path="$2" kind="$3" val="$4"
  _state_apply "$subj" "$kind" "$val" "${path} = \$v"
}
# _state_apply <subject> <--arg|--argjson> <value> <jq-filter using $v> ->
# the one atomic writer behind state_set/state_refresh.
_state_apply() {
  local subj="$1" kind="$2" val="$3" filter="$4" f tmp abs
  have_cmd jq || return 1
  f="$(subject_state_file "$subj")"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  abs="$(cd "$subj" 2>/dev/null && pwd || printf '%s' "$subj")"
  [[ -s "$f" ]] || printf '{}\n' > "$f" 2>/dev/null || return 1
  tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 1
  if jq "$kind" v "$val" --arg s "$abs" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg pv "$(plugin_version)" \
       "${filter} | .subject = \$s | .updated = \$at | .created = (.created // \$at) | .schema = 1 | .drupilot_version = \$pv" \
       "$f" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp" 2>/dev/null || true; return 1
  fi
}

# phase_record <subject> <stage> -> mark <stage> as reached now
# (.stages[stage]), raise .stage when it ranks higher (monotonic, see above),
# rewrite the legacy phase marker and refresh the snapshot (state_refresh).
# Returns 1 for an unknown stage or a write error. Callers in a flow wrap it in
# `|| true`: recording is never a reason to fail a port.
phase_record() {
  local subj="${1:-$PWD}" st cur force
  st="$(stage_normalize "${2:-}")"
  [[ -n "$st" ]] || return 1
  state_set "$subj" ".stages[\"$st\"]" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  cur="$(state_get "$subj" .stage "")"
  force="$(config_get DRUPILOT_STATE_FORCE "")"
  if [[ -z "$cur" || "$(stage_rank "$st")" -gt "$(stage_rank "$cur")" || "$force" == "1" || "$(lc "$force")" == "true" ]]; then
    state_set "$subj" .stage "$st" || return 1
  fi
  state_refresh "$subj" 2>/dev/null || true
  cur="$(state_get "$subj" .stage "$st")"
  printf '%s\n' "$cur" > "$(project_state_dir "$subj")/phase" 2>/dev/null || true
  return 0
}

# phase_get <subject> -> the current stage: state.json's .stage, else the
# legacy phase marker (normalized: refactor -> refactored). Empty when none.
phase_get() {
  local subj="${1:-$PWD}" st
  st="$(state_get "$subj" .stage "")"
  if [[ -z "$st" ]]; then
    st="$({ tr -d '[:space:]' < "$(project_state_path "$subj")/phase"; } 2>/dev/null || true)"
  fi
  stage_normalize "$st"
  return 0
}

# phase_reached <subject> <stage> -> 0 when <stage> was reached:
#   * recorded in state.json's .stages, or implied by the rank of its current
#     .stage (a subject recorded as tested/contributed was ported, even when no
#     writer recorded 'ported' itself) — except 'refactored', which is opt-in
#     and therefore never implied by a later stage when state.json exists;
#   * (a subject without state.json) implied by the legacy marker's rank;
#   * for ported/refactored, the port manifest the flow wrote at the end of a
#     port/refactor (<state_dir>/port-manifest.json .phase), so a port finished
#     before the stage was recorded is not sent back to /drupilot-port.
# Read-only.
phase_reached() {
  local subj="${1:-$PWD}" st cur mp
  st="$(stage_normalize "${2:-}")"
  [[ -n "$st" ]] || return 1
  if [[ -r "$(subject_state_file "$subj")" ]] && have_cmd jq; then
    [[ -n "$(state_get "$subj" ".stages[\"$st\"]" "")" ]] && return 0
    if [[ "$st" != "refactored" ]]; then
      cur="$(state_get "$subj" .stage "")"
      [[ -n "$cur" && "$(stage_rank "$cur")" -ge "$(stage_rank "$st")" ]] && return 0
    fi
  else
    cur="$(phase_get "$subj")"
    [[ -n "$cur" && "$(stage_rank "$cur")" -ge "$(stage_rank "$st")" ]] && return 0
  fi
  case "$st" in
    ported|refactored)
      mp="$(port_manifest_stage "$subj")"
      [[ -n "$mp" && "$(stage_rank "$mp")" -ge "$(stage_rank "$st")" ]] && return 0
      ;;
  esac
  return 1
}

# port_manifest_stage <subject> -> the stage the subject's port manifest
# (<state_dir>/port-manifest.json, written by the flow when a port/refactor
# completes) shows as done: ported | refactored, or empty. Read-only.
port_manifest_stage() {
  local f ph=""
  f="$(project_state_path "${1:-$PWD}")/port-manifest.json"
  [[ -r "$f" ]] && have_cmd jq || return 0
  ph="$(jq -r 'if type == "object" then (.phase // "port") else empty end' "$f" 2>/dev/null || true)"
  case "$(stage_normalize "$ph")" in
    ported|refactored) stage_normalize "$ph";;
  esac
  return 0
}

# _json_from <file> <jq-filter> -> the filter's compact output on a readable,
# valid JSON file, else `null`. Never fails.
_json_from() {
  local out=""
  [[ -r "$1" ]] && out="$(jq -c "$2" "$1" 2>/dev/null || true)"
  [[ -n "$out" ]] || out="null"
  printf '%s' "$out"
}

# The jq definitions shared by state_refresh and state_view_json: how a stored
# record and a fresh snapshot combine. Non-null snapshot keys win (they are
# read from the source records, which are the truth); a key the snapshot cannot
# see any more (the subject tree is gone, so no git info) keeps its stored
# value. An assessment on file that no stage recorded yet backfills the
# assessed stage (raising a lower `stage` to it), and an empty `stage` takes the
# highest one recorded; otherwise an existing `stage` is never moved here (only
# phase_record moves it, so a forced lower stage stays lower). A
# patch recorded by make-patch.sh is kept over the port manifest's one.
_STATE_JQ_DEFS='
def srank: {"setup":1,"assessed":2,"ported":3,"refactored":4,"tested":5,"contributed":6}[. // ""] // 0;
def state_merge($snap):
  . + ($snap | del(.patch, .port_stage, .port_at) | with_entries(select(.value != null)))
  | .patch = (.patch // $snap.patch // null)
  | .stages = (.stages // {})
  | (if (.effort != null and .stages.assessed == null and (.assessed_at // .updated) != null)
     then .stages.assessed = (.assessed_at // .updated)
          | (if (.stage | srank) < ("assessed" | srank) then .stage = "assessed" else . end)
     else . end)
  | (if (($snap.port_stage // "") != "") and .stages.ported == null
     then .stages.ported = ($snap.port_at // .updated // "recorded-by-manifest")
          | (if (.stage | srank) < ("ported" | srank) then .stage = "ported" else . end)
     else . end)
  | (if ($snap.port_stage // "") == "refactored" and .stages.refactored == null
     then .stages.refactored = ($snap.port_at // .updated // "recorded-by-manifest")
          | (if (.stage | srank) < ("refactored" | srank) then .stage = "refactored" else . end)
     else . end)
  | .stages |= with_entries(select(.value != null))
  | (if ((.stage // "") == "") and ((.stages | length) > 0)
     then .stage = (.stages | keys | max_by(srank)) else . end);
'

# origin_baseline_path <root> [machine] -> the file origin-hygiene.sh records
# <machine>'s origin baseline in: the Drupal ROOT's hidden state dir (a moved
# origin is found again through the root), ONE FILE PER SUBJECT
# (origin-baseline-<machine>.json) so the modules placed into a shared test-bed
# do not overwrite each other's. Without a machine name: the single-file name
# older versions used (origin-baseline.json). Pure: creates nothing.
origin_baseline_path() {
  local d; d="$(project_state_path "$1")"
  if [[ -n "${2:-}" ]]; then printf '%s/origin-baseline-%s.json' "$d" "$2"
  else printf '%s/origin-baseline.json' "$d"; fi
}

# origin_baseline_find <root> <machine> -> the path of <machine>'s existing
# baseline under <root>: its own file, else the older single file when that one
# records the same machine name (or none). Prints nothing (still 0) when there
# is none. Read-only.
origin_baseline_find() {
  local f mn
  f="$(origin_baseline_path "$1" "${2:-}")"
  if [[ -n "${2:-}" && -f "$f" ]]; then printf '%s' "$f"; return 0; fi
  f="$(origin_baseline_path "$1")"
  [[ -f "$f" ]] || return 0
  if [[ -n "${2:-}" ]] && have_cmd jq; then
    mn="$(jq -r '.machine_name // empty' "$f" 2>/dev/null || true)"
    [[ -z "$mn" || "$mn" == "$2" ]] || return 0
  fi
  printf '%s' "$f"
  return 0
}

# origin_baseline_files <root> -> every origin baseline under <root>, one path
# per line (the per-subject files and the older single file). Read-only.
origin_baseline_files() {
  local d f; d="$(project_state_path "$1")"
  for f in "$d"/origin-baseline-*.json "$d"/origin-baseline.json; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
  return 0
}

# state_snapshot_json <subject> -> the facts drupilot can read about the subject
# right now, as one compact JSON object (see the schema above): from the
# subject's own state dir (assess.json, last-test.json, core-matrix.json,
# port-manifest.json), the Drupal root's (drupilot-lock.json,
# origin-baseline.json), the info.yml, .ddev/config.yaml and git. Read-only: it
# creates nothing and never starts DDEV. `null` without jq.
state_snapshot_json() {
  local subj="${1:-$PWD}" abs sd root="" rsd="" mn="" typ="" ddev="" digest=""
  local git_json="null" br cm dirty a t m pm l o
  have_cmd jq || { printf 'null'; return 0; }
  abs="$(cd "$subj" 2>/dev/null && pwd || printf '%s' "$subj")"
  sd="$(project_state_path "$abs")"
  if [[ -d "$abs" ]]; then
    root="$(find_drupal_root "$abs" 2>/dev/null || true)"
    mn="$(subject_machine_name "$abs" 2>/dev/null || true)"
    typ="$(subject_type "$abs" 2>/dev/null || true)"
    if have_cmd git && git -C "$abs" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      br="$(git -C "$abs" symbolic-ref --short -q HEAD 2>/dev/null || true)"
      cm="$(git -C "$abs" rev-parse HEAD 2>/dev/null || true)"
      dirty=false
      [[ -n "$(git -C "$abs" status --porcelain -- . 2>/dev/null | head -n1)" ]] && dirty=true
      git_json="$(jq -nc --arg b "$br" --arg c "$cm" --argjson d "$dirty" \
        '{branch: (if $b == "" then "(detached)" else $b end), commit: (if $c == "" then null else $c end), dirty: $d}')"
    fi
    if [[ -r "$sd/last-test.json" || -r "$sd/core-matrix.json" ]]; then
      digest="$(subject_digest "$abs" 2>/dev/null || true)"
    fi
  fi
  if [[ -n "$root" ]]; then
    rsd="$(project_state_path "$root")"
    [[ -f "$root/.ddev/config.yaml" ]] && ddev="$(sed -n 's/^name:[[:space:]]*//p' "$root/.ddev/config.yaml" 2>/dev/null | head -n1 | tr -d "\"' " || true)"
  fi
  a="$(_json_from "$sd/assess.json" '{effort: (.verdict // .effort // null), at: (.timestamp // .generated_at // null)}')"
  t="$(_json_from "$sd/last-test.json" '{status: (.status // null), preservation: (.preservation // null), executed: (.executed // null), tests_failed: ([.tests[]? | select(.status == "fail" or .status == "error")] | length), groups_passed: (.passed // null), groups_failed: (.failed // null), groups_skipped: (.skipped // null), recorded_at: (.recorded_at // .generated_at // null), digest: (.subject_digest // null)}')"
  m="$(_json_from "$sd/core-matrix.json" '{verdict: (.verdict // null), d10_support: (.d10_support // null), generated_at: (.generated_at // null), digest: (.subject_digest // null)}')"
  pm="$(_json_from "$sd/port-manifest.json" '{patch: (.patch | if type == "string" then . else null end), phase: ((.phase // "port") | if type == "string" then . else null end), at: (.generated_at // .recorded_at // null)}')"
  # No patch named in the manifest: the newest local preview next to the
  # subject (make-patch.sh --local writes <machine_name>-<description>.patch).
  if [[ -n "$mn" && "$(printf '%s' "$pm" | jq -r '.patch // empty' 2>/dev/null)" == "" ]]; then
    local lp; lp="$(cd "$abs" 2>/dev/null && ls -1t -- "$mn"-*.patch 2>/dev/null | head -n1 || true)"
    [[ -n "$lp" ]] && pm="$(printf '%s' "$pm" | jq -c --arg p "$abs/$lp" '(if type == "object" then . else {} end) + {patch: $p}' 2>/dev/null || jq -nc --arg p "$abs/$lp" '{patch: $p}')"
  fi
  l="null"; o="null"
  if [[ -n "$rsd" ]]; then
    l="$(_json_from "$rsd/drupilot-lock.json" '{drupal_core: (.drupal.core // null), php_target: (.php_target // null), core_strategy: (.core_strategy // null), packages: (.toolchain // null), lock_drupilot_version: (.drupilot_version // null)}')"
    local ob; ob="$(origin_baseline_find "$root" "$mn")"
    [[ -n "$ob" ]] && o="$(_json_from "$ob" '{source: (.source // null), placement: (.placement // null)}')"
    # No baseline (an in-place subject, or one placed before baselines were
    # per subject): the test-bed marker records each placed subject's origin.
    if [[ "$o" == "null" && -n "$mn" && -r "$root/.drupilot.json" ]]; then
      o="$(jq -c --arg m "$mn" '.drupilot_testbed.subjects[$m] // null
        | if type == "object" and (.origin // "") != "" then {source: .origin, placement: (.placement // null)} else null end' \
        "$root/.drupilot.json" 2>/dev/null || printf 'null')"
      [[ -n "$o" ]] || o="null"
    fi
  fi
  jq -nc --arg subject "$abs" --arg mn "$mn" --arg typ "$typ" --arg root "$root" --arg ddev "$ddev" \
    --arg digest "$digest" --argjson git "$git_json" --argjson a "$a" --argjson t "$t" \
    --argjson m "$m" --argjson pm "$pm" --argjson l "$l" --argjson o "$o" '
    def nz: if . == "" then null else . end;
    def fresh($d): if ($d // "") == "" or $digest == "" then null else ($d == $digest) end;
    {subject: $subject, machine_name: ($mn | nz), type: ($typ | nz),
     drupal_root: ($root | nz), ddev_project: ($ddev | nz),
     origin: ($o.source // null), placement: ($o.placement // null),
     effort: ($a.effort // null), assessed_at: ($a.at // null),
     git: $git, toolchain: $l,
     tests: (if $t == null then null else ($t | del(.digest)) + {fresh: fresh($t.digest)} end),
     core_matrix: (if $m == null then null else ($m | del(.digest)) + {fresh: fresh($m.digest)} end),
     port_stage: (($pm.phase // "") | ascii_downcase | if . == "port" or . == "ported" then "ported" elif . == "refactor" or . == "refactored" then "refactored" else null end),
     port_at: ($pm.at // null),
     patch: (if ($pm.patch // "") == "" then null
             else {path: ($pm.patch | if startswith("/") then . else $subject + "/" + . end),
                   kind: "local", at: null} end)}'
  return 0
}

# state_refresh <subject> -> merge a fresh snapshot into state.json (created
# when absent). Called by the flow scripts after they write a source record.
# Returns 1 without jq or on a write error; callers use `|| true`.
state_refresh() {
  local subj="${1:-$PWD}" snap
  have_cmd jq || return 1
  snap="$(state_snapshot_json "$subj")"
  [[ -n "$snap" && "$snap" != "null" ]] || return 1
  _state_apply "$subj" --argjson "$snap" "${_STATE_JQ_DEFS} state_merge(\$v)"
}

# state_patch_record <subject> <path> <kind> -> remember the last patch made
# for the subject (kind: local | issue | contribution). Never fails.
state_patch_record() {
  local subj="${1:-$PWD}" p="$2" kind="${3:-local}" abs
  have_cmd jq || return 0
  abs="$(cd "$(dirname "$p")" 2>/dev/null && pwd || dirname "$p")/$(basename "$p")"
  state_set_json "$subj" .patch "$(jq -nc --arg p "$abs" --arg k "$kind" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{path: $p, kind: $k, at: $at}')" 2>/dev/null || true
  state_refresh "$subj" 2>/dev/null || true
  return 0
}

# state_view_json <subject> -> the subject's record as a reader should see it:
# the stored state.json (if any) merged with a fresh snapshot, plus
# `recorded` (state.json exists), `exists` (the subject directory exists) and
# `patch.exists`. A subject recorded only by the legacy phase marker gets that
# stage. Read-only: writes and creates nothing.
state_view_json() {
  local subj="${1:-$PWD}" f stored="{}" snap legacy="" recorded=false exists=false abs v p pe
  have_cmd jq || { printf 'null'; return 0; }
  abs="$(cd "$subj" 2>/dev/null && pwd || printf '%s' "$subj")"
  [[ -d "$abs" ]] && exists=true
  f="$(subject_state_file "$abs")"
  if [[ -r "$f" ]]; then
    stored="$(jq -c 'if type == "object" then . else {} end' "$f" 2>/dev/null || true)"
    recorded=true
  fi
  [[ -n "$stored" ]] || stored="{}"
  [[ "$recorded" == "true" ]] || legacy="$(phase_get "$abs")"
  snap="$(state_snapshot_json "$abs")"
  v="$(jq -nc --argjson st "$stored" --argjson snap "$snap" --arg legacy "$legacy" \
     --argjson recorded "$recorded" --argjson exists "$exists" --arg subject "$abs" "${_STATE_JQ_DEFS}"'
    ($st | state_merge($snap))
    | .subject = (.subject // $subject)
    | (if (.stage // "") == "" and $legacy != "" then .stage = $legacy else . end)
    | .stage = (.stage // null)
    | .recorded = $recorded | .exists = $exists' 2>/dev/null || true)"
  [[ -n "$v" ]] || { printf 'null'; return 0; }
  # patch.exists needs the filesystem.
  p="$(printf '%s' "$v" | jq -r '.patch.path // empty' 2>/dev/null || true)"
  if [[ -n "$p" ]]; then
    pe=false; [[ -f "$p" ]] && pe=true
    v="$(printf '%s' "$v" | jq -c --argjson e "$pe" '.patch.exists = $e' 2>/dev/null || printf '%s' "$v")"
  fi
  printf '%s\n' "$v"
  return 0
}

# core_matrix_fresh <subject> -> 0 when a core-matrix result exists for the
# subject AND was computed on its current sources (same subject_digest), so a
# report never presents a verdict about code that changed since.
core_matrix_fresh() {
  local s="${1:-$PWD}" f want have
  f="$(core_matrix_file "$s")"
  [[ -r "$f" ]] && have_cmd jq || return 1
  have="$(jq -r '.subject_digest // empty' "$f" 2>/dev/null || true)"
  want="$(subject_digest "$s")"
  [[ -n "$have" && "$have" == "$want" ]]
}

# ---------------------------------------------------------------------------
# Port record: structured outcome fields + the decision log
# ---------------------------------------------------------------------------
# A port's outcome is recorded in two machine sources that aggregate across
# modules and layers (layer-report.sh, port-report.sh):
#   * the port MANIFEST (<state_dir>/port-manifest.json, written by the flow at
#     the end of a port/refactor) — its optional structured fields:
#       rector_rules       run-rector.sh --json `.rule_hits` ({official:{Rule:n},
#                          digests:{...}}), or {Rule: n}, or [Rule...], or
#                          [{rule, hits?, pass?}] (hits = files changed)
#       rector_reversions  [{rule, file?, why}]  a Rector change undone by hand
#       post_port_fixes    [{fix, file?, why, detected_by?}]  a fix made after
#                          the validate loop / tests / core matrix found a problem
#       preexisting_bugs   [{issue, file?, note?}]  found, NOT fixed by the port
#       behavior_changes   [{change, why?, review_hint?}]  to review in the PR
#       tooling_deviations [{what, why}]  the flow or a tool's output not followed
#       validation         [string]  how the result was validated
#     (a plain string is accepted for any list item);
#   * the DECISION LOG (log-decision.sh): one JSON line per decision in
#     <artifacts_dir>/decisions.jsonl (with a human decisions.md beside it),
#     written the moment the agent reverts a Rector change, diverges from a
#     script's output, skips a step, etc. Entry (schema 1): {schema, ts,
#     subject, machine_name, drupal_root, phase, kind, what, why, rule, file,
#     script, detected_by, review_hint}. Kinds map onto the manifest fields:
#     rector-revert -> rector_reversions, post-port-fix -> post_port_fixes,
#     preexisting-bug -> preexisting_bugs, behavior-change -> behavior_changes,
#     script-divergence | skip | manual-override | tooling-deviation ->
#     tooling_deviations, test-adaptation -> test_adaptations.
# port_record_json merges both (manifest items first, deduplicated), so the
# flow may record a decision in either place, or both.

# project_artifacts_path [base_dir] -> the directory project_artifacts_dir
# resolves, WITHOUT creating it (for read-only callers).
project_artifacts_path() {
  local base="${1:-$PWD}" override
  override="$(config_get DRUPILOT_ARTIFACTS_DIR "")"
  if [[ -n "$override" ]]; then
    ( cd "$override" 2>/dev/null && pwd ) || printf '%s' "$override"
    return 0
  fi
  _artifacts_dir_path "$base"
  return 0
}

# decisions_log_file <subject> -> the decision log (JSONL) the subject's
# decisions go to: <artifacts_dir>/decisions.jsonl. One file per Drupal root;
# every entry names its subject, so modules sharing a test-bed stay apart.
decisions_log_file() { printf '%s/decisions.jsonl' "$(project_artifacts_path "${1:-$PWD}")"; }

# patterns_file [base_dir] -> path of the LEARNED-PATTERN CATALOG
# (scripts/analysis/patterns.sh): the pitfalls a port of this project already
# hit, each with a detector and a fix, so the next module is checked BEFORE it
# is ported. It is human-reviewable and editable, so it is a visible artifact,
# not hidden state. ONE catalog per project, shared by its modules:
#   1. DRUPILOT_PATTERNS_FILE (a team can point it at a committed file; a
#      relative path is taken from the Drupal root, else from base);
#   2. the base is replaced by the portfolio the subject was ported in
#      (state.json .portfolio.dir, from /drupilot-layers), so a set ported with
#      one test-bed per module still shares one catalog;
#   3. <Drupal root>/.drupilot/patterns.json (project_artifacts_path);
#   4. no Drupal root yet (a loose module, a monorepo before setup): the
#      nearest directory from base up to its git toplevel that already has
#      .drupilot/patterns.json, else <git toplevel or base>/.drupilot/, so a
#      submodule and its parent share the catalog.
# Nothing is created (read-only callers must not leave a dir behind).
patterns_file() {
  local base="${1:-$PWD}" f root p top d
  f="$(config_get DRUPILOT_PATTERNS_FILE "")"
  if [[ -n "$f" ]]; then
    case "$f" in
      /*) ;;
      *) root="${DRUPILOT_PROJECT_DIR:-}"
         [[ -z "$root" ]] && root="$(find_drupal_root "$base" 2>/dev/null || true)"
         [[ -z "$root" ]] && root="$base"
         root="$(cd "$root" 2>/dev/null && pwd || printf '%s' "$root")"
         f="$root/$f";;
    esac
    printf '%s' "$f"
    return 0
  fi
  p="$(state_get "$base" '.portfolio.dir' '')"
  [[ -n "$p" && -d "$p" ]] && base="$p"
  base="$(cd "$base" 2>/dev/null && pwd || printf '%s' "$base")"
  root="${DRUPILOT_PROJECT_DIR:-}"
  [[ -z "$root" ]] && root="$(find_drupal_root "$base" 2>/dev/null || true)"
  if [[ -n "$root" || -n "$(config_get DRUPILOT_ARTIFACTS_DIR "")" ]]; then
    printf '%s/patterns.json' "$(project_artifacts_path "$base")"
    return 0
  fi
  top=""
  have_cmd git && top="$(cd "$base" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$top" ]] && top="$(cd "$top" 2>/dev/null && pwd -P || printf '%s' "$top")"
  d="$(cd "$base" 2>/dev/null && pwd -P || printf '%s' "$base")"
  while [[ -n "$top" && "$d" == "$top"/* ]]; do
    if [[ -f "$d/.drupilot/patterns.json" ]]; then printf '%s/.drupilot/patterns.json' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  printf '%s/.drupilot/patterns.json' "${top:-$base}"
  return 0
}

# rector_rules_file <subject> -> the rule counts of the last Rector --apply run
# that changed files (run-rector.sh), the fallback for manifest.rector_rules.
rector_rules_file() { printf '%s/rector-rules.json' "$(project_state_path "${1:-$PWD}")"; }

# decisions_for_subject <subject> -> JSON array of the decision-log entries of
# the subject (matched by path, or by machine name within the same log, which
# survives a moved subject). `[]` when there is no log or no jq. Read-only.
decisions_for_subject() {
  local subj="${1:-$PWD}" abs f mn
  have_cmd jq || { printf '[]'; return 0; }
  abs="$(cd "$subj" 2>/dev/null && pwd || printf '%s' "$subj")"
  f="$(decisions_log_file "$abs")"
  [[ -r "$f" ]] || { printf '[]'; return 0; }
  mn="$(subject_machine_name "$abs" 2>/dev/null || true)"
  # -R + fromjson? skips a damaged line instead of failing the whole log.
  jq -R -c -s --arg s "$abs" --arg mn "$mn" '
    [ split("\n")[] | select(length > 0) | (fromjson? // empty) | select(type == "object")
      | select(.subject == $s or ($mn != "" and .machine_name == $mn)) ]' "$f" 2>/dev/null || printf '[]'
  return 0
}

# The jq definitions that normalize a manifest + decision entries into the
# port record (see the block comment above).
_PORT_RECORD_JQ_DEFS='
def _short: tostring | split("\\") | last;
def _list: if . == null then [] elif type == "array" then . else [.] end;
def _str: if . == null then null elif type == "string" then (if . == "" then null else . end) else tojson end;
def _rules:
  if . == null then []
  elif type == "object" and has("rule_hits") then (.rule_hits | _rules)
  elif type == "object" and (.rules | type) == "array" then (.rules | _rules)
  elif type == "array" then
    map(if type == "string" then {rule: ., hits: null, pass: null}
        elif type == "object" then {rule: (.rule // .name // null), hits: (.hits // .files // null), pass: (.pass // null)}
        else empty end)
  elif type == "object" then
    (if length > 0 and ([.[] | type] | all(. == "object"))
     then [to_entries[] | .key as $p | .value | to_entries[] | {rule: .key, hits: .value, pass: $p}]
     else [to_entries[] | {rule: .key, hits: .value, pass: null}] end)
  else [] end
  | map(select((.rule // "") != "") | .hits = (if (.hits | type) == "number" then .hits elif (.hits | type) == "array" then (.hits | length) else null end));
def _merge_rules:
  group_by(.rule | _short)
  | map({rule: (.[0].rule | _short),
         hits: (if all(.[]; .hits == null) then null else (map(.hits // 0) | add) end),
         passes: ([.[] | .pass | select(. != null)] | unique)});
def _items($k):
  _list | map(if type == "object" then . elif . == null then empty else {($k): tostring} end
              | . + {source: "manifest"} | with_entries(.value |= (if type == "string" or . == null then _str else . end)));
def _dedupe(f): reduce .[] as $i ([]; if any(.[]; (. | f) == ($i | f)) then . else . + [$i] end);
def port_record($m; $d; $rr; $subject; $mn):
  ($d | _list) as $d
  | (if ($m.rector_rules // null) != null then {src: "manifest", r: ($m.rector_rules | _rules)}
     elif $rr != null then {src: "run-rector", r: ($rr | _rules)}
     else {src: null, r: []} end) as $rules
  | def dec($kinds): [$d[] | select(.kind as $k | any($kinds[]; . == $k))];
  {subject: $subject, machine_name: ($m.machine_name // (if $mn == "" then null else $mn end)),
   phase: ($m.phase // null), manifest: ($m != {}),
   rector_files: ($m.rector_official_files // null),
   rector_rules: ($rules.r | _merge_rules), rector_rules_source: $rules.src,
   rector_reversions: (($m.rector_reversions | _items("rule"))
       + [dec(["rector-revert"])[] | {rule, file, why, what, source: "decision-log", ts}]
       | map(select((.rule // "") != "")) | _dedupe([(.rule | _short), (.file // "")])),
   post_port_fixes: (($m.post_port_fixes | _items("fix") | map(.fix = (.fix // .what)))
       + [dec(["post-port-fix"])[] | {fix: .what, file, why, detected_by, source: "decision-log", ts}]
       | map(select((.fix // "") != "")) | _dedupe([.fix, (.file // "")])),
   preexisting_bugs: (($m.preexisting_bugs | _items("issue") | map(.issue = (.issue // .what)))
       + [dec(["preexisting-bug"])[] | {issue: .what, file, note: .why, source: "decision-log", ts}]
       | map(select((.issue // "") != "")) | _dedupe([.issue, (.file // "")])),
   behavior_changes: (($m.behavior_changes | _items("change") | map(.change = (.change // .what)))
       + [dec(["behavior-change"])[] | {change: .what, why, review_hint, file, source: "decision-log", ts}]
       | map(select((.change // "") != "")) | _dedupe([.change])),
   tooling_deviations: (($m.tooling_deviations | _items("what"))
       + [dec(["script-divergence", "skip", "manual-override", "tooling-deviation"])[]
          | {what, why, kind, script, file, source: "decision-log", ts}]
       | map(select((.what // "") != "")) | _dedupe([.what])),
   test_adaptations: [dec(["test-adaptation"])[] | {what, why, file, ts}],
   validation: ($m.validation | _list | map(if type == "string" then . else tojson end)),
   manual_edits: ($m.manual_edits | _list
       | map(if type == "string" then {edit: ., why: null, change_record: null}
             elif type == "object" then {edit: (.edit // .what // "edit"), why: (.why // null), change_record: (.change_record // null)}
             else empty end)),
   decisions: ($d | length)};
'

# port_record_json <subject> [manifest] -> the subject's port record: the
# manifest (default <state_dir>/port-manifest.json) and the decision log merged
# into the normalized structured fields (see above), plus `manifest` (one was
# read) and `decisions` (how many log entries). Read-only; `null` without jq.
port_record_json() {
  local subj="${1:-$PWD}" man="${2:-}" abs mn m='{}' d rr="null"
  have_cmd jq || { printf 'null'; return 0; }
  abs="$(cd "$subj" 2>/dev/null && pwd || printf '%s' "$subj")"
  [[ -n "$man" ]] || man="$(project_state_path "$abs")/port-manifest.json"
  if [[ -r "$man" ]]; then
    m="$(jq -c 'if type == "object" then . else {} end' "$man" 2>/dev/null || true)"
    [[ -n "$m" ]] || m='{}'
  fi
  d="$(decisions_for_subject "$abs")"
  [[ -r "$(rector_rules_file "$abs")" ]] && rr="$(jq -c '.rule_hits // null' "$(rector_rules_file "$abs")" 2>/dev/null || printf 'null')"
  [[ -n "$rr" ]] || rr="null"
  mn="$(subject_machine_name "$abs" 2>/dev/null || true)"
  jq -nc --argjson m "$m" --argjson d "$d" --argjson rr "$rr" --arg s "$abs" --arg mn "$mn" \
    "${_PORT_RECORD_JQ_DEFS} port_record(\$m; \$d; \$rr; \$s; \$mn)" 2>/dev/null || printf 'null'
  return 0
}

# render_template_files TEMPLATE DEST KEY=FILE... -> like render_template, but
# each {{KEY}} is replaced by the CONTENT of FILE (one trailing newline
# dropped), so a value may be multi-line and hold any character (|, &, \, /)
# and any size (render_template passes values through the environment, which
# caps one value at 128 KiB on Linux). DEST "-" prints to STDOUT; otherwise the
# render goes to a temp file next to DEST first. Returns non-zero on a bad
# argument or I/O error.
render_template_files() {
  local tpl="${1:-}" dest="${2:-}"
  shift 2 2>/dev/null || { log_err "render_template_files: usage: render_template_files TEMPLATE DEST [KEY=FILE...]"; return 1; }
  [[ -f "$tpl" ]] || { log_err "render_template_files: template not found: '$tpl'"; return 1; }
  [[ -n "$dest" ]] || { log_err "render_template_files: missing destination for '$tpl'"; return 1; }
  local spec="" pair k v
  for pair in "$@"; do
    k="${pair%%=*}"; v="${pair#*=}"
    case "$k" in
      ''|*[!A-Z0-9_]*) log_err "render_template_files: invalid token name in '$pair'"; return 1;;
    esac
    [[ "$pair" == *=* && -r "$v" ]] || { log_err "render_template_files: unreadable value file in '$pair'"; return 1; }
    spec="$spec$k"$'\x1f'"$v"$'\x1e'
  done
  # shellcheck disable=SC2016  # awk program, not a shell expansion
  local prog='
    BEGIN {
      n = split(ENVIRON["_DRUPILOT_TPLF_SPEC"], pairs, "\036"); m = 0
      for (i = 1; i <= n; i++) {
        if (pairs[i] == "") continue
        split(pairs[i], kv, "\037"); m++
        tok[m] = "{{" kv[1] "}}"; val[m] = ""; first = 1
        while ((getline l < kv[2]) > 0) { val[m] = (first ? l : val[m] "\n" l); first = 0 }
        close(kv[2])
      }
    }
    {
      # Left to right, one token at a time: a value is never re-scanned, so
      # content that happens to contain "{{KEY}}" is printed as is.
      line = $0; out = ""
      while (1) {
        best = 0; bp = 0
        for (i = 1; i <= m; i++) {
          p = index(line, tok[i])
          if (p > 0 && (bp == 0 || p < bp)) { bp = p; best = i }
        }
        if (best == 0) break
        out = out substr(line, 1, bp - 1) val[best]
        line = substr(line, bp + length(tok[best]))
      }
      print out line
    }'
  if [[ "$dest" == "-" ]]; then
    _DRUPILOT_TPLF_SPEC="$spec" awk "$prog" "$tpl"
    return $?
  fi
  local tmp
  tmp="$(mktemp "${dest}.drupilot.XXXXXX" 2>/dev/null)" \
    || { log_err "render_template_files: cannot create a temp file next to '$dest'"; return 1; }
  if _DRUPILOT_TPLF_SPEC="$spec" awk "$prog" "$tpl" > "$tmp" && cat "$tmp" > "$dest"; then
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"
  return 1
}

# ddev_project_name <string> -> a DDEV/hostname-safe project name derived from
# the input (usually a directory basename). DDEV rejects names that are not valid
# hostname labels, so underscores, dots, spaces and uppercase all break
# `ddev config` (e.g. a dir named "upgrade-to-d11-file_version" is refused). We
# take the basename, lowercase it, replace every run of invalid characters with a
# single '-', and trim leading/trailing '-'. Falls back to "drupal-project".
ddev_project_name() {
  local raw="${1:-}" name
  raw="${raw##*/}"
  name="$(printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
  [[ -n "$name" ]] || name="drupal-project"
  printf '%s' "$name"
}

# ---------------------------------------------------------------------------
# Core compatibility target (info.yml core_version_requirement) reasoning
# ---------------------------------------------------------------------------
# drupilot policy: a port to Drupal 11 has a PHP floor equal to the resolved
# DRUPILOT_PHP_TARGET (>= 8.3). Drupal 10 itself allows PHP 8.1, so KEEPING D10
# (`^10 || ^11`) must ALSO declare composer `require.php: ">=<target>"` —
# otherwise a D10 + PHP<target site installs the module and then fatals at
# runtime. `^11` alone needs no require.php (core enforces its own minimum).
#
# recommend_core_target <subject> [phase] [bc_override] -> recommendation JSON:
#   { strategy, phase, current_core_version_requirement,
#     recommended_core_version_requirement, composer_core_constraint,
#     require_php (string|null), version_bump (major|minor|patch),
#     bc_break (bool), php_target, d10_support, verify_cores:[...],
#     rationale:[...], warnings:[...] }
#   verify_cores: the core legs scripts/analysis/verify-core-matrix.sh checks for
#   the recommended requirement (core_matrix_legs), e.g. ["10.0","10","11"].
#   The recommended requirement never lowers a declared Drupal 10 minor floor
#   ('^10.3' -> '^10.3 || ^11') and never goes below the floor of a plugin
#   attribute class the code uses (subject_attribute_floor; one that exists only
#   in Drupal 11 turns keep-d10 into d11-only, e.g. '^11.1').
#   phase: port | refactor (default port). bc_override: auto | yes | no.
recommend_core_target() {
  local subject="${1:-$PWD}" phase="${2:-port}" bc_override="${3:-auto}"
  have_cmd jq || { printf '{}\n'; return 1; }

  local php_target current_req
  php_target="$(resolve_php_target)"
  current_req="$(subject_core_requirement "$subject" 2>/dev/null || true)"
  current_req="$(trim "$current_req")"

  # PHP floor strategy: 'detect' (default) derives a narrower require.php from the
  # detected floor (DRUPILOT_DETECTED_PHP_FLOOR, set by detect-php-floor.sh);
  # 'target' keeps the conservative ">=target". The module's own composer.json is
  # the ONLY place an info.yml-declared '^10 || ^11' module can enforce a PHP
  # floor, so we also note whether it exists.
  local floor_strategy detected_floor has_composer="false"
  floor_strategy="$(config_get DRUPILOT_REQUIRE_PHP_FLOOR detect)"; floor_strategy="$(lc "$floor_strategy")"
  case "$floor_strategy" in target|detect) : ;; *) floor_strategy="detect";; esac
  detected_floor="$(trim "${DRUPILOT_DETECTED_PHP_FLOOR:-}")"
  [[ -f "$subject/composer.json" ]] && has_composer="true"

  # --- strategy resolution (auto default; KEEP_D10 legacy override) --------
  local strat keep_override legacy_note=""
  strat="$(config_get DRUPILOT_CORE_TARGET_STRATEGY auto)"; strat="$(lc "$strat")"
  case "$strat" in d11-only|keep-d10|auto) : ;; *) strat="auto";; esac
  keep_override="$(config_get DRUPILOT_KEEP_D10 "")"
  if [[ "$strat" == "auto" && -n "$keep_override" ]]; then
    case "$(lc "$keep_override")" in
      1|true|yes|on)  strat="keep-d10"; legacy_note="DRUPILOT_KEEP_D10 legacy override";;
      0|false|no|off) strat="d11-only"; legacy_note="DRUPILOT_KEEP_D10 legacy override";;
    esac
  fi

  # --- current support signals --------------------------------------------
  local had_pre11=0 current_has_11=0
  if [[ -n "$current_req" ]] && printf '%s' "$current_req" | grep -qE '(^|[^0-9])(8|9|10)([^0-9]|$)'; then had_pre11=1; fi
  if [[ -n "$current_req" ]] && printf '%s' "$current_req" | grep -qE '(^|[^0-9])11([^0-9]|$)'; then current_has_11=1; fi

  # --- BC-break detection (drives the SemVer major bump) ------------------
  local bc_break=0
  [[ "$phase" == "refactor" ]] && bc_break=1
  case "$(lc "$bc_override")" in
    yes|true|1) bc_break=1;;
    no|false|0) bc_break=0;;
  esac

  # --- resolve `auto` into a concrete strategy ----------------------------
  local resolved
  if [[ "$strat" == "auto" ]]; then
    if [[ "$bc_break" == "1" ]]; then
      resolved="d11-only"
    elif [[ "$had_pre11" == "1" || -z "$current_req" ]]; then
      resolved="keep-d10"           # widest BC-preserving set
    else
      resolved="d11-only"           # already 11-only; nothing older to keep
    fi
  else
    resolved="$strat"
  fi

  # Already Drupal 11-compatible with no BC break, and the strategy was left on
  # 'auto' (not explicitly forced): KEEP the existing declaration verbatim instead
  # of regressing a precise one (e.g. '^11.2' or '^10.3 || ^11 || ^12') to a
  # generic range — that would drop a higher minor floor or a future major the
  # module already supports. The developer can still narrow it via the tab.
  local keep_current=0
  if [[ "$strat" == "auto" && "$current_has_11" == "1" && "$bc_break" == "0" && -n "$current_req" ]]; then
    keep_current=1; resolved="keep-current"
  fi

  # --- core minor floor ----------------------------------------------------
  # Never lower a declared Drupal 10 minor floor ('^10.3' stays '^10.3 || ^11',
  # not '^10 || ^11'), and never declare a floor below what the code needs: a
  # plugin attribute class the code uses exists only from its core minor on
  # (config/plugin-attributes.json), e.g. the Block attribute from 10.2.
  local d10_decl_floor="" api_floor="" api_attr="" core_floor="10.0" _af d10_dropped_note=""
  d10_decl_floor="$(core_verify_legs "$current_req" | awk -F. '$1 == "10" { print ($2 == "" ? "10.0" : $0); exit }')"
  [[ -n "$d10_decl_floor" ]] && core_floor="$d10_decl_floor"
  _af="$(subject_attribute_floor "$subject")"
  if [[ -n "$_af" ]]; then
    api_floor="${_af%%$'\t'*}"; api_attr="${_af#*$'\t'}"
    version_ge "$core_floor" "$api_floor" || core_floor="$api_floor"
  fi
  if [[ "$keep_current" == "0" && "$resolved" == "keep-d10" && "${core_floor%%.*}" -ge 11 ]]; then
    resolved="d11-only"
    legacy_note="the code uses $api_attr, which exists only from core $api_floor"
    d10_dropped_note="Drupal 10 cannot be kept: the code uses $api_attr, which exists only from core $api_floor (PHPStan reports the unknown class on Drupal 10). Keep the annotation instead of the attribute to stay on '^10 || ^11'."
  fi

  # --- requirement + composer constraint + require.php + D10 honesty ---------
  local req composer require_php="" effective_floor="" d10_support="n/a"
  local -a rationale=() warnings=() suggested=()

  # Target compatibility (strategy-independent): code that uses constructs newer
  # than the target fatals even on the target PHP, so flag it regardless of the
  # core strategy.
  local target_compat_json="null"
  if [[ -n "$detected_floor" ]]; then
    if version_ge "$php_target" "$detected_floor"; then
      target_compat_json="true"
    else
      target_compat_json="false"
      warnings+=("The code uses PHP $detected_floor-only constructs but DRUPILOT_PHP_TARGET is $php_target — it will fatal on a Drupal 11 site running PHP $php_target. Raise DRUPILOT_PHP_TARGET to $detected_floor (confirm it is supported on the target Drupal 11 branch) or remove the construct.")
    fi
  fi

  if [[ "$keep_current" == "1" ]]; then
    # Keep the module's existing, already-D11-compatible requirement unchanged.
    req="$current_req"; composer="$current_req"
    rationale+=("The module already declares a Drupal 11-compatible requirement ('$current_req'); keeping it unchanged (minimal change). Use the core-target choice to narrow it if you want.")
    local _decl_floor
    _decl_floor="$(core_floor_from_requirement "$current_req")"
    if [[ -n "$api_floor" && -n "$_decl_floor" ]] && ! version_ge "$_decl_floor" "$api_floor"; then
      req="$(core_requirement_raise_floor "$current_req" "$api_floor")"; composer="$req"
      rationale+=("The code uses $api_attr, which exists only from core $api_floor: the declared floor $_decl_floor is raised ('$current_req' -> '$req').")
    fi
    # The raised floor may leave Drupal 10 behind ('^10 || ^11' + an 11.1
    # attribute -> '^11.1'): the Drupal 10 logic follows the requirement now
    # declared, not the one read from the module.
    local req_pre11=0
    if printf '%s' "$req" | grep -qE '(^|[^0-9])(8|9|10)([^0-9]|$)'; then req_pre11=1; fi
    if [[ "$had_pre11" == "1" && "$req_pre11" == "0" ]]; then
      resolved="d11-only"
      warnings+=("Drupal 10 cannot be kept: the code uses $api_attr, which exists only from core $api_floor (PHPStan reports the unknown class on Drupal 10). Keep the annotation instead of the attribute to stay on '$current_req'.")
    fi
    if [[ "$req_pre11" == "1" ]]; then
      # The kept requirement still allows Drupal 10, so declare the PHP floor.
      require_php=">=$php_target"
      if [[ "$floor_strategy" == "detect" && -n "$detected_floor" ]]; then
        local f="$detected_floor"
        version_ge "$f" "8.1" || f="8.1"
        version_ge "$php_target" "$f" || f="$php_target"
        effective_floor="$f"; require_php=">=$f"
      fi
      d10_support="declared-not-verified"
      warnings+=("The kept requirement still allows Drupal 10 ('$req'); its Drupal 10 compatibility is DECLARED, not verified — run verify-core-matrix.sh (static check on a Drupal 10 core) and install/test on Drupal 10 before relying on it.")
    fi
    if printf '%s' "$current_req" | grep -qE '(^|[^0-9])(8|9)([^0-9]|$)'; then
      suggested+=("The requirement still lists EOL Drupal 8/9 ('$current_req'); narrow it (e.g. to '^10 || ^11' or '^11') via the core-target choice if you no longer support them.")
    fi
  elif [[ "$resolved" == "keep-d10" ]]; then
    req="^10 || ^11"
    [[ "$core_floor" != "10.0" ]] && req="^$core_floor || ^11"
    composer="$req"
    require_php=">=$php_target"      # safe default (policy floor = target)
    rationale+=("Strategy: keep-d10 ('$req')${legacy_note:+ ($legacy_note)}.")
    if [[ "$core_floor" != "10.0" ]]; then
      if [[ -n "$api_floor" && "$core_floor" == "$api_floor" && "$api_floor" != "$d10_decl_floor" ]]; then
        rationale+=("Drupal 10 floor $core_floor: the code uses $api_attr, which exists only from core $api_floor.")
      else
        rationale+=("Drupal 10 floor $core_floor: the declared minor floor ('$current_req') is kept, never lowered.")
      fi
    fi

    # Optionally widen the floor to the detected one (bounded to [8.1, target]).
    if [[ "$floor_strategy" == "detect" && -n "$detected_floor" ]]; then
      local f="$detected_floor"
      version_ge "$f" "8.1" || f="8.1"            # never below Drupal 10's own minimum
      version_ge "$php_target" "$f" || f="$php_target"   # never above the target
      effective_floor="$f"
      require_php=">=$f"
      if [[ "$f" != "$php_target" ]]; then
        rationale+=("Detected PHP floor is $f (heuristic scan), below the target $php_target — require.php is widened to \">=$f\" for genuine Drupal 10 (PHP $f) support.")
        warnings+=("require.php was lowered to \">=$f\" from a best-effort syntactic scan. CONFIRM with PHPCompatibility (testVersion $f-) before release: a missed newer construct would let a Drupal 10 + PHP<$php_target site install and then fatal at runtime. Set DRUPILOT_REQUIRE_PHP_FLOOR=target to keep the conservative \">=$php_target\".")
      else
        rationale+=("PHP floor is the target ($php_target): the scan found PHP 8.2/8.3-only constructs (or the detected floor equals the target).")
      fi
    else
      rationale+=("PHP floor is the target ($php_target); keeping Drupal 10 declares composer require.php \">=$php_target\". (Set DRUPILOT_REQUIRE_PHP_FLOOR=detect to derive a narrower, code-based floor.)")
    fi

    warnings+=("Drupal 10's own minimum is PHP 8.1, but this port's floor is ${effective_floor:-$php_target}. require.php \"$require_php\" blocks D10 sites below that floor at install time (composer) rather than fataling at runtime. If you do not need the D10 transition window, drop to '^11'.")

    # The floor is only enforceable if the module ships a composer.json.
    if [[ "$has_composer" != "true" ]]; then
      warnings+=("This module has no composer.json, so require.php cannot be declared anywhere — an info.yml-only '^10 || ^11' module has NO way to enforce the PHP floor, and a D10 + low-PHP site would install and fatal. Either add a composer.json with \"require\": { \"php\": \"$require_php\" }, or declare '^11' only.")
      suggested+=("Add a composer.json declaring \"require\": { \"php\": \"$require_php\" } (or drop to '^11'), so the PHP floor of the '^10 || ^11' declaration is actually enforced.")
    fi

    # D10 support is DECLARED here, not verified (cheap-scope honesty).
    d10_support="declared-not-verified"
    local digests_note=""
    if config_bool DRUPILOT_USE_DIGESTS_RULES 1; then
      digests_note=" The AI digests / ad-hoc Rector layer may introduce replacements newer than Drupal 10.0, so a raised minor (e.g. '^10.3 || ^11') is more likely — check it."
    fi
    warnings+=("Drupal 10 compatibility is DECLARED, not verified. drupal-rector's standard replacements are usually available across all of Drupal 10 (deprecation contract), but this was not checked here. If the port uses an API added in a later 10.x minor, set core_version_requirement to e.g. '^10.3 || ^11'; if it uses an API absent from Drupal 10, drop to '^11'.$digests_note")
    suggested+=("Verify Drupal 10 compatibility before relying on the '^10 || ^11' declaration: verify-core-matrix.sh runs PHPStan + php -l against a Drupal 10 core (static); install on a Drupal 10 site or run the test suite against Drupal 10 for runtime proof.")
  else
    req="^11"
    if [[ "${core_floor%%.*}" == "11" && "$core_floor" != "11.0" ]]; then req="^$core_floor"; fi
    composer="$req"
    rationale+=("Strategy: d11-only ('$req')${legacy_note:+ ($legacy_note)}.")
    [[ -n "$d10_dropped_note" ]] && warnings+=("$d10_dropped_note")
    rationale+=("Drupal 11 enforces PHP $php_target itself, so no composer require.php is needed.")
  fi

  # --- version bump (SemVer for Drupal contrib) ---------------------------
  # drops_major: the recommended requirement no longer supports a core major the
  # current one did (e.g. '^8 || ^9' -> '^10 || ^11' drops 8 AND 9, '^9 || ^10' ->
  # '^10 || ^11' drops 9). Dropping a previously-supported core major is
  # backwards-incompatible for those sites -> MAJOR, regardless of the strategy
  # (the old check only caught the d11-only path and under-reported keep-d10).
  local drops_major=0
  if [[ -n "$current_req" ]]; then
    local _rec_majors _m
    _rec_majors="$(printf '%s' "$req" | grep -oE '[0-9]+(\.[0-9]+)*' | sed -E 's/\..*//' | sort -u)"
    for _m in $(printf '%s' "$current_req" | grep -oE '[0-9]+(\.[0-9]+)*' | sed -E 's/\..*//' | sort -u); do
      printf '%s\n' "$_rec_majors" | grep -qx "$_m" || drops_major=1
    done
  fi
  local version_bump
  if [[ "$bc_break" == "1" || "$drops_major" == "1" ]]; then
    version_bump="major"
    [[ "$drops_major" == "1" ]] && rationale+=("Dropping a previously-supported Drupal core major (current '${current_req:-none}' -> '$req') is backwards-incompatible -> MAJOR (cut a new N+1.0.x branch).")
    [[ "$bc_break" == "1" ]] && rationale+=("Phase 2 refactor / asserted public-API BC break -> MAJOR.")
  elif [[ "$current_has_11" == "0" ]]; then
    version_bump="minor"
    rationale+=("Adding Drupal 11 support without dropping a supported core major -> MINOR.")
  else
    version_bump="patch"
    rationale+=("No core-major change and no API break -> PATCH.")
  fi

  # --- core legs to verify (verify-core-matrix.sh --cores auto) -------------
  local verify_cores_json
  verify_cores_json="$(core_matrix_legs "$req" | jq -R . | jq -sc 'map(select(length > 0))' 2>/dev/null || printf '[]')"
  [[ -n "$verify_cores_json" ]] || verify_cores_json='[]'

  # --- emit JSON ----------------------------------------------------------
  jq -n \
    --arg strategy "$resolved" \
    --arg phase "$phase" \
    --arg current "$current_req" \
    --arg req "$req" \
    --arg composer "$composer" \
    --arg require_php "$require_php" \
    --arg version_bump "$version_bump" \
    --arg php_target "$php_target" \
    --arg php_floor_strategy "$floor_strategy" \
    --arg php_floor_detected "$detected_floor" \
    --arg php_floor_effective "$effective_floor" \
    --argjson php_floor_target_compatible "$target_compat_json" \
    --arg d10_support "$d10_support" \
    --argjson verify_cores "$verify_cores_json" \
    --argjson has_composer_json "$has_composer" \
    --argjson bc_break "$([[ "$bc_break" == "1" ]] && echo true || echo false)" \
    --argjson rationale "$(arr_to_json ${rationale[@]+"${rationale[@]}"})" \
    --argjson warnings "$(arr_to_json ${warnings[@]+"${warnings[@]}"})" \
    --argjson suggested "$(arr_to_json ${suggested[@]+"${suggested[@]}"})" \
    '{
      strategy: $strategy,
      phase: $phase,
      current_core_version_requirement: ($current | select(. != "") // null),
      recommended_core_version_requirement: $req,
      composer_core_constraint: $composer,
      require_php: ($require_php | select(. != "") // null),
      version_bump: $version_bump,
      bc_break: $bc_break,
      php_target: $php_target,
      php_floor_strategy: $php_floor_strategy,
      php_floor_detected: ($php_floor_detected | select(. != "") // null),
      php_floor_effective: ($php_floor_effective | select(. != "") // null),
      php_floor_target_compatible: $php_floor_target_compatible,
      has_composer_json: $has_composer_json,
      d10_support: $d10_support,
      verify_cores: $verify_cores,
      rationale: $rationale,
      warnings: $warnings,
      suggested_remaining_tasks: $suggested
    }'
}

# ---------------------------------------------------------------------------
# Test-bed ownership marker (scripts/env/clean.sh) + cached base core
# (scripts/env/ddev-up.sh)
# ---------------------------------------------------------------------------
# A Drupal root that drupilot BUILT (ddev-up.sh ran `composer create-project`
# or restored a cached base core into an empty root) carries a marker in its
# .drupilot.json:
#
#   "drupilot_testbed": {
#     "created_at": "<UTC>", "created_by": "ddev-up.sh", "drupilot_version": "x",
#     "core_cache": "<cache entry key>" | absent,
#     "subjects": { "<machine_name>": {"dest": "<abs>", "origin": "<abs>",
#                                      "placement": "move|copy|symlink",
#                                      "at": "<UTC>"} }
#   }
#
# place-subject.sh adds one `subjects` entry per placed module/theme, so a
# later /drupilot-clean knows where a moved checkout came from and can put it
# back. The marker is not a DRUPILOT_* key on purpose: config_get never reads
# it, and an environment variable cannot fake it. clean.sh refuses to delete
# vendor/ or the workspace of a root without it (see testbed_kind).

# _root_prefs_update <root> <jq-filter> [jq args...] -> atomically rewrite
# <root>/.drupilot.json with <filter> (created as {} when absent). The jq
# arguments (e.g. --arg k v) go before the filter. Returns 1 without jq, for a
# missing root or on a jq/write error.
_root_prefs_update() {
  local root="$1" filter="$2" f tmp
  shift 2
  have_cmd jq || return 1
  [[ -n "$root" && -d "$root" ]] || return 1
  f="$root/.drupilot.json"
  [[ -s "$f" ]] || printf '{}\n' > "$f" 2>/dev/null || return 1
  tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 1
  if jq "$@" "$filter" "$f" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp" 2>/dev/null || true; return 1
  fi
}

# testbed_mark <root> <created_by> [core_cache_key] -> mark <root> as a test-bed
# drupilot built. Keeps an existing created_at/created_by. Returns 1 on error.
testbed_mark() {
  local root="$1" by="${2:-drupilot}" key="${3:-}"
  _root_prefs_update "$root" '
    .drupilot_testbed = ((.drupilot_testbed // {})
      | .created_at = (.created_at // $at)
      | .created_by = (.created_by // $by)
      | .drupilot_version = $pv
      | (if $key == "" then . else .core_cache = $key end))' \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg by "$by" \
    --arg pv "$(plugin_version)" --arg key "$key"
}

# testbed_record_subject <root> <machine_name> <dest> <origin> <placement> ->
# remember where a placed subject came from (its origin path before a move).
# Written whether or not the root is marked: the record alone never makes a
# root deletable. Returns 1 on error.
testbed_record_subject() {
  local root="$1" mn="$2" dest="$3" origin="$4" placement="$5"
  [[ -n "$mn" ]] || return 1
  _root_prefs_update "$root" '
    .drupilot_testbed = ((.drupilot_testbed // {})
      | .subjects = ((.subjects // {})
        | .[$mn] = {dest: $dest, origin: $origin, placement: $pl, at: $at}))' \
    --arg mn "$mn" --arg dest "$dest" --arg origin "$origin" --arg pl "$placement" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# subject_project_root <subject> -> the Drupal root (DDEV project) the
# subject is ported in, as ddev-up.sh resolves it: the Drupal root above the
# subject; for a LOOSE checkout (copy/symlink origin, or not placed yet) the
# test-bed resolve-workspace.sh targets; for a path that no longer exists (a
# 'move' placement relocated it) the pinned DRUPILOT_WORKSPACE_DIR or the
# '<name>-d11' sibling that now holds it. Prints nothing (still 0) when none is
# found. Read-only: it never creates the test-bed.
subject_project_root() {
  local s="${1:-$PWD}" r="" base parent c
  if [[ -d "$s" ]]; then
    # A project checkout without installed core is not where the module runs.
    r="$(drupal_run_root "$s" 2>/dev/null || true)"
    if [[ -z "$r" ]] && is_drupal_extension_dir "$s" && have_cmd jq; then
      r="$(bash "$(plugin_root)/scripts/env/resolve-workspace.sh" --subject "$s" --json </dev/null 2>/dev/null \
        | jq -r '.drupal_root // empty' 2>/dev/null || true)"
    fi
  else
    base="$(basename "$s")"
    parent="$(cd "$(dirname "$s")" 2>/dev/null && pwd || true)"
    if [[ -n "$parent" && -n "$base" ]]; then
      for c in "$(config_get DRUPILOT_WORKSPACE_DIR "")" "$parent/${base}-d11"; do
        [[ -n "$c" ]] || continue
        if [[ -d "$c/web/modules/custom/$base" || -d "$c/web/themes/custom/$base" \
              || -d "$c/web/profiles/custom/$base" ]]; then
          r="$(cd "$c" && pwd)"; break
        fi
      done
    fi
  fi
  [[ -n "$r" ]] && printf '%s' "$r"
  return 0
}

# testbed_kind <root> -> "marker" (drupilot built it: .drupilot_testbed.created_by
# is set), "legacy" (built before the marker existed: its .drupilot.json pins
# DRUPILOT_WORKSPACE_DIR to the root itself, which only place-subject.sh does
# for a loose subject's test-bed, AND it has the default '<name>-d11' or
# '<name>-d11-N' sibling name) or "none" (anything else: the user's own site).
# Always returns 0.
testbed_kind() {
  local root="${1:-}" f by ws base
  f="$root/.drupilot.json"
  if [[ -n "$root" && -r "$f" ]] && have_cmd jq; then
    by="$(jq -r '.drupilot_testbed.created_by // empty' "$f" 2>/dev/null || true)"
    if [[ -n "$by" ]]; then printf 'marker'; return 0; fi
    ws="$(jq -r '.DRUPILOT_WORKSPACE_DIR // empty' "$f" 2>/dev/null || true)"
    base="$(basename "$root")"
    if [[ -n "$ws" && "${ws%/}" == "${root%/}" && "$base" =~ -d11(-[0-9]+)?$ ]]; then
      printf 'legacy'; return 0
    fi
  fi
  printf 'none'
  return 0
}

# subjects_with_state_under <root> -> the subject paths (one per line) whose
# state.json records <root> as their Drupal root, or lives under it. Read-only;
# used to mark the environment removed/ready on every module of a test-bed.
subjects_with_state_under() {
  local root="${1%/}" sd f
  [[ -n "$root" ]] && have_cmd jq || return 0
  sd="$(data_dir_path)/state"
  [[ -d "$sd" ]] || return 0
  for f in "$sd"/*/state.json; do
    [[ -r "$f" ]] || continue
    jq -r --arg r "$root" '
      select(type == "object" and (.subject // "") != "")
      | select((.drupal_root // "") == $r or ((.subject // "") | startswith($r + "/")))
      | .subject' "$f" 2>/dev/null || true
  done
  return 0
}

# env_status_record <root> <status> [level] -> store `.environment = {status,
# level, at}` in the state.json of every subject under <root>
# (status: removed | ready). /drupilot-clean records `removed`; ddev-up.sh and
# place-subject.sh record `ready` on a subject that was marked removed, so
# next-step.sh recommends /drupilot-setup exactly while the environment is
# gone. Never fails.
env_status_record() {
  local root="$1" status="$2" level="${3:-}" s cur v
  have_cmd jq || return 0
  v="$(jq -nc --arg s "$status" --arg l "$level" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{status: $s, level: (if $l == "" then null else $l end), at: $at}')"
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    if [[ "$status" == "ready" ]]; then
      cur="$(state_get "$s" .environment.status "")"
      [[ "$cur" == "removed" ]] || continue
    fi
    state_set_json "$s" .environment "$v" 2>/dev/null || true
  done < <(subjects_with_state_under "$root")
  return 0
}

# fast_copy_tree <src> <dest> -> copy the CONTENTS of <src> into <dest>
# (created), preserving modes, times and symlinks, as cheaply as the filesystem
# allows: a copy-on-write clone where possible (GNU cp --reflink=auto on
# btrfs/XFS/..., `cp -c` = clonefile(2) on macOS APFS), a plain `cp -a`
# otherwise. Prints the method used (reflink-auto | clone | copy) on STDOUT.
# Returns 1 when the copy fails.
fast_copy_tree() {
  local src="$1" dest="$2"
  [[ -d "$src" ]] || return 1
  mkdir -p "$dest" 2>/dev/null || return 1
  if cp --help 2>&1 | grep -q -- '--reflink'; then
    cp -a --reflink=auto "$src/." "$dest/" 2>/dev/null || return 1
    printf 'reflink-auto'; return 0
  fi
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] && cp -a -c "$src/." "$dest/" 2>/dev/null; then
    printf 'clone'; return 0
  fi
  cp -a "$src/." "$dest/" 2>/dev/null || cp -R -p "$src/." "$dest/" 2>/dev/null || return 1
  printf 'copy'
  return 0
}

# core_cache_dir -> where ddev-up.sh keeps cached base cores (under drupilot's
# data dir, never a project tree). One entry per PHP target and exact core
# version: <dir>/php<PHP>-<core version>/{tree/, meta.json}.
core_cache_dir() { printf '%s/core-base' "$(data_dir_path)/cache"; }

# core_cache_lookup <php> <constraint> <drush_spec> [exact_version] [max_age_days]
# -> the path of a usable cache entry on STDOUT (nothing when there is none).
# With <exact_version> (the core version the lockfile froze), only that entry.
# Without it, the newest entry built for the same <constraint> that is at most
# <max_age_days> old (0 = no age limit). Either way the entry must have been
# built with the same Drush constraint and hold a complete tree. Read-only.
core_cache_lookup() {
  local php="$1" cons="$2" drush="$3" exact="${4:-}" maxage="${5:-7}"
  local cd e m now best="" best_at=0 at
  have_cmd jq || return 0
  cd="$(core_cache_dir)"
  [[ -d "$cd" ]] || return 0
  now="$(date +%s)"
  for e in "$cd"/php"$php"-*; do
    [[ -d "$e" && -f "$e/meta.json" && -f "$e/tree/composer.lock" && -f "$e/tree/composer.json" ]] || continue
    m="$e/meta.json"
    [[ "$(jq -r '.complete // false' "$m" 2>/dev/null)" == "true" ]] || continue
    [[ "$(jq -r '.drush // empty' "$m" 2>/dev/null)" == "$drush" ]] || continue
    if [[ -n "$exact" ]]; then
      [[ "$(jq -r '.version // empty' "$m" 2>/dev/null)" == "$exact" ]] || continue
      printf '%s' "$e"; return 0
    fi
    [[ "$(jq -r '.constraint // empty' "$m" 2>/dev/null)" == "$cons" ]] || continue
    at="$(jq -r '.created_epoch // 0' "$m" 2>/dev/null || echo 0)"
    [[ "$at" =~ ^[0-9]+$ ]] || at=0
    if [[ "$maxage" =~ ^[0-9]+$ && "$maxage" -gt 0 ]] && (( now - at > maxage * 86400 )); then
      continue
    fi
    if (( at > best_at )); then best="$e"; best_at="$at"; fi
  done
  [[ -n "$best" ]] && printf '%s' "$best"
  return 0
}

# core_cache_entries -> one JSON object per line for every cache entry:
# {path, key, version, php, constraint, created_at, complete}. Read-only.
core_cache_entries() {
  local cd e
  have_cmd jq || return 0
  cd="$(core_cache_dir)"
  [[ -d "$cd" ]] || return 0
  for e in "$cd"/php*; do
    [[ -d "$e" ]] || continue
    if [[ -f "$e/meta.json" ]]; then
      jq -c --arg p "$e" --arg k "$(basename "$e")" \
        '{path: $p, key: $k, version: (.version // null), php: (.php // null),
          constraint: (.constraint // null), created_at: (.created_at // null),
          complete: (.complete // false)}' "$e/meta.json" 2>/dev/null || true
    else
      jq -nc --arg p "$e" --arg k "$(basename "$e")" \
        '{path: $p, key: $k, version: null, php: null, constraint: null, created_at: null, complete: false}'
    fi
  done
  return 0
}

# core_cache_prune <keep> -> delete all but the <keep> newest complete entries
# (and any incomplete leftover). Never fails.
core_cache_prune() {
  local keep="${1:-3}" cd e n=0
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=3
  cd="$(core_cache_dir)"
  [[ -d "$cd" ]] && have_cmd jq || return 0
  while IFS=$'\t' read -r _at e; do
    [[ -n "$e" && -d "$e" ]] || continue
    n=$((n + 1))
    if (( n > keep )); then
      chmod -R u+w "$e" 2>/dev/null || true
      rm -rf "${e:?}" 2>/dev/null || true
    fi
  done < <(for e in "$cd"/php*; do
             [[ -d "$e" ]] || continue
             if [[ "$(jq -r '.complete // false' "$e/meta.json" 2>/dev/null)" != "true" ]]; then
               printf '0\t%s\n' "$e"; continue
             fi
             printf '%s\t%s\n' "$(jq -r '.created_epoch // 0' "$e/meta.json" 2>/dev/null)" "$e"
           done | sort -t "$(printf '\t')" -k1,1nr)
  # Incomplete entries sort last (epoch 0) and are removed only past <keep>;
  # remove them regardless: they can never be used.
  for e in "$cd"/php*; do
    [[ -d "$e" ]] || continue
    if [[ "$(jq -r '.complete // false' "$e/meta.json" 2>/dev/null)" != "true" ]]; then
      chmod -R u+w "$e" 2>/dev/null || true
      rm -rf "${e:?}" 2>/dev/null || true
    fi
  done
  return 0
}

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

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------
# json_str <string> -> a quoted, escaped JSON string
json_str() {
  if have_cmd jq; then jq -Rn --arg s "$1" '$s'
  else printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; fi
}

# arr_to_json <elem...> -> a compact JSON array of the (string) arguments.
# Empty arg list -> "[]". Requires jq.
arr_to_json() {
  if [[ "$#" -eq 0 ]]; then printf '[]'; return 0; fi
  printf '%s\n' "$@" | jq -R . | jq -s -c .
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
# os_id -> OS identifier (fedora, ubuntu, debian, arch, macos, ...)
os_id() {
  case "$(uname -s)" in
    Darwin) printf 'macos'; return 0;;
    Linux) : ;;
    *) printf 'unknown'; return 0;;
  esac
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    ( . /etc/os-release; printf '%s' "${ID:-linux}" )
  else
    printf 'linux'
  fi
}

# ---------------------------------------------------------------------------
# Portability helpers (bash 3.2 / BSD userland — stock macOS)
# ---------------------------------------------------------------------------
# The plugin targets bash >= 3.2 and does not assume GNU tools. So: no
# ${x,,}/${x^^} (bash 4), no declare -A / mapfile / local -n, no `sed -i` (GNU
# and BSD disagree on its argument), and possibly-empty arrays are expanded with
# the ${arr[@]+"${arr[@]}"} idiom (a bare "${arr[@]}" of an empty array is an
# "unbound variable" error under `set -u` before bash 4.4).

# lc <string...> -> the string lowercased (portable replacement for ${x,,}).
lc() { printf '%s' "$*" | tr '[:upper:]' '[:lower:]'; }

# sed_inplace <file> <sed args...> -> edit <file> in place, portably. Runs
# `sed <args...> <file>` into a temp file next to it, then copies it back with
# `cat >` (keeps the inode, permissions and any symlink target). On failure the
# original is left untouched, the temp file is removed and it returns non-zero.
# Use it instead of `sed -i`, which takes a mandatory suffix on BSD/macOS.
sed_inplace() {
  local f="${1:-}"; shift || true
  [[ -n "$f" && -f "$f" ]] || { log_err "sed_inplace: not a regular file: '${f}'"; return 1; }
  [[ $# -gt 0 ]] || { log_err "sed_inplace: no sed expression given for '$f'"; return 1; }
  local tmp
  tmp="$(mktemp "${f}.drupilot.XXXXXX" 2>/dev/null || mktemp 2>/dev/null)" \
    || { log_err "sed_inplace: cannot create a temp file for '$f'"; return 1; }
  if sed "$@" "$f" > "$tmp" && cat "$tmp" > "$f"; then
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"
  return 1
}

# render_template <template> <dest|-> [KEY=VALUE...] -> substitute every
# {{KEY}} token of <template> with VALUE, literally, and write the result to
# <dest> ('-' = stdout). Values are taken verbatim: no sed delimiter, '&',
# backslash or regex metacharacter can break them, and envsubst is not needed.
# The substitution runs in awk with the values passed through the environment
# (awk -v would interpret backslash escapes, and bash's ${x//pat/rep} differs
# between 3.2 and 5.2 in how it treats quotes and '&'). Tokens without a
# KEY=VALUE pair are left as-is, so the caller can detect them. The render goes
# to a temp file next to <dest> first, so <dest> is only touched once rendering
# succeeded. Returns non-zero on a bad argument or I/O error.
render_template() {
  local tpl="${1:-}" dest="${2:-}"
  shift 2 2>/dev/null || { log_err "render_template: usage: render_template TEMPLATE DEST [KEY=VALUE...]"; return 1; }
  [[ -f "$tpl" ]] || { log_err "render_template: template not found: '$tpl'"; return 1; }
  [[ -n "$dest" ]] || { log_err "render_template: missing destination for '$tpl'"; return 1; }
  local -a envs=()
  local keys="" pair k
  for pair in "$@"; do
    k="${pair%%=*}"
    case "$k" in
      ''|*[!A-Z0-9_]*) log_err "render_template: invalid token name in '$pair' (expected KEY=VALUE, KEY in [A-Z0-9_])"; return 1;;
    esac
    [[ "$pair" == *=* ]] || { log_err "render_template: missing '=' in '$pair'"; return 1; }
    keys="$keys $k"
    envs+=("_DRUPILOT_TPL_V_$k=${pair#*=}")
  done
  envs+=("_DRUPILOT_TPL_KEYS=$keys")
  # shellcheck disable=SC2016  # awk program, not a shell expansion
  local prog='
    BEGIN {
      n = split(ENVIRON["_DRUPILOT_TPL_KEYS"], ks, " ")
      for (i = 1; i <= n; i++) { tok[i] = "{{" ks[i] "}}"; val[i] = ENVIRON["_DRUPILOT_TPL_V_" ks[i]] }
    }
    {
      line = $0
      for (i = 1; i <= n; i++) {
        out = ""
        while ((p = index(line, tok[i])) > 0) {
          out = out substr(line, 1, p - 1) val[i]
          line = substr(line, p + length(tok[i]))
        }
        line = out line
      }
      print line
    }'
  if [[ "$dest" == "-" ]]; then
    env "${envs[@]}" awk "$prog" "$tpl"
    return $?
  fi
  local tmp
  tmp="$(mktemp "${dest}.drupilot.XXXXXX" 2>/dev/null)" \
    || { log_err "render_template: cannot create a temp file next to '$dest'"; return 1; }
  # `cat >` (not mv) so a new file gets the umask mode and an existing one keeps
  # its mode/inode, exactly like the plain `> dest` redirect this replaces.
  if env "${envs[@]}" awk "$prog" "$tpl" > "$tmp" && cat "$tmp" > "$dest"; then
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"
  return 1
}

# ---------------------------------------------------------------------------
# Toolchain health: the known-good reference set + Rector crash detection
# ---------------------------------------------------------------------------
# config/toolchain-reference.json is the KNOWN-GOOD dev-toolchain matrix shipped
# with the plugin: exact versions verified together end to end (install + a
# Rector dry-run + PHPStan). install-toolchain.sh pins to it when a project has
# no lock yet (deterministic mode), so a fresh test-bed created after a broken
# upstream release still gets a set that works.

# toolchain_reference_file -> path to the shipped reference matrix.
toolchain_reference_file() { printf '%s/config/toolchain-reference.json' "$(plugin_root)"; }

# toolchain_reference_version <package> -> the known-good exact version of a
# Composer package (e.g. rector/rector -> 2.5.2), or nothing when the reference
# does not pin it. Never fatal.
toolchain_reference_version() {
  local f; f="$(toolchain_reference_file)"
  [[ -r "$f" ]] && have_cmd jq || return 0
  jq -r --arg n "${1:-}" '.toolchain[$n] // empty' "$f" 2>/dev/null || true
  return 0
}

# toolchain_reference_require_cmd -> the exact command that installs the
# reference set (Rector + PHPStan core packages), printed for remediation
# messages. Empty when the reference is unreadable.
toolchain_reference_require_cmd() {
  local f specs; f="$(toolchain_reference_file)"
  [[ -r "$f" ]] && have_cmd jq || return 0
  specs="$(jq -r '(.remediation_packages // []) as $p | .toolchain as $t
                  | [$p[] | select($t[.] != null) | "\(.):\($t[.])"] | join(" ")' "$f" 2>/dev/null || true)"
  [[ -n "$specs" ]] && printf 'ddev composer require --dev -W %s' "$specs"
  return 0
}

# installed_package_version <root> <package> -> the version composer.lock
# records for <package> (packages + packages-dev), or nothing.
installed_package_version() {
  local r="${1:-}" n="${2:-}"
  [[ -n "$r" && -f "$r/composer.lock" ]] && have_cmd jq || return 0
  jq -r --arg n "$n" '((.packages // []) + (."packages-dev" // []))
         | map(select(.name == $n)) | (.[0].version // empty)' "$r/composer.lock" 2>/dev/null \
    | sed 's/^v//' || true
  return 0
}

# rector_output_ok <exit_code> <raw_output> -> 0 when a `rector process` run
# finished normally, 1 when it crashed or reported errors. Rector exits 0 (no
# change / applied) or 2 (dry-run found changes) and always ends with an
# "[OK] ..." line; a configuration error ("[ERROR] Could not detect twig set."),
# per-file processing errors (exit 1) or a PHP fatal (exit 255) do not. Both the
# exit code AND the [OK] marker are required, so neither a wrapper that loses the
# exit code nor a crash after partial output can pass as "no changes".
rector_output_ok() {
  local rc="${1:-1}" raw="${2:-}"
  case "$rc" in 0|2) ;; *) return 1;; esac
  printf '%s\n' "$raw" | grep -qE '^[[:space:]]*\[OK\][[:space:]]' || return 1
  return 0
}

# rector_error_excerpt <raw_output> -> the lines that explain a failed Rector run
# (at most 8), for logs and the --json "errors" payload. Diff hunks are skipped,
# so a module string such as 'Fatal error:' can never be mistaken for a crash.
# A boxed "[ERROR] ..." message wraps onto indented continuation lines (e.g.
# 'Expected an existing class name. Got:' + '"SomeRector"'); those are joined
# into the same excerpt line up to the closing blank line, so the offending
# class/rule name is kept. Falls back to the last non-empty lines when no known
# marker is found.
rector_error_excerpt() {
  local raw="${1:-}" out
  out="$(printf '%s\n' "$raw" | awk '
      function clean(s) { gsub(/\033\[[0-9;]*[A-Za-z]/, "", s); sub(/[[:space:]]+$/, "", s); sub(/^[[:space:]]+/, "", s); return s }
      function flush() { if (length(cur) > 0) print cur; cur = ""; inbox = 0 }
      /-+ begin diff -+/ { flush(); indiff = 1; next }
      /-+ end diff -+/   { indiff = 0; next }
      indiff { next }
      /\[ERROR\]/ { flush(); cur = clean($0); inbox = 1; next }
      inbox && /^[[:space:]]+[^[:space:]]/ && !/\[[A-Z]+\]/ { cur = cur " " clean($0); next }
      inbox { flush() }
      /Fatal error|Uncaught|Exception|Could not |not found|Failed to execute command/ {
        l = clean($0); if (length(l) > 0) print l
      }
      END { flush() }' | head -n 8)"
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$raw" | sed -e "s/$(printf '\033')\\[[0-9;]*[A-Za-z]//g" | grep -v '^[[:space:]]*$' | tail -n 5 || true)"
  fi
  printf '%s' "$out"
  return 0
}

# toolchain_diagnostics <root> -> log (STDERR) the installed vs known-good
# versions of the Rector/PHPStan packages and the exact remediation command.
# Used after a failed smoke test and by run-rector.sh after a Rector crash.
toolchain_diagnostics() {
  local r="${1:-}" f pkg inst ref cmd differs=0
  f="$(toolchain_reference_file)"
  log_plain "   Installed vs known-good toolchain ($(basename "$f")):"
  for pkg in rector/rector palantirnet/drupal-rector phpstan/phpstan mglaman/phpstan-drupal; do
    inst="$(installed_package_version "$r" "$pkg")"
    ref="$(toolchain_reference_version "$pkg")"
    [[ -n "$ref" && "$inst" != "$ref" ]] && differs=1
    log_plain "     $(printf '%-28s' "$pkg") installed: ${inst:-?}   known-good: ${ref:-?}"
  done
  if [[ "$differs" == "0" ]]; then
    log_plain "   The installed toolchain matches the known-good set, so look at the Rector config"
    log_plain "   (rector.php; regenerate it with render-templates.sh --only rector --force) or the error above."
    return 0
  fi
  cmd="$(toolchain_reference_require_cmd)"
  if [[ -n "$cmd" ]]; then
    log_plain "   Fix: reinstall the known-good set (from the Drupal root):"
    log_plain "     bash \"$(plugin_root)/scripts/env/install-toolchain.sh\" --dir \"$r\" --source reference"
    log_plain "   or by hand:  $cmd"
  fi
  return 0
}

# rector_smoke <root> -> run a trivial Rector dry-run (with the Drupal 10 set
# that drupal-rector loads at config time) plus `phpstan --version`, through
# drupal_runner, to prove the installed toolchain actually works. Scratch files
# go under <root>/.drupilot/rector-smoke.* (inside the project so the DDEV
# container sees them; removed afterwards). Prints the failure excerpt on STDOUT
# and returns 1 when broken; prints nothing and returns 0 when healthy.
rector_smoke() {
  local r="${1:-}" runner dir rel raw rc
  [[ -n "$r" && -d "$r" ]] || { printf 'rector_smoke: no Drupal root'; return 1; }
  if [[ ! -f "$r/vendor/bin/rector" ]]; then printf 'vendor/bin/rector is missing'; return 1; fi
  runner="$(drupal_runner "$r")"
  mkdir -p "$r/.drupilot" 2>/dev/null || true
  [[ -f "$r/.drupilot/.gitignore" ]] || printf '*\n' > "$r/.drupilot/.gitignore" 2>/dev/null || true
  dir="$(mktemp -d "$r/.drupilot/rector-smoke.XXXXXX" 2>/dev/null)" \
    || { printf 'rector_smoke: cannot create a scratch dir under %s/.drupilot' "$r"; return 1; }
  rel="${dir#"$r"/}"
  cat > "$dir/smoke.php" <<'PHP'
<?php

function drupilot_smoke(array $items): bool {
  return strpos('drupilot', 'pilot') !== FALSE && count($items) >= 0;
}
PHP
  cat > "$dir/rector.php" <<'PHP'
<?php

declare(strict_types=1);

use DrupalRector\Set\Drupal10SetList;
use Rector\Config\RectorConfig;

return RectorConfig::configure()
  ->withPaths([__DIR__ . '/smoke.php'])
  ->withSets([Drupal10SetList::DRUPAL_10])
  ->withPhpSets(php80: true);
PHP
  # `&& rc=0 || rc=$?` keeps a failing run from tripping the caller's `set -e`.
  # shellcheck disable=SC2086  # intentional word-split: runner is a command prefix.
  raw="$(cd "$r" && $runner vendor/bin/rector process --config "$rel/rector.php" --dry-run --no-progress-bar --clear-cache 2>&1)" \
    && rc=0 || rc=$?
  if ! rector_output_ok "$rc" "$raw"; then
    rm -rf "$dir" 2>/dev/null || true
    printf 'rector smoke dry-run failed (exit %s): %s' "$rc" "$(rector_error_excerpt "$raw")"
    return 1
  fi
  rm -rf "$dir" 2>/dev/null || true
  # shellcheck disable=SC2086  # intentional word-split: runner is a command prefix.
  raw="$(cd "$r" && $runner vendor/bin/phpstan --version 2>&1)" && rc=0 || rc=$?
  if [[ "$rc" != "0" ]] || ! printf '%s' "$raw" | grep -q 'PHPStan'; then
    printf 'phpstan --version failed (exit %s): %s' "$rc" "$(printf '%s\n' "$raw" | tail -n 5)"
    return 1
  fi
  return 0
}

# trim surrounding whitespace from a string
trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# git_port_base_ref <repo> [base] -> print the git ref a port is diffed against,
# WITHOUT touching the network or the working tree (shared by make-patch.sh
# --local and check-port-safety.sh so both judge "what the port changed"
# against the same base). Warnings go to stderr; stdout is only the ref.
#   * An explicit base resolves to origin/<base>, then <base>; it returns 1
#     (printing nothing) when neither exists. It is honored as given, but a
#     base that is not an ancestor of HEAD gets a warning (the diff would also
#     carry the commits that exist only on the base, reversed).
#   * Without a base: the branch upstream when it is an ancestor of HEAD (a
#     diverged upstream falls back to the merge-base, with a warning).
#   * No upstream (e.g. a local branch cut from a release tag): the fork point.
#     origin/HEAD, every other remote-tracking branch and (when any remote ref
#     exists) the nearest tag are candidates; the one whose merge-base with HEAD is CLOSEST to HEAD (fewest
#     commits in between) wins, and its merge-base is used when the candidate is
#     not itself an ancestor — never a ref that would produce a reverse diff of
#     unrelated upstream history. Nothing usable -> HEAD (the working tree).
git_port_base_ref() {
  local repo="$1" base="${2:-}" ref="" mb="" best="" best_mb="" best_n="" best_exact=0 n c head
  if [[ -n "$base" ]]; then
    if git -C "$repo" rev-parse --verify --quiet "origin/$base" >/dev/null 2>&1; then
      ref="origin/$base"
    elif git -C "$repo" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
      ref="$base"
    else
      return 1
    fi
    if git -C "$repo" rev-parse --verify --quiet HEAD >/dev/null 2>&1 \
       && ! git -C "$repo" merge-base --is-ancestor "$ref" HEAD >/dev/null 2>&1; then
      log_warn "Base '$ref' is not an ancestor of HEAD: the diff also contains (reversed) the commits that exist only on '$ref'."
    fi
    printf '%s' "$ref"; return 0
  fi
  head="$(git -C "$repo" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
  [[ -n "$head" ]] || { printf 'HEAD'; return 0; }

  # A copy placed in a test-bed from a larger repository carries its own
  # repository whose first commit is the pristine module (git_seed_baseline):
  # that commit is the base, even after commits made on top of it.
  if git -C "$repo" rev-parse --verify --quiet "$DRUPILOT_BASELINE_REF" >/dev/null 2>&1 \
     && git -C "$repo" merge-base --is-ancestor "$DRUPILOT_BASELINE_REF" HEAD >/dev/null 2>&1; then
    printf '%s' "$DRUPILOT_BASELINE_REF"; return 0
  fi

  ref="$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [[ -n "$ref" ]]; then
    if git -C "$repo" merge-base --is-ancestor "$ref" HEAD >/dev/null 2>&1; then
      printf '%s' "$ref"; return 0
    fi
    mb="$(git -C "$repo" merge-base HEAD "$ref" 2>/dev/null || true)"
    if [[ -n "$mb" ]]; then
      log_warn "Upstream '$ref' has diverged from HEAD; diffing against their merge-base ${mb:0:12} instead."
      printf '%s' "$mb"; return 0
    fi
    log_warn "Upstream '$ref' shares no history with HEAD; diffing against HEAD (uncommitted changes only)."
    printf 'HEAD'; return 0
  fi

  # No upstream: pick the closest fork point among the candidates.
  local -a cands=()
  c="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  [[ -n "$c" ]] && cands+=("$c")
  while IFS= read -r c; do
    [[ -n "$c" && "$c" != */HEAD ]] && cands+=("$c")
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/remotes 2>/dev/null || true)
  # The nearest tag competes only when remotes exist: a remote-less repo keeps
  # the historical HEAD (working tree) default.
  if [[ "${#cands[@]}" -gt 0 ]]; then
    c="$(git -C "$repo" describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
    [[ -n "$c" ]] && cands+=("$c")
  fi
  for c in ${cands[@]+"${cands[@]}"}; do
    mb="$(git -C "$repo" merge-base HEAD "$c" 2>/dev/null || true)"
    [[ -n "$mb" ]] || continue
    n="$(git -C "$repo" rev-list --count "$mb..HEAD" 2>/dev/null || true)"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    # Closest fork point wins; on a tie prefer a candidate that IS the fork
    # point (a readable ref name instead of a bare merge-base sha).
    if [[ -z "$best_n" ]] || (( n < best_n )) \
       || { (( n == best_n )) && [[ "$best_exact" != "1" ]] \
            && [[ "$(git -C "$repo" rev-parse --verify --quiet "$c^{commit}" 2>/dev/null)" == "$mb" ]]; }; then
      best="$c"; best_mb="$mb"; best_n="$n"; best_exact=0
      [[ "$(git -C "$repo" rev-parse --verify --quiet "$c^{commit}" 2>/dev/null)" == "$mb" ]] && best_exact=1
    fi
  done
  if [[ -z "$best" ]]; then
    printf 'HEAD'; return 0
  fi
  if [[ "$best_exact" == "1" ]]; then
    c="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [[ -n "$c" && "$best" != "$c" ]] && ! git -C "$repo" merge-base --is-ancestor "$c" HEAD >/dev/null 2>&1; then
      log_warn "The branch has no upstream and '$c' (origin/HEAD) is not an ancestor of HEAD; diffing against its fork point '$best' (pass --base to override)."
    fi
    printf '%s' "$best"; return 0
  fi
  log_warn "The branch has no upstream; '$best' is not an ancestor of HEAD, so diffing against their merge-base ${best_mb:0:12} (pass --base to override)."
  printf '%s' "$best_mb"
  return 0
}

# The ref git_seed_baseline points at the pristine commit of a seeded copy.
DRUPILOT_BASELINE_REF="refs/drupilot/baseline"

# git_seed_baseline <copy> <origin> -> give a module COPY that has no repository
# of its own a git baseline, so the local patch of a module ported in a test-bed
# is module-relative and holds only the port. The copy gets its own repository
# whose single commit is the pristine module: the origin's HEAD version of the
# module when the origin is a sub-directory of a git repository (a project
# monorepo, a folder of modules), else the copied files as they are. The copy's
# working tree is left as copied, so uncommitted changes the origin had show up
# in the patch, as they would in the origin. Files the origin's repository
# ignores are ignored in the copy too (its .git/info/exclude). The baseline
# commit is pointed at by DRUPILOT_BASELINE_REF (git_port_base_ref prefers it),
# and the copy's local git config records drupilot.origin, drupilot.originRepo,
# drupilot.originPrefix (the module's path in that repository, with a trailing
# slash) and drupilot.originCommit, from which make-patch.sh --local also writes
# a patch relative to the origin repository's root. Never touches the origin
# (a throwaway index and work tree are used). A copy that already has a .git
# (the origin was its own repository) is left alone. Returns 0 when the copy
# has a baseline (or its own repository), 1 otherwise.
git_seed_baseline() {
  local dest="${1:-}" src="${2:-}" repo="" prefix="" commit="" tmp="" idx="" base l
  [[ -n "$dest" && -d "$dest" ]] && have_cmd git || return 1
  [[ -e "$dest/.git" ]] && return 0
  local -a G=(git -c user.name=drupilot -c user.email=drupilot@localhost.invalid
              -c commit.gpgsign=false -c core.hooksPath=/dev/null)
  if [[ -n "$src" && -d "$src" ]]; then
    repo="$(git_enclosing_repo "$src" 2>/dev/null || true)"
    if [[ -z "$repo" ]] && git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      repo="$(cd "$(git -C "$src" rev-parse --show-toplevel)" 2>/dev/null && pwd -P || true)"
    fi
  fi
  if [[ -n "$repo" ]]; then
    prefix="$(git -C "$src" rev-parse --show-prefix 2>/dev/null || true)"
    commit="$(git -C "$repo" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || true)"
  fi
  git -C "$dest" init -q >/dev/null 2>&1 || return 1
  base="$dest"
  if [[ -n "$commit" ]] && git -C "$repo" cat-file -e "$commit:${prefix%/}" 2>/dev/null; then
    # Check the module out of the origin's HEAD into a throwaway work tree
    # through a throwaway index: the origin's index and files stay untouched.
    # A path checkout runs the origin's post-checkout hook (husky, custom
    # scripts...), which could write into the user's repository: no hooks.
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-baseline.XXXXXX")"
    idx="$tmp.idx"
    if GIT_INDEX_FILE="$idx" git -c core.hooksPath=/dev/null -C "$repo" --work-tree="$tmp" checkout "$commit" -- "${prefix:-.}" >/dev/null 2>&1; then
      base="$tmp/${prefix%/}"
    else
      log_warn "Could not read the module from $repo at ${commit:0:12}; the baseline is the copied files."
      commit=""
    fi
  else
    commit=""
  fi
  if [[ -n "$repo" ]]; then
    # What the origin's repository ignores inside the module is not part of it.
    git -C "$repo" ls-files --others --ignored --exclude-standard --directory -- "${prefix:-.}" 2>/dev/null \
      | while IFS= read -r l; do
          [[ -n "$l" ]] && printf '/%s\n' "${l#"$prefix"}"
        done >> "$dest/.git/info/exclude" 2>/dev/null || true
  fi
  git_local_exclude "$dest" '.drupilot/' '.drupilot.json' '*-port-to-drupal-11.patch' '*-port-to-drupal-11-*.patch'
  if ! { git -C "$base" --git-dir="$dest/.git" --work-tree="$base" add -A . >/dev/null 2>&1 \
         && "${G[@]}" -C "$base" --git-dir="$dest/.git" --work-tree="$base" commit -q --allow-empty --no-verify \
              -m "drupilot baseline: the module before the port${commit:+ ($repo at ${commit:0:12})}" >/dev/null 2>&1; }; then
    [[ -n "$tmp" ]] && rm -rf "${tmp:?}" "$idx"
    rm -rf "${dest:?}/.git"
    return 1
  fi
  [[ -n "$tmp" ]] && rm -rf "${tmp:?}" "$idx"
  git -C "$dest" update-ref "$DRUPILOT_BASELINE_REF" HEAD >/dev/null 2>&1 || true
  # The index was built from another work tree: refresh its stat data.
  git -C "$dest" update-index -q --refresh >/dev/null 2>&1 || true
  [[ -n "$src" ]] && git -C "$dest" config drupilot.origin "$src"
  if [[ -n "$commit" ]]; then
    git -C "$dest" config drupilot.originRepo "$repo"
    git -C "$dest" config drupilot.originPrefix "$prefix"
    git -C "$dest" config drupilot.originCommit "$commit"
  fi
  return 0
}

# git_local_exclude <dir> <pattern...> -> idempotently append each pattern to the
# LOCAL, untracked ignore file of the git repo containing <dir>
# ($GIT_DIR/info/exclude, the common dir for a worktree). Used for drupilot's own
# files written INSIDE a subject repo (the local preview patch, the subject-side
# .drupilot.json): a parent Drupal root's .gitignore does not apply to a nested
# repo, and editing the subject's TRACKED .gitignore would itself be a diff.
# Patterns are gitignore syntax relative to the repo root. Never fails: returns
# 0 and does nothing when <dir> is not in a git work tree. Prints nothing.
git_local_exclude() {
  local dir="$1" ex p; shift || true
  have_cmd git || return 0
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  ex="$(git -C "$dir" rev-parse --git-path info/exclude 2>/dev/null || true)"
  [[ -n "$ex" ]] || return 0
  case "$ex" in /*) : ;; *) ex="$(cd "$dir" && pwd)/$ex";; esac
  mkdir -p "$(dirname "$ex")" 2>/dev/null || return 0
  [[ -f "$ex" ]] || : > "$ex" 2>/dev/null || return 0
  # Never glue a pattern onto a last line that lacks its newline.
  if [[ -s "$ex" && -n "$(tail -c 1 "$ex" 2>/dev/null)" ]]; then
    printf '\n' >> "$ex" 2>/dev/null || return 0
  fi
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    grep -qxF -- "$p" "$ex" 2>/dev/null && continue
    if ! grep -qxF '# drupilot (local, never committed)' "$ex" 2>/dev/null; then
      printf '%s\n' '# drupilot (local, never committed)' >> "$ex" 2>/dev/null || return 0
    fi
    printf '%s\n' "$p" >> "$ex" 2>/dev/null || return 0
  done
  return 0
}

# symlink_escapes <tree> <relpath> -> 0 when <tree>/<relpath> is a symlink whose
# target lies outside <tree>: an absolute target not under <tree>, or a relative
# one whose '..' climbs above it (checked lexically — portable, no readlink -f,
# and the target need not exist). Returns 1 otherwise (including non-links).
symlink_escapes() {
  local tree="$1" rel="${2%/}" tgt base comp depth=0
  [[ -L "$tree/$rel" ]] || return 1
  tgt="$(readlink "$tree/$rel" 2>/dev/null || true)"
  case "$tgt" in
    /*) [[ "$tgt" == "$tree" || "$tgt" == "$tree"/* ]] && return 1; return 0;;
  esac
  base="$(dirname "$rel")"; [[ "$base" == "." ]] && base=""
  local IFS=/
  set -f
  for comp in $base $tgt; do
    case "$comp" in
      ''|.) : ;;
      ..) depth=$((depth-1)); if [[ "$depth" -lt 0 ]]; then set +f; return 0; fi ;;
      *) depth=$((depth+1)) ;;
    esac
  done
  set +f
  return 1
}

# ---------------------------------------------------------------------------
# Project PHPCS ruleset discovery (run-phpcs.sh, post-edit-lint.sh)
# ---------------------------------------------------------------------------
# phpcs_ruleset_is_drupilot <file> -> 0 when <file> is the ruleset drupilot
# itself generated from templates/phpcs.xml.dist.tmpl (its root element is
# <ruleset name="drupilot">). That file is drupilot's own default, never "the
# project's rules", so discovery skips it.
phpcs_ruleset_is_drupilot() { grep -q '<ruleset[^>]*name="drupilot"' "$1" 2>/dev/null; }

# _phpcs_ruleset_in_dir <dir> -> print the first project ruleset in <dir>, in
# PHPCS's own auto-discovery order (squizlabs/php_codesniffer src/Config.php:
# .phpcs.xml, phpcs.xml, .phpcs.xml.dist, phpcs.xml.dist), skipping drupilot's.
_phpcs_ruleset_in_dir() {
  local d="$1" n
  for n in .phpcs.xml phpcs.xml .phpcs.xml.dist phpcs.xml.dist; do
    if [[ -f "$d/$n" ]] && ! phpcs_ruleset_is_drupilot "$d/$n"; then
      printf '%s/%s\n' "$d" "$n"
      return 0
    fi
  done
  return 1
}

# _phpcs_ruleset_walk <from> <stop> -> walk from <from> up to <stop> (inclusive;
# <stop> must be <from> or one of its ancestors, else only <from> is checked).
_phpcs_ruleset_walk() {
  local d="$1" stop="$2"
  while [[ -n "$d" ]]; do
    _phpcs_ruleset_in_dir "$d" && return 0
    [[ "$d" == "$stop" || "$d" == "/" ]] && return 1
    case "$d" in "$stop"/*) : ;; *) return 1;; esac
    d="$(dirname "$d")"
  done
  return 1
}

# find_phpcs_ruleset <subject_abs> <drupal_root> -> print the absolute path of
# the subject's OWN PHPCS ruleset, or return 1 when it ships none. Looked up, in
# order (first hit wins):
#   1. the subject dir up to the Drupal root (what PHPCS would auto-discover);
#   2. the subject's physical path (a symlink placement) up to its git top level
#      (a module that is a repo of its own, or a monorepo root);
#   3. the ORIGIN checkout a copy placement left behind (the subject's origin
#      baseline .source, under the Drupal root) up to its git top level.
# drupilot's own generated ruleset (<ruleset name="drupilot">) is never returned.
# A pure file check: it runs no PHPCS and never writes anything.
find_phpcs_ruleset() {
  local subj="$1" root="$2" phys top src b
  [[ -d "$subj" ]] || return 1
  _phpcs_ruleset_walk "$subj" "${root:-$subj}" && return 0
  phys="$(cd -P "$subj" 2>/dev/null && pwd || true)"
  if [[ -n "$phys" ]]; then
    top=""
    have_cmd git && top="$(git -C "$phys" rev-parse --show-toplevel 2>/dev/null || true)"
    _phpcs_ruleset_walk "$phys" "${top:-$phys}" && return 0
  fi
  if [[ -n "$root" ]] && have_cmd jq; then
    b="$(origin_baseline_find "$root" "$(subject_machine_name "$subj" 2>/dev/null || true)")"
    src=""
    [[ -n "$b" ]] && src="$(jq -r '.source // empty' "$b" 2>/dev/null || true)"
    if [[ -n "$src" && -d "$src" ]]; then
      top=""
      have_cmd git && top="$(git -C "$src" rev-parse --show-toplevel 2>/dev/null || true)"
      _phpcs_ruleset_walk "$src" "${top:-$src}" && return 0
    fi
  fi
  return 1
}

# phpcs_ruleset_value <file> <config|property> <name> -> print the value of the
# first <config name="NAME" value="..."/> (or <property .../>) in <file>, in
# either attribute order; nothing (still 0) when absent. Regex-based, no XML
# parser assumed — enough for the flat one-tag-per-line rulesets PHPCS uses.
phpcs_ruleset_value() {
  local f="$1" tag="$2" name="$3"
  grep -o "<${tag}[[:space:]][^>]*>" "$f" 2>/dev/null \
    | grep "name=\"${name}\"" | head -n 1 \
    | sed -n 's/.*value="\([^"]*\)".*/\1/p'
  return 0
}

# ---------------------------------------------------------------------------
# Repository git hooks (scripts/contrib/git-hooks.sh, hooks/scripts/guard-contrib.sh)
# ---------------------------------------------------------------------------
# git_hooks_dir <dir> -> print the ABSOLUTE directory git runs hooks from for the
# repo containing <dir> (core.hooksPath when set, relative paths taken from the
# work-tree top as git does; else $GIT_DIR/hooks). Non-zero outside a repo.
git_hooks_dir() {
  local dir="$1" top hp
  have_cmd git || return 1
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$top" ]] || return 1
  hp="$(git -C "$top" config --get core.hooksPath 2>/dev/null || true)"
  if [[ -n "$hp" ]]; then
    case "$hp" in
      "~"/*) hp="$HOME/${hp#"~"/}";;
      /*) : ;;
      *) hp="$top/$hp";;
    esac
  else
    hp="$(git -C "$top" rev-parse --git-path hooks 2>/dev/null || true)"
    case "$hp" in /*|'') : ;; *) hp="$top/$hp";; esac
  fi
  [[ -n "$hp" ]] || return 1
  printf '%s\n' "$hp"
}

# git_active_commit_hooks <dir> -> print, one per line, the commit-time hooks git
# would actually RUN in the repo containing <dir> (executable pre-commit,
# prepare-commit-msg, commit-msg in git_hooks_dir; *.sample files never run).
# These are exactly the hooks `git commit --no-verify` (or -n) skips, except
# prepare-commit-msg, which still runs and is listed for completeness. Prints
# nothing (still 0) when none is active. A pure file check, safe in hooks.
git_active_commit_hooks() {
  local hd h
  hd="$(git_hooks_dir "$1" 2>/dev/null || true)"
  [[ -n "$hd" && -d "$hd" ]] || return 0
  for h in pre-commit prepare-commit-msg commit-msg; do
    [[ -f "$hd/$h" && -x "$hd/$h" ]] && printf '%s\n' "$h"
  done
  return 0
}
