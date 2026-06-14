---
description: Publish the ported contrib module/theme back to Drupal.org via an issue fork + Merge Request (or legacy patch), in semi (confirm each outward action) or auto mode, degrading gracefully when the GitLab API is blocked. User-invocable only. Never exposes the PAT.
argument-hint: "[module-path] [issue-id]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task, Skill, AskUserQuestion
disable-model-invocation: true
---

# /drupilot-contribute — publish to Drupal.org (issue fork + MR, or patch)

This command performs **outward-facing actions** (git push, opening a Merge
Request). It is user-only by design (`disable-model-invocation: true`) and must
never be triggered automatically. It applies **only to contrib projects** that
exist on Drupal.org.

Arguments: `$1` = subject path (fallback: cwd), `$2` = issue id (optional; asked
for if missing).

## Step 0 — Gate (profile `contribute`) and prerequisite check

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile contribute
```

If it exits `2` (no git, or neither an SSH key nor a PAT), show the report, route
the user to `/drupilot-doctor`, and STOP with no side effects.

Then run the contribution prerequisite check, which also verifies git identity
and whether the project exists on drupal.org:

```bash
!bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; \
  SUBJECT="${1:-$PWD}"; echo "project=$(subject_machine_name "$SUBJECT" 2>/dev/null || echo "?")"' \
  -- "$1"
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/check-prereqs.sh" --project "$(bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; subject_machine_name "${1:-$PWD}"' -- "$1")"
```

If `check-prereqs.sh` reports anything missing (no drupal.org account / GitLab
ToS not accepted / no auth / no git identity), relay its instructions and links
and STOP — do not push or open anything. If the project does **not** exist on
drupal.org, tell the user this command is only for contrib projects already
hosted there, and stop.

## Step 1 — Confirm subject is contrib and load the procedure

Confirm the subject is the contrib project the user means. Then invoke the
**drupal-contribution** skill for the full Drupal.org flow (issue fork, branch
naming, commit-message format, MR, legacy patch, the GitLab-API-blocked
degradation) and delegate the execution to the **drupal-contrib-publisher**
subagent (via the Task tool), which is the git/GitLab/Drupal.org specialist for
both modes.

## Step 2 — Ask for the issue and the mode

- **Issue**: ask for the issue id (`$2` if provided) — an existing issue, or one
  to create on drupal.org. If it must be created, guide the user to create it on
  the web (and to use "Create issue fork" + "Get push access" there). The issue
  can only be created on the web (no public issue API), so **generate the
  ready-to-paste content + the recommended field values** for them:

  ```bash
  !bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/make-issue.sh" --project "<PROJECT>" --base "<BASE>" --issue "<ISSUEID>"
  ```

  This writes `<PROJECT>-issue-summary.md` and `<PROJECT>-issue-comment.md` and
  prints the mandatory fields. Relay them: **Title** `Drupal 11 compatibility`,
  **Category** `Task`, **Priority** `Normal`, **Version** derived from the base
  branch (`4.0.x` → `4.0.x-dev`), **Component** `Code` (have the user verify it
  against the project's own, project-specific component list), **Assigned** to
  themselves. The summary keeps only the sections that apply to a
  behavior-preserving port (Problem/Motivation, Proposed resolution, Remaining
  tasks); Steps to reproduce and UI/API/Data-model changes are omitted. Defaults
  come from the `DRUPILOT_ISSUE_*` config keys (env-overridable).
- **Mode**: present a tab (**AskUserQuestion**, header "Contribute mode") with
  the default taken from `DRUPILOT_CONTRIB_MODE`:

  ```bash
  !bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; echo "default_mode=$(config_get DRUPILOT_CONTRIB_MODE semi)"' -- ""
  ```

  - **semi** (default): prepare everything, but **confirm explicitly before each
    outward action** (push, opening the MR). The `guard-contrib.sh` PreToolUse
    hook also asks before pushes in semi mode — treat that as a backstop, not a
    substitute for asking.
  - **auto**: with SSH/PAT present, use **git directly** (clone / remote / push
    against `git@git.drupal.org:issue/PROJECT-ISSUEID.git`) and open the MR via
    the GitLab API **only if it responds**; if the API is blocked, **degrade
    gracefully** to printing the MR URL for a one-click manual open.

  (An autonomous run never reaches this command — it is `disable-model-invocation`
  and outward-facing.)

## Step 3 — Issue fork, branch, commit

Create/track the issue fork and branch (branch name
`ISSUEID-short-description-with-hyphens`), make the change-set commit with the
correct Drupal core format (`{type}: #{issueID} one-line summary`, with `By:`
lines using drupal.org usernames), and detect the project's own convention from
its `CONTRIBUTING.md` (some contrib still use the legacy
`Issue #NNNN by user: ...`). Use the contrib leaf scripts:

```bash
# Set git identity if needed (idempotent):
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/setup-git.sh"
# Clone the project, add the issue remote, and check out the branch:
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/issue-fork.sh" --project "<PROJECT>" --issue "<ISSUEID>"
```

Apply the ported change-set on the branch, `git add -A`, and commit.

## Step 4 — Push, open the MR, and attach a patch

**Decision point — the push is the point of no return (G5).** In **semi** mode,
before anything leaves the machine, surface a tab (**AskUserQuestion**, header
"Push to Drupal.org", default = "Show the diff first") — because the `confirm()`
inside `open-mr.sh` cannot reach a TTY under Claude Code, this is how the
developer actually consents:

- **Show the diff first** — print `git diff origin/BASE` (or the commit range) so
  they see exactly what will be published, then re-ask.
- **Push now** — proceed with the push + MR.
- **Local patch only** — do **not** push; produce the offline issue-comment patch
  instead (route to `/drupilot-patch` → issue-comment option). Lets them validate
  on the issue before committing to an MR.
- **Cancel** — stop with nothing sent.

In **auto** mode, skip the tab and proceed (the mode's whole point), but the
`guard-contrib.sh` PreToolUse backstop still applies, and an autonomous run is
already excluded. Then, honoring the mode:

For an issue-fork project (modern flow), rebase onto `origin/BASE`, push to the
issue remote, and open the MR — honoring the mode:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/open-mr.sh" --project "<PROJECT>" --issue "<ISSUEID>" --branch "<BRANCH>" --mode "<MODE>" --description-file "<PROJECT>-issue-comment.md"
```

`--description-file` uses the brief comment generated in Step 2 as the MR
description. In **semi** mode, `open-mr.sh` confirms before the push; do not
bypass it. In **auto** mode it tries the API and degrades to printing the MR URL
if blocked.

Then **always** also generate the contribution patch and post the comment — it is
normal (and useful) to attach a `.patch` to the issue: reviewers and CI expect
one, and it lets a user **apply the fix before the maintainer merges the MR**. So
produce it **in addition to** the MR:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/make-patch.sh" --module "<PROJECT>" --issue "<ISSUEID>" --comment "<N>" --base "<BASE>"
```

This writes `PROJECT-port-to-drupal-11-ISSUEID-COMMENT.patch` (diff against
`origin/BASE`) **and verifies it applies cleanly onto `origin/BASE`** — the
version the patch targets. The verification is a **hard gate**: a patch that does
not apply is discarded and the script exits non-zero, because it would be useless
to a user applying it pre-merge. If that happens, re-fetch/rebase onto the
correct base and re-run; never hand over a broken patch. Then guide the user to
attach the patch, post the `PROJECT-issue-comment.md` comment, and set "Needs
review". Bump `--comment` for each new revision.

For a project **not** migrated to issue forks there is no MR: the verified patch
above plus its comment are the whole contribution — run it without the
`open-mr.sh` step (generate the comment with `--kind patch` in Step 2).

## Step 5 — Contribution Record reminder and security notes

End by **reminding the user about the Contribution Record**: credit on Drupal.org
is *not* granted by the commit; maintainers assign it in the issue's Contribution
Record. drupilot does not and cannot claim credit — the user should make sure the
issue's credit section lists the right contributors.

Hard rules, always:

- **Never print, echo, log, or persist the PAT.** It is read only from the env
  var named by `.contrib.pat_env_var` (`DRUPILOT_GITLAB_PAT`) at the moment of
  use. If you ever need to show a command that would include it, redact it.
- **Never push or open an MR without confirmation in semi mode.**
- If the GitLab API is blocked, degrade gracefully to manual instructions / the
  MR URL — never fail the whole flow over the API.

## Step 6 — Report

Summarize in English: the issue, the mode used, the fork/branch, the commit
message format applied, what was pushed and whether the MR was opened via API or
left as a URL to open manually, the **patch path** (generated alongside the MR,
or as the sole deliverable for unmigrated projects), and the Contribution Record
reminder. Confirm that the PAT was never exposed.
