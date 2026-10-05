#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/common.sh
# The shared library. Every script and hook sources this file, never a domain
# lib alone:
#
#     # shellcheck source=../lib/common.sh
#     . "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#
# It sources the domain libs below, in this order: core (logging, tool and
# version detection, portable helpers), canon (canonical JSON and its hash),
# paths, config (and the alias layer),
# lock, cache, subject, ddev, state, plan (the version data), strategy,
# toolchain, git, interact and phpcs. Each lib only defines functions and
# constants; every function lives in exactly one lib (the lib-defs gate of
# scripts/dev/check.sh). A hook sources only the libs it needs (set
# _DRUPILOT_LIBS before sourcing this file). php-scan.sh and ext-scan.sh are
# sourced by the scripts that need them.
#
# Principles: idempotent, fail-safe, does NOT enable `set -e` (each script sets
# its own). All logging goes to STDERR so STDOUT stays clean for parseable
# payloads (JSON, machine output).
# =============================================================================

# Avoid double-sourcing.
if [[ -n "${_DRUPILOT_COMMON_SH:-}" ]]; then
  return 0 2>/dev/null || true
fi
_DRUPILOT_COMMON_SH=1

# The domain libs, in a fixed order (each one only defines functions and
# constants, so the order matters only for the alias calls at the end). A hook
# names the libs it needs in _DRUPILOT_LIBS (a subset of this list, which the
# lib-defs gate of scripts/dev/check.sh checks against every function the hook
# reaches) and starts faster. It counts only in a hook's own process ($0 under
# hooks/scripts/) and is dropped afterwards, so a value inherited from the
# environment never trims another script's libs; every other caller gets them
# all.
# The directory comes from a parameter expansion: no fork on the hooks' path.
# Each lib is linted on its own (scripts/dev/check.sh lists them all):
# following the fourteen from every script that sources common.sh made the
# linter about sixty times slower, hence source=/dev/null.
_drupilot_lib_dir="${BASH_SOURCE[0]%/*}"
[[ "$_drupilot_lib_dir" != "${BASH_SOURCE[0]}" ]] || _drupilot_lib_dir=.
_drupilot_libs="core canon paths config lock cache subject ddev state plan strategy toolchain git interact phpcs"
_drupilot_want="$_drupilot_libs"
case "${0:-}" in */hooks/scripts/*) _drupilot_want="${_DRUPILOT_LIBS:-$_drupilot_libs}";; esac
unset _DRUPILOT_LIBS
for _drupilot_lib in $_drupilot_libs; do
  case " $_drupilot_want " in *" $_drupilot_lib "*) ;; *) continue;; esac
  # shellcheck source=/dev/null
  . "$_drupilot_lib_dir/$_drupilot_lib.sh"
done
unset _drupilot_lib _drupilot_libs _drupilot_want _drupilot_lib_dir

# The alias rows (config/migrations.json): their key names now, without a
# fork; the rows themselves when needed, with a warning for each row already
# in use, once, in the main shell (see the alias layer in config.sh).
_config_alias_scan
_config_alias_prewarn
