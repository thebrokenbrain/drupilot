<?php

namespace Drupal\php_floor_signals;

/**
 * Baseline input: a PHP 8.2 read-only class.
 */
final readonly class Snapshot {

  public function __construct(public string $value) {}

}
