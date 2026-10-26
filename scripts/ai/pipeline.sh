#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/ai/pipeline.sh
# The stage contract (T-M4-12, AR-07, ADR 0028) for the deterministic stages
# of the standard track: upgrade -> php -> validate -> report, in the order of
# config/pipeline.json. For each stage:
#   1. its digest: the sha256 of the frozen plan's hash, the lock's hash and
#      the subject's digest at the stage start;
#   2. a stage whose last record is done (or skipped) with an output digest
#      equal to that digest is up to date: it is not run again (a tree rolled
#      back to before the stage runs it again), unless a stage before it ran
#      in this run;
#   3. a checkpoint of the subject's tree, refs/drupilot/stages/<run>/<stage>
#      (git_stage_checkpoint: a throwaway GIT_INDEX_FILE, the real index and
#      HEAD untouched);
#   4. the stage itself; its raw tool reports are <NN>-<stage>-<tool>.json in
#      the state dir's raw/ (NN: the stage's place in config/pipeline.json),
#      and a raw file of the stage under another NN fails the stage;
#   5. done: the record keeps the input and output digests; failed: the tree
#      goes back to the stage's own checkpoint (git_stage_restore) and the
#      pipeline stops.
# The records are <state>/stages.json; each run is recorded in
# runs/<run_id>/run-manifest.json (run_manifest_record). Progress reporting
# arrives in drupilot 1.2 (M7).
#
# The stages:
#   upgrade   the official Rector pass (run-rector.sh --apply), the
#             extraction at stage upgrade, and the codemods (apply-recipes.sh
#             --reextract: S6, S7); skipped, reason same-major, when the
#             plan's hops are [] (the digests layer, which the developer
#             reviews, stays in /drupilot-port)
#   php       the extraction at stage php (with the PHP-window tools:
#             php-target.sh's removed and deprecated constructs, the php -l
#             legs of php-lint-window.sh), normalize-findings.sh and
#             classify.sh: the PHP-window findings become human worklist
#             items (removed-in-target-php blocks); a finding in no item
#             fails the stage. It runs on every plan, a same-major one too.
#             Rector's or PHPStan's missing verdict (extract.sh exit 3) is
#             warned about (validate's fixpoint judges it); a php -l that
#             did not run on every leg is recorded as the reason
#             php-lint-skipped|partial|failed, and such a record (like a
#             skipped "placeholder" one of 1.0.0-alpha.1) is never up to date
#   validate  the fixpoint gate (fixpoint.sh: the extraction again, the
#             codemods in dry-run); its exit 3 (DRUPILOT_FIXPOINT=enforce)
#             fails the stage
#   report    the generated manifest (manifest.sh, with --rationale when
#             given) and port-report.sh
#
# Usage:
#   pipeline.sh --subject DIR [--stages S1,S2,...] [--phase port|refactor]
#               [--rationale FILE] [--run ID] [--force] [--json] [-h|--help]
#     --subject DIR      the module/theme, inside its Drupal root and a git
#                        repository (the checkpoints need one)
#     --stages LIST      the stages to run, in their catalog order (default:
#                        upgrade,php,validate,report)
#     --phase P          port (default) or refactor: the manifest's phase
#     --rationale FILE   passed to manifest.sh (report)
#     --run ID           the run id (default: the UTC time and a hash)
#     --force            run every stage, even an up-to-date one
#     --json             {run_id, stages: [{id, status, reason, input_digest,
#                        output_digest, rc}]} on STDOUT
#
# Exit codes: 0 every stage done, skipped or up to date · 1 usage error, an
# unknown stage, no git repository, or a checkpoint that cannot be made ·
# 3 a stage failed (the tree is back at its checkpoint; see stages.json).
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""; STAGES="upgrade,php,validate,report"; PHASE="port"; RATIONALE=""; RUN=""; FORCE=0; AS_JSON=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --stages) STAGES="${2:-}"; shift 2 || die "--stages needs a value" 1;;
    --phase) PHASE="${2:-}"; shift 2 || die "--phase needs a value" 1;;
    --rationale) RATIONALE="${2:-}"; shift 2 || die "--rationale needs a value" 1;;
    --run) RUN="${2:-}"; shift 2 || die "--run needs a value" 1;;
    --force) FORCE=1; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ -n "$SUBJECT" && -d "$SUBJECT" ]] || die "Pass --subject DIR (an existing directory)." 1
case "$PHASE" in port|refactor) ;; *) die "--phase is port or refactor." 1;; esac
have_cmd jq || die "jq is required (run /drupilot-doctor)." 1
SUBJECT="$(cd "$SUBJECT" && pwd)"
git -C "$SUBJECT" rev-parse --git-dir > /dev/null 2>&1 || die "$SUBJECT is not in a git repository: the stage checkpoints need one (git init, and commit the module as it is)." 1
[[ -z "$RUN" || "$RUN" =~ ^[A-Za-z0-9._-]+$ ]] || die "--run takes letters, digits, '.', '_' and '-' only." 1
ROOT="$(subject_project_root "$SUBJECT" 2> /dev/null || true)"
case "$SUBJECT/" in "$ROOT"/*) ;; *) ROOT="";; esac
if [[ -n "$ROOT" && -z "${DRUPILOT_PROJECT_DIR:-}" ]]; then export DRUPILOT_PROJECT_DIR="$ROOT"; fi
S="$(plugin_root)/scripts"
CAT="$(plugin_root)/config/pipeline.json"
SD="$(project_state_dir "$SUBJECT")"
REC="$SD/stages.json"

# The stages asked for, known to this script and to the catalog, in catalog order.
KNOWN="upgrade php validate report"
ORDER=""
for s in $(printf '%s' "$STAGES" | tr ',' ' '); do
  case " $KNOWN " in *" $s "*) ;; *) die "Unknown stage '$s' (pipeline.sh runs: $KNOWN)." 1;; esac
  jq -e --arg s "$s" '[.stages[].id] | index($s) != null' "$CAT" > /dev/null 2>&1 || die "Stage '$s' is not in config/pipeline.json." 1
done
for s in $(jq -r '.stages[].id' "$CAT"); do
  case ",$STAGES," in *",$s,"*) ORDER="$ORDER $s";; esac
done
nn_of() { printf '%02d' "$(( $(jq -r --arg s "$1" '[.stages[].id] | index($s)' "$CAT") + 1 ))"; }

# digest_now -> the stage digest of the subject as it is now.
digest_now() {
  local ph lh sd
  ph="$(plan_get_own "$SUBJECT" .subject.machine_name)"
  if [[ -n "$ph" ]]; then ph="$(lock_get .upgrade_plan_hash "")"; fi
  lh="$(canon_json_hashable < "$(drupilot_lock_file 2> /dev/null || printf /dev/null)" 2> /dev/null | json_hash || true)"
  sd="$(subject_digest "$SUBJECT")"
  printf 'plan:%s\nlock:%s\nsubject:%s\n' "$ph" "$lh" "$sd" | json_hash
  return 0
}
record() {  # record STAGE STATUS REASON IN OUT RC
  local base='{"schema": 1, "stages": {}}'
  if [[ -f "$REC" ]] && jq -e 'type == "object" and (.stages | type) == "object"' "$REC" > /dev/null 2>&1; then base="$(cat "$REC")"; fi
  jq -n --argjson b "$base" --arg s "$1" --arg st "$2" --arg r "$3" --arg i "$4" --arg o "$5" --argjson rc "$6" \
    --arg run "$RUN" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '$b | .schema = 1 | .stages[$s] = {status: $st, reason: (if $r == "" then null else $r end), input_digest: $i,
       output_digest: (if $o == "" then null else $o end), rc: $rc, run_id: $run, at: $at}' \
    | canon_json > "$REC.tmp.$$" && mv -f "$REC.tmp.$$" "$REC"
}
raw_files() { find "$SD/raw" -name "[0-9][0-9]-$1-*.json" 2> /dev/null | LC_ALL=C sort || true; }
# raw_misnumbered STAGE NN -> the stage's raw reports not numbered NN, one line
# (no `case` inside a command substitution: bash 3.2 misparses it).
raw_misnumbered() {
  local f b out=""
  for f in $(raw_files "$1"); do
    b="${f##*/}"
    case "$b" in "$2-$1-"*) ;; *) out="$out$b ";; esac
  done
  printf '%s' "$out"
  return 0
}

# The stages themselves. Each returns the stage's exit code; SKIP_REASON set
# means skipped.
stage_upgrade() {
  local hops
  hops="$(plan_get_own "$SUBJECT" '.hops | length')"
  if [[ -z "$hops" ]]; then hops="$(plan_for_subject "$ROOT" "$SUBJECT" 2> /dev/null | jq -r '.hops | length' 2> /dev/null || true)"; fi
  if [[ "$hops" == "0" ]]; then SKIP_REASON="same-major"; return 0; fi
  bash "$S/analysis/run-rector.sh" --subject "$SUBJECT" --apply --json < /dev/null > "$SD/upgrade-rector.json" || return $?
  bash "$S/ai/extract.sh" --subject "$SUBJECT" --stage upgrade < /dev/null || return $?
  bash "$S/ai/normalize-findings.sh" --subject "$SUBJECT" --stage upgrade < /dev/null || return $?
  bash "$S/ai/classify.sh" --subject "$SUBJECT" < /dev/null || return $?
  bash "$S/ai/apply-recipes.sh" --subject "$SUBJECT" --reextract < /dev/null || return $?
  return 0
}
stage_php() {
  local nf nw rc=0 lv
  # Rector's or PHPStan's missing verdict (extract exit 3) is validate's to
  # judge (the fixpoint gate); the PHP-window tools carry their own.
  bash "$S/ai/extract.sh" --subject "$SUBJECT" --stage php < /dev/null || rc=$?
  case "$rc" in
    0) ;;
    3) log_warn "pipeline: php: Rector or PHPStan gave no verdict; the PHP-window tools have their own (findings.json), and validate's fixpoint judges the rest.";;
    *) return "$rc";;
  esac
  bash "$S/ai/normalize-findings.sh" --subject "$SUBJECT" --stage php < /dev/null || return $?
  bash "$S/ai/classify.sh" --subject "$SUBJECT" < /dev/null || return $?
  # The gate: every PHP-window finding is in a worklist item.
  nf="$(jq -r '[.findings[] | select(.class == "php-target" and .tool == "catalog") | .id] | sort | join(",")' "$SD/findings.json" 2> /dev/null || printf 'x')"
  nw="$(jq -r --slurpfile f "$SD/findings.json" '([$f[0].findings[] | select(.class == "php-target" and .tool == "catalog") | .id]) as $p
    | [.items[].finding_ids[] | select(. as $i | $p | index($i))] | sort | join(",")' "$(worklist_file "$SUBJECT")" 2> /dev/null || printf 'y')"
  if [[ "$nf" != "$nw" ]]; then log_err "pipeline: php: a PHP-window finding is in no worklist item."; return 1; fi
  # A php -l that did not run on every leg leaves the stage to run again.
  lv="$(jq -r '.tools["php-lint"] // empty' "$SD/findings.json" 2> /dev/null || true)"
  case "$lv" in skipped|partial|failed) DONE_REASON="php-lint-$lv";; esac
  log_info "pipeline: php: $(jq -r --arg re "$PHP_WINDOW_REASONS_ERE" '[.items[] | select(.status == "open" and .lane == "human" and ((.reason // "") | test($re)))] | "\(length) open PHP-window item(s), \([.[] | select(.blocking)] | length) blocking"' "$(worklist_file "$SUBJECT")")."
  return 0
}
stage_validate() {
  bash "$S/analysis/fixpoint.sh" --subject "$SUBJECT" --stage validate < /dev/null || return $?
  return 0
}
stage_report() {
  set -- --subject "$SUBJECT" --phase "$PHASE"
  [[ -z "$RATIONALE" ]] || set -- "$@" --rationale "$RATIONALE"
  bash "$S/ai/manifest.sh" "$@" < /dev/null || return $?
  bash "$S/analysis/port-report.sh" --subject "$SUBJECT" --manifest "$SD/port-manifest.json" < /dev/null > /dev/null || return $?
  return 0
}

STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
D0="$(digest_now)"
[[ -n "$RUN" ]] || RUN="$(printf '%s' "$STARTED" | tr -d ':-')-$(printf '%s' "${D0#sha256:}" | cut -c1-6)"
# RAN: a stage before ran (done) in this run, so the ones after it run too
# (their records describe what came before).
RC=0; OUT='[]'; RAN=0
for s in $ORDER; do
  D="$(digest_now)"
  last="$(jq -c --arg s "$s" '.stages[$s] // {}' "$REC" 2> /dev/null || printf '{}')"
  if [[ "$FORCE" != "1" && "$RAN" != "1" ]] && jq -e --arg d "$D" '(.status == "done" or .status == "skipped") and .output_digest == $d
       and (((.reason // "") == "placeholder" or ((.reason // "") | startswith("php-lint-"))) | not)' <<< "$last" > /dev/null 2>&1; then
    log_info "pipeline: $s is up to date (its output digest is the current one)."
    OUT="$(jq -c --arg s "$s" --arg d "$D" '. + [{id: $s, status: "up-to-date", reason: null, input_digest: $d, output_digest: $d, rc: 0}]' <<< "$OUT")"
    continue
  fi
  ref="refs/drupilot/stages/$RUN/$s"
  git_stage_checkpoint "$SUBJECT" "$ref" > /dev/null || die "Could not record the checkpoint $ref of $SUBJECT." 1
  log_step "pipeline: $s (run $RUN)"
  SKIP_REASON=""; DONE_REASON=""; rc=0
  "stage_$s" || rc=$?
  # Its raw reports carry the stage's own NN.
  nn="$(nn_of "$s")"
  bad="$(raw_misnumbered "$s" "$nn")"
  if [[ "$rc" == "0" && -n "$bad" ]]; then log_err "pipeline: $s wrote raw reports under another number than $nn: $bad"; rc=1; fi
  if [[ "$rc" != "0" ]]; then
    if git_stage_restore "$SUBJECT" "$ref"; then log_warn "pipeline: $s failed (exit $rc); the tree is back at its checkpoint ($ref)."
    else log_err "pipeline: $s failed (exit $rc), and the tree could not be restored from $ref."; fi
    record "$s" failed "exit $rc" "$D" "" "$rc"
    OUT="$(jq -c --arg s "$s" --arg d "$D" --argjson rc "$rc" '. + [{id: $s, status: "failed", reason: "exit \($rc)", input_digest: $d, output_digest: null, rc: $rc}]' <<< "$OUT")"
    RC=3; break
  fi
  D2="$(digest_now)"
  st="done"; [[ -z "$SKIP_REASON" ]] || st="skipped"
  [[ "$st" != "done" ]] || RAN=1
  record "$s" "$st" "${SKIP_REASON:-$DONE_REASON}" "$D" "$D2" 0
  [[ -z "$SKIP_REASON" ]] || log_info "pipeline: $s skipped ($SKIP_REASON)."
  OUT="$(jq -c --arg s "$s" --arg st "$st" --arg r "${SKIP_REASON:-$DONE_REASON}" --arg d "$D" --arg o "$D2" \
    '. + [{id: $s, status: $st, reason: (if $r == "" then null else $r end), input_digest: $d, output_digest: $o, rc: 0}]' <<< "$OUT")"
done
run_manifest_record "$SUBJECT" pipeline "$STARTED" \
  "$(jq -n -c --arg d "$D0" --arg st "$STAGES" '{digest: $d, stages: ($st | split(","))}')" \
  "$(jq -c --arg d "$(digest_now)" '{digest: $d, stages: map({id, status})}' <<< "$OUT")" > /dev/null || true
if [[ "$AS_JSON" == "1" ]]; then jq -n --arg run "$RUN" --argjson st "$OUT" '{run_id: $run, stages: $st}'; fi
exit "$RC"
