<?php

namespace Drupal\anchor_fx\Form;

use Drupal\Core\Form\FormBase;
use function array_map;

/**
 * A form.
 */
#[\Attribute]
final class Widgets extends FormBase {

  protected array $labels = [];

  /**
   * Builds.
   */
  public function buildForm(array $form, $form_state) {
    $form['#validate'][] = function ($form, $state) {
      return $state;
    };
    $trimmed = array_map(fn ($x) => trim($x), $this->labels);
    $helper = new class($trimmed) extends \ArrayObject {
      public function first() {
        return $this[0] ?? NULL;
      }
    };
    $name = Widgets::class;
    $text = <<<EOT
      Hello {$name}
      EOT;
    return $form;
  }

  #[Override]
  public static function &create($container): static {
    return new static();
  }

}
