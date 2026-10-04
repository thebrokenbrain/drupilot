#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/convert-attributes.sh
# Optional, opt-in pass that converts plugin doc-block annotations (@Block(...),
# @QueueWorker(...), @Filter(...), ...) into PHP 8 attributes with the
# AnnotationToAttributeRector rule of palantirnet/drupal-rector (0.21.x and
# 1.1.x ship the rule but configure it in no set). It is independent of run-rector.sh's
# official and digests passes: it renders its own config,
# templates/rector-attributes.php.tmpl -> <drupal_root>/.drupilot/rector-attributes.php
# (reachable at the same relative path inside DDEV, gitignored), and runs only
# that rule. `run-rector.sh --attributes ...` forwards here.
#
# Supported types: the core plugin types of config/plugin-attributes.json, each
# with the core minor (`since`) that ships its attribute class (verified against
# drupal/core source), plus project/contrib plugin types declared in
# DRUPILOT_ATTRIBUTE_PLUGIN_TYPES (env > .drupilot.json): a comma-separated list
# of `Annotation=Fully\Qualified\AttributeClass[@since]`, e.g.
#   ExtraFieldDisplay=Drupal\extra_field\Attribute\ExtraFieldDisplay
# A custom type is converted only when its attribute class exists under the
# Drupal root; when no plugin manager references it (an annotation-only
# manager) it is never stripped, and kept only with a warning.
#
# Modes (DRUPILOT_ATTRIBUTES_MODE or --mode; default keep):
#   keep   add the attribute and KEEP the annotation next to it. Core reads the
#          attribute from the type's `since` minor on and the annotation before
#          it, so the runtime floor is unchanged. The attribute class itself only
#          exists from `since`: PHPStan on an older core reports it, so the
#          honest declared floor is still >= since (see --raise-floor).
#   strip  add the attribute and REMOVE the annotation — only for types whose
#          `since` is <= the declared core floor (or all with --raise-floor).
#          A type above the floor is kept (keep semantics) and listed, so this
#          pass never raises the floor silently.
#
# The annotation is removed by the rule only when the test-bed core is >= the
# configured removeVersion: drupilot writes the type's `since` to strip and
# 999.0.0 to keep. Names are printed fully qualified (no import). A file that
# already carries a short-named (imported) #[X] attribute of a converted
# type's short name is skipped: the 1.1.x rule takes ANY attribute with that
# short name for the converted one (an unrelated class of the same name would
# suppress the Drupal attribute, and strip mode would then lose the plugin),
# and drupilot does not resolve the imports to tell the cases apart. The rule copies every annotation key into a named
# argument as is, so before the run each annotation's top-level keys are
# checked against the attribute constructor's parameters, read from the
# attribute class in the test-bed core and in every cached reference core at or
# above the type's `since` (.drupilot/cores): a file with a key the constructor
# does not accept (e.g. `source_module` on @MigrateSource) is skipped and keeps
# its annotation, as Drupal core does for such plugins, because the attribute
# would fatal with "Unknown named parameter" when the plugin is discovered.
# After --apply, every changed file is checked: a duplicate attribute, an
# annotation removed without its attribute, a
# `php -l` failure or a PHPStan (level 0) finding that names a converted
# attribute class restores the file from the backup taken just before the run. A class constant the annotation names by a
# qualified but not fully qualified name (`Drupal\filter\Plugin\FilterInterface::
# TYPE_X`, valid in an annotation, namespace-relative in PHP code) is rewritten
# fully qualified (`\Drupal\...`) in the generated attribute.
#
# Usage:
#   convert-attributes.sh --subject DIR [--apply] [--mode keep|strip]
#                         [--floor X.Y] [--raise-floor] [--max-since X.Y]
#                         [--types A,B] [--json] [-h|--help]
#
# Options:
#   --subject DIR    The module/theme (under the Drupal root). Required.
#   --apply          Write the changes (default: dry-run, nothing modified).
#   --dry-run        Explicit dry-run (the default).
#   --mode M         keep | strip (default DRUPILOT_ATTRIBUTES_MODE, else keep).
#   --floor X.Y      The declared core floor to judge against (default: the
#                    lowest core the subject's core_version_requirement admits).
#   --raise-floor    Strip every converted type (strip mode) and, with --apply,
#                    raise core_version_requirement in every *.info.yml
#                    (set-core-requirement.sh) to the highest `since` among the
#                    converted types, keeping higher majors ('^10 || ^11' +
#                    10.3 -> '^10.3 || ^11'; + 11.1 -> '^11.1'). Raising the
#                    floor drops support for older cores: a BC break.
#   --max-since X.Y  Convert only types whose `since` is <= X.Y (e.g. 10.3 keeps
#                    Drupal 10 reachable: the entity types, 11.1, are left alone).
#   --types A,B      Only these annotation names (default: every known type).
#   --json           Print a JSON summary on STDOUT (see below).
#   -h, --help       Show this help.
#
# Output: logs on STDERR; on STDOUT the changed files (one per line), or with
# --json:
#   {tool:"attributes", status: ok|error|noop, ok, applied, mode, core_version,
#    declared_requirement, declared_floor, attribute_floor, floor_ok,
#    recommended_requirement, floor_raised,
#    types:[{annotation, attribute, since, origin: core|custom, files,
#            converted_files, action: strip|keep|skipped, reason}],
#    files:[...], changed_files, skipped_files:[{file, reason}],
#    restored_files:[{file, reason}], qualified_constants,
#    phpstan_check: ok|crashed|unavailable|null (--apply only),
#    rule_hits:{attributes:{AnnotationToAttributeRector:n}}, errors:[...]}
#   attribute_floor: the highest `since` among the converted types (the core
#   floor the result needs for static analysis; also the runtime floor for the
#   stripped types). floor_ok: declared_floor >= attribute_floor.
#   rule_hits merges into the port manifest's rector_rules.
#
# Gate: `analyze` profile. Exit codes: 0 ok (including nothing to convert) ·
# 1 usage error · 2 gate (requirements, Drupal root, vendor/bin/rector or the
# rule missing, unknown core version) · 3 Rector crashed (no verdict).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/php-scan.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/php-scan.sh"

SUBJECT=""
APPLY=0
MODE=""
FLOOR_OPT=""
RAISE=0
MAX_SINCE=""
TYPES_OPT=""
AS_JSON=0

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --apply) APPLY=1; shift;;
    --dry-run) APPLY=0; shift;;
    --mode) MODE="${2:-}"; shift 2 || die "--mode needs a value" 1;;
    --mode=*) MODE="${1#*=}"; shift;;
    --floor) FLOOR_OPT="${2:-}"; shift 2 || die "--floor needs a value" 1;;
    --floor=*) FLOOR_OPT="${1#*=}"; shift;;
    --raise-floor) RAISE=1; shift;;
    --max-since) MAX_SINCE="${2:-}"; shift 2 || die "--max-since needs a value" 1;;
    --max-since=*) MAX_SINCE="${1#*=}"; shift;;
    --types) TYPES_OPT="${2:-}"; shift 2 || die "--types needs a value" 1;;
    --types=*) TYPES_OPT="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_err "Unknown argument: $1"; usage >&2; exit 1;;
  esac
done

[[ -n "$SUBJECT" ]] || die "Missing --subject DIR (the module/theme to process)." 1
if [[ -z "$MODE" ]]; then
  MODE="$(config_enum DRUPILOT_ATTRIBUTES_MODE keep keep strip)" || die "Fix DRUPILOT_ATTRIBUTES_MODE (keep|strip)." 1
fi
case "$MODE" in keep|strip) : ;; *) die "Invalid --mode '$MODE' (expected keep|strip)." 1;; esac
if [[ -n "$FLOOR_OPT" && ! "$FLOOR_OPT" =~ ^[0-9]+\.[0-9]+$ ]]; then die "Invalid --floor '$FLOOR_OPT' (expected MAJOR.MINOR, e.g. 10.3)." 1; fi
if [[ -n "$MAX_SINCE" && ! "$MAX_SINCE" =~ ^[0-9]+\.[0-9]+$ ]]; then die "Invalid --max-since '$MAX_SINCE' (expected MAJOR.MINOR, e.g. 10.3)." 1; fi
have_cmd jq || die "jq is required." 2

# --- Gate: analyze --------------------------------------------------------
PREFLIGHT="$(plugin_root)/scripts/env/preflight.sh"
if ! bash "$PREFLIGHT" --profile analyze --quiet >/dev/null 2>&1; then
  log_err "The 'analyze' requirements are not satisfied; cannot run Rector."
  bash "$PREFLIGHT" --profile analyze >&2 || true
  exit 2
fi

# --- Drupal root + subject --------------------------------------------------
DRUPAL_ROOT="$(find_drupal_root "$SUBJECT" 2>/dev/null || find_drupal_root "$PWD" 2>/dev/null || true)"
[[ -n "$DRUPAL_ROOT" ]] || die "Could not locate a Drupal root from '$SUBJECT'. Run /drupilot-setup first." 2
SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
[[ -n "$SUBJECT_ABS" ]] || SUBJECT_ABS="$(cd "$DRUPAL_ROOT/$SUBJECT" 2>/dev/null && pwd || true)"
[[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1
case "$SUBJECT_ABS" in
  "$DRUPAL_ROOT"/*) SUBJECT_REL="${SUBJECT_ABS#"$DRUPAL_ROOT"/}";;
  *) die "Subject '$SUBJECT_ABS' is outside the Drupal root '$DRUPAL_ROOT' (place it with scripts/env/place-subject.sh)." 1;;
esac

cd "$DRUPAL_ROOT"
export DRUPILOT_PROJECT_DIR="$DRUPAL_ROOT"
[[ -f "$DRUPAL_ROOT/vendor/bin/rector" ]] \
  || die "vendor/bin/rector is missing. Install the toolchain first (/drupilot-setup)." 2
RULE_SRC="$DRUPAL_ROOT/vendor/palantirnet/drupal-rector/src/Drupal10/Rector/Deprecation/AnnotationToAttributeRector.php"
[[ -f "$RULE_SRC" ]] \
  || die "The installed palantirnet/drupal-rector has no AnnotationToAttributeRector (needs 0.20+; the known-good toolchain ships 1.1.x)." 2

CORE_VER="$(drupal_core_version "$DRUPAL_ROOT")"
CORE_MM="$(printf '%s' "$CORE_VER" | grep -oE '^[0-9]+\.[0-9]+' || true)"
[[ -n "$CORE_MM" ]] || die "Could not read the installed drupal/core version under $DRUPAL_ROOT." 2

DECLARED_REQ="$(trim "$(subject_core_requirement "$SUBJECT_ABS" 2>/dev/null || true)")"
DECLARED_REQ="${DECLARED_REQ//\"/}"; DECLARED_REQ="${DECLARED_REQ//\'/}"
if [[ -n "$FLOOR_OPT" ]]; then DECLARED_FLOOR="$FLOOR_OPT"
else DECLARED_FLOOR="$(core_floor_from_requirement "$DECLARED_REQ")"; fi

log_info "Drupal root : $DRUPAL_ROOT (core $CORE_VER)"
log_info "Subject     : $SUBJECT_REL"
log_info "Mode        : $MODE$([[ "$RAISE" == "1" ]] && printf ' (+ raise floor)')"
log_info "Declared    : ${DECLARED_REQ:-<none>} (floor ${DECLARED_FLOOR:-unknown})"

# mm_le A B -> 0 when MAJOR.MINOR A <= B.
mm_le() { version_ge "$2" "$1"; }

# --- Types table: annotation<TAB>attribute<TAB>since<TAB>origin ------------
TYPES_FILE="$(plugin_root)/config/plugin-attributes.json"
[[ -r "$TYPES_FILE" ]] || die "Missing $TYPES_FILE." 2
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-attr.XXXXXX")" || die "Cannot create a temp dir." 1
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT
TYPES_TSV="$TMPD/types.tsv"
# join (not @tsv): @tsv would escape the namespace backslashes.
jq -r '.types[] | [.annotation, .attribute, .since, "core"] | join("\t")' "$TYPES_FILE" > "$TYPES_TSV"

CUSTOM="$(config_get DRUPILOT_ATTRIBUTE_PLUGIN_TYPES "")"
if [[ -n "$CUSTOM" ]]; then
  _old_ifs="$IFS"; IFS=','
  # shellcheck disable=SC2086  # split on commas on purpose
  set -- $CUSTOM
  IFS="$_old_ifs"
  for item in "$@"; do
    item="$(trim "$item")"; [[ -n "$item" ]] || continue
    ann="${item%%=*}"; rest="${item#*=}"; since=""
    if [[ "$item" != *=* ]]; then log_warn "Ignoring DRUPILOT_ATTRIBUTE_PLUGIN_TYPES entry '$item' (expected Annotation=Fully\\Qualified\\Attribute[@since])."; continue; fi
    if [[ "$rest" == *@* ]]; then since="${rest##*@}"; rest="${rest%@*}"; fi
    rest="${rest#\\}"
    if [[ ! "$ann" =~ ^[A-Za-z_][A-Za-z0-9_]*$ || ! "$rest" =~ ^[A-Za-z_][A-Za-z0-9_\\]*$ ]] \
       || [[ -n "$since" && ! "$since" =~ ^[0-9]+\.[0-9]+$ ]]; then
      log_warn "Ignoring DRUPILOT_ATTRIBUTE_PLUGIN_TYPES entry '$item' (expected Annotation=Fully\\Qualified\\Attribute[@MAJOR.MINOR])."
      continue
    fi
    # A custom entry overrides a core one with the same annotation.
    awk -F '\t' -v a="$ann" '$1 != a' "$TYPES_TSV" > "$TYPES_TSV.n" && mv "$TYPES_TSV.n" "$TYPES_TSV"
    # '-' for "no since": tab is IFS whitespace, so `read` would collapse an
    # empty field and shift the next one into it.
    printf '%s\t%s\t%s\tcustom\n' "$ann" "$rest" "${since:--}" >> "$TYPES_TSV"
  done
fi
if [[ -n "$TYPES_OPT" ]]; then
  _want=",$(printf '%s' "$TYPES_OPT" | tr -d ' @'),"
  awk -F '\t' -v w="$_want" 'index(w, "," $1 ",") > 0' "$TYPES_TSV" > "$TYPES_TSV.n" && mv "$TYPES_TSV.n" "$TYPES_TSV"
fi

# --- Scan the subject: annotation tags and existing attributes per file -----
# TAG<TAB>file<TAB>Annotation   (a doc-block line ` * @Annotation(`)
# ATTR<TAB>file<TAB>name        (each attribute as written, every name of a
#                               group `#[A, B(...)]`, one-line or not)
SCAN="$TMPD/scan.tsv"
find "$SUBJECT_REL" -type f -name '*.php' ! -path '*/vendor/*' ! -path '*/node_modules/*' -exec awk '
  FNR == 1 { ingrp = 0; depth = 0; expect = 0; q = "" }
  /^[ \t]*\*[ \t]*@[A-Za-z_][A-Za-z0-9_]*[ \t]*\(/ {
    s = $0; sub(/^[ \t]*\*[ \t]*@/, "", s); sub(/[ \t]*\(.*$/, "", s)
    print "TAG\t" FILENAME "\t" s
  }
  # An attribute group opens at a line-leading #[ and ends at its top-level ];
  # a name follows the #[ and every top-level comma (strings are skipped).
  ingrp || /^[ \t]*#\[/ {
    line = $0; n = length(line); i = 1
    if (!ingrp) { i = index(line, "#[") + 2; ingrp = 1; depth = 0; expect = 1; q = "" }
    while (i <= n) {
      ch = substr(line, i, 1)
      if (q != "") { if (ch == q) q = ""; i++; continue }
      if (ch == "\047" || ch == "\"") { q = ch; i++; continue }
      if (expect && ch ~ /[A-Za-z0-9_\\]/) {
        match(substr(line, i), /^[A-Za-z0-9_\\]+/)
        print "ATTR\t" FILENAME "\t" substr(line, i, RLENGTH)
        i += RLENGTH; expect = 0; continue
      }
      if (ch == "(" || ch == "[") depth++
      else if (ch == ")") depth--
      else if (ch == "]") {
        if (depth > 0) depth--
        else {
          ingrp = 0
          p = index(substr(line, i + 1), "#[")
          if (p == 0) break
          i += p + 2; ingrp = 1; depth = 0; expect = 1; continue
        }
      }
      else if (ch == "," && depth == 0) expect = 1
      i++
    }
  }' {} + > "$SCAN" 2>/dev/null || true

# custom_class_file <FQCN> -> a file under the Drupal root declaring it.
custom_class_file() {
  local fq="$1" short ns f
  short="${fq##*\\}"; ns="${fq%\\*}"
  while IFS= read -r f; do
    grep -qF "namespace $ns;" "$f" 2>/dev/null && { printf '%s' "$f"; return 0; }
  done < <(find web/modules web/profiles web/themes web/core "$SUBJECT_REL" -type f -name "$short.php" 2>/dev/null || true)
  return 0
}
# custom_manager_reads <FQCN> <class_file> -> 0 when a plugin manager / discovery
# outside the attribute's own file references the attribute class.
custom_manager_reads() {
  local fq="$1" self="$2" dq f
  dq="$(printf '%s' "$fq" | sed 's/\\/\\\\/g')"
  while IFS= read -r f; do
    [[ "$f" == "$self" ]] && continue
    grep -qE 'DefaultPluginManager|AttributeClassDiscovery|AttributeDiscoveryWithAnnotations|parent::__construct\(' "$f" 2>/dev/null && return 0
  done < <(find web/modules web/profiles web/core "$SUBJECT_REL" -type f -name '*.php' \
             -exec grep -lF -e "$fq" -e "$dq" {} + 2>/dev/null || true)
  return 1
}

# --- Decide per type ----------------------------------------------------------
TYPES_JSON="[]"
CONFIG_LINES=""
ACTIVE="$TMPD/active.tsv"   # annotation<TAB>attribute<TAB>since<TAB>action
: > "$ACTIVE"
ATTR_FLOOR=""
while IFS=$'\t' read -r ann attr since origin; do
  [[ -n "$ann" ]] || continue
  [[ "$since" == "-" ]] && since=""
  nfiles="$(awk -F '\t' -v a="$ann" '$1 == "TAG" && $3 == a { print $2 }' "$SCAN" | sort -u | grep -c . || true)"
  [[ "$nfiles" == "0" ]] && continue
  action=""; reason=""
  if [[ "$origin" == "core" ]] && ! mm_le "$since" "$CORE_MM"; then
    action="skipped"; reason="needs core >= $since; the test-bed runs $CORE_MM"
  elif [[ -n "$MAX_SINCE" && -n "$since" ]] && ! mm_le "$since" "$MAX_SINCE"; then
    action="skipped"; reason="since $since is above --max-since $MAX_SINCE"
  elif [[ "$origin" == "custom" ]]; then
    cf="$(custom_class_file "$attr")"
    if [[ -z "$cf" ]]; then
      action="skipped"; reason="attribute class $attr not found under the Drupal root"
    elif ! custom_manager_reads "$attr" "$cf"; then
      if [[ "$MODE" == "strip" ]]; then
        action="skipped"; reason="no plugin manager references $attr (annotation-only discovery): never stripped"
      else
        action="keep"; reason="no plugin manager references $attr yet: the attribute is inert until the manager discovers it"
      fi
    fi
  fi
  if [[ -z "$action" ]]; then
    if [[ "$MODE" == "keep" ]]; then
      action="keep"
    elif [[ "$RAISE" == "1" || -z "$since" ]]; then
      action="strip"
    elif [[ -n "$DECLARED_FLOOR" ]] && mm_le "$since" "$DECLARED_FLOOR"; then
      action="strip"
    else
      action="keep"; reason="since $since is above the declared floor ${DECLARED_FLOOR:-unknown}: annotation kept (--raise-floor strips it)"
    fi
  fi
  TYPES_JSON="$(printf '%s' "$TYPES_JSON" | jq -c --arg a "$ann" --arg c "$attr" --arg s "$since" --arg o "$origin" \
    --argjson n "$nfiles" --arg ac "$action" --arg r "$reason" \
    '. + [{annotation:$a, attribute:$c, since:(if $s == "" then null else $s end), origin:$o, files:$n, action:$ac,
           reason:(if $r == "" then null else $r end)}]')"
  [[ "$action" == "skipped" ]] && { log_warn "@$ann: skipped — $reason."; continue; }
  [[ -n "$reason" ]] && log_warn "@$ann: $reason."
  printf '%s\t%s\t%s\t%s\n' "$ann" "$attr" "${since:--}" "$action" >> "$ACTIVE"
  intro="${since:-8.0}.0"
  if [[ "$action" == "strip" ]]; then remove="$intro"; else remove="999.0.0"; fi
  CONFIG_LINES="${CONFIG_LINES}    new AnnotationToAttributeConfiguration('$intro', '$remove', '$ann', '$(printf '%s' "$attr" | sed 's/\\/\\\\/g')'),
"
done < "$TYPES_TSV"

# --- Accepted attribute parameters ---------------------------------------------
# The rule copies every annotation key into a named argument of the attribute
# as is. A key the attribute constructor does not declare (e.g. `source_module`
# of a @MigrateSource: core's MigrateSource attribute takes only id,
# requirements_met, minimum_version and deriver) makes the attribute fatal when
# the plugin manager instantiates it ("Unknown named parameter"), and `php -l`
# cannot see it. So the constructor parameters are read from the attribute
# class itself (php-scan.sh, following the parent classes) in the test-bed core
# and in every cached reference core (.drupilot/cores, verify-core-matrix.sh)
# that is at or above the type's `since`, and a file whose annotation has a
# key one of them does not accept keeps its annotation untouched — what core
# itself does for such plugins (e.g. ban's d7 BlockedIps migrate source). A
# variadic constructor accepts any key.
# docroot_of <root> -> the dir holding core/lib (web/, docroot/ or the root).
docroot_of() {
  local d
  for d in "$1/web" "$1/docroot" "$1"; do
    [[ -d "$d/core/lib/Drupal" ]] && { printf '%s' "$d"; return 0; }
  done
  return 0
}
PARAMS_DIR="$TMPD/params"; mkdir -p "$PARAMS_DIR"
DOCROOTS="$TMPD/docroots.tsv"   # docroot<TAB>core MAJOR.MINOR<TAB>label
: > "$DOCROOTS"
_dr="$(docroot_of "$DRUPAL_ROOT")"
[[ -n "$_dr" ]] && printf '%s\t%s\t%s\n' "$_dr" "$CORE_MM" "test-bed core $CORE_VER" >> "$DOCROOTS"
for _rc in "$DRUPAL_ROOT"/.drupilot/cores/drupal-*; do
  [[ -d "$_rc" ]] || continue
  _dr="$(docroot_of "$_rc")"; [[ -n "$_dr" ]] || continue
  _v="$(drupal_core_version "$_rc")"; _mm="$(printf '%s' "$_v" | grep -oE '^[0-9]+\.[0-9]+' || true)"
  [[ -n "$_mm" ]] && printf '%s\t%s\t%s\n' "$_dr" "$_mm" "reference core $_v" >> "$DOCROOTS"
done
# attr_params <attribute FQCN> <since|-> -> writes $PARAMS_DIR/<key>.<n> (one
# per applicable docroot: the parameter list, `?` when unreadable) and prints
# nothing. Docroots below `since` never read the attribute and are left out.
attr_params() {
  local fq="$1" since="$2" key n=0 dr mm label
  key="$(php_scan_key "$fq")"
  [[ -e "$PARAMS_DIR/$key.done" ]] && return 0
  while IFS=$'\t' read -r dr mm label; do
    [[ -n "$dr" ]] || continue
    n=$((n + 1))
    if [[ "$since" != "-" && -n "$since" ]] && ! mm_le "$since" "$mm"; then continue; fi
    (
      PHPSCAN_DIR="$TMPD/scan-$n"; PHPSCAN_DOCROOT="$dr"
      mkdir -p "$PHPSCAN_DIR/ext" "$PHPSCAN_DIR/memo"; : > "$PHPSCAN_DIR/index.tsv"
      [[ -s "$PHPSCAN_DIR/extmap.tsv" ]] || php_scan_extmap "$SUBJECT_ABS"
      { printf '#%s\n' "$label"; php_ctor_params "$fq"; } > "$PARAMS_DIR/$key.$n"
      # Whether the class ships with core (core/lib or core/modules) in the
      # test-bed: only then must a reference core be able to read it too.
      if [[ "$label" == test-bed* ]]; then
        _cf="$(php_class_file "$fq")"
        case "$_cf" in "$dr"/core/*) : > "$PARAMS_DIR/$key.incore";; esac
      fi
    )
  done < "$DOCROOTS"
  : > "$PARAMS_DIR/$key.done"
  return 0
}
# rejected_keys <file> <annotation> <attribute FQCN> <since|-> -> one line per
# annotation key an applicable core's constructor rejects ("key<TAB>core"), or
# "?<TAB>core" when that core's attribute class cannot be read. A reference
# core holds core only: a contrib or custom attribute class (not under the
# test-bed's core/ tree) is absent there by design, so its `?` does not apply.
rejected_keys() {
  local f="$1" ann="$2" fq="$3" since="$4" keys pf label key incore=0
  attr_params "$fq" "$since"
  keys="$(php_annotation_keys "$f" "$ann")"
  key="$(php_scan_key "$fq")"
  [[ -e "$PARAMS_DIR/$key.incore" ]] && incore=1
  for pf in "$PARAMS_DIR/$key".[0-9]*; do
    [[ -f "$pf" ]] || continue
    label="$(head -n 1 "$pf")"; label="${label#\#}"
    if grep -qx '?' "$pf"; then
      [[ "$label" == reference* && "$incore" == "0" ]] && continue
      printf '?\t%s\n' "$label"; continue
    fi
    grep -q '^\.\.\.' "$pf" && continue
    [[ -n "$keys" ]] || continue
    printf '%s\n' "$keys" | while IFS= read -r k; do
      [[ -n "$k" ]] || continue
      grep -qxF "$k" "$pf" || printf '%s\t%s\n' "$k" "$label"
    done
  done
  return 0
}
# Files carrying a converted annotation, and those to skip: a short-named
# attribute with the type's short name already present (the rule matches on
# the short name and could skip the real conversion), or an annotation key the
# attribute constructor rejects.
CAND="$TMPD/cand.txt"; : > "$CAND"
SKIPPED_JSON="[]"; SKIP_LINES=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  skip_reason=""
  while IFS=$'\t' read -r ann attr since action; do
    awk -F '\t' -v f="$f" -v a="$ann" '$1 == "TAG" && $2 == f && $3 == a { found = 1 } END { exit !found }' "$SCAN" || continue
    rej="$(rejected_keys "$f" "$ann" "$attr" "$since")"
    if [[ -n "$rej" ]]; then
      if printf '%s\n' "$rej" | grep -q '^?'; then
        skip_reason="the constructor of $attr could not be read ($(printf '%s\n' "$rej" | awk -F '\t' '$1 == "?" { print $2; exit }')), so its accepted arguments are unknown: annotation kept"
      else
        skip_reason="@$ann key(s) $(printf '%s\n' "$rej" | cut -f1 | sort -u | paste -sd, - | sed 's/,/, /g') have no parameter in $attr::__construct() ($(printf '%s\n' "$rej" | cut -f2 | sort -u | paste -sd, - | sed 's/,/, /g')): the attribute would fatal with 'Unknown named parameter' when the plugin is discovered. The annotation is kept, as Drupal core does for such plugins"
      fi
      break
    fi
    short="${attr##*\\}"
    # The FQCN goes through ENVIRON: awk -v would interpret its backslashes.
    if AWKV_fq="\\$attr" awk -F '\t' -v f="$f" -v s="$short" '
         $1 == "ATTR" && $2 == f { n = split($3, p, "\\"); if (p[n] == s && $3 != ENVIRON["AWKV_fq"]) bad = 1 }
         END { exit !bad }' "$SCAN"; then
      skip_reason="already has a non fully-qualified #[$short] attribute (the rule could take it for the converted one): finish it by hand"
    fi
  done < "$ACTIVE"
  if [[ -n "$skip_reason" ]]; then
    log_warn "Skipping $f: $skip_reason."
    SKIPPED_JSON="$(printf '%s' "$SKIPPED_JSON" | jq -c --arg f "$f" --arg r "$skip_reason" '. + [{file:$f, reason:$r}]')"
    SKIP_LINES="${SKIP_LINES}    \$drupilotRoot . '/$(printf '%s' "$f" | sed "s/'/\\\\'/g")',
"
  else
    printf '%s\n' "$f" >> "$CAND"
  fi
done < <(awk -F '\t' 'NR == FNR { act[$1] = 1; next } $1 == "TAG" && ($3 in act) { print $2 }' "$ACTIVE" "$SCAN" | sort -u)

# floor_from <file-list> <reason> -> sets ATTR_FLOOR, FLOOR_OK, REC_REQ and the
# per-type converted_files of TYPES_JSON from the files still converted (one
# per line). The floor counts only the types that still have a file there; a
# type left with none becomes "skipped" with <reason>.
floor_from() {
  local list="$1" why="$2" ann attr since action
  ATTR_FLOOR=""
  while IFS=$'\t' read -r ann attr since action; do
    [[ "$since" == "-" ]] && continue
    if awk -F '\t' -v a="$ann" 'NR == FNR { c[$0] = 1; next } $1 == "TAG" && $3 == a && ($2 in c) { found = 1 } END { exit !found }' "$list" "$SCAN"; then
      if [[ -z "$ATTR_FLOOR" ]] || ! mm_le "$since" "$ATTR_FLOOR"; then ATTR_FLOOR="$since"; fi
    fi
  done < "$ACTIVE"
  # Per type: how many files are still converted (0 = every file was skipped).
  TYPES_JSON="$(printf '%s' "$TYPES_JSON" | jq -c --rawfile cand "$list" --rawfile scan "$SCAN" --arg why "$why" '
    ($cand | split("\n") | map(select(length > 0))) as $c
    | ($scan | split("\n") | map(split("\t")) | map(select(.[0] == "TAG" and (.[1] as $f | any($c[]; . == $f))))) as $t
    | map(. as $ty | ($t | map(select(.[2] == $ty.annotation) | .[1]) | unique | length) as $n
          | if .action == "skipped" then . + {converted_files: 0}
            elif $n == 0 then . + {converted_files: 0, action: "skipped", reason: (.reason // $why)}
            else . + {converted_files: $n} end)')"
  FLOOR_OK="true"
  if [[ -n "$ATTR_FLOOR" ]]; then
    if [[ -z "$DECLARED_FLOOR" ]] || ! mm_le "$ATTR_FLOOR" "$DECLARED_FLOOR"; then FLOOR_OK="false"; fi
  fi
  REC_REQ="$DECLARED_REQ"
  if [[ "$FLOOR_OK" == "false" ]]; then REC_REQ="$(core_requirement_raise_floor "$DECLARED_REQ" "$ATTR_FLOOR")"; fi
  return 0
}
floor_from "$CAND" "every file of this type was skipped (see skipped_files)"

# emit_json <status> <files-text> <count> <restored-json> <qualified> <raised> <errors-json>
emit_json() {
  local files_json
  files_json="$(printf '%s\n' "$2" | jq -R . | jq -s -c 'map(select(length > 0))')"
  jq -n --arg st "$1" --argjson files "$files_json" --argjson n "$3" --argjson rest "$4" \
    --argjson q "$5" --argjson raised "$6" --argjson errs "$7" \
    --argjson applied "$([[ "$APPLY" == "1" ]] && echo true || echo false)" \
    --arg mode "$MODE" --arg cv "$CORE_VER" --arg dr "$DECLARED_REQ" --arg df "$DECLARED_FLOOR" \
    --arg af "$ATTR_FLOOR" --argjson fok "$FLOOR_OK" --arg rr "$REC_REQ" --arg ps "${PS_STATUS:-}" \
    --argjson types "$TYPES_JSON" --argjson skipped "$SKIPPED_JSON" \
    '{tool:"attributes", status:$st, ok:($st != "error"), applied:$applied, mode:$mode,
      core_version:$cv,
      declared_requirement:(if $dr == "" then null else $dr end),
      declared_floor:(if $df == "" then null else $df end),
      attribute_floor:(if $af == "" then null else $af end),
      floor_ok:$fok, recommended_requirement:(if $rr == "" then null else $rr end),
      floor_raised:$raised, types:$types, files:$files, changed_files:$n,
      skipped_files:$skipped, restored_files:$rest, qualified_constants:$q,
      phpstan_check:(if $ps == "" then null else $ps end),
      rule_hits:(if $n > 0 then {attributes:{AnnotationToAttributeRector:$n}} else {} end),
      errors:$errs}'
}

if [[ ! -s "$CAND" ]]; then
  log_ok "Nothing to convert: no plugin annotation of a supported type in $SUBJECT_REL."
  [[ "$AS_JSON" == "1" ]] && emit_json noop "" 0 '[]' 0 false '[]'
  exit 0
fi

# --- Render the config ----------------------------------------------------------
CFG_DIR="$DRUPAL_ROOT/.drupilot"
mkdir -p "$CFG_DIR" || die "Cannot create $CFG_DIR." 1
CFG="$CFG_DIR/rector-attributes.php"
render_template "$(plugin_root)/templates/rector-attributes.php.tmpl" "$CFG" \
  "SUBJECT_PATH=$SUBJECT_REL" "SKIP_FILES=${SKIP_LINES%$'\n'}" "ATTRIBUTE_CONFIGS=${CONFIG_LINES%$'\n'}" \
  || die "Could not render the attributes Rector config." 1
log_info "Config      : ${CFG#"$DRUPAL_ROOT"/} ($(grep -c . "$ACTIVE" || true) type(s), $(grep -c . "$CAND" || true) file(s))"

ddev_ensure_running_or_host "$DRUPAL_ROOT" rector \
  || die "Could not start the DDEV project at $DRUPAL_ROOT, and there is no host vendor/bin/rector to fall back to." 2
RUNNER="$(drupal_runner "$DRUPAL_ROOT")"
declare -a RUN=()
[[ -n "$RUNNER" ]] && read -r -a RUN <<<"$RUNNER"

# Back up the candidates before writing anything.
if [[ "$APPLY" == "1" ]]; then
  while IFS= read -r f; do
    mkdir -p "$TMPD/backup/$(dirname "$f")" && cp -p "$f" "$TMPD/backup/$f"
  done < "$CAND"
fi

declare -a CMD=()
[[ ${#RUN[@]} -gt 0 ]] && CMD=("${RUN[@]}")
# --clear-cache: Rector caches the files it found unchanged without keying the
# cache on this config's rule options, so a run after a different --mode /
# --max-since would silently skip a file an earlier run left alone.
CMD+=(vendor/bin/rector process --config .drupilot/rector-attributes.php --no-progress-bar --clear-cache)
[[ "$APPLY" == "1" ]] || CMD+=(--dry-run)
hr
log_step "Rector (annotations -> attributes): ${CMD[*]}"
RC=0
RAW="$("${CMD[@]}" 2>&1)" || RC=$?
if [[ "$RC" != "0" && -n "$RUNNER" ]] && rector_output_ok "$RC" "$RAW"; then
  RAW="$(printf '%s\n' "$RAW" | grep -vE 'Failed to execute command .*: exit status [0-9]+' || true)"
fi
printf '%s\n' "$RAW" >&2
CHANGED="$(printf '%s\n' "$RAW" \
  | grep -oE '[0-9]+\) [^[:space:]]+\.php' | sed -E 's/^[0-9]+\) //' \
  | sed -e "s#^/var/www/html/##" -e "s#^$DRUPAL_ROOT/##" | sort -u || true)"
if ! rector_output_ok "$RC" "$RAW"; then
  MSG="$(rector_error_excerpt "$RAW")"
  log_err "The attributes pass CRASHED (exit $RC) — no verdict:"
  printf '%s\n' "$MSG" | sed 's/^/     /' >&2
  if [[ "$APPLY" == "1" ]]; then
    while IFS= read -r f; do cp -p "$TMPD/backup/$f" "$f" 2>/dev/null || true; done < "$CAND"
    log_warn "Restored the candidate files from the pre-run backup."
  fi
  [[ "$AS_JSON" == "1" ]] && emit_json error "" 0 '[]' 0 false \
    "$(jq -nc --argjson rc "$RC" --arg m "$MSG" '[{exit_code:$rc, message:$m}]')"
  exit 3
fi

RESTORED_JSON="[]"; QUALIFIED=0; RAISED=false; PS_STATUS=""
if [[ "$APPLY" == "1" && -n "$CHANGED" ]]; then
  ATTR_LIST="$(cut -f2 "$ACTIVE" | tr '\n' ' ')"
  restore() {
    cp -p "$TMPD/backup/$1" "$1" 2>/dev/null || true
    RESTORED_JSON="$(printf '%s' "$RESTORED_JSON" | jq -c --arg f "$1" --arg r "$2" '. + [{file:$f, reason:$r}]')"
    log_err "Restored $1: $2."
  }
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    # 1) Fully qualify `Name\Space\Class::CONST` in the generated attributes.
    AWKV_attrs="$ATTR_LIST" awk '
      BEGIN { n = split(ENVIRON["AWKV_attrs"], at, " ") }
      function gen(line,   i) { for (i = 1; i <= n; i++) if (index(line, "#[\\" at[i] "(") > 0) return 1; return 0 }
      {
        line = $0
        if (!inattr && gen(line)) inattr = 1
        if (inattr) {
          res = ""
          while (match(line, /[(, [][A-Za-z_][A-Za-z0-9_]*\\[A-Za-z0-9_\\]*::/)) {
            res = res substr(line, 1, RSTART) "\\" substr(line, RSTART + 1, RLENGTH - 1)
            line = substr(line, RSTART + RLENGTH); fixed++
          }
          line = res line
          if ($0 ~ /\)\][ \t]*$/) inattr = 0
        }
        print line
      }
      END { print fixed + 0 > "/dev/stderr" }' "$f" > "$TMPD/q.php" 2>"$TMPD/q.n" || true
    q="$(head -n1 "$TMPD/q.n" 2>/dev/null | tr -cd '0-9')"
    if [[ "${q:-0}" != "0" ]]; then
      cat "$TMPD/q.php" > "$f"
      QUALIFIED=$((QUALIFIED + q))
      log_info "Fully qualified $q class-constant reference(s) in $f."
    fi
    # 2) No duplicate attribute of a converted type.
    dup=""
    while IFS=$'\t' read -r ann attr since action; do
      short="${attr##*\\}"
      c="$(grep -cE "^[[:space:]]*#\[[[:space:]]*(\\\\?[A-Za-z0-9_\\\\]*\\\\)?${short}[[:space:]]*\(" "$f" || true)"
      if [[ "${c:-0}" -gt 1 ]]; then dup="$short"; break; fi
    done < "$ACTIVE"
    if [[ -n "$dup" ]]; then restore "$f" "duplicate #[$dup] attribute after the pass"; continue; fi
    # 2b) No annotation removed without its attribute (the rule takes any
    #     attribute with the type's short name for the converted one).
    lost=""
    while IFS=$'\t' read -r ann attr since action; do
      grep -qE "^[[:space:]]*\*[[:space:]]*@${ann}[[:space:]]*\(" "$TMPD/backup/$f" 2>/dev/null || continue
      grep -qE "^[[:space:]]*\*[[:space:]]*@${ann}[[:space:]]*\(" "$f" && continue
      grep -qF "#[\\${attr}(" "$f" && continue
      lost="$ann"; break
    done < "$ACTIVE"
    if [[ -n "$lost" ]]; then restore "$f" "the @$lost annotation was removed but no attribute was added"; continue; fi
    # 3) It must still parse. (stdin from /dev/null: `ddev exec` would eat the file list.)
    if ! "${RUN[@]+"${RUN[@]}"}" php -l "$f" </dev/null >/dev/null 2>&1; then
      restore "$f" "php -l failed after the pass"; continue
    fi
  done <<<"$CHANGED"
  if [[ "$RESTORED_JSON" != "[]" ]]; then
    CHANGED="$(printf '%s\n' "$CHANGED" | grep -vxF -f <(printf '%s' "$RESTORED_JSON" | jq -r '.[].file') || true)"
  fi
  # 4) The attributes must be instantiable: `php -l` does not check an
  # attribute's arguments against its constructor, PHPStan does (level 0 already
  # reports "Unknown parameter $x in call to <Attribute> constructor" and an
  # unknown attribute class). Only findings that name a converted attribute
  # class restore a file; any other finding is pre-existing and left to the
  # validate loop.
  if [[ -n "$CHANGED" ]]; then
    if [[ -f "$DRUPAL_ROOT/vendor/bin/phpstan" ]]; then
      declare -a PS=()
      [[ ${#RUN[@]} -gt 0 ]] && PS=("${RUN[@]}")
      PS+=(vendor/bin/phpstan analyse --no-progress --level 0 --error-format=json)
      if [[ -f phpstan.neon ]]; then PS+=(--configuration phpstan.neon)
      elif [[ -f phpstan.neon.dist ]]; then PS+=(--configuration phpstan.neon.dist); fi
      while IFS= read -r f; do [[ -n "$f" ]] && PS+=("$f"); done <<<"$CHANGED"
      log_step "PHPStan (level 0) on the converted files: the attribute arguments must match the constructors."
      PS_OUT="$("${PS[@]}" </dev/null 2>/dev/null || true)"
      PS_JSON="$(printf '%s\n' "$PS_OUT" | sed -n '/^{/,$p' | jq -c . 2>/dev/null || true)"
      if [[ -z "$PS_JSON" ]] || ! printf '%s' "$PS_JSON" | jq -e '.files' >/dev/null 2>&1; then
        PS_STATUS="crashed"
        log_warn "PHPStan produced no report on the converted files: the attribute arguments are NOT verified. Run run-phpstan.sh (or the validate loop) before relying on them."
      else
        PS_STATUS="ok"
        BAD="$(printf '%s' "$PS_JSON" | AWKV_attrs="$ATTR_LIST" jq -r --arg root "$DRUPAL_ROOT/" '
          (env.AWKV_attrs | split(" ") | map(select(length > 0))) as $a
          | .files | to_entries[] | .key as $k | .value.messages[]
          | select(.message as $m | any($a[]; . as $x | $m | contains($x)))
          | [($k | ltrimstr("/var/www/html/") | ltrimstr($root)),
             "line \(.line): \(.message)"] | join("\t")' 2>/dev/null || true)"
        if [[ -n "$BAD" ]]; then
          while IFS=$'\t' read -r bf bm; do
            [[ -n "$bf" ]] || continue
            printf '%s' "$RESTORED_JSON" | jq -e --arg f "$bf" 'any(.[]; .file == $f)' >/dev/null 2>&1 && continue
            restore "$bf" "PHPStan: $bm"
          done <<<"$BAD"
          CHANGED="$(printf '%s\n' "$CHANGED" | grep -vxF -f <(printf '%s' "$RESTORED_JSON" | jq -r '.[].file') || true)"
        else
          log_ok "PHPStan: every converted attribute matches its constructor."
        fi
      fi
    else
      PS_STATUS="unavailable"
      log_warn "vendor/bin/phpstan is missing: the attribute arguments of the converted files are NOT verified (php -l does not check them)."
    fi
  fi
  # A restored file no longer carries an attribute: recompute the floor (and
  # converted_files) from the files still converted, so --raise-floor never
  # declares a core floor for a type the code no longer uses.
  if [[ "$RESTORED_JSON" != "[]" ]]; then
    grep -vxF -f <(printf '%s' "$RESTORED_JSON" | jq -r '.[].file') "$CAND" > "$TMPD/kept.txt" || true
    floor_from "$TMPD/kept.txt" "every file of this type was skipped or restored (see skipped_files, restored_files)"
  fi
  # 5) Raise the declared floor when asked and needed.
  if [[ "$RAISE" == "1" && "$FLOOR_OK" == "false" && -n "$REC_REQ" ]]; then
    log_step "Raising core_version_requirement to '$REC_REQ' (attributes need core >= $ATTR_FLOOR)."
    if bash "$(plugin_root)/scripts/analysis/set-core-requirement.sh" --subject "$SUBJECT_ABS" --requirement "$REC_REQ" >/dev/null; then
      RAISED=true; FLOOR_OK="true"
    else
      log_err "set-core-requirement.sh failed; raise core_version_requirement to '$REC_REQ' by hand."
    fi
  fi
fi

COUNT=0
[[ -n "$CHANGED" ]] && COUNT="$(printf '%s\n' "$CHANGED" | grep -c . || true)"
hr
if [[ "$APPLY" == "1" ]]; then
  log_ok "Attributes pass applied: $COUNT file(s) changed ($MODE mode)."
else
  log_ok "Attributes dry-run: $COUNT file(s) would change ($MODE mode). Re-run with --apply after reviewing the diff."
  if printf '%s\n' "$RAW" | grep -E '^\+#\[' | grep -qE '[(, ][A-Za-z_][A-Za-z0-9_]*\\[A-Za-z0-9_\\]*::'; then
    log_info "Class constants named relative to the annotation's namespace are fully qualified on --apply."
  fi
fi
if [[ -n "$ATTR_FLOOR" ]]; then
  if [[ "$FLOOR_OK" == "true" ]]; then
    log_ok "Core floor: the attributes need core >= $ATTR_FLOOR; the declared requirement covers it."
  elif [[ "$MODE" == "keep" ]]; then
    log_warn "Core floor: the attribute classes exist only from core $ATTR_FLOOR, below which PHPStan reports them as unknown"
    log_warn "(runtime is unaffected: older cores read the kept annotation). Declare '$REC_REQ' (--raise-floor) to make the floor honest."
  else
    log_warn "Core floor: types above the declared floor ${DECLARED_FLOOR:-unknown} kept their annotation. '--raise-floor' strips them and declares '$REC_REQ' (a BC break)."
  fi
fi

if [[ "$AS_JSON" == "1" ]]; then
  emit_json ok "$CHANGED" "$COUNT" "$RESTORED_JSON" "$QUALIFIED" "$RAISED" '[]'
elif [[ -n "$CHANGED" ]]; then
  printf '%s\n' "$CHANGED"
fi
exit 0
