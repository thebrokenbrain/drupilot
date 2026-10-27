#!/usr/bin/env bash
# docs/reference/deprecations-of-drupilot.md lists every config/migrations.json
# row (09-R9, AR-37): for each env alias and each value_aliases row, one table
# line holds both its old and its new name as code spans (a boolean's other
# spellings may be grouped on its line: KEY= plus `value`).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
PAGE="$T_REPO/docs/reference/deprecations-of-drupilot.md"
M="$T_REPO/config/migrations.json"
assert_eq "the page exists" "$([[ -f "$PAGE" ]] && echo yes)" "yes"
missing=""
# row OLD NEW -> 0 when one table line of the page holds both as code spans
# (a KEY=value old name may be written as KEY= plus `value` on that line).
row() {
  local o="$1" n="$2"
  grep '^|' "$PAGE" | while IFS= read -r l; do
    case "$l" in *"\`$n"[\`=\ ]*|*"\`$n\`"*) ;; *) continue;; esac
    case "$l" in
      *"\`$o\`"*|*"\`$o "*) echo hit; break;;
    esac
    if [[ "$o" == *=* && "$l" == *"\`${o%%=*}="* && "$l" == *"\`${o#*=}\`"* ]]; then echo hit; break; fi
  done | grep -q hit
}
while IFS="$(printf '\t')" read -r o n; do
  [[ -n "$o" ]] || continue
  row "$o" "$n" || missing="$missing [$o -> $n]"
done < <(jq -r '(.env_aliases[], .value_aliases[]) | [.old, .new] | @tsv' "$M")
assert_eq "every migrations.json row is on one line of the page" "${missing:-none}" "none"
assert_eq "  (and there are rows to list)" "$([[ "$(jq '[.env_aliases[], .value_aliases[]] | length' "$M")" -ge 4 ]] && echo yes)" "yes"
t_done
