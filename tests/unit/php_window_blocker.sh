#!/usr/bin/env bash
# port-summary.sh and the PHP window (T-M5-07): once the subject is ported, an
# open blocking human item of the PHP window that describes the current code
# blocks the port: status blocked, a php-target blocker, --strict exit 3. An
# item is current while its file has the hash it was classified with
# (file_hash; another file's edit changes nothing), else while the whole
# worklist is (worklist_fresh: the stage's raw index has the subject's digest,
# findings.json was built from that index, the worklist from that
# findings.json). A report-only item, a closed item, another human item, a
# stale item (only warned about) and a stage before ported never block.
# make-issue.sh turns each open item into a remaining task, a stale one marked
# for a re-check. Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

S="$T_TMP/pw"; mkdir -p "$S/src"
printf 'name: PW\ntype: module\ncore_version_requirement: ^11.3\n' > "$S/pw.info.yml"
printf '<?php\nfunction pw_x($a) { return each($a); }\n' > "$S/pw.module"
printf '<?php\nclass Other {}\n' > "$S/src/Other.php"
SD="$(project_state_dir "$S")"; mkdir -p "$SD/raw"
IX="$SD/raw/08-php-index.json"
index_now() { jq -n --arg d "$(subject_digest "$S")" '{stage: "php", subject: {machine_name: "pw", path: "pw"}, subject_digest: $d, tools: []}' > "$IX"; }
findings() {  # findings -> findings.json built from the current index
  jq -n --arg h "$(canon_json_hashable < "$IX" | json_hash)" \
    '{schema: 1, stage: "php", findings: [{id: "F-1", message: "each() is removed in PHP 8.0"}],
      meta: {findings_hash: "sha256:f1", raw: {"08-php-index.json": $h}}}' > "$SD/findings.json"
}
wl() {  # wl STATUS BLOCKING REASON [FILE_HASH]
  jq -n --arg st "$1" --argjson b "$2" --arg r "$3" --arg fh "${4:-}" '{schema: 1, stage: "php", meta: {findings_hash: "sha256:f1"}, items: [
    {id: "W-1", lane: "human", file: "pw.module", status: $st, blocking: $b, reason: $r, finding_ids: ["F-1"]}
    + (if $fh == "" then {} else {file_hash: $fh} end)]}' > "$(worklist_file "$S")"
}
ps() { t_run "$T_SH" "$T_REPO/scripts/analysis/port-summary.sh" --subject "$S" --json "$@"; }
blk() { jq -c '[.status, [.blockers[] | select(.source == "php-target") | .reason]]' "$T_OUT"; }
st() { jq -r '.status' "$T_OUT"; }

# The whole worklist current (no file_hash on the item).
index_now; findings; wl open true removed-in-target-php
assert_eq "worklist_fresh: index, findings and worklist agree" "$(worklist_fresh "$S" && echo fresh)" "fresh"
ps
assert_eq "before ported: never blocked" "$T_RC|$(st)" "0|not-started"
phase_record "$S" ported > /dev/null
ps --strict
assert_eq "ported, a removed construct open: blocked, --strict exit 3" "$T_RC|$(blk)" \
  '3|["blocked",["1 open blocking PHP-window item(s): pw.module (removed-in-target-php)"]]'
wl open true does-not-compile
ps --strict
assert_eq "a file no window PHP that ran compiles: blocked" "$T_RC|$(st)" "3|blocked"
wl open false fix-needs-php-above-floor
ps --strict
assert_eq "a report-only item (not blocking): not blocked" "$T_RC|$(st)" "0|ported"
wl applied true removed-in-target-php
ps --strict
assert_eq "a closed item: not blocked" "$T_RC|$(st)" "0|ported"
wl open true "no recipe"
ps --strict
assert_eq "another human item: not a PHP-window blocker" "$T_RC|$(st)" "0|ported"
wl open true removed-in-target-php
jq '.meta.findings_hash = "sha256:other"' "$(worklist_file "$S")" > "$T_TMP/w" && mv "$T_TMP/w" "$(worklist_file "$S")"
assert_eq "worklist_fresh: a worklist of another findings.json is not current" "$(worklist_fresh "$S" || echo stale)" "stale"
wl open true removed-in-target-php
jq '.meta.raw["08-php-index.json"] = "sha256:old"' "$SD/findings.json" > "$T_TMP/f" && mv "$T_TMP/f" "$SD/findings.json"
assert_eq "worklist_fresh: findings.json of another index is not current" "$(worklist_fresh "$S" || echo stale)" "stale"
findings
t_run "$T_SH" "$T_REPO/scripts/contrib/make-issue.sh" --project pw --subject "$S" --output "$T_TMP/issue" --json
assert_eq "make-issue.sh: a remaining task per open PHP-window item" \
  "$T_RC|$(jq -r '.summary' "$T_OUT" | grep -c 'Fix `pw.module` for the PHP window (removed-in-target-php): each() is removed in PHP 8.0$' || true)" "0|1"

# Another file changes: the worklist is no longer current, but an item with
# the hash of its own, unchanged file still is.
printf '<?php\nclass Other { public $x; }\n' > "$S/src/Other.php"
ps --strict
assert_eq "sources changed, the item without file_hash: stale, not blocked" "$T_RC|$(st)" "0|ported"
assert_match "  and warned about" "$(t_err)" "blocking PHP-window item"
wl open true removed-in-target-php "$(file_hash "$S/pw.module")"
ps --strict
assert_eq "another file changed, the item's file did not: still blocked" "$T_RC|$(st)" "3|blocked"
printf '<?php\nfunction pw_x($a) { return current($a); }\n' > "$S/pw.module"
ps --strict
assert_eq "the item's own file changed: stale, not blocked" "$T_RC|$(st)" "0|ported"
t_run "$T_SH" "$T_REPO/scripts/contrib/make-issue.sh" --project pw --subject "$S" --output "$T_TMP/issue" --json
assert_eq "  make-issue.sh: the task marked for a re-check" \
  "$(jq -r '.summary' "$T_OUT" | grep -c 'found before the file last changed: re-check it' || true)" "1"
t_done
