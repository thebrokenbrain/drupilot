#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/run-rector.sh
# Run drupal-rector against a module/theme to find and (optionally) fix
# Drupal 9/10 -> Drupal 11 deprecations.
#
# Two passes:
#   Pass 1 (always): the official, stable `palantirnet/drupal-rector`. A
#                    `rector.php` is ensured at the Drupal root (copied from
#                    vendor or the plugin template if missing).
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
#                      list: {changed_files, files, pass1_files, pass2_files} —
#                      pass1 = official, pass2 = digests. Used for the reproducible
#                      verdict and the per-pass digests review.
#   -h, --help         Show this help.
#
# Gate: `analyze` profile (git + jq + composer/php).
# Output: status/logging on STDERR; a plain list of changed files (or, with
#         --json, a JSON summary) on STDOUT.
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

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

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
  bash "$PREFLIGHT" --profile analyze || true
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
RUNNER="$(drupal_runner "$DRUPAL_ROOT")"   # "ddev exec" when DDEV is up, else ""
PHP_TARGET="$(resolve_php_target)"

log_info "Drupal root : $DRUPAL_ROOT"
log_info "Subject     : $SUBJECT_REL"
log_info "PHP target  : $PHP_TARGET"
if [[ -n "$RUNNER" ]]; then
  log_info "Runner      : DDEV ($RUNNER)"
else
  log_info "Runner      : host (vendor/bin)"
fi
if php_target_unconfirmed "$PHP_TARGET"; then
  log_warn "PHP target $PHP_TARGET is not officially confirmed for Drupal 11; Rector will use the highest confirmed PHP set."
fi

# --- Verify the Rector binary is present ----------------------------------
if [[ ! -x "$DRUPAL_ROOT/vendor/bin/rector" && ! -f "$DRUPAL_ROOT/vendor/bin/rector" ]]; then
  die "vendor/bin/rector is missing. Install the toolchain first (e.g. via /drupilot-setup, which runs 'composer require --dev palantirnet/drupal-rector')." 2
fi

# --- Ensure a rector.php exists at the Drupal root (idempotent) -----------
RECTOR_PHP="$DRUPAL_ROOT/rector.php"
VENDOR_RECTOR="$DRUPAL_ROOT/vendor/palantirnet/drupal-rector/rector.php"
TEMPLATE_RECTOR="$(plugin_root)/templates/rector.php.tmpl"

if [[ -f "$RECTOR_PHP" ]]; then
  log_ok "rector.php already present at the Drupal root (left untouched)."
elif [[ -f "$VENDOR_RECTOR" ]]; then
  cp "$VENDOR_RECTOR" "$RECTOR_PHP"
  log_ok "Copied rector.php from vendor/palantirnet/drupal-rector/rector.php."
elif [[ -f "$TEMPLATE_RECTOR" ]]; then
  # The template uses {{PLACEHOLDER}} tokens; substitute the ones we know.
  sed -e "s|{{SUBJECT_PATH}}|${SUBJECT_REL}|g" \
      -e "s|{{PHP_TARGET}}|${PHP_TARGET}|g" \
      -e "s|{{DRUPAL_TARGET}}|$(resolve_drupal_target)|g" \
      "$TEMPLATE_RECTOR" > "$RECTOR_PHP"
  log_ok "Wrote rector.php from the drupilot template (subject: $SUBJECT_REL)."
else
  die "No rector.php found and no source to create one (neither $VENDOR_RECTOR nor $TEMPLATE_RECTOR exists)." 2
fi

# --- Helpers --------------------------------------------------------------
# run_rector <dry_run:0/1> [extra args...] -> echoes captured output on STDOUT
# of this function (we capture it to summarize and to feed the changed-files list).
RECTOR_RAW=""
run_rector_pass() {
  local dry="$1"; shift
  local -a cmd=()
  [[ -n "$RUNNER" ]] && read -r -a cmd <<<"$RUNNER"
  cmd+=(vendor/bin/rector process "$SUBJECT_REL")
  if [[ "$dry" == "1" ]]; then cmd+=(--dry-run); fi
  cmd+=("$@")
  log_step "Rector: ${cmd[*]}"
  # Capture combined output; do not let a non-zero rc (dry-run reports diffs as
  # rc!=0) abort the script.
  set +e
  RECTOR_RAW="$("${cmd[@]}" 2>&1)"
  local rc=$?
  set -e
  printf '%s\n' "$RECTOR_RAW" >&2
  return "$rc"
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

# --- Pass 1: official palantirnet/drupal-rector ---------------------------
hr
log_step "Pass 1 — palantirnet/drupal-rector (official, stable)"
if [[ "$APPLY" == "1" ]]; then
  run_rector_pass 0 || true
else
  log_info "Dry-run (no files modified). Use --apply to write changes."
  run_rector_pass 1 || true
fi
PASS1_RAW="$RECTOR_RAW"

# --- Pass 2: complementary dbuytaert/drupal-digests (optional) ------------
PASS2_RAW=""
if [[ "$USE_DIGESTS" == "1" ]]; then
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
    if [[ "$FREEZE_SHA" == "1" && -n "$DIGESTS_SHA" ]]; then
      lock_set .digests.sha "$DIGESTS_SHA" 2>/dev/null || true
      lock_set .digests.ref "$CONFIGURED_REF" 2>/dev/null || true
      log_info "Froze the digests SHA in the lockfile (reused on later runs while deterministic)."
    fi

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
      RUNNER="$DIGESTS_RUNNER" run_rector_pass 0 --config "$CONFIG_PATH" || true
    else
      log_info "Dry-run of the digests pass (no files modified). Use --apply only after reviewing the diff."
      RUNNER="$DIGESTS_RUNNER" run_rector_pass 1 --config "$CONFIG_PATH" || true
    fi
    PASS2_RAW="$RECTOR_RAW"
  fi
fi

# --- Summary --------------------------------------------------------------
hr
PASS1_FILES="$(emit_changed_files "$PASS1_RAW" 2>/dev/null || true)"
PASS2_FILES=""
[[ -n "$PASS2_RAW" ]] && PASS2_FILES="$(emit_changed_files "$PASS2_RAW" 2>/dev/null || true)"
CHANGED="$( { printf '%s\n' "$PASS1_FILES"; printf '%s\n' "$PASS2_FILES"; } | grep -v '^$' | sort -u || true)"

COUNT=0
[[ -n "$CHANGED" ]] && COUNT="$(printf '%s\n' "$CHANGED" | grep -c . || true)"

if [[ "$APPLY" == "1" ]]; then
  log_ok "Rector apply complete. $COUNT file(s) reported as changed."
  log_warn "Next: review the diff, then run phpstan and the test suite to validate."
else
  log_ok "Rector dry-run complete. $COUNT file(s) would change."
  log_info "Re-run with --apply once you have reviewed the proposed diff."
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
      --argjson count "$COUNT" --argjson digests "$([[ "$USE_DIGESTS" == "1" ]] && echo true || echo false)" \
      --argjson applied "$([[ "$APPLY" == "1" ]] && echo true || echo false)" \
      '{tool:"rector", applied:$applied, digests_pass:$digests, changed_files:$count,
        files:$files, pass1_files:$pass1, pass2_files:$pass2}'
  fi
elif [[ -n "$CHANGED" ]]; then
  printf '%s\n' "$CHANGED"
fi
