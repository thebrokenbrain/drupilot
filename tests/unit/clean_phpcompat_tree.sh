#!/usr/bin/env bash
# clean.sh and PHPCompatibility's own Composer tree (T-M5-05, ADR 0003) on a
# marked test-bed without DDEV: --level vendor plans and removes
# .drupilot/phpcompat/vendor (its composer.json stays, the next run
# reinstalls); --level workspace rescues the .drupilot/ reports with neither
# the phpcompat/ tree nor the cores/ cache, then removes the root.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"

R="$T_TMP/bed"
mkdir -p "$R/web/core/lib" "$R/vendor/x" "$R/.drupilot/phpcompat/vendor/bin" "$R/.drupilot/cores/c"
printf '{"name":"x/root"}\n' > "$R/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$R/web/core/lib/Drupal.php"
printf '{"drupilot_testbed":{"created_by":"drupilot"}}\n' > "$R/.drupilot.json"
printf 'report\n' > "$R/.drupilot/port-report.md"
printf 'stub\n' > "$R/.drupilot/phpcompat/vendor/bin/phpcs"
printf '{}\n' > "$R/.drupilot/phpcompat/composer.json"
printf 'core\n' > "$R/.drupilot/cores/c/x"
cl() { t_run "$T_SH" "$T_REPO/scripts/env/clean.sh" --root "$R" --no-ddev --json "$@"; }

cl --level vendor --dry-run
assert_eq "vendor, dry run: the tree's vendor/ is planned" \
  "$T_RC|$(jq -c '[.roots[0].actions[] | select(.path | endswith("/.drupilot/phpcompat/vendor")) | [.op, .detail]]' "$T_OUT")" \
  '0|[["rm","composer-managed"]]'
assert_eq "  nothing removed yet" "$([[ -d "$R/.drupilot/phpcompat/vendor" ]] && echo kept)" "kept"
cl --level vendor --yes
assert_eq "vendor: the tree's vendor/ removed, its composer.json kept" \
  "$T_RC|$([[ -e "$R/.drupilot/phpcompat/vendor" ]] && echo still || echo gone)|$([[ -f "$R/.drupilot/phpcompat/composer.json" ]] && echo kept)" \
  "0|gone|kept"
mkdir -p "$R/.drupilot/phpcompat/vendor/bin"; printf 'stub\n' > "$R/.drupilot/phpcompat/vendor/bin/phpcs"
cl --level workspace --yes
D="$(jq -r '.roots[0].actions[] | select(.op == "rescue-reports") | .detail' "$T_OUT")"
assert_eq "workspace: the root removed, the reports rescued" \
  "$T_RC|$([[ -e "$R" ]] && echo still || echo gone)|$([[ -f "$D/port-report.md" ]] && echo rescued)" "0|gone|rescued"
assert_eq "  neither the phpcompat/ tree nor the cores/ cache copied" \
  "$([[ -e "$D/phpcompat" ]] && echo tree)$([[ -e "$D/cores" ]] && echo cores)" ""
t_done
