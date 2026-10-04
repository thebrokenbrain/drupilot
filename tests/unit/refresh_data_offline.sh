#!/usr/bin/env bash
# scripts/dev/refresh-data.sh --offline (T-M2-05) on tests/fixtures/
# refresh-data: two runs on the same input give byte-identical files and
# output; the generated fields come from the cache while the hand fields stay;
# a second run changes nothing; a supported major ignores pre-release tags;
# --dry-run writes nothing; a hand-set verified:false is kept; a removal the
# tree contradicts, an extension or library that disappears unlisted and a
# hand source that changed are reported; a file missing from the cache, at
# any point of the run, leaves the data untouched; a malformed file exits 1.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
FX="$T_REPO/tests/fixtures/refresh-data"
RD="$T_REPO/scripts/dev/refresh-data.sh"
# run DIR [ARGS] -> the JSON output; the exit code in $T_TMP/rc.
run() {
  local d="$1"; shift
  local rc=0
  "$T_SH" "$RD" --offline --cache "$T_TMP/cache" --data-dir "$d" --as-of 2026-10-04 --json "$@" 2>/dev/null || rc=$?
  printf '%s' "$rc" > "$T_TMP/rc"
}
fresh() { rm -rf "${T_TMP:?}/${1:?}"; mkdir -p "$T_TMP/$1"; cp -R "$FX/data/targets" "$T_TMP/$1/"; }
cp -R "$FX/cache" "$T_TMP/cache"

fresh a; fresh b
run "$T_TMP/a" > "$T_TMP/a.out"; assert_eq "first run: exit 0" "$(cat "$T_TMP/rc")" "0"
run "$T_TMP/b" > "$T_TMP/b.out"
assert_eq "two offline runs write the same bytes" "$(cmp "$T_TMP/a/targets/11.json" "$T_TMP/b/targets/11.json" && echo same)" "same"
assert_eq "and print the same output" "$(cmp "$T_TMP/a.out" "$T_TMP/b.out" && echo same)" "same"
T11="$T_TMP/a/targets/11.json"
assert_eq "generated: latest, released, php_min, php_recommended" \
  "$(jq -c '.minors["11.3"] | [.latest, .released, .php_min, .php_recommended, .symfony_major, .twig_major]' "$T11")" '["11.3.18","2025-12-17","8.3","8.4",7,3]'
assert_eq "generated: the dev constraints" \
  "$(jq -c '.minors["11.3"] | [.phpunit_constraint, .coder_constraint, .phpstan_constraint, .phpstan_drupal_constraint]' "$T11")" \
  '["^11.5.50","^8.3.30","^1.12.27 || ^2.1.26","^1.3.9 || ^2.0.9"]'
assert_eq "hand fields kept" "$(jq -c '.minors["11.3"] | [.php_supported, .php_unsupported, .verified]' "$T11")" '[["8.3","8.4","8.5"],["8.1","8.2","8.6"],true]'
assert_eq "changed minor and file are stamped" "$(jq -c '[.minors["11.3"].checked_at, .as_of]' "$T11")" '["2026-10-04","2026-10-04"]'
assert_eq "a supported major ignores 11.5.0-beta1: 11.5 stays detect" "$(jq -c '.minors["11.5"]' "$T11")" '{"status":"detect"}'
assert_eq "the changes are listed" "$(jq -c '[.changed[].path] | length' "$T_TMP/a.out")" "11"
cp "$T11" "$T_TMP/a.json"
run "$T_TMP/a" > "$T_TMP/a2.out"
assert_eq "a second run changes nothing" "$(jq -c '.changed' "$T_TMP/a2.out")" "[]"
assert_eq "and leaves the file as it was" "$(cmp "$T11" "$T_TMP/a.json" && echo same)" "same"

fresh c
run "$T_TMP/c" --dry-run > "$T_TMP/c.out"
assert_eq "--dry-run reports the changes" "$(jq -c '[.dry_run, (.changed | length)]' "$T_TMP/c.out")" "[true,11]"
assert_eq "--dry-run writes nothing" "$(cmp "$T_TMP/c/targets/11.json" "$FX/data/targets/11.json" && echo same)" "same"

fresh d
jq '.hand_sources[0].changed = "2026-01-01"' "$FX/data/targets/11.json" > "$T_TMP/d/targets/11.json"
run "$T_TMP/d" > "$T_TMP/d.out"
assert_eq "a changed hand source: exit 3" "$(cat "$T_TMP/rc")" "3"
assert_eq "a changed hand source is listed" "$(jq -c '.stale_hand_sources[0] | [.id, .recorded, .current]' "$T_TMP/d.out")" '["php-requirements","2026-01-01","2026-08-04"]'

fresh e
printf '200' > "$T_TMP/cache/git/11.0.0/core_modules_book_book.info.yml.status"
run "$T_TMP/e" > "$T_TMP/e.out"
assert_eq "a removal the tree contradicts: exit 3" "$(cat "$T_TMP/rc")" "3"
assert_eq "it is a mismatch" "$(jq -r '.mismatches[0].detail' "$T_TMP/e.out")" "still in the core tree at 11.0.0"
printf '404' > "$T_TMP/cache/git/11.0.0/core_modules_book_book.info.yml.status"

fresh h
jq '.minors["11.3"].verified = false' "$FX/data/targets/11.json" > "$T_TMP/h/targets/11.json"
run "$T_TMP/h" > /dev/null
assert_eq "a hand-set verified:false survives a refresh" "$(jq -c '.minors["11.3"] | [.verified, .latest]' "$T_TMP/h/targets/11.json")" '[false,"11.3.18"]'

fresh i
jq '.removed_extensions = []' "$FX/data/targets/11.json" > "$T_TMP/i/targets/11.json"
run "$T_TMP/i" > "$T_TMP/i.out"
assert_eq "an extension gone at the major's .0 but not listed: exit 3" "$(cat "$T_TMP/rc")" "3"
assert_eq "it is reported" "$(jq -r '.mismatches[0].detail' "$T_TMP/i.out")" "core/modules/book/book.info.yml is in the core tree at 10.6.18 but not at 11.0.0, and is not listed"
printf 'drupal:\n  version: VERSION\n' > "$T_TMP/cache/git/11.0.0/core_core.libraries.yml"
fresh j
run "$T_TMP/j" > "$T_TMP/j.out"
assert_eq "a library gone at the major's .0 but not listed is reported" "$(jq -r '.mismatches[0].detail' "$T_TMP/j.out")" \
  "core/once is in core.libraries.yml at 10.6.18 but not at 11.0.0, and is not listed"
cp "$FX/cache/git/11.0.0/core_core.libraries.yml" "$T_TMP/cache/git/11.0.0/core_core.libraries.yml"

fresh f
rm "$T_TMP/cache/git/11.3.18/core_lib_Drupal.php"
run "$T_TMP/f" > /dev/null
assert_eq "--offline with a file missing from the cache: exit 1" "$(cat "$T_TMP/rc")" "1"
assert_eq "and nothing written" "$(cmp "$T_TMP/f/targets/11.json" "$FX/data/targets/11.json" && echo same)" "same"
cp "$FX/cache/git/11.3.18/core_lib_Drupal.php" "$T_TMP/cache/git/11.3.18/core_lib_Drupal.php"

fresh g
rm "$T_TMP/cache/git/11.0.0/core_modules_book_book.info.yml.status"
run "$T_TMP/g" > "$T_TMP/g.out"
assert_eq "a fetch failing after the values were computed: exit 1" "$(cat "$T_TMP/rc")" "1"
assert_eq "and still nothing written (writes wait for every fetch)" "$(cmp "$T_TMP/g/targets/11.json" "$FX/data/targets/11.json" && echo same)" "same"
assert_no_stdout "and no JSON claims a change" cat "$T_TMP/g.out"
cp "$FX/cache/git/11.0.0/core_modules_book_book.info.yml.status" "$T_TMP/cache/git/11.0.0/"

fresh l
printf 'core/modules/book/book.info.yml\ncore/modules/book/modules/book_nested/book_nested.info.yml\ncore/modules/node/node.info.yml\n' \
  > "$T_TMP/cache/git/10.6.18/info-yml-paths.txt"
run "$T_TMP/l" > "$T_TMP/l.out"
assert_eq "a nested extension gone unlisted is reported too" "$(jq -r '.mismatches[0].detail' "$T_TMP/l.out")" \
  "core/modules/book/modules/book_nested/book_nested.info.yml is in the core tree at 10.6.18 but not at 11.0.0, and is not listed"
jq '.removed_extensions += [{name: "book_nested", kind: "module", removed_in: "11.0", info_path: "core/modules/book/modules/book_nested/book_nested.info.yml"}]' \
  "$FX/data/targets/11.json" > "$T_TMP/l/targets/11.json"
printf '404' > "$T_TMP/cache/git/11.0.0/core_modules_book_modules_book_nested_book_nested.info.yml.status"
printf '200' > "$T_TMP/cache/git/10.6.18/core_modules_book_modules_book_nested_book_nested.info.yml.status"
run "$T_TMP/l" > "$T_TMP/l.out"
assert_eq "listed under its info_path, it is not" "$(jq -c '.mismatches' "$T_TMP/l.out")" "[]"
cp "$FX/cache/git/10.6.18/info-yml-paths.txt" "$T_TMP/cache/git/10.6.18/info-yml-paths.txt"

fresh k
printf '{"major": 11, "minors": ' > "$T_TMP/k/targets/11.json"
run "$T_TMP/k" > /dev/null
assert_eq "a malformed target file: exit 1" "$(cat "$T_TMP/rc")" "1"
t_done
