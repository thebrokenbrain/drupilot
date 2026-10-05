#!/usr/bin/env bash
# Freshness across subject_digest algorithms (T-M4-02, AR-13): a record
# drupilot 0.9 wrote (no digest_algo) is stale with stale_reason
# "digest-algorithm" everywhere a verdict is shown (digest_freshness, the
# state snapshot, the port report, the next step, the layer report), yet
# port-summary keeps its failing verdict blocking, since its sources may be
# the same; a current record on changed sources is stale "sources-changed" and
# does not block, as in 0.9.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

R="$T_TMP/root"; S="$R/web/modules/custom/legacy_widgets"
mkdir -p "$R/web/core/lib" "$R/web/modules/custom" "$R/.ddev"
printf '{"name":"x/root"}\n' > "$R/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$R/web/core/lib/Drupal.php"
printf 'name: dpl-x\ntype: drupal11\ndocroot: web\n' > "$R/.ddev/config.yaml"
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$S"
SD="$(project_state_dir "$S")"
printf '{"verdict":"S"}\n' > "$SD/assess.json"
printf '{"schema":1,"stage":"ported","stages":{"ported":"2026-10-03T00:00:00Z"},"machine_name":"legacy_widgets","type":"module"}\n' > "$SD/state.json"
# The 0.9 digest of these sources (algorithm 1: no header, no Twig/JS/CSS).
V1="$( ( cd -P "$S" && find . \( -name .git -o -name vendor -o -name node_modules \) -prune -o -type f \
  \( -name '*.php' -o -name '*.module' -o -name '*.inc' -o -name '*.install' -o -name '*.theme' \
     -o -name '*.profile' -o -name '*.engine' -o -name '*.yml' -o -name composer.json \) -print \
  | LC_ALL=C sort | while IFS= read -r f; do printf '%s\n' "$f"; cat "$f"; done ) | sha256_hex)"
record() {   # record STATUS PRESERVATION DIGEST [ALGO]
  jq -n --arg st "$1" --arg p "$2" --arg d "$3" --arg a "${4:-}" \
    '{type: "all", status: $st, preservation: $p, ran: 1, passed: 1, failed: 0, skipped: 0,
      subject_digest: $d, recorded_at: "2026-10-03T00:00:00Z"} + (if $a == "" then {} else {digest_algo: ($a | tonumber)} end)' \
    > "$SD/last-test.json"
}
RDY=(--ready-analyze true --ready-setup true --ready-test true --ready-contribute true)
next() { "$T_SH" "$T_REPO/scripts/env/next-step.sh" --subject "$S" "${RDY[@]}" 2> /dev/null | jq -r .next; }
summary() { "$T_SH" "$T_REPO/scripts/analysis/port-summary.sh" --subject "$S" --strict --json > "$T_TMP/ps.json" 2> /dev/null; echo "$?|$(jq -r .status "$T_TMP/ps.json")"; }

# --- a 0.9 record -------------------------------------------------------------
record passed verified "$V1"
assert_eq "digest_freshness: a 0.9 record is stale (digest-algorithm)" \
  "$(digest_freshness "$S" "$SD/last-test.json")" "false digest-algorithm"
assert_eq "  the state snapshot says so" \
  "$(state_snapshot_json "$S" | jq -c '[.tests.fresh, .tests.stale_reason]')" '[false,"digest-algorithm"]'
assert_eq "  a green 0.9 run is not current proof: the next step tests again" "$(next)" "test"
"$T_SH" "$T_REPO/scripts/analysis/port-report.sh" --subject "$S" > /dev/null 2>&1
assert_match "  the port report marks it stale" "$(cat "$R/.drupilot/port-report.md" 2> /dev/null)" '\| Preservation \| verified \(stale\) \|'
assert_eq "  the layer report keeps tests_fresh false" \
  "$("$T_SH" "$T_REPO/scripts/analysis/layer-report.sh" --subject "$S" --json 2> /dev/null | jq -c '[.modules[0].tests_fresh]')" "[false]"
record failed regression "$V1"
assert_eq "  a 0.9 regression keeps blocking port-summary --strict" "$(summary)" "3|blocked"

# --- current records -------------------------------------------------------------
record passed verified "$(subject_digest "$S")" "$(subject_digest_algo)"
assert_eq "a current record on the same sources: fresh" "$(digest_freshness "$S" "$SD/last-test.json")" "true"
assert_eq "  green and fresh: no test step" "$([[ "$(next)" != "test" ]] && echo moved-on)" "moved-on"
record failed regression "$(subject_digest "$S")" "$(subject_digest_algo)"
assert_eq "  a fresh regression blocks" "$(summary)" "3|blocked"
printf '\n// edited\n' >> "$S/legacy_widgets.module"
assert_eq "the sources changed: stale (sources-changed)" "$(digest_freshness "$S" "$SD/last-test.json")" "false sources-changed"
assert_eq "  the snapshot's reason" "$(state_snapshot_json "$S" | jq -r .tests.stale_reason)" "sources-changed"
assert_eq "  a regression on other sources no longer blocks (as in 0.9)" "$(summary | cut -d'|' -f1)" "0"
rm -f "$SD/last-test.json"
assert_eq "no record: unknown" "$(digest_freshness "$S" "$SD/last-test.json")" "unknown"
t_done
