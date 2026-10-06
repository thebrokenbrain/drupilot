#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/dev/gen-recipes.sh
# Generate config/recipes.json (drupilot.recipes/1, AR-11, ADR 0023) from the
# catalogs, the one source of truth (CC-33): config/deprecations.json
# (deprecations, signature_changes, lifecycle), config/port-checks.json
# (checks) and config/metadata-checks.json (checks). A developer tool: the
# `data` gate of scripts/dev/check.sh runs --check, so the generated file is
# never edited by hand.
#
#   dep.<slug>     a deprecations entry (not a [tag] explainer): ai-templated,
#                  matches its pattern (case-insensitive ERE) and the symbols
#                  of the lifecycle entries the pattern matches
#   sig.<id>       a signature_changes entry: matches rule signature:<id>
#   safety.<check> a port-checks check: matches rule port-safety:<check>; its
#                  template is the [<check>] explainer of deprecations.json
#   meta.<check>   a metadata check: matches rule metadata:<check>
#   life.<symbol>  a lifecycle entry no deprecations pattern matches
#
# An entry's optional `recipe` block sets the lane, the engine (ere-replace,
# yaml-edit, info-yml, attributes, php-script, rector-rule; default template),
# its params, applies_when and postconditions. `version` is the first 12 hex
# of the sha256 of the recipe without version, source and fixtures, so it
# changes exactly when the recipe does. A codemod of a Docker-free engine
# must have its fixtures in tests/fixtures/recipes/<id>/ (expect.json,
# before/, after/).
#
# Usage:
#   scripts/dev/gen-recipes.sh [--check | --write] [--json] [-h|--help]
#     --check   compare config/recipes.json with a fresh generation (the
#               default); write nothing
#     --write   (re)write config/recipes.json
#     --json    {ok, mode, drift, recipes, by_lane, by_engine, problems} on
#               STDOUT
#
# Requires bash >= 3.2, jq and sha256sum or shasum. Exit codes: 0 generated or
# no drift · 1 drift, an invalid catalog entry or a usage error.
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="check"; AS_JSON=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift;;
    --write) MODE="write"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
have_cmd jq || die "jq is required by scripts/dev/gen-recipes.sh" 1
[[ -n "$(printf 'x' | sha256_hex)" ]] || die "gen-recipes.sh needs sha256sum or shasum" 1

DEP="config/deprecations.json"; PC="config/port-checks.json"; MC="config/metadata-checks.json"
OUT="config/recipes.json"; FIX="tests/fixtures/recipes"
for f in "$DEP" "$PC" "$MC"; do jq empty "$REPO/$f" 2> /dev/null || die "$f is missing or not JSON." 1; done
TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-recipes.XXXXXX")"
trap 'rm -rf "$TMP" 2> /dev/null || true' EXIT

# The recipes, without version and fixtures.
jq -n --slurpfile dep "$REPO/$DEP" --slurpfile pc "$REPO/$PC" --slurpfile mc "$REPO/$MC" \
  --arg DEP_PATH "$DEP" --arg PC_PATH "$PC" --arg MC_PATH "$MC" '
  ($dep[0].change_records_search // "") as $cr
  | def slug: ascii_downcase | gsub("[^a-z0-9]+"; "-") | sub("^-+"; "") | sub("-+$"; "");
    def crurl($s): if $cr == "" or $s == null then null else $cr + ($s | @uri) end;
    def istag: (.pattern // "") | startswith("\\[");
    def drop_nulls: with_entries(select(.value != null));
    # The recipe of a catalog entry: its recipe block over the defaults.
    def recipe($id; $lane; $matches; $template; $src; $rule):
      (.recipe // {}) as $r
      | ($r.engine // "template") as $eng
      | {id: $id,
         lane: ($r.lane // $lane),
         kind: (if $eng == "template" then "template" else "codemod" end),
         engine: $eng,
         matches: $matches,
         applies_when: ($r.applies_when // {}),
         params: ($r.params // null),
         template: $template,
         postconditions: ($r.postconditions // (
           if $eng == "ere-replace" then [{type: "absent-ere", where: ($r.params.scope // "line"), ere: ($r.params.search // "")}]
           elif $eng == "yaml-edit" then [{type: "absent-fixed", where: "line", text: "{from}"}, {type: "present-fixed", where: "line", text: "{to}"}]
           else [{type: "rescan"}] end)),
         source: $src}
      | drop_nulls;
    ($dep[0].deprecations // []) as $deps
    | ($dep[0].lifecycle // []) as $life
    | def lifeof($pat): [$life[] | select((.symbol | test($pat; "i")) or ((.symbol + "()") | test($pat; "i")))
        | {symbol, kind, deprecated_in, removed_in, replacement, replacement_since} | drop_nulls];
    ([$deps[] | select(istag | not) | .pattern]) as $plain
    | [ ($deps | to_entries[] | select(.value | istag | not) | .key as $i | .value
          | lifeof(.pattern) as $lc
          | recipe("dep." + (.symbol | slug); "ai-templated";
              ({message_ere: .pattern} + (if ($lc | length) > 0 then {symbols: [$lc[].symbol]} else {} end));
              ({why, fix, category, change_record_search_url: crurl(.symbol)}
                + (if ($lc | length) > 0 then {lifecycle: $lc} else {} end) | drop_nulls);
              "\($DEP_PATH)#/deprecations/\($i)"; null)),
        (($dep[0].signature_changes // []) | to_entries[] | .key as $i | .value
          | recipe("sig." + .id; "ai-templated"; {rule: ("signature:" + .id)};
              ({why, fix, d10_compat, since, change_record_search_url: crurl(.symbol)} | drop_nulls);
              "\($DEP_PATH)#/signature_changes/\($i)"; null)),
        (($pc[0].checks // {}) | to_entries[] | .key as $c | .value
          | (("[" + $c + "]") as $tag | [$deps[] | select(istag) | select(.pattern as $p | $tag | test($p; "i"))] | .[0]) as $ex
          | recipe("safety." + $c; "ai-templated"; {rule: ("port-safety:" + $c)};
              (if $ex then {why: $ex.why, fix: $ex.fix, change_record_search_url: crurl($ex.symbol)} else {why: .description} end | drop_nulls);
              "\($PC_PATH)#/checks/\($c)"; null)),
        (($mc[0].checks // {}) | to_entries[] | .key as $c | .value
          | recipe("meta." + $c; (.lane // "human"); {rule: ("metadata:" + $c)}; {why: .description};
              "\($MC_PATH)#/checks/\($c)"; null)),
        ($life | to_entries[] | .key as $i | .value | . as $l
          | select([$plain[] as $p | ($l.symbol | test($p; "i")) or (($l.symbol + "()") | test($p; "i"))] | any | not)
          | recipe("life." + (.symbol | slug); "ai-templated"; {symbols: [.symbol]};
              ({why: "\(.symbol)() is deprecated in drupal:\(.deprecated_in // "?") and removed from drupal:\(.removed_in // "?").",
                fix: ("Replace it with: " + (.replacement // "see the change record")),
                lifecycle: [{symbol, kind, deprecated_in, removed_in, replacement, replacement_since} | drop_nulls]} | drop_nulls);
              "\($DEP_PATH)#/lifecycle/\($i)"; null)) ]
    | sort_by(.id)' > "$TMP/pre.json" \
  || die "Could not build the recipes from the catalogs (a jq error above)." 1

# Validation: unique ids, known lanes and engines, the ERE dialect of
# ere-replace, and the fixtures of every Docker-free codemod.
PROBLEMS="$TMP/problems.txt"; : > "$PROBLEMS"
jq -r '
  (group_by(.id)[] | select(length > 1) | "duplicate recipe id \(.[0].id)"),
  (.[] | select(.lane | IN("rector", "rector-custom", "codemod", "ai-templated", "ai-free", "test-adapt", "human", "deferred") | not) | "\(.id): unknown lane \(.lane)"),
  (.[] | select(.engine | IN("template", "ere-replace", "yaml-edit", "info-yml", "attributes", "php-script", "rector-rule") | not) | "\(.id): unknown engine \(.engine)"),
  (.[] | select(.engine == "ere-replace") | select((.params.search // "") == "" or (.params.replace // null) == null) | "\(.id): ere-replace needs params.search and params.replace"),
  (.[] | select(.engine == "ere-replace") | select(.params.search | test("\\\\[bBsSdDwW]|\\(\\?")) | "\(.id): params.search is not POSIX ERE (no \\b, \\s, \\d, \\w or (?...))"),
  (.[] | select(.engine == "ere-replace") | select((.params.search + .params.replace) | test("\u0001")) | "\(.id): params contain the \\x01 delimiter"),
  (.[] | select(.kind == "codemod" and .lane != "codemod" and .lane != "rector-custom") | "\(.id): a codemod belongs to lane codemod or rector-custom")' \
  "$TMP/pre.json" >> "$PROBLEMS"
for id in $(jq -r '.[] | select(.engine | IN("ere-replace", "yaml-edit", "info-yml")) | .id' "$TMP/pre.json"); do
  d="$REPO/$FIX/$id"
  if [[ ! -f "$d/expect.json" || ! -d "$d/before" || ! -d "$d/after" ]]; then
    printf '%s: a Docker-free codemod needs %s/{expect.json,before/,after/}\n' "$id" "$FIX/$id" >> "$PROBLEMS"
  fi
done

# Versions and fixtures.
: > "$TMP/meta.tsv"
jq -c '.[]' "$TMP/pre.json" | while IFS= read -r r; do
  id="$(printf '%s' "$r" | jq -r '.id')"
  h="$(printf '%s' "$r" | jq -S -c 'del(.source)' | sha256_hex)"
  fx=""; [[ -d "$REPO/$FIX/$id" ]] && fx="$FIX/$id"
  printf '%s\t%s\t%s\n' "$id" "${h:0:12}" "$fx" >> "$TMP/meta.tsv"
done
META="$(jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: {version: .[1], fixtures: (if .[2] == "" then null else .[2] end)}}) | from_entries' "$TMP/meta.tsv")"
SOURCES="$(for f in "$DEP" "$PC" "$MC"; do printf '%s\t%s\n' "$f" "$(file_hash "$REPO/$f")"; done \
  | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries')"
jq -S --argjson m "$META" --argjson src "$SOURCES" '
  {schema: "drupilot.recipes/1",
   _comment: "GENERATED by scripts/dev/gen-recipes.sh from the catalogs named in sources (ADR 0023): never edit it by hand; change the catalog and run scripts/dev/gen-recipes.sh --write.",
   sources: $src,
   recipes: map(. + $m[.id])}' "$TMP/pre.json" > "$TMP/recipes.json"

DRIFT=false
if [[ "$MODE" == "write" ]]; then
  if [[ ! -s "$PROBLEMS" ]]; then
    cp "$TMP/recipes.json" "$REPO/$OUT.tmp.$$" && mv -f "$REPO/$OUT.tmp.$$" "$REPO/$OUT" || die "Could not write $OUT." 1
  fi
elif ! cmp -s "$TMP/recipes.json" "$REPO/$OUT"; then
  DRIFT=true
  printf '%s differs from a fresh generation: run scripts/dev/gen-recipes.sh --write and commit it\n' "$OUT" >> "$PROBLEMS"
fi
OK=true; [[ -s "$PROBLEMS" ]] && OK=false
while IFS= read -r p; do log_err "$p"; done < "$PROBLEMS"
if [[ "$AS_JSON" == "1" ]]; then
  jq -n --argjson ok "$OK" --arg mode "$MODE" --argjson drift "$DRIFT" --slurpfile r "$TMP/recipes.json" --rawfile p "$PROBLEMS" '
    {ok: $ok, mode: $mode, drift: $drift, recipes: ($r[0].recipes | length),
     by_lane: ($r[0].recipes | group_by(.lane) | map({key: .[0].lane, value: length}) | from_entries),
     by_engine: ($r[0].recipes | group_by(.engine) | map({key: .[0].engine, value: length}) | from_entries),
     problems: ($p | split("\n") | map(select(length > 0)))}'
fi
if [[ "$OK" == "true" ]]; then
  if [[ "$MODE" == "write" ]]; then log_ok "gen-recipes: wrote $OUT ($(jq '.recipes | length' "$TMP/recipes.json") recipes)."
  else log_ok "gen-recipes: $OUT is current ($(jq '.recipes | length' "$TMP/recipes.json") recipes)."; fi
  exit 0
fi
exit 1
