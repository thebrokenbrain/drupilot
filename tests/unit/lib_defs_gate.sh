#!/usr/bin/env bash
# The lib-defs gate of scripts/dev/check.sh (T-M3-10, AR-21), on a scratch
# copy of the tree: green on HEAD; it fails on a function defined in two libs,
# on a function common.sh defines itself, on a domain lib common.sh does not
# list (or lists twice), and on a hook whose
# _DRUPILOT_LIBS misses a lib it reaches, directly or through another
# function (a one-line body included) or through common.sh's own calls, or in
# a form the gate cannot read. A hook's lib list sources exactly those libs,
# and only in a hook's own process.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
r="$T_TMP/tree"
mkdir -p "$r/scripts" "$r/hooks"
cp -R "$T_REPO/scripts/dev" "$T_REPO/scripts/lib" "$r/scripts/"
cp -R "$T_REPO/hooks/scripts" "$r/hooks/"
# gate -> "<status>|<first finding>"
gate() {
  "$T_SH" "$r/scripts/dev/check.sh" --only lib-defs --json 2>/dev/null | jq -r '.gates[0] | "\(.status)|\(.findings[0] // "")"'
}
keep() { cp "$r/$1" "$T_TMP/keep"; }
back() { cp "$T_TMP/keep" "$r/$1"; }
assert_eq "green on HEAD" "$(gate)" "pass|"

keep scripts/lib/git.sh
printf '\ntrim() {\n  printf %%s "$1"\n}\n' >> "$r/scripts/lib/git.sh"
assert_match "a function defined in two libs fails" "$(gate)" '^fail\|trim is defined more than once: scripts/lib/core\.sh scripts/lib/git\.sh'
back scripts/lib/git.sh

keep scripts/lib/common.sh
printf '\nextra_helper() {\n  :\n}\n' >> "$r/scripts/lib/common.sh"
assert_eq "common.sh defining a function fails" "$(gate)" "fail|scripts/lib/common.sh defines extra_helper(): it only sources the domain libs"
back scripts/lib/common.sh

keep scripts/lib/common.sh
sed_inplace "$r/scripts/lib/common.sh" 's/^_drupilot_libs="\(.*\) phpcs"$/_drupilot_libs="\1"/'
assert_eq "a domain lib common.sh does not list fails" "$(gate)" "fail|scripts/lib/phpcs.sh is listed 0 time(s) in common.sh's _drupilot_libs (once expected)"
sed_inplace "$r/scripts/lib/common.sh" 's/^_drupilot_libs="\(.*\)"$/_drupilot_libs="\1 phpcs phpcs"/'
assert_eq "a domain lib listed twice fails" "$(gate)" "fail|scripts/lib/phpcs.sh is listed 2 time(s) in common.sh's _drupilot_libs (once expected)"
back scripts/lib/common.sh

keep hooks/scripts/guard-contrib.sh
sed_inplace "$r/hooks/scripts/guard-contrib.sh" 's/^_DRUPILOT_LIBS="core paths config subject git interact"$/_DRUPILOT_LIBS="core paths config subject interact"/'
assert_eq "a hook missing a lib it calls fails" "$(gate)" \
  "fail|hooks/scripts/guard-contrib.sh calls a function of scripts/lib/git.sh, missing from its _DRUPILOT_LIBS"
back hooks/scripts/guard-contrib.sh
# guard-contrib calls no subject.sh function itself, but config_get reaches
# one (the project prefs file is found from the Drupal root): dropping subject
# is caught through the call chain.
keep hooks/scripts/guard-contrib.sh
sed_inplace "$r/hooks/scripts/guard-contrib.sh" 's/^_DRUPILOT_LIBS="core paths config subject git interact"$/_DRUPILOT_LIBS="core paths config git interact"/'
assert_eq "a lib reached only through another function counts" "$(gate)" \
  "fail|hooks/scripts/guard-contrib.sh calls a function of scripts/lib/subject.sh, missing from its _DRUPILOT_LIBS"
back hooks/scripts/guard-contrib.sh
# A one-line function reaching another lib: its body is read too.
keep scripts/lib/state.sh
printf '\nlibdefs_probe() { git_hooks_dir "$1"; }\n' >> "$r/scripts/lib/state.sh"
printf '#!/usr/bin/env bash\n_DRUPILOT_LIBS="core paths config subject state"\n. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"\nlibdefs_probe .\n' > "$r/hooks/scripts/probe.sh"
assert_eq "a one-line body that reaches another lib counts" "$(gate)" \
  "fail|hooks/scripts/probe.sh calls a function of scripts/lib/git.sh, missing from its _DRUPILOT_LIBS"
back scripts/lib/state.sh
# common.sh's own calls (the alias rows) need config: a list without it fails.
printf '#!/usr/bin/env bash\n_DRUPILOT_LIBS="core subject"\n. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/common.sh"\nsubject_type .\n' > "$r/hooks/scripts/probe.sh"
assert_match "common.sh's own calls count" "$(gate)" '^fail\|hooks/scripts/probe\.sh calls a function of scripts/lib/config\.sh'
printf '#!/usr/bin/env bash\n_DRUPILOT_LIBS=$X\n' > "$r/hooks/scripts/probe.sh"
assert_eq "a list the gate cannot read fails" "$(gate)" \
  'fail|hooks/scripts/probe.sh sets _DRUPILOT_LIBS in a form the gate cannot read (write _DRUPILOT_LIBS="core ...")'
rm -f "$r/hooks/scripts/probe.sh"
assert_eq "green again" "$(gate)" "pass|"

# A hook's list sources exactly those libs (and the alias rows still load);
# outside a hook's own process the list is ignored, even when exported.
loaded() { for f in subject_type config_get git_port_base_ref choose_one; do
  if declare -F "$f" > /dev/null; then printf '%s ' "$f"; fi; done; }
mkdir -p "$T_TMP/fake/hooks/scripts"
{ printf '#!/usr/bin/env bash\n_DRUPILOT_LIBS="core paths config subject"\n. "%s/scripts/lib/common.sh"\n' "$T_REPO"
  declare -f loaded; printf 'loaded\nprintf "[%%s]" "${_DRUPILOT_LIBS:-}"\n'; } > "$T_TMP/fake/hooks/scripts/t.sh"
assert_eq "a hook's list loads its libs only, then is dropped" "$("$T_SH" "$T_TMP/fake/hooks/scripts/t.sh")" "subject_type config_get []"
{ printf '#!/usr/bin/env bash\n. "%s/scripts/lib/common.sh"\n' "$T_REPO"; declare -f loaded; printf 'loaded\n'; } > "$T_TMP/plain.sh"
assert_eq "an exported list never trims another script's libs" \
  "$(_DRUPILOT_LIBS="core paths config subject" "$T_SH" "$T_TMP/plain.sh")" "subject_type config_get git_port_base_ref choose_one "
t_done
