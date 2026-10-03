#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/dev/unit.sh
# The unit-test runner (a developer/CI tool: no command, skill or hook calls
# it; scripts/dev/check.sh runs it as its `unit` gate). It runs
# tests/lib/selftest.sh (the assert library's own test, named `selftest`) and
# every tests/unit/*.sh, each with the SAME bash that runs this file ($BASH), so
# `/bin/bash scripts/dev/unit.sh` on macOS tests stock bash 3.2 end to end.
# A test exits 0 (pass), 77 (skipped: its invariant belongs to a later
# milestone) or anything else (fail); it prints "ok - ..." / "not ok - ..."
# lines (tests/lib/assert.sh).
#
# Usage:
#   scripts/dev/unit.sh [--only T1,T2] [--json] [--list] [-h|--help]
#     --only   run a subset (test names: the file names without .sh)
#     --json   machine summary on STDOUT (the test output goes to STDERR):
#              {ok, bash, tests:[{name, status: pass|fail|skip, detail,
#                                 failures:[..]}]}
#     --list   print the test names, one per line, and exit
#
# Requires bash >= 3.2 and jq. Exit codes: 0 no test failed · 1 a test failed
# or a usage error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SH="${BASH:-bash}"
AS_JSON=0; ONLY=""; LIST=0

usage() { print_usage "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 || die "--only needs a value" 1;;
    --only=*) ONLY="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    --list) LIST=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done

have_cmd jq || die "jq is required by scripts/dev/unit.sh" 1

# The tests, as "name<TAB>path" lines: selftest first, then tests/unit/*.sh.
TESTS="$(printf 'selftest\t%s\n' "$REPO/tests/lib/selftest.sh"
         for f in "$REPO"/tests/unit/*.sh; do
           [[ -f "$f" ]] && printf '%s\t%s\n' "$(basename "$f" .sh)" "$f"
         done)"

if [[ "$LIST" == "1" ]]; then printf '%s\n' "$TESTS" | cut -f1; exit 0; fi

in_list() { case ",$(printf '%s' "$2" | tr ' ' ','),"  in *",$1,"*) return 0;; esac; return 1; }
for _t in $(printf '%s' "$ONLY" | tr ',' ' '); do
  printf '%s\n' "$TESTS" | cut -f1 | grep -qxF -- "$_t" || die "Unknown test: $_t (see --list)" 1
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-unitrun.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
RESULTS="$TMP/results.jsonl"
: > "$RESULTS"
FAILED=0

log_step "drupilot unit tests (bash ${BASH_VERSION:-?}, $(uname -s 2>/dev/null || echo ?))"
while IFS="$(printf '\t')" read -r name path; do
  [[ -n "$name" ]] || continue
  if [[ -n "$ONLY" ]] && ! in_list "$name" "$ONLY"; then continue; fi
  if "$SH" "$path" > "$TMP/$name.out" 2>&1 < /dev/null; then rc=0; else rc=$?; fi
  case "$rc" in
    0)  status="pass"; detail="$(grep -c '^ok - ' "$TMP/$name.out" || true) assertion(s)"; log_ok "$name";;
    77) status="skip"; detail="$(sed -n 's/^skip - //p' "$TMP/$name.out" | head -n 1)"; log_warn "$name: skipped — $detail";;
    *)  status="fail"; detail="exit $rc, $(grep -c '^not ok - ' "$TMP/$name.out" || true) failed assertion(s)"; FAILED=1
        log_err "$name: FAILED — $detail"
        grep -E '^not ok - |unbound variable|syntax error|command not found' "$TMP/$name.out" | head -n 20 | sed 's/^/    /' >&2 || true
        [[ -n "$(grep -E '^not ok - ' "$TMP/$name.out" || true)" ]] || tail -n 10 "$TMP/$name.out" | sed 's/^/    /' >&2;;
  esac
  failures="$( { grep '^not ok - ' "$TMP/$name.out" || true; } | jq -R . | jq -s -c .)"
  jq -n -c --arg n "$name" --arg s "$status" --arg d "$detail" --argjson f "$failures" \
    '{name:$n, status:$s, detail:$d, failures:$f}' >> "$RESULTS"
  [[ "$AS_JSON" == "1" ]] || sed 's/^/  /' "$TMP/$name.out" >&2
done <<< "$TESTS"

if [[ "$FAILED" == "1" ]]; then log_err "unit.sh: at least one test failed"
else log_ok "unit.sh: no test failed"; fi
if [[ "$AS_JSON" == "1" ]]; then
  jq -s -c --argjson ok "$([[ "$FAILED" == "1" ]] && echo false || echo true)" \
    --arg bash "${BASH_VERSION:-}" '{ok:$ok, bash:$bash, tests:.}' "$RESULTS"
fi
exit "$FAILED"
