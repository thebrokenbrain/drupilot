<?php

namespace Drupal\acme_reports;

use Drupal\pathauto\AliasCleaner;

/**
 * Cleans report slugs with pathauto's cleaner.
 */
class SlugCleaner extends AliasCleaner {

  /**
   * Cleans a slug.
   */
  public function cleanSlug(string $slug): string {
    return $this->cleanString($slug);
  }

}
