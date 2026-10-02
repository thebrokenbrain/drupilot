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
    php)      out="$(php -r 'echo PHP_VERSION;' 2>/dev/null || php -v 2>&1 | head -n1)";;
    composer) out="$(composer --version 2>/dev/null | head -n1)";;
    docker)   out="$(docker --version 2>&1 | head -n1)";;
    ddev)     out="$(ddev --version 2>&1 | head -n1)";;
    git)      out="$(git --version 2>&1 | head -n1)";;
    jq)       out="$(jq --version 2>&1 | head -n1)";;
    drush)    out="$(drush --version 2>&1 | head -n1)";;
    *)        out="$("$cmd" --version 2>&1 | head -n1)";;
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
  docker info >/dev/null 2>&1
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

# data_dir -> plugin persistent data directory (cache, state).
# Prefers CLAUDE_PLUGIN_DATA (provided by Claude Code) and falls back to XDG.
data_dir() {
  local d="${CLAUDE_PLUGIN_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/drupilot}"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s' "$d"
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
  local base="${1:-$PWD}"
  local abs; abs="$(cd "$base" 2>/dev/null && pwd || printf '%s' "$base")"
  local key; key="$(printf '%s' "$abs" | tr -c 'A-Za-z0-9' '_' )"
  local d; d="$(data_dir)/state/$key"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s' "$d"
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
# root for <base> > <base> itself (a loose subject with no Drupal yet).
project_artifacts_dir() {
  local base="${1:-$PWD}"
  local override; override="$(config_get DRUPILOT_ARTIFACTS_DIR "")"
  if [[ -n "$override" ]]; then
    mkdir -p "$override" 2>/dev/null || true
    ( cd "$override" 2>/dev/null && pwd ) || printf '%s' "$override"
    return 0
  fi
  local root="${DRUPILOT_PROJECT_DIR:-}"
  [[ -z "$root" ]] && root="$(find_drupal_root "$base" 2>/dev/null || true)"
  [[ -z "$root" ]] && root="$base"
  local d="$root/.drupilot"
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
  local pf; pf="$(drupilot_prefs_file 2>/dev/null || true)"
  if [[ -n "$pf" && -r "$pf" ]] && have_cmd jq; then
    local pv; pv="$(jq -r --arg k "$key" '.[$k] // empty' "$pf" 2>/dev/null)"
    if [[ -n "$pv" && "$pv" != "null" ]]; then printf '%s' "$pv"; return 0; fi
  fi
  local file; file="$(drupilot_config_file)"
  if [[ -r "$file" ]] && have_cmd jq; then
    local v; v="$(jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null)"
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

# php_target_unconfirmed <ver> -> 0 if flagged as not officially confirmed
php_target_unconfirmed() {
  local v="$1" file; file="$(drupilot_config_file)"
  if [[ -r "$file" ]] && have_cmd jq; then
    jq -e --arg v "$v" '.php_support.unconfirmed | index($v)' "$file" >/dev/null 2>&1 && return 0
  fi
  [[ "$v" == "8.5" ]]
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
    st="$( (cd "$r" 2>/dev/null && ddev describe -j 2>/dev/null) \
      | jq -r 'select(.raw != null) | .raw.status // empty' 2>/dev/null | head -n1 || true)"
  elif have_cmd docker; then
    local name
    name="$(grep -E '^name:' "$r/.ddev/config.yaml" 2>/dev/null | head -n1 \
      | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' | tr -d '"'"'"'')"
    [[ -n "$name" ]] || name="$(basename "$r")"
    if docker ps --filter "label=com.ddev.site-name=$name" \
         --filter "label=com.docker.compose.service=web" --format '{{.ID}}' 2>/dev/null \
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
    out="$( ( cd "$r" 2>/dev/null && ddev add-on list --installed -j 2>/dev/null ) \
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
      [ .[] | {test, type, label, verdict, at, mutation: (.mutation.kind // null),
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
#   the recommended requirement (core_verify_legs), e.g. ["10","11"].
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
    if [[ "$had_pre11" == "1" ]]; then
      # The kept requirement still allows Drupal 10, so declare the PHP floor.
      require_php=">=$php_target"
      if [[ "$floor_strategy" == "detect" && -n "$detected_floor" ]]; then
        local f="$detected_floor"
        version_ge "$f" "8.1" || f="8.1"
        version_ge "$php_target" "$f" || f="$php_target"
        effective_floor="$f"; require_php=">=$f"
      fi
      d10_support="declared-not-verified"
      warnings+=("The kept requirement still allows Drupal 10 ('$current_req'); its Drupal 10 compatibility is DECLARED, not verified — run verify-core-matrix.sh (static check on a Drupal 10 core) and install/test on Drupal 10 before relying on it.")
    fi
    if printf '%s' "$current_req" | grep -qE '(^|[^0-9])(8|9)([^0-9]|$)'; then
      suggested+=("The requirement still lists EOL Drupal 8/9 ('$current_req'); narrow it (e.g. to '^10 || ^11' or '^11') via the core-target choice if you no longer support them.")
    fi
  elif [[ "$resolved" == "keep-d10" ]]; then
    req="^10 || ^11"; composer="^10 || ^11"
    require_php=">=$php_target"      # safe default (policy floor = target)
    rationale+=("Strategy: keep-d10 ('^10 || ^11')${legacy_note:+ ($legacy_note)}.")

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
    req="^11"; composer="^11"
    rationale+=("Strategy: d11-only ('^11')${legacy_note:+ ($legacy_note)}.")
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
  verify_cores_json="$(core_verify_legs "$req" | jq -R . | jq -sc 'map(select(length > 0))' 2>/dev/null || printf '[]')"
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
# Interaction (safe confirmation in non-TTY contexts)
# ---------------------------------------------------------------------------
# confirm <question> [default_yes:0/1] -> 0 if the user accepts.
# Without a TTY: uses DRUPILOT_ASSUME_YES or the default; never blocks forever.
# tty_readable -> 0 only if the controlling terminal can actually be OPENED for
# reading. `[[ -r /dev/tty ]]` is not enough: the device node is read-permissioned
# even with no controlling terminal (e.g. the Claude Code Bash tool, cron, CI),
# where the open() then fails. Opening it for real is the reliable test.
tty_readable() { { : </dev/tty; } 2>/dev/null; }

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
# match an option value, else ignored with a warning; (2) an interactive /dev/tty
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
  local override; override="$(config_get "DRUPILOT_CHOICE_${key}" "")"
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
#   3. the ORIGIN checkout a copy placement left behind (origin-baseline.json
#      .source, keyed by the Drupal root) up to its git top level.
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
    b="$(project_state_dir "$root")/origin-baseline.json"
    src="$(jq -r '.source // empty' "$b" 2>/dev/null || true)"
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
