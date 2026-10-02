#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/contrib/git-hooks.sh
# Detect the repository's git hooks (GrumPHP, husky, lefthook, pre-commit,
# CaptainHook, core.hooksPath, plain .git/hooks scripts) for a module/theme, map
# their tasks to drupilot equivalents, and optionally RUN those equivalents.
#
# Why: a slow or environment-bound pre-commit hook (e.g. GrumPHP running PHPStan
# with a 60 s timeout) tempts a `git commit --no-verify`, and then nothing
# records which checks were skipped. drupilot's policy is never to normalize
# --no-verify: commit normally and let the hooks run; only when a hook cannot
# complete in this context, run its tasks separately with this script
# (--run-equivalents) and record in the port report which validations replaced
# the hook (port-report.sh reads hooks-substitution.json). Tasks with no
# equivalent are listed as uncovered — named, never dropped.
#
# Usage:
#   git-hooks.sh [--subject DIR] [--detect | --run-equivalents]
#                [--with-tests] [--json] [--dry-run]
#
# Options:
#   --subject DIR       The module/theme checkout (default: current dir). Its git
#                       repository (the top level) is what is inspected.
#   --detect            (default) Report only. Needs git (+ jq); runs nothing.
#   --run-equivalents   Run the covered equivalents and record the result in the
#                       hidden per-subject state dir (hooks-substitution.json):
#                         phpcs   -> scripts/analysis/run-phpcs.sh (the hook's
#                                    phpcs ruleset when it names a file)
#                         phpstan -> scripts/analysis/run-phpstan.sh (the hook's
#                                    level when it sets one)
#                         phplint -> `php -l` on the changed PHP files, through
#                                    drupal_runner (DDEV when it is up)
#                         composer-> `composer validate --no-check-publish`
#                         phpunit -> scripts/tests/run-phpunit.sh, only with
#                                    --with-tests (it records last-test.json)
#   --with-tests        Also cover/run a hook's PHPUnit task.
#   --json              Accepted for symmetry: STDOUT always carries only the
#                       JSON payload; the human summary goes to STDERR.
#   --dry-run           With --run-equivalents: print the plan, run nothing,
#                       write nothing.
#   -h, --help          Show this help.
#
# Output (STDOUT, JSON):
#   {repo, hooks_dir, hooks_path_config, active_hooks:[...], has_hooks,
#    managers:[{name, config, installed, tasks:[{name, command}]}],
#    equivalents:[{kind, tasks:[...], by, covered, note}],
#    uncovered:[{manager, task}]}
#   --run-equivalents adds {ran:[{kind, by, rc, status}], all_green, complete,
#   state_file}. status: pass | fail | not-runnable. all_green: every covered
#   equivalent passed; complete: no uncovered task.
#   repo is null (and every list empty) when the subject is not in a git repo.
#   active_hooks are the commit-time hooks git would really run (executable,
#   not *.sample); a manager whose config exists but whose hook is not
#   installed has installed:false.
#
# Exit codes: 0 detect done, or every equivalent passed · 1 usage ·
# 2 git/jq missing · 3 an equivalent failed or could not run.
# GrumPHP/lefthook YAML is read with line-based patterns (no YAML parser is
# assumed): an unusual layout yields fewer tasks or an uncovered entry, never
# a crash.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
MODE="detect"
WITH_TESTS=0
DRY=0

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a directory." 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --detect) MODE="detect"; shift;;
    --run-equivalents) MODE="run"; shift;;
    --with-tests) WITH_TESTS=1; shift;;
    --json) shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)." 1;;
  esac
done

have_cmd git || die "git is required to inspect repository hooks." 2
have_cmd jq  || die "jq is required to build the hooks report." 2

[[ -n "$SUBJECT" ]] || SUBJECT="$PWD"
SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
[[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1

REPO="$(git -C "$SUBJECT_ABS" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO" ]]; then
  log_info "No git repository at $SUBJECT_ABS: no repository hooks to honor."
  jq -n '{repo:null, hooks_dir:null, hooks_path_config:null, active_hooks:[], has_hooks:false,
          managers:[], equivalents:[], uncovered:[]}'
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-hooks.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
MGR="$TMP/managers.jsonl"; : > "$MGR"

HOOKS_DIR="$(git_hooks_dir "$REPO" 2>/dev/null || true)"
HOOKS_PATH_CFG="$(git -C "$REPO" config --get core.hooksPath 2>/dev/null || true)"
ACTIVE="$(git_active_commit_hooks "$REPO")"
# Concatenated text of the active hooks: tells which manager installed them.
ACTIVE_TEXT=""
for _h in $ACTIVE; do
  ACTIVE_TEXT="$ACTIVE_TEXT
$(cat "$HOOKS_DIR/$_h" 2>/dev/null || true)"
done

# installed_by <needle> -> true/false: an active hook mentions <needle>.
installed_by() {
  if printf '%s' "$ACTIVE_TEXT" | grep -qi -- "$1"; then printf 'true'; else printf 'false'; fi
  return 0
}

# add_manager <name> <config> <installed> <tasks-tsv-file>
# The TSV holds "name<TAB>command" lines.
add_manager() {
  local name="$1" cfg="$2" inst="$3" tsv="$4"
  jq -Rn --arg n "$name" --arg c "$cfg" --argjson i "$inst" '
    {name:$n, config:$c, installed:$i,
     tasks:[inputs | select(length > 0) | split("\t") | {name:.[0], command:(.[1] // "")}]}
  ' < "$tsv" >> "$MGR"
  return 0
}

# --- GrumPHP -------------------------------------------------------------------
GRUMPHP_CFG=""
for _f in grumphp.yml grumphp.yaml grumphp.yml.dist grumphp.yaml.dist; do
  [[ -f "$REPO/$_f" ]] && { GRUMPHP_CFG="$REPO/$_f"; break; }
done
if [[ -z "$GRUMPHP_CFG" && -f "$REPO/composer.json" ]]; then
  _p="$(jq -r '.extra.grumphp["config-default-path"] // empty' "$REPO/composer.json" 2>/dev/null || true)"
  [[ -n "$_p" && -f "$REPO/$_p" ]] && GRUMPHP_CFG="$REPO/$_p"
fi
GRUMPHP_OPTS="$TMP/grumphp-opts.tsv"; : > "$GRUMPHP_OPTS"
if [[ -n "$GRUMPHP_CFG" ]]; then
  # Task names are the keys one level below `tasks:` (grumphp: tasks: in 1.x+,
  # parameters: tasks: in 0.x). The phpcs standard and the phpstan level are
  # kept as options so the equivalents mirror the hook.
  awk -v OPTS="$GRUMPHP_OPTS" '
    function ind(s) { match(s, /^ */); return RLENGTH }
    /^[[:space:]]*(#.*)?$/ { next }
    {
      i = ind($0)
      if (intasks && i <= tind) intasks = 0
      if (intasks) {
        if (tk < 0) tk = i
        if (i == tk && match($0, /^ *[A-Za-z0-9_.-]+:/)) {
          cur = $0; sub(/^ */, "", cur); sub(/:.*/, "", cur)
          print cur "\t" cur
          next
        }
        if (i > tk && cur != "" && match($0, /^ *(standard|level|configuration):/)) {
          k = $0; sub(/^ */, "", k); sub(/:.*/, "", k)
          v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/["\047]/, "", v); sub(/[[:space:]]+#.*$/, "", v)
          print cur "\t" k "\t" v > OPTS
        }
        next
      }
      if (match($0, /^ *tasks:[[:space:]]*$/)) { intasks = 1; tind = i; tk = -1; cur = "" }
    }
  ' "$GRUMPHP_CFG" > "$TMP/grumphp.tsv" 2>/dev/null || : > "$TMP/grumphp.tsv"
  add_manager grumphp "${GRUMPHP_CFG#"$REPO"/}" "$(installed_by grumphp)" "$TMP/grumphp.tsv"
fi

# --- husky -----------------------------------------------------------------------
if [[ -d "$REPO/.husky" ]]; then
  : > "$TMP/husky.tsv"
  for _h in pre-commit commit-msg; do
    [[ -f "$REPO/.husky/$_h" ]] || continue
    grep -vE '^[[:space:]]*(#|$)|husky\.sh' "$REPO/.husky/$_h" 2>/dev/null \
      | while IFS= read -r _l; do printf '%s\t%s\n' "$_h: $(trim "$_l" | cut -c1-60)" "$(trim "$_l")"; done \
      >> "$TMP/husky.tsv" || true
  done
  _inst=false
  case "$HOOKS_PATH_CFG" in *.husky*) [[ -n "$ACTIVE" ]] && _inst=true;; esac
  add_manager husky ".husky/" "$_inst" "$TMP/husky.tsv"
fi

# --- lefthook ----------------------------------------------------------------------
for _f in lefthook.yml lefthook.yaml .lefthook.yml .lefthook.yaml; do
  [[ -f "$REPO/$_f" ]] || continue
  # Commands of the pre-commit / commit-msg blocks: the key above each `run:`.
  awk '
    function ind(s) { match(s, /^ *[-]? */); return RLENGTH }
    /^[[:space:]]*(#.*)?$/ { next }
    /^[A-Za-z0-9_.-]+:/ { blk = $0; sub(/:.*/, "", blk); inb = (blk == "pre-commit" || blk == "commit-msg"); key = ""; next }
    !inb { next }
    match($0, /^ *-? *run:/) {
      c = $0; sub(/^ *-? *run:[[:space:]]*/, "", c); gsub(/^["\047]|["\047]$/, "", c)
      print blk ": " (key != "" ? key : "run") "\t" c
      next
    }
    match($0, /^ *-? *name:/) { key = $0; sub(/^ *-? *name:[[:space:]]*/, "", key); next }
    match($0, /^ *[A-Za-z0-9_.-]+:[[:space:]]*$/) {
      k = $0; sub(/^ */, "", k); sub(/:.*/, "", k)
      if (k != "commands" && k != "jobs" && k != "scripts") key = k
    }
  ' "$REPO/$_f" > "$TMP/lefthook.tsv" 2>/dev/null || : > "$TMP/lefthook.tsv"
  add_manager lefthook "$_f" "$(installed_by lefthook)" "$TMP/lefthook.tsv"
  break
done

# --- pre-commit (pre-commit.com) -------------------------------------------------
if [[ -f "$REPO/.pre-commit-config.yaml" ]]; then
  sed -n 's/^[[:space:]]*-[[:space:]]*id:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$REPO/.pre-commit-config.yaml" 2>/dev/null \
    | while IFS= read -r _id; do printf '%s\t%s\n' "$_id" "$_id"; done > "$TMP/precommit.tsv" || true
  add_manager pre-commit ".pre-commit-config.yaml" "$(installed_by pre-commit)" "$TMP/precommit.tsv"
fi

# --- CaptainHook -------------------------------------------------------------------
if [[ -f "$REPO/captainhook.json" ]]; then
  jq -r '(."pre-commit".actions // [])[]?.action // empty | tostring | "pre-commit: \(.[0:60])\t\(.)"' \
    "$REPO/captainhook.json" > "$TMP/captainhook.tsv" 2>/dev/null || : > "$TMP/captainhook.tsv"
  add_manager captainhook "captainhook.json" "$(installed_by captainhook)" "$TMP/captainhook.tsv"
fi

# --- A plain hook script no manager above installed ---------------------------------
if [[ -n "$ACTIVE" ]] && ! printf '%s' "$ACTIVE_TEXT" | grep -qiE 'grumphp|husky|lefthook|pre-commit\.com|pre_commit|captainhook' \
   && [[ "$HOOKS_PATH_CFG" != *.husky* ]]; then
  : > "$TMP/script.tsv"
  for _h in $ACTIVE; do
    _hits="$(grep -iE 'phpcs|phpcbf|phpstan|php -l|parallel-lint|phplint|phpunit|composer validate' "$HOOKS_DIR/$_h" 2>/dev/null | grep -vE '^[[:space:]]*#' || true)"
    if [[ -n "$_hits" ]]; then
      printf '%s\n' "$_hits" | while IFS= read -r _l; do printf '%s\t%s\n' "$_h: $(trim "$_l" | cut -c1-60)" "$(trim "$_l")"; done >> "$TMP/script.tsv"
    else
      printf '%s\t%s\n' "$_h script" "$HOOKS_DIR/$_h" >> "$TMP/script.tsv"
    fi
  done
  add_manager hook-script "${HOOKS_DIR}" true "$TMP/script.tsv"
fi

MANAGERS="$(jq -s -c . "$MGR")"

# --- Map tasks to equivalents ----------------------------------------------------------
# classify <text> -> phpcs | phpstan | phplint | composer | phpunit | (empty)
classify() {
  local t; t="$(lc "$1")"
  case "$t" in
    *phpcs*|*phpcbf*|*codesniffer*) printf 'phpcs';;
    *phpstan*) printf 'phpstan';;
    *phplint*|*php_lint*|*php-lint*|*"php -l"*|*parallel-lint*) printf 'phplint';;
    *phpunit*) printf 'phpunit';;
    composer|"composer: composer"|*"composer validate"*) printf 'composer';;
  esac
  return 0
}

: > "$TMP/class.tsv"
printf '%s' "$MANAGERS" | jq -r '.[] | .name as $m | .tasks[] | [$m, .name, .command] | @tsv' \
  | while IFS="$(printf '\t')" read -r _m _n _c; do
      _k="$(classify "$_n")"; [[ -n "$_k" ]] || _k="$(classify "$_c")"
      # GrumPHP's composer task is named exactly "composer" (composer validate).
      [[ -z "$_k" && "$_m" == "grumphp" && "$_n" == "composer" ]] && _k="composer"
      printf '%s\t%s\t%s\n' "$_m" "$_n" "$_k"
    done > "$TMP/class.tsv"

# Hook options that shape the equivalents (GrumPHP only).
PHPCS_RULESET_ARG=""; PHPSTAN_LEVEL=""; NOTE_PHPCS=""; NOTE_PHPSTAN=""
_std="$(awk -F'\t' '$1 == "phpcs" && $2 == "standard" {print $3; exit}' "$GRUMPHP_OPTS" 2>/dev/null || true)"
if [[ -n "$_std" ]]; then
  if [[ -f "$REPO/$_std" ]]; then
    PHPCS_RULESET_ARG="$REPO/$_std"
  elif [[ "$(lc "$(printf '%s' "$_std" | tr -d '[] ')")" == "drupal,drupalpractice" || "$(lc "$_std")" == "drupal" ]]; then
    PHPCS_RULESET_ARG="drupilot"
  else
    NOTE_PHPCS="the hook's phpcs standard '$_std' is not a file; run-phpcs.sh resolves the ruleset itself"
  fi
fi
_lvl="$(awk -F'\t' '$1 == "phpstan" && $2 == "level" {print $3; exit}' "$GRUMPHP_OPTS" 2>/dev/null || true)"
case "$_lvl" in ''|*[!0-9]*) [[ -n "$_lvl" && "$_lvl" != "null" && "$_lvl" != "~" ]] && NOTE_PHPSTAN="the hook's phpstan level '$_lvl' is not a number; run-phpstan.sh uses its default";; *) PHPSTAN_LEVEL="$_lvl";; esac
_pcfg="$(awk -F'\t' '$1 == "phpstan" && $2 == "configuration" {print $3; exit}' "$GRUMPHP_OPTS" 2>/dev/null || true)"
if [[ -n "$_pcfg" && "$_pcfg" != "null" && "$_pcfg" != "~" ]]; then
  NOTE_PHPSTAN="${NOTE_PHPSTAN:+$NOTE_PHPSTAN; }the hook's phpstan configuration '$_pcfg' is not used (run-phpstan.sh uses the test-bed's phpstan.neon)"
fi

SUBJ_Q="$(printf '%q' "$SUBJECT_ABS")"
by_for() {
  case "$1" in
    phpcs)    printf 'scripts/analysis/run-phpcs.sh --subject %s%s' "$SUBJ_Q" "${PHPCS_RULESET_ARG:+ --ruleset $(printf '%q' "$PHPCS_RULESET_ARG")}";;
    phpstan)  printf 'scripts/analysis/run-phpstan.sh --subject %s%s' "$SUBJ_Q" "${PHPSTAN_LEVEL:+ --level $PHPSTAN_LEVEL}";;
    phplint)  printf 'php -l on the changed PHP files (via drupal_runner)';;
    composer) printf 'composer validate --no-check-publish (via drupal_runner)';;
    phpunit)  printf 'scripts/tests/run-phpunit.sh --subject %s' "$SUBJ_Q";;
  esac
  return 0
}

: > "$TMP/eq.jsonl"
for _k in phpcs phpstan phplint composer phpunit; do
  _tasks="$(awk -F'\t' -v k="$_k" '$3 == k {print $1 ": " $2}' "$TMP/class.tsv")"
  [[ -n "$_tasks" ]] || continue
  _cov=true; _note=""
  case "$_k" in
    phpcs) _note="$NOTE_PHPCS";;
    phpstan) _note="$NOTE_PHPSTAN";;
    phpunit) if [[ "$WITH_TESTS" == "1" ]]; then _note="records last-test.json (the preservation verdict)"; else _cov=false; _note="tests are not run by default: pass --with-tests, or run /drupilot-test"; fi;;
  esac
  printf '%s\n' "$_tasks" | jq -R . | jq -s -c --arg k "$_k" --arg by "$(by_for "$_k")" --argjson cov "$_cov" --arg note "$_note" \
    '{kind:$k, tasks:., by:$by, covered:$cov, note:(if $note == "" then null else $note end)}' >> "$TMP/eq.jsonl"
done
EQUIV="$(jq -s -c . "$TMP/eq.jsonl")"
UNCOVERED="$(awk -F'\t' '$3 == "" {print $1 "\t" $2}' "$TMP/class.tsv" \
  | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {manager:.[0], task:.[1]})')"
# A phpunit task left uncovered (no --with-tests) is also listed as uncovered.
UNCOVERED="$(jq -c -n --argjson u "$UNCOVERED" --argjson e "$EQUIV" '
  $u + [ $e[] | select(.covered == false) | .tasks[] | {manager:(split(": ")[0]), task:(split(": ")[1:] | join(": "))} ]')"

ACTIVE_JSON="$(printf '%s\n' $ACTIVE | jq -R . | jq -s -c 'map(select(length > 0))')"
REPORT="$(jq -n -c \
  --arg repo "$REPO" --arg hd "$HOOKS_DIR" --arg hp "$HOOKS_PATH_CFG" \
  --argjson active "$ACTIVE_JSON" --argjson m "$MANAGERS" \
  --argjson e "$EQUIV" --argjson u "$UNCOVERED" '
  {repo:$repo, hooks_dir:(if $hd == "" then null else $hd end),
   hooks_path_config:(if $hp == "" then null else $hp end),
   active_hooks:$active, has_hooks:(($active | length) > 0),
   managers:$m, equivalents:$e, uncovered:$u}')"

# --- Human summary (STDERR) ------------------------------------------------------------
_nm="$(printf '%s' "$REPORT" | jq '.managers | length')"
if [[ "$_nm" == "0" && -z "$ACTIVE" ]]; then
  log_info "Repository $REPO: no git hook manager and no active commit hook."
else
  log_info "Repository $REPO"
  log_info "Active commit hooks : $(printf '%s' "$REPORT" | jq -r 'if (.active_hooks | length) == 0 then "none installed" else (.active_hooks | join(", ")) end')"
  printf '%s' "$REPORT" | jq -r '.managers[] | "Hook manager        : \(.name) (\(.config))\(if .installed then "" else ", not installed here" end): \([.tasks[].name] | join(", "))"' \
    | while IFS= read -r _l; do log_info "$_l"; done
  printf '%s' "$REPORT" | jq -r '.equivalents[] | "Equivalent \(.kind): \(.by)\(if .covered then "" else " (NOT covered: \(.note))" end)"' \
    | while IFS= read -r _l; do log_info "$_l"; done
  printf '%s' "$REPORT" | jq -r '.uncovered[] | "Uncovered (no drupilot equivalent): \(.manager): \(.task)"' \
    | while IFS= read -r _l; do log_warn "$_l"; done
fi

if [[ "$MODE" == "detect" ]]; then
  printf '%s\n' "$REPORT" | jq .
  exit 0
fi

# --- Run the equivalents ------------------------------------------------------------------
if [[ "$DRY" == "1" ]]; then
  log_info "Dry run: nothing executed, nothing recorded."
  printf '%s\n' "$REPORT" | jq '. + {dry_run:true, plan:[.equivalents[] | select(.covered) | {kind, by}]}'
  exit 0
fi

DRUPAL_ROOT="$(find_drupal_root "$SUBJECT_ABS" 2>/dev/null || true)"
RUNNER=""
if [[ -n "$DRUPAL_ROOT" ]]; then
  ddev_ensure_running "$DRUPAL_ROOT" >/dev/null 2>&1 || true
  RUNNER="$(drupal_runner "$DRUPAL_ROOT")"
fi
declare -a RCMD=()
[[ -n "$RUNNER" ]] && read -r -a RCMD <<<"$RUNNER"

# rel_to_root <abs> -> the path relative to the Drupal root (empty if outside).
rel_to_root() {
  case "$1" in
    "$DRUPAL_ROOT") printf '.';;
    "$DRUPAL_ROOT"/*) printf '%s' "${1#"$DRUPAL_ROOT"/}";;
  esac
  return 0
}

run_phplint() {
  [[ -n "$DRUPAL_ROOT" ]] || { log_warn "phplint: no Drupal root (run /drupilot-setup first)."; return 2; }
  local srel files f rc=0 n=0
  srel="$(rel_to_root "$SUBJECT_ABS")"
  [[ -n "$srel" ]] || { log_warn "phplint: the subject is outside the Drupal root."; return 2; }
  if git -C "$SUBJECT_ABS" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    files="$( { git -C "$SUBJECT_ABS" diff --name-only --relative HEAD 2>/dev/null; git -C "$SUBJECT_ABS" ls-files --others --exclude-standard 2>/dev/null; } | sort -u)"
  else
    files="$(git -C "$SUBJECT_ABS" ls-files --cached --others --exclude-standard 2>/dev/null | sort -u)"
  fi
  while IFS= read -r f; do
    [[ -n "$f" && -f "$SUBJECT_ABS/$f" ]] || continue
    case "$f" in *.php|*.module|*.inc|*.install|*.theme|*.profile|*.test) : ;; *) continue;; esac
    n=$((n+1))
    # </dev/null: `ddev exec` reads STDIN and would swallow the rest of the list.
    if ! ( cd "$DRUPAL_ROOT" && ${RCMD[@]+"${RCMD[@]}"} php -l "$srel/$f" </dev/null >/dev/null 2>"$TMP/lint.err" ); then
      log_err "php -l failed: $srel/$f"
      sed 's/^/    /' "$TMP/lint.err" >&2 || true
      rc=1
    fi
  done <<<"$files"
  log_info "phplint: $n changed PHP file(s) checked."
  return "$rc"
}

run_composer() {
  [[ -n "$DRUPAL_ROOT" ]] || { log_warn "composer: no Drupal root (run /drupilot-setup first)."; return 2; }
  local cj rel
  cj="$REPO/composer.json"; [[ -f "$cj" ]] || cj="$SUBJECT_ABS/composer.json"
  [[ -f "$cj" ]] || { log_info "composer: no composer.json to validate."; return 0; }
  rel="$(rel_to_root "$cj")"
  [[ -n "$rel" ]] || { log_warn "composer: $cj is outside the Drupal root."; return 2; }
  if [[ -z "$RUNNER" ]] && ! have_cmd composer; then log_warn "composer: not available on the host and DDEV is not running."; return 2; fi
  ( cd "$DRUPAL_ROOT" && ${RCMD[@]+"${RCMD[@]}"} composer validate --no-check-publish --no-interaction "$rel" </dev/null ) >&2
}

: > "$TMP/ran.jsonl"
FAILED=0
PR="$(plugin_root)"
for _k in $(printf '%s' "$REPORT" | jq -r '.equivalents[] | select(.covered) | .kind'); do
  log_step "Hook equivalent: $_k"
  set +e
  case "$_k" in
    phpcs)
      declare -a _a=(--subject "$SUBJECT_ABS")
      [[ -n "$PHPCS_RULESET_ARG" ]] && _a+=(--ruleset "$PHPCS_RULESET_ARG")
      # run-phpcs.sh records the ruleset it resolved (phpcs-ruleset.json) only
      # once it gets to run PHPCS: set the previous record aside to tell "PHPCS
      # ran" from "it stopped before" (both can exit 2 — PHPCS 3 exits 2 for
      # unfixable violations), and read back whether it fell back.
      _rsj="$(project_state_dir "$SUBJECT_ABS")/phpcs-ruleset.json"
      rm -f "$_rsj.prev"; [[ -f "$_rsj" ]] && mv "$_rsj" "$_rsj.prev"
      bash "$PR/scripts/analysis/run-phpcs.sh" "${_a[@]}" >&2;;
    phpstan)
      declare -a _a=(--subject "$SUBJECT_ABS")
      [[ -n "$PHPSTAN_LEVEL" ]] && _a+=(--level "$PHPSTAN_LEVEL")
      bash "$PR/scripts/analysis/run-phpstan.sh" "${_a[@]}" >&2;;
    phplint)  run_phplint;;
    composer) run_composer;;
    phpunit)  bash "$PR/scripts/tests/run-phpunit.sh" --subject "$SUBJECT_ABS" >&2;;
  esac
  _rc=$?
  set -e
  # run-phpcs/run-phpstan exit 2 for a missing requirement and run-phpstan 3
  # for a crash: no verdict, so "not-runnable" rather than "fail".
  _st="pass"
  if [[ "$_rc" -ne 0 ]]; then
    _st="fail"
    case "$_k:$_rc" in phpstan:2|phpstan:3|phplint:2|composer:2|phpunit:2) _st="not-runnable";; esac
    FAILED=1
  fi
  if [[ "$_k" == "phpcs" ]]; then
    if [[ ! -f "$_rsj" ]]; then
      # Stopped before running PHPCS (toolchain missing, ruleset unusable).
      [[ -f "$_rsj.prev" ]] && mv "$_rsj.prev" "$_rsj"
      if [[ "$_rc" -ne 0 ]]; then _st="not-runnable"; FAILED=1; fi
    else
      rm -f "$_rsj.prev"
      if [[ "$(jq -r '.source // empty' "$_rsj" 2>/dev/null || true)" == "fallback" ]]; then
        # The hook's own ruleset did not load: a run with another standard
        # proves nothing about the hook's task.
        log_warn "phpcs: run-phpcs.sh fell back to the default standard (the project/hook ruleset could not be loaded): not counted as the hook's phpcs task."
        _st="not-runnable"; FAILED=1
      fi
    fi
  fi
  jq -n -c --arg k "$_k" --arg by "$(by_for "$_k")" --argjson rc "$_rc" --arg st "$_st" \
    '{kind:$k, by:$by, rc:$rc, status:$st}' >> "$TMP/ran.jsonl"
done

RAN="$(jq -s -c . "$TMP/ran.jsonl")"
STATE_FILE="$(project_state_dir "$SUBJECT_ABS")/hooks-substitution.json"
RESULT="$(printf '%s' "$REPORT" | jq -c --argjson ran "$RAN" --arg sf "$STATE_FILE" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  . + {ran:$ran,
       all_green:(($ran | length) > 0 and ($ran | all(.status == "pass"))),
       complete:((.uncovered | length) == 0),
       state_file:$sf, at:$at}')"
printf '%s\n' "$RESULT" > "$STATE_FILE" 2>/dev/null || log_warn "Could not record $STATE_FILE."

hr
if [[ "$FAILED" == "0" ]]; then
  log_ok "Every covered hook equivalent passed$(printf '%s' "$RESULT" | jq -r 'if .complete then "." else " (some hook tasks have no equivalent: see uncovered)." end')"
else
  log_warn "A hook equivalent failed or could not run: fix it before committing (do not skip the hook)."
fi
log_info "Recorded: $STATE_FILE (the port report lists it under Verification)."
printf '%s\n' "$RESULT" | jq .
[[ "$FAILED" == "0" ]] || exit 3
exit 0
