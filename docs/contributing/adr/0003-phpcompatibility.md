# 0003 — PHPCompatibility 10.0.0-alpha2 runs report-only from its own Composer tree

- **Status:** accepted
- **Date:** 2026-10-04
- **Decided by:** the 1.0 working session (R-AUTO-3), spike AR-41 (T-M2-09)

## Context

Stage `php` (M5) must check that the module works on every PHP minor of the
window W = [L..P]: L is the PHP floor of the declared core range, P is
`DRUPILOT_PHP_TARGET`. The checks are PHPStan `phpVersion`, `php -l` on each
minor of W, the `PHP_LOW` test leg and PHPCompatibility `testVersion L-P`
(AR-01, AR-08). drupilot 0.9 has no PHP-target gate. `run-phpcs.sh` only
passes `--runtime-set testVersion <target>-` for a project ruleset that
happens to reference PHPCompatibility, and it never installs the standard.
The static floor comes from `detect-php-floor.sh`: 11 ERE signals for
8.2 to 8.4, floor only.

X6 adopted PHPCompatibility, pinned `@alpha` and recorded in the lock, as a
non-blocking stage. It degrades to `detect-php-floor.sh` on any install
failure or crash, and it runs from a separate Composer tree on the bed, so
it never perturbs the bed's own dev toolchain (coder 8.3.31 needs PHPCS
`^3.13`; a D12 bed has coder 9 and PHPCS 4). X6 left the 8.4/8.5 coverage
unverified. This spike answers four questions:

- does it install in a separate tree, and with which PHPCS line;
- what does it detect for PHP 8.4 and 8.5 on a php_window sample;
- which `config/php/rules.json` entries does it cover;
- how M5 must wire it.

The answer decides whether T-M5-05 ships `run-phpcompat.sh` or a stub that
returns `skipped`, and how T-M5-07 maps its findings.

## Decision

**X6 is enabled.** `scripts/analysis/run-phpcompat.sh --json` (T-M5-05) is
implemented, not stubbed. It is report-only: a PHPCompatibility result never
blocks a port and never fails stage `php`.

1. **Pins.** The tree holds exactly these seven packages, all exact
   versions (packagist p2, read 2026-10-04):

   | package | version | dist reference |
   |---|---|---|
   | phpcompatibility/php-compatibility | 10.0.0-alpha2 | e0f0e5a3dc81… |
   | squizlabs/php_codesniffer | 4.0.4 | bbdc3d053262… |
   | phpcsstandards/phpcsutils | 1.2.3 | 5f35d9408c54… |
   | dealerdirect/phpcodesniffer-composer-installer | v1.2.1 | 963f0c67bffd… |
   | phpcompatibility/phpcompatibility-symfony | 2.0.0-alpha3 | e91a96a930a0… |
   | phpcompatibility/phpcompatibility-paragonie | 2.0.0-alpha2 | 7a979711c87d… |
   | phpcompatibility/phpcompatibility-passwordcompat | 2.0.0-alpha1 | 8e67bd0a47a9… |

   The pins go in `config/toolchain-reference.json` as a cell-independent
   `phpcompat` set (T-M2-10), `verified: true`, `src: ADR 0003`. The lock
   records them under `.toolchain.phpcompat` (name, version, dist
   reference) plus the standards list used. Composer accepts the exact root
   constraint `10.0.0-alpha2` without an `@alpha` flag and without a
   `minimum-stability` change: it derives the stability flag from an exact
   root constraint. The same holds for the three Symfony-side alphas, whose
   own `^10.0@dev` requirement is satisfied by the pinned alpha. The pins
   do not move in non-deterministic mode: an alpha is never range-resolved.

2. **PHPCS 4.0.4, not 3.13.6.** Both lines install and detect exactly the
   same thing on the sample (byte-identical matrices, on PHP 8.3 and on
   8.5). The tree never shares PHPCS with coder, so the coder line does not
   matter. PHPCompatibility's `dev-develop` (2026-09-21) already requires
   `squizlabs/php_codesniffer ^4.0.2` and PHP `>=7.2`. The next 10.x
   release will therefore most likely drop PHPCS 3, and the 4.x pin makes
   that bump a one-line change. `phpcsutils` 1.2.x needs `^3.13.5 ||
   ^4.0.1`, which 4.0.4 satisfies.

3. **Placement and install.** The tree lives in
   `<root>/.drupilot/phpcompat/`, next to `verify-core-matrix.sh`'s
   `.drupilot/cores/`. That directory is gitignored (`*`), inside the DDEV
   mount, and outside the bed's own `composer.json`. `run-phpcompat.sh`
   installs it on first use, idempotently: it skips when
   `vendor/bin/phpcs` exists and `composer.lock` lists exactly the pinned
   versions. The tested sequence is:

   ```bash
   # composer.json written first: allow-plugins MUST be set before require
   printf '%s\n' '{"config":{"allow-plugins":{"dealerdirect/phpcodesniffer-composer-installer":true}}}' \
     > <root>/.drupilot/phpcompat/composer.json
   ddev exec timeout 600 "$(ddev_global_composer <root>)" \
     --working-dir=/var/www/html/.drupilot/phpcompat \
     require --dev --no-interaction --no-progress \
     phpcompatibility/php-compatibility:10.0.0-alpha2 \
     squizlabs/php_codesniffer:4.0.4 phpcsstandards/phpcsutils:1.2.3 \
     dealerdirect/phpcodesniffer-composer-installer:v1.2.1 \
     phpcompatibility/phpcompatibility-symfony:2.0.0-alpha3 \
     phpcompatibility/phpcompatibility-paragonie:2.0.0-alpha2 \
     phpcompatibility/phpcompatibility-passwordcompat:2.0.0-alpha1
   ```

   The installer plugin sets `installed_paths` itself, so it never has to
   be set by hand. Composer is named by absolute path because it is not the
   first word of the `ddev exec` line (`ddev_global_composer`). Under
   `timeout`, a bare `composer` can resolve to the bed's
   `vendor/bin/composer`.

4. **Invocation.** It runs in the bed, on P:

   ```bash
   ddev exec timeout 300 .drupilot/phpcompat/vendor/bin/phpcs \
     --standard=PHPCompatibility[,PHPCompatibilitySymfonyPolyfillPHP8x...] \
     --runtime-set testVersion "<L>-<P>" \
     --extensions=php,module,inc,install,theme,profile,engine \
     --report=json -q <subject relative to the root>
   ```

   - **testVersion.** It is derived from `php_window L U` (plan.sh), where U
     is the window's upper bound: the higher of P and the ceiling of the
     declared core range (`php_bounds_for_range`), the same bound ADR 0002
     uses for the compat pass, since the module must run on every PHP a
     core it declares supports:
     - an empty window means status `skipped` (reason `empty-php-window`);
     - otherwise the value is `<first>-<last>` of the window, which is
       `L-U`;
     - it is never an open `L-`;
     - it is never empty. `ddev exec` drops an empty argument, and PHPCS
       then takes the next flag as the testVersion.
   - **Standards.** Add one `PHPCompatibilitySymfonyPolyfillPHP<xy>` for
     each `symfony/polyfill-php<xy>` in the T-M5-04 polyfill intersection,
     the `require` of `core/composer.json` across every minor of C, when the
     tree lists that standard (`phpcs -i`). `polyfill-php86` has no ruleset
     in 2.0.0-alpha3, so it adds nothing; log that. Each polyfill ruleset
     is `PHPCompatibility` with excludes, so listing `PHPCompatibility`
     first changes nothing (verified).
   - **Extensions.** Only the PHP-bearing extensions `detect-php-floor.sh`
     scans. The `.yml`, `.md`, `.txt` and `.info` files that `run-phpcs.sh`
     passes would only yield `Internal.NoCodeFound`.
   - **Never `phpcbf`** with these standards. The one known false positive,
     property hooks, is flagged `fixable: true`.
   - The project's own ruleset is never read or modified (CC-13).
     `run-phpcs.sh` and its testVersion handling stay as in 0.9.

5. **Status** (`raw/phpcompat.json`, its shape goes into `schemas/`):
   - `ok`: exit code 0 to 3 (the PHPCS 4 bitmask: 1 fixable, 2 non-fixable),
     stdout parses as JSON with `.totals`, and no message has source
     `Internal.Exception`.
   - `degraded`: anything else. Observed cases:
     - an install failure (offline exit 100; a missing allow-plugins exit 1
       with a half-installed vendor);
     - exit 16 (standard not installed), 64, 124 (timeout), 127 (no tree)
       or 255 (a PHP fatal);
     - unparsable stdout;
     - an `Internal.Exception` message (for example an invalid testVersion,
       which is reported in the JSON with exit 2, not as a crash).

     The script then runs `detect-php-floor.sh --subject <s> --json` and
     stores it as `fallback`. Stage `php` continues ("a crash in
     PHPCompatibility never fails the stage").
   - `skipped`: the window is empty, or DDEV cannot be started.
   - `Internal.NoCodeFound` messages are dropped, never counted.

6. **Findings to worklist** (T-M5-07). Normalize first: dedupe on
   `(file, line, source)`, then group per `(file, line)`. The backtick
   operator is reported twice, once per backtick; an `ereg()` call is
   reported by both `RemovedExtensions` and `RemovedFunctions`. Classify
   by the PHPCompatibility convention:
   - an ERROR from a `New*` sniff is **floor**: the construct needs a PHP
     above L;
   - any other ERROR is **removed**: removed in a minor of W;
   - a WARNING is **deprecated**: deprecated in a minor of W.

   Correlate each group with `config/php/rules.json` through a new per-rule
   `phpcompat` array of sniff codes (the codes are in the Evidence table).
   A matched group corroborates that rule's own item, whose class
   `php_rule_class` decides; it never adds a second item. An unmatched
   group becomes:
   - floor: `lane: human`, `reason: fix-needs-php-above-floor`;
   - removed: `lane: human`, `reason: removed-in-target-php`,
     **`blocking: false`**, `source: phpcompat`. Blocking stays reserved to
     the rules.json `removed-blocking` entries that the `php -l` leg
     confirms (T-M5-06): an alpha with one known false-positive class must
     not block a port;
   - deprecated: `lane: human`, report-only, non-blocking. The reason name
     belongs to M5; the proposal is `deprecated-in-php-window`.

   **Known false positive.** A `Syntax.*` ERROR on a file that `php -l`
   accepts on every minor of W is dropped as a tokenizer false positive and
   kept in `raw/`. This is the property-hooks case with L >= 8.4.

7. **Timeouts.** Both run with the container's own `timeout`, because
   `run_with_timeout` does not propagate through `ddev exec`: `timeout 600`
   for the install and `timeout 300` for a run. Measured: under 0.7 s per
   real module, 13.4 s for 2,395 core files, and a cold install of 2.6 s.

8. **`detect-php-floor.sh` stays.** It is the fallback and the bed-less
   pre-check, gains the 8.5 row in T-M5-08, and is demoted as planned.

## Evidence

**Sources read on 2026-10-04.**
- `repo.packagist.org/p2/` for:
  - phpcompatibility/php-compatibility (+ `~dev`);
  - phpcsstandards/phpcsutils;
  - squizlabs/php_codesniffer;
  - phpcompatibility/phpcompatibility-{symfony,paragonie,passwordcompat};
  - dealerdirect/phpcodesniffer-composer-installer;
  - drupal/coder.

  The minified p2 entries were expanded with a jq reducer. Results:
  - 10.0.0-alpha2 (2025-11-28) requires `php >=5.4`,
    `squizlabs/php_codesniffer ^3.13.3 || ^4.0` and
    `phpcsstandards/phpcsutils ^1.1.2`;
  - the newest 9.x is 9.3.5 (2019-12-27);
  - there is no alpha3 and no 10.0.0;
  - PHPCS: newest 3.13.x is 3.13.6, newest 4.x is 4.0.4 (both 2026-08-06);
  - coder 8.3.31 needs `^3.13`, coder 9.0.1 needs `^4.0.1`.
- `raw.githubusercontent.com/PHPCompatibility/PHPCompatibility/10.0.0-alpha2/`
  `CHANGELOG.md`, `README.md` and `composer.json`.
  - 8.4 sniffs from alpha1: RemovedImplicitlyNullableParam,
    ForbiddenClassNameUnderscore, RemovedTriggerErrorLevel,
    RemovedDbaKeySplitNullFalse, RemovedXmlSetHandlerCallbackUnset,
    NewClassMemberAccessWithoutParentheses, NewExitAsFunctionCall,
    New{Abstract,Final}Properties and NewPropertiesInInterfaces.
  - 8.5 in alpha2: RemovedLanguageConstructs ("initial version": the
    backtick only), NewStaticAvizProperties, and "list based" sniff updates.
  - No sniff names property hooks, the pipe operator or clone-with.
  - The README makes Composer the only supported install, with
    allow-plugins for the installer.
- php.net `migration84.deprecated`, `migration85.deprecated` and
  `migration80.incompatible`.
- git.drupalcode.org raw `core/composer.json` at 10.3.0, 10.6.0, 11.0.0,
  11.2.0, 11.3.0 and 11.4.8, for the polyfills. The first three have none.
  11.2.0 has php84, 11.3.0 has php84 and php85, and 11.4.8 has php84,
  php85 and php86.

**Bed and trees.**
- Bed: DDEV `dpl-m2-phpcompat-d11`, Drupal 11.4.8, PHP 8.3.33,
  Composer 2.10.3, provisioned with:
  - `DRUPILOT_PHP_TARGET=8.3 ddev-up.sh --name dpl-m2-phpcompat-d11 --dir $B --json`;
  - then `install-toolchain.sh --dir $B --no-core-dev --json`, which gave
    coder 8.3.31 and PHPCS 3.13.6.
- Three trees were installed under `$B/.drupilot/`:
  - `phpcompat`: PHPCS 4.0.4;
  - `phpcompat-p3`: PHPCS 3.13.6;
  - `phpcompat-sym`: PHPCS 4.0.4 plus the Symfony polyfill rulesets.

  All exited 0, with `installed_paths` set by the plugin.
- Before and after, the bed was unchanged:
  - `ddev composer show` output was identical;
  - the bed's `composer.json` and `composer.lock` matched their earlier
    sha256 (`27fb5a0d…ecfa`);
  - the sha256 over every file in `vendor/squizlabs` and
    `vendor/drupal/coder` was identical;
  - `phpcs -i` still listed Drupal, DrupalPractice, VariableAnalysis and
    SlevomatCodingStandard.
- Without allow-plugins, `require` exits 1 ("blocked by your allow-plugins
  config").

**Sample.** `$LAB/m2/ar41/sample/phpwin_sample` has 60 files, one construct
each. Each window was run as
`ddev exec .drupilot/phpcompat/vendor/bin/phpcs --standard=PHPCompatibility --runtime-set testVersion $tv --extensions=php,module,inc,install,theme,profile --report=json -q web/modules/custom/phpwin_sample`.
Each run takes 0.45 s, exit 3.

| window | errors | warnings |
|---|---|---|
| 8.1-8.5 | 28 | 52 |
| 8.3-8.5 | 23 | 52 |
| 8.1-8.3 | 28 | 11 |
| 8.5- | 12 | 52 |

The same matrix came out of PHPCS 3.13.6 on PHP 8.3, and of PHPCS 4.0.4
and 3.13.6 in `php:8.5-cli` (PHP 8.5.11,
`php@sha256:19642e172d3a542225225e202ddc2c11f67bdcbddf147b676c49338609b9290f`).
The bed PHP does not change what is detected.

The windows behave as documented: a deprecation is reported when P is at
or above its version, a `New*` construct when L is below its version, and a
removal in every window. Table legend: **all** means all four windows;
**≥8.4 / ≥8.5** means every window whose top is 8.4 or 8.5 (all but 8.1-8.3);
**<8.x** means the windows that start below 8.x; **dpf** is
`detect-php-floor.sh`, run per file; **php -l** is `php -l` in
`php:8.1/8.3/8.4/8.5-cli`.

PHP 8.4 deprecations (php.net migration84.deprecated):

| construct | rules.json | PHPCompatibility code | windows | dpf | php -l |
|---|---|---|---|---|---|
| `Foo $x = NULL` | p84-implicit-nullable | RemovedImplicitlyNullableParam.Deprecated (W, 3/3 params) | ≥8.4 | - | depr 8.4, 8.5 |
| `E_STRICT` | p84-e-strict | RemovedConstants.e_strictDeprecated | ≥8.4 | - | - |
| `lcg_value()` | p84-lcg-value | RemovedFunctions.lcg_valueDeprecated | ≥8.4 | - | - |
| fputcsv/fgetcsv/str_getcsv, no escape | p84-csv-escape | RemovedProprietaryCSVEscaping.DeprecatedParamNotPassed (3/3) | ≥8.4 | - | - |
| `trigger_error(…, E_USER_ERROR)` | — | RemovedTriggerErrorLevel.Deprecated | ≥8.4 | - | - |
| mysqli_ping/kill/refresh, MYSQLI_REFRESH_* | — | RemovedFunctions.*, RemovedConstants.* | ≥8.4 | - | - |
| `class _` | — | ForbiddenClassNameUnderscore.Deprecated | ≥8.4 | - | depr 8.4, 8.5 |
| session_set_save_handler (6 args) | — | RemovedFunctionParameters.* | ≥8.4 | - | - |
| xml_set_object, stream_context_set_option (2 args), dba_key_split(NULL) | — | detected | ≥8.4 | - | - |
| CURLOPT_BINARYTRANSFER, SUNFUNCS_RET_*, DOM_PHP_ERR | — | RemovedConstants.* | ≥8.4 | - | - |
| new ReflectionMethod('A::b') | — | **not detected** | - | - | - |

PHP 8.5 deprecations (php.net migration85.deprecated):

| construct | rules.json | PHPCompatibility code | windows | dpf | php -l |
|---|---|---|---|---|---|
| backtick operator | p85-backtick | RemovedLanguageConstructs.t_backtickDeprecated (twice per use) | ≥8.5 | - | depr 8.5 |
| (integer)/(boolean)/(double)/(binary) | p85-cast-names | RemovedTypeCasts.{integer,boolean,double,binary}Deprecated | ≥8.5 | - | depr 8.5 |
| curl_close() | p85-noop-close | RemovedFunctions.curl_closeDeprecated | ≥8.5 | - | - |
| finfo_close, imagedestroy, xml_parser_free, curl_share_close | (p85-noop-close) | RemovedFunctions.* | ≥8.5 | - | - |
| DATE_RFC7231, MHASH_*, mysqli_execute, socket_set_timeout, report_memleaks | — | RemovedConstants/Functions/IniDirectives | ≥8.5 | - | - |
| `DateTimeInterface::RFC7231` | — | **not detected** | - | - | - |
| `case X;` | p85-case-semicolon | **not detected** | - | - | depr 8.5 |
| `$http_response_header` | p85-http-response-header | **not detected** | - | - | depr 8.5 |
| Reflection*::setAccessible() | p85-set-accessible | **not detected** | - | - | - |
| `$a[NULL]`, array_key_exists(NULL, …) | p85-null-offset | **not detected** | - | - | - |
| `__debugInfo()` returning NULL | p85-debuginfo-null | **not detected** | - | - | - |
| chr(300) / ord('ab') | p85-chr-range / p85-ord-single-byte | **not detected** | - | - | - |
| \PDO::MYSQL_ATTR_* | p85-pdo-mysql-constants | **not detected** | - | - | - |
| __sleep()/__wakeup() (soft-deprecated) | deny-sleep/wakeup | not detected (no runtime deprecation) | - | - | - |

Constructs above a floor:

| construct | PHPCompatibility code (ERROR) | windows | dpf | php -l |
|---|---|---|---|---|
| readonly class (8.2) | NewReadonlyClasses.Found | <8.2 | 8.2 | fatal 8.1 |
| typed class constant (8.3) | NewTypedConstants.Found | <8.3 | 8.3 | fatal 8.1 |
| `A::{$x}` (8.3) | NewDynamicClassConstantFetch.Found | <8.3 | - | fatal 8.1 |
| json_validate() (8.3) | NewFunctions.json_validateFound | <8.3 | 8.3 | - |
| `public private(set)` (8.4) | NewKeywords.t_private_setFound | <8.4 | 8.4 | fatal 8.1, 8.3 |
| `new A()->m()` (8.4) | NewClassMemberAccessWithoutParentheses.Found | <8.4 | - | fatal 8.1, 8.3 |
| array_find/any/all, mb_trim (8.4) | NewFunctions.*Found (suppressed by PolyfillPHP84) | <8.4 | 8.4 | - |
| property hooks (8.4) | **wrong sniff**: RemovedCurlyBraceArrayAccess.Removed, fixable, also in 8.5- | all | - | fatal 8.1, 8.3 |
| static `private(set)` (8.5) | NewStaticAvizProperties.Found | <8.5 | 8.4 | fatal 8.1, 8.3, 8.4 |
| array_first/array_last (8.5) | NewFunctions.*Found (suppressed by PolyfillPHP85) | <8.5 | - | - |
| pipe `\|>` (8.5) | **not detected** | - | - | fatal 8.1, 8.3, 8.4 |
| `clone($o, [...])` (8.5) | **not detected** | - | - | fatal 8.1, 8.3, 8.4 |
| `#[\Override]` on a property (8.5) | **not detected** | - | 8.3 | fatal 8.3, 8.4 |
| `#[\Override]`, `#[\Deprecated]`, `#[\NoDiscard]` on methods | not detected (harmless on older PHP) | - | 8.3 / 8.4 / - | - |

Other rules.json entries:

| rules.json | PHPCompatibility code | windows |
|---|---|---|
| p82-interpolation | RemovedDollarBraceStringEmbeds.DeprecatedVariableSyntax | all |
| p82-utf8-encode | RemovedFunctions.utf8_{encode,decode}Deprecated | all |
| p83-get-class-no-args | RemovedGetClassNoArgs.ArgMissing | all |
| p80-optional-before-required | RemovedOptionalBeforeRequiredParam.Deprecated80 | all |
| p74-implode-order | RemovedImplodeFlexibleParamOrder.Removed (ERROR) | all |
| p81-strftime | RemovedFunctions.{strftime,gmstrftime}Deprecated | all |
| p81-filter-sanitize-string | RemovedConstants.filter_sanitize_{string,stripped}Deprecated | all |
| p81-null-to-internal | **not detected** (a runtime type) | - |
| removed-mysql-ext | RemovedExtensions.mysql_DeprecatedRemoved + RemovedFunctions.mysql_queryDeprecatedRemoved (ERROR) | all |
| removed-ereg-ext | RemovedExtensions.eregDeprecatedRemoved + RemovedFunctions.{ereg,eregi_replace,split}DeprecatedRemoved | all |
| removed-each | RemovedFunctions.eachDeprecatedRemoved | all |
| removed-create-function | RemovedFunctions.create_functionDeprecatedRemoved | all |

All codes are prefixed `PHPCompatibility.<Category>.`; the full codes are in
`logs/sample-phpcs4/tv-*.json`.

**rules.json coverage.** PHPCompatibility detects 18 of the 30 entries:
- all 4 PHP 8.4 entries;
- 3 of the 11 PHP 8.5 entries (backtick, cast names, no-op close);
- all 4 `removed-no-rule` entries, as ERROR in every window;
- 7 of the 8 older compat and report-only entries.

It misses 11:
- p81-null-to-internal;
- 8 PHP 8.5 entries (case-semicolon, set-accessible, null-offset,
  debuginfo-null, chr-range, ord-single-byte, pdo-mysql-constants,
  http-response-header);
- the two `__sleep`/`__wakeup` deny entries.

`deny-override-on-properties` is an output-side rule, so it does not apply.

Beyond rules.json it reports 24 further 8.4/8.5 deprecations (functions,
constants, parameters, ini directives).

Compared with `detect-php-floor.sh`, which flags 10 of the 17 floor
constructs (one first hit per signal, polyfill-blind, no 8.5 row, no
deprecations), PHPCompatibility:
- adds the deprecations and removals;
- adds polyfill awareness;
- adds `A::{$x}`, `new A()->m()` and array_first/last.

It misses what `php -l` across W catches: the pipe, clone-with, property
hooks with the right label, `#[\Override]` on a property, `case X;` and
`$http_response_header`.

The 8.5 runtime-value deprecations (chr, ord, null offset, `__debugInfo`,
setAccessible, `PDO::MYSQL_ATTR_*`) are found by none of the three static
checks.

**The two M5 plans, from the kept tree.** Both were run with `docker run …
php:8.X-cli php .drupilot/phpcompat*/vendor/bin/phpcs …`:

| plan | P | testVersion | polyfill rulesets | errors | warnings | floor | removed | deprecated |
|---|---|---|---|---|---|---|---|---|
| `^10.3 \|\| ^11` | 8.4 | 8.1-8.4 | none, since core 10.3 has no polyfill | 28 | 36 | 16 | 12 | 36 |
| `^11.3 \|\| ^12` | 8.5 | 8.3-8.5 | PolyfillPHP84 and PolyfillPHP85 | 17 | 52 | 5 | 12 | 52 |

The 12 removed findings of the second plan include the 2 property-hooks
false positives.

**Real code and false positives.** Each module was run 3 times per window
(`logs/real/timing.txt`):

| subject | files | findings in 8.1-8.5, 8.3-8.5 and 8.1-8.3 | wall time with `ddev exec` |
|---|---|---|---|
| autologout 8.x-1.4 (`$LAB/shared/autologout`, .git excluded) | 24 | 0 | 628-671 ms (0.27 s inside the container) |
| legacy_widgets | 15 | 0 | 526-568 ms |

Core 11.4.8 (node, user, system and views):
- with the polyfill rulesets and tests excluded: 666 files, 0 findings,
  4.8 s;
- plain, tests included: 2,395 files, 0 findings, 13.4 s, plus 6
  `Internal.NoCodeFound` warnings for empty fixture files.

The sample's control file (enums, readonly promotion, `never`, `match`,
nullsafe, named arguments, first-class callables, plugin attributes) gave 0
findings in every window.

Faults seen:
- the property-hooks mislabel, which is ERROR and fixable;
- the duplicate backtick report;
- MYSQLI_STORE_RESULT_COPY_DATA attributed to 8.1, while php.net lists it
  under 8.4.

**Failure probes.**

| probe | result |
|---|---|
| testVersion `8.5-8.1` or `abc` | exit 2, plus an `Internal.Exception` ("Invalid range in provided PHPCompatibility testVersion") inside valid JSON |
| testVersion `9.9-`, `8.3-8.6` or `8.6-` | accepted silently |
| empty testVersion through `ddev exec` | a text report |
| no tree | exit 127 |
| php-compatibility removed from the tree | exit 16, "the "PHPCompatibility" coding standard is not installed" |
| phpcsutils removed from the tree | exit 255, PHP fatal |
| `composer require` with `--network none` | exit 100, composer.json reverted |
| cold install in `composer:2` with an empty cache | exit 0 in 2.6 s, and the tree then runs unchanged in `php:8.3-cli` |

**Rerun.** Every exact command, in order, is in `$LAB/m2/ar41/notes.md`
(the lab directory next to the repository, R-LAB-1). The raw JSON is in
`$LAB/m2/ar41/logs/`. `matrix.py` rebuilds the matrix, and
`logs/coverage-table.md` is the generated per-file table.

## Consequences

- **T-M5-05** implements `run-phpcompat.sh --json` as decided, not as a
  stub. Its unit test stubs the binary to cover each case and expects
  `degraded` plus the `fallback` with exit 0:
  - exits 255, 16 and 127;
  - invalid JSON;
  - an `Internal.Exception` message;
  - an install exit 100.

  It also covers an empty window, which gives `skipped`.
- **T-M5-01 / goldens.** The `php_window` fixture takes this spike's
  constructs. A golden of the normalized PHPCompatibility findings pins the
  coverage, so a pin bump shows its coverage diff in its own commit.
- **T-M5-02 data.** Three changes to `config/php/rules.json`:
  - each rule gains a `phpcompat` array with the codes above, and its
    schema is updated;
  - `p74-implode-order` already carries `removed_in: "8.0"` (fixed in M2
    after this spike reported it: php.net migration80.incompatible says
    "Calling implode() with parameters in a reverse order … is no longer
    supported", and PHPCompatibility reports it as `Removed`);
  - `p85-noop-close` can cite php.net migration85.deprecated for
    curl_share_close, finfo_close, imagedestroy and xml_parser_free (read
    in this spike).
- **T-M2-10** adds the cell-independent `phpcompat` set to
  `config/toolchain-reference.json`. The lock gets `.toolchain.phpcompat`.
- **T-M5-06 stays mandatory.** The `php -l` legs catch the syntax that
  PHPCompatibility misses. The 8.5 runtime-value deprecations stay with the
  rules.json compat rules (the Rector compat pass, ADR 0002) and with the
  tests on P.
- **T-M5-07** maps the findings per Decision item 6, and states in
  `port-report.md` that the check ran with an alpha (or that it degraded,
  and why).
- `/drupilot-clean` removes the tree with the workspace. M5 checks that
  `--level vendor` also drops `.drupilot/phpcompat/vendor`.
- No new public config key. An `advanced` off switch is added only if M5
  needs one.
- **Recheck:**
  - on any new php-compatibility 10.x release seen on packagist (an
    alpha3, or 10.0.0, which also ends the alpha caveat), rerun the golden
    and the property-hooks probe; the PHPCS 4.0.4 changelog has no
    property-hook tokenizer support;
  - when a Symfony `PolyfillPHP86` ruleset appears;
  - before P can be 8.6.
