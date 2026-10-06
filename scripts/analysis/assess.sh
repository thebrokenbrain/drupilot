#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/assess.sh
# The viability assessment, computed (07-R4, AR-10, ADR 0025): the S/M/L/XL
# verdict from three counts, the threshold rule that matched, and everything
# the viability report shows, as assess.json; the viability-assessment skill
# only narrates it.
#
#   manual         the occurrences of scope-current PHPStan deprecations of
#                  class hard or unknown that no Drupal Rector rule changes in
#                  the same function or method (a DrupalRector\ rule, or the
#                  Renaming/Transform/Arguments/Removing rules drupal-rector
#                  configures, at the same (file, anchor); a file-level anchor,
#                  or anchors unavailable, never counts as covered), plus the
#                  signature and port-safety findings of severity error
#                  (manual_items, each with its occurrences)
#   hard_breaks    the categories of config/catalog/hard-breaks.json with at
#                  least one matching file of the subject
#   blocking_deps  deps-status.sh's blockers (no Drupal 11 release on
#                  drupal.org; offline every contrib dependency is unknown)
#
#   XL  blocking_deps >= 1 or hard_breaks >= 3 or manual > 40
#   L   hard_breaks == 2 or manual > 15
#   M   hard_breaks == 1 or manual >= 5
#   S   otherwise                                     (first match wins)
#
# It runs the assess stage itself (scripts/ai/extract.sh, normalize-findings.sh,
# classify.sh), scripts/analysis/core-strategy.sh and deps-status.sh, writes
# assess.json (schema 1: the counts, the rule, the core-target decision, the
# hard-break files, the hygiene totals, findings_hash, worklist_hash and
# subject_digest; its time under meta) to the subject's hidden state dir,
# renders viability-report.md from templates/viability-report.md.tmpl into
# the visible .drupilot/ dir, and records the assessed stage with its effort.
# Next-major findings never count (X18). The settings are read from the
# subject's Drupal root (DRUPILOT_PROJECT_DIR), wherever it is run from. When
# Rector or PHPStan gave no verdict (findings.json tools: failed or missing)
# the verdict is provisional: assess.json says so, the stage is not recorded,
# and the exit code is 3. The digests layer is not part of the assessment, so
# a deprecation only a digests rule fixes counts as manual.
#
# Usage:
#   assess.sh --subject DIR [--findings FILE --worklist FILE] [--deps FILE]
#             [--offline] [--no-record] [--json] [-h|--help]
#     --subject DIR      the module/theme
#     --findings FILE    read this findings.json and --worklist FILE instead of
#                        running the assess stage (a golden's; no Docker)
#     --deps FILE        read this deps-status.sh --json instead of running it
#     --offline          deps-status.sh without the network
#     --no-record        do not record the stage in state.json
#     --json             print assess.json on STDOUT
#
# Exit codes: 0 assessed · 1 usage error, not a Drupal extension (no
# <machine_name>.info.yml), no Drupal root to run the assess stage in (run
# /drupilot-setup first), or no findings to assess · 2 jq missing · 3 assessed,
# but Rector or PHPStan gave no verdict (assess.json: provisional, tools).
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""; FINDINGS=""; WORKLIST=""; DEPS=""; OFFLINE=0; RECORD=1; AS_JSON=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --findings) FINDINGS="${2:-}"; shift 2 || die "--findings needs a value" 1;;
    --worklist) WORKLIST="${2:-}"; shift 2 || die "--worklist needs a value" 1;;
    --deps) DEPS="${2:-}"; shift 2 || die "--deps needs a value" 1;;
    --offline) OFFLINE=1; shift;;
    --no-record) RECORD=0; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ -n "$SUBJECT" && -d "$SUBJECT" ]] || die "Pass --subject DIR (an existing directory)." 1
[[ -z "$FINDINGS" && -z "$WORKLIST" || -n "$FINDINGS" && -n "$WORKLIST" ]] || die "Pass --findings and --worklist together." 1
have_cmd jq || die "jq is required (run /drupilot-doctor)." 2
SUBJECT="$(cd "$SUBJECT" && pwd)"
S="$(plugin_root)/scripts"
MN="$(subject_machine_name "$SUBJECT" 2> /dev/null || basename "$SUBJECT")"
TYPE="$(subject_type "$SUBJECT" 2> /dev/null || echo module)"
INFO="$SUBJECT/$MN.info.yml"
[[ -f "$INFO" ]] || die "$SUBJECT is not a Drupal extension (no $MN.info.yml)." 1
# The settings of the subject's Drupal root, wherever this runs from.
ROOT="$(find_drupal_root "$SUBJECT" 2> /dev/null || true)"
[[ -n "$ROOT" ]] || ROOT="$(subject_project_root "$SUBJECT" 2> /dev/null || true)"
if [[ -n "$ROOT" && -d "$ROOT" && -z "${DRUPILOT_PROJECT_DIR:-}" ]]; then export DRUPILOT_PROJECT_DIR="$ROOT"; fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-assess.XXXXXX")"
trap 'rm -rf "$TMP" 2> /dev/null || true' EXIT

# The assess stage (S2..S4), unless given.
RC=0
if [[ -z "$FINDINGS" ]]; then
  _rc=0; bash "$S/ai/extract.sh" --subject "$SUBJECT" --stage assess < /dev/null || _rc=$?
  case "$_rc" in 0|3) ;; 2) die "No Drupal root to run the assess stage in: run /drupilot-setup first." 1;; *) die "extract.sh failed (exit $_rc)." 1;; esac
  bash "$S/ai/normalize-findings.sh" --subject "$SUBJECT" --stage assess < /dev/null || die "normalize-findings.sh failed." 1
  bash "$S/ai/classify.sh" --subject "$SUBJECT" < /dev/null || die "classify.sh failed." 1
  FINDINGS="$(project_state_dir "$SUBJECT")/findings.json"; WORKLIST="$(worklist_file "$SUBJECT")"
fi
jq -e '.schema == 1 and (.findings | type) == "array"' "$FINDINGS" > /dev/null 2>&1 || die "$FINDINGS is not a findings.json." 1
jq -e '.schema == 1 and (.items | type) == "array"' "$WORKLIST" > /dev/null 2>&1 || die "$WORKLIST is not a worklist.json." 1

# The core-target decision and the dependencies.
bash "$S/analysis/core-strategy.sh" --subject "$SUBJECT" --json < /dev/null > "$TMP/cs.json" 2> /dev/null || true
jq -e 'type == "object"' "$TMP/cs.json" > /dev/null 2>&1 || printf '{}\n' > "$TMP/cs.json"
if [[ -n "$DEPS" ]]; then
  cp "$DEPS" "$TMP/deps.json" 2> /dev/null || die "Cannot read $DEPS." 1
else
  set -- --subject "$SUBJECT" --json; [[ "$OFFLINE" == "1" ]] && set -- "$@" --offline
  bash "$S/analysis/deps-status.sh" "$@" < /dev/null > "$TMP/deps.json" 2> /dev/null || true
fi
jq -e 'type == "object"' "$TMP/deps.json" > /dev/null 2>&1 || printf '{}\n' > "$TMP/deps.json"

# The hard breaks: each catalog category's matching files (vendor/,
# node_modules/ and .git/ left out; an unreadable directory skipped), relative
# to the subject, sorted. One glob per line, never expanded by the shell.
CAT="$(plugin_root)/config/catalog/hard-breaks.json"
jq -r '.entries[] | .id as $id | .ere as $e | .globs[] | [$id, $e, .] | join("\u001f")' "$CAT" > "$TMP/hbq"
while IFS="$(printf '\037')" read -r id ere g; do
  ( cd "$SUBJECT" && find . \( -name vendor -o -name node_modules -o -name .git \) -prune -o -type f -name "$g" -print 2> /dev/null || true ) \
    | sed 's#^\./##' | while IFS= read -r f; do
      if grep_q -E -- "$ere" "$SUBJECT/$f"; then printf '%s\t%s\n' "$id" "$f"; fi
    done
done < "$TMP/hbq" | LC_ALL=C sort -u > "$TMP/hb.tsv"
HB="$(jq -R -s -c --slurpfile c "$CAT" 'split("\n") | map(select(length > 0) | split("\t")) as $hits
  | [$c[0].entries[] | .id as $id | {key: $id, value: ([$hits[] | select(.[0] == $id) | .[1]] | unique)}] | from_entries' "$TMP/hb.tsv")"

# info.yml: the current requirement and whether it admits the target major.
CUR_REQ="$(sed -n 's/^core_version_requirement[[:space:]]*:[[:space:]]*//p' "$INFO" 2> /dev/null | sed -n '1p' | tr -d "'\"" | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//')"
TMAJ="$(jq -r '.target.major // empty' "$FINDINGS")"; [[ -n "$TMAJ" ]] || TMAJ="$(resolve_target_major)"
CUR_ADMITS=false
if [[ -n "$CUR_REQ" ]] && constraint_admits_major "$CUR_REQ" "$TMAJ"; then CUR_ADMITS=true; fi
THRESH="$(config_get DRUPILOT_VIABILITY_THRESHOLD medium)"
POLICY="$(jq -r '.target.soft_policy // empty' "$FINDINGS")"; [[ -n "$POLICY" ]] || POLICY="$(config_get DRUPILOT_SOFT_DEPRECATIONS report)"

DOC="$TMP/assess.json"
jq -n -c --slurpfile f "$FINDINGS" --slurpfile w "$WORKLIST" --slurpfile cs "$TMP/cs.json" --slurpfile dp "$TMP/deps.json" \
  --slurpfile life "$(plugin_root)/config/deprecations.json" --argjson hb "$HB" --slurpfile cat "$CAT" \
  --arg mn "$MN" --arg type "$TYPE" --arg curreq "$CUR_REQ" --argjson admits "$CUR_ADMITS" --arg thr "$THRESH" \
  --arg policy "$POLICY" --arg dt "$(resolve_drupal_target)" --arg pt "$(resolve_php_target)" \
  --arg sd "$(subject_digest "$SUBJECT")" --argjson da "$(subject_digest_algo)" '
  $f[0] as $F | $w[0] as $W | $cs[0] as $C | $dp[0] as $D
  | ($F.findings | map(select(.scope == "current"))) as $cur
  # The PHPStan occurrences a (merged) finding stands for.
  | def occ: ([(.sources // [])[] | select(.tool == "phpstan")] | length) as $n | if $n > 0 then $n else 1 end;
  # A Drupal Rector rule changing the same function or method covers it.
    ([$cur[] | select(.tool == "rector" and $F.anchors == "php" and .anchor != "{file}"
                      and ((.rule // "") | test("^(DrupalRector\\\\|Rector\\\\(Renaming|Transform|Arguments|Removing)\\\\)")))
      | "\(.file)\u001f\(.anchor)"] | unique) as $rx
  # manual: hard/unknown deprecations no Drupal Rector rule covers, and the
  # signature and port-safety errors.
  | ([$cur[] | select(.tool == "phpstan" and (.class == "hard" or .class == "unknown")
                      and ("\(.file)\u001f\(.anchor)" as $k | $rx | index($k) | not)) | . + {n: occ}]
     + [$cur[] | select((.class == "signature" or .class == "safety") and .severity == "error") | . + {n: 1}]
     | sort_by([.file, .line // 0, .id])) as $man
  | ([$hb | to_entries[] | select((.value | length) > 0) | .key]) as $breaks
  | ($man | map(.n) | add // 0) as $m | ($breaks | length) as $h | ($D.totals.blockers // 0) as $b
  | ([$F.tools.rector, $F.tools.phpstan] | any(. != "ok" and . != "partial")) as $prov
  | (if $b >= 1 or $h >= 3 or $m > 40 then {v: "XL", rule: "XL: blocking_deps >= 1 or hard_breaks >= 3 or manual > 40"}
     elif $h == 2 or $m > 15 then {v: "L", rule: "L: hard_breaks == 2 or manual > 15"}
     elif $h == 1 or $m >= 5 then {v: "M", rule: "M: hard_breaks == 1 or manual >= 5"}
     else {v: "S", rule: "S: hard_breaks == 0 and manual < 5 and blocking_deps == 0"} end) as $vr
  | ($thr | ascii_downcase | {"small": "S", "s": "S", "medium": "M", "m": "M", "large": "L", "l": "L", "xl": "XL"}[.] // "M") as $tl
  | ({"S": 0, "M": 1, "L": 2, "XL": 3}) as $rank
  | ([$F.findings[] | select(.class == "metadata")]) as $meta
  | ($life[0].lifecycle // [] | map({key: .symbol, value: .}) | from_entries) as $lc
  | {schema: 1, tool: "assess", subject: ($F.subject.path // null), machine_name: $mn, type: $type,
     drupal_target: $dt, php_target: $pt, current_core_version_requirement: (if $curreq == "" then null else $curreq end),
     verdict: $vr.v, effort: $vr.v, provisional: $prov,
     rubric: {manual: $m, hard_breaks: $h, blocking_deps: $b, rule: $vr.rule},
     viability_threshold: $tl, above_threshold: ($rank[$vr.v] > $rank[$tl]),
     core_target: ($C | {strategy, recommended_core_version_requirement, composer_core_constraint, require_php,
                         version_bump, bc_break, d10_support, php_floor_detected, php_floor_target_compatible, rationale, warnings}
                  | with_entries(select(.value != null))),
     recommended_core_version_requirement: ($C.recommended_core_version_requirement // null),
     require_php: ($C.require_php // null), version_bump: ($C.version_bump // null),
     info_yml: {core_version_requirement_present: ($curreq != ""), d11_compatible: $admits,
                submodules_d11_compatible: ([$meta[] | select(.rule == "metadata:submodule-core-req" and .severity != "info")] | length == 0)},
     deprecations_hard: ([$F.findings[] | select(.class == "hard") | occ] | add // 0),
     deprecations_soft: ([$F.findings[] | select(.class == "soft") | occ] | add // 0),
     deprecations_unknown: ([$F.findings[] | select(.class == "unknown") | occ] | add // 0),
     soft_deprecations_policy: $policy,
     soft_deprecations: ([$F.findings[] | select(.class == "soft") | .symbol | strings] | unique
       | map(. as $s | ($lc[$s] // {}) | {symbol: $s, deprecated_in: (.deprecated_in // null), removed_in: (.removed_in // null),
              effort: (.effort // null), replacement_since: (.replacement_since // null)})),
     auto_fixable: {rector_official_files: ([$cur[] | select(.tool == "rector") | .file] | unique | length),
                    rector_official_rules: ([$cur[] | select(.tool == "rector")] | group_by(.message)
                      | map({key: .[0].message, value: ([.[].file] | unique | length)}) | from_entries)},
     manual_items: [$man | to_entries[] | {id: "M\(.key + 1)", finding_id: .value.id, file: .value.file, line: .value.line,
                    occurrences: .value.n, source: "\(.value.tool):\(.value.rule)", what: .value.message}],
     hard_break_categories: $hb, hard_breaks: $breaks,
     hygiene: {error: ([$meta[] | select(.severity == "error")] | length), warn: ([$meta[] | select(.severity == "warning")] | length),
               info: ([$meta[] | select(.severity == "info")] | length)},
     dependencies: {ready: ($D.totals.ready // 0), blockers: $b, unknown: ($D.totals.unknown // 0), offline: (if ($D | has("offline")) then $D.offline else null end),
                    list: ($D.dependencies // [])},
     phpstan: {count: ([$F.findings[] | select(.tool == "phpstan")] | length),
               deprecations: ([$F.findings[] | select(.class == "hard" or .class == "soft" or .class == "unknown") | occ] | add // 0)},
     phpcs: {count: ([$F.findings[] | select(.tool == "phpcs")] | length)},
     tools: $F.tools,
     worklist: {items: $W.counts.items, open: $W.counts.open, by_lane: $W.counts.by_lane},
     findings_hash: ($F.meta.findings_hash // null), worklist_hash: ($W.meta.worklist_hash // null),
     subject_digest: $sd, digest_algo: $da}' | canon_json > "$DOC"
jq -e '.schema == 1' "$DOC" > /dev/null 2>&1 || die "Could not compute assess.json." 1
PROV="$(jq -r '.provisional' "$DOC")"
[[ "$PROV" == "true" ]] && RC=3
jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg v "$(plugin_version 2> /dev/null || true)" \
  '. + {meta: {generated_at: $at, drupilot_version: (if $v == "" then null else $v end)}}' "$DOC" | canon_json > "$DOC.meta"
SD="$(project_state_dir "$SUBJECT")"
cp "$DOC.meta" "$SD/assess.json.tmp.$$" && mv -f "$SD/assess.json.tmp.$$" "$SD/assess.json" || die "Could not write assess.json." 1

# viability-report.md, from the JSON only.
ART="$(project_artifacts_dir "$SUBJECT")"
j() { jq -r "$1" "$DOC"; }
jc() { jq -r "($1) | tostring | gsub(\"\\\\|\"; \"\\\\|\")" "$DOC"; }  # a table cell: | escaped
rawsum() {  # rawsum TOOL -> a short summary of the stage's raw report
  local f; f="$(find "$(project_state_path "$SUBJECT")/raw" -name "[0-9][0-9]-assess-$1.json" 2> /dev/null | sed -n '1p')"
  [[ -n "$f" ]] || { printf '_not run_'; return 0; }
  jq -r 'del(.meta) | tostring | .[0:1500]' "$f" 2> /dev/null || printf '_unreadable_'
  return 0
}
hbs() { if [[ "$(j ".hard_break_categories.$1 | length")" -gt 0 ]]; then printf 'present'; else printf 'not detected'; fi; }
hbn() { jc ".hard_break_categories.$1 | if length == 0 then \"-\" else map(\"\`\" + . + \"\`\") | join(\", \") end"; }
render_template "$(plugin_root)/templates/viability-report.md.tmpl" "$ART/viability-report.md" \
  "SUBJECT_NAME=$MN" "SUBJECT_MACHINE_NAME=$MN" "SUBJECT_TYPE=$TYPE" "SUBJECT_PATH=$(jc '.subject // ""')" \
  "CURRENT_CORE_REQUIREMENT=$(jc '.current_core_version_requirement // "(none)"')" "DATE=$(date -u +%Y-%m-%d)" \
  "DRUPAL_TARGET=$(j .drupal_target)" "PHP_TARGET=$(j .php_target)" "PHP_TARGET_NOTE=" \
  "CORE_TARGET_STRATEGY=$(jc '.core_target.strategy // "-"')" "RECOMMENDED_CORE_REQUIREMENT=$(jc '.recommended_core_version_requirement // "-"')" \
  "COMPOSER_CORE_CONSTRAINT=$(jc '.core_target.composer_core_constraint // "-"')" "REQUIRE_PHP=$(jc '.require_php // "-"')" \
  "VERSION_BUMP=$(jc '.version_bump // "-"')" "CORE_TARGET_RATIONALE=$(j '(.core_target.rationale // []) | if type == "array" then map("- " + .) | join("\n") else tostring end')" \
  "CORE_TARGET_WARNING=$(j '(.core_target.warnings // []) | map("> " + .) | join("\n>\n")')" \
  "VERDICT=$(j 'if .provisional then "\(.verdict) (provisional)" else .verdict end')" "VERDICT_SUMMARY=$(j '(if .provisional then "**Provisional:** " + ([.tools | to_entries[] | select((.key == "rector" or .key == "phpstan") and .value != "ok" and .value != "partial") | "\(.key) \(.value)"] | join(", ")) + ", so these counts are incomplete. Fix the tool and assess again.\n\n" else "" end) + "manual \(.rubric.manual), hard breaks \(.rubric.hard_breaks), blocking dependencies \(.rubric.blocking_deps): first matching rule `\(.rubric.rule)`."')" \
  "VIABILITY_THRESHOLD=$(j .viability_threshold)" "THRESHOLD_NOTE=$(j 'if .above_threshold then "The verdict is above the threshold." else "The verdict is within the threshold." end')" \
  "RECTOR_AUTOFIX_COUNT=$(j .auto_fixable.rector_official_files)" "DIGESTS_AUTOFIX_COUNT=-" "MANUAL_COUNT=$(j .rubric.manual)" \
  "PHPSTAN_COUNT=$(j 'if .tools.phpstan == "ok" or .tools.phpstan == "partial" then .phpstan.deprecations else "not available (PHPStan \(.tools.phpstan))" end')" "PHPSTAN_LEVEL=$(config_get DRUPILOT_PHPSTAN_LEVEL 2)" \
  "DEPRECATIONS_HARD_COUNT=$(j .deprecations_hard)" "DEPRECATIONS_SOFT_COUNT=$(j .deprecations_soft)" "DEPRECATIONS_UNKNOWN_COUNT=$(j .deprecations_unknown)" \
  "PHPCS_COUNT=$(j .phpcs.count)" "SOFT_DEPRECATIONS_POLICY=$(j .soft_deprecations_policy)" \
  "SOFT_DEPRECATION_ROWS=$(j '.soft_deprecations | if length == 0 then "| - | - | - | - | - | - |" else map("| `\(.symbol | gsub("\\|"; "\\|"))` | \(.deprecated_in // "?") | \(.removed_in // "?") | \(.effort // "?") | \(.replacement_since // "?") | per policy |") | join("\n") end')" \
  "TWIG3_STATUS=$(hbs twig3)" "TWIG3_NOTES=$(hbn twig3)" "CKEDITOR5_STATUS=$(hbs ckeditor5)" "CKEDITOR5_NOTES=$(hbn ckeditor5)" \
  "JQUERY_STATUS=$(hbs jquery_ui)" "JQUERY_NOTES=$(hbn jquery_ui)" "SYMFONY7_STATUS=$(hbs symfony7)" "SYMFONY7_NOTES=$(hbn symfony7)" \
  "INFO_YML_STATUS=$(j '.info_yml | "- `core_version_requirement` present: \(.core_version_requirement_present)\n- admits the target major: \(.d11_compatible)\n- every submodule admits it: \(.submodules_d11_compatible)"')" \
  "TARGET_CORE_REQUIREMENT=$(j '.recommended_core_version_requirement // "-"')" \
  "HYGIENE_SUMMARY=$(j '"\(.hygiene.error) error(s), \(.hygiene.warn) warning(s), \(.hygiene.info) info."')" \
  "HYGIENE_ROWS=$(jq -r '[.findings[] | select(.class == "metadata")] | if length == 0 then "| - | - | - | - | - |" else map("| \(.severity) | \(.rule | sub("^metadata:"; "")) | `\(.file | gsub("\\|"; "\\|")):\(.line // "")` | \(.message | gsub("\\|"; "\\|")) | - |") | join("\n") end' "$FINDINGS")" \
  "CONTRIB_DEPENDENCY_ROWS=$(j '(.dependencies.list | if length == 0 then "| - | - | - |" else map("| `\(.project)` | \(.d11 // "unknown") | \(.url // "") |") | join("\n") end) + (if .dependencies.offline == true then "\n\n> Checked offline: drupal.org was not asked, so every contrib dependency is `unknown` and none is counted as blocking." else "" end)')" \
  "NEXT_STEP=/drupilot-port" \
  "PHASE1_SUMMARY=$(j '"the info.yml requirement, the \(.auto_fixable.rector_official_files) Rector file(s), the \(.rubric.manual) manual item(s)" + (if .rubric.hard_breaks > 0 then " and the hard breaks (" + (.hard_breaks | join(", ")) + ")" else "" end) + ", then the tests."')" \
  "PHASE2_SUMMARY=the Drupal $TMAJ way rewrite (attributes, dependency injection, strict types), only when you ask for it." \
  "RECTOR_RAW_OUTPUT=$(rawsum rector)" "DIGESTS_RAW_OUTPUT=_not run in the assessment_" "PHPSTAN_RAW_OUTPUT=$(rawsum phpstan)" \
  "PHPCS_RAW_OUTPUT=$(rawsum phpcs)" "UPGRADE_STATUS_RAW_OUTPUT=_not run_" \
  || die "Could not render viability-report.md." 1

if [[ "$PROV" == "true" ]]; then
  log_warn "assess: Rector or PHPStan gave no verdict (assess.json tools): the verdict is provisional and the assessed stage is not recorded."
elif [[ "$RECORD" == "1" ]]; then
  bash "$S/env/state.sh" record --subject "$SUBJECT" --stage assessed --effort "$(j .verdict)" < /dev/null > /dev/null 2>&1 || log_warn "Could not record the assessed stage."
fi
log_ok "assess: $(j .verdict) ($(j .rubric.rule)); assess.json and $ART/viability-report.md written."
[[ "$AS_JSON" == "1" ]] && cat "$DOC.meta"
exit "$RC"
