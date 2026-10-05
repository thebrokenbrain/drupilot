#!/usr/bin/env bash
# upgrade-path.sh --freeze and the frozen plan (T-M3-04, ADR 0018): the plan
# is frozen in the root's lock only on request, only after exit 0; a later
# run reuses it in deterministic mode (printed as frozen, nothing written)
# while the request matches and its phase is high enough, and resolves afresh
# otherwise (DRUPILOT_DETERMINISTIC=false always, INV8; another subject's
# plan is stale); the same plan always freezes to the same hash; a final plan
# over a frozen one may not change P (G16: final-changes-frozen, nothing
# written) but may add hops; a refusal never freezes. The data is the snapshot tests/golden/plans pins.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/plans/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
UP="$T_REPO/scripts/analysis/upgrade-path.sh"
B="$T_TMP/bed"; mkdir -p "$B/web/core/lib" "$B/web/modules/custom"
printf '{"require": {"drupal/core-recommended": "^11"}}\n' > "$B/composer.json"
printf '<?php\n' > "$B/web/core/lib/Drupal.php"
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$B/web/modules/custom/legacy_widgets"
cp -R "$T_REPO/tests/fixtures/d9_module" "$B/web/modules/custom/d9_module"
LW="$B/web/modules/custom/legacy_widgets"
L="$(lock_path "$B")"
up() { t_run "$T_SH" "$UP" "$@" --json; }

up --subject "$T_REPO/tests/fixtures/legacy_widgets" --freeze
assert_eq "--freeze without a root: exit 1" "$T_RC|$(t_out)" "1|"
assert_tree_unchanged "a plan without --freeze writes nothing" "$HOME" "$T_SH" "$UP" --subject "$LW" --json
assert_eq "  (exit 0)" "$T_RC" "0"

up --subject "$LW" --freeze
assert_eq "draft --freeze: exit 0" "$T_RC" "0"
P1="$(t_out)"
assert_eq "the lock holds the plan as printed" "$(plan_frozen "$B")" "$P1"
assert_eq "  its phase and hash" "$(jq -c '[.upgrade_plan_phase, .upgrade_plan_hash == "'"$(printf '%s' "$P1" | canon_json_hashable | json_hash)"'"]' "$L")" '["draft",true]'
H1="$(jq -r .upgrade_plan_hash "$L")"
assert_eq "plan_get reads it" "$(plan_get .php.final "$B")" "8.3"

# Reuse: mark the frozen plan, then ask again.
jq '.upgrade_plan.rector.php_level = "MARK"' "$L" > "$T_TMP/l.json" && cp "$T_TMP/l.json" "$L"
assert_tree_unchanged "a matching request reuses the frozen plan, writing nothing" "$HOME" "$T_SH" "$UP" --subject "$LW" --json
assert_eq "  printed as frozen" "$(jq -r .rector.php_level "$T_OUT")" "MARK"
up --subject "$LW" --php 8.4
assert_eq "another P resolves afresh" "$T_RC|$(jq -r .rector.php_level "$T_OUT")" "0|PHP_81"
t_run env DRUPILOT_DETERMINISTIC=false "$T_SH" "$UP" --subject "$LW" --json
assert_eq "DRUPILOT_DETERMINISTIC=false resolves afresh (INV8)" "$T_RC|$(jq -r .rector.php_level "$T_OUT")" "0|PHP_81"
up --subject "$B/web/modules/custom/d9_module"
assert_eq "another subject's frozen plan is stale" "$T_RC|$(jq -c '[.subject.machine_name, .rector.php_level]' "$T_OUT")" '0|["d9_module","PHP_81"]'
t_run env DRUPILOT_DETERMINISTIC=false "$T_SH" "$UP" --subject "$LW" --freeze --json
assert_eq "re-freezing the same plan gives the same hash" "$(jq -r .upgrade_plan_hash "$L")" "$H1"

# The final phase: a draft is not enough to reuse; the same values pass.
up --subject "$LW" --phase final --freeze
assert_eq "final over the draft: exit 0, frozen as final" "$T_RC|$(jq -r .upgrade_plan_phase "$L")" "0|final"
up --subject "$LW" --phase draft
assert_eq "a draft request reuses the final plan" "$T_RC|$(jq -r .meta.phase "$T_OUT")" "0|final"

# G16: a final plan may not change the frozen P.
cp "$L" "$T_TMP/before.json"
up --subject "$LW" --phase final --php 8.4 --freeze
assert_eq "G16: final with another P is refused" "$T_RC|$(jq -r .code "$T_OUT")" "2|final-changes-frozen"
assert_eq "  its choices: keep the frozen 8.3 or re-run the setup" \
  "$(jq -c '[.choices[] | [.id, .tab, .set]]' "$T_OUT")" '[["keep-frozen",null,{"DRUPILOT_PHP_TARGET":"8.3"}],["re-setup","PHP_TARGET",{}]]'
assert_file_eq "  and the lock is untouched" "$L" "$T_TMP/before.json"

# A final plan over a frozen draft may add hops (a lower S from the
# analyzer); a frozen final plan is reused, the analyzer output included.
t_run env DRUPILOT_DETERMINISTIC=false "$T_SH" "$UP" --subject "$LW" --freeze --json
assert_eq "a fresh draft replaces the final plan" "$T_RC|$(jq -r .upgrade_plan_phase "$L")" "0|draft"
printf '%s' '{"files":{"x.php":{"messages":[{"line":3,"message":"Call to deprecated function x():\nin drupal:8.5.0 and is removed from drupal:9.0.0."}]}}}' > "$T_TMP/p.json"
up --subject "$LW" --phase final --phpstan "$T_TMP/p.json" --freeze
assert_eq "a final plan that adds hops is fine" "$T_RC|$(jq -c .upgrade_plan.hops "$L")" '0|["8-9","9-10","10-11"]'
cp "$L" "$T_TMP/before.json"
up --subject "$LW" --target 12 --phase final --freeze
assert_eq "a refusal (T 12 without the opt-in) freezes nothing" "$T_RC|$(cmp -s "$L" "$T_TMP/before.json" && echo same)" "2|same"
t_done
