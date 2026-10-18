#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/dev/e2e.sh
# The end-to-end port of legacy_widgets (T-M4-14, R-LAB-8; a developer/CI tool:
# no command, skill or hook calls it, and it needs DDEV and Docker). It builds
# a Drupal test-bed with ddev-up.sh, installs the toolchain, places a fresh git
# copy of tests/fixtures/legacy_widgets in it and runs the scripted sequence of
# tests/fixtures/legacy_widgets.golden/README.md ("Exact commands": scripts
# only, no model, so the AI lane stays empty), then byte-compares the
# make-patch.sh --local patch with
# tests/fixtures/legacy_widgets.golden/golden/port-to-drupal-11.patch.
#
# The environment is the golden's: DRUPILOT_DETERMINISTIC=true, digests off,
# PHP target 8.3, Drupal core 11.4.8, every other DRUPILOT_* variable unset,
# a private DRUPILOT_HOME under the work dir. .github/workflows/e2e.yml runs
# it on GitHub Actions after ddev/github-action-setup-ddev.
#
# Usage:
#   scripts/dev/e2e.sh [--work DIR] [--name NAME] [--keep] [-h|--help]
#     --work DIR   where the test-bed and the state go (default:
#                  $RUNNER_TEMP or $TMPDIR, plus drupilot-e2e); it must not
#                  exist yet or be empty
#     --name NAME  the DDEV project name (default dpl-e2e-legwid-d11)
#     --keep       leave the DDEV project running and the work dir in place
#                  (default: `ddev delete -Oy` the project at the end)
#
# Exit codes: 0 the patch equals the golden · 1 usage error, a missing tool,
# or a work dir that is not empty · 2 a step of the sequence failed (its log
# is in the work dir) · 3 the patch differs from the golden (its diff on
# STDERR).
# =============================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
. "$REPO/scripts/lib/common.sh"

WORK=""; NAME="dpl-e2e-legwid-d11"; KEEP=0
usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work) WORK="${2:-}"; shift 2 || die "--work needs a value" 1;;
    --name) NAME="${2:-}"; shift 2 || die "--name needs a value" 1;;
    --keep) KEEP=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done
# xmllint as on the golden's host: render-templates.sh validates phpcs.xml.dist
# with it.
for c in ddev docker git jq xmllint; do have_cmd "$c" || die "e2e needs $c." 1; done
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--name is a DDEV project name (got '$NAME')." 1
[[ -n "$WORK" ]] || WORK="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/drupilot-e2e"
if [[ -e "$WORK" && -n "$(ls -A "$WORK" 2> /dev/null)" ]]; then die "The work dir $WORK is not empty." 1; fi
mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"
GOLDEN="$REPO/tests/fixtures/legacy_widgets.golden/golden/port-to-drupal-11.patch"
[[ -f "$GOLDEN" ]] || die "No golden patch at $GOLDEN." 1

# The golden's environment: every other DRUPILOT_* variable unset.
for v in $(env | sed -n 's/^\(DRUPILOT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
unset CLAUDE_PLUGIN_DATA
export CLAUDE_PLUGIN_ROOT="$REPO" DRUPILOT_HOME="$WORK/home"
export DRUPILOT_DETERMINISTIC=true DRUPILOT_USE_DIGESTS_RULES=false
export DRUPILOT_PHP_TARGET=8.3 DRUPILOT_DRUPAL_TARGET=11.4.8 DRUPILOT_NONINTERACTIVE=1
BED="$WORK/$NAME"; S="web/modules/custom/legacy_widgets"; LOG="$WORK/e2e.log"
: > "$LOG"
cleanup() {
  [[ "$KEEP" == "1" ]] && return 0
  [[ -d "$BED/.ddev" ]] && (cd "$BED" && ddev delete -Oy < /dev/null >> "$LOG" 2>&1) || true
  return 0
}
trap cleanup EXIT
# step LABEL CMD... -> runs CMD (its output appended to the log); a failure
# stops the run with exit 2. ok_codes lists the exit codes that pass.
step() {
  local label="$1" ok="$2" rc=0; shift 2
  log_step "e2e: $label"
  printf '\n=== %s: %s\n' "$label" "$*" >> "$LOG"
  "$@" < /dev/null >> "$LOG" 2>&1 || rc=$?
  case " $ok " in *" $rc "*) return 0;; esac
  log_err "e2e: $label exited $rc (see $LOG)."
  exit 2
}

step "test-bed" 0 bash "$REPO/scripts/env/ddev-up.sh" --name "$NAME" --dir "$BED" --json
step "toolchain" 0 bash "$REPO/scripts/env/install-toolchain.sh" --dir "$BED" --no-core-dev --json
step "fixture" 0 mkdir -p "$BED/web/modules/custom"
step "fixture copy" 0 cp -a "$REPO/tests/fixtures/legacy_widgets" "$BED/$S"
step "fixture repository" 0 sh -c 'cd "$1" && git init -q && git add -A \
  && git -c user.name=lab -c user.email=lab@example.invalid -c commit.gpgsign=false commit -qm "Initial legacy_widgets fixture (Drupal 10.3)"' sh "$BED/$S"
cd "$BED"
step "rector dry-run" 0 bash "$REPO/scripts/analysis/run-rector.sh" --subject "$S" --json
step "phpstan" "0 1" bash "$REPO/scripts/analysis/run-phpstan.sh" --subject "$S" --json
step "phpcs" "0 1" bash "$REPO/scripts/analysis/run-phpcs.sh" --subject "$S" --json
step "render-templates" 0 bash "$REPO/scripts/env/render-templates.sh" --subject "$S" --force
# A failed substitution is a failed step too (exit 2), never set -e's own code.
REQ="$(bash "$REPO/scripts/analysis/core-strategy.sh" --subject "$S" --json < /dev/null 2>> "$LOG" | jq -r '.recommended_core_version_requirement // empty')" \
  || { log_err "e2e: core-strategy.sh failed (see $LOG)."; exit 2; }
[[ -n "$REQ" ]] || { log_err "e2e: core-strategy.sh gave no recommended range (see $LOG)."; exit 2; }
log_info "e2e: core range $REQ"
step "rector apply" 0 bash "$REPO/scripts/analysis/run-rector.sh" --subject "$S" --apply
step "core requirement" 0 bash "$REPO/scripts/analysis/set-core-requirement.sh" --subject "$S" --requirement "$REQ"
step "phpcbf" "0 1" bash "$REPO/scripts/analysis/run-phpcs.sh" --subject "$S" --fix
P="$(bash "$REPO/scripts/contrib/make-patch.sh" --local --subject "$S" < /dev/null 2>> "$LOG" | sed -n '$p')" \
  || { log_err "e2e: make-patch.sh --local failed (see $LOG)."; exit 2; }
[[ -n "$P" && -f "$P" ]] || { log_err "e2e: make-patch.sh --local wrote no patch (see $LOG)."; exit 2; }
cp "$P" "$WORK/port-to-drupal-11.patch"
if cmp -s "$GOLDEN" "$P"; then
  log_ok "e2e: the patch equals the golden ($(grep -c '^diff --git' "$P" || true) file(s))."
  exit 0
fi
log_err "e2e: the patch differs from tests/fixtures/legacy_widgets.golden/golden/port-to-drupal-11.patch:"
diff -u "$GOLDEN" "$P" >&2 || true
exit 3
