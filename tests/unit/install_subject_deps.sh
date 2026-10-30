#!/usr/bin/env bash
# install-subject-deps.sh (training run module 06, twig_extender: the
# subject's fightbulc/moment was never installed into the test-bed), Docker-
# free paths:
# - the requirements: the subject's composer.json `require` without php,
#   ext-*, composer/*, drupal/core and drupal/core-*; a package the bed's
#   composer.lock has is present, the others are to install;
# - no composer.json, or nothing left: status nothing (exit 0); all present:
#   status present;
# - --dry-run lists them (skipped), Composer is not run;
# - on your own project (no test-bed marker): report-only, exit 0, its
#   composer.json untouched;
# - no Drupal root: exit 2; --help and an unknown flag (AR-22).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
IS="$T_REPO/scripts/env/install-subject-deps.sh"

R="$T_TMP/bed"; M="$R/web/modules/custom/m"
mkdir -p "$R/web/core/lib/Drupal" "$M"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$R/web/core/lib/Drupal.php"
printf '{"name": "drupal/recommended-project", "require": {"drupal/core-recommended": "^11"}}\n' > "$R/composer.json"
printf '{"packages": [{"name": "drupal/core", "version": "11.4.8"}, {"name": "drupal/token", "version": "1.17.0"}], "packages-dev": []}\n' > "$R/composer.lock"
printf 'name: M\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$M/m.info.yml"

t_run "$T_SH" "$IS" --subject "$M" --json
assert_eq "no composer.json: nothing (exit 0)" "$T_RC|$(jq -r .status "$T_OUT")" "0|nothing"

cat > "$M/composer.json" <<'EOF'
{"require": {"php": ">=8.1", "ext-json": "*", "composer/installers": "^2", "drupal/core": "^10 || ^11",
             "drupal/core-recommended": "^11", "fightbulc/moment": "^1.26", "drupal/token": "^1.15"}}
EOF
t_run "$T_SH" "$IS" --subject "$M" --dry-run --json
assert_eq "dry-run: the library to install, token present, the rest left out" \
  "$T_RC|$(jq -c '[.status, [.requested[].name], [.present[].name], [.skipped[].name], .installed]' "$T_OUT")" \
  '0|["dry-run",["fightbulc/moment","drupal/token"],["drupal/token"],["fightbulc/moment"],[]]'
cp "$R/composer.json" "$T_TMP/before.json"
t_run "$T_SH" "$IS" --subject "$M" --json
assert_eq "your own project (no test-bed marker): report-only, exit 0" \
  "$T_RC|$(jq -c '[.status, .testbed, [.skipped[].name]]' "$T_OUT")" '0|["report-only","none",["fightbulc/moment"]]'
assert_file_eq "  its composer.json untouched" "$R/composer.json" "$T_TMP/before.json"
printf '{"packages": [{"name": "fightbulc/moment", "version": "1.33.0"}, {"name": "drupal/token", "version": "1.17.0"}]}\n' > "$R/composer.lock"
t_run "$T_SH" "$IS" --subject "$M" --json
assert_eq "everything in the bed already: present" "$T_RC|$(jq -r .status "$T_OUT")" "0|present"

L="$T_TMP/loose"; mkdir -p "$L"; printf 'name: L\ntype: module\n' > "$L/l.info.yml"
t_run "$T_SH" "$IS" --subject "$L" --json
assert_eq "no Drupal root: exit 2" "$T_RC" "2"
t_run "$T_SH" "$IS" --help
assert_eq "--help: exit 0 with a Usage section" "$T_RC|$(grep -c 'Usage:' "$T_OUT")" "0|1"
t_run "$T_SH" "$IS" --bogus
assert_eq "an unknown flag: exit 1" "$T_RC" "1"
t_done
