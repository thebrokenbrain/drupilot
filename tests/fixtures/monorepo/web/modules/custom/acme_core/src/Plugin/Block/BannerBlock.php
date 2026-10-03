<?php

namespace Drupal\acme_core\Plugin\Block;

use Drupal\Core\Block\Attribute\Block;
use Drupal\Core\Block\BlockBase;
use Drupal\Core\StringTranslation\TranslatableMarkup;

/**
 * Shows the Acme banner.
 */
#[Block(
  id: 'acme_core_banner',
  admin_label: new TranslatableMarkup('Acme banner'),
)]
class BannerBlock extends BlockBase {

  /**
   * {@inheritdoc}
   */
  public function build() {
    return [
      '#markup' => $this->t('Acme'),
      '#attached' => ['library' => ['acme_core/base']],
    ];
  }

}
