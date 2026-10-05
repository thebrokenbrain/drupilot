#!/usr/bin/env bash
# core-strategy.sh --json is byte-identical (raw stdout: key order, indentation,
# every string) to tests/golden/core-strategy/matrix.jsonl, captured before the
# decision logic was split out of recommend_core_target (T-M3-05, CC-11): 12
# subjects (the fixtures, the PHP-floor signals input and three plugin-attribute
# variants) x 14 scenarios (strategies, the 0.9 KEEP_D10 override, phases, BC
# overrides, PHP floors and targets). The version data is the snapshot the
# golden is pinned to.
# Capture (only on purpose, in its own commit): bash tests/unit/core_strategy_matrix.sh --capture
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
G="$T_REPO/tests/golden/core-strategy"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$G/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
F="$T_REPO/tests/fixtures"; S="$T_TMP/s"; mkdir -p "$S"

# --- Subjects -----------------------------------------------------------------
cp -R "$F/legacy_widgets" "$S/lw"
cp -R "$F/legacy_widgets/modules/legacy_widgets_extra" "$S/lw_extra"
cp -R "$F/monorepo/web/modules/custom/acme_core" "$S/acme_core"
cp -R "$F/monorepo/web/modules/custom/acme_search/modules/acme_search_ui" "$S/acme_search_ui"
for f in keep_current d11_php_only d9_module d8_legacy; do cp -R "$F/$f" "$S/$f"; done
cp -R "$T_REPO/tests/baseline/inputs/php_floor_signals" "$S/sig"
# The attribute variants of smoke.sh's core-target test (ct3..ct5).
cp -R "$F/monorepo/web/modules/custom/acme_core" "$S/ct3"
sed_inplace "$S/ct3/acme_core.info.yml" 's/^core_version_requirement: .*/core_version_requirement: ^10/'
cp -R "$S/ct3" "$S/ct4"
printf '<?php\n\nnamespace Drupal\\acme_core\\Entity;\n\nuse Drupal\\Core\\Entity\\Attribute\\ContentEntityType;\n\n#[ContentEntityType(id: "acme_thing")]\nclass Thing {}\n' > "$S/ct4/src/Thing.php"
cp -R "$S/ct4" "$S/ct5"
sed_inplace "$S/ct5/acme_core.info.yml" 's/^core_version_requirement: .*/core_version_requirement: ^10 || ^11/'
SUBJECTS="lw lw_extra acme_core acme_search_ui keep_current d11_php_only d9_module d8_legacy sig ct3 ct4 ct5"

# --- Scenarios: "<name>|<env...>|<args...>" --------------------------------------
SCENARIOS='s01||
s02||--phase refactor
s03|DRUPILOT_CORE_TARGET_STRATEGY=d11-only|
s04|DRUPILOT_CORE_TARGET_STRATEGY=keep-d10|
s05|DRUPILOT_CORE_TARGET_STRATEGY=keep-d10 DRUPILOT_REQUIRE_PHP_FLOOR=target|
s06|DRUPILOT_KEEP_D10=true|
s07|DRUPILOT_KEEP_D10=false|
s08|DRUPILOT_CORE_TARGET_STRATEGY=d11-only DRUPILOT_KEEP_D10=true|
s09||--bc-break
s10||--phase refactor --no-bc-break
s11|DRUPILOT_PHP_TARGET=8.4|
s12|DRUPILOT_PHP_TARGET=8.5 DRUPILOT_CORE_TARGET_STRATEGY=keep-d10 DRUPILOT_USE_DIGESTS_RULES=false|
s13|DRUPILOT_DETECTED_PHP_FLOOR=8.2 DRUPILOT_CORE_TARGET_STRATEGY=keep-d10|
s14|DRUPILOT_DETECTED_PHP_FLOOR=8.4 DRUPILOT_CORE_TARGET_STRATEGY=bogus|'

# matrix -> one JSON line per {subject, scenario}: {case, exit, stdout}.
matrix() {
  local subj line name envs args out rc
  for subj in $SUBJECTS; do
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      name="${line%%|*}"; line="${line#*|}"; envs="${line%%|*}"; args="${line#*|}"
      rc=0
      # shellcheck disable=SC2086  # envs and args are word lists on purpose
      out="$(env $envs "$T_SH" "$T_REPO/scripts/analysis/core-strategy.sh" --subject "$S/$subj" $args --json 2> /dev/null < /dev/null)" || rc=$?
      jq -nc --arg c "$subj/$name" --argjson e "$rc" --arg o "$out" '{case: $c, exit: $e, stdout: $o}'
    done <<EOF
$SCENARIOS
EOF
  done
  return 0
}

if [[ "${1:-}" == "--capture" ]]; then
  matrix > "$G/matrix.jsonl"
  printf 'captured %s lines\n' "$(grep -c . "$G/matrix.jsonl")"
  exit 0
fi

matrix > "$T_TMP/matrix.jsonl"
assert_eq "168 cases" "$(grep -c . "$T_TMP/matrix.jsonl")" "168"
assert_eq "every case exits as in the golden" \
  "$(jq -c '[.case, .exit]' "$T_TMP/matrix.jsonl" | LC_ALL=C sort | cksum)" "$(jq -c '[.case, .exit]' "$G/matrix.jsonl" | LC_ALL=C sort | cksum)"
diffs="$(jq -r '.case' "$G/matrix.jsonl" | while IFS= read -r c; do
  [[ "$(jq -c --arg c "$c" 'select(.case == $c) | .stdout' "$T_TMP/matrix.jsonl")" == "$(jq -c --arg c "$c" 'select(.case == $c) | .stdout' "$G/matrix.jsonl")" ]] || printf '%s ' "$c"
done)"
assert_eq "every case's raw stdout is byte-identical" "$diffs" ""
t_done
