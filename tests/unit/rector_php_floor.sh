#!/usr/bin/env bash
# T-M2-13/14, ADR 0002: the main Rector config targets the PHP floor L (the
# lowest PHP the declared core range and the effective require.php admit,
# never above the PHP target P), and the narrow compat config is rendered only
# when a compat rule is needed (L < 8.4 <= U, U = max(P, the range's PHP
# ceiling)). The rendered files for legacy_widgets (^10 -> ^10 || ^11,
# require.php >=8.1) are pinned byte for byte in tests/fixtures/rector-render/.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

# --- php_constraint_floor (plan.sh) -------------------------------------------
pcf() { php_constraint_floor "$1"; }
assert_eq ">=8.1" "$(pcf '>=8.1')" "8.1"
assert_eq "^8.2" "$(pcf '^8.2')" "8.2"
assert_eq "~8.1.0" "$(pcf '~8.1.0')" "8.1"
assert_eq "8.1.*" "$(pcf '8.1.*')" "8.1"
assert_eq ">= 8.2 (space after the operator)" "$(pcf '>= 8.2')" "8.2"
assert_eq ">=8.1 <8.4" "$(pcf '>=8.1 <8.4')" "8.1"
assert_eq ">=8.1,<8.4" "$(pcf '>=8.1,<8.4')" "8.1"
assert_eq "^8.1 || ^8.3: the lowest alternative" "$(pcf '^8.3 || ^8.1')" "8.1"
assert_eq "^8.3|^8.2 (single bar)" "$(pcf '^8.3|^8.2')" "8.2"
assert_eq ">=8 reads as 8.0" "$(pcf '>=8')" "8.0"
assert_eq "an alternative with no lower bound: no floor" "$(pcf '^8.3 || <8.0')" ""
assert_eq "* has no floor" "$(pcf '*')" ""
assert_eq "empty" "$(pcf '')" ""
assert_eq "not a constraint" "$(pcf 'latest')" ""

# --- rector_php_bounds / rector_compat_needed (common.sh) ----------------------
LW="$T_TMP/lw/legacy_widgets"
mkdir -p "$T_TMP/lw"; cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$T_TMP/lw/"
bounds() { ( "$@" ) 2> /dev/null; }
assert_eq "legacy_widgets, P 8.3: ^10 || ^11 + >=8.1 -> 8.1 8.5" \
  "$(bounds rector_php_bounds "$LW" 8.3)" "8.1 8.5"
assert_eq "d11-only, P 8.4: ^11 -> 8.3 8.5" \
  "$(DRUPILOT_CORE_TARGET_STRATEGY=d11-only bounds rector_php_bounds "$LW" 8.4)" "8.3 8.5"
assert_eq "keep-d10 with the target require.php floor, P 8.4: >=8.4 -> 8.4 8.5" \
  "$(DRUPILOT_CORE_TARGET_STRATEGY=keep-d10 DRUPILOT_REQUIRE_PHP_FLOOR=target bounds rector_php_bounds "$LW" 8.4)" "8.4 8.5"
LW84="$T_TMP/lw84/legacy_widgets"
mkdir -p "$T_TMP/lw84"; cp -R "$LW" "$T_TMP/lw84/"
jq '.require.php = ">=8.4"' "$LW/composer.json" > "$LW84/composer.json"
assert_eq "d11-only + the subject's require.php >=8.4, P 8.4 -> 8.4 8.5" \
  "$(DRUPILOT_CORE_TARGET_STRATEGY=d11-only bounds rector_php_bounds "$LW84" 8.4)" "8.4 8.5"
assert_eq "never above P: d11-only + >=8.4, P 8.3 -> 8.3 8.5" \
  "$(DRUPILOT_CORE_TARGET_STRATEGY=d11-only bounds rector_php_bounds "$LW84" 8.3)" "8.3 8.5"
mkdir -p "$T_TMP/nodata"
assert_eq "no version data for the range: L is the require.php floor, U = P" \
  "$(DRUPILOT_VERSION_DATA_DIR="$T_TMP/nodata" bounds rector_php_bounds "$LW" 8.3)" "8.1 8.3"
LWN="$T_TMP/lwn/legacy_widgets"
mkdir -p "$T_TMP/lwn"; cp -R "$LW" "$T_TMP/lwn/"
jq 'del(.require)' "$LW/composer.json" > "$LWN/composer.json"
assert_eq "no version data and no require.php: L = U = P" \
  "$(DRUPILOT_VERSION_DATA_DIR="$T_TMP/nodata" DRUPILOT_CORE_TARGET_STRATEGY=d11-only bounds rector_php_bounds "$LWN" 8.4)" "8.4 8.4"
assert_eq "d11-only and no require.php: the range floor, 8.3 8.5" \
  "$(DRUPILOT_CORE_TARGET_STRATEGY=d11-only bounds rector_php_bounds "$LWN" 8.4)" "8.3 8.5"
assert_eq "no subject directory: L = U = P" "$(bounds rector_php_bounds "$T_TMP/missing" 8.4)" "8.4 8.4"
cn() { if rector_compat_needed "$1" "$2"; then echo yes; else echo no; fi; }
assert_eq "compat needed: 8.1 8.5" "$(cn 8.1 8.5)" "yes"
assert_eq "compat needed: 8.3 8.4" "$(cn 8.3 8.4)" "yes"
assert_eq "compat not needed: 8.4 8.5 (the php84 set holds the rule)" "$(cn 8.4 8.5)" "no"
assert_eq "compat not needed: 8.3 8.3 (no PHP of the window deprecates it)" "$(cn 8.3 8.3)" "no"
assert_eq "floor tokens 8.1" "$(rector_floor_tokens 8.1 | tr '\n' ' ')" "PHP_FLOOR=8.1 PHP_FLOOR_ID=PHP_81 PHP_FLOOR_SET=php81 "
assert_eq "floor tokens 8.5: no php85 set is assumed" "$(rector_floor_tokens 8.5 2> /dev/null | tr '\n' ' ')" \
  "PHP_FLOOR=8.5 PHP_FLOOR_ID=PHP_85 PHP_FLOOR_SET=php84 "

# --- render-templates.sh --------------------------------------------------------
mkroot() {
  mkdir -p "$1/web/core/lib" "$1/web/modules/custom"
  printf '{"name":"x/root"}\n' > "$1/composer.json"
  printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$1/web/core/lib/Drupal.php"
  cp -R "$2" "$1/web/modules/custom/"
}
r="$T_TMP/root"; mkroot "$r" "$LW"
rt() { t_run env "$@" "$T_SH" "$T_REPO/scripts/env/render-templates.sh" --root "$r" --subject web/modules/custom/legacy_widgets --only rector --json; }
rt DRUPILOT_PHP_TARGET=8.3
assert_eq "--only rector renders the pair" "$T_RC|$(jq -c '[.files[] | [.name, .status]]' "$T_OUT")" \
  '0|[["rector","written"],["rector-compat","written"]]'
GOLD="$T_REPO/tests/fixtures/rector-render/legacy_widgets"
assert_file_eq "rector.php matches the golden render" "$r/rector.php" "$GOLD/rector.php"
assert_file_eq "rector-compat.php matches the golden render" "$r/rector-compat.php" "$GOLD/rector-compat.php"
has() { if grep -qF -- "$2" "$1"; then echo yes; else echo no; fi; }
assert_eq "rector.php: withPhpVersion at the floor" "$(has "$r/rector.php" '->withPhpVersion(PhpVersion::PHP_81)')" "yes"
assert_eq "rector.php: level sets stop at the floor" "$(has "$r/rector.php" '->withPhpSets(php81: true)')" "yes"
assert_eq "rector.php: template marker 4" "$(has "$r/rector.php" 'drupilot-template-version: 4')" "yes"
for _rule in 'Php85\\Rector\\Class_\\SleepToSerializeRector' 'Php85\\Rector\\Class_\\WakeupToUnserializeRector' \
  'Php85\\Rector\\Property\\AddOverrideAttributeToOverriddenPropertiesRector' 'Php81\\Rector\\Array_\\ArrayToFirstClassCallableRector'; do
  assert_eq "both configs skip ${_rule##*\\\\}" "$(has "$r/rector.php" "$_rule")$(has "$r/rector-compat.php" "$_rule")" "yesyes"
done
assert_eq "rector-compat.php: the implicit-nullable rule through withRules" \
  "$(has "$r/rector-compat.php" "'Rector\\\\Php84\\\\Rector\\\\Param\\\\ExplicitNullableParamTypeRector'")$(has "$r/rector-compat.php" '->withRules($drupilotCompatRules)')" "yesyes"
assert_eq "rector-compat.php: opens the filter at PHP_84 and loads no set" \
  "$(has "$r/rector-compat.php" '->withPhpVersion(PhpVersion::PHP_84)')$(has "$r/rector-compat.php" 'withPhpSets')$(has "$r/rector-compat.php" 'withSets')" "yesnono"
rt DRUPILOT_PHP_TARGET=8.3
assert_eq "a second render: both unchanged" "$T_RC|$(jq -c '[.files[].status]' "$T_OUT")" '0|["unchanged","unchanged"]'

# The floor moves (the core target became ^11): the untouched drupilot render
# is regenerated without --force, after a backup.
rt DRUPILOT_PHP_TARGET=8.3 DRUPILOT_CORE_TARGET_STRATEGY=d11-only
assert_eq "floor 8.1 -> 8.3: rector.php upgraded, compat unchanged" "$T_RC|$(jq -c '[.files[].status]' "$T_OUT")" '0|["upgraded","unchanged"]'
assert_eq "... now at PHP_83 / php83" \
  "$(has "$r/rector.php" '->withPhpVersion(PhpVersion::PHP_83)')$(has "$r/rector.php" '->withPhpSets(php83: true)')" "yesyes"
b="$(jq -r '.files[0].backup // empty' "$T_OUT")"
assert_eq "... the PHP_81 copy is backed up" "$([[ -n "$b" && -f "$b" ]] && has "$b" 'PHP_81' || echo none)" "yes"
# A hand edit is never overwritten, even when the floor moves.
printf '\n// hand edit\n' >> "$r/rector.php"; cp "$r/rector.php" "$T_TMP/edited.php"
rt DRUPILOT_PHP_TARGET=8.3
assert_eq "hand-edited + floor moved: differs, exit 3" "$T_RC|$(jq -r '.files[0].status' "$T_OUT")" "3|differs"
assert_file_eq "... the hand edit is still there" "$r/rector.php" "$T_TMP/edited.php"

# L >= 8.4: no compat config.
r="$T_TMP/root84"; mkroot "$r" "$LW84"
rt DRUPILOT_PHP_TARGET=8.4 DRUPILOT_CORE_TARGET_STRATEGY=d11-only
assert_eq "L 8.4: rector-compat skipped" "$T_RC|$(jq -c '[.files[] | [.name, .status]]' "$T_OUT")" \
  '0|[["rector","written"],["rector-compat","skipped"]]'
assert_eq "... and not written" "$([[ -e "$r/rector-compat.php" ]] && echo yes || echo no)" "no"
assert_eq "... rector.php at PHP_84 / php84" \
  "$(has "$r/rector.php" '->withPhpVersion(PhpVersion::PHP_84)')$(has "$r/rector.php" '->withPhpSets(php84: true)')" "yesyes"

# L 8.5: withPhpVersion(PHP_85), but no php85 set is assumed.
r="$T_TMP/root85"; jq '.require.php = ">=8.5"' "$LW/composer.json" > "$T_TMP/c85.json"
mkroot "$r" "$LW"; cp "$T_TMP/c85.json" "$r/web/modules/custom/legacy_widgets/composer.json"
rt DRUPILOT_PHP_TARGET=8.5 DRUPILOT_CORE_TARGET_STRATEGY=d11-only
assert_eq "L 8.5: PHP_85 with the php84 sets" \
  "$T_RC|$(has "$r/rector.php" '->withPhpVersion(PhpVersion::PHP_85)')$(has "$r/rector.php" '->withPhpSets(php84: true)')" "0|yesyes"

# --set PHP_FLOOR overrides the derived floor (and its id and set).
r="$T_TMP/rootset"; mkroot "$r" "$LW"
rt DRUPILOT_PHP_TARGET=8.3
t_run "$T_SH" "$T_REPO/scripts/env/render-templates.sh" --root "$r" --subject web/modules/custom/legacy_widgets \
  --only rector --set PHP_FLOOR=8.2 --dry-run --json
assert_eq "--set PHP_FLOOR=8.2 --dry-run on an untouched 8.1 render: would-upgrade" \
  "$T_RC|$(jq -r '.files[0].status' "$T_OUT")|$(has "$r/rector.php" 'PHP_81')" "0|would-upgrade|yes"
t_run "$T_SH" "$T_REPO/scripts/env/render-templates.sh" --root "$r" --subject web/modules/custom/legacy_widgets \
  --only rector --set PHP_FLOOR=8.0x --json
assert_eq "--set PHP_FLOOR with a bad value: usage error" "$T_RC" "1"
t_done
