#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/run-rector.sh
# Run drupal-rector against a module/theme to find and (optionally) fix
# Drupal 9/10 -> Drupal 11 deprecations.
#
# Passes, in this order:
#   Pass 1 (always): the official, stable `palantirnet/drupal-rector`. A
#                    `rector.php` is ensured at the Drupal root (copied from
#                    vendor or the plugin template if missing). It targets the
#                    PHP floor L (ADR 0002, rector_php_bounds: the lowest PHP
#                    the core range core-strategy.sh recommends and the
#                    effective require.php admit, never above the PHP target):
#                    ->withPhpVersion() and the level sets stop at L.
#   Compat pass (when the floor is below PHP 8.4 and the range runs on 8.4 or
#                    later, rector_compat_needed): `--config rector-compat.php`
#                    (templates/rector-compat.php.tmpl, ensured at the root
#                    like rector.php), only the PHP deprecation fixes whose
#                    output still runs on L (`Foo $x = NULL` -> `?Foo $x =
#                    NULL`). Errors and the dry-run record call it pass 3.
#   Pass 2 (--digests): the COMPLEMENTARY, AI-generated `dbuytaert/drupal-digests`
#                    rules, cloned at runtime into the plugin cache and run via
#                    `--config <cache>/rector/all.php`.
#
# Default is DRY-RUN (no files are modified). Use --apply to write changes.
#
# IMPORTANT (PROMPT 2.1.1) — the digests layer is unlicensed, AI-generated and
# targets the development edge (it may raise the effective core_version_requirement
# to 11.2+). Never apply it blindly. The mandated workflow is:
#     dry-run  ->  human review of the diff  ->  apply  ->  validate (phpstan + tests)
#
# Usage:
#   run-rector.sh --subject DIR [--apply] [--digests] [--digests-ref REF] [--config PATH]
#   run-rector.sh --attributes --subject DIR [convert-attributes.sh options]
#
# Options:
#   --subject DIR      Path to the module/theme to process (relative to the
#                      Drupal root or absolute). Required.
#   --apply            Actually write changes (default is --dry-run).
#   --digests          Run the complementary dbuytaert/drupal-digests pass after
#                      the official pass.
#   --digests-ref REF  Git ref (tag/branch/commit) of the digests repo to use
#                      (default: DRUPILOT_DIGESTS_REF, falling back to 'main').
#   --config PATH      Explicit Rector config for the complementary pass
#                      (overrides the cloned digests all.php). Implies --digests.
#   --json             Emit a JSON summary on STDOUT instead of the plain file
#                      list: {status, ok, errors, changed_files, files,
#                      pass1_files, compat_files, pass2_files, rules,
#                      digests_status, digests_sha, compat_status, php_floor,
#                      php_ceiling} — pass1 = official, compat = the compat
#                      pass, pass2 = digests. Used for the reproducible verdict
#                      and the per-pass digests review. status is "ok",
#                      "error" (the official or the compat pass crashed: no
#                      verdict) or "partial" (only the digests pass crashed:
#                      the official result stands, ok stays true); errors is
#                      [{pass, exit_code, message}] (pass 1 official, 2
#                      digests, 3 compat — not the generated-rules "Pass 3"
#                      of /drupilot-port); digests_status and compat_status
#                      are "off", "ok", "error" or "skipped". php_floor and
#                      php_ceiling are the L and U of the Rector configs. rules
#                      is the sorted list of Rector rule names Rector reported
#                      as applied (its "Applied rules:" sections, every pass);
#                      rule_hits counts them per pass, {official: {Rule: n},
#                      compat: {Rule: n}, digests: {Rule: n}} (n = files the
#                      rule changed; the compat and digests keys only when that
#                      pass changed something) —
#                      copy it into the port manifest's rector_rules. An
#                      --apply that changes files also keeps it in the
#                      subject's state dir (rector-rules.json), the fallback
#                      port-report.sh / layer-report.sh read.
#   --attributes       Run ONLY the optional annotation -> PHP 8 attribute pass
#                      instead of the official/digests passes: forwards every
#                      other argument to scripts/analysis/convert-attributes.sh
#                      (--subject, --apply, --json, --mode keep|strip,
#                      --raise-floor, --max-since X.Y, --floor X.Y, --types A,B;
#                      see its --help for the output and exit codes).
#   -h, --help         Show this help.
#
# Gate: `analyze` profile (git + jq + composer/php).
# Output: status/logging on STDERR; a plain list of changed files (or, with
#         --json, a JSON summary) on STDOUT.
#
# A Rector run only counts when it finished normally: exit 0 (no change /
# applied) or 2 (dry-run found changes) AND its closing "[OK] ..." line. A
# crash — e.g. "[ERROR] Could not detect twig set." from an incompatible
# rector/rector, a PHP fatal, or per-file processing errors — is reported as
# status "error" with the error text and exit 3, never as "0 files would
# change". The file lists of a failed pass are partial at best. The compat
# pass runs on the same toolchain, so its crash counts as the official one's.
# After a crash of the official or the compat pass the passes after it are
# skipped. A crash of the digests pass
# alone is a problem of that third-party ruleset (e.g. a broken upstream
# commit), not of the toolchain: status "partial", digests_status "error",
# exit 4, and the official result is still reported. A digests SHA is frozen
# in the lockfile only after its pass finished normally, so a broken upstream
# commit is never pinned for the project.
#
# rector.php: written from templates/rector.php.tmpl when missing. An existing
# one is left untouched unless it uses the legacy API or was generated by an
# OLDER drupilot template (no current "drupilot-template-version" marker): then
# it is backed up to <root>/.drupilot/backups/ and regenerated, so the risky-rule
# skips (Form API callbacks -> closures, #[\Override], readonly, string casts,
# __sleep/__wakeup) reach projects set up before them. The same happens when its
# PHP floor is not the current one (the core target changed after setup) and it
# is exactly a drupilot render (rector_config_pristine); an edited copy at
# another floor is kept, with a warning. A hand-written rector.php is never
# replaced; a warning is printed when it does not skip
# ArrayToFirstClassCallableRector or has no withPhpVersion(). rector-compat.php
# follows the same rules (written when missing, regenerated from an older
# marker) when the compat pass runs.
#
# Every pass runs with --clear-cache (Rector's cache is shared across configs,
# so a file another config cached as unchanged would otherwise be skipped). A
# dry-run records its per-pass counts (<state_dir>/rector-dryrun.json, with the
# subject digest and the rector.php / rector-compat.php checksum); an --apply on
# the same code and config that changes 0 files in a pass whose dry-run
# announced changes is an error (status "error" for the official and the compat
# pass, exit 3; "partial" for digests).
#
# Exit codes: 0 ok · 1 usage error · 2 gate (requirements, Drupal root,
# vendor/bin/rector or a source for rector.php missing) · 3 the official or the
# compat pass crashed or reported errors (toolchain/config broken, or a broken
# rector-compat.php; the diagnostic lists the
# installed vs known-good versions from config/toolchain-reference.json) ·
# 4 only the digests pass crashed (the official result stands; fix with
# --digests-ref <known-good commit> or DRUPILOT_USE_DIGESTS_RULES=false).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
APPLY=0
USE_DIGESTS=0
DIGESTS_REF=""
DIGESTS_CONFIG=""
AS_JSON=0

usage() { print_usage "$0"; }

# --attributes: a separate pass with its own script (and CLI); the default
# official + digests passes are untouched.
for _a in "$@"; do
  if [[ "$_a" == "--attributes" ]]; then
    _fwd=()
    for _b in "$@"; do [[ "$_b" == "--attributes" ]] || _fwd+=("$_b"); done
    exec bash "$(dirname "${BASH_SOURCE[0]}")/convert-attributes.sh" "${_fwd[@]+"${_fwd[@]}"}"
  fi
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --apply) APPLY=1; shift;;
    --digests) USE_DIGESTS=1; shift;;
    --digests-ref) DIGESTS_REF="${2:-}"; USE_DIGESTS=1; shift 2;;
    --digests-ref=*) DIGESTS_REF="${1#*=}"; USE_DIGESTS=1; shift;;
    --config) DIGESTS_CONFIG="${2:-}"; USE_DIGESTS=1; shift 2;;
    --config=*) DIGESTS_CONFIG="${1#*=}"; USE_DIGESTS=1; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

[[ -n "$SUBJECT" ]] || die "Missing --subject DIR (the module/theme to process)." 1

# --- Gate: analyze --------------------------------------------------------
PREFLIGHT="$(plugin_root)/scripts/env/preflight.sh"
if ! bash "$PREFLIGHT" --profile analyze --quiet >/dev/null 2>&1; then
  log_err "The 'analyze' requirements are not satisfied; cannot run Rector."
  bash "$PREFLIGHT" --profile analyze >&2 || true
  exit 2
fi

# --- Locate the Drupal root and resolve the subject relative to it --------
DRUPAL_ROOT="$(find_drupal_root "$SUBJECT" 2>/dev/null || find_drupal_root "$PWD" 2>/dev/null || true)"
[[ -n "$DRUPAL_ROOT" ]] || die "Could not locate a Drupal root (web/core or .ddev/config.yaml) from '$SUBJECT'. Run /drupilot-setup first." 2

# Absolute subject path (so we can re-express it relative to the Drupal root).
SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
if [[ -z "$SUBJECT_ABS" ]]; then
  # Maybe it was given relative to the Drupal root already.
  SUBJECT_ABS="$(cd "$DRUPAL_ROOT/$SUBJECT" 2>/dev/null && pwd || true)"
fi
[[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1

# Path relative to the Drupal root (works identically on host and inside DDEV).
case "$SUBJECT_ABS" in
  "$DRUPAL_ROOT"/*) SUBJECT_REL="${SUBJECT_ABS#"$DRUPAL_ROOT"/}";;
  "$DRUPAL_ROOT")   SUBJECT_REL=".";;
  *) log_err "Subject '$SUBJECT_ABS' is outside the Drupal root '$DRUPAL_ROOT'."
     log_plain "Rector runs relative to the Drupal root, so the subject must live under it."
     log_plain "Place it with: scripts/env/place-subject.sh --subject '$SUBJECT_ABS'"
     log_plain "(or re-run /drupilot-setup, which resolves the test-bed and places it for you)."
     die "Subject is outside the Drupal root." 1;;
esac

cd "$DRUPAL_ROOT"
export DRUPILOT_PROJECT_DIR="$DRUPAL_ROOT"  # so the lockfile lands in this project's state dir
# A configured but stopped DDEV project is started explicitly (drupal_runner
# itself never starts one); without DDEV the host toolchain is used.
ddev_ensure_running_or_host "$DRUPAL_ROOT" rector \
  || die "Could not start the DDEV project at $DRUPAL_ROOT, and there is no host vendor/bin/rector to fall back to." 1
RUNNER="$(drupal_runner "$DRUPAL_ROOT")"   # "ddev exec" when DDEV is up, else ""
PHP_TARGET="$(resolve_php_target)"
# The PHP floor L of the Rector configs and the ceiling U (ADR 0002).
_b="$(rector_php_bounds "$SUBJECT_ABS" "$PHP_TARGET")"
PHP_FLOOR="${_b%% *}"; PHP_CEIL="${_b##* }"
FLOOR_TOKENS=()
for _t in $(rector_floor_tokens "$PHP_FLOOR" || true); do FLOOR_TOKENS+=("$_t"); done
[[ "${#FLOOR_TOKENS[@]}" -eq 3 ]] || die "Could not derive the Rector tokens of the PHP floor '$PHP_FLOOR'." 1
COMPAT=0
if rector_compat_needed "$PHP_FLOOR" "$PHP_CEIL"; then COMPAT=1; fi

log_info "Drupal root : $DRUPAL_ROOT"
log_info "Subject     : $SUBJECT_REL"
log_info "PHP target  : $PHP_TARGET"
if [[ -n "$RUNNER" ]]; then
  log_info "Runner      : DDEV ($RUNNER)"
else
  log_info "Runner      : host (vendor/bin)"
fi
log_info "PHP floor   : $PHP_FLOOR (Rector withPhpVersion and level sets) · ceiling: $PHP_CEIL · compat pass: $([[ "$COMPAT" == "1" ]] && echo yes || echo no)"
if php_target_unconfirmed "$PHP_FLOOR"; then
  log_warn "PHP floor $PHP_FLOOR (PHP 8.5 needs Drupal 11.3 or later): no Rector php85 set is assumed, the main pass uses the highest set drupilot supports."
fi

# --- Verify the Rector binary is present ----------------------------------
if [[ ! -x "$DRUPAL_ROOT/vendor/bin/rector" && ! -f "$DRUPAL_ROOT/vendor/bin/rector" ]]; then
  die "vendor/bin/rector is missing. Install the toolchain first: bash \"$(plugin_root)/scripts/env/install-toolchain.sh\" --dir \"$DRUPAL_ROOT\" (or /drupilot-setup)." 2
fi

# --- Ensure a rector.php exists at the Drupal root (idempotent) -----------
RECTOR_PHP="$DRUPAL_ROOT/rector.php"
VENDOR_RECTOR="$DRUPAL_ROOT/vendor/palantirnet/drupal-rector/rector.php"
TEMPLATE_RECTOR="$(plugin_root)/templates/rector.php.tmpl"

# Current drupilot template generation (the marker line in the template header).
RECTOR_TEMPLATE_VERSION="$(grep -oE 'drupilot-template-version: [0-9]+' "$TEMPLATE_RECTOR" 2>/dev/null | head -n1 || true)"

# write_rector_from_template — render the drupilot template into rector.php.
write_rector_from_template() {
  render_template "$TEMPLATE_RECTOR" "$RECTOR_PHP" \
    "SUBJECT_PATH=$SUBJECT_REL" "PHP_TARGET=$PHP_TARGET" "DRUPAL_TARGET=$(resolve_drupal_target)" \
    ${FLOOR_TOKENS[@]+"${FLOOR_TOKENS[@]}"} \
    || die "Could not render $TEMPLATE_RECTOR into $RECTOR_PHP." 1
}

# backup_config [file] — copy a config (default rector.php) to
# <root>/.drupilot/backups/ (gitignored; same place render-templates.sh --force
# uses) and print the path.
backup_config() {
  local f="${1:-$RECTOR_PHP}" bdir backup
  bdir="$(project_artifacts_dir "$DRUPAL_ROOT")/backups"
  mkdir -p "$bdir"
  backup="$bdir/$(basename "$f").$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$f" "$backup"
  printf '%s' "$backup"
}

if [[ -f "$RECTOR_PHP" ]]; then
  # Detect legacy API: the old format uses `$rectorConfig->sets([` instead of
  # `RectorConfig::configure()`. If found, regenerate from the drupilot template
  # so the port is not silently run with an incomplete ruleset.
  if ! grep -q "RectorConfig::configure" "$RECTOR_PHP"; then
    log_warn "rector.php uses the legacy API. Regenerating from the drupilot template..."
    if [[ -f "$TEMPLATE_RECTOR" ]]; then
      write_rector_from_template
      log_ok "rector.php regenerated from the drupilot template (subject: $SUBJECT_REL)."
    else
      die "rector.php uses the legacy API and no template is available to regenerate it. Run /drupilot-setup first." 2
    fi
  elif grep -q "drupilot — rector.php" "$RECTOR_PHP" \
       && [[ -n "$RECTOR_TEMPLATE_VERSION" && -f "$TEMPLATE_RECTOR" ]] \
       && ! grep -qF "$RECTOR_TEMPLATE_VERSION" "$RECTOR_PHP"; then
    # A rector.php drupilot generated from an OLDER template: it lacks the
    # risky-rule skips (Form API callbacks -> closures, #[\Override], readonly,
    # (string) casts), so regenerate it. The old copy is backed up first.
    _bk="$(backup_config)"
    write_rector_from_template
    log_warn "rector.php was generated by an older drupilot template; regenerated (${RECTOR_TEMPLATE_VERSION}). Previous copy: ${_bk#"$DRUPAL_ROOT"/}"
  elif grep -q "drupilot — rector.php" "$RECTOR_PHP" \
       && _old_floor="$(rector_config_floor "$RECTOR_PHP")" && [[ -n "$_old_floor" && "$_old_floor" != "$PHP_FLOOR" ]]; then
    # The floor moved since rector.php was rendered (e.g. the core target
    # chosen at port time is not the one setup assumed).
    if rector_config_pristine "$TEMPLATE_RECTOR" "$RECTOR_PHP"; then
      _bk="$(backup_config)"
      write_rector_from_template
      log_warn "rector.php targeted the PHP floor $_old_floor; the declared core range and require.php now give $PHP_FLOOR. Regenerated (it was an untouched drupilot render). Previous copy: ${_bk#"$DRUPAL_ROOT"/}"
    else
      log_warn "rector.php targets PHP $_old_floor (withPhpVersion), but the PHP floor of the declared core range and require.php is $PHP_FLOOR; it was edited by hand, so it is left untouched."
      if version_ge "$_old_floor" "$PHP_FLOOR"; then
        log_warn "Rules up to PHP $_old_floor may emit code PHP $PHP_FLOOR cannot run. Re-render it (the current copy is backed up):"
      else
        log_warn "Rector will modernize less than the floor allows. Re-render it (the current copy is backed up):"
      fi
      log_plain "   bash \"$(plugin_root)/scripts/env/render-templates.sh\" --subject \"$SUBJECT_ABS\" --only rector --force"
      log_plain "   (it re-renders rector-compat.php too)."
    fi
  else
    log_ok "rector.php already present at the Drupal root (left untouched)."
    if ! grep -q "drupilot — rector.php" "$RECTOR_PHP" \
       && ! grep -q "ArrayToFirstClassCallableRector" "$RECTOR_PHP"; then
      log_warn "Your own rector.php does not skip ArrayToFirstClassCallableRector: with a PHP 8.1+ set it turns"
      log_warn "Form/Render API callbacks ([\$this, 'method']) into unserializable closures. See templates/rector.php.tmpl"
      log_warn "for the recommended skip list; check-port-safety.sh flags any such conversion after the port."
    fi
    if ! grep -q "drupilot — rector.php" "$RECTOR_PHP" && ! grep -q "withPhpVersion" "$RECTOR_PHP"; then
      log_warn "Your own rector.php has no withPhpVersion(): Rector then takes the PHP version from composer.json or the"
      log_warn "running PHP, and may emit code PHP $PHP_FLOOR (the floor of the declared core range) cannot run. Add"
      log_warn "->withPhpVersion(PhpVersion::PHP_${PHP_FLOOR//./}) and stop the level sets there (see templates/rector.php.tmpl)."
    fi
  fi
elif [[ -f "$TEMPLATE_RECTOR" ]]; then
  # The template uses {{PLACEHOLDER}} tokens; substitute the ones we know
  # (literally, via the same renderer as render-templates.sh).
  write_rector_from_template
  log_ok "Wrote rector.php from the drupilot template (subject: $SUBJECT_REL)."
elif [[ -f "$VENDOR_RECTOR" ]]; then
  # Fallback: vendor example file. It uses the legacy API and may be incomplete;
  # prefer the drupilot template whenever available.
  cp "$VENDOR_RECTOR" "$RECTOR_PHP"
  log_warn "rector.php copied from vendor/palantirnet/drupal-rector/rector.php (legacy fallback). Run /drupilot-setup to regenerate it from the drupilot template."
else
  die "No rector.php found and no source to create one (neither $TEMPLATE_RECTOR nor $VENDOR_RECTOR exists)." 2
fi

# --- Ensure rector-compat.php when the compat pass runs (ADR 0002) ---------
RECTOR_COMPAT_PHP="$DRUPAL_ROOT/rector-compat.php"
TEMPLATE_COMPAT="$(plugin_root)/templates/rector-compat.php.tmpl"
if [[ "$COMPAT" == "1" ]]; then
  [[ -f "$TEMPLATE_COMPAT" ]] || die "The compat pass needs $TEMPLATE_COMPAT, which is missing." 2
  COMPAT_TEMPLATE_VERSION="$(grep -oE 'drupilot-template-version: [0-9]+' "$TEMPLATE_COMPAT" 2>/dev/null | head -n1 || true)"
  write_compat_from_template() {
    render_template "$TEMPLATE_COMPAT" "$RECTOR_COMPAT_PHP" "SUBJECT_PATH=$SUBJECT_REL" ${FLOOR_TOKENS[@]+"${FLOOR_TOKENS[@]}"} \
      || die "Could not render $TEMPLATE_COMPAT into $RECTOR_COMPAT_PHP." 1
  }
  if [[ ! -f "$RECTOR_COMPAT_PHP" ]]; then
    write_compat_from_template
    log_ok "Wrote rector-compat.php from the drupilot template (the compat pass for the PHP floor $PHP_FLOOR)."
  elif grep -q "drupilot — rector-compat.php" "$RECTOR_COMPAT_PHP" \
       && [[ -n "$COMPAT_TEMPLATE_VERSION" ]] && ! grep -qF "$COMPAT_TEMPLATE_VERSION" "$RECTOR_COMPAT_PHP"; then
    _bk="$(backup_config "$RECTOR_COMPAT_PHP")"
    write_compat_from_template
    log_warn "rector-compat.php was generated by an older drupilot template; regenerated (${COMPAT_TEMPLATE_VERSION}). Previous copy: ${_bk#"$DRUPAL_ROOT"/}"
  else
    log_ok "rector-compat.php already present at the Drupal root (left untouched)."
  fi
fi

# --- Helpers --------------------------------------------------------------
# run_rector_pass <pass:1|2> <dry_run:0/1> [extra args...] -> runs Rector,
# leaves its combined output in RECTOR_RAW (echoed to stderr) and returns its
# exit code. A run that did not finish normally (rector_output_ok) is recorded
# in ERRORS_JSON with the error excerpt.
RECTOR_RAW=""
ERRORS_JSON="[]"
FAILED_PASSES=""
run_rector_pass() {
  local pass="$1" dry="$2"; shift 2
  local -a cmd=()
  [[ -n "$RUNNER" ]] && read -r -a cmd <<<"$RUNNER"
  # --clear-cache: Rector's file cache is shared by every config that runs in
  # the same PHP (this rector.php, the digests all.php, the attributes pass of
  # convert-attributes.sh) and is not keyed on the config's rules, so a file
  # another config cached as "unchanged" would be skipped here: an --apply
  # after another config's run silently changed nothing. A module is small, so
  # every pass starts from an empty cache.
  cmd+=(vendor/bin/rector process "$SUBJECT_REL" --clear-cache)
  if [[ "$dry" == "1" ]]; then cmd+=(--dry-run); fi
  cmd+=("$@")
  log_step "Rector: ${cmd[*]}"
  # Capture combined output; a non-zero rc must not abort the script (a dry-run
  # that finds changes exits 2), so it is classified below instead.
  local rc=0
  RECTOR_RAW="$("${cmd[@]}" 2>&1)" || rc=$?
  # `ddev exec` reports ANY non-zero exit with a red "Failed to execute command
  # ...: exit status N" line. For a dry run that found changes (exit 2) that is
  # not a failure, so drop the wrapper's line when the run finished normally;
  # a real crash keeps it.
  if [[ "$rc" != "0" && -n "$RUNNER" ]] && rector_output_ok "$rc" "$RECTOR_RAW"; then
    RECTOR_RAW="$(printf '%s\n' "$RECTOR_RAW" \
      | grep -vE 'Failed to execute command .*: exit status [0-9]+' || true)"
  fi
  printf '%s\n' "$RECTOR_RAW" >&2
  if ! rector_output_ok "$rc" "$RECTOR_RAW"; then
    local msg; msg="$(rector_error_excerpt "$RECTOR_RAW")"
    FAILED_PASSES="$FAILED_PASSES $pass"
    if have_cmd jq; then
      ERRORS_JSON="$(printf '%s' "$ERRORS_JSON" | jq -c --argjson p "$pass" --argjson rc "$rc" --arg m "$msg" \
        '. + [{pass:$p, exit_code:$rc, message:$m}]')"
    fi
    log_err "Rector pass $pass FAILED (exit $rc) — this is a crash, not a 'no changes' result:"
    printf '%s\n' "$msg" | sed 's/^/     /' >&2
    return 1
  fi
  return 0
}

# summarize_changed <raw> -> print "[N] files would change / changed" to stderr
# and the file list (relative paths) to stdout.
emit_changed_files() {
  local raw="$1"
  # Rector prints lines like "1) web/modules/custom/foo/foo.module" in its
  # "files with changes" section, and a trailing "[OK] N files would have been
  # changed ...". We extract candidate paths conservatively.
  printf '%s\n' "$raw" \
    | grep -oE '[0-9]+\) [^[:space:]]+\.(php|module|inc|install|theme|engine|profile|twig|yml)' \
    | sed -E 's/^[0-9]+\) //' \
    | sort -u
}

# --- Dry-run record (an --apply must change what its dry-run announced) -----
# A dry-run records how many files each pass would change, with the subject's
# digest and the rector.php checksum. An --apply on the SAME code and config
# that then changes nothing in a pass whose dry-run announced changes is an
# error (a stale cache or a broken run), never "0 files changed, ok".
DRYRUN_REC="$(project_state_dir "$SUBJECT_ABS")/rector-dryrun.json"
PRE_DIGEST="$(subject_digest "$SUBJECT_ABS")"
RECTOR_SUM="$(cksum < "$RECTOR_PHP" 2>/dev/null | awk '{ print $1 "-" $2 }' || true)"
if [[ "$COMPAT" == "1" ]]; then
  RECTOR_SUM="$RECTOR_SUM+$(cksum < "$RECTOR_COMPAT_PHP" 2>/dev/null | awk '{ print $1 "-" $2 }' || true)"
fi

# --- Pass 1: official palantirnet/drupal-rector ---------------------------
hr
log_step "Pass 1 — palantirnet/drupal-rector (official, stable)"
PASS1_OK=1
if [[ "$APPLY" == "1" ]]; then
  run_rector_pass 1 0 || PASS1_OK=0
else
  log_info "Dry-run (no files modified). Use --apply to write changes."
  run_rector_pass 1 1 || PASS1_OK=0
fi
PASS1_RAW="$RECTOR_RAW"
# Whether pass 1 itself finished normally (a later compat crash or consistency
# check may clear PASS1_OK, but an --apply has written pass 1's changes).
PASS1_RAN_OK="$PASS1_OK"

# --- Compat pass: rector-compat.php (ADR 0002) ---------------------------------
PASS3_RAW=""
COMPAT_STATUS="off"       # off | ok | error | skipped
if [[ "$COMPAT" == "1" && "$PASS1_OK" != "1" ]]; then
  COMPAT_STATUS="skipped"
  hr
  log_warn "Skipping the compat pass: the official pass crashed, so the toolchain is broken (fix it first)."
elif [[ "$COMPAT" == "1" ]]; then
  hr
  log_step "Compat pass — PHP deprecation fixes that still run on PHP $PHP_FLOOR (rector-compat.php)"
  if [[ "$APPLY" == "1" ]]; then
    run_rector_pass 3 0 --config rector-compat.php || true
  else
    run_rector_pass 3 1 --config rector-compat.php || true
  fi
  PASS3_RAW="$RECTOR_RAW"
  case " $FAILED_PASSES " in
    *" 3 "*) COMPAT_STATUS="error"; PASS1_OK=0;;
    *) COMPAT_STATUS="ok";;
  esac
fi

# --- Pass 2: complementary dbuytaert/drupal-digests (optional) ------------
PASS2_RAW=""
DIGESTS_STATUS="off"      # off | ok | error | skipped
DIGESTS_SHA=""
DIGESTS_FROM_LOCK=0
if [[ "$USE_DIGESTS" == "1" ]]; then DIGESTS_STATUS="skipped"; fi
if [[ "$USE_DIGESTS" == "1" && "$PASS1_OK" != "1" ]]; then
  hr
  log_warn "Skipping the digests pass: the official or the compat pass crashed, so the toolchain is broken (fix it first)."
elif [[ "$USE_DIGESTS" == "1" ]]; then
  hr
  log_step "Pass 2 — dbuytaert/drupal-digests (complementary, AI-generated)"
  log_warn "Digests rules are UNLICENSED, AI-generated and target the development edge."
  log_warn "They may migrate APIs deprecated in 11.2+ and removed in 12.0, which can raise"
  log_warn "the effective core_version_requirement. Workflow: dry-run -> review diff -> apply -> validate."

  # --- Resolve the digests ref/SHA (reproducible by default) --------------
  # Decision: the default ref stays 'main'. In deterministic mode the SHA that
  # 'main' first resolved is frozen in the per-project lockfile and reused, so the
  # same project always runs the same digests rules without maintaining a manual
  # pin. A --digests-ref DIFFERENT from the configured default is an explicit
  # intent: it wins and refreshes the lock. DRUPILOT_DETERMINISTIC=false always
  # re-resolves the live ref. (`--digests-ref main`, the redundant default some
  # callers pass, is treated as "not forced" so the lock still applies.)
  CONFIGURED_REF="$(config_get DRUPILOT_DIGESTS_REF "main")"
  FREEZE_SHA=1
  if [[ -n "$DIGESTS_REF" && "$DIGESTS_REF" != "$CONFIGURED_REF" ]]; then
    REF="$DIGESTS_REF"
  elif deterministic_mode && [[ -n "$(lock_get .digests.sha "")" ]]; then
    REF="$(lock_get .digests.sha "")"
    FREEZE_SHA=0
    DIGESTS_FROM_LOCK=1
    log_info "Deterministic mode: reusing the digests SHA frozen in the lockfile ($REF)."
  else
    REF="$CONFIGURED_REF"
  fi
  REPO_URL="$(config_json .digests.repo_url "https://github.com/dbuytaert/drupal-digests.git")"
  CFG_REL="$(config_json .digests.config_path "rector/all.php")"
  CACHE="$(digests_cache_dir)"

  # Resolve the config to use: explicit --config wins; otherwise the cloned repo.
  if [[ -n "$DIGESTS_CONFIG" ]]; then
    [[ -f "$DIGESTS_CONFIG" ]] || die "Explicit --config not found: $DIGESTS_CONFIG" 1
    CONFIG_PATH="$(cd "$(dirname "$DIGESTS_CONFIG")" && pwd)/$(basename "$DIGESTS_CONFIG")"
    log_info "Using explicit digests config: $CONFIG_PATH"
  else
    # Clone/update the cache, make HEAD exactly $REF, and VERIFY it. A pinned SHA
    # the shallow cache lacks triggers a clean reclone — we never silently reuse a
    # stale cache for a pinned SHA.
    _is_sha=0
    if [[ "$REF" =~ ^[0-9a-f]{7,40}$ ]]; then _is_sha=1; fi
    _digests_checkout_ref() {
      # Detach onto $REF whether it is a branch tip, a tag, or a fetchable SHA.
      git -C "$CACHE" fetch --depth 1 origin "$REF" >/dev/null 2>&1 \
        && git -C "$CACHE" checkout -q --detach FETCH_HEAD >/dev/null 2>&1 && return 0
      git -C "$CACHE" checkout -q "$REF" >/dev/null 2>&1
    }

    if [[ ! -d "$CACHE/.git" ]]; then
      log_info "Cloning $REPO_URL into $CACHE (ref: $REF)"
      rm -rf "$CACHE" 2>/dev/null || true
      git clone --depth 1 --branch "$REF" "$REPO_URL" "$CACHE" >/dev/null 2>&1 \
        || git clone --depth 1 "$REPO_URL" "$CACHE" >/dev/null 2>&1 \
        || die "Failed to clone the digests repo from $REPO_URL. Check your network or skip --digests." 2
    fi
    log_info "Setting digests cache to ref: $REF"
    _digests_checkout_ref || true
    DIGESTS_SHA="$(git -C "$CACHE" rev-parse HEAD 2>/dev/null || true)"

    # A pinned SHA that did not check out -> reclone fresh and try once more.
    if [[ "$_is_sha" == "1" && ( -z "$DIGESTS_SHA" || "$DIGESTS_SHA" != "$REF"* ) ]]; then
      log_warn "Digests cache HEAD ($DIGESTS_SHA) != pinned ref ($REF); recloning."
      rm -rf "$CACHE" 2>/dev/null || true
      git clone --depth 1 "$REPO_URL" "$CACHE" >/dev/null 2>&1 \
        || die "Failed to reclone the digests repo from $REPO_URL." 2
      _digests_checkout_ref || true
      DIGESTS_SHA="$(git -C "$CACHE" rev-parse HEAD 2>/dev/null || true)"
      if [[ -z "$DIGESTS_SHA" || "$DIGESTS_SHA" != "$REF"* ]]; then
        die "Could not check out the pinned digests SHA '$REF'. Retry online, refresh the lock (DRUPILOT_DETERMINISTIC=false), or skip --digests." 2
      fi
    fi

    if [[ -n "$DIGESTS_SHA" ]]; then log_ok "Digests at $DIGESTS_SHA (ref: $REF)."; fi
    # The SHA is frozen in the lockfile only after the pass finished normally
    # (below), so a broken upstream commit is never pinned for the project.

    CONFIG_PATH="$CACHE/$CFG_REL"
    [[ -f "$CONFIG_PATH" ]] || die "Digests config not found after clone/update: $CONFIG_PATH" 2
  fi

  # The DDEV container cannot read the host-side cache path, so the digests pass
  # only runs with the config reachable by the runner. When using DDEV, the
  # cache lives on the host -> run this pass with host PHP if possible.
  DIGESTS_RUNNER="$RUNNER"
  if [[ -n "$RUNNER" && "$CONFIG_PATH" != "$DRUPAL_ROOT"/* ]]; then
    if have_cmd php && [[ -f "$DRUPAL_ROOT/vendor/bin/rector" ]]; then
      log_info "Digests config lives outside the project; running this pass with host PHP so the path is reachable."
      DIGESTS_RUNNER=""
    else
      log_warn "Digests config is on the host but the runner is DDEV and host PHP is unavailable."
      log_warn "Copy the config under the project tree or install host PHP. Skipping the digests pass."
      CONFIG_PATH=""
    fi
  fi

  if [[ -n "$CONFIG_PATH" ]]; then
    if [[ "$APPLY" == "1" ]]; then
      log_warn "Applying digests rules. Review the resulting diff carefully and validate with phpstan + tests."
      RUNNER="$DIGESTS_RUNNER" run_rector_pass 2 0 --config "$CONFIG_PATH" || true
    else
      log_info "Dry-run of the digests pass (no files modified). Use --apply only after reviewing the diff."
      RUNNER="$DIGESTS_RUNNER" run_rector_pass 2 1 --config "$CONFIG_PATH" || true
    fi
    PASS2_RAW="$RECTOR_RAW"
    case " $FAILED_PASSES " in
      *" 2 "*) DIGESTS_STATUS="error";;
      *) DIGESTS_STATUS="ok"
         if [[ "${FREEZE_SHA:-0}" == "1" && -n "$DIGESTS_SHA" ]]; then
           lock_set .digests.sha "$DIGESTS_SHA" 2>/dev/null || true
           lock_set .digests.ref "$CONFIGURED_REF" 2>/dev/null || true
           log_info "Froze the digests SHA in the lockfile (reused on later runs while deterministic)."
         fi;;
    esac
  fi
fi

# --- Summary --------------------------------------------------------------
hr
PASS1_FILES="$(emit_changed_files "$PASS1_RAW" 2>/dev/null || true)"
PASS2_FILES=""
[[ -n "$PASS2_RAW" ]] && PASS2_FILES="$(emit_changed_files "$PASS2_RAW" 2>/dev/null || true)"
PASS3_FILES=""
[[ -n "$PASS3_RAW" ]] && PASS3_FILES="$(emit_changed_files "$PASS3_RAW" 2>/dev/null || true)"
CHANGED="$( { printf '%s\n' "$PASS1_FILES"; printf '%s\n' "$PASS3_FILES"; printf '%s\n' "$PASS2_FILES"; } | grep -v '^$' | sort -u || true)"

# Dry-run vs apply consistency (see DRYRUN_REC above).
P1N="$(printf '%s\n' "$PASS1_FILES" | grep -c . || true)"
P2N="$(printf '%s\n' "$PASS2_FILES" | grep -c . || true)"
P3N="$(printf '%s\n' "$PASS3_FILES" | grep -c . || true)"
if [[ "$APPLY" != "1" && "$PASS1_OK" == "1" && -n "$PRE_DIGEST" ]] && have_cmd jq; then
  jq -n --arg d "$PRE_DIGEST" --arg r "$RECTOR_SUM" --argjson dg "$([[ "$USE_DIGESTS" == "1" ]] && echo true || echo false)" \
    --arg dc "${DIGESTS_SHA:-$DIGESTS_CONFIG}" --argjson p1 "$P1N" --argjson p2 "$P2N" --arg ds "$DIGESTS_STATUS" \
    --arg f2 "$PASS2_FILES" --arg cs "$COMPAT_STATUS" --argjson p3 "$P3N" --arg f3 "$PASS3_FILES" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{tool: "run-rector", generated_at: $at, subject_digest: $d, rector_php: $r, digests: $dg,
      digests_config: $dc, digests_status: $ds, pass1_files: $p1, pass2_files: $p2,
      pass2_list: ($f2 | split("\n") | map(select(length > 0))),
      compat_status: $cs, compat_files: $p3, compat_list: ($f3 | split("\n") | map(select(length > 0)))}' \
    > "$DRYRUN_REC" 2>/dev/null || true
elif [[ "$APPLY" == "1" && -n "$PRE_DIGEST" && -r "$DRYRUN_REC" ]] && have_cmd jq; then
  _rec="$(jq -c --arg d "$PRE_DIGEST" --arg r "$RECTOR_SUM" 'select(.subject_digest == $d and .rector_php == $r)' "$DRYRUN_REC" 2>/dev/null || true)"
  if [[ -n "$_rec" ]]; then
    _dp1="$(printf '%s' "$_rec" | jq -r '.pass1_files // 0')"
    if [[ "$PASS1_OK" == "1" && "$_dp1" -gt 0 && "$P1N" == "0" ]]; then
      PASS1_OK=0; FAILED_PASSES="$FAILED_PASSES 1"
      _m="The dry-run on this same code and rector.php reported $_dp1 file(s) to change, but the apply changed none (a stale Rector cache or a run that skipped the files). Nothing was ported: re-run the dry-run, then --apply."
      ERRORS_JSON="$(printf '%s' "$ERRORS_JSON" | jq -c --arg m "$_m" '. + [{pass: 1, exit_code: 0, message: $m}]')"
      log_err "Pass 1: $_m"
    fi
    # The compat pass runs on pass 1's output, so only the files pass 1 left
    # alone must still change.
    _dp3="$(printf '%s' "$_rec" | jq -r --arg f1 "$PASS1_FILES" '
      ($f1 | split("\n") | map(select(length > 0))) as $p1
      | if .compat_status == "ok"
        then [(.compat_list // [])[] | select(. as $f | any($p1[]; . == $f) | not)] | length else 0 end')"
    if [[ "$COMPAT_STATUS" == "ok" && "$_dp3" -gt 0 && "$P3N" == "0" ]]; then
      PASS1_OK=0; COMPAT_STATUS="error"; FAILED_PASSES="$FAILED_PASSES 3"
      _m="The compat dry-run on this same code and rector-compat.php reported $_dp3 file(s) to change, but the apply changed none."
      ERRORS_JSON="$(printf '%s' "$ERRORS_JSON" | jq -c --arg m "$_m" '. + [{pass: 3, exit_code: 0, message: $m}]')"
      log_err "Compat pass: $_m"
    fi
    # Pass 2 runs on the output of pass 1 and the compat pass, so only the
    # files they left alone must still change (a digests rule may duplicate an
    # official one).
    _dp2="$(printf '%s' "$_rec" | jq -r --arg dc "${DIGESTS_SHA:-$DIGESTS_CONFIG}" --arg f1 "$PASS1_FILES"$'\n'"$PASS3_FILES" '
      ($f1 | split("\n") | map(select(length > 0))) as $p1
      | if .digests and .digests_status == "ok" and .digests_config == $dc
        then [(.pass2_list // [])[] | select(. as $f | any($p1[]; . == $f) | not)] | length else 0 end')"
    if [[ "$DIGESTS_STATUS" == "ok" && "$_dp2" -gt 0 && "$P2N" == "0" ]]; then
      DIGESTS_STATUS="error"; FAILED_PASSES="$FAILED_PASSES 2"
      _m="The digests dry-run on this same code and ruleset reported $_dp2 file(s) to change, but the apply changed none."
      ERRORS_JSON="$(printf '%s' "$ERRORS_JSON" | jq -c --arg m "$_m" '. + [{pass: 2, exit_code: 0, message: $m}]')"
      log_err "Pass 2: $_m"
    fi
  fi
fi

# Rule names from Rector's "Applied rules:" sections only (rector_applied_rules:
# the bullets of a "skipped rule is never registered" warning are not rules
# that ran).
APPLIED_RULES="$({ rector_applied_rules "$PASS1_RAW"; rector_applied_rules "$PASS3_RAW"; rector_applied_rules "$PASS2_RAW"; } | sort -u || true)"

# rule_hits_json <raw> -> {Rule: files} from one pass's "Applied rules:"
# sections (Rector lists the rules once per changed file). `{}` when none or
# when the output format is not recognized: never fails the run.
rule_hits_json() {
  have_cmd jq || { printf '{}'; return 0; }
  local out
  out="$(rector_applied_rules "${1:-}" \
    | jq -R . | jq -s -c 'group_by(.) | map({key: .[0], value: length}) | from_entries' 2>/dev/null || true)"
  [[ -n "$out" ]] || out='{}'
  printf '%s' "$out"
  return 0
}
RULE_HITS="$(jq -nc --argjson o "$(rule_hits_json "$PASS1_RAW")" --argjson c "$(rule_hits_json "$PASS3_RAW")" \
  --argjson d "$(rule_hits_json "$PASS2_RAW")" \
  '{official: $o} + (if ($c | length) > 0 then {compat: $c} else {} end)
   + (if ($d | length) > 0 then {digests: $d} else {} end)' 2>/dev/null || printf '{}')"

COUNT=0
[[ -n "$CHANGED" ]] && COUNT="$(printf '%s\n' "$CHANGED" | grep -c . || true)"

# FAILED=1: the official pass crashed (no verdict). PARTIAL=1: only the digests
# pass crashed — a problem of that third-party ruleset, not of the toolchain.
FAILED=0; PARTIAL=0
if [[ "$PASS1_OK" != "1" ]]; then FAILED=1
elif [[ "$DIGESTS_STATUS" == "error" ]]; then PARTIAL=1; fi
if [[ "$FAILED" == "1" ]]; then
  log_err "Rector FAILED (pass:${FAILED_PASSES}). Its result is NOT a verdict (no '0 files would change' after a crash)."
  [[ "$COUNT" != "0" ]] && log_warn "$COUNT file(s) were reported before the failure (partial result)."
  toolchain_diagnostics "$DRUPAL_ROOT"
  log_plain "   Check the installed toolchain:  bash \"$(plugin_root)/scripts/env/install-toolchain.sh\" --dir \"$DRUPAL_ROOT\" --smoke-only"
elif [[ "$PARTIAL" == "1" ]]; then
  log_ok "Official pass complete: $(printf '%s\n' "$PASS1_FILES" | grep -c . || true) file(s) $([[ "$APPLY" == "1" ]] && echo changed || echo 'would change') (this verdict stands)."
  if [[ -n "$DIGESTS_CONFIG" ]]; then
    log_err "The digests pass CRASHED with the explicit config $DIGESTS_CONFIG."
  else
    log_err "The digests pass CRASHED on digests ${DIGESTS_SHA:-$REF}: that upstream ruleset is broken for this toolchain."
  fi
  log_plain "   This is not a toolchain problem (the official pass ran fine) — do not reinstall the toolchain."
  log_plain "   Fix: pin a known-good digests commit  (--digests-ref <sha>, or DRUPILOT_DIGESTS_REF=<sha>)"
  log_plain "        or skip the layer                (DRUPILOT_USE_DIGESTS_RULES=false)."
  if [[ "$DIGESTS_FROM_LOCK" == "1" ]]; then
    log_plain "   That SHA comes from the lockfile; a forced --digests-ref <sha> refreshes it on its next successful run."
  else
    log_plain "   The SHA was NOT frozen in the lockfile (only a digests pass that finishes normally is pinned)."
  fi
elif [[ "$APPLY" == "1" ]]; then
  log_ok "Rector apply complete. $COUNT file(s) reported as changed."
  log_warn "Next: review the diff, then run phpstan and the test suite to validate."
else
  log_ok "Rector dry-run complete. $COUNT file(s) would change."
  log_info "Re-run with --apply once you have reviewed the proposed diff."
fi

# An --apply that changed files records its rule counts in the subject's
# hidden state dir (rector-rules.json), the fallback for the port manifest's
# rector_rules in port-report.sh / layer-report.sh — also when the compat pass
# crashed after the official pass had written its changes. A later apply that
# changes nothing (a re-run on ported code) keeps the record of the real port.
if [[ "$APPLY" == "1" && "$PASS1_RAN_OK" == "1" && "$COUNT" != "0" ]] && have_cmd jq; then
  jq -n --arg s "$SUBJECT_ABS" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson h "$RULE_HITS" \
    --arg dsha "$DIGESTS_SHA" --argjson n "$COUNT" \
    '{tool: "run-rector", subject: $s, generated_at: $at, changed_files: $n,
      digests_sha: (if $dsha == "" then null else $dsha end), rule_hits: $h}' \
    > "$(project_state_dir "$SUBJECT_ABS")/rector-rules.json" 2>/dev/null \
    || log_warn "Could not record the applied Rector rules in $(rector_rules_file "$SUBJECT_ABS")."
fi

# STDOUT: a JSON summary (--json) or the parseable changed-files list.
# Build the JSON arrays by splitting on NEWLINES only (jq -R reads whole lines),
# so a file path containing a space is never split into two bogus entries.
lines_to_json() { printf '%s\n' "${1:-}" | jq -R . | jq -s -c 'map(select(length>0))'; }
if [[ "$AS_JSON" == "1" ]]; then
  if have_cmd jq; then
    jq -n \
      --argjson files "$(lines_to_json "$CHANGED")" \
      --argjson pass1 "$(lines_to_json "$PASS1_FILES")" \
      --argjson pass2 "$(lines_to_json "$PASS2_FILES")" \
      --argjson pass3 "$(lines_to_json "$PASS3_FILES")" --arg cstatus "$COMPAT_STATUS" \
      --arg floor "$PHP_FLOOR" --arg ceil "$PHP_CEIL" \
      --argjson count "$COUNT" --argjson digests "$([[ "$USE_DIGESTS" == "1" ]] && echo true || echo false)" \
      --argjson applied "$([[ "$APPLY" == "1" ]] && echo true || echo false)" \
      --argjson errors "$ERRORS_JSON" \
      --argjson rules "$(lines_to_json "$APPLIED_RULES")" --argjson hits "$RULE_HITS" \
      --arg dstatus "$DIGESTS_STATUS" --arg dsha "$DIGESTS_SHA" \
      --argjson p1ok "$([[ "$PASS1_OK" == "1" ]] && echo true || echo false)" \
      '{tool:"rector",
        status:(if ($p1ok | not) then "error" elif ($errors|length) > 0 then "partial" else "ok" end),
        ok:$p1ok, errors:$errors,
        digests_status:$dstatus, digests_sha:(if $dsha == "" then null else $dsha end),
        applied:$applied, digests_pass:$digests, changed_files:$count,
        files:$files, pass1_files:$pass1, compat_files:$pass3, pass2_files:$pass2, rules:$rules,
        rule_hits:$hits, compat_status:$cstatus, php_floor:$floor, php_ceiling:$ceil}'
  fi
elif [[ -n "$CHANGED" ]]; then
  printf '%s\n' "$CHANGED"
fi
[[ "$FAILED" == "1" ]] && exit 3
[[ "$PARTIAL" == "1" ]] && exit 4
exit 0
