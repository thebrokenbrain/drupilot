#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/run-phpcompat.sh
# PHPCompatibility over the PHP window (T-M5-05, ADR 0003): a separate PHPCS
# run with testVersion L-U and the Symfony polyfill rulesets of the declared
# range, report-only. It never blocks a port and never fails the php stage.
#
# The tree: its own Composer project in <root>/.drupilot/phpcompat (gitignored,
# inside the DDEV mount, outside the test-bed's composer.json), installed on
# first use with the exact pins of config/toolchain-reference.json `phpcompat`
# (phpcompatibility/php-compatibility 10.0.0-alpha2 on PHPCS 4.0.4, ...),
# idempotent: kept while vendor/bin/phpcs exists and its composer.lock holds
# exactly those pins. The pins and the standards used are kept in the root's
# lock (.phpcompat). The project's own ruleset is never read or modified, and
# phpcbf never runs with these standards.
#
# The window: the upgrade plan's floor L to its top U (the higher of P and the
# highest PHP a core of the range supports, plan_php_top; ADR 0002), as the
# testVersion "L-U" of its first and last PHP (php_window); without a plan,
# the floor and ceiling rector_php_bounds gives. The standards: PHPCompatibility
# plus PHPCompatibilitySymfonyPolyfillPHP<xy> for each polyfill package every
# core of the range ships (the plan's rector.polyfills), when the tree lists
# that standard (`phpcs -i`).
#
# Each message is normalized: Internal.NoCodeFound is dropped; the rest is
# deduplicated on (file, line, source) and classed by PHPCompatibility's
# convention: an ERROR from a New* sniff is `floor` (it needs a PHP above L),
# any other ERROR `removed` (removed in a PHP of the window), a WARNING
# `deprecated`. A finding whose source a config/php/rules.json row lists
# (its phpcompat codes) names that row (rule) and is `covered` when the row
# is handled already: Rector applies or denies it over [L..U], or
# php-target.sh reports it for [L..P] (ADR 0003 item 6: it corroborates the
# row's own item and never adds one). counts leave the covered ones out.
#
# Usage:
#   run-phpcompat.sh --subject DIR [--test-version L-U] [--no-install] [--json]
#                    [-h|--help]
#     --subject DIR        the module/theme (under a Drupal root)
#     --test-version L-U   the window to check instead of the plan's
#     --no-install         never install the tree (a missing one degrades)
#     --json               {tool: "phpcompat", status, reason, test_version,
#                          standards, counts: {floor, removed, deprecated,
#                          covered}, findings: [{file, line, source, type,
#                          kind, message, rule, covered}], fallback,
#                          versions, alpha} on STDOUT
#
# status: ok (PHPCS exited 0-3 with a JSON report and no Internal.Exception),
# degraded (the install failed, PHPCS crashed, timed out or printed no
# report: fallback is then detect-php-floor.sh's scan of the module with the
# plan's range), or skipped (an empty window, a DDEV project that cannot be
# started, or no PHP to run it). reason names why when it is not ok.
#
# Exit codes: 0 always once the arguments are valid (whatever the status) ·
# 1 usage error, or no Drupal root.
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""; TV_ARG=""; INSTALL=1; AS_JSON=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --test-version) TV_ARG="${2:-}"; shift 2 || die "--test-version needs a value" 1;;
    --no-install) INSTALL=0; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ -n "$SUBJECT" ]] || die "Pass --subject DIR." 1
have_cmd jq || die "jq is required (run /drupilot-doctor)." 1
if [[ -n "$TV_ARG" ]]; then
  [[ "$TV_ARG" =~ ^[0-9]+\.[0-9]+-[0-9]+\.[0-9]+$ ]] || die "--test-version is L-U, two PHP versions X.Y (got '$TV_ARG')." 1
fi
ROOT="$(find_drupal_root "$SUBJECT" 2> /dev/null || find_drupal_root "$PWD" 2> /dev/null || true)"
[[ -n "$ROOT" ]] || die "Could not locate a Drupal root from '$SUBJECT'. Run /drupilot-setup first." 1
ROOT="$(cd "$ROOT" && pwd)"
SUBJECT_ABS=""
if [[ -d "$SUBJECT" ]]; then SUBJECT_ABS="$(cd "$SUBJECT" && pwd)"
elif [[ -d "$ROOT/$SUBJECT" ]]; then SUBJECT_ABS="$(cd "$ROOT/$SUBJECT" && pwd)"; fi
[[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1
case "$SUBJECT_ABS" in
  "$ROOT"/*) SUBJECT_REL="${SUBJECT_ABS#"$ROOT"/}";;
  *) die "Subject '$SUBJECT_ABS' is outside the Drupal root '$ROOT'." 1;;
esac
TREE_REL=".drupilot/phpcompat"; TREE="$ROOT/$TREE_REL"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-phpcompat.XXXXXX")"
trap 'rm -rf "$TMP" 2> /dev/null || true' EXIT

PINS="$(jq -c '.phpcompat.toolchain // {}' "$(toolchain_reference_file)" 2> /dev/null || printf '{}')"
ALPHA="$(printf '%s' "$PINS" | jq -r '[.[] | select(test("alpha|beta|RC"; "i"))] | length > 0')"
VERSIONS="$PINS"

# --- The window and the standards' polyfills ------------------------------------
PLAN="$(plan_for_subject "$ROOT" "$SUBJECT_ABS" 2> /dev/null || true)"
RANGE=""; POLY='[]'
if [[ -n "$PLAN" ]]; then
  L="$(printf '%s' "$PLAN" | jq -r '.php.floor // empty')"
  P="$(printf '%s' "$PLAN" | jq -r '.php.final // empty')"
  U="$(plan_php_top "$PLAN")"
  RANGE="$(printf '%s' "$PLAN" | jq -r '.range.constraint // empty')"
  POLY="$(plan_polyfills "$PLAN")"
else
  P="$(resolve_php_target)"
  _b="$(rector_php_bounds "$SUBJECT_ABS" "$P")"; L="${_b%% *}"; U="${_b##* }"
fi
if [[ -n "$TV_ARG" ]]; then
  W="$(php_window "${TV_ARG%-*}" "${TV_ARG#*-}")"
else
  W="$(php_window "$L" "$U")"
fi
TV=""; [[ -z "$W" ]] || TV="${W%% *}-${W##* }"

# emit STATUS REASON [FINDINGS_FILE] [FALLBACK_JSON] -> the report, then exit 0.
STANDARDS='[]'
emit() {
  local st="$1" rs="$2" ff="${3:-}" fb="${4:-null}"
  [[ -n "$ff" && -f "$ff" ]] || { ff="$TMP/none.json"; printf '[]' > "$ff"; }
  [[ -n "$fb" ]] || fb=null
  OUT="$(jq -n -c --arg st "$st" --arg rs "$rs" --arg tv "$TV" --argjson std "$STANDARDS" --slurpfile f "$ff" \
    --argjson fb "$fb" --argjson v "$VERSIONS" --argjson alpha "$ALPHA" '
    {tool: "phpcompat", status: $st, reason: (if $rs == "" then null else $rs end),
     test_version: (if $tv == "" then null else $tv end), standards: $std,
     counts: {floor: ([$f[0][] | select(.kind == "floor" and .covered != true)] | length),
              removed: ([$f[0][] | select(.kind == "removed" and .covered != true)] | length),
              deprecated: ([$f[0][] | select(.kind == "deprecated" and .covered != true)] | length),
              covered: ([$f[0][] | select(.covered == true)] | length)},
     findings: $f[0], fallback: $fb, versions: $v, alpha: $alpha}')"
  if [[ "$AS_JSON" == "1" ]]; then
    printf '%s\n' "$OUT" | canon_json "$ROOT"
  else
    printf '%s\n' "$OUT" | jq -r '"PHPCompatibility (\(.test_version // "-")): \(.status)\(if .reason then " (" + .reason + ")" else "" end)",
      (.findings[] | "  \(.kind)\t\(.file):\(.line)\t\(.source)")'
  fi
  log_info "phpcompat: $st${rs:+ ($rs)}."
  exit 0
}
# degrade REASON -> degraded, with detect-php-floor.sh's scan as the fallback.
degrade() {
  local fb
  log_warn "PHPCompatibility degraded ($1): falling back to detect-php-floor.sh."
  fb="$("$BASH" "$(plugin_root)/scripts/analysis/detect-php-floor.sh" --subject "$SUBJECT_ABS" ${RANGE:+--range "$RANGE"} --json < /dev/null 2> /dev/null || true)"
  printf '%s' "$fb" | jq -e 'type == "object"' > /dev/null 2>&1 || fb=null
  emit degraded "$1" "" "$fb"
}

[[ -n "$TV" ]] || emit skipped empty-php-window

# --- Where it runs ------------------------------------------------------------------
# In the test-bed (DDEV) when the root has a project, on the host otherwise.
RUNNER=""
if [[ -f "$ROOT/.ddev/config.yaml" ]] && have_cmd ddev; then
  ddev_ensure_running "$ROOT" || emit skipped ddev-unavailable
  RUNNER="$(drupal_runner "$ROOT")"
  [[ -n "$RUNNER" ]] || emit skipped ddev-unavailable
elif ! have_cmd php; then
  emit skipped no-php
fi
cd "$ROOT"

# --- The tree -------------------------------------------------------------------------
# tree_ok -> 0 when vendor/bin/phpcs exists and composer.lock holds exactly the pins.
tree_ok() {
  [[ -e "$TREE/vendor/bin/phpcs" && -f "$TREE/composer.lock" ]] || return 1
  jq -e --argjson p "$PINS" '((.packages // []) + (."packages-dev" // [])) | map({key: .name, value: .version}) | from_entries
    | . as $have | ($p | to_entries | all(.value == $have[.key]))' "$TREE/composer.lock" > /dev/null 2>&1
}
if ! tree_ok; then
  [[ "$INSTALL" == "1" ]] || degrade tree-missing
  [[ "$(printf '%s' "$PINS" | jq 'length')" -gt 0 ]] || degrade no-pins
  log_step "Installing PHPCompatibility into $TREE_REL"
  mkdir -p "$TREE" || degrade install-failed
  [[ -f "$ROOT/.drupilot/.gitignore" ]] || printf '*\n' > "$ROOT/.drupilot/.gitignore" 2> /dev/null || true
  # allow-plugins before require: the installer plugin sets installed_paths.
  printf '%s\n' '{"config":{"allow-plugins":{"dealerdirect/phpcodesniffer-composer-installer":true}}}' > "$TREE/composer.json"
  _pins=()
  while IFS= read -r _p; do [[ -n "$_p" ]] && _pins+=("$_p"); done <<EOF
$(printf '%s' "$PINS" | jq -r 'to_entries[] | "\(.key):\(.value)"')
EOF
  _rc=0
  if [[ -n "$RUNNER" ]]; then
    # The container's own Composer by absolute path (ddev_global_composer), with
    # the container's timeout: run_with_timeout does not reach through ddev exec.
    ddev exec timeout 600 "$(ddev_global_composer "$ROOT")" --working-dir="/var/www/html/$TREE_REL" \
      require --dev --no-interaction --no-progress ${_pins[@]+"${_pins[@]}"} < /dev/null >&2 || _rc=$?
  else
    have_cmd composer || degrade install-failed
    run_with_timeout 600 composer --working-dir="$TREE" require --dev --no-interaction --no-progress \
      ${_pins[@]+"${_pins[@]}"} < /dev/null >&2 || _rc=$?
  fi
  [[ "$_rc" == "0" ]] || degrade "install-failed (exit $_rc)"
  tree_ok || degrade "install-incomplete"
fi

# --- Standards --------------------------------------------------------------------------
# shellcheck disable=SC2086  # RUNNER is a command prefix ("ddev exec" or empty)
_installed="$($RUNNER "$TREE_REL/vendor/bin/phpcs" -i < /dev/null 2> /dev/null | tr -d '\r' | sed -n 's/^The installed coding standards are //p' | sed 's/ and /, /g; s/\.$//' | tr ',' '\n' | sed 's/^ *//; s/ *$//' || true)"
STD="PHPCompatibility"
while IFS= read -r _pkg; do
  [[ "$_pkg" =~ ^symfony/polyfill-php([0-9])([0-9])$ ]] || continue
  _s="PHPCompatibilitySymfonyPolyfillPHP${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  if printf '%s\n' "$_installed" | grep_q -xF "$_s"; then STD="$STD,$_s"
  else log_info "phpcompat: no $_s ruleset in the tree ($_pkg's functions are reported as new)."; fi
done <<EOF
$(printf '%s' "$POLY" | jq -r '.[]?' 2> /dev/null || true)
EOF
STANDARDS="$(printf '%s' "$STD" | jq -R -c 'split(",")')"
DRUPILOT_PROJECT_DIR="$ROOT" lock_set_json .phpcompat \
  "$(jq -n -c --argjson v "$PINS" --argjson s "$STANDARDS" '{packages: $v, standards: $s}')" > /dev/null 2>&1 || true

# --- The run ------------------------------------------------------------------------------
log_step "PHPCompatibility: testVersion $TV, $STD"
_rc=0
if [[ -n "$RUNNER" ]]; then
  ddev exec timeout 300 "$TREE_REL/vendor/bin/phpcs" --standard="$STD" --runtime-set testVersion "$TV" \
    --extensions=php,module,inc,install,theme,profile,engine --report=json -q "$SUBJECT_REL" \
    < /dev/null > "$TMP/report.json" 2> "$TMP/err" || _rc=$?
else
  run_with_timeout 300 "$TREE_REL/vendor/bin/phpcs" --standard="$STD" --runtime-set testVersion "$TV" \
    --extensions=php,module,inc,install,theme,profile,engine --report=json -q "$SUBJECT_REL" \
    < /dev/null > "$TMP/report.json" 2> "$TMP/err" || _rc=$?
fi
# PHPCS 4's exit code is a bitmask: 1 fixable, 2 non-fixable findings.
[[ "$_rc" -le 3 ]] || degrade "exit $_rc"
jq -e '(.totals | type) == "object" and (.files | type) == "object"' "$TMP/report.json" > /dev/null 2>&1 || degrade "no-json-report"
if jq -e '[.files[] | (.messages // [])[] | select((.source // "") == "Internal.Exception")] | length > 0' "$TMP/report.json" > /dev/null 2>&1; then
  degrade "internal-exception: $(jq -r '[.files[] | (.messages // [])[] | select(.source == "Internal.Exception") | .message] | .[0]' "$TMP/report.json" | cut -c1-160)"
fi

# --- Normalize ----------------------------------------------------------------------------
jq -c --arg root "$ROOT" --arg sp "$SUBJECT_REL" '
  def rel: ltrimstr("/var/www/html/") | ltrimstr($root + "/") | ltrimstr($sp + "/");
  [.files | to_entries[] | (.key | rel) as $f | (.value.messages // [])[]
   | select((.source // "") != "Internal.NoCodeFound")
   | (.source // "") as $s
   | {file: $f, line: (.line // 0), source: $s, type: (.type // "ERROR"), message: (.message // ""),
      kind: (if (.type // "ERROR") == "WARNING" then "deprecated"
             elif (($s | split(".") | .[2] // "") | startswith("New")) then "floor"
             else "removed" end)}]
  | unique_by([.file, .line, .source]) | sort_by([.file, .line, .source])' "$TMP/report.json" > "$TMP/norm.json" \
  || degrade "unreadable-report"
# Each finding's config/php/rules.json row (its phpcompat sources: exact, or a
# prefix ending in '*'). A row's finding is covered, and adds no item, when
# Rector applies or denies the row over [L..U] (apply-modernize, apply-compat,
# deny: the compat pass reaches U, ADR 0002) or when php-target.sh, which
# classifies against P, reports it (a removed-blocking or report-only row of
# [L..P] with a pattern: the row's own item).
php_rules_classified "$L" "$U" > "$TMP/classes-u.json"
php_rules_classified "$L" "${P:-$U}" > "$TMP/classes-p.json"
jq -c --slurpfile cu "$TMP/classes-u.json" --slurpfile cp "$TMP/classes-p.json" --slurpfile rules "$(version_data_dir)/php/rules.json" '
  ([$cu[0][] | {key: .id, value: .}] | from_entries) as $c
  | ([$cp[0][] | {key: .id, value: .}] | from_entries) as $cpp
  | [$rules[0].rules[] | select((.phpcompat | type) == "array") | {id: (.id // .rule), codes: .phpcompat}] as $rows
  | def hits($s): . as $code | if ($code | endswith("*")) then ($s | startswith($code | rtrimstr("*"))) else $s == $code end;
    map(.source as $s
        | ([$rows[] | select(any(.codes[]; hits($s))) | .id] | .[0] // null) as $rid
        | . + {rule: $rid,
               covered: (if $rid == null then false
                         else (($c[$rid].class // "") | IN("apply-modernize", "apply-compat", "deny"))
                           or ((($cpp[$rid].class // "") | IN("removed-blocking", "report-only")) and $cpp[$rid].detect != null) end)})' \
  "$TMP/norm.json" > "$TMP/findings.json" 2> /dev/null || cp "$TMP/norm.json" "$TMP/findings.json"
emit ok "" "$TMP/findings.json"
