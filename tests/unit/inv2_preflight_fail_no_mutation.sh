#!/usr/bin/env bash
# INV2: a failing gate makes no change. Every command that writes state has a
# gate line, `preflight.sh --profile P ... && ... copy_legacy_state_once`, and
# Claude Code runs every load-time !`...` span of a command whatever the gate
# returns. So, for each gated command, the gate line and then every load-time
# span (with $1/$ARGUMENTS replaced by the subject, as Claude Code does) run
# with a failing preflight, and must change neither the data dir, nor the
# legacy per-plugin data dir (CLAUDE_PLUGIN_DATA, as Claude Code exports it),
# nor the subject: no copy, no migration, no state. Two ways to fail:
#   * jq missing: preflight stops right after its argument parsing;
#   * a requirement of the profile missing (git for analyze and contribute,
#     docker and ddev for setup and test): preflight runs its whole body and
#     exits 2. The router's `--profile all` gate never fails that way (it
#     always exits 0 but on a missing jq or bad arguments), so it has the
#     first case only.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
w="$T_TMP/w"; uh="$w/uhome"; dh="$w/dh"; subj="$w/fx/legacy_widgets"; pd="$uh/.claude/plugins/data/drupilot-x"
mkdir -p "$pd/state/_srv_site" "$w/fx"
printf '{}\n' > "$pd/state/_srv_site/drupilot-lock.json"
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$w/fx/"
# The ddev binary sets up ~/.ddev the first time it runs in an empty HOME
# (DDEV's own setup, not drupilot's): let it happen before the snapshots.
if command -v ddev > /dev/null 2>&1; then HOME="$uh" ddev --version < /dev/null > /dev/null 2>&1 || true; fi

# spans <command> -> the gate line, then every load-time span, one per line,
# with $ARGUMENTS and a bare $1 replaced by the subject and $2 by nothing.
spans() {
  local f="$T_REPO/commands/$1.md"
  {
    sed -n 's/^!`\{0,1\}\(bash "${CLAUDE_PLUGIN_ROOT}\/scripts\/env\/preflight\.sh".*copy_legacy_state_once'"'"'\)`\{0,1\}$/\1/p' "$f" | head -n 1
    grep -o '!`[^`]*`' "$f" | sed 's/^!`//; s/`$//' | grep -v 'copy_legacy_state_once' || true
  } | awk -v s="$subj" '{ gsub(/\$ARGUMENTS/, s); gsub(/\$1/, s); gsub(/\$2/, ""); print }'
}
# run_all <command> <PATH> -> runs the gate line (its exit code goes to
# $T_TMP/gate.rc) and then every load-time span, in order, from the subject,
# as one shell each, with the command environment Claude Code gives them.
run_all() {
  local c="$1" p="$2" s first=1 rc
  spans "$c" | while IFS= read -r s; do
    if env PATH="$p" HOME="$uh" DRUPILOT_HOME="$dh" CLAUDE_PLUGIN_DATA="$pd" "$T_SH" -c "cd '$subj' && $s" > /dev/null 2>&1; then rc=0; else rc=$?; fi
    if [[ "$first" == "1" ]]; then printf '%s' "$rc" > "$T_TMP/gate.rc"; first=0; fi
  done
  return 0
}

nojq="$(t_path_without jq)"
nogit="$(t_path_without git)"
nodocker="$(t_path_without docker ddev)"
n=0
for c in drupilot drupilot-setup drupilot-assess drupilot-port drupilot-refactor drupilot-test \
         drupilot-contribute drupilot-layers drupilot-clean; do
  gate="$(spans "$c" | head -n 1)"
  assert_match "$c: gate line found" "$gate" 'preflight\.sh" --profile [a-z]+'
  case "$gate" in *preflight.sh*) ;; *) continue;; esac
  n=$((n + 1))
  profile="$(printf '%s' "$gate" | sed -n 's/.*--profile \([a-z]*\).*/\1/p')"
  assert_tree_unchanged "$c: no jq -> the gate line and every load-time span change nothing" "$w" run_all "$c" "$nojq"
  assert_eq "$c: no jq -> the gate fails" "$([[ "$(cat "$T_TMP/gate.rc")" != 0 ]] && echo failed || echo passed)" "failed"
  case "$profile" in
    analyze|contribute) p="$nogit"; why="no git";;
    setup|test) p="$nodocker"; why="no docker/ddev";;
    *) continue;;
  esac
  assert_tree_unchanged "$c: $why -> the gate line and every load-time span change nothing" "$w" run_all "$c" "$p"
  assert_eq "$c: $why -> the gate exits 2" "$(cat "$T_TMP/gate.rc")" "2"
done
assert_eq "every gated command checked" "$n" "9"
t_done
