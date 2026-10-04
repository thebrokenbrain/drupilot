#!/usr/bin/env bash
# T-M2-13/14, ADR 0002: the main Rector config targets the PHP floor L (the
# lowest PHP the declared core range and the require.php composer enforces
# admit, never above the PHP target P), and the narrow compat config is
# rendered only when a compat rule is needed (L < 8.4 <= U, U = max(P, the
# highest PHP ceiling of the range's known legs)). The rendered files for
# legacy_widgets (^10 -> ^10 || ^11, require.php >=8.1) are pinned byte for
# byte in tests/fixtures/rector-render/. The version data is a small synthetic
# copy (DRUPILOT_VERSION_DATA_DIR), so a data refresh never changes this test.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

# One shipped-data fact the rest relies on: ^10 || ^11 starts at PHP 8.1.
_b="$(php_bounds_for_range '^10 || ^11')"
assert_eq "the shipped data: ^10 || ^11 runs from PHP 8.1" "${_b%% *}" "8.1"

D="$T_TMP/data"; mkdir -p "$D/targets" "$D/php"
printf '%s\n' '{"major":10,"minors":{"10.0":{"verified":true,"php_supported":["8.1","8.2","8.3"]},"10.3":{"verified":true,"php_supported":["8.1","8.2","8.3"]}}}' > "$D/targets/10.json"
printf '%s\n' '{"major":11,"minors":{"11.0":{"verified":true,"php_supported":["8.3"]},"11.3":{"verified":true,"php_supported":["8.3","8.4","8.5"]}}}' > "$D/targets/11.json"
printf '%s\n' '{"major":12,"minors":{"12.0":{"verified":true,"php_supported":["8.5"]}}}' > "$D/targets/12.json"
printf '%s\n' '{"versions":{"7.4":{},"8.0":{},"8.1":{},"8.2":{},"8.3":{},"8.4":{},"8.5":{}}}' > "$D/php/versions.json"
export DRUPILOT_VERSION_DATA_DIR="$D"

# --- php_constraint_floor (plan.sh) -------------------------------------------
pcf() { php_constraint_floor "$1"; }
assert_eq ">=8.1" "$(pcf '>=8.1')" "8.1"
assert_eq "^8.2" "$(pcf '^8.2')" "8.2"
assert_eq "~8.1.0" "$(pcf '~8.1.0')" "8.1"
assert_eq "8.1.*" "$(pcf '8.1.*')" "8.1"
assert_eq "8.1.x" "$(pcf '8.1.x')" "8.1"
assert_eq "8.x reads as 8.0" "$(pcf '8.x')" "8.0"
assert_eq "a hyphen range: its lower end" "$(pcf '8.1 - 8.3')" "8.1"
assert_eq ">=8.1@dev (a stability flag)" "$(pcf '>=8.1@dev')" "8.1"
assert_eq ">=8.1.0-beta1 (a pre-release)" "$(pcf '>=8.1.0-beta1')" "8.1"
assert_eq ">= 8.2 (space after the operator)" "$(pcf '>= 8.2')" "8.2"
assert_eq ">=8.1 <8.4" "$(pcf '>=8.1 <8.4')" "8.1"
assert_eq ">=8.1,<8.4" "$(pcf '>=8.1,<8.4')" "8.1"
assert_eq "two lower bounds in one alternative: the higher" "$(pcf '>=8.1 >=8.2')" "8.2"
assert_eq "^8.1 || ^8.3: the lowest alternative" "$(pcf '^8.3 || ^8.1')" "8.1"
assert_eq "^8.3|^8.2 (single bar)" "$(pcf '^8.3|^8.2')" "8.2"
assert_eq ">=8 reads as 8.0" "$(pcf '>=8')" "8.0"
assert_eq "an alternative with no lower bound: no floor" "$(pcf '^8.3 || <8.0')" ""
assert_eq "* has no floor" "$(pcf '*')" ""
assert_eq "empty" "$(pcf '')" ""
assert_eq "not a constraint" "$(pcf 'latest')" ""

# --- _rector_range_legs ----------------------------------------------------------
legs() { _rector_range_legs "$1" | tr '\n' ' '; }
assert_eq "caret, tilde and wildcard legs" "$(legs '^10.3 || ~11.1 || 12.x')" "^10.3 ^11.1 ^12.0 "
assert_eq "an open >= covers the higher majors of the data" "$(legs '>=11')" "^11.0 ^12 "
assert_eq "a bounded >= is not read" "$(legs '>=10.3 <12')" "? "

# --- rector_php_bounds / rector_compat_needed (common.sh) ----------------------
mod() {  # mod NAME REQ [COMPOSER-JQ|none] -> a legacy_widgets copy at $T_TMP/m/NAME
  local d="$T_TMP/m/$1"
  mkdir -p "$T_TMP/m"; cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$d"
  [[ -n "$2" ]] && sed_inplace "$d/legacy_widgets.info.yml" "s/^core_version_requirement: .*/core_version_requirement: $2/"
  case "${3:-}" in
    none) rm -f "$d/composer.json";;
    '') ;;
    *) jq "$3" "$T_REPO/tests/fixtures/legacy_widgets/composer.json" > "$d/composer.json";;
  esac
  printf '%s' "$d"
}
bounds() { ( "$@" ) 2> /dev/null; }
LW="$(mod lw '')"
assert_eq "legacy_widgets, P 8.3: ^10 || ^11 + >=8.1 -> 8.1 8.5" \
  "$(bounds rector_php_bounds "$LW" 8.3)" "8.1 8.5"
assert_eq "d11-only, P 8.4: ^11 -> 8.3 8.5" \
  "$(DRUPILOT_CORE_TARGET_STRATEGY=d11-only bounds rector_php_bounds "$LW" 8.4)" "8.3 8.5"
assert_eq "keep-d10 with the target require.php floor, P 8.4: >=8.4 -> 8.4 8.5" \
  "$(DRUPILOT_CORE_TARGET_STRATEGY=keep-d10 DRUPILOT_REQUIRE_PHP_FLOOR=target bounds rector_php_bounds "$LW" 8.4)" "8.4 8.5"
LW84="$(mod lw84 '' '.require.php = ">=8.4"')"
assert_eq "d11-only + the subject's require.php >=8.4, P 8.4 -> 8.4 8.5" \
  "$(DRUPILOT_CORE_TARGET_STRATEGY=d11-only bounds rector_php_bounds "$LW84" 8.4)" "8.4 8.5"
assert_eq "never above P: d11-only + >=8.4, P 8.3 -> 8.3 8.5" \
  "$(DRUPILOT_CORE_TARGET_STRATEGY=d11-only bounds rector_php_bounds "$LW84" 8.3)" "8.3 8.5"
LWNC="$(mod lwnc '' none)"
assert_eq "no composer.json: core-strategy's require.php enforces nothing, the range floor stays" \
  "$(DRUPILOT_CORE_TARGET_STRATEGY=keep-d10 DRUPILOT_REQUIRE_PHP_FLOOR=target bounds rector_php_bounds "$LWNC" 8.4)" "8.1 8.5"
LWNR="$(mod lwnr '' 'del(.require)')"
assert_eq "d11-only and no require.php: the range floor, 8.3 8.5" \
  "$(DRUPILOT_CORE_TARGET_STRATEGY=d11-only bounds rector_php_bounds "$LWNR" 8.4)" "8.3 8.5"
# A Drupal 9 leg kept as-is (keep-current): its PHP is not in the data.
L95="$(mod l95 '^9.5 || ^10 || ^11')"
assert_eq "^9.5 || ^10 || ^11 + >=8.1: the enforced floor, and the known legs' ceiling" \
  "$(bounds rector_php_bounds "$L95" 8.3)" "8.1 8.5"
L95N="$(mod l95n '^9.5 || ^10 || ^11' none)"
assert_eq "... without composer.json: the lowest PHP of the data" "$(bounds rector_php_bounds "$L95N" 8.3)" "7.4 8.5"
t_run rector_php_bounds "$L95N" 8.3
assert_match "... with a warning naming the range" "$(tr '\n' ' ' < "$T_ERR")" "core range '\\^9\\.5 \\|\\| \\^10 \\|\\| \\^11' is not in drupilot's version data"
# A minor the data has not verified yet: its major's verified minors bound it.
L115="$(mod l115 '^11.5' 'del(.require)')"
assert_eq "^11.5 before 11.5 is verified: Drupal 11's verified PHP, no warning" \
  "$(bounds rector_php_bounds "$L115" 8.3)" "8.3 8.5"
t_run rector_php_bounds "$L115" 8.3
assert_eq "... and no warning" "$(grep -c 'not in drupilot' "$T_ERR" || true)" "0"
# A future major with no verified minor adds nothing to an open >= range.
D3="$T_TMP/data3"; cp -R "$D" "$D3"
printf '%s\n' '{"major":13,"minors":{"13.0":{"status":"detect"}}}' > "$D3/targets/13.json"
LGE="$(mod lge '>=11' 'del(.require)')"
assert_eq ">=11 with an unverified major 13: the verified majors bound it" \
  "$(DRUPILOT_VERSION_DATA_DIR="$D3" bounds rector_php_bounds "$LGE" 8.3)" "8.3 8.5"
mkdir -p "$T_TMP/nodata"
assert_eq "no version data: L is the require.php floor, U = P" \
  "$(DRUPILOT_VERSION_DATA_DIR="$T_TMP/nodata" bounds rector_php_bounds "$LW" 8.3)" "8.1 8.3"
assert_eq "no version data and no require.php: L = U = P" \
  "$(DRUPILOT_VERSION_DATA_DIR="$T_TMP/nodata" DRUPILOT_CORE_TARGET_STRATEGY=d11-only bounds rector_php_bounds "$LWNR" 8.4)" "8.4 8.4"
assert_eq "no subject directory: L = U = P" "$(bounds rector_php_bounds "$T_TMP/missing" 8.4)" "8.4 8.4"
# A target P above every ceiling of the range: the code runs on P too (U = P).
D2="$T_TMP/data2"; mkdir -p "$D2/targets" "$D2/php"; cp "$D/targets/10.json" "$D/php/versions.json" "$D2/"
mv "$D2/10.json" "$D2/targets/"; mv "$D2/versions.json" "$D2/php/"
printf '%s\n' '{"major":11,"minors":{"11.0":{"verified":true,"php_supported":["8.3"]}}}' > "$D2/targets/11.json"
assert_eq "P 8.4 above the range's ceiling 8.3: U = P" \
  "$(DRUPILOT_VERSION_DATA_DIR="$D2" bounds rector_php_bounds "$LW" 8.4)" "8.1 8.4"
cn() { if rector_compat_needed "$1" "$2"; then echo yes; else echo no; fi; }
assert_eq "compat needed: 8.1 8.5" "$(cn 8.1 8.5)" "yes"
assert_eq "compat needed: 8.3 8.4" "$(cn 8.3 8.4)" "yes"
assert_eq "compat not needed: 8.4 8.5 (the php84 set holds the rule)" "$(cn 8.4 8.5)" "no"
assert_eq "compat not needed: 8.3 8.3 (no PHP of the window deprecates it)" "$(cn 8.3 8.3)" "no"
assert_eq "floor tokens 8.1" "$(rector_floor_tokens 8.1 | tr '\n' ' ')" "PHP_FLOOR=8.1 PHP_FLOOR_ID=PHP_81 PHP_FLOOR_SET=php81 "
assert_eq "floor tokens 7.4" "$(rector_floor_tokens 7.4 | tr '\n' ' ')" "PHP_FLOOR=7.4 PHP_FLOOR_ID=PHP_74 PHP_FLOOR_SET=php74 "
assert_eq "floor tokens 8.5: no php85 set is assumed" "$(rector_floor_tokens 8.5 2> /dev/null | tr '\n' ' ')" \
  "PHP_FLOOR=8.5 PHP_FLOOR_ID=PHP_85 PHP_FLOOR_SET=php84 "

# --- render-templates.sh --------------------------------------------------------
mkroot() {  # mkroot ROOT MODULE_DIR [NAME]
  mkdir -p "$1/web/core/lib" "$1/web/modules/custom"
  printf '{"name":"x/root"}\n' > "$1/composer.json"
  printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$1/web/core/lib/Drupal.php"
  cp -R "$2" "$1/web/modules/custom/${3:-legacy_widgets}"
}
SUB=web/modules/custom/legacy_widgets
r="$T_TMP/root"; mkroot "$r" "$LW"
rt() { t_run env "$@" "$T_SH" "$T_REPO/scripts/env/render-templates.sh" --root "$r" --subject "$SUB" --only rector --json; }
rt DRUPILOT_PHP_TARGET=8.3
assert_eq "--only rector renders the pair" "$T_RC|$(jq -c '[.files[] | [.name, .status]]' "$T_OUT")" \
  '0|[["rector","written"],["rector-compat","written"]]'
assert_eq "... and reports the floor and ceiling" "$(jq -c '[.php_floor, .php_ceiling]' "$T_OUT")" '["8.1","8.5"]'
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
# is regenerated without --force, after a backup (a TMPDIR that does not exist
# does not get in the way).
rt DRUPILOT_PHP_TARGET=8.3 DRUPILOT_CORE_TARGET_STRATEGY=d11-only TMPDIR="$T_TMP/no-such-dir"
assert_eq "floor 8.1 -> 8.3: rector.php upgraded, compat unchanged" "$T_RC|$(jq -c '[.files[].status]' "$T_OUT")" '0|["upgraded","unchanged"]'
assert_eq "... now at PHP_83 / php83" \
  "$(has "$r/rector.php" '->withPhpVersion(PhpVersion::PHP_83)')$(has "$r/rector.php" '->withPhpSets(php83: true)')" "yesyes"
b="$(jq -r '.files[0].backup // empty' "$T_OUT")"
assert_eq "... the PHP_81 copy is backed up" "$([[ -n "$b" && -f "$b" ]] && has "$b" 'PHP_81' || echo none)" "yes"
assert_eq "... and no temp file is left at the root" "$(find "$r" -maxdepth 1 -name '.*.drupilot-*' | grep -c . || true)" "0"
# A hand edit is never overwritten, even when the floor moves.
printf '\n// hand edit\n' >> "$r/rector.php"; cp "$r/rector.php" "$T_TMP/edited.php"
rt DRUPILOT_PHP_TARGET=8.3
assert_eq "hand-edited + floor moved: differs, exit 3" "$T_RC|$(jq -r '.files[0].status' "$T_OUT")" "3|differs"
assert_file_eq "... the hand edit is still there" "$r/rector.php" "$T_TMP/edited.php"

# A shared test-bed: rendering for a second module moves the pair together.
r="$T_TMP/shared"; mkroot "$r" "$LW"; mkroot "$r" "$LW" other_widgets
rt DRUPILOT_PHP_TARGET=8.3
SUB=web/modules/custom/other_widgets rt DRUPILOT_PHP_TARGET=8.3
assert_eq "second subject on a shared root: both untouched renders regenerated" \
  "$T_RC|$(jq -c '[.files[].status]' "$T_OUT")" '0|["upgraded","upgraded"]'
assert_eq "... both for the second subject" \
  "$(has "$r/rector.php" "'web/modules/custom/other_widgets'")$(has "$r/rector-compat.php" "'web/modules/custom/other_widgets'")" "yesyes"
printf '\n// hand edit\n' >> "$r/rector-compat.php"
rt DRUPILOT_PHP_TARGET=8.3
assert_eq "a hand-edited rector-compat.php: differs, exit 3" "$T_RC|$(jq -c '[.files[].status]' "$T_OUT")" '3|["upgraded","differs"]'

# --only rector-compat alone.
r="$T_TMP/compatonly"; mkroot "$r" "$LW"
t_run env DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/env/render-templates.sh" --root "$r" --subject "$SUB" --only rector-compat --json
assert_eq "--only rector-compat writes that file only" \
  "$T_RC|$(jq -c '[.files[] | [.name, .status]]' "$T_OUT")|$([[ -e "$r/rector.php" ]] && echo yes || echo no)" \
  '0|[["rector-compat","written"]]|no'

# L >= 8.4: no compat config.
r="$T_TMP/root84"; mkroot "$r" "$LW84"
rt DRUPILOT_PHP_TARGET=8.4 DRUPILOT_CORE_TARGET_STRATEGY=d11-only
assert_eq "L 8.4: rector-compat skipped" "$T_RC|$(jq -c '[.files[] | [.name, .status]]' "$T_OUT")" \
  '0|[["rector","written"],["rector-compat","skipped"]]'
assert_eq "... and not written" "$([[ -e "$r/rector-compat.php" ]] && echo yes || echo no)" "no"
assert_eq "... rector.php at PHP_84 / php84" \
  "$(has "$r/rector.php" '->withPhpVersion(PhpVersion::PHP_84)')$(has "$r/rector.php" '->withPhpSets(php84: true)')" "yesyes"

# L 8.5: withPhpVersion(PHP_85), but no php85 set is assumed.
r="$T_TMP/root85"; mkroot "$r" "$(mod l85 '' '.require.php = ">=8.5"')"
rt DRUPILOT_PHP_TARGET=8.5 DRUPILOT_CORE_TARGET_STRATEGY=d11-only
assert_eq "L 8.5: PHP_85 with the php84 sets" \
  "$T_RC|$(has "$r/rector.php" '->withPhpVersion(PhpVersion::PHP_85)')$(has "$r/rector.php" '->withPhpSets(php84: true)')" "0|yesyes"

# The floor is not a token: it follows the core target and require.php.
t_run "$T_SH" "$T_REPO/scripts/env/render-templates.sh" --root "$r" --subject "$SUB" --only rector --set PHP_FLOOR=8.2 --json
assert_eq "--set PHP_FLOOR is refused" "$T_RC" "1"
t_done
