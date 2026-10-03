#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/dev/smoke.sh
# Docker-free smoke tests for the plugin itself, with expected-result
# assertions (a developer/CI tool: no command, skill or hook calls it). It runs
# the read-only scripts that need no DDEV, no Docker and no PHP against the
# fixtures in tests/fixtures/ and compares their JSON with the results recorded
# in tests/fixtures/*.EXPECTED.md. scripts/dev/check.sh runs it as its optional
# `smoke` gate (--smoke, implied by --ci).
#
# Every script is run with the SAME bash that runs this file ($BASH), so
# `/bin/bash scripts/dev/smoke.sh` on macOS exercises stock bash 3.2 + BSD
# tools end to end.
#
# Tests (names are what --only takes):
#   help           every scripts/{analysis,contrib,env,tests,dev}/*.sh --help
#                  exits 0 and prints a Usage section on STDOUT
#   preflight      preflight.sh --profile analyze --json: one JSON object, exit
#                  0 or 2 consistent with .ready.analyze, a passing bash row;
#                  --profile all always exits 0
#   detect-php     detect-php.sh --json: target 8.3 by default, the
#                  DRUPILOT_PHP_TARGET override wins
#   next-step      next-step.sh on a fresh module: setup when ready, doctor when
#                  analysis is not ready, the --human one-liner; a subject
#                  recorded only as tested, or with only a port manifest, is
#                  not sent back to port; a folder of modules gets layers
#   hooks          guard-contrib.sh asks before `git push` in autonomous and
#                  non-interactive mode (even with DRUPILOT_CONTRIB_MODE=auto),
#                  no-ops on other commands and on garbage stdin (exit 0);
#                  session-detect-env.sh honors DRUPILOT_SESSION_CONTEXT=off
#   port-safety    check-port-safety.sh on legacy_widgets: the pre-existing
#                  findings (H12, H22) and no plugin-di; then removing
#                  `implements ContainerFactoryPluginInterface` from the
#                  QueueWorker (H1) turns plugin-di red, attributed to the port
#                  ("introduced") in diff mode when git is available
#   signature      scan-signature-changes.sh on legacy_widgets (H10, H14-H16)
#                  for the declared ^10 floor and for a ^11.3 floor
#   lint-metadata  lint-extension-metadata.sh on legacy_widgets and on each
#                  monorepo module (per-module error/warn/info totals, an
#                  undeclared-deps message text); a same-named copy in the
#                  --set-dir does not duplicate plugin-schema findings
#   (every test)   a shell-level error on a script's stderr (syntax error,
#                  unbound variable, command not found, ...) fails the test
#   layers         layers.sh on the monorepo: layers, cycle, early module,
#                  totals, proposed entries, external modules; --edges declared
#                  (saved as a variant, never over the canonical layers.json;
#                  layer-report.sh reports its edges mode);
#                  layer-report.sh picks up a linted, unregistered module
#   dry-run        set-core-requirement.sh --dry-run and ensure-gitignore.sh
#                  --dry-run report their change and write nothing
#   patterns       every config/deprecations.json ERE is accepted by
#                  patterns.sh add --dry-run, a PCRE \d is refused, and list
#                  prints the stored ERE verbatim
#   status-probe   the /drupilot-status load-time probe and next-step.sh leave
#                  the subject tree and the data dir unchanged
#   core-target    core-strategy.sh keeps a declared minor floor (^10.3 ->
#                  ^10.3 || ^11) and raises it to the minor of a plugin
#                  attribute class the code uses (Block -> ^10.2 || ^11;
#                  ContentEntityType -> ^11.1); the default matrix legs include
#                  the declared floor (^10 || ^11 -> 10.0, 10, 11), also in
#                  verify-core-matrix.sh --dry-run on a stub Drupal root
#   attributes     php-scan.sh reads attribute constructor parameters (own,
#                  inherited, variadic) and annotation top-level keys; on a
#                  stub Drupal root with a stub Rector, convert-attributes.sh
#                  skips a @MigrateSource whose source_module key the
#                  MigrateSource attribute constructor does not take (needs the
#                  analyze profile, else skipped with a warning)
#   rector-cache   run-rector.sh (stub Rector) passes --clear-cache to every
#                  pass, and an --apply that changes nothing after a dry-run of
#                  the same code announced changes is an error (exit 3)
#                  (needs the analyze profile, else skipped with a warning)
#   state-stdin    state.sh list (with the next step) over two subjects of a
#                  test-bed whose DDEV project is up, with a fake `ddev` on PATH
#                  that drains its stdin: both subjects are listed (a ddev call
#                  inside the read loop must not swallow the rest of the list)
#   shared-testbed two modules copied into ONE stub test-bed: each keeps its
#                  own origin baseline (origin-hygiene.sh --check clean for
#                  both), state.sh shows each module's own origin, and
#                  layer-report.sh maps each row to that module's record
#   matrix-classify verify-core-matrix.sh's finding classifier (its jq program,
#                  read from the script): a type from a sibling module missing
#                  on a reference core is a sandbox_missing_dependency in every
#                  message shape, never the subject's own class
#   port-summary   port-summary.sh keeps a recorded `false` (digests, fresh)
#                  and takes d10_support and the core-matrix blocker from the
#                  same source (a fresh core matrix over the manifest)
#   project-root   subject_project_root (what ddev-add-ons.sh --subject uses)
#                  resolves the Drupal root above a placed subject, the sibling
#                  test-bed of a loose checkout, and the test-bed holding a
#                  moved-away original path
#   monorepo-testbed  the monorepo fixture as a git checkout without core
#                  (also with a committed .ddev/): resolve-workspace.sh sees a
#                  project root without installed core and picks the sibling
#                  '<repo>-d11' test-bed (copy, never inside the repo); a
#                  folder of modules in a non-project repo gets
#                  '<parent of repo>/<name>-d11'; a Drupal 10 site is not
#                  in_place_ok and an explicit workspace moves the port out of
#                  it. On a stub test-bed, place-subject.sh gives the copy a git
#                  baseline, make-patch.sh --local writes a module-relative
#                  patch and a repo-relative one, both apply with git apply
#                  --check (pristine module / monorepo root), and the
#                  monorepo's git status stays empty; clean.sh may discard
#                  the pristine seeded copy but not the ported one (needs git)
#   phpcs-scope    run-phpcs.sh --fix --fix-scope changed (stub phpcs/phpcbf
#                  on a stub Drupal root) hands phpcbf only the files that
#                  differ from the pre-port git base plus new ones, --fix
#                  alone still fixes the whole subject, and a subject outside
#                  git is report-only (needs the analyze profile and git)
#
# Isolation: the fixtures are copied to a temp dir (legacy_widgets is committed
# there as a git repo when git exists), and HOME, CLAUDE_PLUGIN_DATA and the
# XDG dirs point inside it; every DRUPILOT_* variable is unset. Nothing is
# written to the repository or to the developer's state. The temp dir is
# removed on exit (--keep leaves it for inspection).
#
# Usage:
#   scripts/dev/smoke.sh [--only T1,T2] [--skip T1,T2] [--json] [--keep]
#                        [--list] [-h|--help]
#     --only/--skip  run a subset of the tests
#     --json         machine summary on STDOUT (logs stay on STDERR):
#                    {ok, bash, tests:[{name, status: pass|fail, detail,
#                                       failures:[..]}]}
#     --keep         keep the temp dir and print its path on STDERR
#     --list         print the test names, one per line, and exit
#
# Requires bash >= 3.2 and jq; git is optional (the diff-mode assertion is
# skipped without it, with a warning). Exit codes: 0 every selected test
# passed · 1 a test failed or usage error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIX="$REPO/tests/fixtures"
SH="${BASH:-bash}"

ALL_TESTS="help preflight detect-php next-step hooks port-safety signature lint-metadata layers dry-run patterns status-probe core-target attributes rector-cache state-stdin shared-testbed matrix-classify port-summary project-root monorepo-testbed phpcs-scope"

AS_JSON=0; ONLY=""; SKIP=""; KEEP=0

usage() { print_usage "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 || die "--only needs a value" 1;;
    --only=*) ONLY="${1#*=}"; shift;;
    --skip) SKIP="${2:-}"; shift 2 || die "--skip needs a value" 1;;
    --skip=*) SKIP="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    --keep) KEEP=1; shift;;
    --list) printf '%s\n' $ALL_TESTS; exit 0;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done

# in_list <word> <comma/space separated list>
in_list() { case ",$(printf '%s' "$2" | tr ' ' ','),"  in *",$1,"*) return 0;; esac; return 1; }

for _t in $(printf '%s %s' "$ONLY" "$SKIP" | tr ',' ' '); do
  in_list "$_t" "$ALL_TESTS" || die "Unknown test: $_t (tests: $ALL_TESTS)" 1
done

have_cmd jq || die "jq is required by scripts/dev/smoke.sh" 1
[[ -d "$FIX/legacy_widgets" && -d "$FIX/monorepo" ]] || die "Fixtures not found under $FIX" 1

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-smoke.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
cleanup() {
  if [[ "$KEEP" == "1" ]]; then log_info "Kept the smoke workspace: $TMP"
  else rm -rf "${TMP:?}"; fi
}
trap cleanup EXIT

# --- Isolated environment -----------------------------------------------------
for _v in $(env | sed -n 's/^\(DRUPILOT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
export CLAUDE_PLUGIN_ROOT="$REPO"
export HOME="$TMP/home"
export CLAUDE_PLUGIN_DATA="$TMP/data"
export XDG_DATA_HOME="$TMP/home/.local/share" XDG_STATE_HOME="$TMP/home/.local/state"
export XDG_CACHE_HOME="$TMP/home/.cache" XDG_CONFIG_HOME="$TMP/home/.config"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$CLAUDE_PLUGIN_DATA" "$TMP/out"

FX="$TMP/fx"
mkdir -p "$FX"
cp -R "$FIX/legacy_widgets" "$FIX/monorepo" "$FX/"
LW="$FX/legacy_widgets"
MONO="$FX/monorepo"
CUSTOM="$MONO/web/modules/custom"

HAVE_GIT=0
if have_cmd git; then
  if git -C "$LW" init -q >/dev/null 2>&1 \
     && git -C "$LW" add -A >/dev/null 2>&1 \
     && git -C "$LW" -c user.name=drupilot-smoke -c user.email=smoke@example.invalid \
          -c commit.gpgsign=false commit -q -m "Initial legacy_widgets fixture (Drupal 10.3)" >/dev/null 2>&1; then
    HAVE_GIT=1
  else
    log_warn "git could not commit the fixture; the diff-mode assertion is skipped."
  fi
fi

# --- Harness --------------------------------------------------------------------
RESULTS="$TMP/results.jsonl"
: > "$RESULTS"
FAILED=0
T_FAILS="$TMP/fails.txt"
T_NAME=""
RC=0

# run <tag> <cmd...> -> stdout in $TMP/out/<tag>.out, stderr in .err, exit in $RC.
# A shell-level failure on stderr (a parse error a bash version hits only at
# runtime, an unbound variable, a missing command) fails the current test even
# when the script still exits 0 and its payload looks right.
run() {
  local tag="$1" hit; shift
  if "$@" > "$TMP/out/$tag.out" 2> "$TMP/out/$tag.err" < /dev/null; then RC=0; else RC=$?; fi
  hit="$(grep -E 'syntax error|unbound variable|command not found|bad substitution|: invalid option|integer expression expected' \
           "$TMP/out/$tag.err" 2>/dev/null | head -n 3 || true)"
  if [[ -n "$hit" ]]; then
    printf '%s: shell error on stderr: %s\n' "$tag" "$(printf '%s' "$hit" | tr '\n' ' ' | head -c 300)" >> "$T_FAILS"
  fi
  return 0
}
# out <tag> -> the captured stdout
out() { cat "$TMP/out/$1.out"; }
# jqo <tag> <filter> -> jq -c over the captured stdout ("<invalid-json>" on error)
jqo() { jq -c "$2" "$TMP/out/$1.out" 2>/dev/null || printf '<invalid-json>'; }

# expect <label> <got> <want>
expect() {
  if [[ "$2" != "$3" ]]; then
    printf '%s: got [%s] want [%s]\n' "$1" "$2" "$3" >> "$T_FAILS"
  fi
  return 0
}
# expect_match <label> <got> <ERE>
expect_match() {
  if ! printf '%s' "$2" | grep -Eq "$3"; then
    printf '%s: [%s] does not match /%s/\n' "$1" "$(printf '%s' "$2" | head -c 200)" "$3" >> "$T_FAILS"
  fi
  return 0
}

begin() { T_NAME="$1"; : > "$T_FAILS"; }
# finish -> records the current test's verdict from its collected failures.
finish() {
  local status detail findings="[]"
  if [[ -s "$T_FAILS" ]]; then
    status="fail"; detail="$(wc -l < "$T_FAILS" | tr -d ' ') assertion(s) failed"
    findings="$(jq -R . < "$T_FAILS" | jq -s -c .)"; FAILED=1
  else status="pass"; detail="ok"; fi
  jq -n -c --arg n "$T_NAME" --arg s "$status" --arg d "$detail" --argjson f "$findings" \
    '{name:$n, status:$s, detail:$d, failures:$f}' >> "$RESULTS"
  case "$status" in
    pass) log_ok "$T_NAME";;
    fail) log_err "$T_NAME: FAILED — $detail"; sed 's/^/    /' "$T_FAILS" >&2;;
  esac
  return 0
}

# --- Tests ----------------------------------------------------------------------
test_help() {
  local f n=0
  for f in "$REPO"/scripts/analysis/*.sh "$REPO"/scripts/contrib/*.sh "$REPO"/scripts/env/*.sh \
           "$REPO"/scripts/tests/*.sh "$REPO"/scripts/dev/*.sh; do
    [[ -f "$f" ]] || continue
    n=$((n + 1))
    run help "$SH" "$f" --help
    expect "${f#"$REPO"/} --help exit" "$RC" "0"
    grep -q 'Usage' "$TMP/out/help.out" || printf '%s --help: no Usage section on STDOUT\n' "${f#"$REPO"/}" >> "$T_FAILS"
  done
  [[ "$n" -gt 0 ]] || printf 'no script found\n' >> "$T_FAILS"
  finish
}

test_preflight() {
  run pf "$SH" "$REPO/scripts/env/preflight.sh" --profile analyze --json --subject "$LW"
  expect "analyze: one JSON object" "$(jqo pf 'type')" '"object"'
  expect "analyze: profile" "$(jqo pf '.profile')" '"analyze"'
  expect "analyze: ready keys" "$(jqo pf '.ready | keys')" '["analyze","contribute","setup","test"]'
  expect "analyze: bash row ok" "$(jqo pf '[.checks[] | select(.id == "bash") | .ok]')" '[true]'
  case "$(jqo pf '.ready.analyze')/$RC" in
    true/0|false/2) ;;
    *) printf 'analyze: exit %s inconsistent with ready.analyze=%s\n' "$RC" "$(jqo pf '.ready.analyze')" >> "$T_FAILS";;
  esac
  run pfall "$SH" "$REPO/scripts/env/preflight.sh" --profile all --json --subject "$LW"
  expect "all: exit" "$RC" "0"
  expect "all: profile" "$(jqo pfall '.profile')" '"all"'
  finish
}

test_detect_php() {
  run dp "$SH" "$REPO/scripts/env/detect-php.sh" --json --subject "$LW"
  expect "default: exit" "$RC" "0"
  expect "default: keys" "$(jqo dp 'keys')" '["ddev_php","host_php","supported","target","unconfirmed"]'
  expect "default: target" "$(jqo dp '.target')" '"8.3"'
  expect "default: supported" "$(jqo dp '.supported')" 'true'
  run dp84 env DRUPILOT_PHP_TARGET=8.4 "$SH" "$REPO/scripts/env/detect-php.sh" --json --subject "$LW"
  expect "override: target" "$(jqo dp84 '.target')" '"8.4"'
  finish
}

test_next_step() {
  local R="--ready-analyze true --ready-setup true --ready-test true --ready-contribute true"
  # shellcheck disable=SC2086  # $R is a fixed list of flag/value words
  run ns "$SH" "$REPO/scripts/env/next-step.sh" --subject "$LW" $R
  expect "ready: exit" "$RC" "0"
  expect "ready: next" "$(jqo ns '[.next, .command, .is_extension, .type, .assessed, .phase]')" \
    '["setup","/drupilot-setup",true,"module",false,null]'
  run nsd "$SH" "$REPO/scripts/env/next-step.sh" --subject "$LW" --ready-analyze false
  expect "not ready: next" "$(jqo nsd '.next')" '"doctor"'
  # shellcheck disable=SC2086
  run nsh "$SH" "$REPO/scripts/env/next-step.sh" --subject "$LW" $R --human
  expect_match "human one-liner" "$(out nsh)" '^Next: /drupilot-setup'
  # A later stage implies the earlier ones: a subject recorded only as tested
  # (no 'ported' writer ran) is not sent back to /drupilot-port, and a port
  # finished before stages were recorded counts from its port manifest.
  local t="$FX/stage_tested/legacy_widgets" mf="$FX/stage_manifest/legacy_widgets" sd
  mkdir -p "$FX/stage_tested" "$FX/stage_manifest"
  cp -R "$LW" "$t"; cp -R "$LW" "$mf"
  for sd in "$t" "$mf"; do
    printf '{"verdict":"S"}\n' > "$(project_state_dir "$sd")/assess.json"
    printf '{"status":"passed","preservation":"verified"}\n' > "$(project_state_dir "$sd")/last-test.json"
  done
  run nst "$SH" "$REPO/scripts/env/state.sh" record --subject "$t" --stage tested
  run nst "$SH" "$REPO/scripts/env/next-step.sh" --subject "$t" --ready-analyze true --ready-setup false
  expect "tested only: next/phase" "$(jqo nst '[.next, .phase]')" '["contribute","tested"]'
  # A folder of modules is a set: /drupilot-layers, not the single-subject flow.
  run nsl "$SH" "$REPO/scripts/env/next-step.sh" --subject "$CUSTOM" --ready-analyze true --ready-setup true
  expect "module set: next" "$(jqo nsl '.next')" '"layers"'
  expect_match "module set: command" "$(jqo nsl '.command')" '^"/drupilot-layers .*/web/modules/custom plan"$'
  printf '{"machine_name":"legacy_widgets","phase":"port"}\n' > "$(project_state_dir "$mf")/port-manifest.json"
  run nsm "$SH" "$REPO/scripts/env/next-step.sh" --subject "$mf" --ready-analyze true --ready-setup false
  expect "manifest only: next/phase" "$(jqo nsm '[.next, .phase]')" '["contribute","ported"]'
  finish
}

test_hooks() {
  local h="$REPO/hooks/scripts"
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' > "$TMP/push.json"
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' > "$TMP/ls.json"
  printf '%s' 'not json {' > "$TMP/garbage.json"
  if env DRUPILOT_AUTONOMOUS=true "$SH" "$h/guard-contrib.sh" < "$TMP/push.json" > "$TMP/out/g1.out" 2>/dev/null; then RC=0; else RC=$?; fi
  expect "autonomous push: exit" "$RC" "0"
  expect "autonomous push: decision" "$(jqo g1 '.hookSpecificOutput.permissionDecision')" '"ask"'
  # A non-interactive wrapper run is as unattended as auto: it asks even in
  # the 'auto' contribution mode (env, or a prefix of the command itself).
  if env DRUPILOT_NONINTERACTIVE=1 DRUPILOT_CONTRIB_MODE=auto "$SH" "$h/guard-contrib.sh" < "$TMP/push.json" > "$TMP/out/g4.out" 2>/dev/null; then RC=0; else RC=$?; fi
  expect "non-interactive push: decision" "$(jqo g4 '.hookSpecificOutput.permissionDecision')" '"ask"'
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"DRUPILOT_NONINTERACTIVE=1 git push origin main"}}' > "$TMP/push-ni.json"
  if env DRUPILOT_CONTRIB_MODE=auto "$SH" "$h/guard-contrib.sh" < "$TMP/push-ni.json" > "$TMP/out/g5.out" 2>/dev/null; then RC=0; else RC=$?; fi
  expect "prefixed non-interactive push: decision" "$(jqo g5 '.hookSpecificOutput.permissionDecision')" '"ask"'
  if env DRUPILOT_CONTRIB_MODE=auto "$SH" "$h/guard-contrib.sh" < "$TMP/push.json" > "$TMP/out/g6.out" 2>/dev/null; then RC=0; else RC=$?; fi
  expect "auto-mode push: decision" "$(jqo g6 '.hookSpecificOutput.permissionDecision')" '"allow"'
  if "$SH" "$h/guard-contrib.sh" < "$TMP/ls.json" > "$TMP/out/g2.out" 2>/dev/null; then RC=0; else RC=$?; fi
  expect "plain command: exit" "$RC" "0"
  expect "plain command: no payload" "$(out g2)" ""
  if "$SH" "$h/guard-contrib.sh" < "$TMP/garbage.json" > "$TMP/out/g3.out" 2>/dev/null; then RC=0; else RC=$?; fi
  expect "garbage stdin: exit" "$RC" "0"
  expect "garbage stdin: no payload" "$(out g3)" ""
  # post-edit-lint in Phase 1: phpcbf runs without the unused-use sniffs, so a
  # `use` added one edit before the code that needs it survives.
  local hr="$FX/hook-root"
  mk_stub_root "$hr" "11.4.8"
  cp -R "$CUSTOM/acme_core" "$hr/web/modules/custom/"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$hr/phpcbf-args.log" > "$hr/vendor/bin/phpcbf"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$hr/vendor/bin/phpcs"
  chmod +x "$hr/vendor/bin/phpcbf" "$hr/vendor/bin/phpcs"
  printf '<?php\n\nnamespace Drupal\\acme_core;\n\nuse Drupal\\Core\\Url;\n\nclass Later {}\n' > "$hr/web/modules/custom/acme_core/src/Later.php"
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hr/web/modules/custom/acme_core/src/Later.php" > "$TMP/edit.json"
  if "$SH" "$h/post-edit-lint.sh" < "$TMP/edit.json" > "$TMP/out/pe1.out" 2>/dev/null; then RC=0; else RC=$?; fi
  expect "post-edit-lint: exit" "$RC" "0"
  expect "post-edit-lint Phase 1: phpcbf skips the unused-use sniff" \
    "$(grep -c -- '--exclude=Drupal.Classes.UnusedUseStatement' "$hr/phpcbf-args.log" 2>/dev/null || true)" "1"
  printf '{"cwd":"%s"}' "$LW" > "$TMP/session.json"
  if (cd "$LW" && env DRUPILOT_SESSION_CONTEXT=off "$SH" "$h/session-detect-env.sh" < "$TMP/session.json" > "$TMP/out/s1.out" 2>/dev/null); then RC=0; else RC=$?; fi
  expect "session off: exit" "$RC" "0"
  expect "session off: no payload" "$(out s1)" ""
  finish
}

test_port_safety() {
  local cps="$REPO/scripts/analysis/check-port-safety.sh" worker
  local q='[.findings[] | .check + "@" + .file + ":" + (.line|tostring) + ":" + .severity] | sort'
  run ps "$SH" "$cps" --subject "$LW" --no-diff --json
  expect "baseline: exit (1 error)" "$RC" "3"
  expect "baseline: findings" "$(jqo ps "$q")" \
    '["class-case@legacy_widgets.services.yml:9:error","serialization@src/Form/WidgetImportForm.php:20:warn","serialization@src/Form/WidgetImportForm.php:21:warn"]'
  # Red: drop the interface a QueueWorker with create() needs (QueueWorkerBase
  # does not implement it) — what a port once did by mistake (H1).
  worker="$LW/src/Plugin/QueueWorker/WidgetReindexWorker.php"
  sed_inplace "$worker" 's/ implements ContainerFactoryPluginInterface {/ {/'
  grep -q 'implements ContainerFactoryPluginInterface' "$worker" \
    && printf 'mutation: the interface is still there\n' >> "$T_FAILS"
  run ps2 "$SH" "$cps" --subject "$LW" --no-diff --json --checks plugin-di
  expect "mutated: plugin-di finding" "$(jqo ps2 '[.findings[] | .check + "@" + .file + ":" + .severity]')" \
    '["plugin-di@src/Plugin/QueueWorker/WidgetReindexWorker.php:error"]'
  if [[ "$HAVE_GIT" == "1" ]]; then
    run ps3 "$SH" "$cps" --subject "$LW" --json --checks plugin-di
    expect "diff mode: attributed to the port" "$(jqo ps3 '[.findings[] | .check + ":" + (.introduced|tostring)]')" \
      '["plugin-di:true"]'
    git -C "$LW" checkout -q -- . 2>/dev/null || true
  else
    log_warn "port-safety: git not available, diff-mode assertion skipped."
    sed_inplace "$worker" 's/^class WidgetReindexWorker extends QueueWorkerBase {/class WidgetReindexWorker extends QueueWorkerBase implements ContainerFactoryPluginInterface {/'
  fi
  run ps4 "$SH" "$cps" --subject "$LW" --no-diff --json --checks plugin-di
  expect "restored: no plugin-di finding" "$(jqo ps4 '[.findings[]] | length')" "0"
  finish
}

test_signature() {
  local s="$REPO/scripts/analysis/scan-signature-changes.sh"
  local q='[.findings[] | .id + "@" + .file + ":" + (.line|tostring) + ":" + .severity] | sort'
  run sg "$SH" "$s" --subject "$LW" --json
  expect "^10 floor: exit (errors)" "$RC" "3"
  expect "^10 floor: counts" "$(jqo sg '[.errors, .warnings, .infos]')" '[2,2,1]'
  expect "^10 floor: findings" "$(jqo sg "$q")" \
    '["config-form-base-ctor@src/Form/SettingsForm.php:32:error","entity-get-original@src/Entity/LegacyWidget.php:57:error","entity-original-accessors-call@modules/legacy_widgets_extra/legacy_widgets_extra.module:15:warn","hook-entity-operation@legacy_widgets.module:24:info","revision-cache-id@src/LegacyWidgetStorage.php:24:warn"]'
  run sg2 "$SH" "$s" --subject "$LW" --json --core-req '^11.3'
  expect "^11.3 floor: counts" "$(jqo sg2 '[.errors, .warnings, .infos]')" '[2,0,2]'
  finish
}

test_lint_metadata() {
  local l="$REPO/scripts/analysis/lint-extension-metadata.sh" m n want
  run lm "$SH" "$l" --subject "$LW" --no-write --json
  expect "legacy_widgets: totals" "$(jqo lm '.totals | "\(.error)/\(.warn)/\(.info)"')" '"2/8/0"'
  expect "legacy_widgets: findings" "$(jqo lm '[.findings[] | .check + "@" + .file + ":" + (.line|tostring)] | sort')" \
    '["config-schema@config/install/legacy_widgets.settings.yml:1","configure-route@legacy_widgets.info.yml:6","plugin-schema@src/Plugin/Condition/WidgetsEnabledCondition.php:1","plugin-schema@src/Plugin/Filter/WidgetSummaryFilter.php:1","services-arity@legacy_widgets.services.yml:3","services-class@legacy_widgets.services.yml:13","services-class@legacy_widgets.services.yml:8","submodule-core-req@modules/legacy_widgets_extra/legacy_widgets_extra.info.yml:5","undeclared-deps@modules/legacy_widgets_extra/legacy_widgets_extra.module:8","undeclared-deps@modules/legacy_widgets_extra/legacy_widgets_extra.module:9"]'
  expect_match "legacy_widgets: undeclared-deps message" \
    "$(jqo lm '[.findings[] | select(.check == "undeclared-deps") | .message][0]')" \
    "uses project module 'legacy_widgets' "
  # Same-named copies elsewhere in the --set-dir only resolve references: the
  # plugin-schema check reports the subject's own plugins once.
  mkdir -p "$FX/lintset/a" "$FX/lintset/b"
  cp -R "$LW" "$FX/lintset/a/"; cp -R "$LW" "$FX/lintset/b/"
  run lms "$SH" "$l" --subject "$FX/lintset/a/legacy_widgets" --set-dir "$FX/lintset" --no-write --json
  expect "legacy_widgets in a set with a copy: totals" "$(jqo lms '.totals | "\(.error)/\(.warn)/\(.info)"')" '"2/8/0"'
  expect "legacy_widgets in a set with a copy: plugin-schema files" \
    "$(jqo lms '[.findings[] | select(.check == "plugin-schema") | .file] | sort')" \
    '["src/Plugin/Condition/WidgetsEnabledCondition.php","src/Plugin/Filter/WidgetSummaryFilter.php"]'
  for m in acme_api:0/2/0 acme_billing:0/0/0 acme_core:0/0/0 acme_invoice:0/1/0 \
           acme_reports:0/6/2 acme_search:0/3/0 acme_standalone:0/0/0 acme_utils:1/0/0; do
    n="${m%%:*}"; want="${m#*:}"
    run lmm "$SH" "$l" --subject "$CUSTOM/$n" --no-write --json
    expect "$n: totals" "$(jqo lmm '.totals | "\(.error)/\(.warn)/\(.info)"')" "\"$want\""
  done
  finish
}

test_layers() {
  local l="$REPO/scripts/analysis/layers.sh"
  run ly "$SH" "$l" --dir "$MONO" --no-write --json
  expect "exit" "$RC" "0"
  expect "layers" "$(jqo ly '[.layers[] | .modules | sort]')" \
    '[["acme_core","acme_standalone"],["acme_billing","acme_invoice","acme_utils"],["acme_api"],["acme_reports","acme_search"],["acme_search_ui"]]'
  expect "cycles" "$(jqo ly '[.cycles[] | sort]')" '[["acme_billing","acme_invoice"]]'
  expect "early" "$(jqo ly '.early')" '[{"module":"acme_reports","layer":3,"declared_layer":0}]'
  expect "totals" "$(jqo ly '.totals')" '{"modules":9,"layers":5,"cycles":1,"undeclared":8,"undeclared_modules":4}'
  expect "proposed" "$(jqo ly '[.modules[] | select((.proposed|length) > 0) | {(.machine): (.proposed | sort)}] | add')" \
    '{"acme_api":["acme_core:acme_core"],"acme_reports":["acme_api:acme_api","acme_core:acme_core","acme_utils:acme_utils","drupal:node","pathauto:pathauto"],"acme_search":["search_api:search_api"],"acme_search_ui":["acme_core:acme_core"]}'
  expect "external" "$(jqo ly '[.external[] | .module + ":" + .scope] | sort')" \
    '["node:core","pathauto:external","search_api:external","token:external"]'
  # layer-report.sh shows the metadata lint record of a module that is linted
  # but has no state.json yet (acme_utils: 1 error).
  run lyl "$SH" "$REPO/scripts/analysis/lint-extension-metadata.sh" --subject "$CUSTOM/acme_utils" --json
  run lyr "$SH" "$REPO/scripts/analysis/layer-report.sh" --dir "$CUSTOM" --no-write --json
  expect "layer-report: hygiene of an unregistered module" \
    "$(jqo lyr '[(.modules[] | select(.machine == "acme_utils") | .hygiene.error), .totals.hygiene_errors]')" '[1,1]'
  run lyd "$SH" "$l" --dir "$MONO" --no-write --json --edges declared
  expect "declared edges: layers" "$(jqo lyd '[.layers[] | .modules | sort]')" \
    '[["acme_core","acme_reports","acme_standalone"],["acme_billing","acme_invoice","acme_utils"],["acme_api"],["acme_search"],["acme_search_ui"]]'
  # A saved --edges declared run is a variant: the canonical layers.json (all
  # edges) stays, and layer-report.sh says which layering it reports.
  local e="$FX/edges/custom" lj
  mkdir -p "$FX/edges"; cp -R "$CUSTOM" "$e"
  run lw1 "$SH" "$l" --dir "$e" --json
  run lw2 "$SH" "$l" --dir "$e" --json --edges declared
  lj="$(project_state_path "$e")"
  expect "saved files: canonical and variant" \
    "$(jq -r .edges "$lj/layers.json" 2>/dev/null)/$(jq -r .edges "$lj/layers-declared.json" 2>/dev/null)" "all/declared"
  run lr1 "$SH" "$REPO/scripts/analysis/layer-report.sh" --dir "$e" --no-write --json
  expect "layer-report: canonical edges" "$(jqo lr1 '[.edges, (.modules[] | select(.machine == "acme_reports") | .layer)]')" '["all",3]'
  run lr2 "$SH" "$REPO/scripts/analysis/layer-report.sh" --dir "$e" --edges declared --no-write --json
  expect "layer-report: declared edges on request" "$(jqo lr2 '[.edges, (.modules[] | select(.machine == "acme_reports") | .layer)]')" '["declared",0]'
  finish
}

test_status_probe() {
  # /drupilot-status is read-only: its load-time probes (the bang lines of
  # commands/drupilot-status.md) leave the subject tree and the data dir as
  # they were. The probe is a `bash -c '<script>' _ "$1"` line.
  local c="$FX/status/legacy_widgets" probe before after
  mkdir -p "$FX/status"; cp -R "$LW" "$c"
  probe="$(sed -n "s/^.\`bash -c '\(.*\)' _ \"\$1\"\`\$/\1/p" "$REPO/commands/drupilot-status.md" | head -n 1)"
  expect "probe found" "$([[ -n "$probe" ]] && echo yes || echo no)" "yes"
  before="$(find "$c" "$CLAUDE_PLUGIN_DATA" | sort)"
  run stp "$SH" -c "$probe" _ "$c"
  expect "probe: exit" "$RC" "0"
  expect_match "probe: machine name" "$(out stp)" 'machine_name=legacy_widgets'
  run stn "$SH" "$REPO/scripts/env/next-step.sh" --subject "$c" --from-preflight --human
  after="$(find "$c" "$CLAUDE_PLUGIN_DATA" | sort)"
  expect "tree and data dir unchanged" "$after" "$before"
  finish
}

test_patterns() {
  local p="$REPO/scripts/analysis/patterns.sh" pat n=0 bad="" c="$FX/patterns/legacy_widgets"
  # Every curated ERE in config/deprecations.json is learnable as-is (an
  # escaped backslash before "D", as in \\Drupal::, is not the PCRE \D).
  while IFS= read -r pat; do
    n=$((n + 1))
    "$SH" "$p" add --subject "$LW" --id "smoke-$n" --pattern "$pat" --fix f --why w --dry-run \
      >/dev/null 2>&1 < /dev/null || bad="$bad [$pat]"
  done < <(jq -r '.. | objects | .pattern? // empty | strings' "$REPO/config/deprecations.json")
  expect "deprecations.json patterns accepted" "${bad:-none}" "none"
  run pd "$SH" "$p" add --subject "$LW" --id smoke-d --pattern 'foo\d+' --fix f --why w --dry-run
  expect "PCRE \\d refused: exit" "$RC" "1"
  # list shows the stored ERE verbatim (no @tsv backslash doubling).
  mkdir -p "$FX/patterns"; cp -R "$LW" "$c"
  run pa "$SH" "$p" add --subject "$c" --id smoke.fromroute --pattern 'Url::fromRoute\(' --fix f --why w
  run pl "$SH" "$p" list --subject "$c"
  expect "list detector" "$(out pl | cut -f4)" 'ere:Url::fromRoute\('
  finish
}

test_dry_run() {
  local before after
  before="$(cat "$CUSTOM/acme_search/acme_search.info.yml" "$CUSTOM/acme_search/modules/acme_search_ui/acme_search_ui.info.yml")"
  run sc "$SH" "$REPO/scripts/analysis/set-core-requirement.sh" --subject "$CUSTOM/acme_search" \
    --requirement '^10 || ^11' --dry-run --json
  expect "set-core-requirement: exit" "$RC" "0"
  expect "set-core-requirement: dry_run" "$(jqo sc '.dry_run')" 'true'
  expect "set-core-requirement: would update" \
    "$(jqo sc '[.files[] | select(.action == "updated") | .role] | sort')" '["main","submodule"]'
  after="$(cat "$CUSTOM/acme_search/acme_search.info.yml" "$CUSTOM/acme_search/modules/acme_search_ui/acme_search_ui.info.yml")"
  expect "set-core-requirement: files untouched" "$([[ "$before" == "$after" ]] && echo same || echo changed)" "same"
  before="$(cat "$MONO/.gitignore")"
  run eg "$SH" "$REPO/scripts/env/ensure-gitignore.sh" --root "$MONO" --dry-run
  expect "ensure-gitignore: exit" "$RC" "0"
  expect "ensure-gitignore: .gitignore untouched" "$(cat "$MONO/.gitignore")" "$before"
  expect "ensure-gitignore: no .drupilot.json" "$([[ -e "$MONO/.drupilot.json" ]] && echo yes || echo no)" "no"
  finish
}

# mk_stub_root DIR VERSION -> a minimal Drupal root (web/core/lib/Drupal.php
# with VERSION) and a stub vendor/bin/rector: it logs its arguments to
# DIR/rector-args.log and prints what DIR/rector-mode asks for (`change FILE`:
# one changed file; anything else: nothing changed), with Rector's [OK] line.
mk_stub_root() {
  local r="$1" v="$2"
  mkdir -p "$r/web/core/lib" "$r/web/modules/custom" "$r/vendor/bin"
  printf '{"name": "drupilot-smoke/stub-root"}\n' > "$r/composer.json"
  printf "<?php\nclass Drupal {\n  const VERSION = '%s';\n}\n" "$v" > "$r/web/core/lib/Drupal.php"
  cat > "$r/vendor/bin/rector" <<'STUB'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/../.." && pwd)"
printf '%s\n' "$*" >> "$root/rector-args.log"
mode="$(cat "$root/rector-mode" 2>/dev/null || true)"
case "$mode" in
  dup\ *) case " $* " in *" --dry-run "*) ;; *) printf '#[\\Drupal\\migrate\\Attribute\\MigrateSource(id: "a")]\n#[\\Drupal\\migrate\\Attribute\\MigrateSource(id: "b")]\nclass X {}\n' >> "$root/${mode#dup }";; esac
    printf '1 file with changes\n===================\n\n1) %s\n\n [OK] 1 file has been changed by Rector\n' "${mode#dup }";;
  change\ *) printf '1 file with changes\n===================\n\n1) %s\n\n [OK] 1 file would have been changed by Rector\n' "${mode#change }";;
  *) printf ' [OK] Rector is done!\n';;
esac
exit 0
STUB
  chmod +x "$r/vendor/bin/rector"
}

# analyze_ready -> 0 when the analyze profile (git + jq + composer/php) is met.
analyze_ready() { "$SH" "$REPO/scripts/env/preflight.sh" --profile analyze --quiet >/dev/null 2>&1 < /dev/null; }

test_core_target() {
  local cs="$REPO/scripts/analysis/core-strategy.sh" m="$FX/ct" r="$FX/ct-root"
  local q='[.strategy, .recommended_core_version_requirement, (.verify_cores | join(","))] | join(" ")'
  run ct1 "$SH" "$cs" --subject "$CUSTOM/acme_core" --json
  expect "^10.3 + Block attribute: floor kept" "$(jqo ct1 "$q")" '"keep-d10 ^10.3 || ^11 10.3,11"'
  run ct2 "$SH" "$cs" --subject "$LW" --json
  expect "^10, no attribute: floor and newest 10.x legs" "$(jqo ct2 "$q")" '"keep-d10 ^10 || ^11 10.0,10,11"'
  mkdir -p "$m"; cp -R "$CUSTOM/acme_core" "$m/"
  sed_inplace "$m/acme_core/acme_core.info.yml" 's/^core_version_requirement: .*/core_version_requirement: ^10/'
  run ct3 "$SH" "$cs" --subject "$m/acme_core" --json
  expect "^10 + Block attribute: raised to its minor" "$(jqo ct3 "$q")" '"keep-d10 ^10.2 || ^11 10.2,11"'
  printf '<?php\n\nnamespace Drupal\\acme_core\\Entity;\n\nuse Drupal\\Core\\Entity\\Attribute\\ContentEntityType;\n\n#[ContentEntityType(id: "acme_thing")]\nclass Thing {}\n' > "$m/acme_core/src/Thing.php"
  run ct4 "$SH" "$cs" --subject "$m/acme_core" --json
  expect "^10 + ContentEntityType attribute: Drupal 11 only" "$(jqo ct4 "$q")" '"d11-only ^11.1 11.1"'
  expect "^10 + ContentEntityType attribute: major bump" "$(jqo ct4 '.version_bump')" '"major"'
  # Already Drupal 11-compatible ('^10 || ^11'): the raised floor drops Drupal
  # 10, so no Drupal 10 support or require.php is claimed any more.
  sed_inplace "$m/acme_core/acme_core.info.yml" 's/^core_version_requirement: .*/core_version_requirement: ^10 || ^11/'
  run ct5 "$SH" "$cs" --subject "$m/acme_core" --json
  expect "^10 || ^11 + ContentEntityType attribute: Drupal 10 dropped" \
    "$(jqo ct5 '[.strategy, .recommended_core_version_requirement, .d10_support, .require_php, .version_bump]')" '["d11-only","^11.1","n/a",null,"major"]'
  expect "^10 || ^11 + ContentEntityType attribute: no 'still allows Drupal 10' warning" \
    "$(jqo ct5 '[.warnings[] | select(test("still allows Drupal 10"))] | length')" '0'
  # The default matrix legs, on a stub Drupal 11 root.
  mk_stub_root "$r" "11.4.8"
  cp -R "$LW" "$r/web/modules/custom/"
  run vm "$SH" "$REPO/scripts/analysis/verify-core-matrix.sh" --subject "$r/web/modules/custom/legacy_widgets" --dry-run --json
  expect "matrix dry-run: exit" "$RC" "0"
  expect "matrix dry-run: legs" "$(jqo vm '[.legs[] | .core + ":" + .role] | join(",")')" '"10.0:reference,10:reference,11:baseline"'
  finish
}

test_attributes() {
  local r="$FX/attr-root" mod pk
  # php-scan.sh: constructor parameters (own, inherited, variadic) and the
  # top-level keys of an annotation (nested objects and @Translation skipped).
  mkdir -p "$FX/attr-docroot/core/lib/Drupal/Component/Plugin/Attribute" "$FX/attr-docroot/core/modules/migrate/src/Attribute"
  printf 'name: Migrate\ntype: module\n' > "$FX/attr-docroot/core/modules/migrate/migrate.info.yml"
  cat > "$FX/attr-docroot/core/lib/Drupal/Component/Plugin/Attribute/Plugin.php" <<'PHP'
<?php

namespace Drupal\Component\Plugin\Attribute;

#[\Attribute(\Attribute::TARGET_CLASS)]
class Plugin {

  public function __construct(
    public readonly string $id,
    public readonly ?string $deriver = NULL,
  ) {}

}
PHP
  cat > "$FX/attr-docroot/core/modules/migrate/src/Attribute/MigrateSource.php" <<'PHP'
<?php

namespace Drupal\migrate\Attribute;

use Drupal\Component\Plugin\Attribute\Plugin;

class MigrateSource extends Plugin {

  /**
   * Not a parameter: $source_module.
   */
  public function __construct(
    public readonly string $id,
    public bool $requirements_met = TRUE,
    public readonly mixed $minimum_version = NULL, // '$x'
    public readonly ?string $deriver = NULL,
  ) {}

}
PHP
  printf '<?php\n\nnamespace Drupal\\migrate\\Attribute;\n\nclass MigrateInherited extends MigrateSource {}\n' > "$FX/attr-docroot/core/modules/migrate/src/Attribute/MigrateInherited.php"
  printf '<?php\n\nnamespace Drupal\\migrate\\Attribute;\n\nclass MigrateAny {\n\n  public function __construct(string $id, ...$additional) {}\n\n}\n' > "$FX/attr-docroot/core/modules/migrate/src/Attribute/MigrateAny.php"
  cat > "$FX/attr-ann.php" <<'PHP'
<?php

/**
 * A source.
 *
 * @MigrateSource(
 *   id = "acme_roles",
 *   source_module = "acme",
 *   label = @Translation("A, b = c", context = "x"),
 *   context_definitions = {
 *     "node" = @ContextDefinition("entity:node", label = @Translation("Node"))
 *   }
 * )
 */
class AcmeRoles {}
PHP
  pk="$(env PHPSCAN_DOCROOT="$FX/attr-docroot" "$SH" -c '
    . "$1/scripts/lib/common.sh"; . "$1/scripts/lib/php-scan.sh"
    PHPSCAN_DIR="$(mktemp -d)"; : > "$PHPSCAN_DIR/index.tsv"; mkdir -p "$PHPSCAN_DIR/ext" "$PHPSCAN_DIR/memo"
    php_scan_extmap "$2"
    for c in MigrateSource MigrateInherited MigrateAny MigrateMissing; do
      printf "%s=%s;" "$c" "$(php_ctor_params "Drupal\\migrate\\Attribute\\$c" | paste -sd, -)"
    done
    printf "keys=%s" "$(php_annotation_keys "$3" MigrateSource | paste -sd, -)"
    rm -rf "$PHPSCAN_DIR"' _ "$REPO" "$FX/attr-docroot" "$FX/attr-ann.php" 2>&1 < /dev/null || true)"
  expect "php-scan: constructor parameters and annotation keys" "$pk" \
    'MigrateSource=id,requirements_met,minimum_version,deriver;MigrateInherited=id,requirements_met,minimum_version,deriver;MigrateAny=id,...additional;MigrateMissing=?;keys=id,source_module,label,context_definitions'
  if ! analyze_ready; then
    log_warn "attributes: the analyze profile is not ready, the convert-attributes.sh assertion is skipped."
    finish; return 0
  fi
  # convert-attributes.sh on a stub Drupal 11.4 root: the file whose
  # annotation has source_module is skipped, the plain one is converted.
  mk_stub_root "$r" "11.4.8"
  cp -R "$FX/attr-docroot/core" "$r/web/"
  printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$r/web/core/lib/Drupal.php"
  mkdir -p "$r/vendor/palantirnet/drupal-rector/src/Drupal10/Rector/Deprecation"
  printf '<?php\n' > "$r/vendor/palantirnet/drupal-rector/src/Drupal10/Rector/Deprecation/AnnotationToAttributeRector.php"
  mod="$r/web/modules/custom/acme_mig"
  mkdir -p "$mod/src/Plugin/migrate/source"
  printf "name: Acme mig\ntype: module\ncore_version_requirement: ^11\n" > "$mod/acme_mig.info.yml"
  cp "$FX/attr-ann.php" "$mod/src/Plugin/migrate/source/AcmeRoles.php"
  printf '<?php\n\n/**\n * Plain.\n *\n * @MigrateSource(\n *   id = "acme_plain"\n * )\n */\nclass AcmePlain {}\n' > "$mod/src/Plugin/migrate/source/AcmePlain.php"
  printf 'change web/modules/custom/acme_mig/src/Plugin/migrate/source/AcmePlain.php' > "$r/rector-mode"
  run at "$SH" "$REPO/scripts/analysis/convert-attributes.sh" --subject "$mod" --json
  expect "convert-attributes: exit" "$RC" "0"
  expect "convert-attributes: source_module file skipped" \
    "$(jqo at '[.skipped_files[] | (.file | sub(".*/"; "")) + ":" + (.reason | test("source_module") | tostring)]')" '["AcmeRoles.php:true"]'
  expect "convert-attributes: plain file converted" "$(jqo at '[.types[] | .annotation + ":" + .action + ":" + (.converted_files | tostring)]')" '["MigrateSource:keep:1"]'
  expect "convert-attributes: skipped file in the Rector skip list" \
    "$(grep -c "acme_mig/src/Plugin/migrate/source/AcmeRoles.php" "$r/.drupilot/rector-attributes.php" 2>/dev/null || true)" "1"
  # --apply --raise-floor: a file restored after the pass (here a duplicate
  # attribute) no longer counts toward the core floor, so nothing is raised.
  local r2="$FX/attr-root2" mod2
  mk_stub_root "$r2" "11.4.8"
  cp -R "$r/web/core" "$r2/web/"
  cp -R "$r/vendor/palantirnet" "$r2/vendor/"
  mod2="$r2/web/modules/custom/acme_mig"
  mkdir -p "$mod2/src/Plugin/migrate/source"
  cp "$mod/acme_mig.info.yml" "$mod2/"
  cp "$mod/src/Plugin/migrate/source/AcmePlain.php" "$mod2/src/Plugin/migrate/source/"
  printf 'dup web/modules/custom/acme_mig/src/Plugin/migrate/source/AcmePlain.php' > "$r2/rector-mode"
  run at3 "$SH" "$REPO/scripts/analysis/convert-attributes.sh" --subject "$mod2" --apply --raise-floor --json
  expect "convert-attributes restore: exit" "$RC" "0"
  expect "convert-attributes restore: file restored, floor dropped, not raised" \
    "$(jqo at3 '[(.restored_files | length), .attribute_floor, .floor_raised, ([.types[] | .converted_files] | add)]')" '[1,null,false,0]'
  expect "convert-attributes restore: requirement untouched" \
    "$(sed -n 's/^core_version_requirement: //p' "$mod2/acme_mig.info.yml")" '^11'
  expect "convert-attributes restore: file content restored" \
    "$(grep -c 'MigrateSource(id' "$mod2/src/Plugin/migrate/source/AcmePlain.php" || true)" '0'
  # A contrib attribute type (no @since) still converts once a reference core
  # (core only, no contrib) is cached under .drupilot/cores.
  mkdir -p "$r/web/modules/contrib/foo/src/Attribute" "$r/.drupilot/cores/drupal-10/web/core/lib/Drupal" "$mod/src/Plugin/Foo"
  printf 'name: Foo\ntype: module\n' > "$r/web/modules/contrib/foo/foo.info.yml"
  printf '<?php\n\nnamespace Drupal\\foo\\Attribute;\n\nclass Foo {\n\n  public function __construct(public readonly string $id, public readonly ?string $label = NULL) {}\n\n}\n' \
    > "$r/web/modules/contrib/foo/src/Attribute/Foo.php"
  printf "<?php\nclass Drupal {\n  const VERSION = '10.3.0';\n}\n" > "$r/.drupilot/cores/drupal-10/web/core/lib/Drupal.php"
  printf '<?php\n\n/**\n * A foo.\n *\n * @Foo(\n *   id = "acme_foo",\n *   label = "Acme"\n * )\n */\nclass AcmeFoo {}\n' > "$mod/src/Plugin/Foo/AcmeFoo.php"
  run at2 env 'DRUPILOT_ATTRIBUTE_PLUGIN_TYPES=Foo=Drupal\foo\Attribute\Foo' "$SH" "$REPO/scripts/analysis/convert-attributes.sh" --subject "$mod" --json
  expect "convert-attributes + reference core: contrib type converted" \
    "$(jqo at2 '[.types[] | select(.annotation == "Foo") | .converted_files] | add')" '1'
  expect "convert-attributes + reference core: contrib file not skipped" \
    "$(jqo at2 '[.skipped_files[] | select(.file | test("AcmeFoo"))] | length')" '0'
  finish
}

test_rector_cache() {
  local r="$FX/rc-root" rr="$REPO/scripts/analysis/run-rector.sh" sub
  if ! analyze_ready; then
    log_warn "rector-cache: the analyze profile is not ready, the test is skipped."
    finish; return 0
  fi
  mk_stub_root "$r" "11.4.8"
  cp -R "$LW" "$r/web/modules/custom/"
  sub="$r/web/modules/custom/legacy_widgets"
  printf 'change web/modules/custom/legacy_widgets/legacy_widgets.module' > "$r/rector-mode"
  run rc1 "$SH" "$rr" --subject "$sub" --json
  expect "dry-run: changed files" "$(jqo rc1 '.changed_files')" "1"
  expect "every pass clears the Rector cache" "$(grep -vc -- '--clear-cache' "$r/rector-args.log" || true)" "0"
  # A stale cache: the apply changes nothing although the dry-run of the same
  # code announced a change.
  printf 'none' > "$r/rector-mode"
  run rc2 "$SH" "$rr" --subject "$sub" --apply --json
  expect "stale apply: exit" "$RC" "3"
  expect "stale apply: status" "$(jqo rc2 '.status')" '"error"'
  expect_match "stale apply: message" "$(jqo rc2 '.errors[0].message')" 'reported 1 file\(s\) to change, but the apply changed none'
  printf 'change web/modules/custom/legacy_widgets/legacy_widgets.module' > "$r/rector-mode"
  run rc3 "$SH" "$rr" --subject "$sub" --apply --json
  expect "consistent apply: exit" "$RC" "0"
  expect "consistent apply: status" "$(jqo rc3 '.status')" '"ok"'
  finish
}

test_state_stdin() {
  local r="$FX/stdin-root" bin="$FX/stdin-bin" m
  mk_stub_root "$r" "11.4.8"
  mkdir -p "$r/.ddev" "$bin"
  printf 'name: dlab-smoke-stdin\ntype: drupal11\n' > "$r/.ddev/config.yaml"
  # A fake ddev that reads all of its stdin, as a real `ddev describe` may.
  cat > "$bin/ddev" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
case "$1" in
  describe) printf '{"raw":{"status":"running","name":"dlab-smoke-stdin"}}\n';;
  --version) printf 'ddev version v1.24.10\n';;
esac
exit 0
STUB
  chmod +x "$bin/ddev"
  for m in acme_core acme_utils; do
    cp -R "$CUSTOM/$m" "$r/web/modules/custom/"
    run ssr env PATH="$bin:$PATH" "$SH" "$REPO/scripts/env/state.sh" record --subject "$r/web/modules/custom/$m" --stage setup --json
  done
  run ssl env PATH="$bin:$PATH" "$SH" "$REPO/scripts/env/state.sh" list \
    --subject "$r/web/modules/custom/acme_core" --subject "$r/web/modules/custom/acme_utils" --json
  expect "list: exit" "$RC" "0"
  expect "list: every subject, each with a next step" \
    "$(jqo ssl '[.count, ([.subjects[] | select(.next != null) | .machine_name] | sort)]')" '[2,["acme_core","acme_utils"]]'
  finish
}

test_shared_testbed() {
  local r="$FX/shared-root" o="$FX/shared-origin" m oh="$REPO/scripts/env/origin-hygiene.sh"
  mk_stub_root "$r" "11.4.8"
  mkdir -p "$o"
  for m in acme_core acme_utils; do
    cp -R "$CUSTOM/$m" "$o/"
    run shs "$SH" "$oh" --snapshot --subject "$o/$m" --root "$r" --placement copy
    cp -R "$o/$m" "$r/web/modules/custom/"
    run shr "$SH" "$REPO/scripts/env/state.sh" record --subject "$r/web/modules/custom/$m" --stage setup --json
  done
  for m in acme_core acme_utils; do
    run shc "$SH" "$oh" --check --subject "$o/$m" --root "$r"
    expect "$m: hygiene baseline of its own" "$(jqo shc '[.clean, .origin, (.baseline | test("origin-baseline-'"$m"'[.]json$"))]')" "[true,\"$o/$m\",true]"
    run shv "$SH" "$REPO/scripts/env/state.sh" show --subject "$r/web/modules/custom/$m" --no-next --json
    expect "$m: recorded origin" "$(jqo shv '.origin')" "\"$o/$m\""
  done
  run shl "$SH" "$REPO/scripts/analysis/layer-report.sh" --dir "$o" --no-write --json
  expect "layer-report: each row is its own module's record" \
    "$(jqo shl '[.modules[] | .machine + "=" + (.subject | sub(".*/"; ""))] | sort')" '["acme_core=acme_core","acme_utils=acme_utils"]'
  expect "layer-report: rows found in the test-bed" \
    "$(jqo shl '[.modules[] | .found and (.subject | startswith("'"$r"'/"))] | unique')" '[true]'
  finish
}

test_matrix_classify() {
  local prog
  prog="$(sed -n "/^CLASSIFY='\$/,/^'\$/p" "$REPO/scripts/analysis/verify-core-matrix.sh" | sed '1d;$d')"
  expect "classifier found" "$([[ -n "$prog" ]] && echo yes || echo no)" "yes"
  cat > "$TMP/matrix-leg.json" <<'JSON'
{"status":"ran","findings":[
 {"file":"src/BillingManager.php","line":12,"identifier":"class.notFound","message":"Parameter $generator of method Drupal\\acme_billing\\BillingManager::__construct() has invalid type Drupal\\acme_invoice\\InvoiceGenerator."},
 {"file":"src/BillingManager.php","line":9,"identifier":"class.notFound","message":"Property Drupal\\acme_billing\\BillingManager::$generator has unknown class Drupal\\acme_invoice\\InvoiceGenerator as its type."},
 {"file":"src/BillingManager.php","line":20,"identifier":"class.notFound","message":"Call to method generate() on an unknown class Drupal\\acme_invoice\\InvoiceGenerator."},
 {"file":"src/Foo.php","line":3,"identifier":"class.notFound","message":"Class Drupal\\acme_billing\\Foo extends unknown class Drupal\\acme_invoice\\Base."},
 {"file":"src/Bar.php","line":5,"identifier":"method.notFound","message":"Call to an undefined method Drupal\\acme_billing\\Bar::baz()."}]}
JSON
  run mc jq -c --argjson other '[]' --argjson own '["acme_billing"]' --argjson mods '[]' --argjson adv '[]' \
    --argjson ref true "$prog" "$TMP/matrix-leg.json"
  expect "classifier: exit" "$RC" "0"
  expect "classifier: kinds" "$(jqo mc '[.[] | .kind]')" \
    '["sandbox_missing_dependency","sandbox_missing_dependency","sandbox_missing_dependency","sandbox_missing_dependency","incompatible"]'
  finish
}

test_port_summary() {
  local c="$FX/summary/acme_core" sd dg
  mkdir -p "$FX/summary"; cp -R "$CUSTOM/acme_core" "$c"
  sd="$(project_state_dir "$c")"
  dg="$(subject_digest "$c")"
  printf '{"machine_name":"acme_core","phase":"port","d10_support":"verified-static-above-floor","digests":{"applied":false,"rejected":[],"skipped":false}}\n' > "$sd/port-manifest.json"
  printf '{"verdict":"fail","d10_support":"failed","subject_digest":"%s"}\n' "$dg" > "$sd/core-matrix.json"
  printf '{"status":"passed","preservation":"verified","subject_digest":"stale"}\n' > "$sd/last-test.json"
  run psr "$SH" "$REPO/scripts/env/state.sh" record --subject "$c" --stage ported --json
  run ps "$SH" "$REPO/scripts/analysis/port-summary.sh" --subject "$c" --json
  expect "port-summary: exit" "$RC" "0"
  expect "port-summary: recorded false kept" "$(jqo ps '[.digests.applied, .digests.skipped, .preservation.fresh, .matrix.fresh]')" '[false,false,false,true]'
  expect "port-summary: one d10 source" "$(jqo ps '[.d10_support, .d10_support_source, .status, ([.blockers[].source] | join(","))]')" \
    '["failed","core-matrix","blocked","core-matrix"]'
  finish
}

test_project_root() {
  local r="$FX/pr-root" p="$FX/pr-loose" got
  mk_stub_root "$r" "11.4.8"
  cp -R "$CUSTOM/acme_core" "$r/web/modules/custom/"
  mkdir -p "$p" "$p/acme_utils-d11/web/modules/custom"
  cp -R "$CUSTOM/acme_core" "$p/"
  cp -R "$CUSTOM/acme_utils" "$p/acme_utils-d11/web/modules/custom/"
  got="$("$SH" -c '. "$1/scripts/lib/common.sh"
    printf "%s|%s|%s" "$(subject_project_root "$2")" "$(subject_project_root "$3")" "$(subject_project_root "$4")"' \
    _ "$REPO" "$r/web/modules/custom/acme_core" "$p/acme_core" "$p/acme_utils" 2>/dev/null < /dev/null || true)"
  expect "placed | loose | moved away" "$got" "$r|$p/acme_core-d11|$p/acme_utils-d11"
  finish
}

test_monorepo_testbed() {
  local m="$FX/mrepo" f="$FX/mfolder" d10="$FX/d10site" rw="$REPO/scripts/env/resolve-workspace.sh" dest mp rp
  if [[ "$HAVE_GIT" != "1" ]]; then
    log_warn "monorepo-testbed: git is not available, the test is skipped."
    finish; return 0
  fi
  local -a G=(git -c user.name=drupilot-smoke -c user.email=smoke@example.invalid -c commit.gpgsign=false)
  cp -R "$FIX/monorepo" "$m"
  printf '/vendor/\n/web/core/\n' > "$m/.gitignore"
  git -C "$m" init -q && git -C "$m" add -A && "${G[@]}" -C "$m" commit -q -m "monorepo fixture"
  run mw1 "$SH" "$rw" --subject "$m/web/modules/custom/acme_core" --json
  expect "monorepo: layout, root, placement" \
    "$(jqo mw1 '[.layout, .loose, .drupal_root, .placement, .testbed_inside_origin, .origin_rel, .shared_root == .drupal_root]')" \
    "[\"project-no-core\",true,\"$m-d11\",\"copy\",false,\"web/modules/custom/acme_core\",true]"
  # A committed .ddev/config.yaml does not make the core-less checkout a root.
  mkdir -p "$m/.ddev"; printf 'name: acme\ntype: drupal10\n' > "$m/.ddev/config.yaml"
  run mw2 "$SH" "$rw" --subject "$m/web/modules/custom/acme_core" --json
  expect "monorepo with .ddev: still a sibling test-bed" "$(jqo mw2 '[.layout, .drupal_root]')" "[\"project-no-core\",\"$m-d11\"]"
  # ... and the --subject consumers that write never target the repository.
  run mg1 "$SH" "$REPO/scripts/env/ensure-gitignore.sh" --subject "$m/web/modules/custom/acme_core"
  expect "monorepo with .ddev: ensure-gitignore leaves the origin .gitignore alone" \
    "$(git -C "$m" status --porcelain -- .gitignore 2>/dev/null)" ""
  run mg2 "$SH" "$REPO/scripts/env/install-toolchain.sh" --subject "$m/web/modules/custom/acme_core" --dry-run
  expect "monorepo with .ddev: install-toolchain does not pick the repository" \
    "$(grep -c "Drupal root *: $m\$" "$TMP/out/mg2.err" || true)" "0"
  run mg3 "$SH" "$REPO/scripts/env/render-templates.sh" --subject "$m/web/modules/custom/acme_core" --dry-run --json
  expect "monorepo with .ddev: render-templates plans nothing in the repository" \
    "$(jq -r '.root // empty' "$TMP/out/mg3.out" 2>/dev/null || true)" ""
  rm -rf "$m/.ddev"
  # A folder of modules in a repository that is not a Drupal project.
  mkdir -p "$f/mods"; cp -R "$CUSTOM/acme_utils" "$f/mods/"
  git -C "$f/mods" init -q && git -C "$f/mods" add -A && "${G[@]}" -C "$f/mods" commit -q -m "modules"
  run mw3 "$SH" "$rw" --subject "$f/mods/acme_utils" --json
  expect "repo sub-directory: next to the repository" "$(jqo mw3 '[.layout, .drupal_root, .placement, .shared_root]')" \
    "[\"repo-subdir\",\"$f/acme_utils-d11\",\"copy\",\"$f/mods-d11\"]"
  # A Drupal 10 site: in place is not possible; an explicit workspace moves out.
  mk_stub_root "$d10" "10.3.6"
  cp -R "$CUSTOM/acme_core" "$d10/web/modules/custom/"
  run mw4 "$SH" "$rw" --subject "$d10/web/modules/custom/acme_core" --json
  expect "Drupal 10 site: in place, not ok" "$(jqo mw4 '[.layout, .core_version, .in_place_ok]')" '["in-place","10.3.6",false]'
  run mw5 env DRUPILOT_WORKSPACE_DIR="$FX/d10-ws" "$SH" "$rw" --subject "$d10/web/modules/custom/acme_core" --json
  expect "Drupal 10 site + workspace: a test-bed port" "$(jqo mw5 '[.loose, .drupal_root, .placement]')" "[true,\"$FX/d10-ws\",\"copy\"]"
  # Place into a stub test-bed, port, and patch.
  mk_stub_root "$m-d11" "11.4.8"
  # The origin's own hooks never run while its module is read for the baseline.
  printf '#!/bin/sh\necho fired >> "%s"\n' "$FX/origin-hook-fired" > "$m/.git/hooks/post-checkout"
  chmod +x "$m/.git/hooks/post-checkout"
  run mp1 "$SH" "$REPO/scripts/env/place-subject.sh" --subject "$m/web/modules/custom/acme_core" --yes
  expect "place: the origin's post-checkout hook does not fire" "$([[ -e "$FX/origin-hook-fired" ]] && echo fired)" ""
  dest="$m-d11/web/modules/custom/acme_core"
  expect "place: exit and destination" "$RC|$(out mp1)" "0|$dest"
  expect "place: the copy has a baseline" \
    "$(git -C "$dest" rev-parse --verify -q refs/drupilot/baseline >/dev/null 2>&1 && echo yes)|$(git -C "$dest" config drupilot.originPrefix 2>/dev/null)" \
    "yes|web/modules/custom/acme_core/"
  run mg4 "$SH" "$REPO/scripts/env/render-templates.sh" --subject "$m/web/modules/custom/acme_core" --dry-run --json
  expect "render-templates --subject <origin>: the placed copy in the test-bed" \
    "$(jqo mg4 '[.root, .subject_path]')" "[\"$m-d11\",\"web/modules/custom/acme_core\"]"
  # /drupilot-clean may discard the pristine seeded copy, not a ported one.
  if [[ -f "$m-d11/.drupilot.json" ]]; then
    jq '.drupilot_testbed.created_by = "smoke"' "$m-d11/.drupilot.json" > "$m-d11/.drupilot.json.new" \
      && mv "$m-d11/.drupilot.json.new" "$m-d11/.drupilot.json"
  fi
  mkdir -p "$m-d11/.drupilot"; printf 'report\n' > "$m-d11/.drupilot/port-report.md"
  run mc1 "$SH" "$REPO/scripts/env/clean.sh" --subject "$dest" --level workspace --dry-run --json
  expect "clean: a pristine seeded copy is redundant" "$(jqo mc1 '[.roots[0].subjects[]?.action]')" '["discard-copy"]'
  expect "clean: reports and patches are never rescued into the monorepo" \
    "$(jq -r --arg m "$m/" '[.roots[0].actions[] | select(.op | startswith("rescue")) | (.detail | startswith($m))] | map(tostring) | join(",")' "$TMP/out/mc1.out" 2>/dev/null)" "false,false"
  if [[ -f "$dest/acme_core.info.yml" && -d "$dest/src" ]]; then
    ( sed_inplace "$dest/acme_core.info.yml" -e 's/^core_version_requirement:.*/core_version_requirement: ^10.3 || ^11/' ) 2>/dev/null || true
    printf '<?php\n\nnamespace Drupal\\acme_core;\n\nfinal class Added {}\n' > "$dest/src/Added.php"
  fi
  run mp2 "$SH" "$REPO/scripts/contrib/make-patch.sh" --local --subject "$dest"
  mp="$(out mp2)"; rp="${mp%.patch}-repo.patch"
  expect "patch: exit and name" "$RC|$(basename "$mp")" "0|acme_core-port-to-drupal-11.patch"
  expect "patch: module-relative, only the port" "$(grep -E '^diff --git' "$mp" 2>/dev/null | tr '\n' ';')" \
    "diff --git a/acme_core.info.yml b/acme_core.info.yml;diff --git a/src/Added.php b/src/Added.php;"
  expect "repo patch: relative to the repository root" "$(grep -E '^diff --git' "$rp" 2>/dev/null | head -n1)" \
    "diff --git a/web/modules/custom/acme_core/acme_core.info.yml b/web/modules/custom/acme_core/acme_core.info.yml"
  expect "repo patch applies at the monorepo root" "$(git -C "$m" apply --check "$rp" >/dev/null 2>&1 && echo ok)" "ok"
  mkdir -p "$FX/pristine"; cp -R "$m/web/modules/custom/acme_core" "$FX/pristine/"
  expect "module patch applies on the pristine module" "$(cd "$FX/pristine/acme_core" && git apply --check "$mp" >/dev/null 2>&1 && echo ok)" "ok"
  run mc2 "$SH" "$REPO/scripts/env/clean.sh" --subject "$dest" --level workspace --dry-run --json
  expect "clean: a ported copy is kept" "$(jqo mc2 '[.roots[0].subjects[]?.action]')" '["refuse"]'
  # The layers plan of a monorepo folder goes to the hidden state dir.
  run ml1 "$SH" "$REPO/scripts/analysis/layers.sh" --dir "$m/web/modules/custom" --json
  expect "layers in a monorepo: plan saved outside the repository" \
    "$([[ -f "$(project_state_path "$m/web/modules/custom")/artifacts/layers.md" ]] && echo yes)" "yes"
  expect "monorepo stays clean" "$(git -C "$m" status --porcelain --ignored 2>/dev/null | tr '\n' ';')" ""
  finish
}

test_phpcs_scope() {
  local r="$FX/pc-root" rp="$REPO/scripts/analysis/run-phpcs.sh" sub b l
  if ! analyze_ready || [[ "$HAVE_GIT" != "1" ]]; then
    log_warn "phpcs-scope: the analyze profile or git is not ready, the test is skipped."
    finish; return 0
  fi
  mk_stub_root "$r" "11.4.8"
  for b in phpcs phpcbf; do
    cat > "$r/vendor/bin/$b" <<'STUB'
#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/../.." && pwd)"
case " $* " in *" -i "*) printf 'The installed coding standards are Drupal and DrupalPractice\n'; exit 0;; esac
printf '%s %s\n' "$(basename "$0")" "$*" >> "$root/phpcs-args.log"
exit 0
STUB
    chmod +x "$r/vendor/bin/$b"
  done
  cp -R "$LW" "$r/web/modules/custom/"
  sub="$r/web/modules/custom/legacy_widgets"
  printf '\n// Changed by the port.\n' >> "$sub/src/WidgetCounter.php"
  printf '<?php\n\nnamespace Drupal\\legacy_widgets;\n\nclass Added {}\n' > "$sub/src/Added.php"
  run pc1 "$SH" "$rp" --subject "$sub" --fix --fix-scope changed
  l="$(grep '^phpcbf ' "$r/phpcs-args.log" 2>/dev/null | tail -n1)"
  expect "changed: phpcbf gets only the changed files" \
    "$(printf '%s' "$l" | tr ' ' '\n' | grep -E '^web/' | tr '\n' ';')" \
    "web/modules/custom/legacy_widgets/src/Added.php;web/modules/custom/legacy_widgets/src/WidgetCounter.php;"
  expect "changed: phpcs still reports on the subject" \
    "$(grep '^phpcs ' "$r/phpcs-args.log" 2>/dev/null | grep -v -- ' -e' | tail -n1 | tr ' ' '\n' | grep -E '^web/' | tr '\n' ';')" \
    "web/modules/custom/legacy_widgets;"
  : > "$r/phpcs-args.log"
  run pc2 "$SH" "$rp" --subject "$sub" --fix
  expect "all: phpcbf gets the subject" \
    "$(grep '^phpcbf ' "$r/phpcs-args.log" 2>/dev/null | tail -n1 | tr ' ' '\n' | grep -E '^web/' | tr '\n' ';')" \
    "web/modules/custom/legacy_widgets;"
  rm -rf "${sub:?}/.git"; : > "$r/phpcs-args.log"
  run pc3 "$SH" "$rp" --subject "$sub" --fix --fix-scope changed
  expect "no git: report only" "$RC|$(grep -c '^phpcbf ' "$r/phpcs-args.log" 2>/dev/null || true)" "0|0"
  run pc4 "$SH" "$rp" --subject "$sub" --fix --fix-scope bogus
  expect "bad scope: usage error" "$RC" "1"
  finish
}

# --- Main -----------------------------------------------------------------------
log_step "drupilot smoke tests (bash ${BASH_VERSION:-?}, $(uname -s 2>/dev/null || echo ?))"
for t in $ALL_TESTS; do
  if [[ -n "$ONLY" ]] && ! in_list "$t" "$ONLY"; then continue; fi
  if [[ -n "$SKIP" ]] && in_list "$t" "$SKIP"; then continue; fi
  begin "$t"
  case "$t" in
    help) test_help;;
    preflight) test_preflight;;
    detect-php) test_detect_php;;
    next-step) test_next_step;;
    hooks) test_hooks;;
    port-safety) test_port_safety;;
    signature) test_signature;;
    lint-metadata) test_lint_metadata;;
    layers) test_layers;;
    dry-run) test_dry_run;;
    patterns) test_patterns;;
    status-probe) test_status_probe;;
    core-target) test_core_target;;
    attributes) test_attributes;;
    rector-cache) test_rector_cache;;
    state-stdin) test_state_stdin;;
    shared-testbed) test_shared_testbed;;
    matrix-classify) test_matrix_classify;;
    port-summary) test_port_summary;;
    project-root) test_project_root;;
    monorepo-testbed) test_monorepo_testbed;;
    phpcs-scope) test_phpcs_scope;;
  esac
done

if [[ "$FAILED" == "1" ]]; then log_err "smoke.sh: at least one test failed"
else log_ok "smoke.sh: all tests passed"; fi

if [[ "$AS_JSON" == "1" ]]; then
  jq -s -c --argjson ok "$([[ "$FAILED" == "1" ]] && echo false || echo true)" \
    --arg bash "${BASH_VERSION:-}" '{ok:$ok, bash:$bash, tests:.}' "$RESULTS"
fi

exit "$FAILED"
