#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/php-target.sh
# The PHP-window scan (T-M5-02, T-M5-07, AR-03): every config/php/rules.json
# row is classified for the PHP floor L and the window's top P
# (php_rule_class: deny, removed-blocking, apply-modernize, apply-compat,
# report-only, not-applicable), and the module's PHP files are searched for
# the constructs of two classes still in the code (Rector's level sets fix
# some forms of a few of them during the upgrade stage; what is left is
# reported here):
#   removed-blocking  removed at or below P: the code fatals on P; a blocking
#                     finding (severity error) for a person
#   report-only       deprecated at or below P, its fix needs a PHP above L or
#                     no rule makes it: a warning for a person (fix_at_floor:
#                     whether the fix runs on L, its output_min_php at or
#                     below L or none)
# A row is searched only when it has a `detect` ERE (`ere:`, or `ere-i:` for
# a case-insensitive one: PHP function and cast names); its `exclude` ERE
# drops the lines it matches (a method of the same name being declared). The
# rows of those classes without a pattern are listed in `unsearched`. Only the
# code is searched: comments, string contents, heredocs and inline HTML are
# blanked first (php_code_lines, scripts/lib/php-scan.sh), the line numbers
# kept. vendor/, node_modules/ and .git/ are left out. L and P are --floor /
# --target, else the module's own frozen plan (php.floor and php.final), else
# the PHP target.
#
# Usage:
#   php-target.sh --subject DIR [--floor X.Y] [--target X.Y] [--json]
#                 [-h|--help]
#     --subject DIR    the module/theme
#     --floor X.Y      the PHP floor L (default: the plan's)
#     --target X.Y     the window's top P (default: the plan's php.final)
#     --json           {tool, floor, target, classes: {class: [ids]},
#                     findings: [{id, class, severity, file, line, construct,
#                     deprecated_in, removed_in, fix_at_floor}], unsearched:
#                     [ids], counts} on STDOUT
#
# Exit codes: 0 scanned (findings or not) · 1 usage error, or a bound that is
# not X.Y.
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/php-scan.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/php-scan.sh"

SUBJECT=""; L=""; P=""; AS_JSON=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --floor) L="${2:-}"; shift 2 || die "--floor needs a value" 1;;
    --target) P="${2:-}"; shift 2 || die "--target needs a value" 1;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ -n "$SUBJECT" && -d "$SUBJECT" ]] || die "Pass --subject DIR (an existing directory)." 1
have_cmd jq || die "jq is required (run /drupilot-doctor)." 1
SUBJECT="$(cd "$SUBJECT" && pwd)"
[[ -n "$L" ]] || L="$(plan_get_own "$SUBJECT" .php.floor)"
[[ -n "$P" ]] || P="$(plan_get_own "$SUBJECT" .php.final)"
[[ -n "$P" ]] || P="$(resolve_php_target)"
[[ -n "$L" ]] || L="$P"
[[ "$L" =~ ^[0-9]+\.[0-9]+$ && "$P" =~ ^[0-9]+\.[0-9]+$ ]] || die "The floor and the target are PHP versions X.Y (got '$L', '$P')." 1
TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-php-target.XXXXXX")"
trap 'rm -rf "$TMP" 2> /dev/null || true' EXIT

php_rules_classified "$L" "$P" > "$TMP/rules.json"
# The module's PHP files, each blanked to its code as $TMP/m/<n> (a name with
# no ':' whatever the source path; line N of the source is line N of <n>).
mkdir -p "$TMP/m"
( cd "$SUBJECT" && find . \( -name vendor -o -name node_modules -o -name .git \) -prune -o -type f \
    \( -name '*.php' -o -name '*.module' -o -name '*.inc' -o -name '*.install' -o -name '*.theme' \
       -o -name '*.profile' -o -name '*.engine' \) -print 2> /dev/null || true ) | sed 's#^\./##' | LC_ALL=C sort > "$TMP/files"
k=0
while IFS= read -r f; do
  k=$((k + 1))
  php_code_lines "$SUBJECT/$f" > "$TMP/m/$k"
done < "$TMP/files"
: > "$TMP/hits.tsv"
US="$(printf '\037')"
jq -r '.[] | select((.class == "removed-blocking" or .class == "report-only") and .detect != null)
       | [.id, .class, .detect, ((.exclude // "") | sub("^ere(-i)?:"; ""))] | join("\u001f")' "$TMP/rules.json" > "$TMP/searched"
# One grep per searched row over the blanked files: "./<n>:LINE:CODE" (no
# match is not an error), the row's exclude applied, <n> mapped back to its path.
while IFS="$US" read -r id cls det exc; do
  [[ -n "$id" ]] || continue
  gopt=(-E); ere="${det#ere:}"
  case "$det" in ere-i:*) gopt=(-i -E); ere="${det#ere-i:}";; esac
  { ( cd "$TMP/m" && LC_ALL=C find . -type f -exec grep -nH "${gopt[@]}" -- "$ere" {} + 2> /dev/null ) || true; } > "$TMP/raw"
  if [[ -n "$exc" ]]; then
    { LC_ALL=C grep -v "${gopt[@]}" -- "$exc" "$TMP/raw" || true; } > "$TMP/kept"
  else
    cp "$TMP/raw" "$TMP/kept"
  fi
  LC_ALL=C awk -v id="$id" -v cls="$cls" 'NR == FNR { path[FNR] = $0; next }
    { p = index($0, ":"); n = substr($0, 3, p - 3); r = substr($0, p + 1); q = index(r, ":")
      ln = substr(r, 1, q - 1)
      if ((n in path) && ln ~ /^[0-9]+$/) printf "%s\t%s\t%s\t%s\n", id, cls, path[n], ln }' "$TMP/files" "$TMP/kept" >> "$TMP/hits.tsv"
done < "$TMP/searched"
OUT="$(jq -R -s -c --slurpfile r "$TMP/rules.json" --arg L "$L" --arg P "$P" '
  def vn: split(".") | map(tonumber? // 0);
  ($r[0] | map({key: .id, value: .}) | from_entries) as $by
  | (split("\n") | map(select(length > 0) | split("\t")
      | {id: .[0], class: .[1], file: .[2], line: (.[3] | tonumber)}
      | . + {severity: (if .class == "removed-blocking" then "error" else "warning" end),
             construct: $by[.id].construct, deprecated_in: $by[.id].deprecated_in, removed_in: $by[.id].removed_in,
             fix_at_floor: ($by[.id].output_min_php as $o | $o == null or (($o | vn) <= ($L | vn)))})
      | unique_by([.file, .line, .id]) | sort_by([.file, .line, .id])) as $f
  | {tool: "php-target", floor: $L, target: $P,
     classes: ($r[0] | group_by(.class) | map({key: .[0].class, value: [.[].id]}) | from_entries),
     findings: $f,
     unsearched: ([$r[0][] | select((.class == "removed-blocking" or .class == "report-only") and .detect == null) | .id] | sort),
     counts: {removed_blocking: ([$f[] | select(.class == "removed-blocking")] | length),
              report_only: ([$f[] | select(.class == "report-only")] | length)}}' "$TMP/hits.tsv")"
if [[ "$AS_JSON" == "1" ]]; then
  printf '%s\n' "$OUT" | canon_json
else
  printf '%s\n' "$OUT" | jq -r '.findings[] | "\(.severity)\t\(.file):\(.line)\t[\(.id)] \(.construct)"'
fi
log_info "php-target: window $L..$P: $(jq -r '.counts.removed_blocking' <<< "$OUT") removed-blocking, $(jq -r '.counts.report_only' <<< "$OUT") report-only finding(s)."
exit 0
