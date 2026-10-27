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
#                [--deep] [--extended] [--subject DIR]
#
# --deep: when DDEV is up, probe the container's real PHP with `ddev exec php`
#   instead of reading php_version from .ddev/config.yaml. Slower (one DDEV
#   call) — used by /drupilot-doctor's full report, NOT by the per-command gate
#   or the SessionStart hook, which stay on the cheap config read.
# --extended: also run the "health" checks for known pitfalls (doctor only).
#   They are report-only: they never change `ready` or the exit code.
#     xmllint        present (validates generated XML configs; optional)
#     sed            GNU or BSD flavour (info: drupilot works with both)
#     phpcs_config   the Drupal root's phpcs.xml.dist / phpcs.xml is well-formed
#                    XML (xmllint --noout; skipped without xmllint)
#     phpstan_config phpstan.neon does not set the deprecated drupal_root
#     toolchain:*    one row per known-good package installed at the root
#                    (composer.lock, read with jq: no PHP, no DDEV), compared
#                    with the root's cell of config/toolchain-reference.json
#                    (legacy_v1 for a lock drupilot 0.9 wrote); plus
#                    toolchain_combo, false when the installed set matches a
#                    known-broken combination (e.g. "Could not detect twig set")
#     disk_free      free space on the root's (else the current dir's)
#                    filesystem >= requirements.disk_free_min_mb (5120)
#     origin_residue the subject's origin checkout carries no drupilot / DDEV
#                    residue (origin-hygiene.sh --check against its baseline,
#                    else resolve-workspace.sh's residue scan)
#   Needs no running DDEV and starts nothing.
# --subject DIR: the module/theme (or Drupal root) the root-based checks look
#   at (default: the current directory).
#
# Output:
#   --json   -> a single JSON object on STDOUT (nothing else):
#               {profile, php_target, ready:{analyze,setup,test,contribute},
#                checks:[{id,label,detail,category,profiles,kind,present,
#                         version,required,ok,hint}]}
#               --extended adds rows with category "health" and the keys
#               extended:true and toolchain:{root, installed:{pkg:ver},
#               known_good:{pkg:ver}, match, differs:[pkg],
#               known_broken:[{packages,symptom}]} (null without a
#               composer.lock). Existing keys never change.
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
DEEP=0
EXTENDED=0
SUBJECT_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-all}"; shift 2;;
    --profile=*) PROFILE="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    --quiet) QUIET=1; shift;;
    --deep) DEEP=1; shift;;
    --extended) EXTENDED=1; shift;;
    --subject) SUBJECT_ARG="${2:-}"; shift; [[ $# -gt 0 ]] && shift;;
    --subject=*) SUBJECT_ARG="${1#*=}"; shift;;
    -h|--help)
      print_usage "$0"; exit 0;;
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
config_enum DRUPILOT_CORE_TARGET_STRATEGY auto   auto d11-only keep-d10 target-only keep-previous widest >/dev/null || true
config_enum DRUPILOT_REQUIRE_PHP_FLOOR    detect detect target          >/dev/null || true
config_enum DRUPILOT_GENERATE_RULES       ask    ask auto off           >/dev/null || true
config_enum DRUPILOT_TOOLCHAIN_SOURCE     auto   auto reference range   >/dev/null || true
config_enum DRUPILOT_SOFT_DEPRECATIONS    report report defer fix        >/dev/null || true
config_enum DRUPILOT_ATTRIBUTES_MODE      keep   keep strip             >/dev/null || true
config_enum DRUPILOT_HOOKS_GUARD          ask    ask off                >/dev/null || true
config_enum DRUPILOT_CORE_CACHE           auto   auto locked off        >/dev/null || true
config_enum DRUPILOT_LOCK_LOCATION        state  state project          >/dev/null || true
[[ -z "$(config_get DRUPILOT_LAYERS_SANDBOX "")" ]] || config_enum DRUPILOT_LAYERS_SANDBOX "" per-module shared >/dev/null || true
# DRUPILOT_VERIFY_CORES is auto | off | a comma list of MAJOR[.MINOR] legs.
_vc="$(config_get DRUPILOT_VERIFY_CORES auto)"
case "$_vc" in
  auto|off) : ;;
  *) printf '%s' "$_vc" | grep_q -E '^[[:space:]]*[0-9]+(\.[0-9]+)?(\.x)?[[:space:]]*(,[[:space:]]*[0-9]+(\.[0-9]+)?(\.x)?[[:space:]]*)*$' \
       || log_err "DRUPILOT_VERIFY_CORES='$_vc' is invalid. Allowed: auto, off, or a comma list of core legs such as 10,11 or 10.3,11";;
esac

TARGET="$(resolve_php_target)"
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
    bash) case "$OS" in
          macos) echo "brew install bash (any bash >= 3.2 works; stock /bin/bash 3.2 is fine)";;
          *) echo "Install bash >= 3.2 from your package manager";;
        esac;;
    selenium) echo "ddev add-on get ddev/ddev-selenium-standalone-chrome  &&  ddev restart";;
    drupalorg) echo "Create/verify your account at $REGISTER_URL and accept the GitLab Terms of Service in your profile's 'DrupalCode access' tab";;
    xmllint) case "$OS" in
          fedora) echo "sudo dnf install libxml2  (optional: validates generated XML configs)";;
          ubuntu|debian) echo "sudo apt-get install libxml2-utils  (optional)";;
          arch) echo "sudo pacman -S libxml2  (optional)";;
          macos) echo "ships with macOS (/usr/bin/xmllint); else brew install libxml2";;
          *) echo "Install xmllint (libxml2) — optional";;
        esac;;
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
    --arg id "$1" --arg lbl "$2" --arg detail "$3" --arg category "$4" \
    --arg profiles "$5" --arg kind "$6" --argjson present "$7" \
    --arg version "$8" --arg required "$9" --argjson ok "${10}" --arg hint "${11}" \
    '{id:$id,label:$lbl,detail:$detail,category:$category,
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

# --- Shell ------------------------------------------------------------------
# The scripts and hooks target bash >= 3.2 (stock macOS /bin/bash) with no GNU
# tool assumptions. Older shells are reported (soft: nothing realistic ships
# bash < 3.2 today, but the reason is then visible instead of an obscure crash).
BASH_MIN="3.2"
BASH_VER="${BASH_VERSINFO[0]:-0}.${BASH_VERSINFO[1]:-0}.${BASH_VERSINFO[2]:-0}"
BASH_OK="false"; version_ge "$BASH_VER" "$BASH_MIN" && BASH_OK="true"
CHECKS+=("$(emit_check bash "bash" "runs the drupilot scripts and hooks" analysis "analyze" soft true "$BASH_VER" "$BASH_MIN" "$BASH_OK" "$(hint_for bash)")")

# --- Analysis tools -------------------------------------------------------
check_tool git      "git"      "version control / patches / contribution" analysis  "analyze contribute" hard git      "$GIT_MIN"
check_tool jq       "jq"       "JSON parsing for hooks and preflight"      analysis  "analyze"            hard jq       "$JQ_MIN"

# PHP + Composer for the analyze path. The static toolchain runs wherever
# drupal_runner sends it: INSIDE DDEV when the container is up (so the DDEV
# php_version — freely configurable across minors — is what matters, not the
# host PHP), else host vendor/bin. Mirror that choice here so the gate validates
# the path that will actually run.
PF_BASE="$PWD"
if [[ -n "$SUBJECT_ARG" ]]; then
  if [[ -d "$SUBJECT_ARG" ]]; then PF_BASE="$(cd "$SUBJECT_ARG" && pwd)"
  else log_warn "--subject '$SUBJECT_ARG' is not a directory; using the current directory."; fi
fi
ANALYZE_ROOT="$(find_drupal_root "$PF_BASE" 2>/dev/null || true)"
if [[ -n "$ANALYZE_ROOT" ]] && ddev_running "$ANALYZE_ROOT"; then
  # --- DDEV is the execution path -----------------------------------------
  DDEV_PHP=""
  if [[ "$DEEP" == "1" ]]; then
    DDEV_PHP="$( ( cd "$ANALYZE_ROOT" 2>/dev/null && ddev exec php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' ) 2>/dev/null || true )"
    DDEV_PHP="$(trim "$DDEV_PHP")"
  fi
  [[ -z "$DDEV_PHP" ]] && DDEV_PHP="$(ddev_php_version "$ANALYZE_ROOT")"

  PHP_OK="false"; PHP_VER="$DDEV_PHP"
  if [[ -z "$DDEV_PHP" ]]; then
    PHP_OK="true"; PHP_VER="unknown"          # in DDEV but version unknown -> don't false-negative
  elif version_ge "$DDEV_PHP" "$TARGET"; then
    PHP_OK="true"
  fi
  DDEV_PHP_HINT="Realign DDEV to the target: 'ddev config --php-version=$TARGET && ddev restart' (or re-run /drupilot-setup)"
  CHECKS+=("$(emit_check php "PHP (DDEV)" "runs inside DDEV (php_version, target $TARGET)" analysis "analyze" soft true "$PHP_VER" "$TARGET" "$PHP_OK" "$DDEV_PHP_HINT")")
  OK_php="$PHP_OK"
  # shellcheck disable=SC2034  # HAS_* mirrors check_tool's printf -v family.
  HAS_php="true"

  # Composer is always available in the container as `ddev composer`.
  CHECKS+=("$(emit_check composer "Composer (DDEV)" "available in the container as 'ddev composer'" analysis "analyze" soft true "" "" true "")")
  OK_composer="true"
  # shellcheck disable=SC2034  # HAS_* mirrors check_tool's printf -v family.
  HAS_composer="true"
else
  # --- Host execution path (no running DDEV) ------------------------------
  check_tool php      "PHP"      "host PHP (static analysis target $TARGET)" analysis "analyze" soft php      "$TARGET"
  check_tool composer "Composer" "dependency management (or via DDEV)"       analysis "analyze" soft composer "$COMPOSER_MIN"
fi

# --- Environment & tests --------------------------------------------------
check_tool docker   "Docker"   "container engine for DDEV"                  environment "setup test"      hard docker   "$DOCKER_MIN"

DAEMON="false"
if docker_daemon_up; then DAEMON="true"; fi
CHECKS+=("$(emit_check docker_daemon "Docker daemon" "the engine must be running, not just installed" environment "setup test" hard "$DAEMON" "" "" "$DAEMON" "$(hint_for docker_daemon)")")

check_tool ddev     "DDEV"     "full Drupal 11 environment (web + DB + chromedriver)" environment "setup test" hard ddev "$DDEV_MIN"

# Selenium add-on: detected from the DDEV project's machine-readable add-on list
# (`ddev add-on list --installed -j`, or .ddev/addon-metadata) when there is a
# project; without one it cannot be known and stays a soft "missing" note.
SEL_OK="false"; SEL_VER=""
if [[ -n "$ANALYZE_ROOT" ]] && SEL_VER="$(ddev_addon_version ddev-selenium-standalone-chrome "$ANALYZE_ROOT")"; then
  SEL_OK="true"
else
  SEL_VER=""
fi
CHECKS+=("$(emit_check selenium "Selenium add-on" "needed for FunctionalJavascript tests" environment "test" soft "$SEL_OK" "$SEL_VER" "" "$SEL_OK" "$(hint_for selenium)")")

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
# Health checks (--extended, /drupilot-doctor only): known pitfalls. Report-only:
# category "health", never part of READY_* or the exit code.
# ---------------------------------------------------------------------------
TOOLCHAIN_JSON="null"
if [[ "$EXTENDED" == "1" ]]; then
  HROOT="$ANALYZE_ROOT"

  # xmllint (optional tool).
  XL_OK="false"; XL_VER=""
  if have_cmd xmllint; then
    XL_OK="true"
    XL_VER="$(xmllint --version 2>&1 | sed -n 's/.*using libxml version \([0-9][0-9]*\).*/\1/p' | sed -n '1p')"
    [[ -n "$XL_VER" ]] && XL_VER="libxml $XL_VER"
  fi
  CHECKS+=("$(emit_check xmllint "xmllint" "validates generated XML configs (optional)" health "setup" soft "$XL_OK" "$XL_VER" "" "$XL_OK" "$(hint_for xmllint)")")

  # sed flavour: info only (no script relies on GNU sed; sed_inplace avoids -i).
  SED_FLAVOR="bsd"; sed --version >/dev/null 2>&1 && SED_FLAVOR="gnu"
  CHECKS+=("$(emit_check sed "sed" "flavour (drupilot works with GNU and BSD sed)" health "analyze" info true "$SED_FLAVOR" "" true "")")

  # Generated configs at the Drupal root.
  if [[ -n "$HROOT" ]]; then
    for _pc in phpcs.xml.dist phpcs.xml; do
      [[ -f "$HROOT/$_pc" ]] || continue
      if have_cmd xmllint; then
        _xerr="$(xmllint --noout "$HROOT/$_pc" 2>&1 | sed -n '1,2p' | tr '\n' ' ' || true)"
        if [[ -z "$_xerr" ]]; then
          CHECKS+=("$(emit_check phpcs_config "$_pc" "the root's PHPCS ruleset is well-formed XML" health "analyze" soft true "valid" "" true "")")
        else
          CHECKS+=("$(emit_check phpcs_config "$_pc" "invalid XML: $_xerr" health "analyze" soft true "invalid" "" false \
            "Regenerate it (drupilot <= 0.8.4 wrote an invalid one): bash \"\$CLAUDE_PLUGIN_ROOT/scripts/env/render-templates.sh\" --root $HROOT --only phpcs --force")")
        fi
      else
        CHECKS+=("$(emit_check phpcs_config "$_pc" "not validated: xmllint is not installed" health "analyze" info true "skipped" "" true "")")
      fi
      break
    done
    if [[ -f "$HROOT/phpstan.neon" ]]; then
      if grep -qE '^[[:space:]]*drupal_root:' "$HROOT/phpstan.neon" 2>/dev/null; then
        CHECKS+=("$(emit_check phpstan_config "phpstan.neon" "sets the deprecated drupal_root parameter" health "analyze" soft true "drupal_root" "" false \
          "Regenerate it: bash \"\$CLAUDE_PLUGIN_ROOT/scripts/env/render-templates.sh\" --root $HROOT --only phpstan --force")")
      else
        CHECKS+=("$(emit_check phpstan_config "phpstan.neon" "no deprecated parameters" health "analyze" soft true "ok" "" true "")")
      fi
    fi
  fi

  # Toolchain at the root vs the known-good reference (composer.lock, jq only).
  REF_FILE="$(toolchain_reference_file)"
  if [[ -n "$HROOT" && -f "$HROOT/composer.lock" && -r "$REF_FILE" ]]; then
    # The known-good set of this root's toolchain cell (a 0.9 lock: legacy_v1).
    _kg="$(toolchain_reference_set "$(toolchain_cell_for "$HROOT")")"
    # Installed versions of the cell's packages, and of every package a
    # known-broken rule or the remediation names (so a broken combination is
    # still found when the cell pins nothing, e.g. Drupal 12's).
    _watch="$(jq -c --argjson kg "$_kg" '[($kg | keys[]), (.known_broken[]?.packages | keys[]), (.remediation_packages // [])[]] | unique' "$REF_FILE" 2>/dev/null || printf '[]')"
    _installed="$(jq -c --argjson w "$_watch" '
        ((.packages // []) + (."packages-dev" // [])) as $all
        | [$w[] as $k
           | ($all | map(select(.name == $k)) | .[0].version // empty) as $v
           | {key: $k, value: ($v | ltrimstr("v"))}] | from_entries' "$HROOT/composer.lock" 2>/dev/null || true)"
    [[ -n "$_installed" ]] || _installed='{}'
    TOOLCHAIN_JSON="$(jq -c --argjson inst "$_installed" --arg root "$HROOT" --argjson kg "$_kg" '
        ($kg | with_entries(select($inst[.key] != null))) as $kgi
        | {root: $root, installed: $inst, known_good: $kgi,
           differs: [$inst | to_entries[] | select(.key as $k | $kg | has($k)) | select($kg[.key] != .value) | .key],
           known_broken_rules: (.known_broken // [])}
        | .match = ((.differs | length) == 0 and ($kgi | length) > 0)' "$REF_FILE" 2>/dev/null || printf 'null')"
    [[ -n "$TOOLCHAIN_JSON" ]] || TOOLCHAIN_JSON="null"
    if [[ "$TOOLCHAIN_JSON" != "null" ]]; then
      _fix="bash \"\$CLAUDE_PLUGIN_ROOT/scripts/env/install-toolchain.sh\" --dir $HROOT --source reference"
      while IFS=$'\037' read -r _pkg _have _want; do
        [[ -n "$_pkg" ]] || continue
        _ok="true"; [[ "$_have" == "$_want" ]] || _ok="false"
        CHECKS+=("$(emit_check "toolchain:$_pkg" "$_pkg" "compared with the known-good reference" health "setup test" soft true "$_have" "$_want" "$_ok" \
          "$([[ "$_ok" == "true" ]] || printf 'Differs from the known-good reference; if Rector or PHPStan misbehaves, reinstall the reference set: %s' "$_fix")")")
      done < <(printf '%s' "$TOOLCHAIN_JSON" | jq -r '.known_good as $kg | .installed | to_entries[] | select(.key as $k | $kg | has($k)) | [.key, .value] | join("\u001f")' 2>/dev/null \
                | while IFS=$'\037' read -r _p _v; do
                    printf '%s\037%s\037%s\n' "$_p" "$_v" "$(printf '%s' "$TOOLCHAIN_JSON" | jq -r --arg p "$_p" '.known_good[$p] // ""')"
                  done)
      # Known-broken combinations: every package of an entry installed at a
      # version its constraint (exact, or >=X) matches.
      _broken="[]"
      _nb="$(printf '%s' "$TOOLCHAIN_JSON" | jq -r '.known_broken_rules | length' 2>/dev/null || echo 0)"
      _i=0
      while [[ "$_i" -lt "${_nb:-0}" ]]; do
        _hit="true"
        while IFS=$'\037' read -r _p _c; do
          [[ -n "$_p" ]] || continue
          _v="$(printf '%s' "$TOOLCHAIN_JSON" | jq -r --arg p "$_p" '.installed[$p] // ""')"
          if [[ -z "$_v" ]]; then _hit="false"; break; fi
          case "$_c" in
            ">="*) version_ge "$_v" "${_c#>=}" || { _hit="false"; break; };;
            *) [[ "$_v" == "$_c" ]] || { _hit="false"; break; };;
          esac
        done < <(printf '%s' "$TOOLCHAIN_JSON" | jq -r --argjson i "$_i" '.known_broken_rules[$i].packages | to_entries[] | [.key, .value] | join("\u001f")' 2>/dev/null)
        if [[ "$_hit" == "true" ]]; then
          _broken="$(printf '%s' "$TOOLCHAIN_JSON" | jq -c --argjson b "$_broken" --argjson i "$_i" '$b + [.known_broken_rules[$i] | {packages, symptom}]')"
        fi
        _i=$((_i + 1))
      done
      TOOLCHAIN_JSON="$(printf '%s' "$TOOLCHAIN_JSON" | jq -c --argjson b "$_broken" 'del(.known_broken_rules) | .known_broken = $b')"
      if [[ "$_broken" == "[]" ]]; then
        CHECKS+=("$(emit_check toolchain_combo "toolchain combination" "not a known-broken combination" health "setup test" soft true "" "" true "")")
      else
        _sym="$(printf '%s' "$_broken" | jq -r '[.[].symptom] | join(" / ")')"
        CHECKS+=("$(emit_check toolchain_combo "toolchain combination" "known-broken: $_sym" health "setup test" soft true "broken" "" false "Reinstall the known-good set: $_fix")")
      fi
    fi
  fi

  # Free disk space on the root's (else the current dir's) filesystem.
  DISK_MIN_MB="$(req_version disk_free_min_mb 5120)"
  _dfdir="${HROOT:-$PF_BASE}"
  _kb="$(df -Pk "$_dfdir" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
  if [[ "$_kb" =~ ^[0-9]+$ ]]; then
    _mb=$((_kb / 1024))
    _dok="false"; [[ "$_mb" -ge "$DISK_MIN_MB" ]] && _dok="true"
    CHECKS+=("$(emit_check disk_free "disk space" "free on the filesystem of $_dfdir" health "setup test" soft true "${_mb} MB" "${DISK_MIN_MB} MB" "$_dok" \
      "Free space: /drupilot-clean (removes test-bed vendor trees, DDEV projects or whole workspaces), 'ddev delete -Oy <project>', 'docker system prune'")")
  fi

  # drupilot / DDEV residue in the subject's origin checkout.
  if is_drupal_extension_dir "$PF_BASE"; then
    _oh="$(bash "$(plugin_root)/scripts/env/origin-hygiene.sh" --check --subject "$PF_BASE" --json 2>/dev/null || true)"
    _clean="$(printf '%s' "$_oh" | jq -r 'if .clean == null then "null" else (.clean | tostring) end' 2>/dev/null || echo null)"
    _origin="$(printf '%s' "$_oh" | jq -r '.origin // empty' 2>/dev/null || true)"
    [[ -n "$_origin" ]] || _origin="$PF_BASE"
    if [[ "$_clean" == "null" ]]; then
      # No baseline: scan the origin for local-environment residue instead.
      _res="$(bash "$(plugin_root)/scripts/env/resolve-workspace.sh" --subject "$_origin" --json 2>/dev/null | jq -r '[.residue[]? | tostring] | join(", ")' 2>/dev/null || true)"
      _how="residue scan (no baseline)"
    else
      _res="$(printf '%s' "$_oh" | jq -r '[.attributable[]? | if type == "object" then (.path // .entry // tostring) else tostring end] | join(", ")' 2>/dev/null || true)"
      _how="compared with the pre-port baseline"
    fi
    _rok="true"; [[ -z "$_res" ]] || _rok="false"
    CHECKS+=("$(emit_check origin_residue "origin residue" "$_origin: ${_res:-none} ($_how)" health "setup" soft true "${_res:+found}" "" "$_rok" \
      "Review with 'git -C $_origin status --porcelain' and remove what drupilot left ('git -C $_origin clean -n -- .ddev' first); details: origin-hygiene.sh --check --subject $PF_BASE")")
  fi
fi

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
if [[ "$EXTENDED" == "1" ]]; then
  RESULT="$(printf '%s' "$RESULT" | jq -c --argjson tc "$TOOLCHAIN_JSON" '. + {extended: true, toolchain: $tc}')"
fi

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
  for cat in analysis environment contribution health; do
    case "$cat" in
      analysis) title="Analysis (assess / static port)";;
      environment) title="Environment & tests (DDEV)";;
      contribution) title="Contribution (Drupal.org)";;
      health) title="Health (known pitfalls)"
        [[ "$(printf '%s' "$res" | jq '[.checks[] | select(.category=="health")] | length')" -gt 0 ]] || continue;;
    esac
    printf '\n%s%s%s\n' "$_C_BOLD" "$title" "$_C_RESET"
    # Use the unit separator (0x1F) instead of tab: it is non-whitespace, so
    # `read` preserves empty fields instead of collapsing adjacent delimiters.
    while IFS=$'\037' read -r label kind ok present version required hint detail; do
      [[ -z "$label" ]] && continue
      local ic; ic="$(icon_for "$ok" "$present" "$kind")"
      local extra=""
      if [[ "$ok" == "true" && -n "$version" && "$version" != "unknown" ]]; then
        extra=" ($version)"
      elif [[ "$ok" == "true" && "$version" == "unknown" ]]; then
        extra=" (version unknown)"
      elif [[ "$kind" == "manual" ]]; then
        extra=" — verify manually"
      elif [[ "$cat" == "health" && "$ok" != "true" ]]; then
        # Health rows explain themselves: the detail says what is wrong.
        extra=" — $detail${required:+ (known-good / minimum: $required${version:+, found $version})}"
      elif [[ "$ok" != "true" && -n "$required" ]]; then
        extra=" — needs >= $required${version:+, found $version}"
      fi
      printf '  %s %-18s %s%s%s\n' "$ic" "$label" "$_C_DIM" "$extra" "$_C_RESET"
      if [[ "$ok" != "true" && -n "$hint" ]]; then
        printf '       %s↳ %s%s\n' "$_C_DIM" "$hint" "$_C_RESET"
      fi
    done < <(printf '%s' "$res" | jq -r --arg c "$cat" \
      '.checks[] | select(.category==$c) | [.label,.kind,(.ok|tostring),(.present|tostring),.version,.required,.hint,.detail] | join("")')
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
