#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/ddev.sh
# DDEV and the test-bed: project status, the toolchain runner, Composer
# inside the container, add-ons, and the ownership marker clean.sh honors.
#
# Part of the shared library: scripts/lib/common.sh sources it with the other
# domain libs (never source it alone); see common.sh for the conventions.
# =============================================================================

# docker_daemon_up -> 0 if the Docker daemon responds (not just the binary)
docker_daemon_up() {
  have_cmd docker || return 1
  docker info </dev/null >/dev/null 2>&1
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
