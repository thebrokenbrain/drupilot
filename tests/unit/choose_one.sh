#!/usr/bin/env bash
# choose_one pre-answers (CC-29): DRUPILOT_CHOICE_<KEY> wins when it is one of
# the options; an invalid value is ignored with a warning; a fork the registry
# marks preanswer:false (PUSH) is never pre-answered; without a terminal the
# first option (the default) is chosen.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
assert_eq "a valid pre-answer" "$(DRUPILOT_CHOICE_CLEAN_LEVEL=ddev choose_one CLEAN_LEVEL Level vendor ddev workspace < /dev/null 2>/dev/null)" "ddev"
assert_eq "an invalid pre-answer falls back to the default" "$(DRUPILOT_CHOICE_CLEAN_LEVEL=bogus choose_one CLEAN_LEVEL Level vendor ddev workspace < /dev/null 2>/dev/null)" "vendor"
assert_match "... with a warning" "$(DRUPILOT_CHOICE_CLEAN_LEVEL=bogus choose_one CLEAN_LEVEL Level vendor ddev workspace < /dev/null 2>&1 >/dev/null)" "Ignoring DRUPILOT_CHOICE_CLEAN_LEVEL='bogus'"
assert_eq "PUSH is never pre-answered" "$(DRUPILOT_CHOICE_PUSH=push choose_one PUSH Push cancel push < /dev/null 2>/dev/null)" "cancel"
assert_eq "no terminal: the default" "$(choose_one CLEAN_LEVEL Level vendor ddev workspace < /dev/null 2>/dev/null)" "vendor"
assert_eq "value|label options print the value" "$(DRUPILOT_CHOICE_CLEAN_LEVEL=workspace choose_one CLEAN_LEVEL Level 'vendor|Vendor only' 'workspace|Everything' < /dev/null 2>/dev/null)" "workspace"
t_done
