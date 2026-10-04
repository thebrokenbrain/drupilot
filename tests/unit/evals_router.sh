#!/usr/bin/env bash
# scripts/dev/evals.sh on a scratch copy of the plugin: the static layer fails
# when a natural-language port no longer maps to `full`, when a bare
# `/drupilot` no longer maps to `next`, when two tabs swap places and when a
# rule that keeps an auto run tab-free is dropped. The live layer, run against
# a stub `claude` (no model), never counts a failed or empty run as a pass:
# the auto case needs an explicit NO_TABS reply.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
c="$T_TMP/plugin"; mkdir -p "$c"
for d in scripts config commands skills agents hooks templates .claude-plugin; do cp -R "$T_REPO/$d" "$c/"; done
# static -> the names of the failing static checks, comma-separated.
static() {
  "$T_SH" "$T_REPO/scripts/dev/evals.sh" --plugin-root "$c" --json 2>/dev/null \
    | jq -r '[.checks[] | select(.status != "pass") | .name] | join(",")'
}
# mutate <label> <file> <perl-free sed program> <expected failing check>
mutate() {
  local f="$c/$2"
  cp "$f" "$T_TMP/orig"; sed "$3" "$T_TMP/orig" > "$f"
  if cmp -s "$f" "$T_TMP/orig"; then assert_eq "$1: the mutation applies" "no change" "a change"; return 0; fi
  assert_match "$1" "$(static)" "$4"
  cp "$T_TMP/orig" "$f"
}
assert_eq "the copy passes" "$(static)" ""
mutate "a port request mapped to auto fails" commands/drupilot.md \
  's/^    \*\*`full`\*\* — or \*\*`auto`\*\* if the user/    **`auto`** — or **`auto`** if the user/' 'mode-inference: port this to Drupal 11'
mutate "a bare /drupilot moved to the status rule fails" commands/drupilot.md \
  's/^  - An \*\*exploratory\*\* request or a bare `\/drupilot` (/  - An **exploratory** request (/; s/^  - A \*\*status\*\* request (/  - A **status** request or a bare `\/drupilot` (/' 'mode-inference: a bare `/drupilot`'
mutate "two swapped tabs fail" commands/drupilot-port.md \
  's/--key CORE_TARGET/--key TMP_SWAP/; s/--key DIGESTS_RULES/--key CORE_TARGET/; s/--key TMP_SWAP/--key DIGESTS_RULES/' 'tab-sequence'
mutate "a dropped auto rule fails" agents/drupal-port-orchestrator.md \
  's/\*\*Never perform any outward-facing action\.\*\*/**Avoid outward-facing actions.**/' 'auto rule: \*\*Never perform'

# The live scorer, with a stub claude on PATH.
mkdir -p "$T_TMP/bin"
live() {  # live <stub body> -> "<ok>|<auto passed>|<total passed>"
  printf '#!/bin/sh\n%s\n' "$1" > "$T_TMP/bin/claude"; chmod +x "$T_TMP/bin/claude"
  PATH="$T_TMP/bin:$PATH" "$T_SH" "$T_REPO/scripts/dev/evals.sh" --live --runs 1 --jobs 4 --plugin-root "$c" --json 2>/dev/null \
    | jq -r '"\(.ok)|\([.cases[] | select(.name == "drupilot auto") | .passed][0])|\([.cases[].passed] | add)"'
}
assert_eq "a logged-out claude passes nothing (auto included)" "$(live 'echo "Invalid API key · Please run /login"; exit 1')" "false|0|0"
assert_eq "an empty answer passes nothing (auto included)" "$(live 'exit 0')" "false|0|0"
assert_eq "an explicit NO_TABS passes the auto case" "$(live 'echo NO_TABS')" "false|1|1"
t_done
