#!/usr/bin/env bash
# scan-removals.sh (T-M6-04, 04-R14, ADR 0031):
# - the d11_for_d12 fixture for T 12, offline, equals
#   tests/golden/removals/d11_for_d12.t12-offline.json on the snapshot its
#   golden.json pins (T-M6-01), and the scan writes nothing in the subject;
# - the detectors: drupal:NAME and a bare NAME are core's, PROJECT:NAME is
#   not; a dependency on a module removed with no replacement and a reference
#   to its namespace are hard breaks; a removed library as a list item, a key
#   or a quoted name; composer.json's require of the replacement; an
#   announced namespace move is a note (T 11); the majors scanned are (S, T];
# - the release feed (a cached copy, no network): a covering release is a
#   rewrite, none a block, a beta counts only in a preview; in deterministic
#   mode the answer is frozen in the root's lock until the range changes, and
#   DRUPILOT_DETERMINISTIC=false asks the feed again; release_history_rows and
#   release_covering on their own;
# - the CLI: --help, an unknown flag, a missing subject.
# Docker-free and network-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
SR="$T_REPO/scripts/analysis/scan-removals.sh"
G="$T_REPO/tests/golden/removals"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$G/golden.json")"
export DRUPILOT_VERSION_DATA_DIR

# The fixture's golden.
cp -R "$T_REPO/tests/fixtures/d11_for_d12" "$T_TMP/d11_for_d12"
assert_tree_unchanged "d11_for_d12, T 12, offline: the subject is left as it was" "$T_TMP/d11_for_d12" \
  "$T_SH" "$SR" --subject "$T_TMP/d11_for_d12" --target 12 --source 11 --range '^11.3 || ^12' --offline --json
t_run "$T_SH" "$SR" --subject "$T_TMP/d11_for_d12" --target 12 --source 11 --range '^11.3 || ^12' --offline --json
assert_eq "  exit 0" "$T_RC" "0"
assert_json_eq "  the golden" "$(cat "$T_OUT")" "$(cat "$G/d11_for_d12.t12-offline.json")"
t_run "$T_SH" "$SR" --subject "$T_TMP/d11_for_d12" --target 12 --offline --json
assert_eq "  without a plan: S = T - 1, C = targets/12.json's target-only range" \
  "$(jq -c '[.source_major, .majors, .range, (.findings | length)]' "$T_OUT")" '[11,[12],"^12",6]'
t_run "$T_SH" "$SR" --subject "$T_TMP/d11_for_d12" --target 12 --source 11 --range '^11.3 || ^12' --offline
assert_eq "  without --json: the finding ids on STDOUT, a summary on STDERR" \
  "$T_RC|$(sed -n '1p' "$T_OUT")|$(grep -c 'hard breaks: base-theme-removed claro' "$T_ERR" || true)" \
  "0|dependency-removed:contact	d11_for_d12.info.yml:8	verify|1"

# The detectors, for T 11 from S 10 (the 11.0 removals).
M="$T_TMP/m"; mkdir -p "$M/templates" "$M/src" "$M/vendor/x" "$M/modules/m_sub"
cat > "$M/m.info.yml" <<'EOF'
name: M
type: module
core_version_requirement: ^10.3
dependencies:
  - drupal:forum
  - 'book (>=10.1)'
  - tracker:tracker
  - drupal:help_topics
libraries-override:
  core/modernizr: false
EOF
printf 'name: S\ntype: module\ndependencies: [drupal:node, drupal:statistics]\n' > "$M/modules/m_sub/m_sub.info.yml"
printf 'x:\n  dependencies:\n    - core/drupal\n    - "core/es6-promise"\n' > "$M/m.libraries.yml"
printf '{{ attach_library("core/drupal.customevent") }}\n' > "$M/templates/m.html.twig"
printf '<?php\n\nuse Drupal\\help_topics\\HelpTopicDiscovery;\nuse Drupal\\text\\Plugin\\Field\\FieldType\\TextWithSummaryItem;\n' > "$M/src/A.php"
printf 'dependencies:\n  - drupal:action\n' > "$M/vendor/x/x.info.yml"
printf '{"require": {"drupal/book": "^2"}}\n' > "$M/composer.json"
t_run "$T_SH" "$SR" --subject "$M" --target 11 --source 10 --range '^10.3 || ^11' --offline --json
assert_eq "T 11 from S 10: the majors (10, 11]" "$(jq -c '.majors' "$T_OUT")" '[11]'
assert_eq "  each finding: detector, name, file, line, action" \
  "$(jq -c '[.findings[] | [.detector, .name, .file, .line, .action]]' "$T_OUT")" \
  '[["dependency-removed","forum","m.info.yml",5,"verify"],["dependency-removed","book","m.info.yml",6,"composer-required"],["dependency-removed","help_topics","m.info.yml",8,"hard-break"],["library-removed","core/modernizr","m.info.yml",10,"hard-break"],["library-removed","core/es6-promise","m.libraries.yml",4,"hard-break"],["dependency-removed","statistics","modules/m_sub/m_sub.info.yml",3,"verify"],["dependency-removed","help_topics","src/A.php",3,"hard-break"],["namespace-move","TextWithSummaryItem","src/A.php",4,"note"],["library-removed","core/drupal.customevent","templates/m.html.twig",1,"hard-break"]]'
assert_eq "  the severities: verify a warning, composer-required and a note info, a hard break an error" \
  "$(jq -c '[.findings[] | .severity] | unique' "$T_OUT")|$(jq -c '[.findings[] | select(.action == "note") | .severity]' "$T_OUT")" \
  '["error","info","warning"]|["info"]'
assert_eq "  the hard breaks, one per detector and name" "$(jq -c '[.hard_breaks[] | [.id, .name, .files]]' "$T_OUT")" \
  '[["dependency-removed","help_topics",["m.info.yml","src/A.php"]],["library-removed","core/drupal.customevent",["templates/m.html.twig"]],["library-removed","core/es6-promise",["m.libraries.yml"]],["library-removed","core/modernizr",["m.info.yml"]]]'
assert_eq "  a note is not a core removal" "$(jq -c '[.core_removals[] | .detector] | index("namespace-move")' "$T_OUT")" "null"
t_run "$T_SH" "$SR" --subject "$M" --target 11 --source 11 --offline --json
assert_eq "S = T: no major to scan, only T's namespace moves" "$(jq -c '[.majors, [.findings[] | .detector]]' "$T_OUT")" '[[],["namespace-move"]]'

# The release feed: a cached copy (fresh for a day), no network.
FEEDS="$(cache_dir)/release-history"; mkdir -p "$FEEDS"
feed() {  # feed PROJECT RELEASES... (each VERSION=CORE_COMPATIBILITY, published)
  local p="$1" r; shift
  { printf '<?xml version="1.0" encoding="utf-8"?>\n<project><short_name>%s</short_name><releases>\n' "$p"
    for r in "$@"; do printf '<release><name>%s %s</name><version>%s</version><status>published</status><core_compatibility>%s</core_compatibility></release>' "$p" "${r%%=*}" "${r%%=*}" "${r#*=}"; done
    printf '\n</releases></project>\n'; } > "$FEEDS/$p.xml"
  date +%s > "$FEEDS/$p.fetched"
}
feed contact '1.x-dev=&gt;11.3' '1.0.0=&gt;11.3'
feed claro '3.0.0=^11.5 || ^12'
assert_eq "release_history_rows: version, status, the decoded core_compatibility" \
  "$(release_history_rows "$FEEDS/contact.xml" | tr '\t' '|' | tr '\n' ' ')" "1.x-dev|published|>11.3 1.0.0|published|>11.3 "
assert_eq "release_covering: the first published, non-dev release covering every minor" \
  "$(release_history_rows "$FEEDS/contact.xml" | release_covering '^11.3 || ^12' 12 false)" \
  '{"available":true,"release":"1.0.0","core_compatibility":">11.3"}'
assert_eq "  ^11.5 || ^12 does not cover ^11.3 || ^12" \
  "$(release_history_rows "$FEEDS/claro.xml" | release_covering '^11.3 || ^12' 12 false | jq -c .available)" "false"
assert_eq "  a beta counts only in a preview" \
  "$(printf '2.0.0-beta1\tpublished\t^11.3 || ^12\n' | release_covering '^11.3 || ^12' 12 false | jq -c .available)|$(printf '2.0.0-beta1\tpublished\t^11.3 || ^12\n' | release_covering '^11.3 || ^12' 12 true | jq -c .release)" \
  'false|"2.0.0-beta1"'
assert_eq "  no release at all: unknown" "$(printf '' | release_covering '^11.3 || ^12' 12 false | jq -c .available)" '"unknown"'

ROOT="$T_TMP/root"; mkdir -p "$ROOT"
t_run "$T_SH" "$SR" --subject "$T_TMP/d11_for_d12" --target 12 --source 11 --range '^11.3 || ^12' --root "$ROOT" --json
assert_eq "online: contact rewritten (1.0.0 covers the range), claro still a decision" \
  "$(jq -c '[.findings[] | select(.replacement_project != null) | [.name, .action, .replacement_available, .covering_release]]' "$T_OUT")" \
  '[["contact","rewrite",true,"1.0.0"],["claro","decision",false,null]]'
assert_match "  the rewrite's message names both changes" "$(jq -r '.findings[0].message' "$T_OUT")" 'depend on contact:contact and require drupal/contact'
assert_eq "  the answers frozen in the root's lock with their range" \
  "$(DRUPILOT_PROJECT_DIR="$ROOT" jq -c '.replacements | [.contact.available, .contact.release, .contact.range, .claro.available]' "$(DRUPILOT_PROJECT_DIR="$ROOT" lock_path)")" \
  '[true,"1.0.0","^11.3 || ^12",false]'
feed contact '1.0.0=^11.5 || ^12'
t_run "$T_SH" "$SR" --subject "$T_TMP/d11_for_d12" --target 12 --source 11 --range '^11.3 || ^12' --root "$ROOT" --json
assert_eq "deterministic: the frozen answer stands though the feed changed" "$(jq -r '.findings[0].action' "$T_OUT")" "rewrite"
t_run env DRUPILOT_DETERMINISTIC=false "$T_SH" "$SR" --subject "$T_TMP/d11_for_d12" --target 12 --source 11 --range '^11.3 || ^12' --root "$ROOT" --json
assert_eq "DRUPILOT_DETERMINISTIC=false: the feed again, nothing covers: blocked (an error)" \
  "$(jq -c '[.findings[0].action, .findings[0].severity]' "$T_OUT")" '["blocked","error"]'
t_run "$T_SH" "$SR" --subject "$T_TMP/d11_for_d12" --target 12 --source 11 --range '^11.5 || ^12' --root "$ROOT" --json
assert_eq "another range: the frozen answer does not hold, the feed is read" \
  "$(jq -c '[.findings[0].action, .findings[0].covering_release]' "$T_OUT")|$(jq -r '.replacements.contact.range' "$(DRUPILOT_PROJECT_DIR="$ROOT" lock_path)")" \
  '["rewrite","1.0.0"]|^11.5 || ^12'
t_run "$T_SH" "$SR" --subject "$T_TMP/d11_for_d12" --target 12 --source 11 --range '^11.3 || ^12' --offline --json
assert_eq "--offline never reads the feed" "$(jq -c '[.findings[0].action, .offline]' "$T_OUT")" '["verify",true]'

# The CLI.
assert_exit "--help: exit 0" 0 "$T_SH" "$SR" --help
assert_match "  it has a Usage section" "$(cat "$T_OUT")" 'Usage:'
assert_exit "an unknown flag: exit 1" 1 "$T_SH" "$SR" --nope
assert_exit "a missing subject: exit 1" 1 "$T_SH" "$SR" --subject "$T_TMP/none"
t_done
