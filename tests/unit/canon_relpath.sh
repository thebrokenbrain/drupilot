#!/usr/bin/env bash
# Runner paths (T-M4-01, T-M4-02, AR-13, DET-2, R-LAB-7): relpath_strip_runner
# makes the same tree's paths identical whether the tool ran on the host (the
# Drupal root's absolute path, logical or physical) or in the DDEV container
# (/var/www/html), inside JSON keys, values and messages, escaped slashes
# included; and it gives back the M1 raw goldens byte for byte from either
# runner's form. canon_json ROOT strips them before it sorts.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

ROOT="$T_TMP/lab/m1/dpl-m1-legwid-d11"
mkdir -p "$ROOT/web/modules/custom" "$T_TMP/links"
ln -s "$ROOT" "$T_TMP/links/bed"
LINK="$T_TMP/links/bed"

assert_eq "the container prefix" \
  "$(printf '/var/www/html/web/modules/custom/x/a.php\n' | relpath_strip_runner "$ROOT")" "web/modules/custom/x/a.php"
assert_eq "the host prefix" \
  "$(printf '%s/web/modules/custom/x/a.php\n' "$ROOT" | relpath_strip_runner "$ROOT")" "web/modules/custom/x/a.php"
assert_eq "the physical path of a symlinked root" \
  "$(printf '%s/web/a.php\n' "$ROOT" | relpath_strip_runner "$LINK")" "web/a.php"
assert_eq "the logical path of a symlinked root" \
  "$(printf '%s/web/a.php\n' "$LINK" | relpath_strip_runner "$LINK")" "web/a.php"
assert_eq "a trailing slash on ROOT" \
  "$(printf '%s/web/a.php\n' "$ROOT" | relpath_strip_runner "$ROOT/")" "web/a.php"
assert_eq "inside a message, every occurrence" \
  "$(printf 'Class in /var/www/html/web/a.php and %s/web/b.php\n' "$ROOT" | relpath_strip_runner "$ROOT")" \
  "Class in web/a.php and web/b.php"
assert_eq "escaped slashes (raw PHPCS JSON)" \
  "$(printf '{"\\/var\\/www\\/html\\/web\\/a.php":1}\n' | relpath_strip_runner "$ROOT")" '{"web\/a.php":1}'
assert_eq "the bare root is ." \
  "$(printf '"/var/www/html" in %s: x\n' "$ROOT" | relpath_strip_runner "$ROOT")" '"." in .: x'
assert_eq "a longer sibling name is kept" \
  "$(printf '/var/www/html2/a %s-old/b %s.bak\n' "$ROOT" "$ROOT" | relpath_strip_runner "$ROOT")" "/var/www/html2/a $ROOT-old/b $ROOT.bak"
assert_eq "no ROOT: only the container prefix" \
  "$(printf '/var/www/html/a %s/b\n' "$ROOT" | relpath_strip_runner)" "a $ROOT/b"
assert_eq "ROOT / strips nothing of its own" \
  "$(printf '/etc/a /var/www/html/b\n' | relpath_strip_runner /)" "/etc/a b"
BS="$T_TMP/a\\/bed"; mkdir -p "$BS"
assert_eq "a root with a component ending in a backslash" "$(printf '%s/web/x.php\n' "$BS" | relpath_strip_runner "$BS")" "web/x.php"
BS2="$T_TMP/b\\c/bed"; mkdir -p "$BS2"
assert_eq "plain text: another directory spelled with an escaped backslash is kept" \
  "$(printf '%s/web/x.php\n' "$T_TMP/b\\\\c/bed" | relpath_strip_runner "$BS2")" "$T_TMP/b\\\\c/bed/web/x.php"
ODD="$T_TMP/a.b+c[1]*(x)\\y"
assert_eq "a ROOT with regex and awk metacharacters is literal" \
  "$(printf '%s/web/a.php %s/web/b.php\n' "$ODD" "$T_TMP/aXb+c[1]*(x)\\y" | relpath_strip_runner "$ODD")" \
  "web/a.php $T_TMP/aXb+c[1]*(x)\\y/web/b.php"
assert_eq "no final newline stays without one" \
  "$(printf '/var/www/html/a' | relpath_strip_runner | od -An -c | tr -s ' ')" "$(printf 'a' | od -An -c | tr -s ' ')"

# A root nested in its own physical path (macOS /tmp -> /private/tmp, Fedora
# Atomic /home -> /var/home): the longer prefix is stripped whole.
NEST="$T_TMP/n"; mkdir -p "$NEST/p$NEST/bed"; ln -s "$NEST/p$NEST/bed" "$NEST/bed"
assert_eq "a root inside its own physical path: the physical one whole" \
  "$(printf '%s/web/a.php %s/web/b.php\n' "$NEST/p$NEST/bed" "$NEST/bed" | relpath_strip_runner "$NEST/bed")" "web/a.php web/b.php"

# A root PHP's json_encode escaped (\/, \u00e9): canon_json undoes the escapes first.
UNI="$T_TMP/josé"; mkdir -p "$UNI"
assert_eq "an escaped non-ASCII root" \
  "$(printf '{"m":"in %s\\/web\\/a.php"}' "$(printf '%s' "$T_TMP" | sed 's#/#\\/#g')\\/jos\\u00e9" | canon_json "$UNI" | jq -r .m)" "in web/a.php"
QR="$T_TMP/q\"b"; mkdir -p "$QR"
assert_eq "a root with a quote, in its JSON form" \
  "$(jq -n -c --arg p "$QR/web/a.php" '{m: $p}' | canon_json "$QR" | jq -r .m)" "web/a.php"

# Keys sort as the relative paths they become (strip, then sort): sorted
# first, the container keys would come before /var/www/html2 and the host key.
assert_eq "keys sort after the strip (container, sibling and host keys)" \
  "$(printf '{"/var/www/html/web/z.php":1,"/var/www/html2/a":2,"%s/web/b.php":3}' "$ROOT" | canon_json "$ROOT" | jq -c 'keys_unsorted')" \
  '["/var/www/html2/a","web/b.php","web/z.php"]'
assert_eq "keys sort after the strip" \
  "$(printf '{"/var/www/html/web/z.php":1,"%s/web/a.php":2,"/opt/m.php":3}' "$ROOT" | canon_json "$ROOT" | jq -r 'keys_unsorted | join(" ")')" \
  "/opt/m.php web/a.php web/z.php"

# The same tree, run on the host and in the container: identical output.
HOST="$(printf '{"files":{"%s/web/modules/custom/x/a.php":{"messages":[{"message":"in %s/web/modules/custom/x/a.php"}]}}}' "$ROOT" "$ROOT")"
CONT='{"files":{"/var/www/html/web/modules/custom/x/a.php":{"messages":[{"message":"in /var/www/html/web/modules/custom/x/a.php"}]}}}'
assert_eq "host and container runs relativize identically" \
  "$(printf '%s' "$HOST" | canon_json "$ROOT" | sha256_hex)" "$(printf '%s' "$CONT" | canon_json "$ROOT" | sha256_hex)"
assert_eq "... to root-relative paths" "$(printf '%s' "$CONT" | canon_json "$ROOT" | jq -r '.files | keys[0]')" \
  "web/modules/custom/x/a.php"

# The M1 raw goldens (recorded with R-LAB-7's sed): put either runner's
# prefix back and strip it again -> the committed bytes.
for f in "$T_REPO"/tests/fixtures/legacy_widgets.golden/raw/*.json; do
  n="$(basename "$f")"
  sed 's#web/modules/custom/#/var/www/html/web/modules/custom/#g' "$f" > "$T_TMP/cont-$n"
  sed "s#web/modules/custom/#$ROOT/web/modules/custom/#g" "$f" > "$T_TMP/host-$n"
  assert_eq "$n: the container form gives the golden back" \
    "$(relpath_strip_runner "$ROOT" < "$T_TMP/cont-$n" | sha256_hex)" "$(sha256_hex < "$f")"
  assert_eq "$n: the host form gives the golden back" \
    "$(relpath_strip_runner "$ROOT" < "$T_TMP/host-$n" | sha256_hex)" "$(sha256_hex < "$f")"
  assert_eq "$n: canon_json ROOT on the host form gives the golden back" \
    "$(canon_json "$ROOT" < "$T_TMP/host-$n" | sha256_hex)" "$(sha256_hex < "$f")"
done
t_done
