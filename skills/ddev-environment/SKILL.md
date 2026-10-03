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
  extensions, coder, drush 13, drupal/core-dev matching core for PHPUnit,
  optional upgrade_status), and writes
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
  the `php-target-tuning` skill for the PHP 8.5 caveat (it needs Drupal 11.3 or
  later).

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
say that PHP 8.5 needs Drupal 11.3 or later and that no Rector `php85` set is
assumed; `ddev-up.sh` warns when the core it creates may be older (the
lock-pinned core, else the lowest minor the Drupal target admits) and when the
installed core is older.

## 3. Create / start the Drupal 11 DDEV project

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/ddev-up.sh" \
  --php "<target>" --subject "<path/to/module-or-theme>" --name "<ddev_name>" --docroot web
```

Pass `--name` explicitly (e.g. `<machine_name>-d11`); otherwise the DDEV project is
named after the test-bed directory. stdout carries only the optional `--json` summary
(`{project_dir, project_name, php_version, primary_url, drupal_target}`); every log,
the preflight report and the ddev/composer output go to stderr.

What `ddev-up.sh` does (idempotently):

- `ddev config --project-type=drupal11 --docroot=web --php-version=$(resolve_php_target)`
  only if the project is not already configured.
- `ddev start`.
- `ddev composer create-project drupal/recommended-project:^11` (`ddev composer create` on DDEV < 1.24.2) only when there is no
  `composer.json` yet (creating a project would overwrite an existing one).
  In deterministic mode a core release already frozen in the root's lockfile is
  created exactly (`drupal/recommended-project:<version>`), and a cached base core
  (`DRUPILOT_CORE_CACHE`, default `auto`) is copied into the empty root instead
  when one matches, then verified with `ddev composer install`.
- `ddev composer install` when `composer.json` exists but `vendor/` does not
  (e.g. after `/drupilot-clean --level vendor`).
- Marks a root it built as a drupilot test-bed (`drupilot_testbed` in its
  `.drupilot.json`), which is what lets `/drupilot-clean` remove it later.
- Ensures `drush/drush:^13` is present (D11 requires Drush 13).
- **Reads the generated `.ddev/config.yaml`** for the real project name and
  hostnames instead of guessing `*.ddev.site`.

It skips work that is already done and reports the state. If it reports the
project is already up, do not restart it.

After it runs, confirm the environment with the shared helpers (these come from
`common.sh`): `find_drupal_root` to locate the Drupal root, `ddev_running` to
confirm the container is up (read-only: it reads `ddev describe`, so it never
starts a stopped project — never probe with `ddev exec`, which does), and
`drupal_runner` which echoes `ddev exec` when the environment is up (empty
otherwise) — that prefix is what every toolchain command should use. Scripts
that run the toolchain call `ddev_ensure_running` first, which starts a stopped
project explicitly and logs it. The analysis scripts (Rector, PHPStan, PHPCS —
the `analyze` profile does not require Docker) use `ddev_ensure_running_or_host`
instead: when DDEV cannot start (e.g. the Docker daemon is down) they warn and
run the host `vendor/bin` tool rather than failing. PHPUnit, the toolchain
install and the core matrix still require DDEV.

## 4. Place the subject module/theme

drupilot uses the **`recommended-project` layout**: Drupal at the repo root, the
subject physically under `web/modules/custom/<name>` (modules) or
`web/themes/custom/<name>` (themes). `subject_type` (from `common.sh`) tells you
module vs theme. A LOOSE checkout (a module/theme NOT already inside a Drupal
site) is never scaffolded on top of; two scripts handle placement, so the loose
checkout stays pristine. First resolve WHERE the test-bed and the subject live
(read-only, like `core-strategy.sh`):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/resolve-workspace.sh" --subject "<dir>" --json
```

It emits `{subject_src, machine_name, type, loose, drupal_root, drupal_root_exists,
subject_dest_rel, subject_dest_abs, placement, already_placed}`. For a loose
subject it targets a sibling Drupal root `<parent>/<name>-d11` (or
`DRUPILOT_WORKSPACE_DIR`); for a module already inside a Drupal root it reports
`loose:false` and the existing layout is kept (full back-compat). `ddev-up.sh`
consults this resolver internally, so the subject is never scaffolded on top of.
Its `layout` field: `in-place` (core installed; `in_place_ok:false` = the site
is on Drupal 10, an in-place port needs Drupal 11 — set `DRUPILOT_WORKSPACE_DIR`
outside the site for a test-bed), `project-no-core` (a module of a Composer
project checkout without installed core, e.g. a monorepo clone: test-bed
`<parent>/<project>-d11`, outside the repository), `repo-subdir` (a module in a
git repository that is not a Drupal project: `<parent of the repo>/<name>-d11`)
or `standalone`. A sub-directory of a repository is never moved (`move`
becomes `copy`; a `symlink` is kept and edits the repository directly), and a copy gets a git baseline (`git_seed_baseline`): its
local patch is module-relative, plus a `-repo.patch` relative to the repository
root.

Then, AFTER Drupal is created (`ddev composer create-project` needs an almost-empty root),
place the subject into `web/<modules|themes|profiles>/custom/<name>`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/place-subject.sh" --subject "<dir>" \
  [--placement move|symlink|copy] [--dry-run] [--yes]
```

It is idempotent (detect-and-skip when already placed), persists
`DRUPILOT_WORKSPACE_DIR` + `DRUPILOT_PLACEMENT` to `.drupilot.json`, and runs
`ensure-gitignore.sh` on the new root. Exit code 2 means the Drupal root does not
exist yet — run `ddev-up.sh` first.

Origin hygiene: before placing, it records the origin repo's `git status` with
`scripts/env/origin-hygiene.sh --snapshot` (hidden state keyed by the Drupal root;
for an in-place subject run `origin-hygiene.sh --snapshot --subject <dir> --placement
in-place` yourself). `copy` leaves `.ddev/`, `vendor/`, `.drupilot*`, `.phpstan-cache/`
(top level) and `node_modules/` (anywhere) behind and drops symlinks escaping the
checkout (`--no-exclude` for a verbatim copy). The subject-side `.drupilot.json` is
hidden via the subject repo's local `.git/info/exclude`. `origin-hygiene.sh --check
--json` later reports drupilot-attributable residue (report-only; it never deletes).
The resolver's `residue` / `residual_ddev` fields flag leftovers in the checkout
(e.g. an untracked `.ddev/` from an old module-at-root sandbox) — surface them, never
delete them.

`ddev-drupal-contrib` also supports a "module at the repo root" layout where it
symlinks the root into `web/modules/custom`. drupilot does NOT use that layout —
with no `*.info.yml` at the repo root, `symlink-project` would derive the name
from the DDEV project and create a spurious `web/modules/custom/<project>/` of
symlinks back to the project's `composer.json`/`.ddev`. `ddev-add-ons.sh` detects
the recommended-project layout and disables that hook automatically, keeping the
add-on's wrapper commands and testing `web_environment`.

## 5. Install add-ons

```bash
# contrib add-on always; Selenium only when FunctionalJavascript tests exist.
# <drupal_root>: the resolve-workspace.sh drupal_root (the test-bed), not the
# original checkout.
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/ddev-add-ons.sh" --contrib --selenium --dir "<drupal_root>"
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

Install it with the deterministic installer — never with a hand-written
`ddev composer require --dev ...` (a fresh resolve after a broken upstream release
silently installs a toolchain that crashes):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/install-toolchain.sh" --dir "<drupal_root>" --json
#   --with-upgrade-status   also drupal/upgrade_status
#   --dry-run               print the resolved specs, run nothing
#   --smoke-only            only re-check an installed toolchain
#   --source reference      force the known-good set (repair path)
```

What it installs (`config/defaults.json` `.packages.*`):

- `palantirnet/drupal-rector` (the `palantirnet/` namespace is current;
  `palantirnet/drupal8-rector` is obsolete) and its engine `rector/rector`
  (range `^2.0 <2.6.2`: drupal-rector 0.21.x throws `Could not detect twig set.`
  with rector/rector >= 2.6.2)
- `phpstan/phpstan`, `phpstan/extension-installer`, `mglaman/phpstan-drupal`,
  `phpstan/phpstan-deprecation-rules`
- `drupal/coder` at `DRUPILOT_CODER_CONSTRAINT` (default `^8.3` → PHPCS 3.x, the
  safe default; `^9.0` → PHPCS 4.x)
- `drupal/core-dev` (PHPUnit + the Drupal test dependencies) — **required for any
  test run**: `drupal/recommended-project` ships no `vendor/bin/phpunit`, and
  without it `run-phpunit.sh` records `not-verified-blocked` and exits 2. It must
  MATCH the installed core, so it is derived with `core_dev_requirement`
  (`common.sh`; e.g. `drupal/core-dev:~11.4.8`), never a fixed range
- optional `drupal/upgrade_status`
- `drush/drush:^13` is NOT installed here — `ddev-up.sh` requires it (as a regular
  dependency).

Version source (`--source`, default `DRUPILOT_TOOLCHAIN_SOURCE=auto`): in
deterministic mode the project lock when it pins the whole known-good set,
otherwise the shipped **known-good reference** `config/toolchain-reference.json`
as a whole (a partial lock is never mixed with it); with
`DRUPILOT_DETERMINISTIC=false`, the `.packages` ranges. If the pinned set does not
resolve against the project, it retries once with the ranges. It allows the
`phpstan/extension-installer` and `dealerdirect/phpcodesniffer-composer-installer`
Composer plugins, runs one `ddev composer require --dev -W`, then:

- a **smoke test** (`rector_smoke` in `common.sh`): a Rector dry-run of a trivial
  file with `Drupal10SetList::DRUPAL_10` plus `phpstan --version`, through DDEV;
- `lock-sync.sh --dir <root>`, so the exact toolchain (including `rector/rector`
  and `drupal/core-dev`) is frozen in the lock.

Exit codes: `0` ok · `1` Composer failure · `2` gate (DDEV not running) · **`3` the
toolchain is installed but broken** — the diagnostic prints installed vs known-good
versions and the fix (`--source reference`). Do not assess or port on a toolchain
that failed the smoke test.

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

**Reproducibility.** `install-toolchain.sh` already re-syncs the lock
(`lock-sync.sh`) after installing, and reuses the lock on later runs, so the same
project converges on the same toolchain; `ddev-up.sh` and `ddev-add-ons.sh` call
`lock-sync.sh` for core and add-ons. `DRUPILOT_DETERMINISTIC=false` resolves the
ranges fresh and refreshes the lock.

## 7. Write the toolchain config from templates

Templates live in `${CLAUDE_PLUGIN_ROOT}/templates/` and use `{{PLACEHOLDER}}`
tokens. Render them with the deterministic renderer — never by hand-substituting
(no `sed` one-liners, no `envsubst`):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/render-templates.sh" --root "<drupal_root>" \
  --subject-path "web/modules/custom/<machine_name>" --json   # add --dry-run to preview
```

It substitutes the tokens literally (`render_template` in `common.sh`, shared with
`run-rector.sh`), validates every output before writing it (no token left;
`xmllint --noout` — or `phpcs --standard=<file> -e` — for `phpcs.xml.dist`; `php -l`
for `rector.php`), and is idempotent: missing -> `written`, identical ->
`unchanged`, different -> `differs` (diff on stderr, file untouched, exit 3) unless
`--force`, which backs the old copy up to `<drupal_root>/.drupilot/backups/` first.
A copy drupilot generated from an OLDER template generation (its `drupilot — <file>`
header without the current `drupilot-template-version: N` marker) is backed up and
regenerated automatically (`upgraded`), so the broken pre-0.9.0 `phpcs.xml.dist` /
`phpstan.neon` heal even in an autonomous run. Bump a template's marker when existing
projects must receive a change.
A file that fails validation is reported `invalid` and never written. Do not
clobber a file the user already tuned without saying so: on `differs`, show the
diff and ask before re-running with `--only <name> --force`. `--only
rector,phpstan,phpcs,testing` limits the set; `--set KEY=VALUE` overrides a token.

| Template | Destination (Drupal root) | Key placeholders |
|---|---|---|
| `rector.php.tmpl` | `rector.php` | `{{PHP_TARGET}}`, `{{PHP_SET}}`, `{{SUBJECT_PATH}}` |
| `phpstan.neon.tmpl` | `phpstan.neon` | `{{PHPSTAN_LEVEL}}`, `{{SUBJECT_PATH}}` |
| `phpcs.xml.dist.tmpl` | `phpcs.xml.dist` | `{{SUBJECT_PATH}}` |
| `ddev-config.yaml.tmpl` | (reference for `.ddev/config.yaml`) | `{{PROJECT_NAME}}`, `{{PHP_TARGET}}` |
| `ddev-web-environment.yaml.tmpl` | `.ddev/config.testing.yaml` (separate file) | — |

`ddev-config.yaml.tmpl` is reference only (`ddev-up.sh` configures the project);
`render-templates.sh` renders the other four.

`{{SUBJECT_PATH}}` is the in-docroot path, e.g. `web/modules/custom/foo`.
`{{PHP_TARGET}}` = `resolve_php_target`; `{{PHPSTAN_LEVEL}}` =
`DRUPILOT_PHPSTAN_LEVEL` (default 2 for Phase 1). `{{WEBDRIVER_HOST}}` (read
from `.ddev/docker-compose.selenium-chrome.yaml`, default `selenium-chrome:4444`)
is still accepted by `--set` but no current template uses it.
The generated `phpstan.neon` intentionally has no `drupal: drupal_root:` block:
phpstan-drupal >= 1.3 discovers the root itself and deprecates that parameter.

Write the testing `web_environment:` to a SEPARATE `.ddev/config.testing.yaml` so
it merges with what the add-ons already provide: ddev-drupal-contrib
(`SIMPLETEST_DB`, `SIMPLETEST_BASE_URL=http://web`, `BROWSERTEST_*`, `DTT_*`)
and the Selenium add-on (`MINK_DRIVER_ARGS_WEBDRIVER` with `"w3c":true`,
`DRUPAL_TEST_WEBDRIVER_*`). The template adds only
`SYMFONY_DEPRECATIONS_HELPER=disabled`. It deliberately does NOT set
`MINK_DRIVER_ARGS_WEBDRIVER`: DDEV loads `config.testing.yaml` after the add-on's
`config.selenium-standalone-chrome.yaml`, so an override replaces the add-on's
working value, and Drupal 11.4's `WebDriverTestBase::getMinkDriverArgs()` forces
`w3c` to false when the value omits it (deprecated in drupal:11.4.0,
https://www.drupal.org/node/3460567) — the Selenium image then refuses every
FunctionalJavascript session. A copy rendered by an older template is upgraded
automatically (template marker). If you ever hand-write a MINK value, include
`"w3c":true` and keep the escaped-quote / YAML single-quote form: DDEV wraps each
web_environment value in double quotes WITHOUT escaping the inner quotes, so a
raw JSON value produces invalid compose YAML ("did not find expected key") and
`ddev start` fails. When the JSON says `restart_needed: true`, run `ddev restart`.

## 8. Verify and report

When done, confirm and report (in English): project name, `type: drupal11`,
docroot `web`, effective `php_version`, add-ons installed, toolchain packages
present, and which config files were written vs already present. If anything was
already in place, say "already configured — skipped". Hand off to the
`viability-assessment`, `minimal-port` or `test-adaptation` skills as appropriate.

## Gotchas

- `ddev composer create-project` overwrites — only run it when there is no
  `composer.json`. `ddev-up.sh` already guards this; do not call it manually
  inside a populated project.
- The installed DDEV may not provide a PHP 8.5 image; `ddev-up.sh` warns about it.
  Fall back to `8.3` rather than failing the whole setup.
- The webdriver hostname differs by add-on version — never hardcode
  `selenium-chrome:4444`; read the generated YAML / add-on output.
- Rector and PHPStan need the Drupal **core tree present** (no database), so they
  work right after `ddev composer create-project`. `upgrade_status` additionally needs an
  **installed** site (DB) — defer it until `ddev drush site:install` has run.
- All status messages go to stderr via the `log_*` helpers; stdout stays clean
  for parseable payloads (e.g. `detect-php.sh --json`).
