#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/strategy.sh
# Core compatibility reasoning: requirement ranges, floors, core-matrix legs
# and recommend_core_target.
#
# Part of the shared library: scripts/lib/common.sh sources it with the other
# domain libs (never source it alone); see common.sh for the conventions.
# =============================================================================

# core_requirement_admits <constraint> <major> -> 0 when a Composer-style
# core_version_requirement admits some <major>.x release ('^10 || ^11' admits
# 11; '^8.8 || ^9 || ^10' does not; '>=10' does; '^10.3' does not). A
# heuristic over each `||` alternative's bounds (^, ~, >=, >, <, <=, =, X.*),
# enough to flag an obsolete requirement; an unreadable constraint returns 1.
core_requirement_admits() {
  printf '%s' "${1:-}" | tr -d "\"'" | tr '|' '\n' | AWKV_m="${2:-11}" awk '
    BEGIN { m = ENVIRON["AWKV_m"] + 0; ok = 0 }
    function maj(p,   v) { sub(/^(\^|~|>=|<=|>|<|==|=|v)+/, "", p); split(p, v, "."); return v[1] + 0 }
    {
      n = split($0, parts, /[[:space:],]+/); lo = -1; hi = 999; seen = 0
      for (i = 1; i <= n; i++) {
        p = parts[i]
        if (p == "" || p !~ /[0-9]/) continue
        seen = 1
        if (p ~ /^(\^|~)/) { x = maj(p); if (x > lo) lo = x; if (x < hi) hi = x }
        else if (p ~ /^>/) { x = maj(p); if (x > lo) lo = x }
        else if (p ~ /^<=/) { x = maj(p); if (x < hi) hi = x }
        else if (p ~ /^</) { x = maj(p); q = p; sub(/^</, "", q); if (q ~ /^[0-9]+(\.0)*$/) x = x - 1; if (x < hi) hi = x }
        else { x = maj(p); if (x > lo) lo = x; if (x < hi) hi = x }
      }
      if (seen && lo <= m && m <= hi) ok = 1
    }
    END { exit ok ? 0 : 1 }'
}

# core_floor_from_requirement <constraint> -> the lowest core MAJOR.MINOR the
# Composer-style constraint admits ('^10 || ^11' -> 10.0, '^10.3 || ^11' ->
# 10.3, '^9.2 || ^10' -> 9.2, '>=10.2' -> 10.2, '^11' -> 11.0). Upper bounds
# ('<', '<=', '!=') are ignored. Prints nothing (and returns 0) when no version
# can be read, so callers treat an unknown floor as "unknown", never guess.
core_floor_from_requirement() {
  printf '%s' "${1:-}" | tr -d "\"'" | tr '|' '\n' | awk '
    {
      n = split($0, parts, /[[:space:],]+/)
      for (i = 1; i <= n; i++) {
        p = parts[i]
        if (p == "" || p ~ /^(<|!=)/) continue
        sub(/^(\^|~|>=|>|==|=|v)+/, "", p)
        if (p !~ /^[0-9]+/) continue
        split(p, v, ".")
        maj = v[1] + 0; mn = (v[2] ~ /^[0-9]+$/) ? v[2] + 0 : 0
        if (!have || maj < bmaj || (maj == bmaj && mn < bmin)) { bmaj = maj; bmin = mn; have = 1 }
        break
      }
    }
    END { if (have) printf "%d.%d", bmaj, bmin }'
  return 0
}

# core_requirement_raise_floor <constraint> <MAJOR.MINOR> -> the constraint with
# its lowest admitted core raised to MAJOR.MINOR, keeping every higher major:
# ('^10 || ^11', 10.3) -> '^10.3 || ^11' · ('^10 || ^11', 11.1) -> '^11.1' ·
# ('^10.3 || ^11 || ^12', 10.2) -> unchanged · ('^11', 11.1) -> '^11.1' ·
# ('>=10.2', 10.3) -> '>=10.3' · ('', 10.3) -> '^10.3'. An alternative of a lower major is dropped; one of the
# same major whose minor is lower is replaced by ^MAJOR.MINOR. Used when a
# change needs a newer core than declared (e.g. plugin attributes whose
# annotation is removed: convert-attributes.sh). Pure: STDOUT only.
core_requirement_raise_floor() {
  local req="${1:-}" floor="${2:-}"
  [[ "$floor" =~ ^[0-9]+\.[0-9]+$ ]] || { printf '%s' "$req"; return 0; }
  printf '%s' "$req" | tr -d "\"'" | tr '|' '\n' | AWKV_f="$floor" awk '
    BEGIN { split(ENVIRON["AWKV_f"], f, "."); fmaj = f[1] + 0; fmin = f[2] + 0; out = ""; same = 0 }
    function add(s) { out = (out == "") ? s : out " || " s }
    {
      a = $0; sub(/^[ \t]+/, "", a); sub(/[ \t]+$/, "", a)
      if (a == "") next
      p = a; sub(/^(\^|~|>=|>|==|=|v)+/, "", p)
      if (p !~ /^[0-9]+/) { add(a); next }
      split(p, v, "."); maj = v[1] + 0; mn = (v[2] ~ /^[0-9]+$/) ? v[2] + 0 : 0
      if (maj < fmaj) next
      if (maj == fmaj) {
        same = 1
        if (mn < fmin) a = (a ~ /^>/) ? ">=" fmaj "." fmin : ((fmin > 0) ? "^" fmaj "." fmin : "^" fmaj)
      }
      add(a)
    }
    END {
      fl = (fmin > 0) ? "^" fmaj "." fmin : "^" fmaj
      if (!same) out = (out == "") ? fl : fl " || " out
      printf "%s", out
    }'
  return 0
}

# core_verify_legs <constraint> -> the core "legs" a Composer-style constraint
# asks to verify, one per line, lowest first: the lower bound of each declared
# major, as MAJOR.MINOR when an explicit minor above 0 is given, else MAJOR
# ('^10 || ^11' -> 10, 11 · '^10.3 || ^11' -> 10.3, 11 · '^11' -> 11 ·
# '>=10.2' -> 10.2). Majors below 10 are dropped (drupilot only verifies the
# Drupal 10 / 11 range phpstan-drupal 2.x supports). Upper bounds are ignored.
# Prints nothing when no version can be read. Pure: no I/O besides STDOUT.
core_verify_legs() {
  printf '%s' "${1:-}" | tr -d "\"'" | tr '|' '\n' | awk '
    {
      n = split($0, parts, /[[:space:],]+/)
      for (i = 1; i <= n; i++) {
        p = parts[i]
        if (p == "" || p ~ /^(<|!=)/) continue
        sub(/^(\^|~|>=|>|==|=|v)+/, "", p)
        if (p !~ /^[0-9]+/) continue
        split(p, v, ".")
        maj = v[1] + 0; mn = (v[2] ~ /^[0-9]+$/) ? v[2] + 0 : 0
        if (maj < 10) break
        if (!(maj in best) || mn < best[maj]) best[maj] = mn
        break
      }
    }
    END {
      for (m = 10; m <= 99; m++) {
        if (!(m in best)) continue
        if (best[m] > 0) printf "%d.%d\n", m, best[m]; else printf "%d\n", m
      }
    }'
  return 0
}

# core_matrix_legs <constraint> -> the legs verify-core-matrix.sh checks by
# default (--cores auto): core_verify_legs, plus the FLOOR minor of every
# major declared without a minor that is below the newest declared major or
# below Drupal 11, the test-bed's major ('^10 || ^11' -> 10.0, 10, 11; '^10' ->
# 10.0, 10; '^11' -> 11). A bare '^10' leg resolves to the newest
# 10.x, which cannot see an API added after 10.0 (e.g. the Block attribute,
# 10.2), so the floor is checked too; an explicit minor floor ('^10.3 || ^11'
# -> 10.3, 11) is already its own leg. Pure: STDOUT only.
core_matrix_legs() {
  local legs top
  legs="$(core_verify_legs "${1:-}")"
  [[ -n "$legs" ]] || return 0
  top="$(printf '%s\n' "$legs" | tail -n 1 | cut -d. -f1)"
  printf '%s\n' "$legs" | awk -v top="$top" '
    { split($0, v, "."); if ($0 !~ /\./ && (v[1] + 0 < top + 0 || v[1] + 0 < 11)) print v[1] ".0"; print }'
  return 0
}

# ---------------------------------------------------------------------------
# Core compatibility target (info.yml core_version_requirement) reasoning
# ---------------------------------------------------------------------------
# drupilot policy: a port to Drupal 11 has a PHP floor equal to the resolved
# DRUPILOT_PHP_TARGET (>= 8.3). Drupal 10 itself allows PHP 8.1, so KEEPING D10
# (`^10 || ^11`) must ALSO declare composer `require.php: ">=<target>"` —
# otherwise a D10 + PHP<target site installs the module and then fatals at
# runtime. `^11` alone needs no require.php (core enforces its own minimum).
#
# strategy_decide <subject> [target_major] [phase] [bc_override] -> the core
# target DECISION for a port to Drupal T (default 11), as one JSON record:
#   {target, php_target, current, floor_strategy, detected_floor,
#    has_composer, strategy_input, legacy_note, had_prev, current_has_target,
#    bc_break, branch (keep-current|keep-d10|d11-only, the 0.9 names),
#    resolved (the 0.9 name), resolved_v1 (keep-current|keep-previous|
#    target-only), prev_decl_floor, api_floor, api_attr, core_floor,
#    d10_dropped, target_compatible (true|false|null), req, composer,
#    require_php, effective_floor, d10_support, kc_raised, kc_decl_floor,
#    req_prev, kc_dropped, current_has_eol}
# recommend_core_target renders core-strategy.sh's 0.9 JSON from it (T = 11,
# byte for byte), and scripts/analysis/upgrade-path.sh builds the plan's range
# from it (any T). For T the ranges come from config/targets/<T>.json
# .default_ranges (keep-previous / target-only: '^10 || ^11' / '^11' for 11),
# the "older major" signals are the majors 8..T-1, and the PHP floor never goes
# below the php_min of the kept previous-major minor (8.1 for every 10.x). It
# never asserts anything: upgrade-path.sh checks the plan.
strategy_decide() {
  local subject="${1:-$PWD}" t="${2:-11}" phase="${3:-port}" bc_override="${4:-auto}"
  have_cmd jq || { printf '{}\n'; return 1; }
  local prev=$((t - 1)) pre_re kp_range to_range default_floor prev_php_min
  pre_re="$(seq 8 "$prev" | tr '\n' '|' | sed 's/|$//')"
  kp_range="$(target_get "$t" '.default_ranges["keep-previous"]')"
  to_range="$(target_get "$t" '.default_ranges["target-only"]')"
  [[ -n "$kp_range" ]] || kp_range="^$prev || ^$t"
  [[ -n "$to_range" ]] || to_range="^$t"
  default_floor="$(core_floor_from_requirement "$kp_range")"
  [[ -n "$default_floor" ]] || default_floor="$prev.0"

  local php_target current_req
  php_target="$(resolve_php_target)"
  current_req="$(subject_core_requirement "$subject" 2>/dev/null || true)"
  current_req="$(trim "$current_req")"

  local floor_strategy detected_floor has_composer="false"
  floor_strategy="$(config_get DRUPILOT_REQUIRE_PHP_FLOOR detect)"; floor_strategy="$(lc "$floor_strategy")"
  case "$floor_strategy" in target|detect) : ;; *) floor_strategy="detect";; esac
  detected_floor="$(trim "${DRUPILOT_DETECTED_PHP_FLOOR:-}")"
  [[ -f "$subject/composer.json" ]] && has_composer="true"

  # --- strategy resolution (auto default; KEEP_D10 legacy override) --------
  local strat keep_override legacy_note=""
  strat="$(config_get DRUPILOT_CORE_TARGET_STRATEGY auto)"; strat="$(lc "$strat")"
  case "$strat" in
    target-only) strat="d11-only";;
    keep-previous) strat="keep-d10";;
  esac
  case "$strat" in d11-only|keep-d10|auto) : ;; *) strat="auto";; esac
  keep_override="$(config_get DRUPILOT_KEEP_D10 "")"
  if [[ "$strat" == "auto" && -n "$keep_override" ]]; then
    case "$(lc "$keep_override")" in
      1|true|yes|on)  strat="keep-d10"; legacy_note="DRUPILOT_KEEP_D10 legacy override";;
      0|false|no|off) strat="d11-only"; legacy_note="DRUPILOT_KEEP_D10 legacy override";;
    esac
  fi

  # --- current support signals --------------------------------------------
  local had_pre11=0 current_has_11=0
  if [[ -n "$current_req" ]] && printf '%s' "$current_req" | grep -qE "(^|[^0-9])($pre_re)([^0-9]|\$)"; then had_pre11=1; fi
  if [[ -n "$current_req" ]] && printf '%s' "$current_req" | grep -qE "(^|[^0-9])$t([^0-9]|\$)"; then current_has_11=1; fi

  # --- BC-break detection (drives the SemVer major bump) ------------------
  local bc_break=0
  [[ "$phase" == "refactor" ]] && bc_break=1
  case "$(lc "$bc_override")" in
    yes|true|1) bc_break=1;;
    no|false|0) bc_break=0;;
  esac

  # --- resolve `auto` into a concrete strategy ----------------------------
  local resolved
  if [[ "$strat" == "auto" ]]; then
    if [[ "$bc_break" == "1" ]]; then
      resolved="d11-only"
    elif [[ "$had_pre11" == "1" || -z "$current_req" ]]; then
      resolved="keep-d10"           # widest BC-preserving set
    else
      resolved="d11-only"           # already T-only; nothing older to keep
    fi
  else
    resolved="$strat"
  fi
  # Already T-compatible with no BC break, and the strategy left on 'auto':
  # keep the existing declaration verbatim (keep-current, CC-36).
  local keep_current=0
  if [[ "$strat" == "auto" && "$current_has_11" == "1" && "$bc_break" == "0" && -n "$current_req" ]]; then
    keep_current=1; resolved="keep-current"
  fi

  # --- core minor floor ----------------------------------------------------
  # Never lower a declared previous-major minor floor ('^10.3' stays
  # '^10.3 || ^11'), never below the target's default keep-previous floor, and
  # never below the minor shipping a plugin attribute class the code uses.
  local d10_decl_floor="" api_floor="" api_attr="" core_floor="$default_floor" _af d10_dropped=0
  d10_decl_floor="$(core_verify_legs "$current_req" | awk -F. -v p="$prev" '$1 == p { print ($2 == "" ? p ".0" : $0); exit }')"
  if [[ -n "$d10_decl_floor" ]] && version_ge "$d10_decl_floor" "$default_floor"; then core_floor="$d10_decl_floor"; fi
  _af="$(subject_attribute_floor "$subject")"
  if [[ -n "$_af" ]]; then
    api_floor="${_af%%$'\t'*}"; api_attr="${_af#*$'\t'}"
    version_ge "$core_floor" "$api_floor" || core_floor="$api_floor"
  fi
  if [[ "$keep_current" == "0" && "$resolved" == "keep-d10" && "${core_floor%%.*}" -ge "$t" ]]; then
    resolved="d11-only"
    legacy_note="the code uses $api_attr, which exists only from core $api_floor"
    d10_dropped=1
  fi
  # The previous major's own PHP minimum (8.1 for every Drupal 10 minor).
  prev_php_min="$(target_get "$prev" ".minors[\"${core_floor}\"].php_min")"
  [[ -n "$prev_php_min" ]] || prev_php_min="$(target_get "$prev" ".minors[\"$prev.0\"].php_min")"
  [[ -n "$prev_php_min" ]] || prev_php_min="8.1"

  # --- target compatibility of the detected floor -------------------------
  local target_compat="null"
  if [[ -n "$detected_floor" ]]; then
    if version_ge "$php_target" "$detected_floor"; then target_compat="true"; else target_compat="false"; fi
  fi

  # --- requirement + composer constraint + require.php ----------------------
  local branch req composer require_php="" effective_floor="" d10_support="n/a"
  local kc_raised=0 kc_decl_floor="" req_pre11=0 kc_dropped=0 current_has_eol=0 f
  if [[ "$keep_current" == "1" ]]; then
    branch="keep-current"
    req="$current_req"; composer="$current_req"
    kc_decl_floor="$(core_floor_from_requirement "$current_req")"
    if [[ -n "$api_floor" && -n "$kc_decl_floor" ]] && ! version_ge "$kc_decl_floor" "$api_floor"; then
      req="$(core_requirement_raise_floor "$current_req" "$api_floor")"; composer="$req"; kc_raised=1
    fi
    if printf '%s' "$req" | grep -qE "(^|[^0-9])($pre_re)([^0-9]|\$)"; then req_pre11=1; fi
    if [[ "$had_pre11" == "1" && "$req_pre11" == "0" ]]; then resolved="d11-only"; kc_dropped=1; fi
    if [[ "$req_pre11" == "1" ]]; then
      require_php=">=$php_target"
      if [[ "$floor_strategy" == "detect" && -n "$detected_floor" ]]; then
        f="$detected_floor"
        version_ge "$f" "$prev_php_min" || f="$prev_php_min"
        version_ge "$php_target" "$f" || f="$php_target"
        effective_floor="$f"; require_php=">=$f"
      fi
      d10_support="declared-not-verified"
    fi
    if printf '%s' "$current_req" | grep -qE '(^|[^0-9])(8|9)([^0-9]|$)'; then current_has_eol=1; fi
  elif [[ "$resolved" == "keep-d10" ]]; then
    branch="keep-d10"
    req="$kp_range"
    [[ "$core_floor" != "$default_floor" ]] && req="^$core_floor || ^$t"
    composer="$req"
    require_php=">=$php_target"
    if [[ "$floor_strategy" == "detect" && -n "$detected_floor" ]]; then
      f="$detected_floor"
      version_ge "$f" "$prev_php_min" || f="$prev_php_min"
      version_ge "$php_target" "$f" || f="$php_target"
      effective_floor="$f"
      require_php=">=$f"
    fi
    d10_support="declared-not-verified"
  else
    branch="d11-only"
    req="$to_range"
    if [[ "${core_floor%%.*}" == "$t" && "$core_floor" != "$t.0" ]]; then req="^$core_floor"; fi
    composer="$req"
  fi

  local v1
  case "$resolved" in keep-current) v1="keep-current";; keep-d10) v1="keep-previous";; *) v1="target-only";; esac
  jq -n -c \
    --argjson t "$t" --arg php_target "$php_target" --arg current "$current_req" \
    --arg floor_strategy "$floor_strategy" --arg detected_floor "$detected_floor" \
    --argjson has_composer "$has_composer" --arg strat "$strat" --arg legacy_note "$legacy_note" \
    --argjson had_prev "$had_pre11" --argjson has_t "$current_has_11" --argjson bc_break "$bc_break" \
    --arg branch "$branch" --arg resolved "$resolved" --arg v1 "$v1" \
    --arg prev_decl_floor "$d10_decl_floor" --arg api_floor "$api_floor" --arg api_attr "$api_attr" \
    --arg core_floor "$core_floor" --argjson d10_dropped "$d10_dropped" \
    --argjson target_compat "$target_compat" --arg req "$req" --arg composer "$composer" \
    --arg require_php "$require_php" --arg effective_floor "$effective_floor" --arg d10_support "$d10_support" \
    --argjson kc_raised "$kc_raised" --arg kc_decl_floor "$kc_decl_floor" --argjson req_prev "$req_pre11" \
    --argjson kc_dropped "$kc_dropped" --argjson eol "$current_has_eol" \
    '{target: $t, php_target: $php_target, current: $current, floor_strategy: $floor_strategy,
      detected_floor: $detected_floor, has_composer: $has_composer, strategy_input: $strat,
      legacy_note: $legacy_note, had_prev: ($had_prev == 1), current_has_target: ($has_t == 1),
      bc_break: ($bc_break == 1), branch: $branch, resolved: $resolved, resolved_v1: $v1,
      prev_decl_floor: $prev_decl_floor, api_floor: $api_floor, api_attr: $api_attr,
      core_floor: $core_floor, d10_dropped: ($d10_dropped == 1), target_compatible: $target_compat,
      req: $req, composer: $composer, require_php: $require_php, effective_floor: $effective_floor,
      d10_support: $d10_support, kc_raised: ($kc_raised == 1), kc_decl_floor: $kc_decl_floor,
      req_prev: ($req_prev == 1), kc_dropped: ($kc_dropped == 1), current_has_eol: ($eol == 1)}'
}

# recommend_core_target <subject> [phase] [bc_override] -> recommendation JSON:
#   { strategy, phase, current_core_version_requirement,
#     recommended_core_version_requirement, composer_core_constraint,
#     require_php (string|null), version_bump (major|minor|patch),
#     bc_break (bool), php_target, d10_support, verify_cores:[...],
#     rationale:[...], warnings:[...] }
#   verify_cores: the core legs scripts/analysis/verify-core-matrix.sh checks for
#   the recommended requirement (core_matrix_legs), e.g. ["10.0","10","11"].
#   The recommended requirement never lowers a declared Drupal 10 minor floor
#   ('^10.3' -> '^10.3 || ^11') and never goes below the floor of a plugin
#   attribute class the code uses (subject_attribute_floor; one that exists only
#   in Drupal 11 turns keep-d10 into d11-only, e.g. '^11.1').
#   phase: port | refactor (default port). bc_override: auto | yes | no.
recommend_core_target() {
  local subject="${1:-$PWD}" phase="${2:-port}" bc_override="${3:-auto}"
  have_cmd jq || { printf '{}\n'; return 1; }
  local rec
  rec="$(strategy_decide "$subject" 11 "$phase" "$bc_override")" || { printf '{}\n'; return 1; }
  # The decision, field by field (one jq call; @sh keeps every value literal).
  local php_target current_req floor_strategy detected_floor has_composer legacy_note
  local branch resolved d10_decl_floor api_floor api_attr core_floor d10_dropped target_compat
  local req composer require_php effective_floor d10_support kc_raised kc_decl_floor
  local req_pre11 kc_dropped current_has_eol current_has_11 bc_break
  eval "$(printf '%s' "$rec" | jq -r '@sh "php_target=\(.php_target) current_req=\(.current)
    floor_strategy=\(.floor_strategy) detected_floor=\(.detected_floor) has_composer=\(.has_composer)
    legacy_note=\(.legacy_note) branch=\(.branch) resolved=\(.resolved)
    d10_decl_floor=\(.prev_decl_floor) api_floor=\(.api_floor) api_attr=\(.api_attr)
    core_floor=\(.core_floor) d10_dropped=\(.d10_dropped) target_compat=\(.target_compatible)
    req=\(.req) composer=\(.composer) require_php=\(.require_php)
    effective_floor=\(.effective_floor) d10_support=\(.d10_support) kc_raised=\(.kc_raised)
    kc_decl_floor=\(.kc_decl_floor) req_pre11=\(.req_prev) kc_dropped=\(.kc_dropped)
    current_has_eol=\(.current_has_eol) current_has_11=\(.current_has_target) bc_break=\(.bc_break)"')"
  local -a rationale=() warnings=() suggested=()

  if [[ "$target_compat" == "false" ]]; then
    warnings+=("The code uses PHP $detected_floor-only constructs but DRUPILOT_PHP_TARGET is $php_target — it will fatal on a Drupal 11 site running PHP $php_target. Raise DRUPILOT_PHP_TARGET to $detected_floor (confirm it is supported on the target Drupal 11 branch) or remove the construct.")
  fi

  if [[ "$branch" == "keep-current" ]]; then
    rationale+=("The module already declares a Drupal 11-compatible requirement ('$current_req'); keeping it unchanged (minimal change). Use the core-target choice to narrow it if you want.")
    if [[ "$kc_raised" == "true" ]]; then
      rationale+=("The code uses $api_attr, which exists only from core $api_floor: the declared floor $kc_decl_floor is raised ('$current_req' -> '$req').")
    fi
    if [[ "$kc_dropped" == "true" ]]; then
      warnings+=("Drupal 10 cannot be kept: the code uses $api_attr, which exists only from core $api_floor (PHPStan reports the unknown class on Drupal 10). Keep the annotation instead of the attribute to stay on '$current_req'.")
    fi
    if [[ "$req_pre11" == "true" ]]; then
      warnings+=("The kept requirement still allows Drupal 10 ('$req'); its Drupal 10 compatibility is DECLARED, not verified — run verify-core-matrix.sh (static check on a Drupal 10 core) and install/test on Drupal 10 before relying on it.")
    fi
    if [[ "$current_has_eol" == "true" ]]; then
      suggested+=("The requirement still lists EOL Drupal 8/9 ('$current_req'); narrow it (e.g. to '^10 || ^11' or '^11') via the core-target choice if you no longer support them.")
    fi
  elif [[ "$branch" == "keep-d10" ]]; then
    rationale+=("Strategy: keep-d10 ('$req')${legacy_note:+ ($legacy_note)}.")
    if [[ "$core_floor" != "10.0" ]]; then
      if [[ -n "$api_floor" && "$core_floor" == "$api_floor" && "$api_floor" != "$d10_decl_floor" ]]; then
        rationale+=("Drupal 10 floor $core_floor: the code uses $api_attr, which exists only from core $api_floor.")
      else
        rationale+=("Drupal 10 floor $core_floor: the declared minor floor ('$current_req') is kept, never lowered.")
      fi
    fi
    if [[ "$floor_strategy" == "detect" && -n "$detected_floor" ]]; then
      if [[ "$effective_floor" != "$php_target" ]]; then
        rationale+=("Detected PHP floor is $effective_floor (heuristic scan), below the target $php_target — require.php is widened to \">=$effective_floor\" for genuine Drupal 10 (PHP $effective_floor) support.")
        warnings+=("require.php was lowered to \">=$effective_floor\" from a best-effort syntactic scan. CONFIRM with PHPCompatibility (testVersion $effective_floor-) before release: a missed newer construct would let a Drupal 10 + PHP<$php_target site install and then fatal at runtime. Set DRUPILOT_REQUIRE_PHP_FLOOR=target to keep the conservative \">=$php_target\".")
      else
        rationale+=("PHP floor is the target ($php_target): the scan found PHP 8.2/8.3-only constructs (or the detected floor equals the target).")
      fi
    else
      rationale+=("PHP floor is the target ($php_target); keeping Drupal 10 declares composer require.php \">=$php_target\". (Set DRUPILOT_REQUIRE_PHP_FLOOR=detect to derive a narrower, code-based floor.)")
    fi
    warnings+=("Drupal 10's own minimum is PHP 8.1, but this port's floor is ${effective_floor:-$php_target}. require.php \"$require_php\" blocks D10 sites below that floor at install time (composer) rather than fataling at runtime. If you do not need the D10 transition window, drop to '^11'.")
    if [[ "$has_composer" != "true" ]]; then
      warnings+=("This module has no composer.json, so require.php cannot be declared anywhere — an info.yml-only '^10 || ^11' module has NO way to enforce the PHP floor, and a D10 + low-PHP site would install and fatal. Either add a composer.json with \"require\": { \"php\": \"$require_php\" }, or declare '^11' only.")
      suggested+=("Add a composer.json declaring \"require\": { \"php\": \"$require_php\" } (or drop to '^11'), so the PHP floor of the '^10 || ^11' declaration is actually enforced.")
    fi
    local digests_note=""
    if config_bool DRUPILOT_USE_DIGESTS_RULES 1; then
      digests_note=" The AI digests / ad-hoc Rector layer may introduce replacements newer than Drupal 10.0, so a raised minor (e.g. '^10.3 || ^11') is more likely — check it."
    fi
    warnings+=("Drupal 10 compatibility is DECLARED, not verified. drupal-rector's standard replacements are usually available across all of Drupal 10 (deprecation contract), but this was not checked here. If the port uses an API added in a later 10.x minor, set core_version_requirement to e.g. '^10.3 || ^11'; if it uses an API absent from Drupal 10, drop to '^11'.$digests_note")
    suggested+=("Verify Drupal 10 compatibility before relying on the '^10 || ^11' declaration: verify-core-matrix.sh runs PHPStan + php -l against a Drupal 10 core (static); install on a Drupal 10 site or run the test suite against Drupal 10 for runtime proof.")
  else
    rationale+=("Strategy: d11-only ('$req')${legacy_note:+ ($legacy_note)}.")
    if [[ "$d10_dropped" == "true" ]]; then
      warnings+=("Drupal 10 cannot be kept: the code uses $api_attr, which exists only from core $api_floor (PHPStan reports the unknown class on Drupal 10). Keep the annotation instead of the attribute to stay on '^10 || ^11'.")
    fi
    rationale+=("Drupal 11 enforces PHP $php_target itself, so no composer require.php is needed.")
  fi

  # --- version bump (SemVer for Drupal contrib) ---------------------------
  # drops_major: the recommended requirement no longer supports a core major the
  # current one did (e.g. '^8 || ^9' -> '^10 || ^11' drops 8 AND 9). Dropping a
  # previously-supported core major is backwards-incompatible -> MAJOR,
  # regardless of the strategy.
  local drops_major=0
  if [[ -n "$current_req" ]]; then
    local _rec_majors _m
    _rec_majors="$(printf '%s' "$req" | grep -oE '[0-9]+(\.[0-9]+)*' | sed -E 's/\..*//' | sort -u)"
    for _m in $(printf '%s' "$current_req" | grep -oE '[0-9]+(\.[0-9]+)*' | sed -E 's/\..*//' | sort -u); do
      printf '%s\n' "$_rec_majors" | grep -qx "$_m" || drops_major=1
    done
  fi
  local version_bump
  if [[ "$bc_break" == "true" || "$drops_major" == "1" ]]; then
    version_bump="major"
    [[ "$drops_major" == "1" ]] && rationale+=("Dropping a previously-supported Drupal core major (current '${current_req:-none}' -> '$req') is backwards-incompatible -> MAJOR (cut a new N+1.0.x branch).")
    [[ "$bc_break" == "true" ]] && rationale+=("Phase 2 refactor / asserted public-API BC break -> MAJOR.")
  elif [[ "$current_has_11" == "false" ]]; then
    version_bump="minor"
    rationale+=("Adding Drupal 11 support without dropping a supported core major -> MINOR.")
  else
    version_bump="patch"
    rationale+=("No core-major change and no API break -> PATCH.")
  fi

  # --- core legs to verify (verify-core-matrix.sh --cores auto) -------------
  local verify_cores_json
  verify_cores_json="$(core_matrix_legs "$req" | jq -R . | jq -sc 'map(select(length > 0))' 2>/dev/null || printf '[]')"
  [[ -n "$verify_cores_json" ]] || verify_cores_json='[]'

  # --- emit JSON ----------------------------------------------------------
  jq -n \
    --arg strategy "$resolved" \
    --arg phase "$phase" \
    --arg current "$current_req" \
    --arg req "$req" \
    --arg composer "$composer" \
    --arg require_php "$require_php" \
    --arg version_bump "$version_bump" \
    --arg php_target "$php_target" \
    --arg php_floor_strategy "$floor_strategy" \
    --arg php_floor_detected "$detected_floor" \
    --arg php_floor_effective "$effective_floor" \
    --argjson php_floor_target_compatible "$target_compat" \
    --arg d10_support "$d10_support" \
    --argjson verify_cores "$verify_cores_json" \
    --argjson has_composer_json "$has_composer" \
    --argjson bc_break "$bc_break" \
    --argjson rationale "$(arr_to_json ${rationale[@]+"${rationale[@]}"})" \
    --argjson warnings "$(arr_to_json ${warnings[@]+"${warnings[@]}"})" \
    --argjson suggested "$(arr_to_json ${suggested[@]+"${suggested[@]}"})" \
    '{
      strategy: $strategy,
      phase: $phase,
      current_core_version_requirement: ($current | select(. != "") // null),
      recommended_core_version_requirement: $req,
      composer_core_constraint: $composer,
      require_php: ($require_php | select(. != "") // null),
      version_bump: $version_bump,
      bc_break: $bc_break,
      php_target: $php_target,
      php_floor_strategy: $php_floor_strategy,
      php_floor_detected: ($php_floor_detected | select(. != "") // null),
      php_floor_effective: ($php_floor_effective | select(. != "") // null),
      php_floor_target_compatible: $php_floor_target_compatible,
      has_composer_json: $has_composer_json,
      d10_support: $d10_support,
      verify_cores: $verify_cores,
      rationale: $rationale,
      warnings: $warnings,
      suggested_remaining_tasks: $suggested
    }'
}
