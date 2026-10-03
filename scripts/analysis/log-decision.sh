#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/log-decision.sh
# The DECISION LOG: record, the moment it happens, every place a port diverges
# from what a tool produced or the flow prescribes — a Rector change reverted
# by hand, a script's verdict overridden, a step skipped, a fix made after
# validation, a behavior change a reviewer must look at — with WHAT and WHY.
# A divergence that is not logged is a defect: the report would show the
# tool's output as if it had been kept.
#
# Each call appends one JSON line to <artifacts_dir>/decisions.jsonl (the
# visible, self-gitignored .drupilot/ at the Drupal root: one log per root,
# every entry names its subject) and regenerates decisions.md beside it (a
# table per module, oldest first). port-report.sh and layer-report.sh merge
# the entries into the port record (common.sh port_record_json), so they
# aggregate across modules and layers with the manifest's structured fields.
#
# Usage:
#   log-decision.sh --subject DIR --kind KIND --what TEXT --why TEXT
#                   [--rule RULE] [--file PATH] [--script NAME]
#                   [--detected-by X] [--review-hint TEXT]
#                   [--phase port|refactor] [--json] [--dry-run]
#   log-decision.sh --subject DIR --list [--json]
#   log-decision.sh --subject DIR --render
#
# Options:
#   --subject DIR    The module/theme the decision is about (default: $PWD).
#   --kind KIND      rector-revert     a Rector change undone or rewritten by
#                                      hand (--rule required)
#                    post-port-fix     a fix made after the validate loop,
#                                      the tests or the core matrix found a
#                                      problem the port introduced
#                    script-divergence a script's output/verdict not followed
#                                      (--script names it)
#                    skip              a step the flow prescribes not run
#                    manual-override   a recommended default overridden
#                    tooling-deviation the toolchain or flow used differently
#                    test-adaptation   a test's FORM changed (never what it
#                                      verifies)
#                    behavior-change   a behavior difference a PR reviewer
#                                      must check (--review-hint says how)
#                    preexisting-bug   a bug found but NOT fixed by the port
#   --what TEXT      What was done (required).
#   --why TEXT       Why (required; a decision without a reason is not logged).
#   --rule RULE      The Rector rule (short name or FQCN).
#   --file PATH      The file concerned (stored relative to the subject when
#                    it is inside it).
#   --script NAME    The script whose output was not followed.
#   --detected-by X  What found the problem (phpstan, phpunit, core-matrix,
#                    port-safety, review, ...).
#   --review-hint T  How a reviewer checks a behavior change.
#   --phase P        port | refactor (default: refactor once the subject's
#                    stage reached refactored, else port).
#   --list           Print the subject's entries (JSON array with --json,
#                    else a table on STDERR). Read-only.
#   --render         Regenerate decisions.md from the log. Prints its path.
#   --json           Print the appended entry (or the --list array) on STDOUT.
#   --dry-run        Print the entry that would be appended; write nothing.
#   -h, --help       Show this help.
#
# Output: STDOUT is the entry JSON (--json / --dry-run) or the path of
# decisions.md; logs go to STDERR.
# Exit codes: 0 ok · 1 usage error / jq missing / write error.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""; KIND=""; WHAT=""; WHY=""; RULE=""; FILE=""; SCRIPT=""
DETECTED=""; HINT=""; PHASE=""; AS_JSON=0; DRY=0; MODE="log"
KINDS="rector-revert post-port-fix script-divergence skip manual-override tooling-deviation test-adaptation behavior-change preexisting-bug"

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --kind) KIND="${2:-}"; shift 2 || die "--kind needs a value" 1;;
    --kind=*) KIND="${1#*=}"; shift;;
    --what) WHAT="${2:-}"; shift 2 || die "--what needs a value" 1;;
    --what=*) WHAT="${1#*=}"; shift;;
    --why) WHY="${2:-}"; shift 2 || die "--why needs a value" 1;;
    --why=*) WHY="${1#*=}"; shift;;
    --rule) RULE="${2:-}"; shift 2 || die "--rule needs a value" 1;;
    --rule=*) RULE="${1#*=}"; shift;;
    --file) FILE="${2:-}"; shift 2 || die "--file needs a value" 1;;
    --file=*) FILE="${1#*=}"; shift;;
    --script) SCRIPT="${2:-}"; shift 2 || die "--script needs a value" 1;;
    --script=*) SCRIPT="${1#*=}"; shift;;
    --detected-by) DETECTED="${2:-}"; shift 2 || die "--detected-by needs a value" 1;;
    --detected-by=*) DETECTED="${1#*=}"; shift;;
    --review-hint) HINT="${2:-}"; shift 2 || die "--review-hint needs a value" 1;;
    --review-hint=*) HINT="${1#*=}"; shift;;
    --phase) PHASE="${2:-}"; shift 2 || die "--phase needs a value" 1;;
    --phase=*) PHASE="${1#*=}"; shift;;
    --list) MODE="list"; shift;;
    --render) MODE="render"; shift;;
    --json) AS_JSON=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_err "Unknown argument: $1"; usage >&2; exit 1;;
  esac
done

have_cmd jq || die "jq is required for log-decision.sh." 1
[[ -n "$SUBJECT" ]] || SUBJECT="$PWD"
[[ -d "$SUBJECT" ]] || die "Subject directory not found: $SUBJECT" 1
SUBJECT="$(cd "$SUBJECT" && pwd)"
MN="$(subject_machine_name "$SUBJECT" 2>/dev/null || basename "$SUBJECT")"
LOG="$(decisions_log_file "$SUBJECT")"
MD="$(dirname "$LOG")/decisions.md"

# render_md -> regenerate decisions.md from the whole log (every module of the
# root), through a temp file + mv so a reader never sees half a file.
render_md() {
  local tmp
  mkdir -p "$(dirname "$MD")" || return 1
  tmp="$(mktemp "$MD.XXXXXX")" || return 1
  # mktemp creates 0600; a report is for the team and CI artifacts too.
  chmod 0644 "$tmp" 2>/dev/null || true
  if jq -R -s -r '
      def cell: if . == null or . == "" then "—" else tostring | gsub("\\|"; "\\|") | gsub("\r?\n"; "<br>") end;
      [ split("\n")[] | select(length > 0) | (fromjson? // empty) | select(type == "object") ] as $all
      | "# Decision log\n",
        "_Every place a port diverged from a tool'"'"'s output or the prescribed flow, and why. Written by `log-decision.sh` as it happened; `decisions.jsonl` beside this file is the machine twin read by `port-report.sh` and `layer-report.sh`._\n",
        ( $all | group_by(.subject)[] | sort_by(.ts)
          | "## `\(.[0].machine_name // "?")`\n",
            "`\(.[0].subject)` — \(length) decision(s)\n",
            "| # | When (UTC) | Phase | Kind | What | Why | Rule / file / source |",
            "|---|---|---|---|---|---|---|",
            ( to_entries[] | .key as $i | .value
              | "| \($i + 1) | \(.ts | cell) | \(.phase | cell) | \(.kind | cell) | \(.what | cell) | \(.why | cell)"
                + (if (.review_hint // "") != "" then "<br>_Review:_ \(.review_hint | cell)" else "" end)
                + " | \([ (if (.rule // "") != "" then "`\(.rule | cell)`" else empty end),
                          (if (.file // "") != "" then "`\(.file | cell)`" else empty end),
                          (if (.script // "") != "" then "script `\(.script | cell)`" else empty end),
                          (if (.detected_by // "") != "" then "found by \(.detected_by | cell)" else empty end) ]
                        | if length == 0 then "—" else join("<br>") end) |" ),
            "" )' "$LOG" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$MD"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

if [[ "$MODE" == "list" ]]; then
  ENTRIES="$(decisions_for_subject "$SUBJECT")"
  printf '%s' "$ENTRIES" | jq -r --arg mn "$MN" '
    "\(length) decision(s) logged for \($mn)",
    (.[] | "- [\(.ts)] \(.kind): \(.what) — why: \(.why)")' >&2
  [[ "$AS_JSON" == "1" ]] && printf '%s\n' "$ENTRIES"
  exit 0
fi

if [[ "$MODE" == "render" ]]; then
  [[ -r "$LOG" ]] || die "No decision log yet at $LOG." 1
  render_md || die "Could not write $MD." 1
  log_ok "Decision log rendered: $MD"
  printf '%s\n' "$MD"
  exit 0
fi

# --- Validate the entry ------------------------------------------------------
[[ -n "$KIND" ]] || die "Missing --kind (one of: $KINDS)." 1
case " $KINDS " in *" $KIND "*) ;; *) die "Unknown --kind '$KIND' (one of: $KINDS)." 1;; esac
[[ -n "$(trim "$WHAT")" ]] || die "Missing --what: say what was done." 1
[[ -n "$(trim "$WHY")" ]] || die "Missing --why: a decision is logged with its reason." 1
[[ "$KIND" != "rector-revert" || -n "$RULE" ]] || die "--kind rector-revert needs --rule (the Rector rule whose change was undone)." 1
if [[ -z "$PHASE" ]]; then
  PHASE="port"
  phase_reached "$SUBJECT" refactored 2>/dev/null && PHASE="refactor"
fi
case "$PHASE" in port|refactor) ;; *) die "--phase must be port or refactor: '$PHASE'" 1;; esac
# A file inside the subject is stored relative to it (stable across a move).
if [[ -n "$FILE" ]]; then
  case "$FILE" in
    "$SUBJECT"/*) FILE="${FILE#"$SUBJECT"/}";;
  esac
fi
ROOT="$(find_drupal_root "$SUBJECT" 2>/dev/null || true)"

ENTRY="$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg s "$SUBJECT" --arg mn "$MN" --arg root "$ROOT" \
  --arg phase "$PHASE" --arg kind "$KIND" --arg what "$WHAT" --arg why "$WHY" --arg rule "$RULE" \
  --arg file "$FILE" --arg script "$SCRIPT" --arg det "$DETECTED" --arg hint "$HINT" '
  def nz: if . == "" then null else . end;
  {schema: 1, ts: $ts, subject: $s, machine_name: ($mn | nz), drupal_root: ($root | nz),
   phase: $phase, kind: $kind, what: $what, why: $why, rule: ($rule | nz), file: ($file | nz),
   script: ($script | nz), detected_by: ($det | nz), review_hint: ($hint | nz)}')"

if [[ "$DRY" == "1" ]]; then
  log_info "Dry run: would append to $LOG (and regenerate $MD)."
  printf '%s\n' "$ENTRY"
  exit 0
fi

# project_artifacts_dir creates the dir with its self-ignoring .gitignore.
ADIR="$(project_artifacts_dir "$SUBJECT")"
[[ "$ADIR/decisions.jsonl" == "$LOG" ]] || LOG="$ADIR/decisions.jsonl"
MD="$ADIR/decisions.md"
# One printf of one line: an append the reader never sees half-written.
printf '%s\n' "$ENTRY" >> "$LOG" || die "Could not append to $LOG." 1
render_md || log_warn "Logged in $LOG, but could not regenerate $MD (run --render)."
log_ok "Decision logged ($KIND) for $MN: $LOG"

if [[ "$AS_JSON" == "1" ]]; then
  printf '%s\n' "$ENTRY"
else
  printf '%s\n' "$MD"
fi
exit 0
