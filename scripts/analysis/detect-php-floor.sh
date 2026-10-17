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
# This is a HEURISTIC syntactic scan (a curated list of well-known 8.2 to 8.5
# language constructs and function additions; the 8.5 ones read on php.net's
# migration85 pages), NOT a full static analysis. For syntax it is a fallback:
# the php stage runs php -l on every PHP of the window. A function's
# availability on the floor is checked only by this scan and by the test
# suite on the floor's PHP (the PHP_LOW test leg). It is
# deliberately CONSERVATIVE: it reports the highest version whose constructs it
# finds, and only reports 8.1 when it finds none. A missed construct could lower
# the floor wrongly (a D10 + low-PHP site would then install and fatal at runtime)
# or miss a target incompatibility, so callers acting on the result MUST still
# rely on the test suite / PHPCompatibility for the authoritative answer.
# With --range, a function a symfony/polyfill-phpXY package defines does not
# raise the floor when every core the range admits provides that package
# (core_range_polyfills, scripts/lib/plan.sh): its signal is kept, marked
# polyfilled.
#
# Usage:
#   detect-php-floor.sh [--subject DIR] [--range CONSTRAINT] [--json] [-h|--help]
#
#   --subject DIR   module/theme directory (default: current directory).
#   --range C       the declared core range (e.g. '^11.3'): the polyfills every
#                   core of C provides are taken into account.
#   --json          print only the JSON payload (suppress the human line).
#
# Output (stdout): JSON
#   { floor: "8.1".."8.5", target: "8.3", target_compatible: true|false,
#     method: "heuristic-scan", signals: [ {version, pattern, location} ... ],
#     scanned_files: N }
#   With --range, also range and polyfills (the packages every core of the
#   range provides); a signal whose every hit calls a polyfilled function
#   carries polyfilled: true and does not count.
# Read-only and ungated.
#
# Exit codes: 0 ok · 1 usage/error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/php-scan.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/php-scan.sh"

SUBJECT=""
JSON_ONLY=0
RANGE=""

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --range) RANGE="${2:-}"; shift 2 || die "--range needs a value" 1;;
    --range=*) RANGE="${1#*=}"; shift;;
    --json) JSON_ONLY=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

SUBJECT="${SUBJECT:-$PWD}"
SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
[[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1
have_cmd jq || die "jq is required for detect-php-floor.sh." 1

# grep_sources <grep args...> -> grep over the PHP source files Drupal uses
# (find selects them: BusyBox grep has no --include).
grep_sources() {
  find "$SUBJECT_ABS" -type f \( -name '*.php' -o -name '*.module' -o -name '*.inc' \
    -o -name '*.install' -o -name '*.theme' -o -name '*.profile' -o -name '*.engine' \) \
    -exec grep "$@" {} + 2>/dev/null
  return 0
}

FLOOR="8.1"
SIGNALS_JSON="[]"
SCANNED="$(grep_sources -Il -e '' | wc -l | tr -d ' ')"

# scan_signal VERSION ERE LABEL -> append a JSON object if found; echo nothing.
# The first hit in path order (then line order), whatever order find walks in.
scan_for() {
  local ver="$1" ere="$2" label="$3" hit
  hit="$(grep_sources -HInE -e "$ere" | LC_ALL=C sort -t: -k1,1 -k2,2n | sed -n '1p' || true)"
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

# The functions every core of --range provides through a polyfill.
POLY='{"functions":[],"packages":[]}'
[[ -z "$RANGE" ]] || POLY="$(core_range_polyfills "$RANGE")"
POLY_FUNCS=" $(printf '%s' "$POLY" | jq -r '.functions | join(" ")') "

# _signal VERSION LABEL HIT POLYFILLED -> append the signal of a grep hit
# (path:line:code), its location relative to the subject.
_signal() {
  local loc="${3%%:*}" line
  line="$(printf '%s' "$3" | cut -d: -f2)"
  loc="${loc#"$SUBJECT_ABS"/}:$line"
  SIGNALS_JSON="$(printf '%s' "$SIGNALS_JSON" | jq -c --arg v "$1" --arg p "$2" --arg l "$loc" --argjson pf "$4" \
    '. + [{version: $v, pattern: $p, location: $l} + (if $pf then {polyfilled: true} else {} end)]')"
  return 0
}
# build_code_dir -> CODE_DIR: each PHP source blanked to its code
# (php_code_lines: comments, string contents, heredocs and inline HTML), as
# $CODE_DIR/<n>, line N of the source being line N of <n>; $CODE_DIR/files
# lists the sources in that order. Made once.
CODE_DIR=""
trap '[[ -z "$CODE_DIR" ]] || rm -rf "$CODE_DIR" 2> /dev/null || true' EXIT
build_code_dir() {
  local f k=0
  [[ -z "$CODE_DIR" ]] || return 0
  CODE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-php-floor.XXXXXX")"
  find "$SUBJECT_ABS" -type f \( -name '*.php' -o -name '*.module' -o -name '*.inc' \
    -o -name '*.install' -o -name '*.theme' -o -name '*.profile' -o -name '*.engine' \) -print 2> /dev/null \
    | LC_ALL=C sort > "$CODE_DIR/files"
  while IFS= read -r f; do
    k=$((k + 1)); php_code_lines "$f" > "$CODE_DIR/$k"
  done < "$CODE_DIR/files"
  return 0
}
# scan_funcs VERSION LABEL FUNC... -> scan_for for calls of the FUNCs: a
# method or static call (->f(, ::f() and a definition are no call, and a FUNC
# the module itself defines as a global function (in its code, in a file with
# no namespace) is provided. The first hit (path order, then line) that calls
# a FUNC no polyfill of --range provides is the signal (return 0); when every
# hit calls a polyfilled one, the first is kept, marked polyfilled, and does
# not count (return 1).
scan_funcs() {
  local ver="$1" label="$2" alt hits hit code n first="" defined="" k _f
  shift 2
  alt="$(IFS='|'; printf '%s' "$*")"
  hits="$(grep_sources -HInE -e "\\b($alt)[[:space:]]*\\(" | LC_ALL=C sort -t: -k1,1 -k2,2n || true)"
  [[ -n "$hits" ]] || return 1
  build_code_dir
  k=0
  while IFS= read -r _f; do
    k=$((k + 1))
    [[ "$(grep -cE '^[[:space:]]*namespace[[:space:]]+[A-Za-z_\\]' "$CODE_DIR/$k" 2> /dev/null || true)" == "0" ]] || continue
    defined="$defined $(grep -ohE "^[[:space:]]*function[[:space:]]+&?($alt)[[:space:]]*\\(" "$CODE_DIR/$k" 2> /dev/null \
      | sed 's/^[[:space:]]*function[[:space:]]*&*//; s/[[:space:]]*($//' | tr '\n' ' ' || true)"
  done < "$CODE_DIR/files"
  defined=" $defined "
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    code="${hit#*:}"; code="${code#*:}"
    # The line without its method and static calls and its definitions.
    code="$(printf '%s\n' "$code" | sed -E 's/(->|::)[[:space:]]*[A-Za-z_][A-Za-z0-9_]*//g; s/function[[:space:]]+&?[A-Za-z_][A-Za-z0-9_]*//g')"
    for n in $(printf '%s\n' "$code" | grep -oE "(^|[^A-Za-z0-9_\$])($alt)[[:space:]]*\\(" | sed 's/^[^A-Za-z_]*//; s/[[:space:]]*($//' || true); do
      case "$defined" in *" $n "*) continue;; esac
      [[ -n "$first" ]] || first="$hit"
      case "$POLY_FUNCS" in *" $n "*) ;; *) _signal "$ver" "$label" "$hit" false; return 0;; esac
    done
  done <<< "$hits"
  [[ -n "$first" ]] || return 1
  _signal "$ver" "$label" "$first" true
  return 1
}
# scan_code VERSION ERE LABEL TOKEN -> scan_for on the code only
# (build_code_dir), so a regex or a docblock is no signal; a tree with no
# TOKEN (a fixed string the ERE needs) anywhere is not blanked for it.
scan_code() {
  local ver="$1" ere="$2" label="$3" token="$4" hit idx
  [[ -n "$(grep_sources -lF -e "$token")" ]] || return 1
  build_code_dir
  hit="$( (cd "$CODE_DIR" && LC_ALL=C find . -type f ! -name files -exec grep -nHE -e "$ere" {} + 2> /dev/null) \
    | sed 's#^\./##' | LC_ALL=C sort -t: -k1,1n -k2,2n | sed -n '1p' || true)"
  [[ -n "$hit" ]] || return 1
  idx="${hit%%:*}"
  _signal "$ver" "$label" "$(sed -n "${idx}p" "$CODE_DIR/files"):${hit#*:}" false
  return 0
}

# Curated, low-false-positive signals scanned directly (no delimiter packing —
# the ERE alternations contain '|', so a delimited list would truncate them).
found_82=0 found_83=0 found_84=0 found_85=0

# PHP 8.5-only language / stdlib additions (php.net migration85.new-features
# and migration85.new-functions).
# The syntax is searched in the code only (a regex or a comment is no pipe);
# the 8.5 attributes are no signal: an older PHP ignores an attribute.
scan_code 8.5 "(^|[^|])\\|>[[:space:]]*([A-Za-z_\\\\\$('\"[]|\$)" 'pipe operator (|>)' '|>'       && found_85=1 || true
scan_code 8.5 '\(void\)[[:space:]]*[$A-Za-z_\\]'          '(void) cast' '(void)'          && found_85=1 || true
scan_funcs 8.5 '8.5 stdlib function' array_first array_last get_error_handler get_exception_handler && found_85=1 || true

# PHP 8.4-only language / stdlib additions.
scan_for 8.4 '\b(public|protected|private)\(set\)'        'asymmetric visibility (private(set))' && found_84=1 || true
scan_for 8.4 '#\[\\Deprecated\b'                          '#[\Deprecated] attribute'      && found_84=1 || true
scan_funcs 8.4 '8.4 stdlib function' array_find array_any array_all array_find_key fpow mb_trim mb_ltrim mb_rtrim mb_ucfirst mb_lcfirst request_parse_body && found_84=1 || true

# PHP 8.3-only language / stdlib additions.
scan_for 8.3 '#\[\\?Override\]'                            '#[\Override] attribute'        && found_83=1 || true
scan_for 8.3 '\bjson_validate[[:space:]]*\('              'json_validate()'               && found_83=1 || true
scan_for 8.3 '\bstr_(increment|decrement)[[:space:]]*\(' 'str_increment()/str_decrement()' && found_83=1 || true
scan_funcs 8.3 'mb_str_pad()' mb_str_pad && found_83=1 || true
scan_for 8.3 '\bconst[[:space:]]+\??(int|float|string|bool|array|iterable|object|mixed|self|static|parent)[[:space:]]+[A-Za-z_]' 'typed class constant' && found_83=1 || true

# PHP 8.2-only language / stdlib additions.
scan_for 8.2 '\breadonly[[:space:]]+class\b'              'readonly class'                && found_82=1 || true
scan_for 8.2 '#\[\\?AllowDynamicProperties\]'            '#[\AllowDynamicProperties] attribute' && found_82=1 || true
scan_for 8.2 '\b(mysqli_execute_query|ini_parse_quantity|memory_reset_peak_usage|curl_upkeep)[[:space:]]*\(' '8.2 stdlib function' && found_82=1 || true

if [[ "$found_85" == "1" ]]; then FLOOR="8.5"
elif [[ "$found_84" == "1" ]]; then FLOOR="8.4"
elif [[ "$found_83" == "1" ]]; then FLOOR="8.3"
elif [[ "$found_82" == "1" ]]; then FLOOR="8.2"
else FLOOR="8.1"; fi

# Target compatibility: the code is OK for the target when its floor <= target.
TARGET="$(resolve_php_target)"
if version_ge "$TARGET" "$FLOOR"; then TARGET_COMPAT="true"; else TARGET_COMPAT="false"; fi

OUT="$(jq -n --arg floor "$FLOOR" --arg target "$TARGET" \
  --argjson target_compatible "$TARGET_COMPAT" \
  --argjson signals "$SIGNALS_JSON" --argjson scanned "${SCANNED:-0}" --arg range "$RANGE" --argjson poly "$POLY" \
  '{floor:$floor, target:$target, target_compatible:$target_compatible,
    method:"heuristic-scan", signals:$signals, scanned_files:$scanned}
   + (if $range == "" then {} else {range: $range, polyfills: $poly.packages} end)')"

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
