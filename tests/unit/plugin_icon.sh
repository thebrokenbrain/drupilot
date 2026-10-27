#!/usr/bin/env bash
# .claude-plugin/icon.png is the plugin directory's listing icon, read once,
# the first time the plugin is submitted. It must stay within the directory's
# limits, which `claude plugin validate` only reports as a directory warning
# that never fails the validate gate: a square PNG of 512 to 2048 px a side,
# under 2 MB.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
ICON="$T_REPO/.claude-plugin/icon.png"
# bytes FILE SKIP COUNT -> the bytes as unsigned decimals, one space apart.
bytes() { od -An -tu1 -j"$2" -N"$3" "$1" | tr -s ' \n' '  ' | sed 's/^ //; s/ $//'; }
assert_eq "the icon exists" "$([[ -f "$ICON" ]] && echo yes)" "yes"
# The PNG signature, then the IHDR chunk, always first and 13 bytes long.
assert_eq "it is a PNG" "$(bytes "$ICON" 0 16)" "137 80 78 71 13 10 26 10 0 0 0 13 73 72 68 82"
# IHDR starts with the width and the height, each 4 bytes big-endian.
wh="$(bytes "$ICON" 16 8 | awk '{ print $1 * 16777216 + $2 * 65536 + $3 * 256 + $4, $5 * 16777216 + $6 * 65536 + $7 * 256 + $8 }')"
w="${wh% *}" h="${wh#* }"
assert_eq "it is square" "$w" "$h"
assert_eq "512 to 2048 px a side (got $w)" "$([[ "$w" -ge 512 && "$w" -le 2048 ]] && echo yes)" "yes"
assert_eq "under 2 MB" "$([[ "$(wc -c < "$ICON")" -lt 2000000 ]] && echo yes)" "yes"
t_done
