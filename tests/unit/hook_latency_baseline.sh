#!/usr/bin/env bash
# T-M1-06 / AR-45: the 0.9 hook-latency baseline is committed and well formed
# (scripts/dev/baseline-0.9.sh ignores the file, so its absence would
# otherwise go unnoticed): v0.9.0, a run count, and a p50/p95 in ms for each
# of the three hooks.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
f="$T_REPO/tests/baseline/v0.9.0/hook-latency.json"
assert_eq "tests/baseline/v0.9.0/hook-latency.json exists" "$([[ -f "$f" ]] && echo yes || echo no)" "yes"
assert_eq "it is the v0.9.0 measurement" "$(jq -r '.plugin_version' "$f" 2>/dev/null)" "0.9.0"
assert_eq "with a run count" "$(jq -r '.runs | type == "number" and . >= 1' "$f" 2>/dev/null)" "true"
assert_eq "and a p50/p95 for each hook" \
  "$(jq -c '[.hooks | to_entries[] | select((.value.p50_ms | type) == "number" and (.value.p95_ms | type) == "number") | .key] | sort' "$f" 2>/dev/null)" \
  '["guard-contrib","post-edit-lint","session-detect-env"]'
t_done
