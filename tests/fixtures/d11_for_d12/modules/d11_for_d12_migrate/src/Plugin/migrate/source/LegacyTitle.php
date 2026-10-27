<?php

declare(strict_types=1);

namespace Drupal\d11_for_d12_migrate\Plugin\migrate\source;

use Drupal\migrate_drupal\Plugin\migrate\source\DrupalSqlBase;

/**
 * Drupal 7 node titles (a stub).
 *
 * @MigrateSource(
 *   id = "d11_for_d12_legacy_title",
 *   source_module = "node"
 * )
 */
class LegacyTitle extends DrupalSqlBase {

  /**
   * {@inheritdoc}
   */
  public function query() {
    return $this->select('node', 'n')->fields('n', ['nid', 'title']);
  }

  /**
   * {@inheritdoc}
   */
  public function fields() {
    return ['nid' => $this->t('Node ID'), 'title' => $this->t('Title')];
  }

  /**
   * {@inheritdoc}
   */
  public function getIds() {
    return ['nid' => ['type' => 'integer']];
  }

}
