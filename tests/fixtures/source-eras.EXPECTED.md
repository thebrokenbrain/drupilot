# Source-era fixtures — expected results

Small modules for `scripts/analysis/detect-source.sh` (AR-05, ADR 0016) and,
from T-M3-03 on, the upgrade-plan goldens. Each one exists for the signal it
carries; `tests/golden/detect-source/<name>.json` pins its full output.

| Fixture | Declares | Code signal | Expected S | Track | Confidence |
|---|---|---|---|---|---|
| `d7_minimal` | `core = 7.x` (`.info`) | `extends DrupalWebTestCase` (`.test`) | 7 | d7-assisted | high |
| `d8_legacy` | `core: 8.x`, no `core_version_requirement` | `extends WebTestBase` (`src/Tests/`) | 8 | standard | high |
| `d9_module` | `^9` | none | 9 | standard | medium |
| `d11_php_only` | `^11` | none (S = T = 11: no hop, PHP work only; M5 completes it) | 11 | standard | medium |
| `keep_current` | `^10.3 \|\| ^11 \|\| ^12` | none (core-strategy keeps the declaration, CC-36) | 10 | standard | medium |
