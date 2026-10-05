#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/subject.sh
# The Drupal subject (module / theme) and the Drupal root: detection,
# .info.yml readers, the core module list, the installed core version.
#
# Part of the shared library: scripts/lib/common.sh sources it with the other
# domain libs (never source it alone); see common.sh for the conventions.
# =============================================================================

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
                | select((.value // []) | index("type:drupal-core")) | .key' "$f" 2>/dev/null | sed -n '1p' || true)"
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
      v="$(sed -nE "s/^[[:space:]]*const VERSION = '([^']+)'.*/\1/p" "$f" 2>/dev/null | sed -n '1p')"
      [[ -n "$v" ]] && break
    done
  fi
  printf '%s' "${v#v}"
  return 0
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
    printf '%s' "$(printf '%s\n' "${matches[@]}" | LC_ALL=C sort | sed -n '1p')"
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
  t="$(grep -E '^[[:space:]]*type:' "$f" 2>/dev/null | sed -n '1p' | sed -E 's/^[[:space:]]*type:[[:space:]]*//; s/[[:space:]]*$//' | tr -d '"'"'"'')"
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
  grep -E '^[[:space:]]*core_version_requirement:' "$f" 2>/dev/null | sed -n '1p' \
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

# subject_project_root <subject> -> the Drupal root (DDEV project) the
# subject is ported in, as ddev-up.sh resolves it: the Drupal root above the
# subject; for a LOOSE checkout (copy/symlink origin, or not placed yet) the
# test-bed resolve-workspace.sh targets; for a path that no longer exists (a
# 'move' placement relocated it) the pinned DRUPILOT_WORKSPACE_DIR or the
# '<name>-d<T>' (or 0.9's '<name>-d11') sibling that now holds it. Prints nothing (still 0) when none is
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
      for c in "$(config_get DRUPILOT_WORKSPACE_DIR "")" "$parent/${base}$(target_workspace_suffix)" "$parent/${base}-d11"; do
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

# subject_d7_info_file <dir> -> the Drupal 7 <name>.info of a directory that
# has NO *.info.yml (the D7 track, AR-05): <basename>.info when present, else
# the first *.info in a stable (LC_ALL=C) order. Returns 1 otherwise, and never
# answers for a directory with a *.info.yml, so the .info.yml subjects keep
# their behavior (CC-22).
subject_d7_info_file() {
  local dir="${1:-$PWD}" f first=""
  subject_info_file "$dir" > /dev/null 2>&1 && return 1
  if [[ -f "$dir/${dir##*/}.info" ]]; then printf '%s' "$dir/${dir##*/}.info"; return 0; fi
  first="$(for f in "$dir"/*.info; do [[ -f "$f" ]] && printf '%s\n' "$f"; done | LC_ALL=C sort | sed -n '1p')"
  [[ -n "$first" ]] || return 1
  printf '%s' "$first"
  return 0
}

# info_value_d7 <file> <key> -> the value of a top-level `key = value` line of
# a Drupal 7 .info file (quotes and surrounding spaces stripped); nothing when
# the key is absent.
info_value_d7() {
  [[ -r "${1:-}" && -n "${2:-}" ]] || return 0
  awk -v k="$2" -v q="'" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, k) == 1 {
      rest = substr(line, length(k) + 1)
      if (rest !~ /^[[:space:]]*=/) next
      sub(/^[[:space:]]*=[[:space:]]*/, "", rest); sub(/[[:space:]]+$/, "", rest)
      gsub(/^"|"$/, "", rest); gsub("^" q "|" q "$", "", rest)
      print rest; exit
    }' "$1" 2>/dev/null || true
  return 0
}
