#!/usr/bin/env bash
# The frozen plan in the root's lock (T-M3-04, ADR 0018): plan_freeze writes
# {upgrade_plan, upgrade_plan_hash, upgrade_plan_phase, data_hash} in one
# write and keeps the rest of the lock; the hash ignores meta and key order;
# plan_frozen prints the plan as upgrade-path.sh did; plan_get reads one
# value (strings raw, false and numbers kept, null as nothing) and returns 1
# without a plan; the readers create no directory (lock_path); a new lock
# starts as {"schema": 1}; misuse returns 1 and writes nothing.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
ROOT="$T_TMP/root"; mkdir -p "$ROOT"
DATA="$HOME/.local/share/drupilot"
PLAN='{"schema_version":1,"meta":{"generated_at":"2026-10-05T10:00:00Z","drupilot_version":"x","phase":"draft"},"target":{"major":11,"preview":false,"bed_core":"11.4.8"},"php":{"floor":"8.1","final":"8.3"},"range":{"constraint":"^10 || ^11"},"hops":["10-11"],"data_hash":"sha256:'"$(printf '%064d' 0)"'"}'

assert_tree_unchanged "plan_get without a lock creates nothing" "$HOME" plan_get .php.final "$ROOT"
assert_eq "  and returns 1" "$T_RC" "1"
assert_tree_unchanged "plan_frozen without a lock creates nothing" "$HOME" plan_frozen "$ROOT"
assert_eq "  and prints nothing" "$(t_out)" ""
assert_eq "lock_path is drupilot_lock_file's path" "$(lock_path "$ROOT")" "$(project_state_path "$ROOT")/drupilot-lock.json"
assert_eq "  without creating it" "$([[ -e "$DATA" ]] && echo exists || echo absent)" "absent"

assert_exit "plan_freeze: a bad phase" 1 plan_freeze "$PLAN" frozen "$ROOT"
assert_exit "plan_freeze: not an object" 1 plan_freeze '[1]' draft "$ROOT"
assert_exit "plan_freeze: an empty plan" 1 plan_freeze '' draft "$ROOT"
assert_eq "  nothing written" "$([[ -e "$(lock_path "$ROOT")" ]] && echo written || echo none)" "none"

assert_exit "plan_freeze draft" 0 plan_freeze "$PLAN" draft "$ROOT"
L="$(lock_path "$ROOT")"
assert_eq "a new lock: schema 1, the four keys, drupilot_version" \
  "$(jq -c '[.schema, (keys | sort), .upgrade_plan_phase, .data_hash == .upgrade_plan.data_hash, .drupilot_version]' "$L")" \
  "[1,[\"data_hash\",\"drupilot_version\",\"schema\",\"upgrade_plan\",\"upgrade_plan_hash\",\"upgrade_plan_phase\"],\"draft\",true,\"$(plugin_version)\"]"
H="$(jq -r .upgrade_plan_hash "$L")"
assert_eq "the hash: the canonical plan without meta" "$H" "$(printf '%s' "$PLAN" | jq -S -c 'del(.meta)' | json_hash)"
assert_eq "plan_frozen: the plan as upgrade-path.sh prints it" "$(plan_frozen "$ROOT")" "$(printf '%s' "$PLAN" | jq -S .)"
assert_eq "plan_get: a string, raw" "$(plan_get .php.final "$ROOT")" "8.3"
assert_eq "plan_get: a number" "$(plan_get .target.major "$ROOT")" "11"
assert_eq "plan_get: false survives" "$(plan_get .target.preview "$ROOT")" "false"
assert_eq "plan_get: an array, compact" "$(plan_get .hops "$ROOT")" '["10-11"]'
assert_eq "plan_get: a missing key is nothing (rc 0)" "$(plan_get .nope "$ROOT"; echo "rc=$?")" "rc=0"
assert_eq "plan_get: DRUPILOT_PROJECT_DIR is the default root" "$(DRUPILOT_PROJECT_DIR="$ROOT" plan_get .range.constraint)" "^10 || ^11"
assert_exit "plan_get: not a jq path" 1 plan_get '.[' "$ROOT"

# Other keys survive; another meta gives the same hash; the final phase replaces the draft.
DRUPILOT_PROJECT_DIR="$ROOT" lock_set .drupal.core 11.4.8
P2="$(printf '%s' "$PLAN" | jq -c '.meta.generated_at = "2026-12-31T00:00:00Z" | .meta.phase = "final"')"
plan_freeze "$P2" final "$ROOT"
assert_eq "a final freeze keeps the other keys, same hash for another meta" \
  "$(jq -c '[.drupal.core, .upgrade_plan_phase, .upgrade_plan_hash == "'"$H"'", .upgrade_plan.meta.phase]' "$L")" '["11.4.8","final",true,"final"]'
P3="$(printf '%s' "$PLAN" | jq -c '.php.final = "8.4"')"
plan_freeze "$P3" draft "$ROOT"
assert_eq "another plan, another hash" "$([[ "$(jq -r .upgrade_plan_hash "$L")" != "$H" ]] && echo differs)" "differs"
assert_eq "  and the lock is still one JSON document" "$(jq -e . "$L" > /dev/null && echo json)" "json"
assert_eq "  no temp file left" "$(find "$(dirname "$L")" -name 'drupilot-lock.json.*' | wc -l | tr -d ' ')" "0"
t_done
