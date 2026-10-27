#!/usr/bin/env bash
# rector_applied_rules (common.sh): the rules a Rector run applied are the
# " * SomeRector" lines of its "Applied rules:" blocks only. Rector 2.6.1 also
# bullets the rule of a "[WARNING] This skipped rule is never registered"
# notice (the template skips NullToStrictStringFuncCallArgRector, which its
# php81 set no longer lists): that rule never ran and must not reach
# run-rector.sh's rules / rule_hits (spikes AR-38, AR-40, AR-42). The output
# below is a real 2.6.1 dry-run on legacy_widgets (lab, M2).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
RAW='1 file with changes
===================

1) web/modules/custom/legacy_widgets/src/Form/WidgetImportForm.php:58

    ---------- begin diff ----------
@@ @@
-    $names = array_map('"'"'trim'"'"', $names);
+    $names = array_map(trim(...), $names);
    ----------- end diff -----------

Applied rules:
 * FunctionFirstClassCallableRector


 [OK] 1 file would have been changed (dry-run) by Rector

 [WARNING] This skipped rule is never registered. You can remove it from
           "->withSkip()"

 * Rector\Php81\Rector\FuncCall\NullToStrictStringFuncCallArgRector'
assert_eq "only the applied rule" "$(rector_applied_rules "$RAW")" "FunctionFirstClassCallableRector"
TWO="$(printf '%s\n\nApplied rules:\n * ExplicitNullableParamTypeRector\n * FunctionFirstClassCallableRector\n' "$RAW")"
assert_eq "one line per changed file and rule" "$(rector_applied_rules "$TWO" | sort | uniq -c | awk '{print $2 ":" $1}' | paste -sd' ' -)" \
  "ExplicitNullableParamTypeRector:1 FunctionFirstClassCallableRector:2"
assert_eq "no Applied rules block: nothing" "$(rector_applied_rules ' [OK] Rector is done!')" ""
assert_eq "empty input: nothing" "$(rector_applied_rules '')" ""
t_done
