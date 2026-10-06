#!/usr/bin/env bash
# The digests filter and verdict replay (T-M4-08, 03-R17, 05-R6, ADR 0026):
# run-rector.sh --digests runs a filtered all.php: without the rules the
# official pass already applies (drupal-rector's implemented-digests.yml,
# cached and frozen in the lock: an entry whose classes are all registered in
# a set rector.php loads, nested sets and includes followed; an entry in a set
# it does not load, and a config-only one, are kept) and without the rules
# rejected for this module (digests-decisions.json, keyed by rule, digests SHA
# and the subject's digest). The --json digests_review gives each rule's
# verdict; a second run on the same sources has nothing pending; a change of
# the sources asks again, and an --apply on them refuses the digests pass; an
# autonomous run's verdicts are replayed only by an autonomous run; a frozen
# yml that cannot be read again is a digests error, and DRUPILOT_DETERMINISTIC
# =false fetches it again; an all.php drupilot cannot read whole is a digests
# error; no yml and nothing frozen filters nothing; no rule left runs nothing.
# Docker-free and offline: a local digests checkout in the cache, a stub
# Rector that applies the rules of the config it is given, a stub curl.
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

# The Drupal root, with drupal-rector 1.1.3 installed: its Drupal 10 sets
# register ImplementedRector (DRUPAL_100) and, through an include of
# DRUPAL_103, OtherLoadedRector; its Drupal 11 set registers ElevenRector.
R="$T_TMP/root"; S=web/modules/custom/m; V="$R/vendor/palantirnet/drupal-rector"
mkdir -p "$R/web/core/lib" "$R/$S/src" "$R/vendor/bin" "$V/src/Set" "$V/config/drupal-10" "$V/config/drupal-11"
printf '{"name":"x/root"}\n' > "$R/composer.json"
printf '{"packages":[],"packages-dev":[{"name":"palantirnet/drupal-rector","version":"1.1.3"}]}\n' > "$R/composer.lock"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$R/web/core/lib/Drupal.php"
printf "<?php\nnamespace DrupalRector\\\\Set;\nfinal class Drupal10SetList\n{\n    public const DRUPAL_100 = __DIR__.'/../../config/drupal-10/drupal-10.0-deprecations.php';\n    public const DRUPAL_103 = __DIR__ . '/../../config/drupal-10/drupal-10.3-deprecations.php';\n}\n" > "$V/src/Set/Drupal10SetList.php"
printf "<?php\nnamespace DrupalRector\\\\Set;\nfinal class Drupal11SetList\n{\n    public const DRUPAL_110 = __DIR__.'/../../config/drupal-11/drupal-11.0-deprecations.php';\n}\n" > "$V/src/Set/Drupal11SetList.php"
printf '<?php\nreturn static function (RectorConfig $c): void {\n    // ElevenRector::class is only named in this comment.\n    $c->rule(ImplementedRector::class);\n};\n' > "$V/config/drupal-10/drupal-10.0-deprecations.php"
printf "<?php\nreturn static function (RectorConfig \$c): void {\n    \$c->import(__DIR__ . '/shared.php');\n};\n" > "$V/config/drupal-10/drupal-10.3-deprecations.php"
printf '<?php\nreturn static function (RectorConfig $c): void {\n    $c->ruleWithConfiguration(OtherLoadedRector::class, []);\n};\n' > "$V/config/drupal-10/shared.php"
printf '<?php\nreturn static function (RectorConfig $c): void {\n    $c->rule(ElevenRector::class);\n};\n' > "$V/config/drupal-11/drupal-11.0-deprecations.php"
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
    [ -f "$d/nohits" ] && { echo '{"totals":{"changed_files":0,"errors":0}}'; exit 0; }
    rules="$(sed -n 's/.*->withRules(\[\(.*\)\]).*/\1/p' "$d/$cfg" | tr ',' '\n' | sed -e 's/::class//' -e 's/[[:space:]]//g' | grep . | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')"
    if [ -n "$rules" ]; then
      printf '{"totals":{"changed_files":1,"errors":0},"file_diffs":[{"file":"web/modules/custom/m/src/A.php","diff":"@@ -1,1 +1,1 @@\\n-a\\n+b\\n","applied_rectors":[%s]}],"changed_files":["web/modules/custom/m/src/A.php"]}\n' "$rules"
      [ "$dry" = 1 ] && exit 2; exit 0
    fi;;
esac
echo '{"totals":{"changed_files":0,"errors":0}}'; exit 0
STUB
chmod +x "$R/vendor/bin/rector"
# The developer's own rector.php (left untouched): the Drupal 10 sets, one as
# a quoted name (as drupilot renders them), one as a constant.
cat > "$R/rector.php" <<'PHP'
<?php

declare(strict_types=1);

use Rector\Config\RectorConfig;

// Drupal11SetList::DRUPAL_110 is only named in this comment.
/* Not yet:
   'DrupalRector\\Set\\Drupal11SetList::DRUPAL_110',
*/
return RectorConfig::configure()
  ->withPaths([__DIR__ . '/web/modules/custom/m'])
  ->withSkip([ArrayToFirstClassCallableRector::class])
  ->withPhpVersion(80100)
  ->withSets(['DrupalRector\\Set\\Drupal10SetList::DRUPAL_100', \DrupalRector\Set\Drupal10SetList::DRUPAL_103]);
PHP

# The digests checkout in the cache: six rules. 111 is implemented by a class
# a loaded set registers; 222 is config-only; 333 names a class drupal-rector
# does not ship; 444 is not listed; 555 needs ElevenRector too (a Drupal 11
# set: not loaded on a port to 11); 666 needs two classes the loaded sets
# register (one through the include). withRules spans lines, with a FQCN; a
# code sample's class comes after the rule's.
DG="$(digests_cache_dir)"; mkdir -p "$DG/rector/rules"
for r in a-rule-111:ARuleRector b-rule-222:BRuleRector c-rule-333:CRuleRector d-rule-444:DRuleRector e-rule-555:ERuleRector f-rule-666:FRuleRector; do
  printf '<?php\n\ndeclare(strict_types=1);\n\nfinal readonly class %s extends AbstractRector\n{\n}\n<<<CODE\nclass MyClass {}\nCODE;\n' "${r#*:}" > "$DG/rector/rules/${r%%:*}.php"
done
mkall() {  # mkall [EXTRA-DIRECTIVE]: all.php registering the six rules
  {
    printf '<?php\n\ndeclare(strict_types=1);\n\nuse Rector\\Config\\RectorConfig;\n\n// rules/not-a-rule-1.php is a comment.\n'
    for f in a-rule-111 b-rule-222 c-rule-333 d-rule-444 e-rule-555 f-rule-666; do printf "require_once __DIR__ . '/rules/%s.php';\n" "$f"; done
    printf '\nreturn RectorConfig::configure()\n    ->withFileExtensions([\n        '"'"'php'"'"', '"'"'module'"'"'])\n'
    [[ -z "${1:-}" ]] || printf '    %s\n' "$1"
    printf '    ->withRules([ARuleRector::class, BRuleRector::class,\n        CRuleRector::class, \\DRuleRector::class, ERuleRector::class, FRuleRector::class]);\n'
  } > "$DG/rector/all.php"
}
mkall
git -C "$DG" init -q && git -C "$DG" add -A && git -C "$DG" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm digests
SHA="$(git -C "$DG" rev-parse HEAD)"
DRUPILOT_PROJECT_DIR="$R" lock_set .digests.sha "$SHA" > /dev/null; DRUPILOT_PROJECT_DIR="$R" lock_set .digests.ref main > /dev/null
YD="$(cache_dir)/drupal-rector/1.1.3"; mkdir -p "$YD"
cat > "$T_TMP/upstream.yml" <<'YML'
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
  '555':
    status: implemented
    class: [ElevenRector, ImplementedRector]
  '666':
    status: implemented
    class: [ImplementedRector, OtherLoadedRector]
YML
cp "$T_TMP/upstream.yml" "$YD/implemented-digests.yml"
# A stub curl that serves $UPSTREAM_YML (exit 22 when it is not there).
CURLD="$T_TMP/curl"; mkdir -p "$CURLD"
mk_bin "$CURLD/curl" 'out=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done; [ -f "$UPSTREAM_YML" ] || exit 22; cp "$UPSTREAM_YML" "$out"'

NONET="$(t_path_without curl wget)"
rr() { : > "$R/calls"; t_run env PATH="$STUBS:$NONET" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$R/$S" --digests --json "$@"; }
dd() { t_run env PATH="$STUBS:$NONET" "$T_SH" "$T_REPO/scripts/analysis/digests-decisions.sh" --subject "$R/$S" "$@"; }
j() { jq -c "$1" "$T_OUT" 2> /dev/null; }
ADIR="$R/.drupilot/digests/${SHA:0:16}/rector"

rr
assert_eq "the filter: 111 and 666 applied by the loaded sets; 555 needs a Drupal 11 set, 333 a class not shipped, 222 is config-only: kept" \
  "$T_RC|$(j '.digests_filter | [.skipped_implemented, .implemented_not_loaded, .config_only, .rejected, .kept]')" \
  '0|[["ARuleRector","FRuleRector"],["CRuleRector","ERuleRector"],["BRuleRector"],[],4]'
assert_eq "  the yml frozen in the lock with its ref" \
  "$(j '.digests_filter.implemented_yml.ref')|$(DRUPILOT_PROJECT_DIR="$R" lock_get .digests.implemented_yml_sha256 "" | grep -c '^sha256:' || true)" '"1.1.3"|1'
assert_eq "  the filtered config loads and registers the kept rules only, with all.php's file extensions" \
  "$(grep -c 'require_once' "$ADIR/all.drupilot.php")|$(grep -c 'BRuleRector::class, CRuleRector::class, DRuleRector::class, ERuleRector::class' "$ADIR/all.drupilot.php")|$(grep -c "withFileExtensions(\[ *'php', 'module'\])" "$ADIR/all.drupilot.php")" "4|1|1"
assert_eq "the review: the four kept rules pending" "$(j '.digests_review | [.digests_sha == "'"$SHA"'", .pending]')" \
  '[true,["BRuleRector","CRuleRector","DRuleRector","ERuleRector"]]'
assert_eq "  kept in the dry-run record, with the ruleset" \
  "$(jq -c '[(.digests_review.pending | length), .digests_ruleset]' "$(project_state_dir "$R/$S")/rector-dryrun.json")" '[4,["BRuleRector","CRuleRector","DRuleRector","ERuleRector"]]'

dd --list --json
assert_eq "digests-decisions --list: all pending" "$T_RC|$(j '.pending | length')" '0|4'
dd --accept BRuleRector,CRuleRector,ERuleRector --reject DRuleRector --json
assert_eq "--accept / --reject: recorded by the developer" "$T_RC|$(j '[.rules[] | [.rule, .verdict, .by]]')|$(j '.pending')" \
  '0|[["BRuleRector","accept","developer"],["CRuleRector","accept","developer"],["DRuleRector","reject","developer"],["ERuleRector","accept","developer"]]|[]'
assert_eq "  in the hidden state dir, keyed by rule, SHA and the subject's digest" \
  "$(jq -c '[.decisions[] | [.rule, .verdict, (.digests_sha | length), (.input_hash | test("^(sha256:)?[0-9a-f]{64}$"))]] | .[2]' "$(digests_decisions_file "$R/$S")")" \
  '["DRuleRector","reject",40,true]'
rr --apply
assert_eq "--apply right after the verdicts (no new dry-run): the rejected rule left out, no false 'changed none' error" \
  "$T_RC|$(j '.rule_hits.digests | keys')|$(j '.digests_status')" '0|["BRuleRector","CRuleRector","ERuleRector"]|"ok"'
git -C "$R" init -q 2> /dev/null || true
printf '<?php\n\nnamespace Drupal\\m;\n\nclass A {\n}\n' > "$R/$S/src/A.php"
rr
assert_eq "a second run on the same sources: the rejected rule is left out, nothing pending (no question)" \
  "$T_RC|$(j '[.digests_filter.rejected, .digests_filter.kept, .digests_review.pending]')" '0|[["DRuleRector"],3,[]]'
# A verdict for another digests SHA does not filter.
jq '.decisions |= map(.digests_sha = "0000000000000000000000000000000000000000")' "$(digests_decisions_file "$R/$S")" > "$T_TMP/dd.json"
cp "$(digests_decisions_file "$R/$S")" "$T_TMP/dd-keep.json"; cp "$T_TMP/dd.json" "$(digests_decisions_file "$R/$S")"
rr
assert_eq "  a verdict of another digests SHA: pending again, nothing filtered" "$T_RC|$(j '[.digests_filter.rejected, (.digests_review.pending | length)]')" '0|[[],4]'
cp "$T_TMP/dd-keep.json" "$(digests_decisions_file "$R/$S")"

# The sources changed: the verdicts belong to the old ones.
printf '// changed\n' >> "$R/$S/src/A.php"
rr --apply
assert_eq "an --apply on sources changed since the review: no digests pass (exit 4), the rejected rule not run" \
  "$T_RC|$(j '[.status, .digests_status, .digests_review]')|$(grep -c 'drupilot/digests' "$R/calls" || true)" '4|["partial","error",null]|0'
assert_match "  it says to run the dry-run again" "$(tr '\n' ' ' < "$T_ERR")" "No digests dry-run of these sources finished.*Run the dry-run again"
rr
assert_eq "changed sources: pending again" "$T_RC|$(j '.digests_review.pending | length')" '0|4'
printf '// changed again\n' >> "$R/$S/src/A.php"
dd --reject DRuleRector
assert_eq "digests-decisions on sources changed since the dry-run: exit 1" "$T_RC" "1"
rr > /dev/null
# An autonomous run's verdicts: replayed by an autonomous run only.
t_run env PATH="$STUBS:$NONET" DRUPILOT_AUTONOMOUS=true "$T_SH" "$T_REPO/scripts/analysis/digests-decisions.sh" --subject "$R/$S" --accept BRuleRector,CRuleRector,ERuleRector --reject DRuleRector --json
assert_eq "an autonomous run records its defaults by auto" "$T_RC|$(j '[.rules[].by] | unique')" '0|["auto"]'
rr
assert_eq "  a guided run asks again (nothing replayed, nothing filtered)" "$T_RC|$(j '[.digests_filter.rejected, (.digests_review.pending | length)]')" '0|[[],4]'
rr_auto() { : > "$R/calls"; t_run env PATH="$STUBS:$NONET" DRUPILOT_PHP_TARGET=8.3 DRUPILOT_AUTONOMOUS=true "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$R/$S" --digests --json; }
rr_auto
assert_eq "  an autonomous run replays them" "$T_RC|$(j '[.digests_filter.rejected, .digests_review.pending]')" '0|[["DRuleRector"],[]]'
rr --auto
assert_eq "  so does run-rector.sh --auto" "$T_RC|$(j '[.digests_filter.rejected, .digests_review.pending]')" '0|[["DRuleRector"],[]]'
dd --clear; rr > /dev/null
t_run env PATH="$STUBS:$NONET" DRUPILOT_AUTONOMOUS=1 "$T_SH" "$T_REPO/scripts/analysis/digests-decisions.sh" --subject "$R/$S" --reject DRuleRector --json
assert_eq "DRUPILOT_AUTONOMOUS=1 records by auto too" "$T_RC|$(j '[.rules[] | select(.verdict != "pending") | .by] | unique')" '0|["auto"]'
dd --clear; rr > /dev/null
dd --reject DRuleRector --auto --json
assert_eq "  and so does --auto" "$T_RC|$(j '[.rules[] | select(.verdict != "pending") | .by] | unique')" '0|["auto"]'
dd --clear; rr > /dev/null
# Once there are verdicts, an --apply needs the last dry-run to be of these
# sources and these rules, with a verdict on every rule it changed files with.
dd --accept BRuleRector
rr --apply
assert_eq "an --apply with rules the dry-run changed files with and no verdict: refused (exit 4)" \
  "$T_RC|$(j '.digests_status')|$(grep -c 'drupilot/digests' "$R/calls" || true)" '4|"error"|0'
assert_match "  it names them" "$(tr '\n' ' ' < "$T_ERR")" "no verdict \(CRuleRector,DRuleRector,ERuleRector\)"
dd --accept CRuleRector,ERuleRector --reject DRuleRector
rr --apply
assert_eq "  every rule decided: applied" "$T_RC|$(j '.rule_hits.digests | keys')" '0|["BRuleRector","CRuleRector","ERuleRector"]'
# A re-port of the ported sources where no digests rule changes anything any
# more: the dry-run has nothing to review, and the apply is not refused.
touch "$R/nohits"
rr
assert_eq "a re-port with nothing left: the dry-run reviews nothing" "$T_RC|$(j '.digests_review | [.rules, .pending]')" '0|[[],[]]'
rr --apply
assert_eq "  and the apply runs (no dead end)" "$T_RC|$(j '.digests_status')" '0|"ok"'
rm -f "$R/nohits"
# The digests rules moved upstream between the dry-run and the apply
# (DRUPILOT_DETERMINISTIC=false resolves main again): refused.
rr > /dev/null; dd --accept BRuleRector,CRuleRector,ERuleRector --reject DRuleRector
printf '// upstream moved\n' >> "$DG/rector/rules/b-rule-222.php"
git -C "$DG" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qam moved
: > "$R/calls"; t_run env PATH="$STUBS:$NONET" DRUPILOT_PHP_TARGET=8.3 DRUPILOT_DETERMINISTIC=false "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$R/$S" --digests --json --apply
assert_eq "the digests rules moved since the dry-run: refused, the rejected rule not run" \
  "$T_RC|$(j '[.digests_status, (.rule_hits.digests // {} | has("DRuleRector"))]')" '4|["error",false]'
assert_match "  it says the rules changed" "$(tr '\n' ' ' < "$T_ERR")" "The digests rules changed since the last dry-run"
git -C "$DG" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false reset -q --hard "$SHA"
DRUPILOT_PROJECT_DIR="$R" lock_set .digests.sha "$SHA" > /dev/null
# A damaged decisions file never stops a run.
printf '{"decisions": [1, "x"]}\n' > "$(digests_decisions_file "$R/$S")"
rr
assert_eq "a damaged decisions file: ignored, every rule pending" "$T_RC|$(j '.digests_review.pending | length')" '0|4'
dd --clear
dd --reject BRuleRector,CRuleRector,DRuleRector,ERuleRector
rr
assert_eq "every rule rejected: no rule left, the pass does not run, status ok" \
  "$T_RC|$(j '[.digests_status, .digests_filter.kept]')|$(grep -c 'drupilot/digests' "$R/calls" || true)" '0|["ok",0]|0'

# all.php drupilot cannot read whole: a digests error, never a silent drop.
mkall '->withSkip([BRuleRector::class])'
git -C "$DG" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qam skip
DRUPILOT_PROJECT_DIR="$R" lock_set .digests.sha "$(git -C "$DG" rev-parse HEAD)" > /dev/null
rr
assert_eq "an all.php directive drupilot does not keep: a digests error, exit 4" "$T_RC|$(j '[.digests_status, .digests_review]')" '4|["error",null]'
assert_match "  it names the directive" "$(tr '\n' ' ' < "$T_ERR")" "->withSkip"
mkall
printf '<?php\nfinal class NotRegisteredRector {}\n' > "$DG/rector/rules/d-rule-444.php"
git -C "$DG" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qam unregistered
DRUPILOT_PROJECT_DIR="$R" lock_set .digests.sha "$(git -C "$DG" rev-parse HEAD)" > /dev/null
rr
assert_eq "a rule file whose class all.php does not register: a digests error" "$T_RC|$(j '.digests_status')" '4|"error"'
assert_match "  it names the file" "$(tr '\n' ' ' < "$T_ERR")" "rules/d-rule-444.php"
assert_match "  and the registered class without one" "$(tr '\n' ' ' < "$T_ERR")" "DRuleRector \(no rule file\)"
git -C "$DG" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false revert -q --no-edit HEAD HEAD~1 > /dev/null 2>&1 || true
DRUPILOT_PROJECT_DIR="$R" lock_set .digests.sha "$SHA" > /dev/null

# The yml: a cached copy that is not the frozen one is fetched again.
printf '  # edited\n' >> "$YD/implemented-digests.yml"
: > "$R/calls"; t_run env PATH="$CURLD:$STUBS:$NONET" UPSTREAM_YML="$T_TMP/upstream.yml" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$R/$S" --digests --json
assert_eq "an edited cached yml is fetched again (same as the frozen one): no error" "$T_RC|$(cmp -s "$YD/implemented-digests.yml" "$T_TMP/upstream.yml" && echo same)" "0|same"
# Changed upstream: deterministic, a digests error; DRUPILOT_DETERMINISTIC=false
# fetches it and freezes its new hash.
printf '  # upstream moved\n' >> "$T_TMP/upstream.yml"; printf '  # edited\n' >> "$YD/implemented-digests.yml"
: > "$R/calls"; t_run env PATH="$CURLD:$STUBS:$NONET" UPSTREAM_YML="$T_TMP/upstream.yml" DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$R/$S" --digests --json
assert_eq "the frozen yml changed upstream: a digests error, exit 4, no review" \
  "$T_RC|$(j '[.status, .digests_status, .digests_review]')" '4|["partial","error",null]'
assert_match "  the remedy names DRUPILOT_DETERMINISTIC=false and lock-sync.sh --refresh" "$(tr '\n' ' ' < "$T_ERR")" "DRUPILOT_DETERMINISTIC=false, or lock-sync.sh --refresh"
OLDH="$(DRUPILOT_PROJECT_DIR="$R" lock_get .digests.implemented_yml_sha256 "")"
: > "$R/calls"; t_run env PATH="$CURLD:$STUBS:$NONET" UPSTREAM_YML="$T_TMP/upstream.yml" DRUPILOT_DETERMINISTIC=false DRUPILOT_PHP_TARGET=8.3 "$T_SH" "$T_REPO/scripts/analysis/run-rector.sh" --subject "$R/$S" --digests --json
assert_eq "  DRUPILOT_DETERMINISTIC=false: fetched again, the new hash frozen, the filter applied" \
  "$T_RC|$([[ "$(DRUPILOT_PROJECT_DIR="$R" lock_get .digests.implemented_yml_sha256 "")" == "$(file_hash "$T_TMP/upstream.yml")" && "$OLDH" != "$(file_hash "$T_TMP/upstream.yml")" ]] && echo refreshed)|$(j '.digests_filter.skipped_implemented')" \
  '0|refreshed|["ARuleRector","FRuleRector"]'
# Offline, the cached copy edited: a digests error.
printf '  # edited\n' >> "$YD/implemented-digests.yml"
rr
assert_eq "the frozen yml changed in the cache, offline: a digests error, exit 4" "$T_RC|$(j '[.status, .digests_status]')" '4|["partial","error"]'
# No yml at all and nothing frozen: no implemented filter, with a warning.
rm -f "$YD/implemented-digests.yml"
DRUPILOT_PROJECT_DIR="$R" lock_set_json .digests "{\"sha\": \"$SHA\", \"ref\": \"main\"}" > /dev/null
dd --clear
rr
assert_eq "no yml, nothing frozen: nothing skipped as implemented" \
  "$T_RC|$(j '.digests_filter | [.implemented_yml, .skipped_implemented, .config_only, .kept]')" '0|[null,[],[],6]'
assert_match "  with a warning" "$(tr '\n' ' ' < "$T_ERR")" "implemented-digests.yml is not available"

# /drupilot-clean forgets the verdicts of the modules of the root it cleans.
dd --reject CRuleRector
state_set "$R/$S" .stage setup > /dev/null 2>&1 || true
testbed_mark "$R" > /dev/null 2>&1 || true
assert_eq "  (a verdict and a state.json before the clean)" "$([[ -f "$(digests_decisions_file "$R/$S")" && -f "$(subject_state_file "$R/$S")" ]] && echo yes)" "yes"
t_run env PATH="$STUBS:$NONET" "$T_SH" "$T_REPO/scripts/env/clean.sh" --root "$R" --level ddev --no-ddev --yes --json
assert_eq "clean.sh: the digests verdicts are forgotten, the state kept" \
  "$T_RC|$([[ -e "$(digests_decisions_file "$R/$S")" ]] && echo kept || echo removed)|$([[ -f "$(subject_state_file "$R/$S")" ]] && echo state)" "0|removed|state"

# The helpers on their own.
assert_eq "digests_rules: file, registered class and nid of each rule (not the code sample's class)" \
  "$(digests_rules "$DG/rector" | awk -F'\t' '{ printf "%s:%s ", $2, $3 }')" "ARuleRector:111 BRuleRector:222 CRuleRector:333 DRuleRector:444 ERuleRector:555 FRuleRector:666 "
assert_eq "digests_official_classes: the classes of the sets rector.php loads, nested includes followed, comments left out" \
  "$(digests_official_classes "$R" "$R/rector.php" | tr '\n' ' ')" "ImplementedRector OtherLoadedRector "
printf 'digests:\n  '"'"'9'"'"':\n    status: implemented\n    class: [ImplementedRector, OtherLoadedRector]\n  '"'"'8'"'"':\n    status: implemented\n    class: [ImplementedRector, ElevenRector]\n' > "$T_TMP/y.yml"
digests_official_classes "$R" "$R/rector.php" > "$T_TMP/off.txt"
assert_eq "digests_implemented_skips: a flow list, every class loaded / one not loaded" \
  "$(digests_implemented_skips "$T_TMP/y.yml" "$T_TMP/off.txt" | tr '\t\n' ': ')" "9:implemented 8:implemented-not-loaded "
assert_eq "  nothing loaded without drupal-rector installed" "$(digests_official_classes "$T_TMP/none" "$R/rector.php")" ""

# Usage errors.
rr > /dev/null
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
