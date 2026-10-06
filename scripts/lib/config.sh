#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/config.sh
# Configuration (env > .drupilot.json > config/defaults.json > caller
# default), the alias layer of config/migrations.json, prefs, and the PHP /
# Drupal target resolution.
#
# Part of the shared library: scripts/lib/common.sh sources it with the other
# domain libs (never source it alone); see common.sh for the conventions.
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration (env override > .drupilot.json project prefs > defaults.json > caller default)
# ---------------------------------------------------------------------------
# drupilot_prefs_file -> path to the per-project preference file (.drupilot.json)
# at the Drupal ROOT, or non-zero if no root is resolvable. This is the
# persistence tier for in-flow tabbed choices (core target, PHP target, refactor
# scope, contrib mode...): config_get reads it BETWEEN the env override and
# defaults.json (env still wins), and prefs_set writes it. It lives in the
# project tree (gitignored via ensure-gitignore.sh), so it is implicitly keyed by
# the project the developer is working in. Scripts that already know the Drupal
# root can export DRUPILOT_PROJECT_DIR; otherwise it is detected from $PWD.
drupilot_prefs_file() {
  local root="${DRUPILOT_PROJECT_DIR:-}"
  [[ -z "$root" ]] && root="$(find_drupal_root 2>/dev/null || true)"
  [[ -n "$root" ]] || return 1
  printf '%s/.drupilot.json' "$root"
}

# config_get <KEY> [default]
config_get() {
  _config_resolve "$1" "${2:-}" 1
}

# _config_resolve <KEY> <default> <aliases 0|1> [explicit 0|1] -> config_get's
# resolution: env, then (aliases=1) an env alias of KEY, then .drupilot.json,
# then a .drupilot.json alias of KEY, then config/defaults.json (skipped with
# explicit=1), then <default>. So the environment still wins over every file
# tier, aliased or not.
_config_resolve() {
  local key="$1" def="${2:-}" aliases="${3:-1}" explicit="${4:-0}"
  local envval="${!key:-}"
  if [[ -n "$envval" ]]; then printf '%s' "$envval"; return 0; fi
  # The rows are read (one jq) only for a key some row renames.
  if [[ "$aliases" == "1" && "$_DRUPILOT_ALIAS_NEW" == *"|$key|"* ]]; then _config_alias_rows; fi
  if [[ "$aliases" == "1" && "$_DRUPILOT_ALIAS_N" -gt 0 ]] && _config_alias env "$key"; then
    printf '%s' "$_DRUPILOT_ALIAS_VALUE"; return 0
  fi
  # Project preference tier (.drupilot.json at the Drupal root): remembered
  # tabbed-choice answers, read between the env override and defaults.json.
  # The jq filter keeps a JSON false/0 (jq's `//` would treat false as missing
  # and fall through to the defaults), stringified as the env tier would be.
  local jqf='if type == "object" and has($k) and .[$k] != null then .[$k] | tostring else empty end'
  local pf; pf="$(drupilot_prefs_file 2>/dev/null || true)"
  if [[ -n "$pf" && -r "$pf" ]] && have_cmd jq; then
    local pv; pv="$(jq -r --arg k "$key" "$jqf" "$pf" 2>/dev/null)"
    if [[ -n "$pv" && "$pv" != "null" ]]; then printf '%s' "$pv"; return 0; fi
  fi
  if [[ "$aliases" == "1" && "$_DRUPILOT_ALIAS_N" -gt 0 ]] && _config_alias prefs "$key"; then
    printf '%s' "$_DRUPILOT_ALIAS_VALUE"; return 0
  fi
  local file; file="$(drupilot_config_file)"
  if [[ "$explicit" != "1" && -r "$file" ]] && have_cmd jq; then
    local v; v="$(jq -r --arg k "$key" "$jqf" "$file" 2>/dev/null)"
    if [[ -n "$v" && "$v" != "null" ]]; then printf '%s' "$v"; return 0; fi
  fi
  printf '%s' "$def"
}

# --- Alias layer (config/migrations.json) -------------------------------------
# A renamed key keeps working for all of 1.x: config/migrations.json lists
#   env_aliases: [{old, new, since, remove_in, note, when?}]
# where `old`/`new` are key names, or KEY=value to alias one value only (an
# `old` of DRUPILOT_X=true applies only while DRUPILOT_X is "true"; a `new` of
# DRUPILOT_Y=v resolves DRUPILOT_Y to v). `when` ({key, equals}) applies the
# row only while <key>, resolved WITHOUT aliases (env, .drupilot.json,
# defaults), equals that value (compared as text, case-insensitively, so
# `equals: false` matches a JSON false) — e.g. a legacy boolean honored only
# while a strategy is still at its default. value_aliases and removed are read
# by their owners and by the `version` gate, not here.
# Warnings: a row in use is reported once per process. When this file is
# sourced, a fork-free scan records the old and new key names of the rows
# (_config_alias_scan); the rows themselves are read with jq only when a key
# some row renames is looked up, or when an old name is in use (environment,
# or the .drupilot.json found from the working directory): those are warned
# about then, in the main shell, so the many `$(config_get ...)` subshells
# inherit the mark; a row first met later (another project root) is warned
# about where it is met. A hook, which looks up no renamed key, never forks.
_DRUPILOT_ALIAS_N=0
_DRUPILOT_ALIAS_VALUE=""
_DRUPILOT_ALIAS_WARNED="|"
_DRUPILOT_ALIAS_PENDING=0
_DRUPILOT_ALIAS_OLD="|"
_DRUPILOT_ALIAS_NEW="|"

# _config_alias_scan -> without forking, the key names on the old and new side
# of the env_aliases rows (|KEY|... in _DRUPILOT_ALIAS_OLD and
# _DRUPILOT_ALIAS_NEW), and _DRUPILOT_ALIAS_PENDING=1 when there are rows to
# read. Only the part of the file before value_aliases is scanned.
_config_alias_scan() {
  local f line side pat rest k in=0
  local -a lines=()
  f="$(plugin_root)/config/migrations.json"
  [[ -r "$f" ]] || return 0
  # One read into an array of lines, then short per-line matches: a pattern
  # removal over the whole file would cost milliseconds.
  IFS=$'\n' read -r -d '' -a lines < "$f" || true
  for line in ${lines[@]+"${lines[@]}"}; do
    case "$line" in *'"env_aliases"'*) in=1;; esac
    [[ "$in" == "1" ]] || continue
    case "$line" in *'"old"'*|*'"new"'*) ;; *'"value_aliases"'*|*'"removed"'*) break;; *) continue;; esac
    for side in old new; do
      for pat in "\"$side\": \"" "\"$side\":\""; do
        rest="$line"
        while [[ "$rest" == *"$pat"* ]]; do
          rest="${rest#*"$pat"}"
          k="${rest%%[\"=]*}"
          case "$k" in ""|[!A-Za-z_]*|*[!A-Za-z0-9_]*) continue;; esac
          if [[ "$side" == "old" ]]; then _DRUPILOT_ALIAS_OLD="${_DRUPILOT_ALIAS_OLD}${k}|"
          else _DRUPILOT_ALIAS_NEW="${_DRUPILOT_ALIAS_NEW}${k}|"; fi
        done
      done
    done
    case "$line" in *'"value_aliases"'*|*'"removed"'*) break;; esac
  done
  if [[ "$_DRUPILOT_ALIAS_NEW" != "|" ]]; then _DRUPILOT_ALIAS_PENDING=1; fi
  return 0
}

# _config_alias_rows -> the rows read (_config_alias_load), once per process.
_config_alias_rows() {
  [[ "$_DRUPILOT_ALIAS_PENDING" == "1" ]] || return 0
  _DRUPILOT_ALIAS_PENDING=0
  _config_alias_load
}

# _config_alias_load -> the env_aliases rows in parallel arrays (_DA_NEW,
# _DA_NV, _DA_OLD, _DA_OV, _DA_WK, _DA_WE, _DA_SINCE, _DA_RIN) and their count
# in _DRUPILOT_ALIAS_N. Without a row (the common case) it reads the file
# without forking jq. A row whose old, new or when key is not a valid variable
# name is ignored (the version gate reports it).
_config_alias_load() {
  local f content="" a b c d e g h k z sep re='^[A-Za-z_][A-Za-z0-9_]*$'
  _DRUPILOT_ALIAS_N=0
  f="$(plugin_root)/config/migrations.json"
  [[ -r "$f" ]] || return 0
  IFS= read -r -d '' content < "$f" || true
  [[ "$content" == *'"old"'* ]] || return 0
  have_cmd jq || return 0
  sep="$(printf '\037')"
  # z takes the "." sentinel that keeps a trailing empty field from being dropped.
  # shellcheck disable=SC2034  # z is only the sentinel
  while IFS="$sep" read -r a b c d e g h k z; do
    [[ "$a" =~ $re && "$c" =~ $re ]] || continue
    [[ -z "$e" || "$e" =~ $re ]] || continue
    _DA_NEW[_DRUPILOT_ALIAS_N]="$a"; _DA_NV[_DRUPILOT_ALIAS_N]="$b"
    _DA_OLD[_DRUPILOT_ALIAS_N]="$c"; _DA_OV[_DRUPILOT_ALIAS_N]="$d"
    _DA_WK[_DRUPILOT_ALIAS_N]="$e"; _DA_WE[_DRUPILOT_ALIAS_N]="$g"
    _DA_SINCE[_DRUPILOT_ALIAS_N]="$h"; _DA_RIN[_DRUPILOT_ALIAS_N]="$k"
    _DRUPILOT_ALIAS_N=$((_DRUPILOT_ALIAS_N + 1))
  done < <(jq -r '.env_aliases[]? | select(type == "object" and (.old | type) == "string" and (.new | type) == "string")
             | (.new | split("=")) as $n | (.old | split("=")) as $o
             | [$n[0], ($n[1:] | join("=")), $o[0], ($o[1:] | join("=")),
                (if (.when | type) == "object" then (.when.key // "" | tostring) else "" end),
                (if (.when | type) == "object" and (.when | has("equals")) then (.when.equals | tostring) else "" end),
                (.since // "" | tostring), (.remove_in // "" | tostring), "."]
             | join("\u001f")' "$f" 2>/dev/null || true)
  return 0
}

# _config_alias_applies <row> <env|prefs> [VALUE] -> 0 and _DRUPILOT_ALIAS_VALUE
# when the row's old name is set in that tier (VALUE: its value there, when
# the caller already read it) with the row's value, if it names one, and the
# row's `when` holds; 1 otherwise. Never warns. The comparisons fork nothing
# (_ci_eq), and `when` is resolved once per lookup (_config_alias_when).
_config_alias_applies() {
  local i="$1" tier="$2" ok ov got="${3-}"
  ok="${_DA_OLD[i]}"; ov="${_DA_OV[i]}"
  [[ "$#" -ge 3 ]] || got="$(_config_alias_tier_value "$tier" "$ok")"
  [[ -n "$got" ]] || return 1
  if [[ -n "$ov" ]] && ! _ci_eq "$got" "$ov"; then return 1; fi
  if [[ -n "${_DA_WK[i]}" ]] && ! _config_alias_when "$i"; then return 1; fi
  _DRUPILOT_ALIAS_VALUE="${_DA_NV[i]:-$got}"
  return 0
}

# _config_alias_tier_value <env|prefs> KEY -> KEY's value in that tier: the
# environment, or the .drupilot.json found from DRUPILOT_PROJECT_DIR / $PWD.
_config_alias_tier_value() {
  local pf
  if [[ "$1" == "env" ]]; then printf '%s' "${!2:-}"; return 0; fi
  pf="$(drupilot_prefs_file 2>/dev/null || true)"
  [[ -n "$pf" && -r "$pf" ]] && have_cmd jq || return 0
  jq -r --arg k "$2" 'if type == "object" and has($k) and .[$k] != null then .[$k] | tostring else empty end' "$pf" 2>/dev/null || true
  return 0
}

# _config_alias_when <row> -> 0 when the row's `when` key, resolved without
# aliases, equals its value (case-insensitively). The last key's value is
# kept for the rest of the lookup (_DA_WHEN_K / _DA_WHEN_V; _config_alias and
# the prewarn reset it), so the eight KEEP_D10 rows resolve it once.
_DA_WHEN_K=""
_DA_WHEN_V=""
_config_alias_when() {
  local i="$1"
  if [[ "$_DA_WHEN_K" != "${_DA_WK[i]}" ]]; then
    _DA_WHEN_K="${_DA_WK[i]}"
    _DA_WHEN_V="$(_config_resolve "${_DA_WK[i]}" "" 0)"
  fi
  _ci_eq "$_DA_WHEN_V" "${_DA_WE[i]}"
}

# _ci_eq A B -> 0 when A and B are equal, ignoring case, without a fork
# (nocasematch, bash >= 3.1; restored as it was).
_ci_eq() {
  local r=1
  if shopt -q nocasematch; then
    [[ "$1" == "$2" ]] && r=0
  else
    shopt -s nocasematch
    [[ "$1" == "$2" ]] && r=0
    shopt -u nocasematch
  fi
  return "$r"
}

# _config_alias_warn <row> -> the deprecation warning, once per process.
_config_alias_warn() {
  local i="$1"
  case "$_DRUPILOT_ALIAS_WARNED" in *"|$i|"*) return 0;; esac
  _DRUPILOT_ALIAS_WARNED="$_DRUPILOT_ALIAS_WARNED$i|"
  log_warn "${_DA_OLD[i]}${_DA_OV[i]:+=${_DA_OV[i]}} is deprecated since ${_DA_SINCE[i]:-1.0.0} and will be removed in ${_DA_RIN[i]:-2.0.0}; use ${_DA_NEW[i]}${_DA_NV[i]:+=${_DA_NV[i]}}"
  return 0
}

# _config_alias <env|prefs> <KEY> -> 0 and _DRUPILOT_ALIAS_VALUE when a row
# aliasing KEY applies in that tier (warning about it once); 1 otherwise.
_config_alias() {
  local tier="$1" key="$2" i=0 lastk="" got=""
  _DA_WHEN_K=""
  while [[ "$i" -lt "$_DRUPILOT_ALIAS_N" ]]; do
    if [[ "${_DA_NEW[i]}" == "$key" ]]; then
      # Each old name is read once per lookup, whatever its number of rows.
      if [[ "${_DA_OLD[i]}" != "$lastk" ]]; then
        lastk="${_DA_OLD[i]}"; got="$(_config_alias_tier_value "$tier" "$lastk")"
      fi
      if _config_alias_applies "$i" "$tier" "$got"; then
        _config_alias_warn "$i"
        return 0
      fi
    fi
    i=$((i + 1))
  done
  return 1
}

# _config_alias_prewarn -> warn now, in the main shell, about every row
# already in use, so later $(config_get ...) subshells stay quiet about it.
# Cheap: the environment tier needs no fork; the .drupilot.json tier costs one
# lookup of the file and one jq listing its keys, and `when` is evaluated only
# for the rows that hit. Skipped in a hook, which discards its STDERR (and is
# latency-bound): a lookup there still resolves the alias, silently.
_config_alias_prewarn() {
  local i=0 pf keys k rest hit=0 pcontent=""
  [[ "$_DRUPILOT_ALIAS_OLD" != "|" ]] || return 0
  case "${0:-}" in */hooks/scripts/*) return 0;; esac
  # Fork-free first: is an old name set in the environment, else written in
  # the .drupilot.json? Only then are the rows read.
  rest="${_DRUPILOT_ALIAS_OLD#|}"
  while [[ -n "$rest" ]]; do
    k="${rest%%|*}"; rest="${rest#*|}"
    if [[ -n "${!k:-}" ]]; then hit=1; fi
  done
  if [[ "$hit" == "0" ]]; then
    pf="$(drupilot_prefs_file 2>/dev/null || true)"
    if [[ -n "$pf" && -r "$pf" ]]; then IFS= read -r -d '' pcontent < "$pf" || true; fi
    rest="${_DRUPILOT_ALIAS_OLD#|}"
    while [[ -n "$pcontent" && -n "$rest" ]]; do
      k="${rest%%|*}"; rest="${rest#*|}"
      if [[ "$pcontent" == *"\"$k\""* ]]; then hit=1; fi
    done
  fi
  [[ "$hit" == "1" ]] || return 0
  _config_alias_rows
  [[ "$_DRUPILOT_ALIAS_N" -gt 0 ]] || return 0
  _DA_WHEN_K=""
  while [[ "$i" -lt "$_DRUPILOT_ALIAS_N" ]]; do
    k="${_DA_OLD[i]}"
    if _config_alias_applies "$i" env "${!k:-}"; then _config_alias_warn "$i"; fi
    i=$((i + 1))
  done
  pf="$(drupilot_prefs_file 2>/dev/null || true)"
  [[ -n "$pf" && -r "$pf" ]] && have_cmd jq || return 0
  # A malformed .drupilot.json must not stop a `set -e` script while common.sh
  # is being sourced: no keys, no warning.
  keys="|$(jq -r 'if type == "object" then keys[] else empty end' "$pf" 2>/dev/null | tr '\n' '|' || true)"
  i=0
  rest=""
  while [[ "$i" -lt "$_DRUPILOT_ALIAS_N" ]]; do
    case "$keys" in
      *"|${_DA_OLD[i]}|"*)
        if [[ "${_DA_OLD[i]}" != "$rest" ]]; then rest="${_DA_OLD[i]}"; pcontent="$(_config_alias_tier_value prefs "$rest")"; fi
        if _config_alias_applies "$i" prefs "$pcontent"; then _config_alias_warn "$i"; fi;;
    esac
    i=$((i + 1))
  done
  return 0
}

# prefs_set <KEY> <value> -> persist a preference into .drupilot.json at the
# Drupal root (atomic temp-file + mv). Used to remember a tabbed-choice answer
# across runs. No-op (return 1) without jq or a resolvable root. The env var of
# the same name always still wins over what this writes.
prefs_set() {
  local key="$1" value="$2" f tmp
  have_cmd jq || return 1
  f="$(drupilot_prefs_file 2>/dev/null || true)"
  [[ -n "$f" ]] || return 1
  [[ -f "$f" ]] || printf '{}\n' > "$f" 2>/dev/null || return 1
  tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 1
  if jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$f" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp" 2>/dev/null || true; return 1
  fi
}

# config_enum <KEY> <default> <allowed...> -> resolve KEY via config_get and
# validate it against the allowed set. Echoes the value (STDOUT) when valid;
# logs a clean error and returns non-zero when it is out of the set, so preflight
# can reject a misconfigured enum up front instead of failing deep inside a tool.
config_enum() {
  local key="$1" def="$2"; shift 2
  local v; v="$(config_get "$key" "$def")"
  local a
  for a in "$@"; do [[ "$v" == "$a" ]] && { printf '%s' "$v"; return 0; }; done
  log_err "$key='$v' is invalid. Allowed: $*"
  return 1
}

# config_bool <KEY> [default 0/1] -> 0 (true) / 1 (false) as the return code
config_bool() {
  local v; v="$(config_get "$1" "")"
  if [[ -z "$v" ]]; then
    [[ "${2:-0}" == "1" ]] && return 0 || return 1
  fi
  case "$(lc "$v")" in
    1|true|yes|on) return 0;;
    *) return 1;;
  esac
}

# config_json <jq-filter> [default] -> read an arbitrary path from defaults.json
config_json() {
  local filter="$1" def="${2:-}"
  local file; file="$(drupilot_config_file)"
  if [[ -r "$file" ]] && have_cmd jq; then
    local v; v="$(jq -r "$filter // empty" "$file" 2>/dev/null)"
    if [[ -n "$v" && "$v" != "null" ]]; then printf '%s' "$v"; return 0; fi
  fi
  printf '%s' "$def"
}

# req_version <name> [default] -> requirements.<name> from defaults.json
req_version() { config_json ".requirements.${1}" "${2:-}"; }

# ---------------------------------------------------------------------------
# PHP / Drupal target resolution
# ---------------------------------------------------------------------------
resolve_php_target()    { config_get DRUPILOT_PHP_TARGET "8.3"; }
# resolve_drupal_target -> the core constraint of the test-bed's Drupal
# (DRUPILOT_DRUPAL_TARGET, default ^11). Without one set, an explicit
# DRUPILOT_TARGET_MAJOR gives ^T (X12).
resolve_drupal_target() {
  local v t
  v="$(config_get_explicit DRUPILOT_DRUPAL_TARGET)"
  if [[ -z "$v" ]]; then
    t="$(config_get_explicit DRUPILOT_TARGET_MAJOR)"
    if [[ "$t" =~ ^[1-9][0-9]*$ ]]; then v="^$t"; else v="$(config_get DRUPILOT_DRUPAL_TARGET "^11")"; fi
  fi
  printf '%s' "$v"
}

# drupal_target_major CONSTRAINT -> N when CONSTRAINT is a bare ^N (X12: it
# names the target major); nothing otherwise (another constraint is an
# explicit declared range).
drupal_target_major() {
  local c re='^\^([1-9][0-9]*)$'
  c="$(printf '%s' "${1:-}" | tr -d " \"'")"
  if [[ "$c" =~ $re ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
  return 0
}

# constraint_top_major CONSTRAINT -> the highest Drupal major a core
# constraint admits (constraint_majors), nothing when none: '^12' is 12,
# '>=11 <12' is 11, '>=10.3 <12' is 11, '^10.3 || ^11' is 11.
constraint_top_major() {
  constraint_majors "${1:-}" | sort -n | sed -n '$p'
}

# constraint_admits_major CONSTRAINT N -> 0 when a core constraint admits
# Drupal major N: an `||` alternative bounded above whose majors include N, an
# open-ended `>=X` / `>X` / `*` with X <= N, or a `^X` / `~X` / bare X with
# X == N; 1 otherwise. '>=9.5' and '^10 || ^11' admit 11; '^10' and
# '>=10 <11' do not. A space after an operator is allowed ('>= 9.5'), a
# hyphen range 'A - B' is read as '>=A <=B', and the highest lower bound of an
# alternative wins ('>=9 >=12' does not admit 11).
constraint_admits_major() {
  local n="${2:-}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${1:-}" | tr -d "\"'" | tr '|' '\n' \
    | sed -E -e 's/([<>=!~^])[[:space:]]+/\1/g' -e 's/([0-9][0-9.*x]*)[[:space:]]+-[[:space:]]+([0-9][0-9.*x]*)/>=\1 <=\2/g' \
    | awk -v n="$n" '
    { k = split($0, parts, /[[:space:],]+/); lo = -1; hi = -1; open = 0
      for (i = 1; i <= k; i++) {
        p = parts[i]
        if (p == "" || p ~ /^!=/) continue
        if (p ~ /^</) {
          inc = (p ~ /^<=/); sub(/^<=?/, "", p)
          if (p !~ /^[0-9]+/) continue
          c = split(p, u, "."); m = u[1] + 0
          if (!inc && (c < 2 || u[2] + 0 == 0) && (c < 3 || u[3] + 0 == 0)) m = m - 1
          if (hi < 0 || m < hi) hi = m
          continue
        }
        o = (p ~ /^>/); sub(/^(\^|~|>=|>|==|=|v)+/, "", p)
        if (p == "*") { if (lo < 0) { lo = 0; open = 1 }; continue }
        if (p !~ /^[0-9]+/) continue
        split(p, v, "."); if (v[1] + 0 > lo) { lo = v[1] + 0; open = o }
      }
      if (lo < 0) next
      if (hi >= 0) { if (n + 0 >= lo && n + 0 <= hi) ok = 1 }
      else if (open) { if (n + 0 >= lo) ok = 1 }
      else if (n + 0 == lo) ok = 1 }
    END { if (ok) print "yes" }' | grep_q -x yes
}

# constraint_majors CONSTRAINT -> every Drupal major a core constraint admits,
# one per line, per `||` alternative: from the major of its first lower bound
# (`^`, `~`, `>=`, `>`, `=`, a bare version) up to the one its upper bound
# leaves (`<12` and `<12.0` stop at 11, `<11.3` and `<=11` at 11); without an
# upper bound, the lower bound's major only. `!=` operands are skipped.
constraint_majors() {
  printf '%s\n' "${1:-}" | tr -d "\"'" | tr '|' '\n' | awk '
    { n = split($0, parts, /[[:space:],]+/); lo = -1; hi = -1
      for (i = 1; i <= n; i++) {
        p = parts[i]
        if (p == "" || p ~ /^!=/) continue
        if (p ~ /^</) {
          inc = (p ~ /^<=/); sub(/^<=?/, "", p)
          if (p !~ /^[0-9]+/) continue
          k = split(p, u, "."); m = u[1] + 0
          if (!inc && (k < 2 || u[2] + 0 == 0) && (k < 3 || u[3] + 0 == 0)) m = m - 1
          if (hi < 0 || m < hi) hi = m
          continue
        }
        if (lo >= 0) continue
        sub(/^(\^|~|>=|>|==|=|v)+/, "", p)
        if (p !~ /^[0-9]+/) continue
        split(p, v, "."); lo = v[1] + 0
      }
      if (lo < 0) next
      top = (hi >= lo) ? hi : lo
      for (j = lo; j <= top; j++) print j }'
  return 0
}

# drupal_target_range -> an explicit DRUPILOT_DRUPAL_TARGET that admits two or
# more majors (e.g. "^10.3 || ^11"): the declared range it overrides
# (strategy explicit, X12 as ADR 0021 narrows it). A bare ^N, any other
# one-major constraint ("^11.2", "~11.2.0") and a dev or wildcard form
# ("11.x-dev") keep their 0.9 meaning, the test-bed's core constraint:
# nothing is printed.
drupal_target_range() {
  local v n
  v="$(config_get_explicit DRUPILOT_DRUPAL_TARGET)"
  [[ -n "$v" && -z "$(drupal_target_major "$v")" ]] || return 0
  case "$v" in *@*|*-dev*|*dev-*|*.x*|*'*'*) return 0;; esac
  n="$(constraint_majors "$v" | sort -u | grep -c . || true)"
  if [[ "${n:-0}" -ge 2 ]]; then printf '%s' "$v"; fi
  return 0
}

# config_get_noalias KEY [default] -> config_get without the alias layer: env,
# .drupilot.json, config/defaults.json, default. For a reader that keeps a 0.9
# legacy path of its own (the KEEP_D10 boolean in strategy_decide) and must
# tell it from the new name.
config_get_noalias() { _config_resolve "$1" "${2:-}" 0; }

# value_alias_normalize SCOPE VALUE [NAME] -> _DRUPILOT_VALUE_ALIAS: VALUE, or the new
# value a migrations.json value_aliases row (kind value, scope SCOPE: a
# setting such as DRUPILOT_CORE_TARGET_STRATEGY) gives an old one (compared
# case-insensitively), warning once per process about NAME (default SCOPE:
# the variable the developer set, e.g. DRUPILOT_CHOICE_CORE_TARGET). Called in
# the main shell (no command substitution), so the warning mark is kept.
# Always returns 0.
value_alias_normalize() {
  local scope="${1:-}" v="${2:-}" name="${3:-${1:-}}" i=0
  _DRUPILOT_VALUE_ALIAS="$v"
  [[ -n "$v" ]] || return 0
  _value_alias_load
  while [[ "$i" -lt "$_DRUPILOT_VALUE_ALIAS_N" ]]; do
    if [[ "${_DV_SCOPE[i]}" == "$scope" && "$(lc "${_DV_OLD[i]}")" == "$(lc "$v")" ]]; then
      _DRUPILOT_VALUE_ALIAS="${_DV_NEW[i]}"
      case "$_DRUPILOT_ALIAS_WARNED" in
        *"|v$i|"*) ;;
        *) _DRUPILOT_ALIAS_WARNED="${_DRUPILOT_ALIAS_WARNED}v$i|"
           log_warn "$name=${_DV_OLD[i]} is deprecated since ${_DV_SINCE[i]:-1.0.0} and will be removed in ${_DV_RIN[i]:-2.0.0}; use $name=${_DV_NEW[i]}";;
      esac
      return 0
    fi
    i=$((i + 1))
  done
  return 0
}

# value_alias_legacy SCOPE VALUE -> the old value a value_aliases row of SCOPE
# renamed to VALUE (VALUE itself when none did): the 0.9 vocabulary drupilot
# still emits and persists for T=11 (CC-07). Prints it; never warns.
value_alias_legacy() {
  local scope="${1:-}" v="${2:-}" i=0
  _value_alias_load
  while [[ "$i" -lt "$_DRUPILOT_VALUE_ALIAS_N" ]]; do
    if [[ "${_DV_SCOPE[i]}" == "$scope" && "$(lc "${_DV_NEW[i]}")" == "$(lc "$v")" ]]; then
      printf '%s\n' "${_DV_OLD[i]}"; return 0
    fi
    i=$((i + 1))
  done
  printf '%s\n' "$v"
  return 0
}

# value_alias_new SCOPE VALUE -> the new value a value_aliases row of SCOPE
# gives an old one (VALUE itself when none does). Prints it; never warns.
value_alias_new() {
  local scope="${1:-}" v="${2:-}" i=0
  _value_alias_load
  while [[ "$i" -lt "$_DRUPILOT_VALUE_ALIAS_N" ]]; do
    if [[ "${_DV_SCOPE[i]}" == "$scope" && "$(lc "${_DV_OLD[i]}")" == "$(lc "$v")" ]]; then
      printf '%s\n' "${_DV_NEW[i]}"; return 0
    fi
    i=$((i + 1))
  done
  printf '%s\n' "$v"
  return 0
}

# _value_alias_load -> the kind-value rows of migrations.json value_aliases in
# parallel arrays (_DV_SCOPE, _DV_OLD, _DV_NEW, _DV_SINCE, _DV_RIN), once per
# process (-1 = not loaded yet).
_DRUPILOT_VALUE_ALIAS_N=-1
_DRUPILOT_VALUE_ALIAS=""
_value_alias_load() {
  local f a b c d e z sep
  [[ "$_DRUPILOT_VALUE_ALIAS_N" -lt 0 ]] || return 0
  _DRUPILOT_VALUE_ALIAS_N=0
  f="$(plugin_root)/config/migrations.json"
  [[ -r "$f" ]] && have_cmd jq || return 0
  sep="$(printf '\037')"
  # shellcheck disable=SC2034  # z is only the sentinel
  while IFS="$sep" read -r a b c d e z; do
    [[ -n "$a" && -n "$b" && -n "$c" ]] || continue
    _DV_SCOPE[_DRUPILOT_VALUE_ALIAS_N]="$a"; _DV_OLD[_DRUPILOT_VALUE_ALIAS_N]="$b"
    _DV_NEW[_DRUPILOT_VALUE_ALIAS_N]="$c"; _DV_SINCE[_DRUPILOT_VALUE_ALIAS_N]="$d"
    _DV_RIN[_DRUPILOT_VALUE_ALIAS_N]="$e"
    _DRUPILOT_VALUE_ALIAS_N=$((_DRUPILOT_VALUE_ALIAS_N + 1))
  done < <(jq -r '.value_aliases[]? | select(type == "object" and .kind == "value")
             | [(.scope // "" | tostring), (.old // "" | tostring), (.new // "" | tostring),
                (.since // "" | tostring), (.remove_in // "" | tostring), "."] | join("\u001f")' "$f" 2>/dev/null || true)
  return 0
}

# config_get_explicit KEY -> the value a developer set: the env tier, the
# .drupilot.json tier and their aliases, never config/defaults.json (so a
# caller can tell an explicit choice from the shipped default). Nothing when
# none is set.
config_get_explicit() { _config_resolve "$1" "" 1 1; }

# config_get_explicit_noalias KEY -> config_get_explicit without the alias
# layer: what a developer set under that very name (a DRUPILOT_KEEP_D10
# boolean is not a strategy someone set, AR-27).
config_get_explicit_noalias() { _config_resolve "$1" "" 0 1; }

# resolve_target_major -> T, the target Drupal major (DRUPILOT_TARGET_MAJOR,
# default 11 for all of 1.0.x, OD-10). Without it set, an explicit
# DRUPILOT_DRUPAL_TARGET names it: ^N -> N, another constraint -> the highest
# major it admits (constraint_top_major; X12).
resolve_target_major() {
  local t c
  t="$(config_get_explicit DRUPILOT_TARGET_MAJOR)"
  if [[ -z "$t" ]]; then
    # X12: a bare ^N in DRUPILOT_DRUPAL_TARGET names the target major; the
    # highest major of any other explicit constraint does.
    c="$(config_get_explicit DRUPILOT_DRUPAL_TARGET)"
    if [[ -n "$c" ]]; then
      t="$(drupal_target_major "$c")"
      [[ -n "$t" ]] || t="$(constraint_top_major "$c")"
    fi
  fi
  printf '%s' "${t:-$(config_get DRUPILOT_TARGET_MAJOR "11")}"
}

# resolve_php_target_for T -> P for target major T: an explicit
# DRUPILOT_PHP_TARGET (env or .drupilot.json), else the target's
# php_defaults.env (config/targets/T.json), else the config default. For T=11
# the data default equals config/defaults.json's 8.3, so 0.9 is unchanged.
resolve_php_target_for() {
  local p d
  p="$(config_get_explicit DRUPILOT_PHP_TARGET)"
  if [[ -z "$p" ]]; then d="$(target_get "${1:-11}" '.php_defaults.env')"; p="${d:-$(resolve_php_target)}"; fi
  printf '%s' "$p"
  return 0
}

# php_target_supported <ver> -> 0 if the version is in php_support.supported
php_target_supported() {
  local v="$1" file; file="$(drupilot_config_file)"
  if [[ -r "$file" ]] && have_cmd jq; then
    jq -e --arg v "$v" '.php_support.supported | index($v)' "$file" >/dev/null 2>&1 && return 0
  fi
  [[ "$v" == "8.3" || "$v" == "8.4" ]]
}

# php_target_unconfirmed <ver> -> 0 if the version is in php_support.unconfirmed
# (8.5): no Rector set is assumed for it, so rector_php_set_arg falls back to the
# highest supported set. Which core minors run it is php_supported_for's answer
# (PHP 8.5 needs Drupal 11.3 or later).
php_target_unconfirmed() {
  local v="$1" file; file="$(drupilot_config_file)"
  if [[ -r "$file" ]] && have_cmd jq; then
    jq -e --arg v "$v" '.php_support.unconfirmed | index($v)' "$file" >/dev/null 2>&1 && return 0
  fi
  [[ "$v" == "8.5" ]]
}
