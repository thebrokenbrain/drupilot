#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/scan-signature-changes.sh
# Flag the places where a module/theme collides with a Drupal 10 -> 11 core
# SIGNATURE change: a constructor that gained a required argument, a method core
# added later (so a same-named method in the module becomes an override, or a
# fatal when its signature differs), a hook whose implementations may now get an
# extra argument, an API that exists only from a given minor. No analyzer in the
# validate loop reports these: Rector and PHPStan only see the ONE core installed
# in the sandbox, while the module declares a range of cores.
#
# Data-driven: the catalog is `.signature_changes` in config/deprecations.json
# (every entry verified against core source; see its _signature_changes_comment).
# Each finding is judged against the declared core FLOOR (the lowest core the
# constraint admits) and the Drupal 11 port target (the range always reaches the
# newest 11.x): e.g. a required 2nd hook_entity_operation parameter is fine for
# a ^11.3 floor and an ArgumentCountError for ^10 || ^11.
#
# Read-only, ungated, no toolchain (bash + awk + jq), like detect-php-floor.sh.
# Ancestry is read from the Drupal root when the subject sits in one (core +
# contrib + the subject), else from each entry's verified known_descendants;
# an unresolvable ancestry is never guessed (no finding).
#
# Usage:
#   scan-signature-changes.sh --subject DIR [--core-req STR] [--core-floor X.Y]
#                             [--drupal-root DIR] [--json] [-h|--help]
#
# Options:
#   --subject DIR      The module/theme directory. Required.
#   --core-req STR     Core constraint to judge against (default: the subject's
#                      core_version_requirement).
#   --core-floor X.Y   The lowest core to keep supporting, overriding the floor
#                      derived from the constraint (e.g. assessing a ^9.2 || ^10
#                      module that will be ported as ^10.3 || ^11: 10.3).
#   --drupal-root DIR  Drupal root used to resolve ancestors (default: found by
#                      walking up from the subject).
#   --json             Print a JSON report on STDOUT instead of tagged lines:
#                      {tool, subject, drupal_root, core_requirement, core_floor,
#                       ok, errors, warnings, infos,
#                       findings:[{id, kind, severity, file, line, class, member,
#                                  since, message, fix, d10_compat,
#                                  change_record}]}
#   -h, --help         Show this help.
#
# Severities: error = breaks a core inside the declared range (fatal or
# ArgumentCountError) · warn = works, but needs a decision (a module method that
# becomes an override of core on newer cores, an API call the floor may lack) ·
# info = touches a changed signature safely (e.g. a one-parameter
# hook_entity_operation: never make the new parameter required).
#
# Output: without --json, one line per finding on STDOUT:
#   [signature:<id>] severity file:line message
# (the shape explain-deprecations.sh annotates when teed into change-log.txt).
# Logs and the summary go to STDERR.
#
# Exit codes: 0 no error findings · 1 usage error · 3 at least one error finding.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/php-scan.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/php-scan.sh"

SUBJECT=""
CORE_REQ=""
FLOOR_OPT=""
ROOT_OPT=""
AS_JSON=0

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --core-req) CORE_REQ="${2:-}"; shift 2;;
    --core-req=*) CORE_REQ="${1#*=}"; shift;;
    --core-floor) FLOOR_OPT="${2:-}"; shift 2;;
    --core-floor=*) FLOOR_OPT="${1#*=}"; shift;;
    --drupal-root) ROOT_OPT="${2:-}"; shift 2;;
    --drupal-root=*) ROOT_OPT="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_err "Unknown argument: $1"; usage >&2; exit 1;;
  esac
done

[[ -n "$SUBJECT" ]] || die "Missing --subject DIR (the module/theme to scan)." 1
case "$SUBJECT" in *"<"*">"*) die "--subject looks like an unsubstituted placeholder: '$SUBJECT'." 1;; esac
SUBJECT_LOGICAL="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
[[ -n "$SUBJECT_LOGICAL" && -d "$SUBJECT_LOGICAL" ]] || die "Subject directory not found: '$SUBJECT'." 1
SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd -P || true)"
[[ -n "$SUBJECT_ABS" ]] || SUBJECT_ABS="$SUBJECT_LOGICAL"
if [[ -n "$FLOOR_OPT" ]] && ! printf '%s' "$FLOOR_OPT" | grep_q -E '^[0-9]+(\.[0-9]+)?$'; then
  die "--core-floor must be MAJOR.MINOR (e.g. 10.3), got '$FLOOR_OPT'." 1
fi
have_cmd jq || die "jq is required for scan-signature-changes.sh." 1
CATALOG="$(plugin_root)/config/deprecations.json"
[[ -f "$CATALOG" ]] || die "Missing $CATALOG." 1
SEARCH_URL="$(jq -r '.change_records_search // ""' "$CATALOG")"

# --- Drupal root / docroot -----------------------------------------------------
DRUPAL_ROOT=""
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

# --- Core range ------------------------------------------------------------------
if [[ -z "$CORE_REQ" ]]; then CORE_REQ="$(subject_core_requirement "$SUBJECT_ABS" 2>/dev/null || true)"; fi
CORE_REQ="$(printf '%s' "$CORE_REQ" | tr -d "\"'")"
if [[ -n "$FLOOR_OPT" ]]; then
  FLOOR="$FLOOR_OPT"
else
  FLOOR="$(core_floor_from_requirement "$CORE_REQ")"
fi
# floor_below SINCE -> 0 when the floor is below SINCE (an unknown floor counts
# as below: without a declared range nothing proves the older cores are gone).
floor_below() {
  [[ -n "$FLOOR" ]] || return 0
  if version_ge "$FLOOR" "$1"; then return 1; fi
  return 0
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-sigscan.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
: > "$TMP/findings.tsv"

# --- Catalog -> TSV ----------------------------------------------------------------
jq -r '.signature_changes[] | [.id, .kind, .target, (.method // ""), .since, (.min_args // 0),
        (.signature.visibility // ""), ((.signature.static // false) | tostring),
        (.signature.params // .params // 0), (.signature.required // 0), ((.signature.returns // []) | join(",")),
        (.params_before // 0), (.pattern // ""), (.guard // "")] | map(tostring) | join("\u001f")' "$CATALOG" > "$TMP/catalog.tsv"
# Verified ancestry used when no Drupal root can be read.
jq -r '.signature_changes[] | .target as $t | (.known_descendants // [])[] | [$t, "yes", .] | join("\t")' \
  "$CATALOG" | LC_ALL=C sort -u > "$TMP/fallback.tsv"
cat_field() {  # cat_field ID JQ-FIELD -> a catalog text field
  jq -r --arg id "$1" ".signature_changes[] | select(.id == \$id) | ($2 // \"\")" "$CATALOG"
}

# --- Scan the subject ----------------------------------------------------------------
PHPSCAN_DIR="$TMP"
PHPSCAN_DOCROOT="$DOCROOT"
FILES="$TMP/files.txt"
find "$SUBJECT_ABS" -type f \( -name '*.php' -o -name '*.module' -o -name '*.inc' -o -name '*.install' \
  -o -name '*.theme' -o -name '*.profile' -o -name '*.engine' \) \
  -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null \
  | LC_ALL=C sort > "$FILES"
php_scan_index "$FILES"
php_scan_extmap "$SUBJECT_ABS"
SCANNED="$(wc -l < "$FILES" | tr -d ' ')"
# The subject's own extensions (machine names), for hook function names.
EXTS="$(find "$SUBJECT_ABS" -name '*.info.yml' -not -path '*/vendor/*' -not -path '*/node_modules/*' 2>/dev/null \
  | while IFS= read -r i; do basename "$i" .info.yml; done | LC_ALL=C sort -u)"

rel() { local p="$1"; p="${p#"$SUBJECT_ABS"/}"; printf '%s' "$p"; }
# A tab is IFS whitespace, so `read` would merge empty TSV fields; records are
# re-joined with the US control character before they are read.
US=$'\037'
records() {  # records SCANFILE TYPE... -> the matching records, US-separated
  local f="$1"; shift
  AWKV_t=" $* " awk -F'\t' 'BEGIN { t = ENVIRON["AWKV_t"]; OFS = "\037" } index(t, " " $1 " ") > 0 { $1 = $1; print }' "$f"
  return 0
}
# add_finding ID KIND SEVERITY FILE LINE CLASS MEMBER SINCE MESSAGE
add_finding() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(rel "$4")" "$5" "$6" "$7" "$8" "$9" >> "$TMP/findings.tsv"
  return 0
}
floor_label() { if [[ -n "$FLOOR" ]]; then printf '%s' "$FLOOR"; else printf 'unknown'; fi; }
norm_type() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^\\//'; }

while IFS="$US" read -r id kind target method since min_args vis static params required returns pbefore pattern guard; do
  [[ -n "$id" ]] || continue
  case "$kind" in
    constructor-arity)
      n=0
      while IFS= read -r f; do
        n=$((n + 1)); s="$TMP/scan/$n.tsv"
        while IFS="$US" read -r _ _ _ cls _ parent _; do
          # Only a DIRECT subclass: its parent::__construct() is the target's.
          [[ "$parent" == "$target" ]] || continue
          sigl="$(AWKV_q="$cls" AWKV_m="$method" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"]; m = ENVIRON["AWKV_m"] } $1 == "SIG" && $3 == q && tolower($4) == tolower(m) { print $2; exit }' "$s")"
          [[ -n "$sigl" ]] || continue   # inherits the core constructor: fine
          pc="$(AWKV_q="$cls" AWKV_m="$method" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"]; m = ENVIRON["AWKV_m"] } $1 == "PCALL" && $3 == q && tolower($4) == tolower(m) && tolower($5) == tolower(m) { print $2 "\t" $6; exit }' "$s")"
          short="${target##*\\}"
          if [[ -z "$pc" ]]; then
            add_finding "$id" "$kind" warn "$f" "$sigl" "$cls" "$method" "$since" \
              "${cls##*\\}::__construct() never calls parent::__construct(): the ${min_args}-argument ${short} constructor (required from $(cat_field "$id" .required_in)) does not run, so its promoted properties stay uninitialized. Verify, or call the parent with all ${min_args} arguments."
            continue
          fi
          pline="${pc%%$'\t'*}"; nargs="${pc#*$'\t'}"
          [[ "$nargs" == "?" ]] && continue   # unpacked arguments: cannot count
          if (( nargs < min_args )); then
            add_finding "$id" "$kind" error "$f" "$pline" "$cls" "$method" "$since" \
              "${cls##*\\}::__construct() passes ${nargs} argument(s) to ${short}::__construct(), which requires ${min_args} from Drupal $(cat_field "$id" .required_in): ArgumentCountError on Drupal 11."
          fi
        done < <(records "$s" CLASS | awk -F"$US" '$3 == "class"')
      done < "$FILES"
      ;;

    method-signature)
      n=0
      while IFS= read -r f; do
        n=$((n + 1)); s="$TMP/scan/$n.tsv"
        while IFS="$US" read -r _ mline cls mname mvis mstatic mn mreq mret; do
          [[ "$(lc "$mname")" == "$(lc "$method")" ]] || continue
          [[ "$cls" != "$target" ]] || continue
          r="$(php_chain_has "$cls" "$target")"
          if [[ "$r" == "unknown" ]]; then
            add_finding "$id" "$kind" warn "$f" "$mline" "$cls" "$method" "$since" \
              "${cls##*\\}::${mname}() may collide with core's ${target##*\\}::${method}() (added in ${since}), but the ancestry ($(php_first_parent "$cls")) could not be resolved here: verify."
            continue
          fi
          [[ "$r" == "yes" ]] || continue
          # Compatibility with the core declaration (PHP inheritance rules).
          bad=""
          case "$vis:$mvis" in
            public:protected|public:private|protected:private) bad="visibility ${mvis} (core: ${vis})";; esac
          cstatic=0; [[ "$static" == "true" ]] && cstatic=1
          if [[ "$mstatic" != "$cstatic" ]]; then bad="${bad:+$bad; }static mismatch"; fi
          if (( mn < params )); then bad="${bad:+$bad; }${mn} parameter(s) (core: ${params})"; fi
          if (( mreq > required )); then bad="${bad:+$bad; }${mreq} required parameter(s) (core: ${required})"; fi
          okret=0
          if [[ -n "$returns" ]]; then
            for rt in $(printf '%s' "$returns" | tr ',' ' '); do
              if [[ "$(norm_type "$mret")" == "$(norm_type "$rt")" ]]; then okret=1; fi
            done
            if [[ "$okret" == "0" ]]; then bad="${bad:+$bad; }return type '${mret:-none}' (core: ${returns//,/ or })"; fi
          fi
          # An #[\Override] attribute right above the method (<= 3 lines).
          ovr="$(AWKV_q="$cls" AWKV_l="$mline" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"]; l = ENVIRON["AWKV_l"] + 0 } $1 == "OVERRIDE" && $3 == q && $2 < l && $2 >= l - 3 { print $2; exit }' "$s")"
          if [[ -n "$bad" ]]; then
            add_finding "$id" "$kind" error "$f" "$mline" "$cls" "$method" "$since" \
              "${cls##*\\}::${mname}() collides with core's ${target##*\\}::${method}() added in Drupal ${since} and is incompatible (${bad}): a fatal 'Declaration must be compatible' when the class loads on ${since}+."
          elif [[ -n "$ovr" ]] && floor_below "$since"; then
            add_finding "$id" "$kind" error "$f" "$ovr" "$cls" "$method" "$since" \
              "#[\\Override] on ${cls##*\\}::${mname}() while the core floor ($(floor_label)) is below ${since}, where core has no ${method}(): a compile-time fatal on PHP 8.3+ with those cores. Remove the attribute while the floor is below ${since}."
          elif floor_below "$since"; then
            add_finding "$id" "$kind" warn "$f" "$mline" "$cls" "$method" "$since" \
              "${cls##*\\}::${mname}() is a module method below Drupal ${since} and silently OVERRIDES core's ${target##*\\}::${method}() from ${since} (core calls it). Rename it unless that override is intended; never mark it with the Override attribute while the floor ($(floor_label)) is below ${since}."
          else
            add_finding "$id" "$kind" info "$f" "$mline" "$cls" "$method" "$since" \
              "${cls##*\\}::${mname}() overrides core's ${target##*\\}::${method}() on every declared core (floor $(floor_label) >= ${since}); confirm it still does what core expects."
          fi
        done < <(records "$s" SIG)
      done < "$FILES"
      ;;

    hook-params)
      # Procedural implementations: <extension>_<hook>() outside classes, and
      # #[Hook('<hook>')] methods.
      n=0
      while IFS= read -r f; do
        n=$((n + 1)); s="$TMP/scan/$n.tsv"
        while IFS="$US" read -r rec line a b c d e; do
          if [[ "$rec" == "FUNC" ]]; then
            np="$b"; nreq="$c"; who="${a}()"
            match=0
            for ext in $EXTS; do if [[ "$a" == "${ext}_${target}" ]]; then match=1; fi; done
            [[ "$match" == "1" ]] || continue
          else
            [[ "$c" == "$target" ]] || continue
            np="$d"; nreq="$e"; short_cls="${a##*\\}"
            who="${short_cls}::${b}() with a Hook attribute"
          fi
          if (( nreq > pbefore )) && floor_below "$since"; then
            add_finding "$id" "$kind" error "$f" "$line" "" "hook_${target}" "$since" \
              "${who} requires ${nreq} parameters, but cores below ${since} pass only ${pbefore} (floor $(floor_label)): ArgumentCountError there. Make the extra parameter optional (?CacheableMetadata \$cacheability = NULL)."
          elif (( nreq > pbefore )); then
            add_finding "$id" "$kind" info "$f" "$line" "" "hook_${target}" "$since" \
              "${who} requires the parameter core passes from ${since}; every declared core (floor $(floor_label)) passes it."
          elif (( np > pbefore )); then
            add_finding "$id" "$kind" info "$f" "$line" "" "hook_${target}" "$since" \
              "${who} accepts the parameter core passes from ${since} as optional, so older cores keep working."
          elif floor_below "$since"; then
            add_finding "$id" "$kind" info "$f" "$line" "" "hook_${target}" "$since" \
              "${who} implements hook_${target}(), which core invokes with ${params} argument(s) from Drupal ${since}; the current ${np}-parameter form works on every core. If you accept the new parameter, keep it optional while the floor ($(floor_label)) is below ${since}."
          else
            add_finding "$id" "$kind" info "$f" "$line" "" "hook_${target}" "$since" \
              "${who} implements hook_${target}(); every declared core (floor $(floor_label)) passes ${params} argument(s), so the new parameter may be required."
          fi
        done < <(records "$s" FUNC HOOK)
      done < "$FILES"
      ;;

    symbol-min-core)
      [[ -n "$pattern" ]] || continue
      floor_below "$since" || continue
      while IFS= read -r f; do
        while IFS= read -r line; do
          [[ -n "$line" ]] || continue
          add_finding "$id" "$kind" warn "$f" "$line" "" "$target" "$since" \
            "${target} exists only from Drupal ${since}, below the core floor ($(floor_label)): a fatal on older cores unless the receiver is the module's own class. Guard it (DeprecationHelper::backwardsCompatibleCall) or raise the floor to ^${since}."
        done < <(AWKV_p="$pattern" AWKV_g="$guard" awk '
          BEGIN { p = ENVIRON["AWKV_p"]; g = ENVIRON["AWKV_g"] }
          { hist[NR] = $0 }
          /^[[:space:]]*(\*|\/\/|\/\*|#)/ { next }
          /function[[:space:]]+&?[[:space:]]*[A-Za-z_]/ { next }
          $0 ~ p {
            if (g != "") { for (j = NR; j >= NR - 5 && j > 0; j--) if (hist[j] ~ g) next }
            print NR
          }' "$f")
      done < "$FILES"
      ;;
  esac
done < "$TMP/catalog.tsv"

# --- Report ----------------------------------------------------------------------------
LC_ALL=C sort -t$'\t' -k4,4 -k5,5n -k1,1 -u "$TMP/findings.tsv" -o "$TMP/findings.tsv"
ERRORS="$(awk -F'\t' '$3 == "error"' "$TMP/findings.tsv" | wc -l | tr -d ' ')"
WARNINGS="$(awk -F'\t' '$3 == "warn"' "$TMP/findings.tsv" | wc -l | tr -d ' ')"
INFOS="$(awk -F'\t' '$3 == "info"' "$TMP/findings.tsv" | wc -l | tr -d ' ')"

log_info "Subject     : $SUBJECT_ABS ($SCANNED PHP file(s))"
log_info "Drupal root : ${DRUPAL_ROOT:-<none - ancestry from the catalog known_descendants>}"
log_info "Core range  : ${CORE_REQ:-<not declared>} (floor: $(floor_label))"

if [[ "$AS_JSON" == "1" ]]; then
  jq -n -c --rawfile f "$TMP/findings.tsv" --slurpfile cat "$CATALOG" \
    --arg subject "$SUBJECT_ABS" --arg root "$DRUPAL_ROOT" --arg core "$CORE_REQ" \
    --arg floor "$FLOOR" --arg search "$SEARCH_URL" '
    ($cat[0].signature_changes | map({key: .id, value: .}) | from_entries) as $c
    | ($f | split("\n") | map(select(length > 0) | split("\t")
        | {id: .[0], kind: .[1], severity: .[2], file: .[3], line: (.[4] | tonumber? // .[4]),
           class: (if .[5] == "" then null else .[5] end), member: .[6], since: .[7], message: .[8],
           fix: ($c[.[0]].fix // null), d10_compat: ($c[.[0]].d10_compat // null),
           change_record: (if $search != "" then $search + ($c[.[0]].symbol // .[0] | @uri) else null end)})) as $fs
    | {tool: "scan-signature-changes", subject: $subject,
       drupal_root: (if $root == "" then null else $root end),
       core_requirement: (if $core == "" then null else $core end),
       core_floor: (if $floor == "" then null else $floor end),
       ok: (($fs | map(select(.severity == "error")) | length) == 0),
       errors: ($fs | map(select(.severity == "error")) | length),
       warnings: ($fs | map(select(.severity == "warn")) | length),
       infos: ($fs | map(select(.severity == "info")) | length),
       findings: $fs}'
else
  awk -F'\t' '{ printf "[signature:%s] %s %s:%s %s\n", $1, $3, $4, $5, $9 }' "$TMP/findings.tsv"
fi

if [[ "$ERRORS" != "0" ]]; then
  log_err "Signature changes: $ERRORS error(s), $WARNINGS warning(s), $INFOS info. Fix the errors (see each entry's fix)."
  exit 3
fi
if [[ "$WARNINGS" != "0" ]]; then
  log_warn "Signature changes: 0 errors, $WARNINGS warning(s), $INFOS info to review."
else
  log_ok "Signature changes: no breaking collision ($INFOS info)."
fi
exit 0
