#!/usr/bin/env bash
# install-smoke.sh (training run modules 03, 06 and 14: no test, no runtime
# evidence), Docker-free paths:
# - --dry-run renders drupilot's BrowserTestBase check under
#   <root>/.drupilot/smoke/<machine_name>/ with the machine name and the type,
#   no token left, the subject untouched, PHPUnit not run;
# - a theme renders the theme branch;
# - no Drupal root: blocked (exit 2, status blocked in --json); not an
#   extension: exit 1; --help and an unknown flag (AR-22).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
IS="$T_REPO/scripts/tests/install-smoke.sh"
R="$T_TMP/bed"; M="$R/web/modules/custom/m"; TH="$R/web/themes/custom/th"
mkdir -p "$R/web/core/lib/Drupal" "$M" "$TH"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$R/web/core/lib/Drupal.php"
printf '{"name": "drupal/recommended-project"}\n' > "$R/composer.json"
printf 'name: M\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$M/m.info.yml"
printf 'name: Th\ntype: theme\nbase theme: false\ncore_version_requirement: ^10 || ^11\n' > "$TH/th.info.yml"

t_run "$T_SH" "$IS" --subject "$M" --dry-run --json
F="$R/.drupilot/smoke/m/DrupilotInstallSmokeTest.php"
assert_eq "dry-run: rendered, not run" "$T_RC|$(jq -c '[.status, .machine_name, .type, .core, .test_file]' "$T_OUT")" \
  '0|["dry-run","m","module","11.4.8",".drupilot/smoke/m/DrupilotInstallSmokeTest.php"]'
assert_eq "  the machine name and the type substituted, no token left" \
  "$(grep -c "\$name = 'm';" "$F")|$(grep -c "'module' === 'theme'" "$F")|$(grep -c '{{' "$F" || true)" "1|1|0"
assert_eq "  the subject untouched" "$(find "$M" -type f | wc -l | tr -d ' ')" "1"
t_run "$T_SH" "$IS" --subject "$TH" --dry-run --json
assert_eq "a theme: the theme branch" "$T_RC|$(jq -r .type "$T_OUT")|$(grep -c "'theme' === 'theme'" "$R/.drupilot/smoke/th/DrupilotInstallSmokeTest.php")" "0|theme|1"

L="$T_TMP/loose"; mkdir -p "$L"; printf 'name: L\ntype: module\n' > "$L/l.info.yml"
t_run "$T_SH" "$IS" --subject "$L" --json
assert_eq "no Drupal root: blocked (exit 2)" "$T_RC|$(jq -r .status "$T_OUT")" "2|blocked"
N="$T_TMP/none"; mkdir -p "$N"
t_run "$T_SH" "$IS" --subject "$N"
assert_eq "not an extension: exit 1" "$T_RC" "1"
t_run "$T_SH" "$IS" --help
assert_eq "--help: exit 0 with a Usage section" "$T_RC|$(grep -c 'Usage:' "$T_OUT")" "0|1"
t_run "$T_SH" "$IS" --bogus
assert_eq "an unknown flag: exit 1" "$T_RC" "1"
t_done
