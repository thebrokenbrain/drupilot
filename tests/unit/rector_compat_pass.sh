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
# change FILE RULE -> Rector's JSON report of one changed file (exit 2 on a dry-run).
change() {
  printf '{"totals":{"changed_files":1,"errors":0},"file_diffs":[{"file":"web/modules/custom/legacy_widgets/%s","diff":"@@ @@\\n-a\\n+b\\n","applied_rectors":["Rector\\\\Stub\\\\%s"]}],"changed_files":["web/modules/custom/legacy_widgets/%s"]}\n' "$1" "$2" "$1"
  if [ "$dry" = 1 ]; then exit 2; fi
  exit 0
}
done_() { echo '{"totals":{"changed_files":0,"errors":0}}'; exit 0; }
case "$cfg" in
  compat)
    case "$m" in *" compat-crash "*) echo '{"fatal_errors":["boom"]}'; exit 1;; *" compat-noop "*) done_;; esac
    case "$m" in *" compat-noop-apply "*) [ "$dry" = 1 ] || done_;; esac
    change src/WidgetLookup.php ExplicitNullableParamTypeRector;;
  digests)
    case "$m" in *" digests-overlap "*) [ "$dry" = 1 ] && change src/WidgetLookup.php SomeDigestsRector;; esac;;
  *)
    case "$m" in *" official-changes "*) change src/Form/WidgetImportForm.php FunctionFirstClassCallableRector;;
      *" official-lookup "*) change src/WidgetLookup.php FunctionFirstClassCallableRector;;
      *" official-dry-only "*) [ "$dry" = 1 ] && change src/Form/WidgetImportForm.php FunctionFirstClassCallableRector;; esac;;
esac
done_
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

# A test-bed shared by two modules: the untouched rector-compat.php follows the
# subject (it named the previous one, whose path may be gone).
O=web/modules/custom/other_mod; mkdir -p "$r/$O/src"
printf 'name: Other\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$r/$O/other_mod.info.yml"
printf '<?php\n' > "$r/$O/src/Other.php"
ro() { printf '%s' "$1" > "$r/mode"; : > "$r/calls"
  t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$r/$2" --json; }
ro ok "$O"
assert_eq "another subject on the same root: rector-compat.php regenerated for it, after a backup" \
  "$T_RC|$(grep -c "'$O'," "$r/rector-compat.php")|$(grep -c "'$S'," "$r/rector-compat.php")|$(grep -l "'$S'," "$r"/.drupilot/backups/rector-compat.php.* 2> /dev/null | xargs grep -l 'drupilot-template-version: 1' | grep -c . || true)" \
  "0|1|0|1"
assert_match "... with a warning" "$(tr '\n' ' ' < "$T_ERR")" 'rector-compat\.php was an untouched drupilot render for another subject; regenerated'
ro ok "$S"
assert_eq "... and back again" "$T_RC|$(grep -c "'$S'," "$r/rector-compat.php")" "0|1"
# A render whose sha256 the lock lost (written by drupilot before it kept one:
# rector_config_pristine) follows the subject too.
LF="$(lock_path "$r")"
jq 'del(.templates["rector-compat.php"])' "$LF" > "$T_TMP/lock.json" && cp "$T_TMP/lock.json" "$LF"
ro ok "$O"
assert_eq "an untouched render with no sha256 in the lock: regenerated for the subject" \
  "$T_RC|$(grep -c "'$O'," "$r/rector-compat.php")|$(jq -r '.templates["rector-compat.php"].sha256 // "none"' "$LF" | grep -c '^sha256:' || true)" "0|1|1"
ro ok "$S"
# A hand-edited copy is kept; a withPaths() path that is gone is named.
sed_inplace "$r/rector-compat.php" "s#'$S',#'web/modules/custom/gone',#"
printf '\n// hand edit\n' >> "$r/rector-compat.php"; cp "$r/rector-compat.php" "$T_TMP/compat-gone.php"
ro ok "$S"
assert_file_eq "a hand-edited rector-compat.php is left alone" "$r/rector-compat.php" "$T_TMP/compat-gone.php"
assert_match "... with a warning naming the path that is gone, and the re-render" "$(tr '\n' ' ' < "$T_ERR")" \
  "names a path that does not exist in withPaths\\(\\): web/modules/custom/gone\\. .*--only rector-compat --force"
sed_inplace "$r/rector-compat.php" "s#'web/modules/custom/gone',#'$O',#"
ro ok "$S"
assert_eq "  naming another module that exists: no warning" "$(grep -c 'names a path that does not exist' "$T_ERR" || true)" "0"
# The developer's own file: one line, a parent directory, no trailing comma.
printf "<?php\nreturn Rector\\Config\\RectorConfig::configure()->withPaths(['web/modules/custom'])->withSkip(['web/nope']);\n" > "$r/rector-compat.php"
ro ok "$S"
assert_eq "  the developer's own one-line withPaths(): no warning (withSkip is not read)" "$(grep -c 'names a path that does not exist' "$T_ERR" || true)" "0"
printf "<?php\nreturn Rector\\Config\\RectorConfig::configure()->withPaths(['web/nope', __DIR__ . '/x']);\n" > "$r/rector-compat.php"
ro ok "$S"
assert_match "  ... one that is gone: warned, told to fix it" "$(tr '\n' ' ' < "$T_ERR")" 'withPaths\(\): web/nope\. .*Fix its withPaths\(\)'
rm -f "$r/rector-compat.php"

# config_backup: a second backup within the same second gets a numbered name.
DS="$T_TMP/datestub"; mkdir -p "$DS"; printf '#!/bin/sh\necho 20260101T000000Z\n' > "$DS/date"; chmod +x "$DS/date"
printf 'a\n' > "$T_TMP/cfg.php"; b1="$(PATH="$DS:$PATH" config_backup "$r" "$T_TMP/cfg.php")"
printf 'b\n' > "$T_TMP/cfg.php"; b2="$(PATH="$DS:$PATH" config_backup "$r" "$T_TMP/cfg.php")"
assert_eq "config_backup: two backups in one second keep both copies" \
  "$(basename "$b1")|$(basename "$b2")|$(cat "$b1")|$(cat "$b2")" "cfg.php.20260101T000000Z|cfg.php.20260101T000000Z.1|a|b"
assert_eq "  a missing file: return 1" "$(config_backup "$r" "$T_TMP/none.php" > /dev/null; echo $?)" "1"
# Both scripts name their backups through it.
REALDATE="$(command -v date)"
printf '#!/bin/sh\nif [ "$1" = "-u" ] && [ "$2" = "+%%Y%%m%%dT%%H%%M%%SZ" ]; then echo 20260101T000000Z; exit 0; fi\nexec %s "$@"\n' "$REALDATE" > "$DS/date"
ros() { printf 'ok' > "$r/mode"; : > "$r/calls"
  t_run env PATH="$DS:$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$r/$1" --json; }
nbk() { find "$r/.drupilot/backups" -name "$1.20260101T000000Z*" | grep -c . || true; }
ros "$S"; ros "$O"; ros "$S"
assert_eq "run-rector.sh: two regenerations in one second keep both backups of each config" \
  "$T_RC|$(nbk rector.php)|$(nbk rector-compat.php)" "0|2|2"
for i in 1 2; do
  printf '\n// hand edit %s\n' "$i" >> "$r/rector-compat.php"
  t_run env PATH="$DS:$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/env/render-templates.sh" --root "$r" --subject "$r/$S" --only rector-compat --force
done
assert_eq "render-templates.sh --force twice in that second: two more backups" "$T_RC|$(nbk rector-compat.php)" "0|4"

# rector_config_missing_paths: the relative literal paths of withPaths([...]) that are gone.
mp() { printf '%s\n' "$1" > "$T_TMP/mp.php"; rector_config_missing_paths "$r" "$T_TMP/mp.php" | tr '\n' ' '; }
assert_eq "missing paths: none in a list naming the subject" "$(mp "->withPaths([
    '$S',
  ])")" ""
assert_eq "  a gone path" "$(mp "->withPaths([
    'web/gone',
    '$S',
  ])")" "web/gone "
assert_eq "  a commented-out entry, an inline comment, a trailing comment: ignored" "$(mp "->withPaths([
    // 'web/old',
    # 'web/old2',
    /* 'web/old3' */ '$S', // was 'web/old4'
  ])")" ""
assert_eq "  a wildcard, an absolute (container) path and a __DIR__ path: not checked" \
  "$(mp "->withPaths(['web/modules/custom/*', '/var/www/html/web/x', __DIR__ . '/web/gone', __DIR__.\"/web/gone2\"])")" ""
assert_eq "  mixed quotes on one line" "$(mp "->withPaths([\"web/gone\", '$S'])")" "web/gone "
assert_eq "  the list ends at its ]: a withSkip after ], ) is not read" "$(mp "->withPaths([
    '$S',
  ], )
  ->withSkip(['web/nope'])")" ""
assert_eq "  a docblock example is not the list" "$(mp "/**
 * Like ->withPaths(['web/example']).
 */
return RectorConfig::configure()->withPaths(['web/gone']);")" "web/gone "
assert_eq "  comments over several lines, without a space before them, and # comments" "$(mp "->withPaths([
    /*
      'web/old',
    */
    '$S',// 'web/old2'
    '$S', # 'web/old3'
    /* old */ 'web/gone',
  ])")" "web/gone "
assert_eq "  a variable in the list is not checked and does not end it" "$(mp "->withPaths([ \$paths['custom'], 'web/gone', ])")" "web/gone "
assert_eq "  a missing file: nothing, exit 0" "$(rector_config_missing_paths "$r" "$T_TMP/none.php"; echo "rc=$?")" "rc=0"

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
nb81() { grep -l 'PHP_81' "$r"/.drupilot/backups/rector.php.* 2> /dev/null | grep -c . || true; }
nb_before="$(nb81)"
rr ok DRUPILOT_PHP_TARGET=8.3 DRUPILOT_CORE_TARGET_STRATEGY=d11-only
assert_eq "floor 8.1 -> 8.3: rector.php regenerated" \
  "$T_RC|$(j '.php_floor')|$(grep -c 'PhpVersion::PHP_83' "$r/rector.php")" '0|"8.3"|1'
assert_eq "... the 8.1 copy backed up" "$(( $(nb81) - nb_before ))" "1"
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
