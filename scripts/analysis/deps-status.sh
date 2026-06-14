#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/deps-status.sh
# Dependency Drupal 11 readiness panel. Answers "will my port actually work?" by
# listing the subject's contrib dependencies and, best-effort, whether each has a
# Drupal 11-compatible release on drupal.org — so a dependency that is NOT ready
# is flagged as a blocker before the port stalls on it.
#
# Sources of dependencies:
#   * composer.json  -> `require` keys matching `drupal/*` (excluding drupal/core*).
#   * *.info.yml     -> the `dependencies:` list (`drupal:token`, `token`, ...).
#
# D11 readiness is checked against the drupal.org release-history feed
# (https://updates.drupal.org/release-history/<project>/current). This needs the
# network; when it is unreachable/blocked the status is reported honestly as
# `unknown` (never guessed) with the project URL to check by hand.
#
# Usage:
#   deps-status.sh --subject DIR [--json] [--offline]
#     --json     emit a JSON object instead of the human table.
#     --offline  skip the network checks (all contrib deps -> `unknown`).
#
# Output: a human table on STDERR + STDOUT, or a JSON object on STDOUT with --json.
# Exit codes: 0 ok (even if a dep is not ready — that is data, not an error)
#             1 usage/error. Read-only; never mutates anything.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
AS_JSON=0
OFFLINE=0
usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    --offline) OFFLINE=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

have_cmd jq || die "jq is required for the dependency panel." 1
[[ -n "$SUBJECT" ]] || SUBJECT="$PWD"
[[ -d "$SUBJECT" ]] || die "Subject directory not found: $SUBJECT" 1
SUBJECT="$(cd "$SUBJECT" && pwd)"
NAME="$(subject_machine_name "$SUBJECT" 2>/dev/null || basename "$SUBJECT")"

# --- Collect contrib dependencies (project short names) ----------------------
declare -A DEPS=()

# composer.json: drupal/* require keys (skip core and the subproject itself).
if [[ -f "$SUBJECT/composer.json" ]]; then
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    case "$pkg" in
      drupal/core*|drupal/core-*) continue;;
      drupal/*) DEPS["${pkg#drupal/}"]=1;;
    esac
  done < <(jq -r '(.require // {}) | keys[]?' "$SUBJECT/composer.json" 2>/dev/null || true)
fi

# *.info.yml dependencies: entries look like `drupal:token`, `token`, or
# `token:token`. Take the project part, drop a `(>=...)` version constraint.
INFO="$(subject_info_file "$SUBJECT" 2>/dev/null || true)"
if [[ -n "$INFO" && -f "$INFO" ]]; then
  in_deps=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^dependencies: ]]; then in_deps=1; continue; fi
    # Leave the block at the next top-level (non-indented, non-list) key.
    if [[ "$in_deps" == "1" && "$line" =~ ^[A-Za-z_] ]]; then in_deps=0; fi
    if [[ "$in_deps" == "1" && "$line" =~ ^[[:space:]]*-[[:space:]]* ]]; then
      dep="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*//; s/["'\'']//g; s/\(.*$//; s/[[:space:]]*$//')"
      dep="${dep##*:}"                       # drupal:token -> token
      [[ -z "$dep" || "$dep" == "core" ]] && continue
      DEPS["$dep"]=1
    fi
  done < "$INFO"
fi

# Drupal core modules/submodules ship WITH core — always available on Drupal 11,
# so they are never a contrib blocker. The drupal.org release-history feed returns
# "<error>No release history" for them (same as a non-existent project), so a name
# check is the reliable signal. This list covers the stable D10/11 core modules;
# a rare omission just degrades to "not-on-drupalorg" (verify by hand), never to a
# false blocker.
CORE_MODULES=" action announcements_feed automated_cron ban basic_auth big_pipe block block_content book breakpoint ckeditor5 comment config config_translation contact content_moderation content_translation contextual datetime datetime_range dblog dynamic_page_cache editor field field_ui file filter help help_topics history image inline_form_errors jsonapi language layout_builder layout_discovery link locale media media_library menu_link_content menu_ui migrate migrate_drupal migrate_drupal_ui mysql navigation node options package_manager page_cache path path_alias pgsql responsive_image rest search serialization settings_tray shortcut sqlite syslog system taxonomy telephone text toolbar tour update user views views_ui workflows workspaces "
is_core_module() { [[ "$CORE_MODULES" == *" $1 "* ]]; }

# --- Classify each dependency's Drupal 11 readiness --------------------------
# d11_status <project> -> echoes ready|not-ready|unknown|not-on-drupalorg
d11_status() {
  local proj="$1" xml
  [[ "$OFFLINE" == "1" ]] && { printf 'unknown'; return; }
  have_cmd curl || { printf 'unknown'; return; }
  xml="$(curl -fsS --max-time 8 "https://updates.drupal.org/release-history/${proj}/current" 2>/dev/null || true)"
  if [[ -z "$xml" ]]; then printf 'unknown'; return; fi
  # An <error> / "no release history" response means the project is not a contrib
  # project on drupal.org (core submodule, custom, or renamed) — not a real blocker.
  if printf '%s' "$xml" | grep -qiE '<error>|no release history|no releases|<project_status>unsupported'; then
    printf 'not-on-drupalorg'; return
  fi
  # A release whose <core_compatibility> constraint admits 11 means D11-ready.
  if printf '%s' "$xml" | grep -oiE '<core_compatibility>[^<]*</core_compatibility>' | grep -q '11'; then
    printf 'ready'; return
  fi
  printf 'not-ready'
}

declare -a ROWS=()
BLOCKERS=0; READY=0; UNKNOWN=0
for proj in $(printf '%s\n' "${!DEPS[@]}" | LC_ALL=C sort); do
  if is_core_module "$proj"; then st="core"; else st="$(d11_status "$proj")"; fi
  case "$st" in
    ready|core) READY=$((READY+1));;
    not-ready)  BLOCKERS=$((BLOCKERS+1));;          # confirmed: a contrib project with no D11 release
    *)          UNKNOWN=$((UNKNOWN+1));;            # not-on-drupalorg / unknown -> verify, NOT a hard blocker
  esac
  ROWS+=("$(jq -n --arg p "$proj" --arg s "$st" \
    --arg url "https://www.drupal.org/project/$proj" '{project:$p, d11:$s, url:$url}')")
done

ROWS_JSON="$(printf '%s\n' "${ROWS[@]+"${ROWS[@]}"}" | jq -s '.' 2>/dev/null || echo '[]')"

# --- Emit --------------------------------------------------------------------
if [[ "$AS_JSON" == "1" ]]; then
  jq -n --arg subject "$NAME" --argjson deps "$ROWS_JSON" \
    --argjson ready "$READY" --argjson blockers "$BLOCKERS" --argjson unknown "$UNKNOWN" \
    --argjson offline "$([[ "$OFFLINE" == "1" ]] && echo true || echo false)" \
    '{subject:$subject, offline:$offline, totals:{ready:$ready, blockers:$blockers, unknown:$unknown},
      dependencies:$deps}'
  exit 0
fi

hr
log_plain "Dependency Drupal 11 readiness — $NAME"
hr
if [[ "${#ROWS[@]}" -eq 0 ]]; then
  log_ok "No contrib dependencies declared — nothing to block the port on this front."
  exit 0
fi
printf '%s' "$ROWS_JSON" | jq -r '.[] | [.project, .d11] | @tsv' | while IFS=$'\t' read -r p s; do
  case "$s" in
    ready)            icon="✅"; note="D11-ready";;
    core)             icon="✅"; note="Drupal core (bundled) — always available";;
    not-ready)        icon="❌"; note="NO D11 release — blocks the port";;
    not-on-drupalorg) icon="❓"; note="not a drupal.org project (core/custom/renamed) — verify by hand";;
    *)                icon="⚠️"; note="unknown (offline/blocked) — check https://www.drupal.org/project/$p";;
  esac
  printf '  %s %-28s %s\n' "$icon" "$p" "$note" >&2
done
hr
log_plain "Ready: $READY · Blockers: $BLOCKERS · Unknown/verify: $UNKNOWN"
[[ "$BLOCKERS" -gt 0 ]] && log_warn "A blocking dependency without a Drupal 11 release will stop the port until it is itself ported (document it, do not fake green)."
# STDOUT (parseable): the project<TAB>status list.
printf '%s' "$ROWS_JSON" | jq -r '.[] | [.project, .d11] | @tsv'
exit 0
