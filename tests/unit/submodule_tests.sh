#!/usr/bin/env bash
# Submodule tests (training run module 13, log_entity: its only test sat in
# modules/log_entity_login_attempts/tests/src/Functional and drupilot neither
# listed nor ran it, so the subject was "not-verified-no-tests"):
# - subject_test_dirs lists the subject's tests/src/<group> first, then each
#   nested extension's (a *.info.yml next to its tests/), never one without an
#   info.yml, under vendor/ or under a dot directory;
# - discover-tests.sh counts the submodule's classes;
# - run-phpunit.sh (stub docker/ddev/PHPUnit, Docker-free) runs one PHPUnit per
#   directory, records every test, and a failing submodule run fails its group.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

R="$T_TMP/site"; S="$R/web/modules/custom/m"
mkdir -p "$R/web/core/lib" "$R/vendor/bin" "$R/.ddev" "$S/tests/src/Unit" \
  "$S/modules/sub/tests/src/Functional" "$S/modules/sub/tests/src/Unit" "$S/modules/noinfo/tests/src/Unit" \
  "$S/vendor/x/y/tests/src/Unit" "$S/.cache/z/tests/src/Unit"
printf '{"name":"x/site"}\n' > "$R/composer.json"
printf 'name: dpl-x\ntype: drupal11\ndocroot: web\n' > "$R/.ddev/config.yaml"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$R/web/core/lib/Drupal.php"
printf '<phpunit/>\n' > "$R/web/core/phpunit.xml.dist"
printf 'name: M\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$S/m.info.yml"
printf 'name: Sub\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$S/modules/sub/sub.info.yml"
for d in tests/src/Unit modules/sub/tests/src/Functional modules/sub/tests/src/Unit modules/noinfo/tests/src/Unit vendor/x/y/tests/src/Unit .cache/z/tests/src/Unit; do
  c="$(printf '%s' "$d" | tr -c 'A-Za-z0-9\n' '_')"
  printf '<?php\nclass %sTest {}\n' "$c" > "$S/$d/${c}Test.php"
done

assert_eq "subject_test_dirs Unit: the subject's, then the submodule's" \
  "$(subject_test_dirs "$S" Unit | tr '\n' ',')" "tests/src/Unit,modules/sub/tests/src/Unit,"
assert_eq "  Functional: the submodule's only" "$(subject_test_dirs "$S" Functional | tr '\n' ',')" "modules/sub/tests/src/Functional,"
assert_eq "  Kernel: none" "$(subject_test_dirs "$S" Kernel)" ""

t_run "$T_SH" "$T_REPO/scripts/tests/discover-tests.sh" --subject "$S" --json
assert_eq "discover-tests: the submodule's classes counted" \
  "$T_RC|$(jq -c '[.unit, .functional, .total, [.files[].path]]' "$T_OUT")" \
  '0|[2,1,3,["tests/src/Unit/tests_src_UnitTest.php","modules/sub/tests/src/Unit/modules_sub_tests_src_UnitTest.php","modules/sub/tests/src/Functional/modules_sub_tests_src_FunctionalTest.php"]]'

B="$T_TMP/bin"; mkdir -p "$B"
printf '#!/bin/sh\ncase "$1" in --version|version) echo "Docker version 29.0.0, build x";; esac\nexit 0\n' > "$B/docker"
cat > "$B/ddev" <<'SH'
#!/bin/sh
case "$1" in
  --version|version) echo "ddev version v1.25.4";;
  describe) echo '{"raw":{"status":"running"}}';;
  exec) shift; [ "$1" = sh ] && exec "$@"; exec "$@";;
esac
exit 0
SH
# The stub PHPUnit: one testcase named after PATH; fails when PATH is STUB_FAIL.
cat > "$R/vendor/bin/phpunit" <<'SH'
#!/bin/sh
[ "$1" = --version ] && { echo "PHPUnit 11.5.50"; exit 0; }
log=""; prev=""; for a; do [ "$prev" = "--log-junit" ] && log="$a"; prev="$a"; done
for p; do :; done
echo "$p" >> "$STUB_LOG"
c="$(printf '%s' "$p" | tr '/' '_')"
if [ "$p" = "$STUB_FAIL" ]; then
  printf '<testsuites><testsuite>\n<testcase name="testIt" class="T\\%s"><failure>x</failure></testcase>\n</testsuite></testsuites>\n' "$c" > "$log"; exit 1
fi
printf '<testsuites><testsuite>\n<testcase name="testIt" class="T\\%s"/>\n</testsuite></testsuites>\n' "$c" > "$log"
SH
chmod +x "$B/docker" "$B/ddev" "$R/vendor/bin/phpunit"
LT="$(project_state_path "$S")/last-test.json"
export STUB_LOG="$T_TMP/calls"
rp() { : > "$STUB_LOG"; t_run env PATH="$B:$PATH" CLAUDE_PLUGIN_ROOT="$T_REPO" STUB_FAIL="${FAIL:-}" "$T_SH" "$T_REPO/scripts/tests/run-phpunit.sh" --subject "$S" --type all; }
rp
assert_eq "run-phpunit: one run per directory, the subject's first" "$T_RC|$(tr '\n' ',' < "$STUB_LOG")" \
  "0|web/modules/custom/m/tests/src/Unit,web/modules/custom/m/modules/sub/tests/src/Unit,web/modules/custom/m/modules/sub/tests/src/Functional,"
assert_eq "  verified, the three tests recorded, two groups passed" \
  "$(jq -c '[.preservation, (.tests | length), .subject_has_tests, [.group_results[] | [.group, .status, .executed]]]' "$LT")" \
  '["verified",3,true,[["Unit","passed",2],["Functional","passed",1]]]'
FAIL=web/modules/custom/m/modules/sub/tests/src/Unit rp
assert_eq "a failing submodule run fails its group (exit 3)" "$T_RC|$(jq -c '[.group_results[] | [.group, .status]]' "$LT")" '3|[["Unit","failed"],["Functional","passed"]]'
t_done
