#!/usr/bin/env bash
# Deterministic tool invocation (T-M4-03, 05-R2, DET-1, DET-2): run-rector.sh
# runs Rector with its JSON report (--output-format=json --no-progress-bar)
# and reads the changed files and rule hits from its file_diffs; the --json
# summaries of run-rector/phpstan/phpcs record the runner ({runner, php_version,
# tool_version}) and keep their 0.9 keys; PHPStan's and PHPCS's reports are
# sorted; a Rector JSON report with an error or a fatal error is a crash; and in
# deterministic mode a tool whose installed version is not the lock's, or a
# host run on a root that has a DDEV project, exits 3 (not with
# DRUPILOT_DETERMINISTIC=false). Docker-free: stub php, composer and tools.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
mk_bin() { printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
STUBS="$T_TMP/stubs"; mkdir -p "$STUBS"
mk_bin "$STUBS/php" 'case "$1" in -r) echo 8.3.30;; -v) echo "PHP 8.3.30 (cli)";; -l) echo "No syntax errors detected in $2";; esac; exit 0'
mk_bin "$STUBS/composer" 'echo "Composer version 2.8.0 2025-01-01 00:00:00"; exit 0'

r="$T_TMP/root"; S=web/modules/custom/legacy_widgets
mkdir -p "$r/web/core/lib" "$r/web/modules/custom" "$r/vendor/bin"
printf '{"name":"x/root"}\n' > "$r/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$r/web/core/lib/Drupal.php"
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$r/web/modules/custom/"
lockpkgs() {   # lockpkgs rector-version
  jq -n --arg v "$1" '{packages: [{name: "drupal/core", version: "11.4.8"}],
    "packages-dev": [{name: "rector/rector", version: $v}, {name: "palantirnet/drupal-rector", version: "1.1.3"},
      {name: "phpstan/phpstan", version: "2.2.16"}, {name: "drupal/coder", version: "8.3.31"}]}' > "$r/composer.lock"
}
lockpkgs 2.6.1
# Rector: the JSON report of two changed files (in reverse order), or what $r/mode says.
cat > "$r/vendor/bin/rector" <<'STUB'
#!/bin/sh
d="$(cd "$(dirname "$0")/../.." && pwd)"; echo "$*" >> "$d/calls"
m="$(cat "$d/mode" 2>/dev/null)"
case "$m" in
  fatal) echo '{"fatal_errors":["Class \"RectorConfig\" not found"]}'; exit 1;;
  file-error) echo '{"totals":{"changed_files":0,"errors":1},"errors":[{"message":"Syntax error","file":"web/modules/custom/legacy_widgets/src/Broken.php","line":2}]}'; exit 1;;
  not-json) echo 'PHP Fatal error: boom'; exit 255;;
esac
case " $* " in *" rector-compat.php "*) echo '{"totals":{"changed_files":0,"errors":0}}'; exit 0;; esac
cat <<'JSON'
{"totals":{"changed_files":2,"errors":0},"file_diffs":[
 {"file":"web/modules/custom/legacy_widgets/src/WidgetLookup.php","diff":"@@ -1 +1 @@\n-a\n+b\n","applied_rectors":["Rector\\Php81\\Rector\\FuncCall\\NullToStrictStringFuncCallArgRector"]},
 {"file":"web/modules/custom/legacy_widgets/src/Form/WidgetImportForm.php","diff":"@@ -2 +2 @@\n-c\n+d\n","applied_rectors":["Rector\\CodingStyle\\Rector\\FuncCall\\FunctionFirstClassCallableRector","Rector\\Php81\\Rector\\FuncCall\\NullToStrictStringFuncCallArgRector"]}],
 "changed_files":["web/modules/custom/legacy_widgets/src/Form/WidgetImportForm.php","web/modules/custom/legacy_widgets/src/WidgetLookup.php"]}
JSON
case " $* " in *" --dry-run "*) exit 2;; esac
exit 0
STUB
chmod +x "$r/vendor/bin/rector"
# PHPStan and PHPCS: unsorted JSON reports.
mk_bin "$r/vendor/bin/phpstan" 'echo "{\"totals\":{\"errors\":2,\"file_errors\":3},\"files\":{\"b.php\":{\"errors\":1,\"messages\":[{\"message\":\"z\",\"line\":9}]},\"a.php\":{\"errors\":2,\"messages\":[{\"message\":\"y\",\"line\":5,\"identifier\":\"b.id\"},{\"message\":\"x\",\"line\":5,\"identifier\":\"a.id\"}]}},\"errors\":[\"second\",\"first\"]}"; exit 1'
mk_bin "$r/vendor/bin/phpcs" 'case " $* " in *" -i "*) echo "The installed coding standards are Drupal and DrupalPractice"; exit 0;; esac; echo "{\"totals\":{\"errors\":2,\"warnings\":0,\"fixable\":0},\"files\":{\"z.php\":{\"errors\":1,\"warnings\":0,\"messages\":[{\"message\":\"m\",\"source\":\"S.b\",\"line\":3,\"column\":1}]},\"a.php\":{\"errors\":1,\"warnings\":0,\"messages\":[{\"message\":\"m2\",\"source\":\"S.a\",\"line\":7,\"column\":4},{\"message\":\"m1\",\"source\":\"S.a\",\"line\":7,\"column\":2}]}}}"; exit 2'
cp "$r/vendor/bin/phpcs" "$r/vendor/bin/phpcbf"

rr() { local m="$1"; shift; printf '%s' "$m" > "$r/mode"; : > "$r/calls"
  t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 DRUPILOT_USE_DIGESTS_RULES=false "$@" \
    "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$r/$S" --json; }
j() { jq -c "$1" "$T_OUT" 2> /dev/null; }

rr ok
assert_eq "run-rector: ok, exit 0" "$T_RC|$(j '[.status, .ok]')" '0|["ok",true]'
assert_eq "  Rector runs with its JSON report and no progress bar" \
  "$(sed -n '1p' "$r/calls" | grep -c -- '--clear-cache --no-progress-bar --output-format=json' || true)" "1"
assert_eq "  the changed files come from its file_diffs, sorted" "$(j '.files')" \
  "[\"$S/src/Form/WidgetImportForm.php\",\"$S/src/WidgetLookup.php\"]"
assert_eq "  rule hits: the applied_rectors' short names, once per file" "$(j '.rule_hits.official')" \
  '{"FunctionFirstClassCallableRector":1,"NullToStrictStringFuncCallArgRector":2}'
assert_eq "  rules" "$(j '.rules')" '["FunctionFirstClassCallableRector","NullToStrictStringFuncCallArgRector"]'
assert_eq "  file_diffs: pass, file, applied rules and diff, in Rector's order" \
  "$(j '[.file_diffs[] | [.pass, (.file | split("/") | last), (.applied_rectors | length), (.diff | test("^@@"))]]')" \
  '[["official","WidgetLookup.php",1,true],["official","WidgetImportForm.php",2,true]]'
assert_eq "  runner: host, the PHP that ran it, the installed rector/rector" "$(j '.runner')" \
  '{"runner":"host","php_version":"8.3.30","tool_version":"2.6.1"}'
assert_eq "  every 0.9 key is kept" \
  "$(j '[["tool","status","ok","errors","digests_status","digests_sha","applied","digests_pass","changed_files","files","pass1_files","compat_files","pass2_files","rules","rule_hits","compat_status","php_floor","php_ceiling"][] as $k | has($k)] | all')" "true"
assert_match "  a person still sees each diff and its rules on STDERR" "$(t_err | tr '\n' ' ')" \
  '2 file\(s\) with changes.*WidgetLookup\.php.*Applied rules: .* NullToStrictStringFuncCallArgRector'

rr fatal
assert_eq "a fatal error report: crash, exit 3, the reason kept" "$T_RC|$(j '[.status, .errors[0].message]')" \
  '3|["error","Class \"RectorConfig\" not found"]'
rr file-error
assert_eq "a file error in the report: crash, exit 3" "$T_RC|$(j '[.status, .errors[0].message]')" \
  "3|[\"error\",\"Syntax error ($S/src/Broken.php:2)\"]"
rr not-json
assert_eq "output that is not JSON: crash, exit 3" "$T_RC|$(j '.status')" '3|"error"'

# DET-1: a tool version the lock does not pin.
mkdir -p "$(project_state_path "$r")"
jq -n '{schema: 1, toolchain: {"rector/rector": "2.6.1", "phpstan/phpstan": "2.2.16", "drupal/coder": "8.3.31"}}' > "$(lock_path "$r")"
rr ok
assert_eq "DET-1: the pinned versions installed: exit 0" "$T_RC" "0"
lockpkgs 2.6.2
rr ok
assert_eq "DET-1: rector/rector 2.6.2 installed, the lock pins 2.6.1: exit 3, Rector never ran" \
  "$T_RC|$(grep -c . "$r/calls" || true)" "3|0"
assert_match "  the reason" "$(t_err)" 'DET-1: rector/rector installed 2.6.2, the lock pins 2.6.1'
rr ok DRUPILOT_DETERMINISTIC=false
assert_eq "  DRUPILOT_DETERMINISTIC=false runs it" "$T_RC" "0"
jq '.toolchain["rector/rector"] = "v2.6.2"' "$(lock_path "$r")" > "$T_TMP/l.json" && mv "$T_TMP/l.json" "$(lock_path "$r")"
rr ok
assert_eq "  a leading v in the lock is no mismatch" "$T_RC" "0"
lockpkgs 2.6.1; jq '.toolchain["rector/rector"] = "2.6.1"' "$(lock_path "$r")" > "$T_TMP/l.json" && mv "$T_TMP/l.json" "$(lock_path "$r")"

# DET-1: a host run on a root that has a DDEV project (DDEV cannot start).
mkdir -p "$r/.ddev"; printf 'name: dpl-x\ntype: drupal11\ndocroot: web\n' > "$r/.ddev/config.yaml"
mk_bin "$STUBS/ddev" 'case "$1" in describe) exit 1;; start) exit 1;; esac; exit 1'
rr ok
assert_eq "DET-1: DDEV project, DDEV not running, host fallback: exit 3" "$T_RC|$(grep -c . "$r/calls" || true)" "3|0"
assert_match "  the reason" "$(t_err)" 'DET-1: .* has a DDEV project but DDEV is not running'
rr ok DRUPILOT_DETERMINISTIC=false
assert_eq "  DRUPILOT_DETERMINISTIC=false accepts the host run" "$T_RC" "0"
rm -rf "$r/.ddev" "$STUBS/ddev"

# PHPStan and PHPCS: sorted reports with the runner.
t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-phpstan.sh" --subject "$r/$S" --json
assert_eq "run-phpstan: findings, exit 1" "$T_RC" "1"
assert_eq "  files by path, messages by line then identifier, errors sorted" \
  "$(j '[(.files | keys_unsorted), [.files["a.php"].messages[].identifier], .errors]')" '[["a.php","b.php"],["a.id","b.id"],["first","second"]]'
assert_eq "  drupilot.runner" "$(j '.drupilot.runner')" '{"runner":"host","php_version":"8.3.30","tool_version":"2.2.16"}'
assert_eq "  its 0.9 keys kept" "$(j '[.totals.file_errors, (.drupilot | [has("status"), has("exit_code"), has("phpstan_exit_code"), has("notices"), has("crash")] | all)]')" '[3,true]'
t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-phpcs.sh" --subject "$r/$S" --json
assert_eq "run-phpcs: PHPCS's exit code" "$T_RC" "2"
assert_eq "  files by path, messages by line then column" \
  "$(j '[(.files | keys_unsorted), [.files["a.php"].messages[].column]]')" '[["a.php","z.php"],[2,4]]'
assert_eq "  drupilot.runner next to the ruleset" "$(j '[.drupilot.runner, (.drupilot | has("source"))]')" \
  '[{"runner":"host","php_version":"8.3.30","tool_version":"8.3.31"},true]'
t_done
