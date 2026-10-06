#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/canon.sh
# Canonical artifacts (AR-13; DET-2 of the determinism rules): one byte form
# for the same JSON document and its hash without the top-level "meta" (the
# only place a hashed artifact keeps timestamps, hosts and versions: what
# changes between two runs that compute the same thing), paths relative to
# the Drupal root whichever runner produced them (the host or the DDEV
# container), the LF-normalized hash of a file, the message part of a
# finding id and the atomic store of the worklist.
#
# Every function ends with `return 0`; an early `return 1` is an explicit,
# documented failure. Part of the shared library: scripts/lib/common.sh
# sources it with the other domain libs (never source it alone); see
# common.sh for the conventions.
# =============================================================================

# canon_json [ROOT] -> STDIN's JSON in its canonical form: keys sorted (jq -S,
# which sorts by code point whatever the locale), two-space indent, LF line
# endings, a CRLF inside a string made LF; with ROOT, the runner paths are
# stripped (relpath_strip_runner ROOT) after jq has undone the producer's
# escapes (\/, \uXXXX) and before the keys are sorted, so they sort as the
# relative paths they become. Array order is data and is kept: a producer
# sorts its arrays on documented keys before it writes them. Several input
# documents give several outputs; input that is not valid JSON throughout (a
# valid document followed by a broken one included) prints nothing.
# shellcheck disable=SC2120  # ROOT is optional; tests and the findings stage pass it
canon_json() {
  local prog='walk(if type == "string" then split("\r\n") | join("\n") else . end)' out
  if [[ -n "${1:-}" ]]; then
    out="$(LC_ALL=C jq -c . 2> /dev/null)" || return 0
    out="$(printf '%s\n' "$out" | relpath_strip_runner "$1" --json | LC_ALL=C jq -S "$prog" 2> /dev/null)" || return 0
  else
    out="$(LC_ALL=C jq -S "$prog" 2> /dev/null)" || return 0
  fi
  [[ -z "$out" ]] || printf '%s\n' "$out"
  return 0
}

# canon_json_hashable -> STDIN's JSON in its hashable canonical form: keys
# sorted, compact, without the top-level "meta" (generated_at, versions: what
# changes between two runs that resolve the same plan). One line, LF-ended.
canon_json_hashable() {
  jq -S -c 'if type == "object" then del(.meta) else . end' 2> /dev/null || true
  return 0
}

# sha256_hex -> the bare SHA-256 hex of STDIN's bytes (sha256sum, else shasum
# -a 256). Prints nothing when neither exists: a caller that needs the hash
# fails then.
sha256_hex() {
  local h=""
  if have_cmd sha256sum; then h="$(sha256sum | cut -d' ' -f1)"
  elif have_cmd shasum; then h="$(shasum -a 256 | cut -d' ' -f1)"
  else cat > /dev/null; return 0; fi
  [[ "$h" =~ ^[0-9a-f]{64}$ ]] && printf '%s' "$h"
  return 0
}

# json_hash -> "sha256:<hex>" of STDIN's bytes (sha256_hex); nothing when no
# hasher exists.
json_hash() {
  local h
  h="$(sha256_hex)"
  [[ -n "$h" ]] && printf 'sha256:%s' "$h"
  return 0
}

# sha256_lines FILE DIR -> "<line number>\t<sha256 hex>" for each line of
# FILE (its bytes without the newline), from ONE hasher process over one file
# per line written under DIR (created; the caller removes it): thousands of
# ids cost one fork, not one each. A line must hold no NUL byte (BusyBox awk
# ends a record there). Prints nothing for an empty FILE or when no hasher
# exists.
sha256_lines() {
  local f="${1:-}" d="${2:-}"
  [[ -f "$f" && -n "$d" ]] || return 0
  mkdir -p "$d" || return 0
  awk -v d="$d" '{ p = d "/" NR; printf "%s", $0 > p; close(p) }' "$f"
  if have_cmd sha256sum; then
    ( cd "$d" && find . -type f -exec sha256sum {} + ) | awk '{ p = $NF; sub(/^\.\//, "", p); print p "\t" $1 }'
  elif have_cmd shasum; then
    ( cd "$d" && find . -type f -exec shasum -a 256 {} + ) | awk '{ p = $NF; sub(/^\.\//, "", p); print p "\t" $1 }'
  fi
  return 0
}

# file_hash FILE -> "sha256:<hex>" of FILE's bytes with every CRLF made LF (a
# CR not followed by LF is data, at the end of the file too; a last line
# without LF stays without one), so a checkout with CRLF line endings hashes
# as the LF one. Nothing for a missing file or without a hasher.
file_hash() {
  local f="${1:-}" h="" final=1
  [[ -f "$f" && -r "$f" ]] || return 0
  if LC_ALL=C grep -q "$(printf '\r')" "$f" 2> /dev/null; then
    [[ -z "$(tail -c 1 "$f" 2> /dev/null)" ]] || final=0
    # A record is printed once the next one shows it ended with LF.
    h="$(LC_ALL=C awk -v final="$final" 'NR > 1 { sub(/\r$/, "", prev); printf "%s\n", prev }
      { prev = $0 }
      END { if (NR > 0) { if (final == 1) { sub(/\r$/, "", prev); printf "%s\n", prev } else printf "%s", prev } }' "$f" | sha256_hex)"
  else
    h="$(sha256_hex < "$f")"
  fi
  [[ -n "$h" ]] && printf 'sha256:%s' "$h"
  return 0
}

# relpath_strip_runner [ROOT] [--json] -> STDIN with the runner prefixes of
# the Drupal root removed wherever they appear (JSON keys, values, inside
# messages): the DDEV container's /var/www/html/ and, with ROOT, the host's
# ROOT/ (as given and its physical path when ROOT is a symlink), each also
# with / escaped as \/; with --json (STDIN is JSON text, as canon_json passes
# it) also with " and \ escaped as JSON escapes them. A bare root not
# followed by a path character becomes ".". So the
# same tree gives the same root-relative paths on the host and in DDEV. The
# match is literal (no regex), byte-wise (LC_ALL=C); a ROOT of / adds nothing.
# STDIN is one record (a \001 byte in it is kept unless it ends the input),
# so a last line without LF stays without one.
relpath_strip_runner() {
  local root="${1:-}" phys="" json=0
  [[ "${2:-}" == "--json" ]] && json=1
  while [[ "$root" == */ ]]; do root="${root%/}"; done
  if [[ -n "$root" && -d "$root" ]]; then
    phys="$(cd -P "$root" 2> /dev/null && pwd -P || true)"
    [[ "$phys" == "$root" || "$phys" == "/" ]] && phys=""
  fi
  _CANON_R1="$root" _CANON_R2="$phys" _CANON_JSON="$json" LC_ALL=C awk '
    function esc(s,   o, i, c) {
      o = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); o = o (c == "/" ? "\\/" : c) }
      return o
    }
    function jesc(s,   o, i, c) {
      o = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") o = o "\\\\"; else if (c == "\"") o = o "\\\""; else o = o c
      }
      return o
    }
    function add(p, sep,   k) {
      for (k = 1; k <= n; k++) if (B[k] == p) return
      n++; P[n] = p sep; B[n] = p
    }
    function strip(s, p,   o, i) {
      o = ""
      while ((i = index(s, p)) > 0) { o = o substr(s, 1, i - 1); s = substr(s, i + length(p)) }
      return o s
    }
    function bare(s, p,   o, i, c) {
      o = ""
      while ((i = index(s, p)) > 0) {
        c = substr(s, i + length(p), 1)
        if (c == "" || c !~ /[A-Za-z0-9._~+-]/) o = o substr(s, 1, i - 1) "."
        else o = o substr(s, 1, i - 1 + length(p))
        s = substr(s, i + length(p))
      }
      return o s
    }
    BEGIN {
      RS = "\001"; n = 0
      r[1] = ENVIRON["_CANON_R1"]; r[2] = ENVIRON["_CANON_R2"]; r[3] = "/var/www/html"
      for (k = 1; k <= 3; k++) {
        if (r[k] == "") continue
        add(r[k], "/"); add(esc(r[k]), "\\/")
        if (ENVIRON["_CANON_JSON"] == "1") { add(jesc(r[k]), "/"); add(esc(jesc(r[k])), "\\/") }
      }
      # Longest prefix first, so a root nested in another one is matched whole.
      for (i = 2; i <= n; i++) {
        p = P[i]; b = B[i]
        for (j = i - 1; j >= 1 && length(P[j]) < length(p); j--) { P[j + 1] = P[j]; B[j + 1] = B[j] }
        P[j + 1] = p; B[j + 1] = b
      }
    }
    {
      s = $0
      for (k = 1; k <= n; k++) s = strip(s, P[k])
      for (k = 1; k <= n; k++) s = bare(s, B[k])
      printf "%s%s", (NR > 1 ? "\001" : ""), s
    }'
  return 0
}

# canon_jq_defs -> the jq definitions of the canonical forms, to prefix a jq
# program with (normalize-findings uses them on every finding at once):
#   finding_norm_message   the message part of a finding id (05 §2.4): "on
#                          line N" dropped, NUL bytes dropped, PHPStan's
#                          anonymous class name (class@anonymous/<file>:<line>,
#                          or <Parent>@anonymous/<file>:<line>) made
#                          ...@anonymous, every whitespace run (newlines
#                          included) made one space, trimmed: a line shift
#                          keeps the message. Runner paths are stripped
#                          before (canon_json ROOT strips them in the whole
#                          raw document).
canon_jq_defs() {
  printf '%s\n' 'def finding_norm_message: split("\u0000") | join("") | gsub("\\s+on line [0-9]+"; "") | gsub("@anonymous[^\\s:]*:[0-9]+"; "@anonymous") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");'
  return 0
}

# finding_norm_message [ROOT] -> STDIN (one message, newlines included) in its
# normalized form (canon_jq_defs), runner paths stripped first
# (relpath_strip_runner ROOT). No trailing newline.
finding_norm_message() {
  relpath_strip_runner "${1:-}" | jq -R -s -j "$(canon_jq_defs) finding_norm_message" 2> /dev/null || true
  return 0
}

# worklist_file [SUBJECT] -> the subject's worklist.json, in its hidden state
# dir (never created here).
worklist_file() {
  printf '%s/worklist.json' "$(project_state_path "${1:-$PWD}")"
  return 0
}

# worklist_get [SUBJECT] [JQ_FILTER] -> the filter (default .) applied to the
# subject's worklist, compact; nothing when there is none or it is unreadable.
worklist_get() {
  local f
  f="$(worklist_file "${1:-$PWD}")"
  [[ -r "$f" ]] || return 0
  jq -c "${2:-.}" "$f" 2> /dev/null || true
  return 0
}

# worklist_set [SUBJECT] -> writes STDIN (one JSON object) as the subject's
# worklist, in its canonical form (canon_json), atomically: a temporary file
# in the same directory, then mv, so a reader never sees half a document and
# concurrent writers leave one whole document. Returns 1, the worklist
# untouched, when STDIN is not one JSON object or the write fails.
worklist_set() {
  local d raw doc tmp
  raw="$(cat)"
  # The raw input itself must be one object: jq -s fails on any broken part.
  if ! printf '%s\n' "$raw" | jq -e -s 'length == 1 and (.[0] | type) == "object"' > /dev/null 2>&1 \
     || ! doc="$(printf '%s\n' "$raw" | canon_json)" || [[ -z "$doc" ]]; then
    log_err "worklist_set: STDIN is not one JSON object; the worklist is unchanged."
    return 1
  fi
  d="$(project_state_dir "${1:-$PWD}")"
  tmp="$(mktemp "$d/.worklist.json.XXXXXX" 2> /dev/null || true)"
  if [[ -n "$tmp" ]] && printf '%s\n' "$doc" > "$tmp" && mv -f "$tmp" "$d/worklist.json"; then
    return 0
  fi
  [[ -z "$tmp" ]] || rm -f "$tmp" 2> /dev/null || true
  log_err "worklist_set: could not write $d/worklist.json; the worklist is unchanged."
  return 1
}

# recipes_effective BASE OVERLAY OUT -> writes to OUT the recipes in effect
# (ADR 0024): BASE (config/recipes.json), with the recipes of OVERLAY (a
# project's <root>/.drupilot/recipes.json; empty: none) replacing BASE's by
# id, sorted by id, as {recipes: [...]}. Returns 1, writing nothing, when a
# file is not a recipe catalog: every recipe needs a string id, a lane of
# AR-10, a matches object and a template with a why.
recipes_effective() {
  local base="${1:-}" ov="${2:-}" out="${3:-}" f
  [[ -n "$base" && -n "$out" ]] || return 1
  for f in "$base" ${ov:+"$ov"}; do
    jq -e '(.recipes | type) == "array" and all(.recipes[]; (.id | type) == "string"
             and (.lane | IN("rector", "rector-custom", "codemod", "ai-templated", "ai-free", "test-adapt", "human", "deferred"))
             and (.matches | type) == "object" and (.template | type) == "object" and (.template.why | type) == "string")' \
      "$f" > /dev/null 2>&1 || return 1
  done
  if [[ -n "$ov" ]]; then
    jq -s '{recipes: ((.[0].recipes | map({key: .id, value: .}) | from_entries) + (.[1].recipes | map({key: .id, value: .}) | from_entries)
            | to_entries | map(.value) | sort_by(.id))}' "$base" "$ov" > "$out" 2> /dev/null || return 1
  else
    jq '{recipes: (.recipes | sort_by(.id))}' "$base" > "$out" 2> /dev/null || return 1
  fi
  return 0
}
