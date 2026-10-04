#!/usr/bin/env bash
# php_supported_for, now read from config/targets and config/php (T-M2-06):
# the whole grid of answers equals the 0.9.1 hard-coded table (T-M0-04), an
# unverified minor or a missing data dir degrades to "unknown" (never a
# guess), and DRUPILOT_VERSION_DATA_DIR points it at another data tree.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
grid() {
  local m p line
  for m in 9.5 10.0 10.1 10.2 10.3 10.4 10.5 10.6 11.0 11.1 11.2 11.3 11.4 11.4.8 v11.3 11.5 12.0 12.0.0-beta1 12.1 13.0; do
    line="$m"
    for p in 7.4 8.0 8.1 8.2 8.3 8.4 8.5 8.6 8.7; do line="$line $(php_supported_for "$m" "$p")"; done
    printf '%s\n' "$line"
  done
  printf 'x %s %s %s %s\n' "$(php_supported_for "" 8.3)" "$(php_supported_for 11.4 "")" "$(php_supported_for abc 8.3)" "$(php_supported_for 11.4 8.4.12)"
}
# The answers of the 0.9.1 table, row = core minor, columns = PHP 7.4 .. 8.7.
M0='
9.5 unknown unknown unknown unknown unknown unknown no unknown unknown
10.0 unknown unknown unknown unknown unknown unknown no unknown unknown
10.1 unknown unknown unknown unknown unknown unknown no unknown unknown
10.2 unknown unknown unknown unknown unknown unknown no unknown unknown
10.3 unknown unknown unknown unknown unknown unknown no unknown unknown
10.4 unknown unknown yes yes yes yes no no unknown
10.5 unknown unknown yes yes yes yes no no unknown
10.6 unknown unknown yes yes yes yes no no unknown
11.0 unknown unknown unknown unknown unknown unknown no unknown unknown
11.1 unknown unknown no no yes yes no no unknown
11.2 unknown unknown no no yes yes no no unknown
11.3 unknown unknown no no yes yes yes no unknown
11.4 unknown unknown no no yes yes yes unknown unknown
11.4.8 unknown unknown no no yes yes yes unknown unknown
v11.3 unknown unknown no no yes yes yes no unknown
11.5 unknown unknown unknown unknown unknown unknown unknown unknown unknown
12.0 unknown unknown no no no no yes unknown unknown
12.0.0-beta1 unknown unknown no no no no yes unknown unknown
12.1 unknown unknown unknown unknown unknown unknown unknown unknown unknown
13.0 unknown unknown unknown unknown unknown unknown unknown unknown unknown
x unknown unknown unknown yes
'
assert_eq "the data gives the 0.9.1 table's answers" "$(grid)" "$(printf '%s' "$M0" | sed '/^$/d')"

d="$T_TMP/data"; mkdir -p "$d"; cp -R "$T_REPO/config/targets" "$T_REPO/config/php" "$d/"
assert_eq "DRUPILOT_VERSION_DATA_DIR: a copy answers the same" \
  "$(DRUPILOT_VERSION_DATA_DIR="$d" php_supported_for 11.3 8.5)" "yes"
jq '.minors["11.3"].verified = false' "$T_REPO/config/targets/11.json" > "$d/targets/11.json"
assert_eq "an unverified minor is unknown, not yes" "$(DRUPILOT_VERSION_DATA_DIR="$d" php_supported_for 11.3 8.5)" "unknown"
assert_eq "an unverified minor still gets no from the PHP's verified core floor" \
  "$(DRUPILOT_VERSION_DATA_DIR="$d" php_supported_for 11.2 8.5)" "no"
jq '.versions["8.5"].verified = false' "$T_REPO/config/php/versions.json" > "$d/php/versions.json"
assert_eq "an unverified core floor is not used" "$(DRUPILOT_VERSION_DATA_DIR="$d" php_supported_for 9.5 8.5)" "unknown"
assert_eq "no data dir: unknown" "$(DRUPILOT_VERSION_DATA_DIR="$T_TMP/none" php_supported_for 11.3 8.5)" "unknown"
assert_eq "without jq: unknown" "$(PATH="$(t_path_without jq)" php_supported_for 11.3 8.5)" "unknown"
t_done
