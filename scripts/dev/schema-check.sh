#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/dev/schema-check.sh
# Validate drupilot's persisted artifacts against schemas/*.schema.json (a
# developer/CI tool: no command, skill or hook calls it; scripts/dev/check.sh
# runs it as its `schemas` gate). Each schema is checked against the
# instances listed below: the 0.9 captures of tests/baseline/v0.9.0/, the lab
# samples of tests/baseline/v0.9.0/samples/, a live `preflight.sh --json`, the
# version data of config/targets|php|paths and an example catalog (the data
# gate, scripts/dev/data-check.sh, also checks their provenance). Two engines:
#   jq         always available: the structural validator of
#              scripts/dev/jsonschema.jq, reading the same schemas (only the
#              keywords that file lists, which the schemas are restricted
#              to), so the bash-only CI legs still check
#   validator  check-jsonschema (07-Q11), CI-only, never a plugin runtime
#              dependency: the one on PATH, or (--mode docker) version
#              0.38.2 in the pinned python:3.13-alpine image below
#
# Usage:
#   scripts/dev/schema-check.sh [--mode auto|jq|validator|docker] [--json]
#                               [-h|--help]
#     --mode   auto (default): jq, plus check-jsonschema when it is on PATH;
#              jq: jq only; validator: jq and check-jsonschema from PATH
#              (missing = failure); docker: jq and the pinned image
#     --json   {ok, mode, engines, checks:[{schema, instance, engine,
#              status: pass|fail, detail}]} on STDOUT
#
# Requires bash >= 3.2 and jq (docker for --mode docker). Exit codes: 0 every
# instance validates · 1 a failure, a missing engine or a usage error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SH="${BASH:-bash}"
MODE="auto"; AS_JSON=0
CJS_VERSION="0.38.2"
CJS_IMAGE="python:3.13-alpine@sha256:2dd78ad5cf13a0b68f5134dc49aa9950203a8cf4b7463431b9f3b398287c5059"

usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 || die "--mode needs a value" 1;;
    --mode=*) MODE="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
case "$MODE" in auto|jq|validator|docker) ;; *) die "--mode must be auto, jq, validator or docker" 1;; esac
have_cmd jq || die "jq is required by scripts/dev/schema-check.sh" 1

# The instances: "schema file<TAB>instance<TAB>jq filter". An instance is a
# repo path, or @preflight (a live `preflight.sh --profile all --json`).
BL="tests/baseline/v0.9.0"
SPECS="$(printf '%s\t%s\t%s\n' \
  port-summary.v1.schema.json "$BL/lw-port-summary.json" .stdout \
  assess.schema.json "$BL/samples/assess.json" . \
  last-test.schema.json "$BL/samples/last-test.json" . \
  port-manifest.schema.json "$BL/samples/port-manifest.json" . \
  lock.schema.json "$BL/samples/drupilot-lock.json" . \
  preflight.schema.json "$BL/samples/preflight.json" . \
  preflight.schema.json @preflight . \
  target.schema.json config/targets/10.json . \
  target.schema.json config/targets/11.json . \
  target.schema.json config/targets/12.json . \
  php-versions.schema.json config/php/versions.json . \
  php-rules.schema.json config/php/rules.json . \
  paths.schema.json config/paths/eras.json . \
  paths.schema.json config/paths/graph.json . \
  toolchain.schema.json config/toolchain-reference.json . \
  catalog.schema.json schemas/examples/catalog.example.json .)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-schema.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
RESULTS="$TMP/results.jsonl"; : > "$RESULTS"; FAILED=0
mkdir -p "$TMP/inst"
result() {
  jq -n -c --arg s "$1" --arg i "$2" --arg e "$3" --arg st "$4" --arg d "$5" \
    '{schema: $s, instance: $i, engine: $e, status: $st, detail: $d}' >> "$RESULTS"
  if [[ "$4" == "pass" ]]; then log_ok "$3: $1 <- $2"; else log_err "$3: $1 <- $2: $5"; FAILED=1; fi
  return 0
}

# The jq validator (scripts/dev/jsonschema.jq): every violation of <schema> by
# the input, one per line.
JQV="$(cat "$REPO/scripts/dev/jsonschema.jq")
. as \$doc | \$schema[0] as \$root | \$doc | chk(\$root; \$root; \"\$\")"

# Extract every instance into $TMP/inst/<n>.json.
n=0; INST=""
while IFS="$(printf '\t')" read -r schema inst filter; do
  [[ -n "$schema" ]] || continue
  n=$((n + 1)); out="$TMP/inst/$n.json"
  if [[ ! -f "$REPO/schemas/$schema" ]]; then result "$schema" "$inst" jq fail "schemas/$schema is missing"; continue; fi
  if [[ "$inst" == "@preflight" ]]; then
    mkdir -p "$TMP/home"
    ( cd "$TMP" && env HOME="$TMP/home" CLAUDE_PLUGIN_ROOT="$REPO" "$SH" "$REPO/scripts/env/preflight.sh" --profile all --json ) \
      > "$TMP/pf.json" 2>/dev/null || true
    jq "$filter" "$TMP/pf.json" > "$out" 2>/dev/null || { result "$schema" "$inst" jq fail "preflight.sh --json gave no JSON"; continue; }
    [[ "$(jq -s 'length' "$out" 2>/dev/null)" == "1" ]] || { result "$schema" "$inst" jq fail "preflight.sh --json gave no JSON value"; continue; }
  elif [[ -f "$REPO/$inst" ]]; then
    jq "$filter" "$REPO/$inst" > "$out" 2>/dev/null || { result "$schema" "$inst" jq fail "not JSON (or $filter fails)"; continue; }
    # jq exits 0 on an empty file: an instance must be exactly one JSON value.
    [[ "$(jq -s 'length' "$out" 2>/dev/null)" == "1" ]] || { result "$schema" "$inst" jq fail "not exactly one JSON value (empty?)"; continue; }
  else
    result "$schema" "$inst" jq fail "instance $inst is missing"; continue
  fi
  INST="$INST$schema	$inst	$out
"
done <<< "$SPECS"
# Every schema has an instance.
for f in "$REPO"/schemas/*.schema.json; do
  [[ -f "$f" ]] || continue
  printf '%s\n' "$SPECS" | cut -f1 | grep -qxF -- "$(basename "$f")" \
    || result "$(basename "$f")" - jq fail "no instance validates this schema (add one to SPECS)"
done

log_step "drupilot schemas: jq$([[ "$MODE" != "jq" ]] && printf ' + check-jsonschema (%s)' "$MODE")"
# Every $ref of every schema resolves, whatever the instances reach.
for f in "$REPO"/schemas/*.schema.json; do
  [[ -f "$f" ]] || continue
  errs="$(jq -r "$(cat "$REPO/scripts/dev/jsonschema.jq") bad_refs" "$f" 2>&1 || true)"
  [[ -z "$errs" ]] || result "$(basename "$f")" refs jq fail "$(printf '%s\n' "$errs" | head -n 5 | tr '\n' ';')"
done
# --- jq engine --------------------------------------------------------------------
while IFS="$(printf '\t')" read -r schema inst out; do
  [[ -n "$schema" ]] || continue
  errs="$(jq -r --slurpfile schema "$REPO/schemas/$schema" "$JQV" "$out" 2>&1)" || errs="jq failed: $errs"
  if [[ -z "$errs" ]]; then result "$schema" "$inst" jq pass ""
  else result "$schema" "$inst" jq fail "$(printf '%s\n' "$errs" | head -n 5 | tr '\n' ';')"; fi
done <<< "$INST"

# --- check-jsonschema engine ------------------------------------------------------
ENGINES="jq"
USE_CJS=0
case "$MODE" in
  auto) have_cmd check-jsonschema && USE_CJS=1;;
  validator) have_cmd check-jsonschema || die "--mode validator: check-jsonschema is not on PATH (pipx install check-jsonschema==$CJS_VERSION)" 1; USE_CJS=1;;
  docker) have_cmd docker || die "--mode docker needs docker" 1; USE_CJS=1;;
esac
if [[ "$USE_CJS" == "1" ]]; then
  ENGINES="jq check-jsonschema"
  if [[ "$MODE" == "docker" ]]; then
    # One container for every check: install once, then validate each pair.
    script="pip install -q --disable-pip-version-check --root-user-action=ignore check-jsonschema==$CJS_VERSION >/dev/null 2>&1 || exit 9
      check-jsonschema --check-metaschema /s/*.schema.json > /i/meta.out 2>&1; echo \$? > /i/meta.rc"
    while IFS="$(printf '\t')" read -r schema inst out; do
      [[ -n "$schema" ]] || continue
      b="$(basename "$out" .json)"
      script="$script
      check-jsonschema --schemafile /s/$schema /i/$b.json > /i/$b.out 2>&1; echo \$? > /i/$b.rc"
    done <<< "$INST"
    docker run --rm -v "$REPO/schemas:/s:ro" -v "$TMP/inst:/i" "$CJS_IMAGE" sh -c "$script" < /dev/null > /dev/null 2>&1 \
      || [[ -f "$TMP/inst/meta.rc" ]] || die "the check-jsonschema container failed (network for pip?)" 1
  else
    if check-jsonschema --check-metaschema "$REPO"/schemas/*.schema.json > "$TMP/inst/meta.out" 2>&1; then echo 0; else echo 1; fi > "$TMP/inst/meta.rc"
    while IFS="$(printf '\t')" read -r schema inst out; do
      [[ -n "$schema" ]] || continue
      b="$(basename "$out" .json)"
      if check-jsonschema --schemafile "$REPO/schemas/$schema" "$out" > "$TMP/inst/$b.out" 2>&1; then echo 0; else echo 1; fi > "$TMP/inst/$b.rc"
    done <<< "$INST"
  fi
  if [[ "$(cat "$TMP/inst/meta.rc" 2>/dev/null)" == "0" ]]; then result "schemas/*.schema.json" metaschema check-jsonschema pass ""
  else result "schemas/*.schema.json" metaschema check-jsonschema fail "$(tail -n 5 "$TMP/inst/meta.out" 2>/dev/null | tr '\n' ';')"; fi
  while IFS="$(printf '\t')" read -r schema inst out; do
    [[ -n "$schema" ]] || continue
    b="$(basename "$out" .json)"
    if [[ "$(cat "$TMP/inst/$b.rc" 2>/dev/null)" == "0" ]]; then result "$schema" "$inst" check-jsonschema pass ""
    else result "$schema" "$inst" check-jsonschema fail "$(grep -v '^Schema validation errors' "$TMP/inst/$b.out" 2>/dev/null | head -n 5 | tr '\n' ';')"; fi
  done <<< "$INST"
fi

if [[ "$FAILED" == "1" ]]; then log_err "schema-check.sh: an artifact does not match its schema"
else log_ok "schema-check.sh: every artifact matches its schema ($ENGINES)"; fi
if [[ "$AS_JSON" == "1" ]]; then
  jq -s -c --argjson ok "$([[ "$FAILED" == "1" ]] && echo false || echo true)" --arg m "$MODE" --arg e "$ENGINES" \
    '{ok: $ok, mode: $m, engines: ($e | split(" ")), checks: .}' "$RESULTS"
fi
exit "$FAILED"
