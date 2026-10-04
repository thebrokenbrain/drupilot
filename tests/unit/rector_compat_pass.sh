#!/usr/bin/env bash
# ADR 0002 / T-M2-13: run-rector.sh runs the narrow compat pass
# (`--config rector-compat.php`) right after the official pass when the PHP
# floor L is below 8.4 and the window reaches 8.4, reports it on its own
# (compat_status, compat_files, rule_hits.compat), treats its crash like an
# official-pass crash, holds its --apply to its dry-run, and keeps rector.php
# at the floor of the declared range. Docker-free: stub php/composer and a stub
# vendor/bin/rector that logs its arguments.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
mk_bin() { printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
STUBS="$T_TMP/stubs"; mkdir -p "$STUBS"
mk_bin "$STUBS/php" 'case "$1" in -r) echo 8.3.30;; -v) echo "PHP 8.3.30 (cli)";; -l) echo "No syntax errors detected in $2";; esac; exit 0'
mk_bin "$STUBS/composer" 'echo "Composer version 2.8.0 2025-01-01 00:00:00"; exit 0'

mkroot() {
  mkdir -p "$1/web/core/lib" "$1/web/modules/custom" "$1/vendor/bin"
  printf '{"name":"x/root"}\n' > "$1/composer.json"
  printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$1/web/core/lib/Drupal.php"
  cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$1/web/modules/custom/"
  # The stub plays the outcome named in <root>/mode; the compat pass reports
  # one implicit nullable fixed.
  mk_bin "$1/vendor/bin/rector" 'd="$(cd "$(dirname "$0")/../.." && pwd)"; echo "$*" >> "$d/calls"
m="$(cat "$d/mode" 2>/dev/null)"; dry=0; compat=0
for a in "$@"; do case "$a" in --dry-run) dry=1;; rector-compat.php) compat=1;; esac; done
if [ "$compat" = 1 ]; then
  case "$m" in compat-crash) echo " [ERROR] Could not process: boom"; exit 1;; compat-noop) echo " [OK] Rector is done!"; exit 0;; esac
  printf "1 file with changes\n===================\n\n1) web/modules/custom/legacy_widgets/src/WidgetLookup.php:10\n\n"
  printf "    ---------- begin diff ----------\n@@ @@\n-  function f(Foo \\$x = NULL) {}\n+  function f(?Foo \\$x = NULL) {}\n    ----------- end diff -----------\n\n"
  printf "Applied rules:\n * ExplicitNullableParamTypeRector\n\n\n"
  if [ "$dry" = 1 ]; then echo " [OK] 1 file would have been changed (dry-run) by Rector"; exit 2; fi
  echo " [OK] 1 file has been changed by Rector"; exit 0
fi
echo " [OK] Rector is done!"; exit 0'
}
r="$T_TMP/root"; mkroot "$r"
S=web/modules/custom/legacy_widgets
rr() { local m="$1"; shift; printf '%s' "$m" > "$r/mode"; : > "$r/calls"
  t_run env PATH="$STUBS:$PATH" "$@" "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$r/$S" --json; }
j() { jq -c "$1" "$T_OUT" 2> /dev/null; }
calls_with() { grep -c -- "$1" "$r/calls" || true; }

rr ok DRUPILOT_PHP_TARGET=8.3
assert_eq "dry-run: exit 0, ok, compat ok" "$T_RC|$(j '[.status, .ok, .compat_status, .php_floor]')" '0|["ok",true,"ok","8.1"]'
assert_eq "... compat_files and files" "$(j '[.compat_files, .files]')" \
  "[[\"$S/src/WidgetLookup.php\"],[\"$S/src/WidgetLookup.php\"]]"
assert_eq "... its own rule_hits key" "$(j '.rule_hits')" '{"official":{},"compat":{"ExplicitNullableParamTypeRector":1}}'
assert_eq "... in rules too" "$(j '.rules')" '["ExplicitNullableParamTypeRector"]'
assert_eq "... the compat pass runs once, as a dry-run, with its own config" \
  "$(calls_with 'rector-compat.php')|$(grep 'rector-compat.php' "$r/calls" | grep -c -- '--dry-run' || true)|$(grep -c . "$r/calls")" "1|1|2"
assert_eq "... after the official pass" "$(head -n1 "$r/calls" | grep -c 'rector-compat' || true)" "0"
assert_eq "rector.php and rector-compat.php are rendered at the root" \
  "$(grep -c 'PhpVersion::PHP_81' "$r/rector.php")|$(grep -c 'Php84.*ExplicitNullableParamTypeRector' "$r/rector-compat.php")" "1|1"

rr ok DRUPILOT_PHP_TARGET=8.3
printf 'ok' > "$r/mode"; : > "$r/calls"
t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$r/$S" --apply --json
assert_eq "--apply: ok, the compat file changed" "$T_RC|$(j '[.status, .applied, .compat_status, (.compat_files | length)]')" '0|["ok",true,"ok",1]'

# The dry-run announced a compat change; an --apply that changes nothing is an error.
rr ok DRUPILOT_PHP_TARGET=8.3
printf 'compat-noop' > "$r/mode"; : > "$r/calls"
t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$r/$S" --apply --json
assert_eq "--apply that skips the announced compat change: error, exit 3" \
  "$T_RC|$(j '[.status, .ok, .compat_status, [.errors[].pass]]')" '3|["error",false,"error",[3]]'

rr compat-crash DRUPILOT_PHP_TARGET=8.3
assert_eq "a compat crash: error, exit 3, digests never reached" \
  "$T_RC|$(j '[.status, .ok, .compat_status, [.errors[].pass], .digests_status]')" '3|["error",false,"error",[3],"off"]'

# L >= 8.4: no compat pass.
r84="$T_TMP/root84"; mkroot "$r84"
jq '.require.php = ">=8.4"' "$r84/$S/composer.json" > "$T_TMP/c.json" && cp "$T_TMP/c.json" "$r84/$S/composer.json"
r_save="$r"; r="$r84"
rr ok DRUPILOT_PHP_TARGET=8.4 DRUPILOT_CORE_TARGET_STRATEGY=d11-only
assert_eq "L 8.4: compat off, never run, never rendered" \
  "$T_RC|$(j '[.compat_status, .php_floor]')|$(calls_with 'rector-compat.php')|$([[ -e "$r/rector-compat.php" ]] && echo yes || echo no)" \
  '0|["off","8.4"]|0|no'
r="$r_save"

# The core target moved to ^11 after rector.php was rendered at 8.1: the
# untouched render is regenerated at the new floor, after a backup.
rr ok DRUPILOT_PHP_TARGET=8.3 DRUPILOT_CORE_TARGET_STRATEGY=d11-only
assert_eq "floor 8.1 -> 8.3: rector.php regenerated" \
  "$T_RC|$(j '.php_floor')|$(grep -c 'PhpVersion::PHP_83' "$r/rector.php")" '0|"8.3"|1'
assert_eq "... the 8.1 copy backed up" "$(grep -l 'PHP_81' "$r"/.drupilot/backups/rector.php.* 2> /dev/null | grep -c . || true)" "1"
# A hand-edited rector.php at another floor is left alone, with a warning.
printf '\n// hand edit\n' >> "$r/rector.php"; cp "$r/rector.php" "$T_TMP/edited.php"
rr ok DRUPILOT_PHP_TARGET=8.3
assert_file_eq "hand-edited rector.php at 8.3 while the floor is 8.1: untouched" "$r/rector.php" "$T_TMP/edited.php"
assert_match "... with a warning naming both floors" "$(tr '\n' ' ' < "$T_ERR")" 'PHP 8\.3 .*floor .*8\.1'
# A rector.php of the developer's own without withPhpVersion(): a warning.
printf '<?php\nuse Rector\\Config\\RectorConfig;\nreturn RectorConfig::configure()->withSkip([\x27ArrayToFirstClassCallableRector\x27]);\n' > "$r/rector.php"
rr ok DRUPILOT_PHP_TARGET=8.3
assert_match "own rector.php without withPhpVersion: warned" "$(tr '\n' ' ' < "$T_ERR")" 'withPhpVersion'
t_done
