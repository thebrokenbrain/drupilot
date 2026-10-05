#!/usr/bin/env bash
# ADR 0002 / T-M2-13: run-rector.sh runs the narrow compat pass
# (`--config rector-compat.php`) right after the official pass when the PHP
# floor L is below 8.4 and the window reaches 8.4, reports it on its own
# (compat_status, compat_files, rule_hits.compat), treats its crash like an
# official-pass crash (but keeps the record of what the official pass
# applied), holds its --apply to its dry-run, and keeps rector.php at the floor
# of the declared range. Docker-free: stub php/composer and a stub
# vendor/bin/rector that logs its arguments; synthetic version data. The
# rule record keeps its time and subject under "meta" (AR-13).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
D="$T_TMP/data"; mkdir -p "$D/targets" "$D/php"
printf '%s\n' '{"major":10,"minors":{"10.0":{"verified":true,"php_supported":["8.1","8.2","8.3"]}}}' > "$D/targets/10.json"
printf '%s\n' '{"major":11,"minors":{"11.0":{"verified":true,"php_supported":["8.3"]},"11.3":{"verified":true,"php_supported":["8.3","8.4","8.5"]}}}' > "$D/targets/11.json"
printf '%s\n' '{"versions":{"7.4":{},"8.0":{},"8.1":{},"8.2":{},"8.3":{},"8.4":{},"8.5":{}}}' > "$D/php/versions.json"
export DRUPILOT_VERSION_DATA_DIR="$D"

mk_bin() { printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
STUBS="$T_TMP/stubs"; mkdir -p "$STUBS"
mk_bin "$STUBS/php" 'case "$1" in -r) echo 8.3.30;; -v) echo "PHP 8.3.30 (cli)";; -l) echo "No syntax errors detected in $2";; esac; exit 0'
mk_bin "$STUBS/composer" 'echo "Composer version 2.8.0 2025-01-01 00:00:00"; exit 0'
: > "$T_TMP/digests.php"

# The stub Rector plays the outcomes named in <root>/mode (words): the compat
# pass fixes one implicit nullable unless compat-crash / compat-noop;
# official-changes makes the official pass change a file; digests-overlap
# makes the digests dry-run announce the compat pass's file.
mkroot() {
  mkdir -p "$1/web/core/lib" "$1/web/modules/custom" "$1/vendor/bin"
  printf '{"name":"x/root"}\n' > "$1/composer.json"
  printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$1/web/core/lib/Drupal.php"
  cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$1/web/modules/custom/"
  cat > "$1/vendor/bin/rector" <<'STUB'
#!/bin/sh
d="$(cd "$(dirname "$0")/../.." && pwd)"; echo "$*" >> "$d/calls"
m=" $(cat "$d/mode" 2>/dev/null) "; dry=0; cfg=official
for a in "$@"; do case "$a" in --dry-run) dry=1;; rector-compat.php) cfg=compat;; *digests.php) cfg=digests;; esac; done
change() {
  printf '1 file with changes\n===================\n\n1) web/modules/custom/legacy_widgets/%s:10\n\n' "$1"
  printf '    ---------- begin diff ----------\n@@ @@\n-a\n+b\n    ----------- end diff -----------\n\n'
  printf 'Applied rules:\n * %s\n\n\n' "$2"
  if [ "$dry" = 1 ]; then echo " [OK] 1 file would have been changed (dry-run) by Rector"; exit 2; fi
  echo " [OK] 1 file has been changed by Rector"; exit 0
}
case "$cfg" in
  compat)
    case "$m" in *" compat-crash "*) echo " [ERROR] Could not process: boom"; exit 1;; *" compat-noop "*) echo " [OK] Rector is done!"; exit 0;; esac
    case "$m" in *" compat-noop-apply "*) [ "$dry" = 1 ] || { echo " [OK] Rector is done!"; exit 0; };; esac
    change src/WidgetLookup.php ExplicitNullableParamTypeRector;;
  digests)
    case "$m" in *" digests-overlap "*) [ "$dry" = 1 ] && change src/WidgetLookup.php SomeDigestsRector;; esac;;
  *)
    case "$m" in *" official-changes "*) change src/Form/WidgetImportForm.php FunctionFirstClassCallableRector;;
      *" official-lookup "*) change src/WidgetLookup.php FunctionFirstClassCallableRector;;
      *" official-dry-only "*) [ "$dry" = 1 ] && change src/Form/WidgetImportForm.php FunctionFirstClassCallableRector;; esac;;
esac
echo " [OK] Rector is done!"; exit 0
STUB
  chmod +x "$1/vendor/bin/rector"
}
r="$T_TMP/root"; mkroot "$r"
S=web/modules/custom/legacy_widgets
rr() { local m="$1"; shift; printf '%s' "$m" > "$r/mode"; : > "$r/calls"
  t_run env PATH="$STUBS:$PATH" "$@" "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$r/$S" --json; }
ra() { local m="$1"; shift; printf '%s' "$m" > "$r/mode"; : > "$r/calls"
  t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$r/$S" --json "$@"; }
j() { jq -c "$1" "$T_OUT" 2> /dev/null; }
calls_with() { grep -c -- "$1" "$r/calls" || true; }
compat_dry_calls() { grep 'rector-compat.php' "$r/calls" | grep -c -- '--dry-run' || true; }

rr ok DRUPILOT_PHP_TARGET=8.3
assert_eq "dry-run: exit 0, ok, compat ok" "$T_RC|$(j '[.status, .ok, .compat_status, .php_floor, .php_ceiling]')" '0|["ok",true,"ok","8.1","8.5"]'
assert_eq "... compat_files and files" "$(j '[.compat_files, .files]')" \
  "[[\"$S/src/WidgetLookup.php\"],[\"$S/src/WidgetLookup.php\"]]"
assert_eq "... its own rule_hits key" "$(j '.rule_hits')" '{"official":{},"compat":{"ExplicitNullableParamTypeRector":1}}'
assert_eq "... in rules too" "$(j '.rules')" '["ExplicitNullableParamTypeRector"]'
assert_eq "... the compat pass runs once, as a dry-run, with its own config" \
  "$(calls_with 'rector-compat.php')|$(compat_dry_calls)|$(grep -c . "$r/calls")" "1|1|2"
assert_eq "... after the official pass" "$(head -n1 "$r/calls" | grep -c 'rector-compat' || true)" "0"
assert_eq "rector.php and rector-compat.php are rendered at the root" \
  "$(grep -c 'PhpVersion::PHP_81' "$r/rector.php")|$(grep -c 'Php84.*ExplicitNullableParamTypeRector' "$r/rector-compat.php")" "1|1"

ra ok --apply
assert_eq "--apply: ok, the compat file changed" "$T_RC|$(j '[.status, .applied, .compat_status, (.compat_files | length)]')" '0|["ok",true,"ok",1]'
assert_eq "... the compat pass really applies (no --dry-run)" "$(calls_with 'rector-compat.php')|$(compat_dry_calls)" "1|0"

# The dry-run announced a compat change; an --apply that changes nothing is an error.
ra ok
ra compat-noop --apply
assert_eq "--apply that skips the announced compat change: error, exit 3" \
  "$T_RC|$(j '[.status, .ok, .compat_status, [.errors[].pass]]')" '3|["error",false,"error",[3]]'

# The official pass changes the compat pass's file too: on --apply the compat
# pass may find nothing left, which is no error.
ra 'official-lookup compat-noop-apply'
ra 'official-lookup compat-noop-apply' --apply
assert_eq "compat after an official change to the same file: no false error" "$T_RC|$(j '[.status, .compat_status]')" '0|["ok","ok"]'
# A rector-compat.php edited after the dry-run voids its record: no check.
ra ok
printf '\n// edited after the dry-run\n' >> "$r/rector-compat.php"
ra compat-noop --apply
assert_eq "an edited rector-compat.php voids the dry-run record" "$T_RC|$(j '[.status, .compat_status]')" '0|["ok","ok"]'
sed_inplace "$r/rector-compat.php" '/edited after the dry-run/d'

# A compat crash: an error; the digests pass after it never runs.
ra compat-crash --config "$T_TMP/digests.php"
assert_eq "a compat crash: error, exit 3, digests skipped" \
  "$T_RC|$(j '[.status, .ok, .compat_status, [.errors[].pass], .digests_status]')|$(calls_with 'digests.php')" \
  '3|["error",false,"error",[3],"skipped"]|0'
# ... but what the official pass applied before it is still recorded.
RULES_REC="$(rector_rules_file "$r/$S")"
rm -f "$RULES_REC"
ra 'official-changes compat-crash' --apply
assert_eq "a compat crash on --apply keeps the official pass's rule record" \
  "$T_RC|$(jq -c '.rule_hits.official' "$RULES_REC" 2> /dev/null)" '3|{"FunctionFirstClassCallableRector":1}'
assert_eq "... its time and subject only under meta (AR-13)" \
  "$(jq -c '[(del(.meta) | [.. | strings | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))] | length), has("generated_at"), has("subject"),
     (.meta.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")), (.meta.subject | type)]' "$RULES_REC" 2> /dev/null)" \
  '[0,false,false,true,"string"]'

# Pass 1 announced a change its --apply did not make: nothing was ported, so
# no rule record is written, whatever the compat pass changed.
rm -f "$RULES_REC"
ra official-dry-only
ra official-dry-only --apply
assert_eq "pass 1 skipped its announced change: error, exit 3, no rule record" \
  "$T_RC|$(j '[.status, [.errors[].pass]]')|$([[ -e "$RULES_REC" ]] && echo yes || echo no)" '3|["error",[1]]|no'

# Digests after compat: its dry-run announced the file the compat pass changes;
# the apply leaves it alone, which is no error.
ra digests-overlap --config "$T_TMP/digests.php"
ra digests-overlap --config "$T_TMP/digests.php" --apply
assert_eq "digests overlapping the compat pass: no false partial" \
  "$T_RC|$(j '[.status, .compat_status, .digests_status]')" '0|["ok","ok","ok"]'

# rector-compat.php: an edited copy is kept; an older generation is regenerated.
printf '\n// hand edit\n' >> "$r/rector-compat.php"; cp "$r/rector-compat.php" "$T_TMP/compat-edited.php"
rr ok DRUPILOT_PHP_TARGET=8.3
assert_file_eq "a hand-edited rector-compat.php is left alone" "$r/rector-compat.php" "$T_TMP/compat-edited.php"
sed_inplace "$r/rector-compat.php" 's/drupilot-template-version: 1/drupilot-template-version: 0/'
rr ok DRUPILOT_PHP_TARGET=8.3
assert_eq "an older rector-compat.php is regenerated, after a backup" \
  "$(grep -c 'drupilot-template-version: 1' "$r/rector-compat.php")|$(grep -l 'drupilot-template-version: 0' "$r"/.drupilot/backups/rector-compat.php.* 2> /dev/null | grep -c . || true)" "1|1"

# L >= 8.4: no compat pass.
r84="$T_TMP/root84"; mkroot "$r84"
jq '.require.php = ">=8.4"' "$r84/$S/composer.json" > "$T_TMP/c.json" && cp "$T_TMP/c.json" "$r84/$S/composer.json"
r_save="$r"; r="$r84"
rr ok DRUPILOT_PHP_TARGET=8.4 DRUPILOT_CORE_TARGET_STRATEGY=d11-only
assert_eq "L 8.4: compat off, never run, never rendered" \
  "$T_RC|$(j '[.compat_status, .php_floor]')|$(calls_with 'rector-compat.php')|$([[ -e "$r/rector-compat.php" ]] && echo yes || echo no)" \
  '0|["off","8.4"]|0|no'
# L 8.5: PHP_85 with the php84 sets, a warning, no compat pass.
jq '.require.php = ">=8.5"' "$r84/$S/composer.json" > "$T_TMP/c.json" && cp "$T_TMP/c.json" "$r84/$S/composer.json"
rr ok DRUPILOT_PHP_TARGET=8.5 DRUPILOT_CORE_TARGET_STRATEGY=d11-only
assert_eq "L 8.5: PHP_85 with the php84 sets, compat off" \
  "$T_RC|$(j '[.php_floor, .compat_status]')|$(grep -c 'PhpVersion::PHP_85' "$r/rector.php")|$(grep -c 'withPhpSets(php84: true)' "$r/rector.php")" \
  '0|["8.5","off"]|1|1'
assert_match "... with the no-php85-set warning" "$(tr '\n' ' ' < "$T_ERR")" 'PHP floor 8\.5 .*no Rector php85 set is assumed'
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
assert_match "... with a warning naming both floors" "$(tr '\n' ' ' < "$T_ERR")" 'targets PHP 8\.3 .*floor .*is 8\.1'
assert_match "... and that it may emit code the floor cannot run" "$(tr '\n' ' ' < "$T_ERR")" 'may emit code PHP 8\.1 cannot run'
# A rector.php of the developer's own without withPhpVersion(): a warning.
printf '<?php\nuse Rector\\Config\\RectorConfig;\nreturn RectorConfig::configure()->withSkip([\x27ArrayToFirstClassCallableRector\x27]);\n' > "$r/rector.php"
rr ok DRUPILOT_PHP_TARGET=8.3
assert_match "own rector.php without withPhpVersion: warned" "$(tr '\n' ' ' < "$T_ERR")" 'Your own rector\.php has no withPhpVersion\(\)'
t_done
