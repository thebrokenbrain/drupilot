#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/dev/refresh-data.sh
# Refresh the generated fields of the version data (a developer tool: no
# command, skill, hook or port ever runs it). For every minor of
# config/targets/<major>.json it reads, at that minor's newest tag:
#   - repo.packagist.org/p2/drupal/core.json: the newest tag of the minor
#     (stable only; alpha/beta/rc too for a pre-release major) and the date of
#     its .0 release
#   - git.drupalcode.org/project/drupal/-/raw/<tag>/: core/composer.json
#     (require.php -> php_min, symfony/http-kernel -> symfony_major,
#     twig/twig -> twig_major), composer/Metapackage/DevDependencies/
#     composer.json (the phpunit, coder, phpstan and phpstan-drupal
#     constraints) and core/lib/Drupal.php (RECOMMENDED_PHP -> php_recommended)
# and merges them with the hand-maintained fields, which it never changes
# (php_supported, php_unsupported, php_src, verified, the removals, status,
# defaults). A {"status": "detect"} minor is filled once a tag of it exists;
# its hand fields stay null until someone reads drupal.org's table. A minor
# whose values changed gets checked_at = --as-of, and its file as_of too.
# It also checks, without writing anything: that every removed extension is in
# the core tree at the previous major's newest tag (or at the minor that
# introduced it) and gone at the removal tag (an obsolete one: still there with
# lifecycle: obsolete), the same for every removed core library; that nothing
# else disappeared between those two tags (every .info.yml under core/modules
# and core/themes, nested modules included, tests/ and theme engines left
# out, listed from a tree-only `git fetch --filter=blob:none` of the tag, and
# every core.libraries.yml key gone at the major's .0 must be listed); and
# that the drupal.org pages in hand_sources did not change since they were read
# (api-d7 JSON, never HTML). Every fetched file is cached, and --offline reads
# only the cache: two offline runs on the same input give byte-identical files
# and output. Nothing is written until every fetch has succeeded, so a failed
# run leaves the data as it was.
#
# Usage:
#   scripts/dev/refresh-data.sh [--dry-run] [--json] [--offline] [--cache DIR]
#                               [--data-dir DIR] [--as-of YYYY-MM-DD] [-h|--help]
#     --dry-run   compute and report; write nothing
#     --json      {ok, dry_run, offline, changed:[{file, path, from, to}],
#                  mismatches:[{file, entry, detail}], stale_hand_sources:
#                  [{file, id, recorded, current}]} on STDOUT
#     --offline   read only the cache (a file missing from it is an error)
#     --cache     the fetch cache (default $XDG_CACHE_HOME/drupilot-dev/
#                 refresh-data, else ~/.cache/drupilot-dev/refresh-data)
#     --data-dir  the directory holding targets/ (default <repo>/config)
#     --as-of     the date stamped on changed values (default: today, UTC)
#
# Requires bash >= 3.2, jq and (unless --offline) curl and git. Exit codes: 0 done ·
# 1 a usage, fetch or parse error · 3 done, but a mismatch or a stale hand
# source needs a human.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRY=0; AS_JSON=0; OFFLINE=0; CACHE=""; DATA=""; AS_OF=""

usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    --json) AS_JSON=1; shift;;
    --offline) OFFLINE=1; shift;;
    --cache) CACHE="${2:-}"; shift 2 || die "--cache needs a value" 1;;
    --cache=*) CACHE="${1#*=}"; shift;;
    --data-dir) DATA="${2:-}"; shift 2 || die "--data-dir needs a value" 1;;
    --data-dir=*) DATA="${1#*=}"; shift;;
    --as-of) AS_OF="${2:-}"; shift 2 || die "--as-of needs a value" 1;;
    --as-of=*) AS_OF="${1#*=}"; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
have_cmd jq || die "jq is required by scripts/dev/refresh-data.sh" 1
[[ "$OFFLINE" == "1" ]] || have_cmd curl || die "curl is required (or pass --offline)" 1
CACHE="${CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/drupilot-dev/refresh-data}"
DATA="${DATA:-$REPO/config}"
AS_OF="${AS_OF:-$(date -u +%Y-%m-%d)}"
[[ "$AS_OF" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--as-of must be YYYY-MM-DD" 1
[[ -d "$DATA/targets" ]] || die "no targets/ directory under $DATA" 1

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-refresh.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/changed.jsonl"; : > "$TMP/mismatches.jsonl"; : > "$TMP/stale.jsonl"
FETCHED=""; PROBED=""; GEN=""
UA="drupilot-dev refresh-data (https://github.com/thebrokenbrain/drupilot)"
RAW="https://git.drupalcode.org/project/drupal/-/raw"
GITURL="https://git.drupalcode.org/project/drupal.git"

# The fetch helpers run in the main shell (never inside $(...), where a die
# would only end a subshell) and hand back their result in a variable.
# fetch URL KEY -> FETCHED: the path of the cached copy of URL (downloaded
# unless --offline).
fetch() {
  local url="$1" f="$CACHE/$2"
  if [[ "$OFFLINE" == "1" ]]; then
    [[ -f "$f" ]] || die "--offline: $url is not in the cache ($f)" 1
  else
    mkdir -p "$(dirname "$f")"
    if ! curl -fsSL --retry 2 -A "$UA" -o "$f.part" "$url" < /dev/null; then
      rm -f "$f.part"; die "could not fetch $url" 1
    fi
    mv "$f.part" "$f"
  fi
  FETCHED="$f"
}
# probe URL KEY -> PROBED: 200 or 404, whether a file exists (the status is cached).
probe() {
  local url="$1" f="$CACHE/$2.status" code
  if [[ "$OFFLINE" == "1" ]]; then
    [[ -f "$f" ]] || die "--offline: the status of $url is not in the cache ($f)" 1
    PROBED="$(cat "$f")"; return 0
  fi
  mkdir -p "$(dirname "$f")"
  code="$(curl -sS -o /dev/null -w '%{http_code}' -A "$UA" "$url" < /dev/null || echo 000)"
  case "$code" in 200|404) printf '%s' "$code" > "$f";; *) die "HTTP $code for $url" 1;; esac
  PROBED="$code"
}
mismatch() {
  jq -n -c --arg f "$1" --arg e "$2" --arg d "$3" '{file: $f, entry: $e, detail: $d}' >> "$TMP/mismatches.jsonl"
  log_warn "$1: $2: $3"
  return 0
}

# Every tag of drupal/core: {version, date, key} (key orders alpha < beta < rc < release).
fetch https://repo.packagist.org/p2/drupal/core.json packagist/drupal-core.json; P2="$FETCHED"
jq -c '[.packages["drupal/core"][]
        | select(.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+(-(alpha|beta|rc)[0-9]+)?$"))
        | (.version | capture("^(?<a>[0-9]+)\\.(?<b>[0-9]+)\\.(?<c>[0-9]+)(-(?<s>alpha|beta|rc)(?<n>[0-9]+))?$")) as $m
        | {version, date: ((.time // "")[0:10]),
           key: [($m.a | tonumber), ($m.b | tonumber), ($m.c | tonumber),
                 ({"alpha": 0, "beta": 1, "rc": 2}[$m.s // "-"] // 3), (($m.n // "0") | tonumber)]}]' \
  "$P2" > "$TMP/tags.json" || die "could not read the drupal/core versions from packagist" 1

# newest_tag MINOR ALLOW_PRE -> the newest tag of MINOR (empty if none).
newest_tag() {
  jq -r --arg m "$1." --argjson pre "$2" \
    '[.[] | select(.version | startswith($m)) | select($pre or .key[3] == 3)] | max_by(.key) | .version // empty' "$TMP/tags.json"
}
# newest_of_major MAJOR -> the newest stable tag of MAJOR.
newest_of_major() {
  jq -r --argjson M "$1" '[.[] | select(.key[0] == $M and .key[3] == 3)] | max_by(.key) | .version // empty' "$TMP/tags.json"
}
# raw TAG PATH -> FETCHED: the cached copy of PATH at TAG.
raw() { fetch "$RAW/$1/$2" "git/$1/$(printf '%s' "$2" | tr '/' '_')"; }
# rawprobe TAG PATH -> PROBED: 200 or 404 for PATH at TAG.
rawprobe() { probe "$RAW/$1/$2" "git/$1/$(printf '%s' "$2" | tr '/' '_')"; }
# infolist TAG -> FETCHED: the sorted .info.yml paths under core/modules and
# core/themes at TAG (tests/ and core/themes/engines/ left out), from a
# tree-only fetch of the tag (no file contents are downloaded).
infolist() {
  local tag="$1" f="$CACHE/git/$1/info-yml-paths.txt" g="$TMP/gt-$1"
  if [[ "$OFFLINE" == "1" ]]; then
    [[ -f "$f" ]] || die "--offline: the core tree listing at $tag is not in the cache ($f)" 1
  else
    have_cmd git || die "git is required to list the core tree (or pass --offline)" 1
    mkdir -p "$g" "$(dirname "$f")"
    if ! ( cd "$g" && git init -q && git fetch -q --depth 1 --filter=blob:none "$GITURL" "refs/tags/$tag" \
             && git ls-tree -r --name-only FETCH_HEAD -- core/modules core/themes ) < /dev/null > "$g.list" 2> /dev/null; then
      die "could not list the core tree at $tag" 1
    fi
    awk '/\.info\.yml$/ && !/\/tests\// && !/^core\/themes\/engines\//' "$g.list" | LC_ALL=C sort > "$f.part"
    [[ -s "$f.part" ]] || die "the core tree listing at $tag holds no .info.yml" 1
    mv "$f.part" "$f"
  fi
  FETCHED="$f"
}
# libkeys FILE -> the top-level keys of a core.libraries.yml, sorted.
libkeys() { sed -n 's/^\([A-Za-z0-9_.-][A-Za-z0-9_.-]*\):[[:space:]]*$/\1/p' "$1" | LC_ALL=C sort -u; }

# generated MINOR TAG -> GEN: the generated fields of MINOR at TAG, as JSON.
generated() {
  local minor="$1" tag="$2" core dev drupal rec released
  raw "$tag" core/composer.json; core="$FETCHED"
  raw "$tag" composer/Metapackage/DevDependencies/composer.json; dev="$FETCHED"
  raw "$tag" core/lib/Drupal.php; drupal="$FETCHED"
  rec="$(sed -n "s/^[[:space:]]*const RECOMMENDED_PHP = '\\([0-9][0-9]*\\.[0-9][0-9]*\\).*/\\1/p" "$drupal" | sed -n '1p')"
  released="$(jq -r --arg v "$minor.0" '.[] | select(.version == $v) | .date' "$TMP/tags.json")"
  GEN="$(jq -n -c --slurpfile core "$core" --slurpfile dev "$dev" --arg latest "$tag" --arg released "$released" \
    --arg rec "$rec" --arg src "$RAW/$tag/{core/composer.json,composer/Metapackage/DevDependencies/composer.json,core/lib/Drupal.php} ; https://repo.packagist.org/p2/drupal/core.json" '
    def mm: if . == null then null else (capture("(?<v>[0-9]+\\.[0-9]+)") | .v) end;
    def major: if . == null then null else (capture("(?<v>[0-9]+)") | .v | tonumber) end;
    ($core[0].require // {}) as $r | ($dev[0].require // {}) as $d
    | {latest: $latest,
       released: (if $released == "" then null else $released end),
       php_min: ($r.php | mm),
       php_recommended: (if $rec == "" then null else $rec end),
       symfony_major: ($r["symfony/http-kernel"] | major),
       twig_major: ($r["twig/twig"] | major),
       phpunit_constraint: ($d["phpunit/phpunit"] // null),
       coder_constraint: ($d["drupal/coder"] // null),
       phpstan_constraint: ($d["phpstan/phpstan"] // null),
       phpstan_drupal_constraint: ($d["mglaman/phpstan-drupal"] // null),
       src: $src}')" || die "could not read the core files at $tag" 1
  return 0
}

GEN_KEYS='["latest","released","php_min","php_recommended","symfony_major","twig_major","phpunit_constraint","coder_constraint","phpstan_constraint","phpstan_drupal_constraint","src"]'
mkdir -p "$TMP/out"
for file in "$DATA"/targets/*.json; do
  [[ -f "$file" ]] || continue
  rel="targets/$(basename "$file")"
  jq -e 'type == "object" and (.major | type) == "number" and (.minors | type) == "object"' "$file" > /dev/null 2>&1 \
    || die "cannot read $rel as a target file (invalid JSON, or no major/minors)" 1
  major="$(jq -r '.major' "$file")"
  pre="$(jq -r 'if .status == "pre-release" then "true" else "false" end' "$file")"
  cp "$file" "$TMP/work.json"
  touched=0
  for minor in $(jq -r '.minors | keys_unsorted[]' "$file"); do
    old="$(jq -c --arg m "$minor" '.minors[$m]' "$file")"
    tag="$(newest_tag "$minor" "$pre")"
    if [[ -z "$tag" ]]; then
      [[ "$(printf '%s' "$old" | jq -r '.status // ""')" == "detect" ]] || mismatch "$rel" "minors.$minor" "no tag of $minor on packagist"
      continue
    fi
    generated "$minor" "$tag"; gen="$GEN"
    new="$(jq -n -c --argjson o "$old" --argjson g "$gen" --arg asof "$AS_OF" '
      {latest: $g.latest, released: $g.released, php_min: $g.php_min, php_recommended: $g.php_recommended,
       php_supported: ($o.php_supported // null), php_unsupported: ($o.php_unsupported // null),
       symfony_major: $g.symfony_major, twig_major: $g.twig_major, phpunit_constraint: $g.phpunit_constraint,
       coder_constraint: $g.coder_constraint, phpstan_constraint: $g.phpstan_constraint,
       phpstan_drupal_constraint: $g.phpstan_drupal_constraint, src: $g.src, php_src: ($o.php_src // null),
       verified: (if $o | has("verified") then $o.verified else true end), checked_at: ($o.checked_at // $asof)}')"
    diffs="$(jq -n -c --argjson o "$old" --argjson n "$new" --argjson k "$GEN_KEYS" --arg f "$rel" --arg m "$minor" \
      '$k[] | select(($o[.] // null) != $n[.]) | {file: $f, path: ".minors[\"\($m)\"].\(.)", from: ($o[.] // null), to: $n[.]}')"
    [[ -n "$diffs" ]] || continue
    printf '%s\n' "$diffs" >> "$TMP/changed.jsonl"
    new="$(printf '%s' "$new" | jq -c --arg asof "$AS_OF" '.checked_at = $asof')"
    jq --arg m "$minor" --argjson v "$new" '.minors[$m] = $v' "$TMP/work.json" > "$TMP/work2.json"
    mv "$TMP/work2.json" "$TMP/work.json"; touched=1
  done
  if [[ "$touched" == "1" ]]; then
    jq --arg asof "$AS_OF" '.as_of = $asof' "$TMP/work.json" > "$TMP/work2.json"
    mv "$TMP/work2.json" "$TMP/work.json"
    cp "$TMP/work.json" "$TMP/out/$(basename "$file")"
  fi

  # Removals: in the tree at the previous major's newest tag, gone (or obsolete) at the removal tag.
  prev="$(newest_of_major "$((major - 1))")"
  n="$(jq -r '.removed_extensions | length' "$file")"
  i=0
  while [[ "$i" -lt "$n" ]]; do
    IFS="$(printf '\t')" read -r name kind rin state intro info <<EOF
$(jq -r --argjson i "$i" '.removed_extensions[$i] | [.name, .kind, .removed_in, (.state_at_removal // "absent"), (.introduced_in // "-"), (.info_path // "-")] | @tsv' "$file")
EOF
    i=$((i + 1))
    dir="modules"; [[ "$kind" == "theme" ]] && dir="themes"
    at="$(newest_tag "$rin" "$pre")"
    if [[ -z "$at" || -z "$prev" ]]; then mismatch "$rel" "removed_extensions.$name" "no tag to check $rin against"; continue; fi
    [[ "$info" != "-" ]] || info="core/$dir/$name/$name.info.yml"
    # Present before the removal: at the previous major's newest tag, or at the
    # minor that introduced it (skipped while that minor has no stable tag).
    before="$prev"
    [[ "$intro" != "-" ]] && before="$(newest_tag "$intro" false)"
    if [[ -n "$before" ]]; then
      rawprobe "$before" "$info"
      [[ "$PROBED" == "200" ]] || mismatch "$rel" "removed_extensions.$name" "not in the core tree at $before"
    fi
    if [[ "$state" == "obsolete" ]]; then
      raw "$at" "$info"
      grep -q '^lifecycle: obsolete' "$FETCHED" || mismatch "$rel" "removed_extensions.$name" "not lifecycle: obsolete at $at"
    else
      rawprobe "$at" "$info"
      [[ "$PROBED" == "404" ]] || mismatch "$rel" "removed_extensions.$name" "still in the core tree at $at"
    fi
  done
  while IFS="$(printf '\t')" read -r name rin; do
    [[ -n "$name" ]] || continue
    key="${name#core/}"
    [[ "$name" == core/* ]] || { mismatch "$rel" "removed_libraries.$name" "only core/ libraries can be checked"; continue; }
    at="$(newest_tag "$rin" "$pre")"
    if [[ -z "$at" || -z "$prev" ]]; then mismatch "$rel" "removed_libraries.$name" "no tag to check $rin against"; continue; fi
    raw "$prev" core/core.libraries.yml
    grep -qF -x -- "$key:" "$FETCHED" || mismatch "$rel" "removed_libraries.$name" "not in core.libraries.yml at $prev"
    raw "$at" core/core.libraries.yml
    if grep -qF -x -- "$key:" "$FETCHED"; then mismatch "$rel" "removed_libraries.$name" "still in core.libraries.yml at $at"; fi
  done < <(jq -r '.removed_libraries[] | [.name, .removed_in] | @tsv' "$file")

  # Completeness: nothing may disappear at the major's .0 without being listed.
  at0="$(newest_tag "$major.0" "$pre")"
  if [[ -n "$at0" && -n "$prev" ]]; then
    raw "$prev" core/core.libraries.yml; libkeys "$FETCHED" > "$TMP/k-prev"
    raw "$at0" core/core.libraries.yml; libkeys "$FETCHED" > "$TMP/k-at"
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      jq -e --arg n "core/$key" --arg r "$major.0" 'any(.removed_libraries[]; .name == $n and .removed_in == $r)' "$file" > /dev/null \
        || mismatch "$rel" "removed_libraries" "core/$key is in core.libraries.yml at $prev but not at $at0, and is not listed"
    done < <(LC_ALL=C comm -23 "$TMP/k-prev" "$TMP/k-at")
    infolist "$prev"; cp "$FETCHED" "$TMP/i-prev"
    infolist "$at0"; cp "$FETCHED" "$TMP/i-at"
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      name="$(basename "$path" .info.yml)"
      # Listed under its own info_path, or by name at the standard location.
      jq -e --arg n "$name" --arg p "$path" --arg r "$major.0" \
        'any(.removed_extensions[]; .removed_in == $r and ((.info_path // "") == $p or ((.info_path // "") == "" and .name == $n)))' "$file" > /dev/null \
        || mismatch "$rel" "removed_extensions" "$path is in the core tree at $prev but not at $at0, and is not listed"
    done < <(LC_ALL=C comm -23 "$TMP/i-prev" "$TMP/i-at")
  fi

  # Hand sources: an api-d7 node whose `changed` moved since it was read.
  while IFS="$(printf '\t')" read -r id url recorded; do
    [[ -n "$id" ]] || continue
    nid="$(printf '%s' "$url" | sed -n 's/.*api-d7\/node\.json?nid=\([0-9][0-9]*\).*/\1/p')"
    [[ -n "$nid" ]] || { mismatch "$rel" "hand_sources.$id" "not an api-d7 node URL: $url"; continue; }
    fetch "$url" "api-d7/node-$nid.json"
    current="$(jq -r '.list[0].changed | tonumber | todate | .[0:10]' "$FETCHED" 2> /dev/null || true)"
    if [[ "$current" != "$recorded" ]]; then
      jq -n -c --arg f "$rel" --arg i "$id" --arg r "$recorded" --arg c "${current:-unreadable}" \
        '{file: $f, id: $i, recorded: $r, current: $c}' >> "$TMP/stale.jsonl"
      log_warn "$rel: hand source $id changed on ${current:-?} (read on $recorded): re-check its fields by hand"
    fi
  done < <(jq -r '.hand_sources[] | [.id, .url, .changed] | @tsv' "$file")
done

# Every fetch succeeded: write the updated files now.
for out in "$TMP"/out/*.json; do
  [[ -f "$out" ]] || continue
  if [[ "$DRY" == "0" ]]; then
    cp "$out" "$DATA/targets/$(basename "$out")"; log_ok "targets/$(basename "$out"): updated"
  else
    log_info "targets/$(basename "$out"): would be updated (--dry-run)"
  fi
done

nchanged="$(grep -c . "$TMP/changed.jsonl" || true)"
nmis="$(grep -c . "$TMP/mismatches.jsonl" || true)"
nstale="$(grep -c . "$TMP/stale.jsonl" || true)"
log_info "refresh-data.sh: ${nchanged:-0} value(s) changed, ${nmis:-0} mismatch(es), ${nstale:-0} stale hand source(s)$([[ "$DRY" == "1" ]] && printf ' (--dry-run: nothing written)')"
if [[ "$AS_JSON" == "1" ]]; then
  jq -n -c --argjson dry "$([[ "$DRY" == "1" ]] && echo true || echo false)" \
    --argjson off "$([[ "$OFFLINE" == "1" ]] && echo true || echo false)" \
    --slurpfile c "$TMP/changed.jsonl" --slurpfile m "$TMP/mismatches.jsonl" --slurpfile s "$TMP/stale.jsonl" \
    '{ok: (($m | length) == 0 and ($s | length) == 0), dry_run: $dry, offline: $off, changed: $c, mismatches: $m, stale_hand_sources: $s}'
fi
[[ "${nmis:-0}" == "0" && "${nstale:-0}" == "0" ]] || exit 3
exit 0
