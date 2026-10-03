#!/usr/bin/env bash
# INV11: setting the core requirement updates every nested info.yml (a
# submodule, too), so each accepts the target after the port.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
m="$T_TMP/fx/acme_search"; mkdir -p "$T_TMP/fx"; cp -R "$T_REPO/tests/fixtures/monorepo/web/modules/custom/acme_search" "$m"
t_run "$T_SH" "$T_REPO/scripts/analysis/set-core-requirement.sh" --subject "$m" --requirement '^10 || ^11' --json
assert_eq "exit" "$T_RC" "0"
assert_eq "every info.yml carries the requirement" \
  "$(find "$m" -name '*.info.yml' -exec sed -n 's/^core_version_requirement: //p' {} \; | LC_ALL=C sort -u | tr '\n' ';')" "^10 || ^11;"
assert_eq "both were updated" "$(find "$m" -name '*.info.yml' | grep -c .)" "2"
t_done
