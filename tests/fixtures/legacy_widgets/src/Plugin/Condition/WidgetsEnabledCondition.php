<?php

namespace Drupal\legacy_widgets\Plugin\Condition;

use Drupal\Core\Condition\ConditionPluginBase;
use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Form\FormStateInterface;
use Drupal\Core\Plugin\ContainerFactoryPluginInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Passes when legacy widgets are enabled.
 *
 * @Condition(
 *   id = "legacy_widgets_enabled",
 *   label = @Translation("Legacy widgets enabled")
 * )
 */
class WidgetsEnabledCondition extends ConditionPluginBase implements ContainerFactoryPluginInterface {

  /**
   * The config factory.
   *
   * @var \Drupal\Core\Config\ConfigFactoryInterface
   */
  protected $configFactory;

  /**
   * Constructs a WidgetsEnabledCondition.
   */
  public function __construct(array $configuration, $plugin_id, $plugin_definition, ConfigFactoryInterface $config_factory) {
    parent::__construct($configuration, $plugin_id, $plugin_definition);
    $this->configFactory = $config_factory;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container, array $configuration, $plugin_id, $plugin_definition) {
    return new static(
      $configuration,
      $plugin_id,
      $plugin_definition,
      $container->get('config.factory')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function defaultConfiguration() {
    return ['require_enabled' => FALSE] + parent::defaultConfiguration();
  }

  /**
   * {@inheritdoc}
   */
  public function buildConfigurationForm(array $form, FormStateInterface $form_state) {
    $form['require_enabled'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Only when legacy widgets are enabled'),
      '#default_value' => $this->configuration['require_enabled'],
    ];
    return parent::buildConfigurationForm($form, $form_state);
  }

  /**
   * {@inheritdoc}
   */
  public function submitConfigurationForm(array &$form, FormStateInterface $form_state) {
    $this->configuration['require_enabled'] = (bool) $form_state->getValue('require_enabled');
    parent::submitConfigurationForm($form, $form_state);
  }

  /**
   * {@inheritdoc}
   */
  public function evaluate() {
    if (empty($this->configuration['require_enabled'])) {
      return TRUE;
    }
    return (bool) $this->configFactory->get('legacy_widgets.settings')->get('enabled');
  }

  /**
   * {@inheritdoc}
   */
  public function summary() {
    return $this->t('Legacy widgets enabled');
  }

}
