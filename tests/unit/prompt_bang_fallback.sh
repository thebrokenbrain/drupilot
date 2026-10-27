#!/usr/bin/env bash
# Every prompt with a load-time !`...` span carries the fixed fallback line
# (AR-26, T-M3-13): a session that turns those spans off
# (disableSkillShellExecution) still learns where the version facts come
# from. The plan block it points to is printed by scripts/drupilot.sh plan
# show: "drupilot plan" first, the facts from the upgrade plan only.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
LINE='If no "drupilot plan" block appears above, run: bash "${CLAUDE_PLUGIN_ROOT}/scripts/drupilot.sh" plan show'
n=0; missing=""
for f in "$T_REPO"/commands/*.md "$T_REPO"/skills/*/SKILL.md "$T_REPO"/agents/*.md; do
  # A span opens a line or follows a blank (not "@user!`" in prose).
  grep -qE '(^|[[:space:]])!`' "$f" || continue
  n=$((n + 1))
  grep -qF -- "$LINE" "$f" || missing="$missing ${f#"$T_REPO"/}"
done
assert_eq "every prompt with a !\` span carries the fallback line" "${missing:-none}" "none"
assert_eq "  (the commands with load-time spans are among them)" "$([[ "$n" -ge 7 ]] && echo yes)" "yes"

DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/plans/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$T_TMP/legacy_widgets"
D="$T_REPO/scripts/drupilot.sh"
t_run "$T_SH" "$D" plan show --subject "$T_TMP/legacy_widgets"
assert_eq "plan show: the drupilot plan block" "$T_RC|$(t_out | sed -n '1p')" "0|drupilot plan (a draft, not frozen):"
assert_match "  its facts come from the plan" "$(t_out | tr '\n' ' ')" "declared range: \\^10 \\|\\| \\^11 .*PHP: floor 8\\.1, target 8\\.3"
t_run "$T_SH" "$D" plan show --subject "$T_TMP/legacy_widgets" --json
assert_eq "plan show --json: the plan" "$(jq -r '[.schema_version, .target.major] | @tsv' "$T_OUT")" "1	11"
t_run "$T_SH" "$D" plan show --subject "$T_TMP"
assert_eq "no module here: one line, exit 0" "$T_RC|$(t_out | grep -c . )|$(t_out | cut -c1-27)" "0|1|drupilot plan: no module or"
t_run "$T_SH" "$D" plan show --subject auto
assert_eq "a value that is not a directory (a mode word): the current directory" "$T_RC|$(t_out | cut -c1-27)" "0|drupilot plan: no module or"
t_run "$T_SH" "$D" assess
assert_eq "another verb: a usage error until drupilot.sh gains it" "$T_RC" "1"
t_done
