#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/cache.sh
# Runtime caches: the digests checkout, the cached base core, the
# copy-on-write tree copy and the staged PHP runtime.
#
# Part of the shared library: scripts/lib/common.sh sources it with the other
# domain libs (never source it alone); see common.sh for the conventions.
# =============================================================================

cache_dir() { local d; d="$(data_dir)/cache"; mkdir -p "$d" 2>/dev/null || true; printf '%s' "$d"; }

# digests_cache_dir -> cache for the dbuytaert/drupal-digests repo (cloned at runtime).
digests_cache_dir() { printf '%s/drupal-digests' "$(cache_dir)"; }

# digests_rector_version ROOT -> the palantirnet/drupal-rector version ROOT's
# composer.lock installs (packages or packages-dev), or nothing.
digests_rector_version() {
  local root="${1:-}"
  [[ -f "$root/composer.lock" ]] && have_cmd jq || return 0
  jq -r '[(.packages // [])[], (.["packages-dev"] // [])[]] | map(select(.name == "palantirnet/drupal-rector"))
         | .[0].version // empty' "$root/composer.lock" 2> /dev/null || true
  return 0
}

# digests_implemented_yml ROOT -> the path of drupal-rector's
# docs/implemented-digests.yml at the version ROOT installs (03-R17: the
# digests rules drupal-rector already implements). The package's docs/ is
# export-ignored, so the file is fetched once from GitHub at that tag and
# cached under <cache>/drupal-rector/<version>/; its sha256 and version are
# frozen in ROOT's lock (.digests.implemented_yml_sha256 / _ref). A cached
# copy whose sha256 is not the one frozen for this version is fetched again;
# still not it, or nothing cached and nothing to fetch it from (offline):
# nothing, return 1.
digests_implemented_yml() {
  local root="${1:-}" v ref d f url want="" fref got
  v="$(digests_rector_version "$root")"
  [[ -n "$v" ]] || return 1
  ref="${v#v}"; case "$ref" in dev-*) ref="${ref#dev-}";; esac
  d="$(cache_dir)/drupal-rector/$ref"; f="$d/implemented-digests.yml"
  fref="$(DRUPILOT_PROJECT_DIR="$root" lock_get .digests.implemented_yml_ref "")"
  [[ "$fref" == "$ref" ]] && want="$(DRUPILOT_PROJECT_DIR="$root" lock_get .digests.implemented_yml_sha256 "")"
  if [[ ! -s "$f" ]] || { [[ -n "$want" ]] && [[ "$(file_hash "$f")" != "$want" ]]; }; then
    mkdir -p "$d" 2> /dev/null || return 1
    url="https://raw.githubusercontent.com/palantirnet/drupal-rector/$ref/docs/implemented-digests.yml"
    if have_cmd curl; then curl -fsSL --max-time 20 "$url" -o "$f.tmp.$$" < /dev/null 2> /dev/null || rm -f "$f.tmp.$$"
    elif have_cmd wget; then wget -q -T 20 -O "$f.tmp.$$" "$url" < /dev/null 2> /dev/null || rm -f "$f.tmp.$$"
    fi
    if [[ -s "$f.tmp.$$" ]]; then mv -f "$f.tmp.$$" "$f"; else rm -f "$f.tmp.$$" 2> /dev/null; fi
  fi
  [[ -s "$f" ]] || return 1
  got="$(file_hash "$f")"
  [[ -z "$want" || "$got" == "$want" ]] || return 1
  if [[ -z "$want" ]]; then
    DRUPILOT_PROJECT_DIR="$root" lock_set .digests.implemented_yml_sha256 "$got" > /dev/null 2>&1 || true
    DRUPILOT_PROJECT_DIR="$root" lock_set .digests.implemented_yml_ref "$ref" > /dev/null 2>&1 || true
  fi
  printf '%s' "$f"
  return 0
}

# digests_rules DIR -> "file<TAB>class<TAB>nid" for each rule DIR/all.php
# loads (its require_once lines) and registers (withRules): the class the
# rule file declares, the drupal.org nid its file name ends with.
digests_rules() {
  local dir="${1:-}" f cls nid reg
  [[ -f "$dir/all.php" ]] || return 0
  reg="$(sed -n 's/.*->withRules(\[\(.*\)\]).*/\1/p' "$dir/all.php" | tr ',' '\n' | sed -e 's/::class//' -e 's/^[[:space:]\\]*//' -e 's/[[:space:]]*$//')"
  sed -n "s/^require_once __DIR__ \. '\/\(rules\/[^']*\)';.*/\1/p" "$dir/all.php" | while IFS= read -r f; do
    [[ -f "$dir/$f" ]] || continue
    cls="$(sed -n 's/^[[:space:]]*\(final[[:space:]]\{1,\}\|abstract[[:space:]]\{1,\}\)\{0,1\}class[[:space:]]\{1,\}\([A-Za-z0-9_]\{1,\}\).*/\2/p' "$dir/$f" | sed -n '1p')"
    [[ -n "$cls" ]] || continue
    printf '%s\n' "$reg" | grep_q -Fx -- "$cls" || continue
    nid="$(printf '%s' "$f" | sed -n 's/.*-\([0-9]\{1,\}\)\.php$/\1/p')"
    printf '%s\t%s\t%s\n' "$f" "$cls" "$nid"
  done
  return 0
}

# digests_implemented_skips YML ROOT -> "nid<TAB>status" for each entry of
# implemented-digests.yml a digests rule of that nid must be skipped for:
# config-only, or implemented by classes that all exist in the drupal-rector
# ROOT installs (vendor/palantirnet/drupal-rector/src; the file also marks
# implemented some rules only an open pull request has). Line-oriented: the
# file's own layout (two-space nid keys, four-space fields, "class:" a name or
# a "- name" list).
digests_implemented_skips() {
  local yml="${1:-}" root="${2:-}" src nid st cls c all
  [[ -f "$yml" ]] || return 0
  src="$root/vendor/palantirnet/drupal-rector/src"
  awk '
    /^  [^ ]/ { if (nid != "") print nid "\t" st "\t" cls; nid = $1; gsub(/[^0-9]/, "", nid); st = ""; cls = ""; inl = 0; next }
    nid == "" { next }
    /^    status:/ { st = $2; gsub(/[^a-z-]/, "", st); inl = 0; next }
    /^    class:[ \t]*$/ { inl = 1; next }
    /^    class:/ { c = $2; gsub(/[^A-Za-z0-9_]/, "", c); cls = c; inl = 0; next }
    inl && /^      - / { c = $2; gsub(/[^A-Za-z0-9_]/, "", c); cls = (cls == "" ? c : cls " " c); next }
    /^    [a-z_]+:/ { inl = 0 }
    END { if (nid != "") print nid "\t" st "\t" cls }' "$yml" | while IFS="$(printf '\t')" read -r nid st cls; do
    case "$st" in
      config-only) printf '%s\tconfig-only\n' "$nid";;
      implemented)
        [[ -n "$cls" && -d "$src" ]] || continue
        all=1
        for c in $cls; do [[ -n "$(grep -rlE "class[[:space:]]+$c([^A-Za-z0-9_]|$)" "$src" 2> /dev/null)" ]] || { all=0; break; }; done
        if [[ "$all" == "1" ]]; then printf '%s\timplemented\n' "$nid"; fi;;
    esac
  done
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
  if cp --help 2>&1 | grep_q -- '--reflink'; then
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

# stage_runtime <root> -> stage the plugin's PHP helpers (scripts/php/*.php)
# into <root>/.drupilot/runtime/ (AR-23, 05-R5), where the bed's container can
# run them: $(drupal_runner) php .drupilot/runtime/<helper>.php. Each copy is
# verified by its sha256 (a missing or tampered one is copied again through a
# temporary file; a helper the plugin no longer ships is removed), and the
# hash of the set is kept in the root's lock as .runtime_hash. .drupilot/ keeps
# itself out of git (a ".gitignore" of "*" inside it, as project_artifacts_dir
# writes; also in drupilot's managed ignore block) and make-patch.sh excludes
# it. Without a sha256 tool each copy is compared byte for byte (cmp) and no
# .runtime_hash is written. Prints ".drupilot/runtime" (relative to the
# root); returns 1 when it cannot stage or verify.
stage_runtime() {
  local root="${1:-}" src dst f n want lines="" rh
  [[ -n "$root" && -d "$root" ]] || return 1
  src="$(plugin_root)/scripts/php"; dst="$root/.drupilot/runtime"
  mkdir -p "$dst" 2> /dev/null || return 1
  [[ -f "$root/.drupilot/.gitignore" ]] || printf '*\n' > "$root/.drupilot/.gitignore" 2> /dev/null || true
  for f in "$src"/*.php; do
    [[ -f "$f" ]] || continue
    n="$(basename "$f")"; want="$(sha256_hex < "$f")"
    if ! _runtime_copy_ok "$f" "$dst/$n" "$want"; then
      { cp "$f" "$dst/.$n.$$" && mv -f "$dst/.$n.$$" "$dst/$n"; } 2> /dev/null || { rm -f "$dst/.$n.$$" 2> /dev/null; return 1; }
      _runtime_copy_ok "$f" "$dst/$n" "$want" || return 1
    fi
    lines="$lines$n $want
"
  done
  for f in "$dst"/*.php; do
    [[ -f "$f" && ! -f "$src/$(basename "$f")" ]] && rm -f "$f" 2> /dev/null
  done
  rh="$(printf '%s' "$lines" | LC_ALL=C sort | json_hash)"
  if [[ -n "$rh" && "$(DRUPILOT_PROJECT_DIR="$root" lock_get .runtime_hash "")" != "$rh" ]]; then
    DRUPILOT_PROJECT_DIR="$root" lock_set .runtime_hash "$rh" > /dev/null 2>&1 || true
  fi
  printf '.drupilot/runtime'
  return 0
}

# _runtime_copy_ok <source> <copy> <source sha256 or ""> -> 0 when the staged
# copy is the source: by sha256, else (no hasher) byte for byte.
_runtime_copy_ok() {
  [[ -f "$2" ]] || return 1
  if [[ -n "$3" ]]; then [[ "$(sha256_hex < "$2")" == "$3" ]]; else cmp -s "$1" "$2"; fi
}
