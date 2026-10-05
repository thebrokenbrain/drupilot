#!/usr/bin/env bash
# upgrade-path.sh's usage errors (exit 1, nothing on STDOUT) and refusals
# (exit 2, the refusal shape of ADR 0017 on STDOUT): a bad --phase, --target,
# --php or --strategy, keep-current as an input, --strategy explicit without
# --range, --range with another strategy, --phpstan without --phase final, a
# missing subject; a target with no toolchain cell (invalid-target) and a
# module already above the target (source-above-target, G18). An explicit
# range is taken verbatim, but it must admit the bed core
# (range-excludes-bed). The root's .drupilot.json and lock are found from
# the subject's logical path, from any cwd (a symlink placement too); a
# standard-track S of 7 starts the hops at 8; a Drupal 7 subject's machine
# name comes from its .info. The data is the snapshot tests/golden/plans pins.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/plans/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
UP="$T_REPO/scripts/analysis/upgrade-path.sh"; LW="$T_REPO/tests/fixtures/legacy_widgets"
up() { t_run "$T_SH" "$UP" "$@"; }

usage_err() {
  local label="$1"; shift
  up "$@"
  assert_eq "$label: exit 1, nothing on STDOUT" "$T_RC|$(t_out)" "1|"
}
usage_err "--phase x" --subject "$LW" --phase x
usage_err "--target abc" --subject "$LW" --target abc
usage_err "--php 8" --subject "$LW" --php 8
usage_err "--strategy bogus" --subject "$LW" --strategy bogus
usage_err "keep-current is not an input" --subject "$LW" --strategy keep-current
usage_err "--strategy explicit without --range" --subject "$LW" --strategy explicit
usage_err "--range with --strategy auto" --subject "$LW" --strategy auto --range '^11'
usage_err "--phpstan without --phase final" --subject "$LW" --phpstan "$T_TMP/x.json"
usage_err "a missing subject" --subject "$T_TMP/nope"
usage_err "an unknown argument" --subject "$LW" --bogus
usage_err "--target 011 (a leading zero)" --subject "$LW" --target 011
usage_err "--target 09" --subject "$LW" --target 09
usage_err "an empty --range" --subject "$LW" --range ''
usage_err "a --range with no lower bound" --subject "$LW" --range 'foo'
DRUPILOT_PHPSTAN_LEVEL='5 6' usage_err "an invalid DRUPILOT_PHPSTAN_LEVEL" --subject "$LW"
up --help
assert_eq "--help: exit 0" "$T_RC" "0"
assert_match "--help: the usage" "$(t_out)$(t_err)" 'upgrade-path\.sh \[--subject DIR\]'

up --subject "$LW" --target 10 --json
assert_eq "--target 10: exit 2" "$T_RC" "2"
assert_eq "--target 10: invalid-target, re-ask the target" \
  "$(jq -c '[.status, .code, [.choices[] | .tab]]' "$T_OUT")" '["refused","invalid-target",["TARGET_MAJOR"]]'
assert_eq "the refusal's shape" "$(jq -c 'keys' "$T_OUT")" '["choices","code","message","phase","schema_version","status","violations"]'

up --subject "$LW" --php 9.0 --json
assert_eq "a PHP the data does not know: php-not-supported, re-ask the PHP target" \
  "$T_RC|$(jq -c '[.code, [.choices[] | .tab]]' "$T_OUT")" '2|["php-not-supported",["PHP_TARGET"]]'

# A range that does not admit the bed core: the module could not be installed on it.
mkdir -p "$T_TMP/m115"
printf 'name: M\ntype: module\ncore_version_requirement: ^11.5\n' > "$T_TMP/m115/m115.info.yml"
up --subject "$T_TMP/m115" --json
assert_eq "a kept ^11.5 on the 11.4.8 bed: range-excludes-bed, re-ask the core range" \
  "$T_RC|$(jq -c '[.code, [.choices[] | .id], .choices[1].set]' "$T_OUT")" \
  '2|["range-excludes-bed",["core-target","target-only"],{"DRUPILOT_CORE_TARGET_STRATEGY":"d11-only"}]'
up --subject "$LW" --range '^10.3' --json
assert_eq "an explicit ^10.3 for Drupal 11: range-excludes-bed" "$T_RC|$(jq -r .code "$T_OUT")" "2|range-excludes-bed"

# A Drupal root: its .drupilot.json is read from any cwd, its lock names the
# bed core, and a subject placed there through a symlink finds both.
B="$T_TMP/bed"; mkdir -p "$B/web/core/lib" "$B/web/modules/custom" "$T_TMP/elsewhere"
printf '{"require": {"drupal/core-recommended": "^11"}}\n' > "$B/composer.json"
printf '<?php\n' > "$B/web/core/lib/Drupal.php"
cp -R "$LW" "$B/web/modules/custom/legacy_widgets"
printf '{"DRUPILOT_PHP_TARGET": "8.4", "DRUPILOT_CORE_TARGET_STRATEGY": "d11-only"}\n' > "$B/.drupilot.json"
( cd "$T_TMP/elsewhere" && "$T_SH" "$UP" --subject "$B/web/modules/custom/legacy_widgets" --json ) > "$T_TMP/p.json" 2> /dev/null
assert_eq "the root's .drupilot.json, from another cwd" "$(jq -c '[.php.final, .range.constraint]' "$T_TMP/p.json")" '["8.4","^11"]'
( cd "$B" && "$T_SH" "$UP" --subject "$LW" --json ) > "$T_TMP/p.json" 2> /dev/null
assert_eq "another root's .drupilot.json is not read for a subject outside it" "$(jq -c '[.php.final, .range.constraint]' "$T_TMP/p.json")" '["8.3","^10 || ^11"]'
rm -f "$B/.drupilot.json"
# shellcheck source=../../scripts/lib/common.sh
( . "$T_LIB"; DRUPILOT_PROJECT_DIR="$B" lock_set .drupal.core 11.5.0 )
mkdir -p "$T_TMP/m115b"; printf 'name: M\ntype: module\ncore_version_requirement: ^11.5\n' > "$T_TMP/m115b/m115b.info.yml"
cp -R "$T_TMP/m115b" "$B/web/modules/custom/m115b"
up --subject "$B/web/modules/custom/m115b" --json
assert_eq "the lock's 11.5.0 bed; L from 11.4's php_min (11.5 has none in the data)" \
  "$T_RC|$(jq -c '[.target.bed_core, .range.constraint, .php.floor]' "$T_OUT")" '0|["11.5.0","^11.5","8.3"]'
cp -R "$LW" "$T_TMP/origin_lw"; mv "$T_TMP/origin_lw" "$T_TMP/legacy_widgets_origin"
ln -s "$T_TMP/legacy_widgets_origin" "$B/web/modules/custom/lwsym"
up --subject "$B/web/modules/custom/lwsym" --json
assert_eq "a symlink-placed subject finds the root and its lock" "$T_RC|$(jq -r .target.bed_core "$T_OUT")" "0|11.5.0"
ln -s "$B" "$T_TMP/bedlink"
up --subject "$T_TMP/bedlink/web/modules/custom/legacy_widgets" --root "$T_TMP/bedlink" --json
assert_eq "a root reached through a symlink: the lock it was written under" "$T_RC|$(jq -r .target.bed_core "$T_OUT")" "0|11.4.8"

# A standard-track module whose analyzer output names a removal in Drupal 8:
# S is 7, the hops start at 8 (never the D7 rewrite edge).
printf '%s' '{"files":{"x.php":{"messages":[{"line":3,"message":"Call to deprecated function x():\nin drupal:7.0.0 and is removed from drupal:8.0.0."}]}}}' > "$T_TMP/p8.json"
up --subject "$LW" --phase final --phpstan "$T_TMP/p8.json" --json
assert_eq "S 7 on the standard track: hops from 8" "$T_RC|$(jq -c '[.source.major, .source.track, .hops]' "$T_OUT")" '0|[7,"standard",["8-9","9-10","10-11"]]'

# A Drupal 7 subject: its machine name from the .info.
up --subject "$T_REPO/tests/fixtures/d7_minimal" --json
assert_eq "D7: the .info's machine name and patch name" "$T_RC|$(jq -c '[.subject.machine_name, .subject.type, .patch_name]' "$T_OUT")" '0|["d7_minimal","module","d7_minimal-port-to-drupal-11.patch"]'
mkdir -p "$T_TMP/d7theme"; printf 'name = T\ncore = 7.x\nengine = phptemplate\n' > "$T_TMP/d7theme/d7theme.info"
up --subject "$T_TMP/d7theme" --json
assert_eq "D7: a theme names an engine" "$T_RC|$(jq -c '[.subject.machine_name, .subject.type]' "$T_OUT")" '0|["d7theme","theme"]'

# G18: a module that already declares only Drupal 12, ported to 11.
mkdir -p "$T_TMP/only12"
printf 'name: Only 12\ntype: module\ncore_version_requirement: ^12\n' > "$T_TMP/only12/only12.info.yml"
up --subject "$T_TMP/only12" --json
assert_eq "a ^12 module for T 11: source-above-target" "$T_RC|$(jq -r .code "$T_OUT")" "2|source-above-target"

up --subject "$LW" --range '^10.2 || ^11' --json
assert_eq "an explicit range: verbatim, explicit" \
  "$T_RC|$(jq -c '[.range.strategy, .range.resolved_strategy, .range.constraint, .range.floor, .rector.bc.enabled]' "$T_OUT")" \
  '0|["explicit","explicit","^10.2 || ^11","10.2",true]'
up --subject "$LW" --strategy explicit --range '^10.3 || ^11 || ^12' --json
assert_eq "an explicit three-major range is allowed" "$T_RC|$(jq -r .range.spans_majors "$T_OUT")" "0|true"
up --subject "$LW" --json
assert_eq "--json: the plan on STDOUT" "$T_RC|$(jq -r .schema_version "$T_OUT")" "0|1"
up --subject "$LW"
assert_match "without --json: a summary on STDERR" "$(t_err)" 'Upgrade plan \(draft\): Drupal 10 -> 11'
t_done
