#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/ddev-up.sh
# Create (if absent) and start a Drupal 11 DDEV project, parameterized by the
# effective PHP target (resolve_php_target). Then ensure a Composer project
# exists (drupal/recommended-project:^11) with Drush ^13.
#
# This script GATES the 'setup' profile via preflight: if a hard requirement
# (Docker daemon up, DDEV) is missing it prints the report and exits 2 WITHOUT
# touching anything.
#
# Idempotent (PROMPT 5.2 / 7.7):
#   - If .ddev/config.yaml already exists we do NOT re-run `ddev config`.
#   - If the project is already running we skip `ddev start`. "Running" is the
#     real status from `ddev describe` (ddev_running never starts a project), and
#     after `ddev start` the status is checked again.
#   - If composer.json already exists we skip `ddev composer create-project`
#     (`ddev composer create` on DDEV < 1.24.2). That step runs with stdin
#     closed and a wall-clock limit of DRUPILOT_DDEV_CREATE_TIMEOUT seconds
#     (default 900, 0 = no limit; needs `timeout`/`gtimeout`, else unbounded).
#     When composer.json exists but vendor/ does not (e.g. after
#     `/drupilot-clean --level vendor`), `ddev composer install` restores it
#     from composer.lock, under the same limit.
#   - In deterministic mode a core version frozen in the lockfile (e.g. by an
#     earlier setup of this root, before a /drupilot-clean) is honored: the
#     project is created as drupal/recommended-project:<that exact version>
#     instead of the floating DRUPILOT_DRUPAL_TARGET.
#
# Cached base core (DRUPILOT_CORE_CACHE = auto | locked | off, default auto):
# after a fresh create-project (+ Drush), the resulting tree (composer.json,
# composer.lock, vendor/, the docroot with core, recipes/, the scaffold files;
# never .ddev/, settings*.php or files/) is stored under the plugin data dir,
# keyed by PHP target + exact core version. A later setup of an EMPTY root
# copies that tree in (copy-on-write: `cp --reflink=auto`, `cp -c` on APFS,
# else a plain copy) before `ddev start`, then verifies it with
# `ddev composer install`; a failed verification discards the entry and falls
# back to create-project. Reuse: 'locked' = only the exact version the
# lockfile froze; 'auto' = that, or (deterministic mode, nothing frozen yet)
# the newest entry built for the same DRUPILOT_DRUPAL_TARGET within
# DRUPILOT_CORE_CACHE_MAX_AGE_DAYS (default 7), which the lockfile then
# freezes; DRUPILOT_DETERMINISTIC=false never reuses a tree (fresh resolve)
# but still refreshes the cache. DRUPILOT_CORE_CACHE_KEEP (default 3) entries
# are kept. A root ddev-up.sh built (create-project or cache) is marked as a
# drupilot test-bed in its .drupilot.json (testbed_mark), which is what lets
# /drupilot-clean remove its vendor/ or the whole workspace. Both the cache
# and the marker need a root built from nothing: a docroot that already holds
# files DDEV did not generate is the user's content, never overwritten by the
# cached tree, never cached and never marked (a failed cache verification
# removes only what the copy added and puts the original docroot back).
#   - We READ the generated .ddev/config.yaml for the real values rather than
#     assuming hostnames/images (PROMPT 2.5 / 7.1).
#
# Usage:
#   ddev-up.sh [--php X] [--name NAME] [--subject DIR] [--docroot web]
#              [--dir PROJECT_DIR] [--workspace DIR] [--no-create] [--json]
#              [-h|--help]
#   --workspace  the test-bed root for a loose --subject, the same as
#              DRUPILOT_WORKSPACE_DIR (the flag wins over the variable).
#
#   --name     DDEV project name (hostname-safe; sanitized). Default: the
#              project directory's name (for a loose subject, the sibling
#              test-bed '<machine_name>-d11').
#   --json     print a JSON summary on STDOUT when done:
#              {project_dir, project_name, php_version, primary_url, drupal_target,
#               core_source, core_cache}
#              core_source: create | cache | existing | install (vendor/
#              restored by composer install); core_cache: {key, method,
#              seconds, stored} or null.
#
# Output: every log line, the preflight report and the ddev/composer output go
# to STDERR; STDOUT carries only the --json payload (empty without --json).
#
# Exit codes:
#   0 -> project configured and running.
#   2 -> a hard 'setup' requirement is missing (preflight gate).
#   1 -> usage/internal error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PHP_TARGET=""
PROJECT_NAME=""
SUBJECT=""
DOCROOT="web"
PROJECT_DIR=""
DO_CREATE=1
JSON_OUT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --php) PHP_TARGET="${2:-}"; shift 2;;
    --php=*) PHP_TARGET="${1#*=}"; shift;;
    --name) PROJECT_NAME="${2:-}"; shift 2;;
    --name=*) PROJECT_NAME="${1#*=}"; shift;;
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --workspace) [[ -n "${2:-}" ]] || die "--workspace needs a directory" 1; export DRUPILOT_WORKSPACE_DIR="$2"; shift 2;;
    --workspace=*) export DRUPILOT_WORKSPACE_DIR="${1#*=}"; shift;;
    --docroot) DOCROOT="${2:-web}"; shift 2;;
    --docroot=*) DOCROOT="${1#*=}"; shift;;
    --dir) PROJECT_DIR="${2:-}"; shift 2;;
    --dir=*) PROJECT_DIR="${1#*=}"; shift;;
    --no-create) DO_CREATE=0; shift;;
    --json) JSON_OUT=1; shift;;
    -h|--help)
      print_usage "$0"; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

# Effective PHP target (flag overrides config; config defaults to 8.3).
[[ -z "$PHP_TARGET" ]] && PHP_TARGET="$(resolve_php_target)"

# Warn (don't block) on PHP 8.5: DDEV may lack that image, and it needs Drupal
# 11.3 or later (checked below against the core this run installs, and at the
# end against the core the test-bed has).
if php_target_unconfirmed "$PHP_TARGET"; then
  log_warn "DDEV may not provide a PHP $PHP_TARGET image. Consider 8.3 (default) or 8.4 if 'ddev start' fails."
fi

PLUGIN_ROOT_DIR="$(plugin_root)"

# ---------------------------------------------------------------------------
# GATE: setup profile (Docker daemon + DDEV). No side effects before this.
# ---------------------------------------------------------------------------
log_step "Checking environment requirements (profile: setup)"
if ! bash "$PLUGIN_ROOT_DIR/scripts/env/preflight.sh" --profile setup >&2; then
  die "Cannot set up the DDEV environment: a hard requirement is missing (see report above). Run /drupilot-doctor." 2
fi

# ---------------------------------------------------------------------------
# Resolve the project directory.
# Preference: --dir > existing Drupal root from --subject/cwd > current dir.
# ---------------------------------------------------------------------------
if [[ -z "$PROJECT_DIR" ]]; then
  PROJECT_DIR="$(find_drupal_root "${SUBJECT:-$PWD}" 2>/dev/null || true)"
  # A LOOSE extension checkout (has *.info.yml) with no Drupal above it must NOT
  # be scaffolded on top of — that intermixes the module with the Drupal site and
  # pollutes its composer.json. resolve-workspace.sh targets a sibling test-bed
  # root instead; the module is placed into it later by place-subject.sh. The
  # same goes for a module of a Composer project whose core is not installed (a
  # monorepo clone, possibly with a committed .ddev/): its test-bed lives
  # outside the user's repository, never in it.
  # (An explicit workspace for a site still on Drupal 10 does the same.) The
  # resolver decides for every extension subject; it returns the existing root
  # unchanged for a module already inside a usable site.
  if is_drupal_extension_dir "${SUBJECT:-$PWD}"; then
    RESOLVER="$PLUGIN_ROOT_DIR/scripts/env/resolve-workspace.sh"
    if [[ -r "$RESOLVER" ]] && have_cmd jq; then
      _plan="$(bash "$RESOLVER" --subject "${SUBJECT:-$PWD}" --json 2>/dev/null || true)"
      if [[ "$(printf '%s' "$_plan" | jq -r '.loose // empty' 2>/dev/null || true)" == "true" ]]; then
        PROJECT_DIR="$(printf '%s' "$_plan" | jq -r '.drupal_root // empty' 2>/dev/null || true)"
        if [[ -n "$PROJECT_DIR" ]]; then
          log_info "Loose subject detected — building the Drupal 11 test-bed outside your checkout:"
          log_info "  $PROJECT_DIR"
          log_info "  (your checkout stays intact; place-subject.sh places the module in once Drupal exists)."
        fi
      fi
    fi
  fi
fi
[[ -z "$PROJECT_DIR" ]] && PROJECT_DIR="$PWD"
mkdir -p "$PROJECT_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# Clean-root guard (BEFORE any `ddev config`): if we will need `ddev composer
# create` (no composer.json yet), the root must contain only the docroot and
# dotfiles. Checking here — rather than just before composer-create — means we
# never write a stray .ddev/ into a dir that creation would then refuse.
if [[ "$DO_CREATE" == "1" && ! -f "$PROJECT_DIR/composer.json" ]]; then
  STRAY=()
  shopt -s nullglob
  for _entry in "$PROJECT_DIR"/*; do
    _base="$(basename "$_entry")"
    [[ "$_base" == "$DOCROOT" ]] && continue
    STRAY+=("$_base")
  done
  shopt -u nullglob
  if [[ ${#STRAY[@]} -gt 0 ]]; then
    log_err "Cannot create the Drupal project: the root '$PROJECT_DIR' is not clean."
    log_err "composer create-project only tolerates '$DOCROOT/' and dotfiles, but it also contains: ${STRAY[*]}"
    log_plain "If you pointed drupilot at a module/theme directly, you do NOT need to fix this by"
    log_plain "hand: re-run /drupilot-setup and drupilot builds Drupal in a sibling directory, then"
    log_plain "place-subject.sh moves the extension under '$DOCROOT/modules/custom/<name>' for you."
    die "Project root not clean for 'ddev composer create-project' (stray: ${STRAY[*]})." 1
  fi
fi

# Default project name from the directory if not provided. Either way, sanitize
# it to a hostname-safe value: DDEV rejects underscores/dots/uppercase, so a
# directory named e.g. "upgrade-to-d11-file_version" would fail `ddev config`.
[[ -z "$PROJECT_NAME" ]] && PROJECT_NAME="$(basename "$PROJECT_DIR")"
_RAW_PROJECT_NAME="$PROJECT_NAME"
PROJECT_NAME="$(ddev_project_name "$PROJECT_NAME")"
[[ "$PROJECT_NAME" != "$_RAW_PROJECT_NAME" ]] \
  && log_info "Sanitized DDEV project name '$_RAW_PROJECT_NAME' -> '$PROJECT_NAME' (hostname-safe)."

DDEV_CONFIG="$PROJECT_DIR/.ddev/config.yaml"
# An existing project keeps its configured name ('ddev config' is not re-run), so
# report THAT name rather than the --name/directory default.
if [[ -f "$DDEV_CONFIG" ]]; then
  _cfg_name="$(grep -E '^name:' "$DDEV_CONFIG" 2>/dev/null | head -n1 \
    | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' | tr -d '"'"'"'')"
  if [[ -n "$_cfg_name" && "$_cfg_name" != "$PROJECT_NAME" ]]; then
    [[ "$_RAW_PROJECT_NAME" != "$(basename "$PROJECT_DIR")" ]] \
      && log_warn "DDEV is already configured as '$_cfg_name'; --name '$_RAW_PROJECT_NAME' is ignored (not re-running 'ddev config')."
    PROJECT_NAME="$_cfg_name"
  fi
fi

log_info "Project directory : $PROJECT_DIR"
log_info "Project name      : $PROJECT_NAME"
log_info "PHP target        : $PHP_TARGET"
log_info "Docroot           : $DOCROOT"

# ---------------------------------------------------------------------------
# Step 1 — ddev config (idempotent: skip if already configured)
# ---------------------------------------------------------------------------
if [[ -f "$DDEV_CONFIG" ]]; then
  log_ok "DDEV is already configured (.ddev/config.yaml exists) — not re-running 'ddev config'."
  # Reconcile the PHP version if the existing config differs from the target.
  EXISTING_PHP="$(grep -E '^[[:space:]]*php_version:' "$DDEV_CONFIG" 2>/dev/null | head -n1 \
    | sed -E 's/^[[:space:]]*php_version:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' | tr -d '"'"'"'')"
  EXISTING_PHP="$(trim "$EXISTING_PHP")"
  if [[ -n "$EXISTING_PHP" && "$EXISTING_PHP" != "$PHP_TARGET" ]]; then
    log_warn "Existing DDEV php_version ($EXISTING_PHP) differs from the target ($PHP_TARGET). Aligning to $PHP_TARGET."
    ( cd "$PROJECT_DIR" && ddev config --php-version="$PHP_TARGET" >&2 )
  fi
else
  log_step "Configuring DDEV (Drupal 11, PHP $PHP_TARGET)"
  ( cd "$PROJECT_DIR" && ddev config \
      --project-name="$PROJECT_NAME" \
      --project-type=drupal11 \
      --docroot="$DOCROOT" \
      --php-version="$PHP_TARGET" >&2 ) \
    || die "'ddev config' failed. If PHP $PHP_TARGET is unsupported by this DDEV version, retry with --php 8.3." 1
  log_ok "DDEV configured."
fi

# ---------------------------------------------------------------------------
# Step 1b — the base core: honor a frozen core version, reuse a cached tree
# ---------------------------------------------------------------------------
DRUPAL_TARGET="$(resolve_drupal_target)"
DRUSH_CONSTRAINT="$(config_json '.packages.drush' 'drush/drush:^13')"
CREATE_TIMEOUT="$(config_get DRUPILOT_DDEV_CREATE_TIMEOUT 900)"
[[ "$CREATE_TIMEOUT" =~ ^[0-9]+$ ]] \
  || die "DRUPILOT_DDEV_CREATE_TIMEOUT must be a number of seconds (got '$CREATE_TIMEOUT')." 1
CORE_CACHE_MODE="$(config_get DRUPILOT_CORE_CACHE auto)"
case "$CORE_CACHE_MODE" in
  auto|locked|off) : ;;
  *) log_warn "DRUPILOT_CORE_CACHE='$CORE_CACHE_MODE' is invalid (auto|locked|off) — not using the cached base core."
     CORE_CACHE_MODE="off";;
esac
CORE_CACHE_MAX_AGE="$(config_get DRUPILOT_CORE_CACHE_MAX_AGE_DAYS 7)"
[[ "$CORE_CACHE_MAX_AGE" =~ ^[0-9]+$ ]] || CORE_CACHE_MAX_AGE=7
CORE_SOURCE="existing"      # create | cache | existing | install
CORE_CACHE_KEY=""; CORE_CACHE_METHOD=""; CORE_CACHE_SECS=""; CORE_CACHE_STORED="false"
RESTORED_ENTRIES=()
CREATE_SPEC="drupal/recommended-project:${DRUPAL_TARGET}"

# The exact core version the lockfile froze for this root (deterministic mode
# only), when it is a plain release that the Drupal target still admits.
LOCKED_CORE=""
if deterministic_mode && [[ ! -f "$PROJECT_DIR/composer.json" ]]; then
  LOCKED_CORE="$(DRUPILOT_PROJECT_DIR="$PROJECT_DIR" lock_get .drupal.core "")"
  if [[ ! "$LOCKED_CORE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
     || ! core_requirement_admits "$DRUPAL_TARGET" "${LOCKED_CORE%%.*}"; then
    LOCKED_CORE=""
  fi
  if [[ -n "$LOCKED_CORE" ]]; then
    CREATE_SPEC="drupal/recommended-project:${LOCKED_CORE}"
    log_info "Lockfile pins Drupal core $LOCKED_CORE for this root — honoring it (DRUPILOT_DETERMINISTIC=false resolves '$DRUPAL_TARGET' fresh)."
  fi
fi

# PHP 8.5 needs Drupal 11.3 or later: warn (don't block) when the core this run
# creates may be older — the lock-pinned core, else the floor of the Drupal
# target. A dev branch or a stability flag (11.x-dev, ^11.3@beta) has no numeric
# floor: unknown, never guessed. The installed core is checked again at the end.
if php_target_unconfirmed "$PHP_TARGET" && [[ "$DO_CREATE" == "1" && ! -f "$PROJECT_DIR/composer.json" ]]; then
  _floor=""; _from=""
  if [[ -n "$LOCKED_CORE" ]]; then
    _floor="$LOCKED_CORE"; _from="the lockfile pins Drupal $LOCKED_CORE"
  elif ! printf '%s' "$DRUPAL_TARGET" | grep -qE '@|-dev|[0-9]\.(x|\*)'; then
    _floor="$(core_floor_from_requirement "$DRUPAL_TARGET")"; _from="the Drupal target $DRUPAL_TARGET also admits $_floor"
  fi
  if [[ -n "$_floor" && "$(php_supported_for "$_floor" "$PHP_TARGET")" == "no" ]]; then
    log_warn "PHP $PHP_TARGET needs Drupal 11.3 or later; $_from."
  fi
fi

# docroot_pristine -> 0 when the docroot is absent or holds nothing but what
# DDEV itself generates (sites/default settings files, an empty files/ dir): a
# root built from nothing. A docroot with any other file (a site without
# Composer laid out as <root>/web, a partial earlier run) is the user's content:
# the cached tree is never copied over it, and the root is never marked as a
# drupilot test-bed (/drupilot-clean would then treat that content as
# disposable).
docroot_pristine() {
  local d="$PROJECT_DIR/$DOCROOT" extra
  [[ -d "$d" ]] || return 0
  extra="$(cd "$d" && find . \( -type f -o -type l \) \
      ! -path './sites/default/settings.php' ! -path './sites/default/settings.ddev.php' \
      ! -path './sites/default/settings.local.php' ! -path './sites/default/.gitignore' \
      -print 2>/dev/null | head -n 1)"
  [[ -z "$extra" ]]
}
DOCROOT_PRISTINE="false"
if [[ ! -f "$PROJECT_DIR/composer.json" ]] && docroot_pristine; then DOCROOT_PRISTINE="true"; fi

# The top-level entries present before a cached tree is copied in: a failed
# copy or verification removes only what the copy ADDED, never one of these.
PRE_ENTRIES=" "
shopt -s nullglob dotglob
for _e in "$PROJECT_DIR"/*; do PRE_ENTRIES="$PRE_ENTRIES$(basename "$_e") "; done
shopt -u nullglob dotglob
# The pre-existing (pristine) docroot is saved aside so a rollback can put it
# back exactly; it holds at most DDEV's generated settings files.
DOCROOT_BACKUP=""

# core_cache_rollback -> take a copied cache tree back out of the root.
core_cache_rollback() {
  local e
  for e in ${RESTORED_ENTRIES[@]+"${RESTORED_ENTRIES[@]}"}; do
    [[ -n "$e" && "$e" != "." && "$e" != ".." && "$e" != ".ddev" && "$e" != ".git" ]] || continue
    if [[ "$e" == "$DOCROOT" ]]; then
      chmod -R u+w "${PROJECT_DIR:?}/$e" 2>/dev/null || true
      rm -rf "${PROJECT_DIR:?}/$e"
      if [[ -n "$DOCROOT_BACKUP" && -d "$DOCROOT_BACKUP/$DOCROOT" ]]; then
        if ! cp -R -p "$DOCROOT_BACKUP/$DOCROOT" "$PROJECT_DIR/" 2>/dev/null; then
          log_warn "Could not put the original $DOCROOT/ back (a copy is kept in $DOCROOT_BACKUP)."
          DOCROOT_BACKUP=""   # keep it: drop_docroot_backup must not remove it
        fi
      fi
      continue
    fi
    case "$PRE_ENTRIES" in *" $e "*) continue;; esac
    chmod -R u+w "${PROJECT_DIR:?}/$e" 2>/dev/null || true
    rm -rf "${PROJECT_DIR:?}/$e"
  done
  return 0
}

# drop_docroot_backup -> remove the saved docroot copy (never fails).
drop_docroot_backup() {
  [[ -n "$DOCROOT_BACKUP" ]] && rm -rf "${DOCROOT_BACKUP:?}" 2>/dev/null
  DOCROOT_BACKUP=""
  return 0
}

if [[ "$DO_CREATE" == "1" && ! -f "$PROJECT_DIR/composer.json" && "$CORE_CACHE_MODE" != "off" \
      && "$DOCROOT_PRISTINE" != "true" ]]; then
  log_warn "$PROJECT_DIR/$DOCROOT/ already holds files that DDEV did not generate — not restoring the cached base core over them."
fi
if [[ "$DO_CREATE" == "1" && ! -f "$PROJECT_DIR/composer.json" && "$CORE_CACHE_MODE" != "off" \
      && "$DOCROOT_PRISTINE" == "true" ]] \
   && deterministic_mode && have_cmd jq; then
  _entry=""
  if [[ -n "$LOCKED_CORE" ]]; then
    _entry="$(core_cache_lookup "$PHP_TARGET" "$DRUPAL_TARGET" "$DRUSH_CONSTRAINT" "$LOCKED_CORE")"
  elif [[ "$CORE_CACHE_MODE" == "auto" ]]; then
    _entry="$(core_cache_lookup "$PHP_TARGET" "$DRUPAL_TARGET" "$DRUSH_CONSTRAINT" "" "$CORE_CACHE_MAX_AGE")"
  fi
  if [[ -n "$_entry" ]]; then
    CORE_CACHE_KEY="$(basename "$_entry")"
    log_step "Restoring the cached base core $CORE_CACHE_KEY (skips composer create-project)"
    # Remember the top-level entries the copy adds, so a failed verification
    # can take them back out and leave the root clean for create-project.
    shopt -s nullglob dotglob
    for _e in "$_entry"/tree/*; do RESTORED_ENTRIES+=("$(basename "$_e")"); done
    shopt -u nullglob dotglob
    # A pre-existing entry the tree would overwrite (other than the pristine
    # docroot) is the user's: skip the cache rather than replace it.
    _clash=""
    for _e in ${RESTORED_ENTRIES[@]+"${RESTORED_ENTRIES[@]}"}; do
      [[ "$_e" == "$DOCROOT" || "$_e" == ".ddev" ]] && continue
      case "$PRE_ENTRIES" in *" $_e "*) _clash="$_clash $_e";; esac
    done
    if [[ -z "$_clash" && -d "$PROJECT_DIR/$DOCROOT" ]]; then
      DOCROOT_BACKUP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-docroot.XXXXXX" 2>/dev/null || true)"
      if [[ -z "$DOCROOT_BACKUP" ]] || ! cp -R -p "$PROJECT_DIR/$DOCROOT" "$DOCROOT_BACKUP/" 2>/dev/null; then
        _clash="$DOCROOT (could not save it aside)"
      fi
    fi
  fi
  if [[ -n "$_entry" && -n "$_clash" ]]; then
    log_warn "Not restoring the cached base core: it would overwrite existing entries in the root:$_clash."
    RESTORED_ENTRIES=(); CORE_CACHE_KEY=""
    drop_docroot_backup
  elif [[ -n "$_entry" ]]; then
    _t0="$(date +%s)"
    if CORE_CACHE_METHOD="$(fast_copy_tree "$_entry/tree" "$PROJECT_DIR")"; then
      CORE_CACHE_SECS="$(( $(date +%s) - _t0 ))"
      CORE_SOURCE="cache"
      log_ok "Copied the cached tree in ${CORE_CACHE_SECS}s ($CORE_CACHE_METHOD)."
    else
      log_warn "Could not copy the cached base core — falling back to composer create-project."
      core_cache_rollback
      drop_docroot_backup
      RESTORED_ENTRIES=(); CORE_CACHE_KEY=""; CORE_CACHE_METHOD=""
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 2 — ddev start (idempotent: skip if already running)
# ---------------------------------------------------------------------------
# ddev_running reads the real project status (`ddev describe`), so a stopped or
# paused project is started here explicitly instead of being woken up as a side
# effect of a probe.
_STATUS="$(ddev_project_status "$PROJECT_DIR")"
if ddev_running "$PROJECT_DIR"; then
  log_ok "DDEV project is already running (status: ${_STATUS:-running}) — skipping 'ddev start'."
else
  log_step "Starting DDEV (status: ${_STATUS:-not created}; this may pull container images on first run)"
  ( cd "$PROJECT_DIR" && ddev start </dev/null >&2 ) \
    || die "'ddev start' failed. Check the Docker daemon and the DDEV logs ('ddev logs')." 1
  ddev_running "$PROJECT_DIR" \
    || die "'ddev start' returned but the project is not running (status: $(ddev_project_status "$PROJECT_DIR")). Check 'ddev describe' and 'ddev logs'." 1
  log_ok "DDEV started."
fi

# ---------------------------------------------------------------------------
# Step 3 — READ the generated config for the real values (do NOT assume).
# ---------------------------------------------------------------------------
EFFECTIVE_PHP=""
PRIMARY_URL=""
if [[ -f "$DDEV_CONFIG" ]]; then
  EFFECTIVE_PHP="$(grep -E '^[[:space:]]*php_version:' "$DDEV_CONFIG" 2>/dev/null | head -n1 \
    | sed -E 's/^[[:space:]]*php_version:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' | tr -d '"'"'"'')"
  EFFECTIVE_PHP="$(trim "$EFFECTIVE_PHP")"
fi
# The authoritative primary URL comes from `ddev describe` (don't guess the host).
if have_cmd jq; then
  PRIMARY_URL="$( ( cd "$PROJECT_DIR" && ddev describe -j </dev/null 2>/dev/null ) \
    | jq -r '.raw.primary_url // .raw.httpsurl // empty' 2>/dev/null || true)"
fi
log_info "Generated config  : $DDEV_CONFIG"
[[ -n "$EFFECTIVE_PHP" ]] && log_info "Effective php_version (from YAML): $EFFECTIVE_PHP"
[[ -n "$PRIMARY_URL" ]]   && log_info "Primary URL (from 'ddev describe'): $PRIMARY_URL"

# ---------------------------------------------------------------------------
# Step 4 — Composer project (idempotent: skip if composer.json present)
# ---------------------------------------------------------------------------
# composer_install_bounded -> `ddev composer install` under the create limit.
# Returns composer's exit code (124 on the time limit, after stopping it).
composer_install_bounded() {
  local rc=0
  ( cd "$PROJECT_DIR" && run_with_timeout "$CREATE_TIMEOUT" \
      ddev composer install --no-interaction </dev/null >&2 ) || rc=$?
  if [[ "$rc" == "124" ]]; then
    ddev_stop_composer "$PROJECT_DIR" || true
  fi
  return "$rc"
}

# A restored cache tree is verified by `composer install` (a no-op when the
# tree matches its composer.lock; it also re-runs the scaffold). On failure the
# entry is discarded and the restored files are removed, so create-project
# below runs on a clean root as if there had been no cache.
if [[ "$CORE_SOURCE" == "cache" ]]; then
  log_step "Verifying the restored base core (ddev composer install)"
  if composer_install_bounded; then
    log_ok "The restored base core is consistent with its composer.lock."
    drop_docroot_backup
  else
    log_warn "Verification failed — discarding cache entry $CORE_CACHE_KEY and running composer create-project instead."
    core_cache_rollback
    drop_docroot_backup
    _bad="$(core_cache_dir)/$CORE_CACHE_KEY"
    if [[ -n "$CORE_CACHE_KEY" && -d "$_bad" ]]; then chmod -R u+w "$_bad" 2>/dev/null || true; rm -rf "${_bad:?}"; fi
    CORE_SOURCE="existing"; CORE_CACHE_KEY=""; CORE_CACHE_METHOD=""; CORE_CACHE_SECS=""
  fi
fi

if [[ -f "$PROJECT_DIR/composer.json" ]]; then
  [[ "$CORE_SOURCE" == "cache" ]] \
    || log_ok "composer.json already present — not running 'ddev composer create-project'."
  # composer.json without vendor/ (e.g. after /drupilot-clean --level vendor):
  # every later step needs vendor/, so restore it from composer.lock.
  _vendor_dir="$(jq -r '.config["vendor-dir"] // "vendor"' "$PROJECT_DIR/composer.json" 2>/dev/null || echo vendor)"
  [[ -n "$_vendor_dir" ]] || _vendor_dir="vendor"
  if [[ "$CORE_SOURCE" != "cache" && ! -f "$PROJECT_DIR/$_vendor_dir/autoload.php" ]]; then
    log_step "composer.json is present but $_vendor_dir/ is not — restoring it (ddev composer install)"
    _irc=0; composer_install_bounded || _irc=$?
    if [[ "$_irc" == "124" ]]; then
      die "'ddev composer install' did not finish within ${CREATE_TIMEOUT}s and was stopped. Check network access, then re-run (raise DRUPILOT_DDEV_CREATE_TIMEOUT, 0 = no limit, for a slow network)." 1
    elif [[ "$_irc" != "0" ]]; then
      die "'ddev composer install' failed (exit $_irc). Check network access and the DDEV web container ('ddev logs -s web')." 1
    fi
    CORE_SOURCE="install"
    log_ok "Dependencies restored from composer.lock."
  fi
else
  log_step "Creating the Drupal $DRUPAL_TARGET Composer project"
  # `ddev composer create-project` requires an almost-empty root (only "$DOCROOT/" and
  # dotfiles). The clean-root guard ran up front — before any .ddev/ was written —
  # so by here the root is known clean.
  # DDEV >= 1.24.2 provides `ddev composer create-project` (and 1.25 deprecates
  # the older `create` spelling with a warning); keep `create` for older DDEV.
  CREATE_SUBCMD="create"
  DDEV_VER="$(tool_version ddev 2>/dev/null || true)"
  if [[ -n "$DDEV_VER" ]] && version_ge "$DDEV_VER" "1.24.2"; then CREATE_SUBCMD="create-project"; fi
  # Bounded and non-interactive: stdin is closed so nothing can wait on a
  # prompt, and DRUPILOT_DDEV_CREATE_TIMEOUT (seconds, 0 = no limit) stops a
  # hung run with a clear error instead of blocking setup indefinitely.
  CREATE_RC=0
  ( cd "$PROJECT_DIR" && run_with_timeout "$CREATE_TIMEOUT" \
      ddev composer "$CREATE_SUBCMD" --no-interaction "$CREATE_SPEC" </dev/null >&2 ) \
    || CREATE_RC=$?
  if [[ "$CREATE_RC" == "124" ]]; then
    # The limit only killed the host-side client: composer keeps running in
    # the web container and would go on writing the files the user is told to
    # remove. Stop it first.
    if ! ddev_stop_composer "$PROJECT_DIR"; then
      log_err "composer is still running in the web container of $PROJECT_DIR; stop the project ('ddev stop') before cleaning up."
    fi
    die "'ddev composer $CREATE_SUBCMD' did not finish within ${CREATE_TIMEOUT}s and was stopped. Check network access and 'ddev logs -s web', remove the partial project it left in $PROJECT_DIR (keep only .ddev/ and .git/: composer.json, composer.lock, vendor/, $DOCROOT/, recipes/ and the scaffolded dotfiles such as .editorconfig must go), then re-run; raise DRUPILOT_DDEV_CREATE_TIMEOUT (0 = no limit) for a slow network." 1
  elif [[ "$CREATE_RC" != "0" ]]; then
    die "'ddev composer $CREATE_SUBCMD' failed (exit $CREATE_RC). Check network access and the DDEV web container ('ddev logs -s web')." 1
  fi
  CORE_SOURCE="create"
  log_ok "Composer project created."
fi

# ---------------------------------------------------------------------------
# Step 5 — ensure Drush ^13 (required by Drupal 11)
# ---------------------------------------------------------------------------
HAS_DRUSH=0
if [[ -f "$PROJECT_DIR/composer.json" ]] && have_cmd jq; then
  if jq -e '(.require // {}) | has("drush/drush") or has("drush/drush:^13")' "$PROJECT_DIR/composer.json" >/dev/null 2>&1; then
    HAS_DRUSH=1
  fi
fi
if [[ "$HAS_DRUSH" == "1" ]]; then
  log_ok "Drush already required in composer.json — skipping."
else
  log_step "Requiring Drush ($DRUSH_CONSTRAINT)"
  ( cd "$PROJECT_DIR" && ddev composer require --no-interaction "$DRUSH_CONSTRAINT" >&2 ) \
    || log_warn "Could not require Drush automatically. Run 'ddev composer require $DRUSH_CONSTRAINT' inside $PROJECT_DIR."
fi

# ---------------------------------------------------------------------------
# Step 5b — Mark the test-bed, refresh the cached base core
# ---------------------------------------------------------------------------
# A root this run built from nothing (create-project, or a cached tree copied
# into an empty root) is a drupilot test-bed: /drupilot-clean may remove its
# vendor/ or the whole workspace. An existing project is never marked here.
drop_docroot_backup
if [[ "$DOCROOT_PRISTINE" != "true" && ( "$CORE_SOURCE" == "create" || "$CORE_SOURCE" == "cache" ) ]]; then
  log_warn "Not marking $PROJECT_DIR as a drupilot test-bed: its $DOCROOT/ held files before this run, so /drupilot-clean must treat it as your project."
elif [[ "$CORE_SOURCE" == "create" || "$CORE_SOURCE" == "cache" ]]; then
  testbed_mark "$PROJECT_DIR" "ddev-up.sh" "$CORE_CACHE_KEY" \
    || log_warn "Could not write the test-bed marker into $PROJECT_DIR/.drupilot.json (non-fatal)."
fi

# core_cache_store -> copy the freshly created tree into the cache (staged,
# then renamed into place). Best-effort: a failure only logs a warning.
core_cache_store() {
  local ver key cd stage dest docroot p
  ver="$(jq -r '((.packages // []) + (."packages-dev" // [])) | map(select(.name == "drupal/core")) | (.[0].version // empty)' \
    "$PROJECT_DIR/composer.lock" 2>/dev/null || true)"
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { log_info "Core version '${ver:-?}' is not a plain release — not caching the base core."; return 0; }
  [[ -f "$PROJECT_DIR/vendor/autoload.php" ]] || return 0
  key="php${PHP_TARGET}-${ver}"
  cd="$(core_cache_dir)"
  mkdir -p "$cd" 2>/dev/null || return 0
  stage="$cd/.staging-${key}.$$"
  dest="$cd/$key"
  rm -rf "${stage:?}" 2>/dev/null || true
  if ! CORE_CACHE_METHOD="$(fast_copy_tree "$PROJECT_DIR" "$stage/tree")"; then
    chmod -R u+w "$stage" 2>/dev/null || true; rm -rf "${stage:?}"
    log_warn "Could not copy the new project into the core cache (non-fatal)."
    return 0
  fi
  # Strip everything that belongs to THIS project, not to the base core: the
  # DDEV config, drupilot's own files, DDEV-generated settings and files/.
  docroot="$DOCROOT"
  chmod u+w "$stage/tree/$docroot/sites/default" 2>/dev/null || true
  for p in .ddev .git .drupilot .drupilot.json .phpstan-cache .drupilot-coverage \
           "$docroot/sites/default/settings.php" "$docroot/sites/default/settings.ddev.php" \
           "$docroot/sites/default/settings.local.php" "$docroot/sites/default/.gitignore" \
           "$docroot/sites/default/files" "$docroot/sites/simpletest" \
           "$docroot/modules/custom" "$docroot/themes/custom" "$docroot/profiles/custom"; do
    if [[ -e "$stage/tree/$p" || -L "$stage/tree/$p" ]]; then
      chmod -R u+w "$stage/tree/$p" 2>/dev/null || true
      rm -rf "${stage:?}/tree/$p"
    fi
  done
  jq -n --arg v "$ver" --arg php "$PHP_TARGET" --arg c "$DRUPAL_TARGET" --arg d "$DRUSH_CONSTRAINT" \
     --arg spec "$CREATE_SPEC" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ep "$(date +%s)" \
     --arg pv "$(plugin_version)" --arg dr "$docroot" \
     '{version: $v, php: $php, constraint: $c, drush: $d, created_from: $spec, docroot: $dr,
       created_at: $at, created_epoch: ($ep | tonumber), drupilot_version: $pv, complete: true}' \
     > "$stage/meta.json" 2>/dev/null || { rm -rf "${stage:?}"; return 0; }
  if [[ -d "$dest" ]]; then chmod -R u+w "$dest" 2>/dev/null || true; rm -rf "${dest:?}"; fi
  if mv "$stage" "$dest" 2>/dev/null; then
    CORE_CACHE_KEY="$key"; CORE_CACHE_STORED="true"
    log_ok "Cached this base core as $key ($CORE_CACHE_METHOD) — the next setup with Drupal $ver and PHP $PHP_TARGET copies it instead of running create-project."
    core_cache_prune "$(config_get DRUPILOT_CORE_CACHE_KEEP 3)"
  else
    chmod -R u+w "$stage" 2>/dev/null || true; rm -rf "${stage:?}"
  fi
  return 0
}
# Only a tree built from nothing is cached (a pre-existing docroot's own files
# must never become everyone's base core).
if [[ "$CORE_SOURCE" == "create" && "$CORE_CACHE_MODE" != "off" && "$DOCROOT_PRISTINE" == "true" ]] && have_cmd jq; then
  core_cache_store || true
  [[ "$CORE_CACHE_STORED" == "true" ]] && testbed_mark "$PROJECT_DIR" "ddev-up.sh" "$CORE_CACHE_KEY" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Step 6 — Freeze the resolved versions in the reproducibility lockfile
# ---------------------------------------------------------------------------
# Best-effort: capture the exact Drupal core (and whatever composer.lock holds so
# far) so later runs reuse it (deterministic mode). Never fail setup over the lock.
bash "$PLUGIN_ROOT_DIR/scripts/env/lock-sync.sh" --dir "$PROJECT_DIR" >/dev/null 2>&1 || true

# The environment exists again: clear a /drupilot-clean 'removed' record on
# the modules of this root (next-step.sh stops recommending /drupilot-setup).
env_status_record "$PROJECT_DIR" ready

# PHP 8.5 on the core this test-bed actually has (warn, never block).
if php_target_unconfirmed "$PHP_TARGET"; then
  _core="$(drupal_core_version "$PROJECT_DIR")"
  if [[ -n "$_core" && "$(php_supported_for "$_core" "$PHP_TARGET")" == "no" ]]; then
    log_warn "PHP $PHP_TARGET needs Drupal 11.3 or later; this test-bed has Drupal $_core."
  fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
hr
log_ok "DDEV Drupal $DRUPAL_TARGET environment is ready (PHP ${EFFECTIVE_PHP:-$PHP_TARGET})."
log_plain "Next: 'ddev-add-ons.sh --contrib [--selenium]' to add the contrib + Selenium add-ons,"
log_plain "      then place your module/theme under $DOCROOT/modules/custom or $DOCROOT/themes/custom."
if [[ "$JSON_OUT" == "1" ]] && have_cmd jq; then
  jq -c -n --arg project_dir "$PROJECT_DIR" --arg project_name "$PROJECT_NAME" \
    --arg php_version "${EFFECTIVE_PHP:-$PHP_TARGET}" --arg primary_url "$PRIMARY_URL" \
    --arg drupal_target "$DRUPAL_TARGET" --arg core_source "$CORE_SOURCE" \
    --arg ck "$CORE_CACHE_KEY" --arg cm "$CORE_CACHE_METHOD" --arg cs "$CORE_CACHE_SECS" \
    --argjson stored "$CORE_CACHE_STORED" \
    '{project_dir:$project_dir, project_name:$project_name, php_version:$php_version,
      primary_url:$primary_url, drupal_target:$drupal_target, core_source:$core_source,
      core_cache: (if $ck == "" then null else
        {key: $ck, method: (if $cm == "" then null else $cm end),
         seconds: (if $cs == "" then null else ($cs | tonumber) end), stored: $stored} end)}'
fi
exit 0
