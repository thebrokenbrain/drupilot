<?php

namespace Drupal\acme_core;

use Drupal\Core\Config\ConfigFactoryInterface;

/**
 * Formats Acme strings.
 */
class AcmeFormatter {

  /**
   * Constructs an AcmeFormatter.
   *
   * @param \Drupal\Core\Config\ConfigFactoryInterface $config_factory
   *   The config factory.
   * @param string $prefix
   *   An optional prefix.
   */
  public function __construct(
    protected ConfigFactoryInterface $configFactory,
    protected string $prefix = '',
  ) {}

  /**
   * Formats a label.
   */
  public function format(string $label): string {
    return $this->prefix . $this->configFactory->get('acme_core.settings')->get('banner_text') . ': ' . $label;
  }

}
