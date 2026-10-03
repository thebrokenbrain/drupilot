#!/usr/bin/env bash
# CC-28 / AR-27: the SessionStart hook writes nothing (no state, no data dir,
# nothing in the module, nothing in HOME), whatever context it prints. (The
# ddev binary creates ~/.ddev the first time it runs in an empty HOME: that is
# DDEV's own setup, not drupilot's, and is ignored.)
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
m="$T_TMP/fx/legacy_widgets"; mkdir -p "$T_TMP/fx"; cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$m"
printf '{"cwd":"%s"}' "$m" > "$T_TMP/session.json"
assert_tree_unchanged "SessionStart in a module dir: the module is unchanged" "$m" \
  "$T_SH" -c 'cd "$1" && "$2" "$3" < "$4"' _ "$m" "$T_SH" "$T_REPO/hooks/scripts/session-detect-env.sh" "$T_TMP/session.json"
assert_eq "exit 0" "$T_RC" "0"
assert_eq "no drupilot data dir was created" "$([[ -e "$XDG_DATA_HOME/drupilot" ]] && echo created || echo none)" "none"
assert_eq "nothing else in HOME (but DDEV's own ~/.ddev)" \
  "$(cd "$HOME" && find . -mindepth 1 ! -path './.ddev' ! -path './.ddev/*' | head -n 5 | tr '\n' ' ')" ""
assert_eq "it printed hook context" "$(jq -r '.hookSpecificOutput.hookEventName // empty' "$T_OUT" 2>/dev/null)" "SessionStart"
t_done
