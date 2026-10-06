#!/usr/bin/env bash
# The stage catalog config/pipeline.json (T-M4-13, AR-07): the public stage
# ids in AR-07's order; every when condition from the catalog's closed set and
# every skip_reason naming one of the stage's conditions; every tab a key of
# config/choices.json, and every choice that names a stage listed in that
# stage's tabs, and the router's INTENT plus every stage's tabs in order the
# tab sequence of a full run (tests/evals/router/tab-sequence.json, with its
# allowed insertions); sub-step ids unique per stage; coarse stages the state.json
# ones, each recorded by one stage; every procedure anchor a step heading of
# exactly one skill; and docs/reference/pipeline.md generated from it.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
P="$T_REPO/config/pipeline.json"
C="$T_REPO/config/choices.json"

assert_eq "the AR-07 stage ids, in order" "$(jq -r '.stages[].id' "$P" | tr '\n' ' ')" \
  "doctor plan-draft setup assess plan-final d7-rewrite upgrade php residual validate test report refactor contribute "
assert_eq "ids are unique" "$(jq '[.stages[].id] | (length == (unique | length))' "$P")" "true"
assert_eq "every when condition is in the closed set" \
  "$(jq -c '.conditions as $c | [.stages[] | .when[] | select($c[.] == null)]' "$P")" "[]"
assert_eq "every skip_reason names one of its stage's conditions" \
  "$(jq -c '[.stages[] | select(.skip_reason) | . as $s | .skip_reason | keys[] | select(. as $k | $s.when | index($k) | not)]' "$P")" "[]"
assert_eq "upgrade is skipped as same-major without hops" "$(jq -r '.stages[] | select(.id == "upgrade") | .skip_reason.hops' "$P")" "same-major"
assert_eq "every tab is a config/choices.json key" \
  "$(jq -c --slurpfile ch "$C" '[.stages[].tabs[] | select($ch[0].choices[.] == null)]' "$P")" "[]"
assert_eq "every choice with a stage is a tab of that stage" \
  "$(jq -c --slurpfile p "$P" '[.choices | to_entries[] | select(.value.stage != null) | . as $e
     | select(([$p[0].stages[] | select(.id == $e.value.stage) | .tabs[]] | index($e.key)) == null) | .key]' "$C")" "[]"
assert_eq "INTENT + the stages' tabs in order = a full run's tab sequence" \
  "$(jq -c '["INTENT"] + [.stages[].tabs[]]' "$P")" \
  "$(jq -c '.allowed_insertions as $ins | reduce $ins[] as $i (.full; (index($i.before)) as $at | .[0:$at] + [$i.key] + .[$at:])' "$T_REPO/tests/evals/router/tab-sequence.json")"
assert_eq "sub-step ids are unique per stage" \
  "$(jq -c '[.stages[] | select((.subs | length) != (.subs | unique | length)) | .id]' "$P")" "[]"
assert_eq "each coarse stage is recorded by one stage" \
  "$(jq -c '[.stages[].coarse_stage | select(. != null)] | sort' "$P")" '["assessed","contributed","ported","refactored","setup","tested"]'
assert_eq "the opt-in stages are refactor and contribute, contribute never in auto" \
  "$(jq -c '[.stages[] | select(.when | index("optin")) | .id], ([.stages[] | select(.when | index("not-auto")) | .id])' "$P" | tr '\n' ' ')" \
  '["refactor","contribute"] ["d7-rewrite","contribute"] '
# Procedure anchors: the heading is a step heading (any level) of exactly one skill.
# has_heading FILE TEXT -> 0 when FILE has a markdown heading (#, ##, ...) TEXT.
has_heading() { awk -v h="$2" '/^#+ / { t = $0; sub(/^#+ /, "", t); if (t == h) f = 1 } END { exit !f }' "$1"; }
bad=""
while IFS="$(printf '\t')" read -r sk hd; do
  [[ -n "$sk" ]] || continue
  n=0
  for f in "$T_REPO"/skills/*/SKILL.md; do
    has_heading "$f" "$hd" && n=$((n + 1))
  done
  [[ -f "$T_REPO/skills/$sk/SKILL.md" ]] && has_heading "$T_REPO/skills/$sk/SKILL.md" "$hd" || bad="$bad $sk:$hd(missing)"
  [[ "$n" -le 1 ]] || bad="$bad $sk:$hd(in $n skills)"
done <<EOF
$(jq -r '.stages[].procedure_anchor | select(. != null) | "\(.skill)\t\(.heading)"' "$P")
EOF
assert_eq "every procedure anchor is a step heading of exactly one skill" "$bad" ""
assert_eq "the docs page is generated from it" \
  "$(head -n 3 "$T_REPO/docs/reference/pipeline.md" | sed -n '3p')" "# Pipeline"
assert_eq "  and lists every stage" \
  "$(grep -c '^## ' "$T_REPO/docs/reference/pipeline.md")" "$(( $(jq '.stages | length' "$P") + 1 ))"
t_done
