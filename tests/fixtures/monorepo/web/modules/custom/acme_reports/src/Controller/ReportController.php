<?php

namespace Drupal\acme_reports\Controller;

use Drupal\acme_api\Client\ApiClient;
use Drupal\Core\Controller\ControllerBase;
use Drupal\Core\Url;

/**
 * Renders the Acme reports overview.
 */
class ReportController extends ControllerBase {

  /**
   * Renders the overview.
   */
  public function overview() {
    /** @var \Drupal\acme_api\Client\ApiClient $client */
    $client = \Drupal::service('acme_api.client');
    $build['remote'] = ['#markup' => count($client->fetch('summary'))];
    $build['settings'] = [
      '#type' => 'link',
      '#title' => $this->t('Core settings'),
      '#url' => Url::fromRoute('acme_core.settings'),
    ];
    $build['banner'] = \Drupal::service('plugin.manager.block')
      ->createInstance('acme_core_banner')
      ->build();
    // Optional integration: guarded, so it is not a hard dependency.
    if (\Drupal::moduleHandler()->moduleExists('acme_search')) {
      $build['search'] = ['#markup' => get_class(\Drupal::service('acme_search.indexer'))];
    }
    return $build;
  }

  /**
   * Returns the API client class (keeps the import used).
   */
  public static function clientClass(): string {
    return ApiClient::class;
  }

}
