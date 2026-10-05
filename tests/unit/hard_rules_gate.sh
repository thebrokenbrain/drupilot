#!/usr/bin/env bash
# The hard-rules gate (alias no-version-literals) and the scripts gate of
# scripts/dev/check.sh (T-M3-12, AR-22), on a scratch copy of the tree they
# read: green on HEAD, red on each injected fault (a hard-rule hit in a
# script, a template or a prompt; a new version literal in a script; a new
# script that ignores an unknown flag, has no help or sources common.sh at the
# wrong depth); a script's comment line is not a hit, and an allow-list row
# admits its rule for its path only.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
r="$T_TMP/tree"
mkdir -p "$r/tests/contract"
for d in scripts hooks templates commands skills agents config; do cp -R "$T_REPO/$d" "$r/"; done
cp "$T_REPO/tests/contract/hard-rules-allow.txt" "$r/tests/contract/"
# gate NAME -> "<status>|<number of findings>|<first finding>"
gate() {
  "$T_SH" "$r/scripts/dev/check.sh" --only "$1" --json 2> /dev/null \
    | jq -r '.gates[0] | "\(.status)|\(.findings | length)|\(.findings[0] // "")"'
}
assert_match "hard-rules: green on HEAD" "$(gate hard-rules)" '^pass\|0\|'
assert_match "  the no-version-literals alias runs it" "$(gate no-version-literals)" '^pass\|0\|'

# fault FILE LINE RULE -> the gate goes red with RULE first, then FILE is restored.
fault() {
  local f="$r/$1"
  cp "$f" "$T_TMP/orig"
  printf '%s\n' "$2" >> "$f"
  assert_match "hard-rules: red on $3 in $1" "$(gate hard-rules)" "^fail\|1\|$3 $1"
  cp "$T_TMP/orig" "$f"
}
fault scripts/env/clean.sh '$rectorConfig->rule(SleepToSerializeRector::class);' H2
fault scripts/lib/toolchain.sh 'cfg="withComposerBased(drupal: true)"' H3
fault skills/minimal-port/SKILL.md 'curl -s https://www.drupal.org/project/foo/releases | grep tar' H5
fault agents/drupal-viability-analyst.md 'Drupal 12 is stable, so target it.' H6
fault templates/rector.php.tmpl '  ->withSets([Drupal10SetList::DRUPAL_10])' AGG
fault scripts/env/ddev-up.sh 'ddev config --project-type=drupal12' DDEV

cp "$r/scripts/env/clean.sh" "$T_TMP/orig"
printf '\n# a comment that names SleepToSerializeRector and drupal12\n' >> "$r/scripts/env/clean.sh"
assert_match "a script's comment line is not a hit" "$(gate hard-rules)" '^pass\|0\|'
printf 'x="^12"\n' >> "$r/scripts/env/clean.sh"
assert_match "H4: a new version literal in a script fails" "$(gate hard-rules)" '^fail\|1\|H4 scripts/env/clean.sh: '
printf 'H4 scripts/env/clean.sh 1  # test\n' >> "$r/tests/contract/hard-rules-allow.txt"
assert_match "  its allow-list count admits it" "$(gate hard-rules)" '^pass\|0\|'
cp "$T_TMP/orig" "$r/scripts/env/clean.sh"
printf '\nThe ddev config --project-type=drupal11 line.\n' >> "$r/commands/drupilot-status.md"
printf 'DDEV commands/drupilot-status.md  # test\n' >> "$r/tests/contract/hard-rules-allow.txt"
assert_match "an allow-list row admits its rule for its path" "$(gate hard-rules)" '^pass\|0\|'
printf '\nAnother ddev config --project-type=drupal11 line.\n' >> "$r/commands/drupilot-doctor.md"
assert_match "  and only for that path" "$(gate hard-rules)" '^fail\|1\|DDEV commands/drupilot-doctor.md'

assert_match "scripts: green on HEAD" "$(gate scripts)" '^pass\|0\|'
s="$r/scripts/env/zz-new.sh"
cat > "$s" <<'EOF'
#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/zz-new.sh
# A script the test adds.
#
# Usage:
#   zz-new.sh [--json]
# =============================================================================
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_usage "$0"; exit 0;;
    *) shift;;
  esac
done
EOF
chmod +x "$s"
assert_match "scripts: a new script that ignores an unknown flag fails" "$(gate scripts)" '^fail\|1\|scripts/env/zz-new.sh --drupilot-no-such-flag: exit 0, want 1'
sed_inplace() { local f="$1"; shift; sed "$@" "$f" > "$f.t" && cat "$f.t" > "$f" && rm -f "$f.t"; }
sed_inplace "$s" 's/    \*) shift;;/    *) echo "Unknown argument: $1" >\&2; exit 1;;/'
assert_match "  refusing it: green" "$(gate scripts)" '^pass\|0\|'
sed_inplace "$s" 's#/\.\./lib/common\.sh#/lib/common.sh#'
assert_match "  common.sh at the wrong depth fails" "$(gate scripts)" '^fail\|.*zz-new.sh: does not source common.sh'
t_done
