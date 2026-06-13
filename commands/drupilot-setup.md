---
description: Provision a Drupal 11 DDEV environment for porting a module/theme - start DDEV, install the contrib (+ Selenium) add-ons, install the Composer dev toolchain (drupal-rector, PHPStan + extensions, coder, drush 13), and write rector.php / phpstan.neon / phpcs.xml.dist / testing web_environment from templates. Idempotent. Use for "/drupilot-setup", "set up the environment", "spin up DDEV for this module".
argument-hint: "[subject-path] [--php X.Y]"
allowed-tools: Bash, Read, Skill, Task
---

# drupilot — setup (DDEV environment + dev toolchain)

You provision the full Drupal 11 environment so the user never has to assemble a manual
LAMP stack. **English only.** Everything here is **idempotent**: detect-and-skip work
that is already done, and report state instead of redoing it.

## Step 1 — Gate: setup requirements

This step touches Docker, so gate the `setup` profile first. If a hard requirement is
missing, the script prints an actionable report and exits non-zero — in that case
**stop with no side effects** and tell the user to run `/drupilot-doctor`:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile setup`

If that command exited non-zero (missing Docker/daemon/DDEV), do not proceed: show the
report and recommend `/drupilot-doctor`.

## Step 2 — Resolve subject and PHP target

Determine the subject directory (`$1` if it is a Drupal extension, else detect from the
cwd), its type (module/theme), and the effective PHP target:

!`bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; SUBJ="${1:-$PWD}"; [[ -d "$SUBJ" ]] || SUBJ="$PWD"; printf "subject_dir=%s\n" "$SUBJ"; printf "machine_name=%s\n" "$(subject_machine_name "$SUBJ" 2>/dev/null || echo -)"; printf "subject_type=%s\n" "$(subject_type "$SUBJ" 2>/dev/null || echo -)"; printf "php_target=%s\n" "$(resolve_php_target)"; printf "php_unconfirmed=%s\n" "$(php_target_unconfirmed "$(resolve_php_target)" && echo yes || echo no)"; printf "drupal_target=%s\n" "$(resolve_drupal_target)"' _ "$1"`

If a `--php X.Y` flag is present in `$ARGUMENTS`, honor it by exporting
`DRUPILOT_PHP_TARGET` for the subsequent scripts. If the chosen target is **unconfirmed**
(e.g. 8.5), warn clearly and keep the safe default unless the user insists — never claim
an unconfirmed version is supported.

## Step 3 — State the plan, then do the work via the ddev-environment skill

Before acting, state in English what you will do: create/start the DDEV Drupal 11
project, install add-ons, install the Composer dev toolchain, place/symlink the subject
under `web/modules/custom` or `web/themes/custom`, and write the tool configs. Note that
the heavy steps (composer create/require, add-on installs) may run in the background.

Use the **ddev-environment** skill for the operating procedure and gotchas, then run the
leaf scripts in order. Each is idempotent.

**Subject placement (important).** drupilot uses the `recommended-project` layout: Drupal
lives at the project root and the subject lives under `web/modules/custom/<machine_name>`
(or `web/themes/custom/...`). `ddev composer create` needs an almost-empty root, so if the
subject was extracted INTO the project root (e.g. from a downloaded tarball), or sits in a
subdirectory next to a tarball, move those aside FIRST (e.g. to a sibling staging dir),
let 3a create Drupal, THEN move the extension into `web/modules/custom/<machine_name>` and
delete the staging copy. `ddev-up.sh` aborts with guidance when the root is not clean, so
do this placement before (re-)running it.

### 3a — Bring up the DDEV Drupal 11 project

Run this yourself via the Bash tool, substituting `<subject_dir>` with the resolved
subject directory from Step 2's context (do not run it verbatim):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/ddev-up.sh" --subject "<subject_dir>" --docroot web
```

This configures `--project-type=drupal11 --docroot=web --php-version=$(resolve_php_target)`,
starts DDEV, runs `ddev composer create drupal/recommended-project:^11` when there is no
composer.json, ensures `drush:^13`, and reads the generated `.ddev/config.yaml` rather
than assuming hostnames/images. It skips if the project is already configured/running.

### 3b — Install the add-ons

Run this yourself via the Bash tool once 3a has the project up:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/ddev-add-ons.sh" --contrib --selenium
```

Installs `ddev/ddev-drupal-contrib` and (for JS tests) `ddev/ddev-selenium-standalone-chrome`
(v2), then restarts. It detects already-installed add-ons and soft-warns (does not fail)
if Selenium cannot install — note that FunctionalJavascript tests will be skipped in
that case.

### 3c — Install the Composer dev toolchain

Inside the DDEV project, install the dev dependencies using the constraints from
`config/defaults.json` (`.packages.*` and `DRUPILOT_CODER_CONSTRAINT`): drupal-rector,
phpstan ^2.1 + extension-installer + phpstan-drupal ^2.0 + phpstan-deprecation-rules
^2.0, drupal/coder (at the configured constraint), and optionally drupal/upgrade_status.
Read the constraints first, then run `ddev composer require --dev ...`. This is
idempotent — Composer is a no-op when the constraints are already satisfied.

drupal/coder ships a Composer plugin (`*/phpcodesniffer-composer-installer`) that
auto-registers the PHPCS `installed_paths`. Allow that plugin, let it run, then just
verify with `ddev exec vendor/bin/phpcs -i` (it must list `Drupal` and `DrupalPractice`).
If you set `installed_paths` MANUALLY, register all THREE paths coder's Drupal standard
references — `coder_sniffer`, `phpcs-variable-analysis` and `slevomat/coding-standard` —
not just `coder_sniffer`, or phpcs aborts with "Referenced sniff ... does not exist":
`ddev exec vendor/bin/phpcs --config-set installed_paths vendor/drupal/coder/coder_sniffer,vendor/sirbrillig/phpcs-variable-analysis,vendor/slevomat/coding-standard`

## Step 4 — Write the tool configs from templates

Write the configuration files at the Drupal root by substituting the template
placeholders (`{{PHP_TARGET}}`, `{{DRUPAL_TARGET}}`, `{{CODER_CONSTRAINT}}`,
`{{PHPSTAN_LEVEL}}`, `{{SUBJECT_PATH}}`, `{{PROJECT_NAME}}`, `{{WEBDRIVER_HOST}}`)
with the resolved values. `{{SUBJECT_PATH}}` is the in-tree
path (e.g. `web/modules/custom/<machine_name>`). Use the templates:

- `@${CLAUDE_PLUGIN_ROOT}/templates/rector.php.tmpl` -> `<drupal_root>/rector.php`
- `@${CLAUDE_PLUGIN_ROOT}/templates/phpstan.neon.tmpl` -> `<drupal_root>/phpstan.neon`
- `@${CLAUDE_PLUGIN_ROOT}/templates/phpcs.xml.dist.tmpl` -> `<drupal_root>/phpcs.xml.dist`
- `@${CLAUDE_PLUGIN_ROOT}/templates/ddev-web-environment.yaml.tmpl` -> write to a
  SEPARATE `<drupal_root>/.ddev/config.testing.yaml` (do NOT merge into the generated
  `config.yaml`). ddev-drupal-contrib already provides `SIMPLETEST_DB`,
  `SIMPLETEST_BASE_URL=http://web`, `BROWSERTEST_*` and `DTT_*` in its
  `config.contrib.yaml`; this file only adds `MINK_DRIVER_ARGS_WEBDRIVER` and
  `SYMFONY_DEPRECATIONS_HELPER`, so it merges cleanly instead of clobbering them.

`{{WEBDRIVER_HOST}}` is the Selenium service host:port — **read the generated
`.ddev/docker-compose.selenium-chrome.yaml`** for it (typically `selenium-chrome:4444`)
instead of assuming. Keep the MINK value's escaped-quote / single-quote form from the
template verbatim — DDEV does not escape inner quotes when it serializes
`web_environment`, so an unescaped JSON value breaks `ddev start`. After writing the file,
run `ddev restart`. Do not overwrite a config the user has hand-edited without saying so;
if a file already exists and differs, show the diff and confirm before replacing.

## Step 5 — Report

Print the final state: DDEV project name and status, PHP target (flag unconfirmed
targets), which add-ons are installed, the toolchain versions, and which config files
were written or left untouched. Recommend the next step: `/drupilot-assess`.

For long-running batches, prefer background execution and notify on completion; do not
block the session. If you delegate the whole environment build, use the Task tool with
the **drupal-port-orchestrator** subagent, but for a plain setup the scripts above are
enough.
