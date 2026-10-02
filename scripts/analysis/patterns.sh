#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/patterns.sh
# The per-project LEARNED-PATTERN CATALOG: the pitfalls a port of this project
# already hit (a Rector change that had to be reverted, a fix made after the
# validate loop, a core signature change, a hygiene defect), each with a
# detector and the fix, so the NEXT module — or the next layer of a set — is
# checked for them BEFORE it is ported (prevention) instead of being repaired
# after. One catalog per project: <Drupal root>/.drupilot/patterns.json (the
# visible, self-gitignored artifacts dir; DRUPILOT_PATTERNS_FILE points it at a
# committed file; a module ported by /drupilot-layers uses the set's catalog —
# see common.sh patterns_file). It is plain JSON, meant to be reviewed and
# edited by hand.
#
# Usage:
#   patterns.sh list    [--catalog F] [--subject DIR] [--json]
#   patterns.sh scan    --subject DIR [--catalog F] [--drupal-root DIR]
#                       [--no-rules] [--json]
#   patterns.sh add     --id ID --fix TEXT --why TEXT
#                       (--pattern ERE [--files GLOBS] [--ignore-case] | --rule REF)
#                       [--kind KIND] [--symbol S] [--category C]
#                       [--change-record URL] [--subject DIR] [--module M]
#                       [--layer N] [--catalog F] [--json] [--dry-run]
#   patterns.sh remove  --id ID [--catalog F] [--subject DIR] [--dry-run]
#   patterns.sh harvest --subject DIR [--manifest F] [--catalog F] [--json]
#   patterns.sh export  [--catalog F] [--subject DIR] [--id ID[,ID]]
#                       [--with-source]
#
# Subcommands:
#   list     Print the catalog: one `id<TAB>kind<TAB>hits<TAB>detector` line
#            per entry (or the entries as a JSON array with --json). Read-only.
#   scan     Run every detector over the subject (before porting it) and print
#            the hits: `[pattern:<id>] file:line fix` lines, or with --json
#            {tool, subject, machine_name, catalog, catalog_exists, patterns,
#             total, skipped:[{id, reason}],
#             by_pattern:[{id, kind, hits, why, fix, source}],
#             hits:[{id, kind, via, file, line, text, severity, why, fix}]}.
#            Read-only. A hit is a must-check item for the port: the fix that
#            worked before is the starting point, not an automatic edit.
#   add      Record a pattern (at the end of a port). Upsert by id: a known id
#            gets hits+1, the new source appended to seen_in and any field given
#            updated. Atomic (temp file + mv). --dry-run prints the resulting
#            entry and writes nothing.
#   remove   Delete an entry by id (--dry-run prints it instead).
#   harvest  Propose candidates from the subject's port record (the manifest's
#            rector_reversions / post_port_fixes merged with the decision log,
#            common.sh port_record_json): each needs a detector before `add`.
#            Read-only; JSON array with --json, else one line per candidate.
#   export   Print the entries that have an ERE detector in the shape of
#            config/deprecations.json (`{deprecations:[{pattern, symbol,
#            category, why, fix}]}`) on STDOUT, to contribute them upstream.
#            The module/layer are left out unless --with-source.
#
# Options:
#   --catalog F        Catalog file (default: common.sh patterns_file for the
#                      subject, or for the current directory).
#   --subject DIR      The module/theme (scan, harvest: required; add: the
#                      source module, its machine name is the default --module).
#   --id ID            Stable id: lowercase letters, digits, '.', '_' or '-'.
#   --kind KIND        rector-reversion | post-port-fix | signature-change |
#                      port-safety | hygiene | other (default: other).
#   --pattern ERE      A POSIX ERE (grep -E) matched per line of the source
#                      files; no PCRE (\d, lookarounds). One that matches an
#                      empty line (it would match every line) is refused.
#   --files GLOBS      Comma-separated basename globs the ERE runs on (default:
#                      *.php,*.module,*.inc,*.install,*.theme,*.profile,
#                      *.engine,*.yml,*.twig,*.js).
#   --ignore-case      Match the ERE case-insensitively.
#   --rule REF         Reuse a deterministic checker as the detector:
#                      port-safety:<check> (check-port-safety.sh, e.g.
#                      port-safety:fapi-callable) or signature:<id>
#                      (scan-signature-changes.sh, an id of .signature_changes in
#                      config/deprecations.json, e.g. signature:entity-get-original).
#   --fix TEXT / --why TEXT   The fix that worked and why it was needed (required).
#   --symbol S         Symbol for the export (default: the id).
#   --category C       deprecations.json category for the export (default from
#                      the kind).
#   --change-record U  A drupal.org change record or issue URL.
#   --module M         Source module (default: the subject's machine name).
#   --layer N          Source layer (default: the subject's recorded layer).
#   --manifest F       harvest: port manifest (default: the subject's).
#   --drupal-root DIR  scan: passed to the rule detectors.
#   --no-rules         scan: run only the ERE detectors (no checker runs).
#   --with-source      export: keep `_source: {module, layer}` on each entry.
#   --json             JSON on STDOUT.
#   --dry-run          add/remove: print, write nothing.
#   -h, --help         Show this help.
#
# Catalog schema (version 1):
#   {version: 1, patterns: [{id, kind, detector: {pattern, files, ignore_case,
#    rule}, symbol, category, why, fix, change_record,
#    source: {module, layer, date}, seen_in: [{module, layer, date}], hits,
#    created, updated}]}
# A detector has a pattern, a rule or both (a hit from either counts).
#
# Output: STDOUT is the payload (lines or JSON); logs go to STDERR.
# Exit codes: 0 ok (hits are data, never a failure) · 1 usage error, jq
# missing, invalid catalog or write error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

KINDS="rector-reversion post-port-fix signature-change port-safety hygiene other"
DEFAULT_FILES="*.php,*.module,*.inc,*.install,*.theme,*.profile,*.engine,*.yml,*.twig,*.js"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { print_usage "$0"; }

CMD="${1:-}"
case "$CMD" in
  -h|--help) usage; exit 0;;
  list|scan|add|remove|harvest|export) shift;;
  "") log_err "Missing subcommand (list, scan, add, remove, harvest or export)."; usage >&2; exit 1;;
  *) log_err "Unknown subcommand: $CMD"; usage >&2; exit 1;;
esac

CATALOG=""; SUBJECT=""; ID=""; KIND=""; PATTERN=""; FILES=""; ICASE=0; RULE=""
FIX=""; WHY=""; SYMBOL=""; CATEGORY=""; CR=""; MODULE=""; LAYER=""; MANIFEST=""
ROOT_OPT=""; NO_RULES=0; WITH_SOURCE=0; AS_JSON=0; DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --catalog) CATALOG="${2:-}"; shift 2 || die "--catalog needs a file" 1;;
    --catalog=*) CATALOG="${1#*=}"; shift;;
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a directory" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --id) ID="${2:-}"; shift 2 || die "--id needs a value" 1;;
    --id=*) ID="${1#*=}"; shift;;
    --kind) KIND="${2:-}"; shift 2 || die "--kind needs a value" 1;;
    --kind=*) KIND="${1#*=}"; shift;;
    --pattern) PATTERN="${2:-}"; shift 2 || die "--pattern needs a value" 1;;
    --pattern=*) PATTERN="${1#*=}"; shift;;
    --files) FILES="${2:-}"; shift 2 || die "--files needs a value" 1;;
    --files=*) FILES="${1#*=}"; shift;;
    --ignore-case) ICASE=1; shift;;
    --rule) RULE="${2:-}"; shift 2 || die "--rule needs a value" 1;;
    --rule=*) RULE="${1#*=}"; shift;;
    --fix) FIX="${2:-}"; shift 2 || die "--fix needs a value" 1;;
    --fix=*) FIX="${1#*=}"; shift;;
    --why) WHY="${2:-}"; shift 2 || die "--why needs a value" 1;;
    --why=*) WHY="${1#*=}"; shift;;
    --symbol) SYMBOL="${2:-}"; shift 2 || die "--symbol needs a value" 1;;
    --symbol=*) SYMBOL="${1#*=}"; shift;;
    --category) CATEGORY="${2:-}"; shift 2 || die "--category needs a value" 1;;
    --category=*) CATEGORY="${1#*=}"; shift;;
    --change-record) CR="${2:-}"; shift 2 || die "--change-record needs a value" 1;;
    --change-record=*) CR="${1#*=}"; shift;;
    --module) MODULE="${2:-}"; shift 2 || die "--module needs a value" 1;;
    --module=*) MODULE="${1#*=}"; shift;;
    --layer) LAYER="${2:-}"; shift 2 || die "--layer needs a value" 1;;
    --layer=*) LAYER="${1#*=}"; shift;;
    --manifest) MANIFEST="${2:-}"; shift 2 || die "--manifest needs a file" 1;;
    --manifest=*) MANIFEST="${1#*=}"; shift;;
    --drupal-root) ROOT_OPT="${2:-}"; shift 2 || die "--drupal-root needs a directory" 1;;
    --drupal-root=*) ROOT_OPT="${1#*=}"; shift;;
    --no-rules) NO_RULES=1; shift;;
    --with-source) WITH_SOURCE=1; shift;;
    --json) AS_JSON=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_err "Unknown argument: $1"; usage >&2; exit 1;;
  esac
done

have_cmd jq || die "jq is required for patterns.sh." 1

for v in "$SUBJECT" "$CATALOG" "$MANIFEST" "$ROOT_OPT"; do
  case "$v" in *"<"*">"*) die "An argument looks like an unsubstituted placeholder: '$v'." 1;; esac
done

SUBJECT_ABS=""
if [[ -n "$SUBJECT" ]]; then
  [[ -d "$SUBJECT" ]] || die "Subject directory not found: '$SUBJECT'." 1
  SUBJECT_ABS="$(cd "$SUBJECT" && pwd)"
fi
case "$CMD" in
  scan|harvest) [[ -n "$SUBJECT_ABS" ]] || die "'$CMD' needs --subject DIR." 1;;
esac

if [[ -z "$CATALOG" ]]; then
  CATALOG="$(patterns_file "${SUBJECT_ABS:-$PWD}")"
fi
case "$CATALOG" in
  /*) ;;
  *) CATALOG="$PWD/$CATALOG";;
esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-patterns.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# load_catalog -> the catalog JSON (compact) on STDOUT; `{"version":1,
# "patterns":[]}` when the file does not exist. Returns 1 for a file that is
# not a valid catalog (never overwrite a hand-edited file jq cannot read).
load_catalog() {
  if [[ ! -e "$CATALOG" ]]; then
    printf '{"version":1,"patterns":[]}'
    return 0
  fi
  jq -ce 'if type == "object" and ((.patterns // []) | type) == "array"
          then .version = (.version // 1) | .patterns = (.patterns // []) else error("bad") end' \
    "$CATALOG" 2>/dev/null || return 1
  return 0
}

# ere_problem <ere> -> a reason on STDOUT when the ERE must be refused (empty
# otherwise); warns on non-portable escapes.
ere_problem() {
  local p="$1" rc=0
  case "$p" in
    *'(?'*) printf 'uses a PCRE group "(?" (lookaround / non-capturing): not POSIX ERE'; return 0;;
    *'\d'*|*'\D'*) printf 'uses \\d / \\D (PCRE): write [0-9] or [[:digit:]]'; return 0;;
  esac
  grep -E -e "$p" </dev/null >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 2 ]]; then printf 'is not a valid POSIX ERE for grep -E'; return 0; fi
  if printf '\n' | grep -qE -e "$p" 2>/dev/null; then
    printf 'matches an empty line, so it would match every line'
    return 0
  fi
  case "$p" in
    *'\s'*|*'\S'*|*'\w'*|*'\W'*|*'\b'*|*'\B'*|*'\<'*|*'\>'*)
      log_warn "The ERE uses a GNU escape (\\s, \\w, \\b, \\<...): prefer [[:space:]] / [[:alnum:]_] so it works with every grep." ;;
  esac
  return 0
}

# rule_problem <ref> -> a reason on STDOUT when the rule reference is unknown.
rule_problem() {
  local ref="$1" name checks
  case "$ref" in
    port-safety:*)
      name="${ref#port-safety:}"
      # The check names come from check-port-safety.sh itself (its ALL_CHECKS).
      checks="$(sed -n 's/^ALL_CHECKS="\(.*\)"$/\1/p' "$SCRIPT_DIR/check-port-safety.sh" 2>/dev/null | head -n 1)"
      case " $checks " in
        *" $name "*) ;;
        *) printf "names an unknown check-port-safety.sh check '%s'" "$name";;
      esac;;
    signature:*)
      name="${ref#signature:}"
      if ! jq -e --arg id "$name" 'any(.signature_changes[]?; .id == $id)' "$(plugin_root)/config/deprecations.json" >/dev/null 2>&1; then
        printf "names an unknown signature change '%s' (see .signature_changes in config/deprecations.json)" "$name"
      fi;;
    *) printf "must be port-safety:<check> or signature:<id>";;
  esac
  return 0
}

# write_catalog <json> -> atomically replace the catalog. A catalog in a
# `.drupilot` dir gets the dir's self-ignore (`*`) so it never lands in a patch.
write_catalog() {
  local json="$1" d tmp
  d="$(dirname "$CATALOG")"
  mkdir -p "$d" || return 1
  if [[ "$(basename "$d")" == ".drupilot" && ! -e "$d/.gitignore" ]]; then
    printf '*\n' > "$d/.gitignore" 2>/dev/null || true
  fi
  tmp="$(mktemp "$CATALOG.XXXXXX")" || return 1
  chmod 0644 "$tmp" 2>/dev/null || true
  if printf '%s\n' "$json" | jq '.' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$CATALOG" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp"; return 1
  fi
  return 0
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------
cmd_list() {
  local cat
  cat="$(load_catalog)" || die "Not a valid pattern catalog: $CATALOG" 1
  [[ -e "$CATALOG" ]] || log_info "No pattern catalog yet at $CATALOG."
  if [[ "$AS_JSON" == "1" ]]; then
    printf '%s\n' "$cat" | jq -c '.patterns'
  else
    printf '%s\n' "$cat" | jq -r '.patterns[] |
      [.id, (.kind // "other"), ((.hits // 0) | tostring),
       ([(.detector.pattern // empty | "ere:" + .), (.detector.rule // empty)] | join(" + "))] | @tsv'
    log_info "Catalog: $CATALOG ($(printf '%s' "$cat" | jq '.patterns | length') pattern(s))"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# scan
# ---------------------------------------------------------------------------
# glob_match <basename> <comma-separated globs> -> 0 when one glob matches.
glob_match() {
  local name="$1" globs="$2" g old_ifs="$IFS"
  IFS=','
  for g in $globs; do
    IFS="$old_ifs"
    g="$(trim "$g")"
    [[ -n "$g" ]] || continue
    # shellcheck disable=SC2254 # the glob is the pattern on purpose
    case "$name" in $g) IFS="$old_ifs"; return 0;; esac
  done
  IFS="$old_ifs"
  return 1
}

cmd_scan() {
  local cat n i e id kind pat files icase rule why fix reason scan_dir mn
  local hits="$TMP/hits.jsonl" skipped="$TMP/skipped.jsonl" rules="$TMP/rules.txt"
  : > "$hits"; : > "$skipped"; : > "$rules"
  cat="$(load_catalog)" || { log_warn "Not a valid pattern catalog (ignored): $CATALOG"; cat='{"version":1,"patterns":[]}'; }
  mn="$(subject_machine_name "$SUBJECT_ABS" 2>/dev/null || basename "$SUBJECT_ABS")"
  scan_dir="$(cd "$SUBJECT_ABS" && pwd -P)"
  n="$(printf '%s' "$cat" | jq '.patterns | length')"

  # All candidate files once (relative to the subject), skipping trees that are
  # never the subject's own code.
  ( cd "$scan_dir" && find . \( -name .git -o -name vendor -o -name node_modules -o -name .drupilot -o -name .ddev \) -prune \
      -o -type f -print 2>/dev/null ) | sed 's|^\./||' | LC_ALL=C sort > "$TMP/files.txt" || true

  i=0
  while (( i < n )); do
    e="$(printf '%s' "$cat" | jq -c ".patterns[$i]")"
    i=$((i+1))
    id="$(printf '%s' "$e" | jq -r '.id // ""')"
    kind="$(printf '%s' "$e" | jq -r '.kind // "other"')"
    pat="$(printf '%s' "$e" | jq -r '.detector.pattern // ""')"
    files="$(printf '%s' "$e" | jq -r '.detector.files // ""')"
    icase="$(printf '%s' "$e" | jq -r 'if .detector.ignore_case == true then 1 else 0 end')"
    rule="$(printf '%s' "$e" | jq -r '.detector.rule // ""')"
    why="$(printf '%s' "$e" | jq -r '.why // ""')"
    fix="$(printf '%s' "$e" | jq -r '.fix // ""')"
    if [[ -z "$id" ]]; then
      printf '%s\n' "$(jq -nc --arg r "entry #$i has no id" '{id: null, reason: $r}')" >> "$skipped"; continue
    fi
    if [[ -z "$pat" && -z "$rule" ]]; then
      jq -nc --arg id "$id" '{id: $id, reason: "no detector (pattern or rule)"}' >> "$skipped"; continue
    fi
    if [[ -n "$rule" ]]; then
      reason="$(rule_problem "$rule")"
      if [[ -n "$reason" ]]; then
        jq -nc --arg id "$id" --arg r "rule $reason" '{id: $id, reason: $r}' >> "$skipped"
      elif [[ "$NO_RULES" != "1" ]]; then
        printf '%s\t%s\t%s\t%s\n' "$rule" "$id" "$kind" "$(printf '%s' "$e" | jq -c '{why, fix}')" >> "$rules"
      fi
    fi
    [[ -n "$pat" ]] || continue
    reason="$(ere_problem "$pat")"
    if [[ -n "$reason" ]]; then
      jq -nc --arg id "$id" --arg r "pattern $reason" '{id: $id, reason: $r}' >> "$skipped"; continue
    fi
    [[ -n "$files" ]] || files="$DEFAULT_FILES"
    : > "$TMP/pfiles.txt"
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      glob_match "$(basename "$f")" "$files" && printf '%s\n' "$f" >> "$TMP/pfiles.txt"
    done < "$TMP/files.txt"
    [[ -s "$TMP/pfiles.txt" ]] || continue
    local gflags="-nHE"
    [[ "$icase" == "1" ]] && gflags="-inHE"
    ( cd "$scan_dir" && tr '\n' '\0' < "$TMP/pfiles.txt" | xargs -0 grep "$gflags" -e "$pat" -- 2>/dev/null ) > "$TMP/grep.txt" || true
    [[ -s "$TMP/grep.txt" ]] || continue
    # file:line:text -> JSON hits (paths are relative and colon-free in practice).
    awk '{ if (match($0, /^[^:]+:[0-9]+:/)) { pre = substr($0, 1, RLENGTH - 1); txt = substr($0, RLENGTH + 1);
             c = index(pre, ":"); printf "%s\t%s\t%s\n", substr(pre, 1, c - 1), substr(pre, c + 1), txt } }' "$TMP/grep.txt" \
      | while IFS=$'\t' read -r f l t; do
          jq -nc --arg id "$id" --arg kind "$kind" --arg f "$f" --arg l "$l" --arg t "$(trim "$t" | cut -c1-200)" \
            --arg why "$why" --arg fix "$fix" \
            '{id: $id, kind: $kind, via: "pattern", file: $f, line: ($l | tonumber), text: $t, severity: null, why: $why, fix: $fix}'
        done >> "$hits"
  done

  # Rule detectors: one run of each checker for every rule the catalog names.
  if [[ -s "$rules" ]]; then
    local ps_checks sig_ids out rc root_args=()
    [[ -n "$ROOT_OPT" ]] && root_args=(--drupal-root "$ROOT_OPT")
    ps_checks="$(awk -F'\t' '$1 ~ /^port-safety:/ { sub(/^port-safety:/, "", $1); print $1 }' "$rules" | LC_ALL=C sort -u | paste -sd, -)"
    sig_ids="$(awk -F'\t' '$1 ~ /^signature:/ { sub(/^signature:/, "", $1); print $1 }' "$rules" | LC_ALL=C sort -u | paste -sd, -)"
    : > "$TMP/rule-findings.jsonl"
    if [[ -n "$ps_checks" ]]; then
      rc=0
      out="$(bash "$SCRIPT_DIR/check-port-safety.sh" --subject "$SUBJECT_ABS" --checks "$ps_checks" --no-diff --json ${root_args[@]+"${root_args[@]}"} 2>"$TMP/ps.log")" || rc=$?
      if [[ "$rc" -eq 0 || "$rc" -eq 3 ]] && printf '%s' "$out" | jq -e '.findings' >/dev/null 2>&1; then
        printf '%s' "$out" | jq -c '.findings[] | {rule: ("port-safety:" + .check), file, line, text: .message, severity}' >> "$TMP/rule-findings.jsonl"
      else
        log_warn "check-port-safety.sh did not run (exit $rc); the port-safety rule detectors were skipped."
        printf '%s' "$ps_checks" | tr ',' '\n' | while IFS= read -r c; do
          awk -F'\t' -v r="port-safety:$c" '$1 == r { print $2 }' "$rules" | while IFS= read -r pid; do
            jq -nc --arg id "$pid" --arg r "rule detector port-safety:$c could not run" '{id: $id, reason: $r}'
          done
        done >> "$skipped"
      fi
    fi
    if [[ -n "$sig_ids" ]]; then
      rc=0
      out="$(bash "$SCRIPT_DIR/scan-signature-changes.sh" --subject "$SUBJECT_ABS" --json ${root_args[@]+"${root_args[@]}"} 2>"$TMP/sig.log")" || rc=$?
      if [[ "$rc" -eq 0 || "$rc" -eq 3 ]] && printf '%s' "$out" | jq -e '.findings' >/dev/null 2>&1; then
        printf '%s' "$out" | jq -c '.findings[] | {rule: ("signature:" + .id), file, line, text: .message, severity}' >> "$TMP/rule-findings.jsonl"
      else
        log_warn "scan-signature-changes.sh did not run (exit $rc); the signature rule detectors were skipped."
        printf '%s' "$sig_ids" | tr ',' '\n' | while IFS= read -r c; do
          awk -F'\t' -v r="signature:$c" '$1 == r { print $2 }' "$rules" | while IFS= read -r pid; do
            jq -nc --arg id "$pid" --arg r "rule detector signature:$c could not run" '{id: $id, reason: $r}'
          done
        done >> "$skipped"
      fi
    fi
    if [[ -s "$TMP/rule-findings.jsonl" ]]; then
      while IFS=$'\t' read -r r pid pkind meta; do
        jq -c --arg r "$r" --arg id "$pid" --arg kind "$pkind" --argjson m "$meta" \
          'select(.rule == $r) | {id: $id, kind: $kind, via: $r, file, line, text: (.text // ""), severity, why: ($m.why // ""), fix: ($m.fix // "")}' \
          "$TMP/rule-findings.jsonl" >> "$hits"
      done < "$rules"
    fi
  fi

  local hits_json skipped_json report
  hits_json="$(jq -sc 'unique_by([.id, .via, .file, .line]) | sort_by(.file, .line, .id)' "$hits")"
  skipped_json="$(jq -sc '.' "$skipped")"
  report="$(jq -nc --arg subject "$SUBJECT_ABS" --arg mn "$mn" --arg catalog "$CATALOG" \
    --argjson exists "$([[ -e "$CATALOG" ]] && echo true || echo false)" \
    --argjson cat "$cat" --argjson hits "$hits_json" --argjson skipped "$skipped_json" '
    {tool: "patterns", subject: $subject, machine_name: $mn, catalog: $catalog, catalog_exists: $exists,
     patterns: ($cat.patterns | length), total: ($hits | length), skipped: $skipped,
     by_pattern: [ $cat.patterns[] | . as $p | ([$hits[] | select(.id == $p.id)] | length) as $n
                   | select($n > 0)
                   | {id: $p.id, kind: ($p.kind // "other"), hits: $n, why: ($p.why // null), fix: ($p.fix // null),
                      source: ($p.source // null)} ],
     hits: $hits}')"

  if [[ "$AS_JSON" == "1" ]]; then
    printf '%s\n' "$report"
  else
    printf '%s\n' "$report" | jq -r '.hits[] | "[pattern:\(.id)] \(.file):\(.line) \(.fix)"'
  fi
  if [[ ! -e "$CATALOG" ]]; then
    log_info "No pattern catalog yet at $CATALOG: nothing learned to check."
  else
    log_info "Pattern scan of $mn: $(printf '%s' "$report" | jq -r '"\(.total) hit(s) from \(.by_pattern | length) of \(.patterns) pattern(s)"') (catalog: $CATALOG)."
    printf '%s' "$report" | jq -r '.skipped[] | "skipped \(.id // "?"): \(.reason)"' | while IFS= read -r l; do log_warn "$l"; done
  fi
  return 0
}

# ---------------------------------------------------------------------------
# add / remove
# ---------------------------------------------------------------------------
cmd_add() {
  local cat reason entry new mn_default="" date
  [[ -n "$ID" ]] || die "add needs --id ID." 1
  printf '%s' "$ID" | grep -Eq '^[a-z0-9][a-z0-9._-]*$' || die "Invalid --id '$ID': use lowercase letters, digits, '.', '_' or '-'." 1
  [[ -n "$FIX" ]] || die "add needs --fix TEXT (the fix that worked)." 1
  [[ -n "$WHY" ]] || die "add needs --why TEXT (why it was needed)." 1
  [[ -n "$PATTERN" || -n "$RULE" ]] || die "add needs a detector: --pattern ERE and/or --rule REF." 1
  local kind_given=1
  [[ -n "$KIND" ]] || { KIND="other"; kind_given=0; }
  case " $KINDS " in *" $KIND "*) ;; *) die "Unknown --kind '$KIND'. Valid: ${KINDS// /, }" 1;; esac
  if [[ -n "$PATTERN" ]]; then
    reason="$(ere_problem "$PATTERN")"
    [[ -z "$reason" ]] || die "Refusing --pattern: it $reason." 1
  fi
  [[ -z "$FILES" || -n "$PATTERN" ]] || die "--files only applies to --pattern." 1
  if [[ -n "$RULE" ]]; then
    reason="$(rule_problem "$RULE")"
    [[ -z "$reason" ]] || die "Refusing --rule '$RULE': it $reason." 1
  fi
  [[ -z "$LAYER" ]] || printf '%s' "$LAYER" | grep -Eq '^[0-9]+$' || die "--layer must be a number." 1
  if [[ -n "$SUBJECT_ABS" ]]; then
    mn_default="$(subject_machine_name "$SUBJECT_ABS" 2>/dev/null || basename "$SUBJECT_ABS")"
    [[ -n "$LAYER" ]] || LAYER="$(state_get "$SUBJECT_ABS" '.portfolio.layer' '')"
  fi
  [[ -n "$MODULE" ]] || MODULE="$mn_default"
  cat="$(load_catalog)" || die "Not a valid pattern catalog (fix or move it first): $CATALOG" 1
  date="$(now_utc)"
  entry="$(jq -nc --arg id "$ID" --arg kind "$KIND" --arg pat "$PATTERN" --arg files "$FILES" \
    --argjson icase "$([[ "$ICASE" == "1" ]] && echo true || echo null)" --arg rule "$RULE" \
    --arg symbol "$SYMBOL" --arg category "$CATEGORY" --arg why "$WHY" --arg fix "$FIX" --arg cr "$CR" \
    --arg module "$MODULE" --arg layer "$LAYER" --arg at "$date" '
    def nz: if . == "" then null else . end;
    {id: $id, kind: $kind,
     detector: {pattern: ($pat | nz), files: ($files | nz), ignore_case: $icase, rule: ($rule | nz)},
     symbol: ($symbol | nz), category: ($category | nz), why: $why, fix: $fix, change_record: ($cr | nz),
     source: {module: ($module | nz), layer: (if $layer == "" then null else ($layer | tonumber) end), date: $at}}')"
  new="$(jq -c --argjson e "$entry" --argjson kg "$kind_given" '
    def clean: if type == "object" then with_entries(select(.value != null) | .value |= clean) else . end;
    ($e | clean) as $e
    | if any(.patterns[]; .id == $e.id) then
        .patterns |= map(if .id == $e.id then
          (. as $o
           | ($o * ($e | del(.source) | if $kg == 0 then del(.kind) else . end))
           | .hits = (($o.hits // 0) + 1)
           | .seen_in = ((($o.seen_in // []) + [$e.source]) | unique_by([.module, .layer]))
           | .updated = $e.source.date)
        else . end)
      else .patterns += [$e + {hits: 1, seen_in: [$e.source], created: $e.source.date, updated: $e.source.date}] end' <<<"$cat")"
  local stored
  stored="$(jq -c --arg id "$ID" '.patterns[] | select(.id == $id)' <<<"$new")"
  if [[ "$DRY" == "1" ]]; then
    printf '%s\n' "$stored"
    log_info "Dry run: $CATALOG left unchanged."
    return 0
  fi
  write_catalog "$new" || die "Could not write the pattern catalog: $CATALOG" 1
  if [[ "$AS_JSON" == "1" ]]; then
    printf '%s\n' "$stored"
  else
    printf '%s\n' "$ID"
  fi
  log_ok "Pattern '$ID' recorded ($(jq -r '.hits' <<<"$stored") hit(s)) in $CATALOG"
  return 0
}

cmd_remove() {
  local cat new
  [[ -n "$ID" ]] || die "remove needs --id ID." 1
  cat="$(load_catalog)" || die "Not a valid pattern catalog: $CATALOG" 1
  jq -e --arg id "$ID" 'any(.patterns[]; .id == $id)' <<<"$cat" >/dev/null 2>&1 || die "No pattern '$ID' in $CATALOG." 1
  if [[ "$DRY" == "1" ]]; then
    jq -c --arg id "$ID" '.patterns[] | select(.id == $id)' <<<"$cat"
    log_info "Dry run: $CATALOG left unchanged."
    return 0
  fi
  new="$(jq -c --arg id "$ID" '.patterns |= map(select(.id != $id))' <<<"$cat")"
  write_catalog "$new" || die "Could not write the pattern catalog: $CATALOG" 1
  printf '%s\n' "$ID"
  log_ok "Pattern '$ID' removed from $CATALOG"
  return 0
}

# ---------------------------------------------------------------------------
# harvest
# ---------------------------------------------------------------------------
cmd_harvest() {
  local rec cat out
  rec="$(port_record_json "$SUBJECT_ABS" "$MANIFEST")"
  [[ -n "$rec" && "$rec" != "null" ]] || die "Could not read the port record of $SUBJECT_ABS." 1
  cat="$(load_catalog)" || { log_warn "Not a valid pattern catalog (ignored): $CATALOG"; cat='{"version":1,"patterns":[]}'; }
  out="$(jq -c --argjson cat "$cat" '
    def slug: ascii_downcase | gsub("[^a-z0-9]+"; "-") | ltrimstr("-") | rtrimstr("-") | .[0:60];
    ([$cat.patterns[].id]) as $known
    | .machine_name as $mn
    | ([ .rector_reversions[]
         | {suggested_id: ("revert-" + (.rule | tostring | split("\\") | last | slug)),
            kind: "rector-reversion", rule: .rule, file: (.file // null),
            why: (.why // null), fix: ("Keep the original code: do not apply " + (.rule | tostring | split("\\") | last) + " here." ),
            source: .source} ]
       + [ .post_port_fixes[]
         | {suggested_id: ("fix-" + (.fix | slug)), kind: "post-port-fix", rule: null, file: (.file // null),
            why: (.why // null), fix: .fix, detected_by: (.detected_by // null), source: .source} ])
    | map(. + {module: $mn, known: (.suggested_id as $s | any($known[]; . == $s)),
               needs: "a detector (--pattern ERE matching the pre-port code, or --rule port-safety:<check> / signature:<id>) before patterns.sh add"})' <<<"$rec")"
  if [[ "$AS_JSON" == "1" ]]; then
    printf '%s\n' "$out"
  else
    jq -r '.[] | "\(.suggested_id)\t\(.kind)\t\(.file // "-")\t\(.fix)\(if .known then "\t(already in the catalog)" else "" end)"' <<<"$out"
  fi
  log_info "$(jq 'length' <<<"$out") candidate(s) from the port record of $(jq -r '.machine_name // "the subject"' <<<"$rec"); add the ones worth preventing with 'patterns.sh add'."
  return 0
}

# ---------------------------------------------------------------------------
# export
# ---------------------------------------------------------------------------
cmd_export() {
  local cat ids_json='null' out skipped
  cat="$(load_catalog)" || die "Not a valid pattern catalog: $CATALOG" 1
  if [[ -n "$ID" ]]; then
    ids_json="$(printf '%s' "$ID" | tr ',' '\n' | jq -R . | jq -sc 'map(select(length > 0))')"
  fi
  out="$(jq -c --argjson ids "$ids_json" --argjson src "$WITH_SOURCE" '
    def cat_of: if .category then .category
                elif .kind == "signature-change" then "signature-change"
                elif .kind == "port-safety" or .kind == "rector-reversion" then "port-safety"
                else "other" end;
    [ .patterns[]
      | select($ids == null or (.id as $i | any($ids[]; . == $i)))
      | select((.detector.pattern // "") != "")
      | {pattern: .detector.pattern, symbol: (.symbol // .id), category: cat_of, why: .why, fix: .fix}
        + (if $src == 1 then {_source: {module: (.source.module // null), layer: (.source.layer // null)}} else {} end) ]
    | {deprecations: .}' <<<"$cat")"
  skipped="$(jq -r --argjson ids "$ids_json" '[.patterns[] | select($ids == null or (.id as $i | any($ids[]; . == $i))) | select((.detector.pattern // "") == "") | .id] | join(", ")' <<<"$cat")"
  [[ -z "$skipped" ]] || log_warn "Not exported (rule-only detectors have no ERE for deprecations.json): $skipped"
  if jq -e --argjson ids "$ids_json" 'any(.patterns[]; ($ids == null or (.id as $i | any($ids[]; . == $i))) and .detector.ignore_case != true and (.detector.pattern // "") != "")' <<<"$cat" >/dev/null 2>&1; then
    log_info "explain-deprecations.sh matches deprecations.json patterns case-insensitively; review case-sensitive entries before contributing."
  fi
  printf '%s\n' "$out" | jq '.'
  log_info "$(jq '.deprecations | length' <<<"$out") entr(y/ies) exported in config/deprecations.json format; verify every fact against core before contributing."
  return 0
}

case "$CMD" in
  list) cmd_list;;
  scan) cmd_scan;;
  add) cmd_add;;
  remove) cmd_remove;;
  harvest) cmd_harvest;;
  export) cmd_export;;
esac
exit 0
