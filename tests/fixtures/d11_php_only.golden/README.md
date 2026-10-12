# d11_php_only golden (T-M5-01, T-M5-06)

The `php -l` legs of `tests/fixtures/d11_php_only` (`^11.3`, the target PHP 8.5: W = 8.3..8.5). Recorded on
2026-10-12 from the branch `m5/php-stage` (base `e591273`) by `scripts/analysis/php-lint-window.sh --subject
tests/fixtures/d11_php_only --window "8.3 8.4 8.5" --json`, in Docker, with no other step and no edit, on the images
listed in `tests/fixtures/php_window.golden/README.md`. `scripts/dev/golden.sh --check` fails on any byte edit
here; a deliberate re-recording runs `golden.sh --update` in its own commit, with a CHANGELOG entry.

## Files in this directory

| File | What it is |
|---|---|
| `raw/php-lint.w83-85.json` | every leg compiles; 8.4 and 8.5 report the implicitly nullable parameter of `Greeter::greet()`. The `each()` call of `d11_php_only.module` compiles: only the run fails on it (removed in PHP 8.0), which `php-target.sh` reports as a blocking item |
| `golden.json` | the manifest `golden.sh` checks: `data_hash` and the sha256 of every file here |

`tests/unit/php_window_golden.sh` feeds this recording, with the `php-target.sh` scan, through
`normalize-findings.sh`, `classify.sh` and `port-summary.sh --strict` (exit 3: the `each()` item blocks).
