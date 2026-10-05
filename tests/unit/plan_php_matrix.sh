#!/usr/bin/env bash
# The upgrade plan's php block, test matrix and CI flags (T-M3-03, AR-06,
# ADR 0017): plan_php_block (window L..P, require_php only when the range
# keeps a previous major, the PHP_VERSION_ID bounds), php_rector_level,
# plan_test_matrix (CURRENT, PHP_LOW when the bed supports a PHP of the
# window below P, PREVIOUS_MAJOR when the range keeps a released minor of
# T-1) and plan_ci_flags. The data is the snapshot the T=11 core-target golden
# is pinned to.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/core-strategy/golden.json")"
export DRUPILOT_VERSION_DATA_DIR

# --- plan_php_block / php_rector_level ----------------------------------------
assert_eq "8.1..8.3 keeping a previous major" "$(plan_php_block 8.1 8.3 true)" \
  '{"floor":"8.1","final":"8.3","window":["8.1","8.2","8.3"],"require_php":">=8.1","phpstan_phpversion":{"min":80100,"max":80300},"phpcompat_testversion":"8.1-8.3"}'
assert_eq "8.3..8.3 on the target major only: no require_php" "$(plan_php_block 8.3 8.3 false)" \
  '{"floor":"8.3","final":"8.3","window":["8.3"],"require_php":null,"phpstan_phpversion":{"min":80300,"max":80300},"phpcompat_testversion":"8.3-8.3"}'
assert_eq "8.3..8.5" "$(plan_php_block 8.3 8.5 true | jq -c '[.window, .require_php, .phpstan_phpversion.max]')" '[["8.3","8.4","8.5"],">=8.3",80500]'
assert_eq "a floor above the final: an empty window, not a refusal" "$(plan_php_block 8.4 8.3 false | jq -c .window)" "[]"
assert_exit "a PHP the data does not know" 1 plan_php_block 8.1 9.9 true
assert_exit "no floor" 1 plan_php_block '' 8.3 true
assert_eq "php_rector_level 8.1" "$(php_rector_level 8.1)" "PHP_81"
assert_eq "php_rector_level 8.5" "$(php_rector_level 8.5)" "PHP_85"
assert_eq "php_rector_level of an unknown PHP" "$(php_rector_level 9.9)" ""

# --- plan_test_matrix / plan_ci_flags -----------------------------------------
cur() { printf '{"leg":"CURRENT","core":"%s","php":"%s","mode":"run"}' "$1" "$2"; }
low() { printf '{"leg":"PHP_LOW","core":"%s","php":"%s","mode":"run"}' "$1" "$2"; }
prv() { printf '{"leg":"PREVIOUS_MAJOR","core":"%s","php":"%s","mode":"static"}' "$1" "$2"; }
m="$(plan_test_matrix 11.4.8 8.3 8.1 '^10 || ^11' 11)"
assert_eq "^10 || ^11 at 8.3 (L 8.1): CURRENT + PREVIOUS_MAJOR 10.6@8.1" "$m" "[$(cur 11.4.8 8.3),$(prv 10.6 8.1)]"
assert_eq "  ci flags" "$(plan_ci_flags "$m" 8.3 11.4)" '{"OPT_IN_TEST_PREVIOUS_MAJOR":1,"OPT_IN_TEST_MAX_PHP":0}'
m="$(plan_test_matrix 11.4.8 8.4 8.1 '^10 || ^11' 11)"
assert_eq "^10 || ^11 at 8.4: PHP_LOW 8.3 (11.4 runs no 8.1/8.2)" "$m" "[$(cur 11.4.8 8.4),$(low 11.4.8 8.3),$(prv 10.6 8.1)]"
assert_eq "  ci flags: 8.4 is not 11.4's highest PHP" "$(plan_ci_flags "$m" 8.4 11.4)" '{"OPT_IN_TEST_PREVIOUS_MAJOR":1,"OPT_IN_TEST_MAX_PHP":0}'
m="$(plan_test_matrix 11.4.8 8.3 8.3 '^11' 11)"
assert_eq "^11 at 8.3: CURRENT only" "$m" "[$(cur 11.4.8 8.3)]"
assert_eq "  ci flags" "$(plan_ci_flags "$m" 8.3 11.4)" '{"OPT_IN_TEST_PREVIOUS_MAJOR":0,"OPT_IN_TEST_MAX_PHP":0}'
m="$(plan_test_matrix 11.4.8 8.5 8.3 '^11' 11)"
assert_eq "^11 at 8.5 (L 8.3): PHP_LOW 8.3" "$m" "[$(cur 11.4.8 8.5),$(low 11.4.8 8.3)]"
assert_eq "  ci flags: 8.5 is 11.4's highest PHP" "$(plan_ci_flags "$m" 8.5 11.4)" '{"OPT_IN_TEST_PREVIOUS_MAJOR":0,"OPT_IN_TEST_MAX_PHP":1}'
m="$(plan_test_matrix 12.0.0-beta1 8.5 8.3 '^11.3 || ^12' 12)"
assert_eq "T=12 ^11.3 || ^12: no PHP_LOW (12.0 runs 8.5 only), PREVIOUS_MAJOR 11.4@8.3" "$m" "[$(cur 12.0.0-beta1 8.5),$(prv 11.4 8.3)]"
assert_eq "  ci flags" "$(plan_ci_flags "$m" 8.5 12.0)" '{"OPT_IN_TEST_PREVIOUS_MAJOR":1,"OPT_IN_TEST_MAX_PHP":0}'
m="$(plan_test_matrix 11.4.8 8.3 8.1 '^10.3 || ^11 || ^12' 11)"
assert_eq "a kept ^10.3 || ^11 || ^12: PREVIOUS_MAJOR 10.6" "$m" "[$(cur 11.4.8 8.3),$(prv 10.6 8.1)]"
assert_eq "PREVIOUS_MAJOR runs at the minor's php_min when L is lower" \
  "$(plan_test_matrix 12.0.0-beta1 8.5 8.1 '^11 || ^12' 12 | jq -c '.[-1]')" "$(prv 11.4 8.3)"
assert_eq "PREVIOUS_MAJOR: the newest minor the range admits" \
  "$(plan_test_matrix 11.4.8 8.3 8.1 '>=10.2 <10.5 || ^11' 11 | jq -c '.[-1]')" "$(prv 10.4 8.1)"
assert_eq "a bed whose PHP list is unknown: no PHP_LOW" \
  "$(plan_test_matrix 11.0.13 8.4 8.3 '^11' 11 | jq -c 'map(.leg)')" '["CURRENT"]'
assert_eq "ci flags of an unknown M" "$(plan_ci_flags "[$(cur 11.4.8 8.5),$(low 11.4.8 8.3)]" 8.5 '')" '{"OPT_IN_TEST_PREVIOUS_MAJOR":0,"OPT_IN_TEST_MAX_PHP":0}'
t_done
