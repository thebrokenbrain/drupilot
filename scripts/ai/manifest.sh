#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/ai/manifest.sh
# The port manifest, generated (T-M4-10, AR-10, 01-R9, ADR 0027): what a port
# or a refactor did, as port-manifest.json (schema 1) in the subject's hidden
# state dir. It is built from what the scripts recorded, never from memory:
#   findings.json      the last extraction: deprecations_remaining (the
#                      current hard and unknown PHPStan occurrences),
#                      deferred_to_phase2 (the next-major symbols), and the
#                      stage's raw reports: port_safety, signature_changes,
#                      metadata_lint (the scripts' --json, canonical) and
#                      soft_deprecations (classify-deprecations.sh --json on
#                      the raw PHPStan report)
#   worklist.json      the lane x status table and every item
#   actions.jsonl      the codemods applied and still in effect
#   rector-rules.json  the rules and files of the applying Rector run, and
#                      attributes-rules.json those of the attribute pass
#                      (convert-attributes.sh --apply)
#   digests verdicts   digests-decisions.json: the rules rejected
#   decision log       log-decision.sh: the count per kind (port-report.sh
#                      merges the entries themselves)
#   the git diff       against the port's base (git_port_base_ref, the base
#                      make-patch.sh --local uses): files_changed, files, and
#                      manual_edits (the files neither Rector nor a codemod
#                      changed)
#   info.yml, composer.json, assess.json, core-matrix.json: the requirement,
#                      require.php, the SemVer bump, d10_support.
# The model writes only the rationale: --rationale FILE, a JSON object
# {"<worklist item id>": "why"}. An id the worklist does not have is refused;
# a previous manifest's rationale is kept for the ids still in the worklist.
# The same inputs give the same document outside meta; inputs records the
# hashes it was built from. port-report.sh renders it.
#
# Usage:
#   manifest.sh --subject DIR [--phase port|refactor] [--rationale FILE]
#               [--base REF] [--no-write] [--json] [-h|--help]
#     --subject DIR      the module/theme
#     --phase P          port (default) or refactor
#     --rationale FILE   {item id: text}, the model's only input
#     --base REF         the port's git base (default: git_port_base_ref)
#     --no-write         do not write port-manifest.json (with --json: a dry
#                        run)
#     --json             print the manifest on STDOUT
#
# Exit codes: 0 done · 1 usage error, no findings.json or worklist.json for
# the subject (run the pipeline first), or a rationale id the worklist does
# not have · 2 jq missing.
# =============================================================================
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""; PHASE="port"; RATIONALE=""; BASE=""; WRITE=1; AS_JSON=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --phase) PHASE="${2:-}"; shift 2 || die "--phase needs a value" 1;;
    --rationale) RATIONALE="${2:-}"; shift 2 || die "--rationale needs a value" 1;;
    --base) BASE="${2:-}"; shift 2 || die "--base needs a value" 1;;
    --no-write) WRITE=0; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
[[ -n "$SUBJECT" && -d "$SUBJECT" ]] || die "Pass --subject DIR (an existing directory)." 1
case "$PHASE" in port|refactor) ;; *) die "--phase is port or refactor." 1;; esac
have_cmd jq || die "jq is required (run /drupilot-doctor)." 2
SUBJECT="$(cd "$SUBJECT" && pwd)"
SD="$(project_state_path "$SUBJECT")"
F="$SD/findings.json"; W="$(worklist_file "$SUBJECT")"
jq -e '.schema == 1 and (.findings | type) == "array"' "$F" > /dev/null 2>&1 || die "No findings.json for $SUBJECT: run the pipeline first." 1
jq -e '.schema == 1 and (.items | type) == "array"' "$W" > /dev/null 2>&1 || die "No worklist.json for $SUBJECT: run the pipeline first." 1
if [[ -n "$RATIONALE" ]]; then
  jq -e 'type == "object" and all(.[]; type == "string")' "$RATIONALE" > /dev/null 2>&1 \
    || die "$RATIONALE is not a JSON object of item id -> text." 1
  BAD="$(jq -r --slurpfile w "$W" '[keys[] | select(. as $k | [$w[0].items[].id] | index($k) | not)] | join(", ")' "$RATIONALE")"
  [[ -z "$BAD" ]] || die "Not an item of the worklist: $BAD (see worklist.json)." 1
fi
MN="$(subject_machine_name "$SUBJECT" 2> /dev/null || basename "$SUBJECT")"
TYPE="$(subject_type "$SUBJECT" 2> /dev/null || echo module)"
ROOT="$(find_drupal_root "$SUBJECT" 2> /dev/null || true)"
if [[ -n "$ROOT" && -z "${DRUPILOT_PROJECT_DIR:-}" ]]; then export DRUPILOT_PROJECT_DIR="$ROOT"; fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-manifest.XXXXXX")"
trap 'rm -rf "$TMP" 2> /dev/null || true' EXIT
json_or() {  # json_or FILE DEFAULT -> FILE when it holds one JSON value, else a file holding DEFAULT
  if [[ -f "$1" ]] && jq -e -s 'length == 1' "$1" > /dev/null 2>&1; then printf '%s' "$1"
  else printf '%s\n' "$2" > "$TMP/d.$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; printf '%s' "$TMP/d.$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; fi
}

# The raw reports of the stage findings.json was extracted at.
STAGE="$(jq -r '.stage // ""' "$F")"
raw() {  # raw TOOL -> the stage's raw report of TOOL without meta, or {} (none)
  local r
  r="$(find "$SD/raw" -name "[0-9][0-9]-$STAGE-$1.json" 2> /dev/null | LC_ALL=C sort | sed -n '$p')"
  if [[ -n "$r" ]] && jq -e 'type == "object"' "$r" > /dev/null 2>&1; then jq -c 'del(.meta)' "$r"; else printf 'null'; fi
  return 0
}
raw port-safety > "$TMP/ps.json"; raw signatures > "$TMP/sig.json"; raw metadata > "$TMP/meta.json"
REQ="$(sed -n 's/^core_version_requirement[[:space:]]*:[[:space:]]*//p' "$SUBJECT/$MN.info.yml" 2> /dev/null | sed -n '1p' | tr -d "'\"" | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//' || true)"
TMAJ="$(jq -r '.target.major // empty' "$F")"; [[ -n "$TMAJ" ]] || TMAJ="$(resolve_target_major)"
POLICY="$(jq -r '.target.soft_policy // empty' "$F")"; [[ -n "$POLICY" ]] || POLICY="$(config_get DRUPILOT_SOFT_DEPRECATIONS report)"
printf 'null\n' > "$TMP/soft.json"
_rp="$(find "$SD/raw" -name "[0-9][0-9]-$STAGE-phpstan.json" 2> /dev/null | LC_ALL=C sort | sed -n '$p')"
if [[ -n "$_rp" ]]; then
  bash "$(plugin_root)/scripts/analysis/classify-deprecations.sh" --file "$_rp" --subject "$SUBJECT" --target-major "$TMAJ" \
    --policy "$POLICY" --phase "$PHASE" --json < /dev/null > "$TMP/soft.raw" 2> /dev/null || true
  jq -e 'type == "object"' "$TMP/soft.raw" > /dev/null 2>&1 && jq -c 'del(.meta)' "$TMP/soft.raw" > "$TMP/soft.json"
fi

# d10_support: the core matrix when it is fresh, else declared or n/a.
D10="n/a"
if constraint_admits_major "$REQ" "$((TMAJ - 1))"; then D10="declared-not-verified"; fi
CM="$SD/core-matrix.json"
if [[ -f "$CM" ]] && [[ "$(jq -r '.subject_digest // ""' "$CM" 2> /dev/null)" == "$(subject_digest "$SUBJECT")" ]]; then
  _v="$(jq -r '.d10_support // empty' "$CM" 2> /dev/null || true)"; [[ -z "$_v" ]] || D10="$_v"
fi

# The git diff against the port's base, relative to the subject.
: > "$TMP/files.tsv"; BASE_SHA=""
if git -C "$SUBJECT" rev-parse --git-dir > /dev/null 2>&1; then
  REF="$(git_port_base_ref "$SUBJECT" "$BASE" 2> /dev/null || true)"
  [[ -n "$REF" ]] || die "The base '$BASE' does not exist in $SUBJECT's repository." 1
  BASE_SHA="$(git -C "$SUBJECT" rev-parse --verify --quiet "$REF^{commit}" 2> /dev/null || true)"
  PFX="$(git -C "$SUBJECT" rev-parse --show-prefix 2> /dev/null || true)"
  {
    git -C "$SUBJECT" diff --no-renames --name-status "$REF" -- . 2> /dev/null || true
    git -C "$SUBJECT" ls-files --others --exclude-standard -- . 2> /dev/null | sed 's/^/A\t/' || true
  } | awk -F'\t' -v p="$PFX" 'NF >= 2 { f = $2; if (p != "" && index(f, p) == 1) f = substr(f, length(p) + 1); print substr($1, 1, 1) "\t" f }' \
    | grep -vE $'\t''(\.drupilot|.*\.patch$|.*\.orig$|.*\.rej$)' | LC_ALL=C sort -u -t "$(printf '\t')" -k2,2 > "$TMP/files.tsv" || true
fi
PATCH=""; _pn="$MN-$(target_patch_desc "$TMAJ").patch"; [[ -f "$SUBJECT/$_pn" ]] && PATCH="$_pn"

# The other inputs, each read defensively.
RR="$(json_or "$(rector_rules_file "$SUBJECT")" '{}')"
AT="$(json_or "$SD/attributes-rules.json" '{}')"
DD="$(json_or "$(digests_decisions_file "$SUBJECT")" '{"decisions": []}')"
AS="$(json_or "$SD/assess.json" '{}')"
actions_state "$SD/actions.jsonl" "$SUBJECT" "$TMP/acts.json" || printf '{"last": {}, "effective": {}, "now": {}, "files": true}\n' > "$TMP/acts.json"
decisions_for_subject "$SUBJECT" > "$TMP/dec.json"
RAT_PREV='{}'
if [[ -f "$SD/port-manifest.json" ]]; then RAT_PREV="$(jq -c '(.rationale // {}) | if type == "object" then . else {} end' "$SD/port-manifest.json" 2> /dev/null || printf '{}')"; fi
RAT_NEW='{}'; [[ -z "$RATIONALE" ]] || RAT_NEW="$(jq -c . "$RATIONALE")"
COMPOSER_PHP="$(jq -r '.require.php // empty' "$SUBJECT/composer.json" 2> /dev/null || true)"
SUBREL="$(jq -r '.subject.path // ""' "$F")"

DOC="$TMP/manifest.json"
jq -n -c --slurpfile f "$F" --slurpfile w "$W" --slurpfile rr "$RR" --slurpfile at "$AT" --slurpfile dd "$DD" --slurpfile asj "$AS" \
  --slurpfile acts "$TMP/acts.json" --slurpfile dec "$TMP/dec.json" --slurpfile ps "$TMP/ps.json" --slurpfile sig "$TMP/sig.json" \
  --slurpfile md "$TMP/meta.json" --slurpfile soft "$TMP/soft.json" --rawfile files "$TMP/files.tsv" \
  --argjson ratprev "$RAT_PREV" --argjson ratnew "$RAT_NEW" --arg phase "$PHASE" --arg mn "$MN" --arg type "$TYPE" \
  --arg req "$REQ" --arg rphp "$COMPOSER_PHP" --arg pt "$(resolve_php_target)" --arg d10 "$D10" --arg patch "$PATCH" \
  --arg base "$BASE_SHA" --arg subrel "$SUBREL" --arg acth "$(file_hash "$SD/actions.jsonl" 2> /dev/null || true)" '
  $f[0] as $F | $w[0] as $W | $rr[0] as $RR | $asj[0] as $A | $acts[0] as $ST
  | def occ: ([(.sources // [])[] | select(.tool == "phpstan")] | length) as $n | if $n > 0 then $n else 1 end;
    def nz: if . == "" then null else . end;
    ($files | split("\n") | map(select(length > 0) | split("\t") | {status: .[0], path: .[1]})) as $diff
  # The files of the Rector run and of the attribute pass, relative to the
  # subject (they name them from the root).
  | ((($RR.files // []) + ($at[0].files // [])) | map(if $subrel != "" and startswith($subrel + "/") then .[($subrel | length) + 1:] else . end)) as $rfiles
  # The codemods in effect: the last applied action of each, while its file
  # still holds its output.
  | ([$ST.last[] | select(.status == "applied" and (.file | type) == "string"
        and ($ST.now[.file] // null) == ($ST.effective[.file] // "") )]
     | map({recipe, version, file, finding_id}) | sort_by([.file, .recipe, .finding_id])) as $codemods
  | ($codemods | map(.file) | unique) as $cfiles
  | ([$W.items[] | {lane, status}] | group_by(.lane) | map({key: .[0].lane, value: (group_by(.status) | map({key: .[0].status, value: length}) | from_entries)}) | from_entries) as $ls
  | (($ratprev | with_entries(select(.key as $k | [$W.items[].id] | index($k)))) + $ratnew) as $rat
  | ([($dd[0].decisions // [])[] | select(.verdict == "reject" and ($RR.digests_sha == null or .digests_sha == $RR.digests_sha)) | .rule] | unique) as $drej
  | {schema: 1, tool: "manifest", phase: $phase, machine_name: $mn, type: $type, subject: (if $subrel == "" then null else $subrel end),
     core_version_requirement: ($req | nz), require_php: ($rphp | nz), php_target: $pt,
     version_bump: (if ($A.recommended_core_version_requirement // null) == $req then ($A.version_bump // null) else null end),
     d10_support: $d10,
     rector_official_files: ($RR.changed_files // null),
     rector_rules: (if ($RR.rule_hits // null) == null and ($at[0].rule_hits // null) == null then null
                    else ($RR.rule_hits // {}) + ($at[0].rule_hits // {}) end),
     digests: {applied: (($RR.rule_hits.digests // {}) | keys), rejected: [$drej[] | {rule: ., reason: "rejected by the developer"}],
               skipped: ((($RR.rule_hits.digests // {}) | length) == 0 and ($drej | length) == 0)},
     codemods: $codemods,
     manual_edits: [$diff[] | select(.path as $p | ($rfiles | index($p) | not) and ($cfiles | index($p) | not)) | {edit: .path, why: null, change_record: null}],
     worklist: {by_lane_status: $ls,
                items: [$W.items[] | {id, lane, status, file, anchor, blocking, recipes: (.recipes // []), findings: (.finding_ids | length)}
                        + (if $rat[.id] then {rationale: $rat[.id]} else {} end)]},
     rationale: $rat,
     deprecations_remaining: ([$F.findings[] | select(.scope == "current" and .tool == "phpstan" and (.class == "hard" or .class == "unknown")) | occ] | add // 0),
     deferred_to_phase2: ([$F.findings[] | select(.scope == "next-major") | (.symbol // empty)] | unique),
     files_changed: (if $base == "" then null else ($diff | length) end),
     files: $diff,
     patch: ($patch | nz),
     port_safety: $ps[0], signature_changes: $sig[0], metadata_lint: $md[0], soft_deprecations: $soft[0],
     decisions: {count: ($dec[0] | length), by_kind: ($dec[0] | group_by(.kind // "?") | map({key: (.[0].kind // "?"), value: length}) | from_entries)},
     inputs: {findings_hash: ($F.meta.findings_hash // null), findings_stage: ($F.stage // null), worklist_hash: ($W.meta.worklist_hash // null),
              actions_hash: ($acth | nz), base: ($base | nz)}}
  | with_entries(select(.value != null or (.key | IN("core_version_requirement", "require_php", "version_bump", "rector_official_files", "rector_rules", "files_changed", "patch", "subject"))))' \
  | canon_json > "$DOC"
jq -e '.schema == 1' "$DOC" > /dev/null 2>&1 || die "Could not build the manifest." 1
jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg v "$(plugin_version 2> /dev/null || true)" \
  '. + {meta: {generated_at: $at, drupilot_version: (if $v == "" then null else $v end)}}' "$DOC" | canon_json > "$DOC.meta"
if [[ "$WRITE" == "1" ]]; then
  mkdir -p "$SD" 2> /dev/null || die "Cannot create $SD." 1
  cp "$DOC.meta" "$SD/port-manifest.json.tmp.$$" && mv -f "$SD/port-manifest.json.tmp.$$" "$SD/port-manifest.json" || die "Could not write port-manifest.json." 1
  log_ok "manifest: $SD/port-manifest.json ($(jq '.worklist.items | length' "$DOC") item(s), $(jq '.rationale | length' "$DOC") with a rationale)."
fi
[[ "$AS_JSON" == "1" ]] && cat "$DOC.meta"
exit 0
