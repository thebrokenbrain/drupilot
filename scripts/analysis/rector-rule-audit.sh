#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/rector-rule-audit.sh
# The Rector rule audit (AR-11, T-M5-03, ADR 0030): reflects the PHP sets of
# the Rector installed in a Drupal root (scripts/php/rule-audit.php, staged by
# stage_runtime and run with $(drupal_runner) php) and lists every rule they
# register, with its sets, the PHP Rector's PhpVersionedFilter needs before it
# runs it (min_php), its polyfill package and its Rector interfaces. Together
# with the compat rows of config/php/rules.json (the allowlist) it gives the
# compat pass its rules and its withPhpVersion() (rector_compat_list,
# rector_compat_php_id in scripts/lib/toolchain.sh).
#
# The audit is a function of the Rector version: it is cached in the root's
# lock (.rector_rule_audit: {rector_version, rules}; the version is
# composer.lock's, else the one Rector's VersionResolver declares) and run
# again only for another installed version or with --refresh. Two runs on the same Rector
# print the same bytes.
#
# Usage:
#   rector-rule-audit.sh --root DIR [--refresh] [--json] [-h|--help]
#     --root DIR    the Drupal root (rector/rector in its vendor/)
#     --refresh     audit again even when the lock holds this Rector's audit
#     --json        {tool: "rector-rule-audit", rector_version, rules: [{rule,
#                   sets, min_php, polyfill, interfaces}], missing: [{id, rule,
#                   kind}]} on STDOUT; missing lists the config/php/rules.json
#                   rows whose rule the installed Rector's PHP sets do not
#                   register (renamed, removed, or outside the PHP sets)
#
# Exit codes: 0 audited (or read from the lock) · 1 usage error · 2 no Rector
# installed in the root, no PHP to run the helper (DDEV down and no host
# php), or the helper failed.
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ROOT=""; REFRESH=0; AS_JSON=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 || die "--root needs a value" 1;;
    --refresh) REFRESH=1; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ -n "$ROOT" && -d "$ROOT" ]] || die "Pass --root DIR (an existing Drupal root)." 1
have_cmd jq || die "jq is required (run /drupilot-doctor)." 1
ROOT="$(cd "$ROOT" && pwd)"
[[ -d "$ROOT/vendor/rector/rector" ]] \
  || die "rector/rector is not installed in $ROOT (install the toolchain first: scripts/env/install-toolchain.sh --dir \"$ROOT\")." 2
VERSION="$(rector_installed_version "$ROOT")"

AUDIT=""
if [[ "$REFRESH" == "0" && -n "$VERSION" ]]; then
  AUDIT="$(rector_audit_cached "$ROOT")"
  [[ -z "$AUDIT" ]] || log_info "rector-rule-audit: Rector $VERSION, from the lock."
fi
if [[ -z "$AUDIT" ]]; then
  RUNNER="$(drupal_runner "$ROOT")"
  [[ -n "$RUNNER" ]] || have_cmd php || die "No PHP to run the audit: start the test-bed (ddev start) or install a host php." 2
  RT="$(stage_runtime "$ROOT" || true)"
  [[ -n "$RT" ]] || die "Could not stage the PHP helpers into $ROOT/.drupilot/runtime." 2
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-rule-audit.XXXXXX")"
  trap 'rm -rf "$TMP" 2> /dev/null || true' EXIT
  # shellcheck disable=SC2086  # RUNNER is a command prefix ("ddev exec" or empty)
  if ! (cd "$ROOT" && $RUNNER php "$RT/rule-audit.php" < /dev/null) > "$TMP/out" 2> "$TMP/err" \
     || ! jq -e '(.rules | type == "array" and length > 0)' "$TMP/out" > /dev/null 2>&1; then
    # PHP prints a fatal error on STDOUT: name it when STDERR is empty.
    log_err "The rule audit failed: $(cat "$TMP/err" "$TMP/out" 2> /dev/null | sed -n '1,3p' | tr '\n' ' ')"
    exit 2
  fi
  [[ -n "$VERSION" ]] || VERSION="$(jq -r '.rector_version // empty' "$TMP/out")"
  AUDIT="$(jq -c '.rules' "$TMP/out")"
  if [[ -n "$VERSION" ]]; then
    DRUPILOT_PROJECT_DIR="$ROOT" lock_set_json .rector_rule_audit \
      "$(jq -c --arg v "$VERSION" '{rector_version: $v, rules: .rules}' "$TMP/out")" > /dev/null 2>&1 \
      || log_warn "Could not keep the rule audit in the lock of $ROOT."
  fi
  log_ok "rector-rule-audit: Rector ${VERSION:-?}, $(jq 'length' <<< "$AUDIT") rules in its PHP sets."
fi

RULES="$(version_data_dir)/php/rules.json"
MISSING="$(jq -c --argjson a "$AUDIT" '[$a[].rule] as $known
  | [.rules[] | select(.rule != null) | select(.rule as $r | $known | index($r) | not) | {id: (.id // .rule), rule, kind}]' \
  "$RULES" 2> /dev/null || printf '[]')"
OUT="$(jq -n -c --arg v "$VERSION" --argjson r "$AUDIT" --argjson m "$MISSING" \
  '{tool: "rector-rule-audit", rector_version: (if $v == "" then null else $v end), rules: $r, missing: $m}')"
if [[ "$AS_JSON" == "1" ]]; then
  printf '%s\n' "$OUT" | canon_json
else
  printf '%s\n' "$OUT" | jq -r '"Rector \(.rector_version // "?"): \(.rules | length) rules in its PHP sets",
    (.missing[] | "  not registered by its PHP sets: \(.id) (\(.rule))")'
fi
exit 0
