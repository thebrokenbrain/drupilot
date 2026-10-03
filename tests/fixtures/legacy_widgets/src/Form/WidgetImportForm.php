<?php

namespace Drupal\legacy_widgets\Form;

use Drupal\Core\Entity\EntityTypeManagerInterface;
use Drupal\Core\Form\FormBase;
use Drupal\Core\Form\FormStateInterface;
use Drupal\Core\Logger\LoggerChannelFactoryInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * Imports widgets from a list of labels.
 */
class WidgetImportForm extends FormBase {

  /**
   * Constructs a WidgetImportForm.
   */
  public function __construct(
    private readonly EntityTypeManagerInterface $entityTypeManager,
    private readonly LoggerChannelFactoryInterface $loggerFactory,
  ) {}

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container) {
    return new static(
      $container->get('entity_type.manager'),
      $container->get('logger.factory')
    );
  }

  /**
   * {@inheritdoc}
   */
  public function getFormId() {
    return 'legacy_widgets_import';
  }

  /**
   * {@inheritdoc}
   */
  public function buildForm(array $form, FormStateInterface $form_state) {
    $form['labels'] = [
      '#type' => 'textarea',
      '#title' => $this->t('Labels'),
      '#description' => $this->t('One widget label per line.'),
      '#required' => TRUE,
    ];
    $form['actions'] = ['#type' => 'actions'];
    $form['actions']['submit'] = [
      '#type' => 'submit',
      '#value' => $this->t('Import'),
    ];
    return $form;
  }

  /**
   * {@inheritdoc}
   */
  public function submitForm(array &$form, FormStateInterface $form_state) {
    $storage = $this->entityTypeManager->getStorage('legacy_widget');
    $labels = array_filter(array_map('trim', explode("\n", trim($form_state->getValue('labels')))));
    foreach ($labels as $label) {
      $storage->create(['label' => $label])->save();
    }
    $this->loggerFactory->get('legacy_widgets')->info('Imported @count widgets.', ['@count' => count($labels)]);
    $this->messenger()->addStatus($this->t('Imported @count widgets.', ['@count' => count($labels)]));
  }

}
