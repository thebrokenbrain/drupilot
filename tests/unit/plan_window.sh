#!/usr/bin/env bash
# php_window and php_bounds_for_range (T-M2-06): the PHP window of a declared
# core range, read from config/targets and config/php. The bounds reproduce
# the window table of the 1.0 plan (02 §A1): ^10 || ^11 and ^10.3 || ^11 ->
# 8.1..8.5, ^11 -> 8.3..8.5, ^11.3 || ^12 -> 8.3..8.5, ^12 -> 8.5..8.5.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
assert_eq "^10 || ^11" "$(php_bounds_for_range '^10 || ^11')" "8.1 8.5"
assert_eq "^10.3 || ^11" "$(php_bounds_for_range '^10.3 || ^11')" "8.1 8.5"
assert_eq "^11" "$(php_bounds_for_range '^11')" "8.3 8.5"
assert_eq "^11.3 || ^12" "$(php_bounds_for_range '^11.3 || ^12')" "8.3 8.5"
assert_eq "^12" "$(php_bounds_for_range '^12')" "8.5 8.5"
assert_eq "^11.1 (no 8.5 below 11.3, but 11.3 is admitted)" "$(php_bounds_for_range '^11.1')" "8.3 8.5"
assert_eq "a single bar also splits" "$(php_bounds_for_range '^10.4 | ^11')" "8.1 8.5"
assert_eq "an unsupported form gives nothing" "$(php_bounds_for_range '>=10.3')" ""
assert_eq "a major without data gives nothing" "$(php_bounds_for_range '^9')" ""
assert_eq "a range with one major without data gives nothing, not a guess" "$(php_bounds_for_range '^9 || ^10')" ""
assert_eq "php_window 8.1 8.5" "$(php_window 8.1 8.5)" "8.1 8.2 8.3 8.4 8.5"
assert_eq "php_window 8.3 8.3" "$(php_window 8.3 8.3)" "8.3"
assert_eq "php_window floor above final" "$(php_window 8.5 8.3)" ""
assert_eq "php_window takes minors only" "$(php_window 8.1.6 8.5)" ""
d="$T_TMP/data"; mkdir -p "$d"; cp -R "$T_REPO/config/targets" "$T_REPO/config/php" "$d/"
jq '.minors["11.4"].verified = false | .minors["11.3"].verified = false' "$T_REPO/config/targets/11.json" > "$d/targets/11.json"
assert_eq "unverified minors are left out" "$(DRUPILOT_VERSION_DATA_DIR="$d" php_bounds_for_range '^11')" "8.3 8.4"
assert_eq "target_get reads a target" "$(target_get 12 .status)" "pre-release"
assert_eq "target_get: null prints nothing" "$(target_get 12 .released.actual)" ""
assert_eq "target_get: no such major" "$(target_get 9 .status)" ""
t_done
