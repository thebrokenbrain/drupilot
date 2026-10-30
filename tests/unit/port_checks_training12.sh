#!/usr/bin/env bash
# The port-safety check migrate-dependencies-expand (training run module 12,
# location_migration: its migrate field plugin, run by its derivers, called
# getMigrationDependencies(), which expands the plugin IDs from Drupal 11.0
# and recursed until the Kernel test ran out of memory), Docker-free:
# - a call in src/Plugin/migrate/field/ and one in a *Deriver.php file are
#   warnings while the range admits Drupal 11; a commented call, a call in
#   another src/ class and getPluginDefinition() are not;
# - on at assess time too, when the declared range is still ^9 || ^10: the
#   target major admits Drupal 11 (as config-schema-sequence).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
PS="$T_REPO/scripts/analysis/check-port-safety.sh"

M="$T_TMP/m"; mkdir -p "$M/src/Plugin/migrate/field" "$M/src/Plugin/Derivative" "$M/src/Controller"
printf 'name: M\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$M/m.info.yml"
cat > "$M/src/Plugin/migrate/field/MField.php" <<'PHP'
<?php

namespace Drupal\m\Plugin\migrate\field;

class MField {

  public function alterFieldInstanceMigration($migration) {
    // $deps = $migration->getMigrationDependencies();
    $deps = $migration->getMigrationDependencies() + ['required' => []];
    $raw = $migration->getPluginDefinition()['migration_dependencies'] ?? [];
  }

}
PHP
cat > "$M/src/Plugin/Derivative/MDeriver.php" <<'PHP'
<?php

namespace Drupal\m\Plugin\Derivative;

class MDeriver {

  public function getDerivativeDefinitions($base) {
    $deps = $this->migration
      ->getMigrationDependencies(TRUE);
  }

}
PHP
cat > "$M/src/Controller/MController.php" <<'PHP'
<?php

namespace Drupal\m\Controller;

class MController {

  public function page($migration) {
    return $migration->getMigrationDependencies();
  }

}
PHP
t_run "$T_SH" "$PS" --subject "$M" --checks migrate-dependencies-expand --json
assert_eq "^10 || ^11: the field plugin and the deriver calls, warnings" \
  "$T_RC|$(jq -c '[.findings[] | [.check, .file, .line, .severity]]' "$T_OUT")" \
  '0|[["migrate-dependencies-expand","src/Plugin/Derivative/MDeriver.php",9,"warn"],["migrate-dependencies-expand","src/Plugin/migrate/field/MField.php",9,"warn"]]'
assert_match "  the message names the release and the portable read" \
  "$(jq -r '.findings[0].message' "$T_OUT")" \
  "from Drupal 11\.0\.0 it always expands the plugin IDs.*getPluginDefinition\(\)\['migration_dependencies'\]"
t_run "$T_SH" "$PS" --subject "$M" --checks migrate-dependencies-expand --core-req '^9 || ^10' --json
assert_eq "^9 || ^10 (assess time): still on, the target admits Drupal 11" "$T_RC|$(jq -c '[.findings[].line]' "$T_OUT")" "0|[9,9]"
t_done
