#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/layers.sh
# Porting LAYERS for a set of custom extensions (a monorepo's
# web/modules/custom, a folder of modules): reads every *.info.yml
# `dependencies:` and composer.json `require` (drupal/*), adds the IMPLICIT
# dependencies found in the code (classes, services, routes, libraries,
# plugins and config dependencies of other modules — see scripts/lib/ext-scan.sh),
# and orders the extensions topologically: layer 0 depends on nothing in the
# set, layer N only on layers < N. A dependency cycle is kept together as one
# group in a single layer. Undeclared dependencies get a proposed
# `dependencies:` line (`<project>:<module>` for one of the set, `drupal:<module>`
# for core, `<module>:<module>` for contrib — verify the project name).
# Read-only on the code: it never edits an info.yml.
#
# Usage:
#   layers.sh --dir DIR [--json] [--edges all|declared] [--core-dir PATH]
#             [--dot] [--no-write] [-h|--help]
#
# Options:
#   --dir DIR        Directory holding the extensions (searched recursively;
#                    vendor/, contrib/, core and tests/ are skipped). Required.
#   --json           Print the JSON report on STDOUT (default: a one-line
#                    `layer<TAB>module` list).
#   --edges MODE     Edges that order the layers: `all` (declared + implicit,
#                    default — an undeclared use still has to be ported first)
#                    or `declared` (info.yml + composer.json only).
#   --core-dir PATH  A Drupal core directory (with modules/) to tell core
#                    modules apart (default: the core of the Drupal root above
#                    DIR, else a built-in list).
#   --dot            Print a Graphviz digraph on STDOUT instead.
#   --no-write       Do not save layers.json / layers.md.
#   -h, --help       Show this help.
#
# JSON (--json):
#   {tool, root, edges, generated_at, totals:{modules, layers, cycles,
#    undeclared, undeclared_modules},
#    layers:[{index, modules:[...], cycle_groups:[[...]]}],
#    cycles:[[...]],
#    early:[{module, layer, declared_layer}]   (would be ported too early if
#                                               only declared deps counted),
#    modules:[{machine, type, dir, parent, project, layer, in_cycle,
#              core_version_requirement, depends_on:[...], declared:[...],
#              implicit:[...], undeclared:[...], proposed:[...]}],
#    external:[{module, scope, required_by:[...]}]}
#
# Files: the JSON is saved to <state dir of DIR>/layers.json (machine state)
# and a rendered table to <artifacts dir>/layers.md (the visible, self-ignored
# .drupilot/ of the Drupal root above DIR, else of DIR).
#
# Exit codes: 0 ok (cycles and undeclared dependencies are data) · 1 usage
# error or no extension found.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/ext-scan.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/ext-scan.sh"

DIR=""
AS_JSON=0
EDGES="all"
CORE_DIR=""
AS_DOT=0
WRITE=1

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="${2:-}"; shift 2 || die "--dir needs a value" 1;;
    --dir=*) DIR="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    --edges) EDGES="${2:-}"; shift 2 || die "--edges needs a value" 1;;
    --edges=*) EDGES="${1#*=}"; shift;;
    --core-dir) CORE_DIR="${2:-}"; shift 2 || die "--core-dir needs a value" 1;;
    --core-dir=*) CORE_DIR="${1#*=}"; shift;;
    --dot) AS_DOT=1; shift;;
    --no-write) WRITE=0; shift;;
    -h|--help) usage; exit 0;;
    *) log_err "Unknown argument: $1"; usage >&2; exit 1;;
  esac
done

[[ -n "$DIR" ]] || die "Missing --dir DIR (the directory holding the extensions)." 1
case "$DIR" in *"<"*">"*) die "--dir looks like an unsubstituted placeholder: '$DIR'." 1;; esac
[[ -d "$DIR" ]] || die "Directory not found: $DIR" 1
case "$EDGES" in all|declared) ;; *) die "--edges must be 'all' or 'declared' (got '$EDGES')." 1;; esac
have_cmd jq || die "jq is required for layers.sh." 1
DIR="$(cd "$DIR" && pwd)"

if [[ -z "$CORE_DIR" ]]; then
  root="$(find_drupal_root "$DIR" 2>/dev/null || true)"
  if [[ -n "$root" ]]; then
    for c in "$root/web/core" "$root/docroot/core" "$root/core"; do
      if [[ -f "$c/lib/Drupal.php" ]]; then CORE_DIR="$c"; break; fi
    done
  fi
fi
[[ -n "$CORE_DIR" ]] && export EXTSCAN_CORE_DIR="$CORE_DIR"

log_step "Scanning extensions under $DIR"
SCAN="$(ext_scan_json "$DIR")" || die "The extension scan failed." 1
N="$(printf '%s' "$SCAN" | jq '.extensions | length')"
[[ "$N" -gt 0 ]] || die "No *.info.yml found under $DIR (tests/, vendor/, contrib/ and core are skipped)." 1

# Graph -> layers. The closure is a fixpoint over the (small) adjacency map;
# strongly connected components are the mutually reachable nodes; a component's
# layer is 0 without dependencies, else 1 + the deepest dependency's layer.
REPORT="$(printf '%s' "$SCAN" | jq --arg edges "$EDGES" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  def closure:
    def step: . as $r | with_entries(.value = ((.value + [.value[] | ($r[.] // [])[]]) | unique));
    def loop: step as $n | if $n == . then . else ($n | loop) end;
    loop;
  # layering($g) -> {node: {layer, comp}}
  def layering($g):
    ($g | closure) as $R
    | ($g | keys) as $nodes
    | ($nodes | map({key: ., value: ([.] + [. as $a | $R[$a][] | select(($R[.] // []) | index($a))] | unique)}) | from_entries) as $comp
    | ($comp | to_entries | map({key: (.value | join(",")), value: .value}) | from_entries) as $comps
    | ($comps | with_entries(.value as $m
        | .value = ([$m[] | $g[.][]] | unique | map(select(. as $x | ($m | index($x)) == null)) | map($comp[.] | join(",")) | unique))) as $cd
    | ($cd | with_entries(.value = 0)
       | until(. as $L | ($cd | with_entries(.value = (if (.value | length) == 0 then 0 else ([.value[] | $L[.]] | max + 1) end))) == $L;
               . as $L | $cd | with_entries(.value = (if (.value | length) == 0 then 0 else ([.value[] | $L[.]] | max + 1) end)))) as $L
    | $nodes | map({key: ., value: {layer: $L[$comp[.] | join(",")], comp: $comp[.]}}) | from_entries;
  . as $s
  | ($s.extensions | map(.machine)) as $set
  | ($s.extensions | map(. as $e | {key: .machine, value: (
        [.declared[] | .module] | unique | map(select(. as $x | ($set | index($x)) != null and $x != $e.machine)))}) | from_entries) as $gd
  | ($s.extensions | map(. as $e | {key: .machine, value: (
        ($gd[.machine] + [.implicit[] | select((.optional | not) and .scope == "internal") | .target]
         | unique | map(select(. as $x | ($set | index($x)) != null and $x != $e.machine))))}) | from_entries) as $ga
  | (if $edges == "declared" then $gd else $ga end) as $g
  | layering($g) as $lay
  | layering($gd) as $layd
  | ([$lay | to_entries[] | select((.value.comp | length) > 1) | .value.comp] | unique) as $cycles
  | ([$lay[] | .layer] | max // -1) as $maxl
  | {tool: "layers", root: $s.root, edges: $edges, generated_at: $at,
     layers: [range(0; $maxl + 1) as $i
       | {index: $i,
          modules: ([$lay | to_entries[] | select(.value.layer == $i) | .key] | sort),
          cycle_groups: [$cycles[] | select($lay[.[0]].layer == $i)]}],
     cycles: $cycles,
     early: ([$s.extensions[] | .machine as $m
       | select($layd[$m].layer < $lay[$m].layer)
       | {module: $m, layer: $lay[$m].layer, declared_layer: $layd[$m].layer}]),
     modules: [$s.extensions[] | . as $e
       | {machine, type, name, dir, parent, project, layer: $lay[.machine].layer,
          in_cycle: (($lay[.machine].comp | length) > 1),
          core_version_requirement, depends_on: $g[.machine],
          declared, implicit, undeclared, proposed}],
     external: ([$s.extensions[] | .machine as $m
         | ((.implicit[] | select(.scope != "internal" and (.optional | not)) | {module: .target, scope}),
            (.declared[] | select(.module as $x | ($set | index($x)) == null) | {module: .module, scope}))
         | . + {by: $m}]
       | group_by(.module)
       | map({module: .[0].module,
              scope: .[0].scope,
              required_by: ([.[].by] | unique)})
       | map(select(.module != "drupal" and .module != "core"))),
     totals: {}}
  | .totals = {modules: (.modules | length), layers: (.layers | length),
               cycles: (.cycles | length),
               undeclared: ([.modules[].undeclared | length] | add // 0),
               undeclared_modules: ([.modules[] | select((.undeclared | length) > 0)] | length)}')" \
  || die "Could not compute the layers." 1

# --- Save --------------------------------------------------------------------
render_md() {
  printf '%s' "$REPORT" | jq -r '
    "# Porting layers\n",
    "> Generated by drupilot on \(.generated_at) for `\(.root)` (edges: `\(.edges)`).",
    "> Port layer 0 first; a layer only depends on the layers before it. Modules in",
    "> a cycle are ported together.\n",
    "| Layer | Modules |", "|---|---|",
    (.layers[] | "| \(.index) | \([.modules[] as $m | if ([.cycle_groups[][]] | index($m)) != null then "`\($m)` (cycle)" else "`\($m)`" end] | join(", ")) |"),
    "",
    (if (.cycles | length) > 0 then
       "## Dependency cycles\n",
       (.cycles[] | "- " + (map("`\(.)`") | join(" <-> "))),
       "\nBreak a cycle by moving the shared code into a module both can depend on, or port the group together.\n"
     else empty end),
    (if (.early | length) > 0 then
       "## Ordered by undeclared dependencies\n",
       "Ordered by its declared dependencies alone, each of these would be ported too early:\n",
       (.early[] | "- `\(.module)`: layer \(.layer) (declared dependencies alone: layer \(.declared_layer))"),
       ""
     else empty end),
    "## Undeclared dependencies\n",
    (if .totals.undeclared == 0 then "None found.\n" else
      "| Module | Uses | Scope | How | Proposed `dependencies:` entry | Evidence |",
      "|---|---|---|---|---|---|",
      (.modules[] | .machine as $m | .undeclared[]
        | "| `\($m)` | `\(.target)` | \({"internal": "project", "external": "contrib"}[.scope] // .scope)\(if .declared_via == "composer" then " (composer.json only)" else "" end) | \(.kinds | join(", ")) | `- \(.proposed)`\(if .verify_project then " (verify the project name)" else "" end) | \(.evidence[0] // "") |"),
      ""
    end),
    (if (.external | length) > 0 then
       "## Outside the set\n",
       "| Module | Kind | Needed by |", "|---|---|---|",
       (.external[] | "| `\(.module)` | \({"external": "contrib"}[.scope] // .scope) | \(.required_by | map("`\(.)`") | join(", ")) |"),
       ""
     else empty end)'
}

if [[ "$WRITE" == "1" ]]; then
  sd="$(project_state_dir "$DIR")"
  printf '%s\n' "$REPORT" > "$sd/layers.json" 2>/dev/null || log_warn "Could not write $sd/layers.json"
  ad="$(project_artifacts_dir "$DIR")"
  render_md > "$ad/layers.md" 2>/dev/null || log_warn "Could not write $ad/layers.md"
fi

# --- Human summary (STDERR) --------------------------------------------------
hr
log_plain "Porting layers — $(printf '%s' "$REPORT" | jq -r '"\(.totals.modules) extension(s), \(.totals.layers) layer(s), edges: \(.edges)"')"
hr
printf '%s' "$REPORT" | jq -r '.layers[] | "  Layer \(.index): \(.modules | join(", "))\(if (.cycle_groups | length) > 0 then "   [cycle: " + (.cycle_groups | map(join(" <-> ")) | join("; ")) + "]" else "" end)"' >&2
CYC="$(printf '%s' "$REPORT" | jq '.totals.cycles')"
UND="$(printf '%s' "$REPORT" | jq '.totals.undeclared')"
[[ "$CYC" -gt 0 ]] && log_warn "$CYC dependency cycle(s): those modules are ported together in one layer."
if [[ "$UND" -gt 0 ]]; then
  log_warn "$UND undeclared dependency(ies) in $(printf '%s' "$REPORT" | jq '.totals.undeclared_modules') module(s) (proposed entries below; review, never applied automatically):"
  printf '%s' "$REPORT" | jq -r '.modules[] | .machine as $m | .undeclared[] | "    \($m): - \(.proposed)\(if .verify_project then "   (verify the project name)" else "" end)   [\(.kinds | join(","))] \(.evidence[0] // "")"' >&2
fi
printf '%s' "$REPORT" | jq -r '.early[] | "  ⚠  \(.module): layer \(.layer), but \(.declared_layer) by its declared dependencies alone (it would be ported too early)."' >&2
if [[ "$WRITE" == "1" ]]; then
  log_info "Saved: $(project_state_dir "$DIR")/layers.json · $(project_artifacts_dir "$DIR")/layers.md"
fi

# --- STDOUT payload ----------------------------------------------------------
if [[ "$AS_DOT" == "1" ]]; then
  printf '%s' "$REPORT" | jq -r '
    "digraph layers {", "  rankdir=BT;", "  node [shape=box];",
    (.layers[] | "  { rank=same; " + (.modules | map("\"\(.)\"") | join("; ")) + "; }"),
    (.modules[] | .machine as $m | (.declared | map(.module)) as $d | .depends_on[]
      | "  \"\($m)\" -> \"\(.)\"" + (. as $t | if ($d | index($t)) != null then ";" else " [style=dashed, color=red, label=\"undeclared\"];" end)),
    "}"'
elif [[ "$AS_JSON" == "1" ]]; then
  printf '%s\n' "$REPORT"
else
  printf '%s' "$REPORT" | jq -r '.layers[] | .index as $i | .modules[] | "\($i)\t\(.)"'
fi
exit 0
