#!/usr/bin/env bash
# port-summary.sh and the core removals (T-M6-04, ADR 0031): once the subject
# is ported, an open blocking human item of the core removals (a removed base
# theme, a removal with no replacement, a dependency no release covers)
# blocks the port while it describes the current code (the hash of its file,
# else worklist_fresh): status blocked, a core-removals blocker, --strict
# exit 3. A non-blocking item (a dependency to rewrite or to verify), a closed
# item, a stale item (only warned about) and a stage before ported never
# block. make-issue.sh turns each open item into a
# remaining task. Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

S="$T_TMP/rm"; mkdir -p "$S"
printf 'name: RM\ntype: theme\nbase theme: claro\ncore_version_requirement: ^11\n' > "$S/rm.info.yml"
SD="$(project_state_dir "$S")"; mkdir -p "$SD/raw"
IX="$SD/raw/04-assess-index.json"
jq -n --arg d "$(subject_digest "$S")" '{stage: "assess", subject: {machine_name: "rm", path: "rm"}, subject_digest: $d, tools: []}' > "$IX"
jq -n --arg h "$(canon_json_hashable < "$IX" | json_hash)" \
  '{schema: 1, stage: "assess", findings: [{id: "F-1", message: "the theme claro was removed from Drupal core in 12.0: choose a new base theme"}],
    meta: {findings_hash: "sha256:f1", raw: {"04-assess-index.json": $h}}}' > "$SD/findings.json"
wl() {  # wl STATUS BLOCKING REASON [FILE_HASH]
  jq -n --arg st "$1" --argjson b "$2" --arg r "$3" --arg fh "${4:-}" '{schema: 1, stage: "assess", meta: {findings_hash: "sha256:f1"}, items: [
    {id: "W-1", lane: "human", file: "rm.info.yml", status: $st, blocking: $b, reason: $r, finding_ids: ["F-1"]}
    + (if $fh == "" then {} else {file_hash: $fh} end)]}' > "$(worklist_file "$S")"
}
ps() { t_run "$T_SH" "$T_REPO/scripts/analysis/port-summary.sh" --subject "$S" --json "$@"; }
blk() { jq -c '[.status, [.blockers[] | select(.source == "core-removals") | .reason]]' "$T_OUT"; }
st() { jq -r '.status' "$T_OUT"; }

wl open true base-theme-removed
assert_eq "removal_items: the open item, current, with its message" "$(removal_items "$S" | jq -c '[.[] | [.file, .reason, .blocking, .fresh, .messages]]')" \
  '[["rm.info.yml","base-theme-removed",true,true,["the theme claro was removed from Drupal core in 12.0: choose a new base theme"]]]'
ps
assert_eq "before ported: never blocked" "$T_RC|$(st)" "0|not-started"
phase_record "$S" ported > /dev/null
ps --strict
assert_eq "ported, a removed base theme open: blocked, --strict exit 3" "$T_RC|$(blk)" \
  '3|["blocked",["1 open blocking core-removal item(s): rm.info.yml (base-theme-removed)"]]'
wl open true "removed-dependency-no-release; removed-dependency-replaceable"
ps --strict
assert_eq "a dependency no release covers, grouped with another reason: blocked" "$T_RC|$(st)" "3|blocked"
wl open false removed-dependency-replaceable
ps --strict
assert_eq "a dependency to rewrite (not blocking): not blocked" "$T_RC|$(st)" "0|ported"
wl applied true removed-from-core
ps --strict
assert_eq "a closed item: not blocked" "$T_RC|$(st)" "0|ported"
wl open true "no recipe"
ps --strict
assert_eq "another human item: no core-removals blocker" "$T_RC|$(blk)" '0|["ported",[]]'
wl open true base-theme-removed
t_run "$T_SH" "$T_REPO/scripts/contrib/make-issue.sh" --project rm --subject "$S" --output "$T_TMP/issue" --json
assert_eq "make-issue.sh: a remaining task per open core-removal item" \
  "$T_RC|$(jq -r '.summary' "$T_OUT" | grep -c 'Resolve `rm.info.yml`: what the target removes from core (base-theme-removed): the theme claro was removed' || true)" "0|1"
printf '<?php\n' > "$S/rm.theme"
ps --strict
assert_eq "another file changed, the item without file_hash: stale, not blocked" "$T_RC|$(st)" "0|ported"
assert_match "  and warned about" "$(t_err)" "blocking core-removal item"
wl open true base-theme-removed "$(file_hash "$S/rm.info.yml")"
ps --strict
assert_eq "another file changed, the item's own file did not: still blocked" "$T_RC|$(st)" "3|blocked"
printf 'name: RM\ntype: theme\nbase theme: stable9\ncore_version_requirement: ^11\n' > "$S/rm.info.yml"
ps --strict
assert_eq "the item's own file changed: stale, not blocked" "$T_RC|$(st)" "0|ported"
t_done
