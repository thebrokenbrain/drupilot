#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/render-templates.sh
# Render the toolchain config templates into the Drupal root, deterministically:
#   rector   templates/rector.php.tmpl              -> <root>/rector.php
#   rector-compat
#            templates/rector-compat.php.tmpl       -> <root>/rector-compat.php
#                                                      (only when the compat
#                                                      pass has a rule to run)
#   phpstan  templates/phpstan.neon.tmpl            -> <root>/phpstan.neon
#   phpcs    templates/phpcs.xml.dist.tmpl          -> <root>/phpcs.xml.dist
#   testing  templates/ddev-web-environment.yaml.tmpl
#                                                   -> <root>/.ddev/config.testing.yaml
# Tokens: {{SUBJECT_PATH}} (in-root path of the module/theme), {{PHP_TARGET}}
# (resolve_php_target), {{PHP_FLOOR}} / {{PHP_FLOOR_ID}} / {{PHP_FLOOR_SET}}
# (the PHP floor L of the Rector configs, rector_php_bounds: the lowest PHP the
# core range core-strategy.sh recommends and the effective require.php admit,
# never above the PHP target, e.g. 8.1 / PHP_81 / php81 for ^10 || ^11; a
# floor of 8.5 gets php84 sets, rector_floor_tokens), {{PHP_SET}} (the
# ->withPhpSets() argument for the PHP target, rector_php_set_arg; no current
# template uses it), {{DRUPAL_TARGET}} (resolve_drupal_target),
# {{PHPSTAN_LEVEL}} (DRUPILOT_PHPSTAN_LEVEL, default 2) and {{WEBDRIVER_HOST}}
# (the Selenium service read from .ddev/docker-compose.selenium-chrome.yaml,
# default selenium-chrome:4444; no current template uses it — the testing
# template leaves MINK_DRIVER_ARGS_WEBDRIVER to the Selenium add-on — but
# --set WEBDRIVER_HOST=... is still accepted). Substitution is literal
# (render_template in common.sh), so no path character can break it.
#
# rector.php (template v5) and phpstan.neon (template v3) are rendered from the
# upgrade plan (ADR 0019, ADR 0020): the frozen plan of the subject
# (plan_for_subject), else a fresh draft from scripts/analysis/upgrade-path.sh.
# rector.php's tokens {{RECTOR_SETS}}, {{SKIP_RULES}}, {{BC_BLOCK}},
# {{PHP_VERSION_L}} / {{PHP_SETS_L}} (the plan's php.floor) and {{POLYFILLS}}
# come from rector_sets_block, rector_skip_block, rector_bc_block and
# rector_floor_tokens; phpstan.neon's {{PHPSTAN_PHP_MIN}} / {{PHPSTAN_PHP_MAX}}
# (the plan's php.phpstan_phpversion), {{PHPSTAN_PROFILE}} /
# {{PHPSTAN_PROFILE_BLOCK}} (the plan's phpstan.profile, or --profile;
# phpstan_profile_block) and {{PHPSTAN_CACHE_KEY}} (the first 12 hex digits of
# the plan's hash, phpstan_cache_key). The sha256 of every file written goes
# into the root's lock (.templates, render_sha_record), so a later render
# regenerates a copy nobody edited.
#
# Every rendered file is validated BEFORE it is written: no {{TOKEN}} may be
# left, phpcs.xml.dist must be well-formed XML (`xmllint --noout`; without
# xmllint, `phpcs --standard=<file> -e` through the toolchain when available),
# rector.php must pass `php -l` (inside DDEV when it is up, else a host php if
# one exists). phpstan.neon and the testing YAML are only token-checked. A file
# that fails validation is never written.
#
# Idempotent and never clobbers a hand-edited config: a missing file is written,
# an identical one is left alone, and one that DIFFERS is left untouched (its
# unified diff goes to stderr, exit 3) unless --force is given — then the old
# copy is backed up to <root>/.drupilot/backups/ first. Exception: a copy
# drupilot generated from an OLDER template (its "drupilot — <file>" header is
# there but the template's current "drupilot-template-version: N" marker is
# not) is upgraded without --force, after the same backup — e.g. the invalid
# 0.8.x phpcs.xml.dist or a phpstan.neon with the deprecated drupal_root. So is
# an untouched render: a file whose sha256 is the one kept in the root's lock
# (ADR 0019), or a rector-compat.php (or template-4 rector.php) that is exactly
# what its template renders for its own floor and subject
# (rector_config_pristine): nobody edited it, and its plan or floor moved (the
# core target changed) or it was rendered for another subject of a shared
# test-bed (0.9 reported that as "differs"). Any other current-generation copy
# that differs counts as hand-edited, a template-5 rector.php whose sha256 the
# lock no longer keeps included (its sha256 is kept again when it is found up
# to date).
#
# rector-compat.php is rendered only when the compat pass has a rule to run
# (rector_compat_needed: the floor is below PHP 8.4 and the core range runs on
# 8.4 or later); otherwise its entry is "skipped" and an existing copy is left
# alone (run-rector.sh does not run it).
#
# Usage:
#   render-templates.sh (--root DIR | --subject DIR) [--subject-path REL]
#                       [--only LIST] [--set KEY=VALUE]... [--profile P]
#                       [--force] [--dry-run] [--json]
#
# Options:
#   --root DIR          Drupal project root. Without it, the root is found by
#                       walking up from --subject.
#   --subject DIR       The module/theme directory (absolute, or relative to the
#                       root). Its path relative to the root is {{SUBJECT_PATH}}.
#   --subject-path REL  Give {{SUBJECT_PATH}} directly (e.g.
#                       web/modules/custom/foo); wins over --subject.
#   --only LIST         Comma-separated subset of
#                       rector,rector-compat,phpstan,phpcs,testing (default:
#                       all; `rector` implies `rector-compat`, the pair shares
#                       the floor; `testing` is skipped when the root has no
#                       .ddev/ directory).
#   --set KEY=VALUE     Override one token value (repeatable), e.g.
#                       --set WEBDRIVER_HOST=selenium-chrome:4444. The PHP
#                       floor is not a token: it follows the core target and
#                       DRUPILOT_REQUIRE_PHP_FLOOR.
#   --profile P         The PHPStan profile of phpstan.neon: compat (Phase 1:
#                       phpstan-drupal's rules without its four opinion rules)
#                       or refactor (Phase 2: every phpstan-drupal rule as it
#                       ships). Default: the plan's phpstan.profile (compat).
#   --force             Replace a file that differs (after backing it up).
#   --dry-run           Render and validate, report what would happen; write
#                       nothing.
#   --json              Print a JSON summary on STDOUT:
#                       {root, subject_path, dry_run, force, ok, restart_needed,
#                        php_floor, php_ceiling, plan, phpstan_profile,
#                        files:[{name, template, path, status, valid, validator,
#                                backup}]}
#                       php_floor / php_ceiling: the floor L and the ceiling U
#                       of the Rector configs (null when no rector template is
#                       selected)
#                       plan: "plan" (the subject's frozen upgrade plan, else a
#                       fresh draft, gave rector.php its sets, skips, BC block
#                       and floor, and phpstan.neon its PHP range), "fallback"
#                       (no plan resolves: the previous major's sets, the floor
#                       above and the PHP target) or null (no rector or
#                       phpstan template selected)
#                       phpstan_profile: compat | refactor, or null (no
#                       phpstan template selected)
#                       status: written | unchanged | differs | replaced |
#                               upgraded | would-write | would-replace |
#                               would-upgrade | invalid | skipped
#                       valid: true | false | null (no validator available)
#   -h, --help          Show this help.
#   A value that is still an unsubstituted <placeholder> (e.g. "<drupal_root>")
#   is rejected with a clear error instead of being treated as a path.
#
# restart_needed is true when .ddev/config.testing.yaml was written, replaced or
# upgraded (run `ddev restart` so the web container picks it up) — and, with
# --dry-run, when it WOULD be (would-write / would-replace / would-upgrade), so
# the preview announces the restart the real run will need.
#
# Exit codes: 0 ok · 1 usage/error · 3 a file differs (not replaced without
# --force) or a rendered file failed validation.
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ROOT=""
SUBJECT=""
SUBJECT_PATH=""
ONLY=""
FORCE=0
DRY=0
AS_JSON=0
PROFILE=""
declare -a OVERRIDES=()

usage() { print_usage "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2;;
    --root=*) ROOT="${1#*=}"; shift;;
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --subject-path) SUBJECT_PATH="${2:-}"; shift 2;;
    --subject-path=*) SUBJECT_PATH="${1#*=}"; shift;;
    --only) ONLY="${2:-}"; shift 2;;
    --only=*) ONLY="${1#*=}"; shift;;
    --set) OVERRIDES+=("${2:-}"); shift 2;;
    --set=*) OVERRIDES+=("${1#*=}"); shift;;
    --profile) PROFILE="${2:-}"; shift 2;;
    --profile=*) PROFILE="${1#*=}"; shift;;
    --force) FORCE=1; shift;;
    --dry-run) DRY=1; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (see --help)." 1;;
  esac
done

reject_placeholder() {
  case "$2" in
    \<*\>|*\<*\>*) die "$1 got the unsubstituted placeholder '$2' — pass the real value." 1;;
  esac
  return 0
}
reject_placeholder --root "$ROOT"
reject_placeholder --subject "$SUBJECT"
reject_placeholder --subject-path "$SUBJECT_PATH"
case "$PROFILE" in
  ""|compat|refactor) ;;
  *) die "Invalid --profile '$PROFILE' (expected compat or refactor)." 1;;
esac

# --- Resolve the Drupal root ------------------------------------------------
if [[ -z "$ROOT" && -n "$SUBJECT" ]]; then
  [[ -d "$SUBJECT" ]] || die "Subject directory not found: $SUBJECT (pass --root too, or --subject-path)." 1
  # The root the subject is ported in: the test-bed for a loose subject or a
  # module of a project checkout without installed core (never the user's repo).
  ROOT="$(subject_project_root "$SUBJECT")"
fi
[[ -n "$ROOT" ]] || die "No Drupal root given or detected. Pass --root DIR (or a --subject inside a Drupal root)." 1
[[ -d "$ROOT" ]] || die "Root directory not found: $ROOT" 1
ROOT="$(cd "$ROOT" && pwd)"
export DRUPILOT_PROJECT_DIR="$ROOT"   # so config_get reads <root>/.drupilot.json

# --- Resolve {{SUBJECT_PATH}} -------------------------------------------------
if [[ -z "$SUBJECT_PATH" && -n "$SUBJECT" ]]; then
  SUBJ_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
  [[ -n "$SUBJ_ABS" ]] || SUBJ_ABS="$(cd "$ROOT/$SUBJECT" 2>/dev/null && pwd || true)"
  [[ -n "$SUBJ_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1
  case "$SUBJ_ABS" in
    "$ROOT"/*) ;;
    *) # A copy/symlink origin: the placed copy in the test-bed, when present.
       for _d in modules themes profiles; do
         if [[ -d "$ROOT/web/$_d/custom/$(basename "$SUBJ_ABS")" ]]; then
           SUBJ_ABS="$ROOT/web/$_d/custom/$(basename "$SUBJ_ABS")"; break
         fi
       done;;
  esac
  case "$SUBJ_ABS" in
    "$ROOT"/*) SUBJECT_PATH="${SUBJ_ABS#"$ROOT"/}";;
    *) die "Subject '$SUBJ_ABS' is outside the Drupal root '$ROOT' (place it first, or pass --subject-path)." 1;;
  esac
fi
SUBJECT_PATH="${SUBJECT_PATH%/}"
SUBJECT_PATH="${SUBJECT_PATH#./}"
case "$SUBJECT_PATH" in
  /*) die "--subject-path must be relative to the Drupal root (got '$SUBJECT_PATH')." 1;;
esac

# --- Which templates ----------------------------------------------------------
ALL="rector rector-compat phpstan phpcs testing"
SELECTED="$ALL"
if [[ -n "$ONLY" ]]; then
  WANT=""
  for n in $(printf '%s' "$ONLY" | tr ',' ' '); do
    case " $ALL " in
      *" $n "*) WANT="$WANT $n "
                # rector.php and rector-compat.php share the floor.
                if [[ "$n" == "rector" ]]; then WANT="$WANT rector-compat "; fi;;
      *) die "Unknown template '$n' in --only (expected: ${ALL// /,})." 1;;
    esac
  done
  SELECTED=""
  for n in $ALL; do
    case "$WANT" in *" $n "*) SELECTED="$SELECTED $n";; esac
  done
fi
needs_subject=0; needs_floor=0; needs_plan=0
for n in $SELECTED; do
  case "$n" in rector|rector-compat|phpstan|phpcs) needs_subject=1;; esac
  case "$n" in rector|rector-compat) needs_floor=1; needs_plan=1;; esac
  case "$n" in phpstan) needs_plan=1;; esac
done
if [[ "$needs_subject" == "1" && -z "$SUBJECT_PATH" ]]; then
  die "{{SUBJECT_PATH}} is unknown: pass --subject DIR or --subject-path REL (or --only testing)." 1
fi

# --- Token values ---------------------------------------------------------------
# webdriver_host -> host:port of the Selenium service, read from the add-on's
# compose file (the first service under `services:`), port 4444 (the
# standalone-chrome default). Falls back to selenium-chrome:4444.
webdriver_host() {
  local f="$ROOT/.ddev/docker-compose.selenium-chrome.yaml" svc=""
  if [[ -f "$f" ]]; then
    svc="$(awk '/^services:[[:space:]]*$/ {s=1; next}
                s && /^[[:space:]]+[A-Za-z0-9_.-]+:[[:space:]]*$/ {gsub(/[[:space:]:]/, ""); print; exit}
                s && /^[^[:space:]#]/ {exit}' "$f" 2>/dev/null || true)"
  fi
  printf '%s:4444' "${svc:-selenium-chrome}"
}

PHP_TARGET="$(resolve_php_target)"
DRUPAL_TARGET="$(resolve_drupal_target)"
PHPSTAN_LEVEL="$(config_get DRUPILOT_PHPSTAN_LEVEL 2)"
case " $SELECTED " in
  *" testing "*) WEBDRIVER_HOST="$(webdriver_host)";;
  *) WEBDRIVER_HOST="selenium-chrome:4444";;
esac

# Overrides (--set KEY=VALUE) win over the resolved values.
for ov in ${OVERRIDES[@]+"${OVERRIDES[@]}"}; do
  k="${ov%%=*}"; v="${ov#*=}"
  [[ "$ov" == *=* ]] || die "--set expects KEY=VALUE (got '$ov')." 1
  reject_placeholder "--set $k" "$v"
  case "$k" in
    SUBJECT_PATH) SUBJECT_PATH="$v";;
    PHP_TARGET) PHP_TARGET="$v";;
    DRUPAL_TARGET) DRUPAL_TARGET="$v";;
    PHPSTAN_LEVEL) PHPSTAN_LEVEL="$v";;
    WEBDRIVER_HOST) WEBDRIVER_HOST="$v";;
    PHP_SET) PHP_SET="$v";;
    *) die "Unknown token '$k' in --set (known: SUBJECT_PATH, PHP_TARGET, PHP_SET, DRUPAL_TARGET, PHPSTAN_LEVEL, WEBDRIVER_HOST)." 1;;
  esac
done
# The Rector PHP set follows the (possibly overridden) PHP target.
[[ -n "${PHP_SET:-}" ]] || PHP_SET="$(rector_php_set_arg "$PHP_TARGET")"
[[ "$PHP_SET" =~ ^php[0-9]+$ ]] || die "Invalid PHP_SET '$PHP_SET' (expected e.g. php83)." 1
case "$PHPSTAN_LEVEL" in
  [0-9]|max) : ;;
  *) die "Invalid PHPSTAN_LEVEL '$PHPSTAN_LEVEL' (expected 0-9 or 'max')." 1;;
esac

# The PHP floor L and ceiling U of the Rector configs (ADR 0002), from the
# subject's declared core range and require.php, never above the PHP target.
PHP_FLOOR=""; PHP_CEIL=""; COMPAT=0; PLAN=""; PLAN_SOURCE=""; PHPSTAN_PROFILE=""
declare -a FLOOR_TOKENS=()
if [[ "$needs_plan" == "1" ]]; then
  _b="$(rector_php_bounds "$ROOT/$SUBJECT_PATH" "$PHP_TARGET")"
  PHP_FLOOR="${_b%% *}"; PHP_CEIL="${_b##* }"
  # The upgrade plan (H4, ADR 0019): the subject's frozen plan, else a fresh
  # draft; its PHP floor wins. Without a plan (the resolver refuses), the
  # floor above and the previous major's sets.
  PLAN="$(plan_for_subject "$ROOT" "$ROOT/$SUBJECT_PATH" || true)"
  if [[ -n "$PLAN" ]]; then
    PLAN_SOURCE="plan"
    _pf="$(printf '%s' "$PLAN" | jq -r '.php.floor // empty')"
    [[ -z "$_pf" ]] || PHP_FLOOR="$_pf"
  else
    PLAN_SOURCE="fallback"
    _tm="$(resolve_target_major)"
    PLAN="$(plan_render_fallback "$_tm")" \
      || die "No configuration can be rendered for DRUPILOT_TARGET_MAJOR '$_tm' (expected an integer such as 11)." 1
  fi
fi
if [[ "$needs_floor" == "1" ]]; then
  _ft="$(rector_floor_tokens "$PHP_FLOOR" || true)"
  for _t in $_ft; do FLOOR_TOKENS+=("$_t"); done
  [[ "${#FLOOR_TOKENS[@]}" -eq 5 ]] || die "Could not derive the Rector tokens of the PHP floor '$PHP_FLOOR'." 1
  if rector_compat_needed "$PHP_FLOOR" "$PHP_CEIL"; then COMPAT=1; fi
  FLOOR_TOKENS+=("RECTOR_SETS=$(rector_sets_block "$PLAN")" "SKIP_RULES=$(rector_skip_block "$PLAN")"
                 "BC_BLOCK=$(rector_bc_block "$PLAN")" "POLYFILLS=")
fi
# phpstan.neon (ADR 0020): the plan's PHP range (without a plan, the floor
# above and the PHP target), its profile unless --profile names one, and a
# result cache directory per plan.
if [[ " $SELECTED " == *" phpstan "* ]]; then
  _pmin="$(printf '%s' "$PLAN" | jq -r '.php.phpstan_phpversion.min // empty')"
  _pmax="$(printf '%s' "$PLAN" | jq -r '.php.phpstan_phpversion.max // empty')"
  [[ -n "$_pmin" ]] || _pmin="$(php_version_id "$PHP_FLOOR" || true)"
  [[ -n "$_pmax" ]] || _pmax="$(php_version_id "$PHP_TARGET" || true)"
  [[ "$_pmin" =~ ^[0-9]+$ && "$_pmax" =~ ^[0-9]+$ ]] \
    || die "Could not derive phpstan.neon's PHP range (floor '$PHP_FLOOR', target '$PHP_TARGET')." 1
  _pf="$(printf '%s' "$PLAN" | jq -r '.php.final // empty')"
  if [[ "$PLAN_SOURCE" == "plan" && -n "$_pf" && "$_pf" != "$PHP_TARGET" ]]; then
    log_warn "phpstan.neon follows the upgrade plan's PHP target $_pf, not $PHP_TARGET: re-plan first (/drupilot-setup, or upgrade-path.sh --phase draft --root \"$ROOT\" --freeze)."
  fi
  PHPSTAN_PROFILE="${PROFILE:-$(printf '%s' "$PLAN" | jq -r '.phpstan.profile // "compat"')}"
  case "$PHPSTAN_PROFILE" in compat|refactor) ;; *) PHPSTAN_PROFILE="compat";; esac
  _ck="$(phpstan_cache_key "$PLAN" "$_pmin" "$_pmax" || true)"
  [[ -n "$_ck" ]] || die "Could not derive phpstan.neon's cache key from the plan." 1
  FLOOR_TOKENS+=("PHPSTAN_PHP_MIN=$_pmin" "PHPSTAN_PHP_MAX=$_pmax" "PHPSTAN_PROFILE=$PHPSTAN_PROFILE"
                 "PHPSTAN_PROFILE_BLOCK=$(phpstan_profile_block "$PHPSTAN_PROFILE")" "PHPSTAN_CACHE_KEY=$_ck")
fi

TOKENS=(
  "SUBJECT_PATH=$SUBJECT_PATH"
  "PHP_TARGET=$PHP_TARGET"
  "PHP_SET=$PHP_SET"
  "DRUPAL_TARGET=$DRUPAL_TARGET"
  "PHPSTAN_LEVEL=$PHPSTAN_LEVEL"
  "WEBDRIVER_HOST=$WEBDRIVER_HOST"
  ${FLOOR_TOKENS[@]+"${FLOOR_TOKENS[@]}"}
)

log_info "Drupal root  : $ROOT"
[[ -n "$SUBJECT_PATH" ]] && log_info "Subject path : $SUBJECT_PATH"
log_info "PHP target   : $PHP_TARGET · PHPStan level: $PHPSTAN_LEVEL${PHPSTAN_PROFILE:+ · PHPStan profile: $PHPSTAN_PROFILE}"
if [[ "$needs_floor" == "1" ]]; then
  log_info "PHP floor    : $PHP_FLOOR (Rector withPhpVersion and level sets) · ceiling: $PHP_CEIL · compat pass: $([[ "$COMPAT" == "1" ]] && echo yes || echo no)"
fi
if [[ "$needs_plan" == "1" && "$PLAN_SOURCE" != "plan" ]]; then
  log_warn "No upgrade plan resolves for this subject: rector.php uses the previous major's sets and the floor above, phpstan.neon the floor and the PHP target."
fi
[[ "$DRY" == "1" ]] && log_info "Dry run: nothing will be written."

RUNNER="$(drupal_runner "$ROOT" 2>/dev/null || true)"
declare -a RCMD=()
[[ -n "$RUNNER" ]] && read -r -a RCMD <<<"$RUNNER"

TMPS=()
cleanup() { local t; for t in ${TMPS[@]+"${TMPS[@]}"}; do rm -f "$t"; done; return 0; }
trap cleanup EXIT

# validate <name> <rendered-file> -> sets VALID (true|false|null) and VALIDATOR.
# The rendered file sits inside the root, so its root-relative path resolves the
# same on the host and inside the DDEV container.
VALID="null"; VALIDATOR=""
validate() {
  local name="$1" f="$2" rel="${2#"$ROOT"/}" left
  VALID="null"; VALIDATOR="tokens"
  left="$(grep -oE '\{\{[A-Z0-9_]+\}\}' "$f" 2>/dev/null | grep -v '{{PLACEHOLDER}}' | sort -u | tr '\n' ' ' || true)"
  if [[ -n "$left" ]]; then
    log_err "$name: unresolved token(s) after rendering: $left"
    VALID="false"; return 0
  fi
  case "$name" in
    phpcs)
      if have_cmd xmllint; then
        VALIDATOR="xmllint"
        local xout=""
        if xout="$(xmllint --noout "$f" 2>&1)"; then
          VALID="true"
        else
          VALID="false"
          log_err "phpcs.xml.dist: xmllint rejected the rendered file:"
          printf '%s\n' "$xout" | sed "s|$ROOT/||" >&2
        fi
      elif [[ -f "$ROOT/vendor/bin/phpcs" ]]; then
        VALIDATOR="phpcs -e"
        if ( cd "$ROOT" && ${RCMD[@]+"${RCMD[@]}"} vendor/bin/phpcs --standard="$rel" -e >/dev/null 2>&1 ); then
          VALID="true"
        else
          VALID="false"
          log_err "phpcs: 'phpcs --standard=<rendered phpcs.xml.dist> -e' rejected the ruleset."
        fi
      else
        VALIDATOR=""
        log_warn "phpcs.xml.dist: neither xmllint nor vendor/bin/phpcs is available; XML validity not checked."
      fi
      ;;
    rector|rector-compat)
      if [[ -n "$RUNNER" ]] || have_cmd php; then
        VALIDATOR="php -l"
        if ( cd "$ROOT" && ${RCMD[@]+"${RCMD[@]}"} php -l "$rel" >/dev/null 2>&1 ); then
          VALID="true"
        else
          VALID="false"
          log_err "$name.php: 'php -l' reports a syntax error in the rendered file."
        fi
      else
        VALIDATOR=""
        log_warn "$name.php: no php (host or DDEV) available; syntax not checked."
      fi
      ;;
    *) VALID="true";;
  esac
  return 0
}

# older_drupilot_copy <template> <dest> -> 0 when <dest> was generated by
# drupilot from an OLDER generation of <template>: it carries the template's
# "drupilot — <file>" header line but not the template's current
# "drupilot-template-version: N" marker. Templates without a marker never
# qualify, so their copies keep the hand-edited (differs) treatment.
older_drupilot_copy() {
  local tpl="$1" dest="$2" marker header
  marker="$(grep -oE 'drupilot-template-version: [0-9]+' "$tpl" 2>/dev/null | sed -n '1p' || true)"
  [[ -n "$marker" ]] || return 1
  header="$(grep -oE 'drupilot — [^ ]+' "$tpl" 2>/dev/null | sed -n '1p' || true)"
  [[ -n "$header" ]] || return 1
  grep -qF "$header" "$dest" 2>/dev/null || return 1
  grep -qF "$marker" "$dest" 2>/dev/null && return 1
  return 0
}

FILES_JSON=""
RC=0
RESTART=0

for name in $SELECTED; do
  case "$name" in
    rector)  tpl="rector.php.tmpl";               dest="$ROOT/rector.php";;
    rector-compat)
             tpl="rector-compat.php.tmpl";        dest="$ROOT/rector-compat.php";;
    phpstan) tpl="phpstan.neon.tmpl";             dest="$ROOT/phpstan.neon";;
    phpcs)   tpl="phpcs.xml.dist.tmpl";           dest="$ROOT/phpcs.xml.dist";;
    testing) tpl="ddev-web-environment.yaml.tmpl"; dest="$ROOT/.ddev/config.testing.yaml";;
  esac
  src="$(plugin_root)/templates/$tpl"
  status=""; backup=""; VALID="null"; VALIDATOR=""
  rel="${dest#"$ROOT"/}"

  if [[ "$name" == "testing" && ! -d "$ROOT/.ddev" ]]; then
    status="skipped"
    log_info "$rel: skipped (no .ddev/ directory at the root)."
  elif [[ "$name" == "rector-compat" && "$COMPAT" != "1" ]]; then
    status="skipped"
    log_info "$rel: skipped (the PHP floor $PHP_FLOOR and ceiling $PHP_CEIL leave the compat pass no rule to run)."
  else
    [[ -f "$src" ]] || die "Template not found: $src" 1
    dir="$(dirname "$dest")"
    tmp="$(mktemp "$dir/.$(basename "$dest").drupilot-render.XXXXXX")" \
      || die "Cannot create a temp file in $dir." 1
    TMPS+=("$tmp")
    render_template "$src" "$tmp" "${TOKENS[@]}" || die "Rendering $tpl failed." 1
    validate "$name" "$tmp"
    if [[ "$VALID" == "false" ]]; then
      status="invalid"; RC=3
      log_err "$rel: the rendered template is invalid; NOT written."
    elif [[ ! -f "$dest" ]]; then
      if [[ "$DRY" == "1" ]]; then status="would-write"
      else cat "$tmp" > "$dest"; status="written"; fi
      log_ok "$rel: ${status}."
    elif cmp -s "$tmp" "$dest"; then
      status="unchanged"
      log_ok "$rel: already up to date."
    else
      log_warn "$rel differs from the rendered template:"
      diff -u "$dest" "$tmp" 2>/dev/null \
        | sed -e "1s|^--- .*|--- $rel (current)|" -e "2s|^+++ .*|+++ $rel (rendered)|" >&2 || true
      older=0
      if older_drupilot_copy "$src" "$dest"; then older=1
      elif render_sha_matches "$ROOT" "$rel" "$dest"; then older=2
      elif [[ "$name" == "rector" || "$name" == "rector-compat" ]] && rector_config_pristine "$src" "$dest"; then older=2; fi
      if [[ "$FORCE" != "1" && "$older" == "0" ]]; then
        status="differs"; RC=3
        log_warn "$rel left untouched (hand-edited). Re-run with --force to replace it (the current copy is backed up)."
      elif [[ "$DRY" == "1" ]]; then
        if [[ "$FORCE" == "1" ]]; then status="would-replace"; else status="would-upgrade"; fi
      else
        backup="$(config_backup "$ROOT" "$dest")" || die "Could not back up $dest." 1
        cat "$tmp" > "$dest"
        if [[ "$FORCE" == "1" ]]; then
          status="replaced"
          log_ok "$rel: replaced (previous copy backed up to ${backup#"$ROOT"/})."
        elif [[ "$older" == "2" ]]; then
          status="upgraded"
          log_ok "$rel: an untouched drupilot render for another plan, PHP floor or subject; regenerated (previous copy backed up to ${backup#"$ROOT"/})."
        else
          status="upgraded"
          log_ok "$rel: generated by an older drupilot template; upgraded (previous copy backed up to ${backup#"$ROOT"/})."
        fi
      fi
    fi
    if [[ "$name" == "testing" ]]; then
      # A dry run reports the restart the planned change WILL need, so a caller
      # planning from it is not told the opposite of the real run.
      case "$status" in written|replaced|upgraded|would-write|would-replace|would-upgrade) RESTART=1;; esac
    fi
  fi

  # Its sha256 goes into the root's lock (never on a dry run).
  if [[ "$DRY" != "1" ]]; then
    case "$status" in
      written|unchanged|replaced|upgraded) render_sha_record "$ROOT" "$rel" "$dest" "$src";;
    esac
  fi
  entry="{\"name\":$(json_str "$name"),\"template\":$(json_str "templates/$tpl"),\"path\":$(json_str "$dest"),\"status\":$(json_str "$status"),\"valid\":$VALID,\"validator\":$(json_str "$VALIDATOR"),\"backup\":$(json_str "$backup")}"
  FILES_JSON="${FILES_JSON:+$FILES_JSON,}$entry"
done

if [[ "$RESTART" == "1" ]]; then
  if [[ "$DRY" == "1" ]]; then
    log_info ".ddev/config.testing.yaml would change: applying it needs a 'ddev restart' so the web container picks it up."
  else
    log_info ".ddev/config.testing.yaml changed: run 'ddev restart' so the web container picks it up."
  fi
fi

if [[ "$AS_JSON" == "1" ]]; then
  ok=true; [[ "$RC" == "0" ]] || ok=false
  restart=false; [[ "$RESTART" == "1" ]] && restart=true
  dry=false; [[ "$DRY" == "1" ]] && dry=true
  force=false; [[ "$FORCE" == "1" ]] && force=true
  fl=null; [[ "$needs_floor" == "1" && -n "$PHP_FLOOR" ]] && fl="$(json_str "$PHP_FLOOR")"
  ce=null; [[ "$needs_floor" == "1" && -n "$PHP_CEIL" ]] && ce="$(json_str "$PHP_CEIL")"
  ps=null; [[ -n "$PLAN_SOURCE" ]] && ps="$(json_str "$PLAN_SOURCE")"
  pp=null; [[ -n "$PHPSTAN_PROFILE" ]] && pp="$(json_str "$PHPSTAN_PROFILE")"
  printf '{"root":%s,"subject_path":%s,"dry_run":%s,"force":%s,"ok":%s,"restart_needed":%s,"php_floor":%s,"php_ceiling":%s,"plan":%s,"phpstan_profile":%s,"files":[%s]}\n' \
    "$(json_str "$ROOT")" "$(json_str "$SUBJECT_PATH")" "$dry" "$force" "$ok" "$restart" "$fl" "$ce" "$ps" "$pp" "$FILES_JSON"
fi
exit "$RC"
