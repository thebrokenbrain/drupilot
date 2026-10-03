#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/dev/check.sh
# The single local developer gate for the plugin itself (it never runs at plugin
# runtime: no command, skill or hook calls it). Run it before every commit.
#
# Gates (in order; names are what --only/--skip/--allow-fail take):
#   - validate    `claude plugin validate .` (skipped when `claude` is absent)
#   - syntax      `bash -n` on scripts/*/*.sh and hooks/scripts/*.sh
#   - exec-bit    those scripts are executable (git mode 100755 when tracked,
#                 the filesystem -x bit otherwise)
#   - shellcheck  `shellcheck -S warning` on the same scripts (reads .shellcheckrc;
#                 skipped when shellcheck is absent)
#   - portability no bash-4-only or GNU-only construct in those scripts (they
#                 must run on bash 3.2 + BSD tools, i.e. stock macOS): ${x,,},
#                 ${x^^}, declare/local -A|-n|-g, mapfile/readarray, sed -i,
#                 readlink -f, realpath, grep -P, grep --include/--exclude/
#                 --exclude-dir before its `--` (BusyBox grep has none; select
#                 the files with find), also in an option array, date -d,
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
#   - jq-compat   no jq program in those scripts uses a jq keyword (label,
#                 module, if, then, else, end, as, def, reduce, foreach, try,
#                 catch, and, or, not, import, include, __loc__) as a --arg /
#                 --argjson name, an `as $name` binding or a shorthand object
#                 key (`{module, scope}`): jq 1.6 (Debian 12, Ubuntu 22.04 —
#                 drupilot's jq_min) rejects each as a syntax error, jq 1.7
#                 accepts it. `{label: .x}` and `.label` are fine everywhere.
#                 A line can opt out with a trailing `# jq-compat-ok` and a reason
#   - bang-lint   no `!`...`` exec span in commands/*.md, skills/*/SKILL.md or
#                 agents/*.md contains a <placeholder>: those spans run at command
#                 load, before the model can substitute anything
#   - templates   render every templates/*.tmpl with dummy values; each XML output
#                 must pass `xmllint --noout` (skipped when xmllint is absent)
#   - json        `jq empty` on config/*.json, hooks/*.json, .claude-plugin/*.json
#   - smoke       OPTIONAL (only with --smoke, --ci or --only smoke): the
#                 Docker-free smoke tests of scripts/dev/smoke.sh (expected
#                 results on tests/fixtures/), run with this same bash
#
# Usage:
#   scripts/dev/check.sh [--json] [--only G1,G2] [--skip G1,G2]
#                        [--allow-fail G1,G2] [--allow-known] [--smoke] [--ci]
#     --json         machine summary on STDOUT (logs stay on STDERR)
#     --only/--skip  run a subset of the gates
#     --allow-fail   report these gates' failures as "allowed-fail" (exit 0)
#     --allow-known  shorthand for --allow-fail with the gates listed in
#                    KNOWN_FAILING below (failures already tracked for a fix)
#     --smoke        also run the optional smoke gate (~15 s)
#     --ci           a missing optional tool (claude/shellcheck/xmllint) is a
#                    failure instead of a skip; implies --smoke
#
# Output (--json):
#   {ok, gates:[{name, status: pass|fail|skip|allowed-fail, detail, findings:[..]}]}
#
# Exit codes: 0 all gates pass/skip/allowed-fail · 1 a gate failed or usage error.
# Read-only: renders templates into a temp dir that is removed on exit.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$REPO"

ALL_GATES="validate syntax exec-bit shellcheck portability special-vars jq-compat bang-lint templates json smoke"
# Gates that run only when asked for (--smoke, --ci, or named in --only).
OPTIONAL_GATES="smoke"
# Gates known to fail on the current tree, with a fix tracked for 0.9.0. Empty
# this list as the fixes land so --allow-known stops hiding them.
KNOWN_FAILING=""

AS_JSON=0; ONLY=""; SKIP=""; ALLOW=""; CI=0; SMOKE=0

usage() { awk 'NR>2 && /^# =+$/ {exit} NR>2 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) AS_JSON=1; shift;;
    --only) ONLY="${2:-}"; shift 2 || die "--only needs a value" 1;;
    --only=*) ONLY="${1#*=}"; shift;;
    --skip) SKIP="${2:-}"; shift 2 || die "--skip needs a value" 1;;
    --skip=*) SKIP="${1#*=}"; shift;;
    --allow-fail) ALLOW="$ALLOW,${2:-}"; shift 2 || die "--allow-fail needs a value" 1;;
    --allow-fail=*) ALLOW="$ALLOW,${1#*=}"; shift;;
    --allow-known) ALLOW="$ALLOW,${KNOWN_FAILING// /,}"; shift;;
    --smoke) SMOKE=1; shift;;
    --ci) CI=1; SMOKE=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done

# in_list <word> <comma/space separated list>
in_list() { case ",${2// /,}," in *",$1,"*) return 0;; esac; return 1; }

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
  cd "$REPO" && ls scripts/*/*.sh hooks/scripts/*.sh 2>/dev/null | LC_ALL=C sort)

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
    mode="$(git -C "$REPO" ls-files -s -- "$f" 2>/dev/null | awk '{print $1; exit}' || true)"
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
      # grep_files_opt <line> -> 1 when a grep on the line takes --include,
      # --exclude or --exclude-dir before its end of options (" -- ") or the
      # end of its command (a pipe, a ";").
      function grep_files_opt(l,   rest, cut) {
        if (!match(l, /(^|[^A-Za-z0-9_.-])grep[[:space:]]/)) return 0
        rest = substr(l, RSTART + RLENGTH - 1)
        cut = index(rest, " -- "); if (cut > 0) rest = substr(rest, 1, cut)
        if (match(rest, /[|;]/)) rest = substr(rest, 1, RSTART)
        return (rest ~ /[[:space:]"'\'']--(include|exclude|exclude-dir)([=[:space:]]|$)/)
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
            line ~ /(^|[[:space:](])--(include|exclude-dir)=/ || grep_files_opt(line) ||
            (line ~ /(^|[[:space:](])--exclude=/ && line !~ /(^|[^A-Za-z])(tar|phpcs|phpcbf|rsync)/) ||
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
            line ~ ("(^|[^$])[{][[:space:]]*" e "[[:space:]]*[,}]") ||
            line ~ ("(^|[^$])[{][^{}]*,[[:space:]]*" e "[[:space:]]*[,}]"))
          printf "%s:%d: %s\n", F, NR, substr($0, 1, 140)
      }' "$f") >> "$out"
  done
  if [[ -s "$out" ]]; then
    record jq-compat fail "$(wc -l < "$out" | tr -d ' ') jq keyword(s) used as a variable or shorthand key (jq 1.6 syntax error; rename, e.g. \$lbl / {label: .label})" "$out"
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
      *) head -c 5 "$dest" | grep -q '^<?xml' || continue;;
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
