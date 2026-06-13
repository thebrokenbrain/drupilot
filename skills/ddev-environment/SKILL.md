---
name: ddev-environment
description: >-
  Use this skill when setting up or verifying the DDEV-based Drupal 11
  development environment for a module or theme port — i.e. when running
  /drupilot-setup, when a command needs a running Drupal 11 site (tests,
  upgrade_status), or when the user asks to "spin up DDEV", "install the
  toolchain", "add Selenium", or "configure rector/phpstan/phpcs". It creates
  and starts a Drupal 11 DDEV project, installs the ddev-drupal-contrib and
  Selenium add-ons, installs the Composer dev toolchain (Rector, PHPStan + Drupal
  extensions, coder, drush 13, optional upgrade_status), and writes
  rector.php / phpstan.neon / phpcs.xml.dist plus the testing web_environment from
  templates parameterized by DRUPILOT_PHP_TARGET. Idempotent: it detects what is
  already in place and only does the missing work.
allowed-tools: Bash, Read, Write, Edit
---

# DDEV Drupal 11 environment

Operating knowledge for standing up the full Drupal 11 environment with DDEV.
DDEV provides web + database + chromedriver over Docker; the user never has to
set up a manual LAMP stack. Everything here is driven through the drupilot leaf
scripts under `${CLAUDE_PLUGIN_ROOT}/scripts/env/` and the templates under
`${CLAUDE_PLUGIN_ROOT}/templates/`. Prefer those scripts over ad-hoc `ddev`
commands so behavior stays idempotent, gated and consistent.

## 0. Golden rules

- **Gate first.** Setup needs Docker (daemon up) + DDEV. Always run preflight for
  the `setup` profile before touching anything; abort cleanly if a hard
  requirement is missing — never start work that cannot finish.
- **Idempotent.** Detect-and-skip. If the project is already configured/running,
  if an add-on is already installed, or if a config file already exists with the
  right values, do not redo it — report state instead.
- **Read the generated YAML.** Do not assume hostnames, the PHP image, or the
  webdriver host. After DDEV writes `.ddev/config.yaml`, read it back for the real
  values (project name, `php_version`, webdriver service host).
- **PHP target drives everything.** The DDEV `php_version`, the Rector PHP set,
  the PHPStan level expectations and some PHPCS sniffs all derive from
  `DRUPILOT_PHP_TARGET` (default `8.3`). Resolve it with `resolve_php_target`; see
  the `php-target-tuning` skill for the 8.5 runtime-detection caveat.

## 1. Gate the operation

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile setup
```

Exit `0` = ready. Exit `2` = a hard requirement (Docker daemon / DDEV) is
missing; show the report and stop with no side effects. If the user wants to fix
it, offer assisted install:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/install-deps.sh" docker ddev
```

`install-deps.sh` confirms before installing (unless `--yes` /
`DRUPILOT_ASSUME_YES=1`), uses the OS package manager or the official DDEV/Docker
installers, and only prints (never forces) the Docker group-add + re-login
guidance.

## 2. Detect the effective PHP target

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/detect-php.sh" --json
# -> {host_php, ddev_php, target, supported, unconfirmed}
```

Use `target` for the rest of the flow. If `unconfirmed` is true (i.e. 8.5),
surface the caveat and prefer the default `8.3` unless the user explicitly
insists — do not claim "8.5 is supported".

## 3. Create / start the Drupal 11 DDEV project

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/ddev-up.sh" \
  --php "<target>" --subject "<path/to/module-or-theme>" --docroot web
```

What `ddev-up.sh` does (idempotently):

- `ddev config --project-type=drupal11 --docroot=web --php-version=$(resolve_php_target)`
  only if the project is not already configured.
- `ddev start`.
- `ddev composer create drupal/recommended-project:^11` only when there is no
  `composer.json` yet (creating a project would overwrite an existing one).
- Ensures `drush/drush:^13` is present (D11 requires Drush 13).
- **Reads the generated `.ddev/config.yaml`** for the real project name and
  hostnames instead of guessing `*.ddev.site`.

It skips work that is already done and reports the state. If it reports the
project is already up, do not restart it.

After it runs, confirm the environment with the shared helpers (these come from
`common.sh`): `find_drupal_root` to locate the Drupal root, `ddev_running` to
confirm the container is up, and `drupal_runner` which echoes `ddev exec` when
the environment is up (empty otherwise) — that prefix is what every toolchain
command should use.

## 4. Place the subject module/theme

drupilot uses the **`recommended-project` layout**: Drupal at the repo root, the
subject physically under `web/modules/custom/<name>` (modules) or
`web/themes/custom/<name>` (themes). `subject_type` (from `common.sh`) tells you
module vs theme. Because `ddev composer create` needs an almost-empty root, place
the subject AFTER Drupal is created: if it was extracted into the project root or
sits next to a tarball, move those aside first, create Drupal, then move the
extension into `web/<modules|themes>/custom/<name>`.

`ddev-drupal-contrib` also supports a "module at the repo root" layout where it
symlinks the root into `web/modules/custom`. drupilot does NOT use that layout —
with no `*.info.yml` at the repo root, `symlink-project` would derive the name
from the DDEV project and create a spurious `web/modules/custom/<project>/` of
symlinks back to the project's `composer.json`/`.ddev`. `ddev-add-ons.sh` detects
the recommended-project layout and disables that hook automatically, keeping the
add-on's wrapper commands and testing `web_environment`.

## 5. Install add-ons

```bash
# contrib add-on always; Selenium only when FunctionalJavascript tests exist
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/ddev-add-ons.sh" --contrib --selenium
```

`ddev-add-ons.sh`:

- Installs `ddev/ddev-drupal-contrib` (isolated contrib/custom development) and,
  with `--selenium`, `ddev/ddev-selenium-standalone-chrome` (use **v2** for D11).
- Detects already-installed add-ons first (idempotent) via `ddev add-on list`.
- Runs `ddev restart` after installing.
- **Soft-warns** (does not fail) if Selenium cannot be installed — JS tests will
  simply be skipped with a clear message later.

Underlying commands for reference:

```bash
ddev add-on get ddev/ddev-drupal-contrib
ddev add-on get ddev/ddev-selenium-standalone-chrome
ddev restart
```

## 6. Install the Composer dev toolchain

Install **inside DDEV** (`ddev composer require --dev ...`). Constraints come from
`config/defaults.json` `.packages.*` — read them with `config_json` rather than
hardcoding versions:

- `palantirnet/drupal-rector` (the `palantirnet/` namespace is current;
  `palantirnet/drupal8-rector` is obsolete)
- `phpstan/phpstan:^2.1`, `phpstan/extension-installer`,
  `mglaman/phpstan-drupal:^2.0`, `phpstan/phpstan-deprecation-rules:^2.0`
- `drupal/coder` pinned by `DRUPILOT_CODER_CONSTRAINT` (default `^8.3` → PHPCS
  3.x, the safe default; `^9.0` → PHPCS 4.x)
- `drush/drush:^13`
- optional `drupal/upgrade_status`

coder ships a Composer plugin (`*/phpcodesniffer-composer-installer`) that
auto-registers PHPCS `installed_paths`. Allow it and just verify with `phpcs -i`.
If you set the paths MANUALLY, register all THREE that coder's Drupal standard
references — or phpcs aborts with "Referenced sniff ... does not exist":

```bash
ddev exec vendor/bin/phpcs --config-set installed_paths \
  vendor/drupal/coder/coder_sniffer,vendor/sirbrillig/phpcs-variable-analysis,vendor/slevomat/coding-standard
ddev exec vendor/bin/phpcs -i   # must list Drupal and DrupalPractice
```

With `phpstan/extension-installer` present, the phpstan-drupal and deprecation
rules autoload — no manual `includes:` needed.

## 7. Write the toolchain config from templates

Templates live in `${CLAUDE_PLUGIN_ROOT}/templates/` and use `{{PLACEHOLDER}}`
tokens; substitute with `sed`/`envsubst`. Write only if missing or out of date
(idempotent — do not clobber a file the user already tuned without saying so).

| Template | Destination (Drupal root) | Key placeholders |
|---|---|---|
| `rector.php.tmpl` | `rector.php` | `{{PHP_TARGET}}`, `{{SUBJECT_PATH}}` |
| `phpstan.neon.tmpl` | `phpstan.neon` | `{{PHPSTAN_LEVEL}}`, `{{SUBJECT_PATH}}` |
| `phpcs.xml.dist.tmpl` | `phpcs.xml.dist` | `{{SUBJECT_PATH}}` |
| `ddev-config.yaml.tmpl` | (reference for `.ddev/config.yaml`) | `{{PROJECT_NAME}}`, `{{PHP_TARGET}}` |
| `ddev-web-environment.yaml.tmpl` | `.ddev/config.testing.yaml` (separate file) | `{{WEBDRIVER_HOST}}` |

`{{SUBJECT_PATH}}` is the in-docroot path, e.g. `web/modules/custom/foo`.
`{{PHP_TARGET}}` = `resolve_php_target`; `{{PHPSTAN_LEVEL}}` =
`DRUPILOT_PHPSTAN_LEVEL` (default 2 for Phase 1). `{{CODER_CONSTRAINT}}` =
`DRUPILOT_CODER_CONSTRAINT`.

Write the testing `web_environment:` to a SEPARATE `.ddev/config.testing.yaml` so
it merges with what ddev-drupal-contrib already provides (`SIMPLETEST_DB`,
`SIMPLETEST_BASE_URL=http://web`, `BROWSERTEST_*`, `DTT_*`,
`DRUPAL_TEST_WEBDRIVER_*`). The template adds only `MINK_DRIVER_ARGS_WEBDRIVER`
(Drupal core's WebDriverTestBase) and `SYMFONY_DEPRECATIONS_HELPER=disabled`.
**Read `.ddev/docker-compose.selenium-chrome.yaml`** for the real webdriver host
(typically `selenium-chrome:4444`) instead of assuming it. Keep the template's
escaped-quote / YAML single-quote form for the MINK value verbatim: DDEV wraps
each web_environment value in double quotes WITHOUT escaping the inner quotes, so
a raw JSON value produces invalid compose YAML ("did not find expected key") and
`ddev start` fails. After writing the file, run `ddev restart`.

## 8. Verify and report

When done, confirm and report (in English): project name, `type: drupal11`,
docroot `web`, effective `php_version`, add-ons installed, toolchain packages
present, and which config files were written vs already present. If anything was
already in place, say "already configured — skipped". Hand off to the
`viability-assessment`, `minimal-port` or `test-adaptation` skills as appropriate.

## Gotchas

- `ddev composer create` overwrites — only run it when there is no
  `composer.json`. `ddev-up.sh` already guards this; do not call it manually
  inside a populated project.
- The PHP 8.5 DDEV image may not exist yet; `detect-php.sh` flags this. Fall back
  to `8.3` rather than failing the whole setup.
- The webdriver hostname differs by add-on version — never hardcode
  `selenium-chrome:4444`; read the generated YAML / add-on output.
- Rector and PHPStan need the Drupal **core tree present** (no database), so they
  work right after `ddev composer create`. `upgrade_status` additionally needs an
  **installed** site (DB) — defer it until `ddev drush site:install` has run.
- All status messages go to stderr via the `log_*` helpers; stdout stays clean
  for parseable payloads (e.g. `detect-php.sh --json`).
