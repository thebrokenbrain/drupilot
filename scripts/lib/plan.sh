#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/plan.sh
# Pure accessors over drupilot's version data: config/targets/<major>.json and
# config/php/versions.json (their shape is schemas/target.schema.json and
# schemas/php-versions.schema.json; scripts/dev/data-check.sh checks them and
# scripts/dev/refresh-data.sh regenerates their derived fields). Sourced by
# scripts/lib/common.sh. Nothing here writes, reaches the network or guesses:
# a value the data does not hold, or holds unverified, is empty or "unknown".
#
#   version_data_dir             the directory holding targets/ and php/:
#                                DRUPILOT_VERSION_DATA_DIR (internal: a test or
#                                a golden pins a data snapshot with it), else
#                                <plugin root>/config
#   target_get MAJOR FILTER      `jq -r FILTER` on targets/MAJOR.json; nothing
#                                when the file or the value is missing (null)
#   php_supported_for MINOR PHP  yes | no | unknown: whether drupal.org's PHP
#                                requirements table supports PHP on core MINOR
#                                (11.4.8 reads as 11.4). A verified minor
#                                answers from its php_supported/php_unsupported
#                                lists, and a PHP in neither is unknown (8.6 on
#                                11.4: "Follow issue #3608511"). A minor the
#                                table does not list is "no" only below the
#                                PHP's drupal_core_floor (8.5 needs 11.3), else
#                                unknown
#   php_window FLOOR FINAL       the PHP minors of php/versions.json from FLOOR
#                                to FINAL, in order, space-separated (8.1 8.5
#                                -> 8.1 8.2 8.3 8.4 8.5); nothing when FLOOR >
#                                FINAL or either is not a PHP minor
#   php_bounds_for_range RANGE   "FLOOR CEILING": the lowest and the highest PHP
#                                some verified minor of a caret core range
#                                supports ('^10 || ^11' -> 8.1 8.5, '^11' ->
#                                8.3 8.5, '^12' -> 8.5 8.5); nothing when the
#                                range has another form, names a major the
#                                data does not hold ('^9 || ^10': Drupal 9's
#                                PHP is not in the data, so no bound is
#                                certain) or no minor is known
#   php_constraint_floor C       the lowest PHP minor a Composer `require.php`
#                                constraint admits ('>=8.1' / '^8.1' / '~8.1.0'
#                                / '8.1.*' -> 8.1; '^8.3 || ^8.1' -> 8.1;
#                                '>=8' -> 8.0); nothing when an alternative has
#                                no lower bound ('*', '<8.4') or C is not a
#                                constraint
#   core_version_cmp A B         compare two core versions: returns 0 when
#                                A == B, 1 when A < B, 2 when A > B, 3 when one
#                                is not a version. Pre-releases order dev <
#                                alpha < beta < rc < the release (12.0.0-beta1
#                                < 12.0.0), but a version given only to the
#                                minor (12.0) or with a wildcard (12.0.x-dev,
#                                11.x) stands for the whole branch, so
#                                12.0.0-beta1 == 12.0. Never version_ge, which
#                                drops the suffix of both sides.
# =============================================================================

version_data_dir() {
  if [[ -n "${DRUPILOT_VERSION_DATA_DIR:-}" ]]; then
    printf '%s' "$DRUPILOT_VERSION_DATA_DIR"; return 0
  fi
  printf '%s/config' "$(plugin_root)"
}

target_get() {
  local f
  [[ -n "${1:-}" && -n "${2:-}" ]] || return 0
  f="$(version_data_dir)/targets/$1.json"
  [[ -r "$f" ]] && have_cmd jq || return 0
  jq -r "($2) | select(. != null)" "$f" 2> /dev/null || true
  return 0
}

core_version_cmp() {
  local r
  r="$(awk -v a="${1:-}" -v b="${2:-}" '
    function parse(v, out,   i, num, suf, parts, n, k) {
      sub(/^v/, "", v)
      num = v; suf = ""
      i = index(v, "-")
      if (i > 0) { num = substr(v, 1, i - 1); suf = tolower(substr(v, i + 1)) }
      n = split(num, parts, ".")
      k = 0; out["wild"] = 0
      for (i = 1; i <= n; i++) {
        if (parts[i] !~ /^[0-9]+$/) { out["wild"] = 1; break }
        k++; out[k] = parts[i] + 0
      }
      out["n"] = k
      out["s"] = 4; out["sn"] = 0
      if (suf != "") {
        if (suf ~ /^dev/) out["s"] = 0
        else if (suf ~ /^alpha/) out["s"] = 1
        else if (suf ~ /^beta/) out["s"] = 2
        else if (suf ~ /^rc/) out["s"] = 3
        else out["s"] = -1
        if (match(suf, /[0-9]+/)) out["sn"] = substr(suf, RSTART, RLENGTH) + 0
      }
      return k
    }
    BEGIN {
      if (parse(a, A) == 0 || parse(b, B) == 0 || A["s"] < 0 || B["s"] < 0) { print 3; exit }
      m = (A["n"] < B["n"]) ? A["n"] : B["n"]
      for (i = 1; i <= m; i++) {
        if (A[i] < B[i]) { print 1; exit }
        if (A[i] > B[i]) { print 2; exit }
      }
      # A shorter or wildcard version stands for its whole branch.
      if (A["n"] != B["n"] || A["n"] < 3 || A["wild"] || B["wild"]) { print 0; exit }
      if (A["s"] != B["s"]) { print (A["s"] < B["s"]) ? 1 : 2; exit }
      if (A["sn"] != B["sn"]) { print (A["sn"] < B["sn"]) ? 1 : 2; exit }
      print 0
    }')"
  return "${r:-3}"
}

php_supported_for() {
  local minor php dir f ans="" floor rc
  minor="$(printf '%s' "${1:-}" | sed -n 's/^v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
  php="$(printf '%s' "${2:-}" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
  if [[ -z "$minor" || -z "$php" ]] || ! have_cmd jq; then printf 'unknown'; return 0; fi
  dir="$(version_data_dir)"
  f="$dir/targets/${minor%%.*}.json"
  if [[ -r "$f" ]]; then
    ans="$(jq -r --arg m "$minor" --arg p "$php" '(.minors[$m] // {}) as $e
      | if $e.verified != true or $e.php_supported == null then ""
        elif ($e.php_supported | index($p)) != null then "yes"
        elif (($e.php_unsupported // []) | index($p)) != null then "no"
        else "unknown" end' "$f" 2> /dev/null || true)"
  fi
  if [[ -z "$ans" ]]; then
    ans="unknown"
    floor="$(jq -r --arg p "$php" '.versions[$p] | select(.verified == true) | .drupal_core_floor // empty' \
      "$dir/php/versions.json" 2> /dev/null || true)"
    if [[ -n "$floor" ]]; then
      rc=0; core_version_cmp "$minor" "$floor" || rc=$?
      [[ "$rc" != "1" ]] || ans="no"
    fi
  fi
  printf '%s' "$ans"
  return 0
}

php_window() {
  local f re='^[0-9]+\.[0-9]+$'
  [[ "${1:-}" =~ $re && "${2:-}" =~ $re ]] || return 0
  f="$(version_data_dir)/php/versions.json"
  [[ -r "$f" ]] && have_cmd jq || return 0
  jq -r --arg lo "$1" --arg hi "$2" 'def k: split(".") | map(tonumber);
    [.versions | keys[] | select(k >= ($lo | k) and k <= ($hi | k))] | sort_by(k) | join(" ") | select(. != "")' \
    "$f" 2> /dev/null || true
  return 0
}

php_constraint_floor() {
  printf '%s\n' "${1:-}" | tr '|' '\n' | awk '
    function key(v,   p) { split(v, p, "."); return p[1] * 1000 + p[2] }
    { gsub(/,/, " ")
      # ">= 8.2": glue each operator to its version.
      while (match($0, /(>=|<=|!=|==|>|<|\^|~|=)[[:space:]]+/)) {
        op = substr($0, RSTART, RLENGTH); sub(/[[:space:]]+$/, "", op)
        $0 = substr($0, 1, RSTART - 1) op substr($0, RSTART + RLENGTH)
      } }
    NF == 0 { next }
    {
      lo = ""
      for (i = 1; i <= NF; i++) {
        t = $i
        if (t ~ /^(<|!=)/) continue
        sub(/^(>=|==|>|\^|~|=)/, "", t); sub(/^v/, "", t)
        if (t !~ /^[0-9]+(\.([0-9]+|\*))*$/) { bad = 1; next }
        n = split(t, p, ".")
        v = p[1] "." ((n >= 2 && p[2] ~ /^[0-9]+$/) ? p[2] + 0 : 0)
        if (lo == "" || key(v) > key(lo)) lo = v
      }
      if (lo == "") { bad = 1; next }
      if (all == "" || key(lo) < key(all)) all = lo
    }
    END { if (!bad && all != "") print all }'
  return 0
}

php_bounds_for_range() {
  local dir alt maj min all="" re='^\^([0-9]+)(\.([0-9]+))?(\.[0-9]+)?$'
  [[ -n "${1:-}" ]] && have_cmd jq || return 0
  dir="$(version_data_dir)"
  while IFS= read -r alt; do
    alt="$(printf '%s' "$alt" | tr -d " \"'")"
    [[ -n "$alt" ]] || continue
    [[ "$alt" =~ $re ]] || return 0
    maj="${BASH_REMATCH[1]}"; min="${BASH_REMATCH[3]:-0}"
    [[ -r "$dir/targets/$maj.json" ]] || return 0
    all="$all $(jq -r --argjson m "$min" '[.minors | to_entries[]
      | select((.key | split(".")[1] | tonumber) >= $m) | .value | select(.verified == true)
      | (.php_supported // [])[]] | join(" ")' "$dir/targets/$maj.json" 2> /dev/null || true)"
  done <<EOF
$(printf '%s\n' "$1" | tr '|' '\n')
EOF
  printf '%s' "$all" | jq -R -r 'def k: split(".") | map(tonumber);
    split(" ") | map(select(length > 0)) | unique_by(k) | sort_by(k)
    | if length == 0 then empty else "\(.[0]) \(.[-1])" end' 2> /dev/null || true
  return 0
}
