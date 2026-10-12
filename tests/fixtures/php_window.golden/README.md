# php_window golden (T-M5-01, T-M5-06)

The `php -l` legs of `tests/fixtures/php_window` on the two PHP windows of the 1.0 plan (T-M5-01): `^10.3 || ^11`
with the target PHP 8.4 (W = 8.1..8.4) and `^11.3 || ^12` with 8.5 (W = 8.3..8.5). Recorded on 2026-10-12 from
the branch `m5/php-stage` (base `e591273`) by `scripts/analysis/php-lint-window.sh --subject
tests/fixtures/php_window --window "<W>" --json`, in Docker, with no other step and no edit. `scripts/dev/golden.sh
--check` (the `golden` gate) fails on any byte edit here; a deliberate re-recording runs `golden.sh --update` in its
own commit, with a CHANGELOG entry.

## Files in this directory

| File | What it is |
|---|---|
| `raw/php-lint.w81-84.json` | the legs 8.1, 8.2, 8.3 and 8.4: every one compiles; 8.4 reports the implicitly nullable parameter of `Connection::label()` |
| `raw/php-lint.w83-85.json` | the legs 8.3, 8.4 and 8.5: 8.5 also reports the `(integer)` cast of `php_window.module` |
| `golden.json` | the manifest `golden.sh` checks: `data_hash` and the sha256 of every file here |

`meta.php_versions` holds the PHP release each image ran. The images (official, tags of `config/php/versions.json`):

| Image | Digest |
|---|---|
| `php:8.1-cli` | `sha256:76e563191d1ade120313a8736df24154d21da5155c0756f147c0b01bd19d9087` |
| `php:8.2-cli` | `sha256:118ef4fb1db5e866fb604f2f260da81f819a0a1eac87a4083f9194f48e00beee` |
| `php:8.3-cli` | `sha256:f1ed6d1fd0aa769ab94ca307b9deaf55fbc18434315b70e319cd79078515cd2b` |
| `php:8.4-cli` | `sha256:0177c7589c0715b63e5343342a7c1f1887db759ad0b0d6ad3bb949938bba6b47` |
| `php:8.5-cli` | `sha256:19642e172d3a542225225e202ddc2c11f67bdcbddf147b676c49338609b9290f` |

The `php-target.sh` scans of the same fixture, which need no Docker, are the goldens of `tests/golden/php-window/`
(`tests/unit/php_window_golden.sh`).
