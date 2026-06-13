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
# Configuration (env override > defaults.json > caller default)
# ---------------------------------------------------------------------------
# config_get <KEY> [default]
config_get() {
  local key="$1" def="${2:-}"
  local envval="${!key:-}"
  if [[ -n "$envval" ]]; then printf '%s' "$envval"; return 0; fi
  local file; file="$(drupilot_config_file)"
  if [[ -r "$file" ]] && have_cmd jq; then
    local v; v="$(jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null)"
    if [[ -n "$v" && "$v" != "null" ]]; then printf '%s' "$v"; return 0; fi
  fi
  printf '%s' "$def"
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
find_drupal_root() {
  local dir; dir="$(cd "${1:-$PWD}" 2>/dev/null && pwd || printf '')"
  [[ -z "$dir" ]] && return 1
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    if [[ -f "$dir/web/core/lib/Drupal.php" || -f "$dir/core/lib/Drupal.php" ]]; then
      printf '%s' "$dir"; return 0
    fi
    if [[ -f "$dir/.ddev/config.yaml" ]]; then
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
  for f in "$dir"/*.info.yml; do
    [[ -e "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
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

  # --- requirement + composer constraint + require.php (floor = target) ---
  local req composer require_php=""
  local -a rationale=() warnings=()
  if [[ "$resolved" == "keep-d10" ]]; then
    req="^10 || ^11"; composer="^10 || ^11"
    require_php=">=$php_target"      # ALWAYS when keeping D10 (policy floor = target)
    rationale+=("Strategy: keep-d10 ('^10 || ^11')${legacy_note:+ ($legacy_note)}.")
    rationale+=("PHP floor is the target ($php_target); keeping Drupal 10 declares composer require.php \">=$php_target\".")
    warnings+=("Drupal 10's own minimum is PHP 8.1, but this port targets PHP $php_target. require.php \">=$php_target\" blocks D10 sites below PHP $php_target at install time (composer) rather than fataling at runtime. If you do not need the D10 transition window, drop to '^11'.")
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
    --argjson bc_break "$([[ "$bc_break" == "1" ]] && echo true || echo false)" \
    --argjson rationale "$(arr_to_json ${rationale[@]+"${rationale[@]}"})" \
    --argjson warnings "$(arr_to_json ${warnings[@]+"${warnings[@]}"})" \
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
      rationale: $rationale,
      warnings: $warnings
    }'
}

# ---------------------------------------------------------------------------
# Interaction (safe confirmation in non-TTY contexts)
# ---------------------------------------------------------------------------
# confirm <question> [default_yes:0/1] -> 0 if the user accepts.
# Without a TTY: uses DRUPILOT_ASSUME_YES or the default; never blocks forever.
confirm() {
  local q="$1" default_yes="${2:-0}"
  if [[ "${DRUPILOT_ASSUME_YES:-}" == "1" ]]; then return 0; fi
  if [[ ! -r /dev/tty ]]; then
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
