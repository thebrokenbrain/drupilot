<?php

namespace Drupal\legacy_widgets\Entity;

use Drupal\Core\Entity\ContentEntityBase;
use Drupal\Core\Entity\EntityTypeInterface;
use Drupal\Core\Field\BaseFieldDefinition;

/**
 * Defines the legacy widget entity.
 *
 * @ContentEntityType(
 *   id = "legacy_widget",
 *   label = @Translation("Legacy widget"),
 *   base_table = "legacy_widget",
 *   handlers = {
 *     "storage" = "Drupal\legacy_widgets\LegacyWidgetStorage",
 *   },
 *   admin_permission = "administer legacy widgets",
 *   entity_keys = {
 *     "id" = "id",
 *     "uuid" = "uuid",
 *     "label" = "label",
 *   },
 * )
 */
class LegacyWidget extends ContentEntityBase {

  /**
   * {@inheritdoc}
   */
  public static function baseFieldDefinitions(EntityTypeInterface $entity_type) {
    $fields = parent::baseFieldDefinitions($entity_type);
    $fields['label'] = BaseFieldDefinition::create('string')
      ->setLabel(t('Label'))
      ->setRequired(TRUE)
      ->setSetting('max_length', 255);
    $fields['owner_label'] = BaseFieldDefinition::create('string')
      ->setLabel(t('Owner label'))
      ->setSetting('max_length', 255);
    $fields['hits'] = BaseFieldDefinition::create('integer')
      ->setLabel(t('Hits'))
      ->setDefaultValue(0);
    $fields['summary_source'] = BaseFieldDefinition::create('string_long')
      ->setLabel(t('Summary source'));
    return $fields;
  }

  /**
   * Returns the unchanged copy of the widget during a save, if any.
   *
   * Drupal 11.2+ declares EntityInterface::getOriginal(): ?static.
   *
   * @return \Drupal\legacy_widgets\Entity\LegacyWidget|null
   *   The original widget, or NULL.
   */
  public function getOriginal() {
    return $this->original ?? NULL;
  }

  /**
   * Increments the hit counter.
   *
   * @return $this
   */
  public function incrementHits() {
    $this->set('hits', (int) $this->get('hits')->value + 1);
    return $this;
  }

}
