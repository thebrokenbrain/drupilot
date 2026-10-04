#!/usr/bin/env bash
# config_get precedence (CC-06): env > .drupilot.json > config/defaults.json >
# the caller's default; a JSON false/0 in .drupilot.json is kept, not skipped.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
root="$T_TMP/root"; mkdir -p "$root"
export DRUPILOT_PROJECT_DIR="$root"
assert_eq "defaults.json when nothing else is set" "$(config_get DRUPILOT_PHP_TARGET x)" "8.3"
assert_eq "caller default for an unknown key" "$(config_get DRUPILOT_NO_SUCH_KEY fallback)" "fallback"
printf '{"DRUPILOT_PHP_TARGET":"8.4","DRUPILOT_DETERMINISTIC":false,"DRUPILOT_PHPSTAN_LEVEL":0}\n' > "$root/.drupilot.json"
assert_eq ".drupilot.json beats defaults.json" "$(config_get DRUPILOT_PHP_TARGET x)" "8.4"
assert_eq ".drupilot.json keeps a JSON false" "$(config_get DRUPILOT_DETERMINISTIC true)" "false"
assert_eq ".drupilot.json keeps a JSON 0" "$(config_get DRUPILOT_PHPSTAN_LEVEL 2)" "0"
assert_eq "the environment beats .drupilot.json" "$(DRUPILOT_PHP_TARGET=8.5 config_get DRUPILOT_PHP_TARGET x)" "8.5"
assert_eq "an empty environment value falls through" "$(DRUPILOT_PHP_TARGET='' config_get DRUPILOT_PHP_TARGET x)" "8.4"
t_done
