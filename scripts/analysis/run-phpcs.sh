#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/run-phpcs.sh
# Run PHP_CodeSniffer with the Drupal + DrupalPractice coding standards against
# a module/theme. With --fix, run phpcbf (autofix) first and then phpcs to
# report whatever remains.
#
# The Drupal/DrupalPractice standards come from drupal/coder. The coder branch
# (PHPCS 3.x vs 4.x) is selected at setup time via DRUPILOT_CODER_CONSTRAINT;
# this script does not install anything, it only runs the binaries.
#
# Usage:
#   run-phpcs.sh --subject DIR [--fix] [--json]
#
# Options:
#   --subject DIR   Path to the module/theme to check (relative to the Drupal
#                   root or absolute). Required.
#   --fix           Run phpcbf first (autofix), then re-check with phpcs.
#   --json          Emit PHPCS's native JSON (`--report=json`) on STDOUT —
#                   `{totals:{errors,warnings,fixable}, files:{...}}` — for a
#                   reproducible count. With --fix, phpcbf output is kept off
#                   stdout so it stays pure JSON.
#   -h, --help      Show this help.
#
# Gate: `analyze` profile (git + jq + composer/php).
# Output: status/logging on STDERR; phpcs/phpcbf reports (or JSON) on STDOUT.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Extension list from PROMPT 2.3.
PHPCS_EXTENSIONS="php,module,inc,install,test,profile,theme,info,txt,md,yml"
PHPCS_STANDARD="Drupal,DrupalPractice"

SUBJECT=""
FIX=0
AS_JSON=0

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --fix) FIX=1; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

[[ -n "$SUBJECT" ]] || die "Missing --subject DIR (the module/theme to check)." 1

# --- Gate: analyze --------------------------------------------------------
PREFLIGHT="$(plugin_root)/scripts/env/preflight.sh"
if ! bash "$PREFLIGHT" --profile analyze --quiet >/dev/null 2>&1; then
  log_err "The 'analyze' requirements are not satisfied; cannot run PHPCS."
  bash "$PREFLIGHT" --profile analyze || true
  exit 2
fi

# --- Locate the Drupal root and resolve the subject relative to it --------
DRUPAL_ROOT="$(find_drupal_root "$SUBJECT" 2>/dev/null || find_drupal_root "$PWD" 2>/dev/null || true)"
[[ -n "$DRUPAL_ROOT" ]] || die "Could not locate a Drupal root (web/core or .ddev/config.yaml) from '$SUBJECT'. Run /drupilot-setup first." 2

SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
if [[ -z "$SUBJECT_ABS" ]]; then
  SUBJECT_ABS="$(cd "$DRUPAL_ROOT/$SUBJECT" 2>/dev/null && pwd || true)"
fi
[[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1

case "$SUBJECT_ABS" in
  "$DRUPAL_ROOT"/*) SUBJECT_REL="${SUBJECT_ABS#"$DRUPAL_ROOT"/}";;
  "$DRUPAL_ROOT")   SUBJECT_REL=".";;
  *) die "Subject '$SUBJECT_ABS' is outside the Drupal root '$DRUPAL_ROOT'." 1;;
esac

cd "$DRUPAL_ROOT"
RUNNER="$(drupal_runner "$DRUPAL_ROOT")"

log_info "Drupal root : $DRUPAL_ROOT"
log_info "Subject     : $SUBJECT_REL"
log_info "Standard    : $PHPCS_STANDARD"
if [[ -n "$RUNNER" ]]; then
  log_info "Runner      : DDEV ($RUNNER)"
else
  log_info "Runner      : host (vendor/bin)"
fi

# --- Verify the binaries are present --------------------------------------
[[ -f "$DRUPAL_ROOT/vendor/bin/phpcs" ]] || \
  die "vendor/bin/phpcs is missing. Install drupal/coder first (e.g. via /drupilot-setup)." 2
if [[ "$FIX" == "1" && ! -f "$DRUPAL_ROOT/vendor/bin/phpcbf" ]]; then
  die "vendor/bin/phpcbf is missing but --fix was requested. Install drupal/coder first." 2
fi

# --- Ensure the Drupal standards are registered (idempotent) --------------
# `phpcs -i` must list Drupal and DrupalPractice or the run silently checks
# against the wrong standard — a real source of divergent results. coder ships a
# Composer plugin that normally registers them; if it did not, register all three
# paths ourselves (PROMPT 1.4) and re-verify. Idempotent: a no-op when present.
declare -a ICMD=()
[[ -n "$RUNNER" ]] && read -r -a ICMD <<<"$RUNNER"
if ! "${ICMD[@]}" vendor/bin/phpcs -i 2>/dev/null | grep -qi 'DrupalPractice'; then
  log_warn "Drupal/DrupalPractice standards not registered yet — registering them now (idempotent)."
  "${ICMD[@]}" vendor/bin/phpcs --config-set installed_paths \
    vendor/drupal/coder/coder_sniffer,vendor/sirbrillig/phpcs-variable-analysis,vendor/slevomat/coding-standard \
    >/dev/null 2>&1 || true
  if "${ICMD[@]}" vendor/bin/phpcs -i 2>/dev/null | grep -qi 'DrupalPractice'; then
    log_ok "Registered the Drupal/DrupalPractice standards."
  else
    log_warn "Could not auto-register the Drupal standards. Ensure drupal/coder is installed and its phpcodesniffer-composer-installer plugin was allowed (composer config allow-plugins)."
  fi
fi

# run_tool <bin> [extra args...] -> run phpcs/phpcbf with the Drupal standards.
run_tool() {
  local bin="$1"; shift
  declare -a cmd=()
  [[ -n "$RUNNER" ]] && read -r -a cmd <<<"$RUNNER"
  cmd+=("vendor/bin/$bin" "--standard=$PHPCS_STANDARD" "--extensions=$PHPCS_EXTENSIONS" "$@" "$SUBJECT_REL")
  log_step "$bin: ${cmd[*]}"
  set +e
  "${cmd[@]}"
  local rc=$?
  set -e
  return "$rc"
}

# --- Optional autofix pass (phpcbf) ---------------------------------------
if [[ "$FIX" == "1" ]]; then
  log_info "Autofixing with phpcbf (this modifies files in place)."
  # phpcbf returns 1 when it fixed something and 2 on real errors; neither is fatal here.
  # In --json mode keep phpcbf's report off stdout so the only thing there is JSON.
  if [[ "$AS_JSON" == "1" ]]; then run_tool phpcbf >&2 || true; else run_tool phpcbf || true; fi
  hr
fi

# --- Report pass (phpcs) --------------------------------------------------
if [[ "$AS_JSON" == "1" ]]; then
  # Native JSON report; capture stdout so it stays pure JSON (logs are on stderr).
  set +e
  OUT="$(run_tool phpcs --report=json 2>/dev/null)"
  RC=$?
  set -e
  [[ -n "$OUT" ]] && printf '%s\n' "$OUT"
else
  run_tool phpcs
  RC=$?
fi

hr
if [[ "$RC" -eq 0 ]]; then
  log_ok "PHPCS clean: no Drupal/DrupalPractice violations in $SUBJECT_REL."
else
  if [[ "$FIX" == "1" ]]; then
    log_warn "PHPCS still reports violations after phpcbf (exit $RC); these need manual fixes."
  else
    log_warn "PHPCS found violations (exit $RC). Re-run with --fix to auto-correct what is fixable."
  fi
fi
exit "$RC"
