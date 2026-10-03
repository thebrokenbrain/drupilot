<?php

namespace Drupal\legacy_widgets;

use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Database\Connection;

/**
 * Counts legacy widgets and classifies counts into buckets.
 */
class WidgetCounter {

  /**
   * The database connection.
   *
   * @var \Drupal\Core\Database\Connection
   */
  protected $database;

  /**
   * The config factory.
   *
   * @var \Drupal\Core\Config\ConfigFactoryInterface
   */
  protected $configFactory;

  /**
   * Constructs a WidgetCounter.
   *
   * @param \Drupal\Core\Database\Connection $database
   *   The database connection.
   * @param \Drupal\Core\Config\ConfigFactoryInterface $config_factory
   *   The config factory.
   */
  public function __construct(Connection $database, ConfigFactoryInterface $config_factory) {
    $this->database = $database;
    $this->configFactory = $config_factory;
  }

  /**
   * Returns the number of stored widgets.
   *
   * @return int
   *   The widget count.
   */
  public function total() {
    return (int) $this->database->select('legacy_widget', 'w')
      ->countQuery()
      ->execute()
      ->fetchField();
  }

  /**
   * Classifies a count against the configured threshold.
   *
   * @param int $count
   *   The count.
   *
   * @return string
   *   One of 'empty', 'low' or 'high'.
   */
  public function bucket(int $count): string {
    if ($count <= 0) {
      return 'empty';
    }
    $threshold = (int) $this->configFactory->get('legacy_widgets.settings')->get('threshold');
    return $count < $threshold ? 'low' : 'high';
  }

}
