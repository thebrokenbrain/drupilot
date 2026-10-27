<?php

declare(strict_types=1);

namespace Drupal\Tests\d11_for_d12\Unit;

use Drupal\Tests\UnitTestCase;
use Drupal\d11_for_d12\Plugin\Validation\Constraint\PlainTitleConstraint;
use Drupal\d11_for_d12\Plugin\Validation\Constraint\PlainTitleConstraintValidator;
use Symfony\Component\Validator\Context\ExecutionContextInterface;

/**
 * Tests the plain-title validator.
 *
 * @coversDefaultClass \Drupal\d11_for_d12\Plugin\Validation\Constraint\PlainTitleConstraintValidator
 * @group d11_for_d12
 */
class PlainTitleConstraintValidatorTest extends UnitTestCase {

  /**
   * Tests that markup in a title is a violation.
   *
   * @covers ::validate
   * @dataProvider providerValidate
   */
  public function testValidate(string $title, int $violations): void {
    $context = $this->createMock(ExecutionContextInterface::class);
    $context->expects($this->exactly($violations))->method('addViolation');
    $validator = new PlainTitleConstraintValidator();
    $validator->initialize($context);
    $validator->validate($title, new PlainTitleConstraint());
  }

  /**
   * Data provider for testValidate().
   */
  public static function providerValidate(): array {
    return [
      'plain' => ['A plain title', 0],
      'markup' => ['<b>Bold</b> title', 1],
    ];
  }

}
