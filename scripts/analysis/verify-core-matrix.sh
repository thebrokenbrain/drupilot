#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/verify-core-matrix.sh
# Verify a module/theme STATICALLY on every Drupal core major its
# core_version_requirement declares, not only on the Drupal 11 test-bed.
#
# A port that keeps `^10 || ^11` claims Drupal 10 support, but the validate loop
# only ever sees the ONE core installed in the test-bed. This script runs the
# same PHPStan analysis (phpstan-drupal + deprecation rules) and `php -l` on a
# cached REFERENCE core per extra leg (e.g. the latest Drupal 10, or 10.3 for a
# `^10.3 || ^11` floor), and compares each leg with the test-bed (the BASELINE):
#   * an error a reference leg reports and the baseline does not — e.g. an
#     `#[\Override]` on a method only Drupal 11.3+ core declares, a call to a
#     class/method that only exists in Drupal 11 — is an INCOMPATIBILITY of that
#     leg (it fails);
#   * deprecation notices never fail a leg (the code still runs there);
#   * a class from a module that is not installed in the reference core
#     (a contrib dependency) is reported as `sandbox_missing_dependency`,
#     documented, never "fixed";
#   * on a reference leg, a finding in tests/ is reported as `test_only`: core's
#     test API typing differs between majors (Drupal 10.6's
#     WebDriverTestBase::assertSession() is documented as returning WebAssert,
#     11.4's as WebDriverWebAssert), and the runtime proof of the suite on
#     Drupal 10 belongs to the test phase;
#   * a finding from one of phpstan-drupal's own best-practice rules (identifiers
#     read from the installed extension) is reported as `advisory`;
#   * a finding PHP tolerates at runtime is reported as `tolerated`, never as an
#     incompatibility. A leg differs from another only through core (same PHP,
#     same analyser), so the callee is userland code, and the matrix answers
#     "does it break on that core?", not "is it tidy?". Two cases qualify:
#       - `arguments.count` with MORE arguments than the callee takes ("invoked
#         with 2 parameters, 1 required", e.g. a Drupal 11 two-argument
#         ConfigFormBase::__construct() call on 10.0, whose constructor takes
#         one): PHP drops extra arguments to a userland function or method.
#         TOO FEW arguments stays incompatible (ArgumentCountError);
#       - `method.void` / `staticMethod.void` / `function.void` ("Result of
#         method ...::set() (void) is used"), typically a `: void` return type a
#         newer core/Symfony declares on a method that never returned a value:
#         the expression is null and nothing is raised. Review it, since the
#         value is always null on that core;
#   * findings both legs share are pre-existing analysis findings, not a core
#     difference (run-phpstan.sh / the validate loop own those).
# A finding's `kind` is one of: incompatible, deprecation,
# sandbox_missing_dependency, test_only, advisory, tolerated (shared ones are
# counted in `errors` but not listed).
# When the baseline leg itself cannot be analysed (status error), a reference
# leg with findings is `skipped` (its findings cannot be told apart from
# pre-existing ones), never `fail`; d10_support then stays declared-not-verified.
# The baseline leg likewise fails on errors the reference legs do not have
# (code that breaks only on the newer core).
# `php -l` runs with the container PHP, and — when a leg's lowest PHP (the max of
# that core's own PHP minimum and the subject's composer require.php) is below
# it — also with that lower PHP in a throwaway `php:X.Y-cli` Docker container,
# so a `^10 || ^11` module with `require.php: ">=8.1"` is linted on PHP 8.1.
#
# Reference cores live in <drupal_root>/.drupilot/cores/drupal-<leg>/ (inside
# the DDEV mount and the self-ignored .drupilot/ dir, so they never reach a
# patch) and are built ONCE through `ddev exec composer` (never the host PHP):
# drupal/recommended-project + drupal/core-recommended at the leg's constraint,
# the test-bed's exact PHPStan toolchain, and the test runtime packages that
# version's drupal/core-dev requires (PHPUnit, Mink, ...; minus its own
# static-analysis tools) so test classes resolve. In deterministic mode
# (DRUPILOT_DETERMINISTIC, default) the resolved core version is frozen in the
# lockfile (`.verify_cores["<leg>"]`) and reused; --refresh (or
# DRUPILOT_DETERMINISTIC=false) re-resolves. The subject is COPIED (not
# symlinked) into the reference core's web/{modules,themes,profiles}/custom/.
#
# Network: building a reference core needs Packagist. When it cannot be reached
# the leg is `skipped` with the reason and the verdict stays
# `declared-not-verified` (exit 0): a blocked network never blocks a port.
#
# Usage:
#   verify-core-matrix.sh --subject DIR [--cores auto|off|LIST] [--level N]
#                         [--lint-floor auto|off] [--refresh] [--json]
#                         [--dry-run] [-h|--help]
#
# Options:
#   --subject DIR      The module/theme (under the Drupal 11 test-bed). Required.
#   --cores SPEC       auto (default; DRUPILOT_VERIFY_CORES): the legs the
#                      subject's core_version_requirement declares (^10 || ^11
#                      -> 10,11; ^10.3 || ^11 -> 10.3,11; ^11 -> 11 only, so no
#                      reference core is built). off: do nothing. Or an explicit
#                      comma list of MAJOR or MAJOR.MINOR legs, e.g. 10,11 or
#                      10.3,11.2. A leg the test-bed core satisfies runs on the
#                      test-bed; the others get a reference core.
#   --level N          PHPStan level (default DRUPILOT_PHPSTAN_LEVEL, 2).
#   --lint-floor MODE  auto (default): also lint on a leg's lower PHP floor via
#                      Docker (php:X.Y-cli). off: container PHP only.
#   --refresh          Rebuild the reference cores and re-resolve their version
#                      (ignores the locked version, then re-freezes it).
#   --json             Print the matrix JSON on STDOUT (see below).
#   --dry-run          Print the plan (legs, sources, constraints, whether a
#                      reference core would be built) and change nothing: no
#                      DDEV start, no composer, no copy, no lock write.
#   -h, --help         Show this help.
#
# JSON (STDOUT; also persisted to <state_dir>/core-matrix.json unless --dry-run):
#   {tool, subject, machine_name, drupal_root, core_version_requirement, level,
#    container_php, subject_digest, generated_at, dry_run,
#    legs:[{core, role: baseline|reference, source: testbed|reference,
#           constraint, version, php_floor, status: pass|fail|skipped|error,
#           reason, phpstan:{status, errors, leg_only, incompatible,
#           deprecations, sandbox_missing_dependency, test_only, advisory,
#           tolerated,
#           findings:[{file, line, identifier, message, kind}]},
#           lint:[{php, via, status, errors, files:[{file, error}]}]}],
#    d10_support: verified-static|verified-static-above-floor|failed|
#                 declared-not-verified|n/a,
#    d10_floor, d10_checked:[versions], d10_floor_checked,
#    verdict: pass|fail|not-verified|off, tests_analysed, notes:[...]}
#   d10_support is verified-static only when every Drupal 10 leg passed (PHPStan
#   + php -l clean on that core — runtime, the test suite, is NOT exercised)
#   AND one of them is the declared floor minor (d10_floor, e.g. 10.3 for
#   ^10.3). A '^10' leg resolves to the newest 10.x, so a clean run there is
#   verified-static-above-floor: the floor (10.0) itself was not checked.
#
# Gate: `test` profile (Docker + daemon + DDEV); the test-bed DDEV project is
# started when stopped. Output: logs and the human table on STDERR.
#
# Exit codes: 0 every leg passed, or a leg could not be verified (skipped,
# not-verified; see the JSON) · 1 usage error · 2 requirements missing / no
# test-bed · 3 a leg FAILED (an incompatibility was found).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
CORES_SPEC=""
LEVEL=""
LINT_FLOOR=""
REFRESH=0
AS_JSON=0
DRY_RUN=0
# Composer runs INSIDE the web container (ddev exec). A host-side `timeout`
# only kills the docker-exec client and leaves composer running in the
# container, so the limit is applied in the container itself (GNU timeout in
# the ddev-webserver image, which kills the whole process group); the host
# limit is a later backstop for a hung `ddev exec` client.
# Under `timeout`, a bare `composer` would resolve to the TEST-BED's
# vendor/bin/composer (drupal/core-dev ships one; EXECIGNORE only hides it from
# the top-level shell), whose plugins then rewrite the test-bed's vendor while
# building a reference core. Every call therefore names the container's own
# Composer by absolute path (VCM_COMPOSER_BIN, see ddev_global_composer).
COMPOSER_TIMEOUT=900
COMPOSER_HOST_TIMEOUT=$((COMPOSER_TIMEOUT + 60))
VCM_COMPOSER_LIMIT="$COMPOSER_TIMEOUT"
export VCM_COMPOSER_LIMIT
VCM_COMPOSER_BIN="/usr/local/bin/composer"
export VCM_COMPOSER_BIN

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --cores) CORES_SPEC="${2:-}"; shift 2 || die "--cores needs a value" 1;;
    --cores=*) CORES_SPEC="${1#*=}"; shift;;
    --level) LEVEL="${2:-}"; shift 2 || die "--level needs a value" 1;;
    --level=*) LEVEL="${1#*=}"; shift;;
    --lint-floor) LINT_FLOOR="${2:-}"; shift 2 || die "--lint-floor needs a value" 1;;
    --lint-floor=*) LINT_FLOOR="${1#*=}"; shift;;
    --refresh) REFRESH=1; shift;;
    --json) AS_JSON=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)." 1;;
  esac
done

[[ -n "$SUBJECT" ]] || die "Missing --subject DIR (the module/theme to verify)." 1
have_cmd jq || die "jq is required for verify-core-matrix.sh." 2

[[ -n "$LEVEL" ]] || LEVEL="$(config_get DRUPILOT_PHPSTAN_LEVEL "2")"
case "$LEVEL" in [0-9]|max) : ;; *) die "Invalid --level '$LEVEL' (expected 0-9 or 'max')." 1;; esac
[[ -n "$LINT_FLOOR" ]] || LINT_FLOOR="auto"
case "$LINT_FLOOR" in auto|off) : ;; *) die "Invalid --lint-floor '$LINT_FLOOR' (expected auto|off)." 1;; esac
[[ -n "$CORES_SPEC" ]] || CORES_SPEC="$(config_get DRUPILOT_VERIFY_CORES auto)"
CORES_SPEC="$(lc "$(trim "$CORES_SPEC")")"

# --- Subject and test-bed -------------------------------------------------
SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
[[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1
is_drupal_extension_dir "$SUBJECT_ABS" || die "No *.info.yml in '$SUBJECT_ABS': not a Drupal module/theme." 1
SUBJECT_PHYS="$(cd -P "$SUBJECT_ABS" 2>/dev/null && pwd || printf '%s' "$SUBJECT_ABS")"
NAME="$(subject_machine_name "$SUBJECT_ABS")"
STYPE="$(subject_type "$SUBJECT_ABS" 2>/dev/null || echo module)"
case "$STYPE" in theme) EXT_DIR="themes";; profile) EXT_DIR="profiles";; *) EXT_DIR="modules";; esac
CORE_REQ="$(trim "$(subject_core_requirement "$SUBJECT_ABS" 2>/dev/null || true)")"

ROOT="$(find_drupal_root "$SUBJECT_ABS" 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "No Drupal root (test-bed) found from '$SUBJECT_ABS'. Run /drupilot-setup first." 2
case "$SUBJECT_ABS" in
  "$ROOT"/*) SUBJECT_REL="${SUBJECT_ABS#"$ROOT"/}";;
  *) die "Subject '$SUBJECT_ABS' is outside the Drupal root '$ROOT'." 1;;
esac
export DRUPILOT_PROJECT_DIR="$ROOT"

CORES_REL=".drupilot/cores"
CORES_DIR="$ROOT/$CORES_REL"
MATRIX_DIR="$ROOT/.drupilot/core-matrix"
CONTAINER_ROOT="/var/www/html"

TESTBED_VERSION="$(drupal_core_version "$ROOT")"
TESTBED_MAJOR="${TESTBED_VERSION%%.*}"
TESTBED_MINOR="$(printf '%s' "$TESTBED_VERSION" | cut -d. -f2)"

# --- Resolve the legs -------------------------------------------------------
declare -a LEGS=()
NOTES_JSON='[]'
add_note() { NOTES_JSON="$(printf '%s' "$NOTES_JSON" | jq -c --arg n "$1" '. + [$n]')"; }

if [[ "$CORES_SPEC" == "off" ]]; then
  log_info "Core matrix verification is off (DRUPILOT_VERIFY_CORES / --cores off)."
  OUT="$(jq -nc --arg s "$SUBJECT_ABS" --arg n "$NAME" --arg req "$CORE_REQ" \
    --argjson dry "$([[ "$DRY_RUN" == 1 ]] && echo true || echo false)" \
    '{tool: "verify-core-matrix", subject: $s, machine_name: $n,
      core_version_requirement: ($req | select(. != "") // null), legs: [],
      d10_support: (if ($req | test("(^|[^0-9])10([^0-9]|$)")) then "declared-not-verified" else "n/a" end),
      verdict: "off", dry_run: $dry, notes: ["verification disabled"]}')"
  [[ "$AS_JSON" == 1 ]] && printf '%s\n' "$OUT"
  exit 0
elif [[ "$CORES_SPEC" == "auto" ]]; then
  [[ -n "$CORE_REQ" ]] || die "The subject declares no core_version_requirement; pass --cores explicitly." 1
  while IFS= read -r l; do [[ -n "$l" ]] && LEGS+=("$l"); done < <(core_verify_legs "$CORE_REQ")
else
  IFS=',' read -r -a _raw <<<"$CORES_SPEC"
  for l in ${_raw[@]+"${_raw[@]}"}; do
    l="$(trim "$l")"; l="${l%.x}"
    [[ "$l" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "Invalid core leg '$l' in --cores (expected MAJOR or MAJOR.MINOR, e.g. 10,11 or 10.3)." 1
    [[ "${l%%.*}" -ge 10 ]] || die "Core leg '$l' is below Drupal 10; only Drupal 10+ can be verified (phpstan-drupal 2.x)." 1
    LEGS+=("$l")
  done
fi
[[ ${#LEGS[@]} -gt 0 ]] || die "No Drupal 10+ core leg to verify for '${CORE_REQ:-?}'." 1

# leg_on_testbed <leg> -> 0 when the test-bed core satisfies the leg.
leg_on_testbed() {
  local leg="$1" maj min
  maj="${leg%%.*}"; min=""
  [[ "$leg" == *.* ]] && min="${leg#*.}"
  [[ -n "$TESTBED_MAJOR" && "$maj" == "$TESTBED_MAJOR" ]] || return 1
  [[ -z "$min" || "$min" == "$TESTBED_MINOR" ]]
}
# leg_constraint <leg> -> the Composer constraint of a reference core.
leg_constraint() {
  if [[ "$1" == *.* ]]; then printf '~%s.0' "$1"; else printf '^%s' "$1"; fi
}

# The baseline is the test-bed leg; it is always part of a matrix with a
# reference leg (the comparison needs it), even when not declared.
BASELINE=""
for l in "${LEGS[@]}"; do leg_on_testbed "$l" && { BASELINE="$l"; break; }; done
if [[ -z "$BASELINE" ]]; then
  [[ -n "$TESTBED_MAJOR" ]] || die "Could not read the test-bed's Drupal core version under '$ROOT'." 2
  BASELINE="$TESTBED_MAJOR"
  LEGS+=("$BASELINE")
  add_note "The test-bed core ($TESTBED_VERSION) is not one of the requested legs; it is analysed as the comparison baseline."
fi
# Distinct legs, sorted by version (bash 3.2: no associative arrays).
LEGS_SORTED="$(printf '%s\n' "${LEGS[@]}" | awk '!seen[$0]++' | sort -t. -k1,1n -k2,2n)"
LEGS=()
while IFS= read -r l; do [[ -n "$l" ]] && LEGS+=("$l"); done <<<"$LEGS_SORTED"

# lock_key <leg> -> the lockfile path of a leg's frozen reference core.
lock_key() { printf '.verify_cores["%s"]' "$1"; }

# --- Dry run: the plan only ---------------------------------------------------
if [[ "$DRY_RUN" == 1 ]]; then
  GATE_OK=true
  bash "$(plugin_root)/scripts/env/preflight.sh" --profile test --quiet >/dev/null 2>&1 || GATE_OK=false
  PLAN='[]'
  for l in "${LEGS[@]}"; do
    if leg_on_testbed "$l"; then
      PLAN="$(printf '%s' "$PLAN" | jq -c --arg c "$l" --arg v "$TESTBED_VERSION" --arg b "$BASELINE" \
        '. + [{core: $c, role: (if $c == $b then "baseline" else "reference" end), source: "testbed", constraint: null, version: $v, action: "analyse the subject in place"}]')"
    else
      d="$CORES_DIR/drupal-$l"; act="build"; ver=""
      locked="$(lock_get "$(lock_key "$l").version" "")"
      if [[ -f "$d/.drupilot-core.json" ]]; then
        ver="$(jq -r '.version // empty' "$d/.drupilot-core.json" 2>/dev/null || true)"
        act="reuse"
        [[ "$REFRESH" == 1 ]] && act="rebuild"
        [[ -n "$locked" && "$locked" != "$ver" ]] && act="rebuild"
      fi
      PLAN="$(printf '%s' "$PLAN" | jq -c --arg c "$l" --arg k "$(leg_constraint "$l")" --arg v "${ver:-$locked}" \
        --arg a "$act" --arg d "$CORES_REL/drupal-$l" --arg lk "$locked" \
        '. + [{core: $c, role: "reference", source: "reference", constraint: $k, version: ($v | select(. != "") // null),
               locked_version: ($lk | select(. != "") // null), path: $d,
               action: (if $a == "build" then "build the reference core (composer, needs network)" elif $a == "rebuild" then "rebuild the reference core" else "reuse the cached reference core (rebuilt if the container PHP or the PHPStan toolchain changed)" end)}]')"
    fi
  done
  OUT="$(jq -nc --arg s "$SUBJECT_ABS" --arg n "$NAME" --arg r "$ROOT" --arg req "$CORE_REQ" \
    --arg lvl "$LEVEL" --argjson legs "$PLAN" --argjson gate "$GATE_OK" --argjson notes "$NOTES_JSON" \
    --arg lf "$LINT_FLOOR" \
    '{tool: "verify-core-matrix", dry_run: true, subject: $s, machine_name: $n, drupal_root: $r,
      core_version_requirement: ($req | select(. != "") // null), level: $lvl, lint_floor: $lf,
      gate_ok: $gate, legs: $legs, notes: $notes}')"
  log_step "Core matrix plan — $NAME (${CORE_REQ:-no requirement})"
  printf '%s' "$OUT" | jq -r '.legs[] | "  \(.core)\t\(.role)\t\(.source)\t\(.version // .constraint // "-")\t\(.action)"' >&2
  [[ "$GATE_OK" == true ]] || log_warn "The 'test' requirements (Docker + DDEV) are not satisfied; a real run would stop (exit 2)."
  [[ "$AS_JSON" == 1 ]] && printf '%s\n' "$OUT"
  exit 0
fi

# --- Gate: test (Docker + daemon + DDEV) --------------------------------------
PREFLIGHT="$(plugin_root)/scripts/env/preflight.sh"
if ! bash "$PREFLIGHT" --profile test --quiet >/dev/null 2>&1; then
  log_err "The 'test' requirements (Docker + daemon + DDEV) are not satisfied; cannot verify the core matrix."
  bash "$PREFLIGHT" --profile test >&2 || true
  exit 2
fi
[[ -f "$ROOT/.ddev/config.yaml" ]] || die "'$ROOT' has no DDEV project; the core matrix runs through DDEV. Run /drupilot-setup first." 2
ddev_ensure_running "$ROOT" || die "Could not start the DDEV project at $ROOT." 2
[[ -f "$ROOT/vendor/bin/phpstan" ]] || die "vendor/bin/phpstan is missing in the test-bed. Install the toolchain first (/drupilot-setup)." 2
VCM_COMPOSER_BIN="$(ddev_global_composer "$ROOT")"
export VCM_COMPOSER_BIN

STATE_FILE="$(core_matrix_file "$SUBJECT_ABS")"
mkdir -p "$CORES_DIR" "$MATRIX_DIR"
[[ -f "$ROOT/.drupilot/.gitignore" ]] || printf '*\n' > "$ROOT/.drupilot/.gitignore"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# dexec <container_dir> <command string> -> run in the web container; the
# command's stdout/stderr pass through. ddev's own "Failed to execute" line is
# dropped by the callers that capture stderr.
dexec() {
  local dir="$1"; shift
  ( cd "$ROOT" && ddev exec -d "$dir" "$*" </dev/null )
}

CONTAINER_PHP="$(dexec "$CONTAINER_ROOT" 'php -r "echo PHP_MAJOR_VERSION . \".\" . PHP_MINOR_VERSION;"' 2>/dev/null | tr -d '[:space:]' || true)"
[[ -n "$CONTAINER_PHP" ]] || CONTAINER_PHP="$(ddev_php_version "$ROOT")"

# network_reason <log file> -> a short reason when composer failed to reach the
# network, else nothing.
network_reason() {
  if grep -qiE 'could not resolve host|curl error|failed to download|network is unreachable|connection (timed out|refused)|temporary failure in name resolution|file could not be downloaded|failed to open stream' "$1" 2>/dev/null; then
    printf 'network unavailable (composer could not reach the package repositories)'
  fi
  return 0
}
# tail_reason <log file> -> the last meaningful composer line, for a reason.
tail_reason() {
  sed -e $'s/\x1b\\[[0-9;]*m//g' "$1" 2>/dev/null | grep -vE 'Failed to execute command|^[[:space:]]*$' | tail -n 3 | tr '\n' ' ' | cut -c1-300
  return 0
}

# heal_extension_config <host dir> <container dir> <label> -> 0 when the
# project's phpstan/extension-installer GeneratedConfig.php is sound, repairing
# it first when needed. A broken one makes PHPStan crash (an include that no
# longer exists) or run WITHOUT phpstan-drupal (the package's stub left in
# place), which reports bogus "unknown class Drupal\..." errors. `composer
# install` against the unchanged lock reinstalls nothing and re-runs the
# installer plugin, which rewrites the file. Sets HEAL_REASON when it stays
# broken.
HEAL_REASON=""
heal_extension_config() {
  local host="$1" cdir="$2" label="$3" why
  HEAL_REASON=""
  why="$(phpstan_extension_config_problem "$host")" && return 0
  log_warn "The PHPStan extension config of $label is broken ($why); regenerating it with composer install."
  run_with_timeout "$COMPOSER_HOST_TIMEOUT" bash -c 'cd "$1" && ddev exec -d "$2" "timeout -k 20 $VCM_COMPOSER_LIMIT $VCM_COMPOSER_BIN install --no-interaction --no-progress" </dev/null' \
    _ "$ROOT" "$cdir" >"$TMP/heal.log" 2>&1 || true
  if why="$(phpstan_extension_config_problem "$host")"; then
    log_ok "Regenerated the PHPStan extension config of $label."
    return 0
  fi
  HEAL_REASON="the PHPStan extension config of $label is broken ($why) and composer install did not repair it"
  return 1
}

# The test-bed first: a broken config there (e.g. left by an older drupilot
# that ran the test-bed's own vendor/bin/composer for a reference core) would
# make the baseline leg crash.
heal_extension_config "$ROOT" "$CONTAINER_ROOT" "the test-bed" \
  || log_err "$HEAL_REASON. Run 'ddev composer install' in $ROOT."

# PHPStan toolchain of the reference cores = the test-bed's exact versions (so
# both legs run the same analyser), else the configured ranges. Every PHPStan
# extension the test-bed has (composer type "phpstan-extension", e.g.
# phpstan/phpstan-phpunit pulled in by drupal/core-dev) is mirrored too:
# extension-installer enables whatever is installed, and a rule set that differs
# between legs would show up as a fake core difference.
TOOL_PKGS="phpstan/phpstan phpstan/extension-installer mglaman/phpstan-drupal phpstan/phpstan-deprecation-rules"
if [[ -f "$ROOT/composer.lock" ]]; then
  for _p in $(jq -r '((.packages // []) + (."packages-dev" // []))[] | select(.type == "phpstan-extension") | .name' "$ROOT/composer.lock" 2>/dev/null | LC_ALL=C sort); do
    case " $TOOL_PKGS " in *" $_p "*) : ;; *) TOOL_PKGS="$TOOL_PKGS $_p";; esac
  done
fi
toolchain_json() {
  local out='{}' p v key
  for p in $TOOL_PKGS; do
    v="$(installed_package_version "$ROOT" "$p")"
    if [[ -z "$v" ]]; then
      key=""
      case "$p" in
        phpstan/phpstan) key=phpstan;;
        phpstan/extension-installer) key=phpstan_extension_installer;;
        mglaman/phpstan-drupal) key=phpstan_drupal;;
        phpstan/phpstan-deprecation-rules) key=phpstan_deprecation_rules;;
      esac
      [[ -n "$key" ]] && { v="$(config_json ".packages.$key" "")"; v="${v#*:}"; }
    fi
    [[ -n "$v" ]] || v="*"
    out="$(printf '%s' "$out" | jq -c --arg p "$p" --arg v "$v" '. + {($p): $v}')"
  done
  printf '%s' "$out"
}
TOOLCHAIN="$(toolchain_json)"

# build_reference <leg> <requested constraint or exact version> -> builds
# $CORES_DIR/drupal-<leg> atomically. Prints nothing; returns 0 on success and
# sets BUILD_REASON on failure.
BUILD_REASON=""
build_reference() {
  local leg="$1" want="$2" tmpname tmpdir final log ver devreq
  tmpname=".build-$leg-$$"; tmpdir="$CORES_DIR/$tmpname"; final="$CORES_DIR/drupal-$leg"
  log="$TMP/build-$leg.log"; : > "$log"
  rm -rf "$tmpdir"
  log_step "Building the reference Drupal $leg core ($want) in $CORES_REL/drupal-$leg (once; cached)"
  if ! run_with_timeout "$COMPOSER_HOST_TIMEOUT" bash -c 'cd "$1" && ddev exec -d "$2" "timeout -k 20 $VCM_COMPOSER_LIMIT $VCM_COMPOSER_BIN create-project --no-interaction --no-install --no-progress '"'"'drupal/recommended-project:$3'"'"' $4" </dev/null' \
       _ "$ROOT" "$CONTAINER_ROOT" "$want" "$CORES_REL/$tmpname" >>"$log" 2>&1; then
    BUILD_REASON="$(network_reason "$log")"; [[ -n "$BUILD_REASON" ]] || BUILD_REASON="composer create-project failed: $(tail_reason "$log")"
    rm -rf "$tmpdir"; return 1
  fi
  # composer.json edits are made on the host with jq (no shell quoting through
  # ddev exec): pin core-recommended to the leg, add the PHPStan toolchain.
  # audit.block-insecure=false: Composer >= 2.9 refuses core releases with a
  # security advisory, i.e. every older minor (e.g. 10.3.x). This core is only
  # ever READ by PHPStan — never installed as a site or served — so the declared
  # floor can still be analysed.
  if ! jq --arg c "$want" --argjson t "$TOOLCHAIN" \
      '.require["drupal/core-recommended"] = $c
       | ."require-dev" = ((."require-dev" // {}) + $t)
       | .config["allow-plugins"]["phpstan/extension-installer"] = true
       | .config.audit["block-insecure"] = false' \
      "$tmpdir/composer.json" > "$TMP/composer.json" 2>>"$log"; then
    BUILD_REASON="could not edit the reference composer.json"; rm -rf "$tmpdir"; return 1
  fi
  cp "$TMP/composer.json" "$tmpdir/composer.json"
  if ! run_with_timeout "$COMPOSER_HOST_TIMEOUT" bash -c 'cd "$1" && ddev exec -d "$2" "timeout -k 20 $VCM_COMPOSER_LIMIT $VCM_COMPOSER_BIN update --no-interaction --no-progress --no-audit" </dev/null' \
       _ "$ROOT" "$CONTAINER_ROOT/$CORES_REL/$tmpname" >>"$log" 2>&1; then
    BUILD_REASON="$(network_reason "$log")"
    if [[ -z "$BUILD_REASON" ]]; then
      if grep -qiE 'requires php|your php version|php extension' "$log"; then
        BUILD_REASON="Drupal $want cannot be installed on the container PHP $CONTAINER_PHP: $(tail_reason "$log")"
      else
        BUILD_REASON="composer could not install Drupal $want with the PHPStan toolchain: $(tail_reason "$log")"
      fi
    fi
    rm -rf "$tmpdir"; return 1
  fi
  ver="$(drupal_core_version "$tmpdir")"
  # Test runtime: the packages THIS core's drupal/core-dev requires, minus its
  # static-analysis tools (they would downgrade PHPStan to the D10 1.x line).
  local test_deps=false
  devreq="$(dexec "$CONTAINER_ROOT/$CORES_REL/$tmpname" "$VCM_COMPOSER_BIN show --all --format=json drupal/core-dev $ver" 2>>"$log" \
            | sed -n '/^{/,$p' | jq -c '(.requires // {}) | with_entries(select(.key | test("^(phpstan/|mglaman/|drupal/coder$|micheh/|squizlabs/)") | not))' 2>/dev/null || true)"
  if [[ -n "$devreq" && "$devreq" != "{}" && "$devreq" != "null" ]]; then
    cp "$tmpdir/composer.json" "$TMP/composer.json.bak"; cp "$tmpdir/composer.lock" "$TMP/composer.lock.bak" 2>/dev/null || true
    jq --argjson d "$devreq" '."require-dev" = ((."require-dev" // {}) + $d)' "$tmpdir/composer.json" > "$TMP/composer.json" \
      && cp "$TMP/composer.json" "$tmpdir/composer.json"
    if run_with_timeout "$COMPOSER_HOST_TIMEOUT" bash -c 'cd "$1" && ddev exec -d "$2" "timeout -k 20 $VCM_COMPOSER_LIMIT $VCM_COMPOSER_BIN update --no-interaction --no-progress --no-audit" </dev/null' \
         _ "$ROOT" "$CONTAINER_ROOT/$CORES_REL/$tmpname" >>"$log" 2>&1; then
      test_deps=true
    else
      log_warn "Could not add drupal/core-dev $ver's test runtime to the reference core; the subject's tests/ are left out of every leg."
      cp "$TMP/composer.json.bak" "$tmpdir/composer.json"; cp "$TMP/composer.lock.bak" "$tmpdir/composer.lock" 2>/dev/null || true
      run_with_timeout "$COMPOSER_HOST_TIMEOUT" bash -c 'cd "$1" && ddev exec -d "$2" "timeout -k 20 $VCM_COMPOSER_LIMIT $VCM_COMPOSER_BIN install --no-interaction --no-progress" </dev/null' \
        _ "$ROOT" "$CONTAINER_ROOT/$CORES_REL/$tmpname" >>"$log" 2>&1 || true
    fi
  fi
  if ! heal_extension_config "$tmpdir" "$CONTAINER_ROOT/$CORES_REL/$tmpname" "the reference Drupal $want core"; then
    BUILD_REASON="$HEAL_REASON"; rm -rf "$tmpdir"; return 1
  fi
  jq -n --arg leg "$leg" --arg c "$(leg_constraint "$leg")" --arg want "$want" --arg v "$ver" \
     --arg php "$CONTAINER_PHP" --argjson t "$TOOLCHAIN" --argjson td "$test_deps" \
     --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '{leg: $leg, constraint: $c, requested: $want, version: $v, php: $php, toolchain: $t, test_deps: $td, built_at: $at}' \
     > "$tmpdir/.drupilot-core.json"
  rm -rf "$final"
  mv "$tmpdir" "$final"
  log_ok "Reference Drupal core $ver ready in $CORES_REL/drupal-$leg."
  return 0
}

# ensure_reference <leg> -> 0 when $CORES_DIR/drupal-<leg> is usable (built or
# reused); sets REF_VERSION, or BUILD_REASON on failure.
REF_VERSION=""
ensure_reference() {
  local leg="$1" d="$CORES_DIR/drupal-$1" marker constraint locked want mver mphp mtool
  marker="$d/.drupilot-core.json"; constraint="$(leg_constraint "$leg")"
  locked=""
  if deterministic_mode && [[ "$REFRESH" == 0 ]]; then
    locked="$(lock_get "$(lock_key "$leg").version" "")"
  fi
  want="${locked:-$constraint}"
  if [[ "$REFRESH" == 0 && -f "$marker" && -f "$d/vendor/bin/phpstan" ]]; then
    mver="$(jq -r '.version // empty' "$marker" 2>/dev/null || true)"
    mphp="$(jq -r '.php // empty' "$marker" 2>/dev/null || true)"
    mtool="$(jq -c '.toolchain // {}' "$marker" 2>/dev/null || true)"
    if [[ -n "$mver" && ( -z "$locked" || "$locked" == "$mver" ) && "$mphp" == "$CONTAINER_PHP" \
          && "$(printf '%s' "$mtool" | jq -cS . 2>/dev/null)" == "$(printf '%s' "$TOOLCHAIN" | jq -cS .)" ]]; then
      if ! deterministic_mode; then
        # Floating mode: refresh within the constraint (best effort, offline-safe).
        if ! run_with_timeout "$COMPOSER_HOST_TIMEOUT" bash -c 'cd "$1" && ddev exec -d "$2" "timeout -k 20 $VCM_COMPOSER_LIMIT $VCM_COMPOSER_BIN update --no-interaction --no-progress --no-audit" </dev/null' \
             _ "$ROOT" "$CONTAINER_ROOT/$CORES_REL/drupal-$leg" >"$TMP/refresh-$leg.log" 2>&1; then
          log_warn "Could not refresh the reference Drupal $leg core ($(network_reason "$TMP/refresh-$leg.log")); using the cached $mver."
        fi
        mver="$(drupal_core_version "$d")"
        jq --arg v "$mver" '.version = $v' "$marker" > "$TMP/marker.json" && cp "$TMP/marker.json" "$marker"
      fi
      # A cached core built by an older drupilot can carry a stub or foreign
      # extension config (it then analyses without phpstan-drupal): repair it,
      # else rebuild it.
      if ! heal_extension_config "$d" "$CONTAINER_ROOT/$CORES_REL/drupal-$leg" "the cached reference Drupal $mver core"; then
        log_warn "$HEAL_REASON; rebuilding it."
        build_reference "$leg" "$want" || return 1
        REF_VERSION="$(jq -r '.version // empty' "$d/.drupilot-core.json" 2>/dev/null || true)"
        lock_set_json "$(lock_key "$leg")" "$(jq -nc --arg c "$constraint" --arg v "$REF_VERSION" '{constraint: $c, version: $v}')" 2>/dev/null || true
        return 0
      fi
      REF_VERSION="$mver"
      log_info "Reusing the reference Drupal core $mver ($CORES_REL/drupal-$leg)."
      lock_set_json "$(lock_key "$leg")" "$(jq -nc --arg c "$constraint" --arg v "$mver" '{constraint: $c, version: $v}')" 2>/dev/null || true
      return 0
    fi
    log_info "The cached reference Drupal $leg core does not match (version '$mver' vs lock '${locked:-none}', PHP '$mphp' vs '$CONTAINER_PHP', or the PHPStan toolchain changed); rebuilding."
  fi
  build_reference "$leg" "$want" || return 1
  REF_VERSION="$(jq -r '.version // empty' "$d/.drupilot-core.json" 2>/dev/null || true)"
  lock_set_json "$(lock_key "$leg")" "$(jq -nc --arg c "$constraint" --arg v "$REF_VERSION" '{constraint: $c, version: $v}')" 2>/dev/null || true
  return 0
}

# copy_subject <reference dir> -> a real copy of the subject (no VCS/vendor).
copy_subject() {
  local dest="$1/web/$EXT_DIR/custom/$NAME"
  rm -rf "$dest"; mkdir -p "$dest"
  ( cd "$SUBJECT_PHYS" && tar -cf - --exclude=.git --exclude=vendor --exclude=node_modules . ) | ( cd "$dest" && tar -xf - )
}

# write_neon <file> <paths entry> <tmpDir> -> uniform PHPStan config, identical
# on every leg so a difference between legs is a core difference.
EXCLUDE_TESTS=0
write_neon() {
  {
    printf '# drupilot — core matrix PHPStan config (generated by verify-core-matrix.sh; safe to delete)\n'
    printf 'parameters:\n  level: %s\n  paths:\n    - %s\n' "$LEVEL" "$2"
    printf '  excludePaths:\n    - */vendor/*\n    - */node_modules/*\n'
    [[ "$EXCLUDE_TESTS" == 1 ]] && printf '    - */tests/*\n'
    printf '  tmpDir: %s\n' "$3"
  } > "$1"
}

# run_phpstan <container dir> <config rel to dir> <subject container prefix> <out json>
# -> writes {status, findings:[{file,line,identifier,message}]} to <out json>.
run_phpstan() {
  local dir="$1" cfg="$2" prefix="$3" out="$4" raw="$TMP/phpstan-raw.json" err="$TMP/phpstan-err.txt" rc=0 status json
  set +e
  ( cd "$ROOT" && ddev exec -d "$dir" "vendor/bin/phpstan analyse --no-progress --error-format=json --memory-limit=2G -c $cfg" </dev/null ) >"$raw" 2>"$err"
  rc=$?
  set -e
  json="$(sed -n '/^{/,$p' "$raw")"
  if [[ -n "$json" ]] && printf '%s' "$json" | jq -e 'type == "object" and has("totals")' >/dev/null 2>&1; then
    if printf '%s' "$json" | jq -e '[.errors[]? | select(type == "string" and test("Internal error"; "i"))] | length > 0' >/dev/null 2>&1; then status="crashed"
    elif [[ "$rc" -eq 0 ]]; then status="clean"
    elif [[ "$rc" -eq 1 ]]; then status="findings"
    else status="crashed"; fi
  else
    status="crashed"
  fi
  if [[ "$status" == "crashed" ]]; then
    jq -nc --arg r "$(sed -e $'s/\x1b\\[[0-9;]*m//g' "$err" | grep -vE 'Failed to execute command' | grep -v '^[[:space:]]*$' | tail -n 5 | tr '\n' ' ' | cut -c1-400)" \
      '{status: "crashed", reason: $r, findings: []}' > "$out"
    return 0
  fi
  printf '%s' "$json" | jq -c --arg p "$prefix/" --arg st "$status" '
    {status: $st, findings: [ (.files // {}) | to_entries[] | .key as $f | .value.messages[]? |
      {file: ($f | if startswith($p) then ltrimstr($p) else . end), line: (.line // 0),
       identifier: (.identifier // ""), message: (.message // "")} ]}' > "$out"
  return 0
}

# Lint helper (POSIX sh): prints "<file>\t<first error line>" per failing file.
cat > "$MATRIX_DIR/lint.sh" <<'LINT'
#!/bin/sh
# drupilot — php -l over a module tree (generated by verify-core-matrix.sh).
cd "${1:-.}" || exit 2
find . \( -name .git -o -name vendor -o -name node_modules \) -prune -o -type f \
  \( -name '*.php' -o -name '*.module' -o -name '*.inc' -o -name '*.install' \
     -o -name '*.theme' -o -name '*.profile' -o -name '*.engine' \) -print |
while IFS= read -r f; do
  out="$(php -l "$f" 2>&1)" || printf '%s\t%s\n' "${f#./}" "$(printf '%s\n' "$out" | grep -v '^Errors parsing' | grep -v '^[[:space:]]*$' | head -n 1)"
done
exit 0
LINT

lint_json() {  # lint_json <php> <via> <status> <tsv file>
  jq -Rn --arg php "$1" --arg via "$2" --arg st "$3" '
    [inputs | select(length > 0) | split("\t") | {file: .[0], error: (.[1] // "")}] as $f
    | {php: $php, via: $via, status: (if $st != "ran" then $st elif ($f | length) > 0 then "fail" else "pass" end),
       errors: ($f | length), files: $f}' < "$4"
}

# Container-PHP lint (shared by every leg: same PHP, same files).
log_step "php -l (PHP $CONTAINER_PHP, container) on $SUBJECT_REL"
: > "$TMP/lint-container.tsv"
if dexec "$CONTAINER_ROOT" "sh $CONTAINER_ROOT/.drupilot/core-matrix/lint.sh $CONTAINER_ROOT/$SUBJECT_REL" > "$TMP/lint-container.tsv" 2>/dev/null; then
  LINT_CONTAINER="$(lint_json "$CONTAINER_PHP" "ddev" "ran" "$TMP/lint-container.tsv")"
else
  : > "$TMP/empty.tsv"
  LINT_CONTAINER="$(lint_json "$CONTAINER_PHP" "ddev" "error" "$TMP/empty.tsv")"
fi

# lint_floor <php X.Y> -> lint JSON on that PHP via Docker. Called in a command
# substitution, so the per-PHP cache is a file, not a variable.
lint_floor() {
  local php="$1" image="php:$1-cli" cache="$TMP/lint-floor-$1.json"
  [[ -s "$cache" ]] && { cat "$cache"; return 0; }
  local res st="ran"
  : > "$TMP/lint-$php.tsv"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    log_info "Pulling $image for the PHP $php lint (once)."
    run_with_timeout 300 docker pull -q "$image" >/dev/null 2>&1 || st="skipped"
  fi
  if [[ "$st" == "ran" ]]; then
    cp "$MATRIX_DIR/lint.sh" "$TMP/.drupilot-lint.sh"
    # The tree is streamed in (no bind mount: nothing on the host is relabelled
    # or written).
    if ! ( cd "$SUBJECT_PHYS" && tar -cf - --exclude=.git --exclude=vendor --exclude=node_modules . -C "$TMP" .drupilot-lint.sh ) \
         | run_with_timeout 300 docker run --rm -i --network none "$image" \
             sh -c 'mkdir -p /s && cd /s && tar -xf - && sh ./.drupilot-lint.sh .' > "$TMP/lint-$php.tsv" 2>/dev/null; then
      st="error"
    fi
  fi
  res="$(lint_json "$php" "docker $image" "$st" "$TMP/lint-$php.tsv")"
  [[ "$st" == "skipped" ]] && res="$(printf '%s' "$res" | jq -c '. + {reason: "the PHP image could not be pulled (network unavailable?)"}')"
  printf '%s' "$res" > "$cache"
  printf '%s' "$res"
}

# Subject PHP floor from its composer.json require.php (empty when none).
SUBJECT_PHP_FLOOR=""
if [[ -f "$SUBJECT_ABS/composer.json" ]]; then
  SUBJECT_PHP_FLOOR="$(core_floor_from_requirement "$(jq -r '.require.php // empty' "$SUBJECT_ABS/composer.json" 2>/dev/null || true)")"
fi

# --- Prepare the legs ---------------------------------------------------------
# Per-leg state kept in parallel indexed arrays (bash 3.2).
declare -a L_SRC=() L_VER=() L_DIR=() L_PREFIX=() L_STATUS=() L_REASON=() L_CFG=() L_CORE_DIR=()
i=0
for l in "${LEGS[@]}"; do
  if leg_on_testbed "$l"; then
    L_SRC[i]="testbed"; L_VER[i]="$TESTBED_VERSION"; L_DIR[i]="$CONTAINER_ROOT"
    L_PREFIX[i]="$CONTAINER_ROOT/$SUBJECT_REL"; L_CFG[i]=".drupilot/core-matrix/phpstan-$l.neon"
    L_CORE_DIR[i]="$ROOT"; L_STATUS[i]=""; L_REASON[i]=""
  else
    L_SRC[i]="reference"; L_CFG[i]="phpstan-drupilot.neon"
    L_DIR[i]="$CONTAINER_ROOT/$CORES_REL/drupal-$l"
    L_PREFIX[i]="$CONTAINER_ROOT/$CORES_REL/drupal-$l/web/$EXT_DIR/custom/$NAME"
    L_CORE_DIR[i]="$CORES_DIR/drupal-$l"; L_STATUS[i]=""; L_REASON[i]=""; L_VER[i]=""
    REF_VERSION=""; BUILD_REASON=""
    if ensure_reference "$l"; then
      L_VER[i]="$REF_VERSION"
      [[ "$(jq -r '.test_deps // false' "$CORES_DIR/drupal-$l/.drupilot-core.json" 2>/dev/null)" == "true" ]] || EXCLUDE_TESTS=1
    else
      L_STATUS[i]="skipped"; L_REASON[i]="$BUILD_REASON"
      log_warn "Drupal $l leg skipped: $BUILD_REASON"
    fi
  fi
  i=$((i + 1))
done
if [[ "$EXCLUDE_TESTS" == 1 ]]; then
  add_note "The subject's tests/ were left out of every leg: a reference core lacks the test runtime (drupal/core-dev's PHPUnit), so test classes could not resolve there."
fi

# --- Run PHPStan on each leg ----------------------------------------------------
i=0
for l in "${LEGS[@]}"; do
  out="$TMP/leg-$i.json"
  if [[ "${L_STATUS[i]}" == "skipped" ]]; then
    printf '{"status":"skipped","findings":[]}' > "$out"
  else
    if [[ "${L_SRC[i]}" == "testbed" ]]; then
      write_neon "$ROOT/${L_CFG[i]}" "../../$SUBJECT_REL" "cache-$l"
    else
      copy_subject "${L_CORE_DIR[i]}"
      write_neon "${L_CORE_DIR[i]}/${L_CFG[i]}" "web/$EXT_DIR/custom/$NAME" ".phpstan-cache"
    fi
    log_step "PHPStan level $LEVEL on Drupal ${L_VER[i]} (${L_SRC[i]} leg $l)"
    run_phpstan "${L_DIR[i]}" "${L_CFG[i]}" "${L_PREFIX[i]}" "$out"
    if [[ "$(jq -r .status "$out")" == "crashed" ]]; then
      L_STATUS[i]="error"; L_REASON[i]="PHPStan could not analyse the subject on Drupal ${L_VER[i]}: $(jq -r '.reason // ""' "$out")"
      log_err "${L_REASON[i]}"
    fi
  fi
  i=$((i + 1))
done

# --- Classify and judge ----------------------------------------------------------
# Baseline index.
BI=0; i=0
for l in "${LEGS[@]}"; do [[ "$l" == "$BASELINE" ]] && BI=$i; i=$((i + 1)); done

# key/kind classification in jq (shared program).
# shellcheck disable=SC2016  # jq program, not shell expansions.
CLASSIFY='
  def key: "\(.file)|\(.line)|\(.identifier)|\(.message)";
  def is_depr: ((.identifier | test("deprecat"; "i")) or (.message | test("\\bdeprecated\\b"; "i")));
  def is_test: (.file | test("(^|/)tests/"));
  # Runtime-tolerated (see the header): more arguments than the callee accepts
  # (PHP drops extra arguments to a userland callable), or the result of a void
  # call used (it evaluates to null; no error is raised).
  def too_many_args:
    (.identifier == "arguments.count")
    and ((.message | capture("invoked with (?<n>[0-9]+) parameters?, (?:[0-9]+-)?(?<m>[0-9]+) required")
          | (.n | tonumber) > (.m | tonumber)) // false);
  def void_used: (.identifier | test("^(method|staticMethod|function)\\.void$"));
  def tolerated: too_many_args or void_used;
  def missing_class:
    ([.message | capture("(?<c>Drupal\\\\[A-Za-z0-9_]+\\\\[A-Za-z0-9_\\\\]+)") | .c] | .[0]) as $c
    | if ($c != null) and (.message | test("Class [^ ]+ not found|unknown class|unknown interface|unknown trait|class [^ ]+ does not exist|invalid (return |parameter |property )?type|Reflection error"; "i"))
      then ($c | split("\\")) as $s
        | (if $s[1] == "Tests" and ($s | length) >= 4 then $s[2] else $s[1] end) as $m
        | if ($m == "" or ($m | test("^(Core|Component|Tests|KernelTests|FunctionalTests|FunctionalJavascriptTests|BuildTests|TestTools|TestSite)$"))
              or ($own | index($m)) != null or ($mods | index($m)) != null) then null else $m end
      else null end;
  ($other | map(key)) as $okeys
  | .findings | map(
      . as $f
      | (key) as $k
      | (if ($okeys | index($k)) != null then "shared"
         elif is_depr then "deprecation"
         elif (missing_class) != null then "sandbox_missing_dependency"
         elif ($adv | index($f.identifier)) != null then "advisory"
         elif tolerated then "tolerated"
         elif $ref and is_test then "test_only"
         else "incompatible" end) as $kind
      | $f + {kind: $kind})
'

# phpstan-drupal's own rule identifiers (best-practice rules such as
# drupal.proceduralHookEntityOperationMissingCacheabilityParameter): a leg-only
# finding from one of them is reported as "advisory", never as a core
# incompatibility — e.g. a one-parameter hook_entity_operation() still runs on
# 11.3+, where core passes an extra argument PHP ignores. Read from the installed
# extension, never hardcoded.
ADV_JSON="$(grep -rhoE "identifier\('[^']+'\)" "$ROOT/vendor/mglaman/phpstan-drupal/src" 2>/dev/null \
  | sed -E "s/^identifier\('//; s/'\)\$//" | LC_ALL=C sort -u | jq -R . | jq -sc 'map(select(length > 0))' 2>/dev/null || printf '[]')"
[[ -n "$ADV_JSON" ]] || ADV_JSON='[]'

# own module names: the subject + its submodules (any *.info.yml below it).
OWN_JSON="$(cd "$SUBJECT_PHYS" && find . \( -name .git -o -name vendor -o -name node_modules \) -prune -o -name '*.info.yml' -print 2>/dev/null \
  | sed -E 's|.*/||; s|\.info\.yml$||' | jq -R . | jq -sc 'map(select(length > 0))')"

# modules_in <core dir> -> JSON list of extension machine names present there.
modules_in() {
  local d="$1"
  { [[ -d "$d/web/core/modules" ]] && ls "$d/web/core/modules"
    [[ -d "$d/web/core/themes" ]] && ls "$d/web/core/themes"
    [[ -d "$d/web/modules/contrib" ]] && ls "$d/web/modules/contrib"
    [[ -d "$d/core/modules" ]] && ls "$d/core/modules"
    true; } 2>/dev/null | jq -R . | jq -sc 'map(select(length > 0))'
}

# leg_floor <i> -> the lowest PHP a site on that leg may run the subject on.
leg_floor() {
  local d="${L_CORE_DIR[$1]}" cj="" core_min="" f
  for cj in "$d/web/core/composer.json" "$d/core/composer.json"; do
    [[ -f "$cj" ]] && { core_min="$(core_floor_from_requirement "$(jq -r '.require.php // empty' "$cj" 2>/dev/null || true)")"; break; }
  done
  f="$core_min"
  if [[ -n "$SUBJECT_PHP_FLOOR" ]]; then
    if [[ -z "$f" ]] || version_ge "$SUBJECT_PHP_FLOOR" "$f"; then f="$SUBJECT_PHP_FLOOR"; fi
  fi
  printf '%s' "$f"
}

LEGS_JSON='[]'
BASE_FINDINGS="$(jq -c '.findings' "$TMP/leg-$BI.json")"
BASE_OK=1; [[ -n "${L_STATUS[BI]}" ]] && BASE_OK=0
REF_FINDINGS='[]'; REF_RAN=0
i=0
for l in "${LEGS[@]}"; do
  if [[ "$i" != "$BI" && -z "${L_STATUS[i]}" ]]; then
    REF_FINDINGS="$(printf '%s' "$REF_FINDINGS" | jq -c --slurpfile f "$TMP/leg-$i.json" '. + $f[0].findings')"
    REF_RAN=$((REF_RAN + 1))
  fi
  i=$((i + 1))
done
# With no reference leg to compare against (none declared, or all skipped), the
# baseline is reported, not judged: its findings are the validate loop's job.
if [[ "$REF_RAN" == 0 ]]; then
  REF_FINDINGS="$BASE_FINDINGS"
  add_note "No reference core leg ran, so the Drupal $TESTBED_VERSION baseline is reported but not judged (run-phpstan.sh owns its findings)."
fi

i=0
for l in "${LEGS[@]}"; do
  role="reference"; [[ "$i" == "$BI" ]] && role="baseline"
  status="${L_STATUS[i]}"; reason="${L_REASON[i]}"
  if [[ "$role" == "baseline" ]]; then other="$REF_FINDINGS"; else other="$BASE_FINDINGS"; fi
  MODS="$(modules_in "${L_CORE_DIR[i]}")"
  classified="$(jq -c --argjson other "$other" --argjson own "$OWN_JSON" --argjson mods "$MODS" --argjson adv "$ADV_JSON" \
    --argjson ref "$([[ "$role" == "reference" ]] && echo true || echo false)" "$CLASSIFY" "$TMP/leg-$i.json")"
  pstatus="$(jq -r .status "$TMP/leg-$i.json")"

  # Lint: the container PHP, plus the leg's lower PHP floor when it is lower.
  floor=""; lint="[$LINT_CONTAINER]"
  if [[ "$status" != "skipped" ]]; then
    floor="$(leg_floor "$i")"
    if [[ "$LINT_FLOOR" == "auto" && -n "$floor" && -n "$CONTAINER_PHP" ]] && ! version_ge "$floor" "$CONTAINER_PHP"; then
      if have_cmd docker; then
        lint="$(printf '%s' "$lint" | jq -c --argjson f "$(lint_floor "$floor")" '. + [$f]')"
      else
        lint="$(printf '%s' "$lint" | jq -c --arg p "$floor" '. + [{php: $p, via: "docker", status: "skipped", errors: 0, files: [], reason: "docker not available"}]')"
      fi
    fi
  fi

  if [[ -z "$status" ]]; then
    incompat="$(printf '%s' "$classified" | jq '[.[] | select(.kind == "incompatible")] | length')"
    lint_fail="$(printf '%s' "$lint" | jq '[.[] | select(.status == "fail")] | length')"
    if [[ "$lint_fail" -gt 0 ]]; then
      status="fail"; reason="php -l failed on $(printf '%s' "$lint" | jq -r '[.[] | select(.status == "fail") | "PHP " + .php] | join(", ")')"
    elif [[ "$role" == "reference" && "$BASE_OK" == 0 ]]; then
      # Without a baseline every finding looks leg-only, so none can be judged
      # an incompatibility (checked BEFORE the incompatible count): only a leg
      # with no finding at all (deprecations aside) counts as passing.
      if [[ "$(printf '%s' "$classified" | jq '[.[] | select(.kind != "deprecation")] | length')" -gt 0 ]]; then
        status="skipped"; reason="the Drupal $TESTBED_VERSION baseline produced no verdict (${L_REASON[BI]:-it did not run}), so this leg's findings cannot be told apart from pre-existing ones"
      else
        status="pass"
      fi
    elif [[ "$incompat" -gt 0 ]]; then
      status="fail"
      if [[ "$role" == "baseline" ]]; then
        reason="$incompat PHPStan error(s) only on this core, absent from the other legs"
      else
        reason="$incompat PHPStan error(s) only on Drupal ${L_VER[i]}, absent from the Drupal $TESTBED_VERSION baseline"
      fi
    else
      status="pass"
    fi
  fi
  LEGS_JSON="$(printf '%s' "$LEGS_JSON" | jq -c \
    --arg core "$l" --arg role "$role" --arg src "${L_SRC[i]}" \
    --arg constraint "$([[ "${L_SRC[i]}" == "reference" ]] && leg_constraint "$l")" \
    --arg version "${L_VER[i]}" --arg floor "$floor" --arg status "$status" --arg reason "$reason" \
    --arg pstatus "$pstatus" --argjson f "$classified" --argjson lint "$lint" \
    '. + [{core: $core, role: $role, source: $src,
           constraint: ($constraint | select(. != "") // null), version: ($version | select(. != "") // null),
           php_floor: ($floor | select(. != "") // null), status: $status, reason: ($reason | select(. != "") // null),
           phpstan: {status: $pstatus, errors: ($f | length),
                     leg_only: ([$f[] | select(.kind != "shared")] | length),
                     incompatible: ([$f[] | select(.kind == "incompatible")] | length),
                     deprecations: ([$f[] | select(.kind == "deprecation")] | length),
                     sandbox_missing_dependency: ([$f[] | select(.kind == "sandbox_missing_dependency")] | length),
                     test_only: ([$f[] | select(.kind == "test_only")] | length),
                     advisory: ([$f[] | select(.kind == "advisory")] | length),
                     tolerated: ([$f[] | select(.kind == "tolerated")] | length),
                     findings: ([$f[] | select(.kind != "shared")] | .[0:50])},
           lint: $lint}]')"
  i=$((i + 1))
done

# --- Verdicts ---------------------------------------------------------------------
D10_SUPPORT="$(printf '%s' "$LEGS_JSON" | jq -r '
  [.[] | select(.core | test("^10(\\.|$)"))] as $d
  | if ($d | length) == 0 then "n/a"
    elif any($d[]; .status == "fail") then "failed"
    elif all($d[]; .status == "pass") then "verified-static"
    else "declared-not-verified" end')"
# A Drupal 10 leg that only exists as the test-bed baseline is not a declared
# leg: the declared requirement decides.
if [[ "$D10_SUPPORT" == "n/a" ]] && printf '%s' "$CORE_REQ" | grep -qE '(^|[^0-9])10([^0-9.]|\.|$)'; then
  D10_SUPPORT="declared-not-verified"
fi
# The declared Drupal 10 FLOOR (^10 -> 10.0, ^10.3 -> 10.3). A '^10' leg
# resolves to the NEWEST 10.x, so a clean leg does not prove the floor: an API
# added in 10.1-10.x passes there and still fatals on 10.0. verified-static is
# kept for a run that checked the floor minor itself; otherwise the verdict is
# verified-static-above-floor and names what was (not) checked.
D10_FLOOR="$(core_verify_legs "$CORE_REQ" | awk -F. '$1 == "10" { print ($2 == "" ? "10.0" : $0); exit }')"
D10_CHECKED="$(printf '%s' "$LEGS_JSON" | jq -c '[.[] | select(.core | test("^10(\\.|$)")) | select(.status == "pass") | (.version // .core)]')"
D10_FLOOR_CHECKED="null"
if [[ -n "$D10_FLOOR" ]]; then
  D10_FLOOR_CHECKED="$(printf '%s' "$D10_CHECKED" | jq --arg f "$D10_FLOOR" \
    'any(.[]; (split(".") | .[0:2] | join(".")) == $f)')"
fi
if [[ "$D10_SUPPORT" == "verified-static" && "$D10_FLOOR_CHECKED" == "false" ]]; then
  D10_SUPPORT="verified-static-above-floor"
fi
VERDICT="$(printf '%s' "$LEGS_JSON" | jq -r '
  if any(.[]; .status == "fail") then "fail"
  elif all(.[]; .status == "pass") then "pass"
  else "not-verified" end')"

DIGEST="$(subject_digest "$SUBJECT_ABS")"

OUT="$(jq -n --arg s "$SUBJECT_ABS" --arg n "$NAME" --arg r "$ROOT" --arg req "$CORE_REQ" \
  --arg lvl "$LEVEL" --arg php "$CONTAINER_PHP" --arg dg "$DIGEST" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson legs "$LEGS_JSON" \
  --arg d10 "$D10_SUPPORT" --arg v "$VERDICT" --argjson notes "$NOTES_JSON" \
  --arg d10f "$D10_FLOOR" --argjson d10c "$D10_CHECKED" --argjson d10fc "$D10_FLOOR_CHECKED" \
  --argjson tests "$([[ "$EXCLUDE_TESTS" == 1 ]] && echo false || echo true)" \
  '{tool: "verify-core-matrix", subject: $s, machine_name: $n, drupal_root: $r,
    core_version_requirement: ($req | select(. != "") // null), level: $lvl,
    container_php: $php, subject_digest: $dg, generated_at: $at, dry_run: false,
    legs: $legs, d10_support: $d10,
    d10_floor: ($d10f | select(. != "") // null), d10_checked: $d10c, d10_floor_checked: $d10fc,
    verdict: $v, tests_analysed: $tests, notes: $notes}')"
printf '%s\n' "$OUT" > "$STATE_FILE" 2>/dev/null || log_warn "Could not persist $STATE_FILE."

# --- Human summary (STDERR) -------------------------------------------------------
hr
log_step "Core matrix — $NAME (${CORE_REQ:-no requirement}), PHPStan level $LEVEL"
printf '%s' "$OUT" | jq -r '.legs[] |
  "  Drupal \(.version // .core) [\(.role)] — \(.status | ascii_upcase)"
  + (if .reason then ": \(.reason)" else "" end)
  + "\n    PHPStan: \(.phpstan.errors) error(s), \(.phpstan.incompatible) incompatible, \(.phpstan.deprecations) deprecation(s) only here, \(.phpstan.sandbox_missing_dependency) missing-dependency (sandbox), \(.phpstan.test_only // 0) in tests only, \(.phpstan.advisory // 0) advisory, \(.phpstan.tolerated // 0) runtime-tolerated (reported)"
  + "\n    php -l : " + ([.lint[] | "PHP \(.php) \(.status)" + (if .errors > 0 then " (\(.errors) file(s))" else "" end)] | join(", "))
  + ([.phpstan.findings[] | select(.kind == "incompatible") | "\n      ✗ \(.file):\(.line) \(.message | split("\n")[0])"] | .[0:10] | join(""))
  + ([.phpstan.findings[] | select(.kind == "tolerated") | "\n      ~ \(.file):\(.line) \(.message | split("\n")[0]) (runtime-tolerated; review)"] | .[0:5] | join(""))
  + ([.lint[] | .php as $p | .files[]? | "\n      ✗ php -l (PHP \($p)) \(.file): \(.error)"] | .[0:10] | join(""))' >&2
if [[ "$D10_SUPPORT" == "verified-static-above-floor" ]]; then
  log_plain "  Drupal 10 support: $D10_SUPPORT (clean on $(printf '%s' "$D10_CHECKED" | jq -r 'join(", ")'); the declared floor $D10_FLOOR was NOT checked: an API newer than $D10_FLOOR would still fatal there)"
else
  log_plain "  Drupal 10 support: $D10_SUPPORT"
fi
case "$VERDICT" in
  pass) log_ok "Every core leg passed (static: PHPStan + php -l; runtime not exercised).";;
  fail) log_err "At least one core leg FAILED: the declared core range is not met. Fix the code the core-safe way, raise the floor, or drop the failing major.";;
  *)    log_warn "The matrix is not fully verified (a leg was skipped); the declared support stays declared-not-verified.";;
esac

[[ "$AS_JSON" == 1 ]] && printf '%s\n' "$OUT"
[[ "$VERDICT" == "fail" ]] && exit 3
exit 0
