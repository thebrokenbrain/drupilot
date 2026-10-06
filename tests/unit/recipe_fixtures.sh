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
    assert_eq "$id: $(cq .name): exit $(cq '.exit_code // 0'), $(cq .status)" \
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
# A placeholder that does not resolve, or a capture that matches nothing,
# fails the postcondition (closed): rejected, nothing written.
jq '.recipes |= map(if .id == "sig.hook-entity-operation" then .postconditions[1].ere = "\\${vra}([^A-Za-z0-9_]|$)" else . end)' \
  "$T_REPO/config/recipes.json" > "$T_TMP/recipes-typo.json"
ar --recipe sig.hook-entity-operation --recipes "$T_TMP/recipes-typo.json" --subject "$w" --file m.module --line 14 --json
assert_eq "an unresolved {placeholder}: rejected, exit 3, nothing written" \
  "$T_RC|$(jq -r .status "$T_OUT")|$(diff -r "$w" "$H/before" > /dev/null && echo same)" '3|rejected|same'
jq '.recipes |= map(if .id == "sig.hook-entity-operation" then .params.captures.var = "NoSuchType[[:space:]]+\\$([a-z]+)" else . end)' \
  "$T_REPO/config/recipes.json" > "$T_TMP/recipes-empty.json"
ar --recipe sig.hook-entity-operation --recipes "$T_TMP/recipes-empty.json" --subject "$w" --file m.module --line 14 --json
assert_eq "a capture that matches nothing: rejected, exit 3" "$T_RC|$(jq -r .status "$T_OUT")" '3|rejected'

# function-body is over-approximated on purpose: a "}" inside a string does
# not end the body; a one-line body and a comment inside the body count right.
mkh() {  # mkh FILE SIGNATURE_AND_BODY...: a module file whose line 3 is the hook
  local f="$1"; shift
  { printf '<?php\n\n'; printf '%s\n' "$@"; } > "$f"
}
hb() { w2="$T_TMP/hb-$1"; rm -rf "$w2"; mkdir -p "$w2"; shift; mkh "$w2/m.module" "$@"
  ar --recipe sig.hook-entity-operation --subject "$w2" --file m.module --line 3 --json; }
hb css 'function m_entity_operation(EntityInterface $e, CacheableMetadata $c) {' "  \$css = '" '.m {' '}' "';" "  \$c->addCacheTags(['x']);" '}'
assert_eq "a '}' at column 0 inside a string does not end the body: the use is found, rejected" "$T_RC|$(jq -r .status "$T_OUT")" '3|rejected'
hb oneline 'function m_entity_operation(EntityInterface $e, CacheableMetadata $c) { return [$c]; }'
assert_eq "a one-line body that uses the parameter: rejected" "$T_RC|$(jq -r .status "$T_OUT")" '3|rejected'
hb comment 'function m_entity_operation(EntityInterface $e, CacheableMetadata $c) {' '  // $c is not used here.' '  return [];' '}' '' 'function m_other(EntityInterface $e, CacheableMetadata $c) {' '  return [$c];' '}'
assert_eq "a comment in the body, and the next function using the same name: applied" "$T_RC|$(jq -r .status "$T_OUT")" '0|applied'
jq '.recipes |= map(if .id == "sig.hook-entity-operation" then .postconditions[1].ere = "\\${var}(" else . end)' \
  "$T_REPO/config/recipes.json" > "$T_TMP/recipes-bad-ere.json"
w3="$T_TMP/hb-bad"; mkdir -p "$w3"; cp "$H/before/m.module" "$w3/"
ar --recipe sig.hook-entity-operation --recipes "$T_TMP/recipes-bad-ere.json" --subject "$w3" --file m.module --line 14 --json
assert_eq "a postcondition ERE that does not compile: rejected, exit 3" "$T_RC|$(jq -r .status "$T_OUT")" '3|rejected'

# applies_when.core_min.
jq '.recipes |= map(if .id == "sig.hook-entity-operation" then .applies_when.core_min = "11.3" else . end)' \
  "$T_REPO/config/recipes.json" > "$T_TMP/recipes-min.json"
ar --recipe sig.hook-entity-operation --recipes "$T_TMP/recipes-min.json" --subject "$w" --file m.module --line 14 --core-floor 10.3 --json
assert_eq "core_min 11.3 above the floor 10.3: not-applicable" "$T_RC|$(jq -r .status "$T_OUT")" '0|not-applicable'
ar --recipe sig.hook-entity-operation --recipes "$T_TMP/recipes-min.json" --subject "$w" --file m.module --line 14 --core-floor 11.3 --dry-run --json
assert_eq "  at the floor 11.3: it applies" "$T_RC|$(jq -r .status "$T_OUT")" '0|would-apply'
ar --recipe sig.hook-entity-operation --recipes "$T_TMP/recipes-min.json" --subject "$w" --file m.module --line 14 --json
assert_eq "  no floor known (no --core-floor, no plan): not-applicable" "$T_RC|$(jq -r .status "$T_OUT")" '0|not-applicable'

# A symlinked subject (DRUPILOT_PLACEMENT=symlink): info-yml works on a copy
# of the real tree, so --dry-run writes nothing and only the finding's file
# changes.
M="$FX/meta.submodule-core-req"
cp -R "$M/main-core-key/before" "$T_TMP/origin"; ln -s "$T_TMP/origin" "$T_TMP/link"
ar --recipe meta.submodule-core-req --subject "$T_TMP/link" --file modules/m_extra/m_extra.info.yml --line 5 --severity warning --param 'requirement=^10 || ^11' --dry-run --json
assert_eq "a symlinked subject, --dry-run: would-apply, the real tree untouched" \
  "$T_RC|$(jq -r .status "$T_OUT")|$(diff -r "$T_TMP/origin" "$M/main-core-key/before" > /dev/null && echo same)" '0|would-apply|same'
ar --recipe meta.submodule-core-req --subject "$T_TMP/link" --file modules/m_extra/m_extra.info.yml --line 5 --severity warning --param 'requirement=^10 || ^11' --json
assert_eq "  applied: only the finding's file changed" \
  "$T_RC|$(jq -r .status "$T_OUT")|$(diff -r "$T_TMP/origin" "$M/main-core-key/after" > /dev/null && echo same)" '0|applied|same'
# The plan in a shared root's lock that belongs to another module is not used.
SR="$T_TMP/shared"; SB="$SR/web/modules/custom/m"; mkdir -p "$SR/web/core/lib" "$SR/web/modules/custom"
printf '{"name":"x/shared"}\n' > "$SR/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$SR/web/core/lib/Drupal.php"
cp -R "$M/before" "$SB"
DRUPILOT_PROJECT_DIR="$SR" lock_set_json .upgrade_plan '{"subject": {"machine_name": "other"}, "range": {"constraint": "^11.2", "floor": "11.2"}}' > /dev/null
ar --recipe meta.submodule-core-req --subject "$SB" --file modules/m_extra/m_extra.info.yml --line 5 --severity warning
assert_eq "another module's frozen plan: no requirement, exit 1, nothing written" \
  "$T_RC|$(diff -r "$SB" "$M/before" > /dev/null && echo same)" "1|same"
jq '.recipes |= map(if .id == "meta.submodule-core-req" then .applies_when.core_min = "10.0" else . end)' "$T_REPO/config/recipes.json" > "$T_TMP/recipes-cm.json"
ar --recipe meta.submodule-core-req --recipes "$T_TMP/recipes-cm.json" --subject "$SB" --file modules/m_extra/m_extra.info.yml --line 5 --severity warning --param 'requirement=^10 || ^11' --json
assert_eq "  nor its floor for core_min: not-applicable" "$T_RC|$(jq -r .status "$T_OUT")" '0|not-applicable'
DRUPILOT_PROJECT_DIR="$SR" lock_set_json .upgrade_plan '{"subject": {"machine_name": "m"}, "range": {"constraint": "^10 || ^11", "floor": "10.0"}}' > /dev/null
ar --recipe meta.submodule-core-req --subject "$SB" --file modules/m_extra/m_extra.info.yml --line 5 --severity warning --json
assert_eq "  its own frozen plan: the plan's range" "$T_RC|$(jq -r '[.status, .to] | join("|")' "$T_OUT")" '0|applied|^10 || ^11'

# The floor guard reads "core_version_requirement :" too.
w4="$T_TMP/floor-space"; cp -R "$FX/meta.submodule-core-req/before" "$w4"
sed_inplace "$w4/m.info.yml" 's/^core_version_requirement: /core_version_requirement : /'
ar --recipe meta.submodule-core-req --subject "$w4" --file modules/m_extra/m_extra.info.yml --line 5 --severity warning --param 'requirement=^10.3 || ^11' --json
assert_eq "\"core_version_requirement :\" with a space: the floor guard still holds (not-applicable)" "$T_RC|$(jq -r .status "$T_OUT")" '0|not-applicable'

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
