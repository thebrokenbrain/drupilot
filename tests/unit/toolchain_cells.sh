#!/usr/bin/env bash
# The toolchain matrix (T-M2-10) and a 0.9 lock read as cell legacy_v1
# (T-M2-11, CC-10), with install-toolchain.sh --dry-run (no DDEV) on a fake
# Drupal root: the lock drupilot 0.9.1 wrote in lab L-M2-2
# (tests/fixtures/migration-0.9) reproduces 0.9.1's own dry-run specs and
# prints the refresh notice; --source reference moves to cell 11; a root
# without a lock gets cell 11's pins; a Drupal 12 root, whose cell is not
# verified yet, warns and resolves from the ranges (exit 0); a lock that
# records its cell is read as that cell; a lock 1.0 created (schema 1) is
# never legacy_v1; reading the cell creates no data dir; preflight still
# finds a known-broken combination on a root whose cell pins nothing.
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

# A lock drupilot 1.0 creates starts with schema 1: one that already pins
# rector/rector (a composer.lock drupilot did not set up, synced by
# lock-sync.sh) is not a 0.9 lock.
F="$T_TMP/fresh"; mkroot "$F" 11.4.8
DRUPILOT_PROJECT_DIR="$F" CLAUDE_PLUGIN_ROOT="$T_REPO" "$T_SH" -c '. "$1"; lock_set ".toolchain[\"rector/rector\"]" 2.6.1' _ "$T_LIB"
LOCK="$(DRUPILOT_PROJECT_DIR="$F" CLAUDE_PLUGIN_ROOT="$T_REPO" "$T_SH" -c '. "$1"; drupilot_lock_file' _ "$T_LIB")"
assert_eq "a lock 1.0 creates carries schema 1" "$(jq -c .schema "$LOCK")" "1"
out="$(dry "$F" --no-core-dev)"
assert_eq "... and is not read as legacy_v1" "$(printf '%s' "$out" | jq -r .cell)" "11"

# Reading the cell never creates drupilot's data dir (preflight runs it).
rm -rf "$DRUPILOT_HOME"
c="$(CLAUDE_PLUGIN_ROOT="$T_REPO" "$T_SH" -c '. "$1"; toolchain_cell_for "$2"' _ "$T_LIB" "$N")"
assert_eq "toolchain_cell_for without a lock: the core's cell" "$c" "11"
assert_eq "... and no data dir was created" "$([[ -e "$DRUPILOT_HOME" ]] && echo created || echo none)" "none"

# preflight still finds a known-broken combination when the cell pins nothing.
B="$T_TMP/broken"; mkdir -p "$B/web/core/lib"
printf '{"name": "lab/root"}\n' > "$B/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '12.0.0-beta1';\n}\n" > "$B/web/core/lib/Drupal.php"
jq -n '{packages: [{name: "drupal/core", version: "12.0.0-beta1"}], "packages-dev": [
  {name: "palantirnet/drupal-rector", version: "0.21.2"}, {name: "rector/rector", version: "2.6.2"}, {name: "phpstan/phpstan", version: "2.2.16"}]}' > "$B/composer.lock"
pf="$(cd "$B" && CLAUDE_PLUGIN_ROOT="$T_REPO" "$T_SH" "$T_REPO/scripts/env/preflight.sh" --profile analyze --extended --json 2>/dev/null || true)"
assert_eq "preflight on a Drupal 12 root: the twig-set combination is found" \
  "$(printf '%s' "$pf" | jq -r '[.toolchain.known_broken[]?.symptom] | join(" / ")')" "[ERROR] Could not detect twig set."
assert_eq "... and nothing claims a match with a known-good set" "$(printf '%s' "$pf" | jq -c '[.toolchain.known_good, .toolchain.match]')" '[{},false]'
t_done
