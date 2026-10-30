#!/usr/bin/env bash
# classify-deprecations.sh's not-removed class (training run 04,
# drush_language: 14 "Function X not found" findings made the verdict L):
# - a function the subject's core defines in a file core loads on demand
#   (core/modules/locale/locale.fetch.inc) is not-removed, with core_file,
#   action report, never blocking; one core does not define stays unknown;
# - a function a *.drush.inc calls (Drush 8 API, never loaded by Drush 9+) is
#   not-removed; the same function called from a class stays unknown;
# - without a Drupal root the include case stays unknown.
# Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
CD="$T_REPO/scripts/analysis/classify-deprecations.sh"

R="$T_TMP/root"; M="$R/web/modules/custom/m"
mkdir -p "$R/web/core/lib/Drupal" "$R/web/core/modules/locale/tests" "$M/src"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$R/web/core/lib/Drupal.php"
printf '<?php\n\nfunction locale_translation_batch_update_build($projects = []) {\n  return [];\n}\n' > "$R/web/core/modules/locale/locale.fetch.inc"
printf '<?php\n\nfunction only_in_core_tests() {}\n' > "$R/web/core/modules/locale/tests/helper.inc"
printf '{"require": {"drupal/core": "^11"}}\n' > "$R/composer.json"
printf 'name: M\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$M/m.info.yml"
cat > "$T_TMP/phpstan.json" <<'EOF'
{"totals": {"errors": 0, "file_errors": 5}, "files": {
  "src/Service/Cli.php": {"errors": 3, "messages": [
    {"message": "Function locale_translation_batch_update_build not found.", "line": 10, "identifier": "function.notFound"},
    {"message": "Function nowhere_at_all not found.", "line": 11, "identifier": "function.notFound"},
    {"message": "Function only_in_core_tests not found.", "line": 12, "identifier": "function.notFound"}]},
  "m.drush.inc": {"errors": 1, "messages": [
    {"message": "Function drush_get_option not found.", "line": 5, "identifier": "function.notFound"}]},
  "src/Drush8Io.php": {"errors": 1, "messages": [
    {"message": "Function drush_get_option not found.", "line": 7, "identifier": "function.notFound"}]}}}
EOF
t_run "$T_SH" "$CD" --file "$T_TMP/phpstan.json" --subject "$M" --json
assert_eq "classify: exit 0" "$T_RC" "0"
assert_eq "the counts: two not-removed, three unknown (blocking)" \
  "$(jq -c '[.counts.not_removed, .counts.unknown, .blocking]' "$T_OUT")" '[2,3,3]'
assert_eq "a function core defines in an include it loads on demand: not-removed, its core file, reported" \
  "$(jq -c '[.not_removed[] | select(.symbol == "locale_translation_batch_update_build") | [.class, .core_file, .action]]' "$T_OUT")" \
  '[["not-removed","core/modules/locale/locale.fetch.inc","report"]]'
assert_match "  the reason says to check the include is loaded" \
  "$(jq -r '.symbols[] | select(.symbol == "locale_translation_batch_update_build") | .reason' "$T_OUT")" \
  "core loads on demand.*check that the code loads that file first: reported, not blocking"
assert_eq "a function core never defines, or only in its tests: unknown" \
  "$(jq -c '[.unknown[] | select(.symbol != "drush_get_option") | .symbol] | sort' "$T_OUT")" '["nowhere_at_all","only_in_core_tests"]'
assert_eq "a Drush 8 function in a *.drush.inc: not-removed; the same one in a class: unknown" \
  "$(jq -c '[(.not_removed[] | select(.symbol == "drush_get_option") | .file), (.unknown[] | select(.symbol == "drush_get_option") | .file)]' "$T_OUT")" \
  '["m.drush.inc","src/Drush8Io.php"]'
assert_eq "  (no core_file for it)" "$(jq -c '[.not_removed[] | select(.symbol == "drush_get_option") | has("core_file")]' "$T_OUT")" '[false]'

# No Drupal root: the core definitions cannot be read, the include case stays unknown.
L="$T_TMP/loose"; mkdir -p "$L"; printf 'name: L\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$L/l.info.yml"
t_run "$T_SH" "$CD" --file "$T_TMP/phpstan.json" --subject "$L" --json
assert_eq "without a Drupal root: only the *.drush.inc one is not-removed" "$(jq -c '[.counts.not_removed, .counts.unknown]' "$T_OUT")" '[1,4]'
t_done
