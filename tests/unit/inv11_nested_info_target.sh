#!/usr/bin/env bash
# INV11: setting the core requirement updates every nested info.yml (a
# submodule, too), so each accepts the target after the port.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
m="$T_TMP/fx/acme_search"; mkdir -p "$T_TMP/fx"; cp -R "$T_REPO/tests/fixtures/monorepo/web/modules/custom/acme_search" "$m"
t_run "$T_SH" "$T_REPO/scripts/analysis/set-core-requirement.sh" --subject "$m" --requirement '^10 || ^11' --json
assert_eq "exit" "$T_RC" "0"
n="$(find "$m" -name '*.info.yml' | grep -c .)"
assert_eq "the fixture has a main and a nested info.yml" "$n" "2"
assert_eq "every info.yml carries exactly the requirement" \
  "$(find "$m" -name '*.info.yml' -exec grep -lx 'core_version_requirement: ^10 || ^11' {} + | grep -c .)" "$n"
assert_eq "... and no other core_version_requirement line" \
  "$(find "$m" -name '*.info.yml' -exec grep -h '^core_version_requirement:' {} + | grep -vxc 'core_version_requirement: ^10 || ^11' || true)" "0"
t_done
