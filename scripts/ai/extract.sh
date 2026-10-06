#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/ai/extract.sh
# Run a stage's deterministic extractors on a module/theme and keep their
# reports as canonical raw files (T-M4-05, AR-07, AR-10, 05-R3, ADR 0022):
#
#   <state>/raw/<NN>-<stage>-<tool>.json
#
# NN is the stage's place in config/pipeline.json. The tools are run-rector.sh
# (a dry-run), run-phpstan.sh, run-phpcs.sh, check-port-safety.sh,
# scan-signature-changes.sh and lint-extension-metadata.sh, each with --json;
# every report goes through canon_json with the Drupal root (root-relative
# paths, sorted keys; its own timestamps moved under meta: DET-2). Then the
# anchor of every (file, line) the reports name in a PHP file is computed
# once, in the bed, by the staged
# scripts/php/anchor.php (stage_runtime) and kept as <NN>-<stage>-anchors.json
# (without a PHP runner: {"unavailable": true}), so scripts/ai/
# normalize-findings.sh needs no PHP. An index, <NN>-<stage>-index.json, names
# the subject, the target major and each tool's file and exit code. A stage's
# previous raw files are replaced; other stages' are kept.
#
# Usage:
#   extract.sh --subject DIR [--stage S] [--json] [-h|--help]
#     --subject DIR  the module/theme (inside its Drupal root or test-bed)
#     --stage S      the stage id of config/pipeline.json (default assess)
#     --json         print the index on STDOUT
#
# Gate: the tools' own (the `analyze` profile). Exit codes: 0 every report
# written · 1 usage error · 2 no Drupal root or jq missing · 3 Rector or
# PHPStan gave no verdict (a crash or a DET-1 refusal: see their raw file); the
# other reports are still written.
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""; STAGE="assess"; AS_JSON=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --stage) STAGE="${2:-}"; shift 2 || die "--stage needs a value" 1;;
    --stage=*) STAGE="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ -n "$SUBJECT" ]] || die "Pass --subject DIR (see --help)." 1
[[ -d "$SUBJECT" ]] || die "Subject '$SUBJECT' is not a directory." 1
have_cmd jq || die "jq is required (run /drupilot-doctor)." 2
SUBJECT="$(cd "$SUBJECT" && pwd)"
NN="$(jq -r --arg s "$STAGE" '[.stages[].id] | index($s) // empty' "$(plugin_root)/config/pipeline.json" 2> /dev/null || true)"
[[ -n "$NN" ]] || die "Unknown stage '$STAGE' (see config/pipeline.json)." 1
NN="$(printf '%02d' "$((NN + 1))")"
ROOT="$(subject_project_root "$SUBJECT")"
[[ -n "$ROOT" && -d "$ROOT" ]] || die "No Drupal root for $SUBJECT (run /drupilot-setup first)." 2
ROOT="$(cd "$ROOT" && pwd)"
case "$SUBJECT" in "$ROOT"/*) SUBJECT_REL="${SUBJECT#"$ROOT"/}";; *) die "Subject '$SUBJECT' is outside its Drupal root '$ROOT'." 2;; esac
MACHINE="$(subject_machine_name "$SUBJECT" 2> /dev/null || basename "$SUBJECT")"
RAW="$(project_state_dir "$SUBJECT")/raw"
mkdir -p "$RAW" || die "Cannot create $RAW." 2
for f in "$RAW/$NN-$STAGE"-*.json; do [[ -f "$f" ]] && rm -f "$f"; done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-extract.XXXXXX")"
trap 'rm -rf "$TMP" 2> /dev/null || true' EXIT
S="$(plugin_root)/scripts"
TOOLS_TSV="$TMP/tools.tsv"; : > "$TOOLS_TSV"
# extract TOOL CMD... -> runs the tool (its STDERR relayed), keeps its report
# canonical as <NN>-<stage>-<TOOL>.json and records its exit code.
extract() {
  local tool="$1" rc=0 out="$RAW/$NN-$STAGE-$1.json"; shift
  log_step "extract: $tool"
  ( cd "$ROOT" && "$@" ) > "$TMP/$tool.out" < /dev/null || rc=$?
  if jq -e -s 'length == 1 and (.[0] | type) == "object"' "$TMP/$tool.out" > /dev/null 2>&1; then
    # A report's own timestamps go under meta (DET-2: two runs of the same
    # tree give the same bytes outside it).
    jq '(to_entries | map(select(.key | IN("generated_at", "recorded_at", "at", "timestamp"))) | from_entries) as $t
        | (to_entries | map(select(.key | IN("generated_at", "recorded_at", "at", "timestamp") | not)) | from_entries)
        + (if ($t | length) > 0 then {meta: ((.meta // {}) + $t)} else {} end)' "$TMP/$tool.out" \
      | canon_json "$ROOT" > "$out.tmp" && mv -f "$out.tmp" "$out"
  else
    jq -n --argjson rc "$rc" '{error: "the tool printed no JSON report", exit_code: $rc}' | canon_json > "$out"
  fi
  printf '%s\t%s\t%s\n' "$tool" "$(basename "$out")" "$rc" >> "$TOOLS_TSV"
  return 0
}
extract rector bash "$S/analysis/run-rector.sh" --subject "$SUBJECT_REL" --json
extract phpstan bash "$S/analysis/run-phpstan.sh" --subject "$SUBJECT_REL" --json
extract phpcs bash "$S/analysis/run-phpcs.sh" --subject "$SUBJECT_REL" --json
extract port-safety bash "$S/analysis/check-port-safety.sh" --subject "$SUBJECT_REL" --no-diff --json
extract signatures bash "$S/analysis/scan-signature-changes.sh" --subject "$SUBJECT_REL" --json
extract metadata bash "$S/analysis/lint-extension-metadata.sh" --subject "$SUBJECT_REL" --json

# The anchors of every (file, line) the reports name in a PHP file.
log_step "extract: anchors"
jq -n -c --arg sp "$SUBJECT_REL" \
  --slurpfile rector "$RAW/$NN-$STAGE-rector.json" --slurpfile stan "$RAW/$NN-$STAGE-phpstan.json" \
  --slurpfile cs "$RAW/$NN-$STAGE-phpcs.json" --slurpfile safety "$RAW/$NN-$STAGE-port-safety.json" \
  --slurpfile sig "$RAW/$NN-$STAGE-signatures.json" --slurpfile meta "$RAW/$NN-$STAGE-metadata.json" '
  def rootrel: if startswith($sp + "/") then . else $sp + "/" + . end;
  def hunk_lines: split("\n") as $l
    | reduce range(0; $l | length) as $i ({out: [], start: null, ctx: 0, found: true};
        ($l[$i]) as $s
        | if ($s | startswith("@@ ")) then .start = ($s | capture("^@@ -(?<a>[0-9]+)").a | tonumber) | .ctx = 0 | .found = false
          elif .found == false and .start != null and ($s | startswith(" ")) then .ctx += 1
          elif .found == false and .start != null and (($s | startswith("-")) or ($s | startswith("+"))) then .out += [.start + .ctx] | .found = true
          else . end)
    | .out;
  [ (($rector[0].file_diffs // [])[] | .file as $f | ((.diff // "") | hunk_lines)[] | {file: ($f | rootrel), line: .}),
    (($stan[0].files // {}) | to_entries[] | .key as $f | (.value.messages // [])[] | {file: ($f | rootrel), line}),
    (($cs[0].files // {}) | to_entries[] | .key as $f | (.value.messages // [])[] | {file: ($f | rootrel), line}),
    (($safety[0].findings // [])[], ($sig[0].findings // [])[], ($meta[0].findings // [])[] | {file: (.file | rootrel), line}) ]
  | map(select((.line | type) == "number" and (.file | test("\\.(php|module|inc|install|theme|profile|engine)$"))))
  | unique' > "$TMP/anchor-req.json"
ANCH="$RAW/$NN-$STAGE-anchors.json"
if [[ "$(jq 'length' "$TMP/anchor-req.json")" == "0" ]]; then
  printf '[]\n' > "$ANCH"
else
  RUNNER="$(drupal_runner "$ROOT")"
  RT=""
  if [[ -n "$RUNNER" ]] || have_cmd php; then RT="$(stage_runtime "$ROOT" || true)"; fi
  if [[ -n "$RT" ]] && (cd "$ROOT" && $RUNNER php "$RT/anchor.php" < "$TMP/anchor-req.json") > "$TMP/anchors.out" 2> "$TMP/anchors.err" \
     && jq -e 'type == "array"' "$TMP/anchors.out" > /dev/null 2>&1; then
    jq -c '[.[] | {file, line, anchor}]' "$TMP/anchors.out" | canon_json > "$ANCH"
  else
    log_warn "No PHP to compute anchors (the bed is not running and there is no host PHP): every anchor is {file}."
    printf '{"unavailable": true}\n' | canon_json > "$ANCH"
  fi
fi

# The index.
TARGET="$(plan_get .target.major "$ROOT" 2> /dev/null || true)"
[[ "$TARGET" =~ ^[0-9]+$ ]] || TARGET="$(resolve_target_major)"
jq -R -s --arg st "$STAGE" --arg mn "$MACHINE" --arg sp "$SUBJECT_REL" --argjson t "$TARGET" '
  {stage: $st, subject: {machine_name: $mn, path: $sp}, target_major: $t,
   tools: (split("\n") | map(select(length > 0) | split("\t") | {tool: .[0], file: .[1], exit_code: (.[2] | tonumber)}))}' \
  "$TOOLS_TSV" | canon_json > "$RAW/$NN-$STAGE-index.json"
log_ok "extract: $(grep -c . "$TOOLS_TSV") report(s) and the anchors in $RAW ($NN-$STAGE-*)"
[[ "$AS_JSON" == "1" ]] && cat "$RAW/$NN-$STAGE-index.json"
# Rector or PHPStan gave no verdict (a crash, a DET-1 refusal): exit 3.
if awk -F'\t' '($1 == "rector" || $1 == "phpstan") && $3 == 3 { f = 1 } END { exit !f }' "$TOOLS_TSV"; then exit 3; fi
exit 0
