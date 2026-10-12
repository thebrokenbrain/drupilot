#!/usr/bin/env bash
# php-lint-window.sh (T-M5-06) with a stub docker that runs the in-container
# helper for real, on a stub php whose answer depends on the image's minor:
# - one leg per window minor; a file one PHP does not compile fails that leg,
#   a compile-time deprecation is reported and fails nothing;
# - a message is attributed to the file php -l was given, even when its path
#   contains " in ";
# - the status: fail (a leg failed), pass, skipped (every leg skipped: no
#   Docker daemon), error (no leg ran, a run failed), partial (some ran);
# - an empty window and a minor that is not X.Y are usage errors. Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate

B="$T_TMP/bin"; mkdir -p "$B"
# php: "-r ..." prints the version; "-l FILE" fails on a line "@fail-on X.Y"
# and deprecates on "@deprecated-on X.Y" for the minor of STUB_PHP.
cat > "$B/php" <<'SH'
#!/bin/sh
v="$STUB_PHP"; m="${v%.*}"
case "$*" in *" -r "*|"-r "*) printf '%s' "$v"; exit 0;; esac
for f; do :; done
n="$(grep -n "@deprecated-on $m" "$f" | cut -d: -f1 | sed -n '1p')"
[ -n "$n" ] && printf '\nDeprecated: Implicitly marking parameter $x as nullable is deprecated in %s on line %s\n' "$f" "$n"
n="$(grep -n "@fail-on $m" "$f" | cut -d: -f1 | sed -n '1p')"
if [ -n "$n" ]; then printf '\nParse error: syntax error, unexpected identifier "NAME" in %s on line %s\nErrors parsing %s\n' "$f" "$n" "$f"; exit 255; fi
printf 'No syntax errors detected in %s\n' "$f"
exit 0
SH
# docker: info and image inspect succeed (STUB_NO_DAEMON makes info fail); run
# extracts the streamed tree and runs the helper (its last argument) on the
# stub php, or fails for an image listed in STUB_RUN_FAIL.
cat > "$B/docker" <<SH
#!/bin/sh
case "\$1" in
  info) [ -z "\$STUB_NO_DAEMON" ]; exit \$?;;
  image) exit 0;;
  pull) exit 0;;
  run)
    for a; do case "\$a" in php:*) img="\$a";; esac; done
    case " \$STUB_RUN_FAIL " in *" \$img "*) cat > /dev/null; exit 1;; esac
    for script; do :; done
    d="\$(mktemp -d "$T_TMP/run.XXXXXX")"; cd "\$d" || exit 1
    tar -xf - || exit 1
    printf '%s\n' "\$script" > "$T_TMP/lint-helper.sh"
    v="\${img#php:}"; v="\${v%-cli}.99"
    STUB_PHP="\$v" PATH="$B:\$PATH" sh "$T_TMP/lint-helper.sh" .
    exit \$?;;
esac
exit 0
SH
chmod +x "$B/php" "$B/docker"

S="$T_TMP/m"; mkdir -p "$S/src/x in y" "$S/src/a\\b"
printf 'name: M\ntype: module\n' > "$S/m.info.yml"
printf '<?php\nclass A {\n  const string NAME = "x"; // @fail-on 8.1\n}\n' > "$S/src/A.php"
printf '<?php\n// @fail-on 8.1\n' > "$S/src/x in y/B.php"
printf '<?php\n\n// @fail-on 8.1\n' > "$S/src/a\\b/C.php"
printf '<?php\nfunction f(Foo $x = NULL) {} // @deprecated-on 8.4\n' > "$S/m.module"
pl() { t_run env PATH="$B:$PATH" "$T_SH" "$T_REPO/scripts/analysis/php-lint-window.sh" --subject "$S" --json "$@"; }

pl --window "8.1 8.3 8.4"
assert_eq "one leg per minor; 8.1 fails, 8.3 and 8.4 pass: status fail" \
  "$T_RC|$(jq -c '[.status, [.legs[] | [.php, .status, .errors, .deprecations]]]' "$T_OUT")" \
  '0|["fail",[["8.1","fail",3,0],["8.3","pass",0,0],["8.4","pass",0,1]]]'
assert_eq "  the parse errors, each on the file php -l was given (a path with \" in \" or a backslash)" \
  "$(jq -c '[.legs[0].messages[] | [.kind, .file, .line]]' "$T_OUT")" \
  '[["parse-error","src/A.php",3],["parse-error","src/a\\b/C.php",3],["parse-error","src/x in y/B.php",2]]'
assert_eq "  the deprecation of 8.4, reported" "$(jq -c '[.legs[2].messages[] | [.kind, .file, .line]]' "$T_OUT")" '[["deprecated","m.module",2]]'
assert_eq "  the PHP release each image ran, under meta" "$(jq -c '.meta.php_versions' "$T_OUT")" '{"8.1":"8.1.99","8.3":"8.3.99","8.4":"8.4.99"}'
pl --window "8.3,8.4"
assert_eq "every leg compiles: pass (a comma-separated window)" "$(jq -r '.status' "$T_OUT")" "pass"
STUB_RUN_FAIL="php:8.3-cli" pl --window "8.3 8.4"
assert_eq "a leg whose run failed, another that ran: partial" "$(jq -c '[.status, [.legs[].status]]' "$T_OUT")" '["partial",["error","pass"]]'
STUB_RUN_FAIL="php:8.3-cli php:8.4-cli" pl --window "8.3 8.4"
assert_eq "no leg ran and a run failed: error, never skipped" "$(jq -r '.status' "$T_OUT")" "error"
STUB_NO_DAEMON=1 pl --window "8.3 8.4"
assert_eq "no Docker daemon: every leg skipped" "$T_RC|$(jq -c '[.status, [.legs[].status]]' "$T_OUT")" '0|["skipped",["skipped","skipped"]]'
pl --window " , "
assert_eq "an empty window: exit 1" "$T_RC" "1"
pl --window "8"
assert_eq "a minor that is not X.Y: exit 1" "$T_RC" "1"
t_done
