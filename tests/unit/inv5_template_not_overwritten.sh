#!/usr/bin/env bash
# INV5: a hand-edited generated config is never overwritten without --force,
# and --force keeps a backup of it.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
r="$T_TMP/root"; mkdir -p "$r/web/core/lib" "$r/web/modules/custom"
printf '{"name":"x/root"}\n' > "$r/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$r/web/core/lib/Drupal.php"
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$r/web/modules/custom/"
rt() { t_run "$T_SH" "$T_REPO/scripts/env/render-templates.sh" --root "$r" --subject web/modules/custom/legacy_widgets --only rector "$@" --json; }
rt
assert_eq "first render writes rector.php" "$T_RC|$(jq -r '.files[0].status' "$T_OUT")" "0|written"
printf '\n// hand edit\n' >> "$r/rector.php"; cp "$r/rector.php" "$T_TMP/edited.php"
rt
assert_eq "a hand-edited file differs: exit 3, not replaced" "$T_RC|$(jq -r '.files[0].status' "$T_OUT")" "3|differs"
assert_file_eq "... the hand edit is still there" "$r/rector.php" "$T_TMP/edited.php"
rt --force
assert_eq "--force replaces it" "$T_RC|$(grep -c 'hand edit' "$r/rector.php" || true)" "0|0"
b="$(jq -r '.files[0].backup // empty' "$T_OUT")"
assert_eq "... after a backup of the hand edit" "$([[ -n "$b" && -f "$b" ]] && grep -c 'hand edit' "$b" || echo none)" "1"
t_done
