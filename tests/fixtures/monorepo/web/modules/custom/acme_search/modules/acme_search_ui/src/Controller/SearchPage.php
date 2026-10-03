<?php

namespace Drupal\acme_search_ui\Controller;

use Drupal\Core\Controller\ControllerBase;

/**
 * The Acme search page.
 */
class SearchPage extends ControllerBase {

  /**
   * Renders the page.
   */
  public function page() {
    return [
      '#markup' => $this->t('Search'),
      '#attached' => ['library' => ['acme_search_ui/search-page']],
    ];
  }

}
