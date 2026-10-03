#!/usr/bin/env bash
# project_state_path (CC-19): the state key of a path is byte-identical to 0.9:
# the absolute path with every non-alphanumeric byte turned into "_", under
# <data dir>/state; an existing directory is made absolute first.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
export DRUPILOT_HOME="$T_TMP/dh"
assert_eq "known path -> known key" "$(project_state_path '/srv/www/site/web/modules/custom/foo')" \
  "$T_TMP/dh/state/_srv_www_site_web_modules_custom_foo"
assert_eq "spaces, dots and dashes become _" "$(project_state_path '/a b/c.d-e')" "$T_TMP/dh/state/_a_b_c_d_e"
assert_eq "a trailing slash of a missing path is kept in the key" "$(project_state_path '/no/such/dir/')" "$T_TMP/dh/state/_no_such_dir_"
mkdir -p "$T_TMP/real/mod"
assert_eq "an existing relative path is made absolute" "$(cd "$T_TMP/real" && project_state_path mod)" \
  "$T_TMP/dh/state/$(printf '%s' "$T_TMP/real/mod" | tr -c 'A-Za-z0-9' '_')"
assert_eq "it creates nothing" "$([[ -e "$T_TMP/dh" ]] && echo created || echo none)" "none"
t_done
