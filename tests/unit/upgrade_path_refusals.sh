#!/usr/bin/env bash
# upgrade-path.sh's usage errors (exit 1, nothing on STDOUT) and refusals
# (exit 2, the refusal shape of ADR 0017 on STDOUT): a bad --phase, --target,
# --php or --strategy, keep-current as an input, --strategy explicit without
# --range, --range with another strategy, --phpstan without --phase final, a
# missing subject; a target with no toolchain cell (invalid-target) and a
# module already above the target (source-above-target, G18). An explicit
# range is taken verbatim. The data is the snapshot tests/golden/plans pins.
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
up --help
assert_eq "--help: exit 0" "$T_RC" "0"
assert_match "--help: the usage" "$(t_out)$(t_err)" 'upgrade-path\.sh \[--subject DIR\]'

up --subject "$LW" --target 10 --json
assert_eq "--target 10: exit 2" "$T_RC" "2"
assert_eq "--target 10: invalid-target, re-ask the target" \
  "$(jq -c '[.status, .code, [.choices[] | .tab]]' "$T_OUT")" '["refused","invalid-target",["TARGET_MAJOR"]]'
assert_eq "the refusal's shape" "$(jq -c 'keys' "$T_OUT")" '["choices","code","message","phase","schema_version","status","violations"]'

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
