#!/usr/bin/env bash
# The toolchain matrix (T-M2-10) and a 0.9 lock read as cell legacy_v1
# (T-M2-11, CC-10), with install-toolchain.sh --dry-run (no DDEV) on a fake
# Drupal root: the lock drupilot 0.9.1 wrote in lab L-M2-2
# (tests/fixtures/migration-0.9) reproduces 0.9.1's own dry-run specs and
# prints the refresh notice; --source reference moves to cell 11; a root
# without a lock gets cell 11's pins; a Drupal 12 root, whose cell is not
# verified yet, warns and resolves from the ranges (exit 0); a lock that
# records its cell is read as that cell.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
export DRUPILOT_HOME="$T_TMP/home"
FX="$T_REPO/tests/fixtures/migration-0.9"
IT="$T_REPO/scripts/env/install-toolchain.sh"
# mkroot DIR CORE -> a Drupal root that only composer.json/composer.lock describe.
mkroot() {
  mkdir -p "$1"
  printf '{"name": "lab/root"}\n' > "$1/composer.json"
  jq -n --arg v "$2" '{packages: [{name: "drupal/core", version: $v}], "packages-dev": []}' > "$1/composer.lock"
}
# dry ROOT [ARGS] -> the dry-run JSON; STDERR in $T_TMP/err, the exit code in $T_TMP/rc.
dry() {
  local root="$1" rc=0; shift
  CLAUDE_PLUGIN_ROOT="$T_REPO" "$T_SH" "$IT" --dir "$root" --dry-run --json "$@" 2> "$T_TMP/err" || rc=$?
  printf '%s' "$rc" > "$T_TMP/rc"
}
specs() { jq -c '[.packages[] | {name, spec, source}]'; }

R="$T_TMP/legacy"; mkroot "$R" 11.4.8
LOCK="$(DRUPILOT_PROJECT_DIR="$R" CLAUDE_PLUGIN_ROOT="$T_REPO" "$T_SH" -c '. "$1"; drupilot_lock_file' _ "$T_LIB")"
mkdir -p "$(dirname "$LOCK")"; cp "$FX/root-state/drupilot-lock.json" "$LOCK"
out="$(dry "$R")"
assert_eq "a 0.9 lock: exit 0" "$(cat "$T_TMP/rc")" "0"
assert_eq "a 0.9 lock is cell legacy_v1" "$(printf '%s' "$out" | jq -r .cell)" "legacy_v1"
assert_eq "a 0.9 lock reproduces 0.9.1's own dry-run specs" "$(printf '%s' "$out" | specs)" "$(specs < "$FX/expected/install-toolchain.dry-run.json")"
assert_match "and tells how to refresh it" "$(cat "$T_TMP/err")" 'written by drupilot 0\.9.*legacy_v1'
out="$(dry "$R" --source reference)"
assert_eq "--source reference refreshes to cell 11" "$(printf '%s' "$out" | jq -r .cell)" "11"
assert_eq "... with cell 11's pins" "$(printf '%s' "$out" | jq -r '[.packages[] | select(.source == "reference") | .spec] | sort | join(" ")')" \
  "drupal/coder:8.3.31 mglaman/phpstan-drupal:2.2.2 palantirnet/drupal-rector:1.1.3 phpstan/extension-installer:1.4.3 phpstan/phpstan-deprecation-rules:2.0.5 phpstan/phpstan:2.2.16 rector/rector:2.6.1"

N="$T_TMP/new"; mkroot "$N" 11.4.8
out="$(dry "$N" --no-core-dev)"
assert_eq "no lock, Drupal 11: cell 11" "$(printf '%s' "$out" | jq -c '[.cell, .source]')" '["11","reference"]'
assert_eq "... pinned to cell 11" "$(printf '%s' "$out" | jq -r '.packages[] | select(.name == "rector/rector") | .spec')" "rector/rector:2.6.1"

D="$T_TMP/d12"; mkroot "$D" 12.0.0-beta1
out="$(dry "$D" --source reference --no-core-dev)"
assert_eq "Drupal 12: exit 0 (T-M2-10 done-when)" "$(cat "$T_TMP/rc")" "0"
assert_eq "Drupal 12 is cell 12" "$(printf '%s' "$out" | jq -r .cell)" "12"
assert_match "an unverified cell warns" "$(cat "$T_TMP/err")" 'Toolchain cell 12 has no verified set yet'
assert_eq "... and resolves every package from the ranges" "$(printf '%s' "$out" | jq -r '[.packages[].source] | unique | join(",")')" "range"

C="$T_TMP/cell"; mkroot "$C" 11.4.8
LOCK="$(DRUPILOT_PROJECT_DIR="$C" CLAUDE_PLUGIN_ROOT="$T_REPO" "$T_SH" -c '. "$1"; drupilot_lock_file' _ "$T_LIB")"
mkdir -p "$(dirname "$LOCK")"; jq '. + {toolchain_cell: "11"}' "$FX/root-state/drupilot-lock.json" > "$LOCK"
out="$(dry "$C" --no-core-dev)"
assert_eq "a lock that records its cell is read as that cell" "$(printf '%s' "$out" | jq -r .cell)" "11"
assert_no_stdout "... and gives no 0.9 notice" grep 'written by drupilot 0.9' "$T_TMP/err"
t_done
