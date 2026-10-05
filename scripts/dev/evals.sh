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
#       with no choice.sh call, such as PUSH). New tabs may only be inserted
#       (CC-02), each as tab-sequence.json's allowed_insertions lists it: right
#       before the 0.9 tab it names (D32); without them, the 0.9 sequence;
#     * the router's mode words, in its argument-hint;
#     * the router's mode-inference rules: each cue's mode is the first bold
#       **`mode`** after it in its rule, else the last one before it;
#     * the auto_rules of tab-sequence.json: the prompt rules that keep an
#       `auto` run tab-free and push-free must still be stated.
#   --live (opt-in, never in --ci: needs a logged-in `claude` CLI) — real
#     `claude -p --plugin-dir` runs, told to report instead of acting:
#     * mode inference: `/drupilot <subject> <args>` must report the expected
#       mode (tests/evals/router/mode-inference.json live_cases);
#     * tab order: each command of the flow must report its tabs in the
#       statically extracted order, and `/drupilot ... auto` none;
#     each case runs --runs times and passes at >= 90% of the runs. A run
#     invokes the namespaced command (`/drupilot:<command>`) with a settings
#     file whose PreToolUse hook denies every tool call, so the model can
#     read but never act; the command's load-time lines still run (Claude
#     Code refuses them when Bash is disallowed). The same settings disable,
#     for that run only, any installed `drupilot@*` plugin, so the tree under
#     test is the only drupilot loaded.
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

# tabs_of <file> -> the tab keys the file declares, in order, one per line:
# its `choice.sh --key KEY` calls, plus each choices.json header the file
# declares without such a call — as an AskUserQuestion `header "..."`, or, in
# a command, as a `"<header>" tab` it shows (drupilot-refactor.md reuses the
# port's "Drupal 10 check" tab that way). An agent's `"<header>" tab` mentions
# narrate the commands' tabs and are not counted again.
tabs_of() {
  local f="$1" toks keyed h k
  toks="$(tr '\n' ' ' < "$f" | grep -oE 'choice\.sh"? --key [A-Z0-9_]+|header[[:space:]]+"[^"]+"|"[^"]{1,60}"[[:space:]]+tabs?[^a-zA-Z]' || true)"
  keyed="$(printf '%s\n' "$toks" | sed -n 's/^choice\.sh"\{0,1\} --key //p' | LC_ALL=C sort -u)"
  printf '%s\n' "$toks" | while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    case "$t" in
      choice*) printf '%s\n' "${t##* }"; continue;;
      header*) h="$(printf '%s' "$t" | sed -E 's/^header[[:space:]]+"(.*)"$/\1/')";;
      *) case "$f" in */commands/*) ;; *) continue;; esac
         h="$(printf '%s' "$t" | sed -E 's/^"([^"]*)".*$/\1/')";;
    esac
    k="$(jq -r --arg h "$h" '[.choices | to_entries[] | select(.value.header == $h) | .key][0] // empty' "$PR/config/choices.json")"
    if [[ -n "$k" ]] && ! printf '%s\n' "$keyed" | grep_q -xF -- "$k"; then printf '%s\n' "$k"; fi
  done
  return 0
}

# --- Static layer -----------------------------------------------------------------
static_layer() {
  local f got want words hint block cue mode
  got="$(for f in $(jq -r '.flow[]' "$EVD/tab-sequence.json"); do if [[ -f "$PR/$f" ]]; then tabs_of "$PR/$f"; fi; done | jq -R . | jq -s -c .)"
  want="$(jq -c '.full' "$EVD/tab-sequence.json")"
  if [[ "$got" == "$want" ]]; then
    result "tab-sequence" pass "the full run declares the 0.9 tab sequence ($(printf '%s' "$want" | jq 'length') tabs)"
  elif jq -n -e --argjson o "$want" --argjson n "$got" --argjson ins "$(jq -c '.allowed_insertions // []' "$EVD/tab-sequence.json")" '
      # Drop each allowed insertion that stands right before the tab it names;
      # what is left must be the 0.9 sequence itself.
      $n | . as $a
      | [range(0; length) as $i | select(any($ins[]; .key == $a[$i] and .before == ($a[$i + 1] // null)) | not) | $a[$i]]
      | . == $o' > /dev/null; then
    result "tab-sequence" pass "the 0.9 tab sequence is kept, with the allowed insertions: $got"
  else
    result "tab-sequence" fail "the tab sequence changed: got $got, want $want (a new tab only as tests/evals/router/tab-sequence.json allowed_insertions lists it)"
  fi
  words="$(jq -r '.mode_words | join("|")' "$EVD/mode-inference.json")"
  hint="$(awk 'NR == 1 && /^---/ { f = 1; next } f && /^---/ { exit } f && /^argument-hint:/' "$PR/commands/drupilot.md")"
  if printf '%s' "$hint" | grep_q -F -- "[$words]"; then result "mode-words" pass "argument-hint offers [$words]"
  else result "mode-words" fail "argument-hint does not offer [$words]: $hint"; fi
  # The mode-inference rules: the block from "**Mode inference" to the next
  # top-level bullet, split into its sub-bullets.
  block="$(awk '/\*\*Mode inference/ { f = 1; next } f && /^- / { exit } f' "$PR/commands/drupilot.md")"
  [[ -n "$block" ]] || { result "mode-inference" fail "no 'Mode inference' rules in commands/drupilot.md"; return 0; }
  # A cue's mode is the first bold **`mode`** after it in its rule (the
  # clause's result), else the last one before it (a qualifier listed after
  # its mode, e.g. the unattended cues after **`auto`**).
  while IFS="$(printf '\t')" read -r cue mode; do
    got="$(printf '%s\n' "$block" | awk -v c="$cue" '
      function bind(b,    p, rest, before, last) {
        gsub(/[[:space:]]+/, " ", b); p = index(b, c); if (!p) return ""
        rest = substr(b, p + length(c))
        if (match(rest, /[*][*]`[a-z]+`[*][*]/)) return substr(rest, RSTART + 3, RLENGTH - 6)
        before = substr(b, 1, p - 1); last = ""
        while (match(before, /[*][*]`[a-z]+`[*][*]/)) { last = substr(before, RSTART + 3, RLENGTH - 6); before = substr(before, RSTART + RLENGTH) }
        return last
      }
      done { next }
      /^  - / { if (b != "") { m = bind(b); if (m != "") { print m; done = 1; next } } b = $0; next }
      { b = b " " $0 }
      END { if (!done && b != "") { m = bind(b); if (m != "") print m } }')"
    if [[ "$got" == "$mode" ]]; then
      result "mode-inference: $cue" pass "-> $mode"
    else
      result "mode-inference: $cue" fail "the rule holding \"$cue\" maps it to **\`${got:-nothing}\`**, want **\`$mode\`**"
    fi
  done < <(jq -r '.static_cues[] | "\(.cue)\t\(.mode)"' "$EVD/mode-inference.json")
  # The rules that keep an auto run tab-free and push-free (the live layer
  # checks the behaviour itself): each must still be stated where listed.
  while IFS="$(printf '\t')" read -r f cue; do
    if tr '\n' ' ' < "$PR/$f" 2>/dev/null | tr -s '[:space:]' ' ' | grep_q -F -- "$cue"; then
      result "auto rule: $cue" pass "stated in $f"
    else
      result "auto rule: $cue" fail "$f no longer states it"
    fi
  done < <(jq -r '.auto_rules[]? | "\(.file)\t\(.cue)"' "$EVD/tab-sequence.json")
  return 0
}

# --- Live layer ---------------------------------------------------------------------
EVAL_MODE='This is an automated evaluation of the drupilot router. Do not call any tool and do not change anything. Read the command you were given and decide the effective run mode exactly as it instructs, from the arguments only. Then reply in English with exactly one line, DRUPILOT_MODE=<full|auto|next|status>, and nothing else.'
EVAL_TABS='This is an automated evaluation of a drupilot command. Do not call any tool and do not change anything. Read the command you were given and list, in order, every AskUserQuestion tab that this exact invocation would show, assuming that every condition depending on the state of the project or of the environment fires, but that the arguments you were given (such as a mode word) still rule out what they rule out. Reply in English with one line TAB=<the tab header> per tab, copying each header verbatim as written in the command or in config/choices.json, and nothing else. If the invocation would show no tab at all, reply with exactly NO_TABS.'

# live_run <out> <system-prompt> <prompt> -> one claude -p run, its text in <out>.
# The command's load-time lines run real (read-only) scripts: their data dir
# is a temp one (DRUPILOT_HOME for 0.9.1+, XDG_DATA_HOME as its fallback), so
# a run never reads or migrates the developer's own drupilot state.
live_run() {
  ( cd "$TMP/work" && DRUPILOT_HOME="$TMP/data" XDG_DATA_HOME="$TMP/xdg" \
      run_with_timeout 600 claude --plugin-dir "$PR" --settings "$TMP/settings.json" -p "$3" \
      --append-system-prompt "$2" \
      --disallowedTools "Edit Write NotebookEdit Task Skill AskUserQuestion WebFetch WebSearch" < /dev/null > "$1" 2>/dev/null \
    && echo 0 > "$1.rc" || echo 1 > "$1.rc" )
  return 0
}

# live_settings -> $TMP/settings.json: a PreToolUse hook that denies every tool
# call, and every installed drupilot@* plugin disabled for these runs.
live_settings() {
  local deny installed
  deny='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"drupilot evals: no tool may run"}}'
  installed="$(jq -c '[.enabledPlugins // {} | keys[] | select(startswith("drupilot@"))] | map({(.): false}) | add // {}' \
                 "$HOME/.claude/settings.json" 2>/dev/null || echo '{}')"
  jq -n --arg cmd "printf '%s' '$deny'" --argjson off "$installed" \
    '{enabledPlugins: $off, hooks: {PreToolUse: [{matcher: "*", hooks: [{type: "command", command: $cmd}]}]}}' \
    > "$TMP/settings.json"
  return 0
}

live_layer() {
  have_cmd claude || die "--live needs the claude CLI (logged in)" 1
  mkdir -p "$TMP/work" "$TMP/runs" "$TMP/data" "$TMP/xdg"
  live_settings
  local ns
  ns="$(jq -r '.name // "drupilot"' "$PR/.claude-plugin/plugin.json" 2>/dev/null || echo drupilot)"
  cp -R "$REPO/tests/fixtures/legacy_widgets" "$TMP/work/"
  local subj="$TMP/work/legacy_widgets" i n name want prompt kind
  # The cases: "kind<TAB>name<TAB>prompt<TAB>expected".
  {
    jq -r --arg s "$subj" --arg ns "$ns" '.live_cases[] | "mode\t\(.name)\t/\($ns):drupilot \($s) \(.args)\t\(.mode)"' "$EVD/mode-inference.json"
    for f in commands/drupilot-setup.md commands/drupilot-assess.md commands/drupilot-port.md commands/drupilot-refactor.md commands/drupilot-contribute.md; do
      want="$(tabs_of "$PR/$f" | paste -sd, -)"
      printf 'tabs\t%s\t/%s:%s %s\t%s\n' "$(basename "$f" .md)" "$ns" "$(basename "$f" .md)" "$subj" "${want:-NO_TABS}"
    done
    # The auto run: the tabs tests/evals/router/tab-sequence.json .auto lists,
    # or, for none, an explicit NO_TABS reply.
    printf 'tabs\tdrupilot auto\t/%s:drupilot %s auto\t%s\n' "$ns" "$subj" \
      "$(jq -r '.auto | if length == 0 then "NO_TABS" else join(",") end' "$EVD/tab-sequence.json")"
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
      if [[ "$(cat "$TMP/runs/$n.$i.rc" 2>/dev/null)" != "0" || ! -s "$TMP/runs/$n.$i" ]]; then
        got="<no answer>"   # claude failed, timed out or printed nothing: never equals an expectation
      elif [[ "$kind" == "mode" ]]; then
        got="$(sed -n 's/.*DRUPILOT_MODE=\([a-z]*\).*/\1/p' "$TMP/runs/$n.$i" 2>/dev/null | sed -n '1p')"
      elif ! grep -q 'TAB=' "$TMP/runs/$n.$i" && grep -qx '[[:space:]]*NO_TABS[[:space:]]*' "$TMP/runs/$n.$i"; then
        got="NO_TABS"
      else
        got="$(sed -n 's/^.*TAB=[[:space:]]*//p' "$TMP/runs/$n.$i" 2>/dev/null | while IFS= read -r h; do
                 h="$(printf '%s' "$h" | sed -E 's/[*`"]//g; s/[[:space:]]+$//')"
                 jq -r --arg h "$h" '($h | ascii_upcase | gsub("[^A-Z0-9]+"; "_")) as $k
                   | [.choices | to_entries[] | select((.value.header | ascii_downcase) == ($h | ascii_downcase) or .key == $k) | .key][0]
                     // ("?" + $h)' "$PR/config/choices.json"
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
