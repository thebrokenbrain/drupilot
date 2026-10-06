#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/run-phpstan.sh
# Run PHPStan (with phpstan-drupal + deprecation rules) against a module/theme.
#
# Level defaults to DRUPILOT_PHPSTAN_LEVEL (2 = deprecation detection, the level
# that drupal-check fixes). The refactor phase raises it to 5-6
# (DRUPILOT_PHPSTAN_LEVEL_REFACTOR). PHPStan needs the Drupal core tree present
# but does NOT bootstrap a database.
#
# The config is the root's phpstan.neon (else phpstan.neon.dist). A drupilot
# render nobody edited (its sha256 is the one kept in the root's lock) follows
# the current upgrade plan: when the plan moved since it was rendered (the
# port's final freeze, a refactor), it is re-rendered first, after a backup,
# with its own profile (ADR 0020). A hand-edited one is used as it is.
#
# Usage:
#   run-phpstan.sh --subject DIR [--level N] [--json]
#
# Options:
#   --subject DIR   Path to the module/theme to analyse (relative to the Drupal
#                   root or absolute). Required.
#   --level N       PHPStan rule level (default: DRUPILOT_PHPSTAN_LEVEL).
#   --json          Emit PHPStan's native JSON (`--error-format=json`) on STDOUT —
#                   `{totals:{errors,file_errors}, files:{...}}` — for a reproducible
#                   count the viability analyst can read instead of estimating.
#                   drupilot adds one key, `drupilot`:
#                   {status: clean|findings|crashed, exit_code, phpstan_exit_code,
#                    notices:[...], crash:[...], runner:{runner: ddev|host,
#                    php_version, tool_version}}, and sorts the report (files
#                    by path, their messages by line, identifier and message,
#                    the general errors by text: DET-2). A DET-1 refusal
#                    (exit 3) is reported as crashed, its reason in crash.
#                    When PHPStan crashed (no
#                   report produced) `totals` is null, `files` is {} and the
#                   reason is in `drupilot.crash` — never a fake zero count.
#   -h, --help      Show this help.
#
# Gate: `analyze` profile (git + jq + composer/php).
# Output: status/logging on STDERR; PHPStan's own report (or JSON) on STDOUT.
# PHPStan's own STDERR is captured and relayed to STDERR, never discarded:
# PHP/configuration deprecation notices (e.g. phpstan-drupal's deprecated
# `drupal_root` parameter) are surfaced as warnings, and a crash (invalid
# config, missing path, fatal error, internal error) is reported as such.
#
# Determinism (DET-1): with DRUPILOT_DETERMINISTIC on, PHPStan never falls back
# to the host for a root that has a DDEV project, nor runs a phpstan/phpstan,
# phpstan-drupal or deprecation-rules other than the version the lock pins:
# exit 3. Its cache lives in the explicit tmpDir of phpstan.neon, keyed by the
# upgrade plan (ADR 0020).
#
# Exit codes: 0 no issues · 1 PHPStan reported findings (or a usage error) ·
# 2 requirements/toolchain missing · 3 PHPStan crashed or could not analyse, so
# there is NO verdict (do not read it as "found issues"), or a DET-1 violation
# (an unplanned host run, a tool version the lock does not pin).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
LEVEL=""
AS_JSON=0

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --level) LEVEL="${2:-}"; shift 2;;
    --level=*) LEVEL="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

[[ -n "$SUBJECT" ]] || die "Missing --subject DIR (the module/theme to analyse)." 1

# Resolve the level (CLI > config). Warn when the level comes from the
# environment (DRUPILOT_PHPSTAN_LEVEL), since that changes results vs the project
# default and is a common silent source of divergence between machines.
if [[ -z "$LEVEL" ]]; then
  if [[ -n "${DRUPILOT_PHPSTAN_LEVEL:-}" ]]; then
    log_warn "PHPStan level '$DRUPILOT_PHPSTAN_LEVEL' comes from the environment (DRUPILOT_PHPSTAN_LEVEL), overriding the project default; unset it to use the configured default."
  fi
  LEVEL="$(config_get DRUPILOT_PHPSTAN_LEVEL "2")"
fi
case "$LEVEL" in
  [0-9]|max) : ;;
  *) die "Invalid --level '$LEVEL' (expected 0-9 or 'max')." 1;;
esac

# --- Gate: analyze --------------------------------------------------------
PREFLIGHT="$(plugin_root)/scripts/env/preflight.sh"
if ! bash "$PREFLIGHT" --profile analyze --quiet >/dev/null 2>&1; then
  log_err "The 'analyze' requirements are not satisfied; cannot run PHPStan."
  bash "$PREFLIGHT" --profile analyze >&2 || true
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
# A configured but stopped DDEV project is started explicitly (drupal_runner
# itself never starts one); without DDEV the host toolchain is used.
ddev_ensure_running_or_host "$DRUPAL_ROOT" phpstan \
  || die "Could not start the DDEV project at $DRUPAL_ROOT, and there is no host vendor/bin/phpstan to fall back to." 1
RUNNER="$(drupal_runner "$DRUPAL_ROOT")"
# DET-1: in deterministic mode PHPStan runs where the plan put it, at the
# versions the lock pins.
_det1="$(DET1_RUNNER="$RUNNER" det1_message "$DRUPAL_ROOT" PHPStan phpstan/phpstan mglaman/phpstan-drupal phpstan/phpstan-deprecation-rules)"
if [[ -n "$_det1" ]]; then
  # The documented exit-3 shape on STDOUT for a --json caller, never empty.
  if [[ "$AS_JSON" == "1" ]] && have_cmd jq; then
    jq -n -c --arg m "$_det1" --argjson prov "$(tool_provenance "$DRUPAL_ROOT" "$RUNNER" phpstan/phpstan)" \
      '{totals: null, files: {}, errors: [$m], drupilot: {status: "crashed", exit_code: 3, phpstan_exit_code: null,
        notices: [], crash: [$m], runner: $prov}}'
  fi
  die "$_det1" 3
fi
PHP_TARGET="$(resolve_php_target)"

log_info "Drupal root : $DRUPAL_ROOT"
log_info "Subject     : $SUBJECT_REL"
log_info "Level       : $LEVEL"
log_info "PHP target  : $PHP_TARGET"
if [[ -n "$RUNNER" ]]; then
  log_info "Runner      : DDEV ($RUNNER)"
else
  log_info "Runner      : host (vendor/bin)"
fi

# --- Verify the PHPStan binary is present ---------------------------------
if [[ ! -f "$DRUPAL_ROOT/vendor/bin/phpstan" ]]; then
  die "vendor/bin/phpstan is missing. Install the toolchain first (e.g. via /drupilot-setup: 'composer require --dev phpstan/phpstan phpstan/extension-installer mglaman/phpstan-drupal phpstan/phpstan-deprecation-rules')." 2
fi

# --- Keep an untouched drupilot phpstan.neon on the current plan -----------
# Its phpVersion range and cache directory come from the upgrade plan (ADR
# 0020), which the port's final freeze or a refactor may have moved since the
# setup rendered it. An untouched render (its sha256 is the one kept in the
# root's lock) is re-rendered for the current plan, after a backup, keeping its
# profile; a hand-edited one, or one whose sha256 the lock no longer keeps, is
# used as it is.
if [[ -f "$DRUPAL_ROOT/phpstan.neon" ]] && grep -q '^# drupilot — phpstan.neon' "$DRUPAL_ROOT/phpstan.neon" 2>/dev/null \
   && render_sha_matches "$DRUPAL_ROOT" phpstan.neon "$DRUPAL_ROOT/phpstan.neon"; then
  _prof="$(sed -n 's/^# drupilot-phpstan-profile: \([a-z]*\)$/\1/p' "$DRUPAL_ROOT/phpstan.neon" 2>/dev/null | sed -n '1p')"
  _rj="$("$BASH" "$(plugin_root)/scripts/env/render-templates.sh" --root "$DRUPAL_ROOT" --subject-path "$SUBJECT_REL" \
          --only phpstan ${_prof:+--profile "$_prof"} --json 2> /dev/null < /dev/null || true)"
  if [[ "$(printf '%s' "$_rj" | jq -r '.files[0].status // empty' 2> /dev/null || true)" == "upgraded" ]]; then
    log_ok "phpstan.neon was an untouched drupilot render for another plan; regenerated for the current one (previous copy in .drupilot/backups/)."
  fi
fi

# --- Build the command ----------------------------------------------------
# Config precedence (deterministic): phpstan.neon > phpstan.neon.dist > extension
# defaults. Prefer the phpstan.neon at the Drupal root (extension-installer
# autoloads the Drupal + deprecation rules). If neither exists, PHPStan still runs
# with the extension defaults; warn so the user knows the analysis context.
declare -a CMD=()
[[ -n "$RUNNER" ]] && read -r -a CMD <<<"$RUNNER"
CMD+=(vendor/bin/phpstan analyse --no-progress --level "$LEVEL")
[[ "$AS_JSON" == "1" ]] && CMD+=(--error-format=json)

CONFIG=""
if [[ -f "$DRUPAL_ROOT/phpstan.neon" ]]; then
  CONFIG="phpstan.neon"
elif [[ -f "$DRUPAL_ROOT/phpstan.neon.dist" ]]; then
  CONFIG="phpstan.neon.dist"
fi
if [[ -n "$CONFIG" ]]; then
  CMD+=(--configuration "$CONFIG")
  log_ok "Using $CONFIG at the Drupal root."
  # A drupilot-generated config from <= 0.8.4 still sets the deprecated
  # `drupal: drupal_root:` (ignored by phpstan-drupal >= 1.3, which prints a
  # deprecation on every run). Never edit it silently: point at the fix.
  if grep -q '^# drupilot' "$CONFIG" 2>/dev/null \
     && grep -qE '^[[:space:]]*drupal_root[[:space:]]*:' "$CONFIG" 2>/dev/null; then
    log_info "$CONFIG was generated by an older drupilot and still sets the deprecated drupal_root parameter. Regenerate it with: render-templates.sh --root \"$DRUPAL_ROOT\" --only phpstan --subject-path \"$SUBJECT_REL\" --force"
  fi
else
  log_warn "No phpstan.neon at the Drupal root; running with extension defaults. Run /drupilot-setup to write one."
fi

CMD+=("$SUBJECT_REL")

log_step "PHPStan: ${CMD[*]}"

# Run. PHPStan exits 0 (no errors) or 1 — and 1 means EITHER "found errors" OR
# "could not analyse" (invalid config, missing path, fatal error). The two are
# told apart by the report on stdout: a crash produces none. stdout and stderr
# are both captured (never discarded): stdout is re-emitted as the report,
# stderr is relayed to our stderr, and its deprecation notices are surfaced.
OUT_F="$(mktemp)"; ERR_F="$(mktemp)"
trap 'rm -f "$OUT_F" "$ERR_F"' EXIT
set +e
"${CMD[@]}" >"$OUT_F" 2>"$ERR_F"
PHPSTAN_RC=$?
set -e

# Clean stderr: strip ANSI colors and DDEV's own "Failed to execute command"
# wrapper line (it only repeats the exit status).
ERR_CLEAN="$(sed -e $'s/\x1b\\[[0-9;]*m//g' "$ERR_F" | grep -vE 'Failed to execute command .*: exit status [0-9]+' || true)"
# Deprecation notices (PHP "Deprecated:" lines, possibly printed twice: once by
# the error log, once by display_errors), de-duplicated.
NOTICES="$(printf '%s\n' "$ERR_CLEAN" | grep -iE '(^|[[:space:]])(PHP )?Deprecated:|User Deprecated' \
  | sed -E 's/^[[:space:]]*(PHP )?(User )?Deprecated:[[:space:]]*//' | sort -u || true)"
OTHER_ERR="$(printf '%s\n' "$ERR_CLEAN" | grep -viE '(^|[[:space:]])(PHP )?Deprecated:|User Deprecated' | sed '/^[[:space:]]*$/d' || true)"

# Did PHPStan produce a report?
STATUS=""
if [[ "$AS_JSON" == "1" ]]; then
  # A JSON report is a single object with `totals`. Tolerate a stray leading
  # line (display_errors to stdout) by parsing from the first '{'.
  JSON_OUT="$(sed -n '/^{/,$p' "$OUT_F")"
  if [[ -n "$JSON_OUT" ]] && printf '%s' "$JSON_OUT" | jq -e 'type == "object" and has("totals")' >/dev/null 2>&1; then
    INTERNAL="$(printf '%s' "$JSON_OUT" | jq '[.errors[]? | select(type == "string" and test("Internal error"; "i"))] | length' 2>/dev/null || echo 0)"
    if [[ "$INTERNAL" != "0" ]]; then STATUS="crashed"
    elif [[ "$PHPSTAN_RC" -eq 0 ]]; then STATUS="clean"
    elif [[ "$PHPSTAN_RC" -eq 1 ]]; then STATUS="findings"
    else STATUS="crashed"; fi
  else
    STATUS="crashed"
  fi
else
  if [[ "$PHPSTAN_RC" -eq 0 ]]; then STATUS="clean"
  elif [[ "$PHPSTAN_RC" -eq 1 ]] && grep -qE 'Found [0-9]+ errors?' "$OUT_F"; then
    if grep -qiE 'Internal error' "$OUT_F"; then STATUS="crashed"; else STATUS="findings"; fi
  else
    STATUS="crashed"
  fi
  cat "$OUT_F"
fi

case "$STATUS" in
  clean) RC=0;; findings) RC=1;; *) RC=3;;
esac

if [[ -n "$NOTICES" ]]; then
  while IFS= read -r n; do
    [[ -n "$n" ]] && log_warn "PHPStan notice: $n"
  done <<<"$NOTICES"
  if printf '%s' "$NOTICES" | grep_q 'drupal_root parameter is deprecated'; then
    log_info "Fix: remove the 'drupal: drupal_root:' block from $CONFIG (phpstan-drupal discovers the Drupal root itself); for a drupilot-generated config, regenerate it with scripts/env/render-templates.sh --only phpstan --force."
  fi
fi
if [[ "$STATUS" == "crashed" && -n "$OTHER_ERR" ]]; then
  log_err "PHPStan could not complete the analysis:"
  printf '%s\n' "$OTHER_ERR" >&2
elif [[ -n "$OTHER_ERR" ]]; then
  printf '%s\n' "$OTHER_ERR" >&2
fi

if [[ "$AS_JSON" == "1" ]]; then
  NOTICES_JSON="$(printf '%s\n' "$NOTICES" | jq -R . | jq -sc 'map(select(length > 0))')"
  CRASH_JSON='[]'
  [[ "$STATUS" == "crashed" ]] && CRASH_JSON="$(printf '%s\n' "$OTHER_ERR" | jq -R . | jq -sc 'map(select(length > 0))')"
  META="$(jq -nc --arg status "$STATUS" --argjson rc "$RC" --argjson prc "$PHPSTAN_RC" \
    --argjson notices "$NOTICES_JSON" --argjson crash "$CRASH_JSON" \
    --argjson prov "$(tool_provenance "$DRUPAL_ROOT" "$RUNNER" phpstan/phpstan)" \
    '{status: $status, exit_code: $rc, phpstan_exit_code: $prc, notices: $notices, crash: $crash, runner: $prov}')"
  if [[ "$STATUS" != "crashed" ]] || printf '%s' "${JSON_OUT:-}" | jq -e 'has("totals")' >/dev/null 2>&1; then
    # Sorted (DET-2): files by path, each file's messages by line, identifier
    # and message, the general errors by text.
    printf '%s' "$JSON_OUT" | jq -c --argjson m "$META" '. + {drupilot: $m}
      | (if (.files | type) == "object" then .files |= (to_entries | sort_by(.key)
          | map(if (.value.messages | type) == "array" then .value.messages |= sort_by([(.line // 0), (.identifier // ""), (.message // "")]) else . end)
          | from_entries) else . end)
      | (if (.errors | type) == "array" then .errors |= sort else . end)'
  else
    jq -nc --argjson m "$META" '{totals: null, files: {}, errors: $m.crash, drupilot: $m}'
  fi
fi

hr
case "$STATUS" in
  clean)    log_ok "PHPStan reported no issues at level $LEVEL for $SUBJECT_REL.";;
  findings) log_warn "PHPStan found issues at level $LEVEL (exit $PHPSTAN_RC). Review the report above.";;
  *)        log_err "PHPStan crashed or could not analyse $SUBJECT_REL (PHPStan exit $PHPSTAN_RC): there is NO verdict. Fix the cause above and re-run (exit 3).";;
esac
exit "$RC"
