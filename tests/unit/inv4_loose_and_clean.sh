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
# Something a --level vendor run would delete in a test-bed drupilot built.
mkdir -p "$T_TMP/site/vendor"; printf '<?php\n' > "$T_TMP/site/vendor/autoload.php"
t_run "$T_SH" "$T_REPO/scripts/env/resolve-workspace.sh" --subject "$T_TMP/loose/legacy_widgets" --json
assert_json_eq "a loose checkout gets a sibling test-bed" "$(jq -c '{loose, drupal_root}' "$T_OUT")" \
  "{\"loose\":true,\"drupal_root\":\"$T_TMP/loose/legacy_widgets-d11\"}"
assert_tree_unchanged "resolving the workspace writes nothing in the checkout" "$T_TMP/loose" \
  "$T_SH" "$T_REPO/scripts/env/resolve-workspace.sh" --subject "$T_TMP/loose/legacy_widgets" --json
assert_tree_unchanged "clean.sh --dry-run on a site drupilot did not build changes nothing" "$T_TMP/site" \
  "$T_SH" "$T_REPO/scripts/env/clean.sh" --subject "$T_TMP/site/web/modules/custom/legacy_widgets" --level workspace --dry-run --json
assert_json_eq "... and proposes no action" "$(jq -c '[.roots[] | {kind: (.testbed_kind // .kind), actions: [.actions[]?.op]}]' "$T_OUT")" \
  '[{"kind":"none","actions":[]}]'
assert_match "... refused as not a drupilot test-bed" "$(jq -r '.roots[0] | .status + ": " + .reason' "$T_OUT")" \
  '^refused: not a drupilot test-bed'
# --level vendor has no placed-subject check of its own, and a real run
# (--yes, no --dry-run) must still leave the site untouched.
assert_tree_unchanged "clean.sh --level vendor --yes on that site changes nothing" "$T_TMP/site" \
  "$T_SH" "$T_REPO/scripts/env/clean.sh" --subject "$T_TMP/site/web/modules/custom/legacy_widgets" --level vendor --yes --json
assert_match "... refused as not a drupilot test-bed" "$(jq -r '.roots[0] | .status + ": " + .reason' "$T_OUT")" \
  '^refused: not a drupilot test-bed'
assert_eq "... with the documented exit code 3, and vendor/ is still there" \
  "$T_RC|$([[ -f "$T_TMP/site/vendor/autoload.php" ]] && echo kept || echo deleted)" "3|kept"
t_done
