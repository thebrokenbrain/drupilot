#!/usr/bin/env bash
# The digests filter and verdict replay (T-M4-08, 03-R17, 05-R6): run-rector.sh
# --digests runs a filtered all.php: without the rules drupal-rector already
# implements (its implemented-digests.yml, cached and frozen in the lock;
# implemented with every class present in vendor/, or config-only) and
# without the rules rejected for this module (digests-decisions.json, keyed by
# rule, digests SHA and the subject's digest). The --json digests_review gives
# each rule's verdict; a second run on the same sources has nothing pending; a
# change of the sources asks again; a frozen yml that cannot be read again is
# a digests error; no yml and nothing frozen filters nothing; no rule left
# runs nothing. Docker-free and offline: a local digests checkout in the
# cache, a stub Rector that applies the rules of the config it is given.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
D="$T_TMP/data"; mkdir -p "$D/targets" "$D/php"
printf '%s\n' '{"major":10,"minors":{"10.0":{"verified":true,"php_supported":["8.1","8.2","8.3"]}}}' > "$D/targets/10.json"
printf '%s\n' '{"major":11,"minors":{"11.0":{"verified":true,"php_supported":["8.3"]},"11.3":{"verified":true,"php_supported":["8.3","8.4","8.5"]}}}' > "$D/targets/11.json"
printf '%s\n' '{"versions":{"7.4":{},"8.0":{},"8.1":{},"8.2":{},"8.3":{},"8.4":{},"8.5":{}}}' > "$D/php/versions.json"
export DRUPILOT_VERSION_DATA_DIR="$D"
mk_bin() { printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
STUBS="$T_TMP/stubs"; mkdir -p "$STUBS"
mk_bin "$STUBS/php" 'case "$1" in -r) echo 8.3.30;; -v) echo "PHP 8.3.30 (cli)";; -l) echo "No syntax errors detected in $2";; esac; exit 0'
mk_bin "$STUBS/composer" 'echo "Composer version 2.8.0 2025-01-01 00:00:00"; exit 0'

# The Drupal root, with drupal-rector 1.1.3 installed (one implemented class).
R="$T_TMP/root"; S=web/modules/custom/m
mkdir -p "$R/web/core/lib" "$R/$S/src" "$R/vendor/bin" "$R/vendor/palantirnet/drupal-rector/src/Rector"
printf '{"name":"x/root"}\n' > "$R/composer.json"
printf '{"packages":[],"packages-dev":[{"name":"palantirnet/drupal-rector","version":"1.1.3"}]}\n' > "$R/composer.lock"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$R/web/core/lib/Drupal.php"
printf '<?php\nnamespace DrupalRector\\Rector;\nfinal class ImplementedRector {}\n' > "$R/vendor/palantirnet/drupal-rector/src/Rector/ImplementedRector.php"
printf 'name: M\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$R/$S/m.info.yml"
printf '<?php\n\nnamespace Drupal\\m;\n\nclass A {\n}\n' > "$R/$S/src/A.php"
# The stub Rector: a config under .drupilot/digests/ applies each class of its
# withRules() to src/A.php; any other config changes nothing.
cat > "$R/vendor/bin/rector" <<'STUB'
#!/bin/sh
d="$(cd "$(dirname "$0")/../.." && pwd)"; echo "$*" >> "$d/calls"
cfg=""; dry=0; prev=""
for a in "$@"; do case "$a" in --dry-run) dry=1;; esac; [ "$prev" = "--config" ] && cfg="$a"; prev="$a"; done
case "$cfg" in
  *.drupilot/digests/*)
    rules="$(sed -n 's/.*->withRules(\[\(.*\)\]).*/\1/p' "$d/$cfg" | tr ',' '\n' | sed -e 's/::class//' -e 's/[[:space:]]//g' | grep . | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')"
    if [ -n "$rules" ]; then
      printf '{"totals":{"changed_files":1,"errors":0},"file_diffs":[{"file":"web/modules/custom/m/src/A.php","diff":"@@ -1,1 +1,1 @@\\n-a\\n+b\\n","applied_rectors":[%s]}],"changed_files":["web/modules/custom/m/src/A.php"]}\n' "$rules"
      [ "$dry" = 1 ] && exit 2; exit 0
    fi;;
esac
echo '{"totals":{"changed_files":0,"errors":0}}'; exit 0
STUB
chmod +x "$R/vendor/bin/rector"

# The digests checkout in the cache: four rules. 111 is implemented by
# drupal-rector (its class exists), 222 is config-only, 333 is marked
# implemented by a class drupal-rector does not ship, 444 is not listed.
DG="$(digests_cache_dir)"; mkdir -p "$DG/rector/rules"
for r in a-rule-111:ARuleRector b-rule-222:BRuleRector c-rule-333:CRuleRector d-rule-444:DRuleRector; do
  printf '<?php\n\ndeclare(strict_types=1);\n\nfinal class %s extends AbstractRector\n{\n}\n' "${r#*:}" > "$DG/rector/rules/${r%%:*}.php"
done
{
  printf '<?php\n\ndeclare(strict_types=1);\n\nuse Rector\\Config\\RectorConfig;\n\n'
  for f in a-rule-111 b-rule-222 c-rule-333 d-rule-444; do printf "require_once __DIR__ . '/rules/%s.php';\n" "$f"; done
  printf '\nreturn RectorConfig::configure()\n    ->withFileExtensions(['"'"'php'"'"', '"'"'module'"'"'])\n'
  printf '    ->withRules([ARuleRector::class, BRuleRector::class, CRuleRector::class, DRuleRector::class]);\n'
} > "$DG/rector/all.php"
git -C "$DG" init -q && git -C "$DG" add -A && git -C "$DG" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm digests
SHA="$(git -C "$DG" rev-parse HEAD)"
DRUPILOT_PROJECT_DIR="$R" lock_set .digests.sha "$SHA" > /dev/null; DRUPILOT_PROJECT_DIR="$R" lock_set .digests.ref main > /dev/null
YD="$(cache_dir)/drupal-rector/1.1.3"; mkdir -p "$YD"
cat > "$YD/implemented-digests.yml" <<'YML'
# fixture
digests:
  '111':
    status: implemented
    phase: '1a'
    class: ImplementedRector
    digest_file: a-rule-111.php
  '222':
    status: config-only
    phase: '2'
  '333':
    status: implemented
    phase: '?'
    class:
      - MissingRector
    note: 'Implemented in an open PR.'
YML

NONET="$(t_path_without curl wget)"
rr() { : > "$R/calls"; t_run env PATH="$STUBS:$NONET" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$R/$S" --digests --json "$@"; }
dd() { t_run env PATH="$STUBS:$NONET" "$T_SH" "$T_REPO/scripts/analysis/digests-decisions.sh" --subject "$R/$S" "$@"; }
j() { jq -c "$1" "$T_OUT" 2> /dev/null; }

rr
assert_eq "the filter: 111 implemented, 222 config-only, 333 kept (its class is not shipped), 444 kept" \
  "$T_RC|$(j '.digests_filter | [.skipped_implemented, .skipped_config_only, .rejected, .kept]')" '0|[["ARuleRector"],["BRuleRector"],[],2]'
assert_eq "  the yml frozen in the lock with its ref" \
  "$(j '.digests_filter.implemented_yml.ref')|$(DRUPILOT_PROJECT_DIR="$R" lock_get .digests.implemented_yml_sha256 "" | grep -c '^sha256:' || true)" '"1.1.3"|1'
assert_eq "  the filtered config loads and registers the kept rules only" \
  "$(grep -c 'require_once' "$R/.drupilot/digests/${SHA:0:16}/rector/all.drupilot.php")|$(grep -c 'CRuleRector::class, DRuleRector::class' "$R/.drupilot/digests/${SHA:0:16}/rector/all.drupilot.php")" "2|1"
assert_eq "the review: both rules pending" "$(j '.digests_review | [.digests_sha == "'"$SHA"'", [.rules[] | [.rule, .verdict]], .pending]')" \
  '[true,[["CRuleRector","pending"],["DRuleRector","pending"]],["CRuleRector","DRuleRector"]]'
assert_eq "  kept in the dry-run record" "$(jq -c '.digests_review.pending' "$(project_state_dir "$R/$S")/rector-dryrun.json")" '["CRuleRector","DRuleRector"]'

dd --list --json
assert_eq "digests-decisions --list: both pending" "$T_RC|$(j '.pending')" '0|["CRuleRector","DRuleRector"]'
dd --accept CRuleRector --reject DRuleRector --json
assert_eq "--accept / --reject: recorded" "$T_RC|$(j '[.rules[] | [.rule, .verdict]]')|$(j '.pending')" '0|[["CRuleRector","accept"],["DRuleRector","reject"]]|[]'
assert_eq "  in the hidden state dir, keyed by rule, SHA and the subject's digest" \
  "$(jq -c '[.decisions[] | [.rule, .verdict, (.digests_sha | length), (.input_hash | test("^(sha256:)?[0-9a-f]{64}$"))]]' "$(digests_decisions_file "$R/$S")")" \
  '[["CRuleRector","accept",40,true],["DRuleRector","reject",40,true]]'

rr
assert_eq "a second run on the same sources: the rejected rule is left out, nothing pending (no question)" \
  "$T_RC|$(j '[.digests_filter.rejected, .digests_filter.kept, .digests_review.pending, [.digests_review.rules[] | [.rule, .verdict]]]')" \
  '0|[["DRuleRector"],1,[],[["CRuleRector","accept"]]]'
rr --apply
assert_eq "--apply: only the accepted rule runs" "$T_RC|$(j '.rule_hits.digests | keys')" '0|["CRuleRector"]'

# The sources changed: the verdicts belong to the old ones.
printf '// changed\n' >> "$R/$S/src/A.php"
rr
assert_eq "changed sources: pending again" "$T_RC|$(j '.digests_review.pending')" '0|["CRuleRector","DRuleRector"]'
dd --reject CRuleRector,DRuleRector
rr
assert_eq "every rule rejected: no rule left, the pass does not run, status ok" \
  "$T_RC|$(j '[.digests_status, .digests_filter.kept]')|$(grep -c 'drupilot/digests' "$R/calls" || true)" '0|["ok",0]|0'

# A frozen yml that cannot be read again (changed in the cache, offline).
printf '  # edited\n' >> "$YD/implemented-digests.yml"
rr
assert_eq "the frozen yml changed and cannot be fetched again: a digests error, exit 4" \
  "$T_RC|$(j '[.status, .digests_status]')" '4|["partial","error"]'
# No yml at all and nothing frozen: no implemented filter, with a warning.
rm -f "$YD/implemented-digests.yml"
DRUPILOT_PROJECT_DIR="$R" lock_set_json .digests "{\"sha\": \"$SHA\", \"ref\": \"main\"}" > /dev/null
dd --clear
rr
assert_eq "no yml, nothing frozen: nothing skipped as implemented" \
  "$T_RC|$(j '.digests_filter | [.implemented_yml, .skipped_implemented, .skipped_config_only, .kept]')" '0|[null,[],[],4]'
assert_match "  with a warning" "$(tr '\n' ' ' < "$T_ERR")" "implemented-digests.yml is not available"

# /drupilot-clean forgets the verdicts of the modules of the root it cleans.
dd --reject CRuleRector > /dev/null 2>&1 || true
rr > /dev/null 2>&1 || true
dd --reject CRuleRector
state_set "$R/$S" .stage setup > /dev/null 2>&1 || true
testbed_mark "$R" > /dev/null 2>&1 || true
assert_eq "  (a verdict and a state.json before the clean)" "$([[ -f "$(digests_decisions_file "$R/$S")" && -f "$(subject_state_file "$R/$S")" ]] && echo yes)" "yes"
t_run env PATH="$STUBS:$NONET" "$T_SH" "$T_REPO/scripts/env/clean.sh" --root "$R" --level ddev --no-ddev --yes --json
assert_eq "clean.sh: the digests verdicts are forgotten, the state kept" \
  "$T_RC|$([[ -e "$(digests_decisions_file "$R/$S")" ]] && echo kept || echo removed)|$([[ -f "$(subject_state_file "$R/$S")" ]] && echo state)" "0|removed|state"

# The helpers on their own.
assert_eq "digests_rules: file, class and nid of each registered rule" \
  "$(digests_rules "$DG/rector" | awk -F'\t' '{ printf "%s:%s ", $2, $3 }')" "ARuleRector:111 BRuleRector:222 CRuleRector:333 DRuleRector:444 "
printf 'digests:\n  '"'"'9'"'"':\n    status: implemented\n    class: ImplementedRector\n' > "$T_TMP/y.yml"
assert_eq "digests_implemented_skips: implemented with its class present" "$(digests_implemented_skips "$T_TMP/y.yml" "$R")" "$(printf '9\timplemented')"
assert_eq "  not without drupal-rector installed" "$(digests_implemented_skips "$T_TMP/y.yml" "$T_TMP/none")" ""

# Usage errors.
dd --accept NoSuchRector
assert_eq "a rule the last dry-run did not name: exit 1" "$T_RC" "1"
dd
assert_eq "no verdict to record: exit 1" "$T_RC" "1"
mkdir -p "$T_TMP/other"
t_run "$T_SH" "$T_REPO/scripts/analysis/digests-decisions.sh" --subject "$T_TMP/other" --list
assert_eq "no digests dry-run for the subject: exit 1" "$T_RC" "1"
dd --bogus
assert_eq "an unknown flag: exit 1" "$T_RC" "1"
t_done
