#!/usr/bin/env bash
# For a Drupal 11 plan with no new feature (no BC block, sets of the previous
# major only), rector.php template 5 configures Rector as template 4 did
# (T-M3-09, AR-24, ADR 0019): the same paths, skipped rules, PHP version and
# level sets, file extensions, and the same Drupal sets — the per-minor sets
# plus drupal-rector's bootstrap file are what its DRUPAL_10 aggregate
# registers (drupal-10-all-deprecations.php in drupal-rector 1.1.3; the lab
# run in ADR 0019 shows identical Rector diffs). Compared statically on
# legacy_widgets (the H10 subject): tests/fixtures/rector-render/legacy_widgets/
# rector.v4.php (template 4, as M2 pinned it) vs rector.php (template 5).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/plans/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
F="$T_REPO/tests/fixtures/rector-render/legacy_widgets"
V4="$F/rector.v4.php"; V5="$F/rector.php"
assert_eq "the v4 fixture is template 4" "$(grep -c 'drupilot-template-version: 4' "$V4")" "1"
assert_eq "the v5 render is template 5" "$(grep -c 'drupilot-template-version: 5' "$V5")" "1"

# list FILE OPENING -> the quoted strings of a PHP array whose opening line
# contains the literal OPENING, one per line, up to its closing line.
list() { _OPEN="$2" awk -v q="'" 'index($0, ENVIRON["_OPEN"]) { on = 1; next } on && /^[[:space:]]*\]/ { on = 0 } on { n = split($0, a, q); if (n >= 3) print a[2] }' "$1"; }
call() { sed -n "s/^[[:space:]]*->$2(\(.*\))\$/\1/p" "$1"; }
nonempty() { [[ -n "$1" ]] && echo yes || echo no; }

for k in "->withPaths([" '$drupilotRiskySkips = ' "->withFileExtensions(["; do
  assert_eq "read from both: $k" "$(nonempty "$(list "$V5" "$k")")$(nonempty "$(list "$V4" "$k")")" "yesyes"
done
assert_eq "the same paths" "$(list "$V5" "->withPaths([")" "$(list "$V4" "->withPaths([")"
assert_eq "the same skipped rules, in order" "$(list "$V5" '$drupilotRiskySkips = ')" "$(list "$V4" '$drupilotRiskySkips = ')"
assert_eq "the same PHP version" "$(call "$V5" withPhpVersion)" "$(call "$V4" withPhpVersion)"
assert_eq "  (PHP_81)" "$(call "$V5" withPhpVersion)" "PhpVersion::PHP_81"
assert_eq "the same PHP level sets" "$(call "$V5" withPhpSets)" "$(call "$V4" withPhpSets)"
assert_eq "the same file extensions" "$(list "$V5" "->withFileExtensions([")" "$(list "$V4" "->withFileExtensions([")"
assert_eq "v4: the DRUPAL_10 aggregate" "$(sed -n '/->withSets(\[/,/\])/p' "$V4" | grep -c 'Drupal10SetList::DRUPAL_10,')" "1"
# What the aggregate registers: the verified per-minor sets of Drupal 10 (the
# data records them from drupal-rector's Drupal10SetList) and the bootstrap file.
AGG="$(target_get 10 '.rector_sets.own_major[]' | sed 's/^/DrupalRector\\\\Set\\\\/')"
assert_eq "v5: the aggregate's per-minor sets, in order" "$(list "$V5" '$drupilotSets = ')" "$AGG"
assert_eq "v5: drupal-rector's bootstrap file, as the aggregate registers it" \
  "$(grep -c "vendor/palantirnet/drupal-rector/config/drupal-phpunit-bootstrap-file.php" "$V5")|$(grep -c 'withBootstrapFiles' "$V5")" "1|1"
assert_eq "v5: no BC block for ^10 || ^11 (drupal-rector's default, as in v4)" \
  "$(grep -c 'DrupalRectorSettings' "$V5" || true)|$(grep -c 'DrupalRectorSettings' "$V4" || true)" "0|0"
t_done
