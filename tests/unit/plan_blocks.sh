#!/usr/bin/env bash
# The upgrade plan's target, hops and Rector blocks (T-M3-03, AR-04/AR-06,
# ADR 0017): plan_target_block (the bed core and the pre-release opt-in),
# plan_hops / plan_detectors over paths/graph.json, rector_sets_for_plan (per
# minor up to the bed, breaking sets by the floor, always_sets, reflection
# from a bed's drupal-rector, the skipped records), plan_rector_skip (= the
# template's skip list) and plan_rector_bc. The data is the snapshot the T=11
# core-target golden is pinned to.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/core-strategy/golden.json")"
export DRUPILOT_VERSION_DATA_DIR

# --- minors -------------------------------------------------------------------
assert_eq "target_released_minor 11" "$(target_released_minor 11)" "11.4"
assert_eq "target_released_minor 12 (none yet)" "$(target_released_minor 12)" ""
assert_eq "target_prerelease_minor 12" "$(target_prerelease_minor 12)" "12.0"
assert_eq "target_prerelease_minor 11 (11.5 is not verified)" "$(target_prerelease_minor 11)" ""
assert_eq "target_minors 10" "$(target_minors 10 | tr '\n' ' ')" "10.0 10.1 10.2 10.3 10.4 10.5 10.6 "
assert_eq "target_minors of a major with no data" "$(target_minors 9)" ""

# --- plan_target_block --------------------------------------------------------
ptb() { local r rc=0; r="$(plan_target_block "$@")" || rc=$?; printf '%s|%s' "$rc" "$r"; }
assert_eq "T=11" "$(ptb 11 false)" \
  '0|{"major":11,"status":"supported","preview":false,"bed_core":"11.4.8","ddev_type":"drupal11","m":"11.4","toolchain_cell":"11"}'
assert_eq "T=12 without the opt-in" "$(ptb 12 false)" \
  '2|{"id":"prerelease-not-opted-in","detail":"Drupal 12 is a pre-release: set DRUPILOT_ALLOW_PRERELEASE=true to port to it as a preview"}'
assert_eq "T=12 opted in: a preview on the beta" "$(ptb 12 true)" \
  '0|{"major":12,"status":"pre-release","preview":true,"bed_core":"12.0.0-beta1","ddev_type":"drupal12","m":"12.0","toolchain_cell":"12"}'
assert_match "T=10: no toolchain cell" "$(ptb 10 true)" '^2\|\{"id":"invalid-target"'
assert_match "T=9: no data" "$(ptb 9 true)" '^2\|\{"id":"invalid-target"'
assert_match "T=abc" "$(ptb abc false)" '^2\|\{"id":"invalid-target","detail":"'"'"'abc'"'"' is not a Drupal major version"\}'
assert_eq "the lock's core when it is a T version (its v dropped)" "$(plan_target_block 11 false v11.3.5 | jq -r .bed_core)" "11.3.5"
assert_eq "the lock's core of another major is ignored" "$(plan_target_block 11 false 10.6.1 | jq -r .bed_core)" "11.4.8"
assert_eq "a lock pre-release of T is kept" "$(plan_target_block 12 true 12.0.0-beta2 | jq -r .bed_core)" "12.0.0-beta2"
assert_eq "a lock core that is no version is ignored" "$(plan_target_block 11 false 11.x-dev | jq -r .bed_core)" "11.4.8"

# --- plan_hops / plan_detectors -----------------------------------------------
ph() { local r rc=0; r="$(plan_hops "$1" "$2")" || rc=$?; printf '%s|%s' "$rc" "$r"; }
assert_eq "10 -> 11" "$(ph 10 11)" "0|10-11"
assert_eq "9 -> 11" "$(ph 9 11)" "0|9-10 10-11"
assert_eq "8 -> 11" "$(ph 8 11)" "0|8-9 9-10 10-11"
assert_eq "7 -> 11: the rewrite edge" "$(ph 7 11)" "0|7-11"
assert_eq "7 -> 12: through 11 (graph.json's forbidden route, allowed)" "$(ph 7 12)" "0|7-11 11-12"
assert_eq "7 -> 12 equals the route graph.json names" "$(ph 7 12)" "0|$(jq -r '.forbidden[0].route | join(" ")' "$DRUPILOT_VERSION_DATA_DIR/paths/graph.json")"
assert_eq "10 -> 12" "$(ph 10 12)" "0|10-11 11-12"
assert_eq "11 -> 11: no hop" "$(ph 11 11)" "0|"
assert_eq "12 -> 11: the source is above the target" "$(ph 12 11)" "2|"
assert_eq "7 -> 10: no edge lands on 10" "$(ph 7 10)" "2|"
assert_eq "x -> 11: not a major" "$(ph x 11)" "1|"
assert_eq "detectors 9-10 10-11, in hop order" "$(plan_detectors 9-10 10-11)" \
  '["twig2-to-3","symfony4-breaks","ckeditor4","jquery-ui","prophecy","removed-ext-11","signature-changes"]'
assert_eq "detectors 10-11 11-12" "$(plan_detectors 10-11 11-12)" \
  '["removed-ext-11","signature-changes","removed-ext-12","library-removed","migrate-drupal-usage","symfony8-constraint-validator"]'
assert_eq "detectors of no hop" "$(plan_detectors)" "[]"
assert_eq "detectors of the D7 rewrite (none)" "$(plan_detectors 7-11)" "[]"
assert_eq "detectors: a repeated hop adds nothing" "$(plan_detectors 10-11 10-11)" '["removed-ext-11","signature-changes"]'

# --- rector_sets_for_plan from the data ---------------------------------------
D10='"Drupal10SetList::DRUPAL_100","Drupal10SetList::DRUPAL_101","Drupal10SetList::DRUPAL_102","Drupal10SetList::DRUPAL_103"'
D11='"Drupal11SetList::DRUPAL_110","Drupal11SetList::DRUPAL_111","Drupal11SetList::DRUPAL_112","Drupal11SetList::DRUPAL_113","Drupal11SetList::DRUPAL_114"'
assert_json_eq "10-11, F 10.0, bed 11.4.8: the per-minor D10 sets, no aggregate" "$(rector_sets_for_plan 10-11 10.0 11.4.8)" \
  "{\"drupal_sets\":[$D10],\"breaking_sets\":[],\"sets_skipped\":[]}"
assert_json_eq "10-11 11-12, F 11.3, bed 12.0.0-beta1: breaking up to 11.3, DRUPAL_120 always" \
  "$(rector_sets_for_plan '10-11 11-12' 11.3 12.0.0-beta1)" \
  "{\"drupal_sets\":[$D10,$D11,\"Drupal12SetList::DRUPAL_120\"],\"breaking_sets\":[\"Drupal11SetList::DRUPAL_111_BREAKING\",\"Drupal11SetList::DRUPAL_112_BREAKING\",\"Drupal11SetList::DRUPAL_113_BREAKING\"],\"sets_skipped\":[]}"
assert_eq "11-12, F 12.0 (no 11.x kept): every 11.x breaking set" \
  "$(rector_sets_for_plan 11-12 12.0 12.0.0-beta1 | jq -c .breaking_sets)" \
  '["Drupal11SetList::DRUPAL_111_BREAKING","Drupal11SetList::DRUPAL_112_BREAKING","Drupal11SetList::DRUPAL_113_BREAKING","Drupal11SetList::DRUPAL_114_BREAKING"]'
assert_eq "11-12, F 11.0: no breaking set" "$(rector_sets_for_plan 11-12 11.0 12.0.0-beta1 | jq -c .breaking_sets)" "[]"
assert_eq "11-12, no F: no breaking set" "$(rector_sets_for_plan 11-12 '' 12.0.0-beta1 | jq -c .breaking_sets)" "[]"
assert_eq "11-12 on a 11.2 bed: the sets stop at 11.2, DRUPAL_120 still in" \
  "$(rector_sets_for_plan 11-12 11.3 11.2.3 | jq -c '[.drupal_sets, .breaking_sets]')" \
  '[["Drupal11SetList::DRUPAL_110","Drupal11SetList::DRUPAL_111","Drupal11SetList::DRUPAL_112","Drupal12SetList::DRUPAL_120"],["Drupal11SetList::DRUPAL_111_BREAKING","Drupal11SetList::DRUPAL_112_BREAKING"]]'
assert_json_eq "8-9 9-10 10-11 with no bed: Drupal8/9 have no data" "$(rector_sets_for_plan '8-9 9-10 10-11' 10.0 11.4.8)" \
  "{\"drupal_sets\":[$D10],\"breaking_sets\":[],\"sets_skipped\":[{\"hop\":\"8-9\",\"family\":\"Drupal8SetList\",\"set\":null,\"reason\":\"no-fallback-data\"},{\"hop\":\"9-10\",\"family\":\"Drupal9SetList\",\"set\":null,\"reason\":\"no-fallback-data\"}]}"
assert_json_eq "the D7 rewrite has no set" "$(rector_sets_for_plan 7-11 10.0 11.4.8)" '{"drupal_sets":[],"breaking_sets":[],"sets_skipped":[]}'
assert_json_eq "no hop" "$(rector_sets_for_plan '' 11.0 11.4.8)" '{"drupal_sets":[],"breaking_sets":[],"sets_skipped":[]}'
assert_exit "no bed core: a usage error" 1 rector_sets_for_plan 10-11 10.0 ''

# --- rector_sets_for_plan by reflection on a bed's drupal-rector --------------
BED="$T_TMP/bed"; S="$BED/vendor/palantirnet/drupal-rector/src/Set"; mkdir -p "$S"
printf '<?php\nfinal class Drupal8SetList\n{\n    const DRUPAL_8 = 1;\n    const DRUPAL_80 = 1;\n    const DRUPAL_88 = 1;\n}\n' > "$S/Drupal8SetList.php"
printf '<?php\nfinal class Drupal10SetList\n{\n    public const DRUPAL_10 = 1;\n    public const DRUPAL_100 = 1;\n    public const DRUPAL_101 = 1;\n    public const DRUPAL_1010 = 1;\n}\n' > "$S/Drupal10SetList.php"
printf '<?php\nfinal class Drupal11SetList\n{\n    public const DRUPAL_11 = 1;\n    public const DRUPAL_110 = 1;\n    public const DRUPAL_111_BREAKING = 1;\n}\n' > "$S/Drupal11SetList.php"
assert_json_eq "reflection: what the bed declares, D8 included; a missing family is recorded" \
  "$(rector_sets_for_plan '8-9 9-10 10-11' 10.0 11.4.8 "$BED")" \
  '{"drupal_sets":["Drupal8SetList::DRUPAL_80","Drupal8SetList::DRUPAL_88","Drupal10SetList::DRUPAL_100","Drupal10SetList::DRUPAL_101","Drupal10SetList::DRUPAL_1010"],"breaking_sets":[],"sets_skipped":[{"hop":"9-10","family":"Drupal9SetList","set":null,"reason":"missing-family"}]}'
assert_eq "reflection: 10.10 sorts after 10.1 and stops at a 10.9 bed" \
  "$(rector_sets_for_plan 10-11 10.0 10.9.1 "$BED" | jq -c .drupal_sets)" \
  '["Drupal10SetList::DRUPAL_100","Drupal10SetList::DRUPAL_101"]'
assert_json_eq "reflection: an always_set the bed lacks is skipped" "$(rector_sets_for_plan 11-12 11.1 12.0.0-beta1 "$BED")" \
  '{"drupal_sets":["Drupal11SetList::DRUPAL_110"],"breaking_sets":["Drupal11SetList::DRUPAL_111_BREAKING"],"sets_skipped":[{"hop":"11-12","family":"Drupal12SetList","set":"Drupal12SetList::DRUPAL_120","reason":"missing-constant"}]}'
assert_json_eq "a bed root without drupal-rector falls back to the data" "$(rector_sets_for_plan 10-11 10.0 11.4.8 "$T_TMP")" \
  "{\"drupal_sets\":[$D10],\"breaking_sets\":[],\"sets_skipped\":[]}"

# --- plan_rector_skip / plan_rector_bc ----------------------------------------
TPL_SKIPS="$(sed -n "/^\$drupilotRiskySkips = /,/^\], 'class_exists'/p" "$T_REPO/templates/rector.php.tmpl" \
  | sed -n "s/^[[:space:]]*'\(.*\)',\$/\1/p" | sed 's/\\\\/\\/g' | jq -R -s -c 'split("\n") | map(select(length > 0))')"
assert_eq "the skip list is the template's, in its order" "$(plan_rector_skip)" "$TPL_SKIPS"
assert_eq "the skip list has the 8 rules" "$(plan_rector_skip | jq length)" "8"
assert_eq "bc ^10 || ^11 (F 10.0 < 10.1.3)" "$(plan_rector_bc '^10 || ^11' 10.0)" '{"enabled":false,"min_core":null}'
assert_eq "bc ^10.1 (10.1.0 < 10.1.3)" "$(plan_rector_bc '^10.1' 10.1)" '{"enabled":false,"min_core":null}'
assert_eq "bc ^10.3 || ^11" "$(plan_rector_bc '^10.3 || ^11' 10.3)" '{"enabled":true,"min_core":"10.3"}'
assert_eq "bc ^11" "$(plan_rector_bc '^11' 11.0)" '{"enabled":true,"min_core":"11.0"}'
assert_eq "bc ^11.3 || ^12" "$(plan_rector_bc '^11.3 || ^12' 11.3)" '{"enabled":true,"min_core":"11.3"}'
assert_eq "bc ~11.2.0 (one minor)" "$(plan_rector_bc '~11.2.0' 11.2)" '{"enabled":false,"min_core":null}'
assert_eq "bc with no floor" "$(plan_rector_bc '^11' '')" '{"enabled":false,"min_core":null}'
t_done
