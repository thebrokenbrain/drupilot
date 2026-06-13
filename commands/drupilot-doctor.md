---
description: Verify all drupilot software requirements (git, jq, php/composer, Docker + daemon, DDEV, SSH/PAT for contribution) grouped by what each is for, with per-platform install instructions, then OPTIONALLY run assisted installation after explicit confirmation. Use for "/drupilot-doctor", "check my setup", "what do I need to install", or when a command reports a missing hard requirement.
argument-hint: "[install]"
allowed-tools: Bash, Read, Skill
---

# drupilot — doctor (requirements check + assisted install)

You verify the developer's environment and, only with explicit confirmation, help
install what is missing. **English only** in all output.

## Step 1 — Run the full readiness report

Run preflight with the `all` profile so it reports every requirement without gating any
single operation (profile `all` always exits 0; it is report-only):

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile all`

Also capture the structured form to reason about precisely:

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile all --json`

## Step 2 — Render readiness

Present the result grouped by purpose, in English:

- **Analysis (assess / static port):** git, jq, and PHP-or-Composer.
- **Environment & tests (DDEV):** Docker, Docker daemon running, DDEV, Selenium add-on.
- **Contribution (Drupal.org):** git identity, SSH key or GitLab PAT, drupal.org
  account + GitLab ToS, optional glab/curl.

For each check use the JSON `ok`/`present`/`kind` to mark it: satisfied (with the
detected version), optional-and-missing, or missing/insufficient (show required vs
found). End with the one-line readiness summary, e.g.
"Ready for: analysis yes - environment+tests no (missing Docker) - contribution
partial (no PAT)".

## Step 3 — Per missing item, show OS-specific install instructions

For every check that is not satisfied, surface its `hint` field from the JSON — it is
already OS-aware (the engine detected the OS). Detect the OS yourself only to phrase the
guidance:

!`bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; printf "os=%s\n" "$(os_id)"'`

On the user's Fedora, package installs use `sudo dnf install ...`; Docker and DDEV use
their official installers. For Docker, also state the post-install step (add the user to
the `docker` group and re-login) and that the daemon must be **started/running**, not
just installed. For SSH/PAT, point at the drupal.org URLs from the hints and never ask
for or print a token value.

## Step 4 — Offer assisted installation (opt-in only)

Assisted install only runs when the user clearly asks for it — either the argument
`$1` is `install`, or the user confirms after you offer. **Never install anything
without explicit confirmation.**

1. List exactly which tools you would install (only the missing/insufficient ones) and
   the command that will be used per the detected OS.
2. Note the limitations: Docker needs a manual group-add + re-login (guided, not forced)
   and the daemon must then be started; package managers require sudo.
3. Ask for confirmation.

For the privileged steps the installer needs `sudo` without a TTY. On Linux, set this
up first with the global **sudo-askpass** skill (it auto-detects the desktop's askpass
helper and exports `SUDO_ASKPASS`), then call the installer in the same shell so the
variable is in scope:

> Invoke the `sudo-askpass` skill, then run:
>
> !`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/install-deps.sh" <tools...>`
>
> where `<tools...>` is the explicit list the user confirmed (e.g. `git jq docker ddev`)
> or `all`. The installer is idempotent: it skips tools that are already present and OK,
> detects the OS via `os_id` (Fedora -> dnf), uses `sudo -A` when `SUDO_ASKPASS` is set,
> and refuses to install anything without `--yes`/`DRUPILOT_ASSUME_YES` unless a TTY
> confirmation is given.

## Step 5 — Re-check

After any install, re-run Step 1's report so the user sees the updated readiness, and
remind them of any manual follow-up (Docker group re-login, starting the daemon,
uploading the SSH key / exporting the PAT). If nothing was missing, simply confirm the
environment is ready and point at `/drupilot-setup` as the next step.
