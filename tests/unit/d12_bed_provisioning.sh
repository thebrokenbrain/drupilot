#!/usr/bin/env bash
# ddev-up.sh builds a Drupal 12 preview test-bed from the target's toolchain
# cell (T-M6-03, ADR 0004), checked with stub ddev/docker that log their calls:
# for a loose subject whose frozen T=12 draft plan names a pre-release bed
# core, a drupal12 project on the plan's PHP (php.final, never the Drupal 11
# default), the plan's exact core, no drush, drupal/core from source; the same
# from the frozen plan alone, with no target in the environment; an explicit
# core pin keeps its own stability; a pin that does not admit the target, and
# a root whose installed core is Drupal 11, are refused (exit 1) before any
# `ddev config`; on the Drupal 12 bed, run-upgrade-status.sh skips on purpose
# (no drush: no `ddev drush` call); a Drupal 11 bed is built as before (the
# target's PHP, ^11, drush).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
export DRUPILOT_CORE_CACHE=off

LOG="$T_TMP/ddev.log"
FAKE="$T_TMP/fake"; mkdir -p "$FAKE"
printf '#!/bin/sh\ncase "$1" in --version|version) echo "Docker version 29.0.0, build x";; esac\nexit 0\n' > "$FAKE/docker"
# The ddev stub: `config` writes .ddev/config.yaml with the PHP it was given;
# `composer create-project` lays out a root of the core version it was asked
# for (12.0.0-beta2 for a ^12 constraint, 11.4.10 for ^11); `composer
# reinstall drupal/core --prefer-source` adds the core tests.
cat > "$FAKE/ddev" <<'STUB'
#!/bin/sh
echo "$*" >> "$DDEV_STUB_LOG"
case "$1" in
  --version|version) echo "ddev version v1.25.4";;
  describe) echo '{"raw":{"status":"running","primary_url":"https://bed.ddev.site"}}';;
  config)
    php=""; for a in "$@"; do case "$a" in --php-version=*) php="${a#--php-version=}";; esac; done
    mkdir -p .ddev && printf 'name: bed\nphp_version: "%s"\n' "$php" > .ddev/config.yaml;;
  composer)
    case "$*" in
      *create-project*)
        spec=""; for a in "$@"; do case "$a" in drupal/recommended-project:*) spec="${a#drupal/recommended-project:}";; esac; done
        case "$spec" in ^12*|12.0.x-dev) v=12.0.0-beta2;; ^11*) v=11.4.10;; *) v="$spec";; esac
        mkdir -p web/core/lib vendor
        printf '{"name":"drupal/recommended-project"}\n' > composer.json
        printf '{"packages":[{"name":"drupal/core","version":"%s"}],"packages-dev":[]}\n' "$v" > composer.lock
        printf "<?php\nclass Drupal {\n  const VERSION = '%s';\n}\n" "$v" > web/core/lib/Drupal.php
        : > vendor/autoload.php;;
      *reinstall*drupal/core*) mkdir -p web/core/tests;;
    esac;;
esac
exit 0
STUB
chmod +x "$FAKE/docker" "$FAKE/ddev"
export DDEV_STUB_LOG="$LOG"
up() { : > "$LOG"; env PATH="$FAKE:$PATH" CLAUDE_PLUGIN_ROOT="$T_REPO" "$@" > "$T_TMP/up.json" 2> "$T_TMP/up.err"; echo "$?" > "$T_TMP/rc"; }
freeze() {   # freeze SUBJECT ROOT -> the T=12 draft plan, frozen in ROOT's lock
  env CLAUDE_PLUGIN_ROOT="$T_REPO" DRUPILOT_TARGET_MAJOR=12 DRUPILOT_ALLOW_PRERELEASE=true \
    "$T_SH" "$T_REPO/scripts/analysis/upgrade-path.sh" --subject "$1" --phase draft --root "$2" --freeze --json > /dev/null 2>&1
}

# --- a loose subject, its T=12 draft plan frozen in <name>-d12 ----------------
SUBJ="$T_TMP/d11_for_d12"; cp -R "$T_REPO/tests/fixtures/d11_for_d12" "$SUBJ"
ROOT="$T_TMP/d11_for_d12-d12"
freeze "$SUBJ" "$ROOT"
assert_eq "the T=12 draft plan is frozen in the -d12 root" "$(plan_get .target.major "$ROOT")" "12"
BED="$(plan_get .target.bed_core "$ROOT")"; PHPF="$(plan_get .php.final "$ROOT")"
assert_eq "  a pre-release bed core, on the target's own PHP" \
  "$(printf '%s' "$BED" | grep -c -- '-' || true)|$PHPF" "1|$(target_get 12 .php_defaults.env)"
up DRUPILOT_TARGET_MAJOR=12 "$T_SH" "$T_REPO/scripts/env/ddev-up.sh" --subject "$SUBJ" --name d11-for-d12-d12 --docroot web --json
assert_eq "ddev-up.sh: exit 0" "$(cat "$T_TMP/rc")" "0"
assert_match "  a drupal12 project on the plan's PHP, not the Drupal 11 default" "$(grep '^config ' "$LOG")" \
  "--project-type=drupal12 --docroot=web --php-version=$PHPF\$"
assert_eq "  created with the plan's exact core, with no --stability" \
  "$(grep 'create-project' "$LOG" | grep -c -- "drupal/recommended-project:$BED\$" || true)|$(grep -c -- '--stability' "$LOG" || true)" "1|0"
assert_eq "  no drush, drupal/core reinstalled from source" \
  "$(grep -c 'require.*drush' "$LOG" || true)|$(grep -c 'reinstall drupal/core --prefer-source' "$LOG" || true)" "0|1"
assert_eq "  the JSON names the bed's PHP and core" "$(jq -r '[.php_version, .drupal_target] | join("|")' "$T_TMP/up.json")" "$PHPF|^12"

# --- Upgrade Status on that bed: skipped on purpose, no drush call -------------
: > "$LOG"
( cd "$ROOT" && env PATH="$FAKE:$PATH" CLAUDE_PLUGIN_ROOT="$T_REPO" "$T_SH" "$T_REPO/scripts/analysis/run-upgrade-status.sh" \
    --module d11_for_d12 > /dev/null 2> "$T_TMP/us.err" ); rc=$?
assert_eq "run-upgrade-status.sh on the Drupal 12 bed: exit 0, no ddev drush call" "$rc|$(grep -c 'drush' "$LOG" || true)" "0|0"
assert_match "  it says why" "$(cat "$T_TMP/us.err")" 'Skipping Upgrade Status: no drush release installs on this test-bed \(toolchain cell 12\)'

# --- the same root again, from its frozen plan alone ---------------------------
rm -rf "$ROOT/.ddev" "$ROOT/web" "$ROOT/vendor" "$ROOT/composer.json" "$ROOT/composer.lock"
up "$T_SH" "$T_REPO/scripts/env/ddev-up.sh" --dir "$ROOT" --docroot web
assert_eq "no target in the environment: the frozen plan's major and PHP" \
  "$(cat "$T_TMP/rc")|$(grep -c -- "--project-type=drupal12 --docroot=web --php-version=$PHPF" "$LOG" || true)" "0|1"

# --- an explicit core pin of the pre-release major ------------------------------
R2="$T_TMP/pin-dev"; freeze "$SUBJ" "$R2"
up DRUPILOT_DRUPAL_TARGET=12.0.x-dev "$T_SH" "$T_REPO/scripts/env/ddev-up.sh" --dir "$R2" --docroot web
assert_eq "DRUPILOT_DRUPAL_TARGET=12.0.x-dev: created with it, no --stability" \
  "$(cat "$T_TMP/rc")|$(grep -c -- 'drupal/recommended-project:12.0.x-dev$' "$LOG" || true)|$(grep -c -- '--stability' "$LOG" || true)" "0|1|0"

# --- refusals, before any ddev config -------------------------------------------
R3="$T_TMP/pin-11"; freeze "$SUBJ" "$R3"
up DRUPILOT_DRUPAL_TARGET=^11 "$T_SH" "$T_REPO/scripts/env/ddev-up.sh" --dir "$R3" --docroot web
assert_eq "a pin that does not admit the plan's Drupal 12: exit 1, no ddev config" \
  "$(cat "$T_TMP/rc")|$(grep -c '^config ' "$LOG" || true)" "1|0"
assert_match "  the message names the pin" "$(cat "$T_TMP/up.err")" "DRUPILOT_DRUPAL_TARGET '\^11' does not admit Drupal 12"
SITE="$T_TMP/site"; mkdir -p "$SITE/web/core/lib"
printf '{"name":"x/site"}\n' > "$SITE/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$SITE/web/core/lib/Drupal.php"
up DRUPILOT_TARGET_MAJOR=12 "$T_SH" "$T_REPO/scripts/env/ddev-up.sh" --dir "$SITE" --docroot web
assert_eq "a root whose core is Drupal 11, for Drupal 12: exit 1, no ddev config" \
  "$(cat "$T_TMP/rc")|$(grep -c '^config ' "$LOG" || true)" "1|0"
assert_match "  the message says why" "$(cat "$T_TMP/up.err")" "has Drupal 11.4.8, an older major than the target of this port, Drupal 12"

# --- a Drupal 11 bed, as before -------------------------------------------------
LW="$T_TMP/legacy_widgets"; cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$LW"
up "$T_SH" "$T_REPO/scripts/env/ddev-up.sh" --subject "$LW" --name lw-d11 --docroot web
assert_eq "Drupal 11: exit 0, a drupal11 project on the target's default PHP" \
  "$(cat "$T_TMP/rc")|$(grep -c -- "--project-type=drupal11 --docroot=web --php-version=$(target_get 11 .php_defaults.env)\$" "$LOG" || true)" "0|1"
assert_eq "  ^11, drush required, no reinstall from source" \
  "$(grep 'create-project' "$LOG" | grep -c -- 'drupal/recommended-project:^11$' || true)|$(grep -c 'require.*drush' "$LOG" || true)|$(grep -c 'reinstall' "$LOG" || true)" "1|1|0"
t_done
