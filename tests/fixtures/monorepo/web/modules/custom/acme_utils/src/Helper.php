<?php

namespace Drupal\acme_utils;

use Drupal\acme_core\AcmeFormatter;

/**
 * Acme helper.
 */
class Helper {

  /**
   * Constructs a Helper.
   */
  public function __construct(protected AcmeFormatter $formatter) {}

  /**
   * Returns a slug.
   */
  public function slug(string $text): string {
    return strtolower(preg_replace('/[^a-z0-9]+/i', '-', $this->formatter->format($text)));
  }

}
