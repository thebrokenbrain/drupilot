<?php

declare(strict_types=1);

namespace Drupal\d11_for_d12\Plugin\Validation\Constraint;

use Drupal\Core\StringTranslation\TranslatableMarkup;
use Drupal\Core\Validation\Attribute\Constraint;
use Symfony\Component\Validator\Constraint as SymfonyConstraint;

/**
 * A title must hold no markup.
 */
#[Constraint(
  id: 'D11ForD12PlainTitle',
  label: new TranslatableMarkup('Plain title', [], ['context' => 'Validation'])
)]
class PlainTitleConstraint extends SymfonyConstraint {

  /**
   * The violation message.
   */
  public string $message = 'The title %value must hold no markup.';

}
