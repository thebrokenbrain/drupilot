<?php

namespace Drupal\php_floor_signals;

/**
 * Baseline input: the PHP 8.3 Override attribute.
 */
class Overridden extends \ArrayObject {

  #[\Override]
  public function count(): int {
    return 0;
  }

}
