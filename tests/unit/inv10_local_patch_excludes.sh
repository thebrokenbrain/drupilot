#!/usr/bin/env bash
# INV10 (CC-26): the local patch holds only the port: local-environment residue
# (.ddev/, vendor/, .phpstan-cache/, node_modules/), drupilot's own files
# (.drupilot/ with the staged PHP runtime, .drupilot.json) and its own patches (also -repo.patch) are each
# excluded, and the patch applies on the pristine module.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
command -v git > /dev/null 2>&1 || t_skip "git is not available"
m="$T_TMP/mod/legacy_widgets"; mkdir -p "$T_TMP/mod"; cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$m"
G=(git -C "$m" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false)
"${G[@]}" init -q && "${G[@]}" add -A && "${G[@]}" commit -qm base
cp -R "$m" "$T_TMP/pristine"
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
sed_inplace "$m/legacy_widgets.info.yml" 's/^core_version_requirement: .*/core_version_requirement: ^10 || ^11/'
mkdir -p "$m/.ddev" "$m/vendor/x" "$m/.phpstan-cache" "$m/js/node_modules/y" "$m/.drupilot"
mkdir -p "$m/.drupilot/runtime"
for f in .ddev/config.yaml vendor/x/a.php .phpstan-cache/c js/node_modules/y/i.js .drupilot/port-report.md \
         .drupilot/runtime/anchor.php \
         .drupilot.json legacy_widgets-port-to-drupal-11-repo.patch other-port-to-drupal-11-123-4.patch; do
  printf 'residue\n' > "$m/$f"
done
t_run "$T_SH" "$T_REPO/scripts/contrib/make-patch.sh" --local --subject "$m"
p="$(t_out)"
assert_eq "make-patch --local: exit" "$T_RC" "0"
assert_eq "only the port is in the patch" "$(grep '^diff --git' "$p" 2>/dev/null | tr '\n' ';')" \
  "diff --git a/legacy_widgets.info.yml b/legacy_widgets.info.yml;"
for x in .ddev vendor .phpstan-cache node_modules .drupilot/ .drupilot.json -repo.patch 123-4.patch; do
  assert_eq "excluded: $x" "$(grep '^diff --git' "$p" 2>/dev/null | grep -cF -- "$x" || true)" "0"
done
assert_eq "it applies on the pristine module" "$(cd "$T_TMP/pristine" && git apply --check "$p" > /dev/null 2>&1 && echo ok)" "ok"
t_done
