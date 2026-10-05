#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/core.sh
# Logging and presentation, tool and version detection, and small portable
# helpers (timeouts, JSON strings, text, template rendering).
#
# Part of the shared library: scripts/lib/common.sh sources it with the other
# domain libs (never source it alone); see common.sh for the conventions.
# =============================================================================

# ---------------------------------------------------------------------------
# Colors / presentation (respects NO_COLOR and non-TTY output)
# ---------------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  _C_RESET=$'\033[0m'; _C_BOLD=$'\033[1m'; _C_DIM=$'\033[2m'
  _C_RED=$'\033[31m'; _C_GREEN=$'\033[32m'; _C_YELLOW=$'\033[33m'
  _C_BLUE=$'\033[34m'; _C_CYAN=$'\033[36m'
else
  _C_RESET=''; _C_BOLD=''; _C_DIM=''
  _C_RED=''; _C_GREEN=''; _C_YELLOW=''; _C_BLUE=''; _C_CYAN=''
fi

log_info()  { printf '%sℹ%s  %s\n'  "$_C_BLUE"   "$_C_RESET" "$*" >&2; }
log_ok()    { printf '%s✅%s %s\n'   "$_C_GREEN"  "$_C_RESET" "$*" >&2; }
log_warn()  { printf '%s⚠️%s  %s\n'  "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
log_err()   { printf '%s❌%s %s\n'   "$_C_RED"    "$_C_RESET" "$*" >&2; }
log_step()  { printf '\n%s▶ %s%s\n'  "$_C_BOLD$_C_CYAN" "$*" "$_C_RESET" >&2; }
log_plain() { printf '%s\n' "$*" >&2; }
hr()        { printf '%s%s%s\n' "$_C_DIM" "────────────────────────────────────────────────────────" "$_C_RESET" >&2; }

# die <message> [code]
die() { log_err "$1"; exit "${2:-1}"; }

# ---------------------------------------------------------------------------
# Tool and version detection
# ---------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# print_usage <script> -> prints the script's header comment block (the lines
# between its first two "# ====" rules, without the leading "# ") on STDOUT, for
# -h/--help. Only the header is printed: later comments, shellcheck directives
# and the rule lines themselves are not part of the help.
print_usage() {
  awk 'NR == 1 && /^#!/ { next }
       /^# =+[[:space:]]*$/ { if (inhdr) exit; inhdr = 1; next }
       !inhdr { next }
       !/^#/ { exit }
       /^#[[:space:]]*shellcheck[[:space:]]/ { next }
       { sub(/^# ?/, ""); print }' "$1"
}

# semver_gt A B -> 0 when version A has a higher SemVer 2.0.0 precedence than
# B (§11: numeric core fields; a release outranks its pre-releases;
# pre-release identifiers compare numerically when both are numbers, else as
# ASCII, a numeric one ranking lower; a longer list wins when all shared ones
# tie). Unlike version_ge (which strips the suffix), 1.0.0-rc.1 < 1.0.0.
semver_gt() {
  local ac="${1%%-*}" bc="${2%%-*}" ap="" bp="" i x y na nb LC_ALL=C
  [[ "$1" == *-* ]] && ap="${1#*-}"
  [[ "$2" == *-* ]] && bp="${2#*-}"
  for i in 1 2 3; do
    x="$(printf '%s' "$ac" | cut -d. -f"$i")"; y="$(printf '%s' "$bc" | cut -d. -f"$i")"
    [[ "${x:-0}" -gt "${y:-0}" ]] && return 0
    [[ "${x:-0}" -lt "${y:-0}" ]] && return 1
  done
  [[ -z "$ap" && -z "$bp" ]] && return 1
  [[ -z "$ap" ]] && return 0
  [[ -z "$bp" ]] && return 1
  na=$(( $(printf '%s' "$ap" | tr -cd . | wc -c) + 1 )); nb=$(( $(printf '%s' "$bp" | tr -cd . | wc -c) + 1 ))
  i=1
  while [[ "$i" -le "$na" && "$i" -le "$nb" ]]; do
    x="$(printf '%s' "$ap" | cut -d. -f"$i")"; y="$(printf '%s' "$bp" | cut -d. -f"$i")"
    if [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]]; then
      [[ "$x" -gt "$y" ]] && return 0
      [[ "$x" -lt "$y" ]] && return 1
    elif [[ "$x" =~ ^[0-9]+$ ]]; then return 1
    elif [[ "$y" =~ ^[0-9]+$ ]]; then return 0
    else
      [[ "$x" > "$y" ]] && return 0
      [[ "$x" < "$y" ]] && return 1
    fi
    i=$((i + 1))
  done
  [[ "$na" -gt "$nb" ]]
}

# extract_semver <string> -> first X.Y(.Z) found
extract_semver() {
  printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1
}

# tool_version <cmd> -> detected version (best-effort), empty if unavailable
tool_version() {
  local cmd="$1" out=""
  have_cmd "$cmd" || { printf ''; return 1; }
  case "$cmd" in
    php)      out="$(php -r 'echo PHP_VERSION;' </dev/null 2>/dev/null || php -v </dev/null 2>&1 | head -n1)";;
    composer) out="$(composer --version </dev/null 2>/dev/null | head -n1)";;
    docker)   out="$(docker --version </dev/null 2>&1 | head -n1)";;
    ddev)     out="$(ddev --version </dev/null 2>&1 | head -n1)";;
    git)      out="$(git --version </dev/null 2>&1 | head -n1)";;
    jq)       out="$(jq --version </dev/null 2>&1 | head -n1)";;
    drush)    out="$(drush --version </dev/null 2>&1 | head -n1)";;
    *)        out="$("$cmd" --version </dev/null 2>&1 | head -n1)";;
  esac
  extract_semver "$out"
}

# version_ge <v1> <v2> -> 0 if v1 >= v2 (lenient semver comparison)
version_ge() {
  local a="${1%%-*}" b="${2%%-*}"          # strip pre-release suffixes (-rc1, etc.)
  a="$(printf '%s' "$a" | tr -cd '0-9.')"   # keep digits and dots only
  b="$(printf '%s' "$b" | tr -cd '0-9.')"
  [[ -z "$a" ]] && a=0
  [[ -z "$b" ]] && b=0
  local IFS=.
  # shellcheck disable=SC2206
  local -a A=($a) B=($b)
  local i max=${#A[@]}
  (( ${#B[@]} > max )) && max=${#B[@]}
  for (( i=0; i<max; i++ )); do
    local x="${A[i]:-0}" y="${B[i]:-0}"
    x=$(( 10#${x:-0} )); y=$(( 10#${y:-0} ))
    (( x > y )) && return 0
    (( x < y )) && return 1
  done
  return 0
}

# run_with_timeout <seconds> <cmd> [args...] -> runs cmd with a wall-clock limit
# when `timeout` (GNU coreutils) or `gtimeout` (Homebrew coreutils on macOS) is
# available, else runs it unbounded. <seconds> 0 (or empty) means no limit.
# Returns cmd's exit code, or 124 when the limit was hit. stdin is NOT
# redirected; callers that must never wait on input pass </dev/null.
# CAVEAT: the limit does NOT propagate through `ddev exec` / `ddev composer`
# (docker exec): only the host-side client is killed and the process keeps
# running in the web container. Bound in-container work with the container's
# own `timeout` (ddev exec "timeout -k 20 N /usr/local/bin/composer ...": name
# Composer by the absolute path ddev_global_composer returns, since under
# `timeout` a bare `composer` resolves to a test-bed's vendor/bin/composer), or
# stop it after a 124 with ddev_stop_composer before cleaning up the files it
# writes.
run_with_timeout() {
  local secs="${1:-0}"; shift
  local t=""
  if [[ "$secs" =~ ^[0-9]+$ && "$secs" -gt 0 ]]; then
    if have_cmd timeout; then t="timeout"
    elif have_cmd gtimeout; then t="gtimeout"
    fi
  fi
  if [[ -n "$t" ]]; then
    "$t" "$secs" "$@"
  else
    "$@"
  fi
}

# render_template_files TEMPLATE DEST KEY=FILE... -> like render_template, but
# each {{KEY}} is replaced by the CONTENT of FILE (one trailing newline
# dropped), so a value may be multi-line and hold any character (|, &, \, /)
# and any size (render_template passes values through the environment, which
# caps one value at 128 KiB on Linux). DEST "-" prints to STDOUT; otherwise the
# render goes to a temp file next to DEST first. Returns non-zero on a bad
# argument or I/O error.
render_template_files() {
  local tpl="${1:-}" dest="${2:-}"
  shift 2 2>/dev/null || { log_err "render_template_files: usage: render_template_files TEMPLATE DEST [KEY=FILE...]"; return 1; }
  [[ -f "$tpl" ]] || { log_err "render_template_files: template not found: '$tpl'"; return 1; }
  [[ -n "$dest" ]] || { log_err "render_template_files: missing destination for '$tpl'"; return 1; }
  local spec="" pair k v
  for pair in "$@"; do
    k="${pair%%=*}"; v="${pair#*=}"
    case "$k" in
      ''|*[!A-Z0-9_]*) log_err "render_template_files: invalid token name in '$pair'"; return 1;;
    esac
    [[ "$pair" == *=* && -r "$v" ]] || { log_err "render_template_files: unreadable value file in '$pair'"; return 1; }
    spec="$spec$k"$'\x1f'"$v"$'\x1e'
  done
  # shellcheck disable=SC2016  # awk program, not a shell expansion
  local prog='
    BEGIN {
      n = split(ENVIRON["_DRUPILOT_TPLF_SPEC"], pairs, "\036"); m = 0
      for (i = 1; i <= n; i++) {
        if (pairs[i] == "") continue
        split(pairs[i], kv, "\037"); m++
        tok[m] = "{{" kv[1] "}}"; val[m] = ""; first = 1
        while ((getline l < kv[2]) > 0) { val[m] = (first ? l : val[m] "\n" l); first = 0 }
        close(kv[2])
      }
    }
    {
      # Left to right, one token at a time: a value is never re-scanned, so
      # content that happens to contain "{{KEY}}" is printed as is.
      line = $0; out = ""
      while (1) {
        best = 0; bp = 0
        for (i = 1; i <= m; i++) {
          p = index(line, tok[i])
          if (p > 0 && (bp == 0 || p < bp)) { bp = p; best = i }
        }
        if (best == 0) break
        out = out substr(line, 1, bp - 1) val[best]
        line = substr(line, bp + length(tok[best]))
      }
      print out line
    }'
  if [[ "$dest" == "-" ]]; then
    _DRUPILOT_TPLF_SPEC="$spec" awk "$prog" "$tpl"
    return $?
  fi
  local tmp
  tmp="$(mktemp "${dest}.drupilot.XXXXXX" 2>/dev/null)" \
    || { log_err "render_template_files: cannot create a temp file next to '$dest'"; return 1; }
  if _DRUPILOT_TPLF_SPEC="$spec" awk "$prog" "$tpl" > "$tmp" && cat "$tmp" > "$dest"; then
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"
  return 1
}

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------
# json_str <string> -> a quoted, escaped JSON string
json_str() {
  if have_cmd jq; then jq -Rn --arg s "$1" '$s'
  else printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; fi
}

# arr_to_json <elem...> -> a compact JSON array of the (string) arguments.
# Empty arg list -> "[]". Requires jq.
arr_to_json() {
  if [[ "$#" -eq 0 ]]; then printf '[]'; return 0; fi
  printf '%s\n' "$@" | jq -R . | jq -s -c .
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
# os_id -> OS identifier (fedora, ubuntu, debian, arch, macos, ...)
os_id() {
  case "$(uname -s)" in
    Darwin) printf 'macos'; return 0;;
    Linux) : ;;
    *) printf 'unknown'; return 0;;
  esac
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    ( . /etc/os-release; printf '%s' "${ID:-linux}" )
  else
    printf 'linux'
  fi
}

# ---------------------------------------------------------------------------
# Portability helpers (bash 3.2 / BSD userland — stock macOS)
# ---------------------------------------------------------------------------
# The plugin targets bash >= 3.2 and does not assume GNU tools. So: no
# ${x,,}/${x^^} (bash 4), no declare -A / mapfile / local -n, no `sed -i` (GNU
# and BSD disagree on its argument), and possibly-empty arrays are expanded with
# the ${arr[@]+"${arr[@]}"} idiom (a bare "${arr[@]}" of an empty array is an
# "unbound variable" error under `set -u` before bash 4.4).

# lc <string...> -> the string lowercased (portable replacement for ${x,,}).
lc() { printf '%s' "$*" | tr '[:upper:]' '[:lower:]'; }

# sed_inplace <file> <sed args...> -> edit <file> in place, portably. Runs
# `sed <args...> <file>` into a temp file next to it, then copies it back with
# `cat >` (keeps the inode, permissions and any symlink target). On failure the
# original is left untouched, the temp file is removed and it returns non-zero.
# Use it instead of `sed -i`, which takes a mandatory suffix on BSD/macOS.
sed_inplace() {
  local f="${1:-}"; shift || true
  [[ -n "$f" && -f "$f" ]] || { log_err "sed_inplace: not a regular file: '${f}'"; return 1; }
  [[ $# -gt 0 ]] || { log_err "sed_inplace: no sed expression given for '$f'"; return 1; }
  local tmp
  tmp="$(mktemp "${f}.drupilot.XXXXXX" 2>/dev/null || mktemp 2>/dev/null)" \
    || { log_err "sed_inplace: cannot create a temp file for '$f'"; return 1; }
  if sed "$@" "$f" > "$tmp" && cat "$tmp" > "$f"; then
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"
  return 1
}

# render_template <template> <dest|-> [KEY=VALUE...] -> substitute every
# {{KEY}} token of <template> with VALUE, literally, and write the result to
# <dest> ('-' = stdout). Values are taken verbatim: no sed delimiter, '&',
# backslash or regex metacharacter can break them, and envsubst is not needed.
# The substitution runs in awk with the values passed through the environment
# (awk -v would interpret backslash escapes, and bash's ${x//pat/rep} differs
# between 3.2 and 5.2 in how it treats quotes and '&'). Tokens without a
# KEY=VALUE pair are left as-is, so the caller can detect them. The render goes
# to a temp file next to <dest> first, so <dest> is only touched once rendering
# succeeded. Returns non-zero on a bad argument or I/O error.
render_template() {
  local tpl="${1:-}" dest="${2:-}"
  shift 2 2>/dev/null || { log_err "render_template: usage: render_template TEMPLATE DEST [KEY=VALUE...]"; return 1; }
  [[ -f "$tpl" ]] || { log_err "render_template: template not found: '$tpl'"; return 1; }
  [[ -n "$dest" ]] || { log_err "render_template: missing destination for '$tpl'"; return 1; }
  local -a envs=()
  local keys="" pair k
  for pair in "$@"; do
    k="${pair%%=*}"
    case "$k" in
      ''|*[!A-Z0-9_]*) log_err "render_template: invalid token name in '$pair' (expected KEY=VALUE, KEY in [A-Z0-9_])"; return 1;;
    esac
    [[ "$pair" == *=* ]] || { log_err "render_template: missing '=' in '$pair'"; return 1; }
    keys="$keys $k"
    envs+=("_DRUPILOT_TPL_V_$k=${pair#*=}")
  done
  envs+=("_DRUPILOT_TPL_KEYS=$keys")
  # shellcheck disable=SC2016  # awk program, not a shell expansion
  local prog='
    BEGIN {
      n = split(ENVIRON["_DRUPILOT_TPL_KEYS"], ks, " ")
      for (i = 1; i <= n; i++) { tok[i] = "{{" ks[i] "}}"; val[i] = ENVIRON["_DRUPILOT_TPL_V_" ks[i]] }
    }
    {
      line = $0
      for (i = 1; i <= n; i++) {
        out = ""
        while ((p = index(line, tok[i])) > 0) {
          out = out substr(line, 1, p - 1) val[i]
          line = substr(line, p + length(tok[i]))
        }
        line = out line
      }
      print line
    }'
  if [[ "$dest" == "-" ]]; then
    env "${envs[@]}" awk "$prog" "$tpl"
    return $?
  fi
  local tmp
  tmp="$(mktemp "${dest}.drupilot.XXXXXX" 2>/dev/null)" \
    || { log_err "render_template: cannot create a temp file next to '$dest'"; return 1; }
  # `cat >` (not mv) so a new file gets the umask mode and an existing one keeps
  # its mode/inode, exactly like the plain `> dest` redirect this replaces.
  if env "${envs[@]}" awk "$prog" "$tpl" > "$tmp" && cat "$tmp" > "$dest"; then
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"
  return 1
}

# trim surrounding whitespace from a string
trim() { local s="$*"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
