#!/usr/bin/env bash
# =============================================================================
# drupilot — tests/lib/assert.sh
# Portable assertions for the unit tests (tests/unit/*.sh), with no bats
# dependency: bash 3.2 + BSD/BusyBox userland + jq 1.6, like the plugin itself.
# Source it from a test, call t_isolate, assert, and end with t_done:
#
#     . "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
#     t_isolate
#     assert_eq "label" "$got" "want"
#     t_done
#
# Every assertion prints one line on STDOUT, "ok - <label>" or
# "not ok - <label>: <why>", and counts it. t_done prints the totals and exits
# 1 when an assertion failed, else 0; t_skip <reason> exits 77 (the runner,
# scripts/dev/unit.sh, reports it as skipped).
#
# Assertions:
#   assert_eq <label> <got> <want>
#   assert_match <label> <got> <ERE>
#   assert_json_eq <label> <got-json> <want-json>   (compared through jq -S)
#   assert_exit <label> <want-code> <cmd...>        (runs cmd, stdin /dev/null)
#   assert_file_eq <label> <file> <file>             (byte-identical)
#   assert_no_stdout <label> <cmd...>                (cmd prints nothing on STDOUT)
#   assert_tree_unchanged <label> <dir> <cmd...>     (no path added, removed or
#                                                     changed under <dir>)
# Helpers:
#   t_isolate   a temp dir ($T_TMP) as HOME, XDG dirs and working directory
#               (so no caller's .drupilot.json is found); every DRUPILOT_*,
#               CLAUDE_PLUGIN_DATA and CLAUDE_CONFIG_DIR unset, then
#               DRUPILOT_NONINTERACTIVE=1 (prompts take their default; note
#               guard-contrib then asks before any push: unset it to test
#               another mode);
#               CLAUDE_PLUGIN_ROOT is the repo; removed on exit (T_KEEP=1 keeps it)
#   t_run <cmd...>  runs cmd in a subshell (stdin /dev/null; an `exit` in a
#               function under test ends only the subshell): STDOUT in $T_OUT
#               (a file), STDERR in $T_ERR, exit code in $T_RC
#   t_out, t_err   print the captured STDOUT / STDERR
#   t_path_without <cmd...>  print a directory holding a symlink to every
#               command of $PATH but the named ones
#               (PATH="$(t_path_without jq)" hides jq)
#   t_unwritable_home  print a HOME no process can write, root included (a
#               read-only directory, or a path under a regular file for root,
#               which ignores directory permissions)
#   t_skip <reason>, t_done
# Paths: $T_REPO (the repository), $T_LIB (scripts/lib/common.sh), $T_SH (the
# bash running the test: the runner passes its own, so /bin/bash 3.2 on macOS
# tests stock bash end to end).
# =============================================================================

T_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC2034  # T_LIB and T_SH are for the tests that source this file
T_LIB="$T_REPO/scripts/lib/common.sh"
# shellcheck disable=SC2034
T_SH="${BASH:-bash}"
T_PASS=0
T_FAIL=0
T_TMP=""
T_OUT=""
T_ERR=""
T_RC=0
T_NAME="$(basename "$0" .sh)"

_t_pass() { T_PASS=$((T_PASS + 1)); printf 'ok - %s\n' "$1"; return 0; }
_t_fail() { T_FAIL=$((T_FAIL + 1)); printf 'not ok - %s: %s\n' "$1" "$2"; return 0; }

# _t_short <text> -> the text on one line, cut to 300 characters.
_t_short() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-300; }

t_isolate() {
  local v
  T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-unit.XXXXXX")" || { echo "t_isolate: mktemp failed" >&2; exit 1; }
  T_TMP="$(cd "$T_TMP" && pwd -P)"
  for v in $(env | sed -n 's/^\(DRUPILOT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
  # No test may block on one of drupilot's /dev/tty prompts (confirm,
  # choose_one), on any platform; a test of the interactive path unsets it.
  export DRUPILOT_NONINTERACTIVE=1
  unset CLAUDE_PLUGIN_DATA CLAUDE_CONFIG_DIR
  export CLAUDE_PLUGIN_ROOT="$T_REPO"
  export HOME="$T_TMP/home"
  export XDG_DATA_HOME="$T_TMP/home/.local/share" XDG_STATE_HOME="$T_TMP/home/.local/state"
  export XDG_CACHE_HOME="$T_TMP/home/.cache" XDG_CONFIG_HOME="$T_TMP/home/.config"
  export GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME" "$T_TMP/out"
  T_OUT="$T_TMP/out/stdout"; T_ERR="$T_TMP/out/stderr"
  trap '_t_cleanup' EXIT
  cd "$T_TMP" || exit 1
  return 0
}

# _t_scratch -> a removed-on-exit $T_TMP for T_OUT/T_ERR when t_isolate did
# not run (the self-test's child shells), so nothing is left in $TMPDIR.
_t_scratch() {
  [[ -n "$T_TMP" ]] || {
    T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-unit.XXXXXX")" || { echo "t_run: mktemp failed" >&2; exit 1; }
    trap '_t_cleanup' EXIT
  }
  mkdir -p "$T_TMP/out"
  T_OUT="$T_TMP/out/stdout"; T_ERR="$T_TMP/out/stderr"
  return 0
}

_t_cleanup() {
  [[ -n "$T_TMP" ]] || return 0
  if [[ "${T_KEEP:-}" == "1" ]]; then echo "# kept $T_TMP" >&2
  else chmod -R u+w "$T_TMP" 2>/dev/null; rm -rf "$T_TMP"; fi
  return 0
}

t_run() {
  [[ -n "$T_OUT" ]] || _t_scratch
  if ( "$@" ) > "$T_OUT" 2> "$T_ERR" < /dev/null; then T_RC=0; else T_RC=$?; fi
  return 0
}
t_out() { cat "$T_OUT" 2>/dev/null; return 0; }
t_err() { cat "$T_ERR" 2>/dev/null; return 0; }

assert_eq() {
  if [[ "$2" == "$3" ]]; then _t_pass "$1"
  else _t_fail "$1" "got [$(_t_short "$2")] want [$(_t_short "$3")]"; fi
}

assert_match() {
  if printf '%s' "$2" | grep -Eq -- "$3"; then _t_pass "$1"
  else _t_fail "$1" "[$(_t_short "$2")] does not match /$3/"; fi
}

assert_json_eq() {
  local a b
  a="$(printf '%s' "$2" | jq -S . 2>/dev/null)" || { _t_fail "$1" "got is not JSON: [$(_t_short "$2")]"; return 0; }
  b="$(printf '%s' "$3" | jq -S . 2>/dev/null)" || { _t_fail "$1" "want is not JSON: [$(_t_short "$3")]"; return 0; }
  if [[ "$a" == "$b" ]]; then _t_pass "$1"
  else _t_fail "$1" "got $(_t_short "$(printf '%s' "$2" | jq -S -c . 2>/dev/null)") want $(_t_short "$(printf '%s' "$3" | jq -S -c . 2>/dev/null)")"; fi
}

assert_exit() {
  local label="$1" want="$2"; shift 2
  t_run "$@"
  if [[ "$T_RC" == "$want" ]]; then _t_pass "$label"
  else _t_fail "$label" "exit $T_RC, want $want (stderr: $(_t_short "$(t_err)"))"; fi
}

assert_file_eq() {
  if [[ -f "$2" && -f "$3" ]] && cmp -s "$2" "$3"; then _t_pass "$1"
  else _t_fail "$1" "$2 and $3 differ (or one is missing)"; fi
}

assert_no_stdout() {
  local label="$1"; shift
  t_run "$@"
  if [[ ! -s "$T_OUT" ]]; then _t_pass "$label"
  else _t_fail "$label" "STDOUT was [$(_t_short "$(t_out)")]"; fi
}

# _t_tree <dir> -> every path under <dir> with a checksum for files, sorted.
_t_tree() {
  local d="$1"
  [[ -e "$d" ]] || { printf '<absent>\n'; return 0; }
  ( cd "$d" && find . -print | LC_ALL=C sort | while IFS= read -r p; do
      if [[ -f "$p" && ! -L "$p" ]]; then printf '%s %s\n' "$p" "$(cksum < "$p" 2>/dev/null | awk '{print $1 "-" $2}')"
      else printf '%s\n' "$p"; fi
    done )
  return 0
}

assert_tree_unchanged() {
  local label="$1" dir="$2" before after; shift 2
  before="$(_t_tree "$dir")"
  t_run "$@"
  after="$(_t_tree "$dir")"
  if [[ "$before" == "$after" ]]; then _t_pass "$label"
  else _t_fail "$label" "$dir changed: $(_t_short "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep '^[<>]' | head -n 5)")"; fi
}

t_path_without() {
  local dir p c
  dir="$T_TMP/path-without-$(printf '%s-' "$@")"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    local IFS=:
    for p in $PATH; do
      [[ -d "$p" ]] || continue
      ln -s "$p"/* "$dir"/ 2>/dev/null || true
    done
    for c in "$@"; do rm -f "$dir/$c"; done
  fi
  printf '%s' "$dir"
  return 0
}

t_unwritable_home() {
  local h="$T_TMP/rohome"
  if [[ "$(id -u 2>/dev/null || echo 1)" == "0" ]]; then
    : > "$T_TMP/not-a-dir"
    h="$T_TMP/not-a-dir/home"
  else
    mkdir -p "$h" && chmod a-w "$h"
  fi
  printf '%s' "$h"
  return 0
}

t_skip() { printf 'skip - %s\n' "$1"; exit 77; }

t_done() {
  printf '# %s: %d passed, %d failed\n' "$T_NAME" "$T_PASS" "$T_FAIL"
  [[ "$T_FAIL" -eq 0 ]] || exit 1
  exit 0
}
