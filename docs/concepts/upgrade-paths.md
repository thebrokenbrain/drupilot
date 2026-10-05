# Upgrade paths

!!! note "Summary"
    Before it changes any code, drupilot resolves an **upgrade plan**: where
    your module comes from, which Drupal it goes to, the core range it will
    declare and the PHP versions it must run on. Every later step reads its
    versions from that plan. The plan is frozen in the project's lock, so a
    port can be repeated with the same versions.

## The three axes

A port is a point on three axes.

- **Source major (S)**: the oldest Drupal whose APIs the code still uses.
  `scripts/analysis/detect-source.sh` reads it from the code: the
  `core_version_requirement`, `.info` files, the APIs it calls (ADR 0016).
- **Target major (T)**: the Drupal you port to. It is 11 for all of 1.0.x, set
  by `DRUPILOT_TARGET_MAJOR`. The setup asks for it only when a newer major is
  opted into as a preview (`DRUPILOT_ALLOW_PRERELEASE`).
- **PHP target (P)**: the PHP the code runs on in the test-bed and on your
  site, set by `DRUPILOT_PHP_TARGET` or the setup's PHP tab.

From these the plan derives:
- **the declared range C**: the module's `core_version_requirement`, and its
  floor F, the lowest core minor kept;
- **the PHP floor L**: the lowest PHP that range admits, raised to what the
  code itself needs;
- **the PHP window [L..P]**: every PHP the code must work on.

PHPStan checks the code against that window (`phpVersion`, ADR 0020), and
Rector rewrites nothing past L (ADR 0002).

## Hops

The path from S to T is a list of **hops**, one per major: a Drupal 9 module
going to 11 takes the hops `9-10` and `10-11`. Each hop brings its
drupal-rector sets, the per-minor sets of the major it leaves. They are
rendered into `rector.php` (ADR 0019). The Drupal 8 and 9 sets join once
their hops are proven; until then, those hops add their detectors only. A
module already on T (S = T) has no hop: only its PHP moves.

A Drupal 7 module takes the `d7-assisted` track. It is a rewrite, not an
upgrade: it is experimental, and it never runs in an autonomous run.

## The core range: strategies

The range the port declares follows a **strategy**. The `/drupilot-port`
"Core target" tab answers it, or `DRUPILOT_CORE_TARGET_STRATEGY`.

| Strategy | Declares (for a port to Drupal 11) | 0.9 name |
| --- | --- | --- |
| `auto` | Keeps the previous major while the port stays backwards compatible, else the target only. A module already compatible keeps its declaration (`keep-current`). | `auto` |
| `keep-previous` | `^10 \|\| ^11`, or `^10.N \|\| ^11` when the code needs Drupal 10.N | `keep-d10` |
| `target-only` | `^11` | `d11-only` |
| `widest` | The widest range the data allows (for Drupal 11, the same as `keep-previous`) | none |
| `explicit` | The range you give (`--range`, or a `DRUPILOT_DRUPAL_TARGET` that admits two or more majors, ADR 0021) | none |

For Drupal 11 drupilot still writes the 0.9 names in its outputs (see
[Deprecations of drupilot](../reference/deprecations-of-drupilot.md)).

## Two phases

The plan is resolved twice. Both runs go through
`scripts/analysis/upgrade-path.sh`.

1. **Draft**, at `/drupilot-setup`. It resolves T, P, the test-bed's core and
   the toolchain from the code and drupilot's version data, before the
   test-bed exists, and freezes them.
2. **Final**, at `/drupilot-port`, after the assessment and the core-target
   answer. It may only add hops or raise F; it never changes T, P or the
   test-bed (ADR 0018). Asking for anything else is refused with
   `final-changes-frozen`, and the setup has to be re-run.

The lock keeps the frozen plan with its hash (`upgrade_plan`,
`upgrade_plan_hash`, `upgrade_plan_phase`). In deterministic mode
(`DRUPILOT_DETERMINISTIC`, on by default) a later run reuses it while the
request is the same. A change of drupilot's version data never moves a
frozen plan.

## Refusals

When no plan fits the request, the resolver writes nothing and exits 2. It
prints the violations and the choices that would resolve each. Examples:
- a PHP target the target's newest release does not support;
- a declared range that excludes the test-bed's core;
- a pre-release major that is not opted into;
- a Drupal 7 source in an autonomous run.

The commands show those choices as the tab to re-ask.

## See the plan

`bash "$CLAUDE_PLUGIN_ROOT/scripts/drupilot.sh" plan show` prints the plan of
the module in the current directory: the frozen one when it exists, else a
draft that is not written. Add `--json` for the plan itself, as
`upgrade-path.sh --json` prints it (its schema is
`schemas/upgrade-plan.schema.json`). The commands and skills render this block
when they load.

## Names

The target major names drupilot's outputs. For Drupal 11 they are the 0.9
names:

| Output | Name |
| --- | --- |
| Local patch | `<module>-port-to-drupal-<T>.patch` |
| Issue fork branch | `<issue>-port-to-drupal-<T>` |
| Test-bed of a loose module | `<module>-d<T>` |
| DDEV project type | `drupal<T>` |
