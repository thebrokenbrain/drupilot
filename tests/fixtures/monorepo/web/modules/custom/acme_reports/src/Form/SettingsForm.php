<?php

namespace Drupal\acme_reports\Form;

use Drupal\Core\Form\ConfigFormBase;
use Drupal\Core\Form\FormStateInterface;

/**
 * Acme reports settings.
 */
class SettingsForm extends ConfigFormBase {

  /**
   * {@inheritdoc}
   */
  public function getFormId() {
    return 'acme_reports_settings';
  }

  /**
   * {@inheritdoc}
   */
  protected function getEditableConfigNames() {
    return ['acme_reports.settings'];
  }

  /**
   * {@inheritdoc}
   */
  public function buildForm(array $form, FormStateInterface $form_state) {
    $form['rows_per_page'] = [
      '#type' => 'number',
      '#title' => $this->t('Rows per page'),
      '#default_value' => $this->config('acme_reports.settings')->get('rows_per_page'),
    ];
    return parent::buildForm($form, $form_state);
  }

}
