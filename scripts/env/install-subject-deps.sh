#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/install-subject-deps.sh
# Install the subject's own Composer requirements into its test-bed: the
# libraries and contrib modules its composer.json `require` lists
# (fightbulc/moment, giggsey/libphonenumber-for-php, drupal/address, ...).
# A test-bed is a fresh drupal/recommended-project with the subject placed
# under web/*/custom/, so nothing installs them otherwise: PHPStan then reports
# their classes as not found, the module cannot be enabled and its tests
# cannot run (training run module 06, twig_extender). Runs after
# place-subject.sh and install-toolchain.sh.
#
# Left out: php, ext-*, lib-*, composer-plugin-api, composer/*,
# cweagans/composer-patches, drupal/core and drupal/core-* (the bed's own).
# A package the bed already has is "present" (never upgraded here).
#
# Only on a test-bed drupilot built (testbed_kind not none): the composer.json
# of your own project is never changed; there the missing packages are only
# listed (status report-only), with the command to add them.
#
# A package Composer cannot install (a contrib module with no release for the
# bed's core, a library whose constraint conflicts) is a blocker: the run says
# which one and why, installs the others, and exits 3. DRUPILOT_LENIENT_DEPS
# (install-toolchain.sh) is the way to install a contrib module whose
# drupal/core constraint does not admit the bed's core yet.
#
# Usage:
#   install-subject-deps.sh --subject DIR [--root ROOT] [--dry-run] [--json]
#                           [-h|--help]
#   --subject DIR  the placed module/theme (its composer.json is read)
#   --root ROOT    the Drupal project root (default: find_drupal_root)
#   --dry-run      list what would be installed; Composer is not run
#   --json         {status, root, testbed, requested, present, installed,
#                   failed: [{name, constraint, reason}], skipped} on STDOUT
#                   status: nothing | present | installed | report-only |
#                   partial | failed | dry-run
#
# Exit codes: 0 nothing to do, installed, present, report-only or dry-run ·
#             1 usage error · 2 no Drupal root / DDEV not running ·
#             3 at least one requirement could not be installed (a blocker).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
ROOT=""
DRY=0
AS_JSON=0
usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --root) ROOT="${2:-}"; shift 2;;
    --root=*) ROOT="${1#*=}"; shift;;
    --dry-run) DRY=1; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done

[[ -n "$SUBJECT" ]] || die "--subject DIR is required." 1
[[ -d "$SUBJECT" ]] || die "Subject directory not found: '$SUBJECT'." 1
have_cmd jq || die "jq is required." 2
SUBJECT_ABS="$(cd "$SUBJECT" && pwd)"
if [[ -z "$ROOT" ]]; then ROOT="$(find_drupal_root "$SUBJECT_ABS" 2>/dev/null || true)"; fi
[[ -n "$ROOT" && -f "$ROOT/composer.json" ]] || die "No Drupal project root with a composer.json for '$SUBJECT_ABS' (run /drupilot-setup first)." 2
ROOT="$(cd "$ROOT" && pwd)"
KIND="$(testbed_kind "$ROOT")"

# The requirements: name<TAB>constraint, the bed's own packages left out.
REQS=""
if [[ -f "$SUBJECT_ABS/composer.json" ]]; then
  REQS="$(jq -r '(.require // {}) | to_entries[]
      | select(.key | test("^(php|ext-.*|lib-.*|composer-plugin-api|composer/.*|cweagans/composer-patches|drupal/core|drupal/core-.*)$") | not)
      | "\(.key)\t\(.value)"' "$SUBJECT_ABS/composer.json" 2>/dev/null || true)"
fi
# What the bed already has.
INSTALLED_NAMES=""
if [[ -f "$ROOT/composer.lock" ]]; then
  INSTALLED_NAMES="$(jq -r '((.packages // []) + (."packages-dev" // []))[] | .name' "$ROOT/composer.lock" 2>/dev/null || true)"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-subjdeps.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/requested.tsv"; : > "$TMP/present.tsv"; : > "$TMP/todo.tsv"; : > "$TMP/installed.tsv"; : > "$TMP/failed.tsv"
if [[ -n "$REQS" ]]; then
  printf '%s\n' "$REQS" > "$TMP/requested.tsv"
  while IFS=$'\t' read -r name con; do
    [[ -n "$name" ]] || continue
    if printf '%s\n' "$INSTALLED_NAMES" | grep_q -x -F "$name"; then
      printf '%s\t%s\n' "$name" "$con" >> "$TMP/present.tsv"
    else
      printf '%s\t%s\n' "$name" "$con" >> "$TMP/todo.tsv"
    fi
  done < "$TMP/requested.tsv"
fi

STATUS=""
if [[ ! -s "$TMP/requested.tsv" ]]; then
  STATUS="nothing"
elif [[ ! -s "$TMP/todo.tsv" ]]; then
  STATUS="present"
elif [[ "$DRY" == "1" ]]; then
  STATUS="dry-run"
elif [[ "$KIND" == "none" ]]; then
  STATUS="report-only"
fi

if [[ -z "$STATUS" ]]; then
  ddev_running "$ROOT" || die "The DDEV project of $ROOT is not running (ddev start)." 2
  SPECS=()
  while IFS=$'\t' read -r name con; do [[ -n "$name" ]] && SPECS+=("$name:$con"); done < "$TMP/todo.tsv"
  log_step "ddev composer require -W --no-interaction ${SPECS[*]}"
  if ( cd "$ROOT" && ddev composer require -W --no-interaction "${SPECS[@]}" < /dev/null >&2 ); then
    cp "$TMP/todo.tsv" "$TMP/installed.tsv"
  else
    # One by one, to name the blocker(s) and still install the rest.
    log_warn "Composer could not install them together; trying one by one."
    while IFS=$'\t' read -r name con; do
      [[ -n "$name" ]] || continue
      if ( cd "$ROOT" && ddev composer require -W --no-interaction "$name:$con" < /dev/null > "$TMP/one.log" 2>&1 ); then
        printf '%s\t%s\n' "$name" "$con" >> "$TMP/installed.tsv"
      else
        reason="$(grep -E -i 'requires drupal/core|conflict|could not be resolved|does not match|not found|Problem [0-9]' "$TMP/one.log" | sed -n '1,3p' | tr -s '[:space:]' ' ' | cut -c1-400)"
        printf '%s\t%s\t%s\n' "$name" "$con" "${reason:-composer require failed}" >> "$TMP/failed.tsv"
        log_err "Could not install $name:$con into the test-bed${reason:+: $reason}"
      fi
    done < "$TMP/todo.tsv"
  fi
  if [[ -s "$TMP/failed.tsv" && -s "$TMP/installed.tsv" ]]; then STATUS="partial"
  elif [[ -s "$TMP/failed.tsv" ]]; then STATUS="failed"
  else STATUS="installed"; fi
fi

tsv_json() { jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], constraint: .[1]} + (if length > 2 then {reason: .[2]} else {} end))' "$1"; }
if [[ "$AS_JSON" == "1" ]]; then
  todo="$(tsv_json "$TMP/todo.tsv")"
  jq -n -c --arg s "$STATUS" --arg r "$ROOT" --arg k "$KIND" \
    --argjson req "$(tsv_json "$TMP/requested.tsv")" --argjson pres "$(tsv_json "$TMP/present.tsv")" \
    --argjson inst "$(tsv_json "$TMP/installed.tsv")" --argjson fail "$(tsv_json "$TMP/failed.tsv")" --argjson todo "$todo" \
    '{status: $s, root: $r, testbed: $k, requested: $req, present: $pres, installed: $inst, failed: $fail,
      skipped: (if $s == "report-only" or $s == "dry-run" then $todo else [] end)}'
fi
case "$STATUS" in
  nothing) log_ok "The subject's composer.json requires nothing the test-bed lacks.";;
  present) log_ok "Every requirement of the subject is already in the test-bed.";;
  installed) log_ok "Installed the subject's requirements into the test-bed: $(cut -f1 "$TMP/installed.tsv" | tr '\n' ' ')";;
  dry-run) log_info "[dry-run] would run: ddev composer require -W $(awk -F'\t' '{printf "%s:%s ", $1, $2}' "$TMP/todo.tsv")";;
  report-only) log_warn "$ROOT is your own project (not a drupilot test-bed): its composer.json is left alone. Missing: $(cut -f1 "$TMP/todo.tsv" | tr '\n' ' ')— add them with ddev composer require.";;
  partial|failed) log_err "The test-bed lacks requirements of the subject: $(cut -f1 "$TMP/failed.tsv" | tr '\n' ' ')(analysis and tests cannot see them)."; exit 3;;
esac
exit 0
