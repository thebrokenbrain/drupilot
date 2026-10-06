#!/usr/bin/env bash
# config/recipes.json is generated from the catalogs (T-M4-06, CC-33, ADR
# 0023): gen-recipes.sh --check is green on HEAD; every catalog entry has its
# recipe (dep.*, sig.*, safety.*, meta.*, and the lifecycle symbols in some
# recipe's matches); config/metadata-checks.json lists exactly the lint's
# ALL_CHECKS; a [tag] explainer is the template of its safety.* recipe; and,
# on a copy of the repository: a hand edit of recipes.json, a codemod without
# fixtures and a search that is not POSIX ERE fail --check, while a changed
# catalog text changes only its own recipe's version.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
GR="$T_REPO/scripts/dev/gen-recipes.sh"
RJ="$T_REPO/config/recipes.json"

t_run "$T_SH" "$GR" --check --json
assert_eq "gen-recipes.sh --check: green on HEAD" "$T_RC|$(jq -c '[.ok, .drift, .problems]' "$T_OUT")" '0|[true,false,[]]'
assert_eq "  schema drupilot.recipes/1, the three sources hashed" \
  "$(jq -c '[.schema, (.sources | keys)]' "$RJ")" '["drupilot.recipes/1",["config/deprecations.json","config/metadata-checks.json","config/port-checks.json"]]'
assert_eq "every signature change has its sig.* recipe" \
  "$(jq -c --slurpfile r "$RJ" '[.signature_changes[].id | "sig." + .] - [$r[0].recipes[].id]' "$T_REPO/config/deprecations.json")" "[]"
assert_eq "every port-safety check has its safety.* recipe" \
  "$(jq -c --slurpfile r "$RJ" '[.checks | keys[] | "safety." + .] - [$r[0].recipes[].id]' "$T_REPO/config/port-checks.json")" "[]"
assert_eq "every deprecations entry that is not a [tag] explainer has a dep.* recipe matching its pattern" \
  "$(jq -c --slurpfile r "$RJ" '[.deprecations[] | select(.pattern | startswith("\\[") | not) | .pattern] - [$r[0].recipes[] | .matches.message_ere // empty]' "$T_REPO/config/deprecations.json")" "[]"
assert_eq "every lifecycle symbol is matched by a recipe" \
  "$(jq -c --slurpfile r "$RJ" '[.lifecycle[].symbol] - [$r[0].recipes[] | (.matches.symbols // [])[]]' "$T_REPO/config/deprecations.json")" "[]"
lint_checks="$(sed -n 's/^ALL_CHECKS="\(.*\)"$/\1/p' "$T_REPO/scripts/analysis/lint-extension-metadata.sh" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "metadata-checks.json lists exactly the lint's ALL_CHECKS" \
  "$(jq -r '.checks | keys[]' "$T_REPO/config/metadata-checks.json" | LC_ALL=C sort | tr '\n' ' ')" "$lint_checks"
assert_eq "a [tag] explainer is the template of its safety.* recipe (plugin-di)" \
  "$(jq -r '.recipes[] | select(.id == "safety.plugin-di") | .template.fix' "$RJ")" \
  "$(jq -r '.deprecations[] | select(.pattern | startswith("\\[plugin-di\\]")) | .fix' "$T_REPO/config/deprecations.json")"
assert_eq "the lanes: codemods, AI templates, and the human ones" \
  "$(jq -c '[.recipes[] | select(.lane == "codemod") | .id]' "$RJ")" \
  '["meta.submodule-core-req","safety.class-case","sig.hook-entity-operation","sig.hook-entity-operation-alter"]'
assert_eq "  jQuery UI and CKEditor 5 go to a person" \
  "$(jq -c '[.recipes[] | select(.id == "dep.jquery-ui" or .id == "dep.ckeditor-5") | .lane]' "$RJ")" '["human","human"]'
assert_eq "every version is 12 hex, every id unique" \
  "$(jq -c '[(.recipes | map(.version | test("^[0-9a-f]{12}$")) | all), ((.recipes | map(.id) | unique | length) == (.recipes | length))]' "$RJ")" '[true,true]'

# On a copy: drift, a missing fixture, a non-POSIX search, a version change.
C="$T_TMP/repo"; mkdir -p "$C/scripts/dev" "$C/tests/fixtures"
cp -R "$T_REPO/scripts/lib" "$C/scripts/"; cp "$GR" "$C/scripts/dev/"; cp -R "$T_REPO/config" "$C/"
cp -R "$T_REPO/tests/fixtures/recipes" "$C/tests/fixtures/"
gr() { t_run env CLAUDE_PLUGIN_ROOT="$C" "$T_SH" "$C/scripts/dev/gen-recipes.sh" "$@"; }
gr --check
assert_eq "the copy: green" "$T_RC" "0"
jq '.recipes[0].template.why = "edited"' "$C/config/recipes.json" > "$T_TMP/r.json" && cp "$T_TMP/r.json" "$C/config/recipes.json"
gr --check --json
assert_eq "a hand edit of recipes.json: drift, exit 1" "$T_RC|$(jq -c '.drift' "$T_OUT")" '1|true'
gr --write
assert_eq "  --write restores it" "$T_RC|$(cmp -s "$C/config/recipes.json" "$RJ" && echo same)" "0|same"
v_before="$(jq -c '[.recipes[] | {key: .id, value: .version}] | from_entries' "$C/config/recipes.json")"
jq '(.deprecations[] | select(.symbol == "drupal_set_message") | .fix) |= . + " Edited."' "$C/config/deprecations.json" > "$T_TMP/d.json" \
  && cp "$T_TMP/d.json" "$C/config/deprecations.json"
gr --check
assert_eq "a catalog change without --write: drift" "$T_RC" "1"
gr --write
assert_eq "  after --write: only dep.drupal-set-message changed its version" \
  "$(jq -c --argjson b "$v_before" '[.recipes[] | select($b[.id] != .version) | .id]' "$C/config/recipes.json")" '["dep.drupal-set-message"]'
mv "$C/tests/fixtures/recipes/safety.class-case" "$T_TMP/cc-fixture"
gr --write --json
assert_eq "a Docker-free codemod without fixtures: exit 1, named, nothing written" \
  "$T_RC|$(jq -r '.problems[0]' "$T_OUT" | grep -c 'safety.class-case: a Docker-free codemod needs' || true)" "1|1"
mv "$T_TMP/cc-fixture" "$C/tests/fixtures/recipes/safety.class-case"
jq '(.signature_changes[] | select(.id == "hook-entity-operation") | .recipe.params.search) = "\\bCacheableMetadata"' "$C/config/deprecations.json" > "$T_TMP/d.json" \
  && cp "$T_TMP/d.json" "$C/config/deprecations.json"
gr --check --json
assert_eq "a search that is not POSIX ERE (\\b): exit 1, named" \
  "$T_RC|$(jq -r '.problems[]' "$T_OUT" | grep -c 'sig.hook-entity-operation: params.search is not POSIX ERE' || true)" "1|1"
gr --bogus
assert_eq "an unknown flag: exit 1" "$T_RC" "1"
t_done
