#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/layer-report.sh
# The CONSOLIDATED report of a /drupilot-layers run: what each module of a
# porting layer (or of every layer, or of any set of modules) recorded, in ONE
# fixed format so layers compare and aggregate (templates/layer-report.md.tmpl):
#   1. per-module result (stage, effort, preservation, Drupal 10 verdict,
#      pre-existing hygiene, undeclared dependencies, Rector files, reverted
#      Rector changes, post-port fixes, patch, report);
#   2. frequent Rector rules — hits (files changed) AND reversions;
#   3. manual changes;  4. post-port fixes;  5. pre-existing bugs (not fixed);
#   6. behavior changes to review in the PR;  7. tooling/flow deviations;
#   8. how it was validated.
# Sections 2-8 come from each module's PORT RECORD (common.sh
# port_record_json): the structured fields of its port manifest merged with its
# decision log (log-decision.sh) and the last Rector apply's rule counts. The
# rest comes from layers.json (layers.sh), the per-module state registry
# (state.sh list) and lint-extension-metadata.sh's state. Read-only on the
# code; a value no record holds is "n/a" / "None recorded", never invented.
#
# Usage:
#   layer-report.sh --dir DIR [--layer N|all] [--edges all|declared] [--json]
#                   [--output DIR] [--no-write]
#   layer-report.sh --subject DIR [--subject DIR]... [--name LABEL] [--json]
#                   [--output DIR] [--no-write]
#
# Options:
#   --dir DIR      The set given to layers.sh / /drupilot-layers.
#   --layer N      One layer (default: all layers). With --dir only.
#   --edges MODE   With --dir: which layering to report — `all` (default: the
#                  canonical layers.json, declared + implicit dependencies) or
#                  `declared` (layers.sh --edges declared, layers-declared.json).
#                  A saved file computed with other edges is not used: the
#                  layers are recomputed. The report states the mode (`edges`).
#   --subject DIR  Report on these modules/themes instead of a layers.json set
#                  (repeatable; e.g. modules ported in separate test-beds).
#                  Undeclared dependencies are then "n/a" (layers.sh did not
#                  run).
#   --name LABEL   With --subject: the report's label (file
#                  layer-<label>-report.md; default modules-report.md).
#   --json         Print the JSON on STDOUT:
#                  {dir, generated_at, layer, layers_generated_at,
#                   edges (all | declared; null with --subject), totals:
#                   {modules, ported, preservation_verified, regressions,
#                    hygiene_errors, undeclared, with_port_record,
#                    rector_reversions, post_port_fixes, preexisting_bugs,
#                    behavior_changes, tooling_deviations},
#                   modules:[{machine, layer, in_cycle, subject, found, stage,
#                             effort, preservation, d10_support, patch,
#                             drupal_root, port_report (the module's
#                             port-report.md: <root>/.drupilot/modules/<machine>/
#                             first, else <root>/.drupilot/),
#                             hygiene:{error,warn,info}|null,
#                             undeclared:[proposed entries]|null,
#                             port:<the port record (port_record_json)>}],
#                   aggregate:{rector_rules:[{rule, hits, modules, reverted,
#                              reverted_in}], rector_reversions, manual_edits,
#                              post_port_fixes, preexisting_bugs,
#                              behavior_changes, tooling_deviations,
#                              test_adaptations (each item + module)}}
#                  With --subject, dir is null and layer is the label.
#   --output DIR   Where to write the markdown (default: the artifacts dir of
#                  DIR, or of the first --subject): layer-<N>-report.md, or
#                  layers-report.md for all.
#   --no-write     Do not write the markdown.
#   -h, --help     Show this help.
#
# Without --json, STDOUT is the path of the markdown written.
# Exit codes: 0 ok · 1 usage error, or no layers.json and layers.sh failed.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DIR=""
LAYER="all"
LAYER_SET=0
AS_JSON=0
OUT=""
WRITE=1
NAME=""
EDGES="all"
EDGES_SET=0
SUBJECTS=()

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="${2:-}"; shift 2 || die "--dir needs a value" 1;;
    --dir=*) DIR="${1#*=}"; shift;;
    --layer) LAYER="${2:-}"; LAYER_SET=1; shift 2 || die "--layer needs a value" 1;;
    --layer=*) LAYER="${1#*=}"; LAYER_SET=1; shift;;
    --subject) [[ -n "${2:-}" ]] || die "--subject needs a value" 1; SUBJECTS+=("$2"); shift 2;;
    --subject=*) SUBJECTS+=("${1#*=}"); shift;;
    --edges) EDGES="${2:-}"; EDGES_SET=1; shift 2 || die "--edges needs a value" 1;;
    --edges=*) EDGES="${1#*=}"; EDGES_SET=1; shift;;
    --name) NAME="${2:-}"; shift 2 || die "--name needs a value" 1;;
    --name=*) NAME="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    --output) OUT="${2:-}"; shift 2 || die "--output needs a value" 1;;
    --output=*) OUT="${1#*=}"; shift;;
    --no-write) WRITE=0; shift;;
    -h|--help) usage; exit 0;;
    *) log_err "Unknown argument: $1"; usage >&2; exit 1;;
  esac
done

have_cmd jq || die "jq is required for layer-report.sh." 1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="$(plugin_root)/templates/layer-report.md.tmpl"
[[ -r "$TPL" ]] || die "Template not found: $TPL" 1

if [[ ${#SUBJECTS[@]} -gt 0 ]]; then
  # --- An explicit set of modules (no layers.json) -------------------------
  [[ -z "$DIR" ]] || die "Use --dir or --subject, not both." 1
  [[ "$LAYER_SET" == "0" ]] || die "--layer works with --dir; label a --subject set with --name." 1
  [[ "$EDGES_SET" == "0" ]] || die "--edges works with --dir (a --subject set has no layers)." 1
  MODS_JSON="[]"
  LIST_ARGS=()
  for s in "${SUBJECTS[@]}"; do
    [[ -d "$s" ]] || die "Subject directory not found: $s" 1
    s="$(cd "$s" && pwd)"
    LIST_ARGS+=(--subject "$s")
    MODS_JSON="$(printf '%s' "$MODS_JSON" | jq -c --arg d "$s" \
      --arg m "$(subject_machine_name "$s" 2>/dev/null || basename "$s")" \
      '. + [{machine: $m, layer: null, in_cycle: false, dir: $d, proposed: null}]')"
  done
  LAYER="${NAME:-selected modules}"
  LAYERS="$(jq -nc --argjson m "$MODS_JSON" '{tool: "layers", root: "", edges: null, generated_at: null, layers: [], modules: $m}')"
  REG="$(bash "$(plugin_root)/scripts/env/state.sh" list "${LIST_ARGS[@]}" --no-next --json 2>/dev/null || printf '{"subjects":[]}')"
  REPORT_DIR=""
  FIRST="${SUBJECTS[0]}"
else
  # --- A layers.json set (layers.sh / /drupilot-layers) ---------------------
  [[ -n "$DIR" ]] || die "Missing --dir DIR (or --subject DIR...)." 1
  [[ -d "$DIR" ]] || die "Directory not found: $DIR" 1
  [[ -z "$NAME" ]] || die "--name labels a --subject set; with --dir the label is the layer." 1
  [[ "$LAYER" == "all" || "$LAYER" =~ ^[0-9]+$ ]] || die "--layer must be a number or 'all': '$LAYER'" 1
  case "$EDGES" in all|declared) ;; *) die "--edges must be 'all' or 'declared' (got '$EDGES')." 1;; esac
  DIR="$(cd "$DIR" && pwd)"
  LJ="$(project_state_path "$DIR")/layers.json"
  [[ "$EDGES" == "declared" ]] && LJ="$(project_state_path "$DIR")/layers-declared.json"
  # A saved file is used only when it was computed with these edges (a file
  # without .edges predates the option and is an all-edges one).
  if [[ -r "$LJ" ]] && jq -e --arg e "$EDGES" '.tool == "layers" and (.edges // "all") == $e' "$LJ" >/dev/null 2>&1; then
    LAYERS="$(jq -c . "$LJ")"
  else
    log_info "No $(basename "$LJ") with $EDGES edges for $DIR: computing the layers (layers.sh --edges $EDGES)."
    LAYERS="$(bash "$HERE/layers.sh" --dir "$DIR" --edges "$EDGES" --json 2>/dev/null)" || die "layers.sh failed for $DIR." 1
  fi
  log_info "Layers: $EDGES edges ($(if [[ "$EDGES" == "all" ]]; then echo "declared + implicit dependencies"; else echo "declared dependencies only"; fi))."
  if [[ "$LAYER" != "all" ]]; then
    printf '%s' "$LAYERS" | jq -e --argjson n "$LAYER" '.layers | any(.index == $n)' >/dev/null \
      || die "Layer $LAYER does not exist (layers 0..$(printf '%s' "$LAYERS" | jq '.layers | length - 1'))." 1
  fi
  # The registry finds a module where it lives now, also after a `move`
  # placement (the record keeps its origin under DIR).
  REG="$(bash "$(plugin_root)/scripts/env/state.sh" list --root "$DIR" --no-next --json 2>/dev/null || printf '{"subjects":[]}')"
  REPORT_DIR="$DIR"
  FIRST="$DIR"
fi

# Per-subject hygiene totals (lint-extension-metadata.sh state file): for every
# registered subject and every module of the set where layers.sh found it (a
# module linted but not assessed yet has no state.json, only its lint record).
HYG="{}"
while IFS= read -r s; do
  [[ -n "$s" ]] || continue
  f="$(project_state_path "$s")/metadata-lint.json"
  [[ -r "$f" ]] || continue
  HYG="$(printf '%s' "$HYG" | jq -c --arg s "$s" --slurpfile h "$f" '. + {($s): ($h[0].totals // null)}' 2>/dev/null || printf '%s' "$HYG")"
done < <({ printf '%s' "$REG" | jq -r '.subjects[]?.subject // empty'
          printf '%s' "$LAYERS" | jq -r '.root as $r | .modules[]? | (if ($r // "") == "" then .dir else $r + "/" + .dir end) // empty'
        } | awk 'NF && !seen[$0]++')

REPORT="$(jq -n --argjson L "$LAYERS" --argjson R "$REG" --argjson H "$HYG" --arg layer "$LAYER" \
  --arg dir "$REPORT_DIR" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  ($R.subjects // []) as $subs
  | [ $L.modules[] | select($L.root == "" or $layer == "all" or (.layer | tostring) == $layer)
      | . as $m
      | (if $L.root == "" then $m.dir else $L.root + "/" + $m.dir end) as $orig
      # The record OF this module: by its path, then by its origin (a placed
      # copy/move) when the record is the same machine, then by machine name.
      # Never by origin alone: a shared test-bed holds several modules.
      | ([$subs[] | select(.subject == $orig)]
         + [$subs[] | select(.origin == $orig and ((.machine_name // $m.machine) == $m.machine))]
         + [$subs[] | select(.machine_name == $m.machine)] | first) as $r
      | {machine, layer, in_cycle, subject: ($r.subject // $orig), found: ($r != null),
         stage: ($r.stage // null), effort: ($r.effort // null),
         preservation: ($r.tests.preservation // null),
         tests_fresh: ($r.tests.fresh // null),
         tests_executed: ($r.tests.executed // null),
         d10_support: ($r.core_matrix.d10_support // null),
         patch: ($r.patch.path // null),
         drupal_root: ($r.drupal_root // null), port_report: null,
         hygiene: ($H[$r.subject // $orig] // $H[$orig] // null),
         undeclared: $m.proposed, port: null} ] as $mods
  | {dir: (if $dir == "" then null else $dir end), generated_at: $at, layer: $layer,
     layers_generated_at: $L.generated_at,
     edges: (if $dir == "" then null else ($L.edges // "all") end), modules: $mods}')"

# Each module's port record (manifest + decision log + Rector rule counts).
while IFS=$'\x1f' read -r i subj; do
  [[ -n "$subj" ]] || continue
  rec="$(port_record_json "$subj" 2>/dev/null || true)"
  printf '%s' "$rec" | jq -e 'type == "object"' >/dev/null 2>&1 || continue
  REPORT="$(printf '%s' "$REPORT" | jq -c --argjson i "$i" --argjson p "$rec" \
    '.modules[$i].port = (if $p.manifest or $p.decisions > 0 or ($p.rector_rules | length) > 0 then $p else null end)')"
done < <(printf '%s' "$REPORT" | jq -r '.modules | to_entries[] | [(.key | tostring), .value.subject] | join("\u001f")')

# The module's port-report.md: the per-module artifacts dir a batch run uses
# (<root>/.drupilot/modules/<machine>/), else the workspace's own .drupilot/.
while IFS=$'\x1f' read -r i mn root; do
  [[ -n "$root" ]] || continue
  for c in "$root/.drupilot/modules/$mn/port-report.md" "$root/.drupilot/port-report.md"; do
    if [[ -f "$c" ]] && grep -q "$mn" "$c" 2>/dev/null; then
      REPORT="$(printf '%s' "$REPORT" | jq -c --argjson i "$i" --arg p "$c" '.modules[$i].port_report = $p')"
      break
    fi
  done
done < <(printf '%s' "$REPORT" | jq -r '.modules | to_entries[] | [(.key | tostring), .value.machine, (.value.drupal_root // "")] | join("\u001f")')

# Totals and the cross-module aggregate (every item tagged with its module).
REPORT="$(printf '%s' "$REPORT" | jq -c '
  def short: tostring | split("\\") | last;
  .modules as $mods
  | ([$mods[] | select(.port != null)]) as $p
  | def tagged(f): [$p[] | .machine as $mn | (.port | f)[]? | . + {module: $mn}];
  .aggregate = {
      rector_rules: (([$p[] | .machine as $mn | .port.rector_rules[]? | . + {module: $mn}]
        | group_by(.rule) | map({rule: .[0].rule,
            hits: (if all(.[]; .hits == null) then null else (map(.hits // 0) | add) end),
            modules: (map(.module) | unique)})) as $rules
        | (tagged(.rector_reversions)) as $rev
        | ($rules + [$rev[] | (.rule | short) as $r | select(all($rules[]; .rule != $r)) | {rule: $r, hits: null, modules: []}]
           | unique_by(.rule)
           | map(.rule as $r | . + {reverted: ([$rev[] | select((.rule | short) == $r)] | length),
                                     reverted_in: ([$rev[] | select((.rule | short) == $r) | .module] | unique)})
           | sort_by(-(.hits // 0), -.reverted, .rule))),
      rector_reversions: tagged(.rector_reversions),
      manual_edits: tagged(.manual_edits),
      post_port_fixes: tagged(.post_port_fixes),
      preexisting_bugs: tagged(.preexisting_bugs),
      behavior_changes: tagged(.behavior_changes),
      tooling_deviations: tagged(.tooling_deviations),
      test_adaptations: tagged(.test_adaptations)}
  | .totals = {modules: ($mods | length),
               ported: ([$mods[] | select((.stage // "") | IN("ported", "refactored", "tested", "contributed"))] | length),
               preservation_verified: ([$mods[] | select(.preservation == "verified")] | length),
               regressions: ([$mods[] | select(.preservation == "regression")] | length),
               hygiene_errors: ([$mods[] | .hygiene.error // 0] | add // 0),
               undeclared: ([$mods[] | .undeclared // [] | length] | add // 0),
               with_port_record: ($p | length),
               rector_reversions: (.aggregate.rector_reversions | length),
               post_port_fixes: (.aggregate.post_port_fixes | length),
               preexisting_bugs: (.aggregate.preexisting_bugs | length),
               behavior_changes: (.aggregate.behavior_changes | length),
               tooling_deviations: (.aggregate.tooling_deviations | length)}
  | {dir, generated_at, layer, layers_generated_at, edges, totals, modules, aggregate}')"

# section <jq program> -> one section's markdown, from the report JSON.
SECT_DIR=""
section() {
  local name="$1" prog="$2"
  printf '%s' "$REPORT" | jq -r "
    def v: if . == null then \"n/a\" else tostring end;
    def cell: if . == null or . == \"\" then \"—\" else tostring | gsub(\"\\\\|\"; \"\\\\|\") | gsub(\"\\r?\\n\"; \"<br>\") end;
    def short: tostring | split(\"\\\\\") | last;
    def code: if . == null or . == \"\" then \"—\" else \"\`\" + cell + \"\`\" end;
    def none: \"_None recorded\" + (if .totals.with_port_record < .totals.modules then \" by the \(.totals.with_port_record) module(s) with a port record\" else \"\" end) + \"._\";
    walk(if type == \"string\" then gsub(\"\\r?\\n\"; \" \") else . end) | $prog" > "$SECT_DIR/$name" || { log_warn "Could not render the $name section."; printf '_unreadable_\n' > "$SECT_DIR/$name"; }
  return 0
}

render_md() {
  SECT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-layer-report.XXXXXX")" || return 1
  section TITLE '"Porting report — \(if .dir == null then .layer elif .layer == "all" then "all layers" else "layer \(.layer)" end)"'
  section GENERATED '"Generated by drupilot on \(.generated_at) for \(if .dir == null then "\(.totals.modules) module(s) given with --subject" else "`\(.dir)` (layers computed \(.layers_generated_at), \(if .edges == "declared" then "**declared dependencies only** (`--edges declared`)" else "declared + implicit dependencies" end))" end). Read from each module'"'"'s own records: the port manifest, the decision log (`decisions.md`), the state registry. `n/a` = not recorded yet."'
  section TOTALS '"**\(.totals.ported)/\(.totals.modules) ported** · preservation verified: \(.totals.preservation_verified) · regressions: \(.totals.regressions) · reverted Rector changes: \(.totals.rector_reversions) · post-port fixes: \(.totals.post_port_fixes) · behavior changes to review: \(.totals.behavior_changes) · pre-existing hygiene errors: \(.totals.hygiene_errors) · undeclared dependencies: \(if .dir == null then "n/a" else .totals.undeclared end)"'
  section MODULE_RESULTS '
    "| Layer | Module | Stage | Effort | Preservation | Drupal 10 | Hygiene (e/w/i) | Undeclared deps | Rector files | Reverted | Post-port fixes | Patch | Report |",
    "|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    (.modules[] | "| \(.layer | v) | `\(.machine)`\(if .in_cycle then " (cycle)" else "" end)\(if .found then "" else " (no record)" end) | \(.stage | v) | \(.effort | v) | \(.preservation | v)\(if .tests_fresh == false then " (stale)" else "" end) | \(.d10_support | v) | \(if .hygiene then "\(.hygiene.error)/\(.hygiene.warn)/\(.hygiene.info)" else "n/a" end) | \(if .undeclared == null then "n/a" elif (.undeclared | length) > 0 then (.undeclared | map("`" + . + "`") | join(", ")) else "none" end) | \(.port.rector_files | v) | \(if .port then (.port.rector_reversions | length) else "n/a" end) | \(if .port then (.port.post_port_fixes | length) else "n/a" end) | \(if .patch then "`" + (.patch | split("/") | last) + "`" else "n/a" end) | \(if .port_report then "[port-report](" + .port_report + ")" else "n/a" end) |"),
    "",
    "Per-module detail: `port-report.md` in each workspace'"'"'s `.drupilot/`, `decisions.md` beside it, and `state.sh show --subject <dir>`."'
  section RECTOR_RULES '
    if (.aggregate.rector_rules | length) == 0 then none
    else
      "_Hits = files a rule changed (Rector'"'"'s \"Applied rules\"), summed over the modules; reverted = changes undone by hand, each with its reason below. A rule reverted again and again is a candidate for the project'"'"'s Rector skip list._\n",
      "| Rule | Files changed | Modules | Reverted | Reverted in |", "|---|---|---|---|---|",
      (.aggregate.rector_rules[] | "| `\(.rule)` | \(.hits | v) | \(.modules | length) | \(.reverted) | \(if (.reverted_in | length) > 0 then (.reverted_in | map("`" + . + "`") | join(", ")) else "—" end) |"),
      (if (.aggregate.rector_reversions | length) > 0 then
         "\n**Reversions:**\n",
         (.aggregate.rector_reversions[] | "- `\(.module)` — `\(.rule | short)`\(if (.file // "") != "" then " in `\(.file)`" else "" end): \(.why // .what // "reason not recorded")")
       else empty end)
    end'
  section MANUAL_CHANGES '
    if (.aggregate.manual_edits | length) == 0 then none
    else (.aggregate.manual_edits[] | "- `\(.module)` — \(.edit)\(if (.why // "") != "" then " — _why:_ \(.why)" else "" end)\(if (.change_record // "") != "" then " ([change record](\(.change_record)))" else "" end)")
    end'
  section POST_PORT_FIXES '
    if (.aggregate.post_port_fixes | length) == 0 then none
    else "| Module | Fix | File | Why | Found by |", "|---|---|---|---|---|",
         (.aggregate.post_port_fixes[] | "| `\(.module)` | \(.fix | cell) | \(.file | code) | \(.why | cell) | \(.detected_by | cell) |")
    end'
  section PREEXISTING_BUGS '
    if (.aggregate.preexisting_bugs | length) == 0 then none
    else "| Module | Issue | File | Note |", "|---|---|---|---|",
         (.aggregate.preexisting_bugs[] | "| `\(.module)` | \(.issue | cell) | \(.file | code) | \(.note | cell) |")
    end'
  section BEHAVIOR_CHANGES '
    if (.aggregate.behavior_changes | length) == 0 then none
    else "| Module | Change | Why | How to review |", "|---|---|---|---|",
         (.aggregate.behavior_changes[] | "| `\(.module)` | \(.change | cell)\(if (.file // "") != "" then " (`\(.file)`)" else "" end) | \(.why | cell) | \(.review_hint | cell) |")
    end'
  section DEVIATIONS '
    if (.aggregate.tooling_deviations | length) == 0 then none
    else "| Module | What | Kind | Why |", "|---|---|---|---|",
         (.aggregate.tooling_deviations[] | "| `\(.module)` | \(.what | cell) | \(.kind // "manifest" | cell)\(if (.script // "") != "" then " (`\(.script)`)" else "" end) | \(.why | cell) |")
    end'
  section VALIDATION '
    (.modules[] | . as $m
      | "- `\(.machine)` — preservation **\(.preservation | v)**\(if .tests_executed != null then " (\(.tests_executed) test(s) executed)" else "" end)\(if .tests_fresh == false then ", stale" else "" end); Drupal 10: \(.d10_support | v)"
        + (if .port == null then "; no port record" else "" end),
        ((.port.validation // [])[] | "    - \(.)"),
        (if ((.port.test_adaptations // []) | length) > 0 then "    - test adaptations (form only): " + ([.port.test_adaptations[] | .what] | join("; ")) else empty end))'
  section NOTES '
    ([.modules[] | select(.port == null) | .machine]) as $missing
    | (if .totals.regressions > 0 then "\n**A regression blocks the next layer**: fix it in the module'"'"'s code before porting the modules that depend on it." else empty end),
      (if .totals.undeclared > 0 then "\nUndeclared dependencies are reported, never added automatically: review the proposed `dependencies:` entries (see layers.md)." else empty end),
      (if ($missing | length) > 0 then "\nNo port record (manifest or decision log) yet for: " + ($missing | map("`" + . + "`") | join(", ")) + ". Their sections above stay empty until they are ported." else empty end)'
  local rc=0
  render_template_files "$TPL" "$1" \
    "TITLE=$SECT_DIR/TITLE" "GENERATED=$SECT_DIR/GENERATED" "TOTALS=$SECT_DIR/TOTALS" \
    "MODULE_RESULTS=$SECT_DIR/MODULE_RESULTS" "RECTOR_RULES=$SECT_DIR/RECTOR_RULES" \
    "MANUAL_CHANGES=$SECT_DIR/MANUAL_CHANGES" "POST_PORT_FIXES=$SECT_DIR/POST_PORT_FIXES" \
    "PREEXISTING_BUGS=$SECT_DIR/PREEXISTING_BUGS" "BEHAVIOR_CHANGES=$SECT_DIR/BEHAVIOR_CHANGES" \
    "DEVIATIONS=$SECT_DIR/DEVIATIONS" "VALIDATION=$SECT_DIR/VALIDATION" "NOTES=$SECT_DIR/NOTES" || rc=1
  rm -rf "${SECT_DIR:?}"
  return "$rc"
}

MD=""
if [[ "$WRITE" == "1" ]]; then
  [[ -n "$OUT" ]] || OUT="$(project_artifacts_dir "$FIRST")"
  mkdir -p "$OUT" 2>/dev/null || die "Cannot create $OUT" 1
  OUT="$(cd "$OUT" && pwd)"
  if [[ -z "$REPORT_DIR" ]]; then
    if [[ -n "$NAME" ]]; then
      MD="$OUT/layer-$(lc "$NAME" | tr -c 'a-z0-9.-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')-report.md"
    else
      MD="$OUT/modules-report.md"
    fi
  elif [[ "$LAYER" == "all" ]]; then MD="$OUT/layers-report.md"
  else MD="$OUT/layer-$LAYER-report.md"; fi
  render_md "$MD" || die "Could not write $MD." 1
  log_ok "Layer report written: $MD"
fi
printf '%s' "$REPORT" | jq -r '"\(.totals.ported)/\(.totals.modules) module(s) ported · preservation verified \(.totals.preservation_verified) · regressions \(.totals.regressions) · reverted Rector changes \(.totals.rector_reversions) · post-port fixes \(.totals.post_port_fixes)"' >&2

if [[ "$AS_JSON" == "1" ]]; then
  printf '%s\n' "$REPORT"
elif [[ -n "$MD" ]]; then
  printf '%s\n' "$MD"
fi
exit 0
