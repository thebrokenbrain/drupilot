#!/usr/bin/env bash
# run-phpunit.sh --leg (T-M5-11, AR-06, CC-14) with stub docker/ddev (ddev exec
# runs the command here, a /usr/bin/phpX.Y becomes a stub PHP) and a stub
# PHPUnit that writes a JUnit log and fails a group on the PHPs STUB_FAIL
# names:
# - CURRENT keeps the 0.9 record and adds legs.CURRENT;
# - PHP_LOW runs Unit and Kernel only, with the plan's lower PHP, and adds
#   legs.PHP_LOW without touching the CURRENT verdict there; the top-level
#   preservation is the aggregate: a PHP_LOW regression makes it regression,
#   a missing PHP binary (blocked) turns a verified CURRENT into
#   verified-partial; nothing outside the 0.9 values;
# - a CURRENT run keeps a PHP_LOW leg of the same sources and drops a stale
#   one; a plan without the leg is a no-op; PREVIOUS_MAJOR and a Functional
#   --type are usage errors. Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

B="$T_TMP/bin"; mkdir -p "$B"
printf '#!/bin/sh\ncase "$1" in --version|version) echo "Docker version 29.0.0, build x";; esac\nexit 0\n' > "$B/docker"
# ddev: running; exec runs the command here, a /usr/bin/phpX.Y through the
# stub PHP (only the versions STUB_PHPS lists exist).
cat > "$B/ddev" <<SH
#!/bin/sh
case "\$1" in
  --version|version) echo "ddev version v1.25.4";;
  describe) echo '{"raw":{"status":"running"}}';;
  exec)
    shift
    if [ "\$1" = test ] && [ "\$2" = -x ]; then
      v="\${3#/usr/bin/php}"; case " \$STUB_PHPS " in *" \$v "*) exit 0;; *) exit 1;; esac
    fi
    case "\$1" in
      /usr/bin/php*) v="\${1#/usr/bin/php}"; shift
        if [ "\$2" = --version ]; then [ -n "\$STUB_NO_AUTOLOAD" ] && { echo "Composer detected issues in your platform"; exit 255; }; echo "PHPUnit 11.5.50"; exit 0; fi
        STUB_PHP="\$v" exec "\$@";;
      sh) exec "\$@";;
      *) STUB_PHP="\${STUB_PHP:-8.4}" exec "\$@";;
    esac;;
esac
exit 0
SH
chmod +x "$B/docker" "$B/ddev"

R="$T_TMP/site"; S="$R/web/modules/custom/m"
mkdir -p "$R/web/core/lib" "$R/vendor/bin" "$R/.ddev" "$S/tests/src/Unit" "$S/tests/src/Kernel" "$S/tests/src/Functional"
printf '{"name":"x/site"}\n' > "$R/composer.json"
printf 'name: dpl-x\ntype: drupal11\ndocroot: web\n' > "$R/.ddev/config.yaml"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$R/web/core/lib/Drupal.php"
printf '<phpunit/>\n' > "$R/web/core/phpunit.xml.dist"
printf 'name: M\ntype: module\ncore_version_requirement: ^10.3 || ^11\n' > "$S/m.info.yml"
for g in Unit Kernel Functional; do printf '<?php\nclass %sTest {}\n' "$g" > "$S/tests/src/$g/${g}Test.php"; done
# The stub PHPUnit: --log-junit FILE ... PATH; the group is PATH's last part;
# it fails when "<php>:<group>" is in STUB_FAIL.
cat > "$R/vendor/bin/phpunit" <<'SH'
#!/bin/sh
log=""; prev=""; for a; do [ "$prev" = "--log-junit" ] && log="$a"; prev="$a"; done
for p; do :; done
g="${p##*/}"; php="${STUB_PHP:-8.4}"
echo "$php $g" >> "${STUB_LOG:-/dev/null}"
case " $STUB_FAIL " in
  *" $php:$g "*) printf '<testsuites><testsuite>\n<testcase name="testIt" class="Drupal\\Tests\\m\\%s\\%sTest">\n<failure>broken on PHP %s</failure>\n</testcase>\n</testsuite></testsuites>\n' "$g" "$g" "$php" > "$log"; exit 1;;
  *) printf '<testsuites><testsuite>\n<testcase name="testIt" class="Drupal\\Tests\\m\\%s\\%sTest"/>\n</testsuite></testsuites>\n' "$g" "$g" > "$log"; exit 0;;
esac
SH
chmod +x "$R/vendor/bin/phpunit"
# The plan: CURRENT on PHP 8.4, PHP_LOW on 8.3.
plan() {  # plan LEGS-JSON
  DRUPILOT_PROJECT_DIR="$R" lock_set_json .upgrade_plan "{\"subject\": {\"machine_name\": \"m\"}, \"test_matrix\": $1}" > /dev/null
}
plan '[{"leg": "CURRENT", "core": "11.4.8", "php": "8.4", "mode": "run"}, {"leg": "PHP_LOW", "core": "11.4.8", "php": "8.3", "mode": "run"},
       {"leg": "PREVIOUS_MAJOR", "core": "10.6", "php": "8.1", "mode": "static"}]'
LT="$(project_state_path "$S")/last-test.json"
export STUB_LOG="$T_TMP/calls" STUB_PHPS="8.3 8.4"
rp() { : > "$STUB_LOG"; t_run env PATH="$B:$PATH" CLAUDE_PLUGIN_ROOT="$T_REPO" "$T_SH" "$T_REPO/scripts/tests/run-phpunit.sh" --subject "$S" "$@"; }
calls() { tr '\n' ',' < "$STUB_LOG"; }
leg() { jq -c --arg l "$1" '.legs[$l] | [.preservation, .php, .groups]' "$LT"; }

rp --type all
assert_eq "CURRENT: every group on the bed's PHP, verified" "$T_RC|$(calls)|$(jq -r .preservation "$LT")" \
  "0|8.4 Unit,8.4 Kernel,8.4 Functional,|verified"
assert_eq "  legs.CURRENT" "$(leg CURRENT)" '["verified",null,["Unit","Kernel","Functional"]]'
rp --type all --leg PHP_LOW
assert_eq "PHP_LOW: Unit and Kernel on PHP 8.3, verified, the record's verdict unchanged" \
  "$T_RC|$(calls)|$(leg PHP_LOW)|$(jq -r .preservation "$LT")" '0|8.3 Unit,8.3 Kernel,|["verified","8.3",["Unit","Kernel"]]|verified'
STUB_FAIL="8.3:Kernel" rp --type all --leg PHP_LOW
assert_eq "a PHP_LOW regression: exit 3, the aggregate regression and a failed status, CURRENT still verified" \
  "$T_RC|$(jq -r '"\(.preservation) \(.status)"' "$LT")|$(leg CURRENT)|$(jq -c '.legs.PHP_LOW.tests_failed' "$LT")" \
  '3|regression failed|["verified",null,["Unit","Kernel","Functional"]]|["Drupal\\Tests\\m\\Kernel\\KernelTest::testIt"]'
assert_eq "  next-step.sh sees red tests, not a green port" \
  "$(env PATH="$B:$PATH" CLAUDE_PLUGIN_ROOT="$T_REPO" "$T_SH" "$T_REPO/scripts/env/next-step.sh" --subject "$S" --json 2>/dev/null | jq -r '.tests // empty')" "failed"
assert_eq "  the leg's time is under meta, none outside it" "$(jq -c '[(.meta.legs.PHP_LOW.recorded_at | type), (.legs.PHP_LOW | has("recorded_at"))]' "$LT")" '["string",false]'
rp --type all
assert_eq "a CURRENT run on the same sources keeps the PHP_LOW leg and its verdict" \
  "$T_RC|$(jq -r .preservation "$LT")|$(jq -r '.legs.PHP_LOW.preservation' "$LT")" "0|regression|regression"
printf '<?php\n// changed\n' >> "$S/tests/src/Unit/UnitTest.php"
rp --leg PHP_LOW --type all
assert_eq "  a PHP_LOW run over a CURRENT record of other sources is not recorded" "$T_RC|$(jq -r '.legs.PHP_LOW.preservation' "$LT")" "0|regression"
rp --type all
assert_eq "  a CURRENT run on other sources keeps the leg, marked stale: verified-partial at best" \
  "$T_RC|$(jq -r .preservation "$LT")|$(jq -c '[.legs.PHP_LOW.stale, .legs.PHP_LOW.preservation]' "$LT")" '0|verified-partial|[true,"regression"]'
rp --type all --leg PHP_LOW
assert_eq "  the leg run again on these sources: fresh and verified" "$T_RC|$(jq -r .preservation "$LT")|$(jq -c '.legs.PHP_LOW.stale' "$LT")" '0|verified|null'
rp --type unit --leg PHP_LOW
assert_eq "  a narrowed PHP_LOW run never replaces a whole leg of the same sources" "$T_RC|$(jq -r .preservation "$LT")|$(jq -r '.legs.PHP_LOW.type' "$LT")" '0|verified|all'
STUB_FAIL="8.3:Kernel" rp --type all --leg PHP_LOW
rp --filter NoSuchTest --leg PHP_LOW
assert_eq "  a --filter matching nothing keeps the failing whole leg: still regression" "$(jq -r .preservation "$LT")" "regression"
rp --type all --leg PHP_LOW
rp --type all --leg PHP_LOW
STUB_NO_AUTOLOAD=1 rp --type all --leg PHP_LOW
assert_eq "a PHP that cannot load the vendor tree: blocked (exit 2), not a red group" \
  "$T_RC|$(jq -r '.legs.PHP_LOW.preservation' "$LT")|$(jq -r .preservation "$LT")" "2|not-verified-blocked|verified-partial"
rp --type all --leg PHP_LOW
STUB_PHPS="8.4" rp --type all --leg PHP_LOW
assert_eq "no /usr/bin/php8.3 in the container: blocked (exit 2), a verified CURRENT becomes verified-partial" \
  "$T_RC|$(jq -r '.legs.PHP_LOW.preservation' "$LT")|$(jq -r .preservation "$LT")|$(jq -r '.legs.PHP_LOW.blocked_reason' "$LT")" \
  "2|not-verified-blocked|verified-partial|the DDEV web container has no /usr/bin/php8.3 (the PHP_LOW leg's PHP)"
assert_eq "the record validates against schemas/last-test.schema.json" \
  "$(jq -r --slurpfile schema "$T_REPO/schemas/last-test.schema.json" "$(cat "$T_REPO/scripts/dev/jsonschema.jq")"' . as $doc | $schema[0] as $root | $doc | chk($root; $root; "$")' "$LT" 2>&1)" ""
assert_eq "every preservation value is a 0.9 one" \
  "$(jq -c '[.preservation, .legs[].preservation] | map(IN("verified","verified-partial","regression","not-verified-blocked","not-verified-no-tests","pre-existing-failures","not-verified-unbaselined")) | all' "$LT")" "true"
# Monotonic: a pre-existing CURRENT failure and a PHP_LOW failure the baseline
# never ran (its Kernel group crashed then) give not-verified-unbaselined.
BL="$(project_state_path "$S")/test-baseline.json"
jq -n '{source: "run", tests: [{group: "Unit", id: "Drupal\\Tests\\m\\Unit\\UnitTest::testIt", status: "fail", message: "old"}],
        group_results: [{group: "Unit", status: "failed"}, {group: "Kernel", status: "crashed"}]}' > "$BL"
STUB_FAIL="8.4:Unit" rp --type all
STUB_FAIL="8.3:Unit 8.3:Kernel" rp --type all --leg PHP_LOW
assert_eq "monotonic: CURRENT pre-existing-failures, PHP_LOW not-verified-unbaselined: the aggregate is the stronger" \
  "$(jq -c '[.legs.CURRENT.preservation, .legs.PHP_LOW.preservation, .preservation, .status]' "$LT")" \
  '["pre-existing-failures","not-verified-unbaselined","not-verified-unbaselined","failed"]'
rm -f "$BL"
rp --type all
STUB_PHPS="8.4" rp --type all --leg PHP_LOW
t_run env CLAUDE_PLUGIN_ROOT="$T_REPO" "$T_SH" "$T_REPO/scripts/analysis/port-report.sh" --subject "$S"
assert_match "port-report.sh: each leg's verdict under the aggregate" "$(cat "$(cat "$T_OUT")")" 'PHP_LOW \(PHP 8\.3\): not-verified-blocked'
rp --type js
STUB_PHPS="8.4" rp --type all --leg PHP_LOW
assert_eq "no test run on CURRENT and a blocked PHP_LOW: still not-verified-no-tests, never verified-partial" \
  "$(jq -c '[.legs.CURRENT.preservation, .legs.PHP_LOW.preservation, .preservation]' "$LT")" '["not-verified-no-tests","not-verified-blocked","not-verified-no-tests"]'
plan '[{"leg": "CURRENT", "core": "11.4.8", "php": "8.3", "mode": "run"}]'
rp --type all --leg PHP_LOW
assert_eq "a plan without a PHP_LOW leg: nothing runs" "$T_RC|$(calls)" "0|"
rp --leg PREVIOUS_MAJOR
assert_eq "PREVIOUS_MAJOR is static: exit 1" "$T_RC" "1"
rp --leg PHP_LOW --type functional
assert_eq "the PHP_LOW leg runs no Functional group: exit 1" "$T_RC" "1"
rp --leg NOPE
assert_eq "an unknown leg: exit 1" "$T_RC" "1"
t_done
