#!/usr/bin/env bash
# The stage contract of scripts/ai/pipeline.sh (T-M4-12, AR-07, ADR 0028),
# with stub tools in a copy of the plugin:
# - upgrade -> php -> validate -> report run in catalog order; php extracts,
#   normalizes and classifies at stage php, and fails when a PHP-window
#   finding is in no worklist item; the records keep the input and output
#   digests;
#   a checkpoint ref per stage, the real index and HEAD untouched;
# - a re-run on the same tree, plan and lock: every stage up to date, no tool
#   runs; --force runs them again; a plan with hops [] runs upgrade too
#   (Rector's PHP floor sets and compat pass, the codemods);
# - only a converged fixpoint leaves validate up to date: not converged in
#   warn mode, off, or no output is done with a fixpoint-* reason, and a done
#   record whose fixpoint.json does not say converged runs again;
# - raw/<NN>-<stage>-<tool>.json: a raw report under another NN fails the
#   stage;
# - an injected failure puts the tree back at the stage's own checkpoint and
#   stops the pipeline (exit 3);
# - the run manifest; the usage errors. Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

# A copy of the plugin with stub tools: each logs its call and its stage.
P="$T_TMP/plugin"; mkdir -p "$P/scripts"; cp -R "$T_REPO/scripts/lib" "$T_REPO/scripts/ai" "$T_REPO/scripts/analysis" "$P/scripts/"; cp -R "$T_REPO/config" "$P/"
LOG="$T_TMP/calls"
stub() {  # stub PATH BODY
  printf '#!/bin/sh\necho "%s $*" >> "%s"\n%s\n' "$(basename "$1" .sh)" "$LOG" "$2" > "$P/scripts/$1"; chmod +x "$P/scripts/$1"
}
stub analysis/run-rector.sh 'printf "// rector\n" >> "$STUB_SUBJECT/src/A.php"; exit "${STUB_RECTOR_RC:-0}"'
stub ai/extract.sh 'st=""; prev=""; for a in "$@"; do [ "$prev" = "--stage" ] && st="$a"; prev="$a"; done
nn="${STUB_NN:-$(printf "%02d" "$(jq -r --arg s "$st" "[.stages[].id] | index(\$s) + 1" "$STUB_CAT")")}"
mkdir -p "$STUB_SD/raw"; printf "{}\n" > "$STUB_SD/raw/$nn-$st-phpstan.json"; exit "${STUB_EXTRACT_RC:-0}"'
# The findings and the worklist: one PHP-window finding, in an item unless
# STUB_PHP_GAP is set.
stub ai/normalize-findings.sh 'printf "%s\n" "{\"tools\":{\"php-lint\":\"${STUB_LINT:-ok}\"},\"findings\":[{\"id\":\"F-1\",\"tool\":\"catalog\",\"class\":\"php-target\"}]}" > "$STUB_SD/findings.json"; exit 0'
stub ai/classify.sh 'if [ -n "${STUB_PHP_GAP:-}" ]; then ids=""; else ids="\"F-1\""; fi
printf "%s\n" "{\"items\":[{\"lane\":\"human\",\"status\":\"open\",\"blocking\":true,\"reason\":\"removed-in-target-php\",\"finding_ids\":[$ids]}]}" > "$STUB_SD/worklist.json"; exit 0'
stub ai/apply-recipes.sh 'exit 0'
stub analysis/fixpoint.sh 'if [ -n "${STUB_FIXPOINT_JSON:-}" ]; then j="$STUB_FIXPOINT_JSON"; else j="{\"mode\": \"enforce\", \"converged\": true}"; fi
mkdir -p "$STUB_SD"; printf "%s\n" "$j" > "$STUB_SD/fixpoint.json"; printf "%s\n" "$j"; if [ "${STUB_FIXPOINT_RC:-0}" != 0 ]; then printf "broken\n" >> "$STUB_SUBJECT/src/A.php"; printf "x\n" > "$STUB_SUBJECT/src/New.php"; fi; exit "${STUB_FIXPOINT_RC:-0}"'
stub ai/manifest.sh 'exit 0'
stub analysis/port-report.sh 'exit 0'

# A Drupal root and the module, in its own git repository.
R="$T_TMP/site"; S="$R/web/modules/custom/m"
mkdir -p "$R/web/core/lib" "$S/src"
printf '{"name":"x/site"}\n' > "$R/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$R/web/core/lib/Drupal.php"
printf 'name: M\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$S/m.info.yml"
printf '<?php\n\nnamespace Drupal\\m;\n\nclass A {\n}\n' > "$S/src/A.php"
g() { git -C "$S" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
g init -q; g add -A; g commit -qm base
HEAD0="$(g rev-parse HEAD)"
setplan() {  # setplan HOPS-JSON
  DRUPILOT_PROJECT_DIR="$R" lock_set_json .upgrade_plan "{\"subject\": {\"machine_name\": \"m\"}, \"hops\": $1}" > /dev/null
  DRUPILOT_PROJECT_DIR="$R" lock_set .upgrade_plan_hash "sha256:$(printf '%s' "$1" | sha256_hex)" > /dev/null
}
setplan '["10-11"]'
SD="$(project_state_dir "$S")"
export STUB_SUBJECT="$S" STUB_SD="$SD" STUB_CAT="$P/config/pipeline.json"
pl() { : > "$LOG"; t_run env CLAUDE_PLUGIN_ROOT="$P" "$T_SH" "$P/scripts/ai/pipeline.sh" --subject "$S" "$@"; }
calls() { awk '{ printf "%s%s", (NR > 1 ? "," : ""), $1 }' "$LOG"; }
st() { jq -r --arg s "$1" '.stages[$s] | "\(.status)|\(.reason // "-")"' "$SD/stages.json"; }

pl --run r1 --json
assert_eq "upgrade, php, validate and report in catalog order: exit 0" "$T_RC|$(calls)" \
  "0|run-rector,extract,normalize-findings,classify,apply-recipes,extract,normalize-findings,classify,fixpoint,manifest,port-report"
assert_eq "  the extraction ran at stages upgrade and php, the fixpoint at stage validate" \
  "$(grep -c -- '^extract .*--stage upgrade' "$LOG")|$(grep -c -- '^extract .*--stage php' "$LOG")|$(grep -c -- '^fixpoint .*--stage validate' "$LOG")" "1|1|1"
assert_eq "  the records: done" "$(st upgrade) $(st php) $(st validate) $(st report)" "done|- done|- done|- done|-"
assert_eq "  upgrade changed the tree: its output digest is not its input's; validate's input is upgrade's output" \
  "$(jq -r '[.stages.upgrade.input_digest != .stages.upgrade.output_digest, .stages.validate.input_digest == .stages.upgrade.output_digest] | @csv' "$SD/stages.json")" "true,true"
assert_eq "  the --json summary" "$(jq -c '[.run_id, [.stages[] | .status]]' "$T_OUT")" '["r1",["done","done","done","done"]]'
assert_eq "  a checkpoint ref per stage; HEAD and the real index untouched" \
  "$(g for-each-ref --format='%(refname)' refs/drupilot/stages/r1 | tr '\n' ' ')|$(g rev-parse HEAD)|$(g diff --cached --name-only | wc -l | tr -d ' ')" \
  "refs/drupilot/stages/r1/php refs/drupilot/stages/r1/report refs/drupilot/stages/r1/upgrade refs/drupilot/stages/r1/validate |$HEAD0|0"
assert_eq "  the run is recorded" "$(jq -r '.tool' "$SD"/runs/*/run-manifest.json | sort -u)" "pipeline"
assert_eq "  the raw reports under each stage's own NN" "$(ls "$SD/raw" | tr '\n' ' ')" "07-upgrade-phpstan.json 08-php-phpstan.json "

# A re-run on the same tree, plan and lock: nothing runs.
pl --json
assert_eq "a re-run: every stage up to date, no tool runs" "$T_RC|$(calls)|$(jq -c '[.stages[].status] | unique' "$T_OUT")" '0||["up-to-date"]'
STUB_LINT=skipped pl --stages php --force
pl
assert_eq "a stage that runs (php, its php -l skipped before) runs the ones after it" "$T_RC|$(calls)" "0|extract,normalize-findings,classify,fixpoint,manifest,port-report"
pl --force
assert_eq "  --force runs them again" "$T_RC|$(calls)" "0|run-rector,extract,normalize-findings,classify,apply-recipes,extract,normalize-findings,classify,fixpoint,manifest,port-report"
# A tree rolled back to before upgrade runs it again.
g checkout -q -- src/A.php
pl
assert_eq "a tree rolled back to before upgrade: upgrade runs again" "$T_RC|$(calls | cut -d, -f1)" "0|run-rector"

# A same-major plan: upgrade runs too (Rector's PHP floor sets and compat
# pass, the codemods).
setplan '[]'
pl
assert_eq "hops []: upgrade runs too, then the other stages" "$T_RC|$(st upgrade)|$(calls)" \
  "0|done|-|run-rector,extract,normalize-findings,classify,apply-recipes,extract,normalize-findings,classify,fixpoint,manifest,port-report"
setplan '["10-11"]'

# A fixpoint that did not converge in warn mode: done, with its reason, and
# never up to date (an enforce run judges it again).
STUB_FIXPOINT_JSON='{"converged": false, "mode": "warn"}' pl --stages validate --force
assert_eq "fixpoint not converged in warn mode: validate done, reason fixpoint-not-converged" "$T_RC|$(st validate)" "0|done|fixpoint-not-converged"
pl --stages validate
assert_eq "  so it is not up to date: the gate runs again" "$T_RC|$(calls)|$(st validate)" "0|fixpoint|done|-"
pl --stages validate
assert_eq "  converged: then it is up to date" "$T_RC|$(calls)" "0|"
STUB_FIXPOINT_JSON='{"schema": 1, "mode": "off", "converged": null}' pl --stages validate --force
assert_eq "fixpoint off: validate done, reason fixpoint-off" "$T_RC|$(st validate)" "0|done|fixpoint-off"
pl --stages validate
assert_eq "  so the next run judges it: the gate runs again" "$T_RC|$(calls)|$(st validate)" "0|fixpoint|done|-"
STUB_FIXPOINT_JSON=' ' pl --stages validate --force
assert_eq "a gate with no output: done, reason fixpoint-no-verdict" "$T_RC|$(st validate)" "0|done|fixpoint-no-verdict"
pl --stages validate
printf '{"converged": false}\n' > "$SD/fixpoint.json"
pl --stages validate
assert_eq "a done record whose fixpoint.json is not converged (an earlier version's warn run): the gate runs again" "$T_RC|$(calls)" "0|fixpoint"

# A raw report under another NN fails the stage, and its changes go back.
cp "$S/src/A.php" "$T_TMP/A.before"
STUB_NN=99 pl --stages upgrade
assert_eq "a raw report under another number: upgrade failed (exit 3), the tree back at its checkpoint" \
  "$T_RC|$(st upgrade)|$(cmp -s "$S/src/A.php" "$T_TMP/A.before" && echo restored)" "3|failed|exit 1|restored"
rm -f "$SD/raw/99-upgrade-phpstan.json"

# An injected failure in validate: back to validate's own checkpoint (after
# upgrade), report never runs.
pl --stages upgrade
cp "$S/src/A.php" "$T_TMP/A.validate"
STUB_FIXPOINT_RC=3 pl --run r9
assert_eq "an injected failure in validate: exit 3, report not run" "$T_RC|$(calls)|$(st validate)" "3|extract,normalize-findings,classify,fixpoint|failed|exit 3"
assert_eq "  the tree back at validate's checkpoint: its edit undone, its new file removed" \
  "$(cmp -s "$S/src/A.php" "$T_TMP/A.validate" && echo restored)|$([[ -e "$S/src/New.php" ]] && echo left || echo removed)" "restored|removed"
assert_eq "  HEAD and the real index still untouched" "$(g rev-parse HEAD)|$(g diff --cached --name-only | wc -l | tr -d ' ')" "$HEAD0|0"
pl
assert_eq "  the next run resumes at validate (upgrade is up to date)" "$T_RC|$(calls)" "0|fixpoint,manifest,port-report"

# The php stage: Rector's or PHPStan's missing verdict (extract exit 3) is
# validate's to judge; a php -l that did not run on every leg, or a placeholder
# record of 1.0.0-alpha.1, is never up to date.
STUB_EXTRACT_RC=3 pl --stages php --force
assert_eq "extract.sh exit 3 in php: warned, the stage done" "$T_RC|$(st php)|$(calls)" "0|done|-|extract,normalize-findings,classify"
STUB_LINT=skipped pl --stages php --force
assert_eq "php -l skipped: done, its reason recorded" "$T_RC|$(st php)" "0|done|php-lint-skipped"
STUB_LINT=skipped pl --stages php
assert_eq "  so the stage is not up to date: it runs again" "$T_RC|$(calls)" "0|extract,normalize-findings,classify"
jq '.stages.php.status = "skipped" | .stages.php.reason = "placeholder"' "$SD/stages.json" > "$T_TMP/st" && mv "$T_TMP/st" "$SD/stages.json"
pl --stages php
assert_eq "an alpha.1 placeholder record on the same tree: the stage runs" "$T_RC|$(calls)|$(st php)" "0|extract,normalize-findings,classify|done|-"
pl --stages php
assert_eq "  then it is up to date" "$T_RC|$(calls)" "0|"

# The php gate: a PHP-window finding in no worklist item fails the stage.
STUB_PHP_GAP=1 pl --stages php --force
assert_eq "a PHP-window finding in no item: php failed (exit 3)" "$T_RC|$(st php)" "3|failed|exit 1"

# Usage errors.
mkdir -p "$T_TMP/nogit"; printf 'name: N\ntype: module\n' > "$T_TMP/nogit/nogit.info.yml"
t_run env CLAUDE_PLUGIN_ROOT="$P" "$T_SH" "$P/scripts/ai/pipeline.sh" --subject "$T_TMP/nogit"
assert_eq "no git repository: exit 1" "$T_RC" "1"
pl --stages upgrade,nowhere
assert_eq "an unknown stage: exit 1" "$T_RC" "1"
pl --run 'a b'
assert_eq "a run id with a space: exit 1" "$T_RC" "1"
pl --bogus
assert_eq "an unknown flag: exit 1" "$T_RC" "1"
t_done
