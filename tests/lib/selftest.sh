#!/usr/bin/env bash
# =============================================================================
# drupilot — tests/lib/selftest.sh
# Self-test of tests/lib/assert.sh: every assertion passes on its good case and
# fails on its bad one, and t_done / t_skip exit 0, 1 and 77. Each case runs in
# a child bash (the same $BASH) that sources the library, so a failing
# assertion there does not count here.
# =============================================================================
. "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
t_isolate

# outcome <snippet> -> "ok" or "not ok": the first line the snippet prints in a
# child shell that sourced assert.sh.
outcome() {
  "$T_SH" -c '. "$1"; eval "$2"' _ "$T_REPO/tests/lib/assert.sh" "$1" 2>/dev/null | head -n 1 | sed 's/ - .*//'
}
# exit_of <snippet> -> the exit code of the snippet in such a child shell.
exit_of() {
  if "$T_SH" -c '. "$1"; eval "$2"' _ "$T_REPO/tests/lib/assert.sh" "$1" > /dev/null 2>&1; then echo 0; else echo $?; fi
}

assert_eq "assert_eq: equal" "$(outcome 'assert_eq x a a')" "ok"
assert_eq "assert_eq: different" "$(outcome 'assert_eq x a b')" "not ok"
assert_eq "assert_match: matches" "$(outcome 'assert_match x "port-to-drupal-11" "drupal-1[0-9]$"')" "ok"
assert_eq "assert_match: does not match" "$(outcome 'assert_match x "abc" "^b"')" "not ok"
assert_eq "assert_json_eq: same object, other key order" "$(outcome 'assert_json_eq x "{\"a\":1,\"b\":[2]}" "{\"b\":[2],\"a\":1}"')" "ok"
assert_eq "assert_json_eq: different value" "$(outcome 'assert_json_eq x "{\"a\":1}" "{\"a\":2}"')" "not ok"
assert_eq "assert_json_eq: not JSON" "$(outcome 'assert_json_eq x "{a" "{}"')" "not ok"
assert_eq "assert_exit: expected code" "$(outcome 'assert_exit x 3 sh -c "exit 3"')" "ok"
assert_eq "assert_exit: other code" "$(outcome 'assert_exit x 0 sh -c "exit 3"')" "not ok"
printf 'same\n' > "$T_TMP/a"; printf 'same\n' > "$T_TMP/b"; printf 'other\n' > "$T_TMP/c"
export ST_A="$T_TMP/a" ST_B="$T_TMP/b" ST_C="$T_TMP/c" ST_D="$T_TMP/tree"
assert_eq "assert_file_eq: identical" "$(outcome 'assert_file_eq x "$ST_A" "$ST_B"')" "ok"
assert_eq "assert_file_eq: different" "$(outcome 'assert_file_eq x "$ST_A" "$ST_C"')" "not ok"
assert_eq "assert_file_eq: missing" "$(outcome 'assert_file_eq x "$ST_A" "$ST_A.missing"')" "not ok"
assert_eq "assert_no_stdout: silent" "$(outcome 'assert_no_stdout x true')" "ok"
assert_eq "assert_no_stdout: prints" "$(outcome 'assert_no_stdout x echo hi')" "not ok"
mkdir -p "$ST_D/sub"; printf 'x\n' > "$ST_D/sub/f"
assert_eq "assert_tree_unchanged: read-only command" "$(outcome 'assert_tree_unchanged x "$ST_D" ls "$ST_D"')" "ok"
assert_eq "assert_tree_unchanged: a new file" "$(outcome 'assert_tree_unchanged x "$ST_D" touch "$ST_D/new"')" "not ok"
assert_eq "assert_tree_unchanged: a changed file" "$(outcome 'assert_tree_unchanged x "$ST_D" sh -c "printf y >> \"\$ST_D/sub/f\""')" "not ok"
assert_eq "t_done: all passed" "$(exit_of 'assert_eq x a a; t_done')" "0"
assert_eq "t_done: a failure" "$(exit_of 'assert_eq x a b; t_done')" "1"
assert_eq "t_skip" "$(exit_of 't_skip later')" "77"
assert_eq "t_run: an exit in the command ends only its subshell" "$(exit_of 'f() { exit 0; }; t_run f; assert_eq x a b; t_done')" "1"
assert_eq "t_run: and its exit code is captured" "$(outcome 'f() { exit 3; }; t_run f; assert_eq x "$T_RC" 3')" "ok"
assert_eq "t_run without t_isolate leaves no temp file behind" \
  "$(d="$T_TMP/td"; mkdir -p "$d"; TMPDIR="$d" "$T_SH" -c '. "$1"; t_run true' _ "$T_REPO/tests/lib/assert.sh"; find "$d" -mindepth 1 | grep -c . || true)" "0"
assert_eq "t_isolate: DRUPILOT_* unset, HOME inside the temp dir" \
  "$(env DRUPILOT_HOME=/x DRUPILOT_PHP_TARGET=8.5 "$T_SH" -c '. "$1"; t_isolate; printf "%s|%s|%s" "${DRUPILOT_HOME:-unset}" "${DRUPILOT_PHP_TARGET:-unset}" "$(case "$HOME" in ("$T_TMP"/*) echo inside;; (*) echo outside;; esac)"' _ "$T_REPO/tests/lib/assert.sh" 2>/dev/null)" \
  "unset|unset|inside"
t_done
