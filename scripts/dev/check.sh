#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/dev/check.sh
# The single local developer gate for the plugin itself (it never runs at plugin
# runtime: no command, skill or hook calls it). Run it before every commit.
#
# Gates (in order; names are what --only/--skip/--allow-fail take):
#   - validate    `claude plugin validate .` (skipped when `claude` is absent)
#   - syntax      `bash -n` on scripts/*.sh, scripts/*/*.sh, hooks/scripts/*.sh and the test
#                 scripts tests/lib/*.sh and tests/unit/*.sh
#   - exec-bit    those scripts are executable (git mode 100755 when tracked,
#                 the filesystem -x bit otherwise)
#   - shellcheck  `shellcheck -S warning` on the same scripts (reads .shellcheckrc;
#                 skipped when shellcheck is absent)
#   - portability no bash-4-only or GNU-only construct in those scripts (they
#                 must run on bash 3.2 + BSD tools, i.e. stock macOS): ${x,,},
#                 ${x^^}, declare/local -A|-n|-g, mapfile/readarray, sed -i,
#                 readlink -f, realpath, grep -P, an --include, --exclude or
#                 --exclude-dir option anywhere on a line without tar, rsync,
#                 curl, phpcs or phpcbf (BusyBox grep has none of them; select
#                 the files with find; a grep pattern after `--` or another
#                 tool's option needs `# portability-ok`), date -d,
#                 xargs -r, stat -c, find -printf, envsubst, a regex interval ({n}, {n,m})
#                 in an awk regex literal (mawk 1.3.4-20200120, the default awk
#                 on Debian 12 / Ubuntu 22.04, matches it as literal text),
#                 and a `case` inside `$(...)` whose patterns lack the leading
#                 `(` (bash 3.2 ends the substitution at the first pattern's
#                 `)`; `bash -n` does not see it).
#                 Comment text is ignored; a line can
#                 opt out with a trailing `# portability-ok` and a reason
#   - special-vars no script assigns, declares, reads into or loops over a bash
#                 special variable (GROUPS, RANDOM, SECONDS, LINENO, UID, EUID,
#                 PPID, BASHPID, HOSTNAME, PWD, PIPESTATUS, BASH_SOURCE, ...):
#                 bash ignores or overrides such assignments silently (a
#                 `GROUPS=(Unit ...)` once made run-phpunit.sh run no test).
#                 A line can opt out with a trailing `# special-var-ok` and a reason
#   - sigpipe     no pipeline in scripts/ or hooks/ (they run under pipefail)
#                 ends in a consumer that stops reading early: `| head`,
#                 `| grep -q` / `-l` / `-L` / `-m` / `--quiet`, `| cmp`
#                 (it stops at the first difference), an `| awk` program
#                 that calls `exit` on the same line. The producer
#                 then dies of SIGPIPE when it writes after the consumer left,
#                 and pipefail turns that race into a failed pipeline: a wrong
#                 `if`, or set -e aborting with exit 141 (seen under load and
#                 with BusyBox tools). Use grep_q (common.sh), sed -n '1p' /
#                 '1,Np', or an awk flag instead of exit. A line can opt out
#                 with a trailing `# sigpipe-ok` and a reason
#   - scripts     (AR-22) every script of scripts/*.sh and scripts/<group>/*.sh
#                 but scripts/dev/ sources common.sh at its depth (a
#                 non-comment line in the canonical form), answers --help with
#                 exit 0 and a Usage section, and refuses an unknown flag with
#                 exit 1 (probed as `--drupilot-no-such-flag --help`, so no
#                 script body runs; a 0.9 script that skips an unknown flag
#                 keeps its frozen CLI: rule AR22-FLAG of hard-rules-allow.txt);
#                 run in an empty directory with HOME and XDG in a temp dir and
#                 every DRUPILOT_* unset. AR-22's `--json` check stays with the
#                 smoke tests, which run the scripts on fixtures
#   - hard-rules  (T-M3-12, alias no-version-literals) the greppable hard
#                 rules over scripts and PHP templates (comment lines skipped)
#                 and the prompts: SleepToSerialize/WakeupToUnserialize outside
#                 a skip list (H2), withComposerBased( (H3), a drupal.org docs
#                 or project releases URL, the HTML pages H5 forbids, a
#                 hard-coded "Drupal 12 stable" (H6), a three-major range
#                 literal (H7), a drush migrate:import (H9), the forbidden
#                 Drupal10SetList::DRUPAL_10 aggregate (AGG), a DDEV type
#                 literal drupalNN outside scripts/lib/plan.sh (DDEV), a lock
#                 path spelled outside scripts/lib/lock.sh (LOCK: readers go
#                 through lock_path / drupilot_lock_file, AR-14), and in
#                 the scripts exactly as many version-literal lines per file as
#                 tests/contract/hard-rules-allow.txt records (H4, a ratchet: a
#                 new literal fails, and a removed one asks to lower the count;
#                 read versions through plan_get / target_get). H1 is checked by
#                 the rendered rector.php (rector_php_floor), H8 by the resolver.
#                 The allow-list admits a rule for one path, each row with its
#                 reason
#   - jq-compat   no jq program in those scripts uses a jq keyword (label,
#                 module, if, then, else, end, as, def, reduce, foreach, try,
#                 catch, and, or, not, import, include, __loc__) as a --arg /
#                 --argjson name, an `as $name` binding or a shorthand object
#                 key (`{module, scope}`) or a `def f($label)` parameter: jq 1.6 (Debian 12, Ubuntu 22.04 —
#                 drupilot's jq_min) rejects each as a syntax error, jq 1.7
#                 accepts it. `{label: .x}` and `.label` are fine everywhere.
#                 It also rejects an object value joined with and/or outside
#                 parentheses (`{ok: (a) and (b)}`, a jq 1.6 syntax error;
#                 write `{ok: ((a) and (b))}`).
#                 A line can opt out with a trailing `# jq-compat-ok` and a reason
#   - lib-defs    the shared library is split into domain libs (scripts/lib/*.sh):
#                 every function is defined in exactly one lib, common.sh only
#                 sources the domain libs (no function of its own), and its
#                 list names each of them once (php-scan.sh and ext-scan.sh are
#                 sourced by the scripts that need them); a hook that sources
#                 only some libs (_DRUPILOT_LIBS) lists every lib that defines
#                 a function it calls, directly or through other functions
#                 (a static scan: every word of the code that names a lib
#                 function). With
#                 --compare-pre-split=REF it also lists the functions defined
#                 in scripts/lib/*.sh at the git REF and fails when the set
#                 differs (the lib split moves functions, it never adds,
#                 renames or drops one)
#   - bang-lint   no `!`...`` exec span in commands/*.md, skills/*/SKILL.md or
#                 agents/*.md contains a <placeholder>: those spans run at command
#                 load, before the model can substitute anything
#   - templates   render every templates/*.tmpl with dummy values; each XML output
#                 must pass `xmllint --noout` (skipped when xmllint is absent)
#   - json        `jq empty` on config/*.json, hooks/*.json, .claude-plugin/*.json
#   - version     the release version (09-R4): .claude-plugin/plugin.json holds
#                 a valid version equal to the top released CHANGELOG.md
#                 heading; a v* tag on HEAD, if any, is v<version>; no
#                 pre-release version on `main` (GITHUB_BASE_REF for a pull
#                 request, else GITHUB_REF_NAME, else the checked-out branch);
#                 and config/migrations.json is coherent (every aliased `new`
#                 and `when` key is declared in config/config-reference.json,
#                 names are valid variable names, every remove_in is a later
#                 major than the version). The version is compared with the
#                 released CHANGELOG heading of highest SemVer precedence
#   - config-keys every DRUPILOT_* key a script, hook, command, skill or agent
#                 reads is declared in config/config-reference.json (as a key,
#                 a runtime_only key or a pattern such as DRUPILOT_CHOICE_*);
#                 its defaults.json keys are exactly those of defaults.json;
#                 every entry has a tier, a type and a description, a
#                 default_ref that resolves and an enum holding the default;
#                 every name the 0.9 README documents is public. A finding
#                 fails the gate (T-M3-14; it warned until M3), and so does a
#                 _*_comment of defaults.json longer than 1800 characters
#                 (AR-27: the prose stays until M11 but must not grow). Comment
#                 lines of the scripts and scripts/dev/ are not scanned
#   - docs        the docs site (08-R6): scripts/dev/gen-docs.sh --check (no
#                 drift of the generated docs/reference pages); every
#                 docs/**/*.md is in the mkdocs.yml nav and every nav entry
#                 exists; no plugin file (commands, skills, agents, scripts but
#                 scripts/dev, hooks) cites a README section (`README "` /
#                 `README.md (`) or a docs/*.md page that does not exist; every
#                 relative .md link inside docs/ resolves. A docs/*_es.md or a
#                 docs/es/ only warns (English-only site); a root FLOW*.md is
#                 only noted in the detail (its content moves to the docs in
#                 the content step, M11)
#   - schemas     the persisted 0.9 artifacts and the version data validate
#                 against schemas/ (scripts/dev/schema-check.sh: jq always,
#                 check-jsonschema where it is installed; with --ci,
#                 check-jsonschema from PATH or the pinned Docker image, and a
#                 failure when neither)
#   - data        the version data and catalogs (scripts/dev/data-check.sh):
#                 config/targets|php|paths and config/catalog/*.json match
#                 their schema, every value names its source, every node a
#                 hard gate reads is verified and never "announced", and the
#                 files agree with each other; and config/recipes.json is what
#                 scripts/dev/gen-recipes.sh generates from the catalogs
#   - unit        the unit tests (scripts/dev/unit.sh: tests/lib/selftest.sh and
#                 tests/unit/*.sh, run with this same bash; a test skipped
#                 until its milestone is not a failure)
#   - contract    the 0.9 public-surface contract (scripts/dev/contract.sh:
#                 commands, choices, JSON key sets, name generators, enums and
#                 the per-script exit codes, against tests/contract/*.json)
#   - evals       the static router evals (scripts/dev/evals.sh: the ordered tab
#                 sequence of a `full` run, the mode words and the mode-inference
#                 rules, against tests/evals/router/*.json; no model)
#   - golden      OPTIONAL (only with --smoke, --ci or --only golden): the
#                 golden outputs (scripts/dev/golden.sh --check: the v0.9.0
#                 baseline of tests/baseline/v0.9.0/ rerun Docker-free, and
#                 the sha256-pinned lab recordings in tests/fixtures/*.golden/)
#   - smoke       OPTIONAL (only with --smoke, --ci or --only smoke): the
#                 Docker-free smoke tests of scripts/dev/smoke.sh (expected
#                 results on tests/fixtures/), run with this same bash
#
# Usage:
#   scripts/dev/check.sh [--json] [--only G1,G2] [--skip G1,G2]
#                        [--allow-fail G1,G2] [--allow-known] [--smoke] [--ci]
#                        [--compare-pre-split=REF]
#     --json         machine summary on STDOUT (logs stay on STDERR)
#     --only/--skip  run a subset of the gates (--gate is an alias of --only)
#     --allow-fail   report these gates' failures as "allowed-fail" (exit 0)
#     --allow-known  shorthand for --allow-fail with the gates listed in
#                    KNOWN_FAILING below (failures already tracked for a fix)
#     --smoke        also run the optional golden and smoke gates (~30 s)
#     --ci           a missing optional tool (claude/shellcheck/xmllint) is a
#                    failure instead of a skip; implies --smoke
#     --compare-pre-split=REF
#                    the lib-defs gate also compares the function set of
#                    scripts/lib/*.sh with the one at the git REF
#
# Output (--json):
#   {ok, gates:[{name, status: pass|fail|skip|allowed-fail|warn, detail, findings:[..]}]}
#
# Exit codes: 0 all gates pass/skip/allowed-fail · 1 a gate failed or usage error.
# Read-only: renders templates into a temp dir that is removed on exit.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$REPO"

ALL_GATES="validate syntax exec-bit scripts shellcheck portability special-vars sigpipe jq-compat lib-defs bang-lint hard-rules templates json version config-keys docs schemas data unit contract evals golden smoke"
# Gates that run only when asked for (--smoke, --ci, or named in --only).
OPTIONAL_GATES="golden smoke"
# Gates known to fail on the current tree, with a fix tracked for 0.9.0. Empty
# this list as the fixes land so --allow-known stops hiding them.
KNOWN_FAILING=""

AS_JSON=0; ONLY=""; SKIP=""; ALLOW=""; CI=0; SMOKE=0; PRE_SPLIT_REF=""

usage() { awk 'NR>2 && /^# =+$/ {exit} NR>2 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) AS_JSON=1; shift;;
    --only|--gate) ONLY="${2:-}"; shift 2 || die "$1 needs a value" 1;;
    --only=*|--gate=*) ONLY="${1#*=}"; shift;;
    --skip) SKIP="${2:-}"; shift 2 || die "--skip needs a value" 1;;
    --skip=*) SKIP="${1#*=}"; shift;;
    --allow-fail) ALLOW="$ALLOW,${2:-}"; shift 2 || die "--allow-fail needs a value" 1;;
    --allow-fail=*) ALLOW="$ALLOW,${1#*=}"; shift;;
    --allow-known) ALLOW="$ALLOW,${KNOWN_FAILING// /,}"; shift;;
    --smoke) SMOKE=1; shift;;
    --ci) CI=1; SMOKE=1; shift;;
    --compare-pre-split) PRE_SPLIT_REF="${2:-}"; shift 2 || die "--compare-pre-split needs a git ref" 1;;
    --compare-pre-split=*) PRE_SPLIT_REF="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done

# in_list <word> <comma/space separated list>
in_list() { case ",${2// /,}," in *",$1,"*) return 0;; esac; return 1; }

# no-version-literals is the hard-rules gate under its AR-07 name.
ONLY="${ONLY//no-version-literals/hard-rules}"; SKIP="${SKIP//no-version-literals/hard-rules}"
ALLOW="${ALLOW//no-version-literals/hard-rules}"
for _g in ${ONLY//,/ } ${SKIP//,/ } ${ALLOW//,/ }; do
  in_list "$_g" "$ALL_GATES" || die "Unknown gate: $_g (gates: $ALL_GATES)" 1
done

have_cmd jq || die "jq is required by scripts/dev/check.sh" 1

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Results: one JSON object per gate, appended to this file.
RESULTS="$TMP/results.jsonl"
: > "$RESULTS"
FAILED=0

# record <gate> <status> <detail> [findings-file]
record() {
  local gate="$1" status="$2" detail="$3" ffile="${4:-}" findings="[]"
  if [[ "$status" == "fail" ]] && in_list "$gate" "$ALLOW"; then status="allowed-fail"; fi
  if [[ -n "$ffile" && -s "$ffile" ]]; then findings="$(jq -R . < "$ffile" | jq -s -c .)"; fi
  jq -n -c --arg n "$gate" --arg s "$status" --arg d "$detail" --argjson f "$findings" \
    '{name:$n, status:$s, detail:$d, findings:$f}' >> "$RESULTS"
  case "$status" in
    pass) log_ok "$gate: $detail";;
    skip) log_warn "$gate: skipped — $detail";;
    warn) log_warn "$gate: WARNING — $detail";;
    allowed-fail) log_warn "$gate: FAILED (allowed) — $detail";;
    fail) log_err "$gate: FAILED — $detail"; FAILED=1;;
  esac
  if [[ "$status" != "pass" && -n "$ffile" && -s "$ffile" ]]; then
    sed 's/^/    /' "$ffile" >&2
  fi
  return 0
}

# missing_tool <gate> <tool>
missing_tool() {
  if [[ "$CI" == "1" ]]; then record "$1" fail "$2 not found (required under --ci)"
  else record "$1" skip "$2 not found"; fi
}

# The plugin's shell scripts, sorted (portable: no mapfile, no find -printf).
SCRIPTS=()
while IFS= read -r _f; do SCRIPTS+=("$_f"); done < <(
  cd "$REPO" && ls scripts/*.sh scripts/*/*.sh hooks/scripts/*.sh tests/lib/*.sh tests/unit/*.sh 2>/dev/null | LC_ALL=C sort)

# ---------------------------------------------------------------------------
gate_validate() {
  have_cmd claude || { missing_tool validate claude; return 0; }
  local out="$TMP/validate.out"
  if (cd "$REPO" && claude plugin validate . ) > "$out" 2>&1; then
    record validate pass "claude plugin validate . passed"
  else
    record validate fail "claude plugin validate . failed" "$out"
  fi
}

gate_syntax() {
  local out="$TMP/syntax.out" f
  : > "$out"
  for f in "${SCRIPTS[@]}"; do
    (cd "$REPO" && bash -n "$f") >> "$out" 2>&1 || true
  done
  if [[ -s "$out" ]]; then record syntax fail "bash -n reported errors" "$out"
  else record syntax pass "${#SCRIPTS[@]} scripts parse"; fi
}

gate_exec_bit() {
  local out="$TMP/exec.out" f mode
  : > "$out"
  for f in "${SCRIPTS[@]}"; do
    mode="$(git -C "$REPO" ls-files -s -- "$f" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
    if [[ -n "$mode" ]]; then
      [[ "$mode" == "100755" ]] || echo "$f: git mode $mode (expected 100755; git update-index --chmod=+x)" >> "$out"
    else
      [[ -x "$REPO/$f" ]] || echo "$f: not executable (chmod +x)" >> "$out"
    fi
  done
  if [[ -s "$out" ]]; then record exec-bit fail "scripts without the executable bit" "$out"
  else record exec-bit pass "${#SCRIPTS[@]} scripts executable"; fi
}

gate_shellcheck() {
  have_cmd shellcheck || { missing_tool shellcheck shellcheck; return 0; }
  local out="$TMP/shellcheck.out"
  if (cd "$REPO" && shellcheck -S warning -f gcc "${SCRIPTS[@]}") > "$out" 2>&1; then
    record shellcheck pass "shellcheck -S warning clean ($(shellcheck --version | awk '/^version:/ {print $2}'))"
  else
    record shellcheck fail "shellcheck -S warning reported issues" "$out"
  fi
}

gate_portability() {
  local out="$TMP/portability.out" f
  : > "$out"
  for f in "${SCRIPTS[@]}"; do
    [[ "$f" == "scripts/dev/check.sh" ]] && continue   # its own patterns would self-match
    # Drop full-line comments and trailing " # ..." comments, keep line numbers.
    (cd "$REPO" && awk -v F="$f" '
      # not_grep_tool <line> -> 1 when tar, rsync, curl, phpcs or phpcbf is a
      # command word on the line (also through a path: vendor/bin/phpcs): their
      # own --include/--exclude options are not the grep ones.
      function not_grep_tool(l) {
        return (l ~ /(^|[;&|(`[:space:]\/"])(tar|rsync|curl|phpcs|phpcbf)(["[:space:]]|$)/)
      }
      /# portability-ok/ { next }
      {
        line = $0
        if (line ~ /^[[:space:]]*#/) next
        sub(/[[:space:]]#[[:space:]].*$/, "", line)
        if (line ~ /\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,?|\^\^?)\}/ ||
            line ~ /(declare|local|typeset)[[:space:]]+-[a-zA-Z]*[Ang]/ ||
            line ~ /(^|[^A-Za-z_])(mapfile|readarray|realpath|envsubst)([^A-Za-z_]|$)/ ||
            line ~ /(^|[^A-Za-z_])sed[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-i/ ||
            line ~ /readlink[[:space:]]+-f/ || line ~ /grep[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*P/ ||
            (line ~ /(^|[[:space:](="'\''])--(include|exclude|exclude-dir)([=[:space:]"'\'']|$)/ && !not_grep_tool(line)) ||
            line ~ /date[[:space:]]+-d/ || line ~ /xargs[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-r/ ||
            line ~ /stat[[:space:]]+-c/ || line ~ /find[[:space:]].*-printf/ ||
            line ~ /\$\([[:space:]]*case[[:space:]].*[[:space:]]in[[:space:]]+[^([:space:]]/ ||
            (line !~ /=~/ && (line ~ /(~|match\(|sub\(|split\()[[:space:]]*[^\/]*\// || line ~ /^[[:space:]]*!?\//) &&
             line ~ /[^\\]\{[0-9]+(,[0-9]*)?\}/))
          printf "%s:%d: %s\n", F, NR, substr($0, 1, 140)
      }' "$f") >> "$out"
  done
  if [[ -s "$out" ]]; then
    record portability fail "$(wc -l < "$out" | tr -d ' ') bash-4/GNU-only construct(s) (use lc, sed_inplace, ... from common.sh)" "$out"
  else
    record portability pass "${#SCRIPTS[@]} scripts free of bash-4/GNU-only constructs"
  fi
}

# lib_functions <file...> -> "<name>\t<file>" for every function defined at
# column 0 (name() {) in the given files.
lib_functions() {
  awk '/^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{/ { n = $0; sub(/\(\).*/, "", n); printf "%s\t%s\n", n, FILENAME }' "$@"
  return 0
}

# lib_reach <defs> <script> -> the domain libs (core, paths, ...) defining a
# function the script reaches: every word of its code and of common.sh's own
# top-level code (comments aside) that names a lib function, then every
# function those call, transitively. A function's code runs from its
# definition line to the next definition, so a one-line body, a heredoc or an
# awk program with a `}` in column 0 cannot end it early (the constants
# between two functions are read as the first one's: wider, never narrower).
# <defs> is lib_functions output of the domain libs. A static
# over-approximation (a name in a string counts), so a hook's lib list can only
# be too wide, never too narrow.
lib_reach() {
  local -a dl=()
  local f
  while IFS= read -r f; do dl+=("$f"); done <<EOF
$(domain_libs)
EOF
  awk -v defs="$1" -v script="$2" -v agg="$REPO/scripts/lib/common.sh" '
    function words(s, kind,   w) {
      while (match(s, /[A-Za-z_][A-Za-z0-9_]*/)) {
        w = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        if (!(w in lib)) continue
        if (kind == "script") need[w] = 1; else edge[cur, w] = 1
      }
    }
    FILENAME == defs { n = split($2, p, "/"); l = p[n]; sub(/\.sh$/, "", l); lib[$1] = l; next }
    FNR == 1 { cur = "" }
    { line = $0; sub(/^[[:space:]]*#.*/, "", line) }
    FILENAME == script || FILENAME == agg { words(line, "script"); next }
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{/ { cur = $0; sub(/\(\).*/, "", cur); sub(/^[^{]*\{/, "", line) }
    cur != "" { words(line, "lib") }
    END {
      do {
        grown = 0
        for (k in edge) {
          split(k, e, SUBSEP)
          if ((e[1] in need) && !(e[2] in need)) { need[e[2]] = 1; grown = 1 }
        }
      } while (grown)
      for (f in need) used[lib[f]] = 1
      for (l in used) print l
    }' FS='\t' "$1" "$REPO/scripts/lib/common.sh" ${dl[@]+"${dl[@]}"} "$2" | LC_ALL=C sort
  return 0
}

# domain_libs -> the paths of the domain libs, one per word (scripts/lib/*.sh but
# the aggregator and the scanners php-scan.sh / ext-scan.sh, which common.sh
# never sources).
domain_libs() {
  local f
  for f in "$REPO"/scripts/lib/*.sh; do
    case "${f##*/}" in common.sh|php-scan.sh|ext-scan.sh) continue;; esac
    printf '%s\n' "$f"
  done
  return 0
}

gate_lib_defs() {
  local out="$TMP/lib-defs.out" all="$TMP/lib-defs.all" b c n libs=0 pre cur order want
  : > "$out"
  ( cd "$REPO" && lib_functions scripts/lib/*.sh ) > "$all"
  # shellcheck disable=SC2046  # one path per word, no spaces in the libs' names
  lib_functions $(domain_libs) > "$TMP/lib-defs.domain"
  # Each function in exactly one lib.
  cut -f1 "$all" | LC_ALL=C sort | uniq -d | while IFS= read -r n; do
    printf '%s is defined more than once: %s\n' "$n" "$(awk -F'\t' -v n="$n" '$1 == n { printf "%s ", $2 }' "$all")"
  done >> "$out"
  # common.sh is the aggregator: it sources the domain libs, each once.
  awk -F'\t' '$2 == "scripts/lib/common.sh" { print "scripts/lib/common.sh defines " $1 "(): it only sources the domain libs" }' "$all" >> "$out"
  order="$(sed -n 's/^_drupilot_libs="\(.*\)"$/\1/p' "$REPO/scripts/lib/common.sh")"
  for b in "$REPO"/scripts/lib/*.sh; do
    b="${b##*/}"; b="${b%.sh}"
    case "$b" in common|php-scan|ext-scan) continue;; esac
    libs=$((libs + 1))
    c="$(printf '%s' "$order" | tr ' ' '\n' | grep -cx "$b" || true)"
    [[ "$c" == "1" ]] || printf 'scripts/lib/%s.sh is listed %s time(s) in common.sh'"'"'s _drupilot_libs (once expected)\n' "$b" "$c" >> "$out"
  done
  # A hook's _DRUPILOT_LIBS covers the libs of every function it reaches.
  for b in "$REPO"/hooks/scripts/*.sh; do
    grep -q '_DRUPILOT_LIBS=' "$b" || continue
    want="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?_DRUPILOT_LIBS=["'"'"']?([a-z][a-z -]*)["'"'"']?[[:space:]]*$/\2/p' "$b" | sed -n '1p')"
    [[ -n "$want" ]] || { printf '%s sets _DRUPILOT_LIBS in a form the gate cannot read (write _DRUPILOT_LIBS="core ...")\n' "hooks/scripts/${b##*/}" >> "$out"; continue; }
    for c in $(lib_reach "$TMP/lib-defs.domain" "$b"); do
      case " $want " in *" $c "*) ;; *) printf '%s calls a function of scripts/lib/%s.sh, missing from its _DRUPILOT_LIBS\n' "hooks/scripts/${b##*/}" "$c" >> "$out";; esac
    done
  done
  if [[ -n "$PRE_SPLIT_REF" ]]; then
    if ! git -C "$REPO" rev-parse -q --verify "$PRE_SPLIT_REF^{commit}" > /dev/null 2>&1; then
      printf 'unknown git ref for --compare-pre-split: %s\n' "$PRE_SPLIT_REF" >> "$out"
    else
      pre="$(git -C "$REPO" ls-tree --name-only "$PRE_SPLIT_REF" scripts/lib/ \
        | grep '\.sh$' | while IFS= read -r b; do git -C "$REPO" show "$PRE_SPLIT_REF:$b"; done \
        | awk '/^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{/ { n = $0; sub(/\(\).*/, "", n); print n }' | LC_ALL=C sort -u)"
      cur="$(cut -f1 "$all" | LC_ALL=C sort -u)"
      log_info "lib-defs: $(printf '%s\n' "$pre" | grep -c .) function(s) in scripts/lib at $PRE_SPLIT_REF, $(printf '%s\n' "$cur" | grep -c .) in the tree"
      comm -23 <(printf '%s\n' "$pre") <(printf '%s\n' "$cur") | sed "s/^/only at $PRE_SPLIT_REF: /" >> "$out"
      comm -13 <(printf '%s\n' "$pre") <(printf '%s\n' "$cur") | sed 's/^/only in the tree: /' >> "$out"
    fi
  fi
  if [[ -s "$out" ]]; then record lib-defs fail "the shared library's function definitions are inconsistent" "$out"
  else record lib-defs pass "$(wc -l < "$all" | tr -d ' ') functions, each defined once; common.sh sources the $libs domain libs; the hooks' lib lists cover what they call$([[ -n "$PRE_SPLIT_REF" ]] && printf '; the same set as %s' "$PRE_SPLIT_REF")"; fi
}

gate_special_vars() {
  local out="$TMP/special-vars.out" f
  # Bash special variables whose assignment is ignored, overridden or harmful.
  local names='GROUPS|RANDOM|SRANDOM|SECONDS|LINENO|HOSTNAME|HOSTTYPE|MACHTYPE|OSTYPE|UID|EUID|PPID|BASHPID|PWD|OLDPWD|PIPESTATUS|FUNCNAME|DIRSTACK|SHLVL|SHELLOPTS|BASHOPTS|HISTCMD|EPOCHSECONDS|EPOCHREALTIME|COMP_WORDS|COMP_CWORD|BASH_ARGC|BASH_ARGV|BASH_ARGV0|BASH_SOURCE|BASH_LINENO|BASH_VERSINFO|BASH_VERSION|BASH_COMMAND|BASH_SUBSHELL|BASH_REMATCH|BASH_ALIASES|BASH_CMDS|BASH_EXECUTION_STRING'
  : > "$out"
  for f in "${SCRIPTS[@]}"; do
    [[ "$f" == "scripts/dev/check.sh" ]] && continue   # its own patterns would self-match
    (cd "$REPO" && awk -v F="$f" -v N="$names" '
      BEGIN { e = "(" N ")" }
      /# special-var-ok/ { next }
      {
        line = $0
        if (line ~ /^[[:space:]]*#/) next
        sub(/[[:space:]]#[[:space:]].*$/, "", line)
        if (line ~ ("(^|[;&|({[:space:]])" e "(\\[[^]]*\\])?\\+?=") ||
            line ~ ("(declare|local|typeset|readonly|export|unset)([[:space:]]+-[a-zA-Z]+)*([[:space:]]+[A-Za-z_][A-Za-z0-9_]*(=[^[:space:]]*)?)*[[:space:]]+" e "([[:space:]=;]|$)") ||
            line ~ ("(^|[;&|({[:space:]])for[[:space:]]+" e "[[:space:]]+in([[:space:]]|$)") ||
            line ~ ("(^|[;&|({[:space:]])read([[:space:]]+[^;|&<>]*)?[[:space:]]+" e "([[:space:];<]|$)"))
          printf "%s:%d: %s\n", F, NR, substr($0, 1, 140)
      }' "$f") >> "$out"
  done
  if [[ -s "$out" ]]; then
    record special-vars fail "$(wc -l < "$out" | tr -d ' ') use(s) of a bash special variable as a plain variable (rename it)" "$out"
  else
    record special-vars pass "${#SCRIPTS[@]} scripts free of bash special-variable collisions"
  fi
}

gate_scripts() {
  local out="$TMP/scripts.out" f n=0 rel depth home="$TMP/scripts-home" rc allow="$REPO/tests/contract/hard-rules-allow.txt"
  local o="$TMP/scripts.o" e="$TMP/scripts.e"
  : > "$out"; mkdir -p "$home/cwd"
  for f in "$REPO"/scripts/*.sh "$REPO"/scripts/*/*.sh; do
    [[ -f "$f" ]] || continue
    rel="${f#"$REPO"/}"
    case "$rel" in scripts/dev/*|scripts/lib/*) continue;; esac
    n=$((n + 1))
    case "$rel" in scripts/*/*) depth='\.\./lib/common\.sh';; *) depth='lib/common\.sh';; esac
    # A non-comment source line in the canonical form, at the script's depth.
    grep -qE '^[[:space:]]*(\.|source)[[:space:]]+"\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/'"$depth"'"' "$f" \
      || echo "$rel: does not source common.sh as \"\$(dirname \"\${BASH_SOURCE[0]}\")/${depth//\\/}\"" >> "$out"
    rc=0
    ( cd "$home/cwd" && env -i PATH="$PATH" HOME="$home" XDG_DATA_HOME="$home/d" XDG_CONFIG_HOME="$home/c" XDG_CACHE_HOME="$home/k" \
        TMPDIR="${TMPDIR:-/tmp}" "$BASH" "$f" --help > "$o" 2> "$e" < /dev/null ) || rc=$?
    if [[ "$rc" != "0" ]]; then echo "$rel --help: exit $rc, want 0" >> "$out"
    elif ! grep -q 'Usage' "$o" "$e"; then echo "$rel --help: no Usage section" >> "$out"; fi
    # A 0.9 script whose CLI ignores an unknown flag keeps doing so (CC-05);
    # tests/contract/hard-rules-allow.txt lists each (rule AR22-FLAG).
    if [[ -f "$allow" ]] && awk -v p="$rel" '!/^[[:space:]]*(#|$)/ && $1 == "AR22-FLAG" && $2 == p { f = 1 } END { exit !f }' "$allow"; then continue; fi
    # The unknown flag first, then --help: a parser that refuses it exits 1
    # there; one that skips it reaches --help and exits 0. No script body runs.
    rc=0
    ( cd "$home/cwd" && env -i PATH="$PATH" HOME="$home" XDG_DATA_HOME="$home/d" XDG_CONFIG_HOME="$home/c" XDG_CACHE_HOME="$home/k" \
        TMPDIR="${TMPDIR:-/tmp}" "$BASH" "$f" --drupilot-no-such-flag --help > /dev/null 2>&1 < /dev/null ) || rc=$?
    [[ "$rc" == "1" ]] || echo "$rel --drupilot-no-such-flag --help: exit $rc, want 1 (the unknown flag refused)" >> "$out"
  done
  if [[ -s "$out" ]]; then record scripts fail "$(grep -c . "$out") script(s) break the AR-22 contract" "$out"
  else record scripts pass "$n scripts: common.sh at their depth, --help exit 0 with a Usage section, an unknown flag exit 1"; fi
}

gate_hard_rules() {
  local out="$TMP/hard-rules.out" allow="$REPO/tests/contract/hard-rules-allow.txt" f rel n=0 id re hits want got
  : > "$out"
  # allowed RULE PATH -> 0 when the allow-list lets RULE match in PATH.
  allowed() { [[ -f "$allow" ]] && awk -v r="$1" -v p="$2" '!/^[[:space:]]*(#|$)/ && $1 == r && $2 == p { f = 1 } END { exit !f }' "$allow"; }
  # body FILE -> the lines a rule reads, each as "LINE:TEXT": a script's
  # non-comment lines, a PHP template's non-comment lines (doc comments and
  # // lines), a prompt whole.
  body() {
    case "$1" in
      *.sh) grep -nvE '^[[:space:]]*#' "$1" 2>/dev/null || true;;
      *.php.tmpl) grep -nvE '^[[:space:]]*(\*|//|/\*)' "$1" 2>/dev/null || true;;
      *) grep -n '' "$1" 2>/dev/null || true;;
    esac
  }
  local rules='H2	SleepToSerializeRector|WakeupToUnserializeRector
H3	withComposerBased\(
H5	https?://(www\.)?drupal\.org/(docs|project/[^ /]+/releases)
H6	(Drupal|D) ?12 (is )?stable|12\.0\.0 (is )?(stable|released)
AGG	Drupal10SetList::DRUPAL_10([^0-9_]|$)
DDEV	drupal1[0-9]([^0-9]|$)
H7	\^[0-9]+(\.[0-9]+)? \|\| \^[0-9]+(\.[0-9]+)? \|\| \^[0-9]+
H9	(drush|vendor/bin/drush)[^|]* (migrate:import|migrate-import|mim)([^a-z-]|$)
LOCK	/drupilot-lock\.json'
  for f in "$REPO"/scripts/*.sh "$REPO"/scripts/*/*.sh "$REPO"/hooks/scripts/*.sh "$REPO"/templates/*.tmpl \
           "$REPO"/commands/*.md "$REPO"/skills/*/SKILL.md "$REPO"/agents/*.md; do
    [[ -f "$f" ]] || continue
    rel="${f#"$REPO"/}"
    case "$rel" in scripts/dev/*) continue;; esac
    n=$((n + 1))
    while IFS="$(printf '\t')" read -r id re; do
      [[ "$id" == "DDEV" && "$rel" == "scripts/lib/plan.sh" ]] && continue
      [[ "$id" == "LOCK" && "$rel" == "scripts/lib/lock.sh" ]] && continue
      # H7 is about a default in code; a prompt may quote an old range.
      case "$id:$rel" in H7:commands/*|H7:skills/*|H7:agents/*) continue;; esac
      hits="$(body "$f" | grep -E -- "^[0-9]+:.*($re)" || true)"
      [[ -n "$hits" ]] || continue
      allowed "$id" "$rel" && continue
      printf '%s\n' "$hits" | sed "s|^|$id $rel:|" | cut -c1-200 >> "$out"
    done <<EOF
$rules
EOF
    # H4: no more version literals than the allow-list records (default 0).
    case "$rel" in
      scripts/*|hooks/*)
        # A substring offset (${x:0:12}) and a numeric test (-ge 11) are not versions.
        got="$(body "$f" | sed -E 's/\$\{[^}]*:[0-9]+(:[0-9]+)?\}//g; s/-(eq|ne|ge|gt|le|lt) [0-9]+//g' \
          | grep -cE '^[0-9]+:(.*[^0-9A-Za-z_.])?(\^?1[0-2](\.[0-9]+)?|8\.[0-5])([^0-9A-Za-z_]|$)' || true)"
        want=0
        if [[ -f "$allow" ]]; then
          want="$(awk -v p="$rel" '!/^[[:space:]]*(#|$)/ && $1 == "H4" && $2 == p { print $3 + 0; exit }' "$allow" || true)"
        fi
        if [[ "${got:-0}" -gt "${want:-0}" ]]; then
          echo "H4 $rel: $got version literal line(s), the allow-list records ${want:-0} (read versions through plan_get / target_get)" >> "$out"
        elif [[ "${got:-0}" -lt "${want:-0}" ]]; then
          echo "H4 $rel: $got version literal line(s), fewer than the ${want:-0} the allow-list records: lower its count (the ratchet only goes down)" >> "$out"
        fi;;
    esac
  done
  if [[ -s "$out" ]]; then record hard-rules fail "$(grep -c . "$out") hard-rule finding(s) (tests/contract/hard-rules-allow.txt allows a reasoned exception)" "$out"
  else record hard-rules pass "$n files: no hard-rule hit outside the allow-list, no new version literal"; fi
}

gate_sigpipe() {
  local out="$TMP/sigpipe.out" f n=0
  : > "$out"
  for f in "${SCRIPTS[@]}"; do
    # The tests run without pipefail (tests/lib/assert.sh is standalone).
    case "$f" in scripts/dev/check.sh|tests/*) continue;; esac   # check.sh: its own patterns would self-match
    n=$((n + 1))
    (cd "$REPO" && awk -v F="$f" '
      /# sigpipe-ok/ { next }
      {
        line = $0
        if (line ~ /^[[:space:]]*#/) next
        sub(/[[:space:]]#[[:space:]].*$/, "", line)
        if (line ~ /\|[[:space:]]*head([[:space:]]|$)/ ||
            line ~ /\|[[:space:]]*grep[[:space:]]+(-[A-Za-z]*[qlLm][A-Za-z]*|--(quiet|silent|max-count|files-with))/ ||
            line ~ /\|[[:space:]]*cmp([[:space:]]|$)/ ||
            line ~ /\|[[:space:]]*awk[[:space:]].*[^A-Za-z_]exit([^A-Za-z_]|$)/)
          printf "%s:%d: %s\n", F, NR, substr($0, 1, 140)
      }' "$f") >> "$out"
  done
  if [[ -s "$out" ]]; then
    record sigpipe fail "$(wc -l < "$out" | tr -d ' ') pipeline consumer(s) that stop reading early (under pipefail the producer's SIGPIPE fails the pipeline: use grep_q, sed -n '1p', an awk flag, sha256_hex on both sides instead of cmp)" "$out"
  else
    record sigpipe pass "$n scripts free of early-exit pipeline consumers"
  fi
}

gate_jq_compat() {
  local out="$TMP/jq-compat.out" f
  local kw='def|if|then|elif|else|end|as|reduce|foreach|try|catch|label|import|include|and|or|not|module|__loc__'
  : > "$out"
  for f in "${SCRIPTS[@]}"; do
    [[ "$f" == "scripts/dev/check.sh" ]] && continue   # its own patterns would self-match
    # A brace not preceded by `$` (so not ${var}) opens a jq object; a keyword
    # right after it or after a comma, followed by `,` or `}`, is a shorthand key.
    (cd "$REPO" && awk -v F="$f" -v K="$kw" '
      BEGIN { e = "(" K ")" }
      /# jq-compat-ok/ { next }
      {
        line = $0
        if (line ~ /^[[:space:]]*#/) next
        sub(/[[:space:]]#[[:space:]].*$/, "", line)
        if (line ~ ("--(arg|argjson|slurpfile|rawfile)[[:space:]]+" e "[[:space:]]") ||
            line ~ ("as[[:space:]]+[$]" e "([^A-Za-z0-9_]|$)") ||
            line ~ ("def[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[(][^)]*[$]" e "[[:space:]]*[;)]") ||
            line ~ ("(^|[^$])[{][[:space:]]*" e "[[:space:]]*[,}]") ||
            line ~ ("(^|[^$])[{][^{}]*,[[:space:]]*" e "[[:space:]]*[,}]") ||
            line ~ "(^|[^$])[{,][[:space:]]*[A-Za-z_]+:[[:space:]]*[(][^(].*[)][[:space:]]+(and|or)[[:space:]]")
          printf "%s:%d: %s\n", F, NR, substr($0, 1, 140)
      }' "$f") >> "$out"
  done
  if [[ -s "$out" ]]; then
    record jq-compat fail "$(wc -l < "$out" | tr -d ' ') jq 1.6 syntax error(s): a keyword used as a variable or shorthand key (rename, e.g. \$lbl / {label: .label}), or an object value joined with and/or outside parentheses (write {ok: ((a) and (b))})" "$out"
  else
    record jq-compat pass "${#SCRIPTS[@]} scripts free of jq 1.7-only keyword names"
  fi
}

gate_bang_lint() {
  local out="$TMP/bang.out" files=() f
  : > "$out"
  while IFS= read -r f; do files+=("$f"); done < <(
    cd "$REPO" && ls commands/*.md skills/*/SKILL.md agents/*.md 2>/dev/null | LC_ALL=C sort)
  for f in "${files[@]}"; do
    # Every !`...` span on a line (fenced or not — be safe) must not contain an
    # <identifier> placeholder. Redirections like </dev/tty or 2>/dev/null do
    # not match the identifier-in-angle-brackets pattern. POSIX awk.
    (cd "$REPO" && awk -v F="$f" '
      {
        line = $0
        while (match(line, /!`[^`]*`/)) {
          span = substr(line, RSTART, RLENGTH)
          if (span ~ /<[A-Za-z_][A-Za-z0-9_.-]*(\.\.\.)?>/)
            printf "%s:%d: placeholder inside !-exec span: %s\n", F, NR, substr(span, 1, 120)
          line = substr(line, RSTART + RLENGTH)
        }
      }' "$f") >> "$out"
  done
  if [[ -s "$out" ]]; then
    record bang-lint fail "$(wc -l < "$out" | tr -d ' ') !-exec span(s) with a <placeholder>" "$out"
  else
    record bang-lint pass "${#files[@]} command/skill/agent files clean"
  fi
}

# Dummy values for the documented setup tokens; any other token gets a generic
# value so every template renders fully.
dummy_for() {
  case "$1" in
    SUBJECT_PATH) printf 'web/modules/custom/example';;
    PHP_TARGET) printf '8.3';;
    PHP_SET) printf 'php83';;
    PHP_FLOOR) printf '8.1';;
    PHP_FLOOR_ID) printf 'PHP_81';;
    PHP_FLOOR_SET) printf 'php81';;
    PHPSTAN_LEVEL|PHPSTAN_LEVEL_REFACTOR) printf '5';;
    PROJECT_NAME) printf 'example';;
    WEBDRIVER_HOST) printf 'selenium-chrome';;
    *) printf 'dummy-%s' "$(printf '%s' "$1" | tr 'A-Z_' 'a-z-')";;
  esac
}

gate_templates() {
  local out="$TMP/templates.out" dir="$TMP/rendered" tpl name dest tok n=0 xml=0
  : > "$out"; mkdir -p "$dir"
  for tpl in "$REPO"/templates/*.tmpl; do
    [[ -f "$tpl" ]] || continue
    name="$(basename "$tpl" .tmpl)"; dest="$dir/$name"
    cp "$tpl" "$dest"
    for tok in $(grep -oE '\{\{[A-Z_]+\}\}' "$tpl" | sort -u | tr -d '{}'); do
      # Values are plain [a-z0-9./-]; '|' is never in them.
      sed "s|{{$tok}}|$(dummy_for "$tok")|g" "$dest" > "$dest.new" && mv "$dest.new" "$dest"
    done
    n=$((n + 1))
    if grep -qE '\{\{[A-Z_]+\}\}' "$dest"; then
      echo "templates/$name.tmpl: unresolved token after rendering" >> "$out"
    fi
    case "$name" in
      *.xml|*.xml.dist) ;;
      *) head -c 5 "$dest" | grep_q '^<?xml' || continue;;
    esac
    xml=$((xml + 1))
    if ! have_cmd xmllint; then continue; fi
    xmllint --noout "$dest" 2>&1 | sed "s|$dir/|templates/rendered:|" >> "$out" || true
  done
  if [[ "$xml" -gt 0 ]] && ! have_cmd xmllint; then
    [[ -s "$out" ]] || { missing_tool templates xmllint; return 0; }
  fi
  if [[ -s "$out" ]]; then record templates fail "rendered templates are invalid" "$out"
  else record templates pass "$n templates rendered, $xml XML output(s) well-formed"; fi
}

gate_json() {
  local out="$TMP/json.out" f n=0
  : > "$out"
  for f in "$REPO"/config/*.json "$REPO"/hooks/*.json "$REPO"/.claude-plugin/*.json; do
    [[ -f "$f" ]] || continue
    n=$((n + 1))
    jq empty "$f" > /dev/null 2>"$TMP/jq.err" || { printf '%s: ' "${f#"$REPO"/}"; cat "$TMP/jq.err"; } >> "$out"
  done
  if [[ -s "$out" ]]; then record json fail "invalid JSON" "$out"
  else record json pass "$n JSON files valid"; fi
}

gate_version() {
  local out="$TMP/version.out" pj="$REPO/.claude-plugin/plugin.json" v top tags t branch mf major
  : > "$out"
  v="$(jq -r '.version // empty' "$pj" 2>/dev/null || true)"
  if ! printf '%s\n' "$v" | grep_q -E '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'; then
    echo "plugin.json: '$v' is not a valid version (X.Y.Z or X.Y.Z-pre.N)" >> "$out"
  fi
  # The released heading of highest SemVer precedence (on the integration
  # branch a 0.9.x section merged from main may be dated, so placed, above the
  # latest 1.0 pre-release: 09-R5).
  top=""
  for t in $(awk '/^## \[/ { h = $2; gsub(/[][]/, "", h); if (h != "Unreleased") print h }' "$REPO/CHANGELOG.md" 2>/dev/null || true); do
    if [[ -z "$top" ]] || semver_gt "$t" "$top"; then top="$t"; fi
  done
  [[ "$top" == "$v" ]] || echo "plugin.json version '$v' differs from the highest released CHANGELOG.md heading '[${top:-none}]'" >> "$out"
  if git -C "$REPO" rev-parse --git-dir > /dev/null 2>&1; then
    tags="$(git -C "$REPO" tag --points-at HEAD 2>/dev/null | grep '^v' || true)"
    for t in $tags; do
      # release.sh runs this gate before its commit, on a HEAD that may still
      # carry the tag of the release it promotes (RELEASE_FROM, e.g. an rc).
      [[ "$t" == "v$v" || ( -n "${RELEASE_FROM:-}" && "$t" == "v$RELEASE_FROM" ) ]] \
        || echo "HEAD is tagged '$t', but plugin.json says '$v' (want 'v$v')" >> "$out"
    done
  fi
  branch="${GITHUB_BASE_REF:-}"
  if [[ -z "$branch" && "${GITHUB_REF_TYPE:-branch}" == "branch" ]]; then branch="${GITHUB_REF_NAME:-}"; fi
  [[ -n "$branch" || -n "${GITHUB_REF_TYPE:-}" ]] || branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$branch" == "main" && "$v" == *-* ]]; then
    echo "pre-release version '$v' on main (a pre-release lives on the integration branch only)" >> "$out"
  fi
  mf="$REPO/config/migrations.json"
  if [[ -f "$mf" ]]; then
    major="${v%%.*}"
    jq -r --slurpfile ref "$REPO/config/config-reference.json" --arg major "$major" '
      def maj: tostring | split(".")[0] | tonumber? // -1;
      def name_ok: type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*(=.*)?$");
      def declared($n): ($ref[0] | ((.keys // {}) | has($n)) or ((.runtime_only // {}) | has($n))
                          or ([(.patterns // {}) | keys[] | rtrimstr("*")] | any(. as $p | $n | startswith($p))));
      if .schema != 1 then "migrations.json: schema must be 1" else empty end,
      (["env_aliases", "value_aliases", "removed"][] as $a
        | if (.[$a] | type) != "array" then "migrations.json: \($a) must be an array" else empty end),
      ((.env_aliases // []) | to_entries[] | .key as $i | .value
        | (if ([.old, .new, .since, .remove_in] | all(type == "string")) then empty
           else "migrations.json: env_aliases[\($i)] needs string old, new, since and remove_in" end),
          (if (.old | name_ok) and (.new | name_ok) then empty
           else "migrations.json: env_aliases[\($i)] old and new must be variable names (KEY or KEY=value)" end),
          ((.new // "" | tostring | split("=")[0]) as $k
            | if declared($k) then empty else "migrations.json: env_aliases[\($i)] new key \($k) is not declared in config/config-reference.json" end),
          (if .when == null then empty
           elif (.when | type) != "object" or ((.when.key // null) | name_ok | not) or ((.when.equals | type) as $t | ["string", "number", "boolean"] | index($t) | not)
           then "migrations.json: env_aliases[\($i)] when must be {key: a variable name, equals: a string, number or boolean}"
           elif declared(.when.key) then empty
           else "migrations.json: env_aliases[\($i)] when.key \(.when.key) is not declared in config/config-reference.json" end)),
      ((.value_aliases // []) | to_entries[] | .key as $i | .value
        | (if ([.kind, .scope, .old, .new, .since, .remove_in] | all(type == "string")) then empty
           else "migrations.json: value_aliases[\($i)] needs string kind, scope, old, new, since and remove_in" end),
          (if (.kind as $kd | ["value", "field", "flag"] | any(. == $kd)) then empty
           else "migrations.json: value_aliases[\($i)] kind must be value, field or flag" end),
          (if .kind != "value" or declared(.scope // "") then empty
           else "migrations.json: value_aliases[\($i)] scope \(.scope) is not declared in config/config-reference.json" end),
          (if .kind != "flag" or ((.old // "") | startswith("--")) and ((.new // "") | startswith("--")) then empty
           else "migrations.json: value_aliases[\($i)] a flag row names two --flags" end)),
      ((.env_aliases // []) + (.value_aliases // []) + (.removed // []) | .[] | select(has("remove_in"))
        | if (.remove_in | maj) > ($major | tonumber) then empty
          else "migrations.json: \(.old // "?") has remove_in \(.remove_in), not a later major than \($major)" end)
    ' "$mf" >> "$out" 2>/dev/null || echo "migrations.json: not valid JSON" >> "$out"
  fi
  if [[ -s "$out" ]]; then record version fail "the release version is inconsistent" "$out"
  else record version pass "$v (CHANGELOG, tag, branch ${branch:-?}, migrations.json)"; fi
}

gate_config_keys() {
  local out="$TMP/ck.out" hard="$TMP/ck.hard" ref="$REPO/config/config-reference.json" read="$TMP/ck.read" f
  : > "$out"; : > "$hard"
  # A _*_comment of defaults.json may not grow past 1800 characters (hard).
  jq -r 'to_entries[] | select((.key | startswith("_")) and (.key | endswith("_comment")) and (.value | type) == "string" and (.value | length) > 1800)
         | "defaults.json \(.key) is \(.value | length) characters (limit 1800; the prose moves to config-reference.json and the docs in M11)"' \
    "$REPO/config/defaults.json" >> "$hard" 2>/dev/null || echo "defaults.json: not valid JSON" >> "$hard"
  if [[ ! -f "$ref" ]]; then
    echo "config/config-reference.json is missing" >> "$out"
  elif ! jq empty "$ref" 2>/dev/null; then
    echo "config/config-reference.json is not valid JSON" >> "$hard"
  else
    # Every DRUPILOT_* name read (not inside a word such as _DRUPILOT_X).
    { for f in "$REPO"/scripts/*.sh "$REPO"/scripts/*/*.sh "$REPO"/hooks/scripts/*.sh; do
        case "$f" in "$REPO"/scripts/dev/*) continue;; esac
        grep -vE '^[[:space:]]*#' "$f" 2>/dev/null || true
      done
      cat "$REPO"/commands/*.md "$REPO"/skills/*/SKILL.md "$REPO"/agents/*.md 2>/dev/null || true
    } | grep -oE '(^|[^A-Za-z0-9_])DRUPILOT_[A-Z0-9_]+' | sed -E 's/^[^D]//' | LC_ALL=C sort -u > "$read"
    jq -r --rawfile r "$read" --slurpfile d "$REPO/config/defaults.json" --slurpfile c "$REPO/config/choices.json" '
      def entries: ((.keys // {}) + (.runtime_only // {}) + (.patterns // {}));
      def resolves($p): ($p | split("#/")) as $q
        | if $q[0] == "defaults.json" then ($d[0] | getpath($q[1] | split("/")) != null)
          elif $q[0] == "choices.json" then ($c[0] | getpath($q[1] | split("/")) != null)
          else false end;
      . as $ref
      | ($ref.patterns // {} | keys | map(rtrimstr("*"))) as $pre
      | (entries | keys) as $declared
      | ($r | split("\n") | map(select(length > 0))[]
          | . as $n
          # declared: an exact entry; a name of a pattern family; or a bare
          # prefix mention (DRUPILOT_ISSUE_<FIELD> in prose reads as
          # DRUPILOT_ISSUE_) that some declared key or pattern starts with.
          | select(($declared | index($n)) == null
                   and ([$pre[] | select(. as $p | $n | startswith($p))] | length) == 0
                   and (($n | endswith("_")) and ([$declared[], $pre[] | select(startswith($n))] | length) > 0 | not))
          | "\($n) is read but not declared in config/config-reference.json"),
        (([$d[0] | keys[] | select(startswith("DRUPILOT_"))] | sort) as $dk
          | ([$ref.keys // {} | to_entries[] | select((.value.default_ref // "") | startswith("defaults.json#/")) | .key] | sort) as $rk
          | ($dk - $rk)[] | "\(.) is in defaults.json but not in config-reference.json keys"),
        (entries | to_entries[] | .key as $k | .value as $v | .value
          | (if (["public", "advanced", "internal", "runtime_only"] | index($v.tier // "")) == null then "\($k): tier must be public, advanced, internal or runtime_only" else empty end),
            (if ((.type // "") | length) == 0 then "\($k): no type" else empty end),
            (if ((.description // "") | length) == 0 then "\($k): no description" else empty end),
            (if .default_ref != null and (resolves(.default_ref) | not) then "\($k): default_ref \(.default_ref) does not resolve" else empty end),
            (if .enum != null and ((.default_ref // "") | startswith("defaults.json#/"))
                and (($v.enum | index($d[0][$k] | tostring)) == null) then "\($k): its enum lacks the default" else empty end))
    ' "$ref" >> "$out" 2>/dev/null || echo "config-keys: the check itself failed (jq)" >> "$out"
    # CC-06: every name the 0.9 README documents stays public.
    if [[ -f "$REPO/tests/baseline/v0.9.0/env-public-v0.9.json" ]]; then
      jq -r --slurpfile ref "$ref" '
        ($ref[0] | ((.keys // {}) + (.runtime_only // {}))) as $exact
        | ($ref[0].patterns // {} | to_entries | map(select(.value.tier == "public") | .key | rtrimstr("*"))) as $pp
        | (.stdout.public // .public // [])[]
        | sub("<KEY>$"; "") as $n
        # An exact entry decides; a pattern only covers names with no entry.
        | select(if ($exact | has($n)) then $exact[$n].tier != "public"
                 else ([$pp[] | select(. as $p | $n | startswith($p))] | length) == 0 end)
        | "\($n) is documented by the 0.9 README but not public in config-reference.json"' \
        "$REPO/tests/baseline/v0.9.0/env-public-v0.9.json" >> "$out" 2>/dev/null || true
    fi
  fi
  if [[ -s "$hard" ]]; then cat "$out" >> "$hard"; record config-keys fail "a defaults.json comment is too long, or the reference is invalid" "$hard"
  elif [[ -s "$out" ]]; then record config-keys fail "$(grep -c . "$out") undeclared or inconsistent key(s)" "$out"
  else record config-keys pass "$(grep -c . "$read") DRUPILOT_* names read, all declared; comments within 1800 characters"; fi
}

gate_docs() {
  local out="$TMP/docs.out" warn="$TMP/docs.warn" nav="$TMP/docs.nav" pages="$TMP/docs.pages" f t d
  : > "$out"; : > "$warn"
  if [[ ! -f "$REPO/mkdocs.yml" || ! -d "$REPO/docs" ]]; then record docs fail "mkdocs.yml or docs/ is missing"; return 0; fi
  # 1. The generated reference pages are current.
  "$BASH" "$REPO/scripts/dev/gen-docs.sh" --check > /dev/null 2> "$TMP/gendocs.err" \
    || { echo "generated pages drift (run scripts/dev/gen-docs.sh and commit):"
         { grep -E '^    [-+]' "$TMP/gendocs.err" | grep -vE '^    (---|[+][+][+]) ' | sed -n '1,10p'; } || true; } >> "$out"
  # 2. Nav completeness: every page is in the nav, every nav entry exists.
  awk '/^nav:/ { f = 1; next } f && /^[^[:space:]#-]/ { exit } f && !/^[[:space:]]*#/' "$REPO/mkdocs.yml" \
    | grep -oE '[A-Za-z0-9_./-]+\.md' | LC_ALL=C sort -u > "$nav" || true
  ( cd "$REPO/docs" && find . -name '*.md' | sed 's#^\./##' | LC_ALL=C sort ) > "$pages"
  while IFS= read -r f; do grep -qxF -- "$f" "$nav" || echo "docs/$f is not in the mkdocs.yml nav" >> "$out"; done < "$pages"
  while IFS= read -r f; do [[ -f "$REPO/docs/$f" ]] || echo "mkdocs.yml nav entry $f does not exist under docs/" >> "$out"; done < "$nav"
  # 3. Stale citations in the plugin files.
  for f in "$REPO"/commands/*.md "$REPO"/skills/*/SKILL.md "$REPO"/agents/*.md "$REPO"/scripts/*.sh "$REPO"/scripts/*/*.sh "$REPO"/hooks/scripts/*.sh; do
    case "$f" in "$REPO"/scripts/dev/*) continue;; esac
    grep -nF -e 'README "' -e 'README.md (' "$f" 2>/dev/null | sed "s#^#${f#"$REPO"/}:#; s#\$# (cite docs/<page>.md instead)#" >> "$out" || true
    for t in $(grep -oE 'docs/[a-z0-9/_.-]+\.md' "$f" 2>/dev/null | LC_ALL=C sort -u); do
      [[ -f "$REPO/$t" ]] || echo "${f#"$REPO"/} cites $t, which does not exist" >> "$out"
    done
  done
  # 4. Relative links between docs pages resolve.
  while IFS= read -r f; do
    d="$(dirname "$REPO/docs/$f")"
    for t in $(grep -oE '\]\([^)#[:space:]]+\.md(#[^)]*)?\)' "$REPO/docs/$f" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//; s/#.*$//' | LC_ALL=C sort -u); do
      case "$t" in http://*|https://*|/*) continue;; esac
      [[ -f "$d/$t" ]] || echo "docs/$f links to $t, which does not exist" >> "$out"
    done
  done < "$pages"
  # 5. English only (warn).
  ( cd "$REPO/docs" && find . -name '*_es.md' -o -type d -name es ) | sed 's#^\./#docs/#; s#$# (the site is English only)#' >> "$warn"
  local flow=""
  for f in $( (cd "$REPO" && ls FLOW*.md 2>/dev/null || true) | LC_ALL=C sort); do flow="$flow $f"; done
  [[ -z "$flow" ]] || flow="; to move into docs/concepts/how-it-works.md:$flow"
  if [[ -s "$out" ]]; then record docs fail "the docs site is inconsistent" "$out"
  elif [[ -s "$warn" ]]; then record docs warn "$(grep -c . "$pages") pages consistent; $(grep -c . "$warn") language note(s)" "$warn"
  else record docs pass "$(grep -c . "$pages") pages: generated pages current, nav complete, citations and links resolve$flow"; fi
}

gate_schemas() {
  local js="$TMP/schemas.json" err="$TMP/schemas.err" out="$TMP/schemas.out" mode="auto"
  # --ci needs the second engine: check-jsonschema from PATH, else the pinned
  # Docker image (ADR 0010); neither is a failure.
  if [[ "$CI" == "1" ]]; then
    if have_cmd check-jsonschema; then mode="validator"
    elif have_cmd docker && docker info > /dev/null 2>&1; then mode="docker"
    else record schemas fail "--ci needs check-jsonschema on PATH (pipx install check-jsonschema==0.38.2) or a running Docker"; return 0; fi
  fi
  if "$BASH" "$REPO/scripts/dev/schema-check.sh" --mode "$mode" --json > "$js" 2> "$err"; then
    record schemas pass "$(jq -r '[.checks[] | select(.engine == "jq")] | length' "$js" 2>/dev/null || echo '?') artifact(s) match their schema ($(jq -r '.engines | join(" + ")' "$js" 2>/dev/null || echo jq))"
  else
    jq -r '.checks[] | select(.status != "pass") | "\(.engine): \(.schema) <- \(.instance): \(.detail)"' "$js" > "$out" 2>/dev/null || true
    [[ -s "$out" ]] || tail -n 20 "$err" > "$out"
    record schemas fail "an artifact does not match its schema" "$out"
  fi
}

gate_data() {
  local js="$TMP/data.json" err="$TMP/data.err" out="$TMP/data.out" rj="$TMP/recipes.json" rok=1
  # config/recipes.json is generated from the catalogs (ADR 0023).
  "$BASH" "$REPO/scripts/dev/gen-recipes.sh" --check --json > "$rj" 2> "$TMP/recipes.err" || rok=0
  if "$BASH" "$REPO/scripts/dev/data-check.sh" --json > "$js" 2> "$err" && [[ "$rok" == "1" ]]; then
    record data pass "$(jq -r '[.checks[].file] | unique | length' "$js" 2>/dev/null || echo '?') data file(s): valid, sourced and safe for the hard gates; $(jq -r '.recipes' "$rj" 2>/dev/null || echo '?') recipes generated from the catalogs"
  else
    jq -r '.checks[] | select(.status != "pass") | "\(.check): \(.file): \(.detail)"' "$js" > "$out" 2>/dev/null || true
    jq -r '.problems[]? | "recipes: \(.)"' "$rj" >> "$out" 2>/dev/null || true
    # The generator died before its report: its own error says why.
    # (-s: jq 1.6 exits 0 on an empty input with -e.)
    if [[ "$rok" == "0" ]] && ! jq -e -s 'length == 1 and (.[0] | has("problems"))' "$rj" > /dev/null 2>&1; then tail -n 5 "$TMP/recipes.err" | sed 's/^/recipes: /' >> "$out"; fi
    [[ -s "$out" ]] || tail -n 20 "$err" > "$out"
    record data fail "the version data or the recipes have problems (scripts/dev/data-check.sh, scripts/dev/gen-recipes.sh --check)" "$out"
  fi
}

gate_unit() {
  local js="$TMP/unit.json" err="$TMP/unit.err" out="$TMP/unit.out" n k
  if "$BASH" "$REPO/scripts/dev/unit.sh" --json > "$js" 2> "$err"; then
    n="$(jq -r '[.tests[] | select(.status == "pass")] | length' "$js" 2>/dev/null || echo '?')"
    k="$(jq -r '[.tests[] | select(.status == "skip") | .name] | if length == 0 then "" else ", skipped until their milestone: " + join(",") end' "$js" 2>/dev/null || true)"
    record unit pass "$n unit tests passed${k} (bash ${BASH_VERSION:-?})"
  else
    jq -r '.tests[] | select(.status == "fail") | .name as $n | (.failures[]? // .detail) | "\($n): \(.)"' "$js" > "$out" 2>/dev/null || true
    [[ -s "$out" ]] || tail -n 20 "$err" > "$out"
    record unit fail "scripts/dev/unit.sh reported failures (re-run it for the full log)" "$out"
  fi
}

gate_contract() {
  local js="$TMP/contract.json" err="$TMP/contract.err" out="$TMP/contract.out" n
  if "$BASH" "$REPO/scripts/dev/contract.sh" --check --json > "$js" 2> "$err"; then
    n="$(jq -r '.snapshots | length' "$js" 2>/dev/null || echo '?')"
    record contract pass "$n snapshots keep the 0.9 contract (or an allowed change)"
  else
    jq -r '.snapshots[] | select(.status == "differs" or .status == "missing") | "\(.name): \(.detail)"' "$js" > "$out" 2>/dev/null || true
    [[ -s "$out" ]] || tail -n 20 "$err" > "$out"
    record contract fail "scripts/dev/contract.sh: the public surface differs from the 0.9 contract" "$out"
  fi
}

gate_evals() {
  local js="$TMP/evals.json" err="$TMP/evals.err" out="$TMP/evals.out"
  if "$BASH" "$REPO/scripts/dev/evals.sh" --json > "$js" 2> "$err"; then
    record evals pass "$(jq -r '.checks | length' "$js" 2>/dev/null || echo '?') static router checks passed"
  else
    jq -r '.checks[] | select(.status != "pass") | "\(.name): \(.detail)"' "$js" > "$out" 2>/dev/null || true
    [[ -s "$out" ]] || tail -n 20 "$err" > "$out"
    record evals fail "scripts/dev/evals.sh: the router evals failed" "$out"
  fi
}

gate_golden() {
  local js="$TMP/golden.json" err="$TMP/golden.err" out="$TMP/golden.out"
  if "$BASH" "$REPO/scripts/dev/golden.sh" --check --json > "$js" 2> "$err"; then
    record golden pass "$(jq -r '[.goldens[] | .name] | join(", ")' "$js" 2>/dev/null || echo '?'): every golden output matches"
  else
    jq -r '.goldens[] | select(.status != "pass") | "\(.name): \(.detail)"' "$js" > "$out" 2>/dev/null || true
    [[ -s "$out" ]] || tail -n 20 "$err" > "$out"
    record golden fail "scripts/dev/golden.sh: a golden output differs" "$out"
  fi
}

gate_smoke() {
  local js="$TMP/smoke.json" err="$TMP/smoke.err" out="$TMP/smoke.out" n x
  # Same interpreter as this gate, so `/bin/bash scripts/dev/check.sh` on macOS
  # smoke-tests stock bash 3.2 end to end.
  if "$BASH" "$REPO/scripts/dev/smoke.sh" --json > "$js" 2> "$err"; then
    n="$(jq -r '[.tests[] | select(.status == "pass")] | length' "$js" 2>/dev/null || echo '?')"
    x="$(jq -r '[.tests[] | select(.status == "xfail") | .name] | if length == 0 then "" else ", xfail: " + join(",") end' "$js" 2>/dev/null || true)"
    record smoke pass "$n smoke tests passed${x} (bash ${BASH_VERSION:-?})"
  else
    jq -r '.tests[] | select(.status == "fail") | .name as $n | .failures[] | "\($n): \(.)"' "$js" > "$out" 2>/dev/null || true
    [[ -s "$out" ]] || tail -n 20 "$err" > "$out"
    record smoke fail "scripts/dev/smoke.sh reported failures (re-run it for the full log)" "$out"
  fi
}

# ---------------------------------------------------------------------------
log_step "drupilot developer gate ($REPO)"
for gate in $ALL_GATES; do
  if [[ -n "$ONLY" ]] && ! in_list "$gate" "$ONLY"; then continue; fi
  if [[ -z "$ONLY" && "$SMOKE" != "1" ]] && in_list "$gate" "$OPTIONAL_GATES"; then continue; fi
  if [[ -n "$SKIP" ]] && in_list "$gate" "$SKIP"; then continue; fi
  "gate_${gate//-/_}"
done

if [[ "$FAILED" == "1" ]]; then log_err "check.sh: at least one gate failed"
else log_ok "check.sh: all gates passed"; fi

if [[ "$AS_JSON" == "1" ]]; then
  jq -s -c --argjson ok "$([[ "$FAILED" == "1" ]] && echo false || echo true)" \
    '{ok:$ok, gates:.}' "$RESULTS"
fi

exit "$FAILED"
