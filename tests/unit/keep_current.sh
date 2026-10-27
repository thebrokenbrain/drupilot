#!/usr/bin/env bash
# recommend_core_target keep-current (CC-36): with strategy auto, a subject that
# already declares a Drupal 11-compatible range and has no BC break keeps it
# verbatim ("keep-current"); the refactor phase (a BC break) does not. The
# upgrade plan agrees (keep_current_alias).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/plans/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
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

# keep_current_alias (CC-36): the keep_current fixture under auto is kept by
# both views of the decision — core-strategy's strategy keep-current, the
# upgrade plan's resolved_strategy keep-current — with the same range,
# verbatim (keep-current is an outcome, never an input of the plan).
k="$T_TMP/keep_current"; cp -R "$T_REPO/tests/fixtures/keep_current" "$k"
want="$(sed -n 's/^core_version_requirement:[[:space:]]*//p' "$k"/*.info.yml)"
t_run "$T_SH" "$T_REPO/scripts/analysis/core-strategy.sh" --subject "$k" --json
assert_eq "keep_current_alias: core-strategy keeps it" "$(jq -c '[.strategy, .recommended_core_version_requirement]' "$T_OUT")" "[\"keep-current\",\"$want\"]"
t_run "$T_SH" "$T_REPO/scripts/analysis/upgrade-path.sh" --subject "$k" --json
assert_eq "keep_current_alias: the plan keeps it" "$(jq -c '[.range.strategy, .range.resolved_strategy, .range.constraint]' "$T_OUT")" "[\"auto\",\"keep-current\",\"$want\"]"
t_run "$T_SH" "$T_REPO/scripts/analysis/upgrade-path.sh" --subject "$k" --strategy keep-current --json
assert_eq "keep_current_alias: keep-current is no input of the plan" "$T_RC|$(t_out)" "1|"
t_done
