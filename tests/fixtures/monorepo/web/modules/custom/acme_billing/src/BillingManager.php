<?php

namespace Drupal\acme_billing;

use Drupal\acme_invoice\InvoiceGenerator;

/**
 * Manages billing accounts.
 */
class BillingManager {

  /**
   * Constructs a BillingManager.
   */
  public function __construct(protected InvoiceGenerator $generator) {}

  /**
   * Bills an account.
   */
  public function bill(string $account): string {
    return $this->generator->generate($account);
  }

}
