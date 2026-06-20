---
description: Provision a Drupal 11 DDEV environment for porting a module/theme - start DDEV, install the contrib (+ Selenium) add-ons, install the Composer dev toolchain (drupal-rector, PHPStan + extensions, coder, drush 13), and write rector.php / phpstan.neon / phpcs.xml.dist / testing web_environment from templates. Idempotent. Use for "/drupilot-setup", "set up the environment", "spin up DDEV for this module".
argument-hint: "[subject-path] [--php X.Y]"
allowed-tools: Bash, Read, Skill, Task, AskUserQuestion
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

**Decision point — let the developer pick the PHP target (G4/G5).** The PHP
version pins the whole toolchain (Rector PHP set, PHPStan, PHPCS, DDEV
`php_version`), so make it an explicit choice with **AskUserQuestion** (header
"PHP target", default = the recommended option) *unless* a `--php X.Y` flag is in
`$ARGUMENTS`, or `DRUPILOT_PHP_TARGET` / `DRUPILOT_CHOICE_PHP_TARGET` is already
pinned, or the run is autonomous. Offer:

- **8.4 — recommended** (`php_support.recommended`) — current, supported on
  Drupal 11; the default.
- **8.3 — safe floor** (`DRUPILOT_PHP_TARGET` default) — conservative; supported
  on every Drupal 11 branch.
- **8.5 — unconfirmed** — **not** officially confirmed on any Drupal 11 branch;
  if chosen, warn clearly, detect at runtime, and never claim it is supported.

A `--php X.Y` flag always wins over the tab. Apply the choice by exporting
`DRUPILOT_PHP_TARGET` for the subsequent scripts **and** persisting it with
`prefs_set DRUPILOT_PHP_TARGET <X.Y>` so the rest of the flow (assess/port/test)
reuses it without re-asking. Never silently proceed on an unconfirmed target.

## Step 3 — State the plan, then do the work via the ddev-environment skill

Before acting, state in English what you will do: create/start the DDEV Drupal 11
project, install add-ons, install the Composer dev toolchain, place/symlink the subject
under `web/modules/custom` or `web/themes/custom`, and write the tool configs. Note that
the heavy steps (composer create/require, add-on installs) may run in the background.

Use the **ddev-environment** skill for the operating procedure and gotchas, then run the
leaf scripts in order. Each is idempotent.

**Subject placement (important).** drupilot uses the `recommended-project` layout: Drupal
lives at the project root and the subject lives under `web/modules/custom/<machine_name>`
(or `web/themes/custom/...`). A LOOSE checkout (a module/theme that is NOT already inside a
Drupal site) is never scaffolded on top of — that would intermix the module with Drupal's
own `composer.json`/`web/`/`vendor/`. Two scripts handle placement: resolve the workspace
first, then place the subject AFTER 3a creates Drupal (`composer create` needs an empty
root). Run the read-only resolver to decide WHERE:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/resolve-workspace.sh" --subject "<subject_dir>" --json
```

It emits `{subject_src, machine_name, type, loose, drupal_root, drupal_root_exists,
subject_dest_rel, subject_dest_abs, placement, already_placed}`. For a loose subject it
targets a sibling Drupal root `<parent>/<machine_name>-d11` (or `DRUPILOT_WORKSPACE_DIR`),
keeping the original checkout pristine; for a module already inside a Drupal root it reports
`loose:false` and the existing layout is kept (full back-compat). `ddev-up.sh` consults this
resolver internally, so the loose subject is never scaffolded on top of.

**Decision point — workspace layout for a loose checkout.** When `loose:true`, make the
placement an explicit choice with **AskUserQuestion** (header "Workspace layout", default =
the recommended option) *unless* the run is autonomous (an autonomous run shows no tab and
resolves with the `move` default). Offer:

- **Sibling dir + move — recommended** (`DRUPILOT_PLACEMENT=move`) — relocate the checkout
  into `<machine_name>-d11/web/.../custom/<machine_name>`; it stays a git repo, just at a
  new path; the default.
- **Sibling dir + symlink** (`DRUPILOT_PLACEMENT=symlink`) — keep editing your original path
  and symlink it into the test-bed. Gate on `autonomous=false`.
- **Sibling dir + copy** (`DRUPILOT_PLACEMENT=copy`) — duplicate the checkout into the
  test-bed; the original is untouched. Gate on `autonomous=false`.

Persist the answer with `prefs_set DRUPILOT_PLACEMENT <mode>` so place-subject.sh reuses it.

Then, AFTER 3a has created Drupal, place the subject (idempotent — detect-and-skip when
already placed). Pass `--yes` because the workspace tab above already captured consent for
the relocating `move` (so the script does not re-prompt):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/place-subject.sh" --subject "<subject_dir>" --yes
```

It places the loose subject into `<root>/web/{modules,themes,profiles}/custom/<machine_name>`,
persists `DRUPILOT_WORKSPACE_DIR` + `DRUPILOT_PLACEMENT` to `.drupilot.json`, and runs
`ensure-gitignore.sh` on the new root. Exit code 2 means the Drupal root does not exist yet
(run 3a first); a non-loose subject is a no-op.

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

Then ensure drupilot's generated artifacts are git-ignored at the Drupal root, so a
coverage run or the `.drupilot.json` preference file can never leak into a contribution
patch. This MERGES a marker-delimited block into any existing `.gitignore` (it never
overwrites the project's own ignores) and is idempotent:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/ensure-gitignore.sh" --root "<drupal_root>"`

## Step 5 — Report

Print the final state: DDEV project name and status, PHP target (flag unconfirmed
targets), which add-ons are installed, the toolchain versions, and which config files
were written or left untouched. Recommend the next step: `/drupilot-assess`.

For long-running batches, prefer background execution and notify on completion; do not
block the session. If you delegate the whole environment build, use the Task tool with
the **drupal-port-orchestrator** subagent, but for a plain setup the scripts above are
enough.
