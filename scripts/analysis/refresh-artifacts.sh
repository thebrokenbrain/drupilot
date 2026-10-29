#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/refresh-artifacts.sh
# Bring a port's artifacts up to the module as it is now, after a stage that
# changes the module without regenerating them: the test stage adapts the
# tests after the port wrote its local patch, its core matrix and its report
# (lab L-PC: all three were left from before those changes, and the report
# still said nothing of the run). The steps, in this order:
#   core-matrix  verify-core-matrix.sh again, at the PHPStan level the
#                previous run used, when core-matrix.json records other
#                sources than the module's now (its subject_digest), the
#                declared range admits the previous major and
#                DRUPILOT_VERIFY_CORES is not off. With no core-matrix.json
#                there is nothing to refresh. A leg that fails (exit 3) is a
#                verdict: the step ran, and it fails only when the verdict
#                is worse than the one it replaces.
#   patch        make-patch.sh --local (a git checkout only): the same tree
#                gives the same patch, so it always runs.
#   extraction   with a git repository, the pipeline's php and validate
#                stages (pipeline.sh, with the manifest's phase): it runs
#                only the stages whose inputs moved, and its fixpoint gate
#                judges the changed files too (validate stays failed until
#                the gate converges); without one, fixpoint.sh (the
#                extraction again and the same gate) unless the worklist is
#                of the module as it is (worklist_fresh) and fixpoint.json
#                converged on it (with DRUPILOT_FIXPOINT=off, the extraction
#                alone when the worklist is stale)
#   manifest     manifest.sh, which keeps the earlier rationale
#   report       port-report.sh with the module's own manifest, which also
#                reads the last test run; it records no stage (the test stage
#                already did)
# A module drupilot has not ported (no port-manifest.json in its state dir)
# has nothing to refresh. Every step reports its status, and a failed step
# never stops the next one.
#
# Usage:
#   refresh-artifacts.sh --subject DIR [--output DIR] [--skip LIST]
#                        [--dry-run] [--json] [-h|--help]
#     --subject DIR   the module/theme
#     --output DIR    where port-report.sh writes the report (default: the
#                     Drupal root's .drupilot/; a layer run passes each
#                     module's own directory, as its port stage did)
#     --skip LIST     comma-separated steps to leave alone: core-matrix,
#                     patch, report (report also leaves the extraction and
#                     the manifest alone)
#     --dry-run       say what would run and why; run nothing
#     --json          {subject, digest, manifest, steps: [{step, status,
#                     reason, rc}]} on STDOUT; status: ran | up-to-date |
#                     skipped | failed | would-run
#
# Exit codes: 0 every step ran, was up to date or was skipped (nothing to
# refresh included) · 1 usage error · 3 a step failed (its rc and reason in
# steps).
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""; SKIP=""; OUTPUT=""; DRY=0; AS_JSON=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --skip) SKIP="${2:-}"; shift 2 || die "--skip needs a value" 1;;
    --skip=*) SKIP="${1#*=}"; shift;;
    --output) OUTPUT="${2:-}"; shift 2 || die "--output needs a value" 1;;
    --output=*) OUTPUT="${1#*=}"; shift;;
    --dry-run) DRY=1; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ -n "$SUBJECT" && -d "$SUBJECT" ]] || die "Pass --subject DIR (an existing directory)." 1
SKIP="$(printf '%s' "$SKIP" | tr -d ' \t')"
for _s in $(printf '%s' "$SKIP" | tr ',' ' '); do
  case "$_s" in core-matrix|patch|report) ;; *) die "--skip: unknown step '$_s' (core-matrix, patch, report)." 1;; esac
done
have_cmd jq || die "jq is required (run /drupilot-doctor)." 1
SUBJECT="$(cd "$SUBJECT" && pwd)"
SD="$(project_state_path "$SUBJECT")"
MAN="$SD/port-manifest.json"
S="$(plugin_root)/scripts"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-refresh.XXXXXX")"
trap 'rm -rf "$TMP" 2> /dev/null || true' EXIT
: > "$TMP/steps.tsv"
DIGEST="$(subject_digest "$SUBJECT" 2> /dev/null || true)"
RC_ALL=0

skipped() { case ",$SKIP," in *",$1,"*) return 0;; esac; return 1; }
# step NAME STATUS RC REASON -> records one step's outcome.
step() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$TMP/steps.tsv"
  case "$2" in failed) RC_ALL=3; log_err "refresh: $1: $4";; ran) log_ok "refresh: $1: $4";; *) log_info "refresh: $1: $2 ($4)";; esac
  return 0
}
# run NAME REASON CMD... -> runs CMD (STDOUT to STDERR) unless --dry-run.
run() {
  local name="$1" why="$2" rc=0; shift 2
  if [[ "$DRY" == "1" ]]; then step "$name" would-run 0 "$why"; return 0; fi
  log_step "refresh: $name"
  "$@" < /dev/null >&2 || rc=$?
  if [[ "$rc" == "0" ]]; then step "$name" ran 0 "$why"; else step "$name" failed "$rc" "$why; it exited $rc"; fi
  return 0
}

if ! jq -e 'type == "object" and (.phase | type) == "string"' "$MAN" > /dev/null 2>&1; then
  step all skipped 0 "no port manifest for this module (port it first): nothing to refresh"
else
  PHASE="$(jq -r '.phase' "$MAN")"
  case "$PHASE" in port|refactor) ;; *) PHASE="port";; esac
  REQ="$(subject_core_requirement "$SUBJECT" 2> /dev/null || true)"
  TMAJ="$(resolve_target_major 2> /dev/null || true)"
  GIT=0; git -C "$SUBJECT" rev-parse --git-dir > /dev/null 2>&1 && GIT=1

  # core-matrix: only a stale one, for a range that admits the previous major.
  CM="$SD/core-matrix.json"
  if skipped core-matrix; then step core-matrix skipped 0 "--skip"
  elif [[ ! -f "$CM" ]]; then step core-matrix skipped 0 "no core-matrix.json to refresh"
  elif [[ "$(lc "$(config_get DRUPILOT_VERIFY_CORES auto)")" == "off" ]]; then step core-matrix skipped 0 "DRUPILOT_VERIFY_CORES is off"
  elif ! [[ "$TMAJ" =~ ^[0-9]+$ ]]; then step core-matrix skipped 0 "the target major is unknown"
  elif ! constraint_admits_major "$REQ" "$((TMAJ - 1))"; then step core-matrix skipped 0 "the range '$REQ' admits no Drupal $((TMAJ - 1))"
  elif [[ "$(jq -r '.subject_digest // ""' "$CM" 2> /dev/null)" == "$DIGEST" ]]; then step core-matrix up-to-date 0 "core-matrix.json is of the module as it is"
  elif [[ "$DRY" == "1" ]]; then step core-matrix would-run 0 "core-matrix.json is of other sources than the module now"
  else
    # At the level the previous run used (a refactor verifies at its own).
    _lvl="$(jq -r '.level // empty' "$CM" 2> /dev/null || true)"
    _old="$(jq -r '.d10_support // empty' "$CM" 2> /dev/null || true)"
    log_step "refresh: core-matrix"
    _rc=0; bash "$S/analysis/verify-core-matrix.sh" --subject "$SUBJECT" ${_lvl:+--level "$_lvl"} --json < /dev/null > /dev/null || _rc=$?
    _new="$(jq -r '.d10_support // empty' "$CM" 2> /dev/null || true)"
    if [[ "$_rc" == "0" ]]; then
      step core-matrix ran 0 "core-matrix.json was of other sources; Drupal $((TMAJ - 1)) support: ${_new:-?}"
    elif [[ "$_rc" == "3" && "$_old" == "failed" ]]; then
      step core-matrix ran 3 "core-matrix.json was of other sources; a leg still fails (Drupal $((TMAJ - 1)) support: failed, as before)"
    elif [[ "$_rc" == "3" ]]; then
      step core-matrix failed 3 "a leg fails now (Drupal $((TMAJ - 1)) support: failed, was ${_old:-?}): see core-matrix.json"
    else
      step core-matrix failed "$_rc" "verify-core-matrix.sh could not run (exit $_rc)"
    fi
  fi

  # patch: git only; the same tree gives the same patch.
  if skipped patch; then step patch skipped 0 "--skip"
  elif [[ "$GIT" != "1" ]]; then step patch skipped 0 "not a git checkout (make-patch.sh --local needs one)"
  else run patch "the local patch of the module as it is" bash "$S/contrib/make-patch.sh" --local --subject "$SUBJECT"
  fi

  # report: the extraction (and its gate) first.
  if skipped report; then step report skipped 0 "--skip"
  else
    if [[ "$GIT" == "1" ]]; then
      # The pipeline decides what is up to date (validate only while the
      # fixpoint gate converges); its report stage is left out, so it
      # records no stage.
      run extraction "the pipeline's php and validate stages, run when their inputs moved" \
        bash "$S/ai/pipeline.sh" --subject "$SUBJECT" --stages php,validate --phase "$PHASE"
    elif [[ "$(lc "$(config_get DRUPILOT_FIXPOINT enforce)")" == "off" ]]; then
      # No gate: the extraction alone, when the worklist is of other sources.
      if worklist_fresh "$SUBJECT"; then
        step extraction up-to-date 0 "the findings are of the module as it is"
      else
        run extraction "the findings are of other sources than the module now" bash -c '
          set -e; s="$1"; d="$2"
          bash "$d/ai/extract.sh" --subject "$s" --stage validate
          bash "$d/ai/normalize-findings.sh" --subject "$s" --stage validate
          bash "$d/ai/classify.sh" --subject "$s"' _ "$SUBJECT" "$S"
      fi
    elif worklist_fresh "$SUBJECT" && jq -e --slurpfile w "$(worklist_file "$SUBJECT")" \
           '.converged == true and .worklist_hash == ($w[0].meta.worklist_hash // "")' "$SD/fixpoint.json" > /dev/null 2>&1; then
      step extraction up-to-date 0 "the findings are of the module as it is, and the fixpoint gate converged on them"
    else
      run extraction "the findings are of other sources, or the fixpoint gate has not converged on them" \
        bash "$S/analysis/fixpoint.sh" --subject "$SUBJECT" --stage validate
    fi
    if [[ "$DRY" == "1" ]]; then
      step report would-run 0 "the manifest and port-report.md of the module as it is"
    elif awk -F'\t' '$1 == "extraction" && $2 == "failed" { f = 1 } END { exit !f }' "$TMP/steps.tsv"; then
      step report failed 3 "not rendered: the extraction failed"
    else
      run manifest "the manifest of the module as it is" bash "$S/ai/manifest.sh" --subject "$SUBJECT" --phase "$PHASE"
      run report "port-report.md with the last test run" bash "$S/analysis/port-report.sh" --subject "$SUBJECT" ${OUTPUT:+--output "$OUTPUT"}
    fi
  fi
fi

if [[ "$AS_JSON" == "1" ]]; then
  jq -R -s -c --arg s "$SUBJECT" --arg d "$DIGEST" --arg m "$MAN" '
    {subject: $s, digest: (if $d == "" then null else $d end), manifest: $m,
     steps: (split("\n") | map(select(length > 0) | split("\t")
             | {step: .[0], status: .[1], rc: (.[2] | tonumber? // null), reason: .[3]}))}' "$TMP/steps.tsv"
fi
exit "$RC_ALL"
