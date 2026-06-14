#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/preflight.sh
# Central requirements engine. Reused by the SessionStart hook, the
# /drupilot-doctor command and every command gate.
#
# Validates ONLY what the requested operation needs (see the requirements
# matrix in PROMPT 4.4.2), checking presence AND minimum version, and — where
# it applies — that the service is actually running (e.g. the Docker daemon,
# not just the binary).
#
# Usage:
#   preflight.sh [--profile analyze|setup|test|contribute|all] [--json] [--quiet]
#
# Output:
#   --json   -> a single JSON object on STDOUT (nothing else).
#   default  -> a human-readable English status report on STDOUT.
#   Diagnostics/logging always go to STDERR.
#
# Exit codes:
#   0  -> all HARD requirements for the profile are satisfied (always 0 for 'all').
#   2  -> a hard requirement is missing or below the minimum version.
#   1  -> usage/internal error.
# =============================================================================
set -uo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

PROFILE="all"
AS_JSON=0
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-all}"; shift 2;;
    --profile=*) PROFILE="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    --quiet) QUIET=1; shift;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; exit 0;;
    *) log_warn "Unknown argument: $1"; shift;;
  esac
done

case "$PROFILE" in
  analyze|setup|test|contribute|all) : ;;
  *) die "Invalid profile: '$PROFILE' (use analyze|setup|test|contribute|all)" 1;;
esac

have_cmd jq || die "'jq' is required to run preflight (it builds JSON). Install jq and retry." 1

# ---------------------------------------------------------------------------
# Config sanity (NON-FATAL): warn early on a misconfigured enum value (env or
# .drupilot.json) so the developer fixes it before it fails deep inside a tool.
# This never changes the exit code — preflight gates requirements, not prefs.
# ---------------------------------------------------------------------------
config_enum DRUPILOT_CONTRIB_MODE         semi   semi auto              >/dev/null || true
config_enum DRUPILOT_CORE_TARGET_STRATEGY auto   auto d11-only keep-d10 >/dev/null || true
config_enum DRUPILOT_REQUIRE_PHP_FLOOR    detect detect target          >/dev/null || true
config_enum DRUPILOT_GENERATE_RULES       ask    ask auto off           >/dev/null || true

TARGET="$(resolve_php_target)"
PHP_MIN="$(req_version php_min "8.3")"
COMPOSER_MIN="$(req_version composer_min "2.2.0")"
GIT_MIN="$(req_version git_min "2.20.0")"
JQ_MIN="$(req_version jq_min "1.6")"
DOCKER_MIN="$(req_version docker_min "20.10.0")"
DDEV_MIN="$(req_version ddev_min "1.23.0")"

SSH_KEYS_URL="$(config_json .contrib.ssh_keys_url "https://git.drupalcode.org/-/user_settings/ssh_keys")"
PAT_URL="$(config_json .contrib.pat_url "https://git.drupalcode.org/-/user_settings/personal_access_tokens")"
PAT_ENV_VAR="$(config_json .contrib.pat_env_var "DRUPILOT_GITLAB_PAT")"
REGISTER_URL="$(config_json .contrib.register_url "https://www.drupal.org/user/register")"
SSH_TEST_TARGET="$(config_json .contrib.ssh_test_target "git@git.drupal.org")"

OS="$(os_id)"

# ---------------------------------------------------------------------------
# Install hints (OS-aware)
# ---------------------------------------------------------------------------
hint_for() {
  case "$1" in
    jq) case "$OS" in
          fedora) echo "sudo dnf install jq";;
          ubuntu|debian) echo "sudo apt-get install jq";;
          arch) echo "sudo pacman -S jq";;
          macos) echo "brew install jq";;
          *) echo "Install jq: https://jqlang.github.io/jq/download/";;
        esac;;
    git) case "$OS" in
          fedora) echo "sudo dnf install git";;
          ubuntu|debian) echo "sudo apt-get install git";;
          arch) echo "sudo pacman -S git";;
          macos) echo "brew install git (or: xcode-select --install)";;
          *) echo "Install git: https://git-scm.com/downloads";;
        esac;;
    php) case "$OS" in
          fedora) echo "sudo dnf install php-cli  (or just use DDEV, which bundles PHP)";;
          ubuntu|debian) echo "sudo apt-get install php-cli  (or use DDEV)";;
          macos) echo "brew install php  (or use DDEV)";;
          *) echo "Install PHP >= $TARGET, or use DDEV which provides it";;
        esac;;
    composer) echo "https://getcomposer.org/download/  (inside DDEV you can use 'ddev composer' instead)";;
    docker) case "$OS" in
          fedora) echo "Docker Engine: https://docs.docker.com/engine/install/fedora/  — then 'sudo usermod -aG docker \$USER' and re-login";;
          ubuntu|debian) echo "Docker Engine: https://docs.docker.com/engine/install/  — then add your user to the 'docker' group and re-login";;
          macos) echo "Docker Desktop / OrbStack / Colima: https://docs.docker.com/desktop/install/mac-install/";;
          *) echo "Install Docker: https://docs.docker.com/engine/install/";;
        esac;;
    docker_daemon) echo "Start the Docker daemon (Linux: 'sudo systemctl start docker'; Desktop: launch the app)";;
    ddev) echo "DDEV: https://ddev.readthedocs.io/en/stable/users/install/ddev-installation/  (Linux script installer recommended)";;
    ssh) echo "ssh-keygen -t ed25519 -C \"you@example.com\", then upload the public key at $SSH_KEYS_URL and test with 'ssh -T $SSH_TEST_TARGET'";;
    pat) echo "Create a token at $PAT_URL (scopes: read_repository, write_repository) and export $PAT_ENV_VAR=...";;
    git_identity) echo "git config --global user.name \"Real Name\"  &&  git config --global user.email you@example.com (the email linked to your drupal.org account)";;
    selenium) echo "ddev add-on get ddev/ddev-selenium-standalone-chrome  &&  ddev restart";;
    drupalorg) echo "Create/verify your account at $REGISTER_URL and accept the GitLab Terms of Service in your profile's 'DrupalCode access' tab";;
    glab) echo "Optional GitLab CLI: https://gitlab.com/gitlab-org/cli  (curl is used as a fallback)";;
    *) echo "";;
  esac
}

# ---------------------------------------------------------------------------
# Check accumulation
# ---------------------------------------------------------------------------
CHECKS=()

emit_check() {
  # emit_check id label detail category profiles kind present version required ok hint
  jq -n \
    --arg id "$1" --arg label "$2" --arg detail "$3" --arg category "$4" \
    --arg profiles "$5" --arg kind "$6" --argjson present "$7" \
    --arg version "$8" --arg required "$9" --argjson ok "${10}" --arg hint "${11}" \
    '{id:$id,label:$label,detail:$detail,category:$category,
      profiles:($profiles|split(" ")|map(select(length>0))),
      kind:$kind,present:$present,version:$version,required:$required,ok:$ok,hint:$hint}'
}

# check_tool id label detail category profiles kind cmd minver
check_tool() {
  local id="$1" label="$2" detail="$3" cat="$4" profiles="$5" kind="$6" cmd="$7" minver="$8"
  local present="false" ver="" ok="false"
  if have_cmd "$cmd"; then
    present="true"
    ver="$(tool_version "$cmd")"
    if [[ -z "$minver" ]]; then
      ok="true"
    elif [[ -z "$ver" ]]; then
      ok="true"; ver="unknown"     # present but unparseable -> don't false-negative
    elif version_ge "$ver" "$minver"; then
      ok="true"
    fi
  fi
  CHECKS+=("$(emit_check "$id" "$label" "$detail" "$cat" "$profiles" "$kind" "$present" "$ver" "$minver" "$ok" "$(hint_for "$cmd")")")
  printf -v "HAS_${id}" '%s' "$present"
  printf -v "OK_${id}" '%s' "$ok"
}

# --- Analysis tools -------------------------------------------------------
check_tool git      "git"      "version control / patches / contribution" analysis  "analyze contribute" hard git      "$GIT_MIN"
check_tool jq       "jq"       "JSON parsing for hooks and preflight"      analysis  "analyze"            hard jq       "$JQ_MIN"
check_tool php      "PHP"      "host PHP (static analysis target $TARGET)" analysis  "analyze"            soft php      "$TARGET"
check_tool composer "Composer" "dependency management (or via DDEV)"        analysis  "analyze"            soft composer "$COMPOSER_MIN"

# --- Environment & tests --------------------------------------------------
check_tool docker   "Docker"   "container engine for DDEV"                  environment "setup test"      hard docker   "$DOCKER_MIN"

DAEMON="false"
if docker_daemon_up; then DAEMON="true"; fi
CHECKS+=("$(emit_check docker_daemon "Docker daemon" "the engine must be running, not just installed" environment "setup test" hard "$DAEMON" "" "" "$DAEMON" "$(hint_for docker_daemon)")")

check_tool ddev     "DDEV"     "full Drupal 11 environment (web + DB + chromedriver)" environment "setup test" hard ddev "$DDEV_MIN"

# Selenium add-on: cannot be detected without a DDEV project -> manual/info.
CHECKS+=("$(emit_check selenium "Selenium add-on" "needed for FunctionalJavascript tests" environment "test" soft false "" "" false "$(hint_for selenium)")")

# --- Contribution ---------------------------------------------------------
# SSH key present? (public key on disk)
SSH_OK="false"; SSH_VER=""
for k in id_ed25519 id_ecdsa id_rsa; do
  if [[ -f "$HOME/.ssh/$k.pub" ]]; then SSH_OK="true"; SSH_VER="$k"; break; fi
done
CHECKS+=("$(emit_check ssh_key "SSH key" "push access to git.drupal.org (recommended)" contribution "contribute" soft "$SSH_OK" "$SSH_VER" "" "$SSH_OK" "$(hint_for ssh)")")

# PAT present in environment?
PAT_OK="false"
if [[ -n "${!PAT_ENV_VAR:-}" ]]; then PAT_OK="true"; fi
CHECKS+=("$(emit_check pat "GitLab PAT" "HTTPS push / API token (alternative to SSH)" contribution "contribute" soft "$PAT_OK" "" "" "$PAT_OK" "$(hint_for pat)")")

# git identity configured?
GIT_NAME="$(git config --global user.name 2>/dev/null || true)"
GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
GIT_ID_OK="false"; [[ -n "$GIT_NAME" && -n "$GIT_EMAIL" ]] && GIT_ID_OK="true"
CHECKS+=("$(emit_check git_identity "git identity" "user.name + user.email for commits" contribution "contribute" soft "$GIT_ID_OK" "$GIT_NAME" "" "$GIT_ID_OK" "$(hint_for git_identity)")")

# drupal.org account + GitLab access: not programmatically verifiable -> manual.
CHECKS+=("$(emit_check drupalorg "drupal.org account" "confirmed account + accepted GitLab ToS" contribution "contribute" manual false "" "" false "$(hint_for drupalorg)")")

# Optional API helpers
GLAB_OK="false"; have_cmd glab && GLAB_OK="true"
CURL_OK="false"; have_cmd curl && CURL_OK="true"
API_OK="false"; { [[ "$GLAB_OK" == "true" ]] || [[ "$CURL_OK" == "true" ]]; } && API_OK="true"
CHECKS+=("$(emit_check api_helper "glab/curl" "open/manage MRs via the GitLab API (degradable)" contribution "contribute" soft "$API_OK" "" "" "$API_OK" "$(hint_for glab)")")

# ---------------------------------------------------------------------------
# Readiness per profile
# ---------------------------------------------------------------------------
is_true() { [[ "$1" == "true" ]]; }

READY_ANALYZE="false"
if is_true "${OK_git:-false}" && is_true "${OK_jq:-false}" \
   && { is_true "${OK_composer:-false}" || is_true "${OK_php:-false}"; }; then
  READY_ANALYZE="true"
fi

READY_SETUP="false"
if is_true "${OK_docker:-false}" && is_true "$DAEMON" && is_true "${OK_ddev:-false}"; then
  READY_SETUP="true"
fi
READY_TEST="$READY_SETUP"

READY_CONTRIBUTE="false"
if is_true "${OK_git:-false}" && { is_true "$SSH_OK" || is_true "$PAT_OK"; }; then
  READY_CONTRIBUTE="true"
fi

READY_JSON="$(jq -n \
  --argjson analyze "$READY_ANALYZE" --argjson setup "$READY_SETUP" \
  --argjson test "$READY_TEST" --argjson contribute "$READY_CONTRIBUTE" \
  '{analyze:$analyze, setup:$setup, test:$test, contribute:$contribute}')"

CHECKS_JSON="$(printf '%s\n' "${CHECKS[@]}" | jq -s '.')"
RESULT="$(jq -n \
  --arg profile "$PROFILE" --arg php_target "$TARGET" \
  --argjson checks "$CHECKS_JSON" --argjson ready "$READY_JSON" \
  '{profile:$profile, php_target:$php_target, ready:$ready, checks:$checks}')"

# ---------------------------------------------------------------------------
# Human report
# ---------------------------------------------------------------------------
icon_for() { # ok present kind  -> icon
  local ok="$1" present="$2" kind="$3"
  if [[ "$ok" == "true" ]]; then echo "✅"; return; fi
  case "$kind" in
    hard) echo "❌";;
    *) echo "⚠️";;
  esac
}

render_human() {
  local res="$1"
  printf '\n%sdrupilot — environment check%s   (PHP target: %s)\n' "$_C_BOLD" "$_C_RESET" "$TARGET"
  hr
  local cat title
  for cat in analysis environment contribution; do
    case "$cat" in
      analysis) title="Analysis (assess / static port)";;
      environment) title="Environment & tests (DDEV)";;
      contribution) title="Contribution (Drupal.org)";;
    esac
    printf '\n%s%s%s\n' "$_C_BOLD" "$title" "$_C_RESET"
    # Use the unit separator (0x1F) instead of tab: it is non-whitespace, so
    # `read` preserves empty fields instead of collapsing adjacent delimiters.
    while IFS=$'\037' read -r label kind ok present version required hint; do
      [[ -z "$label" ]] && continue
      local ic; ic="$(icon_for "$ok" "$present" "$kind")"
      local extra=""
      if [[ "$ok" == "true" && -n "$version" && "$version" != "unknown" ]]; then
        extra=" ($version)"
      elif [[ "$ok" == "true" && "$version" == "unknown" ]]; then
        extra=" (version unknown)"
      elif [[ "$kind" == "manual" ]]; then
        extra=" — verify manually"
      elif [[ "$ok" != "true" && -n "$required" ]]; then
        extra=" — needs >= $required${version:+, found $version}"
      fi
      printf '  %s %-18s %s%s%s\n' "$ic" "$label" "$_C_DIM" "$extra" "$_C_RESET"
      if [[ "$ok" != "true" && -n "$hint" ]]; then
        printf '       %s↳ %s%s\n' "$_C_DIM" "$hint" "$_C_RESET"
      fi
    done < <(printf '%s' "$res" | jq -r --arg c "$cat" \
      '.checks[] | select(.category==$c) | [.label,.kind,(.ok|tostring),(.present|tostring),.version,.required,.hint] | join("")')
  done

  hr
  # Summary line
  local sa ss st sc
  sa="$(printf '%s' "$res" | jq -r '.ready.analyze')"
  ss="$(printf '%s' "$res" | jq -r '.ready.setup')"
  st="$(printf '%s' "$res" | jq -r '.ready.test')"
  sc="$(printf '%s' "$res" | jq -r '.ready.contribute')"
  badge() { [[ "$1" == "true" ]] && printf '✅' || printf '❌'; }
  printf '\n%sReady for:%s  analysis %s  ·  environment+tests %s  ·  contribution %s\n' \
    "$_C_BOLD" "$_C_RESET" "$(badge "$sa")" "$(badge "$ss")" "$(badge "$sc")"
  [[ "$st" != "$ss" ]] && printf '            (tests share the environment requirements)\n'
  printf '\nRun %s/drupilot-doctor%s for the full report and assisted installation.\n\n' "$_C_CYAN" "$_C_RESET"
}

if [[ "$AS_JSON" == "1" ]]; then
  printf '%s\n' "$RESULT"
elif [[ "$QUIET" != "1" ]]; then
  render_human "$RESULT"
fi

# ---------------------------------------------------------------------------
# Exit code
# ---------------------------------------------------------------------------
if [[ "$PROFILE" == "all" ]]; then
  exit 0
fi
case "$PROFILE" in
  analyze)    is_true "$READY_ANALYZE"    && exit 0 || exit 2;;
  setup)      is_true "$READY_SETUP"      && exit 0 || exit 2;;
  test)       is_true "$READY_TEST"       && exit 0 || exit 2;;
  contribute) is_true "$READY_CONTRIBUTE" && exit 0 || exit 2;;
esac
exit 0
