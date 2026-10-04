#!/usr/bin/env bash
# version_ge: lenient numeric comparison; a pre-release suffix is ignored, so
# 1.0.0-alpha.1 compares equal to 1.0.0 (why plugin versions never use it).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
ge() { if version_ge "$1" "$2"; then echo yes; else echo no; fi; }
assert_eq "11.3 >= 11.2" "$(ge 11.3 11.2)" "yes"
assert_eq "11.10 >= 11.9 (numeric, not lexical)" "$(ge 11.10 11.9)" "yes"
assert_eq "2.2.2 >= 2.2.16 is false" "$(ge 2.2.2 2.2.16)" "no"
assert_eq "8.4 >= 8.4.0" "$(ge 8.4 8.4.0)" "yes"
assert_eq "8.4.0 >= 8.4" "$(ge 8.4.0 8.4)" "yes"
assert_eq "v-prefix ignored: v1.2 >= 1.1" "$(ge v1.2 1.1)" "yes"
assert_eq "pre-release suffix ignored: 1.0.0-alpha.1 >= 1.0.0" "$(ge 1.0.0-alpha.1 1.0.0)" "yes"
assert_eq "pre-release suffix ignored: 1.0.0 >= 1.0.0-rc.1" "$(ge 1.0.0 1.0.0-rc.1)" "yes"
assert_eq "empty compares as 0" "$(ge '' 0.0.1)" "no"
t_done
