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
# lines and ends with t_done's "# <name>: N passed, M failed" (tests/lib/
# assert.sh). Exit 0 counts as a pass only with that line, at least one
# assertion and no "not ok" line, so a forgotten t_done or an early `exit 0`
# fails. Each test runs with stdin from /dev/null, in its own process group
# (without a controlling terminal where `setsid --wait` exists), and under a
# per-test timeout where `timeout`/`gtimeout` exists (300 s, times the number
# of tests per CPU when more run at once than there are CPUs; --timeout);
# t_isolate sets DRUPILOT_NONINTERACTIVE=1, so on
# every platform drupilot's own prompts take their default. Ctrl-C stops the
# run (exit 130) and kills the running tests.
#
# The tests run in parallel, --jobs at a time (default: the CPUs this process
# may use — nproc, bounded by a cgroup CPU quota —, at most 8);
# each one is isolated (t_isolate: its own temp HOME, XDG dirs and working
# directory). Each result is reported as its test ends; the --json summary
# keeps the tests' order.
#
# Usage:
#   scripts/dev/unit.sh [--only T1,T2] [--jobs N] [--timeout S] [--json] [--list]
#                       [-h|--help]
#     --only   run a subset (test names: the file names without .sh)
#     --jobs   how many tests run at once (1 to 9999; default: the usable CPUs,
#              at most 8; 1 runs them one by one)
#     --timeout  seconds each test may run (default 300, times the tests per
#              CPU when --jobs exceeds the CPUs)
#     --json   machine summary on STDOUT (the test output still goes to STDERR):
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
AS_JSON=0; ONLY=""; LIST=0; JOBS=""; PER_TEST=""

usage() { print_usage "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 || die "--only needs a value" 1;;
    --only=*) ONLY="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    --jobs) JOBS="${2:-}"; shift 2 || die "--jobs needs a value" 1;;
    --jobs=*) JOBS="${1#*=}"; shift;;
    --timeout) PER_TEST="${2:-}"; shift 2 || die "--timeout needs a value" 1;;
    --timeout=*) PER_TEST="${1#*=}"; shift;;
    --list) LIST=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done

have_cmd jq || die "jq is required by scripts/dev/unit.sh" 1
# usable_cpus -> the CPUs this process may use: nproc (it honours the CPU
# affinity of a container's cpuset), else the online CPUs; bounded by a cgroup
# v2 CPU quota (docker --cpus, CI runners) when one is set.
usable_cpus() {
  local n="" q p
  n="$(nproc 2> /dev/null || getconf _NPROCESSORS_ONLN 2> /dev/null || sysctl -n hw.ncpu 2> /dev/null || true)"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=2
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    read -r q p < /sys/fs/cgroup/cpu.max 2> /dev/null || true
    if [[ "${q:-max}" =~ ^[0-9]+$ && "${p:-0}" =~ ^[1-9][0-9]*$ ]]; then
      q=$(( (q + p - 1) / p )); [[ "$q" -ge 1 && "$q" -lt "$n" ]] && n="$q"
    fi
  fi
  printf '%s' "$n"
  return 0
}
CPUS="$(usable_cpus)"
if [[ -z "$JOBS" ]]; then
  JOBS="$CPUS"
  [[ "$JOBS" -le 8 ]] || JOBS=8
fi
[[ "$JOBS" =~ ^[1-9][0-9]{0,3}$ ]] || die "--jobs needs a positive integer below 10000 (got '$JOBS')" 1
# The per-test timeout grows when more tests run at once than there are CPUs.
if [[ -z "$PER_TEST" ]]; then
  PER_TEST=$(( 300 * ( (JOBS + CPUS - 1) / CPUS ) ))
fi
[[ "$PER_TEST" =~ ^[1-9][0-9]{0,5}$ ]] || die "--timeout needs a positive number of seconds (got '$PER_TEST')" 1

# The tests, as "name<TAB>path" lines: selftest first, then tests/unit/*.sh.
TESTS="$(printf 'selftest\t%s\n' "$REPO/tests/lib/selftest.sh"
         for f in "$REPO"/tests/unit/*.sh; do
           [[ -f "$f" ]] && printf '%s\t%s\n' "$(basename "$f" .sh)" "$f"
         done)"

if [[ "$LIST" == "1" ]]; then printf '%s\n' "$TESTS" | cut -f1; exit 0; fi

in_list() { case ",$(printf '%s' "$2" | tr ' ' ','),"  in *",$1,"*) return 0;; esac; return 1; }
for _t in $(printf '%s' "$ONLY" | tr ',' ' '); do
  printf '%s\n' "$TESTS" | cut -f1 | grep_q -xF -- "$_t" || die "Unknown test: $_t (see --list)" 1
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-unitrun.XXXXXX")"
trap 'rm -rf "$TMP" 2> /dev/null || true' EXIT
RESULTS="$TMP/results.jsonl"
: > "$RESULTS"
FAILED=0

# Detach each test from the controlling terminal when `setsid --wait` exists
# (util-linux); BusyBox and macOS have no such flag and run it as is. The
# timeout runs inside the new session, so its kill on expiry reaches the
# test's whole process group.
DETACH=""
if have_cmd setsid && setsid --wait true < /dev/null > /dev/null 2>&1; then DETACH="setsid --wait"; fi
TIMEOUT=""
if have_cmd timeout; then TIMEOUT="timeout $PER_TEST"; elif have_cmd gtimeout; then TIMEOUT="gtimeout $PER_TEST"; fi
# Each test runs in the background in its own process group (setsid's
# session, else job control: set -m), with its exit code in <name>.rc when it
# ends and, while it runs, its group leader in <name>.pid (removed as soon as
# it ends, so a PID the system hands out again is never signalled). The
# wrapper subshell's PID is in <name>.wpid. Ctrl-C (or a TERM) stops every
# running test's group (TERM, then KILL after 3 s) and every wrapper, waits
# for them, and ends the run with exit 130.
stop_run() {
  local pf p pids="" alive
  trap '' INT TERM HUP
  for pf in "$TMP"/*.pid; do
    [[ -f "$pf" ]] || continue
    p="$(cat "$pf" 2> /dev/null || true)"
    [[ -n "$p" ]] || continue
    pids="$pids $p"
    kill -TERM -- "-$p" 2> /dev/null || kill -TERM "$p" 2> /dev/null || true
  done
  # A test gets 3 s to end on TERM (its EXIT trap removes its temp dir); a
  # group with a process still alive then is killed (a bash can spin on TERM
  # inside its EXIT trap instead of ending).
  for _ in 1 2 3; do
    alive=0
    for p in $pids; do { kill -0 -- "-$p" || kill -0 "$p"; } 2> /dev/null && alive=1; done
    [[ "$alive" == "1" ]] || break
    sleep 1
  done
  for p in $pids; do kill -KILL -- "-$p" 2> /dev/null || kill -KILL "$p" 2> /dev/null || true; done
  for pf in "$TMP"/*.wpid; do
    [[ -f "$pf" ]] || continue
    p="$(cat "$pf" 2> /dev/null || true)"
    [[ -n "$p" ]] && kill -TERM "$p" 2> /dev/null || true
  done
  wait 2> /dev/null || true
  log_err "unit.sh: interrupted"
  exit 130
}
trap stop_run INT TERM HUP

# start NAME PATH -> the test in the background; NAME.rc when it ends.
start() {
  (
    # Job control gives the test its own process group when setsid does not.
    [[ -n "$DETACH" ]] || set -m
    # shellcheck disable=SC2086  # DETACH and TIMEOUT are empty or two words
    $DETACH $TIMEOUT "$SH" "$2" > "$TMP/$1.out" 2>&1 < /dev/null &
    printf '%s\n' "$!" > "$TMP/$1.pid"
    if wait "$!"; then r=0; else r=$?; fi
    rm -f "$TMP/$1.pid"
    printf '%s\n' "$r" > "$TMP/$1.rc.tmp" && mv "$TMP/$1.rc.tmp" "$TMP/$1.rc"
  ) 2> /dev/null &
  printf '%s\n' "$!" > "$TMP/$1.wpid"
  return 0
}

# report NAME -> its verdict, logged and appended to NAME.json.
report() {
  local name="$1" rc n_ok status detail failures
  rc="$(cat "$TMP/$name.rc")"
  n_ok="$(grep -c '^ok - ' "$TMP/$name.out" || true)"
  if [[ "$rc" == "0" ]]; then
    if grep -q '^not ok - ' "$TMP/$name.out"; then rc="0 with a not-ok line"
    elif ! grep -qE "^# [^:]+: [0-9]+ passed, 0 failed\$" "$TMP/$name.out"; then rc="0 without t_done's summary line"
    elif [[ "$n_ok" == "0" ]]; then rc="0 with no assertion"
    fi
  fi
  sed 's/^/  /' "$TMP/$name.out" >&2
  case "$rc" in
    0)  status="pass"; detail="$n_ok assertion(s)"; log_ok "$name";;
    77) status="skip"; detail="$(sed -n 's/^skip - //p' "$TMP/$name.out" | sed -n '1p')"; log_warn "$name: skipped — $detail";;
    *)  status="fail"; detail="exit $rc, $(grep -c '^not ok - ' "$TMP/$name.out" || true) failed assertion(s)"
        log_err "$name: FAILED — $detail"
        grep -E '^not ok - |unbound variable|syntax error|command not found' "$TMP/$name.out" | sed -n '1,20p' | sed 's/^/    /' >&2 || true
        [[ -n "$(grep -E '^not ok - ' "$TMP/$name.out" || true)" ]] || tail -n 10 "$TMP/$name.out" | sed 's/^/    /' >&2;;
  esac
  failures="$( { grep '^not ok - ' "$TMP/$name.out" || true; } | jq -R . | jq -s -c .)"
  jq -n -c --arg n "$name" --arg s "$status" --arg d "$detail" --argjson f "$failures" \
    '{name:$n, status:$s, detail:$d, failures:$f}' > "$TMP/$name.json"
  return 0
}

log_step "drupilot unit tests (bash ${BASH_VERSION:-?}, $(uname -s 2>/dev/null || echo ?), $JOBS at a time)"
NAMES=""
RUNNING=""   # " name1 name2 ": started, not reported yet
# reap -> report every running test that has ended.
reap() {
  local n
  for n in $RUNNING; do
    if [[ -f "$TMP/$n.rc" ]]; then
      # Reap its wrapper, so no finished wrapper's PID is ever signalled.
      wait "$(cat "$TMP/$n.wpid" 2> /dev/null)" 2> /dev/null || true
      rm -f "$TMP/$n.wpid"
      report "$n"; RUNNING="${RUNNING/ $n / }"
    fi
  done
  return 0
}
running_count() { set -- $RUNNING; printf '%s' "$#"; }
while IFS="$(printf '\t')" read -r name path; do
  [[ -n "$name" ]] || continue
  if [[ -n "$ONLY" ]] && ! in_list "$name" "$ONLY"; then continue; fi
  while [[ "$(running_count)" -ge "$JOBS" ]]; do reap; [[ "$(running_count)" -lt "$JOBS" ]] || sleep 1; done
  start "$name" "$path"
  NAMES="$NAMES $name"; RUNNING="${RUNNING:- } $name "; RUNNING="${RUNNING//  / }"
done <<< "$TESTS"
while [[ "$(running_count)" -gt 0 ]]; do reap; [[ "$(running_count)" -eq 0 ]] || sleep 1; done
wait

# The results in the tests' order.
for name in $NAMES; do cat "$TMP/$name.json" >> "$RESULTS"; done
if jq -e -s 'any(.[]; .status == "fail")' "$RESULTS" > /dev/null; then FAILED=1; fi

if [[ "$FAILED" == "1" ]]; then log_err "unit.sh: at least one test failed"
else log_ok "unit.sh: no test failed"; fi
if [[ "$AS_JSON" == "1" ]]; then
  jq -s -c --argjson ok "$([[ "$FAILED" == "1" ]] && echo false || echo true)" \
    --arg bash "${BASH_VERSION:-}" '{ok:$ok, bash:$bash, tests:.}' "$RESULTS"
fi
exit "$FAILED"
