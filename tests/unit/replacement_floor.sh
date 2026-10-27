#!/usr/bin/env bash
# The core floor follows the replacement of a removed API (lab L-1.0-D9,
# optimizedb: format_size() was removed in 11.0, and its replacement
# ByteSizeMarkup exists only from 10.2, so '^10 || ^11' was a false promise):
# - subject_replacement_floor: a call of a catalogued function removed at or
#   below T, or a use of its replacement_class (import, FQCN), gives the
#   replacement's minor and why; a comment, a method, a variable, a longer
#   name, a function not removed by T give nothing (the class still counts);
# - strategy_decide / core-strategy.sh: keep-d10 declares '^10.2 || ^11'
#   (its legs 10.2 and 11) and says why; a kept '^10 || ^11' is raised; a
#   higher declared floor is never lowered; d11-only stays '^11'; T 12 keeps
#   its own floor; a module without the API is unchanged;
# - upgrade-path.sh: the draft plan's range and its rector.bc follow.
# Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
SNAP="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/core-strategy/golden.json")"
export DRUPILOT_VERSION_DATA_DIR="$SNAP"

mod() {  # mod DIR REQ PHP-BODY
  mkdir -p "$1/src"
  printf 'name: M\ntype: module\ncore_version_requirement: %s\n' "$2" > "$1/$(basename "$1").info.yml"
  printf '<?php\n\n%s\n' "$3" > "$1/src/A.php"
}
mod "$T_TMP/call" '^8 || ^9' '$size = format_size($length);'
mod "$T_TMP/cls" '^10 || ^11' 'use Drupal\Core\StringTranslation\ByteSizeMarkup;
$size = ByteSizeMarkup::create($length);'
mod "$T_TMP/fqcn" '^10 || ^11' '$size = \Drupal\Core\StringTranslation\ByteSizeMarkup::create($length);'
mod "$T_TMP/none" '^8 || ^9' '// format_size($length) was here.
 * format_size() in a doc block.
$a = $o->format_size(1) . Foo::format_size(2) . $format_size(3) . my_format_size(4);
use Drupal\Core\StringTranslation\ByteSizeMarkupLike;'
mod "$T_TMP/high" '^10.3 || ^11' '$size = format_size($length);'

rf() { subject_replacement_floor "$@" | tr '\t' '|'; }
assert_eq "a call of format_size(): 10.2, the port replaces it" "$(rf "$T_TMP/call" 11)" \
  '10.2|the port replaces format_size() (removed in Drupal 11) with \Drupal\Core\StringTranslation\ByteSizeMarkup, which exists only from core 10.2'
assert_eq "an import of ByteSizeMarkup: 10.2, the code uses it" "$(rf "$T_TMP/cls" 11)" \
  '10.2|the code uses \Drupal\Core\StringTranslation\ByteSizeMarkup, which exists only from core 10.2'
assert_eq "  its FQCN too" "$(rf "$T_TMP/fqcn" 11 | cut -d'|' -f1)" "10.2"
assert_eq "comments, a method, a static, a variable, longer names: nothing" "$(rf "$T_TMP/none" 11)" ""
assert_eq "T 10: format_size() is not removed yet, nothing" "$(rf "$T_TMP/call" 10)" ""
assert_eq "  but the class still needs 10.2" "$(rf "$T_TMP/cls" 10 | cut -d'|' -f1)" "10.2"
assert_eq "no PHP file: nothing" "$(mkdir -p "$T_TMP/empty"; rf "$T_TMP/empty" 11)" ""

cs() { t_run env "$@"; }
CS="$T_REPO/scripts/analysis/core-strategy.sh"
cs DRUPILOT_CORE_TARGET_STRATEGY=keep-d10 "$T_SH" "$CS" --subject "$T_TMP/call" --json
assert_eq "keep-d10 with format_size(): '^10.2 || ^11', legs 10.2 and 11" \
  "$(jq -c '[.recommended_core_version_requirement, .verify_cores, .version_bump]' "$T_OUT")" '["^10.2 || ^11",["10.2","11"],"major"]'
assert_eq "  the rationale says why" \
  "$(jq -r '.rationale[] | select(startswith("Drupal 10 floor"))' "$T_OUT")" \
  'Drupal 10 floor 10.2: the port replaces format_size() (removed in Drupal 11) with \Drupal\Core\StringTranslation\ByteSizeMarkup, which exists only from core 10.2.'
cs DRUPILOT_CORE_TARGET_STRATEGY=auto "$T_SH" "$CS" --subject "$T_TMP/cls" --json
assert_eq "keep-current '^10 || ^11' with ByteSizeMarkup: raised to '^10.2 || ^11'" \
  "$(jq -c '[.strategy, .recommended_core_version_requirement]' "$T_OUT")" '["keep-current","^10.2 || ^11"]'
assert_eq "  the rationale says why" \
  "$(jq -r '.rationale[] | select(startswith("The declared floor"))' "$T_OUT")" \
  "The declared floor 10.0 is raised ('^10 || ^11' -> '^10.2 || ^11'): the code uses \\Drupal\\Core\\StringTranslation\\ByteSizeMarkup, which exists only from core 10.2."
cs DRUPILOT_CORE_TARGET_STRATEGY=keep-d10 "$T_SH" "$CS" --subject "$T_TMP/high" --json
assert_eq "a declared '^10.3 || ^11' is never lowered" "$(jq -r '.recommended_core_version_requirement' "$T_OUT")" "^10.3 || ^11"
cs DRUPILOT_CORE_TARGET_STRATEGY=d11-only "$T_SH" "$CS" --subject "$T_TMP/call" --json
assert_eq "d11-only: '^11'" "$(jq -r '.recommended_core_version_requirement' "$T_OUT")" "^11"
cs DRUPILOT_CORE_TARGET_STRATEGY=keep-d10 "$T_SH" "$CS" --subject "$T_TMP/none" --json
assert_eq "without the API: '^10 || ^11' as before" "$(jq -r '.recommended_core_version_requirement' "$T_OUT")" "^10 || ^11"
assert_eq "T 12 keep-previous: its own floor" \
  "$(DRUPILOT_CORE_TARGET_STRATEGY=keep-previous strategy_decide "$T_TMP/call" 12 | jq -c '[.req, .repl_floor]')" '["^11.3 || ^12","10.2"]'

# The draft plan: its range and its backwards-compatible rewrites.
t_run env DRUPILOT_CORE_TARGET_STRATEGY=keep-d10 "$T_SH" "$T_REPO/scripts/analysis/upgrade-path.sh" \
  --subject "$T_TMP/call" --root "$T_TMP/call-d11" --json
assert_eq "upgrade-path: the plan declares '^10.2 || ^11', BC rewrites from 10.2" \
  "$T_RC|$(jq -c '[.range.constraint, .range.floor, .rector.bc]' "$T_OUT")" '0|["^10.2 || ^11","10.2",{"enabled":true,"min_core":"10.2"}]'
t_done
