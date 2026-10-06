#!/usr/bin/env bash
# The recipe fixtures (T-M4-06, 05-R4, ADR 0023): every case of every
# tests/fixtures/recipes/<id>/expect.json, applied by scripts/ai/apply-recipe.sh
# to a copy of its before/ tree, reaches its status and leaves exactly its
# after/ tree (a no-match or not-applicable case leaves before/ as it was).
# No codemod raises the declared core floor: the main info.yml of every case
# is unchanged. Plus the executor's contract: --dry-run writes nothing, a
# postcondition that fails rejects the change (exit 3, nothing written),
# applies_when.core_min against the floor, the usage errors. Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
AR="$T_REPO/scripts/ai/apply-recipe.sh"
FX="$T_REPO/tests/fixtures/recipes"
ar() { t_run "$T_SH" "$AR" "$@"; }

n=0
for d in "$FX"/*/; do
  id="$(basename "$d")"
  assert_eq "$id: a recipe of config/recipes.json with these fixtures" \
    "$(jq -r --arg id "$id" '.recipes[] | select(.id == $id) | .fixtures' "$T_REPO/config/recipes.json")" "tests/fixtures/recipes/$id"
  k=0; nc="$(jq '.cases | length' "$d/expect.json")"
  while [[ "$k" -lt "$nc" ]]; do
    c="$(jq -c --argjson k "$k" '.cases[$k]' "$d/expect.json")"
    cq() { jq -r "$1 // empty" <<< "$c"; }
    w="$T_TMP/case-$n"; n=$((n + 1)); cp -R "$d/$(cq .before)" "$w"
    set -- --recipe "$id" --subject "$w" --file "$(cq .file)" --json
    [[ -n "$(cq .line)" ]] && set -- "$@" --line "$(cq .line)"
    [[ -n "$(cq .severity)" ]] && set -- "$@" --severity "$(cq .severity)"
    [[ -n "$(cq .message)" ]] && set -- "$@" --message "$(cq .message)"
    while IFS= read -r kv; do [[ -n "$kv" ]] && set -- "$@" --param "$kv"; done <<EOF
$(jq -r '(.params // {}) | to_entries[] | "\(.key)=\(.value)"' <<< "$c")
EOF
    ar "$@"
    assert_eq "$id: $(cq .name): exit $(cq .exit_code // 0), $(cq .status)" \
      "$T_RC|$(jq -r '.status' "$T_OUT")" "$(jq -r '.exit_code // 0' <<< "$c")|$(cq .status)"
    assert_eq "  the tree is $(cq .after)/" "$(diff -r "$w" "$d/$(cq .after)" > /dev/null 2>&1 && echo same || echo differs)" "same"
    for mi in "$d/$(cq .before)"/*.info.yml; do
      [[ -f "$mi" ]] || continue
      assert_eq "  the declared floor (the main info.yml) is not raised" \
        "$(grep '^core_version_requirement' "$w/$(basename "$mi")")" "$(grep '^core_version_requirement' "$mi")"
    done
    k=$((k + 1))
  done
done
assert_eq "every codemod of a Docker-free engine has fixtures" \
  "$(jq -c '[.recipes[] | select(.engine | IN("ere-replace", "yaml-edit", "info-yml")) | select(.fixtures == null) | .id]' "$T_REPO/config/recipes.json")" "[]"

# The executor's contract, on the hook fixture.
H="$FX/sig.hook-entity-operation"
w="$T_TMP/dry"; cp -R "$H/before" "$w"
ar --recipe sig.hook-entity-operation --subject "$w" --file m.module --line 14 --dry-run --json
assert_eq "--dry-run: would-apply, the hashes of both versions, nothing written" \
  "$T_RC|$(jq -c '[.status, .changed, (.input_hash != .output_hash)]' "$T_OUT")|$(diff -r "$w" "$H/before" > /dev/null && echo same)" \
  '0|["would-apply",true,true]|same'
assert_eq "  input_hash is the file's" "$(jq -r .input_hash "$T_OUT")" "$(file_hash "$w/m.module")"
# A postcondition that fails: rejected, exit 3, nothing written.
jq '.recipes |= map(if .id == "sig.hook-entity-operation" then .postconditions = [{type: "present-fixed", where: "line", text: "never there"}] else . end)' \
  "$T_REPO/config/recipes.json" > "$T_TMP/recipes-post.json"
ar --recipe sig.hook-entity-operation --recipes "$T_TMP/recipes-post.json" --subject "$w" --file m.module --line 14 --json
assert_eq "a postcondition that fails: rejected, exit 3, nothing written" \
  "$T_RC|$(jq -r .status "$T_OUT")|$(diff -r "$w" "$H/before" > /dev/null && echo same)" '3|rejected|same'
# applies_when.core_min.
jq '.recipes |= map(if .id == "sig.hook-entity-operation" then .applies_when.core_min = "11.3" else . end)' \
  "$T_REPO/config/recipes.json" > "$T_TMP/recipes-min.json"
ar --recipe sig.hook-entity-operation --recipes "$T_TMP/recipes-min.json" --subject "$w" --file m.module --line 14 --core-floor 10.3 --json
assert_eq "core_min 11.3 above the floor 10.3: not-applicable" "$T_RC|$(jq -r .status "$T_OUT")" '0|not-applicable'
ar --recipe sig.hook-entity-operation --recipes "$T_TMP/recipes-min.json" --subject "$w" --file m.module --line 14 --core-floor 11.3 --dry-run --json
assert_eq "  at the floor 11.3: it applies" "$T_RC|$(jq -r .status "$T_OUT")" '0|would-apply'
ar --recipe sig.hook-entity-operation --recipes "$T_TMP/recipes-min.json" --subject "$w" --file m.module --line 14 --json
assert_eq "  no floor known (no --core-floor, no plan): not-applicable" "$T_RC|$(jq -r .status "$T_OUT")" '0|not-applicable'

# Usage errors.
ar --recipe dep.drupal-set-message --subject "$w" --file m.module --line 14
assert_eq "a template recipe has no codemod: exit 1" "$T_RC" "1"
ar --recipe nope --subject "$w" --file m.module
assert_eq "an unknown recipe: exit 1" "$T_RC" "1"
ar --recipe sig.hook-entity-operation --subject "$w" --file ../m.module --line 14
assert_eq "a file outside the subject: exit 1" "$T_RC" "1"
ar --recipe sig.hook-entity-operation --subject "$w" --file m.module
assert_eq "a line recipe without --line: exit 1" "$T_RC" "1"
ar --recipe meta.submodule-core-req --subject "$w" --file m.module --line 1
assert_eq "info-yml with no plan and no --param requirement: exit 1" "$T_RC" "1"
ar --recipe sig.hook-entity-operation --subject "$w" --file m.module --line 14 --bogus
assert_eq "an unknown flag: exit 1" "$T_RC" "1"
t_done
