#!/usr/bin/env bash
# The other canonicalization primitives of scripts/lib/canon.sh (T-M4-02,
# AR-13): file_hash (LF-normalized), finding_norm_message (the message part
# of a finding id, 05 §2.4: runner paths, "on line N" and whitespace noise
# dropped) and the atomic worklist_get / worklist_set.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

# --- file_hash ---------------------------------------------------------------
printf 'a\nb\n' > "$T_TMP/lf"; printf 'a\r\nb\r\n' > "$T_TMP/crlf"; printf 'a\nb' > "$T_TMP/nofinal"
printf 'a\r\nb' > "$T_TMP/crlf-nofinal"; printf 'a\rb\n' > "$T_TMP/inner-cr"
assert_eq "file_hash: sha256:<hex> of the bytes" "$(file_hash "$T_TMP/lf")" "sha256:$(sha256_hex < "$T_TMP/lf")"
assert_eq "CRLF and LF hash the same" "$(file_hash "$T_TMP/crlf")" "$(file_hash "$T_TMP/lf")"
assert_eq "no final newline is not a final newline" \
  "$([[ "$(file_hash "$T_TMP/nofinal")" != "$(file_hash "$T_TMP/lf")" ]] && echo differ)" "differ"
assert_eq "CRLF without a final newline = LF without one" "$(file_hash "$T_TMP/crlf-nofinal")" "$(file_hash "$T_TMP/nofinal")"
printf 'a\r' > "$T_TMP/lone-cr"; printf 'a' > "$T_TMP/plain-a"
assert_eq "a lone CR at the end of the file is data" \
  "$([[ "$(file_hash "$T_TMP/lone-cr")" != "$(file_hash "$T_TMP/plain-a")" ]] && echo differ)" "differ"
assert_eq "  its raw bytes" "$(file_hash "$T_TMP/lone-cr")" "sha256:$(sha256_hex < "$T_TMP/lone-cr")"
printf 'a\r\nb\r' > "$T_TMP/crlf-lone"; printf 'a\nb\r' > "$T_TMP/lf-lone"
assert_eq "CRLF lines before a lone CR: only the CRLF made LF" "$(file_hash "$T_TMP/crlf-lone")" "$(file_hash "$T_TMP/lf-lone")"
assert_eq "a CR inside a line is data" \
  "$([[ "$(file_hash "$T_TMP/inner-cr")" != "$(file_hash "$T_TMP/lf")" ]] && echo differ)" "differ"
printf '\000\001\377x' > "$T_TMP/bin"
assert_eq "a binary file without CR: its raw bytes" "$(file_hash "$T_TMP/bin")" "sha256:$(sha256_hex < "$T_TMP/bin")"
assert_eq "a missing file: nothing, exit 0" "$(file_hash "$T_TMP/nope"; echo "rc=$?")" "rc=0"
assert_eq "an empty file" "$(: > "$T_TMP/empty"; file_hash "$T_TMP/empty")" \
  "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

# --- finding_norm_message ----------------------------------------------------
ROOT="$T_TMP/bed"; mkdir -p "$ROOT"
M1="$(printf 'Call to deprecated function user_load_by_mail():\nin drupal:11.4.0 and is removed from drupal:13.0.0.\n  Use X\n  instead.')"
assert_eq "whitespace runs and newlines become one space, trimmed" "$(printf '  %s \n' "$M1" | finding_norm_message)" \
  "Call to deprecated function user_load_by_mail(): in drupal:11.4.0 and is removed from drupal:13.0.0. Use X instead."
assert_eq "runner paths dropped, the host one too" \
  "$(printf 'Class Foo in /var/www/html/web/a.php and %s/web/b.php' "$ROOT" | finding_norm_message "$ROOT")" \
  "Class Foo in web/a.php and web/b.php"
assert_eq "an anonymous class loses its file and line" \
  "$(printf 'Method class@anonymous/web/modules/custom/m/src/A.php:12::run() has no return type.' | finding_norm_message)" \
  'Method class@anonymous::run() has no return type.'
assert_eq "\"on line N\" dropped" "$(printf 'Variable $x might not be defined on line 42.' | finding_norm_message)" \
  'Variable $x might not be defined.'
assert_eq "the same finding from both runners and lines: one message" \
  "$(printf 'Undefined in %s/web/a.php on line 3' "$ROOT" | finding_norm_message "$ROOT")" \
  "$(printf 'Undefined  in /var/www/html/web/a.php on line 97' | finding_norm_message "$ROOT")"
assert_eq "an empty message" "$(printf '' | finding_norm_message)" ""
assert_eq "the jq def: the same normalization of a message without runner paths" \
  "$(jq -n -j --arg m "$(printf ' x  on line 3\n in web/a.php ')" "$(canon_jq_defs) \$m | finding_norm_message")" \
  "$(printf ' x  on line 3\n in web/a.php ' | finding_norm_message)"

# --- worklist_get / worklist_set ---------------------------------------------
SUBJ="$T_TMP/mod"; mkdir -p "$SUBJ"
WL="$(worklist_file "$SUBJ")"
assert_eq "worklist_file: worklist.json in the subject's state dir" "$WL" "$(project_state_path "$SUBJ")/worklist.json"
assert_eq "no worklist yet: get prints nothing" "$(worklist_get "$SUBJ")" ""
printf '{"items":[{"id":"W-2","status":"open"}],"schema":"drupilot.worklist/1"}' | worklist_set "$SUBJ"
assert_eq "set: exit 0, the file is canonical" "$?|$(cat "$WL")" \
  "0|$(printf '{"schema":"drupilot.worklist/1","items":[{"status":"open","id":"W-2"}]}' | canon_json)"
assert_eq "get: compact JSON" "$(worklist_get "$SUBJ")" '{"items":[{"id":"W-2","status":"open"}],"schema":"drupilot.worklist/1"}'
assert_eq "get with a filter" "$(worklist_get "$SUBJ" '.items[].id')" '"W-2"'
before="$(sha256_hex < "$WL")"
printf '{"items":' | worklist_set "$SUBJ"; rc=$?
assert_eq "invalid JSON: exit 1, the worklist untouched" "$rc|$(sha256_hex < "$WL")" "1|$before"
printf '[1,2]' | worklist_set "$SUBJ"; rc=$?
assert_eq "a non-object: exit 1, untouched" "$rc|$(sha256_hex < "$WL")" "1|$before"
printf '{"items":[9]} {"items":' | worklist_set "$SUBJ"; rc=$?
assert_eq "a valid object, then a broken one: exit 1, untouched" "$rc|$(sha256_hex < "$WL")" "1|$before"
printf '{"items":[]}\nDone.\n' | worklist_set "$SUBJ"; rc=$?
assert_eq "a valid object, then a log line: exit 1, untouched" "$rc|$(sha256_hex < "$WL")" "1|$before"
printf '{"a":1}{"b":2}' | worklist_set "$SUBJ"; rc=$?
assert_eq "two objects: exit 1, untouched" "$rc|$(sha256_hex < "$WL")" "1|$before"
# Atomic: a new file is moved into place (a reader never sees half a document).
ino() { ls -i "$1" | awk '{ print $1 }'; }
i1="$(ino "$WL")"; printf '{"items":[{"id":"W-3"}]}' | worklist_set "$SUBJ"
assert_eq "set replaces the file (temp + mv), never rewrites it in place" "$([[ "$(ino "$WL")" != "$i1" ]] && echo replaced)" "replaced"
if [[ "$(id -u)" != "0" ]]; then
  before="$(sha256_hex < "$WL")"; chmod a-w "$(dirname "$WL")"
  printf '{"items":[]}' | worklist_set "$SUBJ" 2> /dev/null; rc=$?
  chmod u+w "$(dirname "$WL")"
  assert_eq "a write that fails: exit 1, untouched" "$rc|$(sha256_hex < "$WL")" "1|$before"
fi
assert_eq "no temporary file is left" "$(find "$(dirname "$WL")" -name '*worklist*' ! -name worklist.json | grep -c . || true)" "0"
# Concurrent writers of different sizes, a reader alongside: every read is
# exactly one whole document.
for i in 1 2 3 4 5 6; do
  jq -n -c --argjson n "$i" '{items: [range(0; $n * 300) | {id: "W-\(.)"}], n: $n}' | worklist_set "$SUBJ" &
done
bad=0
for _r in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  jq -e -s 'length == 1' "$WL" > /dev/null 2>&1 || bad=$((bad + 1))
done
wait
assert_eq "concurrent sets: no read saw a partial document" "$bad" "0"
assert_eq "  one whole document wins" \
  "$(jq -e -s 'length == 1 and (.[0].items | length) == (.[0].n * 300)' "$WL" > /dev/null 2>&1; echo $?)" "0"
t_done
