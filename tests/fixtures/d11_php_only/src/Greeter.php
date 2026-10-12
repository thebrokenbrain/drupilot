<?php

namespace Drupal\d11_php_only;

/**
 * Greets a name.
 */
class Greeter {

  /**
   * Builds the greeting.
   *
   * The implicitly nullable parameter is deprecated in PHP 8.4.
   */
  public function greet(string $name = NULL): string {
    return 'Hello ' . ($name ?? 'world');
  }

}
