#!/usr/bin/env bash
# Rule D7-AUTO (AR-07, ADR 0017; t_d7_auto_refused): a Drupal 7 source in an
# autonomous run (--auto, or DRUPILOT_AUTONOMOUS=true) is refused in both
# phases, exit 2 with AR-07's exact message on STDOUT (.message) and alone on
# STDERR, before anything is written: drupilot's data dir and the subject stay
# byte for byte as they were. Outside auto the D7 subject gets its plan.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
MSG="D7 source detected: the d7-assisted track is experimental and never runs in auto. Run '/drupilot full' with DRUPILOT_EXPERIMENTAL_D7=on, or '/drupilot-assess' for a viability verdict."
cp -R "$T_REPO/tests/fixtures/d7_minimal" "$T_TMP/d7_minimal"
mkdir -p "$HOME/.local/share/drupilot"
UP="$T_REPO/scripts/analysis/upgrade-path.sh"

for phase in draft final; do
  assert_tree_unchanged "--auto, $phase: the subject is untouched" "$T_TMP/d7_minimal" \
    "$T_SH" "$UP" --subject "$T_TMP/d7_minimal" --phase "$phase" --auto --json
  assert_eq "--auto, $phase: exit 2" "$T_RC" "2"
  assert_eq "--auto, $phase: code d7-auto" "$(jq -r .code "$T_OUT")" "d7-auto"
  assert_eq "--auto, $phase: the exact message" "$(jq -r .message "$T_OUT")" "$MSG"
  assert_eq "--auto, $phase: the message alone on STDERR" "$(t_err)" "$MSG"
done
assert_tree_unchanged "DRUPILOT_AUTONOMOUS=true: drupilot's data dir is untouched" "$HOME" \
  env DRUPILOT_AUTONOMOUS=true "$T_SH" "$UP" --subject "$T_TMP/d7_minimal" --json
assert_eq "DRUPILOT_AUTONOMOUS=true: exit 2, d7-auto" "$T_RC|$(jq -r .code "$T_OUT")" "2|d7-auto"
t_run "$T_SH" "$UP" --subject "$T_TMP/d7_minimal" --json
assert_eq "outside auto: the d7-assisted plan" "$T_RC|$(jq -c '[.source.track, .hops]' "$T_OUT")" '0|["d7-assisted",["7-11"]]'
t_done
