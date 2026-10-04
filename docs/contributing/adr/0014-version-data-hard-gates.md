# 0014 — The schemas mark what a hard gate reads, and the data follows the source

- **Status:** accepted
- **Date:** 2026-10-04
- **Decided by:** the 1.0 working session (R-AUTO-3), during M2 (T-M2-01..06)

## Context

The 1.0 plan (AR-02..AR-04) says only verified values that are never
`verified_as: "announced"` may drive a hard gate, and that the `data` gate
enforces it. It does not say how the gate knows which values a hard gate
reads. Writing the data from the primary sources also contradicted the
plan's examples in several places.

## Decision

1. **The schemas mark the hard-gate nodes.** A subschema annotated
   `"x-drupilot-hard-gate": true` describes a node a hard gate reads: a
   target's minors (the PHP support lists), `upgrade_from_min`, `status_src`,
   every removed extension and library, every PHP version. JSON Schema
   ignores unknown keywords, so `check-jsonschema` accepts the annotation;
   `scripts/dev/data-check.sh` walks the schema with the instance (reading
   the annotation next to a `$ref` and inside `anyOf` branches too) and
   requires `verified: true` and no `verified_as` on each node (a
   `{"status": "detect"}` minor holds no value). A catalog entry is a
   hard-gate node when it is `blocking: true`. Advisory notes
   (`namespace_moves`) are not marked.
2. **PHP support is two lists per minor**, `php_supported` (the table's Yes)
   and `php_unsupported` (its No); a PHP in neither is unknown. That is how
   drupal.org's table says "Follow issue #3608511" for PHP 8.6 on 11.4 and
   12.0, and it reproduces every answer of the 0.9.1 `php_supported_for`.
   A minor the table does not list falls back to the PHP version's
   `drupal_core_floor` (8.5: 11.3), only where the table makes it certain.
3. **Generated and hand-maintained fields share a file.**
   `scripts/dev/refresh-data.sh` rewrites only the derived fields of each
   minor, from its newest tag, and writes the files in jq's layout so offline
   runs are byte-identical; it reports, never writes, what needs a human
   (removals the core tree contradicts, an extension directory or a
   `core.libraries.yml` key that disappears at a major's .0 without being
   listed, drupal.org pages changed since read). Where the
   deprecated-and-obsolete page and the core tree disagree, the tree wins
   and the entry's note says so.
4. **Major 10 is not a target.** `toolchain_cell`, `php_defaults` and
   `default_ranges` are optional in the schema and required by the gate only
   from major 11 on; `config/targets/10.json` exists for keep-previous.
5. **The data follows the sources where the plan's examples differ:**
   - the removed libraries are every `core/core.libraries.yml` key gone
     between the previous major's newest tag and the major's .0: 22 in 10.0
     (among them the public `core/backbone` and `core/underscore`), 14 in
     11.0, and 3 in 12.0 (`core/internal.backbone`,
     `core/internal.underscore`, `core/js-cookie`), not the two of AR-02's
     example;
   - Migrate Drupal and Migrate Drupal UI are in the 12.0.0-beta1 release
     notes' removal list and still in its tree as `lifecycle: obsolete` (they
     cannot be installed); they are recorded with `state_at_removal:
     obsolete`, not as absent;
   - the deprecation minors follow the tree: Migrate Drupal 11.4.0 (the
     page's sentence names Migrate Drupal UI by mistake), Field Layout
     11.3.0 (the page says 11.4), Telephone 11.5.0 (the page says 11.4.0, but
     only the 11.5.x branch marks it deprecated);
   - the extensions the page lists but AR-02 does not are there too:
     `simpletest` (an obsolete stub removed in 10.0), `help_topics` (11.0)
     and `node_storage_body_field` (added in 11.3.0, removed in 12.0, nested
     under the node module: `info_path`);
   - "a required parameter after an optional one" is deprecated in PHP 8.0,
     not a hard break (php.net's 8.0 deprecations page), and the historical
     `implode()` argument order was removed in 8.0;
   - a deny rule may carry neither `deprecated_in` nor `removed_in` (a rule
     denied for what it emits, as AR-03's own deny example shows), although
     T-M2-01 asks every rule for one of them.

## Consequences

A new value a hard gate will read needs the annotation in its schema, or the
gate cannot protect it. A drupal.org page or a core tag that changes surfaces
as a `refresh-data.sh` report (exit 3), and its fields are re-read by hand.
The re-verification points of R-FACT-4 (RC, GA) are `reverify_at` in the
entries and the `hand_sources` dates.
