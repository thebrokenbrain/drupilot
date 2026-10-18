#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/scan-removals.sh
# The core-removals scanner (T-M6-04, 04-R14, ADR 0031): what a module/theme
# still takes from Drupal core that a major in (S, T] removes, read from the
# version data (config/targets/<N>.json removed_extensions and
# removed_libraries; DRUPILOT_VERSION_DATA_DIR to read a snapshot). Read-only,
# no toolchain needed (bash, awk and jq; curl for the release feed). It finds:
#
#   dependency-removed    a dependencies:/install: entry of a *.info.yml that
#                         names a removed module as core's (drupal:NAME or a
#                         bare NAME; PROJECT:NAME already names a contrib
#                         project), or a reference to the namespace of a
#                         module removed with no replacement
#   migrate-drupal-usage  the same for migrate_drupal and migrate_drupal_ui
#                         (a hard break: a module that depends on them cannot
#                         target Drupal 12)
#   base-theme-removed    a theme's `base theme:` naming a removed theme
#   library-removed       a removed core library in a *.info.yml or
#                         *.libraries.yml (a list item or a key) or quoted in
#                         a PHP or Twig file
#   namespace-move        a class of targets/<T>.json namespace_moves in its
#                         old namespace (an announced note: never a hard
#                         break)
#
# Each finding has an action:
#   rewrite            the module moved to a contrib project and a published
#                      release of it covers the declared range C (H8): depend
#                      on PROJECT:NAME and require drupal/PROJECT
#   blocked            the release feed was read and no release covers C: a
#                      blocking dependency, never rewritten
#   verify             whether a release covers C is unknown (--offline, no
#                      curl, the feed unreachable)
#   composer-required  composer.json already requires drupal/PROJECT
#   decision           a removed base theme: a person picks the new one
#   hard-break         removed with no replacement path
#   note               an announced namespace move
# A finding is a hard break when its action is decision or hard-break.
#
# A release covers C when it is published, is not a -dev branch, is stable
# (or any release while T is a pre-release: a preview) and its
# core_compatibility admits every verified core minor C admits. The release
# feed (https://updates.drupal.org/release-history/<project>/current) is
# cached for a day under drupilot's cache dir; in deterministic mode
# (DRUPILOT_DETERMINISTIC, default true) a known answer is frozen in the Drupal
# root's lock (.replacements.<project>.<range>, with whether it was a
# preview's) and reused while T's pre-release status is the same, until
# `lock-sync.sh --refresh` drops it; DRUPILOT_DETERMINISTIC=false reads the
# feed and refreshes the lock. This is the only write: nothing in the subject
# or the root's tree is touched.
#
# Usage:
#   scan-removals.sh [--subject DIR] [--target N] [--source S] [--range C]
#                    [--root DIR] [--offline] [--json] [-h|--help]
#
# Options:
#   --subject DIR  The module/theme directory (default: the current one).
#   --target N     T (default: the subject's frozen plan, else
#                  DRUPILOT_TARGET_MAJOR, else 11).
#   --source S     S, the source era: the majors in (S, T] are scanned
#                  (default: the subject's frozen plan, else T - 1).
#   --range C      The declared range a replacement release must cover
#                  (default: the subject's frozen plan, else
#                  targets/<T>.json default_ranges target-only).
#   --root DIR     The Drupal root whose lock freezes the coverage answers
#                  (default: the subject's).
#   --offline      Never read the release feed or the lock's frozen answers:
#                  every coverage is unknown.
#   --json         Print the report as JSON on STDOUT (default: a summary on
#                  STDERR and the finding ids on STDOUT).
#
# Output (--json): {tool, subject, target_major, source_major, majors, range,
# preview, offline, findings[{detector, name, kind, removed_in, file, line,
# evidence, rewrite, replacement_project, core_alternative,
# replacement_available, covering_release, action, hard_break, severity,
# message}], core_removals[{detector, name, kind, removed_in, rewrite,
# replacement_project, core_alternative, replacement_available,
# covering_release, action, hard_break, files}], hard_breaks[{id, name,
# files}]}. Files are subject-relative; findings are sorted by file, line,
# detector and name.
#
# Exit codes: 0 scanned (findings are data, not an error) · 1 usage error,
# not a directory, or version data that cannot be read · 2 jq missing.
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""; TARGET=""; SOURCE=""; RANGE=""; ROOT=""; OFFLINE=0; AS_JSON=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --target) TARGET="${2:-}"; shift 2 || die "--target needs a value" 1;;
    --target=*) TARGET="${1#*=}"; shift;;
    --source) SOURCE="${2:-}"; shift 2 || die "--source needs a value" 1;;
    --source=*) SOURCE="${1#*=}"; shift;;
    --range) RANGE="${2:-}"; shift 2 || die "--range needs a value" 1;;
    --range=*) RANGE="${1#*=}"; shift;;
    --root) ROOT="${2:-}"; shift 2 || die "--root needs a value" 1;;
    --root=*) ROOT="${1#*=}"; shift;;
    --offline) OFFLINE=1; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
have_cmd jq || die "jq is required (run /drupilot-doctor)." 2
[[ -n "$SUBJECT" ]] || SUBJECT="$PWD"
[[ -d "$SUBJECT" ]] || die "Subject '$SUBJECT' is not a directory." 1
SUBJECT="$(cd "$SUBJECT" && pwd)"
MN="$(subject_machine_name "$SUBJECT" 2> /dev/null || basename "$SUBJECT")"
if [[ -n "$ROOT" ]]; then
  [[ -d "$ROOT" ]] || die "--root '$ROOT' is not a directory." 1
  ROOT="$(cd "$ROOT" && pwd)"
elif [[ "$OFFLINE" == "0" ]]; then
  # Only the lock's frozen release answers need the root.
  ROOT="$(subject_project_root "$SUBJECT" 2> /dev/null || true)"
fi

# Defaults: the subject's own frozen plan, else the target's data.
[[ -n "$TARGET" ]] || TARGET="$(plan_get_own "$SUBJECT" .target.major)"
[[ -n "$TARGET" ]] || TARGET="$(DRUPILOT_PROJECT_DIR="${ROOT:-$SUBJECT}" resolve_target_major)"
[[ "$TARGET" =~ ^[0-9]+$ ]] || die "Invalid --target '$TARGET' (a Drupal major)." 1
[[ -n "$SOURCE" ]] || SOURCE="$(plan_get_own "$SUBJECT" .source.major)"
[[ -n "$SOURCE" ]] || SOURCE="$((TARGET - 1))"
[[ "$SOURCE" =~ ^[0-9]+$ ]] || die "Invalid --source '$SOURCE' (a Drupal major)." 1
[[ -n "$(target_get "$TARGET" '.major')" ]] || die "No version data for Drupal $TARGET (config/targets/$TARGET.json)." 1
[[ -n "$RANGE" ]] || RANGE="$(plan_get_own "$SUBJECT" .range.constraint)"
[[ -n "$RANGE" ]] || RANGE="$(target_get "$TARGET" '.default_ranges["target-only"] // empty')"
PREVIEW=false
[[ "$(target_get "$TARGET" '.status')" == "pre-release" ]] && PREVIEW=true

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-removals.XXXXXX")"
trap 'rm -rf "$TMP" 2> /dev/null || true' EXIT

# The removal rows of every major in (S, T], and T's namespace moves.
MAJORS=""; m=$((SOURCE + 1))
while (( m <= TARGET )); do MAJORS="$MAJORS $m"; m=$((m + 1)); done
printf '[]' > "$TMP/ext.json"; printf '[]' > "$TMP/lib.json"
for m in $MAJORS; do
  target_get "$m" '[(.removed_extensions // [])[] | {name, kind, removed_in, rewrite: (.rewrite // null),
      replacement_project: (.replacement_project // null), core_alternative: (.core_alternative // null)}]' > "$TMP/e.json" 2> /dev/null \
    || printf '[]' > "$TMP/e.json"
  target_get "$m" '[(.removed_libraries // [])[] | {name, removed_in}]' > "$TMP/l.json" 2> /dev/null || printf '[]' > "$TMP/l.json"
  jq -s -c '.[0] + (.[1] // [])' "$TMP/ext.json" "$TMP/e.json" > "$TMP/x" && mv -f "$TMP/x" "$TMP/ext.json"
  jq -s -c '.[0] + (.[1] // [])' "$TMP/lib.json" "$TMP/l.json" > "$TMP/x" && mv -f "$TMP/x" "$TMP/lib.json"
done
# The namespace moves of every major from S to T (a move happens within a
# major: 11.5 moves the text_with_summary classes).
printf '[]' > "$TMP/moves.json"
m="$SOURCE"
while (( m <= TARGET )); do
  target_get "$m" '[(.namespace_moves // [])[] | {name, from_ns, to_ns, introduced_in, classes: (.classes // [])}]' > "$TMP/mv.json" 2> /dev/null \
    || printf '[]' > "$TMP/mv.json"
  jq -e 'type == "array"' "$TMP/mv.json" > /dev/null 2>&1 || printf '[]' > "$TMP/mv.json"
  jq -s -c '.[0] + .[1]' "$TMP/moves.json" "$TMP/mv.json" > "$TMP/x" && mv -f "$TMP/x" "$TMP/moves.json"
  m=$((m + 1))
done
# The namespaces of the modules removed with no replacement, as one ERE
# ("Drupal\\migrate_drupal\\" or "Drupal\\Tests\\migrate_drupal\\"), and the
# namespace-move classes.
NS_ERE="$(jq -r '[.[] | select(.kind == "module" and .rewrite == "hard-break") | .name] | unique
  | if length == 0 then "" else "Drupal[\\\\]+(Tests[\\\\]+)?(" + join("|") + ")[\\\\]" end' "$TMP/ext.json")"
MOVE_ERE="$(jq -r '[.[] | .classes[]] | unique | if length == 0 then "" else "(" + join("|") + ")" end' "$TMP/moves.json")"
MOVE_NS="$(jq -r '[.[] | .from_ns] | unique | join("\n")' "$TMP/moves.json")"

# The candidate records, one per line: KIND<TAB>VALUE<TAB>FILE<TAB>LINE<TAB>EVIDENCE.
#   dep VALUE    a dependencies:/install: entry (PROJECT:NAME, version dropped)
#   base VALUE   a base theme
#   lib VALUE    a core/... library reference
#   ns VALUE     a line naming Drupal\<removed module>\ or
#                Drupal\Tests\<removed module>\ (VALUE the module)
#   move VALUE   a line naming a namespace-move class in its old namespace
if [[ -n "$MAJORS" || -n "$MOVE_ERE" ]]; then
  # One awk per kind of file over the whole module (vendor/, node_modules/ and
  # .git/ pruned); FILENAME names each file, FNR its line.
  ( cd "$SUBJECT" && find . \( -name vendor -o -name node_modules -o -name .git \) -prune -o -type f \
      \( -name '*.info.yml' -o -name '*.libraries.yml' \) -exec awk '
      function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
      # A YAML comment: a # after a blank.
      function nocomment(s) { if (s ~ /^[[:space:]]*#/) return ""; sub(/[[:space:]]+#.*$/, "", s); return s }
      function unq(s) { s = trim(nocomment(s)); gsub(/^["\047]|["\047]$/, "", s); return trim(s) }
      function dep(v) { v = unq(v); sub(/[[:space:]]*\(.*$/, "", v); v = trim(v); if (v != "") printf "dep\t%s\t%s\t%d\t%s\n", v, F, FNR, trim($0) }
      function lib(v) { v = unq(v); if (v ~ /^core\/[A-Za-z0-9_.-]+$/) printf "lib\t%s\t%s\t%d\t%s\n", v, F, FNR, trim($0) }
      # flow(KIND, TEXT) -> the items of a flow sequence ([a, b]) on this
      # line, as dep or lib; 1 when its ] closes it here.
      function flow(kind, t,   n, a, i, closed) {
        t = nocomment(t); closed = 0
        if (index(t, "]") > 0) { t = substr(t, 1, index(t, "]") - 1); closed = 1 }
        sub(/^[[:space:]]*\[/, "", t)
        n = split(t, a, ",")
        for (i = 1; i <= n; i++) { if (kind == "dep") dep(a[i]); else lib(a[i]) }
        return closed
      }
      FNR == 1 { F = FILENAME; sub(/^\.\//, "", F); blk = ""; fk = "" }
      { sub(/\r$/, "") }
      # Inside a flow sequence that spans lines.
      fk != "" { if (flow(fk, $0)) fk = ""; next }
      /^[^[:space:]#-]/ { blk = "" }
      /^(dependencies|install)[[:space:]]*:/ {
        blk = "dep"; v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); v = trim(nocomment(v))
        if (v ~ /^\[/) { blk = ""; if (!flow("dep", v)) fk = "dep" }
        next
      }
      /^["\047]?base theme["\047]?[[:space:]]*:/ {
        v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); v = unq(v)
        if (v != "" && v != "false") printf "base\t%s\t%s\t%d\t%s\n", v, F, FNR, trim($0)
        next
      }
      blk == "dep" && /^[[:space:]]*-[[:space:]]*/ { v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); dep(v); next }
      /^[[:space:]]*-[[:space:]]*["\047]?core\// { v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); lib(v); next }
      /^[[:space:]]*["\047]?core\/[A-Za-z0-9_.-]+["\047]?[[:space:]]*:/ { v = $0; sub(/:.*$/, "", v); lib(v) }
      # Any other key with a flow sequence (a library'"'"'s dependencies:, a
      # theme'"'"'s libraries:, a libraries-extend list): its items as libraries.
      /^[[:space:]]*["\047]?[A-Za-z0-9_.\/-]+["\047]?[[:space:]]*:[[:space:]]*\[/ {
        v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); if (!flow("lib", v)) fk = "lib"; next
      }
      /^[[:space:]]*["\047]?core\/[A-Za-z0-9_.-]+["\047]?[[:space:]]*:/ { next }
        ' {} + 2> /dev/null || true ) > "$TMP/rec.tsv"
  ( cd "$SUBJECT" && find . \( -name vendor -o -name node_modules -o -name .git \) -prune -o -type f \
      \( -name '*.php' -o -name '*.module' -o -name '*.inc' -o -name '*.install' -o -name '*.theme' \
         -o -name '*.profile' -o -name '*.engine' -o -name '*.twig' \) -exec env AWKV_NS="$NS_ERE" AWKV_MV="$MOVE_ERE" AWKV_MVNS="$MOVE_NS" awk '
      function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
      BEGIN { NS = ENVIRON["AWKV_NS"]; MV = ENVIRON["AWKV_MV"]; nm = split(ENVIRON["AWKV_MVNS"], mvns, "\n") }
      FNR == 1 { F = FILENAME; sub(/^\.\//, "", F) }
      { sub(/\r$/, "") }
      {
        s = $0
        while (match(s, /["\047]core\/[A-Za-z0-9_.-]+["\047]/)) {
          printf "lib\t%s\t%s\t%d\t%s\n", substr(s, RSTART + 1, RLENGTH - 2), F, FNR, trim($0)
          s = substr(s, RSTART + RLENGTH)
        }
        if (NS != "" && match($0, NS)) {
          v = substr($0, RSTART, RLENGTH); sub(/^Drupal[\\]+/, "", v); sub(/^Tests[\\]+/, "", v); sub(/[\\]+$/, "", v)
          printf "ns\t%s\t%s\t%d\t%s\n", v, F, FNR, trim($0)
        }
        if (MV != "" && match($0, MV)) {
          c = substr($0, RSTART, RLENGTH); hit = 0
          for (i = 1; i <= nm; i++) if (mvns[i] != "" && index($0, mvns[i]) > 0) hit = 1
          if (hit) printf "move\t%s\t%s\t%d\t%s\n", c, F, FNR, trim($0)
        }
      }
        ' {} + 2> /dev/null || true ) >> "$TMP/rec.tsv"
else
  : > "$TMP/rec.tsv"
fi
jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
  | {k: .[0], v: .[1], file: .[2], line: (.[3] | tonumber), evidence: (.[4:] | join("\t"))})' "$TMP/rec.tsv" > "$TMP/rec.json"

# composer.json's drupal/* requires.
REQS="[]"
if [[ -f "$SUBJECT/composer.json" ]]; then
  REQS="$(jq -c '[(.require // {}) | keys[] | select(startswith("drupal/")) | ltrimstr("drupal/")]' "$SUBJECT/composer.json" 2> /dev/null || printf '[]')"
fi

# The candidate findings, before the release feed: a dependency names a
# removed module as core's (drupal:NAME or NAME), a base theme a removed
# theme, a library a removed library.
jq -c --slurpfile ext "$TMP/ext.json" --slurpfile lib "$TMP/lib.json" --slurpfile mv "$TMP/moves.json" '
  ($ext[0] | map(select(.kind == "module")) | map({key: .name, value: .}) | from_entries) as $mods
  | ($ext[0] | map(select(.kind == "theme")) | map({key: .name, value: .}) | from_entries) as $themes
  | ($lib[0] | map({key: .name, value: .}) | from_entries) as $libs
  | ([$mv[0][] | . as $m | .classes[] | {key: ., value: $m}] | from_entries) as $mvc
  | def det($n): if ($n | test("^migrate_drupal(_ui)?$")) then "migrate-drupal-usage" else "dependency-removed" end;
  [.[] | . as $r
   | if .k == "dep" then
       (.v | split(":")) as $p
       | (if ($p | length) > 1 then {proj: $p[0], name: ($p[1:] | join(":"))} else {proj: null, name: $p[0]} end) as $d
       | select($d.proj == null or $d.proj == "drupal")
       | $mods[$d.name] // empty
       | {detector: det(.name), name, kind, removed_in, rewrite, replacement_project, core_alternative,
          file: $r.file, line: $r.line, evidence: $r.evidence}
     elif .k == "base" then $themes[.v] // empty
       | {detector: "base-theme-removed", name, kind, removed_in, rewrite, replacement_project, core_alternative,
          file: $r.file, line: $r.line, evidence: $r.evidence}
     elif .k == "lib" then $libs[.v] // empty
       | {detector: "library-removed", name, kind: "library", removed_in, rewrite: null, replacement_project: null,
          core_alternative: null, file: $r.file, line: $r.line, evidence: $r.evidence}
     elif .k == "ns" then $mods[.v] // empty
       | {detector: det(.name), name, kind, removed_in, rewrite, replacement_project, core_alternative,
          file: $r.file, line: $r.line, evidence: $r.evidence, via: "namespace"}
     elif .k == "move" then $mvc[.v] // empty
       # A class whose module a major of (S, T] removes is gone from core:
       # the code that names it must change. Otherwise an announced note.
       | if $mods[.name] != null then
           . as $m | $mods[.name]
           | {detector: "dependency-removed", name, kind, removed_in, rewrite, replacement_project, core_alternative,
              file: $r.file, line: $r.line, evidence: $r.evidence, via: "class", class: $r.v, from_ns: $m.from_ns}
         else
           {detector: "namespace-move", name: $r.v, kind: "class", removed_in: null, rewrite: "residual",
            replacement_project: null, core_alternative: null, file: $r.file, line: $r.line, evidence: $r.evidence,
            from_ns, to_ns, introduced_in, module: .name}
         end
     else empty end]
  | unique_by([.file, .line, .detector, .name])' "$TMP/rec.json" > "$TMP/cand.json"

# The release feed, once per replacement project of a dependency or base theme.
# coverage PROJECT -> {available: true|false|"unknown", release, core_compatibility}
coverage() {
  local p="$1" frozen="" feed rows ans det=0 keep=0 key
  [[ "$OFFLINE" == "1" ]] && { printf '{"available":"unknown","release":null,"core_compatibility":null}'; return 0; }
  # The lock keeps one answer per project and declared range (a range with a
  # quote or a backslash is never frozen).
  key=".replacements[\"$p\"][\"$RANGE\"]"
  if [[ -n "$ROOT" && -d "$ROOT" && -n "$RANGE" && "$RANGE" != *[\"\\]* ]]; then
    keep=1
    DRUPILOT_PROJECT_DIR="$ROOT" deterministic_mode && det=1
  fi
  if [[ "$det" == "1" ]]; then
    frozen="$(DRUPILOT_PROJECT_DIR="$ROOT" lock_get "$key" "")"
    if [[ -n "$frozen" ]] && printf '%s' "$frozen" | jq -e --argjson pv "$PREVIEW" '.preview == $pv and (.available | type) == "boolean"' > /dev/null 2>&1; then
      printf '%s' "$frozen" | jq -c '{available, release: (.release // null), core_compatibility: (.core_compatibility // null)}'
      return 0
    fi
  fi
  if ! feed="$(release_history_fetch "$p")"; then
    printf '{"available":"unknown","release":null,"core_compatibility":null}'; return 0
  fi
  rows="$(release_history_rows "$feed")"
  ans="$(printf '%s\n' "$rows" | release_covering "$RANGE" "$TARGET" "$PREVIEW")"
  [[ -n "$ans" ]] || ans='{"available":"unknown","release":null,"core_compatibility":null}'
  if [[ "$keep" == "1" ]] && printf '%s' "$ans" | jq -e '(.available | type) == "boolean"' > /dev/null 2>&1; then
    DRUPILOT_PROJECT_DIR="$ROOT" lock_set_json "$key" \
      "$(printf '%s' "$ans" | jq -c --argjson pv "$PREVIEW" '. + {preview: $pv}')" > /dev/null 2>&1 || true
  fi
  printf '%s' "$ans"
  return 0
}
printf '{}' > "$TMP/cov.json"
for p in $(jq -r '[.[] | select((.detector == "dependency-removed" and .rewrite == "dependency") or .detector == "base-theme-removed")
                   | .replacement_project | strings | select(test("^[a-z0-9_]+$"))] | unique[]' "$TMP/cand.json"); do
  c="$(coverage "$p")"
  jq -c --arg p "$p" --argjson c "$c" '. + {($p): $c}' "$TMP/cov.json" > "$TMP/x" && mv -f "$TMP/x" "$TMP/cov.json"
done

# The findings, their actions, the aggregates.
jq -S --slurpfile cov "$TMP/cov.json" --argjson reqs "$REQS" --arg mn "$MN" --argjson t "$TARGET" --argjson s "$SOURCE" \
  --arg c "$RANGE" --argjson pv "$PREVIEW" --argjson off "$([[ "$OFFLINE" == "1" ]] && echo true || echo false)" \
  --arg majors "$MAJORS" '
  $cov[0] as $cv
  # (Not `.available // "unknown"`: `//` reads false as missing.)
  | def avail: if .replacement_project == null then null
               else ($cv[.replacement_project] // {}) | if has("available") then .available else "unknown" end end;
    def rel: if .replacement_project == null then null else ($cv[.replacement_project].release // null) end;
    def action:
      (.replacement_project as $rp | $rp != null and ($reqs | index($rp)) != null) as $req
      | if .detector == "namespace-move" then "note"
      elif .detector == "base-theme-removed" then (if $req then "composer-required" else "decision" end)
      elif .detector == "library-removed" or .detector == "migrate-drupal-usage" or .rewrite != "dependency"
           or .via == "namespace" or .via == "class" then "hard-break"
      elif $req then "composer-required"
      elif .replacement_available == true then "rewrite"
      elif .replacement_available == false then "blocked"
      else "verify" end;
    def sev: if .action == "note" or .action == "composer-required" then "info"
             elif .action == "rewrite" or .action == "verify" then "warning" else "error" end;
    def msg:
      (if .kind == "library" then "the library \(.name)" elif .kind == "theme" then "the theme \(.name)" else .name end) as $what
      | if .action == "note" then
          "\(.name) moves from \(.from_ns) to \(.to_ns) in \(.introduced_in) (announced): refer to the plugin by its ID, not its class"
        elif .action == "decision" then
          "\($what) was removed from Drupal core in \(.removed_in): choose a new base theme"
          + (if .core_alternative then " (core has \(.core_alternative))" else "" end)
          + (if .replacement_project then " or require the contrib theme \(.replacement_project)" else "" end)
        elif .action == "hard-break" then
          if .via == "class" then
            "\(.class) (\(.from_ns)) is gone from core in \(.removed_in) with the \(.name) module"
            + (if .replacement_project then ", which the contrib project \(.replacement_project) carries on: refer to the plugin by its ID, or depend on \(.replacement_project):\(.name)" else "" end)
          elif .detector == "migrate-drupal-usage" then "\(.name) was removed from Drupal core in \(.removed_in): a module that uses it cannot target Drupal \($t)"
          elif .kind == "library" then "\($what) was removed from Drupal core in \(.removed_in): the code that needs it must change"
          else "\($what) was removed from Drupal core in \(.removed_in) with no replacement: the code that needs it must change" end
        elif .action == "composer-required" then
          "\($what) was removed from Drupal core in \(.removed_in); composer.json already requires drupal/\(.replacement_project)"
          + (if .kind == "theme" then ", which provides it" else ": declare the dependency as \(.replacement_project):\(.name)" end)
        elif .action == "rewrite" then
          "\($what) was removed from Drupal core in \(.removed_in); release \(.covering_release) of the contrib project \(.replacement_project) covers \($c): depend on \(.replacement_project):\(.name) and require drupal/\(.replacement_project)"
        elif .action == "blocked" then
          "\($what) was removed from Drupal core in \(.removed_in) and no release of the contrib project \(.replacement_project) covers \($c): a blocking dependency (never rewritten)"
        else
          "\($what) was removed from Drupal core in \(.removed_in); whether a release of the contrib project \(.replacement_project) covers \($c) is unknown: see https://www.drupal.org/project/\(.replacement_project)"
        end;
  [.[] | . + {replacement_available: avail, covering_release: rel}
       | . + {action: action} | . + {hard_break: (.action == "decision" or .action == "hard-break"), severity: sev}
       | . + {message: msg}
       | {detector, name, kind, removed_in, file, line, evidence, rewrite, replacement_project, core_alternative,
          replacement_available, covering_release, action, hard_break, severity, message}]
  | sort_by([.file, .line, .detector, .name]) as $f
  | ($f | map(select(.action != "note")) | group_by([.detector, .name])
      | map(.[0] as $h | {detector: $h.detector, name: $h.name, kind: $h.kind, removed_in: $h.removed_in, rewrite: $h.rewrite,
                          replacement_project: $h.replacement_project, core_alternative: $h.core_alternative,
                          replacement_available: $h.replacement_available, covering_release: $h.covering_release,
                          action: ([.[].action] | if index("hard-break") then "hard-break" else .[0] end),
                          hard_break: any(.[]; .hard_break), files: ([.[].file] | unique)})) as $cr
  | {tool: "scan-removals", subject: $mn, target_major: $t, source_major: $s,
     majors: ($majors | split(" ") | map(select(length > 0) | tonumber)), range: (if $c == "" then null else $c end),
     preview: $pv, offline: $off, findings: $f, core_removals: $cr,
     hard_breaks: [$cr[] | select(.hard_break) | {id: .detector, name, files}]}' "$TMP/cand.json" > "$TMP/report.json" \
  || die "Could not build the removals report." 1

if [[ "$AS_JSON" == "1" ]]; then
  cat "$TMP/report.json"
  exit 0
fi
N="$(jq '.findings | length' "$TMP/report.json")"
HB="$(jq -r '[.hard_breaks[] | "\(.id) \(.name)"] | join(", ")' "$TMP/report.json")"
if [[ "$N" == "0" ]]; then
  log_ok "scan-removals: nothing $MN takes from core is removed in Drupal ${MAJORS# } (range ${RANGE:-?})."
else
  jq -r '.findings[] | "  \(.action)\t\(.file):\(.line)\t\(.message)"' "$TMP/report.json" >&2
  log_info "scan-removals: $N finding(s); hard breaks: ${HB:-none}."
fi
jq -r '.findings[] | "\(.detector):\(.name)\t\(.file):\(.line)\t\(.action)"' "$TMP/report.json"
exit 0
