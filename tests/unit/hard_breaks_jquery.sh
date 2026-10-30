#!/usr/bin/env bash
# config/catalog/hard-breaks.json, the jQuery categories (training run module
# 09, material_admin: $.isNumeric() broke on jQuery 4, .uniqueId() came from
# jQuery UI): each pattern, read from the catalog, matches the removed calls
# and not their look-alikes.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
CAT="$T_REPO/config/catalog/hard-breaks.json"
ere() { jq -r --arg id "$1" '.entries[] | select(.id == $id) | .ere' "$CAT"; }
hits() { printf '%s\n' "$2" | grep -c -E -- "$(ere "$1")" || true; }

assert_eq "jquery4: the removed utilities match" \
  "$(hits jquery4 '$.isNumeric(x)
jQuery.trim(s)
$.isArray(a)
$.parseJSON(j)
$.isFunction(f)
$.type(v)
$.now()
jQuery.unique(list)')" "8"
assert_eq "  what jQuery 4 keeps does not" \
  "$(hits jquery4 '$.extend({}, a)
$.each(list, f)
Drupal.behaviors.x = {};
$.trimmed(s)
myLib.isNumeric(x)')" "0"
assert_eq "jquery_ui: .uniqueId() and .removeUniqueId() match, the library names still do" \
  "$(hits jquery_ui '$(el).uniqueId();
$(el).removeUniqueId();
  - core/jquery.ui.dialog')" "3"
assert_eq "  a method that only shares the prefix does not" "$(hits jquery_ui 'obj.uniqueIdentifier()')" "0"
assert_eq "jquery4 is a *.js category, never blocking" "$(jq -c '.entries[] | select(.id == "jquery4") | [.globs, .blocking, .verified]' "$CAT")" '[["*.js"],false,true]'
t_done
