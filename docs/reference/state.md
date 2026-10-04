# Per-module state

drupilot keeps one record per module/theme, `state.json`, in the same hidden state dir as `assess.json` and `last-test.json`: which stages were reached and when, and a snapshot of what a portfolio view needs. It is machine state, so it is hidden on purpose: it survives `git clean` or a rebuilt test-bed (otherwise the next step would restart at `/drupilot-port`), it can never leak into a patch, and one data dir holds every module's record, so `/drupilot-status --all everything` finds them all without walking your project trees. The visible `.drupilot/` folder keeps the human-facing reports; the record is rendered on demand.

The record is written by the flow, not by memory: `port-report.sh` records `ported` / `refactored` (from the manifest's phase), `run-phpunit.sh` records `tested` after a whole-suite run whose preservation is `verified` or `verified-partial` and carries every recorded run's verdict, `verify-core-matrix.sh` and `make-patch.sh` add their verdict and patch, and `/drupilot-setup`, `/drupilot-assess` and `/drupilot-contribute` record `setup`, `assessed` and `contributed` through `scripts/env/state.sh record`. `next-step.sh` (the router and `/drupilot-status`) and the post-edit hook read it.

| Key | Meaning |
| --- | --- |
| `schema` | Record version (`1`). |
| `subject`, `machine_name`, `type` | The module/theme directory (absolute), its machine name and type. |
| `drupal_root`, `ddev_project` | The test-bed (workspace) it lives in and its DDEV project name. |
| `origin`, `placement` | The developer's checkout a loose subject was placed from, and how (`move` / `symlink` / `copy`). |
| `stage`, `stages` | The highest stage reached (`setup` < `assessed` < `ported` < `refactored` < `tested` < `contributed`; it never goes down without `DRUPILOT_STATE_FORCE`), and the time each stage was last recorded. |
| `effort`, `assessed_at` | The assessment's S/M/L/XL verdict and when it was made. |
| `git` | `branch`, `commit` and `dirty` (uncommitted changes) of the subject's checkout. |
| `toolchain` | From the lock: `drupal_core`, `php_target`, `core_strategy`, `packages` (Rector, drupal-rector, PHPStan, coder, Drush, core-dev versions). |
| `tests` | The last recorded PHPUnit run: `status`, `preservation`, `executed`, `tests_failed`, group counts, `recorded_at`, and `fresh` (computed on the current sources). |
| `core_matrix` | The last core matrix: `verdict`, `d10_support`, `generated_at`, `fresh`. |
| `patch` | The last patch made: `path`, `kind` (`local` / `issue` / `contribution`), `at`. |
| `portfolio` | Set when the module is ported by `/drupilot-layers`: `dir` (the set) and `layer` (its porting layer), written by `state.sh record\|refresh --portfolio DIR --layer N`. |
| `created`, `updated`, `drupilot_version` | Record timestamps and the drupilot that last wrote it. |

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" show --subject web/modules/custom/foo   # one module, merged with the current verdicts
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" list --json                              # every record in drupilot's data dir
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" list --root ~/drupal-ports --json       # every module under a directory of workspaces
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" list --registry ports.txt               # one path per line (module dirs or dirs to scan)
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" record --subject web/modules/custom/foo --stage assessed --effort M
bash "$CLAUDE_PLUGIN_ROOT/scripts/env/state.sh" refresh --subject web/modules/custom/foo --portfolio web/modules/custom --layer 2
```

`show` and `list` are read-only (they never create a state dir); the table goes to stderr and `--json` puts the payload on stdout. A module ported before this record existed is still listed by `--root` or `--subject`, its stage derived from its older records.

