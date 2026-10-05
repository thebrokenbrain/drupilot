#!/usr/bin/env bash
# core-strategy.sh is a view of the decision the upgrade plan is built from
# (T-M3-05, AR-06, CC-11, ADR 0017): for every T=11 subject the plan resolves
# (the fixtures, every monorepo module, and copies with each strategy), the
# range core-strategy recommends is the plan's range.constraint and its 0.9
# strategy name is the plan's resolved_strategy (keep-d10 = keep-previous,
# d11-only = target-only, keep-current = keep-current). A refused plan (an
# assertion core-strategy does not make, e.g. php_floor_signals' L above P)
# is not compared. The data is the snapshot tests/golden/plans pins.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/plans/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
F="$T_REPO/tests/fixtures"; S="$T_TMP/s"; mkdir -p "$S"
for d in legacy_widgets keep_current d11_php_only d9_module d8_legacy; do cp -R "$F/$d" "$S/$d"; done
cp -R "$F/legacy_widgets/modules/legacy_widgets_extra" "$S/legacy_widgets_extra"
for m in "$F"/monorepo/web/modules/custom/*/; do m="${m%/}"; cp -R "$m" "$S/${m##*/}"; done
cp -R "$T_REPO/tests/baseline/inputs/php_floor_signals" "$S/php_floor_signals"

compared=0; refused=0
for subj in "$S"/*/; do
  subj="${subj%/}"; name="${subj##*/}"
  for strat in auto keep-d10 d11-only; do
    cs="$(DRUPILOT_CORE_TARGET_STRATEGY="$strat" "$T_SH" "$T_REPO/scripts/analysis/core-strategy.sh" --subject "$subj" --json 2> /dev/null < /dev/null)"
    rc=0
    plan="$(DRUPILOT_CORE_TARGET_STRATEGY="$strat" "$T_SH" "$T_REPO/scripts/analysis/upgrade-path.sh" --subject "$subj" --json 2> /dev/null < /dev/null)" || rc=$?
    if [[ "$rc" == "2" ]]; then refused=$((refused + 1)); continue; fi
    assert_eq "$name ($strat): the plan resolves" "$rc" "0"
    assert_eq "$name ($strat): the same range" \
      "$(printf '%s' "$cs" | jq -r .recommended_core_version_requirement)" "$(printf '%s' "$plan" | jq -r .range.constraint)"
    assert_eq "$name ($strat): the same resolved strategy" \
      "$(printf '%s' "$cs" | jq -r '.strategy | if . == "keep-d10" then "keep-previous" elif . == "d11-only" then "target-only" else . end')" \
      "$(printf '%s' "$plan" | jq -r .range.resolved_strategy)"
    compared=$((compared + 1))
  done
done
assert_eq "most cases compared (refused: $refused)" "$([[ "$compared" -ge 30 ]] && echo yes)" "yes"
assert_eq "php_floor_signals is refused by the plan, not by core-strategy" \
  "$("$T_SH" "$T_REPO/scripts/analysis/core-strategy.sh" --subject "$S/php_floor_signals" --json > /dev/null 2>&1; echo $?)|$("$T_SH" "$T_REPO/scripts/analysis/upgrade-path.sh" --subject "$S/php_floor_signals" --json > /dev/null 2>&1; echo $?)" "0|2"
t_done
