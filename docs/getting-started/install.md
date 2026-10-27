# Install

drupilot is a Claude Code plugin. It ships as a single-plugin marketplace, so installing it takes two commands.

## Requirements

drupilot checks only what each operation needs, so a static analysis does not need Docker.

| Operation | Hard requirements | Optional |
| --- | --- | --- |
| **Analysis** (`/drupilot-assess`, the static part of `/drupilot-port`) | `git`, `jq`, and `composer` or `php` at or above the PHP target | — |
| **Environment and tests** (`/drupilot-setup`, `/drupilot-test`) | Docker with its daemon running, and DDEV | the Selenium add-on, for FunctionalJavascript tests |
| **Contribution** (Drupal.org) | `git`, a drupal.org account with GitLab access, and an SSH key or a personal access token | `glab` or `curl` for the GitLab API |

- **Claude Code** 2.1.271 or later.
- **Shell:** the scripts and hooks run on bash 3.2 or later, with BSD or GNU tools, so stock macOS works as it is.
- DDEV provides the whole Drupal environment (web server, database, browser driver) on top of Docker: there is no
  LAMP stack to set up.

Run `/drupilot-doctor` at any time. It prints what each operation needs, what is missing, how to install it on your
platform, and a few report-only health checks. It can install a missing tool after you confirm.

## Install

From GitHub:

```text
/plugin marketplace add thebrokenbrain/drupilot
/plugin install drupilot@drupilot
```

From a local checkout:

```text
/plugin marketplace add /path/to/drupilot
/plugin install drupilot@drupilot
```

Then start a new session, so the hooks load, and run `/drupilot-doctor`.

## Update

```text
claude plugin update drupilot@drupilot
```

Claude Code can also update the plugin on its own. Auto-update is off by default for a third-party marketplace such
as drupilot's: turn it on in `/plugin` → Marketplaces. When it runs, it fires within a few minutes of a session's
first message and asks you to run `/reload-plugins`.

Coming from drupilot 0.9? Read [Upgrading from 0.9 to 1.0](../upgrading/0.9-to-1.0.md) first.

## Develop or test a checkout

To try a branch or your own changes, start Claude Code on the checkout instead of installing it:

```text
claude --plugin-dir /path/to/drupilot
```

Its commands are then namespaced (`/drupilot:drupilot-port`, ...), and for that session it takes the place of the
installed plugin. Do not add a checkout as a marketplace while the installed plugin is registered: the checkout's
catalog is also named `drupilot`, and resolving the clash means uninstalling the installed plugin.

`claude plugin validate /path/to/drupilot` checks the plugin's manifest.
