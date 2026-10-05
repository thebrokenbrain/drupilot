#!/usr/bin/env bash
# Pipelines under pipefail never end in a consumer that stops reading early
# (the intermittent exit 141 / wrong verdicts of the baseline-0.9 captures):
# with grep -q, a producer that writes again after the match dies of SIGPIPE
# and the pipeline fails; grep_q (common.sh) reads its whole input, answers
# like grep -q and also works where GNU grep would stop early on a /dev/null
# output. The sigpipe gate of scripts/dev/check.sh, on a scratch copy: green
# on HEAD, red on `| head`, `| grep -q` / `-m` / `-l`, an `| awk` exit, and a
# trailing `# sigpipe-ok` opts a line out; tests/ and comments are not read.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

# A producer that writes after the consumer has seen its match.
two() { printf 'match\n'; sleep 1; printf 'more\n'; }
# 141 when the producer dies of SIGPIPE, 1 when SIGPIPE is ignored (as on
# GitHub's runners) and its write fails with EPIPE: a failure either way.
rc="$(set -o pipefail; two | grep -q match; echo $?)"
assert_eq "the hazard: grep -q under pipefail fails the pipeline (rc $rc)" "$([[ "$rc" != "0" ]] && echo fails)" "fails"
assert_eq "grep_q reads it all: 0" "$(set -o pipefail; two | grep_q match; echo $?)" "0"
assert_eq "grep_q: no match is 1" "$(set -o pipefail; printf 'a\nb\n' | grep_q zzz; echo $?)" "1"
assert_eq "grep_q -x" "$(printf '10\n11\n' | grep_q -x 1 && echo y || echo n)$(printf '10\n11\n' | grep_q -x 11 && echo y || echo n)" "ny"
assert_eq "grep_q -F -- with a leading dash" "$(printf -- '--reflink\n' | grep_q -F -- '--reflink' && echo y)" "y"
assert_eq "grep_q -iE" "$(printf 'DrupalPractice\n' | grep_q -iE 'drupalpractice|x' && echo y)" "y"
assert_eq "grep_q: an invalid regex is 1, quietly" "$(printf 'a\n' | grep_q -E '(' 2>&1; echo $?)" "1"
assert_eq "grep_q on empty input" "$(printf '' | grep_q . ; echo $?)" "1"

r="$T_TMP/tree"
mkdir -p "$r/scripts" "$r/hooks" "$r/tests/unit"
cp -R "$T_REPO/scripts/dev" "$T_REPO/scripts/lib" "$r/scripts/"
cp -R "$T_REPO/hooks/scripts" "$r/hooks/"
# gate -> "<status>|<number of findings>|<first finding>"
gate() {
  "$T_SH" "$r/scripts/dev/check.sh" --only sigpipe --json 2>/dev/null \
    | jq -r '.gates[0] | "\(.status)|\(.findings | length)|\(.findings[0] // "")"'
}
assert_match "green on HEAD" "$(gate)" '^pass\|0\|'
f="$r/scripts/lib/zz.sh"
for line in 'x="$(printf a | head -n1)"' 'printf a | grep -q a' 'printf a | grep -qx a' 'printf a | grep -m 1 a' \
            'printf a | grep -l a' 'printf a | grep --quiet a' "printf a | awk '{ print; exit }'"; do
  printf '#!/usr/bin/env bash\n%s\n' "$line" > "$f"
  assert_match "red: $line" "$(gate)" '^fail\|1\|scripts/lib/zz\.sh:2: '
done
printf '#!/usr/bin/env bash\nprintf a | head -n1  # sigpipe-ok: a single write, read whole\n# printf a | grep -q a\nprintf a | grep -c a\n' > "$f"
assert_match "an opt-out, a comment and grep -c are fine" "$(gate)" '^pass\|0\|'
rm -f "$f"
printf '#!/usr/bin/env bash\nprintf a | grep -q a\n' > "$r/tests/unit/x.sh"
assert_match "tests/ is not read" "$(gate)" '^pass\|0\|'
t_done
