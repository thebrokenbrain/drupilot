#!/usr/bin/env bash
# strategy_decide for any target major (T-M3-05, AR-06, ADR 0017): the
# ranges come from config/targets/<T>.json (T 12: '^11.3 || ^12' / '^12'),
# P is the target's own default unless one is set (8.3 for 11, 8.5 for 12),
# auto keeps the previous major only while its status is not eol (X15: a
# data commit flips it, keep-current and an explicit strategy are not
# affected), and a T that is no major is refused. T=11's 0.9 output is
# pinned by core_strategy_matrix.sh. The data is the snapshot the T=11
# core-target golden is pinned to (and a copy of it with Drupal 10 eol).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
SNAP="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/core-strategy/golden.json")"
export DRUPILOT_VERSION_DATA_DIR="$SNAP"
F="$T_REPO/tests/fixtures"
mkdir -p "$T_TMP/m"
printf 'name: M\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$T_TMP/m/m.info.yml"
printf '{"name": "drupal/m", "require": {"php": ">=8.1"}}\n' > "$T_TMP/m/composer.json"
sd() { strategy_decide "$@" | jq -c '{v1: .resolved_v1, req, php: .php_target, require_php, tc: .target_compatible}'; }

assert_eq "T 11: keep-previous at 8.3" "$(sd "$F/legacy_widgets" 11)" '{"v1":"keep-previous","req":"^10 || ^11","php":"8.3","require_php":">=8.3","tc":null}'
assert_eq "T 12: ^10 || ^11 keeps 11.3, at 12's 8.5" "$(sd "$T_TMP/m" 12)" '{"v1":"keep-previous","req":"^11.3 || ^12","php":"8.5","require_php":">=8.5","tc":null}'
assert_eq "T 12: code needing 8.4 is compatible with 8.5" \
  "$(DRUPILOT_DETECTED_PHP_FLOOR=8.4 sd "$T_TMP/m" 12)" '{"v1":"keep-previous","req":"^11.3 || ^12","php":"8.5","require_php":">=8.4","tc":true}'
assert_eq "T 12: an explicit PHP target wins" "$(DRUPILOT_PHP_TARGET=8.4 sd "$T_TMP/m" 12 | jq -r .php)" "8.4"
assert_eq "T 12: d11-only (target-only) is ^12" "$(DRUPILOT_CORE_TARGET_STRATEGY=d11-only sd "$T_TMP/m" 12 | jq -r .req)" "^12"
assert_eq "the 1.0 names read as the 0.9 ones (CC-07): target-only is ^12" "$(DRUPILOT_CORE_TARGET_STRATEGY=target-only sd "$T_TMP/m" 12 | jq -r .req)" "^12"
assert_eq "  an unknown name is auto, as in 0.9" "$(DRUPILOT_CORE_TARGET_STRATEGY=bogus sd "$T_TMP/m" 12 | jq -r .req)" "^11.3 || ^12"
assert_eq "T 12: keep_current's ^10.3 || ^11 || ^12 is kept" "$(sd "$F/keep_current" 12 | jq -c '[.v1, .req]')" '["keep-current","^10.3 || ^11 || ^12"]'
assert_eq "T abc: refused" "$(strategy_decide "$T_TMP/m" abc; echo "rc=$?")" "{}
rc=1"

# Drupal 10 end-of-life (a copy of the snapshot with targets/10.json eol).
cp -R "$SNAP" "$T_TMP/eol"
jq '.status = "eol"' "$SNAP/targets/10.json" > "$T_TMP/eol/targets/10.json"
export DRUPILOT_VERSION_DATA_DIR="$T_TMP/eol"
assert_eq "D10 eol: auto declares ^11" "$(sd "$F/legacy_widgets" 11 | jq -c '[.v1, .req]')" '["target-only","^11"]'
assert_eq "D10 eol: a kept ^10.3 || ^11 || ^12 stays" "$(sd "$F/keep_current" 11 | jq -c '[.v1, .req]')" '["keep-current","^10.3 || ^11 || ^12"]'
assert_eq "D10 eol: an explicit keep-previous still keeps D10" \
  "$(DRUPILOT_CORE_TARGET_STRATEGY=keep-d10 sd "$F/legacy_widgets" 11 | jq -c '[.v1, .req]')" '["keep-previous","^10 || ^11"]'
export DRUPILOT_VERSION_DATA_DIR="$SNAP"
assert_eq "D10 supported again: auto keeps it" "$(sd "$F/legacy_widgets" 11 | jq -r .v1)" "keep-previous"
t_done
