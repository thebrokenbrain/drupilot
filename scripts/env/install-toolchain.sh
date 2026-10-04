#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/install-toolchain.sh
# Install the Composer dev toolchain into a Drupal 11 DDEV project, pinned
# deterministically, then PROVE it works (a smoke test) and freeze it in the
# lock. Replaces the hand-written `ddev composer require --dev ...` of setup.
#
# Packages (config/defaults.json .packages): palantirnet/drupal-rector,
# rector/rector, phpstan/phpstan, phpstan/extension-installer,
# mglaman/phpstan-drupal, phpstan/phpstan-deprecation-rules, drupal/coder
# (DRUPILOT_CODER_CONSTRAINT), drupal/core-dev (matched to the installed core
# via core_dev_requirement) and, with --with-upgrade-status, drupal/upgrade_status.
# Drush is NOT installed here (ddev-up.sh owns it, as a regular require).
#
# The known-good reference is a matrix (config/toolchain-reference.json): one
# cell per Drupal major family. The test-bed's cell is the one its lock records
# (toolchain_cell), else the one config/targets/<major>.json names for the
# installed core's major; a lock drupilot 0.9 wrote (it pins rector/rector and
# records no cell) is cell legacy_v1, 0.9's own set, until it is refreshed
# (--source reference), and a notice says so. A cell that is not verified yet
# (cell 12 while Drupal 12 is a pre-release) pins nothing: its packages resolve
# from the ranges, with a warning.
#
# Where each version comes from (--source, default DRUPILOT_TOOLCHAIN_SOURCE=auto):
#   auto       Deterministic mode (DRUPILOT_DETERMINISTIC, default true):
#                - the project lock, when it pins EVERY package of the
#                  cell's known-good set (a complete, previously working set);
#                - otherwise the cell's set as a whole (a partial lock is never
#                  mixed with the reference: that combination was never
#                  tested);
#                - packages the reference does not pin: lock, else the range.
#              Non-deterministic mode: the .packages ranges (fresh resolve).
#   reference  The set of the installed core's cell, ignoring the lock (the
#              repair path after a broken resolve, and the refresh of a 0.9
#              lock); the lock is then refreshed from what got installed and
#              records the cell.
#   range      The .packages ranges only (fresh resolve).
# If Composer cannot resolve the pinned set against this project (e.g. a newer
# core needs a newer PHPStan), it retries once with the ranges and says so.
#
# After installing it runs the smoke test (rector_smoke in common.sh: a Rector
# dry-run of a trivial file with the Drupal 10 set, plus `phpstan --version`) and
# re-syncs the lock (lock-sync.sh) so the exact installed toolchain is frozen.
# Idempotent: when every pinned package is already installed at its exact
# version, Composer is not run at all.
#
# Usage:
#   install-toolchain.sh [--subject DIR | --dir ROOT] [--source auto|reference|range]
#                        [--with-upgrade-status] [--no-core-dev] [--smoke-only]
#                        [--dry-run] [--json] [-h|--help]
#
# Options:
#   --subject DIR          A module/theme path; the Drupal root is derived from it.
#   --dir ROOT             The Drupal project root (composer.json + .ddev/).
#   --source S             Version source (see above). Default: auto.
#   --with-upgrade-status  Also install drupal/upgrade_status.
#   --no-core-dev          Skip drupal/core-dev (PHPUnit + test deps).
#   --smoke-only           Do not install; only run the smoke test (+ diagnostics).
#   --dry-run              Print the resolved package specs; run nothing.
#   --json                 JSON summary on STDOUT:
#                          {ok, status, root, source, deterministic, cell,
#                           packages: [{name, spec, source, installed}], composer_ran,
#                           fallback_to_ranges, smoke:{ok, error}, lock_synced}
#                          status: installed | unchanged | dry-run | smoke-only |
#                                  smoke-failed | composer-failed
#   -h, --help             Show this help.
#
# Gate: the `setup` profile (Docker + daemon + DDEV) and a running DDEV project
# (not needed for --dry-run).
# Exit codes: 0 ok · 1 usage error or Composer failure · 2 gate (requirements
# missing, no Drupal root, DDEV not running) · 3 the toolchain is installed but
# BROKEN (smoke test failed — the diagnostic names the known-good versions).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
ROOT=""
SOURCE=""
WITH_US=0
WITH_CORE_DEV=1
SMOKE_ONLY=0
DRY=0
AS_JSON=0

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --dir|--root) ROOT="${2:-}"; shift 2;;
    --dir=*|--root=*) ROOT="${1#*=}"; shift;;
    --source) SOURCE="${2:-}"; shift 2;;
    --source=*) SOURCE="${1#*=}"; shift;;
    --with-upgrade-status) WITH_US=1; shift;;
    --no-core-dev) WITH_CORE_DEV=0; shift;;
    --smoke-only) SMOKE_ONLY=1; shift;;
    --dry-run) DRY=1; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_err "Unknown argument: $1"; usage >&2; exit 1;;
  esac
done

for _v in "$SUBJECT" "$ROOT"; do
  case "$_v" in \<*\>|*\<*\>*) die "Got the unsubstituted placeholder '$_v' — pass the real path." 1;; esac
done
[[ -n "$SOURCE" ]] || SOURCE="$(config_get DRUPILOT_TOOLCHAIN_SOURCE auto)"
SOURCE="$(lc "$SOURCE")"
case "$SOURCE" in auto|reference|range) ;; *) die "Invalid --source '$SOURCE' (expected auto, reference or range)." 1;; esac
have_cmd jq || die "jq is required (run /drupilot-doctor)." 2

# --- Resolve the Drupal root ------------------------------------------------
# A --subject resolves to the root it is ported in (subject_project_root): never
# a project checkout without installed core, e.g. a monorepo with a committed
# .ddev/, whose composer.json belongs to the user.
if [[ -z "$ROOT" && -n "$SUBJECT" ]]; then
  ROOT="$(subject_project_root "$SUBJECT")"
elif [[ -z "$ROOT" ]]; then
  ROOT="$(drupal_run_root "$PWD" 2>/dev/null || true)"
fi
[[ -n "$ROOT" && -d "$ROOT" ]] || die "Could not locate the Drupal root (pass --dir ROOT, or run ddev-up.sh first)." 2
ROOT="$(cd "$ROOT" && pwd)"
[[ -f "$ROOT/composer.json" ]] || die "No composer.json at $ROOT — run ddev-up.sh first." 2
export DRUPILOT_PROJECT_DIR="$ROOT"
REF_FILE="$(toolchain_reference_file)"

DETERMINISTIC=true; deterministic_mode || DETERMINISTIC=false
# The toolchain cell: the lock's (a 0.9 lock: legacy_v1) when the lock decides
# (auto, deterministic), else the cell of the installed core's major.
if [[ "$SOURCE" == "auto" && "$DETERMINISTIC" == "true" ]]; then CELL="$(toolchain_cell_for "$ROOT")"
else CELL="$(toolchain_cell_for "$ROOT" fresh)"; fi
log_step "drupilot toolchain"
log_info "Drupal root   : $ROOT"
log_info "Version source: $SOURCE (deterministic: $DETERMINISTIC)"
log_info "Toolchain cell: $CELL"
if [[ "$CELL" == "legacy_v1" ]]; then
  log_warn "This project's lock was written by drupilot 0.9: it keeps 0.9's toolchain (legacy_v1) until you refresh it to cell $(toolchain_cell_for "$ROOT" fresh):"
  log_warn "  bash \"$(plugin_root)/scripts/env/install-toolchain.sh\" --dir \"$ROOT\" --source reference"
elif [[ "$SOURCE" != "range" ]] && ! toolchain_cell_verified "$CELL"; then
  log_warn "Toolchain cell $CELL has no verified set yet: its packages resolve from the config/defaults.json ranges."
fi

# --- Gate (not for a dry run) -----------------------------------------------
if [[ "$DRY" != "1" ]]; then
  if ! bash "$(plugin_root)/scripts/env/preflight.sh" --profile setup --quiet >/dev/null 2>&1; then
    log_err "The 'setup' requirements are not satisfied; cannot install the toolchain."
    bash "$(plugin_root)/scripts/env/preflight.sh" --profile setup >&2 || true
    exit 2
  fi
  ddev_ensure_running "$ROOT" \
    || die "The DDEV project at $ROOT is not running and could not be started (run ddev-up.sh, or 'ddev start')." 2
  ddev_running "$ROOT" || die "The DDEV project at $ROOT is not running (run ddev-up.sh, or 'ddev start')." 2
fi

# --- Build the package list --------------------------------------------------
# Parallel arrays (bash 3.2: no associative arrays): name, range spec.
PKG_NAMES=()
PKG_RANGES=()
add_pkg() {   # add_pkg <config .packages key> [constraint override]
  local spec name range
  spec="$(config_json ".packages.$1" "")"
  [[ -n "$spec" ]] || return 0
  name="${spec%%:*}"
  range=""; [[ "$spec" == *:* ]] && range="${spec#*:}"
  [[ -n "${2:-}" ]] && range="$2"
  PKG_NAMES+=("$name"); PKG_RANGES+=("$range")
  return 0
}
add_pkg drupal_rector
add_pkg rector
add_pkg phpstan
add_pkg phpstan_extension_installer
add_pkg phpstan_drupal
add_pkg phpstan_deprecation_rules
add_pkg coder "$(config_get DRUPILOT_CODER_CONSTRAINT "^8.3")"
[[ "$WITH_US" == "1" ]] && add_pkg upgrade_status
if [[ "$WITH_CORE_DEV" == "1" ]]; then
  _cd="$(core_dev_requirement "$ROOT")"
  PKG_NAMES+=("${_cd%%:*}"); PKG_RANGES+=("${_cd#*:}")
fi

# Is the lock a COMPLETE known-good set (every reference-pinned package we
# install is in the lock)? Only then is it preferred over the reference.
lock_complete=1
for i in "${!PKG_NAMES[@]}"; do
  n="${PKG_NAMES[$i]}"
  [[ -n "$(toolchain_reference_version "$n" "$CELL")" ]] || continue
  [[ -n "$(lock_get ".toolchain.\"$n\"" "")" ]] || { lock_complete=0; break; }
done

# spec_for <index> <mode:pinned|range> -> "<spec>\t<source>"
spec_for() {
  local i="$1" mode="$2" n r lockv refv
  n="${PKG_NAMES[$i]}"; r="${PKG_RANGES[$i]}"
  lockv="$(lock_get ".toolchain.\"$n\"" "")"
  refv="$(toolchain_reference_version "$n" "$CELL")"
  if [[ "$mode" == "pinned" ]]; then
    case "$SOURCE" in
      reference)
        if [[ -n "$refv" ]]; then printf '%s:%s\treference' "$n" "$refv"; return 0; fi;;
      auto)
        if [[ "$DETERMINISTIC" == "true" ]]; then
          if [[ -n "$refv" ]]; then
            if [[ "$lock_complete" == "1" && -n "$lockv" ]]; then printf '%s:%s\tlock' "$n" "$lockv"; return 0; fi
            printf '%s:%s\treference' "$n" "$refv"; return 0
          fi
          if [[ -n "$lockv" ]]; then printf '%s:%s\tlock' "$n" "$lockv"; return 0; fi
        fi;;
    esac
  fi
  if [[ -n "$r" ]]; then printf '%s:%s\trange' "$n" "$r"; else printf '%s\trange' "$n"; fi
  return 0
}

TAB=$'\t'
SPECS=(); SRCS=()
build_specs() {   # build_specs <pinned|range>
  local i line
  SPECS=(); SRCS=()
  for i in "${!PKG_NAMES[@]}"; do
    line="$(spec_for "$i" "$1")"
    SPECS+=("${line%%"$TAB"*}"); SRCS+=("${line#*"$TAB"}")
  done
  return 0
}
build_specs pinned

# Effective source label for the summary.
EFFECTIVE_SOURCE="range"
for s in "${SRCS[@]}"; do
  case "$s" in reference) EFFECTIVE_SOURCE="reference"; break;; lock) EFFECTIVE_SOURCE="lock";; esac
done

show_specs() {
  local i
  for i in "${!SPECS[@]}"; do log_plain "   $(printf '%-44s' "${SPECS[$i]}") (${SRCS[$i]})"; done
  return 0
}

# all_exact_installed -> 0 when every spec is an exact version already installed.
all_exact_installed() {
  local i spec n v inst
  for i in "${!SPECS[@]}"; do
    spec="${SPECS[$i]}"; n="${spec%%:*}"
    [[ "$spec" == *:* ]] || return 1
    v="${spec#*:}"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    inst="$(installed_package_version "$ROOT" "$n")"
    [[ "$inst" == "$v" ]] || return 1
  done
  return 0
}

COMPOSER_RAN=false
FALLBACK=false
STATUS=""
SMOKE_OK=null
SMOKE_ERR=""
LOCK_SYNCED=false

emit_json() {
  [[ "$AS_JSON" == "1" ]] || return 0
  local pk="[]" i n
  if [[ ${#SPECS[@]} -gt 0 ]]; then
    pk="$(for i in "${!SPECS[@]}"; do
            n="${SPECS[$i]%%:*}"
            jq -nc --arg name "$n" --arg spec "${SPECS[$i]}" --arg src "${SRCS[$i]}" \
                   --arg inst "$(installed_package_version "$ROOT" "$n")" \
              '{name:$name, spec:$spec, source:$src, installed:(if $inst=="" then null else $inst end)}'
          done | jq -sc .)"
  fi
  jq -n --arg status "$STATUS" --arg root "$ROOT" --arg source "$EFFECTIVE_SOURCE" \
        --arg requested "$SOURCE" --argjson det "$DETERMINISTIC" --argjson packages "$pk" \
        --argjson composer_ran "$COMPOSER_RAN" --argjson fallback "$FALLBACK" \
        --argjson smoke_ok "$SMOKE_OK" --arg smoke_err "$SMOKE_ERR" \
        --argjson lock_synced "$LOCK_SYNCED" --arg reference "$REF_FILE" --arg cell "$CELL" \
    '{ok: (($status|IN("installed","unchanged","dry-run","smoke-only")) and ($smoke_ok != false)),
      status:$status, root:$root, source:$source, requested_source:$requested,
      deterministic:$det, reference:$reference, cell:$cell, packages:$packages,
      composer_ran:$composer_ran, fallback_to_ranges:$fallback,
      smoke:{ok:$smoke_ok, error:(if $smoke_err=="" then null else $smoke_err end)},
      lock_synced:$lock_synced}'
  return 0
}

run_smoke() {
  log_step "Smoke test: Rector dry-run (Drupal 10 set) + phpstan --version"
  local out
  if out="$(rector_smoke "$ROOT")"; then
    SMOKE_OK=true
    log_ok "Toolchain smoke test passed."
    return 0
  fi
  SMOKE_OK=false; SMOKE_ERR="$out"
  log_err "Toolchain smoke test FAILED — the installed toolchain is broken:"
  printf '%s\n' "$out" | sed 's/^/     /' >&2
  toolchain_diagnostics "$ROOT"
  return 1
}

# --- Smoke only ---------------------------------------------------------------
if [[ "$SMOKE_ONLY" == "1" ]]; then
  SPECS=(); SRCS=(); EFFECTIVE_SOURCE="none"
  if run_smoke; then STATUS="smoke-only"; emit_json; exit 0; fi
  STATUS="smoke-failed"; emit_json; exit 3
fi

log_info "Packages:"
show_specs

# --- Dry run --------------------------------------------------------------------
if [[ "$DRY" == "1" ]]; then
  log_info "[dry-run] would run: ddev composer require --dev -W --no-interaction ${SPECS[*]}"
  log_info "[dry-run] then the smoke test and lock-sync.sh --dir $ROOT"
  STATUS="dry-run"; emit_json; exit 0
fi

cd "$ROOT"

# --- Install ----------------------------------------------------------------------
if all_exact_installed; then
  log_ok "Every package is already installed at its pinned version — Composer not run."
  STATUS="unchanged"
else
  # Composer plugins the toolchain relies on must be allowed explicitly, or a
  # non-interactive require refuses to run them.
  for plugin in phpstan/extension-installer dealerdirect/phpcodesniffer-composer-installer; do
    ddev composer config --no-plugins "allow-plugins.$plugin" true >/dev/null 2>&1 \
      || log_warn "Could not allow the Composer plugin $plugin."
  done
  log_step "ddev composer require --dev -W --no-interaction ${SPECS[*]}"
  COMPOSER_RAN=true
  if ddev composer require --dev -W --no-interaction "${SPECS[@]}" >&2; then
    STATUS="installed"
  elif [[ "$EFFECTIVE_SOURCE" != "range" ]]; then
    log_warn "The pinned toolchain ($EFFECTIVE_SOURCE) does not resolve against this project; retrying with the .packages ranges."
    FALLBACK=true
    build_specs range
    EFFECTIVE_SOURCE="range"
    show_specs
    if ddev composer require --dev -W --no-interaction "${SPECS[@]}" >&2; then
      STATUS="installed"
    else
      STATUS="composer-failed"
    fi
  else
    STATUS="composer-failed"
  fi
  if [[ "$STATUS" == "composer-failed" ]]; then
    log_err "Composer could not install the toolchain (see its output above)."
    emit_json; exit 1
  fi
  log_ok "Toolchain installed."
fi

# PHPCS: coder's installer plugin registers the standards; report if it did not.
if ddev exec vendor/bin/phpcs -i 2>/dev/null | grep -q 'DrupalPractice'; then
  log_ok "PHPCS standards Drupal + DrupalPractice are registered."
else
  log_warn "phpcs -i does not list Drupal/DrupalPractice yet (run-phpcs.sh registers installed_paths on its first run)."
fi

# --- Smoke test + lock --------------------------------------------------------------
SMOKE_RC=0
run_smoke || SMOKE_RC=3

if bash "$(plugin_root)/scripts/env/lock-sync.sh" --dir "$ROOT" >/dev/null 2>&1; then
  LOCK_SYNCED=true
  # A refreshed lock names its cell; a 0.9 lock reused as is stays legacy_v1.
  [[ "$CELL" == "legacy_v1" ]] || DRUPILOT_PROJECT_DIR="$ROOT" lock_set .toolchain_cell "$CELL" \
    || log_warn "Could not record the toolchain cell in the lock."
  log_info "Lock re-synced: $(drupilot_lock_file "$ROOT")"
else
  log_warn "Could not re-sync the lock (lock-sync.sh)."
fi

if [[ "$SMOKE_RC" != "0" ]]; then
  STATUS="smoke-failed"
  if [[ "$EFFECTIVE_SOURCE" != "reference" ]]; then
    log_warn "This set was resolved from the $EFFECTIVE_SOURCE; re-run with '--source reference' to install the known-good set."
  fi
  emit_json; exit 3
fi
emit_json
exit 0
