#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/tests/negative-control.sh
# Prove that a test GUARDS a production change: undo the change, run the test
# and require it to go RED, restore the code byte for byte, run it again and
# require it to go GREEN. A test that stays green without the change it is
# supposed to protect is "ineffective": it must be strengthened, never accepted.
#
# The change to undo is given either as
#   * --revert-to REF --path FILE...  each FILE gets its content at git REF (the
#     code before the fix); a FILE absent at REF is removed for the red run; or
#   * --mutation-patch FILE           a minimal patch of the covered production
#     code (flip a condition, drop an `implements`, ...), paths relative to the
#     subject (a/… b/… prefixes as `git diff` writes them).
# Only production code may be mutated: a path under tests/, outside the subject,
# or in a git conflict state is refused (mutating the test is not a control).
#
# Safety: every target file is backed up and hashed (`git hash-object`) BEFORE
# it is touched, and an EXIT/INT/TERM trap restores it even on error or Ctrl-C.
# The restore refuses to overwrite a file that changed during the run (someone
# edited it): the backup is kept and its path printed. After the restore every
# hash must match the original (`restored_identical`), or the verdict is error.
# Do not edit the target files while a control runs.
#
# The two runs go through run-phpunit.sh --no-record --no-baseline, so a
# deliberate red run never touches last-test.json or the baseline. Their PHPUnit
# output is kept in per-run logs under the subject's state dir.
#
# Usage:
#   negative-control.sh --subject DIR --filter EXPR
#                       [--type unit|kernel|functional|js|all]
#                       (--revert-to REF --path FILE [--path FILE ...]
#                        | --mutation-patch FILE)
#                       [--label TEXT] [--manifest FILE] [--json] [--dry-run]
#
#   --filter EXPR   the test(s) under control (PHPUnit --filter: a class, a
#                   method, Class::method). Required: a control is about a test.
#   --type T        the test group (default all; give it, Kernel/Functional
#                   suites are slow).
#   --label TEXT    what the control guards (e.g. "H15 getOriginal rename").
#   --manifest FILE also append the record to FILE's
#                   .verification.negative_controls array (a port-manifest.json).
#   --dry-run       validate the inputs and show the planned mutation; no run,
#                   no file touched.
#
# Output: with --json the record on STDOUT:
#   {test, type, label, mutation:{kind, ref|patch, paths}, mutated_rc,
#    restored_rc, red_tests, mutated_executed, restored_executed,
#    restored_identical, verdict, reason, logs:{red, green}, subject_digest, at}
# The record is also stored in negative-controls.json (state dir; one entry per
# test+type+label, the latest wins) and summarized into last-test.json's
# `negative_controls`. Logs on STDERR.
#
# Verdicts / exit codes:
#   0  effective   -> red with the change undone, green once restored, identical.
#   4  ineffective -> the test stayed green without the change: it does not guard it.
#   1  error       -> usage error, or an inconclusive control: the filter ran no
#                     test, the restored code is not green, the restore was not
#                     byte-identical, or the mutation could not be applied.
#   2  blocked     -> the test environment is not available (run-phpunit.sh exit 2).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
FILTER=""
TYPE="all"
REF=""
PATCH_FILE=""
LABEL=""
MANIFEST=""
JSON=0
DRY_RUN=0
declare -a PATHS=()

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --filter|--test) FILTER="${2:-}"; shift 2;;
    --filter=*|--test=*) FILTER="${1#*=}"; shift;;
    --type) TYPE="${2:-}"; shift 2;;
    --type=*) TYPE="${1#*=}"; shift;;
    --revert-to) REF="${2:-}"; shift 2;;
    --revert-to=*) REF="${1#*=}"; shift;;
    --path) PATHS+=("${2:-}"); shift 2;;
    --path=*) PATHS+=("${1#*=}"); shift;;
    --mutation-patch) PATCH_FILE="${2:-}"; shift 2;;
    --mutation-patch=*) PATCH_FILE="${1#*=}"; shift;;
    --label) LABEL="${2:-}"; shift 2;;
    --label=*) LABEL="${1#*=}"; shift;;
    --manifest) MANIFEST="${2:-}"; shift 2;;
    --manifest=*) MANIFEST="${1#*=}"; shift;;
    --json) JSON=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)." 1;;
  esac
done

have_cmd jq  || die "jq is required." 1
have_cmd git || die "git is required (git hash-object / git apply)." 1
[[ -n "$SUBJECT" ]] || die "Missing --subject DIR." 1
[[ -d "$SUBJECT" ]] || die "Subject directory not found: $SUBJECT" 1
[[ -n "$FILTER" ]]  || die "Missing --filter EXPR: name the test under control." 1
case "$TYPE" in unit|kernel|functional|js|all) : ;; *) die "Invalid --type '$TYPE' (use unit|kernel|functional|js|all)." 1;; esac
if [[ -n "$REF" && -n "$PATCH_FILE" ]]; then die "Give either --revert-to REF --path FILE... or --mutation-patch FILE, not both." 1; fi
if [[ -z "$REF" && -z "$PATCH_FILE" ]]; then die "Missing the change to undo: --revert-to REF --path FILE... or --mutation-patch FILE." 1; fi
if [[ -n "$REF" && ${#PATHS[@]} -eq 0 ]]; then die "--revert-to needs at least one --path FILE (the production file(s) the change touched)." 1; fi
if [[ -n "$PATCH_FILE" && ${#PATHS[@]} -gt 0 ]]; then die "--path is only for --revert-to; a mutation patch names its own files." 1; fi
if [[ -n "$PATCH_FILE" ]]; then
  [[ -r "$PATCH_FILE" ]] || die "Mutation patch not readable: $PATCH_FILE" 1
  PATCH_FILE="$(cd "$(dirname "$PATCH_FILE")" && pwd)/$(basename "$PATCH_FILE")"
fi

# The physical subject path: git and the hashes see the real files even for a
# symlink placement.
SUBJECT="$(cd -P "$SUBJECT" 2>/dev/null && pwd)" || die "Cannot resolve subject path." 1
STATE_DIR="$(project_state_dir "$SUBJECT")"
RUNNER_SH="$(plugin_root)/scripts/tests/run-phpunit.sh"
[[ -r "$RUNNER_SH" ]] || die "run-phpunit.sh not found at $RUNNER_SH" 1

# ---------------------------------------------------------------------------
# Target paths (relative to the subject) and their validation.
# ---------------------------------------------------------------------------
if [[ -n "$PATCH_FILE" ]]; then
  # The files a patch touches: its ---/+++ headers, minus /dev/null and the
  # a/ b/ prefixes. awk keeps it portable (no grep -P).
  while IFS= read -r p; do
    [[ -n "$p" ]] && PATHS+=("$p")
  done < <(awk '/^(---|\+\+\+) / { p = $2; sub(/\t.*$/, "", p); if (p == "/dev/null") next;
                 sub(/^[ab]\//, "", p); if (!(p in seen)) { seen[p] = 1; print p } }' "$PATCH_FILE")
  [[ ${#PATHS[@]} -gt 0 ]] || die "The mutation patch names no file: $PATCH_FILE" 1
fi

IN_GIT=0
git -C "$SUBJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && IN_GIT=1

declare -a REL=()
for p in "${PATHS[@]}"; do
  p="${p#./}"
  case "$p" in
    ""|/*) die "Path must be relative to the subject: '$p'" 1;;
  esac
  case "/$p/" in
    */../*) die "Path escapes the subject: '$p'" 1;;
    */tests/*) die "Refusing to mutate '$p': it is test code. A negative control mutates the PRODUCTION code the test guards, never the test." 1;;
  esac
  if [[ "$IN_GIT" == "1" && -n "$(git -C "$SUBJECT" ls-files -u -- "$p" 2>/dev/null)" ]]; then
    die "Refusing to mutate '$p': it is in a git conflict state. Resolve it first." 1
  fi
  REL+=("$p")
done

if [[ -n "$REF" ]]; then
  [[ "$IN_GIT" == "1" ]] || die "--revert-to needs the subject to be a git checkout ($SUBJECT is not)." 1
  git -C "$SUBJECT" rev-parse --verify --quiet "${REF}^{commit}" >/dev/null || die "Unknown git ref: $REF" 1
fi

# hash_of <rel> -> the git blob hash of the file, or "absent".
hash_of() {
  if [[ -f "$SUBJECT/$1" ]]; then git hash-object -- "$SUBJECT/$1"; else printf 'absent'; fi
  return 0
}
# ref_has <rel> -> 0 when REF has the path (run in the subject dir: ./ is relative).
ref_has() { ( cd "$SUBJECT" && git cat-file -e "$REF:./$1" ) 2>/dev/null; }
# ref_hash <rel> -> blob hash of the path at REF, or "absent".
ref_hash() {
  if ref_has "$1"; then ( cd "$SUBJECT" && git rev-parse "$REF:./$1" ); else printf 'absent'; fi
  return 0
}

# The planned mutation must change something; otherwise the "fix" is not there.
declare -a ORIG_HASH=()
CHANGES=0
for i in "${!REL[@]}"; do
  ORIG_HASH[i]="$(hash_of "${REL[i]}")"
  if [[ -n "$REF" ]]; then
    [[ "$(ref_hash "${REL[i]}")" != "${ORIG_HASH[i]}" ]] && CHANGES=$((CHANGES + 1))
  fi
done
if [[ -n "$REF" && "$CHANGES" -eq 0 ]]; then
  die "Nothing to undo: every --path is identical at $REF. Name the ref BEFORE the change the test guards." 1
fi
if [[ -n "$PATCH_FILE" ]]; then
  ( cd "$SUBJECT" && git apply --check "$PATCH_FILE" ) >/dev/null 2>&1 \
    || die "The mutation patch does not apply to the current code: $PATCH_FILE (paths must be relative to the subject)." 1
fi

MUT_KIND="revert-to"; [[ -n "$PATCH_FILE" ]] && MUT_KIND="patch"
MUTATION_JSON="$(jq -n -c --arg kind "$MUT_KIND" --arg ref "$REF" --arg patch "$PATCH_FILE" \
  --argjson paths "$(arr_to_json "${REL[@]}")" \
  '{kind:$kind, paths:$paths} + (if $kind == "patch" then {patch:$patch} else {ref:$ref} end)')"

log_step "Negative control: $FILTER (--type $TYPE)${LABEL:+ — $LABEL}"
log_info "Undoing the guarded change ($MUT_KIND${REF:+ $REF}${PATCH_FILE:+ $PATCH_FILE}) in: ${REL[*]}"

if [[ "$DRY_RUN" == "1" ]]; then
  if [[ -n "$REF" ]]; then
    for p in "${REL[@]}"; do
      ( cd "$SUBJECT" && git --no-pager diff --stat "$REF" -- "$p" ) >&2 2>/dev/null || true
    done
  else
    ( cd "$SUBJECT" && git apply --stat "$PATCH_FILE" ) >&2 || true
  fi
  log_info "Dry run: no file touched, no test run. A real run does: red run, byte-identical restore, green run."
  if [[ "$JSON" == "1" ]]; then
    jq -n --arg test "$FILTER" --arg type "$TYPE" --arg label "$LABEL" --argjson mutation "$MUTATION_JSON" \
      '{dry_run:true, test:$test, type:$type, label:($label | select(. != "") // null), mutation:$mutation}'
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Backup + trap FIRST, then mutate.
# ---------------------------------------------------------------------------
mkdir -p "$STATE_DIR/negative-controls/logs"
BACKUP_DIR="$(mktemp -d "$STATE_DIR/negative-controls/backup.XXXXXX")"
for i in "${!REL[@]}"; do
  if [[ -f "$SUBJECT/${REL[i]}" ]]; then cp -p "$SUBJECT/${REL[i]}" "$BACKUP_DIR/$i"; fi
done

declare -a MUT_HASH=()
MUTATED=0
RESTORED=0
RESTORE_OK=1
RESTORE_NOTE=""

# restore -> put every target back from the backup, unless it changed since we
# mutated it (a concurrent edit: keep the backup, never overwrite). Idempotent.
restore() {
  [[ "$MUTATED" == "1" && "$RESTORED" == "0" ]] || return 0
  RESTORED=1
  local i cur
  for i in "${!REL[@]}"; do
    cur="$(hash_of "${REL[i]}")"
    if [[ -n "${MUT_HASH[i]:-}" && "$cur" != "${MUT_HASH[i]}" ]]; then
      RESTORE_OK=0
      RESTORE_NOTE="${REL[i]} changed during the control (not by drupilot): left as is; the original is in $BACKUP_DIR/$i"
      log_err "$RESTORE_NOTE"
      continue
    fi
    if [[ "${ORIG_HASH[i]}" == "absent" ]]; then
      rm -f "$SUBJECT/${REL[i]}"
    else
      mkdir -p "$(dirname "$SUBJECT/${REL[i]}")"
      cp -p "$BACKUP_DIR/$i" "$SUBJECT/${REL[i]}"
    fi
  done
  return 0
}

on_exit() {
  local rc=$?
  restore
  if [[ "$RESTORE_OK" == "1" ]]; then rm -rf "$BACKUP_DIR" 2>/dev/null || true
  else log_err "Backup kept for manual recovery: $BACKUP_DIR"; fi
  return "$rc"
}
trap on_exit EXIT
trap 'log_err "Interrupted: restoring the original code."; exit 130' INT
trap 'log_err "Terminated: restoring the original code."; exit 143' TERM

MUTATED=1
if [[ -n "$REF" ]]; then
  for i in "${!REL[@]}"; do
    if ref_has "${REL[i]}"; then
      mkdir -p "$(dirname "$SUBJECT/${REL[i]}")"
      ( cd "$SUBJECT" && git show "$REF:./${REL[i]}" ) > "$BACKUP_DIR/ref.$i" \
        || die "Could not read ${REL[i]} at $REF." 1
      cat "$BACKUP_DIR/ref.$i" > "$SUBJECT/${REL[i]}"
    else
      rm -f "$SUBJECT/${REL[i]}"
    fi
  done
else
  ( cd "$SUBJECT" && git apply "$PATCH_FILE" ) || die "Could not apply the mutation patch (nothing was left changed)." 1
fi
for i in "${!REL[@]}"; do MUT_HASH[i]="$(hash_of "${REL[i]}")"; done

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SLUG="$(printf '%s' "$FILTER" | tr -c 'A-Za-z0-9' '_' | cut -c1-60)"
LOG_RED="$STATE_DIR/negative-controls/logs/$STAMP-$SLUG-red.log"
LOG_GREEN="$STATE_DIR/negative-controls/logs/$STAMP-$SLUG-green.log"
RES_RED="$(mktemp "${TMPDIR:-/tmp}/drupilot-nc-red.XXXXXX")"
RES_GREEN="$(mktemp "${TMPDIR:-/tmp}/drupilot-nc-green.XXXXXX")"

# run_tests <log> <result-file> -> run-phpunit.sh's exit code on stdout.
run_tests() {
  local rc
  set +e
  bash "$RUNNER_SH" --subject "$SUBJECT" --type "$TYPE" --filter "$FILTER" \
    --no-record --no-baseline --result-file "$2" > "$1" 2>&1
  rc=$?
  set -e
  printf '%s' "$rc"
  return 0
}

log_info "Red run (the change undone) — log: $LOG_RED"
MUT_RC="$(run_tests "$LOG_RED" "$RES_RED")"

restore
RESTORED_IDENTICAL="true"
for i in "${!REL[@]}"; do
  [[ "$(hash_of "${REL[i]}")" == "${ORIG_HASH[i]}" ]] || RESTORED_IDENTICAL="false"
done
[[ "$RESTORE_OK" == "1" ]] || RESTORED_IDENTICAL="false"
if [[ "$RESTORED_IDENTICAL" == "true" ]]; then
  log_ok "Restored: every target file is byte-identical to the original (git hash-object)."
else
  log_err "The restore is NOT byte-identical — see above."
fi

GREEN_RC="skipped"
if [[ "$RESTORED_IDENTICAL" == "true" ]]; then
  log_info "Green run (the code restored) — log: $LOG_GREEN"
  GREEN_RC="$(run_tests "$LOG_GREEN" "$RES_GREEN")"
fi

res_get() { jq -r "$2 // empty" "$1" 2>/dev/null || true; return 0; }
MUT_EXEC="$(res_get "$RES_RED" '.executed')"
GREEN_EXEC="$(res_get "$RES_GREEN" '.executed')"
RED_TESTS="$(jq -c '[.tests[]? | select(.status == "fail" or .status == "error") | .id]' "$RES_RED" 2>/dev/null || echo '[]')"
[[ -n "$RED_TESTS" ]] || RED_TESTS='[]'
rm -f "$RES_RED" "$RES_GREEN"

VERDICT="error"; REASON=""; EXIT=1
if [[ "$MUT_RC" == "2" || "$GREEN_RC" == "2" ]]; then
  REASON="the test environment is not available (run-phpunit.sh exit 2) — see the logs"; EXIT=2
elif [[ "$RESTORED_IDENTICAL" != "true" ]]; then
  REASON="the restore was not byte-identical${RESTORE_NOTE:+: $RESTORE_NOTE}"
elif [[ "$MUT_RC" == "0" && "${MUT_EXEC:-0}" == "0" ]]; then
  REASON="--filter '$FILTER' executed no test (--type $TYPE): nothing was controlled"
elif [[ "$MUT_RC" == "0" ]]; then
  if [[ "$GREEN_RC" == "0" ]]; then
    VERDICT="ineffective"; EXIT=4
    REASON="the test stayed green with the change undone: it does not guard that change — strengthen the test"
  else
    REASON="the test passed with the change undone but failed once restored (exit $GREEN_RC): flaky or order-dependent"
  fi
elif [[ "$MUT_RC" == "3" ]]; then
  if [[ "$GREEN_RC" == "0" && "${GREEN_EXEC:-0}" != "0" ]]; then
    VERDICT="effective"; EXIT=0
    REASON="red with the change undone, green once restored"
  elif [[ "$GREEN_RC" == "0" ]]; then
    REASON="the restored run executed no test: inconclusive"
  else
    REASON="the test is not green on the restored code (exit $GREEN_RC): fix that first; the control is inconclusive"
  fi
else
  REASON="unexpected run-phpunit.sh exit $MUT_RC on the red run — see $LOG_RED"
fi

RECORD="$(jq -n -c \
  --arg test "$FILTER" --arg type "$TYPE" --arg label "$LABEL" --argjson mutation "$MUTATION_JSON" \
  --arg mrc "$MUT_RC" --arg grc "$GREEN_RC" --arg mexec "${MUT_EXEC:-}" --arg gexec "${GREEN_EXEC:-}" \
  --argjson red_tests "$RED_TESTS" --argjson identical "$RESTORED_IDENTICAL" \
  --arg verdict "$VERDICT" --arg reason "$REASON" --arg lr "$LOG_RED" --arg lg "$LOG_GREEN" \
  --arg digest "$(subject_digest "$SUBJECT")" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{test:$test, type:$type, label:($label | select(. != "") // null), mutation:$mutation,
    mutated_rc:($mrc | tonumber? // null), restored_rc:($grc | tonumber? // null),
    mutated_executed:($mexec | tonumber? // null), restored_executed:($gexec | tonumber? // null),
    red_tests:$red_tests, restored_identical:$identical,
    verdict:$verdict, reason:$reason, logs:{red:$lr, green:$lg},
    subject_digest:($digest | select(. != "") // null), at:$at}')"

# Store: one entry per test+type+label, the latest wins.
NC_FILE="$(negative_controls_file "$SUBJECT")"
PREV='[]'
[[ -r "$NC_FILE" ]] && PREV="$(jq -c 'if type == "array" then . else [] end' "$NC_FILE" 2>/dev/null || echo '[]')"
printf '%s' "$PREV" | jq --argjson r "$RECORD" \
  '[ .[] | select(.test != $r.test or .type != $r.type or .label != $r.label) ] + [$r]' \
  > "$NC_FILE.tmp" && mv "$NC_FILE.tmp" "$NC_FILE"

# Keep last-test.json's summary in step (the record a test run wrote stays its own).
if [[ -r "$STATE_DIR/last-test.json" ]]; then
  jq --argjson nc "$(negative_controls_summary "$SUBJECT")" '.negative_controls = $nc' \
    "$STATE_DIR/last-test.json" > "$STATE_DIR/last-test.json.tmp" 2>/dev/null \
    && mv "$STATE_DIR/last-test.json.tmp" "$STATE_DIR/last-test.json" || rm -f "$STATE_DIR/last-test.json.tmp"
fi

if [[ -n "$MANIFEST" ]]; then
  if [[ -r "$MANIFEST" ]] && jq empty "$MANIFEST" 2>/dev/null; then
    jq --argjson r "$RECORD" '.verification.negative_controls = ([ (.verification.negative_controls // [])[]
        | select(.test != $r.test or .type != $r.type or .label != $r.label) ] + [$r])' \
      "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
  else
    log_warn "--manifest $MANIFEST is missing or not JSON: the record was not added to it."
  fi
fi

hr
case "$VERDICT" in
  effective)   log_ok "effective — $REASON (red: $(printf '%s' "$RED_TESTS" | jq -r 'length') failing test(s))." ;;
  ineffective) log_err "ineffective — $REASON." ;;
  *)           log_err "error — $REASON." ;;
esac
log_info "Recorded in $NC_FILE"
[[ "$JSON" == "1" ]] && printf '%s\n' "$RECORD" | jq .
exit "$EXIT"
