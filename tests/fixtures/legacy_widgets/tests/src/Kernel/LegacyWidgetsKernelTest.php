<?php

namespace Drupal\Tests\legacy_widgets\Kernel;

use Drupal\KernelTests\KernelTestBase;
use Drupal\legacy_widgets\Entity\LegacyWidget;
use Drupal\Tests\user\Traits\UserCreationTrait;

/**
 * Exercises the plugins, services and hooks of legacy_widgets.
 *
 * @group legacy_widgets
 */
class LegacyWidgetsKernelTest extends KernelTestBase {

  use UserCreationTrait;

  /**
   * {@inheritdoc}
   */
  protected static $modules = ['system', 'user', 'filter', 'text', 'legacy_widgets'];

  /**
   * {@inheritdoc}
   */
  protected function setUp(): void {
    parent::setUp();
    $this->installEntitySchema('user');
    $this->installEntitySchema('legacy_widget');
    $this->installConfig(['filter', 'text']);
  }

  /**
   * The queue worker is built through create() and processes an item.
   */
  public function testQueueWorkerProcessesItem(): void {
    $this->createUser([], 'widget_owner');
    $widget = LegacyWidget::create(['label' => 'Alpha']);
    $widget->save();

    $worker = $this->container->get('plugin.manager.queue_worker')->createInstance('legacy_widgets_reindex');
    $worker->processItem(['id' => $widget->id(), 'owner' => 'widget_owner']);

    $reloaded = $this->container->get('entity_type.manager')->getStorage('legacy_widget')->loadUnchanged($widget->id());
    $this->assertSame('widget_owner', $reloaded->get('owner_label')->value);
    $this->assertSame(1, (int) $reloaded->get('hits')->value);
  }

  /**
   * The filter is built through create() and summarizes text.
   */
  public function testFilterProducesSummary(): void {
    $filter = $this->container->get('plugin.manager.filter')->createInstance('legacy_widgets_summary', [
      'settings' => ['summary_length' => 25],
    ]);
    $result = (string) $filter->process('First sentence here. Second sentence follows and is long.', 'en');
    $this->assertSame('First sentence here.', $result);
  }

  /**
   * The hook is callable with the single argument Drupal 10 passes.
   */
  public function testEntityOperationWithDrupal10Arguments(): void {
    $this->setUpCurrentUser([], [], TRUE);
    $widget = LegacyWidget::create(['label' => 'Beta']);
    $widget->save();

    $operations = legacy_widgets_entity_operation($widget);
    $this->assertArrayHasKey('legacy_widgets_reindex', $operations);
  }

  /**
   * The counter service is resolvable and counts stored widgets.
   */
  public function testCounterService(): void {
    LegacyWidget::create(['label' => 'One'])->save();
    LegacyWidget::create(['label' => 'Two'])->save();
    $counter = $this->container->get('legacy_widgets.counter');
    $this->assertSame(2, $counter->total());
  }

  /**
   * The account helper resolves by name and by e-mail.
   */
  public function testFindAccount(): void {
    $account = $this->createUser([], 'finder');
    $account->setEmail('finder@example.com')->save();
    $this->assertSame((int) $account->id(), (int) legacy_widgets_find_account('finder')->id());
    $this->assertSame((int) $account->id(), (int) legacy_widgets_find_account('finder@example.com')->id());
  }

}
