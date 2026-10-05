#!/usr/bin/env bash
# upgrade-path.sh (T-M3-01, T-M3-03, AR-06, ADR 0017): the upgrade plan of
# each golden case matches tests/golden/plans/<case>.json (the plan without
# its meta, keys sorted; a refusal whole), computed on the data snapshot the
# golden.json pins: legacy_widgets for T 11 (auto, keep-previous and its
# keep-d10 alias, target-only and its d11-only alias, P 8.3 / 8.4, the final
# phase with its recorded PHPStan output) and T 12 (refused without the
# opt-in, a preview with it), the D9, D8 and D7 fixtures, a PHP-only move
# (d11_php_only at 8.5), a kept three-major declaration (keep_current), and
# the refusals of acme_api (W = {8.5}) and php_floor_signals (L 8.4 > P 8.3).
# Capture (only on purpose, then golden.sh --update, in its own commit):
#   bash tests/unit/upgrade_path_goldens.sh --capture
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
G="$T_REPO/tests/golden/plans"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$G/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
# The subjects are copies: no Drupal root (or drupal-rector) above the
# checkout can leak into a plan.
F="$T_TMP/fx"; mkdir -p "$F/monorepo/web/modules/custom"
for d in legacy_widgets d9_module d8_legacy d7_minimal d11_php_only keep_current; do cp -R "$T_REPO/tests/fixtures/$d" "$F/$d"; done
cp -R "$T_REPO/tests/fixtures/monorepo/web/modules/custom/acme_api" "$F/monorepo/web/modules/custom/acme_api"
cp -R "$T_REPO/tests/baseline/inputs/php_floor_signals" "$F/php_floor_signals"
PHPSTAN="$T_REPO/tests/fixtures/legacy_widgets.golden/raw/phpstan.json"

# The cases: "<file>|<env...>|<subject>|<args...>".
CASES="legacy_widgets.t11-auto-p83||legacy_widgets|--phase final
legacy_widgets.t11-auto-p84||legacy_widgets|--php 8.4
legacy_widgets.t11-keep-previous-p83||legacy_widgets|--strategy keep-previous
legacy_widgets.t11-target-only-p83||legacy_widgets|--strategy target-only
legacy_widgets.t11-target-only-p84||legacy_widgets|--strategy target-only --php 8.4
legacy_widgets.t11-auto-p83.final-phpstan||legacy_widgets|--phase final --phpstan @PHPSTAN
legacy_widgets.t12-no-optin||legacy_widgets|--target 12
legacy_widgets.t12-preview|DRUPILOT_ALLOW_PRERELEASE=true|legacy_widgets|--target 12
d9_module.t11-auto-p83||d9_module|
d8_legacy.t11-auto-p83||d8_legacy|
d7_minimal.t11-draft||d7_minimal|
d11_php_only.t11-p85||d11_php_only|--php 8.5
keep_current.t11-auto-p83||keep_current|
acme_api.unsatisfiable|DRUPILOT_REQUIRE_PHP_FLOOR=target|monorepo/web/modules/custom/acme_api|--strategy keep-previous --php 8.5
php_floor_signals.t11||php_floor_signals|--php 8.3"

# run SUBJECT ENV ARGS -> T_RC, and OUT: the plan without meta (or the
# refusal), keys sorted. Not in a subshell, so T_RC survives.
run() {
  local envs="$2" a
  local -a args=()
  # shellcheck disable=SC2086  # the args are a word list on purpose; @PHPSTAN is one word
  for a in $3; do [[ "$a" == "@PHPSTAN" ]] && a="$PHPSTAN"; args+=("$a"); done
  # shellcheck disable=SC2086  # envs is a word list on purpose
  t_run env $envs "$T_SH" "$T_REPO/scripts/analysis/upgrade-path.sh" --subject "$F/$1" ${args[@]+"${args[@]}"} --json
  OUT="$(jq -S 'del(.meta)' "$T_OUT" 2> /dev/null || cat "$T_OUT")"
  return 0
}
# valid -> the schema violations of the plan in $T_OUT (none for a refusal).
valid() {
  jq -r 'select(.status != "refused")' "$T_OUT" | jq -r --slurpfile schema "$T_REPO/schemas/upgrade-plan.schema.json" \
    "$(cat "$T_REPO/scripts/dev/jsonschema.jq") chk(\$schema[0]; \$schema[0]; \"\$\")" 2>&1 | tr '\n' ' '
}

while IFS='|' read -r name envs subj args; do
  [[ -n "$name" ]] || continue
  run "$subj" "$envs" "$args"
  if [[ "${1:-}" == "--capture" ]]; then printf '%s\n' "$OUT" > "$G/$name.json"; continue; fi
  want=0; [[ "$(jq -r '.status // ""' "$G/$name.json" 2> /dev/null)" == "refused" ]] && want=2
  assert_eq "$name: exit $want" "$T_RC" "$want"
  assert_eq "$name: the golden" "$OUT" "$(cat "$G/$name.json")"
  assert_eq "$name: valid against schemas/upgrade-plan.schema.json" "$(valid)" ""
done <<EOF
$CASES
EOF
if [[ "${1:-}" == "--capture" ]]; then printf 'captured\n'; exit 0; fi

# The aliases give the same plan as their 1.0 names (range.strategy says the
# 1.0 name).
run legacy_widgets '' '--strategy keep-d10'
assert_eq "keep-d10 = keep-previous" "$OUT" "$(cat "$G/legacy_widgets.t11-keep-previous-p83.json")"
run legacy_widgets '' '--strategy d11-only'
assert_eq "d11-only = target-only" "$OUT" "$(cat "$G/legacy_widgets.t11-target-only-p83.json")"
run legacy_widgets 'DRUPILOT_CORE_TARGET_STRATEGY=keep-d10' ''
assert_eq "DRUPILOT_CORE_TARGET_STRATEGY=keep-d10 = --strategy keep-previous" "$OUT" "$(cat "$G/legacy_widgets.t11-keep-previous-p83.json")"
run legacy_widgets '' '--phase draft'
assert_eq "the draft phase gives the final plan without a PHPStan file" "$OUT" "$(cat "$G/legacy_widgets.t11-auto-p83.json")"
assert_eq "the PHPStan file changes only the evidence hash" \
  "$(jq -c 'del(.source.evidence_hash)' "$G/legacy_widgets.t11-auto-p83.final-phpstan.json")" \
  "$(jq -c 'del(.source.evidence_hash)' "$G/legacy_widgets.t11-auto-p83.json")"
assert_eq "the schema's example is the G1 plan with a meta" \
  "$(jq -S 'del(.meta)' "$T_REPO/schemas/examples/upgrade-plan.example.json")" "$(cat "$G/legacy_widgets.t11-auto-p83.json")"
run legacy_widgets '' ''
assert_eq "meta: the phase, the plugin version, a UTC time" \
  "$(jq -c '[.meta.phase, .meta.drupilot_version == "'"$(plugin_version)"'", (.meta.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))]' "$T_OUT")" '["draft",true,true]'
assert_eq "the plan's data_hash is the snapshot's" "$(jq -r .data_hash "$T_OUT")" "sha256:${DRUPILOT_VERSION_DATA_DIR##*/}"
t_done
