#!/usr/bin/env bash
# The 0.9 strategy vocabulary keeps working through the alias layer
# (T-M3-07, AR-27, CC-07): config/migrations.json maps every 0.9 spelling of
# the DRUPILOT_KEEP_D10 boolean onto DRUPILOT_CORE_TARGET_STRATEGY, only while
# the strategy is auto (an explicit strategy wins, as in 0.9), and the old
# strategy values d11-only / keep-d10 onto target-only / keep-previous. Each
# alias warns once per process. For T=11 drupilot still emits and persists the
# 0.9 names: core-strategy.sh's verdict, a CORE_TARGET answer choice.sh emits
# and persists, and the lock's core_strategy (lock-sync.sh). The D10_CHECK tab keeps its own d11-only option, persisted as in
# 0.9. make-issue.sh takes --prev-major-unverified and its 0.9 name.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
DRUPILOT_VERSION_DATA_DIR="$T_REPO/tests/fixtures/data-snapshots/$(jq -r .data_hash "$T_REPO/tests/golden/plans/golden.json")"
export DRUPILOT_VERSION_DATA_DIR
r="$T_TMP/root"
mkdir -p "$r/web/core/lib" "$r/web/modules/custom"
printf '{"name":"x/root"}\n' > "$r/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$r/web/core/lib/Drupal.php"
cp -R "$T_REPO/tests/fixtures/keep_current" "$r/web/modules/custom/keep_current"
KC="$r/web/modules/custom/keep_current"
# strat ENV... -> config_get's strategy | core-strategy.sh's verdict. keep_current
# is already Drupal 11 compatible: auto keeps its declaration (keep-current).
strat() {
  printf '%s|%s' \
    "$(env "$@" "$T_SH" -c '. "$1"; DRUPILOT_PROJECT_DIR="$2" config_get DRUPILOT_CORE_TARGET_STRATEGY none' _ "$T_LIB" "$r" 2> /dev/null)" \
    "$(cd "$r" && env "$@" "$T_SH" "$T_REPO/scripts/analysis/core-strategy.sh" --subject "$KC" --json 2> /dev/null | jq -r .strategy)"
}
assert_eq "unset: auto (keep_current stays as it is)" "$(strat X=1)" "auto|keep-current"
assert_eq "true while auto: keep-previous, emitted as keep-d10" "$(strat DRUPILOT_KEEP_D10=true)" "keep-previous|keep-d10"
assert_eq "false while auto: target-only, emitted as d11-only" "$(strat DRUPILOT_KEEP_D10=false)" "target-only|d11-only"
for v in 1 yes ON; do
  assert_eq "  the 0.9 spelling $v" "$(strat "DRUPILOT_KEEP_D10=$v")" "keep-previous|keep-d10"
done
for v in 0 no Off; do
  assert_eq "  the 0.9 spelling $v" "$(strat "DRUPILOT_KEEP_D10=$v")" "target-only|d11-only"
done
assert_eq "true with an explicit target-only: ignored" \
  "$(strat DRUPILOT_KEEP_D10=true DRUPILOT_CORE_TARGET_STRATEGY=target-only)" "target-only|d11-only"
assert_eq "true with an explicit d11-only (0.9 name): ignored" \
  "$(strat DRUPILOT_KEEP_D10=true DRUPILOT_CORE_TARGET_STRATEGY=d11-only)" "d11-only|d11-only"
assert_eq "keep-previous and widest read as keep-d10" \
  "$(strat DRUPILOT_CORE_TARGET_STRATEGY=keep-previous | cut -d'|' -f2)|$(strat DRUPILOT_CORE_TARGET_STRATEGY=widest | cut -d'|' -f2)" "keep-d10|keep-d10"
printf '{"DRUPILOT_KEEP_D10": true}\n' > "$r/.drupilot.json"
assert_eq "a .drupilot.json KEEP_D10 (a JSON true) is aliased too" "$(strat X=1)" "keep-previous|keep-d10"
printf '{"DRUPILOT_KEEP_D10": true, "DRUPILOT_CORE_TARGET_STRATEGY": "d11-only"}\n' > "$r/.drupilot.json"
assert_eq "  but not over an explicit strategy beside it" "$(strat X=1)" "d11-only|d11-only"
rm -f "$r/.drupilot.json"

# One warning per process, however often the setting is read.
w="$(env DRUPILOT_KEEP_D10=true "$T_SH" -c '. "$1"; for i in 1 2 3; do config_get DRUPILOT_CORE_TARGET_STRATEGY x > /dev/null; done
  value_alias_normalize DRUPILOT_CORE_TARGET_STRATEGY keep-d10; value_alias_normalize DRUPILOT_CORE_TARGET_STRATEGY keep-d10' _ "$T_LIB" 2>&1 > /dev/null)"
assert_eq "one warning per alias per process" \
  "$(printf '%s\n' "$w" | grep -c 'DRUPILOT_KEEP_D10=true is deprecated')|$(printf '%s\n' "$w" | grep -c 'DRUPILOT_CORE_TARGET_STRATEGY=keep-d10 is deprecated')" "1|1"

# Tabs: a 0.9 pre-answer is accepted under its new name, persisted under the
# 0.9 one for T=11 (and the new one for another T).
CH="$T_REPO/scripts/env/choice.sh"
t_run env DRUPILOT_CHOICE_CORE_TARGET=keep-d10 "$T_SH" "$CH" --key CORE_TARGET --subject "$KC" --persist --json
assert_eq "CHOICE_CORE_TARGET=keep-d10: accepted, not re-asked, emitted as keep-d10 (CC-07)" "$T_RC|$(jq -c '[.value, .valid]' "$T_OUT")" '0|["keep-d10",true]'
assert_eq "  one warning" "$(t_err | grep -c 'deprecated')" "1"
assert_eq "  persisted as keep-d10 (CC-07)" "$(jq -r .DRUPILOT_CORE_TARGET_STRATEGY "$r/.drupilot.json")" "keep-d10"
t_run env DRUPILOT_CHOICE_CORE_TARGET=d11-only "$T_SH" "$CH" --key CORE_TARGET --subject "$KC" --persist --json
assert_eq "CHOICE_CORE_TARGET=d11-only: accepted, emitted and persisted as d11-only" \
  "$(jq -r .value "$T_OUT")|$(jq -r .DRUPILOT_CORE_TARGET_STRATEGY "$r/.drupilot.json")" "d11-only|d11-only"
t_run env DRUPILOT_CHOICE_CORE_TARGET=keep-previous "$T_SH" "$CH" --key CORE_TARGET --subject "$KC" --json
assert_eq "CHOICE_CORE_TARGET=keep-previous (1.0 name): emitted as keep-d10, no warning" \
  "$(jq -c '[.value, .valid]' "$T_OUT")|$(t_err | grep -c deprecated || true)" '["keep-d10",true]|0'
t_run env DRUPILOT_CHOICE_CORE_TARGET=widest "$T_SH" "$CH" --key CORE_TARGET --subject "$KC" --persist --json
assert_eq "CHOICE_CORE_TARGET=widest: no 0.9 name, persisted as it is" \
  "$(jq -r .value "$T_OUT")|$(jq -r .DRUPILOT_CORE_TARGET_STRATEGY "$r/.drupilot.json")" "widest|widest"
t_run env DRUPILOT_CHOICE_CORE_TARGET=keep-d10 DRUPILOT_CORE_TARGET_STRATEGY=keep-d10 "$T_SH" "$CH" --key CORE_TARGET --subject "$KC" --json
assert_eq "  an equivalent environment strategy is no override" "$(jq -c .env_override "$T_OUT")" "[]"
t_run env DRUPILOT_CHOICE_CORE_TARGET=keep-previous DRUPILOT_TARGET_MAJOR=12 "$T_SH" "$CH" --key CORE_TARGET --subject "$KC" --persist --json
assert_eq "T 12: emitted and persisted under the new name" \
  "$(jq -r .value "$T_OUT")|$(jq -r .DRUPILOT_CORE_TARGET_STRATEGY "$r/.drupilot.json")" "keep-previous|keep-previous"
t_run env DRUPILOT_CHOICE_CORE_TARGET=bogus "$T_SH" "$CH" --key CORE_TARGET --subject "$KC" --json
assert_eq "an unknown value: asked" "$(jq -c '[.value, .valid]' "$T_OUT")" '[null,false]'
rm -f "$r/.drupilot.json"
t_run env DRUPILOT_CHOICE_D10_CHECK=d11-only "$T_SH" "$CH" --key D10_CHECK --subject "$KC" --persist --json
assert_eq "CHOICE_D10_CHECK=d11-only --persist: its own option, as in 0.9" \
  "$T_RC|$(jq -r .value "$T_OUT")|$(jq -r .DRUPILOT_CORE_TARGET_STRATEGY "$r/.drupilot.json")|$(t_err | grep -c deprecated || true)" "0|d11-only|d11-only|0"
rm -f "$r/.drupilot.json"
assert_eq "choose_one: a 0.9 pre-answer counts as its new name" \
  "$(env DRUPILOT_CHOICE_CORE_TARGET=keep-d10 "$T_SH" -c '. "$1"; choose_one CORE_TARGET "Core target" auto keep-previous target-only widest' _ "$T_LIB" 2> /dev/null)" "keep-previous"

# The lock keeps the 0.9 vocabulary too: the configured strategy as 0.9 read
# it (a KEEP_D10 boolean leaves it auto), a 1.0 name under its 0.9 name.
ls_strat() {
  rm -f "$(DRUPILOT_PROJECT_DIR="$r" lock_path)"
  env "$@" "$T_SH" "$T_REPO/scripts/env/lock-sync.sh" --dir "$r" > /dev/null 2>&1 < /dev/null
  DRUPILOT_PROJECT_DIR="$r" lock_get .core_strategy
}
assert_eq "lock: keep-previous is written as keep-d10" "$(ls_strat DRUPILOT_CORE_TARGET_STRATEGY=keep-previous)" "keep-d10"
assert_eq "lock: target-only is written as d11-only" "$(ls_strat DRUPILOT_CORE_TARGET_STRATEGY=target-only)" "d11-only"
assert_eq "lock: KEEP_D10 leaves auto, as in 0.9" "$(ls_strat DRUPILOT_KEEP_D10=true)" "auto"
assert_eq "lock: T 12 keeps the new name" "$(ls_strat DRUPILOT_CORE_TARGET_STRATEGY=keep-previous DRUPILOT_TARGET_MAJOR=12)" "keep-previous"

# The flag alias of make-issue.sh.
mi() { "$T_SH" "$T_REPO/scripts/contrib/make-issue.sh" --project legacy_widgets --base 1.x --output "$T_TMP/mi$1" "$2" --json 2> /dev/null; }
mkdir -p "$T_TMP/mi1" "$T_TMP/mi2"
assert_eq "--prev-major-unverified = --d10-unverified" \
  "$(mi 1 --prev-major-unverified | jq -S 'del(.. | strings | select(test("/mi[12]")))' | cksum)" \
  "$(mi 2 --d10-unverified | jq -S 'del(.. | strings | select(test("/mi[12]")))' | cksum)"
assert_match "  both add the Drupal 10 item" "$(cat "$T_TMP"/mi1/* 2> /dev/null)" "Drupal 10"
t_done
