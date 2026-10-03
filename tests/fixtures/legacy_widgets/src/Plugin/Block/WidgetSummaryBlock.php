<?php

namespace Drupal\legacy_widgets\Plugin\Block;

use Drupal\Core\Block\BlockBase;
use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Plugin\ContainerFactoryPluginInterface;
use Drupal\legacy_widgets\WidgetCounter;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Shows a summary of legacy widgets.
 *
 * @Block(
 *   id = "legacy_widgets_summary",
 *   admin_label = @Translation("Legacy widgets summary"),
 *   category = @Translation("Legacy widgets")
 * )
 */
class WidgetSummaryBlock extends BlockBase implements ContainerFactoryPluginInterface {

  /**
   * The config factory.
   *
   * @var \Drupal\Core\Config\ConfigFactoryInterface
   */
  protected $configFactory;

  /**
   * The widget counter.
   *
   * @var \Drupal\legacy_widgets\WidgetCounter
   */
  protected $counter;

  /**
   * Constructs a WidgetSummaryBlock.
   */
  public function __construct(array $configuration, $plugin_id, $plugin_definition, ConfigFactoryInterface $config_factory, WidgetCounter $counter) {
    parent::__construct($configuration, $plugin_id, $plugin_definition);
    $this->configFactory = $config_factory;
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
      $container->get('config.factory'),
      $container->get('legacy_widgets.counter')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function build() {
    $config = $this->configFactory->get('legacy_widgets.settings');
    $intro = check_markup($config->get('intro') ?? '', $config->get('intro_format') ?? 'plain_text');
    $contact = user_load_by_mail($config->get('contact_mail') ?? '');
    $total = $this->counter->total();

    $build['intro'] = ['#markup' => $intro];
    $build['count'] = [
      '#markup' => $this->t('@count widgets (@bucket).', [
        '@count' => $total,
        '@bucket' => $this->counter->bucket($total),
      ]),
    ];
    if ($contact) {
      $build['contact'] = [
        '#markup' => $this->t('Contact: @name', ['@name' => $contact->getDisplayName()]),
      ];
    }
    $build['#cache']['tags'] = ['config:legacy_widgets.settings', 'legacy_widget_list'];
    return $build;
  }

}
