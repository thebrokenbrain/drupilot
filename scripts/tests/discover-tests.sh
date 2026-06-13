#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/tests/discover-tests.sh
# Discover and classify a Drupal extension's PHPUnit test classes.
#
# Scans the subject's tests/src/{Unit,Kernel,Functional,FunctionalJavascript}
# directories and counts the test classes in each group. This is the inventory
# step used by /drupilot-test and the drupal-test-engineer agent before running
# the suite — it does NOT execute anything, so it needs no environment and no
# preflight gate.
#
# Usage:
#   discover-tests.sh --subject DIR [--json]
#
# Output:
#   default  -> a human-readable English summary on STDOUT.
#   --json   -> a single JSON object on STDOUT (nothing else):
#               { unit, kernel, functional, javascript, total,
#                 files:[ {path, type, class} ] }
#   Diagnostics/logging always go to STDERR.
#
# Exit codes:
#   0  -> discovery completed (zero tests is still success).
#   1  -> usage/internal error (e.g. subject is not a Drupal extension).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

SUBJECT=""
AS_JSON=0

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

[[ -n "$SUBJECT" ]] || die "Missing --subject DIR (path to the module/theme to inspect)." 1
[[ -d "$SUBJECT" ]] || die "Subject directory not found: $SUBJECT" 1

# Absolute path for stable, comparable output.
SUBJECT="$(cd "$SUBJECT" 2>/dev/null && pwd)" || die "Cannot resolve subject path: $SUBJECT" 1

is_drupal_extension_dir "$SUBJECT" \
  || log_warn "No *.info.yml in $SUBJECT — inspecting tests/ anyway."

TESTS_DIR="$SUBJECT/tests/src"

# ---------------------------------------------------------------------------
# Map the four Drupal test-suite directories to the JSON group keys.
# Directory name (under tests/src) -> group key.
# ---------------------------------------------------------------------------
group_key_for_dir() {
  case "$1" in
    Unit) echo "unit";;
    Kernel) echo "kernel";;
    Functional) echo "functional";;
    FunctionalJavascript) echo "javascript";;
    *) echo "";;
  esac
}

UNIT=0
KERNEL=0
FUNCTIONAL=0
JAVASCRIPT=0
FILES_JSON="[]"

# extract_class_name <file> -> the declared PHP class, or the basename fallback.
extract_class_name() {
  local f="$1" cls=""
  cls="$(grep -aoE '^[[:space:]]*(final[[:space:]]+|abstract[[:space:]]+)*class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$f" 2>/dev/null \
        | head -n1 | sed -E 's/.*class[[:space:]]+//')"
  [[ -z "$cls" ]] && cls="$(basename "$f" .php)"
  printf '%s' "$cls"
}

if [[ -d "$TESTS_DIR" ]]; then
  # Walk only the four canonical directories so we classify deterministically.
  # FunctionalJavascript is checked before Functional below only conceptually;
  # because we match each top-level directory explicitly there is no overlap.
  for dirname in Unit Kernel Functional FunctionalJavascript; do
    base="$TESTS_DIR/$dirname"
    [[ -d "$base" ]] || continue
    key="$(group_key_for_dir "$dirname")"

    while IFS= read -r -d '' f; do
      # Skip abstract base classes and traits with no concrete *Test class:
      # the canonical convention is that runnable test classes end in "Test".
      [[ "$(basename "$f")" == *Test.php ]] || continue

      cls="$(extract_class_name "$f")"
      rel="${f#"$SUBJECT"/}"

      case "$key" in
        unit) UNIT=$((UNIT + 1));;
        kernel) KERNEL=$((KERNEL + 1));;
        functional) FUNCTIONAL=$((FUNCTIONAL + 1));;
        javascript) JAVASCRIPT=$((JAVASCRIPT + 1));;
      esac

      FILES_JSON="$(jq -c \
        --arg path "$rel" --arg type "$key" --arg class "$cls" \
        '. + [{path:$path, type:$type, class:$class}]' <<<"$FILES_JSON")"
    done < <(find "$base" -type f -name '*.php' -print0 2>/dev/null)
  done
else
  log_info "No tests/src directory under $SUBJECT — the subject has no PHPUnit tests."
fi

TOTAL=$((UNIT + KERNEL + FUNCTIONAL + JAVASCRIPT))

RESULT="$(jq -n \
  --argjson unit "$UNIT" --argjson kernel "$KERNEL" \
  --argjson functional "$FUNCTIONAL" --argjson javascript "$JAVASCRIPT" \
  --argjson total "$TOTAL" --argjson files "$FILES_JSON" \
  '{unit:$unit, kernel:$kernel, functional:$functional, javascript:$javascript,
    total:$total, files:$files}')"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ "$AS_JSON" == "1" ]]; then
  printf '%s\n' "$RESULT"
else
  mn="$(subject_machine_name "$SUBJECT" 2>/dev/null || basename "$SUBJECT")"
  printf '\n%sdrupilot — test discovery%s   (%s)\n' "$_C_BOLD" "$_C_RESET" "$mn"
  hr
  printf '  Unit ................. %s\n' "$UNIT"
  printf '  Kernel ............... %s\n' "$KERNEL"
  printf '  Functional ........... %s\n' "$FUNCTIONAL"
  printf '  FunctionalJavascript . %s\n' "$JAVASCRIPT"
  hr
  printf '  %sTotal test classes ... %s%s\n' "$_C_BOLD" "$TOTAL" "$_C_RESET"
  if [[ "$TOTAL" -eq 0 ]]; then
    printf '\n%sNo PHPUnit tests found.%s In Phase 2 (refactor), add coverage to maximise it.\n' \
      "$_C_YELLOW" "$_C_RESET"
  fi
  printf '\n'
fi
