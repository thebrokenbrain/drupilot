#!/usr/bin/env bash
# docs/reference/deprecations-of-drupilot.md lists every config/migrations.json
# row (09-R9, AR-37): each env alias's old and new names (KEY or KEY=value
# without the value: the page groups a boolean's spellings in one line) and
# each value_aliases row's old and new names, as code spans.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
PAGE="$T_REPO/docs/reference/deprecations-of-drupilot.md"
M="$T_REPO/config/migrations.json"
assert_eq "the page exists" "$([[ -f "$PAGE" ]] && echo yes)" "yes"
missing=""
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if grep -qF -- "\`$name" "$PAGE"; then continue; fi
  # KEY=v listed as another spelling on the line of KEY=...: (also `v`, ...).
  if [[ "$name" == *=* ]] && grep -F -- "\`${name%%=*}=" "$PAGE" | grep -qF -- "\`${name#*=}\`"; then continue; fi
  missing="$missing [$name]"
done < <(jq -r '(.env_aliases[] | .old, .new), (.value_aliases[] | .old, .new), (.removed[]? | .old // empty)' "$M")
assert_eq "every migrations.json name is on the page" "${missing:-none}" "none"
assert_eq "  (and there are rows to list)" "$([[ "$(jq '[.env_aliases[], .value_aliases[]] | length' "$M")" -ge 4 ]] && echo yes)" "yes"
t_done
