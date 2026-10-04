# legacy_widgets H10 golden (lab L-M1-1, T-M1-05)

Produced 2026-10-04 (UTC 2026-10-03T23:18–23:21Z) in the lab bed `dpl-m1-legwid-d11`, by the R-LAB-8 scripted
sequence (scripts only, no model, no manual edit) on a fresh copy of `tests/fixtures/legacy_widgets`.
`$LAB` is the developer's lab directory outside the repository; `<repo>` is this checkout.

## Files in this directory

| File | What it is |
|---|---|
| `golden/port-to-drupal-11.patch` | the `make-patch.sh --local` output of the first HEAD run (`patch-head1.patch` below) |
| `raw/rector-dryrun.json`, `raw/phpstan.json`, `raw/phpcs.json` | the canonicalized `--json` outputs of that run (`raw-head1/` below) |
| `golden.json` | the manifest `scripts/dev/golden.sh` checks: `data_hash` (empty until M2) and the sha256 of every file here |

The golden lives next to the fixture, not inside `tests/fixtures/legacy_widgets/`: that directory is the
module itself, copied as-is into the lab beds, the smoke tests and the v0.9.0 baseline, so any file added to
it would change what PHPCS and the other tools see. `scripts/dev/golden.sh --check` (the `golden` gate)
fails on any byte edit here; a deliberate re-recording runs `golden.sh --update` in its own commit, with a
CHANGELOG entry.

## Environment

| Item | Value |
|---|---|
| drupilot (HEAD) | 0.9.1, repo `<repo>` @ `248e74d` (branch `m1/test-harness`) |
| drupilot (v0.9.0) | worktree `$LAB/shared/v090` @ `c85f72b` (tag `v0.9.0`) |
| Lock file | `$DRUPILOT_HOME/state/<bed key>/drupilot-lock.json` (from `DRUPILOT_PROJECT_DIR=<bed> drupilot_lock_file`) |
| Lock sha256 | `b2c9c7f69570a82960d9d581cf55921ca90b31fd5cb2d3e12d60c3fb289141d1` (unchanged before and after every HEAD run) |
| Drupal core | 11.4.8 (`drupal/recommended-project:^11`, `core_source: create`, cached as `php8.3-11.4.8`) |
| PHP (container) | 8.3.33 (`ddev exec php -r 'echo PHP_VERSION;'`), PHP target 8.3 |
| DDEV | v1.25.4 (web image `ddev/ddev-webserver:v1.25.4`, docker 29.8.2) |
| Toolchain | palantirnet/drupal-rector 0.21.2, rector/rector 2.5.2, phpstan/phpstan 2.2.2, phpstan/extension-installer 1.4.3, mglaman/phpstan-drupal 2.2.2, phpstan/phpstan-deprecation-rules 2.0.5, drupal/coder 8.3.31 (squizlabs/php_codesniffer 3.13.6), drush/drush 13.8.0 |
| Toolchain source | `install-toolchain.sh` `source: reference` (`config/toolchain-reference.json`), smoke ok, no drupal/core-dev (`--no-core-dev`: no PHPUnit in the bed) |
| Digests | **digests off (`DRUPILOT_USE_DIGESTS_RULES=false`)**; no `--digests` line was run, no `DRUPILOT_DIGESTS_REF` |
| Deterministic | `DRUPILOT_DETERMINISTIC=true` |

Lock content (as written by `install-toolchain.sh` / `lock-sync.sh`):

```json
{"created":"2026-10-03T23:16:40Z","drupilot_version":"0.9.1","updated":"2026-10-03T23:17:14Z","drupilot_revision":"v0.9.1",
 "php_target":"8.3","phpstan_level":2,"core_strategy":"auto","drupal":{"core":"11.4.8"},
 "toolchain":{"drush/drush":"13.8.0","drupal/coder":"8.3.31","palantirnet/drupal-rector":"0.21.2","phpstan/phpstan":"2.2.2",
  "phpstan/phpstan-deprecation-rules":"2.0.5","mglaman/phpstan-drupal":"2.2.2","phpstan/extension-installer":"1.4.3","rector/rector":"2.5.2"}}
```

## Exact commands

```bash
export LAB=$LAB
export CLAUDE_PLUGIN_ROOT=<repo>
export DRUPILOT_HOME=$LAB/m1/home
export DRUPILOT_DETERMINISTIC=true
export DRUPILOT_USE_DIGESTS_RULES=false
unset DRUPILOT_CONTRIB_MODE CLAUDE_PLUGIN_DATA

# Bed
bash $CLAUDE_PLUGIN_ROOT/scripts/env/ddev-up.sh --name dpl-m1-legwid-d11 --dir $LAB/m1/dpl-m1-legwid-d11 --json
bash $CLAUDE_PLUGIN_ROOT/scripts/env/install-toolchain.sh --dir $LAB/m1/dpl-m1-legwid-d11 --no-core-dev --json

# One run, plugin root R, tag T (head1, head2 with R=HEAD; v090 with R=$LAB/shared/v090)
export CLAUDE_PLUGIN_ROOT=$R
# v090 only:  unset DRUPILOT_HOME; export CLAUDE_PLUGIN_DATA=$LAB/m1/home-090
cd $LAB/m1/dpl-m1-legwid-d11; S=web/modules/custom/rlab_$T/legacy_widgets
cp -a <repo>/tests/fixtures/legacy_widgets $S
(cd $S && git init -q && git add -A && git -c user.name=lab -c user.email=lab@example.invalid -c commit.gpgsign=false commit -qm "Initial legacy_widgets fixture (Drupal 10.3)")
bash $R/scripts/analysis/run-rector.sh  --subject $S --json > rector-dryrun.json   # exit 0
bash $R/scripts/analysis/run-phpstan.sh --subject $S --json > phpstan.json         # exit 1 (findings)
bash $R/scripts/analysis/run-phpcs.sh   --subject $S --json > phpcs.json           # exit 0
bash $R/scripts/env/render-templates.sh --subject $S --force                       # exit 0
REQ=$(bash $R/scripts/analysis/core-strategy.sh --subject $S --json | jq -r .recommended_core_version_requirement)   # '^10 || ^11'
bash $R/scripts/analysis/run-rector.sh --subject $S --apply                        # exit 0
bash $R/scripts/analysis/set-core-requirement.sh --subject $S --requirement "$REQ" # exit 0
bash $R/scripts/analysis/run-phpcs.sh --subject $S --fix                           # exit 0
P=$(bash $R/scripts/contrib/make-patch.sh --local --subject $S)                    # exit 0

# Canonicalization of each raw JSON
jq -S . F | sed -e 's#/var/www/html/##g' -e "s#$LAB/m1/dpl-[^/]*/##g" -e "s#web/modules/custom/rlab_$T/#web/modules/custom/#g"
```

Between runs the bed root was put back to its post-setup state (lab helper `reset-bed.sh`, files MOVED aside,
not deleted): the previous run's `rector.php`, `phpstan.neon`, `phpcs.xml.dist`, `.ddev/config.testing.yaml`
and its `web/modules/custom/rlab_<T>` copy. So every run started from the same root, with no rendered config
pointing at another copy and no duplicate `legacy_widgets` module under the docroot. The listing after each
reset matched the listing before the run (`diff` empty).

## Results

| File | sha256 |
|---|---|
| `patch-head1.patch` = `patch-head2.patch` = `patch-v090.patch` | `27fd76cbf1c5e4838ee9e3e209f1e14fb0857dbb5e121ba00f9712962e2b72a0` |
| `raw-*/rector-dryrun.json` | `fa83eebead6ced5ded08592b82018239ddf819989124e55c2bdf2caad2cdef38` |
| `raw-*/phpstan.json` | `9bb920da1d3e0af5551266c0c59e60667daa1d33c378d55ee83fc1e708ad1a23` |
| `raw-*/phpcs.json` | `60a72e0365ef067fc61d22596a623aa808186fce593718d458fcd836d71cee7d` |

- `cmp`: raw-head1 == raw-head2 (all three files), and also == raw-v090; patch-head1 == patch-head2 == patch-v090.
- No raw JSON carries a timestamp or a duration. The only run-to-run difference in any captured stream is the
  plain-text `run-phpcs.sh --fix` stdout line `Time: 196ms; Memory: 6MB` (vs 187ms): not a raw golden.

## Caveats for whoever commits this golden

- The patch (36 lines) holds only: `core_version_requirement` `^10` -> `^10 || ^11` (main info.yml), the submodule
  `^8.8 || ^9 || ^10` -> `^10 || ^11`, and one Rector change (`FunctionFirstClassCallableRector`:
  `array_map('trim', ...)` -> `array_map(trim(...), ...)` in `src/Form/WidgetImportForm.php`). It is a
  determinism golden, NOT a working D11 port: the scripted sequence leaves H10 (`ConfigFormBase::__construct()`
  with 1 argument, PHPStan finding `SettingsForm.php:32`) and H15 (untyped `getOriginal()`, not covariant on
  11.2+, `LegacyWidget.php:57`) in place, which the model-driven Steps 5–6 of `/drupilot-port` would fix.
- `raw/phpstan.json` depends on the bed having NO `drupal/core-dev` (`--no-core-dev`): 9 of its 39 file
  errors are `Call to an undefined method Drupal\Tests\legacy_widgets\...::assertSame()/createMock()/assertArrayHasKey()`
  because PHPUnit is absent (11 findings in total are under `tests/`). A bed with core-dev gives a different file.
- `raw/phpcs.json` is the Drupal,DrupalPractice fallback: the fixture's own `phpcs.xml.dist` references
  `PHPCompatibility`, which is not installed in the bed (`drupilot.source: "fallback"`, `test_version: "8.1-"`
  from the ruleset property, H29). Installing PHPCompatibility in the bed would change this file.
- The v0.9.0 run used its own data dir (`CLAUDE_PLUGIN_DATA=$LAB/m1/home-090`), so it saw NO lockfile (0.9.0
  ignores `DRUPILOT_HOME`); it used the same installed `vendor/` toolchain, which is why its outputs match.
