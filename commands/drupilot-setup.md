---
description: Provision a Drupal 11 DDEV environment for porting a module/theme - start DDEV, install the contrib (+ Selenium) add-ons, install the Composer dev toolchain (drupal-rector, PHPStan + extensions, coder, drush 13, drupal/core-dev for PHPUnit), and write rector.php / phpstan.neon / phpcs.xml.dist / testing web_environment from templates. Idempotent. Use for "/drupilot-setup", "set up the environment", "spin up DDEV for this module".
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
the heavy steps (composer create-project/require, add-on installs) may run in the background.

Use the **ddev-environment** skill for the operating procedure and gotchas, then run the
leaf scripts in order. Each is idempotent.

**Subject placement (important).** drupilot uses the `recommended-project` layout: Drupal
lives at the project root and the subject lives under `web/modules/custom/<machine_name>`
(or `web/themes/custom/...`). A LOOSE checkout (a module/theme that is NOT already inside a
Drupal site) is never scaffolded on top of — that would intermix the module with Drupal's
own `composer.json`/`web/`/`vendor/`. Two scripts handle placement: resolve the workspace
first, then place the subject AFTER 3a creates Drupal (`composer create-project` needs an empty
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
(run 3a first); a non-loose subject is a no-op. Before placing it records the origin's
`git status` baseline (`origin-hygiene.sh --snapshot`); a `copy` skips local-environment
residue (`.ddev/`, `vendor/`, `.drupilot*`, `.phpstan-cache/`, `node_modules/`) and drops
symlinks escaping the checkout. If the resolver JSON lists `residue` or `residual_ddev:true`,
tell the developer (report-only — never delete anything in their checkout).

For a subject that is **already inside** a Drupal root (`loose:false`), record the origin
baseline yourself (idempotent — an existing baseline is kept), substituting `<subject_dir>`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/origin-hygiene.sh" --snapshot --subject "<subject_dir>" --placement in-place
```

### 3a — Bring up the DDEV Drupal 11 project

Run this yourself via the Bash tool, substituting `<subject_dir>` with the resolved
subject directory from Step 2's context and `<ddev_name>` with the DDEV project name (do not
run it verbatim). Pass `--name` explicitly: without it the project is named after the
test-bed directory (e.g. `my_module-d11` → `my-module-d11`). A good default is the
`machine_name` from the resolver plus `-d11`; the script sanitizes it to a hostname-safe
value:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/ddev-up.sh" --subject "<subject_dir>" --name "<ddev_name>" --docroot web
```

All logs, the preflight report and the ddev/composer output go to stderr; add `--json` for
a `{project_dir, project_name, php_version, primary_url, drupal_target}` summary on stdout.

This configures `--project-type=drupal11 --docroot=web --php-version=$(resolve_php_target)`,
starts DDEV, runs `ddev composer create-project drupal/recommended-project:^11` (`create` on DDEV < 1.24.2) when there is no
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

Do NOT hand-write `ddev composer require --dev ...`: the toolchain is installed by a
deterministic script that pins the versions, proves the result works and freezes it
in the lock. Run it yourself via the Bash tool once 3a/3b are done, substituting
`<drupal_root>` with the `drupal_root` from the resolve-workspace.sh JSON (do not run
it verbatim — the script rejects an unsubstituted placeholder):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/install-toolchain.sh" --dir "<drupal_root>" --json
```

Add `--with-upgrade-status` to also install `drupal/upgrade_status`; `--dry-run`
prints the resolved package specs without running Composer.

It installs drupal-rector, `rector/rector`, PHPStan + extension-installer +
phpstan-drupal + phpstan-deprecation-rules, drupal/coder (`DRUPILOT_CODER_CONSTRAINT`)
and **`drupal/core-dev`** (PHPUnit + the Drupal test dependencies, matched to the
installed core by `core_dev_requirement` — without it `/drupilot-test` cannot run a
single test). Versions come from, in order (`DRUPILOT_TOOLCHAIN_SOURCE=auto`): the
project lock when it pins the whole known-good set, otherwise the shipped
**known-good reference** `config/toolchain-reference.json`; with
`DRUPILOT_DETERMINISTIC=false`, the `.packages` ranges. Then it runs a **smoke test**
(a Rector dry-run with the Drupal 10 set + `phpstan --version`) and re-syncs the lock
(`lock-sync.sh`), so `rector/rector`, `drupal/core-dev` and the rest are frozen. It
is idempotent: when everything is already installed at its pinned version, Composer
is not run.

Read the JSON (`ok`, `status`, `source`, `smoke`) and act on the exit code:

- `0` — installed (or `unchanged`) and the smoke test passed.
- `3` — **the toolchain is installed but broken** (`status: "smoke-failed"`; e.g.
  `[ERROR] Could not detect twig set.` from an incompatible `rector/rector`). Show
  the diagnostic from stderr (installed vs known-good versions) and do NOT continue
  to assess/port on it. The fix is the known-good set:
  `install-toolchain.sh --dir "<drupal_root>" --source reference` (it refreshes the
  lock). Never work around a crash by reading Rector's output as "no changes".
- `2` — a requirement is missing or DDEV is not running (fix 3a first).
- `1` — Composer could not resolve the set (its output is on stderr); if the pinned
  set did not resolve it already retried once with the ranges (`fallback_to_ranges`).

drupal/coder ships a Composer plugin (`*/phpcodesniffer-composer-installer`) that
auto-registers the PHPCS `installed_paths`. Allow that plugin, let it run, then just
verify with `ddev exec vendor/bin/phpcs -i` (it must list `Drupal` and `DrupalPractice`).
If you set `installed_paths` MANUALLY, register all THREE paths coder's Drupal standard
references — `coder_sniffer`, `phpcs-variable-analysis` and `slevomat/coding-standard` —
not just `coder_sniffer`, or phpcs aborts with "Referenced sniff ... does not exist":
`ddev exec vendor/bin/phpcs --config-set installed_paths vendor/drupal/coder/coder_sniffer,vendor/sirbrillig/phpcs-variable-analysis,vendor/slevomat/coding-standard`

## Step 4 — Write the tool configs from templates

Render the config templates with the deterministic renderer — do NOT substitute the
`{{PLACEHOLDER}}` tokens by hand. Run it yourself via the Bash tool, substituting
`<drupal_root>` with the `drupal_root` from the resolve-workspace.sh JSON and
`<machine_name>` / `<modules|themes|profiles>` with the placed subject's in-tree path
(do not run it verbatim — the script rejects an unsubstituted placeholder):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/render-templates.sh" --root "<drupal_root>" \
  --subject-path "web/<modules|themes|profiles>/custom/<machine_name>" --json
```

It renders, validates and writes, at the Drupal root:

- `templates/rector.php.tmpl` -> `rector.php` (checked with `php -l`)
- `templates/phpstan.neon.tmpl` -> `phpstan.neon`
- `templates/phpcs.xml.dist.tmpl` -> `phpcs.xml.dist` (checked with `xmllint --noout`,
  or `phpcs --standard=<file> -e` when xmllint is absent)
- `templates/ddev-web-environment.yaml.tmpl` -> a SEPARATE `.ddev/config.testing.yaml`
  (never merged into the generated `config.yaml`). ddev-drupal-contrib already provides
  `SIMPLETEST_DB`, `SIMPLETEST_BASE_URL=http://web`, `BROWSERTEST_*` and `DTT_*` in its
  `config.contrib.yaml`, and the Selenium add-on provides `MINK_DRIVER_ARGS_WEBDRIVER`
  (with `"w3c":true`) in its own config; this file only adds `SYMFONY_DEPRECATIONS_HELPER`,
  so it merges cleanly instead of clobbering them. It must NOT re-declare
  `MINK_DRIVER_ARGS_WEBDRIVER`: it loads after the add-on's file and would replace its
  working value (Drupal 11.4 forces `w3c` to false when the value omits it, and the
  Selenium image then refuses every FunctionalJavascript session). An older generated
  copy is upgraded automatically; run `ddev restart` when `restart_needed` is true.

Token values come from the resolved config: `{{PHP_TARGET}}` (`resolve_php_target`), `{{PHP_SET}}`
(the Rector `->withPhpSets()` argument derived from it: `php83`/`php84`),
`{{DRUPAL_TARGET}}`, `{{PHPSTAN_LEVEL}}` (`DRUPILOT_PHPSTAN_LEVEL`) and `{{SUBJECT_PATH}}`
(`{{WEBDRIVER_HOST}}` is still resolved and accepted by `--set`, but no current template
uses it). Override one
with `--set KEY=VALUE` only if it is genuinely wrong. Use `--dry-run` to preview.

Read the JSON (`files[].status`, `ok`, `restart_needed`) and act on it:

- `written` / `unchanged` — done. If `restart_needed` is true, run `ddev restart`.
- `upgraded` — the file was generated by an OLDER drupilot template (e.g. a pre-0.9.0
  `phpstan.neon` with the deprecated `drupal_root`, or the invalid pre-0.9.0
  `phpcs.xml.dist`); it was backed up under `<drupal_root>/.drupilot/backups/` and
  regenerated without asking, also in an autonomous run. Report the backup path.
- `differs` (exit 3) — the file exists, carries the current template generation and is
  not what the template renders, i.e. it was hand-edited. The unified diff is on
  stderr. Do not overwrite a config the user has hand-edited without saying so: show the
  diff and ask (`AskUserQuestion`: replace / keep). On "replace", re-run with
  `--only <name> --force` (the old copy is backed up under `<drupal_root>/.drupilot/backups/`).
  An autonomous run keeps the existing file and reports it.
- `invalid` (exit 3) — the rendered file failed validation and was NOT written; report the
  validator output from stderr. Never hand-write the file to work around it.

Then ensure drupilot's generated artifacts are git-ignored at the Drupal root, so a
coverage run or the `.drupilot.json` preference file can never leak into a contribution
patch. This MERGES a marker-delimited block into any existing `.gitignore` (it never
overwrites the project's own ignores) and is idempotent. Run this yourself via the Bash
tool, substituting `<drupal_root>` with the `drupal_root` from the resolve-workspace.sh
JSON (do not run it verbatim — the script rejects an unsubstituted placeholder):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/ensure-gitignore.sh" --root "<drupal_root>"
```

Equivalently, `--subject "<subject_dir>"` derives the root itself (the enclosing Drupal
root, or the test-bed root for a loose subject).

## Step 5 — Report

Once the environment is up and the subject is placed, record the **setup** stage
in the subject's `state.json` (the per-module registry; it also snapshots the
frozen toolchain from the lock). Run it yourself with the subject's final path
(the placed `web/<modules|themes|profiles>/custom/<name>` for a loose subject):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/state.sh" record --subject <placed_subject_path> --stage setup
```

Then print the final state: DDEV project name and status, PHP target (flag unconfirmed
targets), which add-ons are installed, the toolchain versions, and which config files
were written or left untouched. Recommend the next step: `/drupilot-assess`.

For long-running batches, prefer background execution and notify on completion; do not
block the session. If you delegate the whole environment build, use the Task tool with
the **drupal-port-orchestrator** subagent, but for a plain setup the scripts above are
enough.
