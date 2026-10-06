#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/clean.sh
# Free the disk and the Docker resources a port's test-bed holds, WITHOUT losing
# the work: the reports (.drupilot/), the hidden state (assess.json, the
# lockfile, state.json), the local patches and the subject's git checkout with
# all its branches are always kept. Destructive, so it is default-safe: it
# prints the plan and acts only after an interactive "yes" or --yes
# (DRUPILOT_ASSUME_YES and DRUPILOT_AUTONOMOUS never imply it); without a
# terminal and without --yes it only prints the plan.
#
# Levels (each includes the previous one):
#   ddev       `ddev delete -Oy`: the DDEV containers, volumes and database go
#              (no snapshot); the code and .ddev/ stay, so `ddev start` or
#              /drupilot-setup recreates the project.
#   vendor     (default) + every Composer-installed tree: vendor/ and the
#              composer installer-paths (core, contrib modules/themes/profiles,
#              libraries, recipes, drush contrib) — never a */custom path.
#              /drupilot-setup restores them from composer.lock
#              (ddev-up.sh runs `ddev composer install` when vendor/ is gone).
#   workspace  + the whole test-bed directory. Each placed subject is first put
#              back: a 'move'd checkout is moved back to the path it came from
#              (recorded by place-subject.sh; refused when that path exists and
#              is not empty), a 'symlink' is only unlinked (its target is never
#              followed), and a 'copy' is discarded only when it holds nothing
#              the origin lacks (same git HEAD, clean tree) or with
#              --discard-copies. The test-bed's .drupilot/ reports are copied to
#              each origin's .drupilot/ (self-gitignored; the cores/ cache of
#              reference cores is not copied) first — or, with no
#              origin to copy them to, to the root's hidden state dir
#              (<state>/reports-<UTC time>) — and a discarded copy's *.patch
#              files go to .drupilot/patches/. "Holds nothing the origin
#              lacks" means: the same HEAD, a clean tree, and every local
#              branch, tag and stash on a commit the origin has.
#
# Ownership: vendor and workspace act ONLY on a drupilot test-bed, i.e. a root
# whose .drupilot.json carries the drupilot_testbed marker (ddev-up.sh writes it
# when it builds the root) or, for a test-bed built before the marker existed,
# pins DRUPILOT_WORKSPACE_DIR to itself under the default '<name>-d11[-N]' name
# (common.sh testbed_kind: 'legacy'). Any other root (the developer's own site)
# is refused, except `--level ddev --foreign-ok`, which still asks a second time
# because it destroys that site's database. A 'legacy' root is only recognized
# by its name, which an existing site chosen with --workspace can share: it
# needs --foreign-ok for ddev/vendor (asked a second time too) and is never
# removed at the workspace level. A workspace with its own .git, or with a
# module/theme under */custom that has no recorded origin, is refused.
#
# Afterwards every module of the root gets `.environment = {status: "removed",
# level, at}` in its state.json, so next-step.sh recommends /drupilot-setup
# until ddev-up.sh / place-subject.sh rebuild it, and its digests verdicts
# (digests-decisions.json, scripts/analysis/digests-decisions.sh) are reset.
#
# Usage:
#   clean.sh [--subject DIR | --root DIR | --all [--scan DIR]...]
#            [--level ddev|vendor|workspace] [--core-cache]
#            [--dry-run] [--yes] [--foreign-ok] [--discard-copies] [--no-ddev]
#            [--json] [-h|--help]
#
#   --subject DIR     the module/theme (default: the current directory); its
#                     Drupal root is cleaned. A loose checkout resolves to its
#                     test-bed (resolve-workspace.sh).
#   --root DIR        the Drupal root to clean.
#   --all             every Drupal root drupilot has state for (state.json
#                     records), plus every test-bed found one or two levels
#                     under each --scan DIR. Roots that are not drupilot
#                     test-beds are skipped (never refused-and-acted-on).
#   --level L         ddev | vendor | workspace (default: vendor).
#   --core-cache      also remove the cached base cores (ddev-up.sh's
#                     DRUPILOT_CORE_CACHE store). Alone (no --subject, --root,
#                     --all or --level), only the cache is cleaned.
#   --dry-run         print the plan, change nothing.
#   --yes             act without asking (still refuses what is not allowed).
#   --foreign-ok      allow --level ddev on a root that is not a drupilot
#                     test-bed, and --level ddev|vendor on a 'legacy' one
#                     (recognized only by its name).
#   --discard-copies  workspace: remove a 'copy' placement even when it holds
#                     changes the origin does not have (its patches are kept).
#   --no-ddev         do not run `ddev delete` (e.g. Docker is down): the
#                     project's containers/volumes are left to `ddev delete`
#                     later.
#   --json            print the result as JSON on STDOUT.
#
# Output: the plan and progress on STDERR; with --json, on STDOUT:
#   {dry_run, executed, level, roots: [{root, kind, ddev_project, status,
#    reason, actions: [{op, path, detail, status}], subjects: [{machine_name,
#    path, placement, origin, action}], size_kb, freed_kb}],
#    core_cache: {entries: [...], remove: bool, status} | null}
#   status: planned | done | refused | skipped | failed. freed_kb is `du -sk`
#   before minus after (logical size: a copy-on-write tree frees less).
#
# Exit codes: 0 done, or plan only · 1 usage error · 3 a root was refused or an
# action failed (the other roots are still processed).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
ROOT_ARG=""
ALL=0
SCAN_DIRS=()
LEVEL=""
CORE_CACHE=0
DRY=0
YES=0
FOREIGN_OK=0
DISCARD_COPIES=0
NO_DDEV=0
AS_JSON=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --root) ROOT_ARG="${2:-}"; shift 2 || die "--root needs a value" 1;;
    --root=*) ROOT_ARG="${1#*=}"; shift;;
    --all) ALL=1; shift;;
    --scan) SCAN_DIRS+=("${2:-}"); shift 2 || die "--scan needs a value" 1;;
    --scan=*) SCAN_DIRS+=("${1#*=}"); shift;;
    --level) LEVEL="${2:-}"; shift 2 || die "--level needs a value" 1;;
    --level=*) LEVEL="${1#*=}"; shift;;
    --core-cache) CORE_CACHE=1; shift;;
    --dry-run) DRY=1; shift;;
    --yes|-y) YES=1; shift;;
    --foreign-ok) FOREIGN_OK=1; shift;;
    --discard-copies) DISCARD_COPIES=1; shift;;
    --no-ddev) NO_DDEV=1; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) print_usage "$0"; exit 0;;
    *) print_usage "$0" >&2; die "Unknown argument: $1" 1;;
  esac
done

have_cmd jq || die "jq is required for clean.sh." 1

CACHE_ONLY=0
if [[ "$CORE_CACHE" == "1" && -z "$SUBJECT" && -z "$ROOT_ARG" && "$ALL" == "0" && -z "$LEVEL" ]]; then
  CACHE_ONLY=1
fi
[[ -n "$LEVEL" ]] || LEVEL="vendor"
case "$LEVEL" in
  ddev|vendor|workspace) : ;;
  *) die "--level must be ddev, vendor or workspace (got '$LEVEL')." 1;;
esac
[[ -n "$SUBJECT" && -n "$ROOT_ARG" ]] && die "Give --subject or --root, not both." 1
[[ "$ALL" == "1" && ( -n "$SUBJECT" || -n "$ROOT_ARG" ) ]] && die "--all cannot be combined with --subject/--root." 1
[[ "${#SCAN_DIRS[@]}" -gt 0 && "$ALL" == "0" ]] && die "--scan only works with --all." 1

TAB="$(printf '\t')"

# --- Helpers ----------------------------------------------------------------
abs_dir() { ( cd "$1" 2>/dev/null && pwd ) || true; }

# size_kb <path> -> `du -sk` of the path (0 when it is gone).
size_kb() {
  local s=""
  [[ -e "$1" ]] && s="$(du -sk "$1" 2>/dev/null | awk '{print $1}' || true)"
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  printf '%s' "$s"
}

# root_docroot <root> -> the docroot (from .ddev/config.yaml, default web).
root_docroot() {
  local d=""
  if [[ -f "$1/.ddev/config.yaml" ]]; then
    d="$(sed -n 's/^docroot:[[:space:]]*//p' "$1/.ddev/config.yaml" 2>/dev/null | sed -n '1p' | tr -d "\"' " || true)"
  fi
  [[ -n "$d" ]] || d="web"
  printf '%s' "$d"
}

# ddev_name <root> -> the DDEV project name, or empty.
ddev_name() {
  [[ -f "$1/.ddev/config.yaml" ]] || return 0
  sed -n 's/^name:[[:space:]]*//p' "$1/.ddev/config.yaml" 2>/dev/null | sed -n '1p' | tr -d "\"' " || true
  return 0
}

# safe_rel <rel> -> 0 when <rel> is a plain path inside the root.
safe_rel() {
  local r="$1"
  [[ -n "$r" && "$r" != "." && "$r" != "/" && "$r" != /* ]] || return 1
  case "/$r/" in */../*|*/./*) return 1;; esac
  return 0
}

# composer_paths <root> -> the composer-managed trees, one relative path per
# line: vendor-dir plus each installer-paths key cut before its {$...} part.
# Anything named or containing 'custom' is never listed.
composer_paths() {
  local root="$1" docroot p
  docroot="$(root_docroot "$root")"
  {
    jq -r '.config["vendor-dir"] // "vendor"' "$root/composer.json" 2>/dev/null || printf 'vendor\n'
    jq -r '.extra["installer-paths"] // {} | keys[]' "$root/composer.json" 2>/dev/null || true
  } | while IFS= read -r p; do
        p="${p%%\{\$*}"; p="${p%/}"
        safe_rel "$p" || continue
        case "/$p/" in */custom/*) continue;; esac
        [[ "$p" == "$docroot" ]] && continue
        [[ -e "$root/$p/custom" ]] && continue
        [[ -e "$root/$p" || -L "$root/$p" ]] || continue
        printf '%s\n' "$p"
      done | awk '!seen[$0]++'
  return 0
}

# placed_subjects <root> -> one line per module/theme/profile directory (or
# symlink) under <docroot>/{modules,themes,profiles}/custom: abs path.
placed_subjects() {
  local root="$1" docroot t e
  docroot="$(root_docroot "$root")"
  for t in modules themes profiles; do
    for e in "$root/$docroot/$t/custom"/*; do
      [[ -e "$e" || -L "$e" ]] || continue
      if [[ -L "$e" ]] || is_drupal_extension_dir "$e"; then printf '%s\n' "$e"; fi
    done
  done
  return 0
}

# origin_record <root> <machine> -> "origin<TAB>placement" from the test-bed
# marker, else from origin-hygiene's baseline (test-beds placed before the
# marker existed). Empty when unknown.
origin_record() {
  local root="$1" mn="$2" o="" pl="" b
  if [[ -r "$root/.drupilot.json" ]]; then
    o="$(jq -r --arg m "$mn" '.drupilot_testbed.subjects[$m].origin // empty' "$root/.drupilot.json" 2>/dev/null || true)"
    pl="$(jq -r --arg m "$mn" '.drupilot_testbed.subjects[$m].placement // empty' "$root/.drupilot.json" 2>/dev/null || true)"
  fi
  if [[ -z "$o" ]]; then
    b="$(origin_baseline_find "$root" "$mn")"
    if [[ -n "$b" && -r "$b" ]]; then
      o="$(jq -r '.source // empty' "$b" 2>/dev/null || true)"
      pl="$(jq -r '.placement // empty' "$b" 2>/dev/null || true)"
    fi
  fi
  [[ -n "$o" ]] && printf '%s\t%s\n' "$o" "$pl"
  return 0
}

# rescue_dir <origin> -> where the reports and patches of a module whose origin
# is <origin> are kept: <origin>/.drupilot, unless the origin belongs to a larger
# repository (a module of a monorepo clone or of a folder of modules), which is
# never written into: then the hidden state dir of that origin (<state>/artifacts,
# where its outputs before setup go too).
rescue_dir() {
  local o="$1"
  if find_project_root_nocore "$o" >/dev/null 2>&1 || git_enclosing_repo "$o" >/dev/null 2>&1; then
    printf '%s/artifacts' "$(project_state_path "$o")"
  else
    printf '%s/.drupilot' "$o"
  fi
  return 0
}

# copy_is_redundant <copy> <origin> -> 0 when discarding the copy loses
# nothing: both are git checkouts on the same commit, the copy is clean, and
# every local branch, tag and stash of the copy points at a commit the origin
# already has (a copy has its own .git: an issue branch, a commit not pushed
# yet or a stash made in the test-bed lives only there).
# A copy seeded with a git baseline (git_seed_baseline: the origin is a
# sub-directory of a larger repository) is redundant when it is still exactly
# that baseline: HEAD, every branch and tag on the baseline commit, no stash,
# and a clean tree.
copy_is_redundant() {
  local c="$1" o="$2" hc ho sha bl
  git -C "$c" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$o" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  hc="$(git -C "$c" rev-parse HEAD 2>/dev/null || true)"
  bl="$(git -C "$c" rev-parse --verify -q "$DRUPILOT_BASELINE_REF" 2>/dev/null || true)"
  if [[ -n "$bl" ]]; then
    [[ -n "$hc" && "$hc" == "$bl" ]] || return 1
  else
    ho="$(git -C "$o" rev-parse HEAD 2>/dev/null || true)"
    [[ -n "$hc" && "$hc" == "$ho" ]] || return 1
  fi
  [[ -z "$(git -C "$c" status --porcelain --untracked-files=normal -- . 2>/dev/null | grep -v -E '(^|/| )\.drupilot(/|\.json|$)' | sed -n '1p')" ]] || return 1
  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    if [[ -n "$bl" ]]; then
      [[ "$sha" == "$bl" ]] || return 1
    else
      git -C "$o" cat-file -e "${sha}^{commit}" 2>/dev/null || return 1
    fi
  done < <(git -C "$c" for-each-ref --format='%(objectname)' refs/heads refs/tags refs/stash 2>/dev/null)
  return 0
}

# --- Resolve the roots --------------------------------------------------------
ROOTS=()
add_root() {
  local r="$1" x
  [[ -n "$r" && -d "$r" ]] || return 0
  r="$(abs_dir "$r")"
  [[ -n "$r" ]] || return 0
  for x in ${ROOTS[@]+"${ROOTS[@]}"}; do [[ "$x" == "$r" ]] && return 0; done
  ROOTS+=("$r")
  return 0
}

if [[ "$CACHE_ONLY" == "1" ]]; then
  :
elif [[ "$ALL" == "1" ]]; then
  _sd="$(data_dir_path)/state"
  if [[ -d "$_sd" ]]; then
    for _f in "$_sd"/*/state.json; do
      [[ -r "$_f" ]] || continue
      add_root "$(jq -r '.drupal_root // empty' "$_f" 2>/dev/null || true)"
    done
  fi
  for _d in ${SCAN_DIRS[@]+"${SCAN_DIRS[@]}"}; do
    [[ -d "$_d" ]] || { log_warn "--scan: not a directory: $_d"; continue; }
    for _c in "$_d" "$_d"/* "$_d"/*/*; do
      [[ -d "$_c" && -r "$_c/.drupilot.json" ]] || continue
      [[ "$(testbed_kind "$_c")" != "none" ]] && add_root "$_c"
    done
  done
elif [[ -n "$ROOT_ARG" ]]; then
  _r="$(abs_dir "$ROOT_ARG")"
  [[ -n "$_r" ]] || die "Root directory not found: '$ROOT_ARG'." 1
  [[ -f "$_r/composer.json" || -f "$_r/.ddev/config.yaml" ]] \
    || die "'$_r' is not a Drupal/DDEV project root (no composer.json or .ddev/config.yaml)." 1
  add_root "$_r"
else
  _s="${SUBJECT:-$PWD}"
  [[ -d "$_s" ]] || die "Subject directory not found: '$_s'." 1
  _r="$(find_drupal_root "$_s" 2>/dev/null || true)"
  if [[ -z "$_r" ]] && is_drupal_extension_dir "$_s"; then
    _r="$(bash "$(plugin_root)/scripts/env/resolve-workspace.sh" --subject "$_s" --json 2>/dev/null \
      | jq -r 'select(.drupal_root_exists == true) | .drupal_root // empty' 2>/dev/null || true)"
  fi
  [[ -n "$_r" ]] || die "No Drupal root found for '$_s' (nothing to clean). Use --root DIR or --all." 1
  add_root "$_r"
fi

# --- Plan ------------------------------------------------------------------
# Per root: P_STATUS/P_REASON, the action lines "op<TAB>arg1<TAB>arg2" in
# execution order, and the subjects as JSON lines. Stored as parallel arrays.
R_KIND=(); R_STATUS=(); R_REASON=(); R_ACTIONS=(); R_SUBJECTS=(); R_SIZE=(); R_DDEV=()

plan_root() {
  local root="$1" kind status="planned" reason="" actions="" subjects="" ddev name
  local s mn rec origin pl act docroot p
  kind="$(testbed_kind "$root")"
  name="$(ddev_name "$root")"
  ddev="false"; [[ -f "$root/.ddev/config.yaml" ]] && ddev="true"

  if [[ "$kind" == "none" ]]; then
    if [[ "$ALL" == "1" ]]; then
      status="skipped"; reason="not a drupilot test-bed (only test-beds are cleaned by --all)"
    elif [[ "$LEVEL" != "ddev" ]]; then
      status="refused"; reason="not a drupilot test-bed (no drupilot_testbed marker in .drupilot.json): only '--level ddev --foreign-ok' is allowed here"
    elif [[ "$FOREIGN_OK" != "1" ]]; then
      status="refused"; reason="not a drupilot test-bed: deleting its DDEV project destroys its database; pass --foreign-ok to allow '--level ddev'"
    fi
  fi

  # A 'legacy' test-bed is recognized by its name and workspace pin only, which
  # an existing site chosen with --workspace can also have: its database and
  # Composer trees go only with --foreign-ok, and never the whole workspace.
  if [[ "$kind" == "legacy" ]]; then
    if [[ "$LEVEL" == "workspace" ]]; then
      status="refused"; reason="recognized as a test-bed only by its '<name>-d11' name and workspace pin (built before the drupilot_testbed marker, or an existing site chosen with --workspace): never removed as a whole; use --level vendor --foreign-ok, or remove it by hand"
    elif [[ "$FOREIGN_OK" != "1" ]]; then
      if [[ "$ALL" == "1" ]]; then
        status="skipped"; reason="recognized as a test-bed only by its name (no drupilot_testbed marker): pass --foreign-ok to include it"
      else
        status="refused"; reason="recognized as a test-bed only by its '<name>-d11' name and workspace pin (no drupilot_testbed marker), which an existing site chosen with --workspace also has: pass --foreign-ok to delete its DDEV project (database) and Composer trees"
      fi
    fi
  fi

  if [[ "$status" == "planned" ]]; then
    # 1. DDEV project (every level).
    if [[ "$ddev" == "true" ]]; then
      if [[ "$NO_DDEV" == "1" ]]; then
        :
      elif ! have_cmd ddev; then
        log_warn "$root: ddev is not installed — its DDEV project (if any) is not removed."
      else
        actions="${actions}ddev-delete${TAB}${root}${TAB}${name}"$'\n'
      fi
    fi
    # 2. Composer-managed trees (vendor, workspace removes them with the root).
    if [[ "$LEVEL" == "vendor" ]]; then
      if [[ -f "$root/composer.json" ]]; then
        while IFS= read -r p; do
          [[ -n "$p" ]] || continue
          actions="${actions}rm${TAB}${root}/${p}${TAB}composer-managed"$'\n'
        done < <(composer_paths "$root")
      fi
    fi
    # 3. Workspace: put every placed subject back, then remove the root.
    if [[ "$LEVEL" == "workspace" ]]; then
      if [[ -e "$root/.git" ]]; then
        status="refused"; reason="the workspace is a git repository of its own ($root/.git): remove it by hand if that is intended"
      fi
      local rescue_to=""
      while IFS= read -r s; do
        [[ -n "$s" && "$status" == "planned" ]] || continue
        mn="$(basename "$s")"
        rec="$(origin_record "$root" "$mn")"
        origin="${rec%%"$TAB"*}"; pl="${rec#*"$TAB"}"; [[ -n "$rec" ]] || { origin=""; pl=""; }
        if [[ -L "$s" ]]; then
          act="unlink"; [[ -n "$origin" ]] || origin="$(cd "$s" 2>/dev/null && pwd -P || true)"
          actions="${actions}unlink${TAB}${s}${TAB}"$'\n'
          [[ -n "$origin" && -d "$origin" ]] && rescue_to="${rescue_to}$(rescue_dir "$origin")"$'\n'
        elif [[ -z "$origin" ]]; then
          act="refuse"; status="refused"
          reason="$s has no recorded origin (it was not placed by drupilot, or before its records existed): move it out of the workspace first"
        elif [[ "$pl" == "copy" ]]; then
          if [[ ! -d "$origin" ]]; then
            act="refuse"; status="refused"; reason="$s is a copy, but its origin $origin is gone: move the copy out of the workspace first"
          elif copy_is_redundant "$s" "$origin" || [[ "$DISCARD_COPIES" == "1" ]]; then
            act="discard-copy"
            actions="${actions}rescue-patches${TAB}${s}${TAB}$(rescue_dir "$origin")/patches"$'\n'
            actions="${actions}rm${TAB}${s}${TAB}discarded copy"$'\n'
            rescue_to="${rescue_to}$(rescue_dir "$origin")"$'\n'
          else
            act="refuse"; status="refused"
            reason="$s is a copy with changes its origin $origin does not have (another commit, uncommitted work, or a branch, tag or stash only the copy holds): bring them over, or pass --discard-copies (its *.patch files are still kept)"
          fi
        else
          # move (or an unrecorded placement with a known origin): move it back.
          if [[ -e "$origin" || -L "$origin" ]] && [[ -n "$(ls -A "$origin" 2>/dev/null | sed -n '1p')" || ! -d "$origin" ]]; then
            act="refuse"; status="refused"
            reason="cannot move $mn back: $origin already exists and is not empty"
          else
            act="restore"
            actions="${actions}restore${TAB}${s}${TAB}${origin}"$'\n'
            rescue_to="${rescue_to}${origin}/.drupilot"$'\n'
          fi
        fi
        subjects="${subjects}$(jq -nc --arg m "$mn" --arg p "$s" --arg pl "${pl:-}" --arg o "${origin:-}" --arg a "$act" \
          '{machine_name: $m, path: $p, placement: (if $pl == "" then null else $pl end),
            origin: (if $o == "" then null else $o end), action: $a}')"$'\n'
      done < <(placed_subjects "$root")
      if [[ "$status" == "planned" ]]; then
        if [[ -d "$root/.drupilot" ]]; then
          while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            actions="${actions}rescue-reports${TAB}${root}/.drupilot${TAB}${p}"$'\n'
          done < <(printf '%s' "$rescue_to" | awk 'NF && !seen[$0]++')
          if [[ -z "$rescue_to" ]]; then
            # No origin to copy them to: keep them in the root's hidden state
            # dir, which a clean never removes.
            p="$(project_state_path "$root")/reports-$(date -u +%Y%m%dT%H%M%SZ)"
            log_info "$root: no subject origin to copy its .drupilot/ reports to — they are kept in $p."
            actions="${actions}rescue-reports${TAB}${root}/.drupilot${TAB}${p}"$'\n'
          fi
        fi
        actions="${actions}rm-root${TAB}${root}${TAB}"$'\n'
      fi
    fi
  fi

  # A refused or skipped root runs nothing: show no action for it.
  [[ "$status" == "planned" ]] || actions=""
  R_KIND+=("$kind"); R_STATUS+=("$status"); R_REASON+=("$reason")
  R_ACTIONS+=("$actions"); R_SUBJECTS+=("$subjects"); R_DDEV+=("$name")
  R_SIZE+=("$( [[ "$status" == "planned" ]] && size_kb "$root" || printf 0 )")
  return 0
}

for _r in ${ROOTS[@]+"${ROOTS[@]}"}; do plan_root "$_r"; done
# IDX: the root indexes (empty-safe under `set -u` on bash 3.2).
IDX=""
if [[ "${#ROOTS[@]}" -gt 0 ]]; then IDX="$(seq 0 $(( ${#ROOTS[@]} - 1 )) | tr '\n' ' ')"; fi

CACHE_ENTRIES="$(core_cache_entries | jq -s -c '.' 2>/dev/null || printf '[]')"

# --- Show the plan -----------------------------------------------------------
op_label() {
  case "$1" in
    ddev-delete) printf 'delete the DDEV project %s (containers, volumes, database; no snapshot)' "${3:-}";;
    rm) printf 'remove %s%s' "$2" "$([[ -n "${3:-}" ]] && printf ' (%s)' "$3")";;
    unlink) printf 'remove the symlink %s (its target is kept)' "$2";;
    restore) printf 'move %s back to %s' "$2" "$3";;
    rescue-reports) printf 'copy the reports %s/ to %s/' "$2" "$3";;
    rescue-patches) printf 'keep the *.patch files of %s in %s/' "$2" "$3";;
    rm-root) printf 'remove the workspace %s' "$2";;
    *) printf '%s %s %s' "$1" "$2" "$3";;
  esac
}
if [[ "$CACHE_ONLY" == "1" ]]; then log_step "drupilot clean — cached base cores only"; else log_step "drupilot clean — level: $LEVEL"; fi
ANY_PLANNED=0
for i in $IDX; do
  log_plain "$(printf '%s  [%s, %s]' "${ROOTS[i]}" "${R_KIND[i]}" "${R_STATUS[i]}")"
  [[ -n "${R_REASON[i]}" ]] && log_plain "    reason: ${R_REASON[i]}"
  while IFS="$TAB" read -r _op _a _b; do
    [[ -n "$_op" ]] || continue
    log_plain "    - $(op_label "$_op" "$_a" "$_b")"
  done <<< "${R_ACTIONS[i]}"
  [[ "${R_STATUS[i]}" == "planned" ]] && ANY_PLANNED=1
done
if [[ "${#ROOTS[@]}" -eq 0 && "$CACHE_ONLY" != "1" ]]; then
  log_info "No Drupal root to clean."
fi
CACHE_N="$(printf '%s' "$CACHE_ENTRIES" | jq 'length' 2>/dev/null || echo 0)"
if [[ "$CORE_CACHE" == "1" ]]; then
  if [[ "$CACHE_N" -gt 0 ]]; then
    log_plain "$(core_cache_dir)  [cached base cores: $CACHE_N, $(size_kb "$(core_cache_dir)") KB]"
    log_plain "    - remove every cached base core (the next setup runs composer create-project again)"
    ANY_PLANNED=1
  else
    log_info "No cached base core to remove."
  fi
fi
log_plain "Always kept: the hidden state (lockfile, assess.json, state.json; the digests verdicts are reset), the subject's git checkout and branches, .drupilot/ reports, local patches."

# --- Confirm -------------------------------------------------------------------
EXECUTE=0
if [[ "$DRY" == "1" ]]; then
  log_info "Dry run — nothing was changed."
elif [[ "$ANY_PLANNED" == "0" ]]; then
  :
elif [[ "$YES" == "1" ]]; then
  EXECUTE=1
elif tty_readable; then
  if DRUPILOT_ASSUME_YES="" confirm "Proceed with this clean?" 0; then EXECUTE=1; fi
  [[ "$EXECUTE" == "1" ]] || log_info "Cancelled — nothing was changed."
else
  log_info "No terminal to confirm on — nothing was changed. Re-run with --yes to apply this plan."
fi
# A foreign root (only reachable with --level ddev --foreign-ok) asks once more.
if [[ "$EXECUTE" == "1" ]]; then
  for i in $IDX; do
    [[ "${R_KIND[i]}" != "marker" && "${R_STATUS[i]}" == "planned" ]] || continue
    if [[ "$YES" == "1" ]]; then continue; fi
    if ! DRUPILOT_ASSUME_YES="" confirm "${ROOTS[i]} is NOT a marked drupilot test-bed: delete its DDEV project and its database anyway?" 0; then
      R_STATUS[i]="skipped"; R_REASON[i]="not confirmed (not a drupilot test-bed)"
    fi
  done
fi

# --- Execute -------------------------------------------------------------------
# exec_op <op> <a> <b> -> perform one action; returns 1 on failure.
exec_op() {
  local op="$1" a="$2" b="$3" f
  case "$op" in
    ddev-delete)
      ( cd "$a" && ddev delete -Oy </dev/null >&2 ) || { log_err "'ddev delete -Oy' failed in $a (is Docker running? --no-ddev skips this step)."; return 1; }
      ;;
    rm)
      [[ -n "$a" && "$a" != "/" ]] || return 1
      chmod -R u+w "$a" 2>/dev/null || true
      rm -rf "${a:?}" || return 1
      ;;
    unlink)
      [[ -L "$a" ]] || { log_err "$a is no longer a symlink — not touching it."; return 1; }
      rm -f "$a" || return 1
      ;;
    restore)
      if [[ -d "$b" && ! -L "$b" ]]; then
        [[ -z "$(ls -A "$b" 2>/dev/null | sed -n '1p')" ]] || { log_err "$b is not empty any more — not moving $a there."; return 1; }
        rmdir "$b" || return 1
      elif [[ -e "$b" || -L "$b" ]]; then
        log_err "$b exists — not moving $a there."; return 1
      fi
      mkdir -p "$(dirname "$b")" || return 1
      mv "$a" "$b" || return 1
      if [[ -n "$(git -C "$b" rev-parse --git-dir 2>/dev/null || true)" ]]; then
        git -C "$b" status --porcelain >/dev/null 2>&1 \
          || log_warn "git does not read $b cleanly after the move — check it."
      fi
      ;;
    rescue-reports)
      mkdir -p "$b" || return 1
      # Everything but cores/: the core matrix's reference cores (about 200 MB
      # each) are a rebuildable cache, so rescuing them would only move the
      # disk use the clean is meant to free.
      for e in "$a"/* "$a"/.[!.]* "$a"/..?*; do
        [[ -e "$e" || -L "$e" ]] || continue
        [[ "$(basename "$e")" == "cores" ]] && continue
        cp -R -p "$e" "$b/" || return 1
      done
      [[ -f "$b/.gitignore" ]] || printf '*\n' > "$b/.gitignore"
      ;;
    rescue-patches)
      mkdir -p "$b" || return 1
      [[ -f "$(dirname "$b")/.gitignore" ]] || printf '*\n' > "$(dirname "$b")/.gitignore"
      for f in "$a"/*.patch; do
        [[ -f "$f" ]] || continue
        cp -p "$f" "$b/" || return 1
      done
      ;;
    rm-root)
      # Last line of defence: re-check everything before the only recursive
      # delete of a whole tree.
      [[ -n "$a" && "$a" == /* && "$a" != "/" && "$a" != "${HOME%/}" && -f "$a/.drupilot.json" ]] \
        || { log_err "Refusing to remove '$a' (failed the safety checks)."; return 1; }
      [[ "$(testbed_kind "$a")" == "marker" ]] || { log_err "Refusing to remove '$a': not a marked drupilot test-bed."; return 1; }
      [[ ! -e "$a/.git" ]] || { log_err "Refusing to remove '$a': it has a .git."; return 1; }
      while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        if [[ -L "$f" ]]; then rm -f "$f"; continue; fi
        log_err "Refusing to remove '$a': a module/theme is still inside ($f)."; return 1
      done < <(placed_subjects "$a")
      chmod -R u+w "$a" 2>/dev/null || true
      rm -rf "${a:?}" || return 1
      ;;
    *) log_err "Unknown action '$op'."; return 1;;
  esac
  return 0
}

R_RESULTS=(); R_FREED=()
RC=0
for i in $IDX; do
  res=""; freed=0
  if [[ "$EXECUTE" == "1" && "${R_STATUS[i]}" == "planned" ]]; then
    log_step "Cleaning ${ROOTS[i]}"
    failed=0
    while IFS="$TAB" read -r _op _a _b; do
      [[ -n "$_op" ]] || continue
      if [[ "$failed" == "1" ]]; then
        res="${res}${_op}${TAB}${_a}${TAB}${_b}${TAB}not-run"$'\n'; continue
      fi
      if exec_op "$_op" "$_a" "$_b"; then
        log_ok "$(op_label "$_op" "$_a" "$_b")"
        res="${res}${_op}${TAB}${_a}${TAB}${_b}${TAB}done"$'\n'
      else
        failed=1
        res="${res}${_op}${TAB}${_a}${TAB}${_b}${TAB}failed"$'\n'
      fi
    done <<< "${R_ACTIONS[i]}"
    if [[ "$failed" == "1" ]]; then
      R_STATUS[i]="failed"; R_REASON[i]="an action failed; the actions after it were not run"; RC=3
    else
      R_STATUS[i]="done"
    fi
    freed=$(( ${R_SIZE[i]} - $(size_kb "${ROOTS[i]}") ))
    [[ "$freed" -ge 0 ]] || freed=0
    # Every module of this root: the environment is gone until the next setup,
    # and its digests verdicts are forgotten (05-R6: a clean starts over).
    env_status_record "${ROOTS[i]}" removed "$LEVEL"
    while IFS= read -r _s; do if [[ -n "$_s" ]]; then rm -f "$(digests_decisions_file "$_s")"; fi; done < <(subjects_with_state_under "${ROOTS[i]}")
  else
    while IFS="$TAB" read -r _op _a _b; do
      [[ -n "$_op" ]] || continue
      res="${res}${_op}${TAB}${_a}${TAB}${_b}${TAB}planned"$'\n'
    done <<< "${R_ACTIONS[i]}"
  fi
  [[ "${R_STATUS[i]}" == "refused" ]] && RC=3
  R_RESULTS+=("$res"); R_FREED+=("$freed")
done

CACHE_STATUS="null"
if [[ "$CORE_CACHE" == "1" && "$CACHE_N" -gt 0 ]]; then
  CACHE_STATUS="planned"
  if [[ "$EXECUTE" == "1" ]]; then
    _cd="$(core_cache_dir)"
    chmod -R u+w "$_cd" 2>/dev/null || true
    if [[ -n "$_cd" && "$_cd" == */core-base ]] && rm -rf "${_cd:?}"; then
      CACHE_STATUS="done"; log_ok "Removed the cached base cores ($_cd)."
    else
      CACHE_STATUS="failed"; RC=3
    fi
  fi
fi

[[ "$EXECUTE" == "1" ]] && log_plain "Next: /drupilot-setup rebuilds what was removed (vendor/ from composer.lock, the core version from the lockfile)."

# --- Report --------------------------------------------------------------------
if [[ "$AS_JSON" == "1" ]]; then
  ROOTS_JSON="[]"
  for i in $IDX; do
    acts="$(printf '%s' "${R_RESULTS[i]}" | awk -F '\t' 'NF' | jq -R -s -c '
      split("\n") | map(select(length > 0) | split("\t")
        | {op: .[0], path: .[1], detail: (if (.[2] // "") == "" then null else .[2] end), status: .[3]})')"
    subs="$(printf '%s' "${R_SUBJECTS[i]}" | jq -s -c '.' 2>/dev/null || printf '[]')"
    ROOTS_JSON="$(jq -c --arg root "${ROOTS[i]}" --arg kind "${R_KIND[i]}" --arg dn "${R_DDEV[i]}" \
      --arg st "${R_STATUS[i]}" --arg rs "${R_REASON[i]}" --argjson acts "$acts" --argjson subs "$subs" \
      --arg size "${R_SIZE[i]}" --arg freed "${R_FREED[i]}" \
      '. + [{root: $root, kind: $kind, ddev_project: (if $dn == "" then null else $dn end),
             status: $st, reason: (if $rs == "" then null else $rs end),
             actions: $acts, subjects: $subs, size_kb: ($size | tonumber), freed_kb: ($freed | tonumber)}]' \
      <<< "$ROOTS_JSON")"
  done
  jq -n --argjson dry "$([[ "$DRY" == "1" ]] && echo true || echo false)" \
    --argjson ex "$([[ "$EXECUTE" == "1" ]] && echo true || echo false)" \
    --arg level "$LEVEL" --argjson roots "$ROOTS_JSON" --argjson entries "$CACHE_ENTRIES" \
    --arg cs "$CACHE_STATUS" --argjson cc "$CORE_CACHE" --arg cdir "$(core_cache_dir)" \
    '{dry_run: $dry, executed: $ex, level: $level, roots: $roots,
      core_cache: (if $cc == 1 then {dir: $cdir, entries: $entries, remove: true,
                   status: (if $cs == "null" then "nothing" else $cs end)} else null end)}'
fi
exit "$RC"
