# 0001 — Toolchain cell 11 pins drupal-rector 1.1.3 with Rector 2.6.1 and PHPStan 2.2.16

- **Status:** accepted
- **Date:** 2026-10-04
- **Decided by:** the 1.0 working session (R-AUTO-3), spike AR-38 (T-M2-07)

## Context

drupilot 1.0 turns `config/toolchain-reference.json` into a matrix of
toolchain cells (AR-09). Cell `11` is the dev toolchain of every Drupal 11
test-bed. drupilot 0.9 pins palantirnet/drupal-rector 0.21.2 with
rector/rector 2.5.2 and phpstan/phpstan 2.2.2. The plan (X5) moves to
drupal-rector 1.1.3, the newest release, which declares
`conflict: rector/rector >=2.6.2`. It left open which Rector to pair with
it, 2.5.2 or 2.6.1, and which PHPStan each one needs.

Two failures were already known:

- rector 2.5.2 with phpstan 2.2.16 crashes with
  `MissingPrivatePropertyException`;
- drupal-rector 0.21.2 with rector >= 2.6.2 stops with
  `Could not detect twig set.`

This decision blocks T-M2-10 (the v2 reference file and the range fallback
of `install-toolchain`). It also decides whether the `legacy_widgets` H10
goldens change when the toolchain switches. AR-42 starts cell 12 from it.

## Decision

Cell `11` pins drupal-rector 1.1.3, rector 2.6.1 and phpstan 2.2.16. The
other packages keep their 0.9 pins, which are still the newest versions
compatible with every candidate set. drupal/coder 8.3.31 is also the newest
version that drupal/core-dev 11.4.8 allows (`^8.3.30`). drupal/core-dev stays
matched to the installed core, as today.

```json
"11": {
  "toolchain": {
    "palantirnet/drupal-rector": "1.1.3",
    "rector/rector": "2.6.1",
    "phpstan/phpstan": "2.2.16",
    "phpstan/extension-installer": "1.4.3",
    "mglaman/phpstan-drupal": "2.2.2",
    "phpstan/phpstan-deprecation-rules": "2.0.5",
    "drupal/coder": "8.3.31",
    "drush/drush": "13.8.0",
    "drupal/upgrade_status": "4.3.10"
  },
  "verified_on": { "core": "11.4.8", "php": ["8.3", "8.5"], "ddev": "1.25.4" },
  "verified_with": [
    "tests/fixtures/legacy_widgets",
    "drupal/autologout 8.x-1.4 (2895b8c1c26d1b9604c87fbc01990866c588ba32)"
  ]
}
```

The container PHPs were 8.3.33 and 8.5.9. If the v2 schema keeps `php` as a
single string, write one `verified_on` per PHP. On that bed, Composer
resolves drupal/core-dev to 11.4.8 and installs, transitively,
phpstan/phpstan-phpunit 2.0.21, phpunit/phpunit 11.5.56 and
squizlabs/php_codesniffer 3.13.6. drupilot does not pin any of these.

`known_broken` (top level) becomes the following. Each entry was reproduced
here with the `install-toolchain --smoke-only` test.

```json
[
  { "packages": { "palantirnet/drupal-rector": "0.21.2", "rector/rector": ">=2.6.2" },
    "symptom": "[ERROR] Could not detect twig set.",
    "cause": "drupal-rector's drupal-10.0-deprecations.php needs TwigSetList::TWIG_24/TWIG_240, which rector 2.6.2 removed. Verified: 2.6.1 works; 2.6.2 and 2.6.7 crash." },
  { "packages": { "palantirnet/drupal-rector": "1.1.2", "rector/rector": ">=2.6.2" },
    "symptom": "[ERROR] Could not detect twig set.",
    "cause": "Same as 0.21.2; 1.1.3 added a conflict on rector >=2.6.2 for this reason, so 1.1.3 cannot be installed with it. Verified with rector 2.6.2." },
  { "packages": { "rector/rector": "2.5.2", "phpstan/phpstan": ">=2.2.6" },
    "symptom": "MissingPrivatePropertyException: Property \"$container\" was not found in \"PHPStan\\Parser\\RichParser\"",
    "cause": "rector 2.5.2 reads a private PHPStan property that is gone from phpstan 2.2.6 on (rector 2.5.8 raised its own requirement to ^2.2.6). Verified: phpstan 2.2.2 and 2.2.5 work; 2.2.6 and 2.2.16 crash." }
]
```

The third entry replaces the 0.9 entry `{rector 2.5.2, phpstan 2.2.16}`,
which it covers. The 0.9 set stays, byte for byte, as `legacy_v1`. This
spike checked it again on core 11.4.8 with PHP 8.3 and 8.5, and it still
works.

### Why 2.6.1 and not 2.5.2

Both candidate sets passed every check on both subjects, on PHP 8.3 and on
PHP 8.5. Both kept every port patch byte-identical to the 0.9 control. Four
reasons decide for 2.6.1:

- **Upstream verified it.** The drupal-rector 1.1.3 CHANGELOG says "2.6.1 is
  the last release on which every Drupal set loads". With the conflict in
  place, Composer resolves 2.6.1 for 1.1.3.
- **The range fallback lands on the same set.** With the 0.9 ranges (rector
  `^2.0 <2.6.2`, phpstan `^2.1`) and drupal-rector `^1.1.3`, Composer
  resolves exactly rector 2.6.1 and phpstan 2.2.16 today.
- **PHPStan stays current.** With rector 2.5.2, PHPStan must stay at or
  below 2.2.5. With phpstan 2.2.2 (set B), Composer also holds core-dev's
  phpstan/phpstan-phpunit at 2.0.16, because 2.0.17 and later need phpstan
  `^2.2.3`. Any resolve that lets phpstan move past 2.2.5 (a fallback to the
  ranges, a manual require) then brings back the known crash.
- **Cell 12 can share the Rector line.** drupal/core-dev 12.0.0-beta1
  requires phpstan `^2.2.14` (and drupal/coder `^9.0`), and rector 2.5.2
  crashes on every phpstan from 2.2.6 on. So only the 2.6.1 line can serve
  cell 12 (AR-42).

The cost is one parser fix in `run-rector.sh` (see Consequences).

## Evidence

### Matrix

**Lab setup.**

- Lab: `$LAB/m2/ar38`, on 2026-10-04, with the scripts of the
  `integration/1.0.0` checkout (9221309; the Cf and golden-style runs ran
  after a6e910c moved `php_supported_for` into `scripts/lib/plan.sh`, which
  changed no output).
- DDEV v1.25.4. Every bed ran core 11.4.8, the newest 11.4 release in
  `updates.drupal.org/release-history/drupal/current`.
- Beds and subjects:
  - `dpl-m2-legwid-d11` (PHP 8.3): `legacy_widgets`;
  - `dpl-m2-autolog-d11` (PHP 8.3): autologout 8.x-1.4;
  - `dpl-m2-legwid-d11p85` (PHP 8.5): both subjects, one after the other.
- Each run used a fresh `cp -a` of the subject, committed with
  `git init` first, and digests were off.
- Each run executed:
  - the smoke test;
  - the raw `run-rector --json` (dry run), `run-phpstan --json` and
    `run-phpcs --json`;
  - the R-LAB-8 sequence;
  - a post-port `run-phpstan --json`.
- Unless the set names it, every set used phpstan-drupal 2.2.2,
  deprecation-rules 2.0.5, extension-installer 1.4.3, coder 8.3.31 and
  core-dev 11.4.8.

| Set | drupal-rector / rector / phpstan | Smoke, dry-run, apply (4 legs) | Patches vs A | Raw JSON vs A |
|---|---|---|---|---|
| A (0.9 control) | 0.21.2 / 2.5.2 / 2.2.2 | exit 0, every leg | — | — |
| B | 1.1.3 / 2.5.2 / 2.2.2 | exit 0, every leg | identical ×4 | identical: rector, phpstan, phpcs, post-port phpstan |
| C | 1.1.3 / 2.6.1 / 2.2.16 | exit 0, every leg | identical ×4 | phpstan, phpcs and post-port phpstan identical; rector dry-run gains one false rule (below) |
| Cf: C installed by `install-toolchain` on fresh beds (phpstan-phpunit 2.0.21) | 1.1.3 / 2.6.1 / 2.2.16 | exit 0, every leg | identical ×4 | as C |

**Patch hashes (sha256).** Every set produced the same patch on each leg:

- `legacy_widgets`: `27fd76cb…b72a0` on both PHP 8.3 and 8.5. This is the
  same file as the committed golden
  `tests/fixtures/legacy_widgets.golden/golden/port-to-drupal-11.patch`.
- autologout on PHP 8.3: `52f9e11b…9c01`.
- autologout on PHP 8.5: `ab3c8b63…f4fe`. It is the 8.3 patch plus one
  `NewMethodCallWithoutParenthesesRector` hunk from the php84 set, which
  drupilot uses for an 8.5 target.

**Exit codes.** On every leg of every set, the exit codes matched A: PHPStan
returned 1 (findings, never `crashed`). On autologout, PHPCS returned 2 and
`--fix` returned 1 (violations remain).

**Golden-style bed.** Same bed, without drupal/core-dev (the T-M1-05
setup):

- **C:** the patch and the raw `phpstan.json` (`9bb920da…`) and `phpcs.json`
  (`60a72e03…`) are byte-identical to the committed golden. `rector-dryrun.json`
  differs only by the false rule.
- **A:** all four files are byte-identical to the golden.

PHPStan 2.2.16 and 2.2.2 gave byte-identical reports on both subjects.

The false rule comes from Rector 2.6.1. It removed
`NullToStrictStringFuncCallArgRector` from its php81 set (`config/set/php81.php`
at the 2.5.2 tag lists the rule; the 2.6.1 tag does not). The rule class
still exists, so the template's `class_exists()` filter keeps it in
`withSkip()`. Rector 2.6.1 then prints:

```
 [WARNING] This skipped rule is never registered. You can remove it from
           "->withSkip()"

 * Rector\Php81\Rector\FuncCall\NullToStrictStringFuncCallArgRector
```

`run-rector.sh` (L526-536) counts every ` * …Rector` line in the whole
output as an applied rule. The false rule therefore reaches `rules`, the
`rule_hits` field and the persisted `rector-rules.json`, which feeds the
port report. In the golden this is the only change:

```diff
     "official": {
-      "FunctionFirstClassCallableRector": 1
+      "FunctionFirstClassCallableRector": 1,
+      "Rector\\Php81\\Rector\\FuncCall\\NullToStrictStringFuncCallArgRector": 1
     }
   ...
   "rules": [
-    "FunctionFirstClassCallableRector"
+    "FunctionFirstClassCallableRector",
+    "Rector\\Php81\\Rector\\FuncCall\\NullToStrictStringFuncCallArgRector"
   ],
```

A parser that counts only the bullets of the `Applied rules:` blocks gives
the same rule set on C as on A, for both subjects.

### Probes (smoke test only, bed `dpl-m2-legwid-d11`)

| drupal-rector | rector | phpstan | `install-toolchain --smoke-only` |
|---|---|---|---|
| 1.1.3 | 2.5.2 | 2.2.16 | exit 3, `MissingPrivatePropertyException` |
| 1.1.3 | 2.5.2 | 2.2.6 | exit 3, `MissingPrivatePropertyException` |
| 1.1.3 | 2.5.2 | 2.2.5 | exit 0 |
| 1.1.3 | 2.6.1 | 2.2.6 (its floor) | exit 0 |
| 0.21.2 | 2.6.2 | 2.2.16 | exit 3, `Could not detect twig set.` |
| 0.21.2 | 2.6.7 | 2.2.16 | exit 3, `Could not detect twig set.` |
| 1.1.2 | 2.6.2 | 2.2.16 | exit 3, `Could not detect twig set.` |
| 0.21.2 | 2.6.1 | 2.2.16 | exit 0 |
| 1.1.3 | 2.6.2 | 2.2.16 | not installable: Composer reports "palantirnet/drupal-rector 1.1.3 conflicts with rector/rector >=2.6.2" |

drupal/upgrade_status 4.3.10 installs with set C
(`install-toolchain --with-upgrade-status`), and the smoke test passes.

### Lab commands

```bash
export CLAUDE_PLUGIN_ROOT=<repo> LAB=<lab>
export DRUPILOT_HOME=$LAB/m2/ar38/home
export DRUPILOT_DETERMINISTIC=true DRUPILOT_USE_DIGESTS_RULES=false
unset DRUPILOT_CONTRIB_MODE CLAUDE_PLUGIN_DATA

# Beds (PHP 8.5 for dpl-m2-legwid-d11p85), then the 0.9 control set A
DRUPILOT_PHP_TARGET=8.3 bash $CLAUDE_PLUGIN_ROOT/scripts/env/ddev-up.sh \
  --name dpl-m2-legwid-d11 --dir $LAB/m2/ar38/dpl-m2-legwid-d11 --json
bash $CLAUDE_PLUGIN_ROOT/scripts/env/install-toolchain.sh \
  --dir $LAB/m2/ar38/dpl-m2-legwid-d11 --json

# Another set, inside the bed (B shown; C uses rector 2.6.1 and phpstan 2.2.16)
ddev composer require --dev -W --no-interaction \
  palantirnet/drupal-rector:1.1.3 rector/rector:2.5.2 phpstan/phpstan:2.2.2 \
  mglaman/phpstan-drupal:2.2.2 phpstan/phpstan-deprecation-rules:2.0.5 \
  phpstan/extension-installer:1.4.3 drupal/coder:8.3.31

# Set Cf: a copy of the plugin whose reference holds the C pins, on a fresh bed
CLAUDE_PLUGIN_ROOT=$LAB/m2/ar38/plugin-c \
  bash $LAB/m2/ar38/plugin-c/scripts/env/install-toolchain.sh --dir <bed> --json

# One run from the bed root; S=web/modules/custom/<subject>
# (a fresh copy, committed with git init first)
bash $CLAUDE_PLUGIN_ROOT/scripts/env/install-toolchain.sh --dir <bed> --smoke-only --json
bash $CLAUDE_PLUGIN_ROOT/scripts/analysis/run-rector.sh  --subject $S --json
bash $CLAUDE_PLUGIN_ROOT/scripts/analysis/run-phpstan.sh --subject $S --json
bash $CLAUDE_PLUGIN_ROOT/scripts/analysis/run-phpcs.sh   --subject $S --json
bash $CLAUDE_PLUGIN_ROOT/scripts/env/render-templates.sh --subject $S --force
REQ=$(bash $CLAUDE_PLUGIN_ROOT/scripts/analysis/core-strategy.sh --subject $S --json \
      | jq -r .recommended_core_version_requirement)
bash $CLAUDE_PLUGIN_ROOT/scripts/analysis/run-rector.sh --subject $S --apply
bash $CLAUDE_PLUGIN_ROOT/scripts/analysis/set-core-requirement.sh --subject $S --requirement "$REQ"
bash $CLAUDE_PLUGIN_ROOT/scripts/analysis/run-phpcs.sh --subject $S --fix
bash $CLAUDE_PLUGIN_ROOT/scripts/contrib/make-patch.sh --local --subject $S

# Conflict and range checks
ddev composer require --dev -W --no-interaction --dry-run \
  palantirnet/drupal-rector:1.1.3 rector/rector:2.6.2 phpstan/phpstan:2.2.16   # refused
ddev composer require --dev -W --no-interaction --dry-run \
  'palantirnet/drupal-rector:^1.1.3' 'rector/rector:^2.0 <2.6.2' 'phpstan/phpstan:^2.1'   # "Nothing to modify" with C installed
```

Between runs the lab moved the rendered root configs, `.phpstan-cache`,
`.drupilot/*` and the subject's state directory out of the bed, so every run
started from the same root. The full log is in the lab's `notes.md`.

### Sources read (2026-10-04)

- `repo.packagist.org/p2/` for palantirnet/drupal-rector (and `~dev`),
  rector/rector, phpstan/phpstan, mglaman/phpstan-drupal,
  phpstan/phpstan-deprecation-rules, phpstan/extension-installer,
  drupal/coder, phpstan/phpstan-phpunit, drush/drush and drupal/core-dev.
  The facts read there:
  - drupal-rector 1.1.3 requires `rector/rector ^2` and conflicts with
    `>=2.6.2`. No earlier release declares the conflict.
  - rector requires phpstan `^2.2.2` up to 2.5.7, `^2.2.6` from 2.5.8 to
    2.6.4, `^2.2.10` at 2.6.5 and 2.6.6, and `^2.2.14` at 2.6.7.
  - phpstan-drupal 2.2.2 requires phpstan `^2.1`, and deprecation-rules
    2.0.5 requires `^2.1.39`.
- `git.drupalcode.org/project/drupal/-/raw/11.4.8/composer/Metapackage/DevDependencies/composer.json`:
  phpstan `^1.12.27 || ^2.2.0`, mglaman/phpstan-drupal
  `^1.3.9 || ^2.0.15`, drupal/coder `^8.3.30`.
- The same file at tag 12.0.0-beta1 (the newest 12.0 release in the feed):
  phpstan `^2.2.14`, mglaman/phpstan-drupal `^2.2.1`, drupal/coder `^9.0`.
- `updates.drupal.org/release-history/{drupal,upgrade_status}/current`:
  11.4.8 is the newest 11.4 release, and upgrade_status 4.3.10 declares
  `^9 || ^10 || ^11`.
- `github.com/palantirnet/drupal-rector` at tags 1.1.3 and 0.21.2: the
  CHANGELOG, `config/drupal-10/drupal-10.0-deprecations.php` and
  `src/Set/Drupal10SetList.php`.
- `github.com/rectorphp/rector`, `config/set/php81.php` at tags 2.5.2 and
  2.6.1.
- `github.com/ddev/ddev`, `pkg/nodeps/php_values.go` at tag v1.25.4: PHP
  8.5 is a valid version.

## Consequences

- **T-M2-10** writes cell `11` and `known_broken` as above, and keeps the
  0.9 set as `legacy_v1`. In the same change (or before it), the
  `config/defaults.json` range of `drupal_rector` moves from `^0.21` to
  `^1.1.3`. With the old range, a fallback to ranges resolves 0.21.2 with
  rector 2.6.1. That set works (see Probes), but it is not the cell. The
  rector range (`^2.0 <2.6.2`) and the phpstan range (`^2.1`) already
  resolve to the cell's pins.
- **The `run-rector.sh` parser fix lands with the switch (T-M2-10), before
  the compat pass of ADR 0002 (T-M2-13) adds more such notices.** Count only the
  ` * …Rector` lines inside `Applied rules:` blocks, or read Rector's
  JSON `applied_rectors`. Add a unit case built from the captured Rector
  2.6.1 output (lab `logs/rector-2.6.1-skip-warning-sample.log`). Without
  the fix, every Rector 2.6.x run reports
  `NullToStrictStringFuncCallArgRector` as applied in the JSON, in
  `rector-rules.json` and in the port report, although drupilot
  deliberately skips that rule. Keep the skip entry: `legacy_v1`'s rector
  2.5.2 still registers the rule.
- **H10 goldens.** With the parser fix, the switch changes no golden
  bytes: the patch, `raw/phpstan.json` and `raw/phpcs.json` are identical,
  and `raw/rector-dryrun.json` matches once the false rule is gone. If the
  switch lands before the fix, the change is exactly the diff above,
  recorded with `golden.sh --update` and a CHANGELOG entry. In both cases,
  the golden README's toolchain row (pinned in `golden.json`) needs a
  documentation update to name the cell-11 toolchain.
- **AR-42 (cell 12)** starts from this set: rector 2.6.1 with phpstan
  `>=2.2.14`. Rector 2.5.2 is ruled out there by the third `known_broken`
  entry.
- **Minor item:** on an 8.5 target, `ddev-up.sh` (L120) still warns "DDEV
  may not provide a PHP 8.5 image", but DDEV v1.25.4 ships one. The next
  task that touches `ddev-up.sh` can drop the warning.
- **When to recheck:**
  - a drupal-rector release that lifts the conflict (the composer-based
    sets of PR #419; its `dev-pr-419-*` branches already require
    `rector/rector ^2.6` with no conflict);
  - the first 11.5 bed;
  - a newer rector 2.6.x or phpstan 2.2.x on repo.packagist.org/p2 (a
    manual check: `refresh-data.sh` reads drupal/core-dev's PHPStan
    constraint, not the Rector or PHPStan releases themselves).

  Run the same matrix again before moving a pin.
