#!/usr/bin/env bash
# plugin_root (scripts/lib/paths.sh) derives the root from the library's
# directory, made absolute when the library is sourced, so a script run by a
# relative path (cd <plugin> && bash scripts/...) still finds the plugin after
# it changes directory: run-rector.sh, run that way by the orchestrator in a lab
# run, looked for /templates/rector.php.tmpl. An exported CDPATH never makes cd
# print the directory into the result. With CLAUDE_PLUGIN_ROOT set, it wins.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
unset CLAUDE_PLUGIN_ROOT
got="$(cd "$T_REPO" && "$T_SH" -c '. scripts/lib/common.sh; cd "$1" || exit 1; plugin_root' _ "$T_TMP")"
assert_eq "sourced by a relative path, then cd elsewhere: the plugin root" "$got" "$T_REPO"
got="$(cd "$T_REPO" && "$T_SH" -c '. scripts/lib/common.sh; cd "$1" || exit 1; [[ -r "$(plugin_root)/templates/rector.php.tmpl" ]] && echo readable' _ "$T_TMP")"
assert_eq "  so a template path built from it is readable" "$got" "readable"
got="$(cd "$T_REPO" && CDPATH=".:$T_TMP" "$T_SH" -c '. scripts/lib/common.sh; cd "$1" || exit 1; plugin_root' _ "$T_TMP")"
assert_eq "  the same with CDPATH exported" "$got" "$T_REPO"
got="$(cd "$T_TMP" && CLAUDE_PLUGIN_ROOT=/elsewhere "$T_SH" -c '. "$1/scripts/lib/common.sh"; plugin_root' _ "$T_REPO")"
assert_eq "CLAUDE_PLUGIN_ROOT wins when set" "$got" "/elsewhere"
t_done
