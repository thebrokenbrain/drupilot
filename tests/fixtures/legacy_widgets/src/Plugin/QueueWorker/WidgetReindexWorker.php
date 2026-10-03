<?php

namespace Drupal\legacy_widgets\Plugin\QueueWorker;

use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Plugin\ContainerFactoryPluginInterface;
use Drupal\Core\Queue\QueueWorkerBase;
use Drupal\legacy_widgets\WidgetCounter;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Reindexes legacy widgets.
 *
 * @QueueWorker(
 *   id = "legacy_widgets_reindex",
 *   title = @Translation("Legacy widgets reindex"),
 *   cron = {"time" = 30}
 * )
 */
class WidgetReindexWorker extends QueueWorkerBase implements ContainerFactoryPluginInterface {

  /**
   * The entity type manager.
   *
   * @var \Drupal\Core\Entity\EntityTypeManagerInterface
   */
  protected $entityTypeManager;

  /**
   * The widget counter.
   *
   * @var \Drupal\legacy_widgets\WidgetCounter
   */
  protected $counter;

  /**
   * Constructs a WidgetReindexWorker.
   */
  public function __construct(array $configuration, $plugin_id, $plugin_definition, EntityTypeManagerInterface $entity_type_manager, WidgetCounter $counter) {
    parent::__construct($configuration, $plugin_id, $plugin_definition);
    $this->entityTypeManager = $entity_type_manager;
    $this->counter = $counter;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container, array $configuration, $plugin_id, $plugin_definition) {
    return new static(
      $configuration,
      $plugin_id,
      $plugin_definition,
      $container->get('entity_type.manager'),
      $container->get('legacy_widgets.counter')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function processItem($data) {
    $storage = \Drupal::entityTypeManager()->getStorage('legacy_widget');
    $widget = $storage->load($data['id']);
    if (!$widget) {
      return;
    }
    $owner = user_load_by_name($data['owner'] ?? '');
    $widget->set('owner_label', $owner ? $owner->getAccountName() : 'anonymous');
    $widget->incrementHits();
    $widget->save();
  }

}
