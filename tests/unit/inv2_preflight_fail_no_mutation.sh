#!/usr/bin/env bash
# INV2: a failing gate makes no change. Every command that writes state runs
# `preflight.sh ... && ... copy_legacy_state_once` as its gate line; with a
# preflight that fails (no jq on PATH) that line changes neither the data dir,
# nor the legacy per-plugin data dir, nor the subject (no copy, no migration).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
w="$T_TMP/w"; uh="$w/uhome"; dh="$w/dh"; subj="$w/fx/legacy_widgets"
mkdir -p "$uh/.claude/plugins/data/drupilot-x/state/_srv_site" "$w/fx"
printf '{}\n' > "$uh/.claude/plugins/data/drupilot-x/state/_srv_site/drupilot-lock.json"
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$w/fx/"
nojq="$(t_path_without jq)"
n=0
for c in drupilot drupilot-setup drupilot-assess drupilot-port drupilot-refactor drupilot-test \
         drupilot-contribute drupilot-layers drupilot-clean; do
  line="$(sed -n 's/^!`\{0,1\}\(bash "${CLAUDE_PLUGIN_ROOT}\/scripts\/env\/preflight\.sh".*copy_legacy_state_once'"'"'\)`\{0,1\}$/\1/p' \
            "$T_REPO/commands/$c.md" | head -n 1)"
  assert_eq "$c: gate line found" "$([[ -n "$line" ]] && echo yes || echo no)" "yes"
  [[ -n "$line" ]] || continue
  n=$((n + 1))
  assert_tree_unchanged "$c: failing gate changes nothing" "$w" \
    env PATH="$nojq" HOME="$uh" DRUPILOT_HOME="$dh" "$T_SH" -c "cd '$subj' && $line"
  assert_eq "$c: the gate failed" "$([[ "$T_RC" != 0 ]] && echo failed || echo passed)" "failed"
done
assert_eq "every gated command checked" "$n" "9"
t_done
