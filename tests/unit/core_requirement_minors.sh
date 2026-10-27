#!/usr/bin/env bash
# The range reasoning the upgrade plan builds on (T-M3-03, AR-06):
# core_requirement_minors says which core minors a Composer-style
# core_version_requirement admits and core_requirement_lowest its lowest
# version (both checked against composer/semver's answers),
# core_requirement_majors which majors its alternatives start at, and
# core_range_minors / range_majors apply them to
# the verified minors of the version data (the snapshot the T=11 core-target
# golden is pinned to).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/core-strategy/golden.json")"
export DRUPILOT_VERSION_DATA_DIR

M="9.5 10.0 10.2 10.3 10.4 11.0 11.1 11.2 11.3 11.4 11.5 12.0 13.0"
crm() { printf '%s\n' $M | core_requirement_minors "$1" | tr '\n' ' ' | sed 's/ $//'; }
assert_eq "^10 || ^11" "$(crm '^10 || ^11')" "10.0 10.2 10.3 10.4 11.0 11.1 11.2 11.3 11.4 11.5"
assert_eq "^10.3 || ^11" "$(crm '^10.3 || ^11')" "10.3 10.4 11.0 11.1 11.2 11.3 11.4 11.5"
assert_eq "^11" "$(crm '^11')" "11.0 11.1 11.2 11.3 11.4 11.5"
assert_eq "quoted, as in an info.yml" "$(crm "'^11.3'")" "11.3 11.4 11.5"
assert_eq "~11.2.0: one minor" "$(crm '~11.2.0')" "11.2"
assert_eq "~11.2: to the next major" "$(crm '~11.2')" "11.2 11.3 11.4 11.5"
assert_eq ">=10.2 <11.1.2: 11.1.0 and 11.1.1 count" "$(crm '>=10.2 <11.1.2')" "10.2 10.3 10.4 11.0 11.1"
assert_eq ">= 10.2, < 11.1 (spaces, a comma)" "$(crm '>= 10.2, < 11.1')" "10.2 10.3 10.4 11.0"
assert_eq "<=10.3" "$(crm '<=10.3')" "9.5 10.0 10.2 10.3"
assert_eq "11.2.*" "$(crm '11.2.*')" "11.2"
assert_eq "11.x" "$(crm '11.x')" "11.0 11.1 11.2 11.3 11.4 11.5"
assert_eq "11.2.3 (exact)" "$(crm '11.2.3')" "11.2"
assert_eq "10.4 - 11.1 (a hyphen range)" "$(crm '10.4 - 11.1')" "10.4 11.0 11.1"
assert_eq "10.4 - 11 (to the end of 11)" "$(crm '10.4 - 11')" "10.4 11.0 11.1 11.2 11.3 11.4 11.5"
assert_eq "* admits all" "$(crm '*')" "$M"
assert_eq "^11.3@beta (a stability flag)" "$(crm '^11.3@beta')" "11.3 11.4 11.5"
assert_eq "^12.0.0-beta1 (a pre-release)" "$(crm '^12.0.0-beta1')" "12.0"
assert_eq "!= is ignored" "$(crm '^11 != 11.2.1')" "11.0 11.1 11.2 11.3 11.4 11.5"
assert_eq "an unreadable alternative admits nothing" "$(crm '^9.5 || bogus')" "9.5"
assert_eq "an empty constraint admits nothing" "$(crm '')" ""
assert_eq "a line that is no minor is skipped" "$(printf '11\n11.4.8\nx\n11.4\n' | core_requirement_minors '^11' | tr '\n' ' ')" "11.4 "

# Composer parity: the minors (9.0..13.0) with a release the constraint
# admits, and the lowest admitted version, as composer/semver 3.x's
# Semver::satisfies answers them (recorded in the lab, php:8.3-cli; a minor
# counts when any of its x.y.{0..5,8,10,13,50,99} satisfies the constraint).
PM="9.0 9.1 9.2 9.3 9.4 10.0 10.1 10.2 10.3 10.4 10.5 10.6 11.0 11.1 11.2 11.3 11.4 11.5 12.0 12.1 13.0"
while IFS='#' read -r c want low; do
  [[ -n "$c" ]] || continue
  assert_eq "composer parity: $c" "$(printf '%s\n' $PM | core_requirement_minors "$c" | tr '\n' ' ' | sed 's/ $//')" "$want"
  assert_eq "composer parity, lowest: $c" "$(core_requirement_lowest "$c")" "$low"
done <<'EOF'
^10 || ^11#10.0 10.1 10.2 10.3 10.4 10.5 10.6 11.0 11.1 11.2 11.3 11.4 11.5#10.0.0
^10.3 || ^11#10.3 10.4 10.5 10.6 11.0 11.1 11.2 11.3 11.4 11.5#10.3.0
^11#11.0 11.1 11.2 11.3 11.4 11.5#11.0.0
~11.2.0#11.2#11.2.0
~11.2#11.2 11.3 11.4 11.5#11.2.0
>=10.2 <11.1.2#10.2 10.3 10.4 10.5 10.6 11.0 11.1#10.2.0
>= 10.2, < 11.1#10.2 10.3 10.4 10.5 10.6 11.0#10.2.0
<=10.3#9.0 9.1 9.2 9.3 9.4 10.0 10.1 10.2 10.3#0.0.0
11.2.*#11.2#11.2.0
11.x#11.0 11.1 11.2 11.3 11.4 11.5#11.0.0
11.2.3#11.2#11.2.3
10.4 - 11.1#10.4 10.5 10.6 11.0 11.1#10.4.0
10.4 - 11#10.4 10.5 10.6 11.0 11.1 11.2 11.3 11.4 11.5#10.4.0
*#9.0 9.1 9.2 9.3 9.4 10.0 10.1 10.2 10.3 10.4 10.5 10.6 11.0 11.1 11.2 11.3 11.4 11.5 12.0 12.1 13.0#0.0.0
^11.3@beta#11.3 11.4 11.5#11.3.0
^12.0.0-beta1#12.0 12.1#12.0.0
^11 != 11.2.1#11.0 11.1 11.2 11.3 11.4 11.5#11.0.0
11#11.0#11.0.0
=11#11.0#11.0.0
==11#11.0#11.0.0
10 || 11#10.0 11.0#10.0.0
^11 <>11.2.1#11.0 11.1 11.2 11.3 11.4 11.5#11.0.0
!= 10.6.0#9.0 9.1 9.2 9.3 9.4 10.0 10.1 10.2 10.3 10.4 10.5 10.6 11.0 11.1 11.2 11.3 11.4 11.5 12.0 12.1 13.0#0.0.0
@dev#9.0 9.1 9.2 9.3 9.4 10.0 10.1 10.2 10.3 10.4 10.5 10.6 11.0 11.1 11.2 11.3 11.4 11.5 12.0 12.1 13.0#0.0.0
^12.0.0beta1#12.0 12.1#12.0.0
^11.3 || ^12.0.0beta1#11.3 11.4 11.5 12.0 12.1#11.3.0
< 11 >= 10.3 || ^12#10.3 10.4 10.5 10.6 12.0 12.1#10.3.0
~10.6.0 || ^11.1#10.6 11.1 11.2 11.3 11.4 11.5#10.6.0
10.6.* || ^11.2#10.6 11.2 11.3 11.4 11.5#10.6.0
~10.3.0 || ~10.5.0#10.3 10.5#10.3.0
^10.1.3 || ^11#10.1 10.2 10.3 10.4 10.5 10.6 11.0 11.1 11.2 11.3 11.4 11.5#10.1.3
>10.1.2#10.1 10.2 10.3 10.4 10.5 10.6 11.0 11.1 11.2 11.3 11.4 11.5 12.0 12.1 13.0#10.1.3
>10.1#10.1 10.2 10.3 10.4 10.5 10.6 11.0 11.1 11.2 11.3 11.4 11.5 12.0 12.1 13.0#10.1.1
^9 || ^10 || ^11.5#9.0 9.1 9.2 9.3 9.4 10.0 10.1 10.2 10.3 10.4 10.5 10.6 11.5#9.0.0
>=9.5 <11#10.0 10.1 10.2 10.3 10.4 10.5 10.6#9.5.0
11.x-dev##
^8.8 || ^9 || ^10#9.0 9.1 9.2 9.3 9.4 10.0 10.1 10.2 10.3 10.4 10.5 10.6#8.8.0
^9.5 || ^10.3 <10.4#10.3#9.5.0
>11#11.0 11.1 11.2 11.3 11.4 11.5 12.0 12.1 13.0#11.0.1
<11.1.0#9.0 9.1 9.2 9.3 9.4 10.0 10.1 10.2 10.3 10.4 10.5 10.6 11.0#0.0.0
~11#11.0 11.1 11.2 11.3 11.4 11.5#11.0.0
10.4.x#10.4#10.4.0
^10.3|^11#10.3 10.4 10.5 10.6 11.0 11.1 11.2 11.3 11.4 11.5#10.3.0
EOF

assert_eq "majors of ^10.3 || ^11 || ^12" "$(core_requirement_majors '^10.3 || ^11 || ^12')" "10 11 12"
assert_eq "majors: where each alternative starts" "$(core_requirement_majors '>=10.2 <11.1.2')" "10"
assert_eq "majors: a spaced upper bound starts nothing" "$(core_requirement_majors '< 12 >= 10.3')" "10"
assert_eq "majors: an exclusion starts nothing" "$(core_requirement_majors '!= 11.2.1 ^11 || <> 10.1 ^10.3')" "10 11"
assert_eq "majors of an empty constraint" "$(core_requirement_majors '')" ""

assert_eq "core_range_minors: verified minors of majors <= 11" \
  "$(core_range_minors '^10.3 || ^11 || ^12' 11 | tr '\n' ' ')" "10.3 10.4 10.5 10.6 11.0 11.1 11.2 11.3 11.4 "
assert_eq "core_range_minors: released only" "$(core_range_minors '^11.3 || ^12' 12 released | tr '\n' ' ')" "11.3 11.4 "
assert_eq "core_range_minors: the pre-release 12.0 counts in all" "$(core_range_minors '^11.3 || ^12' 12 | tr '\n' ' ')" "11.3 11.4 12.0 "
assert_eq "core_range_minors: no data for 9" "$(core_range_minors '^9 || ^10.5' 11 | tr '\n' ' ')" "10.5 10.6 "
assert_eq "range_majors: ^10.3 || ^11 || ^12" "$(range_majors '^10.3 || ^11 || ^12')" "10 11 12"
assert_eq "range_majors: >=10.2 <11.1.2 reaches 11" "$(range_majors '>=10.2 <11.1.2')" "10 11"
assert_eq "range_majors: >=10 reaches every major of the data" "$(range_majors '>=10')" "10 11 12"
assert_eq "range_majors: ^11" "$(range_majors '^11')" "11"
assert_eq "range_majors: ^10.3 || ^11 || ^12.1 (12.1 has no data)" "$(range_majors '^10.3 || ^11 || ^12.1')" "10 11 12"
assert_eq "range_majors: ^10 || ^11 || ^13 (no data for 13)" "$(range_majors '^10 || ^11 || ^13')" "10 11 13"
assert_eq "range_majors: >=9.5 <11" "$(range_majors '>=9.5 <11')" "9 10"
assert_eq "range_majors: >=10.6" "$(range_majors '>=10.6')" "10 11 12"
assert_eq "range_majors: ^12" "$(range_majors '^12')" "12"
assert_eq "range_majors: < 11 >= 10.3 || ^12" "$(range_majors '< 11 >= 10.3 || ^12')" "10 12"
t_done
