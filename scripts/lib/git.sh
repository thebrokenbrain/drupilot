#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/git.sh
# git helpers: the enclosing repository, the port base ref, baselines,
# local excludes and the commit hooks a repository runs.
#
# Part of the shared library: scripts/lib/common.sh sources it with the other
# domain libs (never source it alone); see common.sh for the conventions.
# =============================================================================

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
