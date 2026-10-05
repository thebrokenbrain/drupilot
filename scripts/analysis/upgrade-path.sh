#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/upgrade-path.sh
# Resolve the UPGRADE PLAN of a module/theme: every version a stage uses, from
# the subject, the target major, the PHP target, the strategy and the version
# data (AR-06, ADR 0017; schemas/upgrade-plan.schema.json). Pure: it reads the
# subject, the version data (config/, or DRUPILOT_VERSION_DATA_DIR) and the
# root's lock, and writes nothing. No stage derives a version on its own.
#
# Vocabulary (AR-01):
#   S              source era: the oldest Drupal major whose APIs the code
#                  still uses (scripts/analysis/detect-source.sh, ADR 0016)
#   T              target major (11 or 12; data-driven). S = T is a PHP-only
#                  move
#   C = [F, T.x]   declared range: core_version_requirement; F is the lowest
#                  core minor kept
#   strategy       auto | target-only | keep-previous | widest | explicit (the
#                  0.9 names d11-only and keep-d10 are aliases); keep-current
#                  is a resolved output only, never an input
#   L              PHP floor: max(php_min(F), the code's floor
#                  (detect-php-floor.sh), the subject's require.php); L = P
#                  with DRUPILOT_REQUIRE_PHP_FLOOR=target
#   P              PHP final: DRUPILOT_PHP_TARGET, else targets/T.json
#                  .php_defaults.env; it must be a PHP M supports, M the
#                  newest released minor of T or its pre-release minor in
#                  preview
#   W = [L..P]     PHP window: PHPStan phpVersion, PHPCompatibility testVersion
#   bed core       the exact core of the test-bed: the lock's when it is a T
#                  version, else the newest release of M
#   hop            one edge of config/paths/graph.json
#   track          standard (S 8..12) or d7-assisted (S = 7)
#
# Usage:
#   upgrade-path.sh [--subject DIR] [--phase draft|final] [--target N]
#                   [--php X.Y] [--strategy S] [--range C] [--root DIR]
#                   [--phpstan FILE] [--auto] [--json] [-h|--help]
#
# Options:
#   --subject DIR    The module/theme directory (default: the current one).
#   --phase P        draft (default: static signals, before a test-bed) or
#                    final (also the analyzer signal: --phpstan).
#   --target N       T (default DRUPILOT_TARGET_MAJOR, 11).
#   --php X.Y        P (default as above).
#   --strategy S     The compat strategy (default
#                    DRUPILOT_CORE_TARGET_STRATEGY, auto).
#   --range C        An explicit declared range (implies --strategy explicit).
#   --root DIR       The Drupal root whose lock names the bed core and whose
#                    drupal-rector names the Rector sets (default: the
#                    subject's root, if any).
#   --phpstan FILE   With --phase final: a PHPStan --error-format=json output
#                    of the subject (detect-source.sh signal 4).
#   --auto           An autonomous run (as DRUPILOT_AUTONOMOUS=true): a Drupal
#                    7 source is refused.
#   --json           Print only the JSON on STDOUT (no summary on STDERR).
#   -h, --help       Show this help.
#
# Output (STDOUT, keys sorted): the plan, or on a refusal
#   {schema_version, status: "refused", phase, code, message,
#    violations: [{id, detail}], choices: [{id, label, tab, set}]}
#   (tab: the config/choices.json key to re-ask, or null; set: the config
#   values that resolve it). A Drupal 7 source in an autonomous run is code
#   d7-auto, its message also printed alone on STDERR.
#
# Exit codes: 0 the plan · 1 usage error (a bad --phase/--target/--php/
# --strategy, no subject, --strategy explicit without --range) · 2 refused
# (an assertion of AR-06 failed, or the target is not a port target).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
PHASE="draft"
TARGET=""
PHP=""
STRATEGY=""
RANGE=""
ROOT=""
PHPSTAN_FILE=""
AUTO=0
JSON_ONLY=0
D7_AUTO_MESSAGE="D7 source detected: the d7-assisted track is experimental and never runs in auto. Run '/drupilot full' with DRUPILOT_EXPERIMENTAL_D7=on, or '/drupilot-assess' for a viability verdict."

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a directory" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --phase) PHASE="${2:-}"; shift 2 || die "--phase needs draft or final" 1;;
    --phase=*) PHASE="${1#*=}"; shift;;
    --target) TARGET="${2:-}"; shift 2 || die "--target needs a major" 1;;
    --target=*) TARGET="${1#*=}"; shift;;
    --php) PHP="${2:-}"; shift 2 || die "--php needs X.Y" 1;;
    --php=*) PHP="${1#*=}"; shift;;
    --strategy) STRATEGY="${2:-}"; shift 2 || die "--strategy needs a value" 1;;
    --strategy=*) STRATEGY="${1#*=}"; shift;;
    --range) RANGE="${2:-}"; shift 2 || die "--range needs a constraint" 1;;
    --range=*) RANGE="${1#*=}"; shift;;
    --root) ROOT="${2:-}"; shift 2 || die "--root needs a directory" 1;;
    --root=*) ROOT="${1#*=}"; shift;;
    --phpstan) PHPSTAN_FILE="${2:-}"; shift 2 || die "--phpstan needs a file" 1;;
    --phpstan=*) PHPSTAN_FILE="${1#*=}"; shift;;
    --auto) AUTO=1; shift;;
    --json) JSON_ONLY=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done

have_cmd jq || die "jq is required by upgrade-path.sh" 1
case "$PHASE" in draft|final) : ;; *) die "Invalid --phase '$PHASE' (expected draft or final)." 1;; esac
[[ -z "$PHPSTAN_FILE" || "$PHASE" == "final" ]] || die "--phpstan needs --phase final." 1
[[ -n "$TARGET" ]] || TARGET="$(resolve_target_major)"
[[ "$TARGET" =~ ^[0-9]+$ ]] || die "Invalid target major '$TARGET' (expected an integer such as 11)." 1
[[ -n "$PHP" ]] || PHP="$(resolve_php_target_for "$TARGET")"
[[ "$PHP" =~ ^[0-9]+\.[0-9]+$ ]] || die "Invalid PHP target '$PHP' (expected X.Y such as 8.3)." 1
if [[ -z "$STRATEGY" ]]; then
  if [[ -n "$RANGE" ]]; then STRATEGY="explicit"; else STRATEGY="$(config_get DRUPILOT_CORE_TARGET_STRATEGY auto)"; fi
fi
STRATEGY="$(lc "$STRATEGY")"
case "$STRATEGY" in
  d11-only) STRATEGY="target-only";;
  keep-d10) STRATEGY="keep-previous";;
esac
case "$STRATEGY" in
  auto|target-only|keep-previous|widest|explicit) : ;;
  *) die "Invalid strategy '$STRATEGY' (expected auto, target-only, keep-previous, widest or explicit; keep-current is an outcome, not an input)." 1;;
esac
[[ "$STRATEGY" != "explicit" || -n "$RANGE" ]] || die "--strategy explicit needs --range." 1
[[ -z "$RANGE" || "$STRATEGY" == "explicit" ]] || die "--range is an explicit range: it cannot go with --strategy $STRATEGY." 1
SUBJECT="${SUBJECT:-$PWD}"
SUBJECT_ABS="$(CDPATH='' cd -P -- "$SUBJECT" 2> /dev/null && pwd || true)"
[[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1
if [[ -z "$ROOT" ]]; then ROOT="$(find_drupal_root "$SUBJECT_ABS" 2> /dev/null || true)"; fi
if [[ -n "$ROOT" ]]; then
  ROOT="$(CDPATH='' cd -P -- "$ROOT" 2> /dev/null && pwd || true)"
  [[ -n "$ROOT" ]] || die "Root directory not found." 1
fi
if [[ "$AUTO" == "0" ]] && config_bool DRUPILOT_AUTONOMOUS 0; then AUTO=1; fi
ALLOW=false
config_bool DRUPILOT_ALLOW_PRERELEASE 0 && ALLOW=true

# --- refusal ------------------------------------------------------------------
# refuse VIOLATIONS_JSON [MESSAGE] -> the refusal on STDOUT, exit 2.
refuse() {
  local v="$1" msg="${2:-}" choices
  choices="$(printf '%s' "$v" | jq -c --argjson t "$TARGET" --arg p "$PHP" --arg l "${L:-}" \
    --arg fs "${FLOOR_STRATEGY:-detect}" --arg prev "$((TARGET - 1))" '
    def c($id; $label; $tab; $set): {id: $id, label: $label, tab: $tab, set: $set};
    [.[] | .id as $i
      | if $i == "prerelease-not-opted-in" then
          c("allow-prerelease"; "Port to Drupal \($t) as a preview"; null; {DRUPILOT_ALLOW_PRERELEASE: "true"}),
          c("target-\($prev)"; "Port to Drupal \($prev)"; "TARGET_MAJOR"; {DRUPILOT_TARGET_MAJOR: $prev})
        elif $i == "invalid-target" or $i == "source-above-target" then
          c("target"; "Choose another target major"; "TARGET_MAJOR"; {})
        elif $i == "floor-above-final" then
          c("php-target"; "Raise the PHP target to \($l)"; "PHP_TARGET"; {DRUPILOT_PHP_TARGET: $l})
        elif $i == "php-not-supported" then
          c("php-target"; "Choose a PHP target the core supports"; "PHP_TARGET"; {})
        elif $i == "minor-php-disjoint" then
          c("php-target"; "Choose another PHP target"; "PHP_TARGET"; {}),
          c("target-only"; "Declare Drupal \($t) only"; null; {DRUPILOT_CORE_TARGET_STRATEGY: "target-only"}),
          (if $fs == "target" then c("floor-detect"; "Detect the PHP floor from the code"; null; {DRUPILOT_REQUIRE_PHP_FLOOR: "detect"}) else empty end)
        elif $i == "three-majors" then
          c("keep-previous"; "Keep only the previous major"; null; {DRUPILOT_CORE_TARGET_STRATEGY: "keep-previous"}),
          c("target-only"; "Declare Drupal \($t) only"; null; {DRUPILOT_CORE_TARGET_STRATEGY: "target-only"})
        else empty end]
    | reduce .[] as $x ([]; if any(.[]; .id == $x.id) then . else . + [$x] end)')"
  [[ -n "$msg" ]] || msg="The upgrade plan cannot be resolved: $(printf '%s' "$v" | jq -r '.[0].detail')."
  jq -n -S --arg ph "$PHASE" --argjson v "$v" --argjson c "$choices" --arg m "$msg" \
    '{schema_version: 1, status: "refused", phase: $ph, code: $v[0].id, message: $m, violations: $v, choices: $c}'
  [[ "$JSON_ONLY" == "1" ]] || log_err "$msg"
  exit 2
}

# --- source era ---------------------------------------------------------------
DS="$(plugin_root)/scripts/analysis/detect-source.sh"
if [[ "$PHASE" == "final" ]]; then
  SRC="$("$BASH" "$DS" --subject "$SUBJECT_ABS" --full ${PHPSTAN_FILE:+--phpstan "$PHPSTAN_FILE"} --json)" || die "detect-source.sh failed on '$SUBJECT_ABS'." 1
else
  SRC="$("$BASH" "$DS" --subject "$SUBJECT_ABS" --static --json)" || die "detect-source.sh failed on '$SUBJECT_ABS'." 1
fi
S="$(printf '%s' "$SRC" | jq -r '.source_major')"
TRACK="$(printf '%s' "$SRC" | jq -r '.track')"
if [[ "$TRACK" == "d7-assisted" && "$AUTO" == "1" ]]; then
  printf '%s\n' "$D7_AUTO_MESSAGE" >&2
  JSON_ONLY=1 refuse "$(jq -n -c --arg d "$D7_AUTO_MESSAGE" '[{id: "d7-auto", detail: $d}]')" "$D7_AUTO_MESSAGE"
fi
EVIDENCE_HASH="$(printf '%s' "$SRC" | jq -S -c . | json_hash)"
[[ -n "$EVIDENCE_HASH" ]] || die "upgrade-path.sh needs sha256sum or shasum." 1

# --- target -------------------------------------------------------------------
LOCK_CORE=""
if [[ -n "$ROOT" ]]; then
  LOCK_F="$(project_state_path "$ROOT")/drupilot-lock.json"
  [[ -r "$LOCK_F" ]] && LOCK_CORE="$(jq -r '.drupal.core // empty' "$LOCK_F" 2> /dev/null || true)"
fi
TB_RC=0; TB="$(plan_target_block "$TARGET" "$ALLOW" "$LOCK_CORE")" || TB_RC=$?
[[ "$TB_RC" == "0" ]] || refuse "[$TB]"
BED="$(printf '%s' "$TB" | jq -r .bed_core)"

# --- range ----------------------------------------------------------------------
FLOOR_STRATEGY="$(lc "$(config_get DRUPILOT_REQUIRE_PHP_FLOOR detect)")"
[[ "$FLOOR_STRATEGY" == "target" ]] || FLOOR_STRATEGY="detect"
DETECTED=""
if [[ "$FLOOR_STRATEGY" == "detect" ]]; then
  DETECTED="$("$BASH" "$(plugin_root)/scripts/analysis/detect-php-floor.sh" --subject "$SUBJECT_ABS" --json 2> /dev/null \
    | jq -r '.floor // empty' 2> /dev/null || true)"
fi
if [[ "$STRATEGY" == "explicit" ]]; then
  RS="explicit"; C="$RANGE"
else
  case "$STRATEGY" in
    target-only) DS_STRAT="d11-only";;
    keep-previous) DS_STRAT="keep-d10";;
    widest)
      [[ "$(target_get "$TARGET" '.default_ranges.widest')" == "$(target_get "$TARGET" '.default_ranges["keep-previous"]')" ]] \
        || die "The widest range of Drupal $TARGET differs from its keep-previous range: pass it with --range." 1
      DS_STRAT="keep-d10";;
    *) DS_STRAT="auto";;
  esac
  REC="$(DRUPILOT_PHP_TARGET="$PHP" DRUPILOT_CORE_TARGET_STRATEGY="$DS_STRAT" DRUPILOT_DETECTED_PHP_FLOOR="$DETECTED" \
    strategy_decide "$SUBJECT_ABS" "$TARGET" port auto)"
  RS="$(printf '%s' "$REC" | jq -r .resolved_v1)"
  C="$(printf '%s' "$REC" | jq -r .req)"
fi
F="$(core_floor_from_requirement "$C")"
SPANS=false
[[ "$(range_majors "$C" | wc -w | tr -d ' ')" -ge 2 ]] && SPANS=true

# --- PHP floor L ------------------------------------------------------------------
if [[ "$FLOOR_STRATEGY" == "target" ]]; then
  L="$PHP"
else
  L=""
  _max_php() { if [[ -n "$1" ]] && { [[ -z "$L" ]] || ! version_ge "$L" "$1"; }; then L="$1"; fi; return 0; }
  [[ -z "$F" ]] || _max_php "$(target_get "${F%%.*}" ".minors[\"$F\"].php_min")"
  _max_php "$DETECTED"
  [[ ! -f "$SUBJECT_ABS/composer.json" ]] || _max_php "$(php_constraint_floor "$(jq -r '.require.php // empty' "$SUBJECT_ABS/composer.json" 2> /dev/null || true)")"
  [[ -n "$L" ]] || L="$PHP"
fi
PHP_BLOCK="$(plan_php_block "$L" "$PHP" "$SPANS")" || die "PHP $L or $PHP is not a PHP version the data knows." 1

# --- hops and sets -------------------------------------------------------------
HOPS_RC=0; HOPS="$(plan_hops "$S" "$TARGET")" || HOPS_RC=$?
[[ "$HOPS_RC" == "0" || "$S" -gt "$TARGET" ]] || die "No upgrade path from Drupal $S to Drupal $TARGET in paths/graph.json." 1
SETS="$(rector_sets_for_plan "$HOPS" "$F" "$BED" "$ROOT")"
MATRIX="$(plan_test_matrix "$BED" "$PHP" "$L" "$C" "$TARGET")"

PLAN="$(jq -n -S \
  --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ver "$(plugin_version)" --arg ph "$PHASE" \
  --arg mn "$(subject_machine_name "$SUBJECT_ABS")" --arg ty "$(subject_type "$SUBJECT_ABS" 2> /dev/null || printf module)" \
  --argjson s "$S" --arg tr "$TRACK" --arg ev "$EVIDENCE_HASH" --argjson tb "$TB" \
  --arg strat "$STRATEGY" --arg rs "$RS" --arg c "$C" --arg f "$F" --argjson sp "$SPANS" \
  --argjson php "$PHP_BLOCK" --arg hops "$HOPS" --argjson sets "$SETS" \
  --argjson bc "$(plan_rector_bc "$C" "$F")" --arg lvl "$(php_rector_level "$L")" --argjson skip "$(plan_rector_skip)" \
  --arg pl "$(config_get DRUPILOT_PHPSTAN_LEVEL 2)" --argjson tm "$MATRIX" \
  --argjson ci "$(plan_ci_flags "$MATRIX" "$PHP" "$BED")" --argjson det "$(plan_detectors $HOPS)" \
  --arg dh "$(version_data_hash)" '
  {schema_version: 1,
   meta: {generated_at: $gen, drupilot_version: $ver, phase: $ph},
   subject: {machine_name: $mn, type: $ty},
   source: {major: $s, track: $tr, evidence_hash: $ev},
   target: ($tb | del(.m, .toolchain_cell)),
   range: {strategy: $strat, resolved_strategy: $rs, constraint: $c, floor: (if $f == "" then null else $f end), spans_majors: $sp},
   php: $php,
   hops: ($hops | split(" ") | map(select(length > 0))),
   rector: ($sets + {bc: $bc, php_level: $lvl, skip: $skip, compat_rules: null, polyfills: null, tests_pass: null}),
   phpstan: {profile: "compat", level: ($pl | tonumber? // $pl)},
   toolchain_cell: $tb.toolchain_cell,
   test_matrix: $tm,
   detectors: $det,
   core_removals: null,
   hard_breaks: null,
   ci_flags: $ci,
   patch_name: "\($mn)-port-to-drupal-\($tb.major).patch",
   workspace_suffix: "-d\($tb.major)",
   data_hash: (if $dh == "" then null else "sha256:\($dh)" end),
   automation_estimate: null}')"

V_RC=0; V="$(plan_assert "$PLAN")" || V_RC=$?
[[ "$V_RC" == "0" ]] || refuse "$V"
printf '%s\n' "$PLAN"
if [[ "$JSON_ONLY" == "0" ]]; then
  log_ok "Upgrade plan ($PHASE): Drupal $S -> $TARGET$([[ "$ALLOW" == true && "$(printf '%s' "$TB" | jq -r .preview)" == true ]] && printf ' (preview)'), $C, PHP $L..$PHP, bed $BED, hops: ${HOPS:-none}"
fi
exit 0
