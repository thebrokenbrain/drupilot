<?php

namespace Drupal\legacy_widgets;

use Drupal\Core\Entity\EntityTypeManagerInterface;

/**
 * Looks up widget owners.
 */
class WidgetLookup {

  /**
   * The entity type manager.
   *
   * @var \Drupal\Core\Entity\EntityTypeManagerInterface
   */
  protected $entityTypeManager;

  /**
   * Constructs a WidgetLookup.
   *
   * @param \Drupal\Core\Entity\EntityTypeManagerInterface $entity_type_manager
   *   The entity type manager.
   */
  public function __construct(EntityTypeManagerInterface $entity_type_manager) {
    $this->entityTypeManager = $entity_type_manager;
  }

  /**
   * Finds the owner account for an e-mail address.
   *
   * @param string $mail
   *   The e-mail address.
   *
   * @return \Drupal\user\UserInterface|false
   *   The account or FALSE.
   */
  public function findOwnerByMail($mail) {
    return user_load_by_mail($mail);
  }

}
