#!/usr/bin/env bash
# The port's artifacts after the test stage (lab L-PC: the local patch, the
# core matrix and port-report.md were left from before the test stage adapted
# the tests, and a report rendered without --manifest said require.php "none"
# and the version bump "n/a").
# - refresh-artifacts.sh: nothing to refresh without a port manifest; with
#   one, a stale core matrix, the patch, the extraction of a worklist of
#   other sources and the report would run (--dry-run); an up-to-date core
#   matrix, DRUPILOT_VERIFY_CORES=off, a range with no previous major and
#   --skip are said; the patch step really runs (make-patch.sh --local); a
#   failed extraction fails the step and leaves the report unrendered
#   (exit 3); the usage errors;
# - port-report.sh without --manifest renders the module's own
#   port-manifest.json and records no stage.
# Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
RF="$T_REPO/scripts/analysis/refresh-artifacts.sh"
st() { jq -c '[.steps[] | [.step, .status]]' "$T_OUT"; }

# A module in its own repository (no Drupal root), ported: a commit, a change.
S="$T_TMP/m"; mkdir -p "$S/src"
printf 'name: M\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$S/m.info.yml"
printf '<?php\nnamespace Drupal\\m;\nclass A {}\n' > "$S/src/A.php"
g() { git -C "$S" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
g init -q; g add -A; g commit -qm base
printf '<?php\nnamespace Drupal\\m;\nclass A { public function b(): void {} }\n' > "$S/src/A.php"
SD="$(project_state_dir "$S")"

t_run "$T_SH" "$RF" --subject "$S" --json
assert_eq "no port manifest: nothing to refresh, exit 0" "$T_RC|$(st)" '0|[["all","skipped"]]'

jq -n '{schema: 1, tool: "manifest", phase: "port", machine_name: "m", core_version_requirement: "^10 || ^11",
        require_php: ">=8.1", version_bump: "major", meta: {generated_at: "2026-01-01T00:00:00Z"}}' > "$SD/port-manifest.json"
jq -n '{subject_digest: "sha256:old", d10_support: "verified-static"}' > "$SD/core-matrix.json"
t_run "$T_SH" "$RF" --subject "$S" --dry-run --json
assert_eq "--dry-run: a stale core matrix, the patch, the extraction and the report would run" \
  "$T_RC|$(st)" '0|[["core-matrix","would-run"],["patch","would-run"],["extraction","would-run"],["report","would-run"]]'
assert_eq "  nothing ran" "$(ls "$S" | tr '\n' ' ')" "m.info.yml src "
jq --arg d "$(subject_digest "$S")" '.subject_digest = $d' "$SD/core-matrix.json" > "$T_TMP/cm.json" && mv "$T_TMP/cm.json" "$SD/core-matrix.json"
t_run "$T_SH" "$RF" --subject "$S" --dry-run --json
assert_eq "  a core matrix of the module as it is: up to date" "$(jq -c '.steps[0] | [.step, .status]' "$T_OUT")" '["core-matrix","up-to-date"]'
jq '.subject_digest = "sha256:old"' "$SD/core-matrix.json" > "$T_TMP/cm.json" && mv "$T_TMP/cm.json" "$SD/core-matrix.json"
t_run env DRUPILOT_VERIFY_CORES=off "$T_SH" "$RF" --subject "$S" --dry-run --json
assert_eq "  DRUPILOT_VERIFY_CORES=off: skipped" "$(jq -c '.steps[0] | [.status, .reason]' "$T_OUT")" '["skipped","DRUPILOT_VERIFY_CORES is off"]'
sed_inplace "$S/m.info.yml" 's/^core_version_requirement: .*/core_version_requirement: ^11/'
t_run "$T_SH" "$RF" --subject "$S" --dry-run --json
assert_eq "  a range with no Drupal 10: skipped" "$(jq -c '.steps[0].status' "$T_OUT")" '"skipped"'
sed_inplace "$S/m.info.yml" 's/^core_version_requirement: .*/core_version_requirement: ^10 || ^11/'

t_run "$T_SH" "$RF" --subject "$S" --skip core-matrix,report --json
assert_eq "the patch step runs make-patch.sh --local" "$T_RC|$(st)" '0|[["core-matrix","skipped"],["patch","ran"],["report","skipped"]]'
assert_match "  the patch holds the change" "$(cat "$S/m-port-to-drupal-11.patch" 2> /dev/null)" 'public function b\(\): void'
t_run "$T_SH" "$RF" --subject "$S" --skip core-matrix,patch --json
assert_eq "an extraction that fails (no Drupal root): failed, the report not rendered, exit 3" \
  "$T_RC|$(st)" '3|[["core-matrix","skipped"],["patch","skipped"],["extraction","failed"],["report","failed"]]'

t_run "$T_SH" "$RF" --subject "$S" --skip nope
assert_eq "an unknown step to skip: exit 1" "$T_RC" "1"
t_run "$T_SH" "$RF"
assert_eq "no --subject: exit 1" "$T_RC" "1"
t_run "$T_SH" "$RF" --subject "$S" --bogus
assert_eq "an unknown flag: exit 1" "$T_RC" "1"

# port-report.sh without --manifest: the module's own manifest, no stage.
# (The manifest makes the state's snapshot say ported already, state_merge:
# the bare render must not write the state, a --manifest one records it.)
SF="$(subject_state_file "$S")"; cp "$SF" "$T_TMP/state.keep" 2> /dev/null || : > "$T_TMP/state.keep"
t_run "$T_SH" "$T_REPO/scripts/analysis/port-report.sh" --subject "$S" --output "$T_TMP/out"
REP="$(cat "$T_TMP/out/port-report.md" 2> /dev/null || true)"
assert_match "port-report.sh without --manifest: the module's port-manifest.json" "$REP" '\| composer `require.php` \| `>=8\.1` \|'
assert_match "  its version bump" "$REP" '\| Version bump \| major \|'
assert_match "  it says which manifest it read" "$(t_err)" "No --manifest given: rendering with the module's"
assert_eq "  the state is not written (no stage recorded)" "$(cmp -s "$SF" "$T_TMP/state.keep" && echo same)" "same"
t_run "$T_SH" "$T_REPO/scripts/analysis/port-report.sh" --subject "$S" --output "$T_TMP/out" --manifest "$SD/port-manifest.json"
assert_match "  with --manifest the stage is recorded" "$(t_err)" "Recorded stage 'ported'"
t_done
