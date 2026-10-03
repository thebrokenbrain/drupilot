<?php

namespace Drupal\acme_core\Form;

use Drupal\Core\Form\ConfigFormBase;
use Drupal\Core\Form\FormStateInterface;

/**
 * Acme core settings.
 */
class SettingsForm extends ConfigFormBase {

  /**
   * {@inheritdoc}
   */
  public function getFormId() {
    return 'acme_core_settings';
  }

  /**
   * {@inheritdoc}
   */
  protected function getEditableConfigNames() {
    return ['acme_core.settings'];
  }

  /**
   * {@inheritdoc}
   */
  public function buildForm(array $form, FormStateInterface $form_state) {
    $form['banner_text'] = [
      '#type' => 'textfield',
      '#title' => $this->t('Banner text'),
      '#default_value' => $this->config('acme_core.settings')->get('banner_text'),
    ];
    return parent::buildForm($form, $form_state);
  }

}
