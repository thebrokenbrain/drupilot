#!/usr/bin/env bash
# recommend_core_target keep-current (CC-36): with strategy auto, a subject that
# already declares a Drupal 11-compatible range and has no BC break keeps it
# verbatim ("keep-current"); the refactor phase (a BC break) does not.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
m="$T_TMP/mods/keepme"; mkdir -p "$m"
printf "name: Keep me\ntype: module\ncore_version_requirement: ^10.3 || ^11 || ^12\n" > "$m/keepme.info.yml"
t_run "$T_SH" "$T_REPO/scripts/analysis/core-strategy.sh" --subject "$m" --json
assert_eq "exit" "$T_RC" "0"
assert_json_eq "strategy and requirement kept verbatim" "$(jq -c '{strategy, recommended_core_version_requirement}' "$T_OUT")" \
  '{"strategy":"keep-current","recommended_core_version_requirement":"^10.3 || ^11 || ^12"}'
t_run "$T_SH" "$T_REPO/scripts/analysis/core-strategy.sh" --subject "$m" --phase refactor --json
assert_eq "the refactor phase does not keep it" "$(jq -r .strategy "$T_OUT")" "d11-only"
printf "name: Keep me\ntype: module\ncore_version_requirement: ^10 || ^11\n" > "$m/keepme.info.yml"
t_run env DRUPILOT_CORE_TARGET_STRATEGY=keep-d10 "$T_SH" "$T_REPO/scripts/analysis/core-strategy.sh" --subject "$m" --json
assert_eq "an explicit strategy is not keep-current" "$(jq -r .strategy "$T_OUT")" "keep-d10"
t_done
