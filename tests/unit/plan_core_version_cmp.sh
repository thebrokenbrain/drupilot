#!/usr/bin/env bash
# core_version_cmp (T-M2-06, AR-04): 0 equal, 1 lower, 2 higher, 3 not a
# version. Pre-releases order dev < alpha < beta < rc < the release, but a
# version given only to the minor, or with a wildcard, stands for its whole
# branch: 12.0.0-beta1 == 12.0 (the <= test-bed filter of the Rector sets).
# version_ge would call 12.0.0-beta1 == 12.0.0, which is why it is not used.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
c() { local rc=0; core_version_cmp "$1" "$2" || rc=$?; printf '%s' "$rc"; }
assert_eq "12.0.0-beta1 == 12.0 (the roadmap acceptance)" "$(c 12.0.0-beta1 12.0)" "0"
assert_eq "12.0 == 12.0.0-beta1" "$(c 12.0 12.0.0-beta1)" "0"
assert_eq "12.0.0-beta1 < 12.0.0" "$(c 12.0.0-beta1 12.0.0)" "1"
assert_eq "12.0.0 > 12.0.0-rc1" "$(c 12.0.0 12.0.0-rc1)" "2"
assert_eq "alpha < beta" "$(c 12.0.0-alpha1 12.0.0-beta1)" "1"
assert_eq "beta < rc" "$(c 12.0.0-beta2 12.0.0-rc1)" "1"
assert_eq "dev < alpha" "$(c 12.0.0-dev 12.0.0-alpha1)" "1"
assert_eq "beta1 < beta2" "$(c 12.0.0-beta1 12.0.0-beta2)" "1"
assert_eq "RC is read case-insensitively" "$(c 12.0.0-RC1 12.0.0-rc1)" "0"
assert_eq "12.0.x-dev == 12.0 (a branch)" "$(c 12.0.x-dev 12.0)" "0"
assert_eq "11.x == 11.4.8 (a branch)" "$(c 11.x 11.4.8)" "0"
assert_eq "11.4.8 < 12.0.0-beta1" "$(c 11.4.8 12.0.0-beta1)" "1"
assert_eq "11.10 > 11.9 (numeric)" "$(c 11.10 11.9)" "2"
assert_eq "12.1 > 12.0.0-beta1" "$(c 12.1 12.0.0-beta1)" "2"
assert_eq "v-prefix: v11.3.0 == 11.3" "$(c v11.3.0 11.3)" "0"
assert_eq "equal releases" "$(c 11.4.8 11.4.8)" "0"
assert_eq "not a version" "$(c foo 12.0)" "3"
assert_eq "an unknown suffix" "$(c 12.0.0-gamma1 12.0.0)" "3"
assert_eq "empty" "$(c '' 12.0)" "3"
t_done
