<?php

namespace Drupal\acme_invoice;

use Drupal\acme_core\AcmeFormatter;

/**
 * Generates invoices.
 */
class InvoiceGenerator {

  /**
   * Constructs an InvoiceGenerator.
   */
  public function __construct(protected AcmeFormatter $formatter) {}

  /**
   * Generates an invoice number for an account.
   */
  public function generate(string $account): string {
    return $this->formatter->format($account);
  }

  /**
   * Returns the billing manager (the reason for the cycle).
   */
  public static function billing(): \Drupal\acme_billing\BillingManager {
    return \Drupal::service('acme_billing.manager');
  }

}
