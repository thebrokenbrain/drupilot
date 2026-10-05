#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/dev/contract.sh
# The 0.9 public-surface contract (a developer/CI tool: no command, skill or
# hook calls it; scripts/dev/check.sh runs it as its `contract` gate). Each
# snapshot is GENERATED from the plugin tree (and, for exit codes, by running
# the scripts) and compared with the frozen copy in tests/contract/<name>.json:
#   commands         every command: name, argument-hint tokens in order,
#                    disable-model-invocation (CC-01, CC-02)
#   skills-agents    the skill and agent names (CC-32)
#   choices          the choice keys, and the PHP_TARGET header, options and
#                    default (CC-08, CC-29)
#   preflight-keys   the key sets of `preflight --json` and of
#                    `--profile all --extended --json` (CC-12)
#   port-summary-v1  the `port-summary --json` v1 keys (CC-18)
#   core-strategy-keys  the `core-strategy --json` keys (CC-11)
#   names            the patch, issue-patch, branch and test-bed name
#                    generators (CC-16, CC-17)
#   enums            the closed value sets, each value checked in the source
#                    files that own it (CC-07, CC-14, CC-20, CC-24, CC-36, ...)
#   exit-codes       per-script exit codes (CC-05), each triggered by running
#                    the script on a fixture or a stub (stub php/composer make
#                    the `analyze` gate pass everywhere; stub vendor/bin tools
#                    play each outcome); a code only DDEV can trigger is listed
#                    as "lab" and not run
#
# A snapshot passes when it is byte-identical to the frozen one, or when
# tests/contract/allowed-changes.json lists it with the sha256 of the new
# content (and the change has a CHANGELOG entry). In `commands`, an
# argument-hint that only GAINS tokens, in order (AR-25), passes as is.
#
# Usage:
#   scripts/dev/contract.sh [--check | --update] [--only N1,N2]
#                           [--plugin-root DIR] [--json] [-h|--help]
#     --check        generate and compare (the default)
#     --update       write the snapshots that do not exist yet (the initial
#                    seeding; an existing one is never overwritten: list an
#                    intended change in allowed-changes.json instead)
#     --only         a subset of the snapshots
#     --plugin-root  generate from another drupilot tree (e.g. a v0.9.0
#                    worktree), to prove the frozen snapshots are 0.9's
#     --json         {ok, mode, snapshots:[{name, status, detail}]} on STDOUT;
#                    status: same | allowed | additions | differs | missing |
#                    written
#
# Requires bash >= 3.2, jq and git. Exit codes: 0 every snapshot passes ·
# 1 a difference or a usage error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SH="${BASH:-bash}"
CDIR="$REPO/tests/contract"
ALLOWED="$CDIR/allowed-changes.json"
ALL="commands skills-agents choices preflight-keys port-summary-v1 core-strategy-keys names enums exit-codes"
MODE="check"; ONLY=""; PR=""; AS_JSON=0

usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift;;
    --update) MODE="update"; shift;;
    --only) ONLY="${2:-}"; shift 2 || die "--only needs a value" 1;;
    --only=*) ONLY="${1#*=}"; shift;;
    --plugin-root) PR="${2:-}"; shift 2 || die "--plugin-root needs a directory" 1;;
    --plugin-root=*) PR="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
have_cmd jq || die "jq is required by scripts/dev/contract.sh" 1
have_cmd git || die "git is required by scripts/dev/contract.sh" 1
in_list() { case ",$(printf '%s' "$2" | tr ' ' ','),"  in *",$1,"*) return 0;; esac; return 1; }
for _n in $(printf '%s' "$ONLY" | tr ',' ' '); do in_list "$_n" "$ALL" || die "Unknown snapshot: $_n ($ALL)" 1; done
PR="${PR:-$REPO}"
[[ -f "$PR/scripts/lib/common.sh" ]] || die "Not a drupilot tree: $PR" 1
PR="$(cd "$PR" && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-contract.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# --- Isolated environment (as smoke.sh) -----------------------------------------
for _v in $(env | sed -n 's/^\(DRUPILOT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
unset CLAUDE_PLUGIN_DATA CLAUDE_CONFIG_DIR
export CLAUDE_PLUGIN_ROOT="$PR" HOME="$TMP/home" LC_ALL=C GIT_CONFIG_NOSYSTEM=1
export XDG_DATA_HOME="$TMP/home/.local/share" XDG_STATE_HOME="$TMP/home/.local/state"
export XDG_CACHE_HOME="$TMP/home/.cache" XDG_CONFIG_HOME="$TMP/home/.config"
mkdir -p "$HOME" "$TMP/fx" "$TMP/gen"
cp -R "$REPO/tests/fixtures/legacy_widgets" "$REPO/tests/fixtures/monorepo" "$TMP/fx/"
LW="$TMP/fx/legacy_widgets"
CORE_MOD="$TMP/fx/monorepo/web/modules/custom/acme_core"
S="$PR/scripts"
G=(git -c user.name=contract -c user.email=contract@example.invalid -c commit.gpgsign=false)

# --- Generators: each prints the snapshot JSON on STDOUT --------------------------
# fm <file> <key> -> a YAML frontmatter value (unquoted), or nothing.
fm() {
  awk -v k="$2" 'NR == 1 && /^---/ { f = 1; next } f && /^---/ { exit }
                 f && index($0, k ":") == 1 { sub("^" k ":[[:space:]]*", ""); print; exit }' "$1"
}
unquote() { case "$1" in \"*\") v="${1#\"}"; printf '%s' "${v%\"}";; *) printf '%s' "$1";; esac; }

gen_commands() {
  local f n h d rows=""
  for f in "$PR"/commands/*.md; do
    n="$(fm "$f" name)"; [[ -n "$n" ]] || n="$(basename "$f" .md)"
    h="$(unquote "$(fm "$f" argument-hint)")"; d="$(fm "$f" disable-model-invocation)"
    rows="$rows$(jq -n -c --arg n "$n" --arg h "$h" --arg d "$d" \
      '{name: $n, argument_hint: ($h | split(" ") | map(select(. != ""))), disable_model_invocation: ($d == "true")}')"$'\n'
  done
  printf '%s' "$rows" | jq -s '{commands: sort_by(.name)}'
}

gen_skills_agents() {
  local f n s="" a=""
  for f in "$PR"/skills/*/SKILL.md; do n="$(fm "$f" name)"; s="$s${n:-$(basename "$(dirname "$f")")}"$'\n'; done
  for f in "$PR"/agents/*.md; do n="$(fm "$f" name)"; a="$a${n:-$(basename "$f" .md)}"$'\n'; done
  jq -n --arg s "$s" --arg a "$a" '{skills: ($s | split("\n") | map(select(. != "")) | sort), agents: ($a | split("\n") | map(select(. != "")) | sort)}'
}

gen_choices() {
  jq '{keys: (.choices | keys), php_target: (.choices.PHP_TARGET | {header, options, default})}' "$PR/config/choices.json"
}

gen_preflight_keys() {
  local v='{keys: keys, ready: (.ready | keys), check_keys: ([.checks[] | keys] | add | unique)}'
  jq -n --argjson p "$("$SH" "$S/env/preflight.sh" --json --subject "$LW" 2>/dev/null < /dev/null | jq -c "$v")" \
        --argjson e "$("$SH" "$S/env/preflight.sh" --profile all --extended --json --subject "$LW" 2>/dev/null < /dev/null \
                      | jq -c "$v + {toolchain: (if .toolchain == null then null else (.toolchain | keys) end)}")" \
        '{plain: $p, extended: $e}'
}

gen_port_summary_v1() {
  "$SH" "$S/analysis/port-summary.sh" --subject "$LW" --json 2>/dev/null < /dev/null \
    | jq '{schema_version, keys: keys, reports: (.reports | keys)}'
}

gen_core_strategy_keys() {
  "$SH" "$S/analysis/core-strategy.sh" --subject "$LW" --json 2>/dev/null < /dev/null | jq '{keys: keys}'
}

gen_names() {
  local m="$TMP/names/legacy_widgets" p1 p2 ws1 ws2 br r="$TMP/names/repo"
  mkdir -p "$TMP/names"; cp -R "$LW" "$m"
  "${G[@]}" -C "$m" init -q && "${G[@]}" -C "$m" add -A && "${G[@]}" -C "$m" commit -qm base
  printf '\n' >> "$m/legacy_widgets.module"
  p1="$("$SH" "$S/contrib/make-patch.sh" --local --subject "$m" 2>/dev/null < /dev/null || true)"
  p2="$("$SH" "$S/contrib/make-patch.sh" --local --subject "$m" --issue 1234567 --comment 8 2>/dev/null < /dev/null || true)"
  mkdir -p "$TMP/names/loose"; cp -R "$CORE_MOD" "$TMP/names/loose/"
  ws1="$("$SH" "$S/env/resolve-workspace.sh" --subject "$TMP/names/loose/acme_core" --json 2>/dev/null < /dev/null | jq -r '.drupal_root // empty')"
  cp -R "$REPO/tests/fixtures/monorepo" "$r"
  "${G[@]}" -C "$r" init -q && "${G[@]}" -C "$r" add -A && "${G[@]}" -C "$r" commit -qm base
  ws2="$("$SH" "$S/env/resolve-workspace.sh" --subject "$r/web/modules/custom/acme_core" --json 2>/dev/null < /dev/null | jq -r '.drupal_root // empty')"
  br="$(sed -n 's/.*NEW_BRANCH="\${BRANCH:-\$ISSUE-\([^"]*\)}".*/<issue>-\1/p' "$S/contrib/issue-fork.sh" | sed -n '1p')"
  # A name derived from the target major (T-M3-08): its value for the default
  # T. issue-fork.sh computes PATCH_DESC with target_patch_desc.
  if [[ "$br" == *'$PATCH_DESC'* ]] && grep -q '^PATCH_DESC="$(target_patch_desc)"$' "$S/contrib/issue-fork.sh"; then
    br="${br%%\$PATCH_DESC*}$("$SH" -c '. "$1/scripts/lib/common.sh"; target_patch_desc' _ "$PR" 2>/dev/null < /dev/null)${br#*\$PATCH_DESC}"
  fi
  jq -n --arg p1 "$(basename "$p1")" --arg p2 "$(basename "$p2")" --arg w1 "$(basename "$ws1")" \
        --arg w2 "$(basename "$ws2")" --arg br "$br" '
    {local_patch: ($p1 | sub("^legacy_widgets"; "<module>")),
     issue_patch: ($p2 | sub("^legacy_widgets"; "<module>") | sub("1234567"; "<issue>") | sub("-8[.]"; "-<comment>.")),
     issue_branch: $br,
     testbed_loose_module: ($w1 | sub("^acme_core"; "<module>")),
     testbed_project_checkout: ($w2 | sub("^repo"; "<project>"))}'
}

# The closed value sets, each read from the code that EMITS it (comment lines
# skipped), sorted: renaming, adding or dropping an emitted value changes the
# snapshot. (A whole-word grep of the file would still find a renamed value in
# a comment or a log line.)
# code <file> -> the file without its comment lines.
code() { grep -vE '^[[:space:]]*#' "$PR/$1" 2>/dev/null || true; }
# fn_body <file> <function> -> the code of one shell function.
fn_body() { code "$1" | awk -v f="$2" '!d && $0 ~ "^" f "\\(\\) *\\{" { on = 1 } on { print } on && /^}/ { on = 0; d = 1 }'; }
# code_lib -> the code of the whole shared library: the domain libs of
# scripts/lib/ (or the single common.sh of a tree before the lib split).
code_lib() { local f; for f in "$PR"/scripts/lib/*.sh; do grep -vE '^[[:space:]]*#' "$f" 2>/dev/null || true; done; return 0; }
# lib_fn_body <function> -> the code of one function of the shared library.
lib_fn_body() { code_lib | awk -v f="$1" '!d && $0 ~ "^" f "\\(\\) *\\{" { on = 1 } on { print } on && /^}/ { on = 0; d = 1 }'; }
sorted() { tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort -u | jq -R . | jq -s -c .; }

gen_enums() {
  local preservation stages inputs resolved d10 deps pstatus
  # run-phpunit.sh: every PRESERVATION="..." assignment.
  preservation="$(code scripts/tests/run-phpunit.sh | grep -oE 'PRESERVATION="[a-z-]+"' | sed 's/.*="//; s/"$//' | sorted)"
  # stage_rank (the shared library): its case labels, in the order of their rank (the
  # ladder, CC-20), so swapping two ranks changes the snapshot too.
  stages="$(lib_fn_body stage_rank | grep -oE '[a-z]+\) printf [1-9]' | sed 's/) printf / /' \
    | LC_ALL=C sort -k2n | cut -d' ' -f1 | jq -R . | jq -s -c .)"
  # preflight.sh: the values config_enum accepts for the strategy.
  inputs="$(code scripts/env/preflight.sh | awk '$1 == "config_enum" && $2 == "DRUPILOT_CORE_TARGET_STRATEGY" { for (i = 4; i <= NF && $i !~ /^[>|]/; i++) printf "%s ", $i }' | sorted)"
  # The shared library: resolved="..." strategies that are not inputs.
  resolved="$(code_lib | grep -oE 'resolved="[a-z0-9-]+"' | sed 's/.*="//; s/"$//' | sorted \
    | jq -c --argjson in "$inputs" '. - $in')"
  # d10_support: D10_SUPPORT/d10_support assignments, the literals of the jq
  # program that computes D10_SUPPORT, and verify-core-matrix's jq default.
  d10="$( { code scripts/analysis/verify-core-matrix.sh | grep -oE 'D10_SUPPORT="[a-z/-]+"'
            code scripts/analysis/verify-core-matrix.sh | awk '!d && /^D10_SUPPORT="\$\(/ { on = 1 } on { print } on && /'"'"'\)"$/ { on = 0; d = 1 }' \
              | grep -oE '(then|else) "[a-z/-]+"'
            code scripts/analysis/verify-core-matrix.sh | grep -oE 'd10_support: \(if .* end\)' | grep -oE '"[a-z/-]+"'
            code_lib | grep -oE 'd10_support="[a-z/-]+"'; } \
          | grep -oE '"[a-z/-]+"' | tr -d '"' | sorted)"
  # deps-status.sh: what d11_status prints, and the st="..." its main loop
  # sets (core for a core module).
  deps="$( { fn_body scripts/analysis/deps-status.sh d11_status | grep -oE "printf '[a-z-]+'" | sed "s/printf '//; s/'$//"
             code scripts/analysis/deps-status.sh | grep -oE 'st="[a-z-]+"' | sed 's/st="//; s/"$//'; } | sorted)"
  # port-summary.sh: the literals of its status expression, plus the stages it passes through.
  pstatus="$(code scripts/analysis/port-summary.sh | grep -E '^[[:space:]]*status: \(if' | grep -oE '"[a-z-]+"' | tr -d '"' | sorted \
    | jq -c --argjson st "$stages" '. + $st | unique')"
  jq -n --argjson preservation "$preservation" --argjson stages "$stages" --argjson inputs "$inputs" \
    --argjson resolved "$resolved" --argjson d10 "$d10" --argjson deps "$deps" --argjson ps "$pstatus" \
    --argjson rs "$(jq -c '.choices.REFACTOR_SCOPE.options' "$PR/config/choices.json")" \
    '{preservation: $preservation, stages: $stages, strategy_inputs: $inputs, strategy_resolved_only: $resolved,
      d10_support: $d10, deps_status: $deps, port_summary_status: $ps, refactor_scope: $rs}' | jq -S .
}

# --- Exit codes (CC-05) --------------------------------------------------------
mk_bin() { printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
setup_exit_env() {
  local r="$TMP/xroot" p
  STUBS="$TMP/stubs"; mkdir -p "$STUBS"
  mk_bin "$STUBS/php" 'case "$1" in -r) echo 8.3.30;; -v) echo "PHP 8.3.30 (cli)";; -l) echo "No syntax errors detected in $2";; esac; exit 0'
  mk_bin "$STUBS/composer" 'echo "Composer version 2.8.0 2025-01-01 00:00:00"; exit 0'
  NOGIT="$TMP/nogit"; mkdir -p "$NOGIT"
  ( IFS=:; for p in $PATH; do [[ -d "$p" ]] && ln -s "$p"/* "$NOGIT"/ 2>/dev/null; done; true )
  rm -f "$NOGIT/git"
  ln -s "$STUBS/php" "$NOGIT/php" 2>/dev/null || true
  ln -s "$STUBS/composer" "$NOGIT/composer" 2>/dev/null || true
  mkdir -p "$r/web/core/lib" "$r/web/modules/custom" "$r/vendor/bin"
  printf '{"name": "drupilot-contract/stub-root"}\n' > "$r/composer.json"
  printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$r/web/core/lib/Drupal.php"
  cp -R "$LW" "$CORE_MOD" "$r/web/modules/custom/"
  XROOT="$r"
  # The stub tools play the outcome named in $r/mode.
  mk_bin "$r/vendor/bin/rector" 'm="$(cat "$(dirname "$0")/../../mode" 2>/dev/null)"; case "$m" in rector-crash) echo " [ERROR] Could not process: boom"; exit 1;; *) echo " [OK] Rector is done!"; exit 0;; esac'
  mk_bin "$r/vendor/bin/phpstan" 'm="$(cat "$(dirname "$0")/../../mode" 2>/dev/null)"; case "$m" in
  phpstan-clean) echo "{\"totals\":{\"errors\":0,\"file_errors\":0},\"files\":{},\"errors\":[]}"; exit 0;;
  phpstan-findings) echo "{\"totals\":{\"errors\":0,\"file_errors\":1},\"files\":{\"a.php\":{\"errors\":1,\"messages\":[{\"message\":\"x\",\"line\":1}]}},\"errors\":[]}"; exit 1;;
  *) echo "PHP Fatal error: boom" >&2; exit 255;; esac'
  mk_bin "$r/vendor/bin/phpcs" 'case " $* " in *" -i "*) echo "The installed coding standards are Drupal and DrupalPractice"; exit 0;; esac; m="$(cat "$(dirname "$0")/../../mode" 2>/dev/null)"; case "$m" in phpcs-3) echo "ERROR: Referenced sniff \"NoSuchStandard\" does not exist"; exit 3;; *) exit 0;; esac'
  cp "$r/vendor/bin/phpcs" "$r/vendor/bin/phpcbf"
  printf '<?xml version="1.0"?>\n<ruleset name="bad"><rule ref="NoSuchStandard"/></ruleset>\n' > "$r/bad-ruleset.xml"
  return 0
}

# xc <script> <code> <case> <mode> <env...> -- <args...> -> one result line:
# "<script>\t<code>\t<case>\t<observed>".
xc() {
  local script="$1" code="$2" case_="$3" mode="$4" rc; shift 4
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  printf '%s' "$mode" > "$XROOT/mode"
  if (cd "$XROOT" && env PATH="$STUBS:$PATH" ${envs[@]+"${envs[@]}"} "$SH" "$S/$script" "$@") > /dev/null 2>&1 < /dev/null; then rc=0; else rc=$?; fi
  printf '%s\t%s\t%s\t%s\n' "$(basename "$script")" "$code" "$case_" "$rc"
}
xlab() { printf '%s\t%s\t%s\tlab\n' "$(basename "$1")" "$2" "$3"; }

gen_exit_codes() {
  setup_exit_env
  local sub="web/modules/custom/legacy_widgets" core="web/modules/custom/acme_core" bad="$TMP/fx/not-a-module" st
  mkdir -p "$bad"
  # A canned state that makes port-summary's status "blocked": ported, and the
  # last test run (freshness unknown) is a regression.
  st="$("$SH" -c '. "$1/scripts/lib/common.sh"; project_state_dir "$2"' _ "$PR" "$XROOT/$core" < /dev/null)"
  printf '{"schema":1,"stage":"ported","stages":{"ported":"2026-10-03T00:00:00Z"},"machine_name":"acme_core","type":"module"}\n' > "$st/state.json"
  printf '{"status":"failed","preservation":"regression"}\n' > "$st/last-test.json"
  {
    xc env/preflight.sh 0 "profile all" - -- --profile all --json --subject "$LW"
    xc env/preflight.sh 0 "analyze ready (stub php, composer)" - -- --profile analyze --json --subject "$LW"
    xc env/preflight.sh 2 "analyze without git" - PATH="$NOGIT" -- --profile analyze --json --subject "$LW"
    xc analysis/check-port-safety.sh 0 "no error finding" - -- --subject "$core" --no-diff --json
    xc analysis/check-port-safety.sh 3 "error findings (legacy_widgets)" - -- --subject "$sub" --no-diff --json
    xc analysis/check-port-safety.sh 1 "usage: no --subject" - -- --json
    xc analysis/scan-signature-changes.sh 0 "no error finding" - -- --subject "$core" --json
    xc analysis/scan-signature-changes.sh 3 "error findings (legacy_widgets)" - -- --subject "$sub" --json
    xc analysis/scan-signature-changes.sh 1 "usage: no --subject" - -- --json
    xc analysis/port-summary.sh 0 "no state" - -- --subject "$sub" --json
    xc analysis/port-summary.sh 3 "--strict, status blocked" - -- --subject "$core" --strict --json
    xc analysis/port-summary.sh 1 "not a module" - -- --subject "$bad" --json
    xc analysis/run-rector.sh 0 "ok (stub rector)" rector-ok -- --subject "$sub" --json
    xc analysis/run-rector.sh 1 "usage: no --subject" - -- --json
    xc analysis/run-rector.sh 2 "gate: analyze not ready (no git)" - PATH="$NOGIT" -- --subject "$sub" --json
    xc analysis/run-rector.sh 3 "official pass crashed (stub rector)" rector-crash -- --subject "$sub" --json
    xlab analysis/run-rector.sh 4 "only the digests pass crashed (needs the digests checkout)"
    xc analysis/run-phpstan.sh 0 "no issues (stub phpstan)" phpstan-clean -- --subject "$sub" --json
    xc analysis/run-phpstan.sh 1 "findings (stub phpstan)" phpstan-findings -- --subject "$sub" --json
    xc analysis/run-phpstan.sh 2 "gate: analyze not ready (no git)" - PATH="$NOGIT" -- --subject "$sub" --json
    xc analysis/run-phpstan.sh 3 "crashed, no verdict (stub phpstan)" phpstan-crash -- --subject "$sub" --json
    xc analysis/run-phpcs.sh 0 "PHPCS exit 0 passed through" phpcs-0 -- --subject "$core"
    xc analysis/run-phpcs.sh 3 "PHPCS exit 3 passed through" phpcs-3 -- --subject "$core"
    xc analysis/run-phpcs.sh 1 "usage: bad --fix-scope" - -- --subject "$core" --fix --fix-scope bogus
    xc analysis/run-phpcs.sh 1 "usage: a ruleset path that does not exist" phpcs-0 DRUPILOT_PHPCS_RULESET=/nonexistent/ruleset.xml -- --subject "$core"
    xc analysis/run-phpcs.sh 2 "an explicit ruleset PHPCS cannot load (stub)" phpcs-3 DRUPILOT_PHPCS_RULESET="$XROOT/bad-ruleset.xml" -- --subject "$core"
    xc analysis/verify-core-matrix.sh 0 "--dry-run" - -- --subject "$sub" --dry-run --json
    xc analysis/verify-core-matrix.sh 1 "usage: unknown flag" - -- --subject "$sub" --bogus
    xlab analysis/verify-core-matrix.sh 2 "requirements or no DDEV bed (needs Docker to tell apart)"
    xlab analysis/verify-core-matrix.sh 3 "a leg failed (needs DDEV reference cores)"
    xc tests/run-phpunit.sh 1 "usage: invalid --type" - -- --subject "$sub" --type bogus
    xc tests/run-phpunit.sh 2 "no vendor/bin/phpunit, or no Docker/DDEV" - -- --subject "$sub" --json
    xlab tests/run-phpunit.sh 0 "suite green (needs DDEV + PHPUnit)"
    xlab tests/run-phpunit.sh 3 "a group failed (needs DDEV + PHPUnit)"
  } > "$TMP/exit-codes.tsv"
  jq -R -s 'split("\n") | map(select(. != "") | split("\t") | {script: .[0], code: (.[1] | tonumber), case: .[2], observed: .[3]})
            | map(. + {ok: (.observed == "lab" or .observed == (.code | tostring))})
            | sort_by(.script, .code, .case)' "$TMP/exit-codes.tsv"
}

# --- Compare ---------------------------------------------------------------------
RESULTS="$TMP/results.jsonl"; : > "$RESULTS"; FAILED=0
HASHER=""
if have_cmd sha256sum; then HASHER="sha256sum"; elif have_cmd shasum; then HASHER="shasum -a 256"; fi
result() {
  jq -n -c --arg n "$1" --arg s "$2" --arg d "$3" '{name: $n, status: $s, detail: $d}' >> "$RESULTS"
  case "$2" in
    same|written) log_ok "$1: $3";;
    allowed|additions) log_info "$1: $2 — $3";;
    *) log_err "$1: $2 — $3"; FAILED=1;;
  esac
  return 0
}
# allowed_for <snapshot> <sha256> -> the reason of the allowed-changes.json
# entry that pins this exact new snapshot (any entry of the snapshot may: a
# snapshot changed twice has two entries), or nothing.
allowed_for() {
  [[ -f "$ALLOWED" && -n "$2" ]] || return 0
  jq -r --arg f "$1.json" --arg h "$2" '[.changes[]? | select(.snapshot == $f and .sha256 == $h) | .reason][0] // empty' "$ALLOWED" 2>/dev/null || true
  return 0
}

log_step "drupilot 0.9 contract: $MODE ($([[ "$PR" == "$REPO" ]] && echo "this checkout" || echo "$PR"))"
for name in $ALL; do
  if [[ -n "$ONLY" ]] && ! in_list "$name" "$ONLY"; then continue; fi
  fn="gen_$(printf '%s' "$name" | tr '-' '_')"
  new="$TMP/gen/$name.json"
  "$fn" | jq -S . > "$new" 2>/dev/null || { result "$name" differs "the generator failed"; continue; }
  frozen="$CDIR/$name.json"
  if [[ "$MODE" == "update" ]]; then
    if [[ -f "$frozen" ]]; then result "$name" same "exists: not overwritten (list an intended change in allowed-changes.json)"
    else mkdir -p "$CDIR"; cp "$new" "$frozen"; result "$name" written "tests/contract/$name.json"; fi
    continue
  fi
  if [[ ! -f "$frozen" ]]; then result "$name" missing "tests/contract/$name.json does not exist (--update seeds it)"; continue; fi
  if cmp -s "$new" "$frozen"; then result "$name" same "identical"; continue; fi
  if [[ "$name" == "exit-codes" ]] && jq -e '[.[] | select(.ok | not)] | length > 0' "$new" > /dev/null 2>&1; then
    result "$name" differs "documented code not observed: $(jq -r '[.[] | select(.ok | not) | "\(.script) \(.code) (\(.case)): got \(.observed)"] | join("; ")' "$new")"
    continue
  fi
  if [[ "$name" == "commands" ]] && jq -n -e --slurpfile o "$frozen" --slurpfile n "$new" '
      def subseq($a; $b): if ($a | length) == 0 then true elif ($b | length) == 0 then false
                          elif $a[0] == $b[0] then subseq($a[1:]; $b[1:]) else subseq($a; $b[1:]) end;
      ($o[0].commands | map({key: .name, value: .}) | from_entries) as $old
      | ($n[0].commands | map({key: .name, value: .}) | from_entries) as $cur
      | ($old | keys) == ($cur | keys)
        and all($old | keys[]; . as $k | $old[$k].disable_model_invocation == $cur[$k].disable_model_invocation
                                and subseq($old[$k].argument_hint; $cur[$k].argument_hint))' > /dev/null 2>&1; then
    result "$name" additions "argument-hint tokens only added, in order (AR-25)"
    continue
  fi
  h=""; [[ -n "$HASHER" ]] && h="$($HASHER < "$new" | cut -d' ' -f1)"
  a="$(allowed_for "$name" "$h")"
  if [[ -n "$a" ]]; then result "$name" allowed "$a"; continue; fi
  diff -u "$frozen" "$new" 2>/dev/null | sed -n '1,40p' | sed 's/^/    /' >&2 || true
  result "$name" differs "differs from tests/contract/$name.json; to allow, add {\"snapshot\": \"$name.json\", \"sha256\": \"$h\", \"reason\": \"...\"} to allowed-changes.json"
done

if [[ "$FAILED" == "1" ]]; then log_err "contract.sh: the public surface differs from the 0.9 contract"
else log_ok "contract.sh: the public surface keeps the 0.9 contract"; fi
if [[ "$AS_JSON" == "1" ]]; then
  jq -s -c --argjson ok "$([[ "$FAILED" == "1" ]] && echo false || echo true)" --arg m "$MODE" \
    '{ok: $ok, mode: $m, snapshots: .}' "$RESULTS"
fi
exit "$FAILED"
