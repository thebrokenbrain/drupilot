# Findings goldens (T-M4-05, ADR 0022)

Each directory holds one subject's raw reports of the `assess` stage and the `findings.json` that
`scripts/ai/normalize-findings.sh` makes from them (`meta.generated_at` left out). The
`findings_golden` unit test recomputes every `findings.json` from its `raw/` files, Docker-free, on
the data snapshot `golden.json` pins, and compares them; `golden.sh` pins every file by its sha256.

| Case | Subject | What it covers |
|---|---|---|
| `legacy_widgets` | `tests/fixtures/legacy_widgets` | Rector, PHPStan (hard and soft deprecations, untyped errors), port-safety, signature and metadata findings, anchors in classes, functions and a submodule. PHPCS fell back to `Drupal,DrupalPractice` (the fixture's ruleset needs PHPCompatibility) and found nothing. |
| `acme_core` | `tests/fixtures/monorepo` `acme_core` | The clean control: no metadata finding, one PHPStan and two PHPCS findings. |
| `acme_api` | `tests/fixtures/monorepo` `acme_api` | The `services-arity` and `undeclared-deps` metadata findings, with the other monorepo modules on the bed. |

## Recording

Recorded in the lab on a Drupal 11.4.8 test-bed with PHP 8.3 and the toolchain of cell 11. Each case was alone
on the bed: `legacy_widgets` alone, then the monorepo's modules together. Each module had its own git
repository. The recording ran these steps:

```bash
bash scripts/ai/extract.sh --subject web/modules/custom/<case> --json
cp <state dir>/raw/04-assess-*.json tests/golden/findings/<case>/raw/
bash scripts/ai/normalize-findings.sh --raw-dir tests/golden/findings/<case>/raw \
  --target-major 11 --soft-policy report --json | jq 'del(.meta.generated_at)'   # then canon_json
```

Two recordings of the same tree gave the same raw files outside their `meta` (DET-2). A re-recording is
its own commit with a CHANGELOG entry, followed by `scripts/dev/golden.sh --update --only findings`.
