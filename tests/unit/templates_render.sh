#!/usr/bin/env bash
# rector.php (template 5) renders from the upgrade plan (T-M3-09, AR-24, ADR
# 0019): for each golden plan of tests/golden/plans that resolves, the render
# equals tests/golden/templates/<plan>/rector.php byte for byte, and `php -l`
# accepts it (host php when present, else skipped with a note). The tokens
# come from rector_sets_block, rector_skip_block, rector_bc_block and
# rector_floor_tokens, as render-templates.sh and run-rector.sh build them.
# Capture (on purpose, then golden.sh --update in its own commit):
#   bash tests/unit/templates_render.sh --capture
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
P="$T_REPO/tests/golden/plans"; G="$T_REPO/tests/golden/templates"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$G/golden.json")"
export DRUPILOT_VERSION_DATA_DIR

# render PLAN_FILE OUT -> rector.php for the plan, its subject under web/modules/custom.
render() {
  local plan sub
  plan="$(jq -c . "$1")"; sub="web/modules/custom/$(printf '%s' "$plan" | jq -r .subject.machine_name)"
  # shellcheck disable=SC2046  # one KEY=VALUE word per line, no spaces in them
  render_template "$T_REPO/templates/rector.php.tmpl" "$2" "SUBJECT_PATH=$sub" \
    $(rector_floor_tokens "$(printf '%s' "$plan" | jq -r .php.floor)") \
    "RECTOR_SETS=$(rector_sets_block "$plan")" "SKIP_RULES=$(rector_skip_block "$plan")" \
    "BC_BLOCK=$(rector_bc_block "$plan")" "POLYFILLS="
}

n=0
for f in "$P"/*.json; do
  name="${f##*/}"; name="${name%.json}"
  [[ "$name" != golden ]] || continue
  [[ "$(jq -r '.status // ""' "$f")" != refused ]] || continue
  if [[ "${1:-}" == "--capture" ]]; then mkdir -p "$G/$name"; render "$f" "$G/$name/rector.php"; continue; fi
  render "$f" "$T_TMP/$name.php"
  assert_file_eq "$name: rector.php" "$T_TMP/$name.php" "$G/$name/rector.php"
  assert_eq "$name: no token left" "$(grep -c '{{' "$T_TMP/$name.php" || true)" "0"
  if have_cmd php; then
    assert_eq "$name: php -l" "$(php -l "$T_TMP/$name.php" > /dev/null 2>&1 && echo ok)" "ok"
  fi
  n=$((n + 1))
done
if [[ "${1:-}" == "--capture" ]]; then printf 'captured\n'; exit 0; fi
have_cmd php || printf '# note: no host php, php -l skipped (it runs wherever a host php exists, e.g. the ubuntu CI leg)\n'
assert_eq "every resolving golden plan was rendered" "$n" "$(for f in "$P"/*.json; do [[ "${f##*/}" == golden.json ]] && continue; jq -r 'select(.status != "refused") | 1' "$f"; done | grep -c .)"
# Spot checks on what the renders say.
assert_eq "T 11 from D10: the four Drupal 10 sets, no 11.x set" \
  "$(grep -c "Drupal10SetList::DRUPAL_10[0-3]'," "$G/legacy_widgets.t11-auto-p83/rector.php")|$(grep -c 'Drupal11SetList' "$G/legacy_widgets.t11-auto-p83/rector.php")" "4|0"
assert_eq "T 12 preview: the 11.x sets, their breaking sets up to 11.3, DRUPAL_120" \
  "$(grep -c 'Drupal11SetList::DRUPAL_11[0-4]' "$G/legacy_widgets.t12-preview/rector.php")|$(grep -c '_BREAKING' "$G/legacy_widgets.t12-preview/rector.php")|$(grep -c 'Drupal12SetList::DRUPAL_120' "$G/legacy_widgets.t12-preview/rector.php")" "8|3|1"
assert_eq "D8/D9 sources: no Drupal 8/9 set until the D8/D9 hops are proven" \
  "$(grep -c 'Drupal[89]SetList' "$G/d8_legacy.t11-auto-p83/rector.php" "$G/d9_module.t11-auto-p83/rector.php" | sed 's/.*://' | tr '\n' ' ')" "0 0 "
assert_eq "D7 rewrite: no Drupal set at all" "$(grep -c "SetList::DRUPAL_[0-9A-Z_]*'," "$G/d7_minimal.t11-draft/rector.php" || true)" "0"
assert_eq "^10 || ^11 (F 10.0): no BC block (drupal-rector's default, as in 0.9)" \
  "$(grep -c setMinimumCoreVersionSupported "$G/legacy_widgets.t11-auto-p83/rector.php" || true)" "0"
assert_eq "^10.3 || ^11 || ^12 (F 10.3): BC from 10.3.0" \
  "$(grep -c "setMinimumCoreVersionSupported('10.3.0')" "$G/keep_current.t11-auto-p83/rector.php")" "1"
assert_eq "^11 (F 11.0): BC from 11.0.0" \
  "$(grep -c "setMinimumCoreVersionSupported('11.0.0')" "$G/legacy_widgets.t11-target-only-p83/rector.php")" "1"
t_done
