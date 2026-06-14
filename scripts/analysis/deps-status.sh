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

# --- Classify each dependency's Drupal 11 readiness --------------------------
# d11_status <project> -> echoes ready|not-ready|unknown|not-on-drupalorg
d11_status() {
  local proj="$1" xml
  [[ "$OFFLINE" == "1" ]] && { printf 'unknown'; return; }
  have_cmd curl || { printf 'unknown'; return; }
  xml="$(curl -fsS --max-time 8 "https://updates.drupal.org/release-history/${proj}/current" 2>/dev/null || true)"
  if [[ -z "$xml" ]]; then printf 'unknown'; return; fi
  if printf '%s' "$xml" | grep -qiE 'no releases|<project_status>unsupported'; then printf 'not-on-drupalorg'; return; fi
  # A release whose <core_compatibility> constraint admits 11 means D11-ready.
  if printf '%s' "$xml" | grep -oiE '<core_compatibility>[^<]*</core_compatibility>' | grep -q '11'; then
    printf 'ready'; return
  fi
  printf 'not-ready'
}

declare -a ROWS=()
BLOCKERS=0; READY=0; UNKNOWN=0
for proj in $(printf '%s\n' "${!DEPS[@]}" | LC_ALL=C sort); do
  st="$(d11_status "$proj")"
  case "$st" in
    ready) READY=$((READY+1));;
    not-ready|not-on-drupalorg) BLOCKERS=$((BLOCKERS+1));;
    *) UNKNOWN=$((UNKNOWN+1));;
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
    not-ready)        icon="❌"; note="NO D11 release — blocks the port";;
    not-on-drupalorg) icon="❓"; note="not found on drupal.org — verify by hand";;
    *)                icon="⚠️"; note="unknown (offline/blocked) — check https://www.drupal.org/project/$p";;
  esac
  printf '  %s %-28s %s\n' "$icon" "$p" "$note" >&2
done
hr
log_plain "Ready: $READY · Blockers: $BLOCKERS · Unknown: $UNKNOWN"
[[ "$BLOCKERS" -gt 0 ]] && log_warn "A blocking dependency without a Drupal 11 release will stop the port until it is itself ported (document it, do not fake green)."
# STDOUT (parseable): the project<TAB>status list.
printf '%s' "$ROWS_JSON" | jq -r '.[] | [.project, .d11] | @tsv'
exit 0
