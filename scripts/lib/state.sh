#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/state.sh
# Per-subject state (state.json, stages), the port record (manifest +
# decision log), origin baselines and the core-matrix / negative-control
# records.
#
# Part of the shared library: scripts/lib/common.sh sources it with the other
# domain libs (never source it alone); see common.sh for the conventions.
# =============================================================================

# core_matrix_file <subject> -> path of the subject's persisted core-matrix
# result (verify-core-matrix.sh), whether or not it exists yet.
core_matrix_file() { printf '%s/core-matrix.json' "$(project_state_dir "${1:-$PWD}")"; }

# negative_controls_file <subject> -> path of the subject's negative-control
# records (negative-control.sh), whether or not it exists yet. Hidden state,
# like last-test.json: a deliberate red run is never a project artifact.
negative_controls_file() { printf '%s/negative-controls.json' "$(project_state_dir "${1:-$PWD}")"; }

# negative_controls_summary <subject> -> compact JSON summary of the recorded
# negative controls ({total, effective, ineffective, error, stale, controls:
# [{test, type, label, verdict, mutation, stale}]}), or "null" when none was
# recorded. A control is "stale" when the subject's sources changed after it
# ran (its subject_digest differs), so a report never presents it as current
# proof. It carries no time (AR-13: a hashed artifact keeps its timestamps
# under its top-level meta): negative_controls_times gives them.
negative_controls_summary() {
  local s="${1:-$PWD}" f digest
  f="$(negative_controls_file "$s")"
  if [[ ! -r "$f" ]] || ! have_cmd jq; then printf 'null'; return 0; fi
  digest="$(subject_digest "$s")"
  jq -c --arg d "$digest" '
    if (type == "array") and (length > 0) then
      [ .[] | {test, type, label: .label, verdict, mutation: (.mutation.kind // null),
               stale: ((.subject_digest // "") != "" and $d != "" and .subject_digest != $d)} ] as $c
      | {total: ($c | length),
         effective: ([ $c[] | select(.verdict == "effective") ] | length),
         ineffective: ([ $c[] | select(.verdict == "ineffective") ] | length),
         error: ([ $c[] | select(.verdict == "error") ] | length),
         stale: ([ $c[] | select(.stale) ] | length),
         controls: $c}
    else null end' "$f" 2>/dev/null || printf 'null'
  return 0
}

# negative_controls_times <subject> -> when each recorded negative control ran,
# in the order of negative_controls_summary's controls ([{test, type, label,
# at}], compact), or "null" when none was recorded: what last-test.json keeps
# under meta.negative_controls.
negative_controls_times() {
  local f
  f="$(negative_controls_file "${1:-$PWD}")"
  if [[ ! -r "$f" ]] || ! have_cmd jq; then printf 'null'; return 0; fi
  jq -c 'if (type == "array") and (length > 0) then [ .[] | {test, type, label: .label, at: (.at // null)} ] else null end' \
    "$f" 2>/dev/null || printf 'null'
  return 0
}

# --- Per-subject state (state.json) ------------------------------------------
# One JSON record per subject in its HIDDEN state dir (project_state_dir, next
# to assess.json / last-test.json / core-matrix.json): which porting stages
# were reached and when, plus a snapshot of the facts a portfolio view needs
# (effort, branch/commit, toolchain, preservation, core matrix, patch).
#
# Why hidden and not <root>/.drupilot/: it is machine state like the rest of
# that dir. It must survive `git clean` / a workspace rebuild (the stage
# ladder would otherwise restart at /drupilot-port), it can never leak into a
# patch, and /drupilot-status --all can find every subject's record under one
# data dir without walking project trees. The VISIBLE artifacts dir keeps only
# human-facing outputs; `state.sh show/list` render the record on demand.
#
# Writers (deterministic scripts, so the record never depends on the model
# remembering a step): port-report.sh records ported/refactored from the
# manifest's phase, run-phpunit.sh records tested on a verified whole-suite run
# and refreshes the snapshot after every recorded run, verify-core-matrix.sh and
# make-patch.sh refresh it, and state.sh record/refresh is the CLI the commands
# call (assess -> assessed, setup -> setup, contribute -> contributed).
# Readers: next-step.sh, the post-edit hook, /drupilot-status (and --all).
#
# Schema (version 1; every key but subject/stages may be null or absent):
#   {schema: 1, subject: ABS_PATH, machine_name, type, drupal_root,
#    ddev_project, origin: ABS_PATH (the developer's checkout a loose subject
#    was placed from), placement,
#    created, updated: ISO-8601 UTC,
#    stage: setup|assessed|ported|refactored|tested|contributed,
#    stages: {<stage>: ISO time it was last recorded, ...},
#    effort: S|M|L|XL, assessed_at,
#    git: {branch, commit, dirty},
#    toolchain: {drupal_core, php_target, core_strategy, packages: {name: ver},
#                lock_drupilot_version},
#    tests: {status, preservation, executed, tests_failed, groups_passed,
#            groups_failed, groups_skipped, recorded_at, fresh}  (last-test.json),
#    core_matrix: {verdict, d10_support, generated_at, fresh},
#    patch: {path, kind: local|issue|contribution, at},
#    portfolio: {dir: ABS_PATH, layer} (state.sh record --portfolio, from
#               /drupilot-layers: the set and porting layer the subject is in),
#    drupilot_version}
# `fresh` is true when the result was computed on the subject's current
# sources (subject_digest). `stage` is the highest-ranked stage reached and never
# goes down (re-running /drupilot-port after a refactor does not undo it;
# DRUPILOT_STATE_FORCE=1 lets a record lower it). The legacy plain-text
# `<state_dir>/phase` marker is kept in sync with `stage` for older readers.
# Writers merge and never drop keys they do not own.

# subject_state_file <subject> -> path of the subject's state.json (the
# directory is not created: readers must not leave state dirs behind).
subject_state_file() { printf '%s/state.json' "$(project_state_path "${1:-$PWD}")"; }

# stage_normalize <word> -> the canonical stage name (ported, refactored, ...)
# for the verbs and legacy markers in use (port, refactor, ...); empty when
# unknown.
stage_normalize() {
  case "$(lc "${1:-}")" in
    setup) printf 'setup';;
    assess|assessed) printf 'assessed';;
    port|ported) printf 'ported';;
    refactor|refactored) printf 'refactored';;
    test|tested) printf 'tested';;
    contribute|contributed) printf 'contributed';;
  esac
  return 0
}

# stage_rank <stage> -> its position on the ladder (0 when unknown).
stage_rank() {
  case "$(stage_normalize "${1:-}")" in
    setup) printf 1;; assessed) printf 2;; ported) printf 3;;
    refactored) printf 4;; tested) printf 5;; contributed) printf 6;;
    *) printf 0;;
  esac
}

# state_get <subject> <jq-path> [default] -> a value from state.json (strings
# raw, other JSON compact), or the default. STDOUT only; never fails.
state_get() {
  local f v
  f="$(subject_state_file "${1:-$PWD}")"
  if [[ -r "$f" ]] && have_cmd jq; then
    v="$(jq -r "(${2}) // empty | if type == \"string\" then . else tojson end" "$f" 2>/dev/null || true)"
    if [[ -n "$v" ]]; then printf '%s' "$v"; return 0; fi
  fi
  printf '%s' "${3:-}"
  return 0
}

# state_set <subject> <jq-path> <string> / state_set_json <subject> <jq-path>
# <json> -> set one key in state.json (created when absent) and stamp
# `.updated`, `.subject`, `.schema` and `.created`. Atomic (temp file + mv);
# returns 1 without jq or on a write error. <jq-path> is plugin-controlled,
# never user input.
state_set() { _state_write "${1:-$PWD}" "${2}" "--arg" "${3}"; }
state_set_json() { _state_write "${1:-$PWD}" "${2}" "--argjson" "${3}"; }
_state_write() {
  local subj="$1" path="$2" kind="$3" val="$4"
  _state_apply "$subj" "$kind" "$val" "${path} = \$v"
}
# _state_apply <subject> <--arg|--argjson> <value> <jq-filter using $v> ->
# the one atomic writer behind state_set/state_refresh.
_state_apply() {
  local subj="$1" kind="$2" val="$3" filter="$4" f tmp abs
  have_cmd jq || return 1
  f="$(subject_state_file "$subj")"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  abs="$(cd "$subj" 2>/dev/null && pwd || printf '%s' "$subj")"
  [[ -s "$f" ]] || printf '{}\n' > "$f" 2>/dev/null || return 1
  tmp="$(mktemp "${f}.XXXXXX" 2>/dev/null)" || return 1
  if jq "$kind" v "$val" --arg s "$abs" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg pv "$(plugin_version)" \
       "${filter} | .subject = \$s | .updated = \$at | .created = (.created // \$at) | .schema = 1 | .drupilot_version = \$pv" \
       "$f" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f"
  else
    rm -f "$tmp" 2>/dev/null || true; return 1
  fi
}

# phase_record <subject> <stage> -> mark <stage> as reached now
# (.stages[stage]), raise .stage when it ranks higher (monotonic, see above),
# rewrite the legacy phase marker and refresh the snapshot (state_refresh).
# Returns 1 for an unknown stage or a write error. Callers in a flow wrap it in
# `|| true`: recording is never a reason to fail a port.
phase_record() {
  local subj="${1:-$PWD}" st cur force
  st="$(stage_normalize "${2:-}")"
  [[ -n "$st" ]] || return 1
  state_set "$subj" ".stages[\"$st\"]" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  cur="$(state_get "$subj" .stage "")"
  force="$(config_get DRUPILOT_STATE_FORCE "")"
  if [[ -z "$cur" || "$(stage_rank "$st")" -gt "$(stage_rank "$cur")" || "$force" == "1" || "$(lc "$force")" == "true" ]]; then
    state_set "$subj" .stage "$st" || return 1
  fi
  state_refresh "$subj" 2>/dev/null || true
  cur="$(state_get "$subj" .stage "$st")"
  printf '%s\n' "$cur" > "$(project_state_dir "$subj")/phase" 2>/dev/null || true
  return 0
}

# phase_get <subject> -> the current stage: state.json's .stage, else the
# legacy phase marker (normalized: refactor -> refactored). Empty when none.
phase_get() {
  local subj="${1:-$PWD}" st
  st="$(state_get "$subj" .stage "")"
  if [[ -z "$st" ]]; then
    st="$({ tr -d '[:space:]' < "$(project_state_path "$subj")/phase"; } 2>/dev/null || true)"
  fi
  stage_normalize "$st"
  return 0
}

# phase_reached <subject> <stage> -> 0 when <stage> was reached:
#   * recorded in state.json's .stages, or implied by the rank of its current
#     .stage (a subject recorded as tested/contributed was ported, even when no
#     writer recorded 'ported' itself) — except 'refactored', which is opt-in
#     and therefore never implied by a later stage when state.json exists;
#   * (a subject without state.json) implied by the legacy marker's rank;
#   * for ported/refactored, the port manifest the flow wrote at the end of a
#     port/refactor (<state_dir>/port-manifest.json .phase), so a port finished
#     before the stage was recorded is not sent back to /drupilot-port.
# Read-only.
phase_reached() {
  local subj="${1:-$PWD}" st cur mp
  st="$(stage_normalize "${2:-}")"
  [[ -n "$st" ]] || return 1
  if [[ -r "$(subject_state_file "$subj")" ]] && have_cmd jq; then
    [[ -n "$(state_get "$subj" ".stages[\"$st\"]" "")" ]] && return 0
    if [[ "$st" != "refactored" ]]; then
      cur="$(state_get "$subj" .stage "")"
      [[ -n "$cur" && "$(stage_rank "$cur")" -ge "$(stage_rank "$st")" ]] && return 0
    fi
  else
    cur="$(phase_get "$subj")"
    [[ -n "$cur" && "$(stage_rank "$cur")" -ge "$(stage_rank "$st")" ]] && return 0
  fi
  case "$st" in
    ported|refactored)
      mp="$(port_manifest_stage "$subj")"
      [[ -n "$mp" && "$(stage_rank "$mp")" -ge "$(stage_rank "$st")" ]] && return 0
      ;;
  esac
  return 1
}

# port_manifest_stage <subject> -> the stage the subject's port manifest
# (<state_dir>/port-manifest.json, written by the flow when a port/refactor
# completes) shows as done: ported | refactored, or empty. Read-only.
port_manifest_stage() {
  local f ph=""
  f="$(project_state_path "${1:-$PWD}")/port-manifest.json"
  [[ -r "$f" ]] && have_cmd jq || return 0
  ph="$(jq -r 'if type == "object" then (.phase // "port") else empty end' "$f" 2>/dev/null || true)"
  case "$(stage_normalize "$ph")" in
    ported|refactored) stage_normalize "$ph";;
  esac
  return 0
}

# _json_from <file> <jq-filter> -> the filter's compact output on a readable,
# valid JSON file, else `null`. Never fails.
_json_from() {
  local out=""
  [[ -r "$1" ]] && out="$(jq -c "$2" "$1" 2>/dev/null || true)"
  [[ -n "$out" ]] || out="null"
  printf '%s' "$out"
}

# The jq definitions shared by state_refresh and state_view_json: how a stored
# record and a fresh snapshot combine. Non-null snapshot keys win (they are
# read from the source records, which are the truth); a key the snapshot cannot
# see any more (the subject tree is gone, so no git info) keeps its stored
# value. An assessment on file that no stage recorded yet backfills the
# assessed stage (raising a lower `stage` to it), and an empty `stage` takes the
# highest one recorded; otherwise an existing `stage` is never moved here (only
# phase_record moves it, so a forced lower stage stays lower). A
# patch recorded by make-patch.sh is kept over the port manifest's one.
_STATE_JQ_DEFS='
def srank: {"setup":1,"assessed":2,"ported":3,"refactored":4,"tested":5,"contributed":6}[. // ""] // 0;
def state_merge($snap):
  . + ($snap | del(.patch, .port_stage, .port_at) | with_entries(select(.value != null)))
  | .patch = (.patch // $snap.patch // null)
  | .stages = (.stages // {})
  | (if (.effort != null and .stages.assessed == null and (.assessed_at // .updated) != null)
     then .stages.assessed = (.assessed_at // .updated)
          | (if (.stage | srank) < ("assessed" | srank) then .stage = "assessed" else . end)
     else . end)
  | (if (($snap.port_stage // "") != "") and .stages.ported == null
     then .stages.ported = ($snap.port_at // .updated // "recorded-by-manifest")
          | (if (.stage | srank) < ("ported" | srank) then .stage = "ported" else . end)
     else . end)
  | (if ($snap.port_stage // "") == "refactored" and .stages.refactored == null
     then .stages.refactored = ($snap.port_at // .updated // "recorded-by-manifest")
          | (if (.stage | srank) < ("refactored" | srank) then .stage = "refactored" else . end)
     else . end)
  | .stages |= with_entries(select(.value != null))
  | (if ((.stage // "") == "") and ((.stages | length) > 0)
     then .stage = (.stages | keys | max_by(srank)) else . end);
'

# origin_baseline_path <root> [machine] -> the file origin-hygiene.sh records
# <machine>'s origin baseline in: the Drupal ROOT's hidden state dir (a moved
# origin is found again through the root), ONE FILE PER SUBJECT
# (origin-baseline-<machine>.json) so the modules placed into a shared test-bed
# do not overwrite each other's. Without a machine name: the single-file name
# older versions used (origin-baseline.json). Pure: creates nothing.
origin_baseline_path() {
  local d; d="$(project_state_path "$1")"
  if [[ -n "${2:-}" ]]; then printf '%s/origin-baseline-%s.json' "$d" "$2"
  else printf '%s/origin-baseline.json' "$d"; fi
}

# origin_baseline_find <root> <machine> -> the path of <machine>'s existing
# baseline under <root>: its own file, else the older single file when that one
# records the same machine name (or none). Prints nothing (still 0) when there
# is none. Read-only.
origin_baseline_find() {
  local f mn
  f="$(origin_baseline_path "$1" "${2:-}")"
  if [[ -n "${2:-}" && -f "$f" ]]; then printf '%s' "$f"; return 0; fi
  f="$(origin_baseline_path "$1")"
  [[ -f "$f" ]] || return 0
  if [[ -n "${2:-}" ]] && have_cmd jq; then
    mn="$(jq -r '.machine_name // empty' "$f" 2>/dev/null || true)"
    [[ -z "$mn" || "$mn" == "$2" ]] || return 0
  fi
  printf '%s' "$f"
  return 0
}

# origin_baseline_files <root> -> every origin baseline under <root>, one path
# per line (the per-subject files and the older single file). Read-only.
origin_baseline_files() {
  local d f; d="$(project_state_path "$1")"
  for f in "$d"/origin-baseline-*.json "$d"/origin-baseline.json; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
  return 0
}

# state_snapshot_json <subject> -> the facts drupilot can read about the subject
# right now, as one compact JSON object (see the schema above): from the
# subject's own state dir (assess.json, last-test.json, core-matrix.json,
# port-manifest.json), the Drupal root's (drupilot-lock.json,
# origin-baseline.json), the info.yml, .ddev/config.yaml and git. Read-only: it
# creates nothing and never starts DDEV. `null` without jq.
state_snapshot_json() {
  local subj="${1:-$PWD}" abs sd root="" rsd="" mn="" typ="" ddev="" digest=""
  local git_json="null" br cm dirty a t m pm l o
  have_cmd jq || { printf 'null'; return 0; }
  abs="$(cd "$subj" 2>/dev/null && pwd || printf '%s' "$subj")"
  sd="$(project_state_path "$abs")"
  if [[ -d "$abs" ]]; then
    root="$(find_drupal_root "$abs" 2>/dev/null || true)"
    mn="$(subject_machine_name "$abs" 2>/dev/null || true)"
    typ="$(subject_type "$abs" 2>/dev/null || true)"
    if have_cmd git && git -C "$abs" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      br="$(git -C "$abs" symbolic-ref --short -q HEAD 2>/dev/null || true)"
      cm="$(git -C "$abs" rev-parse HEAD 2>/dev/null || true)"
      dirty=false
      [[ -n "$(git -C "$abs" status --porcelain -- . 2>/dev/null | sed -n '1p')" ]] && dirty=true
      git_json="$(jq -nc --arg b "$br" --arg c "$cm" --argjson d "$dirty" \
        '{branch: (if $b == "" then "(detached)" else $b end), commit: (if $c == "" then null else $c end), dirty: $d}')"
    fi
    if [[ -r "$sd/last-test.json" || -r "$sd/core-matrix.json" ]]; then
      digest="$(subject_digest "$abs" 2>/dev/null || true)"
    fi
  fi
  if [[ -n "$root" ]]; then
    rsd="$(project_state_path "$root")"
    [[ -f "$root/.ddev/config.yaml" ]] && ddev="$(sed -n 's/^name:[[:space:]]*//p' "$root/.ddev/config.yaml" 2>/dev/null | sed -n '1p' | tr -d "\"' " || true)"
  fi
  a="$(_json_from "$sd/assess.json" '{effort: (.verdict // .effort // null), at: (.timestamp // .generated_at // null)}')"
  t="$(_json_from "$sd/last-test.json" '{status: (.status // null), preservation: (.preservation // null), executed: (.executed // null), tests_failed: ([.tests[]? | select(.status == "fail" or .status == "error")] | length), groups_passed: (.passed // null), groups_failed: (.failed // null), groups_skipped: (.skipped // null), recorded_at: (.recorded_at // .generated_at // null), digest: (.subject_digest // null)}')"
  m="$(_json_from "$sd/core-matrix.json" '{verdict: (.verdict // null), d10_support: (.d10_support // null), generated_at: (.generated_at // null), digest: (.subject_digest // null)}')"
  pm="$(_json_from "$sd/port-manifest.json" '{patch: (.patch | if type == "string" then . else null end), phase: ((.phase // "port") | if type == "string" then . else null end), at: (.generated_at // .recorded_at // null)}')"
  # A relative manifest patch path is the subject's; when it is not there but
  # the same path exists under the Drupal root (a manifest written with the
  # root-relative path), use that one, so the patch is not reported missing.
  local mp; mp="$(printf '%s' "$pm" | jq -r '.patch // empty' 2>/dev/null || true)"
  if [[ -n "$mp" && "$mp" != /* && ! -e "$abs/$mp" && -n "$root" && -e "$root/$mp" ]]; then
    pm="$(printf '%s' "$pm" | jq -c --arg p "$root/$mp" '.patch = $p' 2>/dev/null || printf '%s' "$pm")"
  fi
  # No patch named in the manifest: the newest local preview next to the
  # subject (make-patch.sh --local writes <machine_name>-<description>.patch).
  if [[ -n "$mn" && "$(printf '%s' "$pm" | jq -r '.patch // empty' 2>/dev/null)" == "" ]]; then
    local lp; lp="$(cd "$abs" 2>/dev/null && ls -1t -- "$mn"-*.patch 2>/dev/null | sed -n '1p' || true)"
    [[ -n "$lp" ]] && pm="$(printf '%s' "$pm" | jq -c --arg p "$abs/$lp" '(if type == "object" then . else {} end) + {patch: $p}' 2>/dev/null || jq -nc --arg p "$abs/$lp" '{patch: $p}')"
  fi
  l="null"; o="null"
  if [[ -n "$rsd" ]]; then
    l="$(_json_from "$rsd/drupilot-lock.json" '{drupal_core: (.drupal.core // null), php_target: (.php_target // null), core_strategy: (.core_strategy // null), packages: (.toolchain // null), lock_drupilot_version: (.drupilot_version // null)}')"
    local ob; ob="$(origin_baseline_find "$root" "$mn")"
    [[ -n "$ob" ]] && o="$(_json_from "$ob" '{source: (.source // null), placement: (.placement // null)}')"
    # No baseline (an in-place subject, or one placed before baselines were
    # per subject): the test-bed marker records each placed subject's origin.
    if [[ "$o" == "null" && -n "$mn" && -r "$root/.drupilot.json" ]]; then
      o="$(jq -c --arg m "$mn" '.drupilot_testbed.subjects[$m] // null
        | if type == "object" and (.origin // "") != "" then {source: .origin, placement: (.placement // null)} else null end' \
        "$root/.drupilot.json" 2>/dev/null || printf 'null')"
      [[ -n "$o" ]] || o="null"
    fi
  fi
  jq -nc --arg subject "$abs" --arg mn "$mn" --arg typ "$typ" --arg root "$root" --arg ddev "$ddev" \
    --arg digest "$digest" --argjson git "$git_json" --argjson a "$a" --argjson t "$t" \
    --argjson m "$m" --argjson pm "$pm" --argjson l "$l" --argjson o "$o" '
    def nz: if . == "" then null else . end;
    def fresh($d): if ($d // "") == "" or $digest == "" then null else ($d == $digest) end;
    {subject: $subject, machine_name: ($mn | nz), type: ($typ | nz),
     drupal_root: ($root | nz), ddev_project: ($ddev | nz),
     origin: ($o.source // null), placement: ($o.placement // null),
     effort: ($a.effort // null), assessed_at: ($a.at // null),
     git: $git, toolchain: $l,
     tests: (if $t == null then null else ($t | del(.digest)) + {fresh: fresh($t.digest)} end),
     core_matrix: (if $m == null then null else ($m | del(.digest)) + {fresh: fresh($m.digest)} end),
     port_stage: (($pm.phase // "") | ascii_downcase | if . == "port" or . == "ported" then "ported" elif . == "refactor" or . == "refactored" then "refactored" else null end),
     port_at: ($pm.at // null),
     patch: (if ($pm.patch // "") == "" then null
             else {path: ($pm.patch | if startswith("/") then . else $subject + "/" + . end),
                   kind: "local", at: null} end)}'
  return 0
}

# state_refresh <subject> -> merge a fresh snapshot into state.json (created
# when absent). Called by the flow scripts after they write a source record.
# Returns 1 without jq or on a write error; callers use `|| true`.
state_refresh() {
  local subj="${1:-$PWD}" snap
  have_cmd jq || return 1
  snap="$(state_snapshot_json "$subj")"
  [[ -n "$snap" && "$snap" != "null" ]] || return 1
  _state_apply "$subj" --argjson "$snap" "${_STATE_JQ_DEFS} state_merge(\$v)"
}

# state_patch_record <subject> <path> <kind> -> remember the last patch made
# for the subject (kind: local | issue | contribution). Never fails.
state_patch_record() {
  local subj="${1:-$PWD}" p="$2" kind="${3:-local}" abs
  have_cmd jq || return 0
  abs="$(cd "$(dirname "$p")" 2>/dev/null && pwd || dirname "$p")/$(basename "$p")"
  state_set_json "$subj" .patch "$(jq -nc --arg p "$abs" --arg k "$kind" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{path: $p, kind: $k, at: $at}')" 2>/dev/null || true
  state_refresh "$subj" 2>/dev/null || true
  return 0
}

# state_view_json <subject> -> the subject's record as a reader should see it:
# the stored state.json (if any) merged with a fresh snapshot, plus
# `recorded` (state.json exists), `exists` (the subject directory exists) and
# `patch.exists`. A subject recorded only by the legacy phase marker gets that
# stage. Read-only: writes and creates nothing.
state_view_json() {
  local subj="${1:-$PWD}" f stored="{}" snap legacy="" recorded=false exists=false abs v p pe
  have_cmd jq || { printf 'null'; return 0; }
  abs="$(cd "$subj" 2>/dev/null && pwd || printf '%s' "$subj")"
  [[ -d "$abs" ]] && exists=true
  f="$(subject_state_file "$abs")"
  if [[ -r "$f" ]]; then
    stored="$(jq -c 'if type == "object" then . else {} end' "$f" 2>/dev/null || true)"
    recorded=true
  fi
  [[ -n "$stored" ]] || stored="{}"
  [[ "$recorded" == "true" ]] || legacy="$(phase_get "$abs")"
  snap="$(state_snapshot_json "$abs")"
  v="$(jq -nc --argjson st "$stored" --argjson snap "$snap" --arg legacy "$legacy" \
     --argjson recorded "$recorded" --argjson exists "$exists" --arg subject "$abs" "${_STATE_JQ_DEFS}"'
    ($st | state_merge($snap))
    | .subject = (.subject // $subject)
    | (if (.stage // "") == "" and $legacy != "" then .stage = $legacy else . end)
    | .stage = (.stage // null)
    | .recorded = $recorded | .exists = $exists' 2>/dev/null || true)"
  [[ -n "$v" ]] || { printf 'null'; return 0; }
  # patch.exists needs the filesystem.
  p="$(printf '%s' "$v" | jq -r '.patch.path // empty' 2>/dev/null || true)"
  if [[ -n "$p" ]]; then
    pe=false; [[ -f "$p" ]] && pe=true
    v="$(printf '%s' "$v" | jq -c --argjson e "$pe" '.patch.exists = $e' 2>/dev/null || printf '%s' "$v")"
  fi
  printf '%s\n' "$v"
  return 0
}

# core_matrix_fresh <subject> -> 0 when a core-matrix result exists for the
# subject AND was computed on its current sources (same subject_digest), so a
# report never presents a verdict about code that changed since.
core_matrix_fresh() {
  local s="${1:-$PWD}" f want have
  f="$(core_matrix_file "$s")"
  [[ -r "$f" ]] && have_cmd jq || return 1
  have="$(jq -r '.subject_digest // empty' "$f" 2>/dev/null || true)"
  want="$(subject_digest "$s")"
  [[ -n "$have" && "$have" == "$want" ]]
}

# core_matrix_summary <subject> -> the core-matrix lines /drupilot-status shows
# at load: "core_matrix_fresh=yes|no" and the matrix (d10_support, verdict,
# generated_at, legs) as one JSON line, or "core_matrix=none". A function, so
# the command's load-time line carries no inline jq program (Claude Code
# refuses such a `bash -c` script in -p mode and asks for approval otherwise).
core_matrix_summary() {
  local s="${1:-$PWD}" f
  f="$(core_matrix_file "$s")"
  if [[ -r "$f" ]]; then
    printf 'core_matrix_fresh=%s\n' "$(core_matrix_fresh "$s" && echo yes || echo no)"
    jq -c '{d10_support, verdict, generated_at, legs: [.legs[] | {core: (.version // .core), role, status, reason}]}' "$f"
  else
    echo "core_matrix=none"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Port record: structured outcome fields + the decision log
# ---------------------------------------------------------------------------
# A port's outcome is recorded in two machine sources that aggregate across
# modules and layers (layer-report.sh, port-report.sh):
#   * the port MANIFEST (<state_dir>/port-manifest.json, written by the flow at
#     the end of a port/refactor) — its optional structured fields:
#       rector_rules       run-rector.sh --json `.rule_hits` ({official:{Rule:n},
#                          digests:{...}}), or {Rule: n}, or [Rule...], or
#                          [{rule, hits?, pass?}] (hits = files changed)
#       rector_reversions  [{rule, file?, why}]  a Rector change undone by hand
#       post_port_fixes    [{fix, file?, why, detected_by?}]  a fix made after
#                          the validate loop / tests / core matrix found a problem
#       preexisting_bugs   [{issue, file?, note?}]  found, NOT fixed by the port
#       behavior_changes   [{change, why?, review_hint?}]  to review in the PR
#       tooling_deviations [{what, why}]  the flow or a tool's output not followed
#       validation         [string]  how the result was validated
#     (a plain string is accepted for any list item);
#   * the DECISION LOG (log-decision.sh): one JSON line per decision in
#     <artifacts_dir>/decisions.jsonl (with a human decisions.md beside it),
#     written the moment the agent reverts a Rector change, diverges from a
#     script's output, skips a step, etc. Entry (schema 1): {schema, ts,
#     subject, machine_name, drupal_root, phase, kind, what, why, rule, file,
#     script, detected_by, review_hint}. Kinds map onto the manifest fields:
#     rector-revert -> rector_reversions, post-port-fix -> post_port_fixes,
#     preexisting-bug -> preexisting_bugs, behavior-change -> behavior_changes,
#     script-divergence | skip | manual-override | tooling-deviation ->
#     tooling_deviations, test-adaptation -> test_adaptations.
# port_record_json merges both (manifest items first, deduplicated), so the
# flow may record a decision in either place, or both.

# project_artifacts_path [base_dir] -> the directory project_artifacts_dir
# resolves, WITHOUT creating it (for read-only callers).
project_artifacts_path() {
  local base="${1:-$PWD}" override
  override="$(config_get DRUPILOT_ARTIFACTS_DIR "")"
  if [[ -n "$override" ]]; then
    ( cd "$override" 2>/dev/null && pwd ) || printf '%s' "$override"
    return 0
  fi
  _artifacts_dir_path "$base"
  return 0
}

# decisions_log_file <subject> -> the decision log (JSONL) the subject's
# decisions go to: <artifacts_dir>/decisions.jsonl. One file per Drupal root;
# every entry names its subject, so modules sharing a test-bed stay apart.
decisions_log_file() { printf '%s/decisions.jsonl' "$(project_artifacts_path "${1:-$PWD}")"; }

# patterns_file [base_dir] -> path of the LEARNED-PATTERN CATALOG
# (scripts/analysis/patterns.sh): the pitfalls a port of this project already
# hit, each with a detector and a fix, so the next module is checked BEFORE it
# is ported. It is human-reviewable and editable, so it is a visible artifact,
# not hidden state. ONE catalog per project, shared by its modules:
#   1. DRUPILOT_PATTERNS_FILE (a team can point it at a committed file; a
#      relative path is taken from the Drupal root, else from base);
#   2. the base is replaced by the portfolio the subject was ported in
#      (state.json .portfolio.dir, from /drupilot-layers), so a set ported with
#      one test-bed per module still shares one catalog;
#   3. <Drupal root>/.drupilot/patterns.json (project_artifacts_path);
#   4. no Drupal root yet (a loose module, a monorepo before setup): the
#      nearest directory from base up to its git toplevel that already has
#      .drupilot/patterns.json, else <git toplevel or base>/.drupilot/, so a
#      submodule and its parent share the catalog.
# Nothing is created (read-only callers must not leave a dir behind).
patterns_file() {
  local base="${1:-$PWD}" f root p top d
  f="$(config_get DRUPILOT_PATTERNS_FILE "")"
  if [[ -n "$f" ]]; then
    case "$f" in
      /*) ;;
      *) root="${DRUPILOT_PROJECT_DIR:-}"
         [[ -z "$root" ]] && root="$(find_drupal_root "$base" 2>/dev/null || true)"
         [[ -z "$root" ]] && root="$base"
         root="$(cd "$root" 2>/dev/null && pwd || printf '%s' "$root")"
         f="$root/$f";;
    esac
    printf '%s' "$f"
    return 0
  fi
  p="$(state_get "$base" '.portfolio.dir' '')"
  [[ -n "$p" && -d "$p" ]] && base="$p"
  base="$(cd "$base" 2>/dev/null && pwd || printf '%s' "$base")"
  root="${DRUPILOT_PROJECT_DIR:-}"
  [[ -z "$root" ]] && root="$(find_drupal_root "$base" 2>/dev/null || true)"
  if [[ -n "$root" || -n "$(config_get DRUPILOT_ARTIFACTS_DIR "")" ]]; then
    printf '%s/patterns.json' "$(project_artifacts_path "$base")"
    return 0
  fi
  top=""
  have_cmd git && top="$(cd "$base" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$top" ]] && top="$(cd "$top" 2>/dev/null && pwd -P || printf '%s' "$top")"
  d="$(cd "$base" 2>/dev/null && pwd -P || printf '%s' "$base")"
  while [[ -n "$top" && "$d" == "$top"/* ]]; do
    if [[ -f "$d/.drupilot/patterns.json" ]]; then printf '%s/.drupilot/patterns.json' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  printf '%s/.drupilot/patterns.json' "${top:-$base}"
  return 0
}

# rector_rules_file <subject> -> the rule counts of the last Rector --apply run
# that changed files (run-rector.sh), the fallback for manifest.rector_rules.
rector_rules_file() { printf '%s/rector-rules.json' "$(project_state_path "${1:-$PWD}")"; }

# decisions_for_subject <subject> -> JSON array of the decision-log entries of
# the subject (matched by path, or by machine name within the same log, which
# survives a moved subject). `[]` when there is no log or no jq. Read-only.
decisions_for_subject() {
  local subj="${1:-$PWD}" abs f mn
  have_cmd jq || { printf '[]'; return 0; }
  abs="$(cd "$subj" 2>/dev/null && pwd || printf '%s' "$subj")"
  f="$(decisions_log_file "$abs")"
  [[ -r "$f" ]] || { printf '[]'; return 0; }
  mn="$(subject_machine_name "$abs" 2>/dev/null || true)"
  # -R + fromjson? skips a damaged line instead of failing the whole log.
  jq -R -c -s --arg s "$abs" --arg mn "$mn" '
    [ split("\n")[] | select(length > 0) | (fromjson? // empty) | select(type == "object")
      | select(.subject == $s or ($mn != "" and .machine_name == $mn)) ]' "$f" 2>/dev/null || printf '[]'
  return 0
}

# The jq definitions that normalize a manifest + decision entries into the
# port record (see the block comment above).
_PORT_RECORD_JQ_DEFS='
def _short: tostring | split("\\") | last;
def _list: if . == null then [] elif type == "array" then . else [.] end;
def _str: if . == null then null elif type == "string" then (if . == "" then null else . end) else tojson end;
def _rules:
  if . == null then []
  elif type == "object" and has("rule_hits") then (.rule_hits | _rules)
  elif type == "object" and (.rules | type) == "array" then (.rules | _rules)
  elif type == "array" then
    map(if type == "string" then {rule: ., hits: null, pass: null}
        elif type == "object" then {rule: (.rule // .name // null), hits: (.hits // .files // null), pass: (.pass // null)}
        else empty end)
  elif type == "object" then
    (if length > 0 and ([.[] | type] | all(. == "object"))
     then [to_entries[] | .key as $p | .value | to_entries[] | {rule: .key, hits: .value, pass: $p}]
     else [to_entries[] | {rule: .key, hits: .value, pass: null}] end)
  else [] end
  | map(select((.rule // "") != "") | .hits = (if (.hits | type) == "number" then .hits elif (.hits | type) == "array" then (.hits | length) else null end));
def _merge_rules:
  group_by(.rule | _short)
  | map({rule: (.[0].rule | _short),
         hits: (if all(.[]; .hits == null) then null else (map(.hits // 0) | add) end),
         passes: ([.[] | .pass | select(. != null)] | unique)});
def _items($k):
  _list | map(if type == "object" then . elif . == null then empty else {($k): tostring} end
              | . + {source: "manifest"} | with_entries(.value |= (if type == "string" or . == null then _str else . end)));
def _dedupe(f): reduce .[] as $i ([]; if any(.[]; (. | f) == ($i | f)) then . else . + [$i] end);
def port_record($m; $d; $rr; $subject; $mn):
  ($d | _list) as $d
  | (if ($m.rector_rules // null) != null then {src: "manifest", r: ($m.rector_rules | _rules)}
     elif $rr != null then {src: "run-rector", r: ($rr | _rules)}
     else {src: null, r: []} end) as $rules
  | def dec($kinds): [$d[] | select(.kind as $k | any($kinds[]; . == $k))];
  {subject: $subject, machine_name: ($m.machine_name // (if $mn == "" then null else $mn end)),
   phase: ($m.phase // null), manifest: ($m != {}),
   rector_files: ($m.rector_official_files // null),
   rector_rules: ($rules.r | _merge_rules), rector_rules_source: $rules.src,
   rector_reversions: (($m.rector_reversions | _items("rule"))
       + [dec(["rector-revert"])[] | {rule, file, why, what, source: "decision-log", ts}]
       | map(select((.rule // "") != "")) | _dedupe([(.rule | _short), (.file // "")])),
   post_port_fixes: (($m.post_port_fixes | _items("fix") | map(.fix = (.fix // .what)))
       + [dec(["post-port-fix"])[] | {fix: .what, file, why, detected_by, source: "decision-log", ts}]
       | map(select((.fix // "") != "")) | _dedupe([.fix, (.file // "")])),
   preexisting_bugs: (($m.preexisting_bugs | _items("issue") | map(.issue = (.issue // .what)))
       + [dec(["preexisting-bug"])[] | {issue: .what, file, note: .why, source: "decision-log", ts}]
       | map(select((.issue // "") != "")) | _dedupe([.issue, (.file // "")])),
   behavior_changes: (($m.behavior_changes | _items("change") | map(.change = (.change // .what)))
       + [dec(["behavior-change"])[] | {change: .what, why, review_hint, file, source: "decision-log", ts}]
       | map(select((.change // "") != "")) | _dedupe([.change])),
   tooling_deviations: (($m.tooling_deviations | _items("what"))
       + [dec(["script-divergence", "skip", "manual-override", "tooling-deviation"])[]
          | {what, why, kind, script, file, source: "decision-log", ts}]
       | map(select((.what // "") != "")) | _dedupe([.what])),
   test_adaptations: [dec(["test-adaptation"])[] | {what, why, file, ts}],
   validation: ($m.validation | _list | map(if type == "string" then . else tojson end)),
   manual_edits: ($m.manual_edits | _list
       | map(if type == "string" then {edit: ., why: null, change_record: null}
             elif type == "object" then {edit: (.edit // .what // "edit"), why: (.why // null), change_record: (.change_record // null)}
             else empty end)),
   decisions: ($d | length)};
'

# port_record_json <subject> [manifest] -> the subject's port record: the
# manifest (default <state_dir>/port-manifest.json) and the decision log merged
# into the normalized structured fields (see above), plus `manifest` (one was
# read) and `decisions` (how many log entries). Read-only; `null` without jq.
port_record_json() {
  local subj="${1:-$PWD}" man="${2:-}" abs mn m='{}' d rr="null"
  have_cmd jq || { printf 'null'; return 0; }
  abs="$(cd "$subj" 2>/dev/null && pwd || printf '%s' "$subj")"
  [[ -n "$man" ]] || man="$(project_state_path "$abs")/port-manifest.json"
  if [[ -r "$man" ]]; then
    m="$(jq -c 'if type == "object" then . else {} end' "$man" 2>/dev/null || true)"
    [[ -n "$m" ]] || m='{}'
  fi
  d="$(decisions_for_subject "$abs")"
  [[ -r "$(rector_rules_file "$abs")" ]] && rr="$(jq -c '.rule_hits // null' "$(rector_rules_file "$abs")" 2>/dev/null || printf 'null')"
  [[ -n "$rr" ]] || rr="null"
  mn="$(subject_machine_name "$abs" 2>/dev/null || true)"
  jq -nc --argjson m "$m" --argjson d "$d" --argjson rr "$rr" --arg s "$abs" --arg mn "$mn" \
    "${_PORT_RECORD_JQ_DEFS} port_record(\$m; \$d; \$rr; \$s; \$mn)" 2>/dev/null || printf 'null'
  return 0
}

# subjects_with_state_under <root> -> the subject paths (one per line) whose
# state.json records <root> as their Drupal root, or lives under it. Read-only;
# used to mark the environment removed/ready on every module of a test-bed.
subjects_with_state_under() {
  local root="${1%/}" sd f
  [[ -n "$root" ]] && have_cmd jq || return 0
  sd="$(data_dir_path)/state"
  [[ -d "$sd" ]] || return 0
  for f in "$sd"/*/state.json; do
    [[ -r "$f" ]] || continue
    jq -r --arg r "$root" '
      select(type == "object" and (.subject // "") != "")
      | select((.drupal_root // "") == $r or ((.subject // "") | startswith($r + "/")))
      | .subject' "$f" 2>/dev/null || true
  done
  return 0
}

# env_status_record <root> <status> [level] -> store `.environment = {status,
# level, at}` in the state.json of every subject under <root>
# (status: removed | ready). /drupilot-clean records `removed`; ddev-up.sh and
# place-subject.sh record `ready` on a subject that was marked removed, so
# next-step.sh recommends /drupilot-setup exactly while the environment is
# gone. Never fails.
env_status_record() {
  local root="$1" status="$2" level="${3:-}" s cur v
  have_cmd jq || return 0
  v="$(jq -nc --arg s "$status" --arg l "$level" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{status: $s, level: (if $l == "" then null else $l end), at: $at}')"
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    if [[ "$status" == "ready" ]]; then
      cur="$(state_get "$s" .environment.status "")"
      [[ "$cur" == "removed" ]] || continue
    fi
    state_set_json "$s" .environment "$v" 2>/dev/null || true
  done < <(subjects_with_state_under "$root")
  return 0
}
