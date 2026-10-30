#!/usr/bin/env bash
# deps-status.sh reading the release-history feed (training run module 10,
# image_resize_filter: ckeditor, an unsupported project whose releases are all
# ^9.4 || ^10, was reported not-on-drupalorg, so the verdict missed the
# blocker), with a stub curl that serves one feed per project:
# - an unsupported project with releases is classified by its releases
#   (not-ready, a blocker);
# - a core_compatibility that admits 11 is ready ('^10.3 || ^11'), one that
#   only names 11 as an excluding bound is not ('>=9 <11');
# - an <error> feed stays not-on-drupalorg; a core module is core;
# - a ready project whose composer.json constraint admits none of its ready
#   majors (module 12, location_migration: drupal/address ^1.8, D11 from 2.x)
#   says so; one whose constraint admits one does not.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
DS="$T_REPO/scripts/analysis/deps-status.sh"
FEEDS="$T_TMP/feeds"; mkdir -p "$FEEDS"
feed() { printf '<?xml version="1.0"?>\n<project><short_name>%s</short_name>%s<releases>%s</releases></project>\n' "$1" "$2" "$3" > "$FEEDS/$1.xml"; }
rel() { printf '<release><version>%s</version><core_compatibility>%s</core_compatibility></release>' "$1" "$2"; }
feed ckeditor '<project_status>unsupported</project_status>' "$(rel 1.0.2 '^9.4 || ^10')$(rel 1.0.1 '^9.4 || ^10')"
feed token '<project_status>published</project_status>' "$(rel 1.17.0 '^10.3 || ^11')"
feed bounded '<project_status>published</project_status>' "$(rel 2.4.1 '&gt;=8.9 &lt;11.0.0-stable')"
feed addr '<project_status>published</project_status>' "$(rel 2.0.4 '^10.3 || ^11')$(rel 8.x-1.12 '^9.2 || ^10')"
printf '<?xml version="1.0"?>\n<error>No release history was found for the requested project (gone).</error>\n' > "$FEEDS/gone.xml"
mk_bin() { printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
STUBS="$T_TMP/bin"; mkdir -p "$STUBS"
mk_bin "$STUBS/curl" 'u=""; for a in "$@"; do u="$a"; done; p="${u#*release-history/}"; p="${p%%/*}"; [ -f "$FEEDS/$p.xml" ] || exit 22; cat "$FEEDS/$p.xml"'
export FEEDS

M="$T_TMP/m"; mkdir -p "$M"
printf 'name: M\ntype: module\ncore_version_requirement: ^10 || ^11\ndependencies:\n  - ckeditor:ckeditor\n  - token:token\n  - bounded:bounded\n  - gone:gone\n  - drupal:filter\n' > "$M/m.info.yml"
printf '{"require": {"drupal/addr": "^1.8", "drupal/token": "^1.15"}}\n' > "$M/composer.json"
t_run env PATH="$STUBS:$PATH" "$T_SH" "$DS" --subject "$M" --json
assert_eq "deps-status: exit 0" "$T_RC" "0"
assert_eq "unsupported with releases: not-ready; ^10.3 || ^11 ready; an excluding <11 bound not-ready; an <error> feed not-on-drupalorg; filter core" \
  "$(jq -c '[.dependencies[] | [.project, .d11]]' "$T_OUT")" \
  '[["addr","ready"],["bounded","not-ready"],["ckeditor","not-ready"],["filter","core"],["gone","not-on-drupalorg"],["token","ready"]]'
assert_eq "  the totals: two blockers" "$(jq -c '.totals' "$T_OUT")" '{"ready":3,"blockers":2,"unknown":1}'
assert_eq "  composer.json ^1.8 admits no ready major (2); ^1.15 admits 1" \
  "$(jq -c '[.dependencies[] | select(has("constraint")) | [.project, .constraint, .constraint_admits_ready, .ready_majors]]' "$T_OUT")" \
  '[["addr","^1.8",false,["2"]],["token","^1.15",true,["1"]]]'
t_run env PATH="$STUBS:$PATH" "$T_SH" "$DS" --subject "$M"
assert_match "  the table tells to widen it" "$(cat "$T_ERR")" "addr .*D11-ready from major 2, but composer.json requires '\^1\.8': widen the constraint"
t_done
