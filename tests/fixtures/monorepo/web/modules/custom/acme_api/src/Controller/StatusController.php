<?php

namespace Drupal\acme_api\Controller;

use Drupal\acme_core\AcmeFormatter;
use Drupal\Core\Controller\ControllerBase;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Shows the API status.
 */
class StatusController extends ControllerBase {

  /**
   * Constructs a StatusController.
   */
  public function __construct(protected AcmeFormatter $formatter) {}

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static($container->get('acme_core.formatter'));
  }

  /**
   * Renders the status page.
   */
  public function status() {
    return ['#markup' => $this->formatter->format((string) \Drupal::token()->replace('[site:name]'))];
  }

}
