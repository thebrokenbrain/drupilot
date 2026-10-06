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
 * them. A scope starts at its own doc comment (the one right before it),
 * attributes and modifiers, and ends at its closing brace (or at the ";" of a
 * method without a body).
 *
 * Core PHP only (token_get_all; no dependency); PHP 8.1 or later (run on 8.1,
 * 8.3 and 8.5). Staged into
 * the Drupal root by stage_runtime (scripts/lib/cache.sh) and run in the bed:
 *
 *   $(drupal_runner) php .drupilot/runtime/anchor.php < requests.json
 *
 * STDIN: a JSON array of {"file": PATH, "line": N} (PATH relative to the
 * working directory; other fields are kept as they are). STDOUT: the same
 * array, each entry with "anchor" added, in the input order. A file that cannot be read, or a line out of any scope,
 * gets "{file}". Exit codes: 0 ok, 1 STDIN is not a JSON array.
 */

declare(strict_types=1);

/**
 * The tokens of a file: TOKEN_PARSE (a keyword used as a name, such as a
 * method match() or a constant NAMESPACE, is then a T_STRING), else the plain
 * tokenizer for code that does not parse.
 */
function drupilot_anchor_tokens(string $code): array {
  try {
    return token_get_all($code, TOKEN_PARSE);
  }
  catch (\Throwable $e) {
    return token_get_all($code);
  }
}

/**
 * The anchored spans of one file: [[start_line, end_line, anchor], ...].
 */
function drupilot_anchor_spans(string $code): array {
  $tokens = drupilot_anchor_tokens($code);
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
  $isAttribute = function ($t): bool {
    return is_array($t) && defined('T_ATTRIBUTE') && $t[0] === T_ATTRIBUTE;
  };
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
  // The "#[" that opens the attribute group closed by the "]" at $j, or -1.
  $attributeStart = function (int $j) use ($tokens, $isAttribute): int {
    $depth = 0;
    for ($k = $j; $k >= 0; $k--) {
      $u = $tokens[$k];
      if ($u === ']') {
        $depth++;
      }
      elseif ($u === '[' || $isAttribute($u)) {
        $depth--;
        if ($depth === 0) {
          return $isAttribute($u) ? $k : -1;
        }
      }
    }
    return -1;
  };
  // The first line of a declaration: its own doc comment (the nearest one
  // only), attributes and modifiers.
  $declStart = function (int $i) use ($tokens, $lines, $modifiers, $attributeStart): int {
    $start = $lines[$i];
    for ($j = $i - 1; $j >= 0; $j--) {
      $t = $tokens[$j];
      if (is_array($t) && $t[0] === T_WHITESPACE) {
        continue;
      }
      if (is_array($t) && $t[0] === T_DOC_COMMENT) {
        return $lines[$j];
      }
      if (is_array($t) && in_array($t[0], $modifiers, TRUE)) {
        $start = $lines[$j];
        continue;
      }
      if ($t === ']' && ($k = $attributeStart($j)) >= 0) {
        $start = $lines[$k];
        $j = $k;
        continue;
      }
      break;
    }
    return $start;
  };
  // Whether the T_CLASS at $i is an anonymous class: "new" before it, past
  // readonly and attribute groups.
  $isAnonymous = function (int $i) use ($tokens, $significant, $attributeStart): bool {
    $j = $significant($i, -1);
    while ($j >= 0) {
      $t = $tokens[$j];
      if (is_array($t) && defined('T_READONLY') && $t[0] === T_READONLY) {
        $j = $significant($j, -1);
        continue;
      }
      if ($t === ']' && ($k = $attributeStart($j)) >= 0) {
        $j = $significant($k, -1);
        continue;
      }
      return is_array($t) && $t[0] === T_NEW;
    }
    return FALSE;
  };

  $spans = [];
  // Open scopes: ['kind' => namespace|class|anon|function|closure, 'name', 'depth', 'start'].
  $stack = [];
  // Declarations whose body has not opened yet, each with the parenthesis
  // depth it was declared at: its body is the next "{" at that depth (a
  // closure or a match in an anonymous class's arguments opens its own first).
  $pending = [];
  $depth = 0;
  $paren = 0;
  $namespace = '';
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
    if ($t === '(') {
      $paren++;
      continue;
    }
    if ($t === ')') {
      $paren--;
      continue;
    }
    if ($id === T_NAMESPACE) {
      $next = $significant($i, 1);
      if ($next >= 0 && is_array($tokens[$next]) && $tokens[$next][0] === T_NS_SEPARATOR) {
        // namespace\foo(): an operator, not a declaration.
        continue;
      }
      $prev = $significant($i, -1);
      if ($prev >= 0 && is_array($tokens[$prev]) && in_array($tokens[$prev][0], [T_DOUBLE_COLON, T_OBJECT_OPERATOR, T_CONST, T_CASE, T_FUNCTION], TRUE)) {
        // A name that only looks like the keyword (plain tokenizer fallback).
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
        $pending[] = ['kind' => 'namespace', 'name' => $namespace, 'start' => $lines[$i], 'paren' => $paren];
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
      if ($id === T_CLASS && $isAnonymous($i)) {
        $pending[] = ['kind' => 'anon', 'name' => NULL, 'start' => $lines[$i], 'paren' => $paren];
        continue;
      }
      $next = $significant($i, 1);
      if ($next >= 0 && is_array($tokens[$next]) && $tokens[$next][0] === T_STRING) {
        $pending[] = ['kind' => 'class', 'name' => $qualify($tokens[$next][1]), 'start' => $declStart($i), 'paren' => $paren];
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
      // A name: T_STRING, or (plain tokenizer, code that does not parse on
      // this PHP) a keyword-shaped token followed by "(", as in match().
      $named = $next >= 0 && is_array($tokens[$next]) && ($tokens[$next][0] === T_STRING
        || (preg_match('/^[A-Za-z_][A-Za-z0-9_]*$/', $tokens[$next][1]) === 1
          && ($after = $significant($next, 1)) >= 0 && $tokens[$after] === '('));
      if ($named) {
        $class = $nearestClass();
        $inClassBody = $class !== NULL && end($stack) === $class;
        if ($inClassBody) {
          $name = $class['name'] === NULL ? NULL : $class['name'] . '::' . $tokens[$next][1];
        }
        else {
          $name = $qualify($tokens[$next][1]);
        }
        $pending[] = ['kind' => 'function', 'name' => $name, 'start' => $declStart($i), 'paren' => $paren];
      }
      else {
        $pending[] = ['kind' => 'closure', 'name' => NULL, 'start' => $lines[$i], 'paren' => $paren];
      }
      continue;
    }
    $top = $pending === [] ? NULL : $pending[count($pending) - 1];
    if ($t === ';' && $top !== NULL && $top['kind'] === 'function' && $top['paren'] === $paren) {
      // A method without a body (abstract, interface).
      array_pop($pending);
      if ($top['name'] !== NULL) {
        $spans[] = [$top['start'], $lines[$i], $top['name']];
      }
      continue;
    }
    if ($t === '{' || ($id !== NULL && in_array($id, [T_CURLY_OPEN, T_DOLLAR_OPEN_CURLY_BRACES], TRUE))) {
      $depth++;
      if ($t === '{' && $top !== NULL && $top['paren'] === $paren) {
        array_pop($pending);
        $stack[] = $top + ['depth' => $depth];
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
// Decoded as objects, so every other field of a request comes back unchanged
// ({} stays {}, an object with numeric keys stays an object).
$input = json_decode($raw);
if (!is_array($input)) {
  fwrite(STDERR, "anchor.php: STDIN must be a JSON array of {\"file\", \"line\"}\n");
  exit(1);
}
$cache = [];
$out = [];
foreach ($input as $request) {
  if (!is_object($request)) {
    $request = new \stdClass();
  }
  $file = isset($request->file) && is_string($request->file) ? $request->file : '';
  $line = isset($request->line) && is_int($request->line) ? $request->line : 0;
  if (!array_key_exists($file, $cache)) {
    $code = ($file !== '' && is_file($file) && is_readable($file)) ? file_get_contents($file) : FALSE;
    $cache[$file] = $code === FALSE ? [] : drupilot_anchor_spans($code);
  }
  $request->anchor = $line > 0 ? drupilot_anchor_of($cache[$file], $line) : '{file}';
  $out[] = $request;
}
echo json_encode($out, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), "\n";
