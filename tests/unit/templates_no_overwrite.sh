#!/usr/bin/env bash
# INV5 with rendered configs kept in the lock (T-M3-09, AR-24, ADR 0019):
# render-templates.sh keeps the sha256 of each file it writes
# (.templates[<file>] in the root's lock, never on a dry run); a rector.php
# whose sha256 is the one kept is an untouched render, regenerated (after a
# backup) when the plan moves — even when the PHP floor stays (the BC block
# of a ^10.3 floor) —, while a hand-edited one is never overwritten without
# --force (then backed up). run-rector.sh keeps the sha256 of what it writes
# and regenerates an untouched render for another plan the same way, and so
# does render-templates.sh for phpstan.neon (template 3, ADR 0020: a
# template-2 copy upgraded, a new tmpDir per plan, --profile). The data is the
# snapshot tests/golden/plans pins.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/plans/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
mkroot() {
  mkdir -p "$1/web/core/lib" "$1/web/modules/custom" "$1/vendor/bin"
  printf '{"name":"x/root"}\n' > "$1/composer.json"
  printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$1/web/core/lib/Drupal.php"
  cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$1/web/modules/custom/"
}
r="$T_TMP/root"; mkroot "$r"; S=web/modules/custom/legacy_widgets
INFO="$r/$S/legacy_widgets.info.yml"
rt() { t_run env DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/env/render-templates.sh" --root "$r" --subject "$S" --only rector --json "$@"; }
kept() { DRUPILOT_PROJECT_DIR="$r" lock_get ".templates[\"$1\"].sha256"; }
shaof() { printf 'sha256:%s' "$(sha256_hex < "$1")"; }

rt --dry-run
assert_eq "a dry run writes no file and no lock" "$T_RC|$([[ -e "$r/rector.php" ]] && echo file)|$([[ -e "$(lock_path "$r")" ]] && echo lock)" "0||"
rt
assert_eq "written, its sha256 kept" "$T_RC|$(jq -r '.files[0].status' "$T_OUT")|$([[ "$(kept rector.php)" == "$(shaof "$r/rector.php")" ]] && echo kept)" "0|written|kept"
assert_eq "  with the template's version" "$(DRUPILOT_PROJECT_DIR="$r" lock_get '.templates["rector.php"].template_version')" "5"
assert_eq "  rector-compat.php too" "$([[ "$(kept rector-compat.php)" == "$(shaof "$r/rector-compat.php")" ]] && echo kept)" "kept"
rt
assert_eq "the same plan: unchanged" "$T_RC|$(jq -c '[.files[].status]' "$T_OUT")" '0|["unchanged","unchanged"]'

# The plan moves while the floor stays: ^10.3 keeps 8.1 but enables BC.
sed_inplace "$INFO" 's/^core_version_requirement: .*/core_version_requirement: ^10.3/'
rt
assert_eq "an untouched render, another plan, same floor: upgraded" "$T_RC|$(jq -r '.files[0].status' "$T_OUT")" "0|upgraded"
assert_eq "  now with the BC block from 10.3.0" "$(grep -c "setMinimumCoreVersionSupported('10.3.0')" "$r/rector.php")" "1"
b="$(jq -r '.files[0].backup // empty' "$T_OUT")"
assert_eq "  the previous copy backed up" "$([[ -n "$b" && -f "$b" ]] && { grep -c setMinimumCoreVersionSupported "$b" || true; } || echo none)" "0"
assert_eq "  and the new sha256 kept" "$([[ "$(kept rector.php)" == "$(shaof "$r/rector.php")" ]] && echo kept)" "kept"

# A hand edit is never overwritten without --force.
printf '\n// hand edit\n' >> "$r/rector.php"; cp "$r/rector.php" "$T_TMP/edited.php"
sed_inplace "$INFO" 's/^core_version_requirement: .*/core_version_requirement: ^10/'
rt
assert_eq "hand-edited, the plan moved: differs, exit 3" "$T_RC|$(jq -r '.files[0].status' "$T_OUT")" "3|differs"
assert_file_eq "  the hand edit stays" "$r/rector.php" "$T_TMP/edited.php"
rt --force
assert_eq "--force: replaced" "$T_RC|$(jq -r '.files[0].status' "$T_OUT")" "0|replaced"
b="$(jq -r '.files[0].backup // empty' "$T_OUT")"
assert_file_eq "  the hand-edited copy backed up" "$b" "$T_TMP/edited.php"

# run-rector.sh: a stub Rector; an untouched render for another plan is
# regenerated, and the sha256 of what it writes is kept.
mk_bin() { printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
STUBS="$T_TMP/stubs"; mkdir -p "$STUBS"
mk_bin "$STUBS/php" 'case "$1" in -r) echo 8.3.30;; -v) echo "PHP 8.3.30 (cli)";; -l) echo "No syntax errors detected in $2";; esac; exit 0'
mk_bin "$STUBS/composer" 'echo "Composer version 2.8.0 2025-01-01 00:00:00"; exit 0'
mk_bin "$r/vendor/bin/rector" 'echo " [OK] Rector is done!"; exit 0'
rr() { t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 DRUPILOT_USE_DIGESTS_RULES=false "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$r/$S" --json; }
sed_inplace "$INFO" 's/^core_version_requirement: .*/core_version_requirement: ^10.3/'
rr
assert_eq "run-rector: the untouched render is regenerated for the new plan" \
  "$T_RC|$(grep -c "setMinimumCoreVersionSupported('10.3.0')" "$r/rector.php")|$(grep -c 'regenerated' "$T_ERR")" "0|1|1"
assert_eq "  and its sha256 kept" "$([[ "$(kept rector.php)" == "$(shaof "$r/rector.php")" ]] && echo kept)" "kept"
assert_eq "  with no false render error (the comparison reads the whole render)" "$(grep -c 'Could not render' "$T_ERR" || true)" "0"

# The lock lost its record (a cleared lock, a moved root): the untouched render
# is kept again as soon as it is found equal to the current render...
lk="$(lock_path "$r")"; jq 'del(.templates)' "$lk" > "$T_TMP/lk" && cat "$T_TMP/lk" > "$lk"
rr
assert_eq "run-rector: the current render, no sha256 kept -> kept again, the file untouched" \
  "$T_RC|$([[ "$(kept rector.php)" == "$(shaof "$r/rector.php")" ]] && echo kept)" "0|kept"
jq 'del(.templates)' "$lk" > "$T_TMP/lk" && cat "$T_TMP/lk" > "$lk"
rt
assert_eq "render-templates: unchanged -> kept again" \
  "$T_RC|$(jq -r '.files[0].status' "$T_OUT")|$([[ "$(kept rector.php)" == "$(shaof "$r/rector.php")" ]] && echo kept)" "0|unchanged|kept"
# ... and while it is not, it counts as hand-edited: never overwritten.
jq 'del(.templates)' "$lk" > "$T_TMP/lk" && cat "$T_TMP/lk" > "$lk"
cp "$r/rector.php" "$T_TMP/unrecorded.php"
sed_inplace "$INFO" 's/^core_version_requirement: .*/core_version_requirement: ^11/'
rt
assert_eq "render-templates: an untouched render whose sha256 was lost, the plan moved: differs" \
  "$T_RC|$(jq -r '.files[0].status' "$T_OUT")" "3|differs"
rr
assert_file_eq "run-rector: left untouched too" "$r/rector.php" "$T_TMP/unrecorded.php"
assert_eq "  the warning names the lost record" "$(grep -c 'its sha256 is not kept in the lock' "$T_ERR")" "1"
rt --force
assert_eq "--force replaces it" "$T_RC|$(jq -r '.files[0].status' "$T_OUT")" "0|replaced"
printf '\n// hand edit\n' >> "$r/rector.php"; cp "$r/rector.php" "$T_TMP/edited2.php"
sed_inplace "$INFO" 's/^core_version_requirement: .*/core_version_requirement: ^10/'
rr
assert_file_eq "run-rector: a hand-edited rector.php is left as it is" "$r/rector.php" "$T_TMP/edited2.php"

# phpstan.neon (template 3, ADR 0020): the same rules, its tmpDir keyed by the
# plan, its profile the plan's unless --profile names one.
rs() { t_run env DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/env/render-templates.sh" --root "$r" --subject "$S" --only phpstan --json "$@"; }
N="$r/phpstan.neon"
cp "$T_REPO/tests/fixtures/rector-render/legacy_widgets/phpstan.v2.neon" "$N"
rs
assert_eq "phpstan: a template-2 copy is upgraded, the plan's compat profile" \
  "$T_RC|$(jq -r '.files[0].status' "$T_OUT")|$(jq -r .phpstan_profile "$T_OUT")|$(jq -r .plan "$T_OUT")|$(jq -r .php_floor "$T_OUT")" "0|upgraded|compat|plan|null"
assert_eq "  its sha256 kept" "$([[ "$(kept phpstan.neon)" == "$(shaof "$N")" ]] && echo kept)" "kept"
k1="$(sed -n 's/^  tmpDir: //p' "$N")"
sed_inplace "$INFO" 's/^core_version_requirement: .*/core_version_requirement: ^10.3/'
rs
k2="$(sed -n 's/^  tmpDir: //p' "$N")"
assert_eq "phpstan: the plan moves -> an untouched render upgraded, another cache directory" \
  "$T_RC|$(jq -r '.files[0].status' "$T_OUT")|$([[ "$k1" != "$k2" && "$k2" == .phpstan-cache/* ]] && echo moved)" "0|upgraded|moved"
rs --profile refactor
assert_eq "phpstan: --profile refactor -> upgraded, no rule turned off" \
  "$T_RC|$(jq -r '.files[0].status' "$T_OUT")|$(jq -r .phpstan_profile "$T_OUT")|$(grep -c 'Rule: false' "$N" || true)|$(grep -c '^# drupilot-phpstan-profile: refactor$' "$N")" "0|upgraded|refactor|0|1"
rs --profile nope
assert_eq "phpstan: an unknown profile is a usage error" "$T_RC" "1"
printf '\n# hand edit\n' >> "$N"; cp "$N" "$T_TMP/edited.neon"
rs
assert_eq "phpstan: hand-edited -> differs, exit 3, kept" \
  "$T_RC|$(jq -r '.files[0].status' "$T_OUT")|$(cmp -s "$N" "$T_TMP/edited.neon" && echo same)" "3|differs|same"
rs --force
assert_eq "phpstan: --force replaces it, compat again" "$T_RC|$(jq -r '.files[0].status' "$T_OUT")|$(grep -c 'Rule: false' "$N")" "0|replaced|4"
t_done
