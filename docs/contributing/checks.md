# Checks

drupilot has one local developer gate, `scripts/dev/check.sh`, and CI runs
nothing else. Run it before every commit:

```bash
bash scripts/dev/check.sh                 # every gate but the optional ones; exit 0 ok / 1 a gate failed
bash scripts/dev/check.sh --smoke         # also the optional golden and smoke gates
bash scripts/dev/check.sh --ci            # a missing optional tool fails instead of skipping; implies --smoke
bash scripts/dev/check.sh --only docs,unit --json   # a subset, machine-readable
```

A gate passes, fails, is skipped (an optional tool such as `claude`,
`shellcheck` or `xmllint` is missing, outside `--ci`) or
warns (a finding reported without failing, for a check that is not enforced
yet). The gate is bash 3.2-compatible and read-only.

| Gate | What it proves |
|---|---|
| `validate` | `claude plugin validate .` accepts the plugin and marketplace manifests. |
| `syntax` | `bash -n` passes on every script (`scripts/*/*.sh`, `hooks/scripts/*.sh`, `tests/lib/*.sh`, `tests/unit/*.sh`). |
| `exec-bit` | Those scripts are executable (git mode `100755`). |
| `shellcheck` | `shellcheck -S warning` finds nothing; an exception is an inline `# shellcheck disable=SCxxxx  # reason`. |
| `portability` | No bash 4-only or GNU-only construct (stock macOS bash 3.2, BSD and BusyBox userland, mawk). |
| `special-vars` | No script assigns or loops over a bash special variable. |
| `scripts` | (AR-22) Every script but `scripts/dev/` sources `common.sh` at its depth, answers `--help` with exit 0 and a Usage section, and refuses an unknown flag with exit 1 (probed as `--drupilot-no-such-flag --help`, so no script body runs). A 0.9 script that skips an unknown flag keeps its frozen CLI through an `AR22-FLAG` row of `tests/contract/hard-rules-allow.txt`. |
| `hard-rules` | (alias `no-version-literals`, T-M3-12) The greppable hard rules over the scripts, the PHP templates (comment lines skipped) and the prompts: H2 `SleepToSerialize`/`WakeupToUnserialize` outside a skip list, H3 `withComposerBased(`, H5 a drupal.org docs or releases URL, H6 a hard-coded "Drupal 12 stable", H7 a three-major range literal in code, H9 a `drush migrate:import`, the `Drupal10SetList::DRUPAL_10` aggregate, a `drupalNN` DDEV-type literal outside `scripts/lib/plan.sh`, and H4: exactly as many version-literal lines per script as `tests/contract/hard-rules-allow.txt` records (a ratchet). That file also holds each reasoned exception. |
| `sigpipe` | No pipeline in `scripts/` or `hooks/` ends in a consumer that stops reading early (`\| head`, `\| grep -q`, an `\| awk` exit): under `pipefail` the producer's SIGPIPE fails the pipeline. Use `grep_q`, `sed -n '1p'` or an awk flag; opt a line out with `# sigpipe-ok` and a reason. |
| `jq-compat` | No jq keyword used as a variable or shorthand key (jq 1.6 rejects them). |
| `lib-defs` | The shared library is split into domain libs: every function of `scripts/lib/*.sh` is defined once, `common.sh` only sources the domain libs (each once), a hook's `_DRUPILOT_LIBS` covers every lib it reaches, and `--compare-pre-split=REF` checks the function set against a git ref. |
| `bang-lint` | No `<placeholder>` inside a load-time `` !`...` `` span of a command, skill or agent. |
| `templates` | Every template renders, and its XML output is well-formed. |
| `json` | Every JSON file of `config/`, `hooks/` and `.claude-plugin/` parses. |
| `version` | `plugin.json` equals the top released CHANGELOG heading, a `v*` tag on HEAD matches it, `main` never carries a pre-release, and `config/migrations.json` is coherent. |
| `config-keys` | Every `DRUPILOT_*` key read is declared in `config/config-reference.json` (fails; it warned until M3); no `defaults.json` comment grows past 1800 characters (fails). |
| `docs` | The generated reference pages are current, every `docs/**/*.md` is in the `mkdocs.yml` nav and every nav entry exists, no plugin file cites a README section or a missing docs page, and every relative link between docs pages resolves. |
| `schemas` | Every persisted 0.9 artifact and the version data validate against their schema in `schemas/`: with the jq validator always, and with `check-jsonschema` where it is installed; under `--ci` it needs `check-jsonschema` on PATH or a running Docker (its pinned image), and fails without both. The detail names the engines that ran. |
| `data` | Every `$ref` of the data schemas resolves; the version data (`config/targets`, `config/php`, `config/paths`) and the detector catalogs (`config/catalog`) match their schema, every value names its source, every value a hard gate reads is verified and never "announced", and the files agree with each other (`scripts/dev/data-check.sh`). |
| `unit` | The unit tests (`scripts/dev/unit.sh`): the assert library, `common.sh` helpers, the hooks' fail-safe contract and the invariants INV1..INV12 (`tests/INVARIANTS.md`). |
| `contract` | The 0.9 public surface is unchanged, or the change is listed in `tests/contract/allowed-changes.json` (`scripts/dev/contract.sh`). |
| `evals` | The router's tab sequence, mode words and mode-inference rules are unchanged (`scripts/dev/evals.sh`, static; `--live` runs the model, never in CI). |
| `golden` | Optional. The v0.9.0 baseline and the lab goldens match (`scripts/dev/golden.sh`), each against the version-data snapshot it is pinned to (`tests/fixtures/data-snapshots/<hash>/`), never against the live `config/`; an edited or missing snapshot fails, and so does a snapshot no golden uses (a full `golden.sh --update` removes it). |
| `smoke` | Optional. Docker-free smoke tests with expected results on the fixtures (`scripts/dev/smoke.sh`). |

CI (`.github/workflows/ci.yml`) runs the gate on Ubuntu and macOS (also under
the stock `/bin/bash` 3.2), inside the Alpine `bash:3.2` image (BusyBox) and
`debian:12-slim` (mawk, jq 1.6), and runs `validate` with the Claude Code CLI.
Anything that needs DDEV or Docker-in-Docker is checked in a lab outside the
repository, never in CI.
