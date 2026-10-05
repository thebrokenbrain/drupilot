<?php

/**
 * @file
 * drupilot — scripts/php/anchor.php
 *
 * The anchor of a line of PHP code (05 §2.4, AR-23): the innermost named
 * scope that contains it, the part of a finding id that survives line shifts.
 *
 *   - a method: Namespace\ClassLike::method (classes, interfaces, traits,
 *     enums);
 *   - a function: Namespace\function (a .module's hooks and helpers);
 *   - inside a class-like but outside its methods: Namespace\ClassLike;
 *   - anywhere else: {file}.
 *
 * Closures, arrow functions and anonymous classes have no stable name: they
 * are transparent, so their lines take the anchor of the named scope around
 * them. A scope starts at the doc comment, attributes and modifiers right
 * before its keyword, and ends at its closing brace (or at the ";" of a
 * method without a body).
 *
 * Core PHP only (token_get_all; no dependency); PHP 8.1 or later (run on 8.1,
 * 8.3 and 8.5). Staged into
 * the Drupal root by stage_runtime (scripts/lib/cache.sh) and run in the bed:
 *
 *   $(drupal_runner) php .drupilot/runtime/anchor.php < requests.json
 *
 * STDIN: a JSON array of {"file": PATH, "line": N} (PATH relative to the
 * working directory). STDOUT: the same array, each entry with "anchor" added,
 * in the input order. A file that cannot be read, or a line out of any scope,
 * gets "{file}". Exit codes: 0 ok, 1 STDIN is not a JSON array.
 */

declare(strict_types=1);

/**
 * The anchored spans of one file: [[start_line, end_line, anchor], ...].
 */
function drupilot_anchor_spans(string $code): array {
  $tokens = token_get_all($code);
  $n = count($tokens);
  $classLike = [T_CLASS, T_INTERFACE, T_TRAIT];
  if (defined('T_ENUM')) {
    $classLike[] = T_ENUM;
  }
  $modifiers = [T_ABSTRACT, T_FINAL, T_PUBLIC, T_PROTECTED, T_PRIVATE, T_STATIC, T_VAR];
  if (defined('T_READONLY')) {
    $modifiers[] = T_READONLY;
  }
  $line = 1;
  $lines = [];
  // The line each token starts on.
  for ($i = 0; $i < $n; $i++) {
    $lines[$i] = $line;
    $text = is_array($tokens[$i]) ? $tokens[$i][1] : $tokens[$i];
    $line += substr_count($text, "\n");
  }
  $significant = function (int $i, int $step) use ($tokens, $n): int {
    for ($j = $i + $step; $j >= 0 && $j < $n; $j += $step) {
      $t = $tokens[$j];
      if (is_array($t) && in_array($t[0], [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT], TRUE)) {
        continue;
      }
      return $j;
    }
    return -1;
  };
  // The first line of a declaration: its doc comment, attributes and modifiers.
  $declStart = function (int $i) use ($tokens, $lines, $modifiers): int {
    $start = $lines[$i];
    for ($j = $i - 1; $j >= 0; $j--) {
      $t = $tokens[$j];
      if (is_array($t) && in_array($t[0], [T_WHITESPACE, T_DOC_COMMENT], TRUE)) {
        if ($t[0] === T_DOC_COMMENT) {
          $start = $lines[$j];
        }
        continue;
      }
      if (is_array($t) && in_array($t[0], $modifiers, TRUE)) {
        $start = $lines[$j];
        continue;
      }
      if ($t === ']') {
        // An attribute group: back to its "#[".
        $depth = 0;
        for ($k = $j; $k >= 0; $k--) {
          $u = $tokens[$k];
          if ($u === ']') {
            $depth++;
          }
          elseif ($u === '[' || (is_array($u) && defined('T_ATTRIBUTE') && $u[0] === T_ATTRIBUTE)) {
            $depth--;
            if ($depth === 0) {
              break;
            }
          }
        }
        if ($k >= 0 && is_array($tokens[$k]) && defined('T_ATTRIBUTE') && $tokens[$k][0] === T_ATTRIBUTE) {
          $start = $lines[$k];
          $j = $k;
          continue;
        }
      }
      break;
    }
    return $start;
  };

  $spans = [];
  // Scopes: ['kind' => namespace|class|anon|function|closure, 'name', 'depth', 'start'].
  $stack = [];
  $depth = 0;
  $namespace = '';
  // A declaration whose body has not opened yet.
  $pending = NULL;
  $nearestClass = function () use (&$stack) {
    for ($k = count($stack) - 1; $k >= 0; $k--) {
      if (in_array($stack[$k]['kind'], ['class', 'anon'], TRUE)) {
        return $stack[$k];
      }
      if ($stack[$k]['kind'] === 'function' || $stack[$k]['kind'] === 'closure') {
        return NULL;
      }
    }
    return NULL;
  };
  $qualify = function (string $name) use (&$namespace): string {
    return $namespace === '' ? $name : $namespace . '\\' . $name;
  };

  for ($i = 0; $i < $n; $i++) {
    $t = $tokens[$i];
    $id = is_array($t) ? $t[0] : NULL;
    if ($id === T_NAMESPACE) {
      $next = $significant($i, 1);
      if ($next >= 0 && is_array($tokens[$next]) && $tokens[$next][0] === T_NS_SEPARATOR) {
        // namespace\foo(): an operator, not a declaration.
        continue;
      }
      $name = '';
      for ($j = $i + 1; $j < $n; $j++) {
        $u = $tokens[$j];
        if ($u === ';' || $u === '{') {
          break;
        }
        if (is_array($u) && $u[0] !== T_WHITESPACE && $u[0] !== T_COMMENT && $u[0] !== T_DOC_COMMENT) {
          $name .= $u[1];
        }
      }
      $namespace = trim($name, '\\');
      if ($j < $n && $tokens[$j] === '{') {
        $pending = ['kind' => 'namespace', 'name' => $namespace, 'start' => $lines[$i]];
      }
      $i = $j - 1;
      continue;
    }
    if ($id !== NULL && in_array($id, $classLike, TRUE)) {
      $prev = $significant($i, -1);
      if ($prev >= 0 && is_array($tokens[$prev]) && $tokens[$prev][0] === T_DOUBLE_COLON) {
        // Foo::class.
        continue;
      }
      if ($id === T_CLASS && $prev >= 0 && is_array($tokens[$prev]) && $tokens[$prev][0] === T_NEW) {
        $pending = ['kind' => 'anon', 'name' => NULL, 'start' => $lines[$i]];
        continue;
      }
      $next = $significant($i, 1);
      if ($next >= 0 && is_array($tokens[$next]) && $tokens[$next][0] === T_STRING) {
        $pending = ['kind' => 'class', 'name' => $qualify($tokens[$next][1]), 'start' => $declStart($i)];
      }
      continue;
    }
    if ($id === T_FUNCTION) {
      $prev = $significant($i, -1);
      if ($prev >= 0 && is_array($tokens[$prev]) && $tokens[$prev][0] === T_USE) {
        // use function Foo\bar;
        continue;
      }
      $next = $significant($i, 1);
      // A by-reference function: "&" (PHP 7) or T_AMPERSAND_* (PHP 8.1+).
      if ($next >= 0 && ($tokens[$next] === '&' || (is_array($tokens[$next]) && strpos(token_name($tokens[$next][0]), 'AMPERSAND') !== FALSE))) {
        $next = $significant($next, 1);
      }
      if ($next >= 0 && is_array($tokens[$next]) && $tokens[$next][0] === T_STRING) {
        $class = $nearestClass();
        $inClassBody = $class !== NULL && end($stack) === $class;
        if ($inClassBody) {
          $name = $class['name'] === NULL ? NULL : $class['name'] . '::' . $tokens[$next][1];
        }
        else {
          $name = $qualify($tokens[$next][1]);
        }
        $pending = ['kind' => 'function', 'name' => $name, 'start' => $declStart($i)];
      }
      else {
        $pending = ['kind' => 'closure', 'name' => NULL, 'start' => $lines[$i]];
      }
      continue;
    }
    if ($t === ';' && $pending !== NULL && $pending['kind'] === 'function') {
      // A method without a body (abstract, interface).
      if ($pending['name'] !== NULL) {
        $spans[] = [$pending['start'], $lines[$i], $pending['name']];
      }
      $pending = NULL;
      continue;
    }
    if ($t === '{' || ($id !== NULL && in_array($id, [T_CURLY_OPEN, T_DOLLAR_OPEN_CURLY_BRACES], TRUE))) {
      $depth++;
      if ($t === '{' && $pending !== NULL) {
        $stack[] = $pending + ['depth' => $depth];
        $pending = NULL;
      }
      continue;
    }
    if ($t === '}') {
      if ($stack !== [] && end($stack)['depth'] === $depth) {
        $scope = array_pop($stack);
        if ($scope['kind'] === 'namespace') {
          $namespace = '';
        }
        elseif (in_array($scope['kind'], ['class', 'function'], TRUE) && $scope['name'] !== NULL) {
          $spans[] = [$scope['start'], $lines[$i], $scope['name']];
        }
      }
      $depth--;
      continue;
    }
  }
  return $spans;
}

/**
 * The anchor of one line: the innermost span that contains it, else {file}.
 */
function drupilot_anchor_of(array $spans, int $line): string {
  $best = NULL;
  foreach ($spans as $span) {
    if ($line >= $span[0] && $line <= $span[1]) {
      if ($best === NULL || $span[0] > $best[0] || ($span[0] === $best[0] && $span[1] < $best[1])) {
        $best = $span;
      }
    }
  }
  return $best === NULL ? '{file}' : $best[2];
}

$raw = (string) stream_get_contents(STDIN);
// A JSON array decodes to a PHP array only without assoc (an object to stdClass).
if (!is_array(json_decode($raw))) {
  fwrite(STDERR, "anchor.php: STDIN must be a JSON array of {\"file\", \"line\"}\n");
  exit(1);
}
$input = json_decode($raw, TRUE);
$cache = [];
$out = [];
foreach ($input as $request) {
  $file = is_array($request) && isset($request['file']) && is_string($request['file']) ? $request['file'] : '';
  $line = is_array($request) && isset($request['line']) && is_int($request['line']) ? $request['line'] : 0;
  if (!array_key_exists($file, $cache)) {
    $code = ($file !== '' && is_file($file) && is_readable($file)) ? file_get_contents($file) : FALSE;
    $cache[$file] = $code === FALSE ? [] : drupilot_anchor_spans($code);
  }
  $out[] = (is_array($request) ? $request : []) + ['anchor' => $line > 0 ? drupilot_anchor_of($cache[$file], $line) : '{file}'];
}
echo json_encode($out, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), "\n";
