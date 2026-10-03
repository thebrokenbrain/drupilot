<?php

namespace Drupal\acme_reports;

use Drupal\acme_utils\Helper;
use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\node\NodeInterface;

/**
 * Builds Acme reports.
 */
class ReportBuilder {

  /**
   * Constructs a ReportBuilder.
   */
  public function __construct(
    protected Helper $helper,
    protected EntityTypeManagerInterface $entityTypeManager,
  ) {}

  /**
   * Builds one report row for a node.
   */
  public function row(NodeInterface $node): array {
    return [$this->helper->slug($node->label())];
  }

}
