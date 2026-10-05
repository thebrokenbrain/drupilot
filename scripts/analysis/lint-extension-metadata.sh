#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/lint-extension-metadata.sh
# Pre-existing extension HYGIENE that no analyzer of the validate loop reports
# and that keeps turning up as "pre-existing bugs" in real ports: config
# without schema, a `configure:` route that does not exist, services.yml
# entries pointing at missing classes or passing the wrong number of
# arguments, submodules left on an obsolete core_version_requirement, and
# dependencies used but not declared. REPORT, never fix: in Phase 1 these are
# listed as pre-existing hygiene (the viability report, the port report), not
# changed (the one exception, a submodule's core_version_requirement, is bumped
# by the port itself with set-core-requirement.sh). Read-only, ungated, no
# toolchain needed (bash + awk + jq).
#
# Checks (--checks selects a subset; default all), for the subject and every
# extension nested in it (submodules; test modules only for submodule-core-req):
#   config-schema       config/install|optional/<machine>.*.yml with no
#                       matching key in the extension's config/schema/*.schema.yml
#                       (exact, or a trailing wildcard as core's
#                       TypedConfigManager::getFallbackName() resolves it). warn
#   plugin-schema       a Block / Condition / Filter / FieldFormatter /
#                       FieldWidget plugin with its own settings
#                       (defaultConfiguration(), defaultSettings(), a Filter's
#                       `settings`) and no block.settings.<id> /
#                       condition.plugin.<id> / filter_settings.<id> /
#                       field.formatter.settings.<id> / field.widget.settings.<id>
#                       schema: only core's generic fallback covers it. warn
#   configure-route     the info.yml `configure:` route is defined by no
#                       *.routing.yml of the set (core's ModulesListForm then
#                       silently drops the Configure link). warn; an `entity.*`
#                       route (dynamic) or one defined by another module: info
#   services-class      a services.yml class in the extension's own namespace
#                       whose src/ file does not exist (orphan service), or
#                       exists only with a different letter case (a fatal on
#                       case-sensitive filesystems). error
#   services-arity      `arguments:` count outside the class constructor's
#                       [required, total] parameters: fewer is an
#                       ArgumentCountError (error), more are silently ignored
#                       by PHP (warn). Skipped for autowire / parent / factory /
#                       abstract services and named arguments; a class with no
#                       own constructor is followed up its parents inside the
#                       subject, else reported as info (not checked)
#   submodule-core-req  a nested *.info.yml whose core_version_requirement does
#                       not admit Drupal 11 (warn: core marks it incompatible,
#                       it cannot be installed), is missing (error: core throws
#                       InfoParserException; `package: Testing` is exempt), or
#                       still lists Drupal 8/9 while admitting 11 (info)
#   undeclared-deps     a module used by the code (class, service, route,
#                       library, plugin, config dependency — see
#                       scripts/lib/ext-scan.sh) that is not in the info.yml
#                       `dependencies:` (warn, with the proposed entry; a use
#                       guarded by moduleExists()/config/optional/`@?`, or a
#                       plugin of the module's own type such as
#                       src/Plugin/migrate/: info; the always-enabled core
#                       modules system/user/path_alias are never reported)
#
# Usage:
#   lint-extension-metadata.sh --subject DIR [--json] [--checks LIST]
#                              [--set-dir DIR] [--core-dir PATH] [--no-write]
#                              [-h|--help]
#
# Options:
#   --subject DIR    The module/theme directory. Required.
#   --json           Print the JSON report on STDOUT instead of tagged lines.
#   --checks LIST    Comma-separated subset of the checks above.
#   --set-dir DIR    Other extensions whose services/routes/plugins resolve
#                    references (default: the subject's parent directory when
#                    it is a modules|themes|profiles/custom folder).
#   --core-dir PATH  A Drupal core directory (with modules/) to tell core
#                    modules apart (default: the Drupal root's, else a list).
#   --no-write       Do not save <state dir>/metadata-lint.json.
#   -h, --help       Show this help.
#
# JSON (--json):
#   {tool, subject, generated_at, checks_run:[...], subject_digest,
#    findings:[{check, severity: error|warn|info, extension, file, line,
#               message, suggestion}],
#    totals:{error, warn, info}}
# Without --json, one line per finding on STDOUT:
#   [check] severity file:line message
# The JSON is also saved to <state dir of the subject>/metadata-lint.json (read
# by port-report.sh). Logs and the summary go to STDERR.
#
# Exit codes: 0 always after a run (findings are data, never a gate) · 1 usage
# error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/php-scan.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/php-scan.sh"
# shellcheck source=../lib/ext-scan.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/ext-scan.sh"

ALL_CHECKS="config-schema plugin-schema configure-route services-class services-arity submodule-core-req undeclared-deps"
SUBJECT=""
AS_JSON=0
CHECKS=""
SET_DIR=""
CORE_DIR=""
WRITE=1

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    --checks) CHECKS="${2:-}"; shift 2 || die "--checks needs a value" 1;;
    --checks=*) CHECKS="${1#*=}"; shift;;
    --set-dir) SET_DIR="${2:-}"; shift 2 || die "--set-dir needs a value" 1;;
    --set-dir=*) SET_DIR="${1#*=}"; shift;;
    --core-dir) CORE_DIR="${2:-}"; shift 2 || die "--core-dir needs a value" 1;;
    --core-dir=*) CORE_DIR="${1#*=}"; shift;;
    --no-write) WRITE=0; shift;;
    -h|--help) usage; exit 0;;
    *) log_err "Unknown argument: $1"; usage >&2; exit 1;;
  esac
done

[[ -n "$SUBJECT" ]] || die "Missing --subject DIR (the module/theme to lint)." 1
case "$SUBJECT" in *"<"*">"*) die "--subject looks like an unsubstituted placeholder: '$SUBJECT'." 1;; esac
[[ -d "$SUBJECT" ]] || die "Subject directory not found: $SUBJECT" 1
have_cmd jq || die "jq is required for lint-extension-metadata.sh." 1
SUBJECT="$(cd "$SUBJECT" && pwd)"
is_drupal_extension_dir "$SUBJECT" || die "No *.info.yml in $SUBJECT: not a Drupal extension directory." 1
if [[ -n "$CHECKS" ]]; then
  for c in $(printf '%s' "$CHECKS" | tr ',' ' '); do
    case " $ALL_CHECKS " in *" $c "*) ;; *) die "Unknown check '$c' (known: $ALL_CHECKS)." 1;; esac
  done
else
  CHECKS="$ALL_CHECKS"
fi
check_on() { case ",$(printf '%s' "$CHECKS" | tr ' ' ','),"  in *",$1,"*) return 0;; esac; return 1; }

if [[ -z "$SET_DIR" ]]; then
  case "$(dirname "$SUBJECT")" in
    */modules/custom|*/themes/custom|*/profiles/custom) SET_DIR="$(dirname "$SUBJECT")";;
  esac
fi
if [[ -z "$CORE_DIR" ]]; then
  root="$(find_drupal_root "$SUBJECT" 2>/dev/null || true)"
  if [[ -n "$root" ]]; then
    for c in "$root/web/core" "$root/docroot/core" "$root/core"; do
      if [[ -f "$c/lib/Drupal.php" ]]; then CORE_DIR="$c"; break; fi
    done
  fi
fi
[[ -n "$CORE_DIR" ]] && export EXTSCAN_CORE_DIR="$CORE_DIR"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-metalint.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
: > "$WORK/findings.tsv"

# add_finding check severity extension file line message suggestion
add_finding() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "${7:-}" >> "$WORK/findings.tsv"
  return 0
}

log_step "Linting extension metadata of $(basename "$SUBJECT")"
if [[ -n "$SET_DIR" ]]; then
  SCAN="$(EXTSCAN_TESTS=1 ext_scan_json "$SUBJECT" "$SET_DIR")" || die "The extension scan failed." 1
else
  SCAN="$(EXTSCAN_TESTS=1 ext_scan_json "$SUBJECT")" || die "The extension scan failed." 1
fi
printf '%s' "$SCAN" > "$WORK/scan.json"
# ext rows: machine dir info test core_req configure package
# (\037-separated: IFS=<tab> would collapse empty fields)
jq -r '.extensions[] | [.machine, .dir, .info_file, (if .test then "1" else "0" end), .core_version_requirement, .configure, .package] | join("\u001f")' "$WORK/scan.json" > "$WORK/ext.tsv"
TOP_REQ="$(subject_core_requirement "$SUBJECT" 2>/dev/null || true)"

# Schema keys of every extension in the subject (a submodule may rely on its
# parent's schema): one key per line.
find "$SUBJECT" \( -name vendor -o -name node_modules -o -name .git \) -prune -o -path '*/config/schema/*.schema.yml' -type f -print 2>/dev/null \
  | while IFS= read -r f; do grep -E '^[^[:space:]#][^:]*:' "$f" 2>/dev/null | sed -E 's/:.*$//; s/^["'\'']//; s/["'\'']$//' || true; done \
  | LC_ALL=C sort -u > "$WORK/schema-keys.txt"

# schema_covers <config-name> -> 0 when a schema key covers it, following core's
# getFallbackName(): trailing segments become `*`, and a single trailing `*`
# is greedy.
schema_covers() {
  AWKV_n="$1" awk '
    function m(name, key,   nk, nn, kp, np, i, plen, stars) {
      if (key == name) return 1
      if (index(key, "*") == 0) return 0
      nk = split(key, kp, /[.:]/); nn = split(name, np, /[.:]/)
      plen = 0; for (i = 1; i <= nk; i++) { if (kp[i] == "*") break; plen++ }
      for (i = plen + 1; i <= nk; i++) if (kp[i] != "*") return 0
      stars = nk - plen
      if (plen < 1 || plen >= nn) return 0
      for (i = 1; i <= plen; i++) if (kp[i] != np[i]) return 0
      return (nn - plen == stars || stars == 1)
    }
    BEGIN { n = ENVIRON["AWKV_n"]; found = 0 }
    { if (m(n, $0)) { found = 1; exit } }
    END { exit found ? 0 : 1 }' "$WORK/schema-keys.txt"
}

# --- Check: config-schema ----------------------------------------------------
if check_on config-schema; then
  while IFS=$'\x1f' read -r m d _ t _; do
    [[ "$t" == "1" ]] && continue
    for sub in install optional; do
      for f in "$SUBJECT/$d/config/$sub/$m".*.yml; do
        [[ -f "$f" ]] || continue
        name="$(basename "$f" .yml)"
        schema_covers "$name" && continue
        rel="${f#"$SUBJECT"/}"; rel="${rel#./}"
        add_finding config-schema warn "$m" "$rel" 1 \
          "Config '$name' has no schema in config/schema/*.schema.yml: strict config schema checks (Kernel/Functional tests, config inspector) fail on it and its values are not typed or translatable." \
          "Add a '$name:' entry (type: config_object for simple config) to config/schema/$m.schema.yml."
      done
    done
  done < "$WORK/ext.tsv"
fi

# --- Check: plugin-schema ----------------------------------------------------
if check_on plugin-schema; then
  jq -r --slurpfile s "$WORK/scan.json" '
    ($s[0].extensions | map(.machine)) as $mine
    | .plugins[] | select(.own and .has_settings) | select(.machine as $x | $mine | index($x))
    | [.machine, .type, .id, .file] | join("\u001f")' "$WORK/scan.json" 2>/dev/null \
  | while IFS=$'\x1f' read -r m ptype pid pfile; do
      case "$ptype" in
        Block) key="block.settings.$pid"; generic="block.settings.*";;
        Condition) key="condition.plugin.$pid"; generic="condition.plugin.*";;
        Filter) key="filter_settings.$pid"; generic="filter_settings.*";;
        FieldFormatter) key="field.formatter.settings.$pid"; generic="field.formatter.settings.*";;
        FieldWidget) key="field.widget.settings.$pid"; generic="field.widget.settings.*";;
        *) continue;;
      esac
      grep -qxF "$key" "$WORK/schema-keys.txt" && continue
      add_finding plugin-schema warn "$m" "$pfile" 1 \
        "$ptype plugin '$pid' has its own settings but no '$key' schema: only core's generic '$generic' covers it, so its extra settings fail strict config schema checks." \
        "Add '$key:' to config/schema/$m.schema.yml describing the plugin's settings."
    done
fi

# --- Check: configure-route --------------------------------------------------
if check_on configure-route; then
  while IFS=$'\x1f' read -r m d info t _ conf _; do
    [[ -n "$conf" && "$t" != "1" ]] || continue
    line="$(grep -n '^configure:' "$SUBJECT/$info" 2>/dev/null | sed -n '1p' | cut -d: -f1 || true)"
    owner="$(jq -r --arg r "$conf" '.routes[$r] // empty' "$WORK/scan.json")"
    if [[ -n "$owner" ]]; then
      mine="$(awk -F'\037' -v o="$owner" '$1 == o { print "yes"; exit }' "$WORK/ext.tsv")"
      if [[ -z "$mine" ]]; then
        add_finding configure-route info "$m" "$info" "${line:-1}" \
          "configure: '$conf' is defined by '$owner', not by this extension." \
          "Declare '$owner' in dependencies: so the route exists whenever this module is installed."
      fi
      continue
    fi
    case "$conf" in
      entity.*)
        add_finding configure-route info "$m" "$info" "${line:-1}" \
          "configure: '$conf' is a dynamic entity route (generated by an entity route provider): not verifiable statically." ""
        continue;;
    esac
    near="$(jq -r --arg r "$conf" --arg m "$m" '.routes | to_entries[] | select(.value == $m) | .key | select(startswith($r) or ($r | startswith(.)))' "$WORK/scan.json" | sed -n '1p')"
    add_finding configure-route warn "$m" "$info" "${line:-1}" \
      "configure: '$conf' names a route that no *.routing.yml of the extension defines: core drops the Configure link from /admin/modules silently (unless a route subscriber or another module provides it)." \
      "$(if [[ -n "$near" ]]; then printf "Point it at the real route ('%s'?)." "$near"; else printf 'Point it at a route defined in %s.routing.yml.' "$m"; fi)"
  done < "$WORK/ext.tsv"
fi

# --- services.yml parsing (services-class / services-arity) --------------------
# One \037-separated row per service: ext file id line class nargs skip
# (nargs -1 = none given, -2 = named/unparseable; skip = autowire|parent|
# factory|abstract|alias|"").
parse_services() {
  local m="$1" f="$2"
  AWKV_m="$m" AWKV_f="$f" awk '
    function flush() {
      if (id == "") return
      if (cls == "" && id ~ /\\/) cls = id
      printf "%s\037%s\037%s\037%d\037%s\037%d\037%s\n", m, f, id, idline, cls, nargs, skip
      id = ""
    }
    function count(s,   i, c, n, depth, q, any) {
      n = 0; depth = 0; q = ""; any = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") { if (c == q) q = ""; continue }
        if (c == "\"" || c == "\047") { q = c; any = 1; continue }
        if (c == "[" || c == "{" || c == "(") { depth++; any = 1; continue }
        if (c == "]" || c == "}" || c == ")") { depth--; continue }
        if (c == "," && depth == 0) { n++; any = 0; continue }
        if (c !~ /[ \t]/) any = 1
      }
      return n + (any ? 1 : 0)
    }
    BEGIN { m = ENVIRON["AWKV_m"]; f = ENVIRON["AWKV_f"]; ind = -1; id = ""; autodef = 0; indef = 0 }
    { sub(/\r$/, "") }
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    { line = $0; sub(/[ \t]+#.*$/, "", line) }
    /^services:/ { insvc = 1; next }
    /^[^ ]/ { flush(); insvc = 0; next }
    !insvc { next }
    {
      match(line, /^ */); li = RLENGTH
      if (ind < 0) ind = li
      if (li == ind) {
        flush()
        k = line; sub(/^ +/, "", k); v = k; sub(/:.*$/, "", k); gsub(/["\047]/, "", k)
        sub(/^[^:]*:[ \t]*/, "", v)
        indef = (k == "_defaults"); if (k ~ /^_/) next
        id = k; idline = NR; cls = ""; nargs = -1; skip = (autodef ? "autowire" : ""); inargs = 0; flow = ""
        if (v ~ /^["\047]?@/) skip = "alias"
        next
      }
      if (indef) { if (line ~ /autowire:[ \t]*true/) autodef = 1; next }
      if (id == "") next
      kv = line; sub(/^ +/, "", kv)
      if (inargs == 2) {                       # inside a multi-line flow list
        flow = flow " " kv
        if (flow ~ /\][ \t]*$/) { s = flow; sub(/^\[/, "", s); sub(/\][ \t]*$/, "", s); nargs = count(s); inargs = 0 }
        next
      }
      if (inargs == 1) {                       # block list items
        if (kv ~ /^-/ && li > argind) { if (itemind < 0) itemind = li; if (li == itemind) nargs++; next }
        if (li > argind && kv !~ /^-/ && itemind < 0) { nargs = -2; inargs = 0; next }
        if (li > itemind && itemind >= 0) next
        inargs = 0
      }
      if (kv ~ /^class:/) { c = kv; sub(/^class:[ \t]*/, "", c); gsub(/["\047]/, "", c); sub(/^\\/, "", c); cls = c; next }
      if (kv ~ /^(parent|factory):/) { skip = substr(kv, 1, index(kv, ":") - 1); next }
      if (kv ~ /^abstract:[ \t]*true/) { skip = "abstract"; next }
      if (kv ~ /^autowire:[ \t]*true/) { skip = "autowire"; next }
      if (kv ~ /^autowire:[ \t]*false/ && skip == "autowire") { skip = ""; next }
      if (kv ~ /^alias:/) { skip = "alias"; next }
      if (kv ~ /^arguments:/) {
        a = kv; sub(/^arguments:[ \t]*/, "", a)
        if (a == "") { inargs = 1; argind = li; itemind = -1; nargs = 0; next }
        if (a ~ /^\{/) { nargs = -2; next }
        if (a ~ /^\[/) {
          if (a ~ /\][ \t]*$/) { s = a; sub(/^\[/, "", s); sub(/\][ \t]*$/, "", s); nargs = count(s) }
          else { inargs = 2; flow = a }
        }
        next
      }
    }
    END { flush() }' "$SUBJECT/$f"
  return 0
}

# resolve_case <base> <relpath> -> "ok <path>" | "case <real path>" | "missing"
# Walks each component with an exact listing match, so it is correct on
# case-insensitive filesystems (macOS) too.
resolve_case() {
  local cur="$1" rel="$2" comp hit ci="" IFS=/ out=""
  for comp in $rel; do
    [[ -n "$comp" ]] || continue
    hit="$(ls -1a "$cur" 2>/dev/null | awk -v c="$comp" '!d && $0 == c { print; d = 1 }')"
    if [[ -z "$hit" ]]; then
      hit="$(ls -1a "$cur" 2>/dev/null | awk -v c="$comp" '!d && tolower($0) == tolower(c) { print; d = 1 }')"
      [[ -n "$hit" ]] || { printf 'missing'; return 0; }
      ci=1
    fi
    cur="$cur/$hit"; out="${out:+$out/}$hit"
  done
  if [[ -n "$ci" ]]; then printf 'case %s' "$out"; else printf 'ok %s' "$out"; fi
  return 0
}

# ext_dir_of <machine> -> its dir relative to the subject ("" when not in it).
ext_dir_of() { awk -F'\037' -v m="$1" '$1 == m && $4 == "0" { print $2; exit }' "$WORK/ext.tsv"; }

# ctor_of <file> <fqcn> [depth] -> "nparams nrequired" of the class's own
# constructor, else of the nearest parent inside the subject; "" when unknown.
ctor_of() {
  local f="$1" fq="$2" depth="${3:-0}" sig parent pe pd prel r
  [[ -f "$f" ]] || return 0
  php_scan_file "$f" > "$WORK/ctor.tsv"
  sig="$(AWKV_q="$fq" awk -F'\t' 'BEGIN { q = tolower(ENVIRON["AWKV_q"]) } $1 == "SIG" && tolower($3) == q && $4 == "__construct" { print $7 " " $8; exit }' "$WORK/ctor.tsv")"
  if [[ -n "$sig" ]]; then printf '%s' "$sig"; return 0; fi
  (( depth < 5 )) || return 0
  parent="$(AWKV_q="$fq" awk -F'\t' 'BEGIN { q = tolower(ENVIRON["AWKV_q"]) } $1 == "CLASS" && tolower($4) == q { print $6; exit }' "$WORK/ctor.tsv")"
  case "$parent" in Drupal\\*\\*) ;; *) return 0;; esac
  pe="${parent#Drupal\\}"; pe="${pe%%\\*}"
  pd="$(ext_dir_of "$pe")"
  [[ -n "$pd" ]] || return 0
  prel="$(printf '%s' "${parent#Drupal\\"$pe"\\}" | tr '\\' '/').php"
  r="$(resolve_case "$SUBJECT/$pd/src" "$prel")"
  case "$r" in ok\ *|case\ *) ctor_of "$SUBJECT/$pd/src/${r#* }" "$parent" $((depth + 1));; esac
  return 0
}

if check_on services-class || check_on services-arity; then
  : > "$WORK/services.tsv"
  while IFS=$'\x1f' read -r m d _ t _; do
    [[ "$t" == "1" ]] && continue
    [[ -f "$SUBJECT/$d/$m.services.yml" ]] || continue
    rel="$m.services.yml"; [[ "$d" != "." ]] && rel="$d/$m.services.yml"
    parse_services "$m" "$rel" >> "$WORK/services.tsv"
  done < "$WORK/ext.tsv"
  while IFS=$'\x1f' read -r m f id line cls nargs skip; do
    [[ -n "$cls" ]] || continue
    case "$cls" in Drupal\\*\\*) ;; *) continue;; esac
    ce="${cls#Drupal\\}"; ce="${ce%%\\*}"
    cd_="$(ext_dir_of "$ce")"
    [[ -n "$cd_" ]] || continue
    crel="$(printf '%s' "${cls#Drupal\\"$ce"\\}" | tr '\\' '/').php"
    r="$(resolve_case "$SUBJECT/$cd_/src" "$crel")"
    expect="src/$crel"; [[ "$cd_" != "." ]] && expect="$cd_/src/$crel"
    case "$r" in
      missing)
        if check_on services-class; then
          add_finding services-class error "$m" "$f" "$line" \
            "Service '$id' points at class $cls, but $expect does not exist (orphan service): fetching it is a fatal error." \
            "Remove the service definition, or restore/rename the class."
        fi
        continue;;
      case\ *)
        if check_on services-class; then
          real="${r#case }"
          add_finding services-class error "$m" "$f" "$line" \
            "Service '$id' class $cls differs in letter case from the real file src/$real: the autoloader fails on case-sensitive filesystems (Linux servers, DDEV)." \
            "Use the exact class name: Drupal\\$ce\\$(printf '%s' "${real%.php}" | tr '/' '\\')."
        fi;;
    esac
    check_on services-arity || continue
    [[ -z "$skip" ]] || continue
    [[ "$nargs" == "-2" ]] && continue
    [[ "$nargs" == "-1" ]] && nargs=0
    file="$SUBJECT/$cd_/src/${r#* }"
    sig="$(ctor_of "$file" "$cls")"
    if [[ -z "$sig" ]]; then
      [[ "$nargs" -gt 0 ]] || continue
      add_finding services-arity info "$m" "$f" "$line" \
        "Service '$id' passes $nargs argument(s); $cls has no own constructor (inherited from outside the subject): not checked." ""
      continue
    fi
    total="${sig% *}"; req="${sig#* }"
    if [[ "$nargs" -lt "$req" ]]; then
      add_finding services-arity error "$m" "$f" "$line" \
        "Service '$id' passes $nargs argument(s) but $cls::__construct() requires $req: ArgumentCountError when the service is instantiated." \
        "Add the missing argument(s) to arguments: in $f."
    elif [[ "$nargs" -gt "$total" ]]; then
      add_finding services-arity warn "$m" "$f" "$line" \
        "Service '$id' passes $nargs argument(s) but $cls::__construct() takes $total: PHP silently ignores the extra one(s) (a stale argument, or a constructor that lost a parameter)." \
        "Drop the extra argument(s), or restore the constructor parameter they were meant for."
    fi
  done < "$WORK/services.tsv"
fi

# --- Check: submodule-core-req -------------------------------------------------
if check_on submodule-core-req; then
  while IFS=$'\x1f' read -r m d info t req _ pkg; do
    [[ "$d" == "." ]] && continue
    line="$(grep -n '^core_version_requirement:' "$SUBJECT/$info" 2>/dev/null | sed -n '1p' | cut -d: -f1 || true)"
    what="Submodule"; [[ "$t" == "1" ]] && what="Test module"
    sugg="Set it to the parent's constraint${TOP_REQ:+ ('$TOP_REQ')}: /drupilot-port does this with set-core-requirement.sh."
    if [[ -z "$req" ]]; then
      [[ "$pkg" == "Testing" ]] && continue
      add_finding submodule-core-req error "$m" "$info" 1 \
        "$what '$m' has no core_version_requirement: core throws InfoParserException ('The core_version_requirement key must be present')." "$sugg"
    elif ! core_requirement_admits "$req" 11; then
      add_finding submodule-core-req warn "$m" "$info" "${line:-1}" \
        "$what '$m' declares core_version_requirement: $req, which does not admit Drupal 11: core marks it incompatible and it cannot be installed$( [[ "$t" == "1" ]] && printf ' (tests that enable it fail)')." "$sugg"
    elif printf '%s' "$req" | grep_q -E '(^|[^0-9.])(\^|~|>=?)?[89](\.|[[:space:]]|$|\|)'; then
      add_finding submodule-core-req info "$m" "$info" "${line:-1}" \
        "$what '$m' still lists Drupal 8/9 in core_version_requirement: $req (harmless, but stale)." "$sugg"
    fi
  done < "$WORK/ext.tsv"
fi

# --- Check: undeclared-deps ----------------------------------------------------
if check_on undeclared-deps; then
  jq -r '.extensions[] | select(.test | not) | .machine as $m | .info_file as $i | .implicit[]
         | select((.declared | not) and (.always_enabled | not))
         | [$m, $i, (if .optional then "info" else "warn" end), .target, .scope, (.kinds | join(",")),
            (.declared_via // ""), .proposed, (if .verify_project then "1" else "0" end), (.evidence[0] // "")] | join("\u001f")' \
    "$WORK/scan.json" | while IFS=$'\x1f' read -r m info sev target scope kinds via proposed verify ev; do
      evf="${ev%% *}"; evfile="${evf%:*}"; evline="${evf##*:}"
      [[ -n "$evfile" ]] || { evfile="$info"; evline=1; }
      if [[ "$sev" == "info" ]]; then
        add_finding undeclared-deps info "$m" "$evfile" "$evline" \
          "'$m' uses '$target' ($kinds) only optionally (a moduleExists() guard, config/optional, an @?service, or a plugin of $target's own plugin type): fine without a dependency." ""
        continue
      fi
      # A plain case, not one inside $(...): bash 3.2 ends the substitution at
      # the first pattern's ")".
      case "$scope" in
        internal) scope_label="project";;
        external) scope_label="contrib";;
        *) scope_label="$scope";;
      esac
      msg="'$m' uses $scope_label module '$target' ($kinds) without declaring it in $(basename "$info") dependencies:"
      [[ "$via" == "composer" ]] && msg="$msg it is only required in composer.json, so Drupal does not enable it when '$m' is installed."
      [[ "$via" == "composer" ]] || msg="$msg installing '$m' alone fails or breaks at runtime."
      sugg="Add '- $proposed' to dependencies:"
      [[ "$verify" == "1" ]] && sugg="$sugg (verify the drupal.org project name)"
      add_finding undeclared-deps warn "$m" "$evfile" "$evline" "$msg" "$sugg."
    done
fi

# --- Report --------------------------------------------------------------------
CHECKS_JSON="$(printf '%s\n' $CHECKS | jq -R . | jq -s -c .)"
REPORT="$(jq -R -s --arg subject "$SUBJECT" --argjson checks "$CHECKS_JSON" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg digest "$(subject_digest "$SUBJECT")" '
  split("\n") | map(select(length > 0) | split("\t")
    | {check: .[0], severity: .[1], extension: .[2], file: .[3], line: (.[4] | tonumber? // 1),
       message: .[5], suggestion: (.[6] // "")})
  | sort_by((.severity | {"error":0,"warn":1,"info":2}[.]), .extension, .file, .line) as $f
  | {tool: "lint-extension-metadata", subject: $subject, generated_at: $at, checks_run: $checks,
     subject_digest: (if $digest == "" then null else $digest end),
     findings: $f,
     totals: {error: ([$f[] | select(.severity == "error")] | length),
              warn: ([$f[] | select(.severity == "warn")] | length),
              info: ([$f[] | select(.severity == "info")] | length)}}' "$WORK/findings.tsv")"

if [[ "$WRITE" == "1" ]]; then
  printf '%s\n' "$REPORT" > "$(project_state_dir "$SUBJECT")/metadata-lint.json" 2>/dev/null || true
fi

hr
log_plain "Extension metadata hygiene — $(basename "$SUBJECT") (report only; not fixed in Phase 1)"
hr
printf '%s' "$REPORT" | jq -r '.findings[] | "  \(if .severity == "error" then "❌" elif .severity == "warn" then "⚠️ " else "ℹ️ " end) [\(.check)] \(.file):\(.line) \(.message)\(if .suggestion != "" then "\n       → " + .suggestion else "" end)"' >&2
log_plain "$(printf '%s' "$REPORT" | jq -r '"Errors: \(.totals.error) · Warnings: \(.totals.warn) · Info: \(.totals.info)"')"

if [[ "$AS_JSON" == "1" ]]; then
  printf '%s\n' "$REPORT"
else
  printf '%s' "$REPORT" | jq -r '.findings[] | "[\(.check)] \(.severity) \(.file):\(.line) \(.message)"'
fi
exit 0
