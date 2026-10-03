# monorepo fixture — expected drupilot results

Synthetic Drupal 10.3 site (`acme/site`) with 8 custom modules + 1 submodule under
`web/modules/custom`, for `/drupilot-layers` (item 4.1: `scripts/analysis/layers.sh`)
and the metadata lint (item 4.7: `scripts/analysis/lint-extension-metadata.sh`).
No core/contrib is installed (`web/core`, `vendor` are absent), so core modules are
recognized from drupilot's built-in list.

## Modules

| Module | Declared deps | Role in the fixture |
|---|---|---|
| acme_core | none | Clean base: services, route, library, attribute Block plugin, config with exact + wildcard (`acme_core.profile.*`) schema. Zero lint findings (false-positive control). |
| acme_utils | `acme_core:acme_core` | Chain layer 1; orphan service. |
| acme_api | `acme_utils:acme_utils`, `token:token (>=8.x-1.13)` + composer `drupal/token` | Chain layer 2; arity mismatch; undeclared `acme_core`. |
| acme_search | `acme_api` (bare form) + composer `drupal/search_api` | Chain layer 3; uses `Drupal\search_api` with the dependency only in composer.json. |
| acme_search/modules/acme_search_ui | `acme_search:acme_search` | Submodule, chain layer 4; obsolete `core_version_requirement: ^8.8 \|\| ^9 \|\| ^10`; library dependency on `acme_core/base` undeclared. |
| acme_billing | `acme_core:acme_core`, `acme_invoice:acme_invoice` | Cycle with acme_invoice; config/optional block placement of `acme_core_banner` (optional plugin reference, declared anyway). |
| acme_invoice | `acme_core:acme_core`, `acme_billing:acme_billing` | Cycle; `configure:` points to a missing route. |
| acme_reports | **none** | Uses everything undeclared; config without schema; inherited constructor; a `moduleExists('acme_search')`-guarded service use (optional). |
| acme_standalone | none | Leaf with no deps nobody depends on; mentions `\Drupal\acme_billing\...` / `\Drupal\acme_invoice\...` only in comments (must NOT count). |

## Hazards

| ID | Hazard | Where | Expected |
|---|---|---|---|
| M1 | Dependency chain of 4 layers + submodule | core → utils → api → search → search_ui | Layers 0..4 in that order. |
| M2 | Cycle | acme_billing ↔ acme_invoice (info.yml + code) | Reported in `cycles`; both in ONE layer (1, after acme_core) as a cycle group. |
| M3 | Undeclared project deps (class / service / route / plugin / library) | acme_reports: `use Drupal\acme_api\...` + `\Drupal::service('acme_api.client')`, `@acme_utils.helper` + `use Drupal\acme_utils\Helper`, `Url::fromRoute('acme_core.settings')`, `createInstance('acme_core_banner')`, library `acme_core/base`; acme_api: `use Drupal\acme_core\AcmeFormatter` + `$container->get('acme_core.formatter')`; acme_search_ui: `- acme_core/base` | Proposed `- acme_api:acme_api`, `- acme_utils:acme_utils`, `- acme_core:acme_core` (reports), `- acme_core:acme_core` (api, search_ui). |
| M4 | Undeclared contrib dep | acme_reports `SlugCleaner extends Drupal\pathauto\AliasCleaner` | `- pathauto:pathauto` flagged "verify the project name". |
| M5 | Undeclared core dep | acme_reports `use Drupal\node\NodeInterface` | `- drupal:node`. |
| M6 | Contrib dep only in composer.json | acme_search → search_api | Undeclared (declared_via `composer`): "Drupal does not enable it"; proposed `- search_api:search_api`. |
| M7 | Optional integration | acme_reports `moduleExists('acme_search')` guard | `optional`, NOT proposed, NOT an ordering edge (lint: info). |
| M8 | Layer "advanced" by missing declarations | acme_reports | Layer 3 with all edges, layer 0 with declared only → listed in `early`. |
| M9 | Leaf without deps | acme_standalone | Layer 0; comment-only namespace mentions ignored. |
| M10 | Config without schema | acme_reports `config/install/acme_reports.settings.yml` | lint `config-schema` warn. (acme_core's exact + wildcard schema: no finding.) |
| M11 | `configure:` to a missing route | acme_invoice.info.yml:6 (`acme_invoice.settings`; real `acme_invoice.settings_form`) | lint `configure-route` warn with "did you mean 'acme_invoice.settings_form'". |
| M12 | Orphan service class | acme_utils.services.yml:7 (`Drupal\acme_utils\Legacy\OldHelper`) | lint `services-class` error. |
| M13 | Service args vs constructor | acme_api.services.yml:3 (3 args, constructor 2) | lint `services-arity` warn. acme_core.formatter (1 arg, ctor 1 required of 2) and the others: no finding. acme_reports.cleaner (inherited ctor from pathauto): info "not checked". |
| M14 | Obsolete submodule core req | acme_search_ui.info.yml:5 | lint `submodule-core-req` warn; `set-core-requirement.sh --subject acme_search --requirement '^10 \|\| ^11'` bumps main + submodule. |
| M15 | Project-prefixed + bare dependency forms | `acme_core:acme_core`, `acme_api`, `token:token (>=8.x-1.13)` | All parsed to their module (constraint stripped). |

## Expected `layers.sh --dir <fixture> --json` (edges `all`)

```
layers: 0 [acme_core, acme_standalone]
        1 [acme_billing, acme_invoice, acme_utils]   cycle_groups [[acme_billing, acme_invoice]]
        2 [acme_api]
        3 [acme_reports, acme_search]
        4 [acme_search_ui]
cycles: [[acme_billing, acme_invoice]]
early:  [{module: acme_reports, layer: 3, declared_layer: 0}]
totals: {modules: 9, layers: 5, cycles: 1, undeclared: 8, undeclared_modules: 4}
external: node (core, acme_reports), pathauto (external, acme_reports),
          search_api (external, acme_search), token (external, acme_api)
```

With `--edges declared`: acme_reports moves to layer 0, everything else unchanged.

## Expected `lint-extension-metadata.sh --subject web/modules/custom/<m> --json` totals

| Module | error | warn | info | Findings |
|---|---|---|---|---|
| acme_api | 0 | 2 | 0 | services-arity (M13), undeclared-deps acme_core |
| acme_billing | 0 | 0 | 0 | — |
| acme_core | 0 | 0 | 0 | — |
| acme_invoice | 0 | 1 | 0 | configure-route (M11) |
| acme_reports | 0 | 6 | 2 | config-schema (M10); undeclared-deps acme_api, acme_core, acme_utils, node, pathauto; info: inherited ctor, optional acme_search |
| acme_search | 0 | 3 | 0 | undeclared-deps search_api (composer only), submodule-core-req (M14), undeclared-deps acme_search_ui → acme_core |
| acme_standalone | 0 | 0 | 0 | — |
| acme_utils | 1 | 0 | 0 | services-class orphan (M12) |

(The subject's parent `web/modules/custom` is used automatically as `--set-dir`, so
services/routes/plugins of sibling modules resolve.)

## Real Drupal 11 check (done once by hand on a Drupal 11.4.8 test-bed)

Modules copied under `web/modules/custom/acme`, `set-core-requirement.sh --requirement '^10.3 || ^11'`
on each (all 9 info.yml files, submodule included):

- `drush en acme_reports` alone (it declares no dependencies) **breaks the site**:
  `The service "acme_reports.builder" has a dependency on a non-existent service
  "acme_utils.helper"`, the module stays enabled and `drush cr` fails.
- In layer order (acme_core, acme_utils, then acme_reports) the container then fails on
  `acme_reports.cleaner` -> `pathauto.alias_cleaner` (M4: the undeclared contrib dependency).
- With the proposed entries declared (`acme_api:acme_api`, `acme_core:acme_core`,
  `acme_utils:acme_utils`, `drupal:node`, `pathauto:pathauto`) Drupal refuses cleanly:
  `module 'acme_reports' is missing its dependency module token` (via acme_api), nothing is
  enabled and `drush cr` succeeds.

Assertions for this file: `scripts/dev/smoke.sh` (tests `layers` and `lint-metadata`).
