#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/check-port-safety.sh
# Deterministic post-port safety checks for a module/theme. They catch the
# breakages that ports (Rector, the digests layer, or an agent "fixing" the
# sandbox PHPStan) have introduced in real projects and that no analyzer in the
# validate loop reports. Read-only, ungated, no toolchain needed (bash + awk +
# jq; git for the diff-aware part). Data lives in config/port-checks.json.
#
# Checks (--checks selects a subset; default all):
#   plugin-di          A class with static create(ContainerInterface ...) that
#                      does not implement the matching interface, itself or
#                      through an ancestor: ContainerFactoryPluginInterface
#                      (create($container, array $configuration, ...)),
#                      ContainerDeriverInterface (create($container,
#                      $base_plugin_id)) or ContainerInjectionInterface
#                      (create($container), other parameters optional). The ancestry is READ from
#                      the Drupal root (core + contrib + the subject), so it is
#                      right for the core version installed; a small verified
#                      fallback list covers a missing root. QueueWorkerBase,
#                      BlockBase, FilterBase, ActionBase, ConditionPluginBase and
#                      core PluginBase do NOT implement it.
#   removed-use        A `use` import the port removed while the short name is
#                      still referenced in the file (diff mode only).
#   static-factory     `new self(` inside create() of a non-final class (e.g. a
#                      `new static` -> `new self` edit to silence PHPStan).
#   fapi-callable      A first-class callable `$this->m(...)` or a closure under
#                      a Form/Render API callback key (#ajax 'callback',
#                      #submit, #validate, #element_validate, #process,
#                      #pre_render, #after_build, #value_callback,
#                      #lazy_builder, ...): closures are not serializable.
#   serialization      private/readonly properties (declared or promoted) in a
#                      class using DependencySerializationTrait (forms,
#                      plugins): dropped by __sleep() / not re-initializable by
#                      __wakeup().
#   override-attribute #[\Override] while the declared core range still
#                      includes Drupal 10 (an error when the port added it;
#                      a review warning when it cannot be attributed).
#   class-case         services.yml / routing.yml class references and PSR-4
#                      class names whose case differs from the real file.
#   test-label-markup  In a file under tests/, a translated string object
#                      ($this->t(...)) as a submitForm() label (its second
#                      argument) or a buttonExists() locator while the
#                      declared range admits a core from the check's
#                      strict_from (10.2.3, where core's WebAssert declares
#                      strict_types) to before its cast_from (10.3.0, where
#                      it casts the label), or as a buttonNotExists()
#                      locator while it admits a core from strict_from to
#                      before not_exists_typed_from (12.0.0, where its
#                      parameter is typed string and PHP converts the
#                      label): Mink's findButton(string) gets it, a
#                      TypeError (lab L-1.0-D9 on 10.2.12). In diff mode, a
#                      line the port left alone is attributed to the port
#                      when the range at the base admitted no such core.
#   test-phpunit-metadata
#                      In a file under tests/, a class or a method with a
#                      PHPUnit attribute (#[RunTestsInSeparateProcesses],
#                      #[Group], ...) whose doc-comment still carries PHPUnit
#                      metadata with no attribute twin (@group, @covers,
#                      @dataProvider, ...), while the declared range admits
#                      a core whose PHPUnit reads attributes (the check's
#                      attributes_from, 11.0): PHPUnit 10+ then reads only
#                      that level's attributes, so the test loses its
#                      @group (it falls into the group "default") and a
#                      method's relative @covers ::name becomes invalid
#                      without the ignored @coversDefaultClass (lab L-PC).
#                      PHPUnit 9 (Drupal 10) reads the annotations only:
#                      keep them and add the twins. In diff mode, a line
#                      the port left alone is attributed to the port when
#                      the range at the base admitted no such core.
#   test-phpunit-api   In a file under tests/, a call of a PHPUnit method that
#                      exists only from the check's phpunit_from (10, Drupal
#                      11.0) while the declared range admits an older
#                      Drupal major: $matcher->numberOfInvocations(), which
#                      Rector's WithConsecutiveRector writes, is
#                      getInvocationCount() on PHPUnit 9 (training run 01).
#   test-abstract-suffix
#                      An abstract class in a tests/ file named *Test.php while
#                      the range admits Drupal 11.0+ (PHPUnit 10+ throws 'Class
#                      X is abstract': failOnWarning fails the run; training
#                      run module 08). Name it *TestBase.
#   test-field-ui-display-path
#                      A tests/ path ending in /display given to drupalGet()
#                      or a Url while the range admits the check's
#                      overview_from (11.4.0): Field UI serves an overview
#                      there; the default form is .../display/default on
#                      every core (training run modules 05 and 08).
#   config-schema-sequence
#                      In config/schema/*.yml (test modules included), a
#                      `sequence:` whose item type is a one-item YAML list
#                      (`- type: string`), a form core removed from the
#                      check's removed_in (11.0.0): the items then have no
#                      type and saving the configuration throws
#                      SchemaIncompleteException (training run 01, filelog).
#                      On when the declared range or the target major admits
#                      that major. Always an error: write the item
#                      definition as a mapping (drop the '- ').
#   migrate-dependencies-expand
#                      In src/, a ->getMigrationDependencies() call in a
#                      migrate field plugin (src/Plugin/migrate/field/) or a
#                      deriver (*Deriver*.php), while the range or the target
#                      admits the check's expands_from (11.0.0): from there
#                      the call always expands the plugin IDs, which reads
#                      the migration definitions that are being built and
#                      can recurse endlessly (training run module 12,
#                      location_migration). A warning: read the unexpanded
#                      getPluginDefinition()['migration_dependencies'].
#   event-dispatch-order
#                      A ->dispatch() call whose first argument is an event
#                      name (a class constant such as Events::NAME, or a string
#                      literal), the Symfony 4.2 order, while the range or the
#                      target admits the check's removed_in (10.0.0, Symfony
#                      6): dispatch(object $event, ?string $eventName) then
#                      throws a TypeError (training run module 13, log_entity:
#                      its login hooks). An error: swap the two arguments.
#
# Diff-aware: when the subject is tracked by git, every finding is attributed —
# "introduced" (on a line the port added/changed vs the pre-port base) or
# "pre-existing" — and the severity comes from the per-check matrix in
# config/port-checks.json (e.g. a readonly property the port added is an error,
# one that was already there a warning). The base is the same one make-patch.sh
# --local uses (git_port_base_ref: the fork point — upstream, else the closest
# merge-base among the remote branches and the nearest tag, else HEAD), or
# --base REF. Untracked files count as added. Without git (or with --no-diff)
# "introduced" is null and the "unknown" severity applies.
#
# Usage:
#   check-port-safety.sh --subject DIR [--base REF] [--no-diff]
#                        [--checks LIST] [--drupal-root DIR] [--core-req STR]
#                        [--json] [-h|--help]
#
# Options:
#   --subject DIR      The module/theme directory. Required.
#   --base REF         Git ref holding the PRE-port code (default: as above).
#   --no-diff          Do not look at git; every finding is "unknown".
#   --checks LIST      Comma-separated subset of the checks above.
#   --drupal-root DIR  Drupal root whose core/contrib classes resolve ancestors
#                      (default: found by walking up from the subject).
#   --core-req STR     Core constraint to judge override-attribute against
#                      (default: the subject's core_version_requirement).
#   --json             Print a JSON report on STDOUT instead of tagged lines:
#                      {tool, subject, drupal_root, base, diff_mode,
#                       core_requirement, checks, ok, errors, warnings,
#                       findings:[{check, severity, file, line, introduced,
#                                  message}]}
#   -h, --help         Show this help.
#
# Output: without --json, one line per finding on STDOUT:
#   [check-id] severity file:line message
# (the same shape explain-deprecations.sh annotates when teed into a log).
# Logs and the summary go to STDERR.
#
# Exit codes: 0 no error findings (warnings allowed) · 1 usage error ·
# 3 at least one error finding (the port/refactor stage is NOT done).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/php-scan.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/php-scan.sh"

ALL_CHECKS="plugin-di removed-use static-factory fapi-callable serialization override-attribute class-case test-label-markup test-phpunit-metadata test-phpunit-api test-abstract-suffix test-field-ui-display-path config-schema-sequence migrate-dependencies-expand event-dispatch-order"
SUBJECT=""
BASE=""
NO_DIFF=0
CHECKS=""
ROOT_OPT=""
CORE_REQ=""
AS_JSON=0

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --base) BASE="${2:-}"; shift 2;;
    --base=*) BASE="${1#*=}"; shift;;
    --no-diff) NO_DIFF=1; shift;;
    --checks) CHECKS="${2:-}"; shift 2;;
    --checks=*) CHECKS="${1#*=}"; shift;;
    --drupal-root) ROOT_OPT="${2:-}"; shift 2;;
    --drupal-root=*) ROOT_OPT="${1#*=}"; shift;;
    --core-req) CORE_REQ="${2:-}"; shift 2;;
    --core-req=*) CORE_REQ="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_err "Unknown argument: $1"; usage >&2; exit 1;;
  esac
done

[[ -n "$SUBJECT" ]] || die "Missing --subject DIR (the module/theme to check)." 1
case "$SUBJECT" in *"<"*">"*) die "--subject looks like an unsubstituted placeholder: '$SUBJECT'." 1;; esac
# Two spellings of the subject: the logical path (may end in a symlink, e.g. a
# DRUPILOT_PLACEMENT=symlink test-bed) locates the Drupal root it sits in; the
# physical path is what gets scanned. `find` does not descend into a symlinked
# starting point, and git reports the physical toplevel, so scanning, rel()
# and the git pathspecs must all use the physical spelling.
SUBJECT_LOGICAL="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
[[ -n "$SUBJECT_LOGICAL" && -d "$SUBJECT_LOGICAL" ]] || die "Subject directory not found: '$SUBJECT'." 1
SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd -P || true)"
[[ -n "$SUBJECT_ABS" ]] || SUBJECT_ABS="$SUBJECT_LOGICAL"
have_cmd jq || die "jq is required for check-port-safety.sh." 1
CFG="$(plugin_root)/config/port-checks.json"
[[ -f "$CFG" ]] || die "Missing $CFG." 1

if [[ -z "$CHECKS" ]]; then
  CHECKS="$ALL_CHECKS"
else
  CHECKS="$(printf '%s' "$CHECKS" | tr ',' ' ')"
  for c in $CHECKS; do
    case " $ALL_CHECKS " in *" $c "*) ;; *) die "Unknown check '$c'. Valid: ${ALL_CHECKS// /,}" 1;; esac
  done
fi
check_on() { case " $CHECKS " in *" $1 "*) return 0;; esac; return 1; }

# --- Drupal root / docroot (for ancestor resolution) ------------------------
if [[ -n "$ROOT_OPT" ]]; then
  DRUPAL_ROOT="$(cd "$ROOT_OPT" 2>/dev/null && pwd || true)"
  [[ -n "$DRUPAL_ROOT" ]] || die "--drupal-root not found: '$ROOT_OPT'." 1
else
  DRUPAL_ROOT="$(find_drupal_root "$SUBJECT_LOGICAL" 2>/dev/null || true)"
  [[ -n "$DRUPAL_ROOT" ]] || DRUPAL_ROOT="$(find_drupal_root "$SUBJECT_ABS" 2>/dev/null || true)"
fi
DOCROOT=""
if [[ -n "$DRUPAL_ROOT" ]]; then
  for d in "$DRUPAL_ROOT/web" "$DRUPAL_ROOT/docroot" "$DRUPAL_ROOT"; do
    if [[ -d "$d/core/lib/Drupal" ]]; then DOCROOT="$d"; break; fi
  done
fi

if [[ -z "$CORE_REQ" ]]; then CORE_REQ="$(subject_core_requirement "$SUBJECT_ABS" 2>/dev/null || true)"; fi
CORE_REQ="$(printf '%s' "$CORE_REQ" | tr -d "\"'")"
# The declared range reaches below Drupal 11 when it names an 8/9/10 major.
SPANS_D10=0
if printf '%s' "$CORE_REQ" | grep_q -E '(^|[^0-9.])(8|9|10)(\.|[^0-9]|$)'; then SPANS_D10=1; fi
CORE_FLOOR="$(core_floor_from_requirement "$CORE_REQ")"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-portsafety.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/scan" "$TMP/ext" "$TMP/memo" "$TMP/diff"
: > "$TMP/findings.tsv"

# --- Config: severity matrix + fallback ancestry ----------------------------
jq -r '.checks | to_entries[] | [.key, .value.severity.introduced, .value.severity.preexisting, .value.severity.unknown] | @tsv' "$CFG" > "$TMP/severity.tsv"
jq -r '.fallback | to_entries[] | .key as $t | ((.value.yes // [])[] | [$t, "yes", .]), ((.value.no // [])[] | [$t, "no", .]) | join("\t")' "$CFG" > "$TMP/fallback.tsv"
IF_PLUGIN="$(jq -r '.interfaces.plugin_factory' "$CFG")"
IF_INJECT="$(jq -r '.interfaces.container_injection' "$CFG")"
IF_DERIVER="$(jq -r '.interfaces.container_deriver' "$CFG")"
TR_SERIAL="$(jq -r '.interfaces.serialization_trait' "$CFG")"
# test-label-markup (config/port-checks.json): from strict_from, core's
# WebAssert declares strict_types, so a translated label it passes on to
# Mink's findButton(string) is a TypeError; from cast_from, buttonExists()
# (which submitForm() calls) casts it first; buttonNotExists() never does,
# but from not_exists_typed_from it declares string $button, so PHP converts
# the label of a test without strict_types.
LABEL_STRICT="$(jq -r '.checks["test-label-markup"].strict_from // empty' "$CFG")"
LABEL_CAST="$(jq -r '.checks["test-label-markup"].cast_from // empty' "$CFG")"
LABEL_TYPED="$(jq -r '.checks["test-label-markup"].not_exists_typed_from // empty' "$CFG")"
# label_window REQ -> "CAST STRICT": 1 when REQ admits a core of the minors
# from strict_from's up to before cast_from's (a translated submitForm() /
# buttonExists() label fails there), and 1 when it admits one from
# strict_from's minor up to before not_exists_typed_from's (a translated
# buttonNotExists() locator fails there), read on the minors of the version
# data; 0 0 for no requirement.
label_window() {
  local req="${1:-}" sm cm tm m v win="" all="" c=0 st=0
  [[ -n "$req" && "$LABEL_STRICT" =~ ^([0-9]+)\.([0-9]+) ]] || { printf '0 0'; return 0; }
  sm="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"; cm="$(printf '%s' "$LABEL_CAST" | cut -d. -f1-2)"
  tm="$(printf '%s' "$LABEL_TYPED" | cut -d. -f1-2)"
  for m in $(seq "${sm%%.*}" "$(( ${sm%%.*} + 3 ))"); do
    for v in $(target_get "$m" '.minors | keys[]' 2> /dev/null); do
      version_ge "$v" "$sm" || continue
      if [[ -z "$tm" ]] || ! version_ge "$v" "$tm"; then all="$all$v"$'\n'; fi
      if [[ -z "$cm" ]] || ! version_ge "$v" "$cm"; then win="$win$v"$'\n'; fi
    done
  done
  [[ -n "$win" && -n "$(printf '%s' "$win" | core_requirement_minors "$req")" ]] && c=1
  [[ -n "$all" && -n "$(printf '%s' "$all" | core_requirement_minors "$req")" ]] && st=1
  printf '%s %s' "$c" "$st"
  return 0
}
read -r LABEL_CASTFAIL LABEL_STRICTFAIL <<EOF
$(label_window "$CORE_REQ")
EOF
# test-phpunit-metadata (config/port-checks.json): from attributes_from, core
# runs a PHPUnit that reads attributes (10, then 11), and an attribute on a
# class or a method hides that level's doc-comment metadata; below it core
# runs PHPUnit 9, which reads the annotations only. On when the range admits
# a major from attributes_from's; the annotations stay needed while it also
# admits a lower one.
PUMETA_FROM="$(jq -r '.checks["test-phpunit-metadata"].attributes_from // empty' "$CFG")"
PUMETA_PHPUNIT="$(jq -r '.checks["test-phpunit-metadata"].phpunit_from // empty' "$CFG")"
PUMETA_PREV=""; [[ "$PUMETA_FROM" =~ ^([0-9]+) ]] && PUMETA_PREV="$((BASH_REMATCH[1] - 1))"
# pumeta_on REQ -> 1 when REQ admits a major from attributes_from's on.
pumeta_on() {
  local req="${1:-}" m on=0
  if [[ -n "$req" && -n "$PUMETA_PREV" ]]; then
    for m in $(seq "$((PUMETA_PREV + 1))" "$((PUMETA_PREV + 4))"); do constraint_admits_major "$req" "$m" && on=1; done
  fi
  printf '%s' "$on"
  return 0
}
PUMETA_ON="$(pumeta_on "$CORE_REQ")"; PUMETA_KEEP=0
if [[ -n "$CORE_REQ" && -n "$PUMETA_PREV" ]]; then
  for _m in $(seq "$((PUMETA_PREV - 2))" "$PUMETA_PREV"); do constraint_admits_major "$CORE_REQ" "$_m" && PUMETA_KEEP=1; done
fi
FAPI_KEYS="$(jq -r '.fapi_callback_keys | join(" ")' "$CFG")"
# Methods core added in a known minor (config/deprecations.json
# .signature_changes, kind method-signature) and their verified ancestry, so an
# #[\Override] on one of them is judged against the declared core floor.
SIGCAT="$(plugin_root)/config/deprecations.json"
: > "$TMP/sigmethods.tsv"
if [[ -f "$SIGCAT" ]]; then
  jq -r '(.signature_changes // [])[] | select(.kind == "method-signature") | [.id, .target, .method, .since] | join("\t")' "$SIGCAT" > "$TMP/sigmethods.tsv" 2>/dev/null || true
  jq -r '(.signature_changes // [])[] | select(.kind == "method-signature") | .target as $t | (.known_descendants // [])[] | [$t, "yes", .] | join("\t")' "$SIGCAT" >> "$TMP/fallback.tsv" 2>/dev/null || true
fi

# test-phpunit-api (config/port-checks.json): PHPUnit methods that exist only
# from phpunit_from (Drupal drupal_from), while the range admits an older
# Drupal major whose PHPUnit has another name for them (members).
PUAPI_FROM="$(jq -r '.checks["test-phpunit-api"].drupal_from // empty' "$CFG")"
PUAPI_PHPUNIT="$(jq -r '.checks["test-phpunit-api"].phpunit_from // empty' "$CFG")"
PUAPI_ERE="$(jq -r '(.checks["test-phpunit-api"].members // {}) | keys | join("|")' "$CFG")"
PUAPI_ON=0
if [[ -n "$CORE_REQ" && -n "$PUAPI_ERE" && "$PUAPI_FROM" =~ ^([0-9]+) ]]; then
  _pm="${BASH_REMATCH[1]}"
  for _m in $(seq "$((_pm - 3))" "$((_pm - 1))"); do constraint_admits_major "$CORE_REQ" "$_m" && PUAPI_ON=1; done
fi

# test-abstract-suffix / test-field-ui-display-path (config/port-checks.json).
TABS_FROM="$(jq -r '.checks["test-abstract-suffix"].drupal_from // empty' "$CFG")"
TABS_PHPUNIT="$(jq -r '.checks["test-abstract-suffix"].phpunit_from // empty' "$CFG")"
TABS_ON=0
if [[ "$TABS_FROM" =~ ^([0-9]+) ]]; then
  _am="${BASH_REMATCH[1]}"
  if [[ -z "$CORE_REQ" ]]; then TABS_ON=1
  else for _m in $(seq "$_am" "$((_am + 3))"); do constraint_admits_major "$CORE_REQ" "$_m" && TABS_ON=1; done; fi
fi
FUID_FROM="$(jq -r '.checks["test-field-ui-display-path"].overview_from // empty' "$CFG")"
FUID_ON=0
if [[ -n "$FUID_FROM" ]]; then
  if [[ -z "$CORE_REQ" ]]; then FUID_ON=1
  # (A range that admits the major admits its later minors: ^11 reaches 11.4.)
  else _fm="${FUID_FROM%%.*}"; for _m in $(seq "$_fm" "$((_fm + 3))"); do constraint_admits_major "$CORE_REQ" "$_m" && FUID_ON=1; done
  fi
fi

# --- Git base (diff-aware attribution) ---------------------------------------
REPO=""; BASE_REF=""; DIFF_MODE=0
if [[ "$NO_DIFF" != "1" ]] && have_cmd git; then
  REPO="$(git -C "$SUBJECT_ABS" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$REPO" ]]; then
    if [[ -n "$BASE" ]]; then
      BASE_REF="$(git_port_base_ref "$REPO" "$BASE")" \
        || die "Base '$BASE' not found (tried origin/$BASE and $BASE)." 1
    else
      BASE_REF="$(git_port_base_ref "$REPO" "")"
    fi
    if git -C "$REPO" rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null 2>&1 \
       && [[ -n "$(git -C "$REPO" ls-tree -r --name-only "$BASE_REF" -- "$SUBJECT_ABS" 2>/dev/null | sed -n '1p')" ]]; then
      DIFF_MODE=1
    else
      log_warn "The subject is not in '$BASE_REF' of $REPO; findings cannot be attributed to the port (introduced: null)."
      BASE_REF=""
    fi
  fi
fi

# The range at the port's base, for test-label-markup: a label line the port
# left alone is still the port's when its range change made it fail.
BASE_CASTFAIL=""; BASE_STRICTFAIL=""; BASE_PUMETA_ON=""
if [[ "$DIFF_MODE" == "1" ]]; then
  _bmn="$(subject_machine_name "$SUBJECT_ABS" 2> /dev/null || basename "$SUBJECT_ABS")"
  if git -C "$SUBJECT_ABS" cat-file -e "$BASE_REF:./$_bmn.info.yml" 2> /dev/null; then
    _breq="$(git -C "$SUBJECT_ABS" show "$BASE_REF:./$_bmn.info.yml" 2> /dev/null \
      | sed -n 's/^core_version_requirement[[:space:]]*:[[:space:]]*//p' | sed -n '1p' | tr -d "'\"" \
      | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//' || true)"
    read -r BASE_CASTFAIL BASE_STRICTFAIL <<EOF
$(label_window "$_breq")
EOF
    BASE_PUMETA_ON="$(pumeta_on "$_breq")"
  fi
fi

# --- Helpers ----------------------------------------------------------------
rel() { local p="$1"; p="${p#"$SUBJECT_ABS"/}"; printf '%s' "$p"; }
key_of() { php_scan_key "$@"; }

# diff_info FILE -> prepares $TMP/diff/<key>.{added,removed}; prints the key.
# .added holds the added/changed line numbers (or "ALL" for an untracked file).
diff_info() {
  local f="$1" k; k="$(key_of "$f")"
  if [[ ! -f "$TMP/diff/$k.added" ]]; then
    : > "$TMP/diff/$k.added"; : > "$TMP/diff/$k.removed"
    if [[ "$DIFF_MODE" == "1" ]]; then
      if ! git -C "$REPO" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
        echo ALL > "$TMP/diff/$k.added"
      else
        git -C "$REPO" diff -U0 --no-color "$BASE_REF" -- "$f" 2>/dev/null > "$TMP/diff/$k.patch" || true
        awk '/^@@/ { split($3, a, ","); s = substr(a[1], 2) + 0; n = (a[2] == "" ? 1 : a[2] + 0); for (i = 0; i < n; i++) print s + i }' \
          "$TMP/diff/$k.patch" > "$TMP/diff/$k.added"
        grep -E '^-' "$TMP/diff/$k.patch" | grep -vE '^--- (a/|/dev/null)' | sed 's/^-//' > "$TMP/diff/$k.removed" || true
      fi
    fi
  fi
  printf '%s' "$k"
}
# introduced FILE LINE -> true | false | null
introduced() {
  if [[ "$DIFF_MODE" != "1" ]]; then printf 'null'; return 0; fi
  local k; k="$(diff_info "$1")"
  if grep -qxE "ALL|$2" "$TMP/diff/$k.added"; then printf 'true'; else printf 'false'; fi
  return 0
}
# removed_matches FILE ERE -> 0 when a line the port removed matches.
removed_matches() {
  [[ "$DIFF_MODE" == "1" ]] || return 1
  local k; k="$(diff_info "$1")"
  grep -qE "$2" "$TMP/diff/$k.removed"
}

# add_finding CHECK FILE LINE INTRODUCED MESSAGE [FORCED_SEVERITY]
add_finding() {
  local check="$1" file="$2" line="$3" intro="$4" msg="$5" sev="${6:-}"
  if [[ -z "$sev" ]]; then
    local col=4
    case "$intro" in true) col=2;; false) col=3;; esac
    sev="$(AWKV_c="$check" AWKV_col="$col" awk -F'\t' 'BEGIN { c = ENVIRON["AWKV_c"]; col = ENVIRON["AWKV_col"] } $1 == c { print $col }' "$TMP/severity.tsv")"
    sev="${sev:-warn}"
  fi
  [[ "$sev" == "skip" ]] && return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$check" "$sev" "$(rel "$file")" "$line" "$intro" "$msg" >> "$TMP/findings.tsv"
  return 0
}

# --- Scan the subject --------------------------------------------------------
# Scans, the class index, the extension map and the ancestry resolver are the
# shared helpers in scripts/lib/php-scan.sh (work files under $TMP).
PHPSCAN_DIR="$TMP"
PHPSCAN_DOCROOT="$DOCROOT"
FILES="$TMP/files.txt"
find "$SUBJECT_ABS" -type f \( -name '*.php' -o -name '*.module' -o -name '*.inc' -o -name '*.install' \
  -o -name '*.theme' -o -name '*.profile' -o -name '*.engine' \) \
  -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null \
  | LC_ALL=C sort > "$FILES"
php_scan_index "$FILES"
SCANNED="$(wc -l < "$FILES" | tr -d ' ')"
php_scan_extmap "$SUBJECT_ABS"
EXTMAP="$TMP/extmap.tsv"
chain_has() { php_chain_has "$@"; }
first_parent() { php_first_parent "$@"; }

# --- Check: plugin-di / static-factory / serialization / override ------------
n=0
while IFS= read -r f; do
  n=$((n + 1)); s="$TMP/scan/$n.tsv"
  [[ -s "$s" ]] || continue

  if check_on plugin-di; then
    while IFS=$'\t' read -r _ _ cls mname np first second; do
      case "$(lc "$mname")" in create) ;; *) continue;; esac
      printf '%s' "$first" | grep_q -E 'ContainerInterface|\$container' || continue
      kind="$(AWKV_q="$cls" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } $1 == "CLASS" && $4 == q { print $3; exit }' "$s")"
      [[ "$kind" == "class" ]] || continue
      # The factory kind follows the signature: create($container, array
      # $configuration, $plugin_id, $plugin_definition, ...) is a plugin factory,
      # create($container, $base_plugin_id) a deriver, and create($container)
      # (extra parameters all optional) a ClassResolver factory. Anything else
      # is not a container factory drupilot knows: skipped, never guessed.
      if printf '%s' "$second" | grep_q -E '\$configuration([^A-Za-z0-9_]|$)'; then
        target="$IF_PLUGIN"; short="ContainerFactoryPluginInterface"
      elif printf '%s' "$second" | grep_q -E '\$base_plugin_id([^A-Za-z0-9_]|$)'; then
        target="$IF_DERIVER"; short="ContainerDeriverInterface"
      elif (( np == 1 )) || printf '%s' "$second" | grep_q '='; then
        target="$IF_INJECT"; short="ContainerInjectionInterface"
      else
        continue
      fi
      cline="$(AWKV_q="$cls" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } $1 == "CLASS" && $4 == q { print $2; exit }' "$s")"
      r="$(chain_has "$cls" "$target")"
      if [[ "$r" == "no" ]]; then
        msg="${cls##*\\} defines create() (${short%Interface} factory) but neither it nor any ancestor implements ${short}: the factory is never called and the constructor gets the wrong arguments (ArgumentCountError)."
        if removed_matches "$f" "$short"; then msg="$msg The port REMOVED '$short' from this file - restore it."; fi
        add_finding plugin-di "$f" "$cline" "$(introduced "$f" "$cline")" "$msg"
      elif [[ "$r" == "unknown" ]]; then
        add_finding plugin-di "$f" "$cline" "$(introduced "$f" "$cline")" \
          "${cls##*\\} defines create() but its ancestry ($(first_parent "$cls")) could not be resolved here; verify it implements ${short} (do not assume a *Base class does)." warn
      fi
    done < <(awk -F'\t' '$1 == "METHOD"' "$s")
  fi

  if check_on static-factory; then
    while IFS=$'\t' read -r _ line cls meth; do
      case "$(lc "$meth")" in create) ;; *) continue;; esac
      mods="$(AWKV_q="$cls" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } $1 == "CLASS" && $4 == q { print $5; exit }' "$s")"
      case ",$mods," in *,final,*) continue;; esac
      msg="create() of non-final ${cls##*\\} uses 'new self(': a subclass gets a parent instance. Keep 'new static(' (do not change it to silence the sandbox PHPStan 'Unsafe usage of new static()'; leave it and note it, or make the class final in Phase 2)."
      if removed_matches "$f" 'new[[:space:]]+static[[:space:]]*\('; then msg="$msg The port replaced 'new static(' here."; fi
      add_finding static-factory "$f" "$line" "$(introduced "$f" "$line")" "$msg"
    done < <(awk -F'\t' '$1 == "NEWSELF"' "$s")
  fi

  if check_on serialization; then
    while IFS=$'\t' read -r cls cline cmods; do
      props="$(AWKV_q="$cls" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } $1 == "PROP" && $3 == q && $4 !~ /static/ && $4 ~ /(private|readonly)/' "$s")"
      ro_class=0; case ",$cmods," in *,readonly,*) ro_class=1;; esac
      [[ -n "$props" || "$ro_class" == "1" ]] || continue
      r="$(chain_has "$cls" "$TR_SERIAL")"
      [[ "$r" == "yes" ]] || continue
      if [[ "$ro_class" == "1" ]]; then
        add_finding serialization "$f" "$cline" "$(introduced "$f" "$cline")" \
          "readonly class ${cls##*\\} uses DependencySerializationTrait: __wakeup() cannot re-initialize its properties ('Cannot initialize readonly property'). Drop readonly."
      fi
      while IFS=$'\t' read -r _ pline _ pmods pname promo hasdef; do
        [[ -n "$pline" ]] || continue
        # A private, non-readonly property WITH an initializer gets its default
        # back on unserialize (e.g. a constant-like limit): not a hazard.
        case ",$pmods," in *,readonly,*) ;; *) [[ "$hasdef" == "1" ]] && continue;; esac
        what="property"; [[ "$promo" == "1" ]] && what="promoted property"
        why=""
        case ",$pmods," in *,readonly,*) why="readonly: __wakeup() cannot re-initialize it ('Cannot initialize readonly property')";; esac
        case ",$pmods," in *,private,*) why="${why:+$why; }private: __sleep() runs in the base-class scope and drops it ('must not be accessed before initialization' after unserialize)";; esac
        add_finding serialization "$f" "$pline" "$(introduced "$f" "$pline")" \
          "${cls##*\\}::\$${pname} is a ${pmods//,/ } ${what} in a class using DependencySerializationTrait - ${why}. Use protected, non-readonly."
      done <<< "$props"
    done < <(awk -F'\t' '$1 == "CLASS" && $3 == "class" { print $4 "\t" $2 "\t" $5 }' "$s")
  fi

  if check_on override-attribute; then
    while IFS=$'\t' read -r _ line cls; do
      # The method the attribute sits on (declared within the next 3 lines).
      mname="$(AWKV_q="$cls" AWKV_l="$line" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"]; l = ENVIRON["AWKV_l"] + 0 } $1 == "METHOD" && $3 == q && $2 > l && $2 <= l + 3 { print $4; exit }' "$s")"
      # A method core added in a known minor (signature catalog): an error
      # whenever the declared floor is below that minor, Drupal 10 or not.
      known=""
      if [[ -n "$mname" && -s "$TMP/sigmethods.tsv" ]]; then
        while IFS=$'\t' read -r sid starget smethod ssince; do
          [[ "$(lc "$smethod")" == "$(lc "$mname")" ]] || continue
          [[ "$(chain_has "$cls" "$starget")" == "yes" ]] || continue
          if [[ -z "$CORE_FLOOR" ]] || ! version_ge "$CORE_FLOOR" "$ssince"; then
            known="${starget##*\\}::${smethod}() exists only from Drupal ${ssince} (signature catalog: ${sid})"
          fi
          break
        done < "$TMP/sigmethods.tsv"
      fi
      if [[ -n "$known" ]]; then
        add_finding override-attribute "$f" "$line" "$(introduced "$f" "$line")" \
          "#[\\Override] on ${cls##*\\}::${mname}() but ${known}, above the declared core floor (${CORE_FLOOR:-unknown}, '${CORE_REQ}'): a compile-time fatal on PHP 8.3+ with the older cores. Remove it while the floor is below that minor." error
      elif [[ "$SPANS_D10" == "1" ]]; then
        add_finding override-attribute "$f" "$line" "$(introduced "$f" "$line")" \
          "#[\\Override] in ${cls##*\\} while core_version_requirement '${CORE_REQ}' still includes Drupal 10: confirm the parent method exists on the LOWEST core you declare (without it PHP 8.3+ fatals at compile time). Phase 1 does not add #[\\Override]."
      fi
    done < <(awk -F'\t' '$1 == "OVERRIDE"' "$s")
  fi

  if check_on test-label-markup && [[ "$LABEL_STRICTFAIL" == "1" ]]; then
    case "/$(rel "$f")" in
      */tests/*)
        php_code_lines "$f" > "$TMP/label.blank"
        while IFS=$'\t' read -r line call; do
          [[ -n "$line" ]] || continue
          intro="$(introduced "$f" "$line")"
          if [[ "$call" == "buttonNotExists" ]]; then
            [[ "$BASE_STRICTFAIL" == "0" && "$intro" == "false" ]] && intro=true
            msg="buttonNotExists() gets a translated string object as its locator while core_version_requirement '${CORE_REQ}' admits a core from ${LABEL_STRICT} to before ${LABEL_TYPED}: there core's WebAssert never casts it and passes it to Mink's findButton(string), a TypeError. Pass a string: (string) \$this->t('...') or the label itself."
          else
            [[ "$LABEL_CASTFAIL" == "1" ]] || continue
            [[ "$BASE_CASTFAIL" == "0" && "$intro" == "false" ]] && intro=true
            msg="${call}() gets a translated string object as its label while core_version_requirement '${CORE_REQ}' admits a core from ${LABEL_STRICT} to before ${LABEL_CAST}: there core's WebAssert is strict and passes it to Mink's findButton(string) unchanged, a TypeError (from ${LABEL_CAST} it casts the label). Pass a string: (string) \$this->t('...') or the label itself."
          fi
          add_finding test-label-markup "$f" "$line" "$intro" "$msg"
        done < <(php_markup_label_lines "$TMP/label.blank")
        ;;
    esac
  fi

  if check_on test-phpunit-metadata && [[ "$PUMETA_ON" == "1" ]]; then
    case "/$(rel "$f")" in
      */tests/*)
        # (0x1f between the fields: a tab is IFS whitespace, and read would
        # merge two empty fields into one separator.)
        while IFS=$'\037' read -r line level hidden twins relative grouped; do
          [[ -n "$line" ]] || continue
          intro="$(introduced "$f" "$line")"
          # Metadata that was harmless on the base range's PHPUnit 9: the
          # port's range change made it break.
          [[ "$BASE_PUMETA_ON" == "0" && "$intro" == "false" ]] && intro=true
          msg="${level} has a PHPUnit attribute (line ${line}), so PHPUnit ${PUMETA_PHPUNIT} and later (Drupal ${PUMETA_FROM} and later) read only the attributes of that level and ignore its doc-comment metadata"
          [[ -z "$hidden" ]] || msg="${msg}, with no attribute twin there for ${hidden}"
          if [[ "$level" != *::* && "$grouped" == "0" ]]; then
            case "$hidden" in *@group*) msg="${msg} (the test falls into the group \"default\", and core's run-tests.sh cannot list it)";; esac
          fi
          [[ -z "$relative" ]] || msg="${msg}; its @coversDefaultClass is ignored as well, so ${relative} is invalid there (a coverage run fails under failOnWarning): name the method in full, @covers \\Namespace\\Class::method"
          if [[ -n "$twins" && "$PUMETA_KEEP" == "1" ]]; then
            msg="${msg}. Keep the annotations for the PHPUnit of Drupal ${PUMETA_PREV} and before, which '${CORE_REQ}' still admits and which reads only them, and add their twins next to them: ${twins}."
          elif [[ -n "$twins" ]]; then
            msg="${msg}. Add their twins: ${twins}."
          else
            msg="${msg}."
          fi
          add_finding test-phpunit-metadata "$f" "$line" "$intro" "$msg"
        done < <(php_phpunit_hidden_metadata "$f")
        ;;
    esac
  fi

  if check_on test-abstract-suffix && [[ "$TABS_ON" == "1" ]]; then
    case "/$(rel "$f")" in
      */tests/*Test.php)
        while IFS=$'\t' read -r _ cline _ cfq cmods _; do
          case ",$cmods," in *,abstract,*) ;; *) continue;; esac
          add_finding test-abstract-suffix "$f" "$cline" "$(introduced "$f" "$cline")" \
            "${cfq##*\\} is abstract in a file named *Test.php: from PHPUnit ${TABS_PHPUNIT} (Drupal ${TABS_FROM} and later) collecting it throws 'Class ${cfq##*\\} is abstract', a warning that core's failOnWarning turns into a failed run. Name the class and its file *TestBase, as core does, and update the classes that extend it."
        done < <(awk -F'\t' '$1 == "CLASS" && $3 == "class"' "$s")
        ;;
    esac
  fi

  if check_on test-field-ui-display-path && [[ "$FUID_ON" == "1" ]]; then
    case "/$(rel "$f")" in
      */tests/*)
        while IFS=: read -r line _; do
          [[ -n "$line" ]] || continue
          add_finding test-field-ui-display-path "$f" "$line" "$(introduced "$f" "$line")" \
            "this path ends in /display: from Drupal ${FUID_FROM} Field UI serves an overview of the view modes there, so a test that opens it to configure a display finds no form. Open .../display/default, which serves the default display form on every core."
        done < <(grep -n -E "(drupalGet|fromUri|fromUserInput|->visit)[[:space:]]*\(.*/display(['\"]|[[:space:]]*\))" "$f" 2>/dev/null | grep -v -E '^[0-9]+:[[:space:]]*(//|\*|#)' || true)
        ;;
    esac
  fi

  if check_on test-phpunit-api && [[ "$PUAPI_ON" == "1" ]]; then
    case "/$(rel "$f")" in
      */tests/*)
        php_code_lines "$f" > "$TMP/puapi.code"
        while IFS=: read -r line member; do
          [[ -n "$line" && -n "$member" ]] || continue
          old="$(jq -r --arg m "$member" '.checks["test-phpunit-api"].members[$m] // empty' "$CFG")"
          add_finding test-phpunit-api "$f" "$line" "$(introduced "$f" "$line")" \
            "${member}() exists only from PHPUnit ${PUAPI_PHPUNIT} (Drupal ${PUAPI_FROM} and later), while '${CORE_REQ}' admits an older Drupal major whose PHPUnit has ${old}() instead: the test fails there (Rector's WithConsecutiveRector writes this call). Count the calls in the callback itself, for example with a local counter captured by reference, which every PHPUnit runs."
        done < <(grep -n -o -E -- "->[[:space:]]*(${PUAPI_ERE})[[:space:]]*\(" "$TMP/puapi.code" 2>/dev/null \
                   | sed -E 's/^([0-9]+):->[[:space:]]*([A-Za-z0-9_]+).*/\1:\2/' || true)
        ;;
    esac
  fi
done < "$FILES"

# --- Check: removed-use (diff mode) -------------------------------------------
if check_on removed-use && [[ "$DIFF_MODE" == "1" ]]; then
  n=0
  while IFS= read -r f; do
    n=$((n + 1)); s="$TMP/scan/$n.tsv"
    k="$(diff_info "$f")"
    [[ -s "$TMP/diff/$k.removed" ]] || continue
    fns="$(awk -F'\t' '$1 == "NS" { print $2; exit }' "$s")"
    while IFS= read -r ul; do
      fq="$(printf '%s' "$ul" | sed -E 's/^use[[:space:]]+\\?([A-Za-z0-9_\\]+).*/\1/')"
      alias="$(printf '%s' "$ul" | sed -nE 's/.*[[:space:]]as[[:space:]]+([A-Za-z0-9_]+)[[:space:]]*;.*/\1/p')"
      [[ -n "$alias" ]] || alias="${fq##*\\}"
      # Still imported (moved/re-added), or resolvable in the same namespace.
      AWKV_a="$alias" awk -F'\t' 'BEGIN { a = ENVIRON["AWKV_a"] } $1 == "USE" && $2 == a { found = 1 } END { exit !found }' "$s" && continue
      [[ -n "$fns" ]] && AWKV_q="$fns\\$alias" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } $1 == q { found = 1 } END { exit !found }' "$TMP/index.tsv" && continue
      ref="$(AWKV_a="$alias" awk 'BEGIN { a = ENVIRON["AWKV_a"] } 
        /^[[:space:]]*(use|namespace)[[:space:]]/ { next }
        /^[[:space:]]*(\*|\/\/|\/\*)/ && $0 !~ /@(param|return|var|throws|see)/ { next }
        { line = $0
          while (match(line, "(^|[^A-Za-z0-9_\\\\$>:])" a "([^A-Za-z0-9_]|$)")) { print NR; exit }
        }' "$f")"
      [[ -n "$ref" ]] || continue
      add_finding removed-use "$f" "$ref" true \
        "the port removed 'use ${fq};' but '${alias}' is still referenced here (class not found / broken PHPDoc type). Restore the import."
    done < <(grep -E '^use[[:space:]]+[A-Za-z\\]' "$TMP/diff/$k.removed" | grep -vE '^use[[:space:]]+(function|const)[[:space:]]' || true)
  done < "$FILES"
fi

# --- Check: fapi-callable -----------------------------------------------------
if check_on fapi-callable; then
  while IFS= read -r f; do
    while IFS=$'\t' read -r line key; do
      [[ -n "$line" ]] || continue
      add_finding fapi-callable "$f" "$line" "$(introduced "$f" "$line")" \
        "'${key}' gets a first-class callable/closure: closures cannot be serialized, so a cached form (#ajax, form state cache) fatals. Use [\$this, 'method'], [static::class, 'method'], '::method' or a function-name string."
    done < <(AWKV_keys=" $FAPI_KEYS " awk 'BEGIN { keys = ENVIRON["AWKV_keys"] } 
      function lastkey(s,   k, t, best, pos) {
        best = ""
        t = s
        while (match(t, /\[[[:space:]]*["\047]#[A-Za-z_]+["\047][[:space:]]*\]|["\047]#?[A-Za-z_]+["\047][[:space:]]*=>/)) {
          k = substr(t, RSTART, RLENGTH); gsub(/[][]/, "", k); gsub(/["\047]/, "", k); gsub(/=>/, "", k); gsub(/[[:space:]]/, "", k); best = k
          t = substr(t, RSTART + RLENGTH)
        }
        return best
      }
      /^[[:space:]]*(\*|\/\/|\/\*|#[^\[])/ { hist[NR] = ""; next }
      {
        hist[NR] = $0
        if (match($0, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([[:space:]]*\.\.\.[[:space:]]*\)|(^|[^A-Za-z0-9_$>])(static[[:space:]]+)?(function|fn)[[:space:]]*\(|Closure::fromCallable/)) {
          k = lastkey(substr($0, 1, RSTART - 1))
          if (k == "") {
            for (j = NR - 1; j >= NR - 10 && j > 0; j--) {
              if (hist[j] ~ /;[[:space:]]*$/) break
              k = lastkey(hist[j]); if (k != "") break
            }
          }
          if (k != "" && index(keys, " " k " ") > 0) print NR "\t" k
        }
      }' "$f")
  done < "$FILES"
fi

# --- Check: class-case ----------------------------------------------------------
if check_on class-case; then
  # PSR-4: the single class in src/**/X.php must be named X (same case).
  n=0
  while IFS= read -r f; do
    n=$((n + 1)); s="$TMP/scan/$n.tsv"
    case "$f" in */src/*.php) ;; *) continue;; esac
    [[ "$(awk -F'\t' '$1 == "CLASS"' "$s" | wc -l | tr -d ' ')" == "1" ]] || continue
    IFS=$'\t' read -r _ cline _ cfq _ < <(awk -F'\t' '$1 == "CLASS"' "$s")
    base="$(basename "$f" .php)"; cname="${cfq##*\\}"
    if [[ "$cname" != "$base" ]]; then
      add_finding class-case "$f" "$cline" "$(introduced "$f" "$cline")" \
        "declares '${cname}' in ${base}.php: PSR-4 autoloading needs the exact file name (case-sensitive on Linux)."
    fi
  done < "$FILES"
  # services.yml / routing.yml references into this extension.
  while IFS= read -r y; do
    while IFS=$'\t' read -r line val; do
      fq="${val#\\}"; fq="${fq%%::*}"
      case "$fq" in Drupal\\*\\*) ;; *) continue;; esac
      rest="${fq#Drupal\\}"; ext="${rest%%\\*}"; rest="${rest#*\\}"
      dir="$(AWKV_e="$ext" awk -F'\t' 'BEGIN { e = ENVIRON["AWKV_e"] } $1 == e { print $2; exit }' "$EXTMAP")"
      case "$dir" in "$SUBJECT_ABS"|"$SUBJECT_ABS"/*) ;; *) continue;; esac
      relp="$(printf '%s' "$rest" | tr '\\' '/').php"
      [[ -d "$dir/src" ]] || continue
      exact="$(find "$dir/src" -type f -path "$dir/src/$relp" 2>/dev/null | sed -n '1p')"
      [[ -z "$exact" ]] || continue
      real="$(find "$dir/src" -type f -ipath "$dir/src/$relp" 2>/dev/null | sed -n '1p')"
      [[ -n "$real" ]] || continue   # a missing class is metadata hygiene, not a case problem
      add_finding class-case "$y" "$line" "$(introduced "$y" "$line")" \
        "'${fq}' does not match the real file '$(rel "$real")' (case differs): works on a case-insensitive filesystem, fatals on Linux."
    done < <(awk '
      /^[[:space:]]*#/ { next }
      match($0, /^[[:space:]]+(class|_form|_controller|_title_callback):[[:space:]]*/) {
        v = substr($0, RSTART + RLENGTH); gsub(/["\047[:space:]]/, "", v)
        if (v ~ /\\/) print NR "\t" v
      }' "$y")
  done < <(find "$SUBJECT_ABS" \( -name '*.services.yml' -o -name '*.routing.yml' \) \
             -not -path '*/vendor/*' -not -path '*/node_modules/*' 2>/dev/null | LC_ALL=C sort)
fi

# --- Check: config-schema-sequence ------------------------------------------------
# config/port-checks.json: the list form of a sequence's item type is removed
# from removed_in. On when the declared range, or the target major the port
# declares, admits that major (at assess time the range is still the old one).
if check_on config-schema-sequence; then
  SEQ_DEPRECATED="$(jq -r '.checks["config-schema-sequence"].deprecated_in // empty' "$CFG")"
  SEQ_REMOVED="$(jq -r '.checks["config-schema-sequence"].removed_in // empty' "$CFG")"
  SEQ_ON=0
  if [[ "$SEQ_REMOVED" =~ ^([0-9]+) ]]; then
    _sm="${BASH_REMATCH[1]}"
    _tm="$(resolve_target_major 2>/dev/null || true)"
    if [[ "$_tm" =~ ^[0-9]+$ ]] && (( _tm >= _sm )); then SEQ_ON=1; fi
    if [[ -n "$CORE_REQ" ]]; then
      for _m in $(seq "$_sm" "$((_sm + 3))"); do constraint_admits_major "$CORE_REQ" "$_m" && SEQ_ON=1; done
    fi
  fi
  if [[ "$SEQ_ON" == "1" ]]; then
    while IFS= read -r y; do
      while IFS= read -r line; do
        add_finding config-schema-sequence "$y" "$line" "$(introduced "$y" "$line")" \
          "this sequence lists its item type ('- type: ...'), a form deprecated in drupal:${SEQ_DEPRECATED} and removed from drupal:${SEQ_REMOVED}: from Drupal ${SEQ_REMOVED%%.*} its items have no type and saving the configuration throws SchemaIncompleteException. Write the item definition as a mapping under 'sequence:' (drop the '- '), which every core reads."
      done < <(awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
          if (pend && $0 ~ /^[[:space:]]*-[[:space:]]/) print NR
          pend = 0
          if ($0 ~ /^[[:space:]]*sequence:[[:space:]]*(#.*)?$/) pend = 1
          else if ($0 ~ /^[[:space:]]*sequence:[[:space:]]*\[/) print NR
        }' "$y")
    done < <(find "$SUBJECT_ABS" -type f -path '*/config/schema/*' -name '*.yml' \
               -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | LC_ALL=C sort)
  fi
fi

# --- Check: migrate-dependencies-expand -----------------------------------------
# config/port-checks.json: getMigrationDependencies() expands the plugin IDs
# from expands_from. On like config-schema-sequence (range or target major).
if check_on migrate-dependencies-expand; then
  MDE_FROM="$(jq -r '.checks["migrate-dependencies-expand"].expands_from // empty' "$CFG")"
  MDE_ON=0
  if [[ "$MDE_FROM" =~ ^([0-9]+) ]]; then
    _dm="${BASH_REMATCH[1]}"
    _tm="$(resolve_target_major 2>/dev/null || true)"
    if [[ "$_tm" =~ ^[0-9]+$ ]] && (( _tm >= _dm )); then MDE_ON=1; fi
    if [[ -n "$CORE_REQ" ]]; then
      for _m in $(seq "$_dm" "$((_dm + 3))"); do constraint_admits_major "$CORE_REQ" "$_m" && MDE_ON=1; done
    fi
  fi
  if [[ "$MDE_ON" == "1" ]]; then
    while IFS= read -r f; do
      case "/$(rel "$f")" in
        */src/Plugin/migrate/field/*.php|*/src/*Deriver*.php) ;;
        *) continue;;
      esac
      php_code_lines "$f" > "$TMP/mde.code"
      while IFS=: read -r line _; do
        [[ -n "$line" ]] || continue
        add_finding migrate-dependencies-expand "$f" "$line" "$(introduced "$f" "$line")" \
          "getMigrationDependencies() here runs while the migration definitions are being built (a migrate field plugin or a deriver): from Drupal ${MDE_FROM} it always expands the plugin IDs, which reads those definitions again and can recurse until PHP runs out of memory. Read the unexpanded dependencies, \$migration->getPluginDefinition()['migration_dependencies'], which every core keeps."
      done < <(grep -n -E -- '->[[:space:]]*getMigrationDependencies[[:space:]]*\(' "$TMP/mde.code" 2>/dev/null || true)
    done < "$FILES"
  fi
fi

# --- Check: event-dispatch-order ------------------------------------------------
# config/port-checks.json: the event name first, removed with removed_in's
# Symfony. On like config-schema-sequence (range or target major). The first
# argument may start on the line after 'dispatch('.
if check_on event-dispatch-order; then
  EDO_REMOVED="$(jq -r '.checks["event-dispatch-order"].removed_in // empty' "$CFG")"
  EDO_ON=0
  if [[ "$EDO_REMOVED" =~ ^([0-9]+) ]]; then
    _em="${BASH_REMATCH[1]}"
    _tm="$(resolve_target_major 2>/dev/null || true)"
    if [[ "$_tm" =~ ^[0-9]+$ ]] && (( _tm >= _em )); then EDO_ON=1; fi
    if [[ -n "$CORE_REQ" ]]; then
      for _m in $(seq "$_em" "$((_em + 3))"); do constraint_admits_major "$CORE_REQ" "$_m" && EDO_ON=1; done
    fi
  fi
  if [[ "$EDO_ON" == "1" ]]; then
    while IFS= read -r f; do
      php_code_lines "$f" > "$TMP/edo.code"
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        add_finding event-dispatch-order "$f" "$line" "$(introduced "$f" "$line")" \
          "dispatch() gets the event name first, the order of Symfony 4.2 and before: from Drupal ${EDO_REMOVED%%.*} (Symfony 6 and later) the signature is dispatch(object \$event, ?string \$eventName = NULL), so this call throws a TypeError. Swap the two arguments: dispatch(\$event, NAME)."
      done < <(awk '
        function first_is_name(t) {
          sub(/^[[:space:]]+/, "", t)
          return t ~ /^(\\?[A-Za-z_][A-Za-z0-9_\\]*::[A-Z][A-Z0-9_]*|\047[^\047]*\047|"[^"]*")[[:space:]]*,/
        }
        pend { if ($0 ~ /^[[:space:]]*$/) next; if (first_is_name($0)) print pend; pend = 0 }
        {
          t = $0
          while (match(t, /->[[:space:]]*dispatch[[:space:]]*\(/)) {
            t = substr(t, RSTART + RLENGTH)
            if (t ~ /^[[:space:]]*$/) { pend = NR; break }
            if (first_is_name(t)) { print NR; break }
          }
        }' "$TMP/edo.code")
    done < "$FILES"
  fi
fi

# --- Report ---------------------------------------------------------------------
LC_ALL=C sort -t$'\t' -k3,3 -k4,4n -k1,1 -u "$TMP/findings.tsv" -o "$TMP/findings.tsv"
ERRORS="$(awk -F'\t' '$2 == "error"' "$TMP/findings.tsv" | wc -l | tr -d ' ')"
WARNINGS="$(awk -F'\t' '$2 == "warn"' "$TMP/findings.tsv" | wc -l | tr -d ' ')"

log_info "Subject     : $SUBJECT_ABS ($SCANNED PHP file(s))"
log_info "Drupal root : ${DRUPAL_ROOT:-<none - ancestry from the fallback list>}"
if [[ "$DIFF_MODE" == "1" ]]; then
  log_info "Diff base   : $BASE_REF ($REPO)"
else
  log_info "Diff base   : <none - findings not attributed to the port>"
fi
log_info "Core range  : ${CORE_REQ:-<not declared>}"

if [[ "$AS_JSON" == "1" ]]; then
  jq -R -s -c \
    --arg subject "$SUBJECT_ABS" --arg root "$DRUPAL_ROOT" --arg base "$BASE_REF" \
    --argjson diff "$([[ "$DIFF_MODE" == "1" ]] && echo true || echo false)" \
    --arg core "$CORE_REQ" --arg checks "$CHECKS" \
    '(split("\n") | map(select(length > 0) | split("\t")
       | {check: .[0], severity: .[1], file: .[2], line: (.[3] | tonumber? // .[3]),
          introduced: (.[4] | if . == "true" then true elif . == "false" then false else null end),
          message: .[5]})) as $f
     | {tool: "check-port-safety", subject: $subject,
        drupal_root: (if $root == "" then null else $root end),
        base: (if $base == "" then null else $base end), diff_mode: $diff,
        core_requirement: (if $core == "" then null else $core end),
        checks: ($checks | split(" ") | map(select(length > 0))),
        ok: (($f | map(select(.severity == "error")) | length) == 0),
        errors: ($f | map(select(.severity == "error")) | length),
        warnings: ($f | map(select(.severity == "warn")) | length),
        findings: $f}' "$TMP/findings.tsv"
else
  awk -F'\t' '{ printf "[%s] %s %s:%s %s\n", $1, $2, $3, $4, $5 == "true" ? $6 " (introduced by the port)" : $6 }' "$TMP/findings.tsv"
fi

if [[ "$ERRORS" != "0" ]]; then
  log_err "Port-safety: $ERRORS error(s), $WARNINGS warning(s). Fix the errors before the stage is done."
  exit 3
fi
if [[ "$WARNINGS" != "0" ]]; then
  log_warn "Port-safety: 0 errors, $WARNINGS warning(s) to review."
else
  log_ok "Port-safety: clean."
fi
exit 0
