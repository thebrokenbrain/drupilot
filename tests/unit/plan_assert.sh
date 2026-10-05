#!/usr/bin/env bash
# plan_assert (T-M3-03, AR-06, ADR 0017): the plan's assertions, listed in a
# fixed order and never fixed silently — source-above-target,
# prerelease-not-opted-in, range-excludes-bed (the bed core outside the
# range), floor-above-final, php-not-supported,
# minor-php-disjoint (only a minor whose every answer is "no"),
# three-majors. Exit 0 with [] when the plan holds, 2 with the violations,
# 1 when the plan is not an object. The data is the snapshot the T=11
# core-target golden is pinned to.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/core-strategy/golden.json")"
export DRUPILOT_VERSION_DATA_DIR

# plan S T STATUS PREVIEW L P CONSTRAINT STRATEGY RESOLVED -> a plan holding
# what plan_assert reads.
plan() {
  jq -n -c --argjson s "$1" --argjson t "$2" --arg st "$3" --argjson pv "$4" --arg l "$5" --arg p "$6" \
    --arg c "$7" --arg strat "$8" --arg rs "$9" \
    '{source: {major: $s}, target: {major: $t, status: $st, preview: $pv}, php: {floor: $l, final: $p},
      range: {constraint: $c, strategy: $strat, resolved_strategy: $rs}}'
}
# pa ARGS... -> "<rc>|<violation ids, space-separated>"
pa() { local r rc=0; r="$(plan_assert "$(plan "$@")")" || rc=$?; printf '%s|%s' "$rc" "$(printf '%s' "$r" | jq -r 'map(.id) | join(" ")')"; }

assert_eq "legacy_widgets at 8.3 (^10 || ^11, L 8.1) holds" "$(pa 10 11 supported false 8.1 8.3 '^10 || ^11' auto keep-previous)" "0|"
assert_eq "  and prints []" "$(plan_assert "$(plan 10 11 supported false 8.1 8.3 '^10 || ^11' auto keep-previous)")" "[]"
assert_eq "^11 at 8.5 holds" "$(pa 11 11 supported false 8.3 8.5 '^11' auto keep-current)" "0|"
assert_eq "T=12 preview ^11.3 || ^12 at 8.5 holds" "$(pa 10 12 pre-release true 8.3 8.5 '^11.3 || ^12' auto keep-previous)" "0|"
assert_eq "a kept ^10.3 || ^11 || ^12 holds (12.0 is above T: not checked)" \
  "$(pa 10 11 supported false 8.1 8.3 '^10.3 || ^11 || ^12' auto keep-current)" "0|"
assert_eq "an explicit three-major range holds" "$(pa 10 11 supported false 8.1 8.3 '^10.3 || ^11 || ^12' explicit explicit)" "0|"

assert_eq "source-above-target" "$(pa 12 11 supported false 8.3 8.3 '^12' auto keep-current)" "2|source-above-target"
assert_eq "prerelease-not-opted-in (8.5 is checked on 12.0: supported)" \
  "$(pa 10 12 pre-release false 8.3 8.5 '^11.3 || ^12' auto keep-previous)" "2|prerelease-not-opted-in"
assert_eq "floor-above-final (php_floor_signals: L 8.4 > P 8.3)" \
  "$(pa 10 11 supported false 8.4 8.3 '^10 || ^11' auto keep-previous)" "2|floor-above-final"
r="$(plan_assert "$(plan 10 11 supported false 8.4 8.3 '^10 || ^11' auto keep-previous)" || true)"
assert_eq "  its detail" "$(printf '%s' "$r" | jq -r '.[0].detail')" "the code needs PHP 8.4, above the PHP target 8.3"
assert_eq "php-not-supported: 11.4 does not run 8.2 (and 11.1+ none of 8.1..8.2)" \
  "$(pa 10 11 supported false 8.1 8.2 '^10 || ^11' auto keep-previous)" \
  "2|php-not-supported minor-php-disjoint minor-php-disjoint minor-php-disjoint minor-php-disjoint"
r="$(plan_assert "$(plan 10 11 supported false 8.1 8.6 '^10 || ^11' auto keep-previous)" || true)"
assert_eq "php-not-supported: whether 11.4 runs 8.6 is unknown" "$r" \
  '[{"id":"php-not-supported","detail":"whether Drupal 11.4 supports PHP 8.6 is unknown"}]'
r="$(plan_assert "$(plan 10 11 supported false 8.5 8.5 '^10.3 || ^11' keep-previous keep-previous)" || true)"
assert_eq "minor-php-disjoint: ^10.3 || ^11 with W = {8.5}" "$(printf '%s' "$r" | jq -r 'map(.detail | split(" ")[1]) | join(" ")')" \
  "10.3 10.4 10.5 10.6 11.0 11.1 11.2"
assert_eq "  its detail" "$(printf '%s' "$r" | jq -r '.[1].detail')" "Drupal 10.4 supports none of PHP 8.5 (^10.3 || ^11)"
assert_eq "  each names its minor" "$(printf '%s' "$r" | jq -r 'map(.minor) | join(" ")')" "10.3 10.4 10.5 10.6 11.0 11.1 11.2"
bed() { plan_assert "$(plan 10 11 supported false 8.3 8.3 "$1" explicit explicit | jq -c --arg b "$2" '.target.bed_core = $b')" | jq -r 'map(.id) | join(" ")'; }
assert_eq "range-excludes-bed: ^11.5 on an 11.4.8 bed" "$(bed '^11.5' 11.4.8)" "range-excludes-bed"
assert_eq "range-excludes-bed: ^10.3 (no Drupal 11) on an 11.4.8 bed" "$(bed '^10.3' 11.4.8)" "range-excludes-bed"
assert_eq "range-excludes-bed: ~11.2.0 on an 11.4.8 bed" "$(bed '~11.2.0' 11.4.8)" "range-excludes-bed"
assert_eq "a range admitting the bed holds" "$(bed '^11' 11.4.8)" ""
assert_eq "  a pre-release bed counts as its minor" "$(plan_assert "$(plan 10 12 pre-release true 8.5 8.5 '^12' auto target-only | jq -c '.target.bed_core = "12.0.0-beta1"')")" "[]"
assert_eq "an unknown answer is no violation (10.0's PHP list is unknown)" \
  "$(pa 10 11 supported false 8.3 8.3 '^10.0 || ^11' keep-previous keep-previous)" "0|"
assert_eq "three-majors: keep-previous may not reach 3 majors" \
  "$(pa 10 11 supported false 8.1 8.3 '^10.3 || ^11 || ^12' keep-previous keep-previous)" "2|three-majors"
assert_eq "three-majors: >=10 reaches 10, 11 and 12" "$(pa 10 11 supported false 8.1 8.3 '>=10' auto keep-previous)" "2|three-majors"
assert_eq "several at once, in the fixed order" \
  "$(pa 12 11 supported false 8.4 8.3 '^10 || ^11 || ^12' auto keep-previous)" "2|source-above-target floor-above-final three-majors"
assert_eq "the schema's example plan holds" "$(plan_assert "$(cat "$T_REPO/schemas/examples/upgrade-plan.example.json")")" "[]"
# A field of another type is never a shell word: no command runs, and the
# checks it feeds see a value of no valid format.
bad="$(plan 12 11 supported false 8.4 8.3 '^10 || ^11' auto keep-previous | jq -c --arg f "$T_TMP/pwned" '.range.resolved_strategy = ["x", "touch", $f] | .range.strategy = {}')"
r="$(plan_assert "$bad" || true)"
assert_eq "an array or object field runs nothing" "$([[ -e "$T_TMP/pwned" ]] && echo ran || echo safe)" "safe"
assert_eq "  and the other checks still run" "$(printf '%s' "$r" | jq -r 'map(.id) | join(" ")')" "source-above-target floor-above-final"
assert_eq "a numeric PHP floor is read as text" \
  "$(plan_assert "$(plan 10 11 supported false 8.1 8.3 '^10 || ^11' auto keep-previous | jq -c '.php.floor = 8.4')" | jq -r '.[0].id')" "floor-above-final"
assert_exit "a plan that is not an object" 1 plan_assert '[1]'
assert_exit "no plan" 1 plan_assert ''
t_done
