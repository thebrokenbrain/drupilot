#!/usr/bin/env bash
# The hook contract (AR-45, CC-03, CC-27, CC-28, INV1, INV7): every hook exits 0
# and prints nothing on malformed stdin, without jq, and with a read-only HOME;
# guard-contrib asks (never denies) before a push in autonomous mode.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
H="$T_REPO/hooks/scripts"
mkdir -p "$T_TMP/plain"; printf 'x\n' > "$T_TMP/plain/notes.txt"
printf '%s' 'not json {' > "$T_TMP/garbage.json"
printf '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' > "$T_TMP/push.json"
printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' > "$T_TMP/ls.json"
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$T_TMP/plain/notes.txt" > "$T_TMP/edit.json"
printf '{"cwd":"%s"}' "$T_TMP/plain" > "$T_TMP/session.json"
nojq="$(t_path_without jq)"

# hook <name> <payload> [env...] -> exit code and STDOUT of the hook.
hook() {
  local name="$1" payload="$2"; shift 2
  if (cd "$T_TMP/plain" && env "$@" "$T_SH" "$H/$name.sh") < "$payload" > "$T_OUT" 2> "$T_ERR"; then T_RC=0; else T_RC=$?; fi
  return 0
}
for h in session-detect-env post-edit-lint guard-contrib; do
  case "$h" in
    session-detect-env) good="$T_TMP/session.json";;
    post-edit-lint) good="$T_TMP/edit.json";;
    guard-contrib) good="$T_TMP/push.json";;
  esac
  hook "$h" "$T_TMP/garbage.json"
  assert_eq "$h: malformed stdin -> exit 0, no stdout" "$T_RC|$(t_out)" "0|"
  hook "$h" "$good" PATH="$nojq" DRUPILOT_AUTONOMOUS=true
  assert_eq "$h: no jq -> exit 0, no stdout" "$T_RC|$(t_out)" "0|"
  mkdir -p "$T_TMP/rohome"; chmod a-w "$T_TMP/rohome"
  case "$h" in guard-contrib) benign="$T_TMP/ls.json";; *) benign="$good";; esac
  hook "$h" "$benign" HOME="$T_TMP/rohome" XDG_DATA_HOME="$T_TMP/rohome/.local/share"
  assert_eq "$h: read-only HOME -> exit 0, no stdout" "$T_RC|$(t_out)" "0|"
  chmod u+w "$T_TMP/rohome"
done
# INV1: an autonomous run never pushes on its own; the guard asks.
hook guard-contrib "$T_TMP/push.json" DRUPILOT_AUTONOMOUS=true
assert_eq "INV1: autonomous push -> ask" "$T_RC|$(jq -r '.hookSpecificOutput.permissionDecision' "$T_OUT" 2>/dev/null)" "0|ask"
hook guard-contrib "$T_TMP/push.json" DRUPILOT_CONTRIB_MODE=auto DRUPILOT_AUTONOMOUS=true
assert_eq "INV1: autonomous push asks even in contrib auto mode" "$(jq -r '.hookSpecificOutput.permissionDecision' "$T_OUT" 2>/dev/null)" "ask"
# INV7: hooks ask, never deny: no deny decision is ever emitted.
assert_eq "INV7: no hook emits a deny decision" \
  "$(grep -n 'permissionDecision' "$H"/*.sh | grep -c '"deny"' || true)" "0"
assert_eq "INV7: guard-contrib only ever decides allow or ask" \
  "$(grep -oE 'emit_decision[[:space:]]+"?[a-z]+' "$H/guard-contrib.sh" | sed -E 's/.*[[:space:]]"?//' | LC_ALL=C sort -u | tr '\n' ' ')" "allow ask "
t_done
