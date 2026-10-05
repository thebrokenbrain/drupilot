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
# hash of the set is kept in the root's lock as .runtime_hash. .drupilot/ is
# in drupilot's managed ignore block and make-patch.sh excludes it. Prints
# ".drupilot/runtime" (relative to the root); returns 1 when it cannot stage.
stage_runtime() {
  local root="${1:-}" src dst f n want lines="" rh
  [[ -n "$root" && -d "$root" ]] || return 1
  src="$(plugin_root)/scripts/php"; dst="$root/.drupilot/runtime"
  mkdir -p "$dst" 2> /dev/null || return 1
  for f in "$src"/*.php; do
    [[ -f "$f" ]] || continue
    n="$(basename "$f")"; want="$(sha256_hex < "$f")"
    if [[ ! -f "$dst/$n" || "$(sha256_hex < "$dst/$n")" != "$want" ]]; then
      { cp "$f" "$dst/.$n.$$" && mv -f "$dst/.$n.$$" "$dst/$n"; } 2> /dev/null || { rm -f "$dst/.$n.$$" 2> /dev/null; return 1; }
      [[ "$(sha256_hex < "$dst/$n")" == "$want" ]] || return 1
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
