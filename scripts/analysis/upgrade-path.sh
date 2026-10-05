#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/upgrade-path.sh
# Resolve the UPGRADE PLAN of a module/theme: every version a stage uses, from
# the subject, the target major, the PHP target, the strategy and the version
# data (AR-06, ADR 0017; schemas/upgrade-plan.schema.json). It reads the
# subject, the version data (config/, or DRUPILOT_VERSION_DATA_DIR) and the
# root's lock, and writes nothing unless --freeze asks it to freeze the plan
# in that lock (ADR 0018). No stage derives a version on its own: they read
# the frozen plan through plan_get (scripts/lib/plan.sh).
#
# The frozen plan (ADR 0018): in deterministic mode (DRUPILOT_DETERMINISTIC,
# default true) a plan frozen for the same subject is reused, printed as it
# was frozen and with nothing written, when its phase is at least the
# requested one and the requested T, P, strategy, explicit range and
# pre-release opt-in are its own; anything else resolves afresh (a change of
# the version data does not). A value nobody asked for again stays the
# frozen one: a P that is the data's default, the bed core while the lock
# records none, the toolchain cell; a lock that records another core for the
# test-bed re-plans. A final plan may only add hops or raise F over a frozen
# draft, and never change T, P, the toolchain cell or the bed core's minor
# of a frozen plan (final-changes-frozen); with DRUPILOT_DETERMINISTIC=false
# it re-resolves without that guard.
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
#                   [--phpstan FILE] [--auto] [--freeze] [--json] [-h|--help]
#
# Options:
#   --subject DIR    The module/theme directory (default: the current one).
#   --phase P        draft (default: static signals, before a test-bed) or
#                    final (also the analyzer signal: --phpstan).
#   --target N       T (default DRUPILOT_TARGET_MAJOR, else the major an
#                    explicit DRUPILOT_DRUPAL_TARGET names, else 11; X12).
#   --php X.Y        P (default as above).
#   --strategy S     The compat strategy (default
#                    DRUPILOT_CORE_TARGET_STRATEGY, auto).
#   --range C        An explicit declared range (implies --strategy explicit).
#                    Without --range or --strategy, an explicit
#                    DRUPILOT_DRUPAL_TARGET that admits two or more majors
#                    (e.g. '^10.3 || ^11') is one too, unless
#                    DRUPILOT_CORE_TARGET_STRATEGY is set (X12, ADR 0021);
#                    a one-major value ('^11.2', '~11.2.0', '11.x-dev') only
#                    pins the test-bed's core, as in 0.9.
#   --root DIR       The Drupal root whose lock names the bed core, whose
#                    drupal-rector names the Rector sets and whose
#                    .drupilot.json holds the persisted choices (default: the
#                    subject's root, found from its logical path, as the lock
#                    is keyed; for a loose subject, DRUPILOT_PROJECT_DIR or
#                    the subject itself, never the cwd's root). An absolute
#                    path that does not exist yet (a loose subject's future
#                    test-bed) is kept as given.
#   --phpstan FILE   With --phase final: a PHPStan --error-format=json output
#                    of the subject (detect-source.sh signal 4).
#   --auto           An autonomous run (as DRUPILOT_AUTONOMOUS=true): a Drupal
#                    7 source is refused.
#   --freeze         Freeze the resolved plan in the root's lock
#                    (upgrade_plan, upgrade_plan_hash, upgrade_plan_phase,
#                    data_hash; one write, only after exit 0; needs a root).
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
# --strategy, no subject or no machine name, --strategy explicit without
# --range, an empty --range or one with no lower bound, an invalid
# DRUPILOT_PHPSTAN_LEVEL) · 2 refused (an assertion of AR-06 failed: the
# codes of plan_assert in scripts/lib/plan.sh, invalid-target,
# php-not-supported for a PHP the data does not know, d7-auto). A
# standard-track S below 8 starts the hops at 8.
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
RANGE_SET=0
ROOT=""
PHPSTAN_FILE=""
AUTO=0
JSON_ONLY=0
FREEZE=0
D7_AUTO_MESSAGE="D7 source detected: the d7-assisted track is experimental and never runs in auto. Run '/drupilot full' with DRUPILOT_EXPERIMENTAL_D7=on, or '/drupilot-assess' for a viability verdict."

usage() { print_usage "$0"; }

# future_path ABS -> the path ABS will have once it exists, as `cd && pwd`
# will print it then: its deepest existing ancestor resolved, the rest
# appended with `.`, `..`, empty and trailing components applied (a trailing
# slash or a `..` in DRUPILOT_WORKSPACE_DIR keys the lock as the test-bed's).
future_path() {
  local head="$1" tail="" c out
  while [[ -n "$head" && ! -d "$head" ]]; do tail="${head##*/}/$tail"; head="${head%/*}"; done
  out="$(CDPATH='' cd -- "${head:-/}" 2> /dev/null && pwd)" || out="/"
  local IFS=/
  for c in $tail; do
    case "$c" in
      ''|.) : ;;
      ..) out="${out%/*}"; [[ -n "$out" ]] || out="/";;
      *) [[ "$out" == "/" ]] && out="/$c" || out="$out/$c";;
    esac
  done
  printf '%s' "$out"
  return 0
}

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
    --range) RANGE="${2:-}"; RANGE_SET=1; shift 2 || die "--range needs a constraint" 1;;
    --range=*) RANGE="${1#*=}"; RANGE_SET=1; shift;;
    --root) ROOT="${2:-}"; shift 2 || die "--root needs a directory" 1;;
    --root=*) ROOT="${1#*=}"; shift;;
    --phpstan) PHPSTAN_FILE="${2:-}"; shift 2 || die "--phpstan needs a file" 1;;
    --phpstan=*) PHPSTAN_FILE="${1#*=}"; shift;;
    --auto) AUTO=1; shift;;
    --freeze) FREEZE=1; shift;;
    --json) JSON_ONLY=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done

have_cmd jq || die "jq is required by upgrade-path.sh" 1
case "$PHASE" in draft|final) : ;; *) die "Invalid --phase '$PHASE' (expected draft or final)." 1;; esac
[[ -z "$PHPSTAN_FILE" || "$PHASE" == "final" ]] || die "--phpstan needs --phase final." 1
[[ "$RANGE_SET" == "0" || -n "$RANGE" ]] || die "--range needs a constraint." 1
# The subject and its root first, by their logical paths (the lock and the
# root's .drupilot.json are keyed by them, as lock-sync.sh writes them); every
# setting below is read from that root.
SUBJECT="${SUBJECT:-$PWD}"
SUBJECT_ABS="$(CDPATH='' cd -- "$SUBJECT" 2> /dev/null && pwd || true)"
[[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1
if [[ -z "$ROOT" ]]; then ROOT="$(find_drupal_root "$SUBJECT_ABS" 2> /dev/null || true)"; fi
if [[ -n "$ROOT" ]]; then
  # A loose subject's future root (resolve-workspace.sh) may not exist yet:
  # an absolute path is kept as given, so the draft plan is frozen under the
  # key the test-bed will have (ADR 0018).
  if _r="$(CDPATH='' cd -- "$ROOT" 2> /dev/null && pwd)"; then ROOT="$_r"
  elif [[ "$ROOT" == /* ]]; then ROOT="$(future_path "$ROOT")"
  else die "Root directory not found: '$ROOT' (a root that does not exist yet must be an absolute path)." 1
  fi
  export DRUPILOT_PROJECT_DIR="$ROOT"
  # The root's .drupilot.json may hold an old name (a DRUPILOT_KEEP_D10): warn
  # about it here, in the main shell, once (the later lookups run in subshells).
  _config_alias_prewarn
elif [[ -z "${DRUPILOT_PROJECT_DIR:-}" ]]; then
  # A loose subject: never the .drupilot.json of whatever root holds the cwd.
  export DRUPILOT_PROJECT_DIR="$SUBJECT_ABS"
fi
[[ -n "$TARGET" ]] || TARGET="$(resolve_target_major)"
[[ "$TARGET" =~ ^[1-9][0-9]*$ ]] || die "Invalid target major '$TARGET' (expected an integer such as 11)." 1
# Whether P was asked for (--php or a DRUPILOT_PHP_TARGET setting), or is the
# target's data default: a frozen plan keeps its own P over a data default.
PHP_EXPLICIT=1
if [[ -z "$PHP" ]]; then
  PHP="$(config_get_explicit DRUPILOT_PHP_TARGET)"
  if [[ -z "$PHP" ]]; then PHP_EXPLICIT=0; PHP="$(resolve_php_target_for "$TARGET")"; fi
fi
[[ "$PHP" =~ ^[0-9]+\.[0-9]+$ ]] || die "Invalid PHP target '$PHP' (expected X.Y such as 8.3)." 1
if [[ -z "$STRATEGY" && -z "$RANGE" ]]; then
  # X12 (ADR 0021): an explicit DRUPILOT_DRUPAL_TARGET that admits two or more
  # majors is a declared range override, unless DRUPILOT_CORE_TARGET_STRATEGY
  # itself is set too (it wins; a DRUPILOT_KEEP_D10 boolean does not count).
  _dtr="$(drupal_target_range)"
  if [[ -n "$_dtr" ]]; then
    if [[ -n "$(config_get_explicit_noalias DRUPILOT_CORE_TARGET_STRATEGY)" ]]; then
      log_warn "DRUPILOT_DRUPAL_TARGET='$_dtr' is not used as the declared range: DRUPILOT_CORE_TARGET_STRATEGY is set."
    else
      RANGE="$_dtr"; RANGE_SET=1
    fi
  fi
fi
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
[[ "$FREEZE" == "0" || -n "$ROOT" ]] || die "--freeze needs a Drupal root (--root DIR)." 1
PHPSTAN_LEVEL="$(config_get DRUPILOT_PHPSTAN_LEVEL 2)"
[[ "$PHPSTAN_LEVEL" =~ ^(max|[0-9]+)$ ]] || die "Invalid DRUPILOT_PHPSTAN_LEVEL '$PHPSTAN_LEVEL' (expected 0-10 or max)." 1
if [[ "$AUTO" == "0" ]] && config_bool DRUPILOT_AUTONOMOUS 0; then AUTO=1; fi
ALLOW=false
config_bool DRUPILOT_ALLOW_PRERELEASE 0 && ALLOW=true

# _max_php X -> L becomes X when X is higher (or L is still empty).
_max_php() { if [[ -n "${1:-}" ]] && { [[ -z "$L" ]] || ! version_ge "$L" "$1"; }; then L="$1"; fi; return 0; }

# php_min_at MAJOR.MINOR -> that core minor's php_min, else the php_min of the
# newest verified minor of its major below it (11.5, not in the data yet:
# 11.4's 8.3); nothing when its major has none.
php_min_at() {
  local f="${1:-}" m v="" pm rc
  [[ "$f" =~ ^[0-9]+\.[0-9]+$ ]] || return 0
  v="$(target_get "${f%%.*}" ".minors[\"$f\"].php_min")"
  if [[ -z "$v" ]]; then
    for m in $(target_minors "${f%%.*}"); do
      rc=0; core_version_cmp "$m" "$f" || rc=$?
      [[ "$rc" == "0" || "$rc" == "1" ]] || continue
      pm="$(target_get "${f%%.*}" ".minors[\"$m\"].php_min")"
      [[ -z "$pm" ]] || v="$pm"
    done
  fi
  printf '%s' "$v"
  return 0
}

# --- refusal ------------------------------------------------------------------
# refuse VIOLATIONS_JSON [MESSAGE] -> the refusal on STDOUT, exit 2.
refuse() {
  local v="$1" msg="${2:-}" choices
  # The strategy values are the 0.9 names (d11-only = target-only, keep-d10 =
  # keep-previous): the ones every 0.9 surface accepts.
  choices="$(printf '%s' "$v" | jq -c --argjson t "$TARGET" --arg p "$PHP" --arg l "${L:-}" \
    --arg fs "${FLOOR_STRATEGY:-detect}" --arg prev "$((TARGET - 1))" '
    def c($id; $lbl; $tab; $set): {id: $id, label: $lbl, tab: $tab, set: $set};
    ([.[] | select(.id == "minor-php-disjoint") | .minor // "" | split(".")[0] | select(. != "") | tonumber]
      | any(.[]; . == $t)) as $t_disjoint |
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
          (if $t_disjoint then empty else c("target-only"; "Declare Drupal \($t) only"; null; {DRUPILOT_CORE_TARGET_STRATEGY: "d11-only"}) end),
          (if $fs == "target" then c("floor-detect"; "Detect the PHP floor from the code"; null; {DRUPILOT_REQUIRE_PHP_FLOOR: "detect"}) else empty end)
        elif $i == "range-excludes-bed" then
          c("core-target"; "Choose a core range that admits Drupal \($t)"; "CORE_TARGET"; {}),
          c("target-only"; "Declare Drupal \($t) only"; null; {DRUPILOT_CORE_TARGET_STRATEGY: "d11-only"})
        elif $i == "final-changes-frozen" and .field == "php.final" then
          c("keep-frozen"; "Keep the frozen PHP target \(.frozen)"; null; {DRUPILOT_PHP_TARGET: .frozen}),
          c("re-setup"; "Choose the PHP target again (run the setup)"; "PHP_TARGET"; {})
        elif $i == "final-changes-frozen" and .field == "target.major" then
          c("keep-frozen-target"; "Keep the frozen target Drupal \(.frozen)"; null; {DRUPILOT_TARGET_MAJOR: (.frozen | tostring)}),
          c("re-setup-target"; "Choose the target major again (run the setup)"; "TARGET_MAJOR"; {})
        elif $i == "final-changes-frozen" and .field == "range.floor" then
          (if (.frozen_strategy // "") == "explicit" then empty
           else c("keep-frozen-range"; "Keep the frozen core range strategy (\(.frozen_strategy))"; null;
                  {DRUPILOT_CORE_TARGET_STRATEGY: ({"target-only": "d11-only", "keep-previous": "keep-d10", "widest": "keep-d10"}[.frozen_strategy] // .frozen_strategy)}) end),
          c("core-target"; "Choose the core target again"; "CORE_TARGET"; {})
        elif $i == "final-changes-frozen" then
          c("re-setup"; "Run the setup again to re-plan"; null; {})
        elif $i == "three-majors" then
          c("keep-previous"; "Keep only the previous major"; null; {DRUPILOT_CORE_TARGET_STRATEGY: "keep-d10"}),
          c("target-only"; "Declare Drupal \($t) only"; null; {DRUPILOT_CORE_TARGET_STRATEGY: "d11-only"})
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
# The machine name and type: the .info.yml's, else a Drupal 7 .info's (its
# basename; a theme when it names an engine or ships template.php).
MACHINE="$(subject_machine_name "$SUBJECT_ABS" 2> /dev/null || true)"
STYPE="$(subject_type "$SUBJECT_ABS" 2> /dev/null || true)"
if [[ -z "$MACHINE" ]]; then
  D7_INFO="$(subject_d7_info_file "$SUBJECT_ABS" 2> /dev/null || true)"
  if [[ -n "$D7_INFO" ]]; then
    MACHINE="$(basename "$D7_INFO" .info)"
    if [[ -n "$(info_value_d7 "$D7_INFO" engine)" || -f "$SUBJECT_ABS/template.php" ]]; then STYPE="theme"; else STYPE="module"; fi
  fi
fi
[[ "$MACHINE" =~ ^[a-z][a-z0-9_]*$ ]] || die "Cannot read a machine name for '$SUBJECT_ABS' (got '$MACHINE')." 1
[[ -n "$STYPE" ]] || STYPE="module"
# --- the frozen plan (ADR 0018) ---------------------------------------------------
LOCK_CORE=""
if [[ -n "$ROOT" ]]; then
  LOCK_F="$(lock_path "$ROOT")"
  [[ -r "$LOCK_F" ]] && LOCK_CORE="$(jq -r '.drupal.core // empty' "$LOCK_F" 2> /dev/null || true)"
fi
FROZEN=""
[[ -z "$ROOT" ]] || FROZEN="$(plan_frozen "$ROOT")"
if [[ -n "$FROZEN" ]] && [[ "$(printf '%s' "$FROZEN" | jq -r '.subject.machine_name // ""')" != "$MACHINE" ]]; then
  FROZEN=""   # another subject's plan: stale
fi
DET=0
deterministic_mode && DET=1
FROZEN_T=""
if [[ -n "$FROZEN" && "$DET" == "1" ]]; then
  FROZEN_T="$(printf '%s' "$FROZEN" | jq -r '.target.major')"
  # The plan keeps naming the versions it was resolved with until the
  # developer asks for another one: a P nobody asked for is the frozen P, not
  # the data's current default.
  if [[ "$PHP_EXPLICIT" == "0" && "$FROZEN_T" == "$TARGET" ]]; then
    PHP="$(printf '%s' "$FROZEN" | jq -r '.php.final')"
  fi
  # Reused when its phase is high enough and the request is its own: the
  # target, P, the strategy (and an explicit range), the pre-release opt-in
  # a preview needs, and the core the lock records for the test-bed (a setup
  # that installed another core re-plans).
  if printf '%s' "$FROZEN" | jq -e --argjson t "$TARGET" --arg p "$PHP" --arg st "$STRATEGY" --arg r "$RANGE" \
       --arg allow "$ALLOW" --arg ph "$PHASE" --arg lc "${LOCK_CORE#v}" '
       def rank: if . == "final" then 2 elif . == "draft" then 1 else 0 end;
       def minor: split("-")[0] | split(".") | .[0:2] | join(".");
       (.meta.phase | rank) >= ($ph | rank) and .target.major == $t and .php.final == $p
       and .range.strategy == $st and ($st != "explicit" or .range.constraint == $r)
       and ((.target.preview // false) == false or $allow == "true")
       and ($lc == "" or ($lc | split(".")[0]) != ($t | tostring) or ($lc | minor) == (.target.bed_core | minor))' \
       > /dev/null 2>&1; then
    printf '%s\n' "$FROZEN"
    [[ "$JSON_ONLY" == "1" ]] || log_ok "Upgrade plan: the one frozen in the lock ($(printf '%s' "$FROZEN" | jq -r .meta.phase)), reused"
    exit 0
  fi
  # Re-resolved over it: the test-bed core the lock does not record yet stays
  # the frozen one.
  if [[ -z "$LOCK_CORE" && "$FROZEN_T" == "$TARGET" ]]; then
    LOCK_CORE="$(printf '%s' "$FROZEN" | jq -r '.target.bed_core // empty')"
  fi
fi
EVIDENCE_HASH="$(printf '%s' "$SRC" | jq -S -c . | json_hash)"
[[ -n "$EVIDENCE_HASH" ]] || die "upgrade-path.sh needs sha256sum or shasum." 1

# --- target -------------------------------------------------------------------
TB_RC=0; TB="$(plan_target_block "$TARGET" "$ALLOW" "$LOCK_CORE")" || TB_RC=$?
[[ "$TB_RC" == "0" ]] || refuse "[$TB]"
# ... and so does the toolchain cell it was planned with (what the setup
# installs), whatever the data now names for T.
if [[ -n "$FROZEN_T" && "$FROZEN_T" == "$TARGET" ]]; then
  TB="$(printf '%s' "$TB" | jq -c --arg c "$(printf '%s' "$FROZEN" | jq -r '.toolchain_cell // empty')" 'if $c == "" then . else .toolchain_cell = $c end')"
fi
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
[[ -n "$F" ]] || die "--range '$C' names no lowest core version." 1
SPANS=false
[[ "$(range_majors "$C" | wc -w | tr -d ' ')" -ge 2 ]] && SPANS=true

# --- PHP floor L ------------------------------------------------------------------
if [[ "$FLOOR_STRATEGY" == "target" ]]; then
  L="$PHP"
else
  L=""
  _max_php "$(php_min_at "$F")"
  _max_php "$DETECTED"
  [[ ! -f "$SUBJECT_ABS/composer.json" ]] || _max_php "$(php_constraint_floor "$(jq -r '.require.php // empty' "$SUBJECT_ABS/composer.json" 2> /dev/null || true)")"
  [[ -n "$L" ]] || L="$PHP"
fi
[[ -n "$(php_rector_level "$PHP")" ]] \
  || refuse "[$(_plan_issue php-not-supported "PHP $PHP is not a PHP version the version data knows")]"
PHP_BLOCK="$(plan_php_block "$L" "$PHP" "$SPANS")" || die "The PHP floor $L is not a PHP version the version data knows." 1

# --- hops and sets -------------------------------------------------------------
# A standard-track subject never takes the Drupal 7 rewrite edge: an S of 7
# there (an analyzer hit removed in Drupal 8) starts the hops at 8.
HOP_S="$S"
[[ "$TRACK" != "standard" || "$S" -ge 8 ]] || HOP_S=8
HOPS_RC=0; HOPS="$(plan_hops "$HOP_S" "$TARGET")" || HOPS_RC=$?
[[ "$HOPS_RC" == "0" || "$S" -gt "$TARGET" ]] || die "No upgrade path from Drupal $S to Drupal $TARGET in paths/graph.json." 1
SETS="$(rector_sets_for_plan "$HOPS" "$F" "$BED" "$ROOT")"
MATRIX="$(plan_test_matrix "$BED" "$PHP" "$L" "$C" "$TARGET")"

PLAN="$(jq -n -S \
  --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ver "$(plugin_version)" --arg ph "$PHASE" \
  --arg mn "$MACHINE" --arg ty "$STYPE" \
  --argjson s "$S" --arg tr "$TRACK" --arg ev "$EVIDENCE_HASH" --argjson tb "$TB" \
  --arg strat "$STRATEGY" --arg rs "$RS" --arg c "$C" --arg f "$F" --argjson sp "$SPANS" \
  --argjson php "$PHP_BLOCK" --arg hops "$HOPS" --argjson sets "$SETS" \
  --argjson bc "$(plan_rector_bc "$C" "$F")" --arg lvl "$(php_rector_level "$L")" --argjson skip "$(plan_rector_skip)" \
  --arg pl "$PHPSTAN_LEVEL" --argjson tm "$MATRIX" \
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

# The final phase may only add hops or raise F over a frozen plan.
GUARD=""
[[ "$PHASE" != "final" || "$DET" != "1" ]] || GUARD="$FROZEN"
V_RC=0; V="$(plan_assert "$PLAN" "$GUARD")" || V_RC=$?
[[ "$V_RC" == "0" ]] || refuse "$V"
if [[ "$FREEZE" == "1" ]]; then
  lock_location_note "$ROOT"
  plan_freeze "$PLAN" "$PHASE" "$ROOT" || die "Could not freeze the plan in the lock of '$ROOT'." 1
  [[ "$JSON_ONLY" == "1" ]] || log_ok "Frozen in the lock of $ROOT ($PHASE)."
fi
printf '%s\n' "$PLAN"
if [[ "$JSON_ONLY" == "0" ]]; then
  log_ok "Upgrade plan ($PHASE): Drupal $S -> $TARGET$([[ "$ALLOW" == true && "$(printf '%s' "$TB" | jq -r .preview)" == true ]] && printf ' (preview)'), $C, PHP $L..$PHP, bed $BED, hops: ${HOPS:-none}"
fi
exit 0
