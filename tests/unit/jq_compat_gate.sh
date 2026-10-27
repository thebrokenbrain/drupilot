#!/usr/bin/env bash
# The jq-compat gate of scripts/dev/check.sh, on a scratch copy: jq 1.6
# (drupilot's jq_min) rejects a jq keyword used as a --arg name, an `as $x`
# binding, a shorthand object key or a `def` parameter (upgrade-path.sh's
# refusals once died on `def c($id; $label; ...)`), and an object value
# joined with and/or, or with //, outside parentheses. Each of them turns the gate red; the
# safe spellings and a `# jq-compat-ok` line keep it green.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
r="$T_TMP/tree"
mkdir -p "$r/scripts" "$r/hooks"
cp -R "$T_REPO/scripts/dev" "$T_REPO/scripts/lib" "$r/scripts/"
cp -R "$T_REPO/hooks/scripts" "$r/hooks/"
gate() {
  "$T_SH" "$r/scripts/dev/check.sh" --only jq-compat --json 2>/dev/null \
    | jq -r '.gates[0] | "\(.status)|\(.findings | length)"'
}
assert_eq "green on HEAD" "$(gate)" "pass|0"
f="$r/scripts/lib/zz.sh"
# The cases spell each keyword as @KW so this file does not trip the gate.
while IFS='|' read -r kw line; do
  [[ -n "$line" ]] || continue
  line="$(printf '%s' "$line" | sed "s#@KW#$kw#g")"
  printf '#!/usr/bin/env bash\n%s\n' "$line" > "$f"
  assert_eq "red: $line" "$(gate)" "fail|1"
done <<'EOF'
label|jq -n --arg @KW x '$@KW'
end|jq '.[] as $@KW | $@KW'
module|jq '{@KW, scope}'
label|jq -n 'def c($id; $@KW; $tab): {id: $id}; c(1; 2; 3)'
if|jq -n 'def f($@KW): $@KW; f(1)'
and|jq -n '{ok: (.a) @KW (.b)}'
//|jq -n '{k: .a @KW "x", v: 1}'
EOF
printf '%s\n' '#!/usr/bin/env bash' "jq -n 'def c(\$id; \$lbl; \$tab): {id: \$id, label: \$lbl}; c(1; 2; 3)'" \
  "jq '{label: .label, ok: ((.a) and (.b)), k: (.a // \"x\"), url: \"https://x\"}'" "jq -n --arg label x '.'  # jq-compat-ok: a test of the gate" > "$f"
assert_eq "the safe spellings and an opt-out are green" "$(gate)" "pass|0"
t_done
