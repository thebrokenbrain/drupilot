#!/usr/bin/env bash
# DRUPILOT_LENIENT_DEPS (T-M4-17, AR-08, AR-28, CC-14): off by default; a
# list of drupal/<project> packages makes install-toolchain.sh install
# mglaman/composer-drupal-lenient and allow-list them, on a test-bed drupilot
# built only (a warning skips the developer's own project); a bad value is a
# usage error. lenient_packages reads the list in effect from the bed's
# composer.json, and a test record carries it as lenient[] while the
# preservation enum stays the 0.9 one. Docker-free: install-toolchain.sh
# --dry-run, and run-phpunit.sh with stub docker/ddev whose bed has no PHPUnit
# (the not-verified-blocked record).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
IT="$T_REPO/scripts/env/install-toolchain.sh"

mkroot() {
  mkdir -p "$1/web/core/lib" "$1/web/modules/custom" "$1/.ddev"
  printf '{"name": "lab/root"}\n' > "$1/composer.json"
  jq -n '{packages: [{name: "drupal/core", version: "11.4.8"}], "packages-dev": []}' > "$1/composer.lock"
  printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$1/web/core/lib/Drupal.php"
  printf 'name: dpl-x\ntype: drupal11\ndocroot: web\n' > "$1/.ddev/config.yaml"
}
# dry ROOT [ENV...] -> install-toolchain.sh --dry-run --json; STDERR in $T_TMP/err, exit code in $T_TMP/rc.
dry() {
  local root="$1" rc=0; shift
  env "$@" CLAUDE_PLUGIN_ROOT="$T_REPO" "$T_SH" "$IT" --dir "$root" --dry-run --json --no-core-dev 2> "$T_TMP/err" || rc=$?
  printf '%s' "$rc" > "$T_TMP/rc"
}
pkgs() { jq -r '[.packages[].name] | join(" ")'; }

BED="$T_TMP/m-d11"; mkroot "$BED"; testbed_mark "$BED" ddev-up.sh
OWN="$T_TMP/site"; mkroot "$OWN"

out="$(dry "$BED")"
assert_eq "off by default: no lenient package, lenient []" \
  "$(cat "$T_TMP/rc")|$(printf '%s' "$out" | jq -c .lenient)|$(printf '%s' "$out" | pkgs | grep -c lenient || true)" "0|[]|0"
out="$(dry "$BED" DRUPILOT_LENIENT_DEPS='drupal/token, drupal/ctools')"
assert_eq "a list on a test-bed: lenient set (sorted)" "$(cat "$T_TMP/rc")|$(printf '%s' "$out" | jq -c .lenient)" '0|["drupal/ctools","drupal/token"]'
assert_eq "  composer-drupal-lenient is installed with the toolchain, from its range" \
  "$(printf '%s' "$out" | jq -r '.packages[] | select(.name == "mglaman/composer-drupal-lenient") | "\(.spec) \(.source)"')" \
  "mglaman/composer-drupal-lenient:^2.0 range"
assert_match "  the plugin is allowed and the list merged into extra" "$(tr '\n' ' ' < "$T_TMP/err")" \
  'allow-plugins\.mglaman/composer-drupal-lenient true.*extra\.drupal-lenient\.allowed-list .\["drupal/ctools","drupal/token"\]'
out="$(dry "$OWN" DRUPILOT_LENIENT_DEPS=drupal/token)"
assert_eq "the developer's own project: skipped, lenient []" \
  "$(cat "$T_TMP/rc")|$(printf '%s' "$out" | jq -c .lenient)|$(printf '%s' "$out" | pkgs | grep -c lenient || true)" "0|[]|0"
assert_match "  with a warning" "$(cat "$T_TMP/err")" 'DRUPILOT_LENIENT_DEPS applies only to a test-bed drupilot built'
dry "$BED" DRUPILOT_LENIENT_DEPS='token' > /dev/null
assert_eq "not a drupal/<project> package: usage error" "$(cat "$T_TMP/rc")" "1"
dry "$BED" DRUPILOT_LENIENT_DEPS='drupal/token;rm' > /dev/null
assert_eq "  nor anything else in it" "$(cat "$T_TMP/rc")" "1"

# lenient_packages: what the bed's composer.json has in effect.
L="$T_TMP/l"; mkdir -p "$L"
assert_eq "lenient_packages: no composer.json" "$(lenient_packages "$L")" "[]"
printf '{"extra":{"drupal-lenient":{"allowed-list":["drupal/token","drupal/ctools","drupal/token"]}}}\n' > "$L/composer.json"
assert_eq "  the allowed list, sorted and unique" "$(lenient_packages "$L")" '["drupal/ctools","drupal/token"]'
printf '{"extra":{"drupal-lenient":{"allow-all":true}}}\n' > "$L/composer.json"
assert_eq "  allow-all" "$(lenient_packages "$L")" '["*"]'
printf '{"extra":{"drupal-lenient":"x"}}\n' > "$L/composer.json"
assert_eq "  a malformed entry" "$(lenient_packages "$L")" "[]"

# A test record carries lenient[]; the preservation enum is unchanged.
STUBS="$T_TMP/bin"; mkdir -p "$STUBS"
printf '#!/bin/sh\ncase "$1" in --version|version) echo "Docker version 29.0.0, build x";; esac\nexit 0\n' > "$STUBS/docker"
printf '#!/bin/sh\ncase "$1" in\n  --version|version) echo "ddev version v1.25.4";;\n  describe) echo "{\\"raw\\":{\\"status\\":\\"running\\"}}";;\n  exec) exit 1;;\nesac\nexit 0\n' > "$STUBS/ddev"
chmod +x "$STUBS/docker" "$STUBS/ddev"
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$BED/web/modules/custom/"
jq '. + {extra: {"drupal-lenient": {"allowed-list": ["drupal/token"]}}}' "$BED/composer.json" > "$T_TMP/c.json" && mv "$T_TMP/c.json" "$BED/composer.json"
( cd "$BED" && env PATH="$STUBS:$PATH" CLAUDE_PLUGIN_ROOT="$T_REPO" "$T_SH" "$T_REPO/scripts/tests/run-phpunit.sh" \
    --subject web/modules/custom/legacy_widgets --type unit > /dev/null 2>&1 ); rc=$?
LT="$(project_state_path "$BED/web/modules/custom/legacy_widgets")/last-test.json"
assert_eq "run-phpunit.sh on a bed without PHPUnit: blocked (exit 2), recorded" \
  "$rc|$(jq -r .preservation "$LT" 2> /dev/null)" "2|not-verified-blocked"
assert_eq "  the record names the lenient dependency" "$(jq -c .lenient "$LT" 2> /dev/null)" '["drupal/token"]'
assert_eq "the preservation enum is the frozen one (CC-14): no lenient value" \
  "$(jq -c '.properties.preservation.enum | sort' "$T_REPO/schemas/last-test.schema.json")" \
  "$(jq -c '.preservation | sort' "$T_REPO/tests/contract/enums.json")"
assert_eq "  and run-phpunit.sh assigns no other" \
  "$(grep -oE 'PRESERVATION="[a-z-]+"' "$T_REPO/scripts/tests/run-phpunit.sh" | sed 's/.*="//; s/"$//' | sort -u | jq -R . | jq -sc 'sort')" \
  "$(jq -c '.preservation | sort' "$T_REPO/tests/contract/enums.json")"
t_done
