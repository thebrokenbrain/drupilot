---
name: php-target-tuning
description: >-
  Use this skill whenever a PHP version target matters for the port — i.e.
  deciding or changing DRUPILOT_PHP_TARGET, and translating it into the Rector
  PHP sets, the PHPStan level/expectations, the PHPCS sniffs and the DDEV
  php_version. It is the single source of truth for how one variable
  (DRUPILOT_PHP_TARGET, default 8.3) flows through the whole toolchain, and for
  the PHP 8.5 caveat (8.5 needs Drupal 11.3 or later, and no Rector php85 set is
  assumed — check the core minor, never hardcode). Invoke it from /drupilot-setup,
  /drupilot-assess, /drupilot-port and /drupilot-refactor before configuring any
  tool, and whenever the user asks to target a specific PHP version.
allowed-tools: Bash, Read, Edit
---

# PHP target tuning

`DRUPILOT_PHP_TARGET` is the one knob that decides every PHP-version-dependent
setting. Resolve it once, then derive everything from it. **Default is `8.3`** —
the absolute minimum across the entire Drupal 11 series, so it is always safe.

## 1. Resolve the target

Use the shared helper (env var wins over `config/defaults.json`):

```bash
TARGET="$(resolve_php_target)"     # default 8.3
```

Or get the full picture, including the host and DDEV PHP versions:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/detect-php.sh" --json
# -> {host_php, ddev_php, target, supported, unconfirmed}
```

`supported` and `unconfirmed` come from `php_support` in `defaults.json`
(`supported: ["8.3","8.4"]`, `unconfirmed: ["8.5"]`). The matching helpers are
`php_target_supported VER` and `php_target_unconfirmed VER`; which core minor
runs which PHP is `php_supported_for MINOR VER` (`yes`, `no` or `unknown`).

## 2. The PHP 8.5 caveat (critical)

PHP support per Drupal 11 branch (drupal.org PHP requirements, read through
`https://www.drupal.org/api-d7/node.json?nid=2891690` on 2026-10-03):

| D11 branch | PHP min | PHP 8.5 |
|---|---|---|
| 11.0 | 8.3 | No |
| 11.1 | 8.3 | No |
| 11.2 | 8.3 | No |
| 11.3 | 8.3 | Yes |
| 11.4 | 8.3 | Yes |

- **Minimum across the whole 11.x series: PHP 8.3.** drupilot recommends 8.4
  (`php_support.recommended`).
- **PHP 8.5 needs Drupal 11.3 or later.** `php_supported_for "$MINOR" 8.5` says
  `no` for 11.2 and earlier; an unlisted minor is `unknown` — never assume it.
- **No Rector `php85` set is assumed.** `php_target_unconfirmed "$TARGET"` is true
  for 8.5: `rector_php_set_arg` then uses `php84` with a warning. Never emit a
  `php85`/`UP_TO_PHP_85` set or assume a DDEV 8.5 image exists — detect them at
  runtime and degrade gracefully, so an 8.5 target never breaks the flow.
- When the target is 8.5, say so and check the core: `ddev-up.sh` warns, when it
  creates the project, if the lock-pinned core (else the lowest minor the Drupal
  target admits; a dev branch or stability flag is not guessed) is older than
  11.3, and again when the installed core is older. Composer installs the newest
  core the target admits, so the first warning is about the declared range.

## 3. How the target flows into each tool

Resolve `TARGET` first, then:

### Rector — PHP set selection (`rector.php`)

PHP sets are cumulative; target exactly **one** PHP version per run:

- `8.3` → `LevelSetList::UP_TO_PHP_83`, or the modern API `->withPhpSets(php83: true)`
- `8.4` → `UP_TO_PHP_84` / `->withPhpSets(php84: true)`
- `8.5` → `php84` (no `php85` set is assumed; `rector_php_set_arg` warns). Use a
  `php85` set only after verifying it exists in the installed Rector.

The Drupal set (`Drupal10SetList::DRUPAL_10`: APIs removed in D11) is independent
of the PHP target; `Drupal11SetList::DRUPAL_11` (D11 deprecations, for a future
D12 port) is deliberately not included. The PHP level set is applied minus the
rules the template skips (`ArrayToFirstClassCallableRector`,
`AddOverrideAttributeToOverriddenMethodsRector`, `ReadOnlyPropertyRector`,
`ReadOnlyClassRector`, `NullToStrictStringFuncCallArgRector`): they are not
compatibility fixes, they break Form API callbacks / serialization / Drupal 10,
and the `#[\Override]` and `readonly` they add would also raise the PHP floor
`detect-php-floor.sh` reports. The `rector.php.tmpl`
template encodes this; `scripts/env/render-templates.sh` (and `run-rector.sh` when it
writes a missing `rector.php`) derives the `->withPhpSets()` argument from the
target via `rector_php_set_arg` (`8.3` → `php83`, `8.4` → `php84`, `8.5` →
`php84` with a warning) — never edit it by hand. (The digests complementary
pass runs separately via `--config`, see the `minimal-port` skill.)

### PHPStan — level and expectations (`phpstan.neon`)

`DRUPILOT_PHPSTAN_LEVEL` (default `2`) is the base level for Phase 1 deprecation
detection; Phase 2 raises it to 5–6 via `DRUPILOT_PHPSTAN_LEVEL_REFACTOR`
(default `6`). The PHP target itself does not change the level number, but it
changes which language-level findings are valid — analyze against the same PHP
the code will run on. `render-templates.sh` substitutes `{{PHPSTAN_LEVEL}}` in
`phpstan.neon.tmpl` (or pass `--set PHPSTAN_LEVEL=N`).

### PHPCS — sniffs (`phpcs.xml.dist`)

`run-phpcs.sh` uses the subject's own ruleset when it ships a loadable one
(`DRUPILOT_PHPCS_RULESET=auto`, the default), else `Drupal,DrupalPractice`
(`DRUPILOT_PHPCS_RULESET=drupilot` forces the latter). The PHP target reaches
PHPCompatibility through `--runtime-set testVersion <target>-`, passed on every
run (override with `DRUPILOT_PHPCS_TEST_VERSION`, e.g. `8.1-` while Drupal 10 is
kept); a ruleset's own `<config name="testVersion">` is never overridden, and a
testVersion wrongly declared as a `<property>` inside a `<rule>` is passed
through, which avoids PHPCompatibility's "trim(): Passing null" failure. The
coder branch is chosen by
`DRUPILOT_CODER_CONSTRAINT` (default `^8.3` → PHPCS 3.x; `^9.0` → PHPCS 4.x), not
by the PHP target — but a higher PHP target can surface additional sniff results
(e.g. new syntax). Keep coder and the PHP target consistent so sniffs match the
runtime.

### DDEV — `php_version`

```bash
ddev config --project-type=drupal11 --docroot=web --php-version="$(resolve_php_target)"
```

`ddev-up.sh` already passes `--php-version=$(resolve_php_target)`. With 8.5 it
warns that the DDEV image may be missing (and when the core is older than 11.3);
fall back to `8.3` rather than failing `ddev start`.

## 4. Changing the target

To retarget, set the env var (it overrides `defaults.json`):

```bash
export DRUPILOT_PHP_TARGET=8.4
```

Then re-derive: re-run `detect-php.sh --json`, regenerate `rector.php`,
`phpstan.neon` and `phpcs.xml.dist` from the templates for the new target
(`export DRUPILOT_PHP_TARGET=8.4`, then `render-templates.sh --root <drupal_root>
--subject-path <path> --force`; the Rector PHP set follows the target), and reconfigure DDEV (`ddev config --php-version=8.4` then
`ddev restart`). Keep all four in lockstep — a mismatch between the Rector PHP
set, PHPStan, PHPCS and the DDEV runtime produces confusing, inconsistent
findings.

## 5. Cross-reference: the core target and `require.php`

The PHP target is also the **floor of the port**. The Drupal core-target decision
itself lives in `scripts/analysis/core-strategy.sh` (helper `recommend_core_target`),
not here — but the two meet at one rule: when a port **keeps Drupal 10**
(`core_version_requirement: ^10 || ^11`) it declares composer
`require.php: ">=<floor>"`, because Drupal 10's own minimum is PHP 8.1 while the
port requires at least the target (>= 8.3). A `^11`-only target needs no
`require.php` (core enforces it). The strategy is set by
`DRUPILOT_CORE_TARGET_STRATEGY` (default `auto`). This skill stays the source of
truth for the PHP target itself; it does **not** duplicate the core-target / SemVer
logic.

### 5.1 Two PHP-version questions — floor vs. target compatibility

`scripts/analysis/detect-php-floor.sh` is a heuristic scan of the code for
PHP 8.2/8.3/8.4 constructs and answers both directions, controlled by
`DRUPILOT_REQUIRE_PHP_FLOOR` (`detect` default | `target` conservative):

- **Floor (look down).** The lowest PHP the code can run on. With `detect`, this
  *widens* `require.php` below the target when honest (e.g. `>=8.1` when the code
  uses no 8.2+ constructs), for genuine Drupal 10 support. Lowering is best-effort
  — surface the "confirm with PHPCompatibility" warning. (Note: Rector's
  `->withPhpSets(php8X)` can *raise* the floor by modernizing syntax, which is the
  tension with keeping Drupal 10 on PHP 8.1.)
- **Target compatibility (look up).** `php_floor_target_compatible` is false when
  the code uses a construct **newer than the target** (e.g. an 8.4 feature with
  target 8.3) — that fatals on Drupal 11/PHP 8.3, so raise `DRUPILOT_PHP_TARGET`
  or remove the construct. Within one PHP major, higher minors are backwards
  compatible (8.4 runs 8.3 code bar non-fatal deprecations), so a floor ≤ target
  means OK.

This scan is a cheap static signal, **not** the authoritative answer: the real
proof that the port runs on the target is the **test suite executing on the target
PHP version inside DDEV** (the preservation gate). Report target compatibility as
verified by tests, or "not verified" when there are no tests.

## Gotchas

- **One PHP version per run.** Do not stack `php83` + `php84` Rector sets.
- **Never hardcode 8.5 anywhere.** Go through `php_target_unconfirmed` and
  `php_supported_for`, and detect the concrete capability (Rector constant, DDEV
  image) at runtime.
- A reconfigure (`ddev config --php-version=...`) needs `ddev restart` to take
  effect.
- `defaults.json` is the fallback; an exported `DRUPILOT_PHP_TARGET` always wins —
  check the env when a target seems "wrong".
