<?php

namespace Drupal\acme_api\Client;

use Drupal\acme_utils\Helper;
use GuzzleHttp\ClientInterface;

/**
 * Talks to the Acme remote API.
 */
class ApiClient {

  /**
   * Constructs an ApiClient.
   *
   * @param \GuzzleHttp\ClientInterface $httpClient
   *   The HTTP client.
   * @param \Drupal\acme_utils\Helper $helper
   *   The Acme helper.
   */
  public function __construct(
    protected ClientInterface $httpClient,
    protected Helper $helper,
  ) {}

  /**
   * Fetches a remote item.
   */
  public function fetch(string $id): array {
    $response = $this->httpClient->request('GET', 'https://api.example.com/items/' . $this->helper->slug($id));
    return json_decode((string) $response->getBody(), TRUE) ?: [];
  }

}
