---
name: php-target-tuning
description: >-
  Use this skill whenever a PHP version target matters for the port — i.e.
  deciding or changing DRUPILOT_PHP_TARGET, and translating it into the Rector
  PHP sets, the PHPStan level/expectations, the PHPCS sniffs and the DDEV
  php_version. It is the single source of truth for how one variable
  (DRUPILOT_PHP_TARGET, default 8.3) flows through the whole toolchain, and for
  the PHP 8.5 runtime-detection caveat (8.5 is NOT confirmed on any Drupal 11
  branch — detect at runtime, never hardcode). Invoke it from /drupilot-setup,
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
`php_target_supported VER` and `php_target_unconfirmed VER`.

## 2. The PHP 8.5 runtime-detection caveat (critical)

PHP support per Drupal 11 branch (verified, PROMPT §1.2):

| D11 branch | PHP min | PHP recommended | PHP 8.5 |
|---|---|---|---|
| 11.0 | 8.3 | 8.3 | No |
| 11.1 | 8.3 | 8.4 | No |
| 11.2 | 8.3 | 8.4 | No |
| 11.3 | 8.3 | 8.4 | not confirmed |

- **Minimum across the whole 11.x series: PHP 8.3.** Recommended: 8.4.
- **PHP 8.5 is NOT confirmed on any branch.** The exact Drupal 11 minor that
  officially supports it is unknown. **Never** emit "8.5 is supported" or assume
  a `php85`/`UP_TO_PHP_85` Rector set / a DDEV 8.5 image exists.
- When `php_target_unconfirmed "$TARGET"` returns true (i.e. 8.5): branch on it.
  Warn the user, prefer falling back to `8.3` for the actual run, and if they
  insist on 8.5, **detect at runtime** whether the relevant pieces exist (Rector
  `UP_TO_PHP_85` constant, the DDEV PHP image) and degrade gracefully if not —
  do not let an unconfirmed target break the flow.

## 3. How the target flows into each tool

Resolve `TARGET` first, then:

### Rector — PHP set selection (`rector.php`)

PHP sets are cumulative; target exactly **one** PHP version per run:

- `8.3` → `LevelSetList::UP_TO_PHP_83`, or the modern API `->withPhpSets(php83: true)`
- `8.4` → `UP_TO_PHP_84` / `->withPhpSets(php84: true)`
- `8.5` → **verify `UP_TO_PHP_85` / `php85` exists in the installed Rector
  version before using it.** If absent, fall back to `php84` and note the gap.

The Drupal sets (`Drupal10SetList::DRUPAL_10` + `Drupal11SetList::DRUPAL_11`) are
independent of the PHP target — always include both. The `rector.php.tmpl`
template encodes this; substitute `{{PHP_TARGET}}`. (The digests complementary
pass runs separately via `--config`, see the `minimal-port` skill.)

### PHPStan — level and expectations (`phpstan.neon`)

`DRUPILOT_PHPSTAN_LEVEL` (default `2`) is the base level for Phase 1 deprecation
detection; Phase 2 raises it to 5–6 via `DRUPILOT_PHPSTAN_LEVEL_REFACTOR`
(default `6`). The PHP target itself does not change the level number, but it
changes which language-level findings are valid — analyze against the same PHP
the code will run on. Substitute `{{PHPSTAN_LEVEL}}` in `phpstan.neon.tmpl`.

### PHPCS — sniffs (`phpcs.xml.dist`)

The standard is always `Drupal,DrupalPractice`. The coder branch is chosen by
`DRUPILOT_CODER_CONSTRAINT` (default `^8.3` → PHPCS 3.x; `^9.0` → PHPCS 4.x), not
by the PHP target — but a higher PHP target can surface additional sniff results
(e.g. new syntax). Keep coder and the PHP target consistent so sniffs match the
runtime.

### DDEV — `php_version`

```bash
ddev config --project-type=drupal11 --docroot=web --php-version="$(resolve_php_target)"
```

`ddev-up.sh` already passes `--php-version=$(resolve_php_target)`. If the target
is unconfirmed (8.5) and the DDEV image is unavailable, `detect-php.sh` flags it;
fall back to `8.3` rather than failing `ddev start`.

## 4. Changing the target

To retarget, set the env var (it overrides `defaults.json`):

```bash
export DRUPILOT_PHP_TARGET=8.4
```

Then re-derive: re-run `detect-php.sh --json`, regenerate `rector.php`,
`phpstan.neon` and `phpcs.xml.dist` from the templates with the new
`{{PHP_TARGET}}`, and reconfigure DDEV (`ddev config --php-version=8.4` then
`ddev restart`). Keep all four in lockstep — a mismatch between the Rector PHP
set, PHPStan, PHPCS and the DDEV runtime produces confusing, inconsistent
findings.

## Gotchas

- **One PHP version per run.** Do not stack `php83` + `php84` Rector sets.
- **Never hardcode 8.5 anywhere.** Always go through `php_target_unconfirmed` and
  detect the concrete capability (Rector constant, DDEV image) at runtime.
- A reconfigure (`ddev config --php-version=...`) needs `ddev restart` to take
  effect.
- `defaults.json` is the fallback; an exported `DRUPILOT_PHP_TARGET` always wins —
  check the env when a target seems "wrong".
