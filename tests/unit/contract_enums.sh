#!/usr/bin/env bash
# The enums snapshot of scripts/dev/contract.sh reads each closed value set
# from the code that emits it: renaming one emitted value, in a scratch copy
# of the plugin, must turn the snapshot red for every enum (a word left in a
# comment or a log line must not keep it green).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
c="$T_TMP/plugin"; mkdir -p "$c"
for d in scripts config commands skills agents hooks templates .claude-plugin; do cp -R "$T_REPO/$d" "$c/"; done
# enums -> the status of the enums snapshot for the copy.
enums() {
  "$T_SH" "$T_REPO/scripts/dev/contract.sh" --check --only enums --plugin-root "$c" --json 2>/dev/null \
    | jq -r '.snapshots[0].status // "none"'
}
# mutate <label> <file> <sed expression>: the snapshot goes red, then the file is restored.
mutate() {
  local f="$c/$2"
  cp "$f" "$T_TMP/orig"
  sed "$3" "$T_TMP/orig" > "$f"
  if cmp -s "$f" "$T_TMP/orig"; then assert_eq "$1: the mutation applies" "no change" "a change"; return 0; fi
  assert_eq "$1" "$(enums)" "differs"
  cp "$T_TMP/orig" "$f"
}
assert_eq "the copy keeps the 0.9 enums (same)" "$(enums)" "same"
mutate "preservation: a renamed verdict" scripts/tests/run-phpunit.sh 's/PRESERVATION="regression"/PRESERVATION="behavior-broken"/'
mutate "stages: a renamed stage" scripts/lib/common.sh 's/tested) printf 5/verified) printf 5/'
mutate "strategy inputs: a renamed strategy" scripts/env/preflight.sh 's/ keep-d10 >\/dev\/null/ keep-ten >\/dev\/null/'
mutate "resolved strategy: keep-current renamed" scripts/lib/common.sh 's/resolved="keep-current"/resolved="keep-declared"/'
mutate "d10_support: a renamed verdict" scripts/analysis/verify-core-matrix.sh 's/then "failed"/then "broken"/'
mutate "deps status: a renamed verdict" scripts/analysis/deps-status.sh "s/printf 'not-ready'/printf 'blocked'/"
mutate "deps status: core renamed" scripts/analysis/deps-status.sh 's/st="core"/st="bundled"/'
mutate "stages: two ranks swapped" scripts/lib/common.sh 's/setup) printf 1;; assessed) printf 2;;/setup) printf 2;; assessed) printf 1;;/'
mutate "port-summary status: a renamed status" scripts/analysis/port-summary.sh 's/then "blocked"/then "stuck"/'
mutate "refactor scope: a renamed option" config/choices.json 's/"final"/"sealed"/'
assert_eq "restored: the same again" "$(enums)" "same"
t_done
