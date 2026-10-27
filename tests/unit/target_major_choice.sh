#!/usr/bin/env bash
# The TARGET_MAJOR tab (T-M3-15, D30): choice.sh pre-answers it from
# DRUPILOT_CHOICE_TARGET_MAJOR (11 or 12; anything else is ignored with a
# warning and the tab is asked), and a draft plan can be frozen under a loose
# subject's future test-bed root that does not exist yet (ADR 0018, item 7),
# where plan_get then reads it.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/plans/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$T_TMP/legacy_widgets"
CH="$T_REPO/scripts/env/choice.sh"

t_run env DRUPILOT_CHOICE_TARGET_MAJOR=12 "$T_SH" "$CH" --key TARGET_MAJOR --subject "$T_TMP/legacy_widgets" --json
assert_eq "a pre-answered 12" "$T_RC|$(jq -c '[.value, .valid, .header, .persist]' "$T_OUT")" '0|["12",true,"Target major",[{"key":"DRUPILOT_TARGET_MAJOR","value":"12"}]]'
t_run env DRUPILOT_CHOICE_TARGET_MAJOR=13 "$T_SH" "$CH" --key TARGET_MAJOR --subject "$T_TMP/legacy_widgets" --json
assert_eq "13 is not an option: asked" "$T_RC|$(jq -c '[.value, .valid]' "$T_OUT")" '0|[null,false]'
assert_match "  with a warning" "$(t_err)" "allowed: 11, 12"
t_run "$T_SH" "$CH" --key TARGET_MAJOR --subject "$T_TMP/legacy_widgets" --json
assert_eq "not pre-answered: asked, default 11" "$(jq -c '[.value, .default]' "$T_OUT")" '[null,"11"]'

FUT="$T_TMP/legacy_widgets-d11"
t_run "$T_SH" "$T_REPO/scripts/analysis/upgrade-path.sh" --subject "$T_TMP/legacy_widgets" --root "$FUT" --freeze --json
assert_eq "a draft frozen under a root that does not exist yet" "$T_RC|$([[ -e "$FUT" ]] && echo created || echo absent)" "0|absent"
assert_eq "  plan_get reads it under that root" "$(plan_get .range.constraint "$FUT")" "^10 || ^11"
t_run "$T_SH" "$T_REPO/scripts/analysis/upgrade-path.sh" --subject "$T_TMP/legacy_widgets" --root "relative/nope" --json
assert_eq "a relative root that does not exist: exit 1" "$T_RC" "1"
t_done
