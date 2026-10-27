#!/usr/bin/env bash
# upgrade-path.sh --freeze and the frozen plan (T-M3-04, ADR 0018): the plan
# is frozen in the root's lock only on request, only after exit 0; a later
# run reuses it in deterministic mode (printed as frozen, nothing written)
# while the request matches and its phase is high enough, and resolves afresh
# otherwise (DRUPILOT_DETERMINISTIC=false always, INV8; another subject's
# plan is stale); the same plan always freezes to the same hash; a final plan
# over a frozen one may not change P (G16: final-changes-frozen, nothing
# written) but may add hops; a refusal never freezes. A data refresh does
# not make the plan stale (P, bed core and toolchain cell stay the frozen
# ones), a core the lock records later re-plans the draft, a final over a
# frozen final may drop hops, DRUPILOT_DETERMINISTIC=false skips the guard,
# and a loose subject's draft freezes under its future root. The data is the snapshot tests/golden/plans pins.
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

# Over a frozen final plan, a later final may drop hops (the code was ported).
printf '{"files":{}}' > "$T_TMP/clean.json"
up --subject "$LW" --phase final --phpstan "$T_TMP/clean.json"
assert_eq "a final with a clean analyzer over the frozen final: reused (frozen evidence)" "$T_RC|$(jq -c .hops "$T_OUT")" '0|["8-9","9-10","10-11"]'
t_run env DRUPILOT_DETERMINISTIC=false "$T_SH" "$UP" --subject "$LW" --phase final --phpstan "$T_TMP/clean.json" --php 8.4 --freeze --json
assert_eq "DRUPILOT_DETERMINISTIC=false: re-resolved, no guard, refrozen" "$T_RC|$(jq -c '[.upgrade_plan.hops, .upgrade_plan.php.final]' "$L")" '0|[["10-11"],"8.4"]'

# A data refresh does not make the plan stale: a P nobody asked for stays the
# frozen one, so do the bed core and the toolchain cell.
t_run env DRUPILOT_DETERMINISTIC=false "$T_SH" "$UP" --subject "$LW" --freeze --json
cp -R "$DRUPILOT_VERSION_DATA_DIR" "$T_TMP/data2"
jq '.php_defaults.env = "8.4" | .toolchain_cell = "11b" | .minors["11.4"].latest = "11.4.9"' "$DRUPILOT_VERSION_DATA_DIR/targets/11.json" > "$T_TMP/data2/targets/11.json"
H2="$(jq -r .upgrade_plan_hash "$L")"
t_run env DRUPILOT_VERSION_DATA_DIR="$T_TMP/data2" "$T_SH" "$UP" --subject "$LW" --freeze --json
assert_eq "new data, the same request: the frozen draft is reused" "$T_RC|$(jq -r .upgrade_plan_hash "$L")" "0|$H2"
t_run env DRUPILOT_VERSION_DATA_DIR="$T_TMP/data2" "$T_SH" "$UP" --subject "$LW" --phase final --freeze --json
assert_eq "  and the final keeps its P, bed core and toolchain cell" \
  "$T_RC|$(jq -c '[.upgrade_plan_phase, .upgrade_plan.php.final, .upgrade_plan.target.bed_core, .upgrade_plan.toolchain_cell]' "$L")" '0|["final","8.3","11.4.8","11"]'

# A core recorded by the setup after the draft: the draft re-plans on it.
t_run env DRUPILOT_DETERMINISTIC=false "$T_SH" "$UP" --subject "$LW" --freeze --json
DRUPILOT_PROJECT_DIR="$B" lock_set .drupal.core 11.3.9
up --subject "$LW" --freeze
assert_eq "the lock's 11.3.9: the draft re-plans on it" "$T_RC|$(jq -r .upgrade_plan.target.bed_core "$L")" "0|11.3.9"
up --subject "$LW" --phase final --freeze
assert_eq "  and the final passes" "$T_RC|$(jq -r .upgrade_plan_phase "$L")" "0|final"

# A lowered core floor over a frozen draft offers to keep the frozen strategy.
t_run env DRUPILOT_DETERMINISTIC=false DRUPILOT_CORE_TARGET_STRATEGY=d11-only "$T_SH" "$UP" --subject "$LW" --freeze --json
up --subject "$LW" --phase final --strategy keep-previous
assert_eq "keep-previous over a frozen target-only draft: refused" "$T_RC|$(jq -r '.violations[0].field' "$T_OUT")" "2|range.floor"
assert_eq "  keep the frozen strategy, or re-ask the core target" \
  "$(jq -c '[.choices[] | [.id, .tab, .set]]' "$T_OUT")" '[["keep-frozen-range",null,{"DRUPILOT_CORE_TARGET_STRATEGY":"d11-only"}],["core-target","CORE_TARGET",{}]]'

# A loose subject's draft, frozen under the test-bed root it will have.
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$T_TMP/loose_lw"
up --subject "$T_TMP/loose_lw" --root "$T_TMP/loose_lw-d11" --freeze
assert_eq "frozen under a root that does not exist yet" "$T_RC|$(plan_get .subject.machine_name "$T_TMP/loose_lw-d11")" "0|legacy_widgets"
up --subject "$T_TMP/loose_lw" --root "$T_TMP/x/../loose_beds//lw-d11/" --freeze
mkdir -p "$T_TMP/loose_beds/lw-d11"
assert_eq "a trailing slash and a .. key the lock as the created root will" "$T_RC|$(plan_get .subject.machine_name "$T_TMP/loose_beds/lw-d11")" "0|legacy_widgets"
t_done
