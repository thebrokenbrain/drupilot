#!/usr/bin/env bash
# scripts/dev/evals.sh on a scratch copy of the plugin: the static layer fails
# when a natural-language port no longer maps to `full`, when a bare
# `/drupilot` no longer maps to `next`, when two tabs swap places, when a tab
# is inserted where allowed_insertions does not list it (or twice, or out of
# its listed order), and when a
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
# Mutations that keep every mode word in the rule, so only the cue-to-mode
# binding can see them (a "the rule names the mode somewhere" check cannot).
mutate "full and auto swapped in the port rule fail" commands/drupilot.md \
  's/^    \*\*`full`\*\* — or \*\*`auto`\*\* if the user/    **`auto`** — or **`full`** if the user/' 'mode-inference: port this to Drupal 11.*mode-inference: do everything yourself|mode-inference: do everything yourself.*mode-inference: port this to Drupal 11'
mutate "a bare /drupilot bound to status in the next rule fails" commands/drupilot.md \
  's/^  - An \*\*exploratory\*\* request or a bare `\/drupilot` ("what.s next", "where am I") →/  - An **exploratory** request ("what'"'"'s next", "where am I") → **`next`**; a bare `\/drupilot` →/; s/^    \*\*`next`\*\* (summarize/    **`status`** (summarize/' 'mode-inference: a bare `/drupilot`'
mutate "two swapped tabs fail" commands/drupilot-port.md \
  's/--key CORE_TARGET/--key TMP_SWAP/; s/--key DIGESTS_RULES/--key CORE_TARGET/; s/--key TMP_SWAP/--key DIGESTS_RULES/' 'tab-sequence'
mutate "a tab inserted without an allowed_insertions entry fails" commands/drupilot-setup.md \
  's/--key TARGET_MAJOR/--key LEARN/' 'tab-sequence'
mutate "the allowed insertion after its anchor fails" commands/drupilot-setup.md \
  's/--key TARGET_MAJOR/--key TMP_SWAP/; s/--key PHP_TARGET/--key TARGET_MAJOR/; s/--key TMP_SWAP/--key PHP_TARGET/' 'tab-sequence'
mutate "two allowed insertions out of their listed order fail" commands/drupilot-setup.md \
  's/--key TARGET_MAJOR/--key TMP_SWAP/; s/--key ALLOW_PRERELEASE/--key TARGET_MAJOR/; s/--key TMP_SWAP/--key ALLOW_PRERELEASE/' 'tab-sequence'
mutate "an allowed insertion asked twice fails" commands/drupilot-setup.md \
  '/--key ALLOW_PRERELEASE/p' 'tab-sequence'
# A tab shown twice, before both copies of a reused 0.9 tab (LEARN in the
# port and in the refactor), passes with two rows of allowed_insertions.
jq '.allowed_insertions += [{key: "PATCH_KIND", before: "LEARN", since: "test"}, {key: "PATCH_KIND", before: "LEARN", since: "test"}]' \
  "$T_REPO/tests/evals/router/tab-sequence.json" > "$T_TMP/ts.json"
for f in commands/drupilot-port.md commands/drupilot-refactor.md; do
  cp "$c/$f" "$T_TMP/$(basename "$f").orig"
  awk '/--key LEARN/ && !d { print "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/env/choice.sh\" --key PATCH_KIND --json"; d = 1 } { print }' "$T_TMP/$(basename "$f").orig" > "$c/$f"
done
mkdir -p "$c/tests/evals/router"; cp -R "$T_REPO/tests/evals/router/." "$c/tests/evals/router/"; cp "$T_TMP/ts.json" "$c/tests/evals/router/tab-sequence.json"
assert_eq "a tab inserted twice before a reused 0.9 tab, with two rows: passes" \
  "$("$T_SH" "$c/scripts/dev/evals.sh" --plugin-root "$c" --json 2>/dev/null | jq -r '[.checks[] | select(.name == "tab-sequence") | .status] | join(",")')" "pass"
jq '.allowed_insertions |= .[:-1]' "$T_TMP/ts.json" > "$c/tests/evals/router/tab-sequence.json"
assert_eq "  with one row: fails" \
  "$("$T_SH" "$c/scripts/dev/evals.sh" --plugin-root "$c" --json 2>/dev/null | jq -r '[.checks[] | select(.name == "tab-sequence") | .status] | join(",")')" "fail"
for f in commands/drupilot-port.md commands/drupilot-refactor.md; do cp "$T_TMP/$(basename "$f").orig" "$c/$f"; done
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
assert_eq "valid answers from a failed run pass nothing" "$(live 'echo NO_TABS; echo DRUPILOT_MODE=full; exit 1')" "false|0|0"
t_done
