# refresh-data fixture

A tiny, hand-made input for `tests/unit/refresh_data_offline.sh`: one target
file (`data/targets/11.json`) and the fetch cache `scripts/dev/refresh-data.sh
--offline` reads instead of the network (`cache/`). The cached files are cut
down to the fields the script reads; their values come from the real sources
on 2026-10-04 (packagist p2 `drupal/core`, git.drupalcode.org at `11.3.18`,
api-d7 node 2891690), except the `11.5.0-beta1` tag, which is made up to
prove that a supported major ignores pre-release tags, and the trimmed
`core.libraries.yml` files and `.info.yml` listings at `10.6.18` and
`11.0.0` (`git/`), which hold just enough for the completeness check: `book`
disappears and is listed, nothing else does. The `require` of the packagist
entries holds only the PHP and `symfony/polyfill-*` packages (11.3.18's and
11.0.0's as on packagist; 11.3.0 inherits 11.3.18's, as p2's minified format
does, and 11.x-dev clears it with `"__unset"`), to prove the `polyfills`
derivation: what every tag of a minor requires.
