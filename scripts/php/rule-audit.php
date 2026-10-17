<?php

/**
 * @file
 * drupilot — scripts/php/rule-audit.php
 *
 * The Rector rule audit (AR-11, T-M5-03, ADR 0030): reflects the PHP sets of
 * the Rector installed in the Drupal root and lists every rule they register,
 * the facts the compat pass is built from:
 *
 *   - rule: the rule class;
 *   - sets: the SetList constants that register it (PHP_53 ... PHP_86, and
 *     PHP_POLYFILLS);
 *   - min_php: its provideMinPhpVersion() as X.Y (the PHP version Rector's
 *     PhpVersionedFilter needs before it runs the rule), null when the rule
 *     is not version-bound;
 *   - polyfill: its providePolyfillPackage() (the symfony/polyfill-phpXY
 *     package that lets it run below min_php), null when none;
 *   - interfaces: the Rector interfaces it implements.
 *
 * Each set config is imported into its own RectorConfig, as Rector does, and
 * read back from the rules it registered; no rule is run, and a rule is never
 * constructed (min_php and polyfill are read from an instance made without
 * its constructor: both methods return a constant).
 *
 * Staged into the Drupal root by stage_runtime (scripts/lib/cache.sh) and run
 * there by scripts/analysis/rector-rule-audit.sh:
 *
 *   $(drupal_runner) php .drupilot/runtime/rule-audit.php
 *
 * STDOUT: {"rector_version": V, "rules": [...]} (sorted by rule; the same
 * bytes for the same Rector). Exit codes: 0 ok, 2 no Rector in
 * vendor/autoload.php, or a set that cannot be read.
 */

declare(strict_types=1);

$autoload = getcwd() . '/vendor/autoload.php';
if (!is_file($autoload)) {
  fwrite(STDERR, "rule-audit: no vendor/autoload.php in " . getcwd() . "\n");
  exit(2);
}
require $autoload;

$config = 'Rector\\Config\\RectorConfig';
$setList = 'Rector\\Set\\ValueObject\\SetList';
if (!class_exists($config) || !class_exists($setList)) {
  fwrite(STDERR, "rule-audit: rector/rector is not installed\n");
  exit(2);
}

/**
 * A PhpVersion integer (80400) as X.Y; null for anything else.
 */
function drupilot_php_minor($id): ?string {
  if (!is_int($id) || $id < 50000) {
    return NULL;
  }
  return intdiv($id, 10000) . '.' . intdiv($id % 10000, 100);
}

$sets = [];
foreach ((new ReflectionClass($setList))->getConstants() as $name => $file) {
  if (is_string($file) && (preg_match('/^PHP_\d\d$/', $name) || $name === 'PHP_POLYFILLS')) {
    $sets[$name] = $file;
  }
}
ksort($sets);

$registered = new ReflectionProperty($config, 'registeredRectorClasses');
$registered->setAccessible(TRUE);
$rules = [];
foreach ($sets as $name => $file) {
  try {
    $rectorConfig = new $config();
    $rectorConfig->import($file);
  }
  catch (Throwable $e) {
    fwrite(STDERR, "rule-audit: set $name: " . $e->getMessage() . "\n");
    exit(2);
  }
  foreach (array_keys($registered->getValue($rectorConfig)) as $rule) {
    $rules[$rule]['sets'][] = $name;
  }
}

$out = [];
foreach ($rules as $rule => $row) {
  $class = new ReflectionClass($rule);
  $min = NULL;
  $polyfill = NULL;
  if (!$class->isAbstract()) {
    $instance = $class->newInstanceWithoutConstructor();
    if (method_exists($instance, 'provideMinPhpVersion')) {
      $min = drupilot_php_minor($instance->provideMinPhpVersion());
    }
    if (method_exists($instance, 'providePolyfillPackage')) {
      $polyfill = (string) $instance->providePolyfillPackage();
    }
  }
  $interfaces = array_values(array_filter($class->getInterfaceNames(), static fn (string $i): bool => strncmp($i, 'Rector\\', 7) === 0));
  sort($interfaces);
  sort($row['sets']);
  $out[] = [
    'rule' => $rule,
    'sets' => $row['sets'],
    'min_php' => $min,
    'polyfill' => $polyfill,
    'interfaces' => $interfaces,
  ];
}
usort($out, static fn (array $a, array $b): int => strcmp($a['rule'], $b['rule']));

$version = defined('Rector\\Application\\VersionResolver::PACKAGE_VERSION')
  ? constant('Rector\\Application\\VersionResolver::PACKAGE_VERSION') : NULL;
echo json_encode(['rector_version' => $version, 'rules' => $out], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), "\n";
exit(0);
