#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/phpcs.sh
# The project's PHPCS ruleset discovery.
#
# Part of the shared library: scripts/lib/common.sh sources it with the other
# domain libs (never source it alone); see common.sh for the conventions.
# =============================================================================

# ---------------------------------------------------------------------------
# Project PHPCS ruleset discovery (run-phpcs.sh, post-edit-lint.sh)
# ---------------------------------------------------------------------------
# phpcs_ruleset_is_drupilot <file> -> 0 when <file> is the ruleset drupilot
# itself generated from templates/phpcs.xml.dist.tmpl (its root element is
# <ruleset name="drupilot">). That file is drupilot's own default, never "the
# project's rules", so discovery skips it.
phpcs_ruleset_is_drupilot() { grep -q '<ruleset[^>]*name="drupilot"' "$1" 2>/dev/null; }

# _phpcs_ruleset_in_dir <dir> -> print the first project ruleset in <dir>, in
# PHPCS's own auto-discovery order (squizlabs/php_codesniffer src/Config.php:
# .phpcs.xml, phpcs.xml, .phpcs.xml.dist, phpcs.xml.dist), skipping drupilot's.
_phpcs_ruleset_in_dir() {
  local d="$1" n
  for n in .phpcs.xml phpcs.xml .phpcs.xml.dist phpcs.xml.dist; do
    if [[ -f "$d/$n" ]] && ! phpcs_ruleset_is_drupilot "$d/$n"; then
      printf '%s/%s\n' "$d" "$n"
      return 0
    fi
  done
  return 1
}

# _phpcs_ruleset_walk <from> <stop> -> walk from <from> up to <stop> (inclusive;
# <stop> must be <from> or one of its ancestors, else only <from> is checked).
_phpcs_ruleset_walk() {
  local d="$1" stop="$2"
  while [[ -n "$d" ]]; do
    _phpcs_ruleset_in_dir "$d" && return 0
    [[ "$d" == "$stop" || "$d" == "/" ]] && return 1
    case "$d" in "$stop"/*) : ;; *) return 1;; esac
    d="$(dirname "$d")"
  done
  return 1
}

# find_phpcs_ruleset <subject_abs> <drupal_root> -> print the absolute path of
# the subject's OWN PHPCS ruleset, or return 1 when it ships none. Looked up, in
# order (first hit wins):
#   1. the subject dir up to the Drupal root (what PHPCS would auto-discover);
#   2. the subject's physical path (a symlink placement) up to its git top level
#      (a module that is a repo of its own, or a monorepo root);
#   3. the ORIGIN checkout a copy placement left behind (the subject's origin
#      baseline .source, under the Drupal root) up to its git top level.
# drupilot's own generated ruleset (<ruleset name="drupilot">) is never returned.
# A pure file check: it runs no PHPCS and never writes anything.
find_phpcs_ruleset() {
  local subj="$1" root="$2" phys top src b
  [[ -d "$subj" ]] || return 1
  _phpcs_ruleset_walk "$subj" "${root:-$subj}" && return 0
  phys="$(cd -P "$subj" 2>/dev/null && pwd || true)"
  if [[ -n "$phys" ]]; then
    top=""
    have_cmd git && top="$(git -C "$phys" rev-parse --show-toplevel 2>/dev/null || true)"
    _phpcs_ruleset_walk "$phys" "${top:-$phys}" && return 0
  fi
  if [[ -n "$root" ]] && have_cmd jq; then
    b="$(origin_baseline_find "$root" "$(subject_machine_name "$subj" 2>/dev/null || true)")"
    src=""
    [[ -n "$b" ]] && src="$(jq -r '.source // empty' "$b" 2>/dev/null || true)"
    if [[ -n "$src" && -d "$src" ]]; then
      top=""
      have_cmd git && top="$(git -C "$src" rev-parse --show-toplevel 2>/dev/null || true)"
      _phpcs_ruleset_walk "$src" "${top:-$src}" && return 0
    fi
  fi
  return 1
}

# phpcs_ruleset_value <file> <config|property> <name> -> print the value of the
# first <config name="NAME" value="..."/> (or <property .../>) in <file>, in
# either attribute order; nothing (still 0) when absent. Regex-based, no XML
# parser assumed — enough for the flat one-tag-per-line rulesets PHPCS uses.
phpcs_ruleset_value() {
  local f="$1" tag="$2" name="$3"
  grep -o "<${tag}[[:space:]][^>]*>" "$f" 2>/dev/null \
    | grep "name=\"${name}\"" | sed -n '1p' \
    | sed -n 's/.*value="\([^"]*\)".*/\1/p'
  return 0
}
