#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/dev/baseline-0.9.sh
# The frozen v0.9.0 baseline (a developer/CI tool: no command, skill or hook
# calls it). --capture runs the Docker-free, PHP-free scripts of the v0.9.0 tag
# (a throwaway `git worktree`) on copies of tests/fixtures/legacy_widgets and
# tests/fixtures/monorepo and writes their canonical output to
# tests/baseline/v0.9.0/. --check runs the SAME captures with this checkout's
# scripts and compares them byte for byte: every change of 0.9 behaviour is
# either listed in tests/baseline/v0.9.0/allowed-diffs.txt or fails. --check
# never needs the tag (CI checkouts fetch none); scripts/dev/smoke.sh runs it as
# its `baseline` test.
#
# Captures (one file each under tests/baseline/v0.9.0/; JSON is wrapped as
# {exit, stdout} so each script's exit code is frozen too):
#   lw-*            lint-extension-metadata (--no-write), check-port-safety
#                   (--no-diff), scan-signature-changes, detect-php-floor,
#                   core-strategy (port and refactor phase) and port-summary
#                   (on the canned state) for legacy_widgets
#   mono-<module>-* the same per-module scripts (but port-summary) for every
#                   monorepo module, and mono-layers (all and declared edges,
#                   --no-write) for the monorepo
#   sig-*           the same per-module scripts for the committed input module
#                   tests/baseline/inputs/php_floor_signals (one PHP 8.2, 8.3
#                   and 8.4 construct per detect-php-floor.sh signal, each hit
#                   unique, so the first-hit order is the same on every walk)
#   classify-deprecations-{txt,json}, explain-deprecations-{txt,json}
#                   on the committed PHPStan sample, in both formats
#   render-<P>      render-templates.sh --json (every key but the host-dependent
#                   files[].valid/validator) and, under render-<P>/, the files it
#                   writes (rector.php, phpstan.neon, phpcs.xml.dist,
#                   .ddev/config.testing.yaml) into a stub Drupal root, for
#                   DRUPILOT_PHP_TARGET 8.3/8.4/8.5
#   preflight-keys, preflight-extended-keys   the key sets only of
#                   `preflight --json` and `--profile all --extended --json`
#                   (toolchain is null on a loose subject)
#   detect-php-<P>  detect-php.sh --json: its keys and the host-independent
#                   values (target, supported, unconfirmed)
#   commands-frontmatter  every command's name, argument-hint tokens (in
#                   order) and disable-model-invocation
#   choices         config/choices.json, every choice without its free-text note
#   env-public-v0.9 the README-documented DRUPILOT_* names and the
#                   config/defaults.json keys (CC-06)
#
# Inputs are committed, never ad hoc: tests/baseline/inputs/ holds the
# hand-made PHPStan sample (0.9 text table and native JSON formats) that
# classify-/explain-deprecations.sh read, the canned state.json that
# port-summary.sh reads, and the php_floor_signals module.
#
# Isolation (as smoke.sh): the fixtures are copied to one fixed path,
# $TMP/bl/fx/<fixture>; HOME, CLAUDE_PLUGIN_DATA and the XDG dirs point inside
# $TMP (CLAUDE_PLUGIN_DATA equals the XDG data dir, so 0.9.0 and a checkout
# that ignores it resolve the same state); every DRUPILOT_* variable is unset;
# LC_ALL=C. Nothing is written to the repository (apart from --capture's
# output) or to the developer's state.
#
# Normalization (before the compare): JSON goes through jq -S; the fixture
# prefix becomes <SUBJECT>, the plugin root <PLUGIN_ROOT>, the temp dir <TMP>
# (and the sanitized forms of the subject and temp paths that state keys use,
# <SUBJECTKEY> and <TMPKEY>), every ISO-8601 timestamp <TS>, and every
# drupilot_version/drupilot_revision string <VER> (a release bump is not a
# behaviour change).
#
# allowed-diffs.txt: one intended difference per line,
#     <file> sha256:<hex of the normalized output> <reason; CHANGELOG entry>
# A listed file passes only while the checkout produces exactly that output.
# '#' starts a comment. --check prints the line to add for each differing
# file (and a diff on STDERR).
#
# SHA256SUMS (written by --capture) pins every captured file, so an edit to
# the committed baseline itself fails --check too, also for a file whose
# output allowed-diffs.txt lets differ.
#
# Usage:
#   scripts/dev/baseline-0.9.sh [--capture | --check] [--json] [--keep]
#                               [-h|--help]
#     --capture  capture from the v0.9.0 tag into tests/baseline/v0.9.0/
#                (needs git and the tag; run once, commit the result)
#     --check    capture from this checkout and compare (the default)
#     --json     machine summary on STDOUT (logs stay on STDERR):
#                {ok, mode, files:[{name, status, detail}]}, status:
#                same | allowed | differs | missing | unexpected | error |
#                tampered (the committed file does not match SHA256SUMS)
#     --keep     keep the temp dir and print its path on STDERR
#
# Requires bash >= 3.2 and jq; --capture also git and the v0.9.0 tag; a
# sha256 tool (sha256sum or shasum) to honour allowed-diffs.txt.
# Exit codes: 0 every capture matches the baseline or an allowed diff ·
# 1 a difference, a script error on a capture, a usage error or a missing
# requirement.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SH="${BASH:-bash}"
REF="v0.9.0"
BASE_DIR="$REPO/tests/baseline/v0.9.0"
INPUTS="$REPO/tests/baseline/inputs"
ALLOWED="$BASE_DIR/allowed-diffs.txt"
PHP_TARGETS="8.3 8.4 8.5"

MODE="check"; AS_JSON=0; KEEP=0

usage() { print_usage "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --capture) MODE="capture"; shift;;
    --check) MODE="check"; shift;;
    --json) AS_JSON=1; shift;;
    --keep) KEEP=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done

have_cmd jq || die "jq is required by scripts/dev/baseline-0.9.sh" 1
[[ -d "$REPO/tests/fixtures/legacy_widgets" && -d "$REPO/tests/fixtures/monorepo" ]] \
  || die "Fixtures not found under $REPO/tests/fixtures" 1
[[ -d "$INPUTS" ]] || die "Baseline inputs not found: $INPUTS" 1
if [[ "$MODE" == "capture" ]]; then
  have_cmd git || die "--capture needs git" 1
  git -C "$REPO" rev-parse -q --verify "refs/tags/$REF^{commit}" >/dev/null 2>&1 \
    || die "--capture needs the $REF tag (git fetch --tags)" 1
else
  [[ -d "$BASE_DIR" ]] || die "No baseline to check against: $BASE_DIR (run --capture first)" 1
fi

HASHER=""
if have_cmd sha256sum; then HASHER="sha256sum"; elif have_cmd shasum; then HASHER="shasum -a 256"; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-baseline.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
WT=""
cleanup() {
  if [[ -n "$WT" ]]; then
    git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
    git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  fi
  if [[ "$KEEP" == "1" ]]; then log_info "Kept the baseline workspace: $TMP"
  else rm -rf "${TMP:?}"; fi
}
trap cleanup EXIT

# The plugin tree under test: the v0.9.0 worktree, or this checkout.
if [[ "$MODE" == "capture" ]]; then
  WT="$TMP/wt"
  git -C "$REPO" worktree add -q --detach "$WT" "$REF" >/dev/null 2>&1 \
    || die "git worktree add $WT $REF failed" 1
  PR="$WT"
else
  PR="$REPO"
fi

# --- Isolated environment -----------------------------------------------------
for _v in $(env | sed -n 's/^\(DRUPILOT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
export CLAUDE_PLUGIN_ROOT="$PR"
export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/home/.local/share" XDG_STATE_HOME="$TMP/home/.local/state"
export XDG_CACHE_HOME="$TMP/home/.cache" XDG_CONFIG_HOME="$TMP/home/.config"
export CLAUDE_PLUGIN_DATA="$XDG_DATA_HOME/drupilot"
unset CLAUDE_CONFIG_DIR
export GIT_CONFIG_NOSYSTEM=1 LC_ALL=C
mkdir -p "$HOME" "$CLAUDE_PLUGIN_DATA"

FXROOT="$TMP/bl/fx"
IN="$TMP/bl/in"
RAW="$TMP/raw"
OUT="$TMP/out"
mkdir -p "$FXROOT" "$IN" "$RAW" "$OUT"
cp -R "$REPO/tests/fixtures/legacy_widgets" "$REPO/tests/fixtures/monorepo" "$INPUTS/php_floor_signals" "$FXROOT/"
cp -R "$INPUTS/." "$IN/"
LW="$FXROOT/legacy_widgets"
MONO="$FXROOT/monorepo"
SIG="$FXROOT/php_floor_signals"

# --- Normalization ------------------------------------------------------------
# sanitized <path> -> the state-key form of a path (project_state_path's tr).
sanitized() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

# The literal replacements, longest first, handed to awk through ENVIRON (an
# `awk -v` value would have its backslashes interpreted).
_np=0
add_pair() { _np=$((_np + 1)); export "BL_F$_np=$1" "BL_T$_np=$2"; return 0; }
add_pair "$LW" "<SUBJECT>"
add_pair "$MONO" "<SUBJECT>"
add_pair "$SIG" "<SUBJECT>"
add_pair "$(sanitized "$LW")" "<SUBJECTKEY>"
add_pair "$(sanitized "$MONO")" "<SUBJECTKEY>"
add_pair "$(sanitized "$SIG")" "<SUBJECTKEY>"
add_pair "$PR" "<PLUGIN_ROOT>"
add_pair "$TMP" "<TMP>"
add_pair "$(sanitized "$TMP")" "<TMPKEY>"
export BL_N="$_np"

# lit_replace: STDIN -> STDOUT with every literal occurrence of each pair
# replaced, in order.
lit_replace() {
  awk 'BEGIN { n = ENVIRON["BL_N"] + 0
               for (i = 1; i <= n; i++) { f[i] = ENVIRON["BL_F" i]; t[i] = ENVIRON["BL_T" i] } }
       { line = $0
         for (i = 1; i <= n; i++) {
           if (f[i] == "") continue
           res = ""
           while ((p = index(line, f[i])) > 0) {
             res = res substr(line, 1, p - 1) t[i]
             line = substr(line, p + length(f[i]))
           }
           line = res line
         }
         print line }'
}

TS_ERE='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9](\.[0-9]+)?(Z|[+-][0-9][0-9]:?[0-9][0-9])?'

# The canonical JSON form (with jq -S): numbers re-printed, timestamps and
# drupilot versions masked.
JQ_NORM='def norm:
  if type == "string" then gsub($ts; "<TS>")
  elif type == "number" then . + 0
  elif type == "object" then
    (if (.drupilot_version | type) == "string" then .drupilot_version = "<VER>" else . end)
    | (if (.drupilot_revision | type) == "string" then .drupilot_revision = "<VER>" else . end)
  else . end;'

# --- Capture harness ------------------------------------------------------------
ERRORS="$TMP/errors.txt"
: > "$ERRORS"

# cap <name> <view|-> <cmd...> -> runs the command (stdin /dev/null) and keeps
# its stdout, stderr and exit code under $RAW. <view> is a jq filter applied
# to the stdout JSON before it is stored ("-" keeps the whole document). Safe
# in a background job: every capture writes its own files.
cap() {
  local name="$1" view="$2" rc hit; shift 2
  if "$@" > "$RAW/$name.out" 2> "$RAW/$name.err" < /dev/null; then rc=0; else rc=$?; fi
  printf '%s\n' "$rc" > "$RAW/$name.rc"
  printf '%s\n' "$view" > "$RAW/$name.view"
  hit="$(grep -E 'syntax error|unbound variable|command not found|bad substitution|: invalid option|integer expression expected' \
           "$RAW/$name.err" 2>/dev/null | head -n 2 || true)"
  [[ -z "$hit" ]] || printf '%s: shell error: %s\n' "$name" "$(printf '%s' "$hit" | tr '\n' ' ')" >> "$ERRORS"
  return 0
}

# finalize <name> -> $OUT/<name>.json: {exit, stdout} (stdout_text when the
# output is not one JSON document), normalized.
finalize() {
  local name="$1" rc view
  rc="$(cat "$RAW/$name.rc")"; view="$(cat "$RAW/$name.view")"
  [[ "$view" == "-" ]] && view="."
  lit_replace < "$RAW/$name.out" > "$RAW/$name.lit"
  if jq -e -s 'length == 1' "$RAW/$name.lit" >/dev/null 2>&1; then
    jq -S --argjson rc "$rc" --arg ts "$TS_ERE" \
      "$JQ_NORM {exit: \$rc, stdout: ($view)} | walk(norm)" "$RAW/$name.lit" > "$OUT/$name.json" 2>/dev/null \
      || jq -S -n --argjson rc "$rc" --arg ts "$TS_ERE" --rawfile t "$RAW/$name.lit" \
           "$JQ_NORM {exit: \$rc, stdout_text: \$t, view_error: true} | walk(norm)" > "$OUT/$name.json"
  else
    jq -S -n --argjson rc "$rc" --arg ts "$TS_ERE" --rawfile t "$RAW/$name.lit" \
      "$JQ_NORM {exit: \$rc, stdout_text: \$t} | walk(norm)" > "$OUT/$name.json"
  fi
  return 0
}

# capture_file <src> <name> -> a rendered text file, path- and time-normalized.
capture_file() {
  local src="$1" name="$2"
  mkdir -p "$(dirname "$OUT/$name")"
  if [[ -f "$src" ]]; then
    lit_replace < "$src" | sed -E "s/$TS_ERE/<TS>/g" > "$OUT/$name"
  else
    printf '<absent>\n' > "$OUT/$name"
  fi
  return 0
}

S="$PR/scripts"

# --- Per-subject captures -------------------------------------------------------
subject_caps() {
  local p="$1" d="$2"
  cap "$p-lint-extension-metadata" - "$SH" "$S/analysis/lint-extension-metadata.sh" --subject "$d" --json --no-write
  cap "$p-check-port-safety" - "$SH" "$S/analysis/check-port-safety.sh" --subject "$d" --no-diff --json
  cap "$p-scan-signature-changes" - "$SH" "$S/analysis/scan-signature-changes.sh" --subject "$d" --json
  cap "$p-detect-php-floor" - "$SH" "$S/analysis/detect-php-floor.sh" --subject "$d" --json
  cap "$p-core-strategy" - "$SH" "$S/analysis/core-strategy.sh" --subject "$d" --json
  cap "$p-core-strategy-refactor" - "$SH" "$S/analysis/core-strategy.sh" --subject "$d" --phase refactor --json
  return 0
}

log_step "drupilot v0.9.0 baseline: $MODE ($(basename "$PR"))"

# The per-subject captures are independent (each subject has its own state
# key): run them as parallel jobs.
subject_caps lw "$LW" &
subject_caps sig "$SIG" &
for _m in $(find "$MONO/web/modules/custom" -name '*.info.yml' | LC_ALL=C sort); do
  _d="$(dirname "$_m")"
  subject_caps "mono-$(basename "$_d")" "$_d" &
done
wait

# port-summary on the canned state (its "subject" placeholder is the copy).
_sd="$("$SH" -c '. "$1/scripts/lib/common.sh"; project_state_path "$2"' _ "$PR" "$LW" < /dev/null)"
mkdir -p "$_sd"
BL_SUBJ="$LW" awk '{ line = $0; f = "<SUBJECT>"; res = ""
  while ((p = index(line, f)) > 0) { res = res substr(line, 1, p - 1) ENVIRON["BL_SUBJ"]; line = substr(line, p + length(f)) }
  print res line }' "$IN/state.json" > "$_sd/state.json"
cap lw-port-summary - "$SH" "$S/analysis/port-summary.sh" --subject "$LW" --json

cap mono-layers - "$SH" "$S/analysis/layers.sh" --dir "$MONO" --json --no-write
cap mono-layers-declared - "$SH" "$S/analysis/layers.sh" --dir "$MONO" --json --no-write --edges declared

for _f in txt json; do
  cap "classify-deprecations-$_f" - "$SH" "$S/analysis/classify-deprecations.sh" \
    --file "$IN/phpstan-legacy_widgets.$_f" --subject "$LW" --json
  cap "explain-deprecations-$_f" - "$SH" "$S/analysis/explain-deprecations.sh" \
    --file "$IN/phpstan-legacy_widgets.$_f" --json
done

# --- Host-independent views of host-dependent reports ---------------------------
cap preflight-keys '{keys: keys, profile, php_target, ready: (.ready | keys),
  check_keys: ([.checks[] | keys] | add | unique)}' \
  "$SH" "$S/env/preflight.sh" --json --subject "$LW"
cap preflight-extended-keys '{keys: keys, profile, php_target, extended, ready: (.ready | keys),
  check_keys: ([.checks[] | keys] | add | unique),
  toolchain: (if .toolchain == null then null else (.toolchain | keys) end)}' \
  "$SH" "$S/env/preflight.sh" --profile all --extended --json --subject "$LW"
for _p in $PHP_TARGETS; do
  cap "detect-php-$_p" '{keys: keys, target, supported, unconfirmed}' \
    env DRUPILOT_PHP_TARGET="$_p" "$SH" "$S/env/detect-php.sh" --json --subject "$LW"
done

# --- Rendered templates (a stub Drupal root per PHP target) ---------------------
for _p in $PHP_TARGETS; do
  _r="$TMP/bl/root-$_p"
  mkdir -p "$_r/web/core/lib" "$_r/web/modules/custom" "$_r/.ddev"
  printf '{"name": "drupilot-baseline/stub-root"}\n' > "$_r/composer.json"
  printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$_r/web/core/lib/Drupal.php"
  printf 'name: dpl-baseline\ntype: drupal11\ndocroot: web\n' > "$_r/.ddev/config.yaml"
  cp -R "$LW" "$_r/web/modules/custom/"
  cap "render-$_p" '{keys: keys, root, subject_path, dry_run, force, ok, restart_needed,
    files: [.files[] | del(.valid, .validator)], file_keys: ([.files[] | keys] | add | unique)}' \
    env DRUPILOT_PHP_TARGET="$_p" "$SH" "$S/env/render-templates.sh" \
      --root "$_r" --subject web/modules/custom/legacy_widgets --json
  for _f in rector.php phpstan.neon phpcs.xml.dist .ddev/config.testing.yaml; do
    capture_file "$_r/$_f" "render-$_p/$(basename "$_f")"
  done
done

# --- Static snapshots of the public surface ------------------------------------
snap_commands() {
  local f n hint dmi rows="" row
  for f in "$PR"/commands/*.md; do
    [[ -f "$f" ]] || continue
    n="$(awk 'NR == 1 && /^---/ { fm = 1; next } fm && /^---/ { exit }
              fm && /^name:/ { sub(/^name:[[:space:]]*/, ""); print; exit }' "$f")"
    [[ -n "$n" ]] || n="$(basename "$f" .md)"
    hint="$(awk 'NR == 1 && /^---/ { fm = 1; next } fm && /^---/ { exit }
                 fm && /^argument-hint:/ { sub(/^argument-hint:[[:space:]]*/, ""); print; exit }' "$f")"
    dmi="$(awk 'NR == 1 && /^---/ { fm = 1; next } fm && /^---/ { exit }
                fm && /^disable-model-invocation:/ { sub(/^disable-model-invocation:[[:space:]]*/, ""); print; exit }' "$f")"
    row="$(jq -n -c --arg n "$n" --arg h "$hint" --arg d "$dmi" '
      ($h | if test("^\".*\"$") then .[1:-1] else . end) as $hint
      | {name: $n,
         argument_hint: ($hint | split(" ") | map(select(. != ""))),
         disable_model_invocation: ($d == "true")}')"
    rows="$rows$row"$'\n'
  done
  printf '%s' "$rows" | jq -s -c 'sort_by(.name)'
  return 0
}
snap_choices() { jq -c '.choices | map_values(del(.note))' "$PR/config/choices.json"; }
snap_env_public() {
  local readme defaults
  readme="$( { grep -oE 'DRUPILOT_[A-Z0-9_]*(<KEY>|[A-Z0-9])' "$PR/README.md" || true; } \
             | grep -vx 'DRUPILOT_CHOICE' | LC_ALL=C sort -u | jq -R . | jq -s -c .)"
  defaults="$(jq -c '[keys[] | select(startswith("DRUPILOT_"))] | sort' "$PR/config/defaults.json")"
  jq -n -c --argjson r "$readme" --argjson d "$defaults" \
    '{readme: $r, defaults_json: $d, public: ($r + $d | unique)}'
}
cap commands-frontmatter - snap_commands
cap choices - snap_choices
cap env-public-v0.9 - snap_env_public

for _rc in "$RAW"/*.rc; do finalize "$(basename "$_rc" .rc)"; done

# --- Capture mode: write the baseline -------------------------------------------
if [[ "$MODE" == "capture" ]]; then
  if [[ -s "$ERRORS" ]]; then
    sed 's/^/    /' "$ERRORS" >&2
    die "A captured script failed with a shell error; nothing written." 1
  fi
  [[ -n "$HASHER" ]] || die "--capture needs sha256sum or shasum (for SHA256SUMS)" 1
  mkdir -p "$BASE_DIR"
  find "$BASE_DIR" -mindepth 1 ! -name allowed-diffs.txt -exec rm -rf {} + 2>/dev/null || true
  cp -R "$OUT/." "$BASE_DIR/"
  ( cd "$BASE_DIR" && find . -type f ! -name allowed-diffs.txt ! -name SHA256SUMS | sed 's#^\./##' | LC_ALL=C sort \
      | while IFS= read -r _f; do printf '%s  %s\n' "$($HASHER < "$_f" | cut -d' ' -f1)" "$_f"; done ) > "$BASE_DIR/SHA256SUMS"
  if [[ ! -f "$ALLOWED" ]]; then
    printf '# Intended differences from the v0.9.0 baseline, one per line:\n' > "$ALLOWED"
    printf '#   <file> sha256:<hex of the normalized output> <reason; CHANGELOG entry>\n' >> "$ALLOWED"
    printf '# scripts/dev/baseline-0.9.sh --check prints the line for each differing file.\n' >> "$ALLOWED"
  fi
  _count="$(cd "$OUT" && find . -type f | wc -l | tr -d ' ')"
  log_ok "Captured $_count file(s) from $REF into ${BASE_DIR#"$REPO"/}"
  if [[ "$AS_JSON" == "1" ]]; then
    jq -n -c --arg m "$MODE" --argjson c "$_count" '{ok: true, mode: $m, captured: $c}'
  fi
  exit 0
fi

# --- Check mode: compare ----------------------------------------------------------
RESULTS="$TMP/results.jsonl"
: > "$RESULTS"
FAILED=0

# allowed_hash <file> -> the sha256 recorded for <file> in allowed-diffs.txt.
allowed_hash() {
  [[ -f "$ALLOWED" ]] || return 0
  awk -v f="$1" '!/^[[:space:]]*(#|$)/ && $1 == f { h = $2; sub(/^sha256:/, "", h); print h; exit }' "$ALLOWED"
  return 0
}
file_hash() { [[ -n "$HASHER" ]] && $HASHER < "$1" | cut -d' ' -f1; return 0; }

result() {
  jq -n -c --arg n "$1" --arg s "$2" --arg d "$3" '{name: $n, status: $s, detail: $d}' >> "$RESULTS"
  case "$2" in
    same) ;;
    allowed) log_info "$1: allowed difference ($3)";;
    *) log_err "$1: $2 — $3"; FAILED=1;;
  esac
  return 0
}

while IFS= read -r _e; do
  [[ -n "$_e" ]] || continue
  result "${_e%%:*}" error "${_e#*: }"
done < "$ERRORS"

# The committed baseline itself: every file must match its SHA256SUMS line.
if [[ -z "$HASHER" ]]; then
  result SHA256SUMS error "no sha256 tool (sha256sum or shasum) to verify the committed baseline"
elif [[ ! -f "$BASE_DIR/SHA256SUMS" ]]; then
  result SHA256SUMS missing "tests/baseline/v0.9.0/SHA256SUMS is missing (rerun --capture)"
else
  ( cd "$BASE_DIR" && find . -type f ! -name allowed-diffs.txt ! -name SHA256SUMS | sed 's#^\./##' | LC_ALL=C sort ) \
    > "$TMP/committed.txt"
  awk '{ print $2 }' "$BASE_DIR/SHA256SUMS" | LC_ALL=C sort > "$TMP/pinned.txt"
  while IFS= read -r _f; do
    grep -qxF -- "$_f" "$TMP/pinned.txt" || result "$_f" tampered "committed but not pinned in SHA256SUMS"
  done < "$TMP/committed.txt"
  while read -r _h _f; do
    [[ -n "$_f" ]] || continue
    if [[ ! -f "$BASE_DIR/$_f" ]]; then
      result "$_f" tampered "pinned in SHA256SUMS but not committed"
    elif [[ "$(file_hash "$BASE_DIR/$_f")" != "$_h" ]]; then
      result "$_f" tampered "the committed baseline file no longer matches SHA256SUMS"
    fi
  done < "$BASE_DIR/SHA256SUMS"
fi

_seen="$TMP/seen.txt"
( cd "$OUT" && find . -type f | sed 's#^\./##' | LC_ALL=C sort ) > "$_seen"
while IFS= read -r _f; do
  _b="$BASE_DIR/$_f"
  if [[ ! -f "$_b" ]]; then
    result "$_f" unexpected "not in the baseline (a new capture needs a --capture refresh)"
    continue
  fi
  if cmp -s "$OUT/$_f" "$_b"; then
    result "$_f" same "byte-identical"
    continue
  fi
  _h="$(file_hash "$OUT/$_f")"
  _want="$(allowed_hash "$_f")"
  _why="$(awk -v f="$_f" '!/^[[:space:]]*(#|$)/ && $1 == f { $1 = ""; $2 = ""; sub(/^[[:space:]]+/, ""); print; exit }' "$ALLOWED" 2>/dev/null || true)"
  if [[ -n "$_h" && -n "$_want" && "$_h" == "$_want" ]]; then
    result "$_f" allowed "${_why:-listed in allowed-diffs.txt}"
    continue
  fi
  diff -u "$_b" "$OUT/$_f" 2>/dev/null | head -n 60 | sed 's/^/    /' >&2 || true
  if [[ -z "$_h" ]]; then
    result "$_f" differs "differs from the baseline (no sha256 tool to check allowed-diffs.txt)"
  elif [[ -n "$_want" ]]; then
    result "$_f" differs "differs from the baseline and from its allowed-diffs.txt hash; to allow: $_f sha256:$_h <reason>"
  else
    result "$_f" differs "differs from the baseline; to allow: $_f sha256:$_h <reason>"
  fi
done < "$_seen"

( cd "$BASE_DIR" && find . -type f ! -name allowed-diffs.txt ! -name SHA256SUMS | sed 's#^\./##' | LC_ALL=C sort ) \
  | while IFS= read -r _f; do
      grep -qxF -- "$_f" "$_seen" || printf '%s\n' "$_f"
    done > "$TMP/missing.txt"
while IFS= read -r _f; do
  [[ -n "$_f" ]] && result "$_f" missing "in the baseline, not produced by this checkout"
done < "$TMP/missing.txt"

_total="$(wc -l < "$RESULTS" | tr -d ' ')"
if [[ "$FAILED" == "1" ]]; then
  log_err "baseline-0.9.sh: the checkout differs from the v0.9.0 baseline"
else
  log_ok "baseline-0.9.sh: $_total capture(s) match the v0.9.0 baseline (or an allowed difference)"
fi
if [[ "$AS_JSON" == "1" ]]; then
  jq -s -c --argjson ok "$([[ "$FAILED" == "1" ]] && echo false || echo true)" --arg m "$MODE" \
    '{ok: $ok, mode: $m, files: .}' "$RESULTS"
fi
exit "$FAILED"
