# migration-0.9 — a drupilot 0.9.1 lock and state, captured from a real run

This fixture is what drupilot **0.9.1** persisted for a real project: a
`setup` → `assess` → `port` run of the `legacy_widgets` fixture in a DDEV
Drupal 11 test-bed, captured on **2026-10-04** by lab scenario **L-M2-2** of the
1.0 roadmap. It backs task **T-M2-11** and contract row **CC-10**. drupilot 1.0
must read `root-state/drupilot-lock.json` as the toolchain cell `legacy_v1`
until the user refreshes it, show a refresh notice, and reproduce the 0.9 pins
listed below.

**Never regenerate or hand-edit these files.** The only way to refresh them is
to rerun L-M2-2 with a 0.9.x checkout: a local clone at the tag, used as
`CLAUDE_PLUGIN_ROOT` and `--plugin-dir`.

## Provenance

| | |
|---|---|
| drupilot | 0.9.1: tag `v0.9.1`, commit `248e74d7158e78fc6f5cedc1778c9c73141b2c60`, a clean clone (`git describe --tags` printed `v0.9.1`) |
| Subject | `tests/fixtures/legacy_widgets` (identical at v0.9.1 and at 1.0 m2/data-model `9221309`), copied, then `git init` and one commit `518f214ea8572359c4ef8f93daaa8af43b1f1af0` "fixture" |
| Drupal core | 11.4.8 (`drupal/recommended-project:^11`, `core_source: create`, cache key `php8.3-11.4.8`) |
| PHP | 8.3: `DRUPILOT_PHP_TARGET` unset, so the 0.9 default applied; the container ran PHP 8.3.33 and Composer 2.10.3 |
| DDEV | v1.25.4 (Docker 29.8.2); project `dpl-m2-mig09-d11`, type `drupal11`, nginx-fpm, MariaDB 11.8 |
| DDEV add-ons | `ddev-drupal-contrib` 1.2.1, `ddev-selenium-standalone-chrome` 2.2.1 |
| Claude Code | 2.1.289, headless (`claude -p`) |
| Digests | off (`DRUPILOT_USE_DIGESTS_RULES=false`); the lock has no `.digests` |

## Exact commands

The environment for every step:

```bash
export LAB=/home/<user>/Proyectos/drupilot-lab        # @HOME@/Proyectos/drupilot-lab
export CLAUDE_PLUGIN_ROOT=$LAB/m2/lm22/drupilot-0.9.1
export DRUPILOT_HOME=$LAB/m2/lm22/home
export DRUPILOT_WORKSPACE_DIR=$LAB/m2/lm22/dpl-m2-mig09-d11
export DRUPILOT_DETERMINISTIC=true DRUPILOT_USE_DIGESTS_RULES=false
unset DRUPILOT_CONTRIB_MODE CLAUDE_PLUGIN_DATA DRUPILOT_PHP_TARGET
```

1. Make the 0.9.1 checkout:
   `git clone --branch v0.9.1 <repo> $LAB/m2/lm22/drupilot-0.9.1`
2. Prepare the subject:
   `cp -a <repo>/tests/fixtures/legacy_widgets $LAB/m2/lm22/src/legacy_widgets`,
   then `git init` and commit it as "fixture" (author `lab
   <lab@example.invalid>`).
3. Provision the bed with the 0.9.1 scripts:
   ```bash
   bash $CLAUDE_PLUGIN_ROOT/scripts/env/ddev-up.sh --name dpl-m2-mig09-d11 \
     --workspace $LAB/m2/lm22/dpl-m2-mig09-d11 --subject $LAB/m2/lm22/src/legacy_widgets --json
   bash $CLAUDE_PLUGIN_ROOT/scripts/env/install-toolchain.sh --dir $LAB/m2/lm22/dpl-m2-mig09-d11 --json
   ```
   `install-toolchain.sh` took its pins from `source: reference`, because no
   lock existed yet.
4. Run three headless sessions, one per command. Each runs with
   `DRUPILOT_AUTONOMOUS=true DRUPILOT_NONINTERACTIVE=1
   DRUPILOT_CHOICE_PHP_TARGET=8.3` and uses this command line:
   ```bash
   timeout 3600 claude --plugin-dir $LAB/m2/lm22/drupilot-0.9.1 --settings settings.json \
     --permission-mode acceptEdits --allowedTools "Bash,Read,Edit,Write,Glob,Grep,Task,Skill,TodoWrite" \
     --append-system-prompt "<lab rules>" --output-format stream-json --verbose -p "<prompt>"
   ```
   `settings.json` disables the installed `drupilot@drupilot` plugin
   (`enabledPlugins`). For `assess` and `port` it also sets
   `env.DRUPILOT_CONTRIB_MODE=""`, which overrides a user-level `auto`. The
   prompts:
   - `/drupilot:drupilot-setup $LAB/m2/lm22/src/legacy_widgets`. This used the
     loose path: setup placed the subject itself (placement `move`), and the
     second toolchain run took its pins from `source: lock`.
   - `/drupilot:drupilot-assess $LAB/m2/lm22/dpl-m2-mig09-d11/web/modules/custom/legacy_widgets`
     gave verdict S.
   - `/drupilot:drupilot-port $LAB/m2/lm22/dpl-m2-mig09-d11/web/modules/custom/legacy_widgets`
     set `^10 || ^11`, with `d10_support` `verified-static`. The whole-suite
     PHPUnit run recorded preservation `verified` (9 tests), so the final stage
     is `tested`.
5. Capture the files: copy the root state dir, the subject state dir and the bed
   root's `.drupilot.json`, then run `sed -i "s#$HOME#@HOME@#g"` on every
   copied file.

## Files

The original locations are the hidden state dirs under
`$DRUPILOT_HOME/state/<key>`. `<key>` is `project_state_path`: the absolute
path with every non-alphanumeric byte turned into `_`. The **root** key is the
key of `@HOME@/Proyectos/drupilot-lab/m2/lm22/dpl-m2-mig09-d11`. The
**subject** key is the key of that path plus
`/web/modules/custom/legacy_widgets`.

| File | Written by (0.9.1) | Kind |
|---|---|---|
| `root-state/drupilot-lock.json` | `lock-sync.sh` (via `install-toolchain.sh`, `ddev-add-ons.sh`); `.verify_cores` by `verify-core-matrix.sh` | canonical |
| `root-state/origin-baseline-legacy_widgets.json` | `origin-hygiene.sh --snapshot` (via `place-subject.sh`) | canonical |
| `bed-root/.drupilot.json` | `ddev-up.sh` (`testbed_mark`), `place-subject.sh`, `prefs_set` | canonical |
| `subject-state/state.json`, `subject-state/phase` | `state.sh record`, `phase_record` (setup, assess, port, `run-phpunit.sh`) | canonical |
| `subject-state/assess.json` | the model, as `/drupilot-assess` prescribes | canonical |
| `subject-state/port-manifest.json` | the model, as `/drupilot-port` prescribes (read by `port-report.sh`) | canonical |
| `subject-state/last-test.json`, `subject-state/test-baseline.json` | `run-phpunit.sh` (`--baseline` before Rector, then the whole suite) | canonical |
| `subject-state/core-matrix.json` | `verify-core-matrix.sh` | canonical |
| `subject-state/phpcs-ruleset.json` | `run-phpcs.sh` | canonical |
| `subject-state/rector-dryrun.json`, `subject-state/rector-rules.json` | `run-rector.sh` | canonical |
| `subject-state/metadata-lint.json` | `lint-extension-metadata.sh` | canonical |
| `subject-state/phpstan.json`, `subject-state/change-log.txt` | the model, at the paths the minimal-port skill names | canonical |
| `subject-state/{classify-final,core-matrix-run,metadata-lint-final,patterns-scan,phpcs-final,port-safety-final,rector-apply,signature-final}.json`, `subject-state/phpstan-final.txt` | the model's own scratch output; 0.9.1 never names these files | scratch |
| `expected/install-toolchain.dry-run.json` | `install-toolchain.sh --dir <bed> --dry-run --json` (0.9.1), run against this lock after the port | oracle |

A second subject state dir, for the submodule `modules/legacy_widgets_extra`,
was created and left **empty**, so nothing was captured from it.

### sha256 (after sanitizing; these are the committed bytes)

```
72f743e10c05abd0d8632e9d5291f1f354f4237945be127d610d8d773463ca22  bed-root/.drupilot.json
5c4234241d79827dbcdb533ee08f938576a4d69e630cd5b4369900766388f9cc  root-state/drupilot-lock.json
be44cfbc7d9e5723dd721cd8747a228b7650ec090db350dfad6a5ccad0601d51  root-state/origin-baseline-legacy_widgets.json
4968ebb951fa69c221cafd797d8c01b66888982f5a12b2dbe02c5dfcf0a6fd23  subject-state/assess.json
c1b7d11827f5b0d3993006c1f60a1bed0afb38d06676c0f93c4e701668daa70d  subject-state/change-log.txt
b3a75b9c19c7204d04ea9bce2b945d77d59049c6938665342c51816c4b583e30  subject-state/classify-final.json
938f3538ce40a02b458aa3a715458acdfe5b101610321a9ea3efdeccb21900ae  subject-state/core-matrix-run.json
938f3538ce40a02b458aa3a715458acdfe5b101610321a9ea3efdeccb21900ae  subject-state/core-matrix.json
5b452e26690b5c9473c7fee57595e975f988082553b241271259fd493a4d24c5  subject-state/last-test.json
97489fafe2895b8f847c54caeca0071ca0fa7c205284fc251e1338cbde5b2d04  subject-state/metadata-lint-final.json
97489fafe2895b8f847c54caeca0071ca0fa7c205284fc251e1338cbde5b2d04  subject-state/metadata-lint.json
29b8483ebc636905a77342cba82b40f5943226c8583652b0f29c538e455c40e4  subject-state/patterns-scan.json
28c0cba0b2983db5a296342bd0f7caea7f18ee7d44718fe523478836a0887e11  subject-state/phase
c1f523aa3ae627239228137b9fe1b7330974516c1802d13d75d2ca044860e011  subject-state/phpcs-final.json
956a8ac418744670e5112c21ed7dd8b902e0e8a4ff7734738c54fda6e865a70e  subject-state/phpcs-ruleset.json
ef8961a25d7b133f2d7fdb410e9433aef81be946303855f09538050cf4e0fa95  subject-state/phpstan-final.txt
79a8ddd0c9a131d8c2d37c4bf84bbf20b05d681195856cb11d009becf0a46560  subject-state/phpstan.json
a76dd9b5e034a12e143a485ea233d6a3294c82711626e18c7e8660a1a0c4040f  subject-state/port-manifest.json
5a6d28cd422299df892a926857de8e76e00cb14dd59ad79d1532db62e956fb5c  subject-state/port-safety-final.json
a9168a8ca28c3066116e3818a5764c3e4dc79181c45ea291112d8ca58986ebba  subject-state/rector-apply.json
48c7b9573e77e2d46c86ac045e6ddf5dd9fe3222bd3eccf913587db9d38e81ab  subject-state/rector-dryrun.json
2d8af01ff022fe32c222883c3ebf8cb8c354fc77c97be770241419ddec71b78d  subject-state/rector-rules.json
d92bdf312ba4d13f6eaf6fb599d164ca897075931b9a671ed1e977969a9cecec  subject-state/signature-final.json
f13ec6284e7e7aa4c355eab81d1bf8744aef9a2cbb771d01dabee9cb3e64080c  subject-state/state.json
e68a32a30bfbb9f61e4fa4a51fb31428373e29839b237e5c96242c379a72b602  subject-state/test-baseline.json
fa8ced7c095e4a42ed86ef37b03b4470d81be8e321c5d691c6f43e28a0112836  expected/install-toolchain.dry-run.json
```

The lab's `notes.md` keeps the hashes from before sanitizing. The lock,
`phase`, `phpstan.json`, `rector-apply.json`, `rector-dryrun.json`,
`classify-final.json` and `test-baseline.json` contain no `$HOME` path, so the
sanitizing step did not change them.

## Sanitization rule

There is exactly one substitution: every occurrence of the literal `$HOME`
prefix (the lab user's home directory) became `@HOME@`. Nothing else was
changed, re-indented or re-ordered, so every file is otherwise byte-identical
to what 0.9.1 wrote, including the JSON key order and whether it is compact or
pretty-printed. After sanitizing, `grep -r "/home/<user>" .` prints nothing. A
reader that needs real paths substitutes `@HOME@` back.

**Known residue.** `subject-state/last-test.json` `.baseline.file` holds the
absolute path of `test-baseline.json` inside the hidden state dir. The prefix
of that path became `@HOME@`, but the state-dir key in the middle of it is the
underscore-encoded absolute path (`_home_<user>_Proyectos_...`), which the
`@HOME@` rule does not match. This is the same residue that L-M1-1 found.

## The 0.9 pins (what `legacy_v1` must reproduce)

`root-state/drupilot-lock.json` `.toolchain` holds these pins, and they are
exactly the packages installed in the bed (`ddev composer show` and
`composer.lock`):

| Package | Lock pin | Installed | composer.lock reference |
|---|---|---|---|
| palantirnet/drupal-rector | 0.21.2 | 0.21.2 | 421665d1777df769292b47c51e297c73ed417d00 |
| rector/rector | 2.5.2 | 2.5.2 | 49ff6339174bdbdf50b0b35ecbcff14a05ac9e24 |
| phpstan/phpstan | 2.2.2 | 2.2.2 | e5cc34d491a90e79c216d824f60fe21fd4d93bd6 |
| phpstan/extension-installer | 1.4.3 | 1.4.3 | 85e90b3942d06b2326fba0403ec24fe912372936 |
| mglaman/phpstan-drupal | 2.2.2 | 2.2.2 | 99d198489a50bf5a654187bf2e6acd55786157d7 |
| phpstan/phpstan-deprecation-rules | 2.0.5 | 2.0.5 | 67bedd65c24bc72840afc45aed48b1059dd44bec |
| drupal/coder | 8.3.31 | 8.3.31 | 07c14cf2217c2b53cc4469e2ed360141e6bb18ea |
| drupal/core-dev | 11.4.8 | 11.4.8 | 00497b38938a9ca8920982af95e0eb11da189afd |
| drush/drush | 13.8.0 | 13.8.0 | a5529118232c722c052ad6ae3be587df43c7d6fa |

PHPUnit was not pinned in the lock; it came in through `drupal/core-dev` as
11.5.56. The other lock values are:

- `.drupal.core` `11.4.8`, `.php_target` `"8.3"`, `.phpstan_level` `2`
- `.core_strategy` `"auto"`. This is the configured strategy, not the resolved
  one: the port resolved keep-d10 (`^10 || ^11`).
- `.drupilot_version` `"0.9.1"`, `.drupilot_revision` `"v0.9.1"`
- `.ddev_addons` `{ddev-drupal-contrib: 1.2.1, ddev-selenium-standalone-chrome: 2.2.1}`
- `.verify_cores` `{"10.0": {constraint: "~10.0.0", version: "10.0.11"}, "10": {constraint: "^10", version: "10.6.18"}}`
- no `.digests` and no `.schema`

`.updated` (`2026-10-04T12:27:18Z`) is older than the `.verify_cores` write,
because only `lock-sync.sh` bumps `.updated`.

`state.json` `.toolchain.packages` copies the same nine pins. The 0.9.1
`config/toolchain-reference.json` (`sha256
5a32e124697660c59e231139f66b6d2206df83b74c427d5201f008f57c80f2f4`) has the
same seven toolchain pins plus drush 13.8.0. It also lists
`drupal/upgrade_status` 4.3.10, which was not installed here
(`--with-upgrade-status` was not used), so the lock has no
`drupal/upgrade_status` key.

**0.9.1 behaviour on this lock (the oracle).** With this lock in place,
`install-toolchain.sh --dir <bed> --dry-run --json` on the 0.9.1 checkout
exits 0 with `source: "lock"` and `requested_source: "auto"`. Its specs, in
this order, are `palantirnet/drupal-rector:0.21.2`, `rector/rector:2.5.2`,
`phpstan/phpstan:2.2.2`, `phpstan/extension-installer:1.4.3`,
`mglaman/phpstan-drupal:2.2.2`, `phpstan/phpstan-deprecation-rules:2.0.5`,
`drupal/coder:8.3.31` and `drupal/core-dev:11.4.8`, each with `source:
"lock"`. The setup session's second `install-toolchain.sh` run made the same
choice (`status: unchanged`, `composer_ran: false`). The `installed` fields of
`expected/install-toolchain.dry-run.json` were read from the live bed, so a
Docker-free test compares `source` and `spec` only.

## In the repository

Only what drupilot 1.0 needs to read a 0.9 project is committed: the lock,
the bed root's `.drupilot.json`, the canonical subject state written by
scripts or prescribed by a command (`state.json`, `assess.json`,
`last-test.json`, `test-baseline.json`, `port-manifest.json`,
`phpcs-ruleset.json`) and the oracle. The other files of the table stay in the
lab capture. A second substitution was applied before committing: the state
keys derived from a home path (`_home_<user>_...`) read `@HOMEKEY@_...`, so no
user name is committed; it changes `last-test.json` only.

Committed bytes:

```
72f743e10c05abd0d8632e9d5291f1f354f4237945be127d610d8d773463ca22  bed-root/.drupilot.json
fa8ced7c095e4a42ed86ef37b03b4470d81be8e321c5d691c6f43e28a0112836  expected/install-toolchain.dry-run.json
5c4234241d79827dbcdb533ee08f938576a4d69e630cd5b4369900766388f9cc  root-state/drupilot-lock.json
4968ebb951fa69c221cafd797d8c01b66888982f5a12b2dbe02c5dfcf0a6fd23  subject-state/assess.json
08424da11e78a204912cb03e0dc0ef5896f72cbcbff24e81c3d41894abcc8933  subject-state/last-test.json
956a8ac418744670e5112c21ed7dd8b902e0e8a4ff7734738c54fda6e865a70e  subject-state/phpcs-ruleset.json
a76dd9b5e034a12e143a485ea233d6a3294c82711626e18c7e8660a1a0c4040f  subject-state/port-manifest.json
f13ec6284e7e7aa4c355eab81d1bf8744aef9a2cbb771d01dabee9cb3e64080c  subject-state/state.json
e68a32a30bfbb9f61e4fa4a51fb31428373e29839b237e5c96242c379a72b602  subject-state/test-baseline.json
```
