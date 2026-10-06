#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/toolchain.sh
# The dev toolchain: the known-good reference (cells), Rector's configs
# (the PHP floor, the compat pass), crash detection and smoke tests.
#
# Part of the shared library: scripts/lib/common.sh sources it with the other
# domain libs (never source it alone); see common.sh for the conventions.
# =============================================================================

# rector_php_set_arg [ver] -> the named argument of Rector's ->withPhpSets()
# for a PHP target: 8.3 -> php83, 8.4 -> php84. A target flagged unconfirmed
# (PHP 8.5) or not recognised falls back to the highest confirmed supported
# version (php84 by default) with a warning on STDERR: the matching Rector
# LevelSet may not exist in the installed Rector, so it is never assumed.
rector_php_set_arg() {
  local v="${1:-$(resolve_php_target)}" file best=""
  if [[ "$v" =~ ^8\.[0-9]$ ]] && ! php_target_unconfirmed "$v"; then
    printf 'php%s' "${v//./}"; return 0
  fi
  file="$(drupilot_config_file)"
  if [[ -r "$file" ]] && have_cmd jq; then
    best="$(jq -r '(.php_support.unconfirmed // []) as $u
                   | [(.php_support.supported // [])[] | select(. as $s | $u | index($s) | not)]
                   | sort_by(split(".") | map(tonumber)) | last // empty' "$file" 2>/dev/null || true)"
  fi
  [[ "$best" =~ ^8\.[0-9]$ ]] || best="8.4"
  log_warn "PHP target '$v' is not a confirmed Rector PHP set for Drupal 11; using php${best//./} (PHP $best)."
  printf 'php%s' "${best//./}"
  return 0
}

# The PHP floor of the Rector configs (ADR 0002). templates/rector.php.tmpl
# runs the main pass at the floor L: ->withPhpVersion(PhpVersion::PHP_<L>) and
# ->withPhpSets(php<L>: true), so no version-bound rule and no level set above
# L applies. templates/rector-compat.php.tmpl is the narrow compat pass: the
# PHP deprecation fixes whose output still runs on L (today only
# ExplicitNullableParamTypeRector, deprecated in PHP 8.4), run right after the
# official pass. M5 generates the compat list from config/php/rules.json.
RECTOR_COMPAT_FROM_PHP="8.4"

# _rector_range_legs RANGE -> one caret leg per alternative of a core range,
# one per line ("^10.3"), or "?" for an alternative it cannot read. ^X.Y,
# ~X.Y, X.Y.*, X.x and a bare version read as ^X.Y; an open >=X.Y as ^X.Y plus
# ^M for every higher major the version data holds.
_rector_range_legs() {
  local alt maj min f m dir
  local re_c='^[~^]?v?([0-9]+)(\.([0-9]+|[*xX]))?(\.([0-9]+|[*xX]))?$' re_ge='^>=?v?([0-9]+)(\.([0-9]+))?(\.[0-9]+)?$'
  dir="$(version_data_dir)"
  while IFS= read -r alt; do
    alt="$(printf '%s' "$alt" | tr -d " \"'")"
    [[ -n "$alt" ]] || continue
    if [[ "$alt" =~ $re_c ]]; then
      maj="${BASH_REMATCH[1]}"; min="${BASH_REMATCH[3]}"
      case "$min" in ''|'*'|x|X) min=0;; esac
      printf '^%s.%s\n' "$maj" "$min"
    elif [[ "$alt" =~ $re_ge ]]; then
      maj="${BASH_REMATCH[1]}"; min="${BASH_REMATCH[3]:-0}"
      printf '^%s.%s\n' "$maj" "$min"
      for f in "$dir"/targets/*.json; do
        [[ -f "$f" ]] || continue
        m="${f##*/}"; m="${m%.json}"
        [[ "$m" =~ ^[0-9]+$ ]] && (( m > maj )) && printf '^%s\n' "$m"
      done
    else
      printf '?\n'
    fi
  done <<EOF
$(printf '%s\n' "${1:-}" | tr '|' '\n')
EOF
  return 0
}

# _rector_leg_major ^X.Y -> X
_rector_leg_major() { local l="${1#^}"; printf '%s' "${l%%.*}"; }

# rector_php_bounds <subject_dir> [php_target] -> "L U".
# L, the floor, is the highest of the lowest PHP the declared core range
# supports (core-strategy.sh's recommendation, which honors
# DRUPILOT_CORE_TARGET_STRATEGY; each of its legs through
# php_bounds_for_range) and the floor of the require.php composer will
# enforce (core-strategy's require_php, which honors
# DRUPILOT_REQUIRE_PHP_FLOOR, else the subject's own; only when the subject
# has a composer.json), never above the PHP target P. A leg whose minor is not
# verified yet is bounded by its major's verified minors. When a leg is one
# the version data does not hold (a Drupal 9 leg kept as-is, an unusual
# constraint), the range floor is unknown: L is the enforced require.php
# floor, else the lowest PHP the data knows, with a warning. U, the highest
# PHP the code must run on, is max(P, the highest ceiling of the known legs).
rector_php_bounds() {
  local subj="${1:-}" p="${2:-}" cs="" req="" rphp="" leg b lo="" hi="" f="" unknown=1 n=0
  [[ -n "$p" ]] || p="$(resolve_php_target)"
  if [[ -n "$subj" && -d "$subj" ]] && have_cmd jq; then
    cs="$(DRUPILOT_PHP_TARGET="$p" bash "$(plugin_root)/scripts/analysis/core-strategy.sh" --subject "$subj" --json 2>/dev/null </dev/null || true)"
    req="$(printf '%s' "$cs" | jq -r '.recommended_core_version_requirement // empty' 2>/dev/null || true)"
    if [[ -f "$subj/composer.json" ]]; then
      rphp="$(printf '%s' "$cs" | jq -r '.require_php // empty' 2>/dev/null || true)"
      [[ -n "$rphp" ]] || rphp="$(jq -r '.require.php // empty' "$subj/composer.json" 2>/dev/null || true)"
      f="$(php_constraint_floor "$rphp")"
    fi
    if [[ -n "$req" ]]; then
      unknown=0
      while IFS= read -r leg; do
        [[ -n "$leg" ]] || continue
        b=""; [[ "$leg" == "?" ]] || b="$(php_bounds_for_range "$leg")"
        if [[ -z "$b" && "$leg" != "?" && -r "$(version_data_dir)/targets/$(_rector_leg_major "$leg").json" ]]; then
          # The major is in the data but no verified minor reaches the leg's
          # (^11.5 before 11.5 is verified): its verified minors bound it. A
          # major with no verified minor at all (a future one) adds nothing.
          b="$(php_bounds_for_range "^$(_rector_leg_major "$leg")")"
          [[ -n "$b" ]] || continue
        fi
        n=$((n + 1))
        if [[ -z "$b" ]]; then unknown=1; continue; fi
        if [[ -z "$lo" ]] || ! version_ge "${b%% *}" "$lo"; then lo="${b%% *}"; fi
        if [[ -z "$hi" ]] || ! version_ge "$hi" "${b##* }"; then hi="${b##* }"; fi
      done <<EOF
$(_rector_range_legs "$req")
EOF
      [[ "$n" -gt 0 ]] || unknown=1
    fi
  fi
  if [[ "$unknown" == "1" ]]; then
    lo="$f"
    # A range drupilot could not bound (not no range at all: then P).
    if [[ -z "$lo" && -n "$req" ]]; then
      lo="$(jq -r '.versions | keys | sort_by(split(".") | map(tonumber)) | .[0] // empty' \
        "$(version_data_dir)/php/versions.json" 2>/dev/null || true)"
      log_warn "The PHP floor of the core range '$req' is not in drupilot's version data and no composer require.php bounds it: Rector targets PHP ${lo:-$p}, the lowest PHP drupilot knows."
    fi
  elif [[ -n "$f" ]] && ! version_ge "$lo" "$f"; then
    lo="$f"
  fi
  [[ -n "$lo" ]] || lo="$p"
  [[ -n "$hi" ]] || hi="$p"
  version_ge "$p" "$lo" || lo="$p"
  version_ge "$hi" "$p" || hi="$p"
  printf '%s %s' "$lo" "$hi"
  return 0
}

# rector_compat_needed L U -> 0 when the compat pass has a rule to run: the
# floor is below the PHP that deprecates it, and the window reaches that PHP
# (from L >= 8.4 on, the php84 level set of the main pass holds the rule).
rector_compat_needed() {
  [[ -n "${1:-}" && -n "${2:-}" ]] || return 1
  version_ge "$1" "$RECTOR_COMPAT_FROM_PHP" && return 1
  version_ge "$2" "$RECTOR_COMPAT_FROM_PHP"
}

# rector_floor_tokens L -> the template tokens of a floor, one KEY=VALUE per
# line: PHP_FLOOR=8.1, PHP_FLOOR_ID=PHP_81 (Rector's PhpVersion constant) and
# PHP_FLOOR_SET=php81 (the ->withPhpSets() argument; an unconfirmed 8.5 floor
# gets rector_php_set_arg's php84, since no php85 set is assumed), and the same
# two under rector.php v5's names, PHP_VERSION_L and PHP_SETS_L. Returns 1
# when L is not a PHP minor.
rector_floor_tokens() {
  local l="${1:-}" set
  [[ "$l" =~ ^[0-9]\.[0-9]$ ]] || return 1
  if php_target_unconfirmed "$l"; then set="$(rector_php_set_arg "$l" 2>/dev/null)"; else set="php${l//./}"; fi
  printf 'PHP_FLOOR=%s\nPHP_FLOOR_ID=PHP_%s\nPHP_FLOOR_SET=%s\nPHP_VERSION_L=PHP_%s\nPHP_SETS_L=%s\n' \
    "$l" "${l//./}" "$set" "${l//./}" "$set"
  return 0
}

# rector_sets_block PLAN -> rector.php v5's {{RECTOR_SETS}}: one quoted,
# comma-ended constant name per line (  'DrupalRector\\Set\\Drupal10SetList::DRUPAL_100',)
# for the plan's rector.drupal_sets then rector.breaking_sets, in order. The
# Drupal 8 and 9 families stay out until the D8/D9 hops are proven (T-M9-03,
# ADR 0019): 0.9 never ran them.
rector_sets_block() {
  printf '%s' "${1:-}" | jq -r '[(.rector.drupal_sets // [])[], (.rector.breaking_sets // [])[]]
    | map(select(test("^Drupal[0-9]+SetList::DRUPAL_[0-9]+(_BREAKING)?$")
                 and ((capture("^Drupal(?<n>[0-9]+)SetList").n | tonumber) >= 10)))
    | .[] | "  \u0027DrupalRector\\\\Set\\\\" + . + "\u0027,"' 2> /dev/null || true
  return 0
}

# rector_skip_block PLAN -> rector.php v5's {{SKIP_RULES}}: the plan's
# rector.skip FQCNs, one quoted, comma-ended PHP string per line, backslashes
# doubled (  'Rector\\Php81\\Rector\\Array_\\ArrayToFirstClassCallableRector',).
rector_skip_block() {
  printf '%s' "${1:-}" | jq -r '(.rector.skip // [])[] | select(type == "string" and test("^[A-Za-z0-9_\\\\]+$"))
    | "  \u0027" + (split("\\") | join("\\\\")) + "\u0027,"' 2> /dev/null || true
  return 0
}

# rector_bc_block PLAN -> rector.php v5's {{BC_BLOCK}}: with the plan's
# rector.bc enabled, a wrapper that registers drupal-rector's settings with
# backwards-compatible rewrites (DeprecationHelper) for every core from
# rector.bc.min_core on (ADR 0017 item 2); nothing otherwise, so drupal-rector
# keeps its own default, as in 0.9.
rector_bc_block() {
  local min
  min="$(printf '%s' "${1:-}" | jq -r 'select(.rector.bc.enabled == true) | .rector.bc.min_core // empty' 2> /dev/null || true)"
  [[ "$min" =~ ^[0-9]+\.[0-9]+$ ]] || return 0
  cat <<EOF

// Backwards-compatible rewrites (DeprecationHelper) for every core the declared
// range keeps, from $min on (the plan's rector.bc).
\$drupilotConfig = static function (RectorConfig \$rectorConfig) use (\$drupilotConfig): void {
  \$drupilotConfig(\$rectorConfig);
  if (class_exists(\\DrupalRector\\Services\\DrupalRectorSettings::class)) {
    \$rectorConfig->singleton(\\DrupalRector\\Services\\DrupalRectorSettings::class, static fn () => (new \\DrupalRector\\Services\\DrupalRectorSettings())
      ->enableBackwardCompatibility()
      ->setMinimumCoreVersionSupported('$min.0'));
  }
};
EOF
  return 0
}

# php_version_id X.Y -> PHP's PHP_VERSION_ID of a minor (8.1 -> 80100), as
# PHPStan's phpVersion takes it; nothing (return 1) when X.Y is not a minor.
php_version_id() {
  local v="${1:-}"
  [[ "$v" =~ ^([0-9])\.([0-9])$ ]] || return 1
  printf '%s\n' "$((BASH_REMATCH[1] * 10000 + BASH_REMATCH[2] * 100))"
}

# phpstan_profile_block PROFILE -> phpstan.neon v3's {{PHPSTAN_PROFILE_BLOCK}}
# (ADR 0020, 03-R8), lines under `parameters:`. compat (Phase 1): none of
# phpstan-drupal's opinion rules, which ask for changes no Drupal version
# requires (dependency injection, test class names, @internal parents).
# refactor (Phase 2): every rule as phpstan-drupal ships it. The rule names
# are those of phpstan-drupal 2.2's extension.neon. Its bleedingEdge
# deprecated-hook flags stay off: in 2.2 they only load the *.api.php files,
# no registered rule reads them (lab, ADR 0020).
phpstan_profile_block() {
  local p="${1:-compat}"
  case "$p" in compat|refactor) ;; *) return 1;; esac
  printf '\n  # Profile %s (ADR 0020).\n' "$p"
  if [[ "$p" == "compat" ]]; then
    printf '  # phpstan-drupal'"'"'s opinion rules are off: a minimal port makes no change\n'
    printf '  # they ask for.\n'
    printf '  drupal:\n    rules:\n'
    printf '      globalDrupalDependencyInjectionRule: false\n'
    printf '      entityStorageDirectInjectionRule: false\n'
    printf '      testClassSuffixNameRule: false\n'
    printf '      classExtendsInternalClassRule: false\n'
  else
    printf '  # Every phpstan-drupal rule as it ships.\n'
  fi
  return 0
}

# phpstan_cache_key PLAN [MIN MAX] -> the first 12 hex digits of the plan's
# hash (upgrade_plan_hash's form: meta excluded), the directory of
# phpstan.neon's result cache under .phpstan-cache/. A fallback plan carries no
# PHP range, so MIN and MAX join its hash.
phpstan_cache_key() {
  local plan="${1:-}" h
  [[ -n "$plan" ]] || return 1
  h="$(printf '%s' "$plan" | jq -c --arg lo "${2:-}" --arg hi "${3:-}" \
        'if .php.phpstan_phpversion then . else . + {phpstan_range: [$lo, $hi]} end' 2> /dev/null \
        | canon_json_hashable | json_hash)"
  h="${h#sha256:}"
  [[ ${#h} -ge 12 ]] || return 1
  printf '%s\n' "${h:0:12}"
}

# rector_config_floor FILE -> the floor a rendered rector.php targets (8.1 from
# its ->withPhpVersion(PhpVersion::PHP_81)); nothing when it has none.
rector_config_floor() {
  sed -n 's/.*->withPhpVersion(PhpVersion::PHP_\([0-9]\)\([0-9]\)).*/\1.\2/p' "${1:-}" 2>/dev/null | sed -n '1p'
  return 0
}

# rector_config_missing_paths ROOT FILE -> the relative literal paths of the
# withPaths([...]) list of a Rector config FILE that do not exist under ROOT,
# one per line (Rector stops on such a path). Comment lines, /* */ and trailing
# // comments are ignored; an absolute path (it may be the container's), a
# __DIR__ path and a wildcard are not checked; only the first list after the
# first ->withPaths([ outside a comment is read. Read-only; prints nothing
# when FILE is missing.
rector_config_missing_paths() {
  local root="${1:-}" f="${2:-}" p list
  [[ -f "$f" ]] || return 0
  # shellcheck disable=SC2016  # awk program, not a shell expansion
  list="$(awk -v q="'" '
    {
      l = $0
      sub(/^[ \t]*(\*|\/\*|#|\/\/).*/, "", l)
      gsub(/\/\*[^*]*\*\//, "", l)
      sub(/[ \t]\/\/.*$/, "", l)
      if (!on) { if (!match(l, /->withPaths\(\[/)) next; on = 1; l = substr(l, RSTART + RLENGTH) }
      last = 0
      if (match(l, /\]/)) { l = substr(l, 1, RSTART - 1); last = 1 }
      gsub("__DIR__[ \t]*[.][ \t]*(" q "[^" q "]*" q "|\"[^\"]*\")", "", l)
      while (match(l, q "[^" q "]*" q "|\"[^\"]*\"")) { print substr(l, RSTART + 1, RLENGTH - 2); l = substr(l, RSTART + RLENGTH) }
      if (last) exit
    }' "$f" 2> /dev/null || true)"
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != /* && "$p" != *[*?[]* ]] || continue
    [[ -e "$root/$p" ]] || printf '%s\n' "$p"
  done <<EOF
$list
EOF
  return 0
}

# rector_config_pristine TEMPLATE FILE -> 0 when FILE is exactly what TEMPLATE
# renders for FILE's own floor and subject path (rector.php, or
# rector-compat.php, whose only token is the subject: its withPhpVersion is
# the rules' own and the floor tokens are ignored): a drupilot
# render nobody edited, which may be regenerated when its inputs change. A
# hand edit, another template generation or a file of the developer's own -> 1.
# A template-5 rector.php never matches (its sets, skips and BC block come from
# the plan): the sha256 kept in the lock recognizes it (render_sha_matches).
rector_config_pristine() {
  local tpl="${1:-}" f="${2:-}" fl sp rc=1
  [[ -f "$tpl" && -f "$f" ]] || return 1
  fl="$(rector_config_floor "$f")"
  [[ -n "$fl" ]] || return 1
  # shellcheck disable=SC2016  # awk program, not a shell expansion
  sp="$(awk -v q="'" '/->withPaths\(\[/ { if ((getline l) > 0) { sub("^[[:space:]]*" q, "", l); sub(q ",[[:space:]]*$", "", l); print l }; exit }' "$f" 2>/dev/null || true)"
  [[ -n "$sp" ]] || return 1
  # Rendered to STDOUT and compared through a pipe: no temp file, whatever
  # TMPDIR holds (pipefail makes a failed render a mismatch).
  # shellcheck disable=SC2046  # one KEY=VALUE word per line, no spaces in them
  if ( set -o pipefail; render_template "$tpl" - "SUBJECT_PATH=$sp" $(rector_floor_tokens "$fl") 2>/dev/null \
       | cmp -s - "$f" ); then  # sigpipe-ok: any failure is a mismatch, the render's stderr is discarded
    rc=0
  fi
  return "$rc"
}

# phpstan_extension_config_problem <project_dir> -> checks the
# phpstan/extension-installer GeneratedConfig.php of a Composer project (a
# test-bed or a core-matrix reference core). Prints a one-line reason on STDOUT
# and returns 1 when it is broken: an extension include that does not resolve
# (PHPStan resolves `relative_install_path` from the file's directory, then the
# absolute `install_path`), or an installed `phpstan-extension` package the file
# does not list (e.g. the stub the package ships, left in place when another
# Composer's plugin ran instead). Returns 0, printing nothing, when the file is
# sound or the project has no extension-installer. Host-side and read-only.
phpstan_extension_config_problem() {
  local d="${1:-}" src gc listed missing name mount=""
  src="$d/vendor/phpstan/extension-installer/src"
  gc="$src/GeneratedConfig.php"
  [[ -d "$src" ]] || return 0
  if [[ ! -f "$gc" ]]; then printf 'vendor/phpstan/extension-installer/src/GeneratedConfig.php is missing'; return 1; fi
  mount="$(cd "$d" 2>/dev/null && pwd || true)"
  while [[ -n "$mount" && "$mount" != "/" && ! -f "$mount/.ddev/config.yaml" ]]; do mount="$(dirname "$mount")"; done
  [[ "$mount" == "/" ]] && mount=""
  # Each extension entry -> "name<TAB>relative_install_path<TAB>install_path<TAB>include".
  missing="$(awk '
    function val(s,   i) { i = index(s, "=>"); s = substr(s, i + 2); gsub(/^[ \t]*\047|\047,?[ \t]*$/, "", s); return s }
    /^  \047[^\047]+\047 => *$/ { name = $0; sub(/^  \047/, "", name); sub(/\047.*$/, "", name); rel = ""; abs = ""; next }
    name != "" && /\047relative_install_path\047 =>/ { rel = val($0); next }
    name != "" && /\047install_path\047 =>/ { abs = val($0); next }
    name != "" && /^        [0-9]+ => \047/ { printf "%s\t%s\t%s\t%s\n", name, rel, abs, val($0); next }
  ' "$gc" 2>/dev/null | while IFS="$(printf '\t')" read -r name rel abs inc; do
      [[ -n "$inc" ]] || continue
      if [[ -n "$rel" && -f "$src/$rel/$inc" ]]; then continue; fi
      # install_path is a container path (/var/www/html/...): map it to the
      # host through the DDEV project that mounts it.
      case "$abs" in /var/www/html/*) [[ -n "$mount" ]] && abs="$mount/${abs#/var/www/html/}";; esac
      [[ -n "$abs" && -f "$abs/$inc" ]] && continue
      printf '%s (%s)\n' "$name" "$inc"
    done | sed -n '1,3p' | tr '\n' ' ' || true)"
  if [[ -n "$missing" ]]; then
    printf 'it points to extension files that do not exist: %s' "$missing"
    return 1
  fi
  if have_cmd jq && [[ -f "$d/vendor/composer/installed.json" ]]; then
    listed="$(grep -oE "^  '[^']+' =>" "$gc" 2>/dev/null | sed -E "s/^  '//; s/' =>\$//" || true)"
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      if ! printf '%s\n' "$listed" | grep_q -xF "$name"; then
        printf 'it does not list the installed PHPStan extension %s' "$name"
        return 1
      fi
    done < <(jq -r '(if type == "object" then (.packages // []) else . end)[] | select(.type == "phpstan-extension") | .name' "$d/vendor/composer/installed.json" 2>/dev/null || true)
  fi
  return 0
}

# core_dev_requirement [root] -> the Composer requirement for drupal/core-dev
# (PHPUnit + the Drupal test dependencies) MATCHING the installed core, so the
# test toolchain never drifts from core:
#   11.4.8        -> drupal/core-dev:~11.4.8   (same minor, >= that patch)
#   11.2.0-rc1    -> drupal/core-dev:11.2.0-rc1 (pre-release: exact)
#   11.x-dev      -> drupal/core-dev:11.x-dev   (dev branch: exact)
#   unknown       -> drupal/core-dev:<resolve_drupal_target> (e.g. ^11)
# The package name comes from config .packages.core_dev (default drupal/core-dev).
core_dev_requirement() {
  local r="${1:-$(find_drupal_root 2>/dev/null || true)}" v pkg
  pkg="$(config_json '.packages.core_dev' 'drupal/core-dev')"
  pkg="${pkg%%:*}"; [[ -n "$pkg" ]] || pkg="drupal/core-dev"
  v="$(drupal_core_version "$r")"
  if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s:~%s' "$pkg" "$v"
  elif [[ -n "$v" ]]; then
    printf '%s:%s' "$pkg" "$v"
  else
    printf '%s:%s' "$pkg" "$(resolve_drupal_target)"
  fi
  return 0
}

# phpunit_available [root] -> 0 when vendor/bin/phpunit exists for the project,
# checked through drupal_runner (inside the container when DDEV is up), so a
# mutagen-synced or container-only vendor is seen exactly as PHPUnit would be.
phpunit_available() {
  local r="${1:-$(find_drupal_root 2>/dev/null || true)}" runner
  [[ -n "$r" ]] || return 1
  runner="$(drupal_runner "$r")"
  if [[ -n "$runner" ]]; then
    # shellcheck disable=SC2086  # intentional word-split: runner is a command prefix.
    ( cd "$r" && $runner test -f vendor/bin/phpunit ) >/dev/null 2>&1
  else
    [[ -f "$r/vendor/bin/phpunit" ]]
  fi
}

# ---------------------------------------------------------------------------
# Toolchain health: the known-good reference set + Rector crash detection
# ---------------------------------------------------------------------------
# config/toolchain-reference.json is the KNOWN-GOOD dev-toolchain matrix shipped
# with the plugin: one cell per Drupal major family (.cells["11"], ["12"], ...),
# each an exact set verified together end to end (install + a Rector dry-run and
# apply + PHPStan), plus the single set drupilot 0.9 shipped (.legacy_v1).
# install-toolchain.sh pins a test-bed to its cell when the project has no lock
# yet (deterministic mode), so a fresh test-bed created after a broken upstream
# release still gets a set that works. Only a verified cell is pinned.

# toolchain_reference_file -> path to the shipped reference matrix.
toolchain_reference_file() { printf '%s/config/toolchain-reference.json' "$(plugin_root)"; }

# toolchain_cell_for <root> [fresh] -> the toolchain cell of a test-bed: the
# cell its lock records (.toolchain_cell); "legacy_v1" for a lock drupilot 0.9
# created (no .schema; it pins rector/rector, which only install-toolchain.sh
# installs, and records no cell: it keeps 0.9's set until it is refreshed);
# else, and always with a second argument (a refresh), the cell
# config/targets/<major>.json names for the installed core's major; else
# "11". A lock's answer that no longer fits the installed core's cell (the
# root was rebuilt on another major) gives way to the core's. Reads the lock
# without creating drupilot's data dir.
toolchain_cell_for() {
  local r="${1:-}" c="" major core_cell="" lf
  if [[ -n "$r" ]]; then
    major="$(drupal_core_version "$r" | sed -n 's/^v\{0,1\}\([0-9][0-9]*\)\..*/\1/p')"
    [[ -n "$major" ]] && core_cell="$(target_get "$major" .toolchain_cell)"
  fi
  if [[ -n "$r" && -z "${2:-}" ]] && have_cmd jq; then
    lf="$(lock_path "$r")"
    if [[ -r "$lf" ]]; then
      c="$(jq -r 'if (.toolchain_cell // "") != "" then .toolchain_cell
                  elif (.schema // 0) == 0 and ((.toolchain // {})["rector/rector"] // "") != "" then "legacy_v1"
                  else "" end' "$lf" 2> /dev/null || true)"
    fi
    # legacy_v1 is 0.9's Drupal 11 set.
    if [[ -n "$c" && -n "$core_cell" ]]; then
      if [[ "$c" == "legacy_v1" && "$core_cell" != "11" ]] || [[ "$c" != "legacy_v1" && "$c" != "$core_cell" ]]; then c=""; fi
    fi
  fi
  printf '%s' "${c:-${core_cell:-11}}"
  return 0
}

# toolchain_cell_verified <cell> -> 0 when the cell holds a verified set
# (legacy_v1 always does: drupilot 0.9 verified it).
toolchain_cell_verified() {
  local f; f="$(toolchain_reference_file)"
  [[ "${1:-}" == "legacy_v1" ]] && return 0
  [[ -r "$f" ]] && have_cmd jq || return 1
  jq -e --arg c "${1:-}" '.cells[$c].verified == true' "$f" > /dev/null 2>&1
}

# toolchain_reference_set [cell] -> the cell's pins as one JSON object
# ({package: version}; a null pin is left out), {} for an unverified or unknown
# cell. Default cell: 11.
toolchain_reference_set() {
  local f; f="$(toolchain_reference_file)"
  [[ -r "$f" ]] && have_cmd jq || { printf '{}'; return 0; }
  jq -c --arg c "${1:-11}" '(if $c == "legacy_v1" then .legacy_v1 else (.cells[$c] | select(.verified == true)) end
      | .toolchain // {}) // {} | with_entries(select(.value != null))' "$f" 2>/dev/null || printf '{}'
  return 0
}

# toolchain_reference_version <package> [cell] -> the known-good exact version
# of a Composer package in that cell (e.g. rector/rector -> 2.6.1 in cell 11),
# or nothing when the cell does not pin it or is not verified. Never fatal.
toolchain_reference_version() {
  local f; f="$(toolchain_reference_file)"
  [[ -r "$f" ]] && have_cmd jq || return 0
  jq -r --arg n "${1:-}" --arg c "${2:-11}" '(if $c == "legacy_v1" then .legacy_v1 else (.cells[$c] | select(.verified == true)) end
      | .toolchain[$n]) // empty' "$f" 2>/dev/null || true
  return 0
}

# toolchain_reference_require_cmd [cell] -> the exact command that installs the
# cell's set (Rector + PHPStan core packages), printed for remediation
# messages. Empty when the reference is unreadable or the cell is not verified.
toolchain_reference_require_cmd() {
  local f specs; f="$(toolchain_reference_file)"
  [[ -r "$f" ]] && have_cmd jq || return 0
  specs="$(jq -r --argjson t "$(toolchain_reference_set "${1:-11}")" '(.remediation_packages // []) as $p
                  | [$p[] | select($t[.] != null) | "\(.):\($t[.])"] | join(" ")' "$f" 2>/dev/null || true)"
  [[ -n "$specs" ]] && printf 'ddev composer require --dev -W %s' "$specs"
  return 0
}

# lenient_packages [root] -> the packages mglaman/composer-drupal-lenient lets
# install on ROOT despite their drupal/core constraint, as a compact JSON
# array: ROOT/composer.json extra.drupal-lenient.allowed-list, sorted, or ["*"]
# with allow-all; [] when there is none (or no jq). Read from the bed's own
# composer.json, so it is what is in effect, whoever set it. Every test record
# carries it as lenient[] (AR-28): such a dependency was installed on the
# test-bed only, so a green suite does not show it supports the target core.
lenient_packages() {
  local r="${1:-${DRUPILOT_PROJECT_DIR:-$PWD}}" v=""
  if [[ -r "$r/composer.json" ]] && have_cmd jq; then
    v="$(jq -c '((.extra // {})["drupal-lenient"] // {}) as $l
      | if ($l | type) != "object" then []
        # composer-drupal-lenient tests allow-all by PHP truthiness ("true" too).
        elif ($l["allow-all"] // false) as $a | ($a != false and $a != null and $a != 0 and $a != ""
              and $a != "0" and $a != [] and $a != {}) then ["*"]
        else [($l["allowed-list"] // [])[]? | strings] | unique end' "$r/composer.json" 2> /dev/null || true)"
  fi
  [[ -n "$v" ]] || v='[]'
  printf '%s' "$v"
  return 0
}

# installed_package_version <root> <package> -> the version composer.lock
# records for <package> (packages + packages-dev), or nothing.
installed_package_version() {
  local r="${1:-}" n="${2:-}"
  [[ -n "$r" && -f "$r/composer.lock" ]] && have_cmd jq || return 0
  jq -r --arg n "$n" '((.packages // []) + (."packages-dev" // []))
         | map(select(.name == $n)) | (.[0].version // empty)' "$r/composer.lock" 2>/dev/null \
    | sed 's/^v//' || true
  return 0
}

# rector_output_ok <exit_code> <raw_output> -> 0 when a `rector process` run
# finished normally, 1 when it crashed or reported errors. Rector exits 0 (no
# change / applied) or 2 (dry-run found changes) and always ends with an
# "[OK] ..." line; a configuration error ("[ERROR] Could not detect twig set."),
# per-file processing errors (exit 1) or a PHP fatal (exit 255) do not. Both the
# exit code AND the [OK] marker are required, so neither a wrapper that loses the
# exit code nor a crash after partial output can pass as "no changes".
rector_output_ok() {
  local rc="${1:-1}" raw="${2:-}"
  case "$rc" in 0|2) ;; *) return 1;; esac
  printf '%s\n' "$raw" | grep_q -E '^[[:space:]]*\[OK\][[:space:]]' || return 1
  return 0
}

# rector_applied_rules <raw_output> -> the " * SomeRector" lines of Rector's
# "Applied rules:" blocks, without the bullet, one per line (once per changed
# file, as Rector prints them). Only inside those blocks: Rector also bullets
# the rules of a "[WARNING] This skipped rule is never registered" notice, and
# those were never applied. Never fails.
rector_applied_rules() {
  printf '%s\n' "${1:-}" | awk '
    /^Applied rules:[[:space:]]*$/ { inb = 1; next }
    inb && /^ \* [A-Za-z0-9_\\]+Rector[[:space:]]*$/ { sub(/^ \* /, ""); sub(/[[:space:]]+$/, ""); print; next }
    { inb = 0 }'
  return 0
}

# rector_json_ok <rc> <json> -> 0 when a Rector run with --output-format=json
# finished normally: exit 0 or 2 (a dry-run with changes) and one JSON report
# with totals and no error. Rector 2.x reports a per-file system error as
# totals.errors > 0 with exit 1, and a broken config as {"fatal_errors": [...]}
# (verified on 2.6.1 in lab L-M4); output that is not JSON is a crash too.
rector_json_ok() {
  [[ "${1:-}" == "0" || "${1:-}" == "2" ]] || return 1
  printf '%s' "${2:-}" | jq -e -s 'length == 1 and (.[0] | type == "object" and (.totals | type) == "object"
    and (.totals.errors // 0) == 0 and ((.fatal_errors // []) | length) == 0)' > /dev/null 2>&1
}

# rector_json_error <json> [stderr] -> at most 8 lines saying why a Rector run
# failed: its fatal errors, its file errors ("message (file:line)", sorted by
# file, line and message: Rector reports them in the order its parallel jobs
# end) — from the
# report, or from its last line when something printed text before it (a rule
# file without "<?php" is echoed by PHP) —, else the last non-empty lines of
# its STDERR, else of its STDOUT.
rector_json_error() {
  local out="" prog='((.fatal_errors // [])[]), ((.errors // []) | sort_by([(.file // ""), (.line // 0), (.message // "")])[] | "\(.message) (\(.file // "?")\(if .line then ":\(.line)" else "" end))")'
  out="$(printf '%s' "${1:-}" | jq -r "$prog" 2> /dev/null | sed -n '1,8p' || true)"
  [[ -n "$out" ]] || out="$(printf '%s\n' "${1:-}" | awk 'NF { l = $0 } END { print l }' | jq -r "$prog" 2> /dev/null | sed -n '1,8p' || true)"
  [[ -n "$out" ]] || out="$(printf '%s\n' "${2:-}" | awk '{ gsub(/\033\[[0-9;]*[A-Za-z]/, "") } /[^[:space:]]/' | tail -n 8 || true)"
  [[ -n "$out" ]] || out="$(printf '%s\n' "${1:-}" | grep -v '^[[:space:]]*$' | tail -n 8 || true)"
  printf '%s\n' "${out:-Rector failed without a message}"
  return 0
}

# rector_json_files <json> -> the files a Rector JSON report changed (or would
# change: its file_diffs), sorted, one per line.
rector_json_files() {
  printf '%s' "${1:-}" | jq -r '[(.file_diffs // [])[] | .file] | unique | .[]' 2> /dev/null || true
  return 0
}

# rector_json_rule_hits <json> -> {Rule: files} from a Rector JSON report: the
# short names of each file's applied_rectors, counted once per file. {} when
# none or not JSON.
rector_json_rule_hits() {
  local out
  out="$(printf '%s' "${1:-}" | jq -c '[(.file_diffs // [])[] | {file, r: ((.applied_rectors // []) | map(split("\\") | last) | unique)[]}]
    | group_by(.r) | map({key: .[0].r, value: length}) | from_entries' 2> /dev/null || true)"
  [[ -n "$out" ]] || out='{}'
  printf '%s' "$out"
  return 0
}

# tool_provenance <root> <runner> <package> -> {runner: "ddev"|"host",
# php_version, tool_version} (DET-1, AR-13): where a tool ran, on which PHP, at
# which installed version (composer.lock). Values that cannot be read are null.
tool_provenance() {
  local root="${1:-}" runner="${2:-}" pkg="${3:-}" php="" ver="" kind="host"
  [[ -n "$runner" ]] && kind="ddev"
  # shellcheck disable=SC2086  # intentional word-split: runner is a command prefix.
  php="$( (cd "$root" 2> /dev/null && $runner php -r 'echo PHP_VERSION;' < /dev/null) 2> /dev/null | tr -d '\r' || true)"
  [[ "$php" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || php=""
  [[ -n "$pkg" ]] && ver="$(installed_package_version "$root" "$pkg" | sed 's/^v//')"
  jq -n -c --arg r "$kind" --arg p "$php" --arg v "$ver" \
    '{runner: $r, php_version: (if $p == "" then null else $p end), tool_version: (if $v == "" then null else $v end)}'
  return 0
}

# det1_tool_mismatch <root> <package>... -> in deterministic mode, prints the
# first package whose installed version (composer.lock) differs from the one
# the root's lock pins, as "PKG installed INSTALLED, the lock pins PINNED", and
# returns 1 (restore the pins with install-toolchain.sh --dir ROOT, or accept
# the installed versions with lock-sync.sh --dir ROOT); returns 0 (silent)
# when they agree, when either side is unknown,
# or with DRUPILOT_DETERMINISTIC=false (DET-1). A leading "v" is ignored.
det1_tool_mismatch() {
  local root="${1:-}" pkg pin inst; shift || true
  deterministic_mode || return 0
  for pkg in "$@"; do
    pin="$(DRUPILOT_PROJECT_DIR="$root" lock_get ".toolchain.\"$pkg\"" "" | sed 's/^v//')"
    inst="$(installed_package_version "$root" "$pkg" | sed 's/^v//')"
    if [[ -n "$pin" && -n "$inst" && "$pin" != "$inst" ]]; then
      printf '%s installed %s, the lock pins %s' "$pkg" "$inst" "$pin"
      return 1
    fi
  done
  return 0
}

# det1_message <root> <tool> <package>... -> the DET-1 refusal for a tool about
# to run, or nothing when it may run (det1_unplanned_host, det1_tool_mismatch):
# the reason and what to do.
det1_message() {
  local root="${1:-}" tool="${2:-}" m; shift 2 || true
  if det1_unplanned_host "$root" "${DET1_RUNNER:-}"; then
    printf "DET-1: %s has a DDEV project but DDEV is not running, so %s would run on the host: start it ('ddev start'), or set DRUPILOT_DETERMINISTIC=false to accept the host run." "$root" "$tool"
  elif ! m="$(det1_tool_mismatch "$root" "$@")"; then
    printf 'DET-1: %s. Restore the pins (bash "%s/scripts/env/install-toolchain.sh" --dir "%s"), accept the installed versions (bash "%s/scripts/env/lock-sync.sh" --dir "%s"), or set DRUPILOT_DETERMINISTIC=false.' \
      "$m" "$(plugin_root)" "$root" "$(plugin_root)" "$root"
  fi
  return 0
}

# det1_unplanned_host <root> <runner> -> 0 when, in deterministic mode, a tool
# is about to run on the host although the root has a DDEV project and the
# ddev CLI is there (DDEV could not start): an unplanned fallback DET-1
# forbids. A root without .ddev/, or a machine without ddev (the analyze
# profile is Docker-free), runs on the host by plan; its provenance says
# runner "host".
det1_unplanned_host() {
  deterministic_mode && [[ -z "${2:-}" && -f "${1:-}/.ddev/config.yaml" ]] && have_cmd ddev
}

# rector_error_excerpt <raw_output> -> the lines that explain a failed Rector run
# (at most 8), for logs and the --json "errors" payload. Diff hunks are skipped,
# so a module string such as 'Fatal error:' can never be mistaken for a crash.
# A boxed "[ERROR] ..." message wraps onto indented continuation lines (e.g.
# 'Expected an existing class name. Got:' + '"SomeRector"'); those are joined
# into the same excerpt line up to the closing blank line, so the offending
# class/rule name is kept. Falls back to the last non-empty lines when no known
# marker is found.
rector_error_excerpt() {
  local raw="${1:-}" out
  out="$(printf '%s\n' "$raw" | awk '
      function clean(s) { gsub(/\033\[[0-9;]*[A-Za-z]/, "", s); sub(/[[:space:]]+$/, "", s); sub(/^[[:space:]]+/, "", s); return s }
      function flush() { if (length(cur) > 0) print cur; cur = ""; inbox = 0 }
      /-+ begin diff -+/ { flush(); indiff = 1; next }
      /-+ end diff -+/   { indiff = 0; next }
      indiff { next }
      /\[ERROR\]/ { flush(); cur = clean($0); inbox = 1; next }
      inbox && /^[[:space:]]+[^[:space:]]/ && !/\[[A-Z]+\]/ { cur = cur " " clean($0); next }
      inbox { flush() }
      /Fatal error|Uncaught|Exception|Could not |not found|Failed to execute command/ {
        l = clean($0); if (length(l) > 0) print l
      }
      END { flush() }' | sed -n '1,8p')"
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$raw" | sed -e "s/$(printf '\033')\\[[0-9;]*[A-Za-z]//g" | grep -v '^[[:space:]]*$' | tail -n 5 || true)"
  fi
  printf '%s' "$out"
  return 0
}

# phpstan_crash_ere -> the POSIX ERE (match it case-insensitively) of the
# PHPStan messages that mean the report is incomplete, so a run that printed
# them never reads as clean or as its findings: an internal error, a parallel
# worker that died (its memory limit, a fatal, a segfault) or timed out, and
# "Result is incomplete because of severe errors". With a worker gone PHPStan
# drops that worker's file errors and still exits 1. The messages are
# PHPStan 2.x's (src/Parallel/ParallelAnalyser.php, src/Parallel/Process.php,
# src/Command/AnalyseCommand.php in phpstan.phar).
phpstan_crash_ere() {
  printf '%s' 'Internal error|Child process (error|timed out)|PHPStan process crashed|Result is incomplete'
  return 0
}

# toolchain_diagnostics <root> [cell] -> log (STDERR) the installed vs known-good
# versions of the Rector/PHPStan packages and the exact remediation command.
# Used after a failed smoke test and by run-rector.sh after a Rector crash.
toolchain_diagnostics() {
  local r="${1:-}" f pkg inst ref cmd differs=0 cell="${2:-}" fix_cell
  f="$(toolchain_reference_file)"
  [[ -n "$cell" ]] || cell="$(toolchain_cell_for "$r")"
  if ! toolchain_cell_verified "$cell"; then
    log_plain "   Toolchain cell $cell has no verified set yet ($(basename "$f")): there is no known-good"
    log_plain "   version to compare with. Check its known_broken combinations, or the Rector config."
    return 0
  fi
  log_plain "   Installed vs known-good toolchain ($(basename "$f"), cell $cell):"
  for pkg in rector/rector palantirnet/drupal-rector phpstan/phpstan mglaman/phpstan-drupal; do
    inst="$(installed_package_version "$r" "$pkg")"
    ref="$(toolchain_reference_version "$pkg" "$cell")"
    [[ -n "$ref" && "$inst" != "$ref" ]] && differs=1
    log_plain "     $(printf '%-28s' "$pkg") installed: ${inst:-?}   known-good: ${ref:-?}"
  done
  if [[ "$differs" == "0" ]]; then
    log_plain "   The installed toolchain matches the known-good set, so look at the Rector config"
    log_plain "   (rector.php; regenerate it with render-templates.sh --only rector --force) or the error above."
    return 0
  fi
  # The fix installs the cell --source reference installs: for a 0.9 lock,
  # the refreshed cell, not legacy_v1.
  fix_cell="$cell"; [[ "$cell" == "legacy_v1" ]] && fix_cell="$(toolchain_cell_for "$r" fresh)"
  cmd="$(toolchain_reference_require_cmd "$fix_cell")"
  if [[ -n "$cmd" ]]; then
    [[ "$fix_cell" == "$cell" ]] || log_plain "   This project's lock was written by drupilot 0.9 (legacy_v1); the fix refreshes it to cell $fix_cell."
    log_plain "   Fix: reinstall the known-good set (from the Drupal root):"
    log_plain "     bash \"$(plugin_root)/scripts/env/install-toolchain.sh\" --dir \"$r\" --source reference"
    log_plain "   or by hand:  $cmd && bash \"$(plugin_root)/scripts/env/lock-sync.sh\" --dir \"$r\""
  fi
  return 0
}

# rector_smoke <root> -> run a trivial Rector dry-run (with the Drupal 10 set
# that drupal-rector loads at config time) plus `phpstan --version`, through
# drupal_runner, to prove the installed toolchain actually works. Scratch files
# go under <root>/.drupilot/rector-smoke.* (inside the project so the DDEV
# container sees them; removed afterwards). Prints the failure excerpt on STDOUT
# and returns 1 when broken; prints nothing and returns 0 when healthy.
rector_smoke() {
  local r="${1:-}" runner dir rel raw rc
  [[ -n "$r" && -d "$r" ]] || { printf 'rector_smoke: no Drupal root'; return 1; }
  if [[ ! -f "$r/vendor/bin/rector" ]]; then printf 'vendor/bin/rector is missing'; return 1; fi
  runner="$(drupal_runner "$r")"
  mkdir -p "$r/.drupilot" 2>/dev/null || true
  [[ -f "$r/.drupilot/.gitignore" ]] || printf '*\n' > "$r/.drupilot/.gitignore" 2>/dev/null || true
  dir="$(mktemp -d "$r/.drupilot/rector-smoke.XXXXXX" 2>/dev/null)" \
    || { printf 'rector_smoke: cannot create a scratch dir under %s/.drupilot' "$r"; return 1; }
  rel="${dir#"$r"/}"
  cat > "$dir/smoke.php" <<'PHP'
<?php

function drupilot_smoke(array $items): bool {
  return strpos('drupilot', 'pilot') !== FALSE && count($items) >= 0;
}
PHP
  cat > "$dir/rector.php" <<'PHP'
<?php

declare(strict_types=1);

use DrupalRector\Set\Drupal10SetList;
use Rector\Config\RectorConfig;

return RectorConfig::configure()
  ->withPaths([__DIR__ . '/smoke.php'])
  ->withSets([Drupal10SetList::DRUPAL_10])
  ->withPhpSets(php80: true);
PHP
  # `&& rc=0 || rc=$?` keeps a failing run from tripping the caller's `set -e`.
  # shellcheck disable=SC2086  # intentional word-split: runner is a command prefix.
  raw="$(cd "$r" && $runner vendor/bin/rector process --config "$rel/rector.php" --dry-run --no-progress-bar --clear-cache 2>&1)" \
    && rc=0 || rc=$?
  if ! rector_output_ok "$rc" "$raw"; then
    rm -rf "$dir" 2>/dev/null || true
    printf 'rector smoke dry-run failed (exit %s): %s' "$rc" "$(rector_error_excerpt "$raw")"
    return 1
  fi
  rm -rf "$dir" 2>/dev/null || true
  # shellcheck disable=SC2086  # intentional word-split: runner is a command prefix.
  raw="$(cd "$r" && $runner vendor/bin/phpstan --version 2>&1)" && rc=0 || rc=$?
  if [[ "$rc" != "0" ]] || ! printf '%s' "$raw" | grep_q 'PHPStan'; then
    printf 'phpstan --version failed (exit %s): %s' "$rc" "$(printf '%s\n' "$raw" | tail -n 5)"
    return 1
  fi
  return 0
}
