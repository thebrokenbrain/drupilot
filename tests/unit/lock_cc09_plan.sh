#!/usr/bin/env bash
# Freezing a plan in a lock drupilot 0.9 wrote (CC-09, CC-10, ADR 0015, ADR
# 0018): on a copy of tests/fixtures/migration-0.9's lock, plan_freeze adds
# its four keys, stamps drupilot_version and changes nothing else: every 0.9
# value stays, .schema stays absent (a 0.9 lock is schema 0 until it is
# migrated), and toolchain_cell_for still reads the lock as legacy_v1.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
ROOT="$T_TMP/root"; mkdir -p "$ROOT"
L="$(drupilot_lock_file "$ROOT")"
cp "$T_REPO/tests/fixtures/migration-0.9/root-state/drupilot-lock.json" "$L"
ORIG="$T_TMP/orig.json"; cp "$L" "$ORIG"
assert_eq "the 0.9 lock reads as legacy_v1" "$(toolchain_cell_for "$ROOT")" "legacy_v1"

PLAN="$(jq -c . "$T_REPO/schemas/examples/upgrade-plan.example.json")"
assert_exit "plan_freeze on the 0.9 lock" 0 plan_freeze "$PLAN" draft "$ROOT"
assert_eq "every 0.9 value but drupilot_version is unchanged" \
  "$(jq -S -c 'del(.drupilot_version, .upgrade_plan, .upgrade_plan_hash, .upgrade_plan_phase, .data_hash)' "$L")" \
  "$(jq -S -c 'del(.drupilot_version)' "$ORIG")"
assert_eq "drupilot_version is stamped" "$(jq -r .drupilot_version "$L")" "$(plugin_version)"
assert_eq ".schema stays absent" "$(jq -r 'has("schema")' "$L")" "false"
assert_eq "the plan's keys are added" "$(jq -c '[.upgrade_plan_phase, (.upgrade_plan_hash | test("^sha256:[0-9a-f]{64}$")), .data_hash == .upgrade_plan.data_hash]' "$L")" '["draft",true,true]'
assert_eq "still legacy_v1" "$(toolchain_cell_for "$ROOT")" "legacy_v1"
assert_eq "the 0.9 keys keep their order" "$(jq -c 'keys_unsorted[0:11]' "$L")" "$(jq -c 'keys_unsorted' "$ORIG")"
t_done
