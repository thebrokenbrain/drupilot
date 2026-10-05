#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/cache.sh
# Runtime caches: the digests checkout, the cached base core and the
# copy-on-write tree copy.
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
