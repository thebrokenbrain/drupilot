---
description: Generate a .patch of the port WITHOUT contributing — offline, no push, no rebase, no contribution gate. Use it to test the change on another checkout now, or to attach to a Drupal.org issue comment, and contribute the Merge Request later. Two modes via a tabbed choice — a plain local-test patch, or one named with the Drupal.org issue-comment convention.
argument-hint: "[subject-path] [issue-id]"
allowed-tools: Bash, Read, AskUserQuestion
---

# /drupilot-patch — get the patch, decoupled from contribution

This command produces the port's `.patch` **independently of upstream
contribution**. It never pushes, never touches the network, never rebases, and
runs **no `contribute` gate** — it only needs `git`. It is the first-class way to:

1. **test the port on another checkout** right now (`git apply`), and
2. **attach a patch to a Drupal.org issue comment** to share/validate the fix,
   while opening the Merge Request **later** (via `/drupilot-contribute`).

It is safe and model-invocable (no outward-facing action). The merge-verified
contribution patch (rebased onto `origin/BASE`, hard-gated to apply cleanly) is a
separate thing produced by `/drupilot-contribute`.

## Step 1 — Resolve the subject

Resolve the subject directory: use `$1` if it points at a Drupal extension,
otherwise detect it from the current directory. Confirm the machine name:

!`bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; SUBJ="${1:-$PWD}"; [[ -d "$SUBJ" ]] || SUBJ="$PWD"; printf "subject_dir=%s\n" "$SUBJ"; printf "is_extension=%s\n" "$(is_drupal_extension_dir "$SUBJ" && echo yes || echo no)"; printf "machine_name=%s\n" "$(subject_machine_name "$SUBJ" 2>/dev/null || echo -)"; printf "under_git=%s\n" "$(git -C "$SUBJ" rev-parse --is-inside-work-tree >/dev/null 2>&1 && echo yes || echo no)"' _ "$1"`

If the subject is not a Drupal extension, or not under git, say so plainly and
stop (the patch needs a git checkout). `make-patch.sh --local` already
warns-and-skips in that case, so never fail the session over it.

## Step 2 — Ask what the patch is for (tabbed choice)

Use **AskUserQuestion** to let the developer own the decision (default = the
first option). Header "Patch for":

- **Test locally** — a plain `MODULE-port-to-drupal-11.patch` next to the module,
  for `git apply` on another checkout. No issue id needed.
- **Drupal.org issue comment** — a patch named with the issue-comment convention
  `MODULE-port-to-drupal-11-ISSUE-COMMENT.patch`, ready to attach to an issue.
  Also generates the paste-ready comment. Still offline; **no push, no MR**.

If the developer picks the issue-comment option, ask for the **issue id** (`$2`
if provided) and, optionally, the **comment number** (default `1`) — these only
affect the filename and the generated comment, nothing is sent anywhere.

## Step 3 — Generate the patch (offline, no gate)

For **Test locally**:

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/make-patch.sh" --local --subject "<SUBJECT>"
```

For **Drupal.org issue comment** (note: still `--local`, so no rebase / network /
gate; the issue id only names the file):

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/make-patch.sh" --local --subject "<SUBJECT>" --issue "<ISSUEID>" --comment "<N>"
```

The script prints the patch path on stdout and a friendly apply hint on stderr.
If it reports "No differences" (nothing ported yet), tell the developer to run
`/drupilot-port` first.

Then, for the issue-comment option, also generate the paste-ready comment that
references the patch (offline, no credentials):

```bash
!bash "${CLAUDE_PLUGIN_ROOT}/scripts/contrib/make-issue.sh" --project "<PROJECT>" --subject "<SUBJECT>" --issue "<ISSUEID>" --comment "<N>" --kind patch --patch-name "<PATCH_FILENAME>"
```

## Step 4 — Hand it over

- `SendUserFile` the generated patch path (and the `*-issue-comment.md` when the
  issue-comment option was chosen) so it surfaces as a deliverable.
- Summarize in English: where the patch is, how to apply it
  (`git apply <name>`), and — for the issue-comment option — that the developer
  attaches it to the issue and sets "Needs review", bumping the comment number
  for each new revision.
- Remind that this patch is **offline**: it diffs against the local base, not a
  freshly fetched `origin/BASE`. When ready to open the Merge Request (which
  rebases and hard-verifies the patch applies onto `origin/BASE`), run
  **`/drupilot-contribute`** — that is the upstream step, and it is opt-in.

This command performs no outward-facing action and exposes no credentials.
