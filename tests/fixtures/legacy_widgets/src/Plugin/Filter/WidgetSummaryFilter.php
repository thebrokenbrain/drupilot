<?php

namespace Drupal\legacy_widgets\Plugin\Filter;

use Drupal\Core\Logger\LoggerChannelFactoryInterface;
use Drupal\Core\Plugin\ContainerFactoryPluginInterface;
use Drupal\filter\FilterProcessResult;
use Drupal\filter\Plugin\FilterBase;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Replaces the text with its summary.
 *
 * @Filter(
 *   id = "legacy_widgets_summary",
 *   title = @Translation("Legacy widgets summary"),
 *   type = Drupal\filter\Plugin\FilterInterface::TYPE_TRANSFORM_REVERSIBLE,
 *   settings = {
 *     "summary_length" = 200,
 *   },
 * )
 */
class WidgetSummaryFilter extends FilterBase implements ContainerFactoryPluginInterface {

  /**
   * The logger channel factory.
   *
   * @var \Drupal\Core\Logger\LoggerChannelFactoryInterface
   */
  protected $loggerFactory;

  /**
   * Constructs a WidgetSummaryFilter.
   */
  public function __construct(array $configuration, $plugin_id, $plugin_definition, LoggerChannelFactoryInterface $logger_factory) {
    parent::__construct($configuration, $plugin_id, $plugin_definition);
    $this->loggerFactory = $logger_factory;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container, array $configuration, $plugin_id, $plugin_definition) {
    return new static(
      $configuration,
      $plugin_id,
      $plugin_definition,
      $container->get('logger.factory')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function process($text, $langcode) {
    if ($text === '') {
      $this->loggerFactory->get('legacy_widgets')->notice('Empty text passed to the summary filter.');
    }
    $summary = text_summary($text, NULL, (int) $this->settings['summary_length']);
    return new FilterProcessResult($summary);
  }

}
