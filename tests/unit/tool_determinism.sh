#!/usr/bin/env bash
# Deterministic tool invocation (T-M4-03, 05-R2, DET-1, DET-2): run-rector.sh
# runs Rector with its JSON report (--output-format=json --no-progress-bar)
# and reads the changed files and rule hits from its file_diffs; the --json
# summaries of run-rector/phpstan/phpcs record the runner ({runner, php_version,
# tool_version}) and keep their 0.9 keys; PHPStan's and PHPCS's reports are
# sorted; a Rector JSON report with an error or a fatal error is a crash; and in
# deterministic mode a tool whose installed version is not the lock's, or a
# host run on a root that has a DDEV project while the ddev CLI is there,
# exits 3 with the documented --json shape (not with
# DRUPILOT_DETERMINISTIC=false; without ddev the host run is planned). Rector's
# file_diffs and errors come sorted (its parallel jobs end in any order).
# Docker-free: stub php, composer and tools.
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
      {name: "phpstan/phpstan", version: "2.2.16"}, {name: "mglaman/phpstan-drupal", version: "2.2.2"},
      {name: "phpstan/phpstan-deprecation-rules", version: "2.0.5"}, {name: "drupal/coder", version: "8.3.31"}]}' > "$r/composer.lock"
}
lockpkgs 2.6.1
# Rector: the JSON report of two changed files (in reverse order), or what $r/mode says.
cat > "$r/vendor/bin/rector" <<'STUB'
#!/bin/sh
d="$(cd "$(dirname "$0")/../.." && pwd)"; echo "$*" >> "$d/calls"
m="$(cat "$d/mode" 2>/dev/null)"
case "$m" in
  fatal) echo '{"fatal_errors":["Class \"RectorConfig\" not found"]}'; exit 1;;
  file-error) echo '{"totals":{"changed_files":0,"errors":2},"errors":[{"message":"Syntax error","file":"web/modules/custom/legacy_widgets/src/Z.php","line":9},{"message":"Syntax error","file":"web/modules/custom/legacy_widgets/src/Broken.php","line":2}]}'; exit 1;;
  not-json) echo 'PHP Fatal error: boom'; exit 255;;
esac
case " $* " in *" rector-compat.php "*) echo '{"totals":{"changed_files":0,"errors":0}}'; exit 0;; esac
cat <<'JSON'
{"totals":{"changed_files":2,"errors":0},"file_diffs":[
 {"file":"web/modules/custom/legacy_widgets/src/WidgetLookup.php","diff":"@@ -1 +1 @@\n-a\n+b\n","applied_rectors":["Rector\\Php81\\Rector\\FuncCall\\NullToStrictStringFuncCallArgRector"]},
 {"file":"web/modules/custom/legacy_widgets/src/Form/WidgetImportForm.php","diff":"@@ -2 +2 @@\n-c\n+d\n","applied_rectors":["Rector\\Php81\\Rector\\FuncCall\\NullToStrictStringFuncCallArgRector","Rector\\CodingStyle\\Rector\\FuncCall\\FunctionFirstClassCallableRector"]}],
 "changed_files":["web/modules/custom/legacy_widgets/src/Form/WidgetImportForm.php","web/modules/custom/legacy_widgets/src/WidgetLookup.php"]}
JSON
case " $* " in *" --dry-run "*) exit 2;; esac
exit 0
STUB
chmod +x "$r/vendor/bin/rector"
# PHPStan and PHPCS: unsorted JSON reports.
mk_bin "$r/vendor/bin/phpstan" 'echo "{\"totals\":{\"errors\":2,\"file_errors\":4},\"files\":{\"b.php\":{\"errors\":1,\"messages\":[{\"message\":\"z\",\"line\":9}]},\"a.php\":{\"errors\":3,\"messages\":[{\"message\":\"late\",\"line\":8,\"identifier\":\"a.id\"},{\"message\":\"a\",\"line\":5,\"identifier\":\"z.id\"},{\"message\":\"b\",\"line\":5,\"identifier\":\"a.id\"}]}},\"errors\":[\"second\",\"first\"]}"; exit 1'
mk_bin "$r/vendor/bin/phpcs" 'case " $* " in *" -i "*) echo "The installed coding standards are Drupal and DrupalPractice"; exit 0;; esac; echo "{\"totals\":{\"errors\":2,\"warnings\":0,\"fixable\":0},\"files\":{\"z.php\":{\"errors\":1,\"warnings\":0,\"messages\":[{\"message\":\"m\",\"source\":\"S.b\",\"line\":3,\"column\":1}]},\"a.php\":{\"errors\":3,\"warnings\":0,\"messages\":[{\"message\":\"m3\",\"source\":\"S.a\",\"line\":9,\"column\":1},{\"message\":\"a\",\"source\":\"S.z\",\"line\":7,\"column\":2},{\"message\":\"b\",\"source\":\"S.a\",\"line\":7,\"column\":2},{\"message\":\"m2\",\"source\":\"S.a\",\"line\":7,\"column\":1}]}}}"; exit 2'
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
assert_eq "  file_diffs: sorted by file (Rector's parallel jobs end in any order), applied rules sorted" \
  "$(j '[.file_diffs[] | [.pass, (.file | split("/") | last), (.applied_rectors | map(split("\\") | last)), (.diff | test("^@@"))]]')" \
  '[["official","WidgetImportForm.php",["FunctionFirstClassCallableRector","NullToStrictStringFuncCallArgRector"],true],["official","WidgetLookup.php",["NullToStrictStringFuncCallArgRector"],true]]'
assert_match "  the STDERR rendering in file order too" "$(t_err | tr '\n' ' ')" '1\) [^ ]*WidgetImportForm\.php .*2\) [^ ]*WidgetLookup\.php'
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
assert_eq "file errors in the report: crash, exit 3, sorted by file" "$T_RC|$(j '[.status, .errors[0].message]')" \
  "3|[\"error\",\"Syntax error ($S/src/Broken.php:2)\\nSyntax error ($S/src/Z.php:9)\"]"
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

lockpkgs 2.6.2
rr ok
assert_eq "  with --json, the documented exit-3 shape" "$T_RC|$(j '[.status, .ok, .errors[0].pass, (.errors[0].message | test("^DET-1: rector/rector installed 2.6.2"))]')" \
  '3|["error",false,0,true]'
lockpkgs 2.6.1
# DET-1 for PHPStan and PHPCS: their own packages.
jq '.toolchain["phpstan/phpstan"] = "2.2.15" | .toolchain["drupal/coder"] = "8.3.30"' "$(lock_path "$r")" > "$T_TMP/l.json" && mv "$T_TMP/l.json" "$(lock_path "$r")"
t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-phpstan.sh" --subject "$r/$S" --json
assert_eq "DET-1: run-phpstan with phpstan/phpstan not the lock's: exit 3, crashed, the reason" \
  "$T_RC|$(j '[.drupilot.status, (.drupilot.crash[0] | test("^DET-1: phpstan/phpstan installed 2.2.16, the lock pins 2.2.15")), .totals]')" '3|["crashed",true,null]'
t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-phpcs.sh" --subject "$r/$S" --json
assert_eq "DET-1: run-phpcs with drupal/coder not the lock's: exit 3, the reason" \
  "$T_RC|$(j '.drupilot.error | test("^DET-1: drupal/coder installed 8.3.31, the lock pins 8.3.30")')" '3|true'
jq '.toolchain["phpstan/phpstan"] = "2.2.16" | .toolchain["drupal/coder"] = "8.3.31"' "$(lock_path "$r")" > "$T_TMP/l.json" && mv "$T_TMP/l.json" "$(lock_path "$r")"
# Every package each tool checks: the lock pins it at another version -> exit 3.
for row in "run-rector rector/rector" "run-rector palantirnet/drupal-rector" "run-phpstan phpstan/phpstan" \
           "run-phpstan mglaman/phpstan-drupal" "run-phpstan phpstan/phpstan-deprecation-rules" "run-phpcs drupal/coder"; do
  tool="${row%% *}"; pkg="${row#* }"
  jq --arg p "$pkg" '."packages-dev" |= ((map(select(.name != $p))) + [{name: $p, version: "9.9.9"}])' "$r/composer.lock" > "$T_TMP/c.json"
  cp "$r/composer.lock" "$T_TMP/c.bak"; mv "$T_TMP/c.json" "$r/composer.lock"
  jq --arg p "$pkg" '.toolchain[$p] = "1.0.0"' "$(lock_path "$r")" > "$T_TMP/l.json" && cp "$(lock_path "$r")" "$T_TMP/l.bak" && mv "$T_TMP/l.json" "$(lock_path "$r")"
  t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 DRUPILOT_USE_DIGESTS_RULES=false "$T_SH" "$T_REPO/scripts/analysis/$tool.sh" --subject "$r/$S" --json
  assert_match "DET-1: $tool checks $pkg" "$T_RC|$(t_err | tr '\n' ' ')" "^3\|.*DET-1: $pkg installed 9\.9\.9, the lock pins 1\.0\.0"
  mv "$T_TMP/c.bak" "$r/composer.lock"; mv "$T_TMP/l.bak" "$(lock_path "$r")"
done
# The attributes pass (run-rector.sh --attributes) checks Rector too, with its --json error shape.
mkdir -p "$r/vendor/palantirnet/drupal-rector/src/Drupal10/Rector/Deprecation"
printf '<?php\n' > "$r/vendor/palantirnet/drupal-rector/src/Drupal10/Rector/Deprecation/AnnotationToAttributeRector.php"
jq '."packages-dev" |= map(if .name == "rector/rector" then .version = "9.9.9" else . end)' "$r/composer.lock" > "$T_TMP/c.json" && cp "$r/composer.lock" "$T_TMP/c.bak" && mv "$T_TMP/c.json" "$r/composer.lock"
t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --attributes --subject "$r/$S" --json
assert_eq "DET-1: the attributes pass refuses too (exit 3, its error JSON)" \
  "$T_RC|$(j '[.tool, .status, (.errors[0].message | test("^DET-1: rector/rector installed 9.9.9"))]')" '3|["attributes","error",true]'
mv "$T_TMP/c.bak" "$r/composer.lock"

# DET-1: no ddev on the machine (the analyze profile is Docker-free): a root
# with a committed .ddev/ runs on the host by plan.
mkdir -p "$r/.ddev"; printf 'name: dpl-x\ntype: drupal11\ndocroot: web\n' > "$r/.ddev/config.yaml"
NODDEV="$(t_path_without ddev)"
printf 'ok' > "$r/mode"; : > "$r/calls"
t_run env PATH="$STUBS:$NODDEV" DRUPILOT_PHP_TARGET=8.3 DRUPILOT_USE_DIGESTS_RULES=false "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$r/$S" --json
assert_eq "no ddev CLI, a committed .ddev/: the host run is planned (exit 0, runner host)" "$T_RC|$(j '.runner.runner')" '0|"host"'
rm -rf "$r/.ddev"

# DET-1: a host run on a root that has a DDEV project (DDEV cannot start).
mkdir -p "$r/.ddev"; printf 'name: dpl-x\ntype: drupal11\ndocroot: web\n' > "$r/.ddev/config.yaml"
mk_bin "$STUBS/ddev" 'case "$1" in describe) exit 1;; start) exit 1;; esac; exit 1'
rr ok
assert_eq "DET-1: DDEV project, DDEV not running, host fallback: exit 3" "$T_RC|$(grep -c . "$r/calls" || true)" "3|0"
assert_match "  the reason" "$(t_err)" 'DET-1: .* has a DDEV project but DDEV is not running'
rr ok DRUPILOT_DETERMINISTIC=false
assert_eq "  DRUPILOT_DETERMINISTIC=false accepts the host run" "$T_RC" "0"
for tool in phpstan phpcs; do
  t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-$tool.sh" --subject "$r/$S" --json
  assert_eq "  run-$tool too: exit 3" "$T_RC" "3"
done
rm -rf "$r/.ddev" "$STUBS/ddev"

# Digests under DDEV (a ddev stub that runs the command as the container would,
# from the root): an explicit config whose directory holds the root is staged
# alone, self-ignored, and passed relative to the root; one under the root is
# passed relative, unstaged.
mk_bin "$STUBS/ddev" 'case "$1" in describe) echo "{\"raw\":{\"status\":\"running\"}}";; exec) shift; exec "$@";; esac; exit 0'
mkdir -p "$r/.ddev"; printf 'name: dpl-x\ntype: drupal11\ndocroot: web\n' > "$r/.ddev/config.yaml"
printf '<?php return [];\n' > "$T_TMP/digests.php"
printf 'ok' > "$r/mode"; : > "$r/calls"
t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$r/$S" --config "$T_TMP/digests.php" --json
staged="$(grep -o -- '--config \.drupilot/digests/[^ ]*' "$r/calls" | sed -n '1p' | cut -d' ' -f2)"
assert_eq "an explicit config beside the root: the pass ran in the bed, exit 0, runner ddev" "$T_RC|$(j '[.digests_status, .runner.runner]')" '0|["ok","ddev"]'
assert_match "  with the config staged alone, relative to the root" "$staged" '^\.drupilot/digests/config-[0-9a-f]{16}/[^/]+/digests\.php$'
assert_eq "  its directory was not copied (it holds the root)" "$(find "$r/.drupilot/digests" -type f ! -name .staged | grep -c . || true)" "1"
assert_eq "  .drupilot/ ignores itself" "$(cat "$r/.drupilot/.gitignore" 2> /dev/null)" "*"
cp "$T_TMP/digests.php" "$r/rector-digests.php"; : > "$r/calls"
t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$r/$S" --config "$r/rector-digests.php" --json
assert_eq "a config under the root: passed relative, not staged" "$T_RC|$(grep -c -- '--config rector-digests.php' "$r/calls" || true)" "0|1"
rm -rf "$r/.ddev" "$r/.drupilot" "$r/rector-digests.php" "$STUBS/ddev"

# PHPStan and PHPCS: sorted reports with the runner.
t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-phpstan.sh" --subject "$r/$S" --json
assert_eq "run-phpstan: findings, exit 1" "$T_RC" "1"
assert_eq "  files by path, messages by line then identifier (not message), errors sorted" \
  "$(j '[(.files | keys_unsorted), [.files["a.php"].messages[] | "\(.line):\(.identifier)"], .errors]')" '[["a.php","b.php"],["5:a.id","5:z.id","8:a.id"],["first","second"]]'
assert_eq "  drupilot.runner" "$(j '.drupilot.runner')" '{"runner":"host","php_version":"8.3.30","tool_version":"2.2.16"}'
assert_eq "  its 0.9 keys kept" "$(j '[.totals.file_errors, (.drupilot | [has("status"), has("exit_code"), has("phpstan_exit_code"), has("notices"), has("crash")] | all)]')" '[4,true]'
t_run env PATH="$STUBS:$PATH" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-phpcs.sh" --subject "$r/$S" --json
assert_eq "run-phpcs: PHPCS's exit code" "$T_RC" "2"
assert_eq "  files by path, messages by line, column, then source (not message)" \
  "$(j '[(.files | keys_unsorted), [.files["a.php"].messages[] | "\(.line):\(.column):\(.source)"]]')" '[["a.php","z.php"],["7:1:S.a","7:2:S.a","7:2:S.z","9:1:S.a"]]'
assert_eq "  drupilot.runner next to the ruleset" "$(j '[.drupilot.runner, (.drupilot | has("source"))]')" \
  '[{"runner":"host","php_version":"8.3.30","tool_version":"8.3.31"},true]'
t_done
