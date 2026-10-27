<?php

declare(strict_types=1);

namespace Drupal\d11_for_d12\Plugin\Validation\Constraint;

use Symfony\Component\Validator\Constraint;
use Symfony\Component\Validator\ConstraintValidator;

/**
 * Validates the D11ForD12PlainTitle constraint.
 */
class PlainTitleConstraintValidator extends ConstraintValidator {

  /**
   * {@inheritdoc}
   */
  public function validate($value, Constraint $constraint) {
    $items = is_iterable($value) ? $value : [$value];
    foreach ($items as $item) {
      $text = is_object($item) && isset($item->value) ? (string) $item->value : (string) $item;
      if ($text !== strip_tags($text)) {
        $this->context->addViolation($constraint->message, ['%value' => $text]);
      }
    }
  }

}
