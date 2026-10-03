<?php

namespace Drupal\legacy_widgets;

use Drupal\Core\Entity\Sql\SqlContentEntityStorage;

/**
 * Storage handler for legacy widgets.
 */
class LegacyWidgetStorage extends SqlContentEntityStorage {

  /**
   * Builds the cache ID used for a widget revision.
   *
   * This is a module-local helper on Drupal 10; Drupal 11.3+ core declares a
   * method with the same name on ContentEntityStorageBase.
   *
   * @param int|string $id
   *   The revision ID.
   *
   * @return string
   *   The cache ID.
   */
  protected function buildRevisionCacheId($id): string {
    return 'legacy_widget:revision:' . $id;
  }

  /**
   * Loads widgets by label.
   *
   * @param string $label
   *   The label.
   *
   * @return \Drupal\legacy_widgets\Entity\LegacyWidget[]
   *   The matching widgets.
   */
  public function loadByLabel(string $label): array {
    return $this->loadByProperties(['label' => $label]);
  }

}
