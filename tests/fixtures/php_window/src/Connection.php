<?php

namespace Drupal\php_window;

/**
 * Builds the options of a MySQL connection.
 */
class Connection {

  /**
   * The PDO options (the PDO::MYSQL_ATTR_* constants are deprecated in 8.5).
   */
  public function options(): array {
    return [\PDO::MYSQL_ATTR_INIT_COMMAND => 'SET NAMES utf8mb4'];
  }

  /**
   * Labels the connection (an implicitly nullable parameter: deprecated in 8.4).
   */
  public function label(string $prefix = NULL): string {
    return ($prefix ?? 'db') . ':mysql';
  }

}
