#!/usr/bin/env bash
# discover-tests.sh's legacy list (training run modules 03 like_dislike and 11
# nodeviewcount): test classes in src/Tests/ or a top-level Tests/ are listed
# under legacy, never counted; tests/src/ ones are counted as before; no
# legacy key when there is none (the 0.9 shape).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
DT="$T_REPO/scripts/tests/discover-tests.sh"
M="$T_TMP/m"; mkdir -p "$M/src/Tests/Sub" "$M/Tests/Controller" "$M/tests/src/Kernel"
printf 'name: M\ntype: module\n' > "$M/m.info.yml"
printf '<?php\nclass ATest {}\n' > "$M/src/Tests/ATest.php"
printf '<?php\nclass BTest {}\n' > "$M/src/Tests/Sub/BTest.php"
printf '<?php\nclass CTest {}\n' > "$M/Tests/Controller/CTest.php"
printf '<?php\nclass Helper {}\n' > "$M/src/Tests/Helper.php"
printf '<?php\nclass KTest {}\n' > "$M/tests/src/Kernel/KTest.php"
t_run "$T_SH" "$DT" --subject "$M" --json
assert_eq "the tests/src class counted, the SimpleTest-era ones listed apart" \
  "$T_RC|$(jq -c '[.kernel, .total, .legacy]' "$T_OUT")" \
  '0|[1,1,["Tests/Controller/CTest.php","src/Tests/ATest.php","src/Tests/Sub/BTest.php"]]'
t_run "$T_SH" "$DT" --subject "$M"
assert_match "  the human report says to move them" "$(cat "$T_OUT")" "3 test class file\(s\) in a SimpleTest-era location PHPUnit never reads"
rm -rf "$M/src/Tests" "$M/Tests"
t_run "$T_SH" "$DT" --subject "$M" --json
assert_eq "none left: no legacy key" "$(jq -c 'has("legacy")' "$T_OUT")" "false"
t_done
