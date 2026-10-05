#!/usr/bin/env bash
# The staged PHP runtime and its first helper (T-M4-04, AR-23, 05-R5):
# stage_runtime copies scripts/php/*.php into <root>/.drupilot/runtime/,
# verifies every copy by its sha256 (a tampered or missing one is staged again,
# a helper the plugin no longer ships is removed), keeps the set's hash in the
# root's lock as .runtime_hash and touches nothing when the copies are current.
# anchor.php gives each line of the tests/fixtures/anchor files its anchor
# (closures, arrow functions and anonymous classes transparent; traits, enums,
# interfaces, a by-reference method, braced namespaces, a mixed .module) with
# the PHP on PATH; the lab runs the same fixtures in the bed's container.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

R="$T_TMP/root"; mkdir -p "$R/web/core/lib"; printf '{"name":"x/root"}\n' > "$R/composer.json"
RT="$(stage_runtime "$R")"
assert_eq "stage_runtime: prints the path relative to the root" "$RT" ".drupilot/runtime"
n_src="$(find "$T_REPO/scripts/php" -name '*.php' | grep -c . || true)"
assert_eq "  every helper is staged" "$(find "$R/$RT" -name '*.php' | grep -c . || true)" "$n_src"
assert_eq "  byte for byte" "$(sha256_hex < "$R/$RT/anchor.php")" "$(sha256_hex < "$T_REPO/scripts/php/anchor.php")"
assert_match "  the set's hash is in the root's lock" "$(DRUPILOT_PROJECT_DIR="$R" lock_get .runtime_hash)" '^sha256:[0-9a-f]{64}$'
H1="$(DRUPILOT_PROJECT_DIR="$R" lock_get .runtime_hash)"
ino() { ls -i "$1" | awk '{ print $1 }'; }
i1="$(ino "$R/$RT/anchor.php")"
stage_runtime "$R" > /dev/null
assert_eq "  current copies are left alone" "$(ino "$R/$RT/anchor.php")|$(DRUPILOT_PROJECT_DIR="$R" lock_get .runtime_hash)" "$i1|$H1"
printf '<?php // tampered\n' >> "$R/$RT/anchor.php"
printf '<?php\n' > "$R/$RT/gone.php"
stage_runtime "$R" > /dev/null
assert_eq "  a tampered copy is staged again" "$(sha256_hex < "$R/$RT/anchor.php")" "$(sha256_hex < "$T_REPO/scripts/php/anchor.php")"
assert_eq "  a helper the plugin no longer ships is removed" "$([[ -e "$R/$RT/gone.php" ]] && echo kept || echo removed)" "removed"
assert_eq "  no temporary file is left" "$(find "$R/$RT" -name '.*' -type f | grep -c . || true)" "0"
assert_eq "  .drupilot/ is in drupilot's managed ignore block" "$(grep -cx '\.drupilot/' "$T_REPO/templates/gitignore.tmpl")" "1"
assert_eq "a missing root: exit 1" "$(stage_runtime "$T_TMP/nope" > /dev/null; echo $?)" "1"

# anchor.php on the fixtures.
FX="$T_REPO/tests/fixtures/anchor"
if command -v php > /dev/null 2>&1; then
  out="$(cd "$FX" && jq '[.[] | del(.anchor)]' requests.json | php "$R/$RT/anchor.php")"; rc=$?
  assert_eq "anchor.php: exit 0" "$rc" "0"
  assert_eq "  every fixture line has its expected anchor" \
    "$(jq -c --argjson o "$out" '[to_entries[] | select($o[.key].anchor != .value.anchor) | "\(.value.file):\(.value.line) got \($o[.key].anchor)"]' "$FX/requests.json")" "[]"
  assert_eq "  the input order and fields are kept" \
    "$(printf '%s' "$out" | jq -c '[.[] | [.file, .line]]')" "$(jq -c '[.[] | [.file, .line]]' "$FX/requests.json")"
  assert_eq "  STDIN that is not a JSON array: exit 1" "$(printf '{}' | php "$R/$RT/anchor.php" > /dev/null 2>&1; echo $?)" "1"
  assert_eq "  an empty array" "$(printf '[]' | php "$R/$RT/anchor.php")" "[]"
else
  printf '# no php on PATH: the anchor fixtures run in the lab bed only\n'
  assert_eq "the anchor fixtures are well-formed" "$(jq -e 'type == "array" and length > 0 and all(.[]; has("file") and has("line") and has("anchor"))' "$FX/requests.json")" "true"
fi
t_done
