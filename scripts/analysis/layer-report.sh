#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/layer-report.sh
# The CONSOLIDATED report of a /drupilot-layers run: one row per module of a
# porting layer (or of every layer) with what each module's own records say —
# stage reached, effort, preservation verdict, Drupal 10 verdict, patch,
# pre-existing metadata hygiene and the undeclared dependencies layers.sh
# found — so a layer is reviewed at a glance instead of module by module.
# Read-only on the code; it reads layers.json (layers.sh) and the per-module
# state registry (state.sh list), and never invents a value ("n/a").
#
# Usage:
#   layer-report.sh --dir DIR [--layer N|all] [--json] [--output DIR]
#                   [--no-write] [-h|--help]
#
# Options:
#   --dir DIR      The set given to layers.sh / /drupilot-layers. Required.
#   --layer N      One layer (default: all layers).
#   --json         Print the JSON on STDOUT:
#                  {dir, generated_at, layer, layers_generated_at, totals:
#                   {modules, ported, preservation_verified, regressions,
#                    hygiene_errors, undeclared},
#                   modules:[{machine, layer, in_cycle, subject, found, stage,
#                             effort, preservation, d10_support, patch,
#                             drupal_root, port_report (the module's
#                             port-report.md: <root>/.drupilot/modules/<machine>/
#                             first, else <root>/.drupilot/),
#                             hygiene:{error,warn,info}|null,
#                             undeclared:[proposed entries]}]}
#   --output DIR   Where to write the markdown (default: the artifacts dir of
#                  DIR): layer-<N>-report.md, or layers-report.md for all.
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
AS_JSON=0
OUT=""
WRITE=1

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="${2:-}"; shift 2 || die "--dir needs a value" 1;;
    --dir=*) DIR="${1#*=}"; shift;;
    --layer) LAYER="${2:-}"; shift 2 || die "--layer needs a value" 1;;
    --layer=*) LAYER="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    --output) OUT="${2:-}"; shift 2 || die "--output needs a value" 1;;
    --output=*) OUT="${1#*=}"; shift;;
    --no-write) WRITE=0; shift;;
    -h|--help) usage; exit 0;;
    *) log_err "Unknown argument: $1"; usage >&2; exit 1;;
  esac
done

[[ -n "$DIR" ]] || die "Missing --dir DIR." 1
[[ -d "$DIR" ]] || die "Directory not found: $DIR" 1
[[ "$LAYER" == "all" || "$LAYER" =~ ^[0-9]+$ ]] || die "--layer must be a number or 'all': '$LAYER'" 1
have_cmd jq || die "jq is required for layer-report.sh." 1
DIR="$(cd "$DIR" && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LJ="$(project_state_path "$DIR")/layers.json"
if [[ -r "$LJ" ]] && jq -e '.tool == "layers"' "$LJ" >/dev/null 2>&1; then
  LAYERS="$(jq -c . "$LJ")"
else
  log_info "No layers.json for $DIR yet: computing the layers (layers.sh)."
  LAYERS="$(bash "$HERE/layers.sh" --dir "$DIR" --json 2>/dev/null)" || die "layers.sh failed for $DIR." 1
fi
if [[ "$LAYER" != "all" ]]; then
  printf '%s' "$LAYERS" | jq -e --argjson n "$LAYER" '.layers | any(.index == $n)' >/dev/null \
    || die "Layer $LAYER does not exist (layers 0..$(printf '%s' "$LAYERS" | jq '.layers | length - 1'))." 1
fi

# The registry finds a module where it lives now, also after a `move`
# placement (the record keeps its origin under DIR).
REG="$(bash "$(plugin_root)/scripts/env/state.sh" list --root "$DIR" --no-next --json 2>/dev/null || printf '{"subjects":[]}')"

# Per-subject hygiene totals (lint-extension-metadata.sh state file).
HYG="{}"
while IFS= read -r s; do
  [[ -n "$s" ]] || continue
  f="$(project_state_path "$s")/metadata-lint.json"
  [[ -r "$f" ]] || continue
  HYG="$(printf '%s' "$HYG" | jq -c --arg s "$s" --slurpfile h "$f" '. + {($s): ($h[0].totals // null)}' 2>/dev/null || printf '%s' "$HYG")"
done < <(printf '%s' "$REG" | jq -r '.subjects[]?.subject // empty')

REPORT="$(jq -n --argjson L "$LAYERS" --argjson R "$REG" --argjson H "$HYG" --arg layer "$LAYER" \
  --arg dir "$DIR" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  ($R.subjects // []) as $subs
  | [ $L.modules[] | select($layer == "all" or (.layer | tostring) == $layer)
      | . as $m
      | ($L.root + "/" + $m.dir) as $orig
      | ([$subs[] | select(.subject == $orig or .origin == $orig)] + [$subs[] | select(.machine_name == $m.machine)] | first) as $r
      | {machine, layer, in_cycle, subject: ($r.subject // $orig), found: ($r != null),
         stage: ($r.stage // null), effort: ($r.effort // null),
         preservation: ($r.tests.preservation // null),
         tests_fresh: ($r.tests.fresh // null),
         d10_support: ($r.core_matrix.d10_support // null),
         patch: ($r.patch.path // null),
         drupal_root: ($r.drupal_root // null), port_report: null,
         hygiene: ($H[$r.subject // ""] // null),
         undeclared: $m.proposed} ] as $mods
  | {dir: $dir, generated_at: $at, layer: $layer, layers_generated_at: $L.generated_at,
     totals: {modules: ($mods | length),
              ported: ([$mods[] | select((.stage // "") | IN("ported", "refactored", "tested", "contributed"))] | length),
              preservation_verified: ([$mods[] | select(.preservation == "verified")] | length),
              regressions: ([$mods[] | select(.preservation == "regression")] | length),
              hygiene_errors: ([$mods[] | .hygiene.error // 0] | add // 0),
              undeclared: ([$mods[] | .undeclared | length] | add // 0)},
     modules: $mods}')"

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

render_md() {
  printf '%s' "$REPORT" | jq -r '
    def v: if . == null then "n/a" else tostring end;
    "# Porting report — \(if .layer == "all" then "all layers" else "layer \(.layer)" end)\n",
    "> Generated by drupilot on \(.generated_at) for `\(.dir)` (layers computed \(.layers_generated_at)). Read from each module'"'"'s own records; `n/a` = not recorded yet.\n",
    "**\(.totals.ported)/\(.totals.modules) ported** · preservation verified: \(.totals.preservation_verified) · regressions: \(.totals.regressions) · pre-existing hygiene errors: \(.totals.hygiene_errors) · undeclared dependencies: \(.totals.undeclared)\n",
    "| Layer | Module | Stage | Effort | Preservation | Drupal 10 | Hygiene (e/w/i) | Undeclared deps | Patch | Report |",
    "|---|---|---|---|---|---|---|---|---|---|",
    (.modules[] | "| \(.layer) | `\(.machine)`\(if .in_cycle then " (cycle)" else "" end)\(if .found then "" else " (no record)" end) | \(.stage | v) | \(.effort | v) | \(.preservation | v)\(if .tests_fresh == false then " (stale)" else "" end) | \(.d10_support | v) | \(if .hygiene then "\(.hygiene.error)/\(.hygiene.warn)/\(.hygiene.info)" else "n/a" end) | \(if (.undeclared | length) > 0 then (.undeclared | map("`" + . + "`") | join(", ")) else "none" end) | \(if .patch then "`" + (.patch | split("/") | last) + "`" else "n/a" end) | \(if .port_report then "[port-report](" + .port_report + ")" else "n/a" end) |"),
    "",
    "Per-module detail: `port-report.md` in each workspace'"'"'s `.drupilot/`, and `state.sh show --subject <dir>`.",
    (if .totals.regressions > 0 then "\n**A regression blocks the next layer**: fix it in the module'"'"'s code before porting the modules that depend on it." else empty end),
    (if .totals.undeclared > 0 then "\nUndeclared dependencies are reported, never added automatically: review the proposed `dependencies:` entries (see layers.md)." else empty end)'
}

MD=""
if [[ "$WRITE" == "1" ]]; then
  [[ -n "$OUT" ]] || OUT="$(project_artifacts_dir "$DIR")"
  mkdir -p "$OUT" 2>/dev/null || die "Cannot create $OUT" 1
  if [[ "$LAYER" == "all" ]]; then MD="$OUT/layers-report.md"; else MD="$OUT/layer-$LAYER-report.md"; fi
  render_md > "$MD"
  log_ok "Layer report written: $MD"
fi
printf '%s' "$REPORT" | jq -r '"\(.totals.ported)/\(.totals.modules) module(s) ported · preservation verified \(.totals.preservation_verified) · regressions \(.totals.regressions)"' >&2

if [[ "$AS_JSON" == "1" ]]; then
  printf '%s\n' "$REPORT"
elif [[ -n "$MD" ]]; then
  printf '%s\n' "$MD"
fi
exit 0
