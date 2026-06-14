#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/detect-php-floor.sh
# Best-effort detection of the minimum PHP version a module/theme's code needs
# (the "floor": the highest version-specific construct it uses). It answers two
# symmetric questions at once:
#
#   1. FLOOR (look down) — to set an HONEST composer `require.php` when keeping
#      Drupal 10 (`^10 || ^11`). Drupal 10 allows PHP 8.1 but Drupal 11 needs
#      >= 8.3, so if the ported code uses no syntax/functions newer than 8.1 it
#      can genuinely support a D10 + PHP 8.1 site; if it uses 8.2/8.3 constructs
#      it cannot.
#   2. TARGET COMPATIBILITY (look up) — whether the code is compatible with the
#      Drupal 11 PHP target (DRUPILOT_PHP_TARGET, default 8.3). If the floor is
#      ABOVE the target (e.g. the code uses an 8.4 construct while the target is
#      8.3), the code is NOT compatible with the target: `target_compatible` is
#      false and the caller must raise the target or remove the construct.
#      (Within one PHP major, higher minors are backwards compatible — 8.4 runs
#      8.3 code bar non-fatal deprecations — so a floor <= target means OK; the
#      authoritative proof of "runs on the target" is still the test suite, which
#      drupilot runs inside DDEV on the target PHP version.)
#
# This is a HEURISTIC syntactic scan (a curated list of well-known 8.2/8.3/8.4
# language constructs and function additions), NOT a full static analysis. It is
# deliberately CONSERVATIVE: it reports the highest version whose constructs it
# finds, and only reports 8.1 when it finds none. A missed construct could lower
# the floor wrongly (a D10 + low-PHP site would then install and fatal at runtime)
# or miss a target incompatibility, so callers acting on the result MUST still
# rely on the test suite / PHPCompatibility for the authoritative answer.
#
# Usage:
#   detect-php-floor.sh [--subject DIR] [--json] [-h|--help]
#
#   --subject DIR   module/theme directory (default: current directory).
#   --json          print only the JSON payload (suppress the human line).
#
# Output (stdout): JSON
#   { floor: "8.1".."8.4", target: "8.3", target_compatible: true|false,
#     method: "heuristic-scan", signals: [ {version, pattern, location} ... ],
#     scanned_files: N }
# Read-only and ungated.
#
# Exit codes: 0 ok · 1 usage/error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
JSON_ONLY=0

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --json) JSON_ONLY=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

SUBJECT="${SUBJECT:-$PWD}"
SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
[[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1
have_cmd jq || die "jq is required for detect-php-floor.sh." 1

# PHP source extensions Drupal uses.
INCLUDES=(--include='*.php' --include='*.module' --include='*.inc' \
          --include='*.install' --include='*.theme' --include='*.profile' \
          --include='*.engine')

FLOOR="8.1"
SIGNALS_JSON="[]"
SCANNED="$(grep -rIl "${INCLUDES[@]}" -e '' "$SUBJECT_ABS" 2>/dev/null | wc -l | tr -d ' ')"

# scan_signal VERSION ERE LABEL -> append a JSON object if found; echo nothing.
scan_for() {
  local ver="$1" ere="$2" label="$3" hit
  hit="$(grep -rInE "${INCLUDES[@]}" -e "$ere" "$SUBJECT_ABS" 2>/dev/null | head -n1 || true)"
  if [[ -n "$hit" ]]; then
    # location relative to the subject (file:line), trimmed.
    local loc="${hit%%:*}"; local line; line="$(printf '%s' "$hit" | cut -d: -f2)"
    loc="${loc#"$SUBJECT_ABS"/}:$line"
    SIGNALS_JSON="$(printf '%s' "$SIGNALS_JSON" | jq -c \
      --arg v "$ver" --arg p "$label" --arg l "$loc" \
      '. + [{version:$v, pattern:$p, location:$l}]')"
    return 0
  fi
  return 1
}

# Curated, low-false-positive signals scanned directly (no delimiter packing —
# the ERE alternations contain '|', so a delimited list would truncate them).
found_82=0 found_83=0 found_84=0

# PHP 8.4-only language / stdlib additions.
scan_for 8.4 '\b(public|protected|private)\(set\)'        'asymmetric visibility (private(set))' && found_84=1 || true
scan_for 8.4 '#\[\\Deprecated\b'                          '#[\Deprecated] attribute'      && found_84=1 || true
scan_for 8.4 '\b(array_find|array_any|array_all|array_find_key|mb_trim|mb_ltrim|mb_rtrim|mb_str_pad|request_parse_body)[[:space:]]*\(' '8.4 stdlib function' && found_84=1 || true

# PHP 8.3-only language / stdlib additions.
scan_for 8.3 '#\[\\?Override\]'                            '#[\Override] attribute'        && found_83=1 || true
scan_for 8.3 '\bjson_validate[[:space:]]*\('              'json_validate()'               && found_83=1 || true
scan_for 8.3 '\bstr_(increment|decrement)[[:space:]]*\(' 'str_increment()/str_decrement()' && found_83=1 || true
scan_for 8.3 '\bconst[[:space:]]+\??(int|float|string|bool|array|iterable|object|mixed|self|static|parent)[[:space:]]+[A-Za-z_]' 'typed class constant' && found_83=1 || true

# PHP 8.2-only language / stdlib additions.
scan_for 8.2 '\breadonly[[:space:]]+class\b'              'readonly class'                && found_82=1 || true
scan_for 8.2 '#\[\\?AllowDynamicProperties\]'            '#[\AllowDynamicProperties] attribute' && found_82=1 || true
scan_for 8.2 '\b(mysqli_execute_query|ini_parse_quantity|memory_reset_peak_usage|curl_upkeep)[[:space:]]*\(' '8.2 stdlib function' && found_82=1 || true

if [[ "$found_84" == "1" ]]; then FLOOR="8.4"
elif [[ "$found_83" == "1" ]]; then FLOOR="8.3"
elif [[ "$found_82" == "1" ]]; then FLOOR="8.2"
else FLOOR="8.1"; fi

# Target compatibility: the code is OK for the target when its floor <= target.
TARGET="$(resolve_php_target)"
if version_ge "$TARGET" "$FLOOR"; then TARGET_COMPAT="true"; else TARGET_COMPAT="false"; fi

OUT="$(jq -n --arg floor "$FLOOR" --arg target "$TARGET" \
  --argjson target_compatible "$TARGET_COMPAT" \
  --argjson signals "$SIGNALS_JSON" --argjson scanned "${SCANNED:-0}" \
  '{floor:$floor, target:$target, target_compatible:$target_compatible,
    method:"heuristic-scan", signals:$signals, scanned_files:$scanned}')"

if [[ "$JSON_ONLY" -eq 0 ]]; then
  if [[ "$TARGET_COMPAT" != "true" ]]; then
    log_warn "PHP target: the code uses PHP $FLOOR-only constructs but the Drupal 11 target is $TARGET — it is NOT compatible with $TARGET. Raise DRUPILOT_PHP_TARGET to $FLOOR or remove the construct."
    printf '%s' "$SIGNALS_JSON" | jq -r '.[] | select(.version > "'"$TARGET"'") | "    - " + .version + ": " + .pattern + " (" + .location + ")"' >&2 || true
  elif [[ "$FLOOR" == "8.1" ]]; then
    log_info "PHP floor (heuristic): no PHP 8.2+ constructs found across $SCANNED file(s) — code looks 8.1-compatible and is OK for the target $TARGET (the test suite on PHP $TARGET is the authoritative check)."
  else
    log_info "PHP floor (heuristic): the code uses PHP $FLOOR constructs; OK for the target $TARGET. Drupal 10 support is only honest on PHP $FLOOR+ (the test suite on PHP $TARGET is the authoritative check)."
    printf '%s' "$SIGNALS_JSON" | jq -r '.[] | "    - " + .version + ": " + .pattern + " (" + .location + ")"' >&2 || true
  fi
fi

printf '%s\n' "$OUT"
exit 0
