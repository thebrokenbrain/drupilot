<?php

namespace Drupal\legacy_widgets\Controller;

use Drupal\Core\Controller\ControllerBase;
use Drupal\legacy_widgets\WidgetCounter;
use Symfony\Component\DependencyInjection\ContainerInterface;
use Symfony\Component\HttpFoundation\JsonResponse;

/**
 * Exposes widget status as JSON.
 */
class WidgetStatusController extends ControllerBase {

  /**
   * The widget counter.
   *
   * @var \Drupal\legacy_widgets\WidgetCounter
   */
  protected $counter;

  /**
   * Constructs a WidgetStatusController.
   *
   * @param \Drupal\legacy_widgets\WidgetCounter $counter
   *   The widget counter.
   */
  public function __construct(WidgetCounter $counter) {
    $this->counter = $counter;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static($container->get('legacy_widgets.counter'));
  }

  /**
   * Returns the widget status.
   *
   * @return \Symfony\Component\HttpFoundation\JsonResponse
   *   The status response.
   */
  public function status() {
    $total = $this->counter->total();
    return new JsonResponse([
      'total' => $total,
      'bucket' => $this->counter->bucket($total),
    ]);
  }

}
