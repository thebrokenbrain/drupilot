#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/origin-hygiene.sh
# Prove drupilot left the developer's ORIGIN checkout clean. A port must change
# the module's code and nothing else in the origin repo: no stray .ddev/,
# vendor/, node_modules/, .phpstan-cache/, generated config, drupilot files or
# symlinks escaping the tree. This script records the origin's state BEFORE
# drupilot touches it and later diffs the current state against that baseline.
# Report-only: it never deletes or edits anything in the origin.
#
#   --snapshot  record `git status --porcelain` (untracked dirs collapsed) of the
#               origin subtree, or its top-level entries when it is not a git
#               checkout. Called by place-subject.sh BEFORE placing, and by
#               /drupilot-setup for a subject already inside a Drupal root. An
#               existing baseline is kept (idempotent) unless --force.
#   --check     diff the current state against the baseline and classify each NEW
#               untracked entry as drupilot-attributable (.ddev/, .drupilot*,
#               .phpstan-cache/, vendor/, node_modules/, rector.php,
#               phpstan.neon, phpcs.xml.dist, *-port-to-drupal-11*.patch,
#               symlinks resolving outside the origin) or other. Tracked files
#               the port modified are listed separately (expected for move /
#               symlink / in-place; unexpected for copy).
#
# The baseline is machine state: it lives in the HIDDEN per-project state dir
# keyed by the Drupal ROOT (origin-baseline.json), never in the tree, so it is
# found again after a 'move' relocates the origin (the moved path is recorded
# with --record-origin).
#
# Usage:
#   origin-hygiene.sh --snapshot [--subject DIR] [--root DIR]
#                     [--record-origin DIR] [--placement MODE] [--force] [--json]
#   origin-hygiene.sh --check [--subject DIR] [--root DIR] [--json]
#
#   --subject        the origin module/theme checkout (default: current dir).
#   --root           the Drupal root that keys the baseline (default: the root
#                    found above --subject, else the test-bed root
#                    resolve-workspace.sh targets, else --subject itself).
#   --record-origin  where the origin will live once placed (move mode).
#   --placement      move|symlink|copy|in-place, recorded for the check.
#   --force          overwrite an existing baseline (--snapshot).
#   --json           accepted for symmetry with the other scripts: STDOUT always
#                    carries only the JSON payload, the human summary is STDERR.
#
# Output (STDOUT, JSON):
#   --snapshot: {baseline, origin, git, created}
#   --check:    {origin, placement, baseline, git, clean, new_untracked:[...],
#                attributable:[...], other:[...], changed_tracked:[...]}
#               clean is null when there is no baseline / nothing to compare.
# Exit codes: 0 always for a completed snapshot/check (report-only) · 1 usage.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

MODE=""
SUBJECT=""
ROOT=""
RECORD_ORIGIN=""
PLACEMENT=""
FORCE=0

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot) MODE="snapshot"; shift;;
    --check) MODE="check"; shift;;
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --root) ROOT="${2:-}"; shift 2;;
    --root=*) ROOT="${1#*=}"; shift;;
    --record-origin) RECORD_ORIGIN="${2:-}"; shift 2;;
    --record-origin=*) RECORD_ORIGIN="${1#*=}"; shift;;
    --placement) PLACEMENT="${2:-}"; shift 2;;
    --placement=*) PLACEMENT="${1#*=}"; shift;;
    --force) FORCE=1; shift;;
    --json) shift;;  # no-op: STDOUT is always the JSON payload.
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)." 1;;
  esac
done

[[ -n "$MODE" ]] || die "Pass --snapshot or --check (see --help)." 1
have_cmd jq || die "jq is required for origin-hygiene.sh." 1

SUBJECT="${SUBJECT:-$PWD}"
SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"

# --- Resolve the keying root ------------------------------------------------
# Candidates, in order: the Drupal root above the subject, the workspace pinned
# in the subject-side .drupilot.json (copy/symlink), the test-bed root the
# resolver targets, the subject itself. For --check the first candidate that
# HAS a baseline wins — so residue that makes the module look like its own root
# (an untracked .ddev/config.yaml) cannot hide the real baseline.
root_candidates() {
  local c
  c="$(find_drupal_root "$SUBJECT_ABS" 2>/dev/null || true)"
  [[ -n "$c" ]] && printf 'strong\t%s\n' "$c"
  if [[ -r "$SUBJECT_ABS/.drupilot.json" ]]; then
    jq -r '.DRUPILOT_WORKSPACE_DIR // empty | "weak\t" + .' "$SUBJECT_ABS/.drupilot.json" 2>/dev/null || true
  fi
  c="$(config_get DRUPILOT_WORKSPACE_DIR "")"; [[ -n "$c" ]] && printf 'weak\t%s\n' "$c"
  bash "$(plugin_root)/scripts/env/resolve-workspace.sh" --subject "$SUBJECT_ABS" --json 2>/dev/null \
    | jq -r '.drupal_root // empty | "weak\t" + .' 2>/dev/null || true
  printf 'weak\t%s\n' "$SUBJECT_ABS"
  return 0
}
# baseline_matches <file> <strength> -> 0 when the baseline is this subject's:
# same machine name (when recorded), and — unless the root was found by walking
# up from the subject — the subject IS the recorded origin/source.
baseline_matches() {
  local f="$1" strength="$2" mn
  mn="$(jq -r '.machine_name // empty' "$f" 2>/dev/null || true)"
  [[ -n "$mn" && -n "$MACHINE" && "$mn" != "$MACHINE" ]] && return 1
  [[ "$strength" == "strong" ]] && return 0
  [[ "$(jq -r '.origin // empty' "$f" 2>/dev/null)" == "$SUBJECT_ABS" \
     || "$(jq -r '.source // empty' "$f" 2>/dev/null)" == "$SUBJECT_ABS" ]] && return 0
  return 1
}
MACHINE=""
[[ -n "$SUBJECT_ABS" ]] && MACHINE="$(subject_machine_name "$SUBJECT_ABS" 2>/dev/null || true)"
NO_MATCH=0
if [[ -z "$ROOT" && -n "$SUBJECT_ABS" ]]; then
  _first=""
  while IFS=$'\t' read -r _s _c; do
    [[ -n "$_c" && -d "$_c" ]] || continue
    _c="$(cd "$_c" && pwd)"
    [[ -n "$_first" ]] || _first="$_c"
    _b="$(project_state_dir "$_c")/origin-baseline.json"
    if [[ "$MODE" == "check" && -f "$_b" ]]; then
      if baseline_matches "$_b" "$_s"; then ROOT="$_c"; break; fi
      NO_MATCH=1
    fi
  done < <(root_candidates)
  [[ -n "$ROOT" ]] || ROOT="$_first"
fi
[[ -n "$ROOT" ]] || ROOT="${SUBJECT_ABS:-$SUBJECT}"
[[ -d "$ROOT" ]] && ROOT="$(cd "$ROOT" && pwd)"
BASELINE="$(project_state_dir "$ROOT")/origin-baseline.json"

# --- Helpers ----------------------------------------------------------------
# origin_state <dir> -> one entry per line: porcelain lines for a git checkout
# (scoped to <dir>, untracked directories collapsed), else top-level names.
origin_state() {
  local d="$1"
  if git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$d" status --porcelain=v1 --untracked-files=normal -- . 2>/dev/null || true
  else
    ( cd "$d" && ls -A 2>/dev/null ) | sed 's/^/?? /' || true
  fi
  return 0
}

# is_git <dir> -> 0 when <dir> is inside a git work tree.
is_git() { git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; }

# attributable <origin> <relpath> -> 0 when the entry looks like drupilot's.
attributable() {
  local rel="$2" name
  name="${rel%/}"; name="${name##*/}"
  case "$name" in
    .ddev|.drupilot|.drupilot.json|.phpstan-cache|.drupilot-coverage|vendor|node_modules) return 0;;
    rector.php|phpstan.neon|phpcs.xml.dist|*-port-to-drupal-11.patch|*-port-to-drupal-11-*.patch) return 0;;
  esac
  symlink_escapes "$1" "$rel" && return 0
  return 1
}

# =============================================================================
# SNAPSHOT
# =============================================================================
if [[ "$MODE" == "snapshot" ]]; then
  [[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1
  ORIGIN="${RECORD_ORIGIN:-$SUBJECT_ABS}"
  # A baseline taken for a DIFFERENT origin (another subject under the same
  # root) is stale: retake it rather than compare against the wrong checkout.
  if [[ -f "$BASELINE" && "$FORCE" != "1" ]] \
     && [[ "$(jq -r '.source // empty' "$BASELINE" 2>/dev/null)" != "$SUBJECT_ABS" \
           && "$(jq -r '.origin // empty' "$BASELINE" 2>/dev/null)" != "$SUBJECT_ABS" ]]; then
    log_info "The recorded origin baseline belongs to another checkout — retaking it."
    FORCE=1
  fi
  if [[ -f "$BASELINE" && "$FORCE" != "1" ]]; then
    log_ok "Origin baseline already recorded (kept; --force to retake): $BASELINE"
    jq -c --arg b "$BASELINE" '{baseline:$b, origin:.origin, git:.git, created:false}' "$BASELINE"
    exit 0
  fi
  GIT=false; HEADSHA=""
  if is_git "$SUBJECT_ABS"; then
    GIT=true
    HEADSHA="$(git -C "$SUBJECT_ABS" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
  fi
  STATE_JSON="$(origin_state "$SUBJECT_ABS" | jq -R . | jq -s -c .)"
  TMP="$(mktemp "${TMPDIR:-/tmp}/drupilot-origin.XXXXXX")"
  jq -n --arg origin "$ORIGIN" --arg source "$SUBJECT_ABS" --arg root "$ROOT" \
    --arg placement "$PLACEMENT" --argjson git "$GIT" --arg head "$HEADSHA" \
    --arg machine_name "$MACHINE" \
    --arg taken_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson entries "$STATE_JSON" \
    '{origin:$origin, source:$source, root:$root, placement:$placement, git:$git,
      machine_name:$machine_name,
      head:$head, taken_at:$taken_at, entries:$entries}' > "$TMP" \
    && mv "$TMP" "$BASELINE" || { rm -f "$TMP"; die "Could not write $BASELINE" 1; }
  log_ok "Origin baseline recorded ($(jq '.entries | length' "$BASELINE") pre-existing status entries): $BASELINE"
  jq -c --arg b "$BASELINE" '{baseline:$b, origin:.origin, git:.git, created:true}' "$BASELINE"
  exit 0
fi

# =============================================================================
# CHECK
# =============================================================================
HAVE_BASE=false
ORIGIN="$SUBJECT_ABS"
PLACE="$PLACEMENT"
if [[ -f "$BASELINE" && "$NO_MATCH" == "1" ]] && ! baseline_matches "$BASELINE" weak; then
  log_info "The origin baseline under $ROOT belongs to another checkout — ignoring it."
  BASELINE_IGNORED=1
fi
if [[ -f "$BASELINE" && -z "${BASELINE_IGNORED:-}" ]]; then
  HAVE_BASE=true
  _o="$(jq -r '.origin // empty' "$BASELINE" 2>/dev/null || true)"
  [[ -n "$_o" ]] && ORIGIN="$_o"
  [[ -n "$PLACE" ]] || PLACE="$(jq -r '.placement // empty' "$BASELINE" 2>/dev/null || true)"
fi

emit() { # emit <clean-json> <reason>
  local clean="$1" reason="$2"
  jq -c -n --arg origin "$ORIGIN" --arg placement "$PLACE" --arg baseline "$BASELINE" \
    --argjson has "$HAVE_BASE" --argjson git "${GIT:-false}" --argjson clean "$clean" \
    --arg reason "$reason" \
    --argjson new "${NEW_JSON:-[]}" --argjson attr "${ATTR_JSON:-[]}" \
    --argjson other "${OTHER_JSON:-[]}" --argjson changed "${CHANGED_JSON:-[]}" \
    '{origin:$origin, placement:$placement, baseline:(if $has then $baseline else null end),
      git:$git, clean:$clean, reason:(if $reason == "" then null else $reason end),
      new_untracked:$new, attributable:$attr, other:$other, changed_tracked:$changed}'
}

if [[ -z "$ORIGIN" || ! -d "$ORIGIN" ]]; then
  log_warn "Origin checkout not found ('${ORIGIN:-$SUBJECT}') — nothing to check."
  emit null "origin-missing"; exit 0
fi
GIT=false; is_git "$ORIGIN" && GIT=true
if [[ "$HAVE_BASE" != "true" ]]; then
  log_warn "No origin baseline for $ROOT — hygiene cannot be verified (run with --snapshot before placing)."
  emit null "no-baseline"; exit 0
fi

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-hyg.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT
jq -r '.entries[]' "$BASELINE" | sort -u > "$TMPD/before"
origin_state "$ORIGIN" | sort -u > "$TMPD/after"
comm -13 "$TMPD/before" "$TMPD/after" > "$TMPD/new"

: > "$TMPD/untracked"; : > "$TMPD/attr"; : > "$TMPD/other"; : > "$TMPD/changed"
TOP="$ORIGIN"
[[ "$GIT" == "true" ]] && TOP="$(git -C "$ORIGIN" rev-parse --show-toplevel 2>/dev/null || echo "$ORIGIN")"
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  code="${line:0:2}"; rel="${line:3}"
  # porcelain v1 quotes unusual names; strip the quotes for display/matching.
  case "$rel" in \"*\") rel="${rel#\"}"; rel="${rel%\"}";; esac
  if [[ "$code" == "??" ]]; then
    printf '%s\n' "$rel" >> "$TMPD/untracked"
    if attributable "$TOP" "$rel"; then printf '%s\n' "$rel" >> "$TMPD/attr"
    else printf '%s\n' "$rel" >> "$TMPD/other"; fi
  else
    printf '%s\n' "$rel" >> "$TMPD/changed"
  fi
done < "$TMPD/new"

tojson() { if [[ -s "$1" ]]; then jq -R . < "$1" | jq -s -c .; else printf '[]'; fi; }
NEW_JSON="$(tojson "$TMPD/untracked")"
ATTR_JSON="$(tojson "$TMPD/attr")"
OTHER_JSON="$(tojson "$TMPD/other")"
CHANGED_JSON="$(tojson "$TMPD/changed")"

CLEAN=true
[[ -s "$TMPD/attr" ]] && CLEAN=false
if [[ "$PLACE" == "copy" && -s "$TMPD/changed" ]]; then CLEAN=false; fi

# Human summary (STDERR). --json is accepted for symmetry: STDOUT always holds
# only the JSON payload.
{
  if [[ "$CLEAN" == "true" ]]; then
    log_ok "Origin hygiene: no drupilot residue in $ORIGIN."
  else
    log_warn "Origin hygiene: drupilot left residue in $ORIGIN:"
    while IFS= read -r l; do log_plain "    ?? $l"; done < "$TMPD/attr"
    if [[ "$PLACE" == "copy" && -s "$TMPD/changed" ]]; then
      log_warn "Tracked files changed in the origin although placement is 'copy':"
      while IFS= read -r l; do log_plain "    M  $l"; done < "$TMPD/changed"
    fi
    log_plain "  Nothing was deleted. Review and remove what you do not want (git status in $ORIGIN)."
  fi
  if [[ -s "$TMPD/other" ]]; then
    log_info "Other new untracked entries (not attributed to drupilot):"
    while IFS= read -r l; do log_plain "    ?? $l"; done < "$TMPD/other"
  fi
}
emit "$CLEAN" ""
exit 0
