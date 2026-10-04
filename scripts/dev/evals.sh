#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/dev/evals.sh
# Router evals (a developer/CI tool: no command, skill or hook calls it), in
# two layers (G-EVALS):
#   static (default, the `evals` gate of scripts/dev/check.sh: no model, no
#     Docker) — against tests/evals/router/*.json:
#     * the ordered tab sequence of a guided `full` run, extracted from the
#       prompts in flow order: each command's `choice.sh --key KEY` calls, plus
#       the tabs declared only by an AskUserQuestion header (a choices.json key
#       with no choice.sh call, such as PUSH). New tabs may only be inserted:
#       the 0.9 sequence must stay a subsequence (CC-02);
#     * the router's mode words, in its argument-hint;
#     * the router's mode-inference rules: each cue sits in the rule that
#       names its mode.
#   --live (opt-in, never in --ci: needs a logged-in `claude` CLI) — real
#     `claude -p --plugin-dir` runs, told to report instead of acting:
#     * mode inference: `/drupilot <subject> <args>` must report the expected
#       mode (tests/evals/router/mode-inference.json live_cases);
#     * tab order: each command of the flow must report its tabs in the
#       statically extracted order, and `/drupilot ... auto` none;
#     each case runs --runs times and passes at >= 90% of the runs.
#
# Usage:
#   scripts/dev/evals.sh [--live] [--runs N] [--jobs N] [--plugin-root DIR]
#                        [--json] [-h|--help]
#     --live         run the live layer instead of the static one
#     --runs N       runs per live case (default 10)
#     --jobs N       live runs at a time (default 4)
#     --plugin-root  evaluate another drupilot tree (e.g. a v0.9.0 worktree)
#     --json         {ok, layer, checks|cases:[...]} on STDOUT
#
# Requires bash >= 3.2 and jq; --live also `claude`. Exit codes: 0 every check
# or case passes · 1 a failure or a usage error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVD="$REPO/tests/evals/router"
LIVE=0; RUNS=10; JOBS=4; PR=""; AS_JSON=0

usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --live) LIVE=1; shift;;
    --runs) RUNS="${2:-}"; shift 2 || die "--runs needs a value" 1;;
    --runs=*) RUNS="${1#*=}"; shift;;
    --jobs) JOBS="${2:-}"; shift 2 || die "--jobs needs a value" 1;;
    --jobs=*) JOBS="${1#*=}"; shift;;
    --plugin-root) PR="${2:-}"; shift 2 || die "--plugin-root needs a directory" 1;;
    --plugin-root=*) PR="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ "$RUNS" =~ ^[0-9]+$ && "$RUNS" -gt 0 && "$JOBS" =~ ^[0-9]+$ && "$JOBS" -gt 0 ]] || die "--runs and --jobs must be positive numbers" 1
have_cmd jq || die "jq is required by scripts/dev/evals.sh" 1
PR="${PR:-$REPO}"
[[ -f "$PR/commands/drupilot.md" ]] || die "Not a drupilot tree: $PR" 1
PR="$(cd "$PR" && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-evals.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
RESULTS="$TMP/results.jsonl"; : > "$RESULTS"; FAILED=0

result() {
  jq -n -c --arg n "$1" --arg s "$2" --arg d "$3" '{name: $n, status: $s, detail: $d}' >> "$RESULTS"
  if [[ "$2" == "pass" ]]; then log_ok "$1: $3"; else log_err "$1: $3"; FAILED=1; fi
  return 0
}

# tabs_of <file> -> the tab keys the file declares, in order, one per line.
tabs_of() {
  local f="$1" toks keyed
  toks="$(tr '\n' ' ' < "$f" | grep -oE 'choice\.sh"? --key [A-Z0-9_]+|header[[:space:]]+"[^"]+"' || true)"
  keyed="$(printf '%s\n' "$toks" | sed -n 's/^choice\.sh"\{0,1\} --key //p' | LC_ALL=C sort -u)"
  printf '%s\n' "$toks" | while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    case "$t" in
      choice*) printf '%s\n' "${t##* }";;
      header*)
        h="$(printf '%s' "$t" | sed -E 's/^header[[:space:]]+"(.*)"$/\1/')"
        k="$(jq -r --arg h "$h" '[.choices | to_entries[] | select(.value.header == $h) | .key][0] // empty' "$PR/config/choices.json")"
        [[ -n "$k" ]] && ! printf '%s\n' "$keyed" | grep -qxF -- "$k" && printf '%s\n' "$k";;
    esac
  done
  return 0
}

# --- Static layer -----------------------------------------------------------------
static_layer() {
  local f got want words hint block cue mode bullet
  got="$(for f in $(jq -r '.flow[]' "$EVD/tab-sequence.json"); do [[ -f "$PR/$f" ]] && tabs_of "$PR/$f"; done | jq -R . | jq -s -c .)"
  want="$(jq -c '.full' "$EVD/tab-sequence.json")"
  if [[ "$got" == "$want" ]]; then
    result "tab-sequence" pass "the full run declares the 0.9 tab sequence ($(printf '%s' "$want" | jq 'length') tabs)"
  elif jq -n -e --argjson o "$want" --argjson n "$got" '
      def subseq($a; $b): if ($a | length) == 0 then true elif ($b | length) == 0 then false
                          elif $a[0] == $b[0] then subseq($a[1:]; $b[1:]) else subseq($a; $b[1:]) end;
      subseq($o; $n)' > /dev/null; then
    result "tab-sequence" pass "the 0.9 tab sequence is kept, with inserted tabs: $got"
  else
    result "tab-sequence" fail "the tab sequence changed: got $got, want (as a subsequence) $want"
  fi
  words="$(jq -r '.mode_words | join("|")' "$EVD/mode-inference.json")"
  hint="$(awk 'NR == 1 && /^---/ { f = 1; next } f && /^---/ { exit } f && /^argument-hint:/' "$PR/commands/drupilot.md")"
  if printf '%s' "$hint" | grep -qF -- "[$words]"; then result "mode-words" pass "argument-hint offers [$words]"
  else result "mode-words" fail "argument-hint does not offer [$words]: $hint"; fi
  # The mode-inference rules: the block from "**Mode inference" to the next
  # top-level bullet, split into its sub-bullets.
  block="$(awk '/\*\*Mode inference/ { f = 1; next } f && /^- / { exit } f' "$PR/commands/drupilot.md")"
  [[ -n "$block" ]] || { result "mode-inference" fail "no 'Mode inference' rules in commands/drupilot.md"; return 0; }
  while IFS="$(printf '\t')" read -r cue mode; do
    bullet="$(printf '%s\n' "$block" | awk -v c="$cue" '
      /^  - / { if (b != "" && index(b, c)) { print b; found = 1; exit } b = $0; next }
      { b = b " " $0 }
      END { if (!found && b != "" && index(b, c)) print b }')"
    if [[ -n "$bullet" ]] && printf '%s' "$bullet" | grep -qF -- "**\`$mode\`**"; then
      result "mode-inference: $cue" pass "-> $mode"
    else
      result "mode-inference: $cue" fail "the rule holding \"$cue\" does not name **\`$mode\`**"
    fi
  done < <(jq -r '.static_cues[] | "\(.cue)\t\(.mode)"' "$EVD/mode-inference.json")
  return 0
}

# --- Live layer ---------------------------------------------------------------------
EVAL_MODE='This is an automated evaluation of the drupilot router. Do not call any tool and do not change anything. Read the command you were given and decide the effective run mode exactly as it instructs, from the arguments only. Then reply with exactly one line, DRUPILOT_MODE=<full|auto|next|status>, and nothing else.'
EVAL_TABS='This is an automated evaluation of a drupilot command. Do not call any tool and do not change anything. Read the command you were given and list, in order, every AskUserQuestion tab a guided interactive run of it would show when every condition fires, as one line TAB=<the tab header> each, and nothing else. If the run would show no tab at all, reply with exactly NO_TABS.'

# live_run <out> <system-prompt> <prompt> -> one claude -p run, its text in <out>.
live_run() {
  ( cd "$TMP/work" && timeout 600 claude --plugin-dir "$PR" -p "$3" --append-system-prompt "$2" \
      --disallowedTools "Bash Edit Write NotebookEdit Task Skill AskUserQuestion WebFetch WebSearch" < /dev/null > "$1" 2>/dev/null ) || true
  return 0
}

live_layer() {
  have_cmd claude || die "--live needs the claude CLI (logged in)" 1
  mkdir -p "$TMP/work" "$TMP/runs"
  cp -R "$REPO/tests/fixtures/legacy_widgets" "$TMP/work/"
  local subj="$TMP/work/legacy_widgets" i n name want prompt kind
  # The cases: "kind<TAB>name<TAB>prompt<TAB>expected".
  {
    jq -r --arg s "$subj" '.live_cases[] | "mode\t\(.name)\t/drupilot \($s) \(.args)\t\(.mode)"' "$EVD/mode-inference.json"
    for f in commands/drupilot-setup.md commands/drupilot-assess.md commands/drupilot-port.md commands/drupilot-refactor.md commands/drupilot-contribute.md; do
      printf 'tabs\t%s\t/%s %s\t%s\n' "$(basename "$f" .md)" "$(basename "$f" .md)" "$subj" "$(tabs_of "$PR/$f" | paste -sd, -)"
    done
    printf 'tabs\tdrupilot auto\t/drupilot %s auto\t\n' "$subj"
  } > "$TMP/cases.tsv"
  # Run every case --runs times, --jobs at a time.
  n=0
  while IFS="$(printf '\t')" read -r kind name prompt want; do
    for ((i = 1; i <= RUNS; i++)); do
      if [[ "$kind" == "mode" ]]; then live_run "$TMP/runs/$n.$i" "$EVAL_MODE" "$prompt" &
      else live_run "$TMP/runs/$n.$i" "$EVAL_TABS" "$prompt" &
      fi
      while [[ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]]; do sleep 1; done
    done
    n=$((n + 1))
  done < "$TMP/cases.tsv"
  wait
  # Score.
  n=0
  while IFS="$(printf '\t')" read -r kind name prompt want; do
    local ok=0 got obs=""
    for ((i = 1; i <= RUNS; i++)); do
      if [[ "$kind" == "mode" ]]; then
        got="$(sed -n 's/.*DRUPILOT_MODE=\([a-z]*\).*/\1/p' "$TMP/runs/$n.$i" 2>/dev/null | head -n 1)"
      else
        got="$(sed -n 's/^.*TAB=[[:space:]]*//p' "$TMP/runs/$n.$i" 2>/dev/null | while IFS= read -r h; do
                 h="$(printf '%s' "$h" | sed -E 's/[*`"]//g; s/[[:space:]]+$//')"
                 jq -r --arg h "$h" '[.choices | to_entries[] | select((.value.header | ascii_downcase) == ($h | ascii_downcase)) | .key][0] // ("?" + $h)' "$PR/config/choices.json"
               done | paste -sd, -)"
      fi
      [[ "$got" == "$want" ]] && ok=$((ok + 1))
      obs="$obs$got"$'\n'
    done
    local rate=$((ok * 100 / RUNS))
    jq -n -c --arg k "$kind" --arg n "$name" --arg w "$want" --argjson ok "$ok" --argjson runs "$RUNS" \
      --arg obs "$obs" '{kind: $k, name: $n, expected: $w, passed: $ok, runs: $runs,
        observed: ($obs | split("\n") | map(select(. != "")) | group_by(.) | map({(.[0]): length}) | add // {})}' >> "$TMP/live.jsonl"
    if [[ "$rate" -ge 90 ]]; then result "live $kind: $name" pass "$ok/$RUNS"
    else result "live $kind: $name" fail "$ok/$RUNS (want >= 90%)"; fi
    n=$((n + 1))
  done < "$TMP/cases.tsv"
  return 0
}

log_step "drupilot router evals: $([[ "$LIVE" == "1" ]] && echo "live, $RUNS run(s) per case" || echo static) ($([[ "$PR" == "$REPO" ]] && echo "this checkout" || echo "$PR"))"
if [[ "$LIVE" == "1" ]]; then live_layer; else static_layer; fi
if [[ "$FAILED" == "1" ]]; then log_err "evals.sh: at least one check failed"
else log_ok "evals.sh: every check passed"; fi
if [[ "$AS_JSON" == "1" ]]; then
  if [[ "$LIVE" == "1" ]]; then
    jq -s -c --argjson ok "$([[ "$FAILED" == "1" ]] && echo false || echo true)" --arg pr "$PR" \
      '{ok: $ok, layer: "live", plugin_root: $pr, cases: .}' "$TMP/live.jsonl"
  else
    jq -s -c --argjson ok "$([[ "$FAILED" == "1" ]] && echo false || echo true)" '{ok: $ok, layer: "static", checks: .}' "$RESULTS"
  fi
fi
exit "$FAILED"
