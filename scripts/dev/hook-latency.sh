#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/dev/hook-latency.sh
# Measure the wall-clock latency of the plugin's hooks (a developer tool: no
# command, skill or hook calls it). Each hook runs --runs times on a fixed,
# representative payload in an isolated temp HOME, and the p50/p95 in
# milliseconds are reported. The 0.9 numbers are the AR-45 baseline
# (tests/baseline/v0.9.0/hook-latency.json); the 1.0 budgets are checked
# against numbers measured the same way on the same runner.
#
# Payloads:
#   session-detect-env  SessionStart in a module directory (legacy_widgets)
#   post-edit-lint      an Edit of a PHP file of a module placed in a stub
#                       Drupal root whose vendor/bin/phpcs and phpcbf are stubs
#                       (the hook's own cost, not PHPCS's)
#   guard-contrib       `git push origin main` in autonomous mode (an ask)
#
# Usage:
#   scripts/dev/hook-latency.sh [--runs N] [--plugin-root DIR] [--json] [-h|--help]
#     --runs N  runs per hook (default 20)
#     --plugin-root DIR  measure the hooks of another drupilot tree (e.g. a
#               v0.9.0 worktree) instead of this checkout
#     --json    {measured_at, plugin_version, bash, os, runs,
#                hooks:{<hook>:{p50_ms, p95_ms}}}
#
# Needs a millisecond clock: bash >= 5 ($EPOCHREALTIME). Exit codes: 0 ok ·
# 1 usage error or no millisecond clock.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SH="${BASH:-bash}"
RUNS=20; AS_JSON=0; PR=""

usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="${2:-}"; shift 2 || die "--runs needs a value" 1;;
    --runs=*) RUNS="${1#*=}"; shift;;
    --plugin-root) PR="${2:-}"; shift 2 || die "--plugin-root needs a directory" 1;;
    --plugin-root=*) PR="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ "$RUNS" =~ ^[0-9]+$ && "$RUNS" -gt 0 ]] || die "--runs must be a positive number" 1
[[ -n "${EPOCHREALTIME:-}" ]] || die "hook-latency.sh needs bash >= 5 (\$EPOCHREALTIME) for a millisecond clock" 1
have_cmd jq || die "jq is required" 1
PR="${PR:-$REPO}"
[[ -f "$PR/hooks/scripts/guard-contrib.sh" ]] || die "Not a drupilot tree: $PR" 1
PR="$(cd "$PR" && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-latency.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
for _v in $(env | sed -n 's/^\(DRUPILOT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
unset CLAUDE_PLUGIN_DATA CLAUDE_CONFIG_DIR
export CLAUDE_PLUGIN_ROOT="$PR" HOME="$TMP/home" XDG_DATA_HOME="$TMP/home/.local/share"
mkdir -p "$HOME"

# The payloads.
mkdir -p "$TMP/fx" "$TMP/root/web/core/lib" "$TMP/root/web/modules/custom" "$TMP/root/vendor/bin"
cp -R "$REPO/tests/fixtures/legacy_widgets" "$TMP/fx/"
printf '{"name": "drupilot-latency/stub-root"}\n' > "$TMP/root/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$TMP/root/web/core/lib/Drupal.php"
cp -R "$REPO/tests/fixtures/legacy_widgets" "$TMP/root/web/modules/custom/"
for _b in phpcs phpcbf; do printf '#!/bin/sh\nexit 0\n' > "$TMP/root/vendor/bin/$_b"; chmod +x "$TMP/root/vendor/bin/$_b"; done
printf '{"cwd":"%s"}' "$TMP/fx/legacy_widgets" > "$TMP/session.json"
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$TMP/root/web/modules/custom/legacy_widgets/src/WidgetCounter.php" > "$TMP/edit.json"
printf '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' > "$TMP/push.json"

# now_us -> microseconds since the epoch ($EPOCHREALTIME has 6 decimals and the
# locale's decimal separator, which may be a comma).
now_us() { local t="$EPOCHREALTIME"; printf '%s' "${t//[!0-9]/}"; }

# measure <hook> <payload> [env...] -> one duration in microseconds per line.
measure() {
  local hook="$1" payload="$2" i t0 t1; shift 2
  for ((i = 0; i < RUNS; i++)); do
    t0="$(now_us)"
    (cd "$TMP/fx/legacy_widgets" && env "$@" "$SH" "$PR/hooks/scripts/$hook.sh" < "$payload" > /dev/null 2>&1) || true
    t1="$(now_us)"
    printf '%s\n' "$((t1 - t0))"
  done
  return 0
}

# pct <p> < durations -> the p-th percentile (nearest rank), in milliseconds.
pct() { LC_ALL=C sort -n | awk -v p="$1" '{ v[NR] = $1 } END { r = int((p * NR + 99) / 100); if (r < 1) r = 1; printf "%.1f", v[r] / 1000 }'; }

RES="{}"
for _h in session-detect-env post-edit-lint guard-contrib; do
  case "$_h" in
    session-detect-env) measure "$_h" "$TMP/session.json" > "$TMP/$_h.us";;
    post-edit-lint) measure "$_h" "$TMP/edit.json" > "$TMP/$_h.us";;
    guard-contrib) measure "$_h" "$TMP/push.json" DRUPILOT_AUTONOMOUS=true > "$TMP/$_h.us";;
  esac
  _p50="$(pct 50 < "$TMP/$_h.us")"; _p95="$(pct 95 < "$TMP/$_h.us")"
  log_info "$_h: p50 ${_p50} ms, p95 ${_p95} ms ($RUNS runs)"
  RES="$(printf '%s' "$RES" | jq -c --arg h "$_h" --argjson a "$_p50" --argjson b "$_p95" '.[$h] = {p50_ms: $a, p95_ms: $b}')"
done

if [[ "$AS_JSON" == "1" ]]; then
  jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg bash "${BASH_VERSION:-}" \
    --arg pv "$(jq -r '.version // empty' "$PR/.claude-plugin/plugin.json" 2>/dev/null)" \
    --arg os "$(uname -sr 2>/dev/null || echo ?)" --argjson runs "$RUNS" --argjson h "$RES" \
    '{measured_at: $at, plugin_version: $pv, bash: $bash, os: $os, runs: $runs, hooks: $h}'
fi
exit 0
