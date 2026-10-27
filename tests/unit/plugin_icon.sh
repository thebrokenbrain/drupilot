#!/usr/bin/env bash
# .claude-plugin/icon.png is the plugin directory's listing icon, read once,
# the first time the plugin is submitted: a complete, square PNG of 512 to
# 2048 px a side, under 2 MB. This test is the guard: `claude plugin validate`
# (2.1.311) reports only a missing icon (ICON_MISSING) or one over 2 MiB
# (ICON_INVALID), as a directory warning that never fails the validate gate.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
ICON="$T_REPO/.claude-plugin/icon.png"
# bytes FILE SKIP COUNT -> the bytes as unsigned decimals, one space apart.
bytes() { od -An -tu1 -j"$2" -N"$3" "$1" 2> /dev/null | tr -s ' \n' '  ' | sed 's/^ //; s/ $//'; }
assert_eq "the icon exists" "$([[ -f "$ICON" ]] && echo yes)" "yes"
# BSD wc pads the count with spaces; the arithmetic drops them.
size="$( { wc -c < "$ICON"; } 2> /dev/null || true)"
size=$(( ${size:-0} + 0 ))
assert_eq "a non-empty file under 2 MB (got $size bytes)" "$([[ "$size" -gt 0 && "$size" -lt 2000000 ]] && echo yes)" "yes"
# The PNG signature, then the IHDR chunk, always first and 13 bytes long.
assert_eq "it is a PNG" "$(bytes "$ICON" 0 16)" "137 80 78 71 13 10 26 10 0 0 0 13 73 72 68 82"
# IHDR starts with the width and the height, each 4 bytes big-endian.
wh="$(bytes "$ICON" 16 8 | awk '{ print $1 * 16777216 + $2 * 65536 + $3 * 256 + $4, $5 * 16777216 + $6 * 65536 + $7 * 256 + $8 }')"
w="${wh% *}" h="${wh#* }"
assert_eq "it is square (${w:-?} x ${h:-?})" "$([[ -n "$w" && "$w" == "$h" ]] && echo yes)" "yes"
assert_eq "512 to 2048 px a side" "$([[ "$w" -ge 512 && "$w" -le 2048 ]] && echo yes)" "yes"
# A complete PNG ends with the IEND chunk: length 0, "IEND" and its CRC.
assert_eq "it ends with IEND (not cut short)" "$(bytes "$ICON" $(( size > 12 ? size - 12 : 0 )) 12)" "0 0 0 0 73 69 78 68 174 66 96 130"
t_done
