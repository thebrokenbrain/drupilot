#!/usr/bin/env bash
# port-summary.sh and the PHP window (T-M5-07): once the subject is ported, an
# open blocking human item of the PHP window in a worklist extracted from the
# current sources (its raw index's subject_digest) blocks the port: status
# blocked, a php-target blocker, --strict exit 3. A report-only item, a closed
# item, a stale worklist (the sources changed since) and a stage before ported
# never block. make-issue.sh turns each open PHP-window item into a remaining
# task. Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

S="$T_TMP/pw"; mkdir -p "$S/src"
printf 'name: PW\ntype: module\ncore_version_requirement: ^11.3\n' > "$S/pw.info.yml"
printf '<?php\nfunction pw_x($a) { return each($a); }\n' > "$S/pw.module"
SD="$(project_state_dir "$S")"; mkdir -p "$SD/raw"
jq -n --arg d "$(subject_digest "$S")" '{stage: "php", subject: {machine_name: "pw", path: "pw"}, subject_digest: $d, tools: []}' > "$SD/raw/08-php-index.json"
wl() {  # wl STATUS BLOCKING REASON
  jq -n --arg st "$1" --argjson b "$2" --arg r "$3" '{schema: 1, stage: "php", items: [
    {id: "W-1", lane: "human", file: "pw.module", status: $st, blocking: $b, reason: $r, finding_ids: ["F-1"]}]}' > "$(worklist_file "$S")"
}
ps() { t_run "$T_SH" "$T_REPO/scripts/analysis/port-summary.sh" --subject "$S" --json "$@"; }
blk() { jq -c '[.status, [.blockers[] | select(.source == "php-target") | .reason]]' "$T_OUT"; }

wl open true removed-in-target-php
ps
assert_eq "before ported: never blocked" "$T_RC|$(jq -r '.status' "$T_OUT")" "0|not-started"
phase_record "$S" ported > /dev/null
ps --strict
assert_eq "ported, a removed construct open: blocked, --strict exit 3" "$T_RC|$(blk)" \
  '3|["blocked",["1 open blocking PHP-window item(s): pw.module (removed-in-target-php)"]]'
wl open true does-not-compile
ps --strict
assert_eq "a file no window PHP compiles: blocked" "$T_RC|$(jq -r '.status' "$T_OUT")" "3|blocked"
wl open false fix-needs-php-above-floor
ps --strict
assert_eq "a report-only item (not blocking): not blocked" "$T_RC|$(jq -r '.status' "$T_OUT")" "0|ported"
wl applied true removed-in-target-php
ps --strict
assert_eq "a closed item: not blocked" "$T_RC|$(jq -r '.status' "$T_OUT")" "0|ported"
wl open true "no recipe"
ps --strict
assert_eq "another human item: not a PHP-window blocker" "$T_RC|$(jq -r '.status' "$T_OUT")" "0|ported"
wl open true removed-in-target-php
jq -n '{schema: 1, findings: [{id: "F-1", message: "each() is removed in PHP 8.0"}]}' > "$SD/findings.json"
t_run "$T_SH" "$T_REPO/scripts/contrib/make-issue.sh" --project pw --subject "$S" --output "$T_TMP/issue" --json
assert_eq "make-issue.sh: a remaining task per open PHP-window item" "$T_RC|$(jq -r '.summary' "$T_OUT" | grep -c 'Fix `pw.module` for the PHP window (removed-in-target-php): each() is removed in PHP 8.0' || true)" "0|1"
printf '<?php\nfunction pw_x($a) { return current($a); }\n' > "$S/pw.module"
ps --strict
assert_eq "the sources changed since the extraction: stale, not blocked" "$T_RC|$(jq -r '.status' "$T_OUT")" "0|ported"
t_run "$T_SH" "$T_REPO/scripts/contrib/make-issue.sh" --project pw --subject "$S" --output "$T_TMP/issue" --json
assert_eq "  make-issue.sh: no task from a stale worklist" "$(jq -r '.summary' "$T_OUT" | grep -c 'PHP window' || true)" "0"
t_done
