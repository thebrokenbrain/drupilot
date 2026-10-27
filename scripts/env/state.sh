#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/state.sh
# The per-module state registry: one state.json per subject (stage reached and
# when, effort, branch/commit, toolchain, preservation and core-matrix verdicts,
# last patch), kept in the subject's HIDDEN state dir like assess.json and
# last-test.json (machine state survives `git clean` and never leaks into a
# patch). The schema is documented in common.sh ("Per-subject state") and in
# docs/reference/state.md.
#
# Subcommands:
#   record   mark a stage as reached now and refresh the snapshot. The flow's
#            deterministic scripts record ported/refactored (port-report.sh)
#            and tested (run-phpunit.sh) themselves; the commands call this for
#            setup, assessed and contributed.
#   refresh  re-read the source records (assess.json, last-test.json,
#            core-matrix.json, the lockfile, git) into state.json, no stage
#            change.
#   show     one subject's record, merged with what can be read right now.
#            Read-only.
#   list     a portfolio view of several subjects / workspaces. Read-only.
#
# Usage:
#   state.sh record  --subject DIR --stage STAGE [--effort S|M|L|XL] [--force]
#                    [--portfolio DIR [--layer N]] [--dry-run] [--json]
#   state.sh refresh --subject DIR [--portfolio DIR [--layer N]] [--dry-run]
#                    [--json]
#   state.sh show    [--subject DIR] [--no-next] [--json]
#   state.sh list    [--root DIR]... [--registry FILE] [--subject DIR]...
#                    [--depth N] [--from-preflight] [--no-next] [--json]
#
#   --subject DIR    the module/theme directory (default, or when empty: the
#                    current directory; show also falls back to it, with a
#                    warning, for a value that is not a directory).
#   --stage STAGE    setup | assessed | ported | refactored | tested |
#                    contributed (verbs such as assess / port are accepted).
#   --effort X       the assessment verdict (S/M/L/XL), stored as `effort`; the
#                    cached assess.json, when present, stays authoritative.
#   --force          let this record LOWER the stage (DRUPILOT_STATE_FORCE).
#   --portfolio DIR  record/refresh: the set the subject is ported with (the
#                    directory given to /drupilot-layers), stored as
#                    `portfolio: {dir, layer}`; --layer N is its porting layer
#                    (layers.sh).
#   --root DIR       list: every module/theme under DIR (up to --depth levels,
#                    default 8; vendor/, core/, node_modules/, tests/ and
#                    dot-dirs are skipped) that drupilot has state for, plus
#                    every recorded subject whose path or origin is under DIR.
#                    Repeatable; e.g. a directory holding several workspaces.
#   --registry FILE  list: a text file with one path per line (relative paths
#                    resolve against the file's directory; blank lines and
#                    `#` comments are ignored). A module/theme directory is
#                    listed as is; any other directory is scanned like --root.
#   With no --root/--registry/--subject, list shows every subject that has a
#   state.json in drupilot's data dir. A subject with only older records
#   (assess.json, last-test.json, no state.json) is found by --root/--subject,
#   since its path cannot be recovered from the state dir's name.
#   --from-preflight list/show: read the environment readiness once from
#                    `preflight.sh --profile all` for the `next` column (else
#                    the environment is assumed ready: the column then names
#                    the next PORTING step).
#   --no-next        do not compute the next step (faster: no next-step.sh run).
#   --dry-run        record/refresh: print the record that would be written,
#                    write nothing.
#   --json           print the JSON payload on STDOUT. The human view always
#                    goes to STDERR, so STDOUT stays parseable.
#
# Output (STDOUT with --json):
#   record/refresh/show: the subject's record (schema in common.sh) plus
#     `recorded` (a state.json exists), `exists` (the directory exists),
#     `patch.exists` and, for show, `next: {step, command, reason}`.
#   list: {generated_at, data_dir, scope: {roots, registry, subjects}, count,
#          subjects: [record + next, ...]} sorted by Drupal root, then name.
#
# Exit codes: 0 ok · 1 usage error / not a module or theme directory (record,
# refresh) / jq missing.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

usage() { print_usage "$0"; }

CMD="${1:-}"
case "$CMD" in
  record|refresh|show|list) shift;;
  -h|--help|help) usage; exit 0;;
  "") usage >&2; die "Missing subcommand (record, refresh, show or list)." 1;;
  *) usage >&2; die "Unknown subcommand: $CMD" 1;;
esac

SUBJECTS=(); ROOTS=(); REGISTRY=""; STAGE=""; EFFORT=""; FORCE=0; DRY=0; AS_JSON=0
NEXT=1; FROM_PF=0; DEPTH=8; PORTFOLIO=""; LAYER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    # An empty --subject (an unset "$1" in a command's load-time line) means
    # the current directory, as in next-step.sh.
    --subject) [[ -n "${2:-}" ]] && SUBJECTS+=("$2"); shift; [[ $# -gt 0 ]] && shift;;
    --subject=*) [[ -n "${1#*=}" ]] && SUBJECTS+=("${1#*=}"); shift;;
    --stage) STAGE="${2:-}"; shift 2;;
    --stage=*) STAGE="${1#*=}"; shift;;
    --effort) EFFORT="${2:-}"; shift 2;;
    --effort=*) EFFORT="${1#*=}"; shift;;
    --root) [[ -n "${2:-}" ]] || die "--root needs a directory." 1; ROOTS+=("$2"); shift 2;;
    --root=*) ROOTS+=("${1#*=}"); shift;;
    --registry) REGISTRY="${2:-}"; shift 2;;
    --registry=*) REGISTRY="${1#*=}"; shift;;
    --depth) DEPTH="${2:-}"; shift 2;;
    --depth=*) DEPTH="${1#*=}"; shift;;
    --portfolio) PORTFOLIO="${2:-}"; shift 2 || die "--portfolio needs a directory." 1;;
    --portfolio=*) PORTFOLIO="${1#*=}"; shift;;
    --layer) LAYER="${2:-}"; shift 2 || die "--layer needs a number." 1;;
    --layer=*) LAYER="${1#*=}"; shift;;
    --force) FORCE=1; shift;;
    --dry-run) DRY=1; shift;;
    --json) AS_JSON=1; shift;;
    --no-next) NEXT=0; shift;;
    --from-preflight) FROM_PF=1; shift;;
    -h|--help) usage; exit 0;;
    *) usage >&2; die "Unknown argument: $1" 1;;
  esac
done

have_cmd jq || die "jq is required for the state registry." 1
[[ "$DEPTH" =~ ^[0-9]+$ && "$DEPTH" -gt 0 ]] || die "--depth must be a positive integer: '$DEPTH'" 1
[[ -z "$LAYER" || "$LAYER" =~ ^[0-9]+$ ]] || die "--layer must be a non-negative integer: '$LAYER'" 1
[[ -z "$LAYER" || -n "$PORTFOLIO" ]] || die "--layer needs --portfolio DIR." 1
if [[ -n "$PORTFOLIO" ]]; then
  [[ -d "$PORTFOLIO" ]] || die "Portfolio directory not found: $PORTFOLIO" 1
  PORTFOLIO="$(cd "$PORTFOLIO" && pwd)"
fi

# abs_dir DIR -> absolute logical path (the form project_state_dir keys on).
abs_dir() { ( cd "$1" 2>/dev/null && pwd ) || printf '%s' "$1"; }

# one_subject -> the single --subject (default: the current directory).
# show falls back to the current directory for a value that is not a
# directory (e.g. a router mode word passed as $1), with a warning.
one_subject() {
  [[ "${#SUBJECTS[@]}" -le 1 ]] || die "$CMD takes one --subject." 1
  local s="${SUBJECTS[0]:-$PWD}"
  if [[ ! -d "$s" ]]; then
    [[ "$CMD" == "show" ]] || die "Subject directory not found: $s" 1
    log_warn "'$s' is not a directory; using the current directory as the subject."
    s="$PWD"
  fi
  abs_dir "$s"
}

# need_extension DIR -> die unless DIR is a module/theme/profile directory, so a
# record never lands on a Drupal root or a random directory by mistake.
need_extension() {
  is_drupal_extension_dir "$1" \
    || die "'$1' has no *.info.yml: pass the module/theme directory as --subject (not the Drupal root)." 1
}

# Readiness for next-step.sh: assumed ready unless --from-preflight.
READY=(--ready-analyze true --ready-setup true --ready-test true --ready-contribute true)
if [[ "$FROM_PF" == "1" && "$NEXT" == "1" ]]; then
  _pf="$(bash "$(plugin_root)/scripts/env/preflight.sh" --profile all --json --quiet 2>/dev/null \
    | jq -r '.ready | [.analyze, .setup, .test, .contribute] | map(if . == null then "true" else tostring end) | join(" ")' 2>/dev/null || true)"
  if [[ -n "$_pf" ]]; then
    # shellcheck disable=SC2086  # four space-separated booleans.
    set -- $_pf
    READY=(--ready-analyze "$1" --ready-setup "$2" --ready-test "$3" --ready-contribute "$4")
  else
    log_warn "Could not read readiness from preflight; assuming the environment is ready."
  fi
fi

# with_next JSON -> JSON plus `next` (null with --no-next or a missing subject).
with_next() {
  local v="$1" s n="null"
  s="$(printf '%s' "$v" | jq -r 'if .exists then .subject else empty end' 2>/dev/null || true)"
  if [[ "$NEXT" == "1" && -n "$s" ]]; then
    n="$(bash "$(plugin_root)/scripts/env/next-step.sh" --subject "$s" "${READY[@]}" --json 2>/dev/null \
      | jq -c '{step: .next, command: (.command | if . == "" then null else . end), reason}' 2>/dev/null || true)"
    [[ -n "$n" ]] || n="null"
  fi
  printf '%s' "$v" | jq -c --argjson n "$n" '. + {next: $n}'
}

# human_record JSON -> a key/value view on STDERR.
human_record() {
  printf '%s' "$1" | jq -r '
    def v: if . == null then "-" else tostring end;
    "Subject:      \(.machine_name | v) (\(.type | v)) — \(.subject)",
    "Workspace:    \(.drupal_root | v)\(if .ddev_project then " [ddev: \(.ddev_project)]" else "" end)",
    (if .origin then "Origin:       \(.origin) (\(.placement | v))" else empty end),
    "Stage:        \(.stage | v)\(if (.stages // {}) != {} then "  (" + ([.stages | to_entries[] | "\(.key) \(.value)"] | join(", ")) + ")" else "" end)",
    "Effort:       \(.effort | v)\(if .assessed_at then " (assessed \(.assessed_at))" else "" end)",
    "Git:          \(if .git then "\(.git.branch) @ \((.git.commit // "-")[0:12])\(if .git.dirty then " (uncommitted changes)" else "" end)" else "-" end)",
    "Toolchain:    \(if .toolchain then "Drupal \(.toolchain.drupal_core | v), PHP target \(.toolchain.php_target | v), rector \(.toolchain.packages["rector/rector"] | v), drupal-rector \(.toolchain.packages["palantirnet/drupal-rector"] | v), phpstan \(.toolchain.packages["phpstan/phpstan"] | v)" else "-" end)",
    "Tests:        \(if .tests then "\(.tests.status | v), preservation \(.tests.preservation | v), \(.tests.executed | v) executed, \(.tests.tests_failed | v) failing (\(.tests.recorded_at | v))\(if .tests.fresh == false then " — STALE: sources changed since" else "" end)" else "not run" end)",
    "Core matrix:  \(if .core_matrix then "\(.core_matrix.verdict | v), Drupal 10 \(.core_matrix.d10_support | v) (\(.core_matrix.generated_at | v))\(if .core_matrix.fresh == false then " — STALE" else "" end)" else "not run" end)",
    "Patch:        \(if .patch then "\(.patch.path) [\(.patch.kind | v)]\(if .patch.exists == false then " — MISSING" else "" end)" else "-" end)",
    "Updated:      \(.updated | v)\(if .recorded | not then " (no state.json yet: derived from the older records)" else "" end)",
    (if .next then "Next:         \(.next.command // "(nothing required)") — \(.next.reason | v)" else empty end)' >&2
}

case "$CMD" in
  # -------------------------------------------------------------------------
  record|refresh)
    SUBJ="$(one_subject)" || exit 1
    need_extension "$SUBJ"
    if [[ "$CMD" == "record" ]]; then
      [[ -n "$STAGE" ]] || die "record needs --stage (setup, assessed, ported, refactored, tested, contributed)." 1
      ST="$(stage_normalize "$STAGE")"
      [[ -n "$ST" ]] || die "Unknown stage '$STAGE' (setup, assessed, ported, refactored, tested, contributed)." 1
    fi
    if [[ -n "$EFFORT" ]]; then
      EFFORT="$(printf '%s' "$EFFORT" | tr '[:lower:]' '[:upper:]')"
      case "$EFFORT" in S|M|L|XL) ;; *) die "--effort must be S, M, L or XL: '$EFFORT'" 1;; esac
    fi
    if [[ "$DRY" == "1" ]]; then
      V="$(state_view_json "$SUBJ")"
      if [[ "$CMD" == "record" ]]; then
        V="$(printf '%s' "$V" | jq -c --arg st "$ST" --arg e "$EFFORT" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '.stages[$st] = $at | (if $e != "" then .effort = (.effort // $e) else . end)')"
        log_info "Dry run: would record stage '$ST' for $(basename "$SUBJ") (nothing written)."
      else
        log_info "Dry run: would refresh the state of $(basename "$SUBJ") (nothing written)."
      fi
      human_record "$V"
      [[ "$AS_JSON" == "1" ]] && printf '%s\n' "$V"
      exit 0
    fi
    [[ -n "$EFFORT" ]] && { state_set "$SUBJ" .effort "$EFFORT" || die "Could not write $(subject_state_file "$SUBJ")." 1; }
    if [[ -n "$PORTFOLIO" ]]; then
      state_set_json "$SUBJ" .portfolio "$(jq -nc --arg d "$PORTFOLIO" --arg l "$LAYER" '{dir: $d, layer: (if $l == "" then null else ($l | tonumber) end)}')" \
        || die "Could not write $(subject_state_file "$SUBJ")." 1
    fi
    if [[ "$CMD" == "record" ]]; then
      if [[ "$FORCE" == "1" ]]; then
        DRUPILOT_STATE_FORCE=true phase_record "$SUBJ" "$ST" || die "Could not write $(subject_state_file "$SUBJ")." 1
      else
        phase_record "$SUBJ" "$ST" || die "Could not write $(subject_state_file "$SUBJ")." 1
      fi
      CUR="$(phase_get "$SUBJ")"
      if [[ "$CUR" == "$ST" ]]; then log_ok "Recorded stage '$ST' for $(basename "$SUBJ")."
      else log_ok "Recorded stage '$ST' for $(basename "$SUBJ"); its stage stays '$CUR' (stages never go down without --force)."; fi
    else
      state_refresh "$SUBJ" || die "Could not write $(subject_state_file "$SUBJ")." 1
      log_ok "Refreshed the state of $(basename "$SUBJ")."
    fi
    V="$(state_view_json "$SUBJ")"
    [[ "$AS_JSON" == "1" ]] && printf '%s\n' "$V"
    exit 0
    ;;

  # -------------------------------------------------------------------------
  show)
    SUBJ="$(one_subject)" || exit 1
    V="$(with_next "$(state_view_json "$SUBJ")")"
    is_drupal_extension_dir "$SUBJ" || log_warn "'$SUBJ' has no *.info.yml — is it the module/theme directory?"
    human_record "$V"
    [[ "$AS_JSON" == "1" ]] && printf '%s\n' "$V"
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------
CAND="$(mktemp)"; trap 'rm -f "$CAND"' EXIT

# has_state DIR -> 0 when drupilot keeps any record for DIR.
has_state() {
  local sd f; sd="$(project_state_path "$1")"
  [[ -d "$sd" ]] || return 1
  for f in state.json assess.json last-test.json port-manifest.json core-matrix.json phase; do
    [[ -e "$sd/$f" ]] && return 0
  done
  return 1
}

# scan_root DIR -> append the module/theme dirs under DIR that have state.
scan_root() {
  local r="$1" f d
  # Real directories, then symlinked ones (a `symlink` placement), which find
  # does not descend into.
  { find "$r" -maxdepth "$DEPTH" \( -name vendor -o -name node_modules -o -name core -o -name tests \
        -o -name 'files' -o \( -name '.*' ! -name . \) \) -prune -o -name '*.info.yml' -type f -print 2>/dev/null \
      | while IFS= read -r f; do dirname "$f"; done
    find "$r" -maxdepth "$DEPTH" \( -name vendor -o -name node_modules -o -name core -o -name tests \
        -o -name 'files' -o \( -name '.*' ! -name . \) \) -prune -o -type l -print 2>/dev/null \
      | while IFS= read -r d; do
          if [[ -d "$d" ]] && is_drupal_extension_dir "$d"; then printf '%s\n' "$d"; fi
        done
  } | while IFS= read -r d; do
      if has_state "$d"; then abs_dir "$d"; printf '\n'; fi
    done >> "$CAND"
  # Recorded subjects whose path or origin lies under DIR (e.g. a subject
  # deeper than --depth, or one whose directory is gone).
  recorded_subjects | while IFS=$'\t' read -r s o; do
    case "$s/" in "$r"/*) printf '%s\n' "$s" >> "$CAND"; continue;; esac
    case "$o/" in "$r"/*) printf '%s\n' "$s" >> "$CAND";; esac
  done
  return 0
}

# recorded_subjects -> "subject<TAB>origin" for every state.json in the data dir.
recorded_subjects() {
  local f
  for f in "$(data_dir_path)"/state/*/state.json; do
    [[ -r "$f" ]] || continue
    jq -r 'select(type == "object" and (.subject // "") != "") | [.subject, (.origin // "")] | @tsv' "$f" 2>/dev/null || true
  done
  return 0
}

SCOPE_ROOTS=()
add_root() {
  [[ -d "$1" ]] || { log_warn "Not a directory, skipped: $1"; return 0; }
  local a; a="$(abs_dir "$1")"
  SCOPE_ROOTS+=("$a"); scan_root "$a"
}

for r in ${ROOTS[@]+"${ROOTS[@]}"}; do add_root "$r"; done
SCOPE_SUBJECTS=()
for s in ${SUBJECTS[@]+"${SUBJECTS[@]}"}; do
  if [[ -d "$s" ]]; then SCOPE_SUBJECTS+=("$(abs_dir "$s")"); abs_dir "$s" >> "$CAND"; printf '\n' >> "$CAND"
  else log_warn "Not a directory, skipped: $s"; fi
done
if [[ -n "$REGISTRY" ]]; then
  [[ -r "$REGISTRY" ]] || die "Registry file not readable: $REGISTRY" 1
  REG_DIR="$(abs_dir "$(dirname "$REGISTRY")")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -n "$line" ]] || continue
    case "$line" in /*) ;; "~"/*) line="$HOME/${line#\~/}";; *) line="$REG_DIR/$line";; esac
    if [[ -d "$line" ]] && is_drupal_extension_dir "$line"; then
      abs_dir "$line" >> "$CAND"; printf '\n' >> "$CAND"
    else
      add_root "$line"
    fi
  done < "$REGISTRY"
fi
if [[ "${#ROOTS[@]}" -eq 0 && "${#SUBJECTS[@]}" -eq 0 && -z "$REGISTRY" ]]; then
  recorded_subjects | cut -f1 >> "$CAND"
fi

ITEMS="$(mktemp)"; trap 'rm -f "$CAND" "$ITEMS"' EXIT
LC_ALL=C sort -u "$CAND" | while IFS= read -r s; do
  [[ -n "$s" ]] || continue
  with_next "$(state_view_json "$s")"
  printf '\n'
done > "$ITEMS"

OUT="$(jq -s -c --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg dd "$(data_dir_path)" \
  --argjson roots "$(printf '%s\n' ${SCOPE_ROOTS[@]+"${SCOPE_ROOTS[@]}"} | jq -R . | jq -s 'map(select(. != ""))')" \
  --argjson subjects "$(printf '%s\n' ${SCOPE_SUBJECTS[@]+"${SCOPE_SUBJECTS[@]}"} | jq -R . | jq -s 'map(select(. != ""))')" \
  --arg registry "$REGISTRY" '
  map(select(. != null)) | sort_by([(.drupal_root // ""), (.machine_name // ""), .subject]) as $s
  | {generated_at: $at, data_dir: $dd,
     scope: {roots: $roots, registry: (if $registry == "" then null else $registry end), subjects: $subjects},
     count: ($s | length), subjects: $s}' "$ITEMS")"

# Human table (STDERR).
if [[ "$(printf '%s' "$OUT" | jq '.count')" == "0" ]]; then
  log_info "No drupilot state found for this scope."
else
  printf '%s' "$OUT" | jq -r '
    def v: if . == null then "-" else tostring end;
    ["MODULE", "WORKSPACE", "STAGE", "EFFORT", "TESTS", "D10 (MATRIX)", "GIT", "CORE", "UPDATED", "NEXT"],
    (.subjects[] | [
      (.machine_name // (.subject | split("/") | last)) + (if .exists then "" else " (missing)" end),
      (.ddev_project // ((.drupal_root // "-") | split("/") | last)),
      (.stage | v),
      (.effort | v),
      (if .tests then (.tests.preservation // .tests.status | v) + (if .tests.fresh == false then "*" else "" end) else "-" end),
      (if .core_matrix then (.core_matrix.d10_support | v) + (if .core_matrix.fresh == false then "*" else "" end) else "-" end),
      (if .git then "\(.git.branch)@\((.git.commit // "")[0:7])\(if .git.dirty then "+" else "" end)" else "-" end),
      (.toolchain.drupal_core | v),
      ((.updated // .tests.recorded_at // .assessed_at) | v | .[0:10]),
      (if .next then (.next.command // "done") else "-" end)
    ]) | @tsv' > "$ITEMS"
  if have_cmd column; then column -t -s "$(printf '\t')" < "$ITEMS" >&2; else cat "$ITEMS" >&2; fi
  printf '%s\n' "(* = computed on older sources; + = uncommitted changes. Details: state.sh show --subject DIR)" >&2
fi
[[ "$AS_JSON" == "1" ]] && printf '%s\n' "$OUT"
exit 0
