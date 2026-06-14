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

# project_state_dir [base_dir] -> per-project state (cache assess results, etc.)
# Keyed by the project's absolute path (sanitized) under data_dir/state.
project_state_dir() {
  local base="${1:-$PWD}"
  local abs; abs="$(cd "$base" 2>/dev/null && pwd || printf '%s' "$base")"
  local key; key="$(printf '%s' "$abs" | tr -c 'A-Za-z0-9' '_' )"
  local d; d="$(data_dir)/state/$key"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s' "$d"
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
  case "${v,,}" in
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
lock_set() {
  local path="$1" value="$2" f tmp
  have_cmd jq || return 1
  f="$(drupilot_lock_file)"
  [[ -f "$f" ]] || printf '{}\n' > "$f" 2>/dev/null || return 1
  tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 1
  if jq --arg v "$value" "${path} = \$v" "$f" > "$tmp" 2>/dev/null; then
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
  if jq --argjson v "$value" "${path} = \$v" "$f" > "$tmp" 2>/dev/null; then
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

# ddev_running [root] -> 0 if a DDEV web container is up for the project at root.
# Functional check (`ddev exec true` only succeeds when the container runs).
ddev_running() {
  have_cmd ddev || return 1
  local r="${1:-$(find_drupal_root 2>/dev/null || true)}"
  [[ -n "$r" && -f "$r/.ddev/config.yaml" ]] || return 1
  ( cd "$r" 2>/dev/null && ddev exec true >/dev/null 2>&1 )
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
#     bc_break (bool), php_target, rationale:[...], warnings:[...] }
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
  floor_strategy="$(config_get DRUPILOT_REQUIRE_PHP_FLOOR detect)"; floor_strategy="${floor_strategy,,}"
  case "$floor_strategy" in target|detect) : ;; *) floor_strategy="detect";; esac
  detected_floor="$(trim "${DRUPILOT_DETECTED_PHP_FLOOR:-}")"
  [[ -f "$subject/composer.json" ]] && has_composer="true"

  # --- strategy resolution (auto default; KEEP_D10 legacy override) --------
  local strat keep_override legacy_note=""
  strat="$(config_get DRUPILOT_CORE_TARGET_STRATEGY auto)"; strat="${strat,,}"
  case "$strat" in d11-only|keep-d10|auto) : ;; *) strat="auto";; esac
  keep_override="$(config_get DRUPILOT_KEEP_D10 "")"
  if [[ "$strat" == "auto" && -n "$keep_override" ]]; then
    case "${keep_override,,}" in
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
  case "${bc_override,,}" in
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

  if [[ "$resolved" == "keep-d10" ]]; then
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
    suggested+=("Verify Drupal 10 compatibility (install on a Drupal 10 site, or run the test suite against Drupal 10) before relying on the '^10 || ^11' declaration.")
  else
    req="^11"; composer="^11"
    rationale+=("Strategy: d11-only ('^11')${legacy_note:+ ($legacy_note)}.")
    rationale+=("Drupal 11 enforces PHP $php_target itself, so no composer require.php is needed.")
  fi

  # --- version bump (SemVer for Drupal contrib) ---------------------------
  local drops_major=0
  [[ "$resolved" == "d11-only" && "$had_pre11" == "1" ]] && drops_major=1
  local version_bump
  if [[ "$bc_break" == "1" || "$drops_major" == "1" ]]; then
    version_bump="major"
    [[ "$drops_major" == "1" ]] && rationale+=("Dropping a previously-supported Drupal major (current '${current_req:-none}' -> '$req') is backwards-incompatible -> MAJOR (cut a new N+1.0.x branch).")
    [[ "$bc_break" == "1" ]] && rationale+=("Phase 2 refactor / asserted public-API BC break -> MAJOR.")
  elif [[ "$current_has_11" == "0" ]]; then
    version_bump="minor"
    rationale+=("Adding Drupal 11 support with no API break -> MINOR.")
  else
    version_bump="patch"
    rationale+=("No core-major change and no API break -> PATCH.")
  fi

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
  ans="${ans,,}"
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

# trim surrounding whitespace from a string
trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
