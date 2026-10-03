<?php

namespace Drupal\Tests\legacy_widgets\Unit;

use Drupal\Core\Database\Connection;
use Drupal\legacy_widgets\WidgetCounter;
use Drupal\Tests\UnitTestCase;

/**
 * @coversDefaultClass \Drupal\legacy_widgets\WidgetCounter
 * @group legacy_widgets
 */
class WidgetCounterTest extends UnitTestCase {

  /**
   * @covers ::bucket
   * @dataProvider providerBucket
   */
  public function testBucket(int $count, string $expected): void {
    $config_factory = $this->getConfigFactoryStub([
      'legacy_widgets.settings' => ['threshold' => 10],
    ]);
    $counter = new WidgetCounter($this->createMock(Connection::class), $config_factory);
    $this->assertSame($expected, $counter->bucket($count));
  }

  /**
   * Data provider for testBucket().
   */
  public static function providerBucket(): array {
    return [
      'zero' => [0, 'empty'],
      'below threshold' => [5, 'low'],
      'at threshold' => [10, 'high'],
      'above threshold' => [50, 'high'],
    ];
  }

}
