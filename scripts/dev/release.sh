#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/dev/release.sh
# Cut a release (a maintainer tool: no command, skill or hook calls it), as
# 09-R4 lays it out, and nothing more:
#   1. validate <version> (X.Y.Z or X.Y.Z-pre.N; it must be newer than the
#      current one, and no pre-release on `main`);
#   2. set .claude-plugin/plugin.json `version` (the single version source);
#   3. rename CHANGELOG.md `## [Unreleased]` to `## [<version>] - <date>`, add
#      an empty `[Unreleased]` above it and update the compare links
#      ([Unreleased] then compares from the new tag, so on the integration
#      branch it compares from the latest pre-release);
#   4. run `claude plugin validate .` (no warning but the known CLAUDE.md-at-
#      root one, which is why --strict is not used) and `check.sh --ci`;
#   5. commit `chore(release): <version>` and tag it `v<version>` (annotated);
#   6. print the push commands. It never pushes, and never runs
#      `claude plugin tag` (09-R12: only vX.Y.Z tags).
# A failing step 4 restores both files and commits nothing.
#
# Usage:
#   scripts/dev/release.sh <version> [--dry-run] [--date YYYY-MM-DD] [--json]
#                          [-h|--help]
#     --dry-run  write nothing: show the new plugin.json version and the
#                CHANGELOG diff, and run the `version` gate on a temp copy
#     --date     the release date (default: today, UTC)
#     --json     {ok, version, previous, dry_run, tag, commit, push} on STDOUT
#
# Requires bash >= 3.2, git, jq; the real run also `claude`, shellcheck and
# xmllint (check.sh --ci). Exit codes: 0 released (or dry run ok) · 1 usage
# error, a refused version, a dirty tree or a failed check.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SH="${BASH:-bash}"
VERSION=""; DRY=0; AS_JSON=0; DATE=""

usage() { print_usage "${BASH_SOURCE[0]}"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    --date) DATE="${2:-}"; shift 2 || die "--date needs a value" 1;;
    --date=*) DATE="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    -*) die "Unknown option: $1 (see --help)" 1;;
    *) [[ -z "$VERSION" ]] || die "Only one version, got '$VERSION' and '$1'" 1; VERSION="$1"; shift;;
  esac
done
[[ -n "$VERSION" ]] || die "Usage: release.sh <version> [--dry-run] [--json] (see --help)" 1
have_cmd git || die "release.sh needs git" 1
have_cmd jq || die "release.sh needs jq" 1
[[ -n "$DATE" ]] || DATE="$(date -u +%Y-%m-%d)"
printf '%s\n' "$DATE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || die "--date must be YYYY-MM-DD, got '$DATE'" 1

PJ="$REPO/.claude-plugin/plugin.json"
CL="$REPO/CHANGELOG.md"
SEMVER='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

# --- 1. Validate ----------------------------------------------------------------
printf '%s\n' "$VERSION" | grep -qE "$SEMVER" || die "'$VERSION' is not a valid version (X.Y.Z or X.Y.Z-pre.N)" 1
PREV="$(jq -r '.version // empty' "$PJ")"

# semver_gt A B -> 0 when A has a higher SemVer precedence than B (2.0.0 §11:
# numeric core fields; a release outranks its pre-releases; pre-release
# identifiers compare numerically when both are numbers, else as ASCII, a
# numeric one ranking lower; a longer list wins when all shared ones tie).
semver_gt() {
  local ac="${1%%-*}" bc="${2%%-*}" ap="" bp="" i x y na nb LC_ALL=C
  [[ "$1" == *-* ]] && ap="${1#*-}"
  [[ "$2" == *-* ]] && bp="${2#*-}"
  for i in 1 2 3; do
    x="$(printf '%s' "$ac" | cut -d. -f"$i")"; y="$(printf '%s' "$bc" | cut -d. -f"$i")"
    [[ "$x" -gt "$y" ]] && return 0
    [[ "$x" -lt "$y" ]] && return 1
  done
  [[ -z "$ap" && -z "$bp" ]] && return 1
  [[ -z "$ap" ]] && return 0
  [[ -z "$bp" ]] && return 1
  na=$(( $(printf '%s' "$ap" | tr -cd . | wc -c) + 1 )); nb=$(( $(printf '%s' "$bp" | tr -cd . | wc -c) + 1 ))
  i=1
  while [[ "$i" -le "$na" && "$i" -le "$nb" ]]; do
    x="$(printf '%s' "$ap" | cut -d. -f"$i")"; y="$(printf '%s' "$bp" | cut -d. -f"$i")"
    if [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]]; then
      [[ "$x" -gt "$y" ]] && return 0
      [[ "$x" -lt "$y" ]] && return 1
    elif [[ "$x" =~ ^[0-9]+$ ]]; then return 1
    elif [[ "$y" =~ ^[0-9]+$ ]]; then return 0
    else
      [[ "$x" > "$y" ]] && return 0
      [[ "$x" < "$y" ]] && return 1
    fi
    i=$((i + 1))
  done
  [[ "$na" -gt "$nb" ]]
}
semver_gt "$VERSION" "$PREV" || die "'$VERSION' is not newer than the current version '$PREV' (never reuse or lower a version)" 1
git -C "$REPO" rev-parse -q --verify "refs/tags/v$VERSION" > /dev/null && die "Tag v$VERSION already exists" 1
BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ "$BRANCH" == "main" && "$VERSION" == *-* ]] && die "A pre-release ('$VERSION') never goes on main; release it from the integration branch" 1
if [[ "$DRY" != "1" ]]; then
  [[ -z "$(git -C "$REPO" status --porcelain)" ]] || die "The working tree is not clean; commit or stash first" 1
fi
grep -q '^## \[Unreleased\]' "$CL" || die "CHANGELOG.md has no '## [Unreleased]' section" 1
UNREL_BODY="$(awk '/^## \[Unreleased\]/ { f = 1; next } f && /^## \[/ { exit } f && NF' "$CL")"
[[ -n "$UNREL_BODY" ]] || die "CHANGELOG.md [Unreleased] is empty: nothing to release" 1

# --- 2-3. The new plugin.json and CHANGELOG.md, in a temp dir ---------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-release.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
jq --arg v "$VERSION" '.version = $v' "$PJ" > "$TMP/plugin.json"
BASE_URL="$(sed -n 's#^\[Unreleased\]: \(.*\)/compare/.*#\1#p' "$CL" | head -n 1)"
[[ -n "$BASE_URL" ]] || die "CHANGELOG.md has no '[Unreleased]: <repo>/compare/...' link" 1
awk -v v="$VERSION" -v d="$DATE" -v p="$PREV" -v u="$BASE_URL" '
  /^## \[Unreleased\]/ && !h { print; print ""; print "## [" v "] - " d; h = 1; next }
  /^\[Unreleased\]: / && !l {
    print "[Unreleased]: " u "/compare/v" v "...HEAD"
    print "[" v "]: " u "/compare/v" p "...v" v
    l = 1; next
  }
  { print }' "$CL" > "$TMP/CHANGELOG.md"

PUSH_BRANCH="git push origin ${BRANCH:-<branch>}"
PUSH_TAG="git push origin v$VERSION"

if [[ "$DRY" == "1" ]]; then
  log_step "release.sh $VERSION --dry-run (current $PREV, branch ${BRANCH:-?})"
  log_info "plugin.json: version $PREV -> $VERSION"
  diff -u "$CL" "$TMP/CHANGELOG.md" | sed -n '1,40p' >&2 || true
  # The version gate on a temp copy holding the new files.
  mkdir -p "$TMP/tree/scripts/dev" "$TMP/tree/scripts/lib" "$TMP/tree/config" "$TMP/tree/.claude-plugin"
  cp "$REPO/scripts/dev/check.sh" "$TMP/tree/scripts/dev/"
  cp "$REPO/scripts/lib/common.sh" "$TMP/tree/scripts/lib/"
  cp "$REPO"/config/*.json "$TMP/tree/config/"
  cp "$TMP/plugin.json" "$TMP/tree/.claude-plugin/plugin.json"
  cp "$TMP/CHANGELOG.md" "$TMP/tree/CHANGELOG.md"
  if env GITHUB_REF_NAME="${BRANCH:-}" GITHUB_REF_TYPE=branch "$SH" "$TMP/tree/scripts/dev/check.sh" --only version >&2; then
    log_ok "Dry run: the version gate passes with $VERSION; nothing was written"
  else
    die "Dry run: the version gate fails with $VERSION" 1
  fi
  if [[ "$AS_JSON" == "1" ]]; then
    jq -n -c --arg v "$VERSION" --arg p "$PREV" --arg b "$PUSH_BRANCH" --arg t "$PUSH_TAG" \
      '{ok: true, version: $v, previous: $p, dry_run: true, tag: ("v" + $v), commit: null, push: [$b, $t]}'
  fi
  exit 0
fi

# --- Real run ---------------------------------------------------------------------
log_step "release.sh $VERSION (current $PREV, branch ${BRANCH:-?})"
have_cmd claude || die "release.sh needs the claude CLI (claude plugin validate)" 1
cp "$TMP/plugin.json" "$PJ"
cp "$TMP/CHANGELOG.md" "$CL"
restore() { git -C "$REPO" checkout -- .claude-plugin/plugin.json CHANGELOG.md 2>/dev/null || true; }

# --- 4. Validate --------------------------------------------------------------------
if ! ( cd "$REPO" && claude plugin validate . ) > "$TMP/validate.out" 2>&1; then
  sed 's/^/    /' "$TMP/validate.out" >&2; restore; die "claude plugin validate failed; nothing was committed" 1
fi
OTHER="$(grep -E '^[[:space:]]*❯' "$TMP/validate.out" | grep -v 'CLAUDE.md at the plugin root is not loaded' || true)"
if [[ -n "$OTHER" ]]; then
  printf '%s\n' "$OTHER" | sed 's/^/    /' >&2; restore
  die "claude plugin validate reports a warning other than the known CLAUDE.md-at-root one; nothing was committed" 1
fi
if ! "$SH" "$REPO/scripts/dev/check.sh" --ci >&2; then
  restore; die "check.sh --ci failed; nothing was committed" 1
fi

# --- 5. Commit and tag --------------------------------------------------------------
git -C "$REPO" add .claude-plugin/plugin.json CHANGELOG.md
git -C "$REPO" commit -q -m "chore(release): $VERSION"
git -C "$REPO" tag -a "v$VERSION" -m "drupilot $VERSION"
COMMIT="$(git -C "$REPO" rev-parse --short HEAD)"
log_ok "Released $VERSION: commit $COMMIT, tag v$VERSION (nothing pushed)"

# --- 6. The push commands -----------------------------------------------------------
log_info "To publish (after review): $PUSH_BRANCH && $PUSH_TAG"
if [[ "$AS_JSON" == "1" ]]; then
  jq -n -c --arg v "$VERSION" --arg p "$PREV" --arg c "$COMMIT" --arg b "$PUSH_BRANCH" --arg t "$PUSH_TAG" \
    '{ok: true, version: $v, previous: $p, dry_run: false, tag: ("v" + $v), commit: $c, push: [$b, $t]}'
fi
exit 0
