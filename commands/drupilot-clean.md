---
description: Free disk and Docker resources held by a port's Drupal 11 test-bed — delete the DDEV project, the Composer-installed trees (vendor/, core, contrib) or the whole derived workspace — while keeping the reports, the hidden state and lockfile, the local patches and the module's git checkout with its branches. Refuses anything drupilot did not build. User-invocable only (destructive); previews the plan and asks before acting.
argument-hint: "[subject-path] [--all [dir]] [--level ddev|vendor|workspace] [--core-cache]"
allowed-tools: Bash, Read, AskUserQuestion
disable-model-invocation: true
---

# /drupilot-clean — remove a test-bed's environment, keep the work

All output is in **English**. This command is **destructive**, so it is
user-invocable only and always shows the plan before anything is removed. It
never contributes, never pushes, and never touches the subject's git history.

What is **always kept**: the `.drupilot/` reports (copied to the module's own
checkout before a workspace is removed, or to the root's hidden state dir when
no module has an origin to copy them to), the hidden state (`state.json`,
`assess.json`, `last-test.json`, the `drupilot-lock.json` lockfile, so a later
`/drupilot-setup` rebuilds the same core), the local `*.patch` files, and the
module's git checkout with all its branches.

What **may** be removed is decided by `scripts/env/clean.sh` (see its header):

| Level | Removes | Rebuilt by |
| --- | --- | --- |
| `ddev` | the DDEV project: containers, volumes, database (`ddev delete -Oy`, no snapshot) | `/drupilot-setup` (or `ddev start`) |
| `vendor` (default) | + `vendor/` and every Composer installer path (core, contrib, libraries, recipes) — never `*/custom` | `/drupilot-setup` (`ddev composer install` from `composer.lock`) |
| `workspace` | + the whole test-bed directory, after moving a `move`d module back to where it came from, unlinking a `symlink`, and discarding a `copy` only when it holds nothing its origin lacks (same commit, clean tree, no branch, tag or stash only the copy has) | `/drupilot-setup` on the module (the cached base core makes it fast) |

`vendor` and `workspace` only act on a **drupilot test-bed** (a root
`ddev-up.sh` built, marked in its `.drupilot.json`). On any other Drupal root
only `--level ddev --foreign-ok` is possible, and it asks a second time because
it destroys that site's database. A `legacy` root (recognized only by its
`<name>-d11` name and workspace pin, which an existing site chosen with
`--workspace` can share) needs `--foreign-ok` for `ddev` and `vendor`, asks a
second time too, and is never removed at the `workspace` level.

## Step 1 — Gate

DDEV removal needs the `setup` profile (Docker daemon + DDEV); a stopped
workspace can still be removed without it (`--no-ddev` skips `ddev delete`):

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile setup --json --quiet`

If `ready.setup` is false, say that `ddev delete` cannot run now, and offer only
`--no-ddev` (the project's containers and volumes then stay until a later
`ddev delete`).

## Step 2 — Scope

Use `$1` as the subject when it is a directory; with `--all` in `$ARGUMENTS`,
clean every test-bed drupilot has state for (plus, with a directory after
`--all`, the test-beds one or two levels under it, via `--scan <dir>`). A
`--level` or `--core-cache` in `$ARGUMENTS` is passed through.

## Step 3 — Ask the level (tabbed choice)

Unless `$ARGUMENTS` already names a level, check for a pre-answer —
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/choice.sh" --key CLEAN_LEVEL --subject "<SUBJECT>" --json`
returns a `value` (`vendor` / `ddev` / `workspace`) to use without the tab (say
so in one line) — and otherwise use **AskUserQuestion**, header
"Clean level", the recommended option first:

- **vendor (Recommended)** — free most of the disk (vendor/, core, contrib) and
  the DDEV project; the workspace and the placed module stay where they are.
- **ddev** — only the DDEV project and its database; the code stays.
- **workspace** — remove the whole test-bed; the module goes back to its
  original path.

Also ask (multi-select, default off) whether to remove the **cached base
cores** (`--core-cache`; the next setup then runs `composer create-project`
again).

## Step 4 — Preview (always)

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/clean.sh" --subject "<SUBJECT>" --level <LEVEL> --dry-run --json
```

(With `--all`: replace `--subject "<SUBJECT>"` by `--all [--scan <DIR>]`.)

STDOUT is `{dry_run, executed, level, roots: [{root, kind, ddev_project,
status, reason, actions: [{op, path, detail, status}], subjects: [...], size_kb,
freed_kb}], core_cache}`. Show one block per root: the workspace, whether it is
a drupilot test-bed (`kind`: marker / legacy / none), each action in plain
words, the size, and every `refused` / `skipped` root with its `reason`
verbatim (e.g. a copy with unmerged changes, a module with no recorded origin,
an origin path that is no longer empty). Never suggest working around a
refusal by deleting things by hand.

## Step 5 — Confirm, then clean

If nothing is `planned`, stop here. Otherwise use **AskUserQuestion**, header
"Proceed?", options **Clean now** / **Cancel** (default: Cancel). This
confirmation is never pre-answered (`DRUPILOT_CHOICE_CLEAN_CONFIRM` has no
effect). Only on **Clean now**:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/clean.sh" --subject "<SUBJECT>" --level <LEVEL> --yes --json
```

Add `--discard-copies` only if the developer explicitly chose to drop a copy
placement's unmerged changes after seeing the refusal (its `*.patch` files are
still kept), `--foreign-ok` only for an explicit `--level ddev` on a root that
is not a drupilot test-bed (or `--level ddev|vendor` on a `legacy` one) after
the developer confirmed that root is a disposable test-bed, and `--no-ddev` when Step 1 found DDEV unavailable.

## Step 6 — Summarize

Report per root: `status`, the actions done, `freed_kb` (as MB/GB; it is the
logical size, so a copy-on-write tree frees less), where a moved module now
lives, and where its reports went. Exit code 3 means a root was refused or an
action failed; the others were still processed. End with the next step:
`/drupilot-setup` rebuilds what was removed (`next-step.sh` recommends it until
then).
