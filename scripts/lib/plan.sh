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
#                                / '8.1.*' / '8.1.x' / '8.1 - 8.3' /
#                                '>=8.1@dev' / '>=8.1.0-beta1' -> 8.1;
#                                '^8.3 || ^8.1' -> 8.1; '>=8' -> 8.0); nothing
#                                when an alternative has no lower bound ('*',
#                                '<8.4') or C is not a constraint
#   core_version_cmp A B         compare two core versions: returns 0 when
#                                A == B, 1 when A < B, 2 when A > B, 3 when one
#                                is not a version. Pre-releases order dev <
#                                alpha < beta < rc < the release (12.0.0-beta1
#                                < 12.0.0), but a version given only to the
#                                minor (12.0) or with a wildcard (12.0.x-dev,
#                                11.x) stands for the whole branch, so
#                                12.0.0-beta1 == 12.0. Never version_ge, which
#                                drops the suffix of both sides.
#
# The upgrade-plan building blocks (AR-04/AR-06), each documented where it is
# defined: target_minors, target_released_minor, target_prerelease_minor,
# core_range_minors, range_majors, plan_target_block, plan_hops,
# plan_detectors, rector_sets_for_plan, plan_rector_skip, plan_rector_bc,
# php_rector_level, plan_php_block, plan_test_matrix, plan_ci_flags,
# plan_assert and version_data_hash. scripts/analysis/upgrade-path.sh
# assembles the plan from them; they never write and never refuse on their
# own (plan_assert lists, the resolver refuses). The frozen plan (ADR 0018):
# plan_freeze writes it to the root's lock (upgrade-path.sh --freeze only),
# plan_frozen and plan_get read it back without creating anything;
# plan_for_subject / plan_render_fallback give the configs their plan.
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
      lo = ""; upper = 0
      for (i = 1; i <= NF; i++) {
        t = $i
        # "8.1 - 8.3": the token after the hyphen is the upper bound.
        if (t == "-") { upper = 1; continue }
        if (upper) { upper = 0; continue }
        if (t ~ /^(<|!=)/) continue
        sub(/^(>=|==|>|\^|~|=)/, "", t); sub(/^v/, "", t)
        sub(/@.*$/, "", t); sub(/-.*$/, "", t)
        if (t !~ /^[0-9]+(\.([0-9]+|\*|x|X))*$/) { bad = 1; next }
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

# ---------------------------------------------------------------------------
# Upgrade-plan building blocks (AR-04/AR-06; read by
# scripts/analysis/upgrade-path.sh). Pure: data in, JSON or words out.
# ---------------------------------------------------------------------------

# The lowest core a drupal-rector backwards-compatible rewrite can run on:
# Drupal\Component\Utility\DeprecationHelper is absent at tag 10.1.0 and
# present at 10.1.3 (git.drupalcode.org core source by tag, 03-F-D6).
PLAN_BC_MIN_CORE="10.1.3"

# target_minors MAJOR [all|released|prerelease] -> the verified minors of
# targets/MAJOR.json, ascending, one per line: all of them, those with a
# release date, or those without one (a pre-release: 12.0 while 12.0.0 is not
# out).
target_minors() {
  local sel='.value.verified == true'
  case "${2:-all}" in
    released) sel="$sel and .value.released != null";;
    prerelease) sel="$sel and .value.released == null";;
  esac
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 0
  target_get "$1" "[(.minors // {}) | to_entries[] | select($sel) | .key] | sort_by(split(\".\") | map(tonumber)) | .[]"
  return 0
}

# target_released_minor MAJOR -> the newest released verified minor (11 ->
# 11.4); target_prerelease_minor MAJOR -> the newest verified minor with no
# release yet (12 -> 12.0). Nothing when there is none.
target_released_minor() { target_minors "${1:-}" released | tail -n 1; return 0; }
target_prerelease_minor() { target_minors "${1:-}" prerelease | tail -n 1; return 0; }

# core_range_minors CONSTRAINT MAXMAJOR [all|released] -> the verified minors
# of every targets/<N>.json with N <= MAXMAJOR that CONSTRAINT admits,
# ascending (core_requirement_minors). A major with no data file is unknown,
# so none of its minors is listed.
core_range_minors() {
  local c="${1:-}" max="${2:-}" dir f n majors=""
  [[ -n "$c" && "$max" =~ ^[0-9]+$ ]] || return 0
  dir="$(version_data_dir)/targets"
  for f in "$dir"/*.json; do
    [[ -r "$f" ]] || continue
    n="${f##*/}"; n="${n%.json}"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n <= max )) && majors="$majors $n"
  done
  for n in $(printf '%s\n' $majors | LC_ALL=C sort -n); do
    target_minors "$n" "${3:-all}"
  done | core_requirement_minors "$c"
  return 0
}

# range_majors CONSTRAINT -> the majors CONSTRAINT reaches, ascending,
# space-separated: those its alternatives start at plus those of the data
# minors it admits ('>=10.2 <11.1.2' -> "10 11"; '>=10' -> "10 11 12" with
# the data for 10, 11 and 12).
range_majors() {
  local c="${1:-}"
  [[ -n "$c" ]] || return 0
  { core_requirement_majors "$c" | tr ' ' '\n'; printf '\n'; core_range_minors "$c" 999 | cut -d. -f1; } \
    | awk 'NF { seen[$1 + 0] = 1 } END { out = ""; for (m = 0; m <= 999; m++) if (m in seen) out = out (out == "" ? "" : " ") m; printf "%s", out }'
  return 0
}

# _plan_issue ID DETAIL -> {"id": ID, "detail": DETAIL} as one JSON line: a
# refusal of plan_target_block or a violation of plan_assert.
_plan_issue() { jq -n -c --arg i "$1" --arg d "$2" '{id: $i, detail: $d}'; return 0; }

# plan_target_block T ALLOW_PRERELEASE [LOCK_CORE] -> the plan's target, one
# JSON line: {major, status, preview, bed_core, ddev_type, m, toolchain_cell}.
# M is the newest released minor of T, or the pre-release minor when T is a
# pre-release (then ALLOW_PRERELEASE must be true: preview). bed_core is
# LOCK_CORE (a leading "v" dropped) when it is a version of T, else the data's
# .minors[M].latest. Returns 2 with the refusal on stdout when T is no
# port target (no targets/T.json, no toolchain cell, no verified minor:
# id "invalid-target") or a pre-release T is not opted in
# ("prerelease-not-opted-in"); the refusal is {id, detail}.
plan_target_block() {
  local t="${1:-}" allow="${2:-false}" lock="${3:-}" f status cell ddev m bed preview=false
  have_cmd jq || return 1
  if ! [[ "$t" =~ ^[0-9]+$ ]]; then
    _plan_issue invalid-target "'$t' is not a Drupal major version"; return 2
  fi
  f="$(version_data_dir)/targets/$t.json"
  cell="$(target_get "$t" '.toolchain_cell')"
  if [[ ! -r "$f" || -z "$cell" ]]; then
    _plan_issue invalid-target "Drupal $t is not a port target drupilot has data for (no toolchain cell in targets/$t.json)"; return 2
  fi
  status="$(target_get "$t" '.status')"
  ddev="$(target_get "$t" '.ddev_type')"
  if [[ "$status" == "pre-release" ]]; then
    if [[ "$allow" != "true" ]]; then
      _plan_issue prerelease-not-opted-in "Drupal $t is a pre-release: set DRUPILOT_ALLOW_PRERELEASE=true to port to it as a preview"; return 2
    fi
    preview=true; m="$(target_prerelease_minor "$t")"
  else
    m="$(target_released_minor "$t")"
  fi
  if [[ -z "$m" ]]; then
    _plan_issue invalid-target "targets/$t.json holds no verified minor to build a test-bed on"; return 2
  fi
  lock="${lock#v}"
  if [[ "$lock" =~ ^([0-9]+)\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ && "${BASH_REMATCH[1]}" == "$t" ]]; then
    bed="$lock"
  else
    bed="$(target_get "$t" ".minors[\"$m\"].latest")"
  fi
  if [[ -z "$bed" ]]; then
    _plan_issue invalid-target "targets/$t.json has no latest release for Drupal $m"; return 2
  fi
  jq -n -c --argjson t "$t" --arg s "$status" --argjson p "$preview" --arg b "$bed" --arg d "$ddev" \
    --arg m "$m" --arg c "$cell" \
    '{major: $t, status: $s, preview: $p, bed_core: $b, ddev_type: (if $d == "" then null else $d end), m: $m, toolchain_cell: $c}'
  return 0
}

# plan_hops S T -> the upgrade-path edge ids (paths/graph.json) from source
# major S to target major T, space-separated: from each major the edge that
# reaches farthest without passing T (7 -> 12: "7-11 11-12"; 9 -> 11:
# "9-10 10-11"). Nothing when S = T. Returns 2 when S > T or no edge chain
# ends at T, 1 when S or T is not a major.
plan_hops() {
  local s="${1:-}" t="${2:-}" f r
  [[ "$s" =~ ^[0-9]+$ && "$t" =~ ^[0-9]+$ ]] && have_cmd jq || return 1
  (( s <= t )) || return 2
  f="$(version_data_dir)/paths/graph.json"
  [[ -r "$f" ]] || return 2
  r="$(jq -r --argjson s "$s" --argjson t "$t" '
    def route($c):
      if $c == $t then []
      else ([.edges[] | select(.from == $c and .to <= $t)] | max_by(.to)) as $e
        | if $e == null then null
          else route($e.to) as $r | if $r == null then null else [$e.id] + $r end end
      end;
    route($s) | if . == null then "-" else join(" ") end' "$f" 2> /dev/null || true)"
  [[ -n "$r" && "$r" != "-" ]] || { [[ "$r" == "" && "$s" == "$t" ]] && return 0; return 2; }
  printf '%s' "$r"
  return 0
}

# plan_detectors HOP... -> the hard-break detectors of the hops' edges, one
# JSON array in hop order without repeats ([] for no hop, or a hop with none).
plan_detectors() {
  local f
  f="$(version_data_dir)/paths/graph.json"
  [[ -r "$f" ]] && have_cmd jq || { printf '[]'; return 0; }
  jq -c --arg h "$*" '($h | split(" ") | map(select(length > 0))) as $hs
    | [$hs[] as $id | .edges[] | select(.id == $id) | (.detectors // [])[]]
    | reduce .[] as $d ([]; if any(.[]; . == $d) then . else . + [$d] end)' "$f" 2> /dev/null || printf '[]'
  return 0
}

# _plan_set_consts FAMILY [BED_ROOT] -> {source, consts}: the DRUPAL_* constant
# names a drupal-rector set list declares. With BED_ROOT holding drupal-rector,
# read from its src/Set/FAMILY.php (source "bed"; [] when the file is absent);
# else from targets/<N>.json .rector_sets (N from DrupalNSetList, verified
# only: source "data"); else {source: null, consts: []}.
_plan_set_consts() {
  local fam="${1:-}" root="${2:-}" f maj
  if [[ -n "$root" && -d "$root/vendor/palantirnet/drupal-rector/src/Set" ]]; then
    f="$root/vendor/palantirnet/drupal-rector/src/Set/$fam.php"
    if [[ -r "$f" ]]; then
      LC_ALL=C sed -n 's/^[[:space:]]*\(public[[:space:]][[:space:]]*\)\{0,1\}const[[:space:]][[:space:]]*\(DRUPAL_[0-9][0-9A-Z_]*\)[[:space:]]*=.*/\2/p' "$f" \
        | jq -R -s -c '{source: "bed", consts: (split("\n") | map(select(length > 0)))}'
    else
      printf '{"source":"bed","consts":[]}'
    fi
    return 0
  fi
  maj="$(printf '%s' "$fam" | sed -n 's/^Drupal\([0-9][0-9]*\)SetList$/\1/p')"
  f="$(version_data_dir)/targets/$maj.json"
  if [[ -n "$maj" && -r "$f" ]] && jq -e '.rector_sets.verified == true' "$f" > /dev/null 2>&1; then
    jq -c --arg fam "$fam" '{source: "data", consts: [((.rector_sets.own_major // []) + (.rector_sets.breaking // []))[]
      | select(startswith($fam + "::")) | ltrimstr($fam + "::")]}' "$f"
    return 0
  fi
  printf '{"source":null,"consts":[]}'
  return 0
}

# rector_sets_for_plan HOPS F BED [BED_ROOT] -> the drupal-rector sets of the
# plan's hops, one JSON line {drupal_sets, breaking_sets, sets_skipped}. HOPS
# is plan_hops' list, F the floor of the declared range (MAJOR.MINOR), BED
# the test-bed core. Each rector hop contributes its edge's set_family, per
# minor only (DRUPAL_100, never the DRUPAL_10 aggregate), every minor up to
# BED's (12.0.0-beta1 counts as 12.0); its DRUPAL_<N><m>_BREAKING sets only
# when the edge declares breaking_sets, for m <= F's minor when F's major is
# N and all of them when F's major is above N; its always_sets whatever BED.
# Constants come from _plan_set_consts. sets_skipped lists {hop, family, set,
# reason} for a family with no source (no-fallback-data: Drupal8/9SetList
# without a bed), a family the installed drupal-rector lacks (missing-family)
# and an always_set it does not declare (missing-constant).
rector_sets_for_plan() {
  local hops="${1:-}" floor="${2:-}" bed="${3:-}" root="${4:-}" graph edges fam fams="{}" c
  [[ -n "$bed" ]] && have_cmd jq || return 1
  graph="$(version_data_dir)/paths/graph.json"
  [[ -r "$graph" ]] || return 1
  edges="$(jq -c --arg h "$hops" '($h | split(" ") | map(select(length > 0))) as $hs
    | [$hs[] as $id | .edges[] | select(.id == $id)
       | {hop: .id, family: (.set_family // null), breaking: has("breaking_sets"), always: (.always_sets // [])}]' "$graph")" || return 1
  for fam in $(printf '%s' "$edges" | jq -r '[.[] | (.family // empty), (.always[] | split("::")[0])] | unique | .[]'); do
    c="$(_plan_set_consts "$fam" "$root")"
    fams="$(jq -n -c --argjson a "$fams" --arg k "$fam" --argjson v "$c" '$a + {($k): $v}')"
  done
  jq -n -c --argjson edges "$edges" --argjson fams "$fams" --arg f "$floor" --arg bed "$bed" '
    def ver: sub("^v"; "") | split("-")[0] | split(".") | map(tonumber? // 0) | . + [0, 0] | .[0:2];
    def le($a; $b): $a[0] < $b[0] or ($a[0] == $b[0] and $a[1] <= $b[1]);
    def minor($n): ltrimstr("DRUPAL_") as $r | ($r | endswith("_BREAKING")) as $br
      | ($r | rtrimstr("_BREAKING")) as $d | ($n | tostring) as $ns
      | if ($d | test("^[0-9]+$")) and ($d | startswith($ns)) and (($d | length) > ($ns | length))
        then {name: ., minor: ($d | ltrimstr($ns) | tonumber), breaking: $br} else empty end;
    ($bed | ver) as $b
    | (if $f == "" then null else ($f | ver) end) as $fl
    | reduce $edges[] as $e ({drupal_sets: [], breaking_sets: [], sets_skipped: []};
        (if $e.family == null then .
         else ($fams[$e.family]) as $src
           | ($e.family | ltrimstr("Drupal") | rtrimstr("SetList") | tonumber) as $n
           | if $src.source == null then .sets_skipped += [{hop: $e.hop, family: $e.family, set: null, reason: "no-fallback-data"}]
             elif ($src.consts | length) == 0 then .sets_skipped += [{hop: $e.hop, family: $e.family, set: null, reason: "missing-family"}]
             else ([$src.consts[] | minor($n) | select(le([$n, .minor]; $b))] | sort_by(.minor)) as $ms
               | .drupal_sets += [$ms[] | select(.breaking | not) | "\($e.family)::\(.name)"]
               | .breaking_sets += (if $e.breaking and $fl != null
                   then [$ms[] | select(.breaking and ($fl[0] > $n or ($fl[0] == $n and .minor <= $fl[1]))) | "\($e.family)::\(.name)"]
                   else [] end)
             end
         end)
        | reduce $e.always[] as $a (.;
            ($a | split("::")) as $p | ($fams[$p[0]]) as $src
            | if $src.source == null then .sets_skipped += [{hop: $e.hop, family: $p[0], set: $a, reason: "no-fallback-data"}]
              elif any($src.consts[]; . == $p[1]) then (if any(.drupal_sets[]; . == $a) then . else .drupal_sets += [$a] end)
              else .sets_skipped += [{hop: $e.hop, family: $p[0], set: $a, reason: "missing-constant"}] end))'
  return 0
}

# plan_rector_skip -> the Rector rules every drupilot config skips, one JSON
# array of FQCNs in php/rules.json order (= templates/rector.php.tmpl's
# $drupilotRiskySkips): the deny rows, plus any compat row not drupal_safe.
plan_rector_skip() {
  local f
  f="$(version_data_dir)/php/rules.json"
  [[ -r "$f" ]] && have_cmd jq || { printf '[]'; return 0; }
  jq -c '[.rules[] | select(.kind == "deny" or (.kind == "compat" and .drupal_safe == false)) | .rule]' "$f" 2> /dev/null || printf '[]'
  return 0
}

# plan_rector_bc CONSTRAINT F -> {enabled, min_core}: drupal-rector's
# backwards-compatible rewrites (DeprecationHelper) are on when CONSTRAINT
# admits more than one minor (a data minor, F's next minor or the next major
# besides F) and the lowest core it admits (core_requirement_lowest:
# '^10.1.3 || ^11' -> 10.1.3) is at least PLAN_BC_MIN_CORE; min_core is then
# F (MAJOR.MINOR), else null.
plan_rector_bc() {
  local c="${1:-}" f="${2:-}" on=false rc=0 more low
  if [[ -n "$c" && "$f" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    more="$( { printf '%s\n%s\n' "${BASH_REMATCH[1]}.$((BASH_REMATCH[2] + 1))" "$((BASH_REMATCH[1] + 1)).0" \
               | core_requirement_minors "$c"; core_range_minors "$c" 999; } | grep -vxF "$f" || true)"
    low="$(core_requirement_lowest "$c")"
    if [[ -n "$low" ]]; then core_version_cmp "$low" "$PLAN_BC_MIN_CORE" || rc=$?; else rc=1; fi
    [[ -n "$more" && ( "$rc" == 0 || "$rc" == 2 ) ]] && on=true
  fi
  jq -n -c --argjson on "$on" --arg f "$f" '{enabled: $on, min_core: (if $on then $f else null end)}'
  return 0
}

# php_rector_level X -> php/versions.json .versions[X].rector_level (8.1 ->
# PHP_81); nothing when X is not a PHP minor of the data.
php_rector_level() {
  local f
  f="$(version_data_dir)/php/versions.json"
  [[ -r "$f" && -n "${1:-}" ]] && have_cmd jq || return 0
  jq -r --arg p "$1" '.versions[$p].rector_level // empty' "$f" 2> /dev/null || true
  return 0
}

# plan_php_block L P SPANS -> the plan's php block, one JSON line: {floor: L,
# final: P, window: php_window L P, require_php: ">=L" when SPANS is true
# (the range keeps a previous major, whose sites may run an older PHP) else
# null, phpstan_phpversion: {min, max} (the PHP_VERSION_ID of L and P),
# phpcompat_testversion: "L-P"}. Returns 1 when L or P is not a PHP minor of
# php/versions.json. An L above P gives an empty window (plan_assert reports
# it).
plan_php_block() {
  local lo="${1:-}" hi="${2:-}" spans=false f
  [[ "${3:-}" == "true" ]] && spans=true
  f="$(version_data_dir)/php/versions.json"
  [[ -r "$f" ]] && have_cmd jq || return 1
  jq -e -c --arg lo "$lo" --arg hi "$hi" --arg w "$(php_window "$lo" "$hi")" --argjson sp "$spans" '
    select(.versions[$lo].id != null and .versions[$hi].id != null)
    | {floor: $lo, final: $hi, window: ($w | split(" ") | map(select(length > 0))),
       require_php: (if $sp then ">=" + $lo else null end),
       phpstan_phpversion: {min: .versions[$lo].id, max: .versions[$hi].id},
       phpcompat_testversion: "\($lo)-\($hi)"}' "$f" 2> /dev/null || return 1
  return 0
}

# plan_test_matrix BED P L CONSTRAINT T -> the plan's test legs, one JSON
# array (AR-06, in this order): CURRENT {BED, P, run}; PHP_LOW {BED, the
# lowest PHP of L..P the bed core supports, run} when that PHP is below P;
# PREVIOUS_MAJOR {the newest released verified minor of T-1 CONSTRAINT
# admits, the higher of L and that minor's php_min, static} when there is
# one. Every leg is {leg, core, php, mode}.
plan_test_matrix() {
  local bed="${1:-}" p="${2:-}" l="${3:-}" c="${4:-}" t="${5:-}" low="" x prev="" pphp=""
  have_cmd jq || return 1
  for x in $(php_window "$l" "$p"); do
    [[ "$(php_supported_for "$bed" "$x")" == "yes" ]] && { low="$x"; break; }
  done
  if [[ "$t" =~ ^[0-9]+$ && -n "$c" ]]; then
    prev="$(target_minors "$((t - 1))" released | core_requirement_minors "$c" | tail -n 1)"
  fi
  if [[ -n "$prev" ]]; then
    pphp="$(target_get "$((t - 1))" ".minors[\"$prev\"].php_min")"
    if [[ -z "$pphp" ]] || { [[ -n "$l" ]] && version_ge "$l" "$pphp"; }; then pphp="$l"; fi
  fi
  jq -n -c --arg bed "$bed" --arg p "$p" --arg low "$low" --arg pc "$prev" --arg pp "$pphp" '
    [{leg: "CURRENT", core: $bed, php: $p, mode: "run"}]
    + (if $low != "" and $low != $p then [{leg: "PHP_LOW", core: $bed, php: $low, mode: "run"}] else [] end)
    + (if $pc != "" then [{leg: "PREVIOUS_MAJOR", core: $pc, php: (if $pp == "" then null else $pp end), mode: "static"}] else [] end)'
  return 0
}

# plan_ci_flags MATRIX P BED -> the drupal.org GitLab CI opt-ins the test
# legs map to, one JSON line: OPT_IN_TEST_PREVIOUS_MAJOR = 1 with a
# PREVIOUS_MAJOR leg; OPT_IN_TEST_MAX_PHP = 1 with a PHP_LOW leg when P is
# the highest PHP the bed core's minor supports (AR-06; BED as 11.4.8 or
# 11.4: CURRENT then is the max-PHP run). 0 otherwise.
plan_ci_flags() {
  local mx="${1:-[]}" p="${2:-}" m="" max=""
  have_cmd jq || return 1
  m="$(printf '%s' "${3:-}" | sed -n 's/^v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
  [[ -n "$m" ]] && \
    max="$(target_get "${m%%.*}" "(.minors[\"$m\"].php_supported // []) | sort_by(split(\".\") | map(tonumber)) | last")"
  jq -n -c --argjson mx "$mx" --arg p "$p" --arg max "$max" '
    {OPT_IN_TEST_PREVIOUS_MAJOR: (if any($mx[]; .leg == "PREVIOUS_MAJOR") then 1 else 0 end),
     OPT_IN_TEST_MAX_PHP: (if any($mx[]; .leg == "PHP_LOW") and $max != "" and $p == $max then 1 else 0 end)}'
  return 0
}

# plan_assert PLAN [FROZEN] -> the plan's violated assertions (AR-06), one
# JSON array of {id, detail}, in this order: source-above-target (S > T),
# prerelease-not-opted-in (a pre-release T without preview),
# range-excludes-bed (the range does not admit the bed core's minor: the
# module could not be installed on the test-bed), floor-above-final (L > P),
# php-not-supported (P is not a PHP M supports, M the newest released minor
# of T or its pre-release minor in preview), minor-php-disjoint (a verified
# minor of a major <= T that the range admits supports none of the PHP
# minors L..P: every answer "no"; an "unknown" one is not a violation; the
# violation also names the `minor`), three-majors (the range reaches 3 or
# more majors while its strategy is not explicit and it does not keep the
# current declaration), and, with a FROZEN plan (a final plan over the one
# frozen in the lock, ADR 0018), final-changes-frozen for each frozen value
# it changes: T, P, the toolchain cell, the bed core's minor, and over a
# frozen draft only, a hop dropped or F lowered (the final plan may only add
# hops and raise F; a lowered F also names the `frozen_strategy`); each
# names its `field`. Returns 2 when any is violated, 1 when PLAN is not an object.
# Nothing is fixed: the caller refuses (upgrade-path.sh exits 2).
plan_assert() {
  local plan="${1:-}" frozen="${2:-}" t="" s="" l="" p="" st="" pv="" b="" c="" strat="" rs="" m x w n ans all bm
  local out="" vals
  have_cmd jq || return 1
  # -s: an empty PLAN is [] (jq 1.6's -e exits 0 on no input at all).
  printf '%s' "$plan" | jq -e -s 'length == 1 and (.[0] | type == "object")' > /dev/null 2>&1 || return 1
  # Every field as one shell word: a string as is, a number or boolean as
  # text, anything else as its JSON (which then matches no check's format).
  vals="$(printf '%s' "$plan" | jq -r 'def w: if type == "string" then . elif type == "number" or type == "boolean" then tostring
      elif . == null then "" else tojson end;
    @sh "t=\(.target.major | w) s=\(.source.major | w) l=\(.php.floor | w) p=\(.php.final | w) st=\(.target.status | w) pv=\(.target.preview | w) b=\(.target.bed_core | w) c=\(.range.constraint | w) strat=\(.range.strategy | w) rs=\(.range.resolved_strategy | w)"')" || return 1
  [[ -n "$vals" ]] || return 1
  eval "$vals"
  if [[ "$s" =~ ^[0-9]+$ && "$t" =~ ^[0-9]+$ ]] && (( s > t )); then
    out="$out$(_plan_issue source-above-target "the code is already Drupal $s, above the target Drupal $t")"$'\n'
  fi
  if [[ "$st" == "pre-release" && "$pv" != "true" ]]; then
    out="$out$(_plan_issue prerelease-not-opted-in "Drupal $t is a pre-release and the plan is not a preview")"$'\n'
  fi
  bm="$(printf '%s' "$b" | sed -n 's/^v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\)\..*/\1/p')"
  if [[ -n "$c" && -n "$bm" && -z "$(printf '%s\n' "$bm" | core_requirement_minors "$c")" ]]; then
    out="$out$(_plan_issue range-excludes-bed "'$c' does not admit the test-bed core $b: the module could not be installed on it")"$'\n'
  fi
  if [[ -n "$l" && -n "$p" ]] && ! version_ge "$p" "$l"; then
    out="$out$(_plan_issue floor-above-final "the code needs PHP $l, above the PHP target $p")"$'\n'
  fi
  if [[ "$t" =~ ^[0-9]+$ && -n "$p" ]]; then
    if [[ "$pv" == "true" ]]; then m="$(target_prerelease_minor "$t")"; else m="$(target_released_minor "$t")"; fi
    # A pre-release T without preview has no released minor: check the
    # pre-release one (prerelease-not-opted-in already says the rest).
    [[ -n "$m" ]] || m="$(target_prerelease_minor "$t")"
    ans="$(php_supported_for "$m" "$p")"
    if [[ -z "$m" ]]; then
      out="$out$(_plan_issue php-not-supported "the data holds no verified Drupal $t minor to check PHP $p against")"$'\n'
    elif [[ "$ans" == "no" ]]; then
      out="$out$(_plan_issue php-not-supported "Drupal $m does not support PHP $p")"$'\n'
    elif [[ "$ans" != "yes" ]]; then
      out="$out$(_plan_issue php-not-supported "whether Drupal $m supports PHP $p is unknown")"$'\n'
    fi
  fi
  w="$(php_window "$l" "$p")"
  if [[ -n "$w" && -n "$c" && "$t" =~ ^[0-9]+$ ]]; then
    for n in $(core_range_minors "$c" "$t"); do
      all="no"
      for x in $w; do
        ans="$(php_supported_for "$n" "$x")"
        [[ "$ans" == "no" ]] || { all="$ans"; break; }
      done
      [[ "$all" != "no" ]] || out="$out$(_plan_issue minor-php-disjoint "Drupal $n supports none of PHP $(printf '%s' "$w" | tr ' ' ',') ($c)" | jq -c --arg n "$n" '. + {minor: $n}')"$'\n'
    done
  fi
  n="$(range_majors "$c" | wc -w | tr -d ' ')"
  if (( n >= 3 )) && [[ "$strat" != "explicit" && "$rs" != "keep-current" ]]; then
    out="$out$(_plan_issue three-majors "'$c' reaches $n majors: only an explicit range or a kept declaration may")"$'\n'
  fi
  if [[ -n "$frozen" ]]; then
    out="$out$(_plan_frozen_changes "$plan" "$frozen")"
  fi
  printf '%s' "$out" | jq -s -c '.'
  [[ -z "$out" ]] || return 2
  return 0
}

# _plan_frozen_changes PLAN FROZEN -> one final-changes-frozen violation per
# line ({id, detail, field, frozen, value}) for each frozen value PLAN
# changes beyond what the final phase may (plan_assert).
_plan_frozen_changes() {
  local plan="$1" frozen="$2" f0 f1 rc=0
  printf '%s' "$frozen" | jq -e -s 'length == 1 and (.[0] | type == "object")' > /dev/null 2>&1 || return 0
  jq -n -c --argjson p "$plan" --argjson f "$frozen" '
    def minor: tostring | sub("^v"; "") | split("-")[0] | split(".") | .[0:2] | join(".");
    def ch($fld; $old; $new; $what): {id: "final-changes-frozen", field: $fld, frozen: $old, value: $new,
      detail: "the final plan changes the frozen \($what) (\($old) -> \($new)): only the setup may change it"};
    (if $p.target.major != $f.target.major then ch("target.major"; $f.target.major; $p.target.major; "target major") else empty end),
    (if $p.php.final != $f.php.final then ch("php.final"; $f.php.final; $p.php.final; "PHP target") else empty end),
    (if $p.toolchain_cell != $f.toolchain_cell then ch("toolchain_cell"; $f.toolchain_cell; $p.toolchain_cell; "toolchain cell") else empty end),
    (if ($p.target.bed_core | minor) != ($f.target.bed_core | minor) then ch("target.bed_core"; $f.target.bed_core; $p.target.bed_core; "test-bed core") else empty end),
    if $f.meta.phase != "draft" then empty
    else (($f.hops // []) - ($p.hops // [])) as $lost
      | (if ($lost | length) > 0 then ch("hops"; ($f.hops | join(" ")); ($p.hops | join(" ")); "hops (\($lost | join(", ")) dropped)") else empty end) end' \
    2> /dev/null || true
  # Hops and F are bounded by the setup's draft only; a final plan may
  # re-resolve over another final one.
  [[ "$(printf '%s' "$frozen" | jq -r '.meta.phase // ""' 2> /dev/null || true)" == "draft" ]] || return 0
  f0="$(printf '%s' "$frozen" | jq -r '.range.floor // empty' 2> /dev/null || true)"
  f1="$(printf '%s' "$plan" | jq -r '.range.floor // empty' 2> /dev/null || true)"
  if [[ -n "$f0" && -n "$f1" ]]; then
    core_version_cmp "$f1" "$f0" || rc=$?
    [[ "$rc" != "1" ]] || jq -n -c --arg o "$f0" --arg n "$f1" \
      --arg st "$(printf '%s' "$frozen" | jq -r '.range.strategy // ""' 2> /dev/null || true)" \
      '{id: "final-changes-frozen", field: "range.floor", frozen: $o, value: $n, frozen_strategy: $st,
        detail: "the final plan lowers the frozen core floor (\($o) -> \($n)): F may only rise"}'
  fi
  return 0
}

# version_data_hash [DIR] -> the bare SHA-256 identity of a version-data
# directory (default version_data_dir): the hash of "<path> <sha256>" lines,
# one per JSON file under targets/, php/ and paths/, sorted (LC_ALL=C) — the
# name of its tests/fixtures/data-snapshots/ copy and of a golden.json
# data_hash (scripts/dev/golden.sh computes the same). Nothing when DIR holds
# none or no hasher exists.
version_data_hash() {
  local d="${1:-}" f h lines=""
  [[ -n "$d" ]] || d="$(version_data_dir)"
  [[ -d "$d" ]] || return 0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    h="$(sha256_hex < "$d/$f")"
    [[ -n "$h" ]] || return 0
    lines="$lines$f $h
"
  done <<EOF
$(CDPATH='' cd "$d" && find targets php paths -type f -name '*.json' 2> /dev/null | LC_ALL=C sort)
EOF
  [[ -n "$lines" ]] || return 0
  printf '%s' "$lines" | sha256_hex
  return 0
}

# ---------------------------------------------------------------------------
# The frozen plan (ADR 0018): .upgrade_plan, .upgrade_plan_hash,
# .upgrade_plan_phase and .data_hash in the Drupal root's lock.
# ---------------------------------------------------------------------------

# plan_get JQPATH [ROOT] -> one value of the frozen plan: `.upgrade_plan |
# JQPATH` of ROOT's lock (default DRUPILOT_PROJECT_DIR, else $PWD), a string
# raw, anything else as compact JSON (false and 0 included); nothing when the
# value is null. Returns 1 when the lock holds no plan (or JQPATH is not a jq
# path). Read-only: it never creates the state dir (lock_path). The way every
# stage reads a version (H4): `plan_get .php.final "$ROOT"`.
plan_get() {
  local p="${1:-}" f
  [[ -n "$p" ]] && have_cmd jq || return 1
  f="$(lock_path "${2:-${DRUPILOT_PROJECT_DIR:-$PWD}}")"
  [[ -r "$f" ]] || return 1
  # -s: an empty lock is no plan (jq 1.6's -e exits 0 on no input at all).
  jq -e -s 'length == 1 and (.[0].upgrade_plan | type == "object")' "$f" > /dev/null 2>&1 || return 1
  jq -r ".upgrade_plan | ($p) | select(. != null) | if type == \"string\" then . else tojson end" "$f" 2> /dev/null || return 1
  return 0
}

# plan_frozen [ROOT] -> the frozen plan, keys sorted and indented as
# upgrade-path.sh prints it (byte for byte the output that was frozen), or
# nothing. Read-only.
plan_frozen() {
  local f
  have_cmd jq || return 0
  f="$(lock_path "${1:-${DRUPILOT_PROJECT_DIR:-$PWD}}")"
  [[ -r "$f" ]] || return 0
  jq -S 'select(.upgrade_plan | type == "object") | .upgrade_plan' "$f" 2> /dev/null || true
  return 0
}

# plan_freeze PLAN PHASE [ROOT] -> freeze PLAN (a draft or final plan) in
# ROOT's lock in one write: {upgrade_plan: PLAN, upgrade_plan_hash:
# json_hash(canon_json_hashable PLAN) (meta excluded), upgrade_plan_phase:
# PHASE, data_hash: PLAN.data_hash}, through lock_merge_json (the rest of the
# lock is kept). Returns 1 on a bad PHASE, a PLAN that is not an object, no
# hasher, or a failed write.
plan_freeze() {
  local plan="${1:-}" phase="${2:-}" root="${3:-${DRUPILOT_PROJECT_DIR:-$PWD}}" h obj
  case "$phase" in draft|final) : ;; *) return 1;; esac
  have_cmd jq || return 1
  printf '%s' "$plan" | jq -e -s 'length == 1 and (.[0] | type == "object")' > /dev/null 2>&1 || return 1
  h="$(printf '%s' "$plan" | canon_json_hashable | json_hash)"
  [[ -n "$h" ]] || return 1
  obj="$(printf '%s' "$plan" | jq -c --arg h "$h" --arg ph "$phase" \
    '{upgrade_plan: ., upgrade_plan_hash: $h, upgrade_plan_phase: $ph, data_hash: .data_hash}')" || return 1
  lock_merge_json "$obj" "$root"
}

# plan_for_subject ROOT SUBJECT -> the upgrade plan a stage renders its
# configs from (H4): the plan frozen in ROOT's lock when it is SUBJECT's, else
# a fresh draft from scripts/analysis/upgrade-path.sh (nothing written).
# Nothing, and return 1, when neither resolves (the resolver refuses, or the
# version data cannot plan).
plan_for_subject() {
  local root="${1:-}" subj="${2:-}" fz mn out
  [[ -n "$subj" && -d "$subj" ]] && have_cmd jq || return 1
  mn="$(subject_machine_name "$subj" 2> /dev/null || true)"
  if [[ -n "$root" && -n "$mn" ]]; then
    fz="$(plan_frozen "$root")"
    if [[ -n "$fz" && "$(printf '%s' "$fz" | jq -r '.subject.machine_name // ""' 2> /dev/null)" == "$mn" ]]; then
      printf '%s\n' "$fz"; return 0
    fi
  fi
  out="$("$BASH" "$(plugin_root)/scripts/analysis/upgrade-path.sh" --subject "$subj" ${root:+--root "$root"} \
    --phase draft --json 2> /dev/null < /dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# plan_render_fallback T -> a plan-shaped object for rendering when no plan
# resolves: the verified per-minor sets of Drupal T-1 (config/targets/<T-1>.json
# rector_sets.own_major), the skip list, backwards-compatible rewrites left to
# drupal-rector's default (as in 0.9).
plan_render_fallback() {
  local t="${1:-11}" ds=""
  [[ "$t" =~ ^[0-9]+$ ]] && have_cmd jq || return 1
  ds="$(target_get "$((t - 1))" 'select(.rector_sets.verified == true) | .rector_sets.own_major' | jq -c '. // []' 2> /dev/null || true)"
  jq -n -c --argjson t "$t" --argjson ds "${ds:-[]}" --argjson sk "$(plan_rector_skip)" \
    '{target: {major: $t}, rector: {drupal_sets: $ds, breaking_sets: [], skip: $sk, bc: {enabled: false, min_core: null}}}'
  return 0
}

# --- Names derived from the target major (T-M3-08, CC-16, CC-17) -------------
# For T=11 they are the 0.9 names, byte for byte: the patch description
# port-to-drupal-11 (MODULE-port-to-drupal-11.patch, the issue-fork branch
# ID-port-to-drupal-11), the test-bed suffix -d11, the DDEV type drupal11. T is
# resolve_target_major (DRUPILOT_TARGET_MAJOR, else DRUPAL_TARGET's major, else
# 11), read where DRUPILOT_PROJECT_DIR points; anything but an integer is 11.

# target_names_major [T] -> T, validated (11 when it is not an integer).
target_names_major() {
  local t="${1:-}"
  [[ -n "$t" ]] || t="$(resolve_target_major)"
  [[ "$t" =~ ^[1-9][0-9]*$ ]] || t=11
  printf '%s\n' "$t"
}

# target_patch_desc [T] -> port-to-drupal-<T>, the default patch description.
target_patch_desc() { printf 'port-to-drupal-%s\n' "$(target_names_major "${1:-}")"; }

# target_workspace_suffix [T] -> -d<T>, the suffix of a loose subject's test-bed.
target_workspace_suffix() { printf -- '-d%s\n' "$(target_names_major "${1:-}")"; }

# target_workspace_suffixes [T] -> the suffixes an existing test-bed may carry,
# one per line: -d<T>, then -d11 when T is not 11 (a bed drupilot 0.9 built is
# still recognized, CC-17).
target_workspace_suffixes() {
  local t
  t="$(target_names_major "${1:-}")"
  printf -- '-d%s\n' "$t"
  if [[ "$t" != "11" ]]; then printf -- '-d11\n'; fi
  return 0
}

# target_ddev_type [T] -> the DDEV project type of the test-bed: the target's
# .ddev_type (config/targets/<T>.json), else drupal<T>.
target_ddev_type() {
  local t d
  t="$(target_names_major "${1:-}")"
  d="$(target_get "$t" '.ddev_type')"
  printf '%s\n' "${d:-drupal$t}"
}

# target_patch_globs -> the globs that match any drupilot patch, one per line:
# the 0.9 names (*-port-to-drupal-11.patch, *-port-to-drupal-11-*.patch) and
# every target's (*-port-to-drupal-*.patch), so an old patch never leaks into a
# new one (09-R10).
target_patch_globs() {
  printf '%s\n' '*-port-to-drupal-11.patch' '*-port-to-drupal-11-*.patch' '*-port-to-drupal-*.patch'
}
