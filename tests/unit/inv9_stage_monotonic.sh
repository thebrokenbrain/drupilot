#!/usr/bin/env bash
# INV9 (CC-20): the recorded stage never goes backwards without
# DRUPILOT_STATE_FORCE.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
m="$T_TMP/fx/legacy_widgets"; mkdir -p "$T_TMP/fx"; cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$m"
st() { "$T_SH" "$T_REPO/scripts/env/state.sh" "$@" < /dev/null 2>/dev/null; }
st record --subject "$m" --stage tested --json > /dev/null
assert_eq "tested is recorded" "$(st show --subject "$m" --no-next --json | jq -r .stage)" "tested"
st record --subject "$m" --stage ported --json > /dev/null || true
assert_eq "a lower stage does not lower it" "$(st show --subject "$m" --no-next --json | jq -r .stage)" "tested"
DRUPILOT_STATE_FORCE=true st record --subject "$m" --stage ported --json > /dev/null || true
assert_eq "DRUPILOT_STATE_FORCE lowers it" "$(st show --subject "$m" --no-next --json | jq -r .stage)" "ported"
st record --subject "$m" --stage refactored --json > /dev/null
assert_eq "a higher stage raises it" "$(st show --subject "$m" --no-next --json | jq -r .stage)" "refactored"
t_done
