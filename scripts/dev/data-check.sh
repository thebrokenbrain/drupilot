#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/dev/data-check.sh
# Check drupilot's version data and catalogs (a developer/CI tool: no command,
# skill or hook calls it; scripts/dev/check.sh runs it as its `data` gate):
#   schema      every $ref of the schemas resolves (whatever the data);
#               config/targets/<major>.json (schemas/target.schema.json),
#               config/php/versions.json and rules.json, config/paths/eras.json
#               and graph.json, and every config/catalog/*.json validate
#               against their schema (the jq validator, scripts/dev/
#               jsonschema.jq); the eight core files (targets/10, 11 and 12,
#               php/versions and rules, paths/eras and graph, and the toolchain
#               matrix toolchain-reference.json) must exist
#   provenance  every object that carries `verified` names its source (src or
#               url), every object holding a version value names one too (a
#               PHP support list: php_src), and every `verified_as` object
#               lists when to re-verify it (reverify_at)
#   hard-gate   every node a schema marks x-drupilot-hard-gate (next to a
#               $ref or inside an anyOf too; a catalog entry: blocking: true)
#               is verified:true and never verified_as "announced" (a
#               {"status": "detect"} minor holds no value)
#   coherence   a target file's major matches its name and its minors; a
#               target major (11 and up) has toolchain_cell, php_defaults and
#               default_ranges, and its toolchain_cell is a cell of the
#               toolchain matrix; a verified cell says where and pins a set; every PHP version a target names is in
#               php/versions.json; a minor never lists a PHP as both supported
#               and unsupported; versions.json ids and rector_level match the
#               key; rules have unique ids and a verified removed-no-rule rule
#               cites php.net; graph edges are unique, named from-to, join
#               known eras, and every forbidden route chains from -> to
#
# Usage:
#   scripts/dev/data-check.sh [--root DIR] [--json] [-h|--help]
#     --root   the tree to check (holding config/ and schemas/; default: this
#              repo), so a test can check an altered copy
#     --json   {ok, root, checks:[{check, file, status, detail}]} on STDOUT
#
# Requires bash >= 3.2 and jq. Exit codes: 0 every check passes · 1 a check
# failed or a usage error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT=""; AS_JSON=0

usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 || die "--root needs a value" 1;;
    --root=*) ROOT="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
have_cmd jq || die "jq is required by scripts/dev/data-check.sh" 1
ROOT="${ROOT:-$REPO}"
[[ -d "$ROOT/config" && -d "$ROOT/schemas" ]] || die "--root $ROOT holds no config/ and schemas/" 1
LIB="$REPO/scripts/dev/jsonschema.jq"
[[ -r "$LIB" ]] || die "missing $LIB" 1

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-data.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
RESULTS="$TMP/results.jsonl"; : > "$RESULTS"; FAILED=0
result() {
  jq -n -c --arg c "$1" --arg f "$2" --arg s "$3" --arg d "$4" '{check: $c, file: $f, status: $s, detail: $d}' >> "$RESULTS"
  if [[ "$3" == "pass" ]]; then log_ok "$1: $2"; else log_err "$1: $2: $4"; FAILED=1; fi
  return 0
}
# report CHECK FILE ERRORS -> one pass or one fail line (the first errors).
report() {
  if [[ -z "$3" ]]; then result "$1" "$2" pass ""
  else result "$1" "$2" fail "$(printf '%s\n' "$3" | head -n 5 | tr '\n' ';')"; fi
  return 0
}

# The files and their schema: "file<TAB>schema".
FILES=""
for f in targets/10.json targets/11.json targets/12.json; do
  [[ -f "$ROOT/config/$f" ]] || { result schema "config/$f" fail "missing"; continue; }
done
for f in "$ROOT"/config/targets/*.json; do
  [[ -f "$f" ]] && FILES="${FILES}config/targets/$(basename "$f")	target.schema.json
"
done
for p in "php/versions.json	php-versions.schema.json" "php/rules.json	php-rules.schema.json" \
         "paths/eras.json	paths.schema.json" "paths/graph.json	paths.schema.json" \
         "toolchain-reference.json	toolchain.schema.json"; do
  f="${p%%	*}"
  if [[ -f "$ROOT/config/$f" ]]; then FILES="${FILES}config/$p
"; else result schema "config/$f" fail "missing"; fi
done
for f in "$ROOT"/config/catalog/*.json; do
  [[ -f "$f" ]] && FILES="${FILES}config/catalog/$(basename "$f")	catalog.schema.json
"
done

JQ_LIB="$(cat "$LIB")"
# Provenance over any document: one line per violation.
PROV='
def vkeys: ["php_min", "php_recommended", "latest", "released", "symfony_major", "twig_major",
            "phpunit_constraint", "coder_constraint", "phpstan_constraint", "phpstan_drupal_constraint",
            "removed_in", "deprecated_in", "introduced_in", "value", "actual", "planned",
            "active_until", "security_until", "output_min_php", "drupal_core_floor"];
def hassrc: ((.src // "") | tostring | length) > 0 or ((.url // "") | tostring | length) > 0;
paths(type == "object") as $p | getpath($p) as $o
| ($p | map(tostring) | join(".")) as $at
| ( (if ($o | has("verified")) and ($o | hassrc | not) then "\($at): verified without src/url" else empty end),
    (if ($o | has("verified_as")) and ((($o.reverify_at // []) | length) == 0) then "\($at): verified_as without reverify_at" else empty end),
    (if ($o | hassrc | not) and any(vkeys[]; . as $k | ($o | has($k)) and ($o[$k] != null) and (($o[$k] | type) != "object"))
     then "\($at): version value without src/url" else empty end),
    (if ((($o.php_supported // null) != null) or (($o.php_unsupported // null) != null)) and ((($o.php_src // "") | length) == 0)
     then "\($at): PHP support list without php_src" else empty end) )'

# Every $ref of every schema used resolves (once per schema, whatever the data).
for schema in $(printf '%s' "$FILES" | cut -f2 | LC_ALL=C sort -u); do
  report schema-refs "schemas/$schema" "$(jq -r "$JQ_LIB bad_refs" "$ROOT/schemas/$schema" 2>&1 || true)"
done

while IFS="$(printf '\t')" read -r file schema; do
  [[ -n "$file" ]] || continue
  src="$ROOT/$file"
  if ! jq -e 'type == "object"' "$src" > /dev/null 2>&1; then result schema "$file" fail "not a JSON object"; continue; fi
  errs="$(jq -r --slurpfile schema "$ROOT/schemas/$schema" "$JQ_LIB
    . as \$doc | \$schema[0] as \$root | \$doc | chk(\$root; \$root; \"\$\")" "$src" 2>&1)" || errs="jq failed: $errs"
  report schema "$file" "$errs"
  report provenance "$file" "$(jq -r "$PROV" "$src" 2>&1 || true)"
  if [[ "$schema" == "catalog.schema.json" ]]; then
    errs="$(jq -r '.entries[]? | select(.blocking == true) | select(.verified != true or has("verified_as")) | "entry \(.id): blocking but not verified (or announced)"' "$src" 2>&1 || true)"
  else
    errs="$(jq -r --slurpfile schema "$ROOT/schemas/$schema" "$JQ_LIB
      . as \$doc | \$schema[0] as \$root | [\$doc | hard(\$root; \$root; \"\$\")] | unique_by(.path)[]
      | select((.node | type) != \"object\" or ((.node.status // \"\") != \"detect\" and (.node.verified != true or (.node | has(\"verified_as\")))))
      | \"\\(.path): feeds a hard gate but is not verified (or is announced)\"" "$src" 2>&1 || true)"
  fi
  report hard-gate "$file" "$errs"
done <<< "$FILES"

# --- coherence ---------------------------------------------------------------
TCR="$ROOT/config/toolchain-reference.json"
if [[ -f "$TCR" ]]; then
  errs="$(jq -r '(.cells // {}) | to_entries[] | select(.value.verified == true)
    | (if (.value.verified_on | type) != "object" then "cell \(.key): verified without verified_on" else empty end),
      (if ((.value.toolchain // {}) | length) == 0 then "cell \(.key): verified with no pins" else empty end)' "$TCR" 2>&1 || true)"
  report coherence config/toolchain-reference.json "$errs"
fi
VERS="$ROOT/config/php/versions.json"
if [[ -f "$VERS" ]]; then
  for f in "$ROOT"/config/targets/*.json; do
    [[ -f "$f" ]] || continue
    n="$(basename "$f" .json)"
    errs="$(jq -r --arg n "$n" --slurpfile v "$VERS" --slurpfile t "$([[ -f "$TCR" ]] && printf '%s' "$TCR" || printf /dev/null)" '
      ($v[0].versions // {}) as $vs | (($t[0].cells // {}) | keys) as $cells
      | (if has("toolchain_cell") and (.toolchain_cell as $tc | $cells | index($tc) | not)
         then "toolchain_cell \(.toolchain_cell) is not a cell of config/toolchain-reference.json" else empty end),
        (if (.major | tostring) != $n then "major \(.major) in \($n).json" else empty end),
        (.minors | keys[] | select(startswith($n + ".") | not) | "minor \(.) is not of major \($n)"),
        (if (.major >= 11) and ((has("toolchain_cell") and has("php_defaults") and has("default_ranges")) | not)
         then "a target major needs toolchain_cell, php_defaults and default_ranges" else empty end),
        ([(.php_defaults // {})[]?, (.minors[] | (.php_supported // [])[], (.php_unsupported // [])[])] | unique[]
         | select(. as $p | $vs | has($p) | not) | "PHP \(.) is not in php/versions.json"),
        (.minors | to_entries[] | .key as $m
         | ((.value.php_supported // []) - ((.value.php_supported // []) - (.value.php_unsupported // [])))[]
         | "minor \($m) lists PHP \(.) as both supported and unsupported")' "$f" 2>&1 || true)"
    report coherence "config/targets/$n.json" "$errs"
  done
  errs="$(jq -r '.versions | to_entries[] | .key as $k | ($k | split(".") | map(tonumber)) as $p
    | (if .value.id != ($p[0] * 10000 + $p[1] * 100) then "\($k): id \(.value.id)" else empty end),
      (if .value.rector_level != ("PHP_" + ($k | sub("\\."; ""))) then "\($k): rector_level \(.value.rector_level)" else empty end),
      (if .value.rector_set != null and .value.rector_set != ("php" + ($k | sub("\\."; ""))) then "\($k): rector_set \(.value.rector_set)" else empty end)' "$VERS" 2>&1 || true)"
  report coherence config/php/versions.json "$errs"
fi
RULES="$ROOT/config/php/rules.json"
if [[ -f "$RULES" ]]; then
  errs="$(jq -r '(.rules | group_by(.id)[] | select(length > 1) | "duplicate rule id \(.[0].id)"),
    (.rules[] | select(.kind == "removed-no-rule" and .verified == true and ((.src // "") | test("php\\.net") | not)) | "\(.id): a verified removed-no-rule rule must cite php.net"),
    (.rules[] | select(.kind == "removed-no-rule" and .rule != null) | "\(.id): a removed-no-rule rule has no Rector rule")' "$RULES" 2>&1 || true)"
  report coherence config/php/rules.json "$errs"
fi
GRAPH="$ROOT/config/paths/graph.json"; ERAS="$ROOT/config/paths/eras.json"
if [[ -f "$GRAPH" && -f "$ERAS" ]]; then
  errs="$(jq -r --slurpfile e "$ERAS" '($e[0].eras // {}) as $eras
    | (.edges | group_by(.id)[] | select(length > 1) | "duplicate edge \(.[0].id)"),
      (.edges[] | select(.id != "\(.from)-\(.to)") | "edge \(.id) joins \(.from) -> \(.to)"),
      (.edges[] | select(.from >= .to) | "edge \(.id) does not go forward"),
      (.edges[] | (.from, .to) | tostring | select(. as $x | $eras | has($x) | not) | "era \(.) has no fingerprint in eras.json"),
      ([.edges[] | {key: .id, value: .}] | from_entries) as $by
      | .forbidden[]? | . as $f
      | ([.route[] | $by[.] // null]) as $hops
      | if any($hops[]; . == null) then "forbidden \($f.from)->\($f.to): an unknown edge in its route"
        elif $hops[0].from != $f.from or $hops[-1].to != $f.to then "forbidden \($f.from)->\($f.to): its route does not go from \($f.from) to \($f.to)"
        elif any(range(1; $hops | length); $hops[. - 1].to != $hops[.].from) then "forbidden \($f.from)->\($f.to): its route does not chain"
        else empty end' "$GRAPH" 2>&1 || true)"
  report coherence config/paths/graph.json "$errs"
fi

if [[ "$FAILED" == "1" ]]; then log_err "data-check.sh: the version data has problems"
else log_ok "data-check.sh: the version data is valid, sourced and safe for the hard gates"; fi
if [[ "$AS_JSON" == "1" ]]; then
  jq -s -c --argjson ok "$([[ "$FAILED" == "1" ]] && echo false || echo true)" --arg r "$ROOT" \
    '{ok: $ok, root: $r, checks: .}' "$RESULTS"
fi
exit "$FAILED"
