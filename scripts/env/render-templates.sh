#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/render-templates.sh
# Render the toolchain config templates into the Drupal root, deterministically:
#   rector   templates/rector.php.tmpl              -> <root>/rector.php
#   phpstan  templates/phpstan.neon.tmpl            -> <root>/phpstan.neon
#   phpcs    templates/phpcs.xml.dist.tmpl          -> <root>/phpcs.xml.dist
#   testing  templates/ddev-web-environment.yaml.tmpl
#                                                   -> <root>/.ddev/config.testing.yaml
# Tokens: {{SUBJECT_PATH}} (in-root path of the module/theme), {{PHP_TARGET}}
# (resolve_php_target), {{PHP_SET}} (the Rector ->withPhpSets() argument for
# that target, rector_php_set_arg: 8.3 -> php83, 8.4 -> php84, an unconfirmed
# 8.5 -> php84), {{DRUPAL_TARGET}} (resolve_drupal_target),
# {{PHPSTAN_LEVEL}} (DRUPILOT_PHPSTAN_LEVEL, default 2) and {{WEBDRIVER_HOST}}
# (the Selenium service read from .ddev/docker-compose.selenium-chrome.yaml,
# default selenium-chrome:4444; no current template uses it — the testing
# template leaves MINK_DRIVER_ARGS_WEBDRIVER to the Selenium add-on — but
# --set WEBDRIVER_HOST=... is still accepted). Substitution is literal
# (render_template in common.sh), so no path character can break it.
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
# 0.8.x phpcs.xml.dist or a phpstan.neon with the deprecated drupal_root. A
# current-generation copy that differs counts as hand-edited.
#
# Usage:
#   render-templates.sh (--root DIR | --subject DIR) [--subject-path REL]
#                       [--only LIST] [--set KEY=VALUE]... [--force]
#                       [--dry-run] [--json]
#
# Options:
#   --root DIR          Drupal project root. Without it, the root is found by
#                       walking up from --subject.
#   --subject DIR       The module/theme directory (absolute, or relative to the
#                       root). Its path relative to the root is {{SUBJECT_PATH}}.
#   --subject-path REL  Give {{SUBJECT_PATH}} directly (e.g.
#                       web/modules/custom/foo); wins over --subject.
#   --only LIST         Comma-separated subset of rector,phpstan,phpcs,testing
#                       (default: all; `testing` is skipped when the root has no
#                       .ddev/ directory).
#   --set KEY=VALUE     Override one token value (repeatable), e.g.
#                       --set WEBDRIVER_HOST=selenium-chrome:4444.
#   --force             Replace a file that differs (after backing it up).
#   --dry-run           Render and validate, report what would happen; write
#                       nothing.
#   --json              Print a JSON summary on STDOUT:
#                       {root, subject_path, dry_run, force, ok, restart_needed,
#                        files:[{name, template, path, status, valid, validator,
#                                backup}]}
#                       status: written | unchanged | differs | replaced |
#                               upgraded | would-write | would-replace |
#                               would-upgrade | invalid | skipped
#                       valid: true | false | null (no validator available)
#   -h, --help          Show this help.
#   A value that is still an unsubstituted <placeholder> (e.g. "<drupal_root>")
#   is rejected with a clear error instead of being treated as a path.
#
# restart_needed is true when .ddev/config.testing.yaml was written, replaced or
# upgraded (run `ddev restart` so the web container picks it up).
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
declare -a OVERRIDES=()

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

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

# --- Resolve the Drupal root ------------------------------------------------
if [[ -z "$ROOT" && -n "$SUBJECT" ]]; then
  [[ -d "$SUBJECT" ]] || die "Subject directory not found: $SUBJECT (pass --root too, or --subject-path)." 1
  ROOT="$(find_drupal_root "$SUBJECT" 2>/dev/null || true)"
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
ALL="rector phpstan phpcs testing"
SELECTED="$ALL"
if [[ -n "$ONLY" ]]; then
  SELECTED=""
  for n in $(printf '%s' "$ONLY" | tr ',' ' '); do
    case " $ALL " in
      *" $n "*) SELECTED="$SELECTED $n";;
      *) die "Unknown template '$n' in --only (expected: ${ALL// /,})." 1;;
    esac
  done
fi
needs_subject=0
for n in $SELECTED; do
  case "$n" in rector|phpstan|phpcs) needs_subject=1;; esac
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

TOKENS=(
  "SUBJECT_PATH=$SUBJECT_PATH"
  "PHP_TARGET=$PHP_TARGET"
  "PHP_SET=$PHP_SET"
  "DRUPAL_TARGET=$DRUPAL_TARGET"
  "PHPSTAN_LEVEL=$PHPSTAN_LEVEL"
  "WEBDRIVER_HOST=$WEBDRIVER_HOST"
)

log_info "Drupal root  : $ROOT"
[[ -n "$SUBJECT_PATH" ]] && log_info "Subject path : $SUBJECT_PATH"
log_info "PHP target   : $PHP_TARGET (Rector set: $PHP_SET) · PHPStan level: $PHPSTAN_LEVEL"
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
    rector)
      if [[ -n "$RUNNER" ]] || have_cmd php; then
        VALIDATOR="php -l"
        if ( cd "$ROOT" && ${RCMD[@]+"${RCMD[@]}"} php -l "$rel" >/dev/null 2>&1 ); then
          VALID="true"
        else
          VALID="false"
          log_err "rector.php: 'php -l' reports a syntax error in the rendered file."
        fi
      else
        VALIDATOR=""
        log_warn "rector.php: no php (host or DDEV) available; syntax not checked."
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
  marker="$(grep -oE 'drupilot-template-version: [0-9]+' "$tpl" 2>/dev/null | head -n1 || true)"
  [[ -n "$marker" ]] || return 1
  header="$(grep -oE 'drupilot — [^ ]+' "$tpl" 2>/dev/null | head -n1 || true)"
  [[ -n "$header" ]] || return 1
  grep -qF "$header" "$dest" 2>/dev/null || return 1
  grep -qF "$marker" "$dest" 2>/dev/null && return 1
  return 0
}

FILES_JSON=""
RC=0
RESTART=0
TS="$(date -u +%Y%m%dT%H%M%SZ)"

for name in $SELECTED; do
  case "$name" in
    rector)  tpl="rector.php.tmpl";               dest="$ROOT/rector.php";;
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
      if older_drupilot_copy "$src" "$dest"; then older=1; fi
      if [[ "$FORCE" != "1" && "$older" != "1" ]]; then
        status="differs"; RC=3
        log_warn "$rel left untouched (hand-edited). Re-run with --force to replace it (the current copy is backed up)."
      elif [[ "$DRY" == "1" ]]; then
        if [[ "$FORCE" == "1" ]]; then status="would-replace"; else status="would-upgrade"; fi
      else
        bdir="$(project_artifacts_dir "$ROOT")/backups"
        mkdir -p "$bdir"
        backup="$bdir/$(basename "$dest").$TS"
        cp -p "$dest" "$backup"
        cat "$tmp" > "$dest"
        if [[ "$FORCE" == "1" ]]; then
          status="replaced"
          log_ok "$rel: replaced (previous copy backed up to ${backup#"$ROOT"/})."
        else
          status="upgraded"
          log_ok "$rel: generated by an older drupilot template; upgraded (previous copy backed up to ${backup#"$ROOT"/})."
        fi
      fi
    fi
    if [[ "$name" == "testing" ]]; then
      case "$status" in written|replaced|upgraded) RESTART=1;; esac
    fi
  fi

  entry="{\"name\":$(json_str "$name"),\"template\":$(json_str "templates/$tpl"),\"path\":$(json_str "$dest"),\"status\":$(json_str "$status"),\"valid\":$VALID,\"validator\":$(json_str "$VALIDATOR"),\"backup\":$(json_str "$backup")}"
  FILES_JSON="${FILES_JSON:+$FILES_JSON,}$entry"
done

[[ "$RESTART" == "1" ]] && log_info ".ddev/config.testing.yaml changed: run 'ddev restart' so the web container picks it up."

if [[ "$AS_JSON" == "1" ]]; then
  ok=true; [[ "$RC" == "0" ]] || ok=false
  restart=false; [[ "$RESTART" == "1" ]] && restart=true
  dry=false; [[ "$DRY" == "1" ]] && dry=true
  force=false; [[ "$FORCE" == "1" ]] && force=true
  printf '{"root":%s,"subject_path":%s,"dry_run":%s,"force":%s,"ok":%s,"restart_needed":%s,"files":[%s]}\n' \
    "$(json_str "$ROOT")" "$(json_str "$SUBJECT_PATH")" "$dry" "$force" "$ok" "$restart" "$FILES_JSON"
fi
exit "$RC"
