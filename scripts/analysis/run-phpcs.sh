#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/run-phpcs.sh
# Run PHP_CodeSniffer against a module/theme. With --fix, run phpcbf (autofix)
# first and then phpcs to report whatever remains.
#
# Ruleset: the subject's OWN ruleset wins when it ships one (.phpcs.xml,
# phpcs.xml, .phpcs.xml.dist or phpcs.xml.dist — PHPCS's discovery order),
# looked up from the subject up to the Drupal root, then from its physical path
# up to its git top level, then in the origin checkout a copy placement left
# behind (find_phpcs_ruleset in common.sh). drupilot's own generated
# phpcs.xml.dist (<ruleset name="drupilot">) is never treated as the project's.
# Without a project ruleset it uses Drupal,DrupalPractice (drupal/coder), as
# before. A project ruleset that PHPCS cannot load (e.g. it references a
# standard such as PHPCompatibility that is not installed in the test-bed) is
# reported and drupilot falls back to Drupal,DrupalPractice for the run.
#
# testVersion: `--runtime-set testVersion <target>-` is always passed (target =
# DRUPILOT_PHP_TARGET), so a ruleset using PHPCompatibility never runs with a
# null testVersion (PHPCompatibility then fails with "trim(): Passing null").
# Two exceptions keep a project's deliberate choice: a ruleset that sets
# <config name="testVersion"> is left alone (a CLI --runtime-set would override
# it), and a ruleset that wrongly declares testVersion as a <property> inside a
# <rule> gets that value passed through --runtime-set. --test-version or
# DRUPILOT_PHPCS_TEST_VERSION force a value in every case.
#
# The Drupal/DrupalPractice standards come from drupal/coder. The coder branch
# (PHPCS 3.x vs 4.x) is selected at setup time via DRUPILOT_CODER_CONSTRAINT;
# this script does not install anything, it only runs the binaries.
#
# Usage:
#   run-phpcs.sh --subject DIR [--fix [--fix-scope changed|all]] [--json]
#                [--ruleset auto|drupilot|PATH] [--test-version VER]
#
# Options:
#   --subject DIR   Path to the module/theme to check (relative to the Drupal
#                   root or absolute). Required.
#   --fix           Run phpcbf first (autofix), then re-check with phpcs.
#   --fix-scope S   What phpcbf may touch: all (default) = the whole subject;
#                   changed = only the files the port changed, i.e. those that
#                   differ from the same pre-port git base as the local patch
#                   (git_port_base_ref) plus new untracked files. Phase 1 uses
#                   `changed` so autofixing never widens the minimal diff into
#                   files the port did not touch; the report pass still covers
#                   the whole subject. Without git (no base to compare with)
#                   phpcbf is skipped and the run is report-only.
#   --json          Emit PHPCS's native JSON (`--report=json`) on STDOUT —
#                   `{totals:{errors,warnings,fixable}, files:{...}}` — for a
#                   reproducible count. With --fix, phpcbf output is kept off
#                   stdout so it stays pure JSON. drupilot adds one key,
#                   `drupilot`: {ruleset, source: project|explicit|drupilot|
#                   fallback, location: subject|drupal-root|origin|
#                   outside-root|null,
#                   fallback_reason, test_version, test_version_source:
#                   explicit|ruleset-config|ruleset-property|php-target,
#                   runner: {runner: ddev|host, php_version, tool_version}};
#                   the report is sorted (files by path, their messages by
#                   line, column and source: DET-2).
#   --ruleset R     auto (default, DRUPILOT_PHPCS_RULESET): the project ruleset
#                   when found, else Drupal,DrupalPractice. drupilot: always
#                   Drupal,DrupalPractice (the pre-0.9 behavior). PATH: that
#                   ruleset file (absolute, or relative to the Drupal root);
#                   unlike an auto-detected one, an explicit ruleset that PHPCS
#                   cannot load is an error (exit 2), never a silent fallback.
#   --test-version V  Force PHPCompatibility's testVersion (e.g. 8.1-).
#                   Default: DRUPILOT_PHPCS_TEST_VERSION, else see above.
#   -h, --help      Show this help.
#
# The resolved choice is also written to the hidden per-subject state dir
# (phpcs-ruleset.json): port-report.sh renders it in its Verification section
# and the post-edit-lint hook reuses it, so both lint with the same rules.
#
# Gate: `analyze` profile (git + jq + composer/php).
# Output: status/logging on STDERR; phpcs/phpcbf reports (or JSON) on STDOUT.
# Determinism (DET-1): with DRUPILOT_DETERMINISTIC on, PHPCS never falls back to
# the host for a root that has a DDEV project, nor runs a drupal/coder other
# than the version the lock pins: exit 3.
#
# Exit codes: PHPCS's own (0 clean, non-zero violations or a PHPCS error) ·
# 1 usage · 2 requirements/toolchain missing · 3 also a DET-1 violation (an
# unplanned host run, a coder version the lock does not pin).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# Extension list from PROMPT 2.3.
PHPCS_EXTENSIONS="php,module,inc,install,test,profile,theme,info,txt,md,yml"
PHPCS_STANDARD="Drupal,DrupalPractice"

SUBJECT=""
FIX=0
FIX_SCOPE="all"
AS_JSON=0
RULESET_OPT=""
TV_OPT=""

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --fix) FIX=1; shift;;
    --fix-scope) FIX_SCOPE="${2:-}"; shift 2 || die "--fix-scope needs a value (changed|all)." 1;;
    --fix-scope=*) FIX_SCOPE="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    --ruleset) RULESET_OPT="${2:-}"; shift 2 || die "--ruleset needs a value (auto|drupilot|PATH)." 1;;
    --ruleset=*) RULESET_OPT="${1#*=}"; shift;;
    --test-version) TV_OPT="${2:-}"; shift 2 || die "--test-version needs a value (e.g. 8.3-)." 1;;
    --test-version=*) TV_OPT="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

[[ -n "$SUBJECT" ]] || die "Missing --subject DIR (the module/theme to check)." 1
case "$FIX_SCOPE" in changed|all) : ;; *) die "--fix-scope must be 'changed' or 'all' (got '$FIX_SCOPE')." 1;; esac
CALLER_PWD="$PWD"

# --- Gate: analyze --------------------------------------------------------
PREFLIGHT="$(plugin_root)/scripts/env/preflight.sh"
if ! bash "$PREFLIGHT" --profile analyze --quiet >/dev/null 2>&1; then
  log_err "The 'analyze' requirements are not satisfied; cannot run PHPCS."
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
ddev_ensure_running_or_host "$DRUPAL_ROOT" phpcs \
  || die "Could not start the DDEV project at $DRUPAL_ROOT, and there is no host vendor/bin/phpcs to fall back to." 1
RUNNER="$(drupal_runner "$DRUPAL_ROOT")"
# DET-1: in deterministic mode PHPCS runs where the plan put it, at the coder
# version the lock pins.
if det1_unplanned_host "$DRUPAL_ROOT" "$RUNNER"; then
  die "DET-1: $DRUPAL_ROOT has a DDEV project but DDEV is not running, so PHPCS would run on the host: start it ('ddev start'), or set DRUPILOT_DETERMINISTIC=false to accept the host run." 3
fi
if ! _det1="$(det1_tool_mismatch "$DRUPAL_ROOT" drupal/coder)"; then
  die "DET-1: $_det1. Reinstall the pinned toolchain (bash \"$(plugin_root)/scripts/env/install-toolchain.sh\" --dir \"$DRUPAL_ROOT\"), or set DRUPILOT_DETERMINISTIC=false." 3
fi

log_info "Drupal root : $DRUPAL_ROOT"
log_info "Subject     : $SUBJECT_REL"
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
if ! ${ICMD[@]+"${ICMD[@]}"} vendor/bin/phpcs -i 2>/dev/null | grep_q -i 'DrupalPractice'; then
  log_warn "Drupal/DrupalPractice standards not registered yet — registering them now (idempotent)."
  ${ICMD[@]+"${ICMD[@]}"} vendor/bin/phpcs --config-set installed_paths \
    vendor/drupal/coder/coder_sniffer,vendor/sirbrillig/phpcs-variable-analysis,vendor/slevomat/coding-standard \
    >/dev/null 2>&1 || true
  if ${ICMD[@]+"${ICMD[@]}"} vendor/bin/phpcs -i 2>/dev/null | grep_q -i 'DrupalPractice'; then
    log_ok "Registered the Drupal/DrupalPractice standards."
  else
    log_warn "Could not auto-register the Drupal standards. Ensure drupal/coder is installed and its phpcodesniffer-composer-installer plugin was allowed (composer config allow-plugins)."
  fi
fi

# --- Resolve the ruleset (project vs drupilot) and testVersion -------------
RS_MODE="$RULESET_OPT"
[[ -n "$RS_MODE" ]] || RS_MODE="$(config_get DRUPILOT_PHPCS_RULESET auto)"
[[ -n "$RS_MODE" ]] || RS_MODE="auto"
RS_SOURCE="drupilot"     # project | explicit | drupilot | fallback
RS_FILE=""               # host absolute path of the chosen ruleset file
RS_ARG=""                # what --standard gets (relative to the root under DDEV)
RS_LOCATION=""           # subject | drupal-root | origin
RS_REASON=""             # why a project ruleset was not used (fallback)
case "$RS_MODE" in
  drupilot) : ;;
  auto)
    RS_FILE="$(find_phpcs_ruleset "$SUBJECT_ABS" "$DRUPAL_ROOT" 2>/dev/null || true)"
    [[ -n "$RS_FILE" ]] && RS_SOURCE="project"
    ;;
  *)
    for _c in "$RS_MODE" "$DRUPAL_ROOT/$RS_MODE" "$CALLER_PWD/$RS_MODE"; do
      case "$_c" in /*) : ;; *) continue;; esac
      if [[ -f "$_c" ]]; then RS_FILE="$(cd "$(dirname "$_c")" && pwd)/$(basename "$_c")"; break; fi
    done
    [[ -n "$RS_FILE" ]] || die "PHPCS ruleset not found: '$RS_MODE' (expected auto, drupilot, or a ruleset file path)." 1
    RS_SOURCE="explicit"
    ;;
esac

if [[ -n "$RS_FILE" ]]; then
  case "$RS_FILE" in
    "$SUBJECT_ABS"/*) RS_LOCATION="subject";;
    "$DRUPAL_ROOT"/*) RS_LOCATION="drupal-root";;
    *) if [[ "$RS_SOURCE" == "explicit" ]]; then RS_LOCATION="outside-root"; else RS_LOCATION="origin"; fi;;
  esac
  case "$RS_FILE" in
    "$DRUPAL_ROOT"/*) RS_ARG="${RS_FILE#"$DRUPAL_ROOT"/}";;
    *)
      if [[ -z "$RUNNER" ]]; then
        RS_ARG="$RS_FILE"
      else
        # DDEV only mounts the Drupal root: stage a copy of an outside ruleset in
        # the gitignored artifacts dir. A ruleset whose relative references do
        # not survive the move fails the load probe below and falls back.
        _art="$(project_artifacts_dir "$DRUPAL_ROOT")"
        case "$_art" in
          "$DRUPAL_ROOT"/*)
            cp "$RS_FILE" "$_art/phpcs-project-ruleset.xml" 2>/dev/null               && RS_ARG="${_art#"$DRUPAL_ROOT"/}/phpcs-project-ruleset.xml"
            ;;
        esac
        [[ -n "$RS_ARG" ]] || RS_REASON="the ruleset is outside the Drupal root, which is all DDEV mounts"
      fi
      ;;
  esac
fi

# testVersion (PHPCompatibility). See the header for the precedence.
TV="$TV_OPT"; TV_SRC=""
[[ -n "$TV" ]] || TV="$(config_get DRUPILOT_PHPCS_TEST_VERSION "")"
if [[ -n "$TV" ]]; then
  TV_SRC="explicit"
elif [[ -n "$RS_FILE" && -n "$(phpcs_ruleset_value "$RS_FILE" config testVersion)" ]]; then
  TV="$(phpcs_ruleset_value "$RS_FILE" config testVersion)"; TV_SRC="ruleset-config"
elif [[ -n "$RS_FILE" && -n "$(phpcs_ruleset_value "$RS_FILE" property testVersion)" ]]; then
  TV="$(phpcs_ruleset_value "$RS_FILE" property testVersion)"; TV_SRC="ruleset-property"
else
  TV="$(resolve_php_target)-"; TV_SRC="php-target"
fi

# standard_args -> fill the global STD_ARGS for the resolved ruleset.
declare -a STD_ARGS=()
standard_args() {
  STD_ARGS=()
  if [[ "$RS_SOURCE" == "project" || "$RS_SOURCE" == "explicit" ]]; then
    STD_ARGS+=("--standard=$RS_ARG")
    # A ruleset that sets its own extensions keeps them; otherwise use the list
    # drupilot has always passed.
    grep -q '<arg[^>]*name="extensions"' "$RS_FILE" 2>/dev/null       || STD_ARGS+=("--extensions=$PHPCS_EXTENSIONS")
  else
    STD_ARGS+=("--standard=$PHPCS_STANDARD" "--extensions=$PHPCS_EXTENSIONS")
  fi
  [[ "$TV_SRC" == "ruleset-config" ]] || STD_ARGS+=("--runtime-set" "testVersion" "$TV")
  return 0
}

# A project ruleset must load (every referenced standard/sniff installed)
# before it is trusted: `phpcs -e` only explains the ruleset, it checks no file.
if [[ -n "$RS_FILE" && -z "$RS_REASON" ]]; then
  standard_args
  set +e
  _probe="$(${ICMD[@]+"${ICMD[@]}"} vendor/bin/phpcs "${STD_ARGS[@]}" -e 2>&1)"
  _prc=$?
  set -e
  if [[ "$_prc" -ne 0 ]]; then
    # The first line naming the problem, else PHPCS's last line. No match is
    # not an error: under pipefail a bare grep here would abort the script
    # (exit 1) before the explicit-ruleset refusal (exit 2) or the fallback.
    _why="$(printf '%s\n' "$_probe" | grep -E 'ERROR|does not exist|not installed' | sed -n '1p' || true)"
    [[ -n "$_why" ]] || _why="$(printf '%s\n' "$_probe" | grep -v '^[[:space:]]*$' | tail -n 1 || true)"
    RS_REASON="PHPCS cannot load it (exit $_prc): $(printf '%s' "$_why" | cut -c1-200)"
    RS_REASON="${RS_REASON%: }"; RS_REASON="${RS_REASON%.}"
  fi
fi
if [[ -n "$RS_REASON" && "$RS_SOURCE" == "explicit" ]]; then
  # An explicitly named ruleset (--ruleset PATH / DRUPILOT_PHPCS_RULESET=PATH)
  # runs as given or not at all: silently checking another standard would let
  # a caller (e.g. git-hooks.sh substituting a hook's phpcs task) report rules
  # that never ran as passing. Only an auto-detected ruleset falls back.
  die "The PHPCS ruleset ${RS_FILE} given explicitly cannot be used: ${RS_REASON}. Not falling back to ${PHPCS_STANDARD}: install the missing standard in the test-bed, or pass --ruleset auto|drupilot." 2
fi
if [[ -n "$RS_REASON" ]]; then
  log_warn "Project PHPCS ruleset ${RS_FILE} cannot be used: ${RS_REASON}."
  log_warn "Falling back to ${PHPCS_STANDARD} for this run (install the missing standard in the test-bed, or set DRUPILOT_PHPCS_RULESET=drupilot to silence this)."
  RS_SOURCE="fallback"
fi
standard_args
if [[ "$RS_SOURCE" == "project" || "$RS_SOURCE" == "explicit" ]]; then
  log_info "Ruleset     : ${RS_SOURCE} (${RS_FILE}, found in the ${RS_LOCATION})"
elif [[ "$RS_SOURCE" == "fallback" ]]; then
  log_info "Ruleset     : fallback to drupilot default (${PHPCS_STANDARD})"
else
  log_info "Ruleset     : drupilot default (${PHPCS_STANDARD})"
fi
if [[ "$TV_SRC" == "ruleset-config" ]]; then
  log_info "testVersion : ${TV} (the ruleset's own <config>, not overridden)"
else
  log_info "testVersion : ${TV} (${TV_SRC}, passed with --runtime-set)"
fi

# Record the resolution (hidden state): the port report and the post-edit-lint
# hook read it back. The checksum lets the hook notice a ruleset edited since.
RS_CKSUM=""
[[ -n "$RS_FILE" ]] && RS_CKSUM="$(cksum < "$RS_FILE" 2>/dev/null | awk '{print $1}')"
_pass_ext=true
case " ${STD_ARGS[*]} " in *" --extensions="*) : ;; *) _pass_ext=false;; esac
RS_INFO="$(jq -n \
  --arg ruleset "$RS_FILE" --arg arg "$RS_ARG" --arg source "$RS_SOURCE" \
  --arg location "$RS_LOCATION" --arg reason "$RS_REASON" --arg tv "$TV" \
  --arg tvs "$TV_SRC" --arg ck "$RS_CKSUM" --arg mode "$RS_MODE" \
  --argjson ext "$_pass_ext" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{ruleset: (if $ruleset == "" then null else $ruleset end),
    standard: (if ($source == "project" or $source == "explicit") then $arg else "Drupal,DrupalPractice" end),
    source: $source, mode: $mode,
    location: (if $location == "" then null else $location end),
    fallback_reason: (if $reason == "" then null else $reason end),
    test_version: $tv, test_version_source: $tvs,
    pass_extensions: $ext,
    cksum: (if $ck == "" then null else $ck end), at: $at}' 2>/dev/null || true)"
if [[ -n "$RS_INFO" ]]; then
  printf '%s\n' "$RS_INFO" > "$(project_state_dir "$SUBJECT_ABS")/phpcs-ruleset.json" 2>/dev/null || true
fi

# run_tool <bin> [extra args...] -> run phpcs/phpcbf with the resolved ruleset,
# on TARGETS (the subject by default; the changed files for --fix-scope changed).
declare -a TARGETS=("$SUBJECT_REL")
run_tool() {
  local bin="$1"; shift
  declare -a cmd=()
  [[ -n "$RUNNER" ]] && read -r -a cmd <<<"$RUNNER"
  cmd+=("vendor/bin/$bin" "${STD_ARGS[@]}" "$@" "${TARGETS[@]}")
  log_step "$bin: ${cmd[*]}"
  local rc=0
  if [[ -n "$RUNNER" ]]; then
    # Violations (phpcs exit 1/2) and fixes (phpcbf exit 1) are normal
    # verdicts reported below: drop `ddev exec`'s red "Failed to execute
    # command" line, which only repeats the exit status.
    run_dropping_ddev_failure_line "${cmd[@]}" || rc=$?
  else
    set +e
    "${cmd[@]}"
    rc=$?
    set -e
  fi
  return "$rc"
}

# --- Optional autofix pass (phpcbf) ---------------------------------------
# changed_files -> the subject's files (relative to the Drupal root) that differ
# from the pre-port git base, plus new untracked ones, limited to the extensions
# PHPCS checks. Returns 1 when the subject is not in git (no base to compare).
changed_files() {
  local repo base f ext ok e
  git -C "$SUBJECT_ABS" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  repo="$(git -C "$SUBJECT_ABS" rev-parse --show-toplevel 2>/dev/null)" || return 1
  base="$(git_port_base_ref "$repo" "" 2>/dev/null)" || return 1
  { git -C "$SUBJECT_ABS" diff --name-only --relative "$base" -- . 2>/dev/null || true
    git -C "$SUBJECT_ABS" ls-files --others --exclude-standard -- . 2>/dev/null || true
  } | LC_ALL=C sort -u | while IFS= read -r f; do
    [[ -n "$f" && -f "$SUBJECT_ABS/$f" ]] || continue
    ext="${f##*.}"; ok=0
    for e in ${PHPCS_EXTENSIONS//,/ }; do [[ "$ext" == "$e" ]] && ok=1; done
    [[ "$ok" == "1" ]] || continue
    if [[ "$SUBJECT_REL" == "." ]]; then printf '%s\n' "$f"; else printf '%s/%s\n' "$SUBJECT_REL" "$f"; fi
  done
  return 0
}

if [[ "$FIX" == "1" ]]; then
  _do_fix=1
  if [[ "$FIX_SCOPE" == "changed" ]]; then
    TARGETS=()
    if _changed="$(changed_files)"; then
      while IFS= read -r _f; do [[ -n "$_f" ]] && TARGETS+=("$_f"); done <<<"$_changed"
      if [[ "${#TARGETS[@]}" -eq 0 ]]; then
        log_info "phpcbf skipped: the port changed no file PHPCS checks (--fix-scope changed)."
        _do_fix=0
      else
        log_info "Autofix limited to the ${#TARGETS[@]} file(s) the port changed (--fix-scope changed); other files are only reported."
      fi
    else
      log_warn "phpcbf skipped: the subject is not in git, so the files the port changed are unknown (--fix-scope changed). Report only."
      _do_fix=0
    fi
  fi
  if [[ "$_do_fix" == "1" ]]; then
    log_info "Autofixing with phpcbf (this modifies files in place)."
    # phpcbf returns 1 when it fixed something and 2 on real errors; neither is fatal here.
    # In --json mode keep phpcbf's report off stdout so the only thing there is JSON.
    if [[ "$AS_JSON" == "1" ]]; then run_tool phpcbf >&2 || true; else run_tool phpcbf || true; fi
    hr
  fi
  TARGETS=("$SUBJECT_REL")
fi

# --- Report pass (phpcs) --------------------------------------------------
if [[ "$AS_JSON" == "1" ]]; then
  # Native JSON report; capture stdout so it stays pure JSON (logs are on stderr).
  set +e
  OUT="$(run_tool phpcs --report=json 2>/dev/null)"
  RC=$?
  set -e
  # Add the ruleset resolution and the runner as one extra top-level key
  # (existing consumers read .totals/.files, untouched) and sort the report
  # (DET-2: files by path, their messages by line, column and source);
  # non-JSON output is relayed as is.
  if [[ -n "$OUT" ]] && printf '%s' "$OUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
    _rs="${RS_INFO:-}"; [[ -n "$_rs" ]] || _rs='{}'
    printf '%s' "$OUT" | jq -c --argjson d "$_rs" --argjson prov "$(tool_provenance "$DRUPAL_ROOT" "$RUNNER" drupal/coder)" \
      '. + {drupilot: (($d | del(.cksum, .at)) + {runner: $prov})}
       | (if (.files | type) == "object" then .files |= (to_entries | sort_by(.key)
           | map(if (.value.messages | type) == "array" then .value.messages |= sort_by([(.line // 0), (.column // 0), (.source // ""), (.message // "")]) else . end)
           | from_entries) else . end)'
  elif [[ -n "$OUT" ]]; then
    printf '%s\n' "$OUT"
  fi
  PHPCS_TEXT="$OUT"
else
  set +e
  PHPCS_TEXT="$(run_tool phpcs)"
  RC=$?
  set -e
  [[ -n "$PHPCS_TEXT" ]] && printf '%s\n' "$PHPCS_TEXT"
fi

# A ruleset bug surfaces as a processing error, not as a violation: say so
# instead of letting it read like a coding-standard finding.
if printf '%s' "${PHPCS_TEXT:-}" | grep_q -E 'An error occurred during processing|trim\(\): Passing null'; then
  log_warn "PHPCS reported a processing error (not a coding-standard violation). With PHPCompatibility this usually means testVersion is unset or malformed: pass --test-version X- (or set DRUPILOT_PHPCS_TEST_VERSION), or fix the ruleset."
fi

hr
if [[ "$RC" -eq 0 ]]; then
  log_ok "PHPCS clean: no violations of the resolved ruleset in $SUBJECT_REL."
else
  if [[ "$FIX" == "1" ]]; then
    log_warn "PHPCS still reports violations after phpcbf (exit $RC); these need manual fixes."
  else
    log_warn "PHPCS found violations (exit $RC). Re-run with --fix to auto-correct what is fixable."
  fi
fi
exit "$RC"
