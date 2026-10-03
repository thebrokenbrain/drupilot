#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/resolve-workspace.sh
# Decide WHERE the Drupal 11 test-bed lives and WHERE the subject module/theme is
# placed inside it — WITHOUT mutating anything (a pure resolver, like
# core-strategy.sh). It is the single source of truth that ddev-up.sh and
# place-subject.sh consult so a LOOSE checkout is never scaffolded on top of.
#
# The problem it solves: when drupilot is pointed at a module/theme that is NOT
# already inside a Drupal site, the old fallback scaffolded Drupal (composer.json,
# web/, vendor/, .ddev/) into the module's own directory, intermixing the two and
# polluting the module's composer.json. Instead, this resolver targets a sibling
# Drupal root and a clean web/{modules,themes,profiles}/custom/<name> destination.
#
# Resolution of the Drupal ROOT (first match wins):
#   1. An existing Drupal root found by walking up from the subject (the module is
#      already inside a site) -> use it, placement 'in-place', loose=false.
#      In place means the site's OWN core: it must already be on Drupal 11
#      (core_version, in_place_ok:false + a warning below 11). For a site still
#      on Drupal 10, an explicit DRUPILOT_WORKSPACE_DIR / --workspace pointing
#      elsewhere makes it a test-bed port instead (step 2).
#      A Composer project root WITHOUT installed core (a monorepo clone: web/core
#      and vendor/ are gitignored) is never such a root, even with a committed
#      .ddev/config.yaml: layout 'project-no-core', handled as loose.
#   2. DRUPILOT_WORKSPACE_DIR (env / .drupilot.json) -> that explicit path.
#   3. A default test-bed OUTSIDE the user's repository:
#      - project-no-core: '<parent>/<project dir>-d11', one test-bed shared by
#        every module of the project (the project root, or the enclosing git
#        repository when the project sits deeper in one);
#      - repo-subdir (the module is a sub-directory of a git repository that is
#        not a Drupal project, e.g. a folder of modules): '<parent of the
#        repository>/<machine_name>-d11';
#      - standalone (the module is its own repository, or not in git): the
#        sibling '<parent-of-subject>/<machine_name>-d11'.
# Placement mode comes from DRUPILOT_PLACEMENT (move|symlink|copy, default move).
# A module that is a sub-directory of a repository (project-no-core,
# repo-subdir) is never moved out of it: 'move' becomes 'copy' (moving it would
# leave a deletion in the user's repository), and place-subject.sh gives the
# copy a git baseline (git_seed_baseline) so its local patch holds only the port.
#
# Usage:
#   resolve-workspace.sh [--subject DIR] [--workspace DIR] [--json] [-h|--help]
#     --subject DIR  Module/theme directory (default: current directory).
#     --workspace DIR  The test-bed root for a loose subject; the same as
#                    DRUPILOT_WORKSPACE_DIR (the flag wins over the variable).
#     --json         Print only the JSON payload (suppress the human table).
#
# Output: a human table on STDERR; the recommendation JSON on STDOUT:
#   { subject_src, machine_name, type, loose, drupal_root, drupal_root_exists,
#     subject_dest_rel, subject_dest_abs, placement, already_placed,
#     residue, residual_ddev, layout, project_root, origin_repo, origin_rel,
#     shared_root, testbed_inside_origin, core_version, in_place_ok }
# layout: in-place | project-no-core | repo-subdir | standalone. project_root:
# the Composer project root without installed core (or a Drupal 10 site an
# explicit workspace moves the port out of; null otherwise). origin_repo /
# origin_rel: the enclosing git repository and the subject's path in it (null
# when the subject is its own repository or not in git). shared_root: the
# test-bed to share between the modules of the same set (/drupilot-layers),
# outside the repository. testbed_inside_origin: the chosen root lies inside the
# subject's repository or project (only an explicit DRUPILOT_WORKSPACE_DIR can
# do that; warned). core_version / in_place_ok: the installed core of an
# in-place root and whether it is Drupal 11 or later (null otherwise).
# residue lists untracked local-environment leftovers at the top of the subject
# (.ddev/, vendor/, node_modules/, .phpstan-cache/, .drupilot/) and symlinks
# whose target escapes it. residual_ddev is true when the Drupal "root" is the
# module itself only because of an UNTRACKED .ddev/config.yaml with no core
# (a leftover module-at-root sandbox). Both are report-only: they never change
# the loose/root decision (ddev-drupal-contrib's module-at-root layout is
# legitimate).
# Read-only and ungated. Exit codes: 0 ok · 1 usage/error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
JSON_ONLY=0
usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --json) JSON_ONLY=1; shift;;
    --workspace) [[ -n "${2:-}" ]] || die "--workspace needs a directory" 1; export DRUPILOT_WORKSPACE_DIR="$2"; shift 2;;
    --workspace=*) export DRUPILOT_WORKSPACE_DIR="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

have_cmd jq || die "jq is required for resolve-workspace.sh." 1

# A directory we may treat as an existing Drupal/drupilot test-bed root (vs. an
# unrelated dir that merely shares the '<name>-d11' name).
_is_drupal_rootish() {
  [[ -f "$1/.ddev/config.yaml" || -f "$1/web/core/lib/Drupal.php" || -f "$1/core/lib/Drupal.php" ]]
}

SUBJECT="${SUBJECT:-$PWD}"
SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
[[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1

MACHINE="$(subject_machine_name "$SUBJECT_ABS" 2>/dev/null || basename "$SUBJECT_ABS")"
TYPE="$(subject_type "$SUBJECT_ABS" 2>/dev/null || echo module)"
case "$TYPE" in
  theme)   DEST_SUB="themes";;
  profile) DEST_SUB="profiles";;
  *)       DEST_SUB="modules";;
esac

# Placement mode (validated). A misconfigured value is reported on stderr (the
# config_enum error is NOT suppressed — only stdout matters for the payload), but
# we still default to 'move' so the resolver always yields a plan.
PLACEMENT="$(config_enum DRUPILOT_PLACEMENT move move symlink copy || echo move)"

# --- 1) Is the subject already inside a Drupal site? -----------------------
EXISTING_ROOT="$(find_drupal_root "$SUBJECT_ABS" 2>/dev/null || true)"
PROJECT_NOCORE="$(find_project_root_nocore "$SUBJECT_ABS" 2>/dev/null || true)"
ORIGIN_REPO="$(git_enclosing_repo "$SUBJECT_ABS" 2>/dev/null || true)"
ORIGIN_REL=""
if [[ -n "$ORIGIN_REPO" ]]; then
  ORIGIN_REL="$(git -C "$SUBJECT_ABS" rev-parse --show-prefix 2>/dev/null || true)"
  ORIGIN_REL="${ORIGIN_REL%/}"
fi
# A project checkout without core, with a committed .ddev/config.yaml, is found
# by find_drupal_root; it is not a site to run in (nothing is installed), so it
# is handled as a project-no-core checkout. A drupilot test-bed is never
# reclassified (its core may be missing only mid-setup).
if [[ -n "$EXISTING_ROOT" && -n "$PROJECT_NOCORE" ]] \
   && ! drupal_core_installed "$EXISTING_ROOT" \
   && [[ "$(testbed_kind "$EXISTING_ROOT")" == "none" ]]; then
  EXISTING_ROOT=""
fi

LOOSE="true"
ROOT=""
DEST_REL=""
PLACEMENT_OUT="$PLACEMENT"
ALREADY="false"
LAYOUT="standalone"
CORE_VERSION=""
IN_PLACE_OK="null"
SHARED_ROOT=""
PLACEMENT_NOTE=""

if [[ -n "$EXISTING_ROOT" ]]; then
  CORE_VERSION="$(drupal_core_version "$EXISTING_ROOT" 2>/dev/null || true)"
  if [[ "$CORE_VERSION" =~ ^([0-9]+)\. ]]; then
    if [[ "${BASH_REMATCH[1]}" -ge 11 ]]; then IN_PLACE_OK="true"; else IN_PLACE_OK="false"; fi
  fi
  # A site still on Drupal 10 cannot host a Drupal 11 port in place: an explicit
  # workspace elsewhere turns it into a test-bed port.
  _ws="$(config_get DRUPILOT_WORKSPACE_DIR "")"
  if [[ "$IN_PLACE_OK" == "false" && -n "$_ws" ]]; then
    case "$_ws" in /*) : ;; *) _ws="$(dirname "$SUBJECT_ABS")/$_ws";; esac
    [[ -d "$_ws" ]] && _ws="$(cd "$_ws" && pwd)"
    if [[ "${_ws%/}" != "${EXISTING_ROOT%/}" ]]; then
      PROJECT_NOCORE="$EXISTING_ROOT"
      EXISTING_ROOT=""
    fi
  fi
fi

if [[ -n "$EXISTING_ROOT" ]]; then
  LAYOUT="in-place"
  # The module lives inside a resolvable Drupal root already: keep today's layout
  # untouched (back-compat). Nothing to move.
  LOOSE="false"
  ROOT="$EXISTING_ROOT"
  PLACEMENT_OUT="in-place"
  ALREADY="true"
  case "$SUBJECT_ABS" in
    "$ROOT"/*) DEST_REL="${SUBJECT_ABS#"$ROOT"/}";;
    "$ROOT")   DEST_REL=".";;
    *)         DEST_REL="$SUBJECT_ABS";;
  esac
else
  # Loose checkout: target an explicit workspace, else a clearly-named sibling.
  WORKSPACE_OVERRIDE="$(config_get DRUPILOT_WORKSPACE_DIR "")"
  # Honor a workspace pinned at the SUBJECT side by a prior copy/symlink run:
  # config_get cannot reach it (a loose subject has no Drupal root above it, so
  # drupilot_prefs_file resolves nothing), so read the subject-side file directly.
  if [[ -z "$WORKSPACE_OVERRIDE" && -r "$SUBJECT_ABS/.drupilot.json" ]]; then
    WORKSPACE_OVERRIDE="$(jq -r '.DRUPILOT_WORKSPACE_DIR // empty' "$SUBJECT_ABS/.drupilot.json" 2>/dev/null || true)"
  fi
  if [[ -n "$WORKSPACE_OVERRIDE" ]]; then
    # Absolute-ize relative overrides against the subject's parent.
    case "$WORKSPACE_OVERRIDE" in
      /*) ROOT="$WORKSPACE_OVERRIDE";;
      *)  ROOT="$(dirname "$SUBJECT_ABS")/$WORKSPACE_OVERRIDE";;
    esac
  fi
  # Default test-bed, always outside the user's repository/project. Reuse an
  # existing drupilot test-bed at the canonical name (idempotent re-run), but
  # NEVER silently adopt an UNRELATED pre-existing dir of the same name — bump
  # to the next free name instead.
  if [[ -n "$PROJECT_NOCORE" ]]; then
    LAYOUT="project-no-core"
    _outer="$PROJECT_NOCORE"
    _pp="$(cd "$PROJECT_NOCORE" 2>/dev/null && pwd -P || printf '%s' "$PROJECT_NOCORE")"
    if [[ -n "$ORIGIN_REPO" ]]; then
      case "$_pp/" in "$ORIGIN_REPO"/*) _outer="$ORIGIN_REPO";; esac
    fi
    _parent="$(dirname "$_outer")"; _name="$(basename "$_outer")-d11"
  elif [[ -n "$ORIGIN_REPO" ]]; then
    LAYOUT="repo-subdir"
    _parent="$(dirname "$ORIGIN_REPO")"; _name="${MACHINE}-d11"
  else
    _parent="$(dirname "$SUBJECT_ABS")"; _name="${MACHINE}-d11"
  fi
  _default="$_parent/$_name"
  _n=2
  while [[ -e "$_default" ]] && ! _is_drupal_rootish "$_default"; do
    _default="$_parent/${_name}-$_n"; _n=$((_n+1))
  done
  # The test-bed a SET of modules shares (/drupilot-layers), outside the repo.
  case "$LAYOUT" in
    project-no-core) SHARED_ROOT="$_default";;
    repo-subdir)     SHARED_ROOT="$(dirname "$ORIGIN_REPO")/$(basename "$ORIGIN_REPO")-d11";;
    *)               _sp="$(dirname "$SUBJECT_ABS")"; SHARED_ROOT="$(dirname "$_sp")/$(basename "$_sp")-d11";;
  esac
  [[ -n "$ROOT" ]] || ROOT="$_default"
  DEST_REL="web/$DEST_SUB/custom/$MACHINE"
  # A sub-directory of a repository is copied, never moved out of it.
  if [[ "$LAYOUT" != "standalone" && "$PLACEMENT_OUT" == "move" ]]; then
    PLACEMENT_OUT="copy"
    PLACEMENT_NOTE="'move' would delete the module from its repository ($LAYOUT); copying it instead"
  fi
fi

# Normalize ROOT (without requiring it to exist yet). drupal_root_exists means
# "a Drupal site is already scaffolded there" (the precondition place-subject.sh
# needs), NOT merely that the directory exists.
[[ -d "$ROOT" ]] && ROOT="$(cd "$ROOT" && pwd)"
ROOT_EXISTS="false"
_is_drupal_rootish "$ROOT" && ROOT_EXISTS="true"
DEST_ABS="$ROOT/$DEST_REL"

# Does the chosen test-bed land inside the subject's repository or project?
INSIDE="false"
if [[ "$LOOSE" == "true" ]]; then
  for _o in "$ORIGIN_REPO" "$PROJECT_NOCORE"; do
    [[ -n "$_o" ]] || continue
    case "$ROOT/" in "$_o"/*) INSIDE="true";; esac
  done
fi

# Already placed? (loose case only — the destination holds this module already.)
if [[ "$LOOSE" == "true" && -d "$DEST_ABS" ]] && is_drupal_extension_dir "$DEST_ABS" 2>/dev/null; then
  ALREADY="true"
fi

# --- Residue report (read-only) --------------------------------------------
RESIDUE=()
_tracked() { git -C "$SUBJECT_ABS" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  && [[ -n "$(git -C "$SUBJECT_ABS" ls-files -- "$1" 2>/dev/null | head -n1)" ]]; }
for _n in .ddev vendor node_modules .phpstan-cache .drupilot; do
  if [[ -e "$SUBJECT_ABS/$_n" ]] && ! _tracked "$_n"; then RESIDUE+=("$_n/"); fi
done
while IFS= read -r _l; do
  [[ -n "$_l" ]] || continue
  _rel="${_l#"$SUBJECT_ABS"/}"
  symlink_escapes "$SUBJECT_ABS" "$_rel" && RESIDUE+=("$_rel")
done < <(find "$SUBJECT_ABS" \( -name .git -o -name node_modules -o -name vendor -o -name .ddev \) -prune -o -type l -print 2>/dev/null || true)
RESIDUAL_DDEV="false"
if [[ "$ROOT" == "$SUBJECT_ABS" && -f "$SUBJECT_ABS/.ddev/config.yaml" ]] \
   && is_drupal_extension_dir "$SUBJECT_ABS" 2>/dev/null \
   && [[ ! -f "$SUBJECT_ABS/web/core/lib/Drupal.php" && ! -f "$SUBJECT_ABS/core/lib/Drupal.php" ]] \
   && ! _tracked ".ddev/config.yaml"; then
  RESIDUAL_DDEV="true"
fi
RESIDUE_JSON="$(arr_to_json ${RESIDUE[@]+"${RESIDUE[@]}"})"

JSON="$(jq -c -n \
  --arg subject_src "$SUBJECT_ABS" \
  --arg machine_name "$MACHINE" \
  --arg type "$TYPE" \
  --argjson loose "$LOOSE" \
  --arg drupal_root "$ROOT" \
  --argjson drupal_root_exists "$ROOT_EXISTS" \
  --arg subject_dest_rel "$DEST_REL" \
  --arg subject_dest_abs "$DEST_ABS" \
  --arg placement "$PLACEMENT_OUT" \
  --argjson already_placed "$ALREADY" \
  --argjson residue "$RESIDUE_JSON" \
  --argjson residual_ddev "$RESIDUAL_DDEV" \
  --arg layout "$LAYOUT" --arg project_root "$PROJECT_NOCORE" \
  --arg origin_repo "$ORIGIN_REPO" --arg origin_rel "$ORIGIN_REL" \
  --arg shared_root "$SHARED_ROOT" --argjson inside "$INSIDE" \
  --arg core_version "$CORE_VERSION" --argjson in_place_ok "$IN_PLACE_OK" \
  'def n: if . == "" then null else . end;
   {subject_src:$subject_src, machine_name:$machine_name, type:$type, loose:$loose,
    drupal_root:$drupal_root, drupal_root_exists:$drupal_root_exists,
    subject_dest_rel:$subject_dest_rel, subject_dest_abs:$subject_dest_abs,
    placement:$placement, already_placed:$already_placed,
    residue:$residue, residual_ddev:$residual_ddev,
    layout:$layout, project_root:($project_root | n),
    origin_repo:($origin_repo | n), origin_rel:($origin_rel | n),
    shared_root:($shared_root | n), testbed_inside_origin:$inside,
    core_version:($core_version | n), in_place_ok:$in_place_ok}')"

# Residue warnings are useful even in --json mode (they go to STDERR).
if [[ "${#RESIDUE[@]}" -gt 0 ]]; then
  log_warn "Local-environment residue in the subject (untracked, not part of the module): ${RESIDUE[*]}"
fi
if [[ "$RESIDUAL_DDEV" == "true" ]]; then
  log_warn "The subject itself looks like a leftover module-at-root DDEV sandbox (untracked .ddev/config.yaml, no Drupal core)."
  log_plain "  It is treated as the Drupal root. If that is stale, remove its .ddev/ or set DRUPILOT_WORKSPACE_DIR."
fi

[[ -n "$PLACEMENT_NOTE" ]] && log_warn "Placement: $PLACEMENT_NOTE."
if [[ "$INSIDE" == "true" ]]; then
  log_warn "The test-bed root $ROOT lies inside the subject's repository/project: it would leave untracked files there."
  log_plain "  Point DRUPILOT_WORKSPACE_DIR outside it (the default is $_default)."
fi
if [[ "$IN_PLACE_OK" == "false" ]]; then
  log_warn "The Drupal root $ROOT runs Drupal $CORE_VERSION: an in-place port needs the site on Drupal 11 first."
  log_plain "  Port in a Drupal 11 test-bed instead: set DRUPILOT_WORKSPACE_DIR (or --workspace) to a directory outside it."
fi

if [[ "$JSON_ONLY" -eq 0 ]]; then
  log_step "Workspace resolution — $MACHINE ($TYPE)"
  if [[ "$LOOSE" == "true" ]]; then
    case "$LAYOUT" in
      project-no-core) log_plain "  Subject is part of a Composer project without installed core: $PROJECT_NOCORE";;
      repo-subdir)     log_plain "  Subject is a sub-directory of the git repository $ORIGIN_REPO (not inside a Drupal site).";;
      *)               log_plain "  Subject is LOOSE (not inside a Drupal site).";;
    esac
    log_plain "  Drupal test-bed root : $ROOT $( [[ "$ROOT_EXISTS" == "true" ]] && echo '(exists)' || echo '(to be created)')"
    log_plain "  Place subject at     : $DEST_REL"
    log_plain "  Placement mode       : $PLACEMENT_OUT"
    [[ "$ALREADY" == "true" ]] && log_plain "  Status               : already placed (idempotent)"
    log_plain ""
    log_plain "  Your checkout stays intact; Drupal + .ddev live in the sibling root above,"
    log_plain "  so the module is never scaffolded on top of. Run place-subject.sh to apply."
  else
    log_plain "  Subject already lives inside a Drupal root — keeping the existing layout."
    log_plain "  Drupal root          : $ROOT"
    log_plain "  Subject (relative)   : $DEST_REL"
  fi
  hr
fi

printf '%s\n' "$JSON"
exit 0
