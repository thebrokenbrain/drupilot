#!/usr/bin/env bash
# subject_digest, algorithm 2 (T-M4-01, T-M4-02, AR-13, 05 G12): a Twig, JS or
# CSS edit changes the digest (algorithm 1 saw only the PHP family, *.yml and
# composer.json); drupilot's own outputs next to the module, .git, vendor and
# node_modules do not. Every digest changed once with algorithm 2, also for a
# subject without Twig/JS/CSS, so an artifact a 0.9 run recorded is never
# taken as fresh (it has no digest_algo 2); subject_digest_algo names it.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

S="$T_TMP/legacy_widgets"
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$S"
d0="$(subject_digest "$S")"
assert_match "a 64-hex digest" "$d0" '^[0-9a-f]{64}$'
assert_eq "subject_digest_algo is 2" "$(subject_digest_algo)" "2"

changed() { local d; d="$(subject_digest "$S")"; [[ "$d" != "$d0" ]] && echo changed || echo same; d0="$d"; }
mkdir -p "$S/templates" "$S/js" "$S/css"
printf '<div>{{ widget }}</div>\n' > "$S/templates/widget.html.twig"
assert_eq "a new Twig template changes it" "$(changed)" "changed"
printf '<div>{{- widget -}}</div>\n' > "$S/templates/widget.html.twig"
assert_eq "a Twig-only edit changes it" "$(changed)" "changed"
printf 'Drupal.behaviors.w = {};\n' > "$S/js/w.js"
assert_eq "a JS file changes it" "$(changed)" "changed"
printf '.w { color: red; }\n' > "$S/css/w.css"
assert_eq "a CSS file changes it" "$(changed)" "changed"
printf '.w { color: blue; }\n' > "$S/css/w.css"
assert_eq "a CSS-only edit changes it" "$(changed)" "changed"
printf 'diff\n' > "$S/legacy_widgets-port-to-drupal-11.patch"
printf '# issue\n' > "$S/legacy_widgets-issue.md"
assert_eq "a local patch or issue text next to the module does not" "$(changed)" "same"
mkdir -p "$S/node_modules/x" "$S/vendor/y" "$S/.git"
printf 'x\n' > "$S/node_modules/x/i.js"; printf 'y\n' > "$S/vendor/y/s.css"; printf 'z\n' > "$S/.git/a.twig"
assert_eq "node_modules, vendor and .git do not" "$(changed)" "same"
assert_eq "the same tree elsewhere: the same digest" "$(cp -R "$S" "$T_TMP/copy" && subject_digest "$T_TMP/copy")" "$d0"

# Algorithm 1 (drupilot 0.9), restated: on a subject without Twig/JS/CSS its
# digest still differs from algorithm 2's.
v1() {
  ( cd -P "$1" && find . \( -name .git -o -name vendor -o -name node_modules \) -prune -o -type f \
      \( -name '*.php' -o -name '*.module' -o -name '*.inc' -o -name '*.install' -o -name '*.theme' \
         -o -name '*.profile' -o -name '*.engine' -o -name '*.yml' -o -name composer.json \) -print \
      | LC_ALL=C sort | while IFS= read -r f; do printf '%s\n' "$f"; cat "$f"; done ) | sha256_hex
}
P="$T_TMP/plain"; cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$P"
assert_eq "the fixture has no Twig/JS/CSS" "$(find "$P" \( -name '*.twig' -o -name '*.js' -o -name '*.css' \) | grep -c . || true)" "0"
assert_eq "an algorithm-1 digest never equals the algorithm-2 one" \
  "$([[ -n "$(v1 "$P")" && "$(v1 "$P")" != "$(subject_digest "$P")" ]] && echo differ)" "differ"
assert_eq "the 0.9 baseline digest of legacy_widgets is algorithm 1's" \
  "$(jq -r '.stdout.subject_digest' "$T_REPO/tests/baseline/v0.9.0/lw-lint-extension-metadata.json" 2> /dev/null)" "$(v1 "$P")"
t_done
