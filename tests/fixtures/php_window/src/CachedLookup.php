<?php

namespace Drupal\php_window;

use Drupal\Core\DependencyInjection\DependencySerializationTrait;

/**
 * A lookup that is serialized with the form state.
 *
 * __sleep() stays: DependencySerializationTrait defines __sleep() and
 * __wakeup(), so Rector's SleepToSerializeRector is denied for Drupal.
 */
class CachedLookup {

  use DependencySerializationTrait;

  /**
   * The cached values.
   */
  protected array $values = [];

  /**
   * {@inheritdoc}
   */
  public function __sleep(): array {
    return ['values'];
  }

}
