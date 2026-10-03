<?php

namespace Drupal\acme_search;

use Drupal\acme_api\Client\ApiClient;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\search_api\IndexInterface;

/**
 * Pushes remote items into a Search API index.
 */
class Indexer {

  /**
   * Constructs an Indexer.
   */
  public function __construct(
    protected ApiClient $client,
    protected EntityTypeManagerInterface $entityTypeManager,
  ) {}

  /**
   * Indexes one remote item.
   */
  public function index(IndexInterface $index, string $id): void {
    $item = $this->client->fetch($id);
    if ($item) {
      $index->reindex();
    }
  }

}
