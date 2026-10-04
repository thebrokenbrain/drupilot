#!/usr/bin/env bash
# The hook contract (AR-45, CC-03, CC-27, CC-28, INV1, INV7): every hook exits 0
# and prints nothing but a hookSpecificOutput JSON on malformed stdin, without
# jq, and with a HOME it cannot write; guard-contrib asks (never denies)
# before a push in autonomous mode. The payloads are the representative ones
# of scripts/dev/hook-latency.sh, so each hook gets past its early exits:
# SessionStart in a module directory, an Edit of a PHP file of a module in a
# stub Drupal root (stub vendor/bin/phpcs and phpcbf), and a push.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
H="$T_REPO/hooks/scripts"
mkdir -p "$T_TMP/fx" "$T_TMP/root/web/core/lib" "$T_TMP/root/web/modules/custom" "$T_TMP/root/vendor/bin"
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$T_TMP/fx/"
printf '{"name": "drupilot-unit/stub-root"}\n' > "$T_TMP/root/composer.json"
printf "<?php\nclass Drupal {\n  const VERSION = '11.4.8';\n}\n" > "$T_TMP/root/web/core/lib/Drupal.php"
cp -R "$T_REPO/tests/fixtures/legacy_widgets" "$T_TMP/root/web/modules/custom/"
# phpcs reports one error, so post-edit-lint reaches its STDOUT path (the
# PostToolUse context); phpcbf changes nothing.
printf '#!/bin/sh\nprintf " 3 | ERROR | [x] Missing file doc comment\\n"\nexit 2\n' > "$T_TMP/root/vendor/bin/phpcs"
printf '#!/bin/sh\nexit 0\n' > "$T_TMP/root/vendor/bin/phpcbf"
chmod +x "$T_TMP/root/vendor/bin/phpcs" "$T_TMP/root/vendor/bin/phpcbf"
printf '%s' 'not json {' > "$T_TMP/garbage.json"
printf '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' > "$T_TMP/push.json"
printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' > "$T_TMP/ls.json"
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$T_TMP/root/web/modules/custom/legacy_widgets/src/WidgetCounter.php" > "$T_TMP/edit.json"
printf '{"cwd":"%s"}' "$T_TMP/fx/legacy_widgets" > "$T_TMP/session.json"
nojq="$(t_path_without jq)"
rohome="$(t_unwritable_home)"

# hook <name> <payload> [env...] -> exit code and STDOUT of the hook, run from
# the directory its payload points at.
hook() {
  local name="$1" payload="$2" dir; shift 2
  case "$name" in
    session-detect-env) dir="$T_TMP/fx/legacy_widgets";;
    post-edit-lint) dir="$T_TMP/root";;
    *) dir="$T_TMP";;
  esac
  if (cd "$dir" && env "$@" "$T_SH" "$H/$name.sh") < "$payload" > "$T_OUT" 2> "$T_ERR"; then T_RC=0; else T_RC=$?; fi
  return 0
}
# contract -> "0|ok" when the hook exited 0 and printed nothing, or only one
# JSON object with a hookSpecificOutput.
contract() {
  local o; o="$(t_out)"
  if [[ -z "$o" ]] || printf '%s' "$o" | jq -e -s 'length == 1 and (.[0] | type == "object" and has("hookSpecificOutput"))' > /dev/null 2>&1; then
    printf '%s|ok' "$T_RC"
  else
    printf '%s|stdout: %s' "$T_RC" "$(printf '%s' "$o" | head -c 200)"
  fi
}
for h in session-detect-env post-edit-lint guard-contrib; do
  case "$h" in
    session-detect-env) good="$T_TMP/session.json"; benign="$good";;
    post-edit-lint) good="$T_TMP/edit.json"; benign="$good";;
    guard-contrib) good="$T_TMP/push.json"; benign="$T_TMP/ls.json";;
  esac
  hook "$h" "$T_TMP/garbage.json"
  assert_eq "$h: malformed stdin -> exit 0, at most a hookSpecificOutput" "$(contract)" "0|ok"
  hook "$h" "$good" PATH="$nojq" DRUPILOT_AUTONOMOUS=true
  assert_eq "$h: no jq -> exit 0, no stdout" "$T_RC|$(t_out)" "0|"
  hook "$h" "$good"
  assert_eq "$h: its representative payload -> exit 0, at most a hookSpecificOutput" "$(contract)" "0|ok"
  case "$h" in
    post-edit-lint) assert_eq "$h: it reports the finding as PostToolUse context" \
      "$(jq -r '.hookSpecificOutput.hookEventName // empty' "$T_OUT" 2>/dev/null)" "PostToolUse";;
    session-detect-env) assert_eq "$h: it prints SessionStart context" \
      "$(jq -r '.hookSpecificOutput.hookEventName // empty' "$T_OUT" 2>/dev/null)" "SessionStart";;
  esac
  hook "$h" "$benign" HOME="$rohome" XDG_DATA_HOME="$rohome/.local/share" XDG_STATE_HOME="$rohome/.local/state" \
    XDG_CACHE_HOME="$rohome/.cache" XDG_CONFIG_HOME="$rohome/.config"
  assert_eq "$h: a HOME it cannot write -> exit 0, at most a hookSpecificOutput" "$(contract)" "0|ok"
done
# INV1: an autonomous run never pushes on its own; the guard asks.
hook guard-contrib "$T_TMP/push.json" DRUPILOT_AUTONOMOUS=true
assert_eq "INV1: autonomous push -> ask" "$T_RC|$(jq -r '.hookSpecificOutput.permissionDecision' "$T_OUT" 2>/dev/null)" "0|ask"
hook guard-contrib "$T_TMP/push.json" DRUPILOT_CONTRIB_MODE=auto DRUPILOT_AUTONOMOUS=true
assert_eq "INV1: autonomous push asks even in contrib auto mode" "$(jq -r '.hookSpecificOutput.permissionDecision' "$T_OUT" 2>/dev/null)" "ask"
# INV7: hooks ask, never deny. No code line of any hook names a deny (only a
# comment may), and every emit_decision call of every hook is allow or ask.
assert_eq "INV7: no hook code line mentions deny" \
  "$(grep -n 'deny' "$H"/*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -c . || true)" "0"
assert_eq "INV7: every emit_decision is allow or ask" \
  "$(cat "$H"/*.sh | grep -oE 'emit_decision[[:space:]]+"?[a-z]+' | sed -E 's/.*[[:space:]]"?//' | LC_ALL=C sort -u | tr '\n' ' ')" "allow ask "
t_done
