#!/usr/bin/env bash
# The docs gate of scripts/dev/check.sh (T-M1-14, T-M1-18, 08-R6), on a
# scratch copy of what it reads: it passes (or only warns about the root
# FLOW*.md) on HEAD, and fails on each injected fault: an ADR page with no nav
# line, a nav entry with no page, a drifted generated page, a broken relative
# link, a README-section citation and a citation of a missing docs page. A
# root FLOW*.md is only noted; a Spanish page under docs/ warns.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
r="$T_TMP/tree"; mkdir -p "$r"
for d in scripts config hooks commands skills agents docs; do cp -R "$T_REPO/$d" "$r/"; done
cp "$T_REPO/mkdocs.yml" "$r/"
# gate -> "<status>|<first finding>"
gate() {
  "$T_SH" "$r/scripts/dev/check.sh" --only docs --json 2>/dev/null | jq -r '.gates[0] | "\(.status)|\(.findings[0] // "")"'
}
assert_eq "HEAD passes (no FLOW*.md in the copy)" "$(gate | cut -d'|' -f1)" "pass"
printf '# FLOW\n' > "$r/FLOW.md"
assert_eq "a root FLOW*.md is only noted" "$(gate | cut -d'|' -f1)" "pass"
assert_match "... in the detail" "$("$T_SH" "$r/scripts/dev/check.sh" --only docs --json 2>/dev/null | jq -r '.gates[0].detail')" 'to move into docs/concepts/how-it-works\.md: FLOW\.md$'
rm "$r/FLOW.md"
printf '# Hola\n' > "$r/docs/index_es.md"; cp "$r/mkdocs.yml" "$T_TMP/mk0.bak"
sed 's#^  - Home: index.md#  - Home: index.md\n  - Inicio: index_es.md#' "$T_TMP/mk0.bak" > "$r/mkdocs.yml"
assert_match "a Spanish page under docs/ warns" "$(gate)" '^warn\|docs/index_es\.md \(the site is English only\)'
rm "$r/docs/index_es.md"; cp "$T_TMP/mk0.bak" "$r/mkdocs.yml"

printf '# 9999 — An orphan\n' > "$r/docs/contributing/adr/9999-orphan.md"
assert_eq "an ADR page with no nav line fails" "$(gate)" "fail|docs/contributing/adr/9999-orphan.md is not in the mkdocs.yml nav"
rm "$r/docs/contributing/adr/9999-orphan.md"

cp "$r/mkdocs.yml" "$T_TMP/mk.bak"
sed 's#^  - Changelog: changelog.md#  - Changelog: changelog.md\n  - Missing: missing.md#' "$T_TMP/mk.bak" > "$r/mkdocs.yml"
assert_eq "a nav entry with no page fails" "$(gate)" "fail|mkdocs.yml nav entry missing.md does not exist under docs/"
sed 's#^  - Changelog: changelog.md#  - Changelog: changelog.md\n  \# - Planned: planned.md#' "$T_TMP/mk.bak" > "$r/mkdocs.yml"
assert_eq "a commented planned line is ignored" "$(gate | cut -d'|' -f1)" "pass"
cp "$T_TMP/mk.bak" "$r/mkdocs.yml"

printf 'hand edit\n' >> "$r/docs/reference/choices.md"
assert_match "a drifted generated page fails" "$(gate)" "^fail\|generated pages drift"
cp "$T_REPO/docs/reference/choices.md" "$r/docs/reference/choices.md"
cp "$T_REPO/config/choices.json" "$T_TMP/ch.bak"
jq '.choices.PUSH.header = "Push it"' "$T_TMP/ch.bak" > "$r/config/choices.json"
assert_match "a source change without regenerating fails" "$(gate)" "^fail\|generated pages drift"
cp "$T_TMP/ch.bak" "$r/config/choices.json"

printf '\nSee [the guide](../guides/nowhere.md#x).\n' >> "$r/docs/contributing/checks.md"
assert_eq "a broken relative link fails" "$(gate)" "fail|docs/contributing/checks.md links to ../guides/nowhere.md, which does not exist"
cp "$T_REPO/docs/contributing/checks.md" "$r/docs/contributing/checks.md"

printf '\nThe schema is in README "Per-module state".\n' >> "$r/commands/drupilot-status.md"
assert_match "a README-section citation fails" "$(gate)" '^fail\|commands/drupilot-status\.md:[0-9]+:.*README "Per-module state"'
cp "$T_REPO/commands/drupilot-status.md" "$r/commands/drupilot-status.md"
printf '\n# See docs/guides/nowhere.md.\n' >> "$r/scripts/env/state.sh"
assert_eq "a citation of a missing docs page fails" "$(gate)" "fail|scripts/env/state.sh cites docs/guides/nowhere.md, which does not exist"

# A change-record link is encoded the same on every jq (jq 1.6 leaves ( ) ! * '
# unencoded, jq 1.7+ encodes them).
jq '.deprecations += [{"pattern": "drupal_get_path\\(", "symbol": "drupal_get_path()", "why": "w", "fix": "f"}]' \
  "$T_REPO/config/deprecations.json" > "$r/config/deprecations.json"
"$T_SH" "$r/scripts/dev/gen-docs.sh" --out "$T_TMP/gen" > /dev/null 2>&1
assert_match "a symbol with parentheses gets %28%29 on any jq" \
  "$(grep -F 'drupal_get_path' "$T_TMP/gen/deprecations.md" | grep 'Change records')" 'keywords_description=drupal_get_path%28%29>$'
t_done
