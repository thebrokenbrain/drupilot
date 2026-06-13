---
name: drupal-contribution
description: >-
  Contribute a ported module/theme back to Drupal.org via the modern issue-fork +
  Merge Request flow on git.drupalcode.org, or the legacy patch flow for
  unmigrated projects. USE THIS for the /drupilot-contribute flow and the
  drupal-contrib-publisher agent, when the user asks to "open a merge request /
  create an issue fork / make a patch / push my fix to drupal.org / contribute
  this upstream". Checks the prerequisites (drupal.org account + GitLab access +
  SSH key or PAT + git identity), creates the issue fork, branch and a correctly
  formatted commit, opens the MR (semi = confirm before every outward-facing
  action; auto = direct git push and API MR when the endpoint responds), degrades
  gracefully to manual instructions when the GitLab API is blocked, reminds the
  user about the Contribution Record (maintainers assign credit), and NEVER
  prints or persists the PAT.
allowed-tools: Bash, Read, Grep, Glob
user-invocable: true
---

# Drupal.org contribution (issue fork + MR, or legacy patch)

This skill publishes the result of a port/refactor back to Drupal.org. It
implements PROMPT 3 in full. It only applies to a **contrib** subject (a project
that exists on drupal.org); custom-only code has nowhere to contribute to.

Two hard safety rules run through everything:

1. **Never print or persist the PAT.** It lives only in the environment variable
   named by `.contrib.pat_env_var` (default `DRUPILOT_GITLAB_PAT`). Never echo it,
   never write it to a file, never put it in a URL that gets logged, never commit
   it.
2. **In `semi` mode, every outward-facing action is confirmed** (push, MR
   creation, anything hitting drupalcode/gitlab). The `guard-contrib.sh`
   PreToolUse hook also asks for confirmation on `git push`/MR commands in semi
   mode; do not try to bypass it.

## 0. Conventions and source of truth

- All output is **English**.
- Verified facts and URLs come from PROMPT 3 and `defaults.json -> .contrib.*`.
  Read them via `config_json`:
  - `.contrib.gitlab_host` (`git.drupal.org`, SSH),
    `.contrib.gitlab_https_host` (`git.drupalcode.org`, HTTPS/web),
  - `.contrib.ssh_test_target`, `.contrib.ssh_keys_url`, `.contrib.pat_url`,
    `.contrib.register_url`, `.contrib.drupalcode_access_url`,
    `.contrib.pat_env_var`.
- `${CLAUDE_PLUGIN_ROOT}` is the plugin root; the contrib leaf scripts live under
  `${CLAUDE_PLUGIN_ROOT}/scripts/contrib/`.
- Mode comes from `DRUPILOT_CONTRIB_MODE` (default `semi`); the developer may
  override per run.

## 1. Confirm the subject is contributable

```bash
ROOT="${CLAUDE_PLUGIN_ROOT}"
. "$ROOT/scripts/lib/common.sh"
SUBJECT="$(cd "${1:-$PWD}" && pwd)"
NAME="$(subject_machine_name "$SUBJECT")"   # candidate drupal.org project name
```

The project name is usually the module/theme machine name (or the parent project
if it is a submodule). The prerequisite check (§2) confirms the project exists on
drupal.org. If it does not, stop: there is nothing upstream to contribute to.

## 2. Gate + prerequisites (PROMPT 3.1)

Run the contribute gate and the prerequisite checker:

```bash
bash "$ROOT/scripts/env/preflight.sh" --profile contribute
bash "$ROOT/scripts/contrib/check-prereqs.sh" --project "$NAME"
```

- The gate's hard requirements are `git` + (SSH key OR PAT). Exit `2` -> show the
  report and **stop** with no side effects.
- `check-prereqs.sh` additionally verifies git identity and, with `--project`,
  whether the project exists on drupal.org
  (`curl -fsI https://www.drupal.org/project/NAME`). It prints actionable guidance
  and the links from `.contrib.*`.
- The human prerequisites cannot be auto-verified — remind and link, do not block
  on detection alone (PROMPT 3.1):
  - drupal.org account with confirmed email and **real name** in the profile.
  - **DrupalCode access**: accept the GitLab Terms of Service in the profile's
    "DrupalCode access" tab (`.contrib.drupalcode_access_url`). Without this you
    cannot push.
  - **Authentication**, one of:
    - **SSH** (recommended for push): `ssh-keygen -t ed25519`; upload the public
      key at `.contrib.ssh_keys_url`; test `ssh -T $(config_json .contrib.ssh_test_target)`
      (expect `Welcome to GitLab, @user!`).
    - **HTTPS + PAT**: create a token at `.contrib.pat_url` with scopes
      `read_repository`, `write_repository` (+ `api` if using the API), expiry <=
      1 year; export it as the `.contrib.pat_env_var` variable. The PAT acts as
      the password — never printed, never stored.

If git identity is missing and a TTY exists, set it (idempotent):

```bash
bash "$ROOT/scripts/contrib/setup-git.sh"      # or --name "Real Name" --email you@example.com
```

The email should be the one linked to the drupal.org account.

## 3. Ask for the issue and the mode

Before any outward-facing action, gather:

- **Issue ID** — an existing issue, or guide the user to create one on
  drupal.org (the issue fork is created from the issue web UI: "Create issue fork"
  + "Get push access").
- **Base version** — the branch to target (e.g. `4.0.x`, `11.x`), used for
  rebasing and the tracking branch.
- **Mode** — `semi` (default) or `auto`, from `DRUPILOT_CONTRIB_MODE` unless the
  developer overrides.

## 4. Detect the project's commit/branch conventions

Different projects use different conventions — detect, do not assume (PROMPT 3.4):

- Read the project's `CONTRIBUTING.md` / `README` (Grep for "commit message",
  "Issue #", branch naming).
- **Modern Core format** (preferred default):
  ```
  {type}: #{issueID} One-line summary

  By: user1
  By: user2
  ```
  Types: `fix`, `feat`, `ci`, `docs`, `perf`, `refactor`, `test`, `task`,
  `revert`. `By:` lines use **drupal.org usernames** (no `@`).
- **Legacy contrib format** still common:
  `Issue #NNNN by user1, user2: Description`.

Pick the format the project actually uses. Branch name convention:
`ISSUEID-short-description-in-lowercase-with-hyphens`
(e.g. `3982435-ckeditor-5-compatibility`).

## 5a. Modern flow — issue fork + Merge Request (PROMPT 3.2, preferred)

### Create / track the issue fork

```bash
bash "$ROOT/scripts/contrib/issue-fork.sh" --project "$NAME" --issue ISSUEID \
     --base BASE_VERSION [--branch ISSUEID-short-description] [--workdir DIR]
```

This clones `https://git.drupalcode.org/project/NAME.git`, adds the issue remote
`NAME-ISSUEID` -> `git@git.drupal.org:issue/NAME-ISSUEID.git`, fetches, and checks
out either the existing tracking branch or a new `ISSUEID-description` branch. It
prints the next steps.

- Fork URLs: SSH `git@git.drupal.org:issue/NAME-ISSUEID.git`,
  HTTPS `https://git.drupalcode.org/issue/NAME-ISSUEID.git`.
- The issue fork itself is created from the **issue web page** ("Create issue
  fork" + "Get push access"); drupilot then works against its remote.

### Commit the change

Apply the port/refactor changes in the working tree, then commit with the
detected format (§4). Example, modern format:

```bash
git add -A
git commit -m "fix: #ISSUEID One-line summary"
```

### Open the MR

```bash
bash "$ROOT/scripts/contrib/open-mr.sh" --project "$NAME" --issue ISSUEID \
     --branch ISSUEID-short-description --base BASE_VERSION --mode semi
```

`open-mr.sh` (mode defaults to `DRUPILOT_CONTRIB_MODE`):

- Rebases onto `origin/BASE_VERSION` (PROMPT 3.2:
  `git fetch origin && git rebase origin/BASE_VERSION`).
- **semi**: `confirm` before the push and before opening the MR.
- **auto**: pushes directly to the issue remote, then tries to open the MR via
  `glab` / `curl` against the GitLab API (PAT read from the
  `.contrib.pat_env_var` env var — never printed).
- Pushes to the issue remote: `git push NAME-ISSUEID ISSUEID-short-description`.

### Also attach a patch (always, in addition to the MR)

A `.patch` on the issue is conventional even when there is an MR — reviewers and
some CI expect one, and it lets people test the change without checking out the
fork. So after the MR, **always** also produce the contribution patch:

```bash
bash "$ROOT/scripts/contrib/make-patch.sh" --module "$NAME" --issue ISSUEID \
     [--comment N] --base BASE_VERSION
```

This writes `NAME-short-description-ISSUEID-COMMENT.patch`
(`git diff origin/BASE_VERSION`). Attach it to the issue alongside (or as a
complement to) the MR, and bump `--comment` per revision. This is distinct from
the offline **local preview** patch (`make-patch.sh --local`, named
`NAME-short-description.patch`) that the port/refactor flow writes for local
testing.

## 5b. Legacy flow — patch only (PROMPT 3.3, for unmigrated projects)

If the project is not on the issue-fork workflow there is no MR; the patch is the
whole contribution. Run the same script (no `open-mr.sh` step):

```bash
bash "$ROOT/scripts/contrib/make-patch.sh" --module "$NAME" --issue ISSUEID \
     [--comment N] --base BASE_VERSION
```

It rebases onto `origin/BASE_VERSION` and writes
`git diff origin/BASE_VERSION > NAME-short-description-ISSUEID-COMMENT.patch`
(naming convention `[module]-[short-description]-[issue]-[comment].patch`). Then
the developer attaches the patch to the issue, comments, and sets "Needs review".

## 6. GitLab API degradation (PROMPT 3.5)

The drupalcode GitLab API is standard (`/api/v4/...`) **but blocked by default**
by the Drupal Association; endpoints open only on request. Therefore:

- For `auto`, prefer **direct git** (clone/remote/push against
  `git@git.drupal.org:issue/NAME-ISSUEID.git`) for the work that git can do.
- Use the API **only** to open/manage the MR, and only **if the endpoint
  responds**.
- If the API is blocked or errors, **degrade gracefully**: print the MR creation
  URL so the user opens it in the browser with one click. Never treat a blocked
  API as a failure of the contribution — the push already landed; the MR is one
  manual click away.

## 7. Credit reminder (PROMPT 3.5) — always

After opening the MR or producing the patch, **always** remind the user:

> Credit is **not** granted by the commit. It is assigned in the issue's
> **Contribution Record**, and only **maintainers** assign it. Comment on the
> issue, set the status to "Needs review", and ensure your contributors are
> listed so maintainers can credit them. Do not attempt to "claim" credit.

This reminder is mandatory on every successful contribution, in both modes.

## 8. Security and idempotency rules (recap)

- **PAT**: read only from the env var named by `.contrib.pat_env_var`; never echo
  it, never write it to disk, never place it in a logged URL, never commit it. If
  no PAT and no SSH key are present, stop at the gate (§2).
- **semi mode**: confirm before every push / MR / outward-facing call. The
  `guard-contrib.sh` hook enforces this too; respect its `ask` decisions.
- **Idempotent**: re-running `issue-fork.sh` must not duplicate remotes or
  clobber an existing checkout; re-running `open-mr.sh` must detect an existing
  MR/branch and not create a second one. The leaf scripts handle this — do not
  reinvent the git plumbing.
- **Never push without confirmation in semi mode**, and never force-push a shared
  issue branch without explicit user consent.

## 9. Report in chat (concise English)

State: the project + issue, the flow used (modern MR + patch, or legacy patch
only), the branch/commit, whether the MR was opened via API or left as a manual
URL (with that URL), the contribution patch path (generated in both flows), and
the Contribution Record reminder. Never include the PAT or any credential in the
summary.
