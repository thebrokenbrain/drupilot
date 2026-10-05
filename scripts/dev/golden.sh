#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/dev/golden.sh
# The golden outputs (a developer/CI tool: no command, skill or hook calls it;
# scripts/dev/check.sh runs it as its `golden` gate). Two kinds of golden
# directory, each with a golden.json manifest carrying a `data_hash`: the
# sha256 of the version data (config/targets|php|paths) it was computed with.
# That data is vendored as a snapshot, tests/fixtures/data-snapshots/<hash>/,
# and the goldens are checked against the snapshot, never against the live
# config/: a data commit never changes an existing golden. Only an --update
# (a re-recording, with its CHANGELOG entry) vendors the live data as a new
# snapshot and repins the goldens to it.
#   baseline-0.9   tests/baseline/v0.9.0/: the Docker-free outputs of v0.9.0,
#                  checked by rerunning them (scripts/dev/baseline-0.9.sh
#                  --check, which this absorbs)
#   <fixture>      tests/fixtures/<fixture>.golden/: outputs recorded in the lab
#                  (DDEV), such as a fixture's port patch and its raw tool
#                  outputs; every file is pinned by its sha256 in golden.json,
#                  so a byte edit fails, and the nightly DDEV end-to-end run
#                  (G-E2E) is what regenerates them
# The data hash: the sha256 of the lines "<path> <sha256>" of every file under
# targets/, php/ and paths/ (path relative to the data dir, sorted). A snapshot
# whose content no longer gives its own name fails, and so does a golden
# pinned to a missing snapshot. A full --check also fails on a snapshot no
# golden is pinned to; a full --update removes such snapshots.
#
# Usage:
#   scripts/dev/golden.sh [--check | --update] [--only G1,G2] [--json] [-h|--help]
#     --check   verify every golden directory (the default)
#     --update  rewrite the `files` map of the fixture goldens' golden.json
#               from the files present (after a deliberate re-recording; a
#               golden change is its own commit with a CHANGELOG entry, H10),
#               vendor the live data as a snapshot if it is new, and pin
#               every updated golden (baseline-0.9 included) to it
#     --only    a subset (baseline-0.9, or a fixture name)
#     --json    {ok, mode, goldens:[{name, status, detail}]} on STDOUT
#
# Requires bash >= 3.2, jq and sha256sum or shasum. Exit codes: 0 every golden
# matches · 1 a mismatch or a usage error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SH="${BASH:-bash}"
MODE="check"; ONLY=""; AS_JSON=0

usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift;;
    --update) MODE="update"; shift;;
    --only) ONLY="${2:-}"; shift 2 || die "--only needs a value" 1;;
    --only=*) ONLY="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
have_cmd jq || die "jq is required by scripts/dev/golden.sh" 1
HASHER=""
if have_cmd sha256sum; then HASHER="sha256sum"; elif have_cmd shasum; then HASHER="shasum -a 256"; fi
[[ -n "$HASHER" ]] || die "golden.sh needs sha256sum or shasum" 1

in_list() { case ",$(printf '%s' "$2" | tr ' ' ','),"  in *",$1,"*) return 0;; esac; return 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-golden.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
RESULTS="$TMP/results.jsonl"; : > "$RESULTS"; FAILED=0
result() {
  jq -n -c --arg n "$1" --arg s "$2" --arg d "$3" '{name: $n, status: $s, detail: $d}' >> "$RESULTS"
  case "$2" in pass|updated) log_ok "$1: $3";; *) log_err "$1: $3"; FAILED=1;; esac
  return 0
}
sha() { $HASHER < "$1" | cut -d' ' -f1; }
IN_GIT=0
git -C "$REPO" rev-parse --git-dir > /dev/null 2>&1 && IN_GIT=1
# golden_files <dir> -> the files of a golden directory, sorted, but
# golden.json and operating-system/editor litter (.DS_Store, Thumbs.db, *.swp,
# *~). Anything else is listed even when git ignores it: --update pins it, and
# --check then fails on it as "not tracked by git", so an ignored recording is
# never dropped silently.
golden_files() {
  ( cd "$1" && find . -type f ! -name golden.json ! -name .DS_Store ! -name Thumbs.db ! -name '*.swp' ! -name '*~' \
      | sed 's#^\./##' | LC_ALL=C sort )
  return 0
}

# data_hash_of <data dir> -> the data hash (empty when the dir holds no data).
data_hash_of() {
  local d="$1" f lines=""
  [[ -d "$d" ]] || return 0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    lines="$lines$f $(sha "$d/$f")
"
  done < <( cd "$d" && find targets php paths -type f -name '*.json' 2> /dev/null | LC_ALL=C sort )
  [[ -n "$lines" ]] || return 0
  printf '%s' "$lines" | $HASHER | cut -d' ' -f1
  return 0
}
SNAPS="$REPO/tests/fixtures/data-snapshots"
# check_snapshot <name> <dir> -> 0 when the golden's data_hash names an intact
# snapshot (SNAP is then its path); otherwise one fail result and 1.
check_snapshot() {
  local name="$1" h
  h="$(jq -r '.data_hash // ""' "$2/golden.json" 2> /dev/null || true)"
  if [[ ! "$h" =~ ^[0-9a-f]{64}$ ]]; then result "$name" fail "golden.json has no data_hash (run --update to pin the data snapshot)"; return 1; fi
  SNAP="$SNAPS/$h"
  [[ -d "$SNAP" ]] || { result "$name" fail "its data snapshot ${SNAP#"$REPO"/} is missing"; return 1; }
  [[ "$(data_hash_of "$SNAP")" == "$h" ]] || { result "$name" fail "the data snapshot ${SNAP#"$REPO"/} was edited (its content no longer hashes to its name)"; return 1; }
  return 0
}
SNAP=""; USED=""

# The golden directories: "name<TAB>dir".
GOLDENS="$(printf 'baseline-0.9\t%s\n' "$REPO/tests/baseline/v0.9.0"
           for d in "$REPO"/tests/fixtures/*.golden; do
             [[ -d "$d" ]] && printf '%s\t%s\n' "$(basename "$d" .golden)" "$d"
           done)"
for _n in $(printf '%s' "$ONLY" | tr ',' ' '); do
  printf '%s\n' "$GOLDENS" | cut -f1 | grep_q -xF -- "$_n" || die "Unknown golden: $_n" 1
done

check_manifest() {
  local name="$1" dir="$2" m="$2/golden.json" f want got listed
  [[ -f "$m" ]] || { result "$name" fail "no golden.json in ${dir#"$REPO"/}"; return 0; }
  jq -e 'has("data_hash")' "$m" > /dev/null 2>&1 || { result "$name" fail "golden.json has no data_hash"; return 0; }
  listed="$(jq -r '.files | keys[]' "$m" 2>/dev/null || true)"
  [[ -n "$listed" ]] || { result "$name" fail "golden.json pins no file"; return 0; }
  while IFS= read -r f; do
    want="$(jq -r --arg f "$f" '.files[$f]' "$m")"
    if [[ ! -f "$dir/$f" ]]; then result "$name" fail "$f is pinned but missing"; return 0; fi
    got="$(sha "$dir/$f")"
    [[ "$got" == "$want" ]] || { result "$name" fail "$f differs from its pinned sha256 (a deliberate re-recording runs --update in its own commit)"; return 0; }
    # A pinned file must be committed: an ignore rule (such as *.patch) would
    # keep it out of a clone while it still exists here.
    if [[ "$IN_GIT" == "1" ]] && ! git -C "$REPO" ls-files --error-unmatch "${dir#"$REPO"/}/$f" > /dev/null 2>&1; then
      result "$name" fail "$f is pinned but not tracked by git$(git -C "$REPO" check-ignore -q "$dir/$f" 2>/dev/null && echo ' (an ignore rule matches it)')"; return 0
    fi
  done <<< "$listed"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    printf '%s\n' "$listed" | grep_q -xF -- "$f" || { result "$name" fail "$f is not pinned in golden.json"; return 0; }
  done < <(golden_files "$dir")
  result "$name" pass "$(printf '%s\n' "$listed" | grep -c .) pinned file(s) match"
  return 0
}

log_step "drupilot goldens: $MODE"
LIVE_HASH=""
if [[ "$MODE" == "update" ]]; then
  LIVE_HASH="$(data_hash_of "$REPO/config")"
  [[ -n "$LIVE_HASH" ]] || die "config/ holds no version data to snapshot" 1
  if [[ -d "$SNAPS/$LIVE_HASH" ]]; then
    # An existing snapshot must really hold the live data (an interrupted
    # vendoring leaves a partial one behind).
    [[ "$(data_hash_of "$SNAPS/$LIVE_HASH")" == "$LIVE_HASH" ]] \
      || die "tests/fixtures/data-snapshots/$LIVE_HASH exists but does not hold the live data: remove it and re-run --update" 1
  else
    # Vendor into a temp dir, verify, then move into place.
    mkdir -p "$SNAPS" "$TMP/snap"
    for _d in targets php paths; do [[ -d "$REPO/config/$_d" ]] && cp -R "$REPO/config/$_d" "$TMP/snap/"; done
    [[ "$(data_hash_of "$TMP/snap")" == "$LIVE_HASH" ]] || die "the copied data does not hash to $LIVE_HASH" 1
    mv "$TMP/snap" "$SNAPS/$LIVE_HASH"
    log_ok "vendored the live data as tests/fixtures/data-snapshots/$LIVE_HASH"
  fi
fi
# pin <golden.json> -> set its data_hash to the live data hash.
pin() { jq --arg h "$LIVE_HASH" '.data_hash = $h' "$1" > "$TMP/p.json" && mv "$TMP/p.json" "$1"; }
while IFS="$(printf '\t')" read -r name dir; do
  [[ -n "$name" ]] || continue
  if [[ -n "$ONLY" ]] && ! in_list "$name" "$ONLY"; then continue; fi
  if [[ "$MODE" == "update" ]]; then
    if [[ "$name" == "baseline-0.9" ]]; then
      [[ -f "$dir/golden.json" ]] || jq -n '{data_hash: ""}' > "$dir/golden.json"
      pin "$dir/golden.json"
      result "$name" updated "pinned to data snapshot $LIVE_HASH (its captures are refreshed by scripts/dev/baseline-0.9.sh --capture, not here)"
      continue
    fi
    files="$(golden_files "$dir" \
             | while IFS= read -r f; do jq -n -c --arg f "$f" --arg h "$(sha "$dir/$f")" '{($f): $h}'; done | jq -s -c 'add // {}')"
    if [[ -f "$dir/golden.json" ]]; then
      jq --argjson f "$files" '.files = $f' "$dir/golden.json" > "$TMP/g.json" && mv "$TMP/g.json" "$dir/golden.json"
    else
      jq -n --argjson f "$files" '{data_hash: "", files: $f}' > "$dir/golden.json"
    fi
    pin "$dir/golden.json"
    result "$name" updated "golden.json pins $(printf '%s' "$files" | jq 'length') file(s), data snapshot $LIVE_HASH"
    continue
  fi
  if [[ ! -f "$dir/golden.json" ]] || ! jq -e 'has("data_hash")' "$dir/golden.json" > /dev/null 2>&1; then
    result "$name" fail "${dir#"$REPO"/}/golden.json is missing or has no data_hash"; continue
  fi
  # A pinned snapshot counts as used even when its integrity check fails.
  USED="$USED $(jq -r '.data_hash // ""' "$dir/golden.json" 2> /dev/null || true)"
  check_snapshot "$name" "$dir" || continue
  if [[ "$name" != "baseline-0.9" ]]; then check_manifest "$name" "$dir"; continue; fi
  if "$SH" "$REPO/scripts/dev/baseline-0.9.sh" --check --json --data-dir "$SNAP" > "$TMP/bl.json" 2> "$TMP/bl.err"; then
    result "$name" pass "$(jq -r '.files | length' "$TMP/bl.json") capture(s) match v0.9.0 (or an allowed difference)"
  else
    _why="$(jq -r '[.files[] | select(.status != "same" and .status != "allowed") | "\(.name): \(.status)"] | join("; ")' "$TMP/bl.json" 2>/dev/null || true)"
    # The diff baseline-0.9.sh printed, added lines first, so a CI log shows
    # what the run produced, not only what it lost (an intermittent
    # difference cannot be rerun to see it).
    _diff="$( { grep -E '^    [+][^+]' "$TMP/bl.err"; grep -E '^    [-][^-]' "$TMP/bl.err"; } 2>/dev/null \
      | sed -n '1,24p' | sed 's/^    //' | tr '\n' '|' || true)"
    result "$name" fail "${_why:-$(tail -n 3 "$TMP/bl.err" | tr '\n' ' ')}${_diff:+ — diff: $_diff}"
  fi
done <<< "$GOLDENS"

# A full --update (no --only) removes the snapshots no golden is pinned to any
# more; a full --check fails on one.
if [[ "$MODE" == "update" && -z "$ONLY" && -d "$SNAPS" ]]; then
  for _s in "$SNAPS"/*; do
    [[ -d "$_s" && "${_s##*/}" != "$LIVE_HASH" ]] || continue
    _pinned=0
    while IFS="$(printf '\t')" read -r _n _d; do
      [[ -n "$_n" ]] || continue
      [[ "$(jq -r '.data_hash // ""' "$_d/golden.json" 2> /dev/null || true)" == "${_s##*/}" ]] && _pinned=1
    done <<< "$GOLDENS"
    if [[ "$_pinned" == "0" ]]; then rm -rf "${_s:?}"; log_ok "removed the unused data snapshot ${_s#"$REPO"/}"; fi
  done
fi
if [[ "$MODE" == "check" && -z "$ONLY" && -d "$SNAPS" ]]; then
  for _s in "$SNAPS"/*; do
    [[ -d "$_s" ]] || continue
    case " $USED " in *" ${_s##*/} "*) ;; *) result "data-snapshots" fail "${_s#"$REPO"/} is not used by any golden (remove it)";; esac
  done
fi
if [[ "$MODE" == "update" ]]; then log_ok "golden.sh: manifests updated"
elif [[ "$FAILED" == "1" ]]; then log_err "golden.sh: a golden output differs"
else log_ok "golden.sh: every golden output matches"; fi
if [[ "$AS_JSON" == "1" ]]; then
  jq -s -c --argjson ok "$([[ "$FAILED" == "1" ]] && echo false || echo true)" --arg m "$MODE" \
    '{ok: $ok, mode: $m, goldens: .}' "$RESULTS"
fi
exit "$FAILED"
