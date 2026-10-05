<?php

namespace Drupal\anchor_fx\Routing;

final class Router {

  public const NAMESPACE = 'ns';

  public function match(string $path): array {
    $kind = self::NAMESPACE;
    $helper = new readonly class ($path) {
      public function __construct(public string $p) {}
      public function get(): string {
        return $this->p;
      }
    };
    $other = new #[\AllowDynamicProperties] class (match ($kind) { 'ns' => 1, default => 2 }) {
      public function __construct(public int $n) {}
      public function value(): int {
        return $this->n;
      }
    };
    return [$helper->get(), $other->value()];
  }

  public function list(): array {
    return [];
  }

}

class After {

  public function run() {}

}
