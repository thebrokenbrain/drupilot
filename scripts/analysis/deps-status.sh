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
#   A `ready` project the subject's composer.json requires also carries
#   {constraint, constraint_admits_ready, ready_majors}: false when that
#   constraint admits none of the majors with a release for the target
#   (drupal/address ^1.8 while only 2.x supports Drupal 11) — the port has to
#   widen it, or the test-bed cannot install the dependency.
# Exit codes: 0 ok (even if a dep is not ready — that is data, not an error)
#             1 usage/error. Read-only; never mutates anything.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
AS_JSON=0
OFFLINE=0
usage() { print_usage "$0"; }

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
# A newline-separated list, de-duplicated with `sort -u` below (no `declare -A`:
# associative arrays need bash 4, and the scripts target bash >= 3.2).
DEPS_LIST=""
add_dep() { DEPS_LIST="${DEPS_LIST}${1}"$'\n'; }

# composer.json: drupal/* require keys (skip core and the subproject itself).
if [[ -f "$SUBJECT/composer.json" ]]; then
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    case "$pkg" in
      drupal/core*) continue;;   # also covers drupal/core-*
      drupal/*) add_dep "${pkg#drupal/}";;
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
      add_dep "$dep"
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
# d11_status <project> -> echoes ready|not-ready|unknown|not-on-drupalorg; sets
# READY_MAJORS to the majors (1 for 8.x-1.8, 2 for 2.0.4) of the releases that
# admit the target major, space-separated.
READY_MAJORS=""
d11_status() {
  local proj="$1" xml
  READY_MAJORS=""
  [[ "$OFFLINE" == "1" ]] && { printf 'unknown'; return; }
  have_cmd curl || { printf 'unknown'; return; }
  xml="$(curl -fsS --max-time 8 "https://updates.drupal.org/release-history/${proj}/current" 2>/dev/null || true)"
  if [[ -z "$xml" ]]; then printf 'unknown'; return; fi
  # An <error> / "no release history" response means the project is not a contrib
  # project on drupal.org (core submodule, custom, or renamed) — not a real blocker.
  # An unsupported (abandoned) project is still one: its releases decide
  # (training run module 10: ckeditor, unsupported, ^9.4 || ^10 only, was
  # reported not-on-drupalorg and the verdict missed the blocker).
  if printf '%s' "$xml" | grep_q -iE '<error>|no release history|no releases'; then
    printf 'not-on-drupalorg'; return
  fi
  # A release whose <core_compatibility> constraint admits the target major
  # means ready (constraint_admits_major: '<11' or '^9.4 || ^10' does not).
  local v c m found=0
  while IFS=$'\t' read -r v c; do
    [[ -n "$c" ]] || continue
    constraint_admits_major "$c" "$D11_MAJOR" || continue
    found=1
    m="$(printf '%s' "$v" | sed -E 's/^[0-9]+\.x-//; s/^([0-9]+).*/\1/')"
    [[ "$m" =~ ^[0-9]+$ && " $READY_MAJORS " != *" $m "* ]] && READY_MAJORS="${READY_MAJORS:+$READY_MAJORS }$m"
  done < <(printf '%s\n' "$xml" | awk '{ buf = buf " " $0 }
      END {
        n = split(buf, rel, "</release>")
        for (i = 1; i <= n; i++) {
          v = ""; c = ""
          if (match(rel[i], /<version>[^<]*<\/version>/)) v = substr(rel[i], RSTART + 9, RLENGTH - 19)
          if (match(rel[i], /<core_compatibility>[^<]*<\/core_compatibility>/)) c = substr(rel[i], RSTART + 20, RLENGTH - 41)
          if (c != "") print v "\t" c
        }
      }' | sed -E 's/&gt;/>/g; s/&lt;/</g; s/&amp;/\&/g')
  # (Literal printf: tests/contract reads the statuses from them.)
  if [[ "$found" == "1" ]]; then printf 'ready'; else printf 'not-ready'; fi
}

D11_MAJOR="$(resolve_target_major 2>/dev/null || true)"; [[ "$D11_MAJOR" =~ ^[0-9]+$ ]] || D11_MAJOR=11
TMP_ST="$(mktemp "${TMPDIR:-/tmp}/drupilot-deps.XXXXXX")"
trap 'rm -f "$TMP_ST"' EXIT
declare -a ROWS=()
BLOCKERS=0; READY=0; UNKNOWN=0
for proj in $(printf '%s' "$DEPS_LIST" | LC_ALL=C sort -u); do
  READY_MAJORS=""
  if is_core_module "$proj"; then st="core"
  else d11_status "$proj" > "$TMP_ST"; st="$(cat "$TMP_ST")"; fi
  # A ready project whose composer.json constraint admits none of its ready
  # releases (training run module 12, location_migration: drupal/address ^1.8,
  # D11 from 2.0.x only): the port has to widen it, or the bed cannot get it.
  extra='{}'
  con="$(jq -r --arg k "drupal/$proj" '(.require // {})[$k] // empty' "$SUBJECT/composer.json" 2>/dev/null || true)"
  if [[ "$st" == "ready" && -n "$con" && -n "$READY_MAJORS" ]]; then
    ok=false
    for m in $READY_MAJORS; do constraint_admits_major "$con" "$m" && ok=true; done
    extra="$(jq -n -c --arg c "$con" --argjson ok "$ok" --arg rm "$READY_MAJORS" \
      '{constraint: $c, constraint_admits_ready: $ok, ready_majors: ($rm | split(" "))}')"
  fi
  case "$st" in
    ready|core) READY=$((READY+1));;
    not-ready)  BLOCKERS=$((BLOCKERS+1));;          # confirmed: a contrib project with no D11 release
    *)          UNKNOWN=$((UNKNOWN+1));;            # not-on-drupalorg / unknown -> verify, NOT a hard blocker
  esac
  ROWS+=("$(jq -n --arg p "$proj" --arg s "$st" --argjson x "$extra" \
    --arg url "https://www.drupal.org/project/$proj" '{project:$p, d11:$s, url:$url} + $x')")
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
printf '%s' "$ROWS_JSON" | jq -r '.[] | [.project, .d11, (if .constraint_admits_ready == false then "\(.constraint)\t\(.ready_majors | join(", "))" else "" end)] | join("\t")' | while IFS=$'\t' read -r p s con rm; do
  case "$s" in
    ready)            icon="✅"; note="D11-ready"
                      [[ -z "$con" ]] || { icon="⚠️"; note="D11-ready from major $rm, but composer.json requires '$con': widen the constraint";};;
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
