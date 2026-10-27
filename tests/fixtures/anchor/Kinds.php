<?php

namespace Drupal\anchor_fx;

interface Counter {

  public function count(): int;

}

trait Logs {

  public function log(string $m): void {
    echo $m;
  }

}

enum Suit: string {

  case Hearts = 'H';

  public function label(): string {
    return match ($this) {
      Suit::Hearts => 'Hearts',
    };
  }

}

abstract class Base {

  abstract protected function run();

  public function go() {
    $this->run();
  }

}
