---
description: Port a SET of custom modules (a monorepo's web/modules/custom, a folder of modules) layer by layer. Computes the porting layers from info.yml + composer.json dependencies plus the dependencies the code really uses (classes, services, routes, libraries, plugins), reports cycles and undeclared dependencies with a proposed `<project>:<module>` entry, then — on request — ports each layer's modules one after another through the normal drupilot flow and writes a consolidated layer report. Use for "/drupilot-layers", "port all the custom modules", "in which order should I port these modules", "find undeclared dependencies in my modules".
argument-hint: "<dir> [plan|run] [--layer N] [--edges all|declared]"
allowed-tools: Bash, Read, Edit, Task, AskUserQuestion
---

# drupilot — layers (port a set of modules in dependency order)

All output is in **English**. `$1` is the directory holding the modules (default:
the current directory); `$2` is the mode: `plan` (default, read-only) or `run`.
Other flags in `$ARGUMENTS`: `--layer N` (run one layer), `--edges all|declared`.

Porting a set out of order is what breaks batch ports: a module ported before the
module whose classes/services it uses cannot be tested, and a dependency the
code uses but `dependencies:` does not declare makes a module "advance" to an
early layer. This command orders the work and makes those gaps visible. It
never edits an `info.yml` on its own and never does anything outward-facing.

## Step 1 — Gate (read-only analysis)

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/preflight.sh" --profile analyze --json`

If `ready.analyze` is false, print the actionable report and stop (no side effects).
Read the autonomy flag:

!`bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; printf "autonomous=%s\n" "$(config_get DRUPILOT_AUTONOMOUS false)"; printf "placement=%s\n" "$(config_get DRUPILOT_PLACEMENT move)"; printf "layers_sandbox=%s\n" "$(config_get DRUPILOT_LAYERS_SANDBOX "")"'`

## Step 2 — Compute the layers (always)

Run it yourself, substituting the directory (and `--edges declared` only when the
user asked for it):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/layers.sh" --dir <dir> --json
```

STDOUT is `{layers:[{index, modules, cycle_groups}], cycles, early, modules:[{machine,
layer, in_cycle, depends_on, declared, implicit, undeclared, proposed}], external,
totals}` (header of `layers.sh`). It also saves `layers.json` (hidden state) and
`layers.md` (the visible `.drupilot/`): the canonical plan, all edges. An
`--edges declared` run saves `layers-declared.json` / `layers-declared.md`
instead and leaves the canonical plan alone. Exit 1 = no `*.info.yml` under the
directory: say so and stop.

Present, concisely:

1. The **layers** table (layer → modules; mark cycle members).
2. **Cycles** — each group is ported together, in the same layer; suggest moving
   the shared code into a module both can depend on.
3. **Early** modules — ordered by declared dependencies alone they would be ported
   too early; the real order follows what the code uses (`--edges all`, default).
4. **Undeclared dependencies** — per module: the module used, how (class / service /
   route / library / plugin / config), the evidence `file:line`, and the proposed
   entry: `- <project>:<module>` for one of the set (the project is the top-level
   module containing it), `- drupal:<module>` for core, `- <module>:<module>` for
   contrib (**verify the drupal.org project name**). Uses guarded by
   `moduleExists()` / `config/optional` / `@?service` are optional and not proposed.
   The detection is a heuristic (line-based, no PHP/YAML parser): review the
   evidence, never treat it as proof.
5. **Outside the set** — core and contrib modules the set needs (run
   `deps-status.sh --subject <module dir>` for a contrib module's Drupal 11 readiness).

**Learned patterns.** The set shares ONE pattern catalog (`patterns.sh`): the
pitfalls a module's port hit, with a detector and the fix, recorded at the end
of its port and checked on every later module BEFORE it is ported — so layer
N+1 prevents what layer N had to repair. Resolve it once for the set and use
that path as `<catalog>` below:

```bash
bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; patterns_file "$1"' _ <dir>
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/patterns.sh" list --catalog <catalog> --json
```

(`<Drupal root>/.drupilot/patterns.json` for a set inside a Drupal root; for a
loose folder, the `.drupilot/` of its git toplevel or of the folder;
`DRUPILOT_PATTERNS_FILE` overrides it.) When the catalog has entries, scan the
modules of the next layer to port and list the hits per module (read-only):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/patterns.sh" scan --subject <module dir> --catalog <catalog> --json
```

Also run the metadata lint for each module when the user wants the full picture
(`plan` with "hygiene", or before `run`), and summarize the totals per module:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/lint-extension-metadata.sh" --subject <module dir> --json
```

## Step 3 — `plan` mode (default): stop here, offer the next step

Ask with **AskUserQuestion** (skip when `autonomous=true`: print the plan and stop):

- **Port layer `<lowest layer with unported modules>` now** (recommended) — go to
  Step 4 with that layer.
- **Add the proposed dependencies first** — show the exact `dependencies:` lines per
  `info.yml` as a diff; apply them with Edit only after the user confirms the diff
  (one confirmation for all, or per module). Never in autonomous mode. Re-run
  Step 2 afterwards: the layers may change.
- **Stop** — the plan is in `.drupilot/layers.md`.

## Step 4 — `run` mode: port one layer, module by module

1. **Pick the layer.** `--layer N` when given; otherwise the lowest layer that has
   a module whose stage is below `ported`. Read each module's stage (read-only):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/state.sh" list --root <dir> --no-next --json
   ```

   (`subjects[].machine_name`, `.stage`; a module moved by a `move` placement is
   still found through its recorded origin.) A layer is **ready** only when every
   module of the earlier layers it depends on is at least `ported` — if not, say
   which ones are missing and recommend porting that layer first.

2. **Sandbox.** If `<dir>` is inside a Drupal root (the monorepo case: the
   modules sit under `web/modules/custom` of a Composer project), every module is
   ported **in place, in that one site** — the modules a layer depends on are
   installed alongside it, which is what lets its tests run. Nothing to choose.
   If `<dir>` is a loose folder of modules, ask with **AskUserQuestion**
   (autonomous: use the first option, it changes nothing):
   - **One test-bed per module** (today's behavior, recommended when the layer's
     modules do not depend on each other or on earlier layers) — each module gets
     its sibling `<name>-d11` workspace.
   - **One shared test-bed for the whole set** — set
     `DRUPILOT_WORKSPACE_DIR=<parent of dir>/<basename of dir>-d11` for every
     module, so a module and the modules it depends on are placed in the same
     Drupal site. Placement follows `DRUPILOT_PLACEMENT` (`placement` above;
     `move` relocates each checkout — say so before choosing; `copy` leaves the
     originals untouched).
   A `DRUPILOT_LAYERS_SANDBOX` already set (`per-module` / `shared`, env or
   `.drupilot.json`) answers this without asking. Persist a new answer once a
   Drupal root exists (the shared test-bed, after its setup):

   ```bash
   bash -c '. "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"; DRUPILOT_PROJECT_DIR="$1" prefs_set DRUPILOT_LAYERS_SANDBOX "$2"' _ <drupal root> <per-module|shared>
   ```

3. **Confirm** the layer and the module order with **AskUserQuestion** (skip when
   `autonomous=true`): the modules in the layer, those skipped as already ported,
   and that each one runs the normal flow (setup → assess → port → test, Phase 1;
   refactor and contribute stay opt-in).

4. **Port each module sequentially** — never in parallel (they may share a
   site). For each module of the layer, in the listed order (a cycle group's
   members one after another), delegate to the **drupal-port-orchestrator**
   subagent via the Task tool with:
   - the module directory as the subject;
   - the run mode: `auto` when `autonomous=true`, else `full` (its confirmations
     stay on; `auto` never pushes or opens an MR — contribution is never part of
     a layer run);
   - **batch context**: `portfolio=<dir>`, `layer=<N>`, `catalog=<catalog>` (the
     set's pattern catalog: the module is scanned with it before porting and
     records what it teaches into it, `--layer <N>`), and the per-module
     artifacts directory `<Drupal root>/.drupilot/modules/<machine>` to pass to
     `port-report.sh --output` (several modules share one site, so they must not
     overwrite each other's `port-report.md`);
   - the instruction to stop that module (not the layer) at a failed gate and
     report why.

   After each module, record its batch context (stage changes are recorded by
   the flow's own scripts):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/env/state.sh" refresh --subject <module dir now> --portfolio <dir> --layer <N>
   ```

   If a module ends with a **regression** or a blocked gate, finish the other
   modules of the same layer, but do not start the next layer: its modules may
   depend on the broken one.

5. **Consolidated report** for the layer:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/analysis/layer-report.sh" --dir <dir> --layer <N>
   ```

   Pass the same `--edges declared` when the run used it; the report states the
   layering it used (`edges`).

   It writes `.drupilot/layer-<N>-report.md` from `templates/layer-report.md.tmpl`
   — the same fixed sections for every layer, so layers compare: per-module
   result (stage, effort, preservation, Drupal 10 verdict, pre-existing
   hygiene, undeclared dependencies, Rector files, reverted Rector changes,
   post-port fixes, patch, link to its port report), frequent Rector rules
   with hits AND reversions, manual changes, post-port fixes, pre-existing
   bugs, behavior changes to review in the PR, tooling/flow deviations and how
   it was validated — and prints the path. Sections 2-8 come from each
   module's port manifest and decision log (`log-decision.sh`), so they are
   only as complete as what the module's flow recorded; `--json` gives the
   cross-module `aggregate`. A set ported outside `/drupilot-layers` is
   reported with `layer-report.sh --subject <dir> --subject <dir> --name <label>`. Relay its
   totals and the patterns this layer added to the catalog (entries of
   `patterns.sh list --catalog <catalog> --json` whose `seen_in` has `layer: N`
   — they will be checked on the next layer), then ask with **AskUserQuestion** (autonomous: stop after the layer and
   recommend the next one): **Port layer N+1** (recommended when the layer is clean)
   / **Stop here**.

## Rules

- Never apply a proposed dependency without the user's confirmation; never in
  autonomous mode.
- Never run two modules' flows at the same time.
- Never push, open an MR or run `/drupilot-contribute` from a layer run, even in
  `auto` contribution mode: contribution stays per module and opt-in.
- `DRUPILOT_AUTONOMOUS=true` only skips drupilot's own confirmations; the Claude
  Code permission mode still governs Bash/Edit/Write.
- Point at `/drupilot-status --all <dir>` for the per-module records at any time.
