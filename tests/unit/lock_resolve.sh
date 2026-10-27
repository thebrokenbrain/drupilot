#!/usr/bin/env bash
# lock_resolve (INV8): deterministic mode reuses the frozen value; with
# DRUPILOT_DETERMINISTIC=false it resolves fresh and refreshes the lock; an
# empty resolution is an error and freezes nothing.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
export DRUPILOT_HOME="$T_TMP/dh"
mkdir -p "$T_TMP/root"; export DRUPILOT_PROJECT_DIR="$T_TMP/root"
assert_eq "first resolution is fresh" "$(lock_resolve .toolchain.rector echo 2.5.2)" "2.5.2"
assert_eq "it is frozen in the lock" "$(lock_get .toolchain.rector none)" "2.5.2"
assert_eq "deterministic: the frozen value is reused" "$(lock_resolve .toolchain.rector echo 2.6.1)" "2.5.2"
assert_eq "not deterministic: resolved fresh" "$(DRUPILOT_DETERMINISTIC=false lock_resolve .toolchain.rector echo 2.6.1)" "2.6.1"
assert_eq "... and the lock refreshed" "$(lock_get .toolchain.rector none)" "2.6.1"
assert_exit "an empty resolution fails" 1 lock_resolve .toolchain.phpstan printf ''
assert_eq "... and freezes nothing" "$(lock_get .toolchain.phpstan none)" "none"
assert_eq "the lock names the drupilot that wrote it" "$(lock_get .drupilot_version none)" "$(plugin_version)"
t_done
