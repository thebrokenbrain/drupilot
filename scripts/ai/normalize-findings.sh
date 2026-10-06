#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/ai/normalize-findings.sh
# Turn one stage's raw tool reports into findings.json (T-M4-05, AR-10, 05 §2.4,
# ADR 0022): every finding with its stable id, subject-relative file, anchor,
# symbol, normalized message, occurrence, severity, scope and class; findings
# of different tools about the same symbol at the same anchor merged (the
# precedence rector > phpstan > catalog > phpcs keeps its record, sources[]
# lists every tool); sorted by file, anchor and id. A pure function of the raw
# files, the target major and the soft-deprecation policy: no tool runs, no
# PHP, so the result is the same on every platform (DET-2).
#
# Reads <raw-dir>/<NN>-<stage>-{index,rector,phpstan,phpcs,port-safety,
# signatures,metadata,anchors}.json as scripts/ai/extract.sh writes them (any
# but the index may be missing).
#
#   id      "F-" + the first 12 hex of sha256(tool␟rule␟file␟anchor␟symbol␟
#           message␟occurrence) (␟ = 0x1f); the line is not part of it
#   rule    Rector's FQCN; PHPStan's identifier (phpstan:untyped:<8 hex of the
#           message's sha256> without one); PHPCS's source;
#           port-safety:<check>, signature:<id>, metadata:<check>
#   anchor  the innermost Namespace\Class::method or function of the line
#           (the raw anchors file, scripts/php/anchor.php), else {file}
#   scope   current, or next-major for a soft deprecation under the report or
#           defer policy (DRUPILOT_SOFT_DEPRECATIONS)
#   class   hard | soft | unknown (classify-deprecations.sh) | analysis |
#           safety | signature | metadata | style | php-target | rector
#
# Usage:
#   normalize-findings.sh (--subject DIR | --raw-dir DIR) [--stage S]
#                         [--target-major N] [--soft-policy P] [--out FILE]
#                         [--json] [-h|--help]
#     --subject DIR      the module/theme: its raw dir and findings.json are in
#                        its hidden state dir
#     --raw-dir DIR      read these raw files instead (a golden's); with no
#                        --subject, nothing is written unless --out is given
#     --stage S          the stage whose raw files to read (default assess)
#     --target-major N   default: the upgrade plan's, else DRUPILOT_TARGET_MAJOR
#     --soft-policy P    report | defer | fix (default DRUPILOT_SOFT_DEPRECATIONS)
#     --out FILE         where to write findings.json (default: the subject's
#                        state dir)
#     --json             print findings.json on STDOUT
#
# findings.json also records each tool's verdict (tools: ok | partial |
# failed | missing), so a run where a tool crashed never hashes like a clean
# one; an error PHPStan reports in a trait once per class that uses it is one
# finding in the trait's file.
#
# Exit codes: 0 written (or printed) · 1 usage error, no raw index for the
# stage, several, or one that is not JSON · 2 jq or a sha256 tool missing · 3
# classify-deprecations.sh could not classify the PHPStan report (nothing is
# written).
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""; RAW_DIR=""; STAGE="assess"; TARGET=""; POLICY=""; OUT=""; AS_JSON=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --raw-dir) RAW_DIR="${2:-}"; shift 2 || die "--raw-dir needs a value" 1;;
    --raw-dir=*) RAW_DIR="${1#*=}"; shift;;
    --stage) STAGE="${2:-}"; shift 2 || die "--stage needs a value" 1;;
    --stage=*) STAGE="${1#*=}"; shift;;
    --target-major) TARGET="${2:-}"; shift 2 || die "--target-major needs a value" 1;;
    --target-major=*) TARGET="${1#*=}"; shift;;
    --soft-policy) POLICY="${2:-}"; shift 2 || die "--soft-policy needs a value" 1;;
    --soft-policy=*) POLICY="${1#*=}"; shift;;
    --out) OUT="${2:-}"; shift 2 || die "--out needs a value" 1;;
    --out=*) OUT="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ -n "$SUBJECT" || -n "$RAW_DIR" ]] || die "Pass --subject DIR or --raw-dir DIR (see --help)." 1
[[ "$STAGE" =~ ^[a-z0-9-]+$ ]] || die "Invalid --stage '$STAGE'." 1
have_cmd jq || die "jq is required (run /drupilot-doctor)." 2
[[ -n "$(printf 'x' | sha256_hex)" ]] || die "A sha256 tool (sha256sum or shasum) is required." 2

if [[ -n "$SUBJECT" ]]; then
  [[ -d "$SUBJECT" ]] || die "Subject '$SUBJECT' is not a directory." 1
  SUBJECT="$(cd "$SUBJECT" && pwd)"
  [[ -n "$RAW_DIR" ]] || RAW_DIR="$(project_state_path "$SUBJECT")/raw"
  [[ -n "$OUT" ]] || OUT="$(project_state_dir "$SUBJECT")/findings.json"
fi
[[ -d "$RAW_DIR" ]] || die "No raw dir at $RAW_DIR (run scripts/ai/extract.sh first)." 1
# The stage's index: exactly one (extract.sh replaces a stage's files whatever
# its NN), a JSON object; the other raw files share its NN.
INDEX=""; n_ix=0
for f in "$RAW_DIR"/[0-9][0-9]-"$STAGE"-index.json; do [[ -f "$f" ]] && { INDEX="$f"; n_ix=$((n_ix + 1)); }; done
[[ -n "$INDEX" ]] || die "No raw index for stage '$STAGE' in $RAW_DIR (run scripts/ai/extract.sh --stage $STAGE)." 1
[[ "$n_ix" == "1" ]] || die "Several raw sets for stage '$STAGE' in $RAW_DIR: re-run scripts/ai/extract.sh --stage $STAGE." 1
jq -e 'type == "object"' "$INDEX" > /dev/null 2>&1 || die "The raw index $INDEX is not a JSON object: re-run scripts/ai/extract.sh --stage $STAGE." 1
NN="$(basename "$INDEX")"; NN="${NN%%-*}"
# raw TOOL -> the stage's raw file of that tool, or nothing.
raw() { [[ -f "$RAW_DIR/$NN-$STAGE-$1.json" ]] && printf '%s' "$RAW_DIR/$NN-$STAGE-$1.json"; return 0; }

if [[ -z "$TARGET" ]]; then
  TARGET="$(jq -r '.target_major // empty' "$INDEX" 2> /dev/null || true)"
  [[ -n "$TARGET" ]] || TARGET="$(DRUPILOT_PROJECT_DIR="$(subject_project_root "${SUBJECT:-$PWD}" 2> /dev/null || printf '%s' "$PWD")" resolve_target_major)"
fi
[[ "$TARGET" =~ ^[0-9]+$ ]] || die "Invalid --target-major '$TARGET'." 1
[[ -n "$POLICY" ]] || POLICY="$(config_get DRUPILOT_SOFT_DEPRECATIONS report)"
case "$POLICY" in report|defer|fix) ;; *) die "Invalid --soft-policy '$POLICY' (report, defer or fix)." 1;; esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-findings.XXXXXX")"
trap 'rm -rf "$TMP" 2> /dev/null || true' EXIT
# json_or FILE DEFAULT -> FILE when it is one JSON value, else DEFAULT in a temp file.
json_or() {
  local f="${1:-}" d="$2" n="$TMP/empty-$_jn"
  _jn=$((_jn + 1))
  if [[ -n "$f" ]] && jq -e -s 'length == 1' "$f" > /dev/null 2>&1; then printf '%s' "$f"; return 0; fi
  printf '%s\n' "$d" > "$n"; printf '%s' "$n"
  return 0
}
_jn=0
F_RECTOR="$(json_or "$(raw rector)" '{}')"
F_PHPSTAN="$(json_or "$(raw phpstan)" '{}')"
F_PHPCS="$(json_or "$(raw phpcs)" '{}')"
F_SAFETY="$(json_or "$(raw port-safety)" '{}')"
F_SIG="$(json_or "$(raw signatures)" '{}')"
F_META="$(json_or "$(raw metadata)" '{}')"
F_ANCH="$(json_or "$(raw anchors)" '{"unavailable": true}')"
MISSING="$(for t in rector phpstan phpcs port-safety signatures metadata; do [[ -n "$(raw "$t")" ]] || printf '%s ' "$t"; done)"
# The deprecations' class and symbol: classify-deprecations.sh on the PHPStan
# report. Without it every deprecation would read as a plain analysis error:
# stop rather than write that.
F_CLASS="$TMP/classify.json"
if jq -e '(.files | type) == "object" and (.files | length) > 0' "$F_PHPSTAN" > /dev/null 2>&1; then
  if ! bash "$(plugin_root)/scripts/analysis/classify-deprecations.sh" --file "$F_PHPSTAN" --target-major "$TARGET" \
       --policy "$POLICY" --json < /dev/null > "$F_CLASS" 2> "$TMP/classify.err" \
     || ! jq -e 'type == "object"' "$F_CLASS" > /dev/null 2>&1; then
    log_err "$(tail -n 3 "$TMP/classify.err" 2> /dev/null)"
    die "classify-deprecations.sh could not classify the PHPStan report: nothing is written." 3
  fi
else
  printf '{}\n' > "$F_CLASS"
fi

# Pass 1: every tool's findings as flat records (no id yet).
PRE="$TMP/pre.json"
jq -n -c --slurpfile ix "$INDEX" --slurpfile rector "$F_RECTOR" --slurpfile stan "$F_PHPSTAN" \
  --slurpfile cs "$F_PHPCS" --slurpfile safety "$F_SAFETY" --slurpfile sig "$F_SIG" --slurpfile meta "$F_META" \
  --slurpfile anch "$F_ANCH" --slurpfile cls "$F_CLASS" --arg policy "$POLICY" \
  "$(canon_jq_defs)"'
  ($ix[0].subject.path // "") as $sp
  | (if $sp == "" then "" else $sp + "/" end) as $pre
  | def subrel: if $pre != "" and startswith($pre) then .[($pre | length):] else . end;
    def rootrel: if $pre == "" or startswith($pre) then . else $pre + . end;
    def anchor_of($rf; $ln): if $ln == null then "{file}"
      else ($anch[0] | if type == "array" then (map(select(.file == $rf and .line == $ln)) | .[0].anchor // "{file}") else "{file}" end) end;
    def short: split("\\") | last;
    # The first changed line (old numbering) of each hunk of a unified diff.
    def hunk_lines: split("\n") as $l
      | reduce range(0; $l | length) as $i ({out: [], start: null, ctx: 0, found: true};
          ($l[$i]) as $s
          | if ($s | startswith("@@ ")) then .start = ($s | capture("^@@ -(?<a>[0-9]+)").a | tonumber) | .ctx = 0 | .found = false
            elif .found == false and .start != null and ($s | startswith(" ")) then .ctx += 1
            elif .found == false and .start != null and (($s | startswith("-")) or ($s | startswith("+"))) then .out += [.start + .ctx] | .found = true
            else . end)
      | .out;
    def sev: ascii_downcase | if . == "warn" then "warning" elif . == "notice" then "info" else . end;
    # PHPStan keys an error in a trait "<file> (in context of class X)": the
    # file is the trait'"'"'s, once (the class contexts are deduplicated below).
    def ctxless: sub(" \\(in context of (class|anonymous class) [^)]*\\)$"; "");
    # classify-deprecations items, keyed by root-relative file, line and normalized message.
    ([($cls[0].hard // [])[], ($cls[0].soft // [])[], ($cls[0].unknown // [])[]]
      | map({key: "\(.file)\u001f\(.line)\u001f\(.message | finding_norm_message)", value: .}) | from_entries) as $cmap
  | [
      # Rector: one finding per applied rule and hunk. (Each generator is
      # parenthesized: an unparenthesized "as" binding would scope over the
      # generators after it.)
      (($rector[0].file_diffs // [])[] as $d
        | ($d.file | rootrel) as $rf
        | (($d.diff // "") | hunk_lines | if length == 0 then [null] else . end)[] as $ln
        | ($d.applied_rectors // [])[] as $r
        | {tool: "rector", rule: $r, rf: $rf, line: $ln, symbol: null, message: ($r | short),
           severity: "info", scope: "current", class: "rector"}),
      # PHPStan: every file message; deprecations classified.
      (($stan[0].files // {}) | to_entries[] as $e | ($e.value.messages // [])[] as $m
        | ($e.key | ctxless | rootrel) as $rf
        | ($m.message | finding_norm_message) as $nm
        | ($cmap["\($e.key)\u001f\($m.line)\u001f\($nm)"] // null) as $c
        | {tool: "phpstan", rule: ($m.identifier // null), rf: $rf, line: ($m.line // null),
           symbol: (if $c then $c.symbol else null end), message: $nm, severity: "error",
           scope: (if $c and $c.class == "soft" and $policy != "fix" then "next-major" else "current" end),
           class: (if $c then $c.class else "analysis" end), ctx: ($e.key != ($e.key | ctxless))}),
      # PHPCS: every file message.
      (($cs[0].files // {}) | to_entries[] as $e | ($e.value.messages // [])[] as $m
        | {tool: "phpcs", rule: ($m.source // "phpcs"), rf: ($e.key | rootrel), line: ($m.line // null), symbol: null,
           message: ($m.message | finding_norm_message), severity: (($m.type // "error") | sev), scope: "current",
           class: (if (($m.source // "") | startswith("PHPCompatibility.")) then "php-target" else "style" end)}),
      # The catalog scans.
      (($safety[0].findings // [])[] | {tool: "catalog", rule: "port-safety:\(.check)", rf: (.file | rootrel), line: (.line // null),
         symbol: null, message: (.message | finding_norm_message), severity: ((.severity // "error") | sev), scope: "current", class: "safety"}),
      (($sig[0].findings // [])[] | {tool: "catalog", rule: "signature:\(.id)", rf: (.file | rootrel), line: (.line // null),
         symbol: (.member // null), message: (.message | finding_norm_message), severity: ((.severity // "error") | sev), scope: "current", class: "signature"}),
      (($meta[0].findings // [])[] | {tool: "catalog", rule: "metadata:\(.check)", rf: (.file | rootrel), line: (.line // null),
         symbol: null, message: (.message | finding_norm_message), severity: ((.severity // "error") | sev), scope: "current", class: "metadata"})
    ]
  | (map(select(.ctx == true)) | unique_by([.rule, .rf, .line, .message])) + map(select(.ctx != true))
  | map(del(.ctx) + {file: (.rf | subrel), anchor: anchor_of(.rf; .line)})
' > "$PRE"

# hash_lines FILE -> "<line number>\t<sha256 hex>" for each line of FILE (its
# bytes without the newline), from one hasher process over one file per line.
if have_cmd sha256sum; then HASHER=(sha256sum); else HASHER=(shasum -a 256); fi
hash_lines() {
  local d="$TMP/h.$_hl"; _hl=$((_hl + 1)); mkdir -p "$d"
  awk -v d="$d" '{ f = d "/" NR; printf "%s", $0 > f; close(f) }' "$1"
  ( cd "$d" && find . -type f -exec "${HASHER[@]}" {} + ) | awk '{ p = $NF; sub(/^\.\//, "", p); print p "\t" $1 }'
  return 0
}
_hl=0

# Untyped PHPStan errors get a rule from their message's hash.
jq -r '[.[] | select(.rule == null) | .message] | unique[]' "$PRE" > "$TMP/untyped.txt"
hash_lines "$TMP/untyped.txt" > "$TMP/untyped.tsv"
jq -R -s -c --rawfile msgs "$TMP/untyped.txt" '($msgs | split("\n")) as $m
  | split("\n") | map(select(length > 0) | split("\t") | {key: $m[(.[0] | tonumber) - 1], value: ("phpstan:untyped:" + .[1][0:8])}) | from_entries' \
  "$TMP/untyped.tsv" > "$TMP/untyped.json"

# Pass 2: rules, occurrences (the ordinal of identical tuples by line), the
# tuples to hash.
SEP="$(printf '\037')"
jq -c --slurpfile utf "$TMP/untyped.json" --arg sep "$SEP" '
  $utf[0] as $ut
  | map(.rule = (.rule // $ut[.message]))
  | map(. + {tkey: ([.tool, .rule, .file, .anchor, (.symbol // ""), .message] | join($sep))})
  | group_by(.tkey) | map(sort_by(.line // 1e9) | to_entries | map(.value + {occurrence: .key})) | add // []
  | to_entries | map(.value + {n: .key})' "$PRE" > "$TMP/pre2.json"
# Line k of tuples.txt is the tuple of record n = k - 1.
jq -r --arg sep "$SEP" '.[] | "\(.tkey)\($sep)\(.occurrence)"' "$TMP/pre2.json" > "$TMP/tuples.txt"
hash_lines "$TMP/tuples.txt" \
  | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: ((.[0] | tonumber) - 1 | tostring), value: ("F-" + .[1][0:12])}) | from_entries' \
  > "$TMP/ids.json"

# Pass 3: ids, merges, order, the document.
DOC="$TMP/findings.json"
jq -c --slurpfile idsf "$TMP/ids.json" --slurpfile ix "$INDEX" --slurpfile rector "$F_RECTOR" --slurpfile anch "$F_ANCH" \
  --slurpfile stan "$F_PHPSTAN" --slurpfile cs "$F_PHPCS" --slurpfile safety "$F_SAFETY" --slurpfile sig "$F_SIG" --slurpfile meta "$F_META" \
  --arg stage "$STAGE" --argjson target "$TARGET" --arg policy "$POLICY" --arg missing "$MISSING" '
  def prec: {"rector": 0, "phpstan": 1, "catalog": 2, "phpcs": 3}[.] // 9;
  # A tool that gave no verdict: its raw file is missing, the error record
  # extract.sh writes, or the report of a crash.
  def verdict($t; $failed):
    if ($missing | split(" ") | index($t)) then "missing"
    elif (has("error") and has("exit_code") and (has("files") or has("findings") or has("file_diffs") | not)) or $failed then "failed"
    elif $t == "rector" and .status == "partial" then "partial"
    else "ok" end;
  $idsf[0] as $ids
  | map(. + {id: $ids["\(.n)"]})
  | map({id, tool, rule, file, line, anchor, symbol, message, occurrence, severity, scope, class,
         sources: [{tool, rule, line}]})
  # The same symbol at the same anchor of a file: one finding, every source kept.
  | (map(select(.symbol != null)) | group_by([.file, .anchor, .symbol])
      | map(sort_by([(.tool | prec), .id]) | .[0] + {sources: ([.[].sources[]] | sort_by([(.tool | prec), .rule, (.line // 0)]))}))
    + map(select(.symbol == null))
  | sort_by([.file, .anchor, .id])
  | . as $f
  | {schema: 1, stage: $stage,
     subject: {machine_name: ($ix[0].subject.machine_name // null), path: ($ix[0].subject.path // null)},
     target: {major: $target, soft_policy: $policy,
              runner: ($rector[0].runner.runner // null), php_version: ($rector[0].runner.php_version // null)},
     anchors: (if ($anch[0] | type) == "array" then "php" else "unavailable" end),
     tools: {rector: ($rector[0] | verdict("rector"; .status == "error")),
             phpstan: ($stan[0] | verdict("phpstan"; .drupilot.status == "crashed")),
             phpcs: ($cs[0] | verdict("phpcs"; (.drupilot.error // null) != null)),
             "port-safety": ($safety[0] | verdict("port-safety"; false)),
             signatures: ($sig[0] | verdict("signatures"; false)),
             metadata: ($meta[0] | verdict("metadata"; false))},
     counts: {total: ($f | length),
              current: ([$f[] | select(.scope == "current")] | length),
              next_major: ([$f[] | select(.scope == "next-major")] | length),
              by_tool: ($f | group_by(.tool) | map({key: .[0].tool, value: length}) | from_entries),
              by_class: ($f | group_by(.class) | map({key: .[0].class, value: length}) | from_entries)},
     findings: $f}' "$TMP/pre2.json" | canon_json > "$DOC"
jq -e '.schema == 1' "$DOC" > /dev/null 2>&1 || die "Could not build findings.json from $RAW_DIR." 1

# meta: what differs between two runs of the same tree (not hashed: DET-2).
# Each raw file is named by the hash of its content outside its own meta, so
# two runs of the same tree record the same raw hashes.
HASH="$(canon_json_hashable < "$DOC" | json_hash)"
RAWS="$(for t in index rector phpstan phpcs port-safety signatures metadata anchors; do f="$RAW_DIR/$NN-$STAGE-$t.json"; [[ -f "$f" ]] || continue; printf '%s\t%s\n' "$(basename "$f")" "$(canon_json_hashable < "$f" | json_hash)"; done \
  | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries')"
jq --arg h "$HASH" --argjson raws "$RAWS" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '. + {meta: {findings_hash: $h, raw: $raws, generated_at: $at}}' "$DOC" | canon_json > "$DOC.meta"

if [[ -n "$OUT" ]]; then
  mkdir -p "$(dirname "$OUT")" 2> /dev/null || true
  cp "$DOC.meta" "$OUT.tmp.$$" && mv -f "$OUT.tmp.$$" "$OUT" || die "Could not write $OUT." 1
  log_ok "findings.json: $(jq -r '.counts.total' "$DOC") finding(s), $(jq -r '.counts.current' "$DOC") current ($OUT)."
fi
[[ "$AS_JSON" == "1" ]] && cat "$DOC.meta"
exit 0
