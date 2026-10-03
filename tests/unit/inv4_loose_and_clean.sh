#!/usr/bin/env bash
# INV4: never scaffold over a loose checkout (its test-bed is a sibling
# <name>-d11 directory, never the checkout itself), and clean.sh proposes
# nothing for a root drupilot did not create.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
mkdir -p "$T_TMP/loose" "$T_TMP/site/web/core/lib" "$T_TMP/site/web/modules/custom"
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$T_TMP/loose/"
printf '{"name":"x/site"}\n' > "$T_TMP/site/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$T_TMP/site/web/core/lib/Drupal.php"
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$T_TMP/site/web/modules/custom/"
t_run "$T_SH" "$T_REPO/scripts/env/resolve-workspace.sh" --subject "$T_TMP/loose/legacy_widgets" --json
assert_json_eq "a loose checkout gets a sibling test-bed" "$(jq -c '{loose, drupal_root}' "$T_OUT")" \
  "{\"loose\":true,\"drupal_root\":\"$T_TMP/loose/legacy_widgets-d11\"}"
assert_tree_unchanged "resolving the workspace writes nothing in the checkout" "$T_TMP/loose" \
  "$T_SH" "$T_REPO/scripts/env/resolve-workspace.sh" --subject "$T_TMP/loose/legacy_widgets" --json
assert_tree_unchanged "clean.sh --dry-run on a site drupilot did not build changes nothing" "$T_TMP/site" \
  "$T_SH" "$T_REPO/scripts/env/clean.sh" --subject "$T_TMP/site/web/modules/custom/legacy_widgets" --level workspace --dry-run --json
assert_json_eq "... and proposes no action" "$(jq -c '[.roots[] | {kind: (.testbed_kind // .kind), actions: [.actions[]?.op]}]' "$T_OUT")" \
  '[{"kind":"none","actions":[]}]'
t_done
