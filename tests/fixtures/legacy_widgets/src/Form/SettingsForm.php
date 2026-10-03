<?php

namespace Drupal\legacy_widgets\Form;

use Drupal\Core\Config\ConfigFactoryInterface;
use Drupal\Core\Form\ConfigFormBase;
use Drupal\Core\Form\FormStateInterface;
use Drupal\Core\State\StateInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Configures the Legacy widgets module.
 */
class SettingsForm extends ConfigFormBase {

  /**
   * The state service.
   *
   * @var \Drupal\Core\State\StateInterface
   */
  protected $state;

  /**
   * Constructs a SettingsForm.
   *
   * @param \Drupal\Core\Config\ConfigFactoryInterface $config_factory
   *   The config factory.
   * @param \Drupal\Core\State\StateInterface $state
   *   The state service.
   */
  public function __construct(ConfigFactoryInterface $config_factory, StateInterface $state) {
    parent::__construct($config_factory);
    $this->state = $state;
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static(
      $container->get('config.factory'),
      $container->get('state')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function getFormId() {
    return 'legacy_widgets_settings';
  }

  /**
   * {@inheritdoc}
   */
  protected function getEditableConfigNames() {
    return ['legacy_widgets.settings'];
  }

  /**
   * {@inheritdoc}
   */
  public function buildForm(array $form, FormStateInterface $form_state) {
    $config = $this->config('legacy_widgets.settings');

    $form['enabled'] = [
      '#type' => 'checkbox',
      '#title' => $this->t('Enable legacy widgets'),
      '#default_value' => $config->get('enabled'),
    ];

    $form['mode'] = [
      '#type' => 'select',
      '#title' => $this->t('Mode'),
      '#options' => [
        'basic' => $this->t('Basic'),
        'advanced' => $this->t('Advanced'),
      ],
      '#default_value' => $config->get('mode'),
      '#ajax' => [
        'callback' => [$this, 'ajaxRefreshMode'],
        'wrapper' => 'legacy-widgets-mode-details',
      ],
    ];

    $mode = $form_state->getValue('mode', $config->get('mode'));
    $form['mode_details'] = [
      '#type' => 'container',
      '#attributes' => ['id' => 'legacy-widgets-mode-details'],
      'help' => [
        '#markup' => $mode === 'advanced'
          ? $this->t('Advanced mode reindexes every widget on cron.')
          : $this->t('Basic mode only reindexes changed widgets.'),
      ],
    ];

    $form['threshold'] = [
      '#type' => 'textfield',
      '#title' => $this->t('High-count threshold'),
      '#default_value' => $config->get('threshold'),
      '#element_validate' => [[$this, 'validateThreshold']],
      '#process' => [[static::class, 'processThreshold']],
    ];

    $form['intro'] = [
      '#type' => 'textarea',
      '#title' => $this->t('Block introduction'),
      '#default_value' => $config->get('intro'),
    ];

    $form['contact_mail'] = [
      '#type' => 'email',
      '#title' => $this->t('Contact e-mail'),
      '#default_value' => $config->get('contact_mail'),
    ];

    $form = parent::buildForm($form, $form_state);

    $form['actions']['reset'] = [
      '#type' => 'submit',
      '#value' => $this->t('Reset counters'),
      '#submit' => [[$this, 'resetCounters']],
      '#limit_validation_errors' => [],
    ];

    $form['#validate'] = ['::validateForm', [$this, 'validateIntro']];

    return $form;
  }

  /**
   * Ajax callback: returns the mode details container.
   */
  public function ajaxRefreshMode(array &$form, FormStateInterface $form_state) {
    return $form['mode_details'];
  }

  /**
   * Element validate callback for the threshold.
   */
  public function validateThreshold(array &$element, FormStateInterface $form_state, array &$complete_form) {
    if (!is_numeric($element['#value']) || (int) $element['#value'] < 1) {
      $form_state->setError($element, $this->t('The threshold must be a positive integer.'));
    }
  }

  /**
   * Process callback for the threshold element.
   */
  public static function processThreshold(array $element, FormStateInterface $form_state, array &$complete_form) {
    $element['#description'] = t('Counts at or above this value are reported as high.');
    return $element;
  }

  /**
   * Form-level validate callback for the introduction.
   */
  public function validateIntro(array &$form, FormStateInterface $form_state) {
    if (mb_strlen((string) $form_state->getValue('intro')) > 2000) {
      $form_state->setErrorByName('intro', $this->t('The introduction is too long.'));
    }
  }

  /**
   * Submit callback for the reset button.
   */
  public function resetCounters(array &$form, FormStateInterface $form_state) {
    $this->state->delete('legacy_widgets.last_reindex');
    $this->messenger()->addStatus($this->t('Counters reset.'));
  }

  /**
   * {@inheritdoc}
   */
  public function submitForm(array &$form, FormStateInterface $form_state) {
    $this->config('legacy_widgets.settings')
      ->set('enabled', (bool) $form_state->getValue('enabled'))
      ->set('mode', $form_state->getValue('mode'))
      ->set('threshold', (int) $form_state->getValue('threshold'))
      ->set('intro', $form_state->getValue('intro'))
      ->set('contact_mail', $form_state->getValue('contact_mail'))
      ->save();
    parent::submitForm($form, $form_state);
  }

}
