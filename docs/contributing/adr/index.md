# Architecture decision records

Each record states one decision, why it was taken and what it implies.
[0000](0000-owner-decisions.md) holds the owner's answers to the 1.0 plan's
open questions; the 1.0 spikes add 0001–0006 (0005 is AR-39's, in M9); the others record forks the
working session decided on its own, choosing the option that keeps 0.9
behaviour.

| ADR | Decision |
|---|---|
| [0000](0000-owner-decisions.md) | Owner decisions for drupilot 1.0 |
| [0001](0001-toolchain-pins.md) | Toolchain cell 11 pins drupal-rector 1.1.3 with Rector 2.6.1 and PHPStan 2.2.16 |
| [0002](0002-rector-compat-pass.md) | PHP compat rules run in a second, narrow Rector pass |
| [0003](0003-phpcompatibility.md) | PHPCompatibility 10.0.0-alpha2 runs report-only from its own Composer tree |
| [0004](0004-d12-bed.md) | The provisional D12 cell pins Rector 2.6.1 and coder 9, without drush |
| [0006](0006-headless-ask.md) | Hooks keep `ask`: headless `claude -p` denies it in every permission mode |
| [0007](0007-golden-next-to-the-fixture.md) | The lab goldens live next to their fixture, not inside it |
| [0008](0008-live-router-evals-harness.md) | Live router evals deny every tool through a hook |
| [0009](0009-tab-sequence-counts-shown-tabs.md) | The frozen tab sequence counts the tabs a command shows by header |
| [0010](0010-schema-validator.md) | check-jsonschema validates the schemas in CI, with a jq fallback |
| [0011](0011-release-validation-without-strict.md) | release.sh validates the plugin without `--strict` |
| [0012](0012-docs-site-in-m1.md) | The docs site starts with the pages that exist |
| [0013](0013-config-keys-scope.md) | What the config-keys gate scans, and the comment limit |
| [0014](0014-version-data-hard-gates.md) | The schemas mark what a hard gate reads, and the data follows the source |
| [0015](0015-toolchain-cells.md) | How a test-bed finds its toolchain cell, and how a 0.9 lock is read |
| [0016](0016-source-era-fallback.md) | The source era when no code signal decides, and its confidence |
| [0017](0017-upgrade-plan-resolver.md) | What the upgrade-plan resolver decides where AR-04/AR-06 are silent |

A new ADR takes the next free number, gets a line here and a nav line in
`mkdocs.yml` in the same change (the `docs` gate rejects an orphan page).
