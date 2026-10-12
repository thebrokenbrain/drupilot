#!/usr/bin/env bash
# The PHP window on its fixtures (T-M5-01, T-M5-07), on the data snapshot
# tests/golden/php-window/golden.json pins:
# - php-target.sh on php_window for the two windows of the plan, ^10.3 || ^11
#   at 8.4 (8.1..8.4) and ^11.3 || ^12 at 8.5 (8.3..8.5), and on d11_php_only
#   (8.3..8.5), byte for byte with tests/golden/php-window/<case>.json: the
#   classes (apply-compat, report-only, deny, removed-blocking) and the
#   constructs found;
# - the recorded php -l legs (tests/fixtures/<fixture>.golden/raw/) have one
#   leg per minor of their window;
# - d11_php_only end to end without Docker: its scan and its recorded legs
#   through normalize-findings.sh and classify.sh give a blocking human item
#   (removed-in-target-php) for each(), and once the module is ported
#   port-summary.sh --strict exits 3.
# Capture (only on purpose, then golden.sh --update, in its own commit):
#   bash tests/unit/php_window_golden.sh --capture
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
G="$T_REPO/tests/golden/php-window"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$G/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
F="$T_TMP/fx"; mkdir -p "$F"
for d in php_window d11_php_only; do cp -R "$T_REPO/tests/fixtures/$d" "$F/$d"; done

# The cases: "<file>|<subject>|<floor>|<target>".
CASES="php_window.w81-84|php_window|8.1|8.4
php_window.w83-85|php_window|8.3|8.5
d11_php_only.w83-85|d11_php_only|8.3|8.5"
while IFS='|' read -r name subj l p; do
  t_run "$T_SH" "$T_REPO/scripts/analysis/php-target.sh" --subject "$F/$subj" --floor "$l" --target "$p" --json
  if [[ "${1:-}" == "--capture" ]]; then cp "$T_OUT" "$G/$name.json"; continue; fi
  assert_eq "$name: exit 0" "$T_RC" "0"
  assert_file_eq "$name: the golden" "$T_OUT" "$G/$name.json"
done <<EOF
$CASES
EOF
if [[ "${1:-}" == "--capture" ]]; then printf 'captured\n'; exit 0; fi
assert_eq "php_window 8.1..8.4: the compat rule and the deny rows; nothing removed" \
  "$(jq -c '[(.classes["apply-compat"] | index("p84-implicit-nullable") != null), (.classes.deny | index("deny-sleep-to-serialize") != null), .counts]' "$G/php_window.w81-84.json")" \
  '[true,true,{"removed_blocking":0,"report_only":0}]'
assert_eq "php_window 8.3..8.5: the (integer) cast and the PDO constant are reported" \
  "$(jq -c '[.findings[] | [.id, .file]]' "$G/php_window.w83-85.json")" \
  '[["p85-cast-names","php_window.module"],["p85-pdo-mysql-constants","src/Connection.php"]]'
assert_eq "d11_php_only 8.3..8.5: each() blocks" "$(jq -c '[.findings[] | [.id, .class, .severity, .file]]' "$G/d11_php_only.w83-85.json")" \
  '[["removed-each","removed-blocking","error","d11_php_only.module"]]'

# The recorded php -l legs: one per minor of the window.
for rec in php_window:w81-84:8.1,8.2,8.3,8.4 php_window:w83-85:8.3,8.4,8.5 d11_php_only:w83-85:8.3,8.4,8.5; do
  fx="${rec%%:*}"; rest="${rec#*:}"; w="${rest%%:*}"; legs="${rest#*:}"
  assert_eq "$fx $w: one php -l leg per window minor" \
    "$(jq -r '[.legs[].php] | join(",")' "$T_REPO/tests/fixtures/$fx.golden/raw/php-lint.$w.json")" "$legs"
done

# d11_php_only end to end, Docker-free: the php stage's raw set (the other
# tools clean), normalize, classify, then port-summary once ported.
S="$F/d11_php_only"; SD="$(project_state_dir "$S")"; RAW="$SD/raw"; mkdir -p "$RAW"
jq -n --arg d "$(subject_digest "$S")" --argjson da "$(subject_digest_algo)" '{stage: "php", subject: {machine_name: "d11_php_only", path: "d11_php_only"},
  target_major: 11, subject_digest: $d, digest_algo: $da,
  tools: [{tool: "php-target", file: "08-php-php-target.json", exit_code: 0}, {tool: "php-lint", file: "08-php-php-lint.json", exit_code: 0}]}' > "$RAW/08-php-index.json"
printf '{"status": "ok", "file_diffs": []}\n' > "$RAW/08-php-rector.json"
printf '{"totals": {"errors": 0, "file_errors": 0}, "files": {}}\n' > "$RAW/08-php-phpstan.json"
printf '{"totals": {"errors": 0, "warnings": 0}, "files": {}}\n' > "$RAW/08-php-phpcs.json"
for t in port-safety signatures metadata; do printf '{"findings": []}\n' > "$RAW/08-php-$t.json"; done
printf '[]\n' > "$RAW/08-php-anchors.json"
cp "$G/d11_php_only.w83-85.json" "$RAW/08-php-php-target.json"
cp "$T_REPO/tests/fixtures/d11_php_only.golden/raw/php-lint.w83-85.json" "$RAW/08-php-php-lint.json"
t_run "$T_SH" "$T_REPO/scripts/ai/normalize-findings.sh" --subject "$S" --stage php --target-major 11 --soft-policy report
assert_eq "normalize-findings.sh: exit 0, every tool ok" "$T_RC|$(jq -c '.tools | [.["php-target"], .["php-lint"]]' "$SD/findings.json")" '0|["ok","ok"]'
t_run "$T_SH" "$T_REPO/scripts/ai/classify.sh" --subject "$S"
assert_eq "classify.sh: each() is a blocking human item, removed-in-target-php" \
  "$T_RC|$(jq -c '[.items[] | select(.lane == "human") | [.file, .blocking, .reason, .status]]' "$(worklist_file "$S")")" \
  '0|[["d11_php_only.module",true,"removed-in-target-php","open"]]'
phase_record "$S" ported > /dev/null
t_run "$T_SH" "$T_REPO/scripts/analysis/port-summary.sh" --subject "$S" --json --strict
assert_eq "port-summary.sh --strict: blocked, exit 3" "$T_RC|$(jq -c '[.status, [.blockers[].source]]' "$T_OUT")" '3|["blocked",["php-target"]]'
t_done
