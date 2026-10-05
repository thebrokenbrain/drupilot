# legacy_widgets H10 golden (lab L-M1-1, T-M1-05; re-recorded in M2)

First produced in M1 (lab L-M1-1, bed `dpl-m1-legwid-d11`, 2026-10-03T23:18–23:21Z) and re-recorded in M2
(2026-10-04, UTC 18:21–18:24Z, bed `dpl-m2-legwid-d11`) after the toolchain matrix (T-M2-10) and the Rector PHP
floor (T-M2-13, T-M2-14), by the R-LAB-8 scripted sequence (scripts only, no model, no manual edit) on a fresh
copy of `tests/fixtures/legacy_widgets`. `$LAB` is the developer's lab directory outside the repository; `<repo>`
is a checkout of this repository.

## Files in this directory

| File | What it is |
|---|---|
| `golden/port-to-drupal-11.patch` | the `make-patch.sh --local` output of the M2 run `rc` (byte-identical to M1's) |
| `raw/rector-dryrun.json`, `raw/phpstan.json`, `raw/phpcs.json` | the canonicalized `--json` outputs of the M2 run `rc` (`raw-rc/` below) |
| `golden.json` | the manifest `scripts/dev/golden.sh` checks: `data_hash` (the version data snapshot of the run) and the sha256 of every file here |

The golden lives next to the fixture, not inside `tests/fixtures/legacy_widgets/`: that directory is the
module itself, copied as-is into the lab beds, the smoke tests and the v0.9.0 baseline, so any file added to
it would change what PHPCS and the other tools see. `scripts/dev/golden.sh --check` (the `golden` gate)
fails on any byte edit here; a deliberate re-recording runs `golden.sh --update` in its own commit, with a
CHANGELOG entry.

## Environment (M2)

| Item | Value |
|---|---|
| drupilot, run `tc` | `<repo>` @ `6fe5b4f` (branch `m2/toolchain-matrix`: the cell 11 pins, template v3) |
| drupilot, runs `rc` and `rc2` | `<repo>` @ `d7bf3b4` (branch `m2/rector-compat`: template v4 and the compat pass) |
| Lock file | `$DRUPILOT_HOME/state/<bed key>/drupilot-lock.json` (from `DRUPILOT_PROJECT_DIR=<bed> drupilot_lock_file`) |
| Lock sha256 | `36d4585ae6be2b4afbc963f65b8ec88167fb052595b6fdbdfe3c5ac078ed6beb` (unchanged before and after every run) |
| Drupal core | 11.4.8 (`DRUPILOT_DRUPAL_TARGET=11.4.8`, the core of the M1 recording; `core_source: create`, cached as `php8.3-11.4.8`) |
| PHP (container) | 8.3.33, PHP target 8.3 |
| DDEV | v1.25.4 (web image `ddev/ddev-webserver:v1.25.4`, docker 29.8.2) |
| Toolchain | cell 11: palantirnet/drupal-rector 1.1.3, rector/rector 2.6.1, phpstan/phpstan 2.2.16, phpstan/extension-installer 1.4.3, mglaman/phpstan-drupal 2.2.2, phpstan/phpstan-deprecation-rules 2.0.5, drupal/coder 8.3.31, drush/drush 13.8.0 |
| Toolchain source | `install-toolchain.sh` `source: reference`, `cell: "11"`, smoke ok, no drupal/core-dev (`--no-core-dev`: no PHPUnit in the bed) |
| Digests | **digests off (`DRUPILOT_USE_DIGESTS_RULES=false`)**; no `--digests` line was run, no `DRUPILOT_DIGESTS_REF` |
| Deterministic | `DRUPILOT_DETERMINISTIC=true` |

Lock content (as written by `install-toolchain.sh` / `lock-sync.sh`):

```json
{"schema":1,"created":"2026-10-04T18:21:06Z","drupilot_version":"0.9.2","updated":"2026-10-04T18:21:20Z",
 "drupilot_revision":"v0.9.2-57-g6fe5b4f","php_target":"8.3","phpstan_level":2,"core_strategy":"auto",
 "drupal":{"core":"11.4.8"},"toolchain_cell":"11",
 "toolchain":{"drush/drush":"13.8.0","drupal/coder":"8.3.31","palantirnet/drupal-rector":"1.1.3","phpstan/phpstan":"2.2.16",
  "phpstan/phpstan-deprecation-rules":"2.0.5","mglaman/phpstan-drupal":"2.2.2","phpstan/extension-installer":"1.4.3","rector/rector":"2.6.1"}}
```

## Exact commands

```bash
export LAB=$LAB
export DRUPILOT_HOME=$LAB/m2/h10/home
export DRUPILOT_DETERMINISTIC=true DRUPILOT_USE_DIGESTS_RULES=false
export DRUPILOT_PHP_TARGET=8.3 DRUPILOT_DRUPAL_TARGET=11.4.8
# every other DRUPILOT_* variable unset; CLAUDE_PLUGIN_DATA unset

# Bed (plugin root R = the m2/toolchain-matrix checkout)
export CLAUDE_PLUGIN_ROOT=$R
bash $R/scripts/env/ddev-up.sh --name dpl-m2-legwid-d11 --dir $LAB/m2/h10/dpl-m2-legwid-d11 --json
bash $R/scripts/env/install-toolchain.sh --dir $LAB/m2/h10/dpl-m2-legwid-d11 --no-core-dev --json

# One run, plugin root R, tag T (tc with the m2/toolchain-matrix checkout; rc, rc2 with m2/rector-compat)
export CLAUDE_PLUGIN_ROOT=$R
cd $LAB/m2/h10/dpl-m2-legwid-d11; S=web/modules/custom/rlab_$T/legacy_widgets
cp -a $R/tests/fixtures/legacy_widgets $S
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
jq -S . F | sed -e 's#/var/www/html/##g' -e "s#$LAB/m2/h10/dpl-[^/]*/##g" -e "s#web/modules/custom/rlab_$T/#web/modules/custom/#g"
```

Between runs the bed root was put back to its post-setup state (lab helper `reset-bed.sh`, files MOVED aside,
not deleted): the previous run's `rector.php`, `rector-compat.php`, `phpstan.neon`, `phpcs.xml.dist`,
`.ddev/config.testing.yaml` and its `web/modules/custom/rlab_<T>` copy. So every run started from the same root,
with no rendered config pointing at another copy and no duplicate `legacy_widgets` module under the docroot.
The listing after each reset matched the listing before the run (`diff` empty). The bed's DDEV project was
deleted afterwards.

## Results

| Run | Patch | `rector-dryrun.json` | `phpstan.json` | `phpcs.json` |
|---|---|---|---|---|
| M1 golden | `27fd76cb…` | `fa83eebe…` | `9bb920da…` | `60a72e03…` |
| `tc` (cell 11 pins, template v3) | = M1 | = M1 | = M1 | = M1 |
| `rc` = `rc2` (template v4, compat pass) | = M1 | `f1bfa031…` | = M1 | = M1 |

- The cell 11 pins (drupal-rector 1.1.3, rector 2.6.1, phpstan 2.2.16; were 0.21.2, 2.5.2, 2.2.2) change no
  output of this golden (run `tc`), so they needed no re-recording of their own.
- With T-M2-13/14 (run `rc`), `rector.php` targets the floor of `^10 || ^11`:
  `->withPhpVersion(PhpVersion::PHP_81)` and `->withPhpSets(php81: true)`. The compat pass runs and changes no
  file (the fixture has no implicitly nullable parameter). The port patch is unchanged: its one Rector change,
  `FunctionFirstClassCallableRector`, is a PHP 8.1 rule. `raw/rector-dryrun.json` only gains the new keys
  `compat_files: []`, `compat_status: "ok"`, `php_floor: "8.1"` and `php_ceiling: "8.5"`.
- `cmp`: `rc` == `rc2` for the patch and all three raw files. No raw JSON carries a timestamp or a duration.
  The only run-to-run difference in any captured stream is the plain-text `run-phpcs.sh --fix` stdout line
  `Time: 184ms; Memory: 6MB` (vs 180ms): not a raw golden.

## M4 re-recording of the raw files (T-M4-03)

Lab L-M4, bed `dpl-m4-legwid-d11` (the same environment as M2: Drupal 11.4.8, PHP 8.3.33, DDEV v1.25.4, cell 11
pins), 2026-10-05, with `<repo>` on branch `m4/tool-determinism`. Run `h10a` is the R-LAB-8 sequence above
(lab script `rlab8.sh`); runs `a` and `b` are the three `--json` calls alone on fresh copies, canonicalized with
`canon_json ROOT` (scripts/lib/canon.sh) plus the `rlab_<T>/` path.

| Run | Patch | `rector-dryrun.json` | `phpstan.json` | `phpcs.json` |
|---|---|---|---|---|
| `h10a` | = M1 (`27fd76cb…`) | `a3407735…` | `6cda12a0…` | `a40041ed…` |
| `a` = `b` | — | = `h10a` | = `h10a` | = `h10a` |

- Rector now runs with its JSON report: `raw/rector-dryrun.json` gains `file_diffs` (the official pass's
  `WidgetImportForm.php` diff, `FunctionFirstClassCallableRector`) and `runner` (`ddev`, PHP 8.3.33, rector/rector
  2.6.1); every other key is unchanged.
- `raw/phpstan.json` and `raw/phpcs.json` gain `drupilot.runner`; PHPStan's report is sorted, so its two messages on
  `WidgetImportForm.php` line 18 now come by identifier (`dependencySerializationTraitProperty...`,
  `property.readOnly`, `property.visibility`); the findings are the same.
- The H10 patch is unchanged (the R-LAB-8 run is byte-identical to the golden).

## Caveats for whoever re-records this golden

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
- `DRUPILOT_DRUPAL_TARGET=11.4.8` keeps the core of the first recording; `^11` would resolve a newer 11.x, whose
  PHPStan findings may differ.
- The M1 recording also ran drupilot v0.9.0 on the same `vendor/` (its own data dir, so no lockfile) and got
  the same four files: the patch and `phpstan.json`/`phpcs.json` here are still 0.9.0's output.
