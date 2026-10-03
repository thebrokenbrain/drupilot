# v0.9.0 baseline

The frozen output of drupilot v0.9.0's Docker-free scripts, the reference every
later change is measured against. `scripts/dev/baseline-0.9.sh` owns it (its
`--help` lists every capture):

- `--capture` runs the scripts of the `v0.9.0` tag (a throwaway `git worktree`)
  on copies of `tests/fixtures/legacy_widgets` and `tests/fixtures/monorepo`,
  normalizes the output and writes it to `v0.9.0/`. It ran once; its output is
  committed.
- `--check` (the smoke test `baseline`, so every CI leg) runs the same captures
  with the checkout's scripts and compares them byte for byte. It never needs
  the tag.

`inputs/` holds the committed inputs: a hand-made PHPStan sample in the 0.9 text
table and native JSON formats (read by `classify-deprecations.sh` and
`explain-deprecations.sh`; its `user_roles` and `drupal_set_message` entries and
the trailing tagged lines are synthetic, the rest point at real fixture lines),
the canned `state.json` that `port-summary.sh` reads, and `php_floor_signals/`,
a module with one PHP 8.2, 8.3 and 8.4 construct per `detect-php-floor.sh`
signal (no fixture has one), each hit unique so the first hit is the same
whatever order the directory walk takes.

An intended change of 0.9 behaviour is one line in `v0.9.0/allowed-diffs.txt`:

```text
<file> sha256:<hex of the normalized output> <reason; CHANGELOG entry>
```

`--check` prints that line (with the hash) for every file that differs. The
allowed output is pinned by its hash, so a later unintended change to the same
file still fails. `v0.9.0/SHA256SUMS`, written by `--capture`, pins the committed
baseline files themselves, so editing one fails `--check` too. Never re-capture
to make a difference go away.
