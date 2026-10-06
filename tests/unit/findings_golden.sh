#!/usr/bin/env bash
# The findings goldens (T-M4-05, ADR 0022): normalize-findings.sh, run on the
# raw reports recorded in the lab (tests/golden/findings/<case>/raw/), gives
# each case's findings.json byte for byte outside meta.generated_at, on the
# data snapshot the golden pins, with the target major and the soft policy
# the golden records. Plus a few facts the fixtures' EXPECTED files name, so a
# re-recording that loses them fails here too (the port-safety one is the
# fixture's class-name case hazard).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
G="$T_REPO/tests/golden/findings"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$G/golden.json")"
export DRUPILOT_VERSION_DATA_DIR

n=0
for d in "$G"/*/; do
  c="$(basename "$d")"; n=$((n + 1))
  want="$d/findings.json"
  t_run "$T_SH" "$T_REPO/scripts/ai/normalize-findings.sh" --raw-dir "$d/raw" \
    --target-major "$(jq -r '.target.major' "$want")" --soft-policy "$(jq -r '.target.soft_policy' "$want")" --json
  assert_eq "$c: exit 0" "$T_RC" "0"
  jq 'del(.meta.generated_at)' "$T_OUT" | canon_json > "$T_TMP/$c.json"
  assert_file_eq "$c: findings.json, byte for byte outside meta.generated_at" "$T_TMP/$c.json" "$want"
  assert_eq "$c: the raw hashes are the raw files' (outside their meta)" \
    "$(jq -c '.meta.raw' "$want")" \
    "$(for f in "$d"/raw/*.json; do printf '%s\t%s\n' "$(basename "$f")" "$(canon_json_hashable < "$f" | json_hash)"; done \
       | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries')"
done
assert_eq "three cases" "$n" "3"

f() { jq -c "$2" "$G/$1/findings.json"; }
assert_eq "legacy_widgets: 57 findings, 8 soft deprecations for the next major" \
  "$(f legacy_widgets '[.counts.total, .counts.next_major, ([.findings[] | select(.class == "soft")] | length)]')" '[57,8,8]'
assert_eq "  the port-safety error: the class-name case at legacy_widgets.services.yml:9" \
  "$(f legacy_widgets '[.findings[] | select(.class == "safety" and .severity == "error") | [.rule, .file, .line]]')" '[["port-safety:class-case","legacy_widgets.services.yml",9]]'
assert_eq "  every Rector and PHPStan finding has a class, method or function anchor (only catalog findings on YAML or top-level lines are {file})" \
  "$(f legacy_widgets '[([.findings[] | select(.tool != "catalog" and .anchor == "{file}")] | length), ([.findings[] | select(.anchor == "{file}")] | length)]')" "[0,11]"
assert_eq "acme_core: no metadata finding (the clean control)" "$(f acme_core '[.findings[] | select(.class == "metadata")] | length')" "0"
assert_eq "acme_api: services-arity at acme_api.services.yml:3 and the undeclared acme_core" \
  "$(f acme_api '[.findings[] | select(.class == "metadata") | [.rule, .file, .line]] | sort')" \
  '[["metadata:services-arity","acme_api.services.yml",3],["metadata:undeclared-deps","src/Controller/StatusController.php",5]]'
t_done
