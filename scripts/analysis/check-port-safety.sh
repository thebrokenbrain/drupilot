#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/analysis/check-port-safety.sh
# Deterministic post-port safety checks for a module/theme. They catch the
# breakages that ports (Rector, the digests layer, or an agent "fixing" the
# sandbox PHPStan) have introduced in real projects and that no analyzer in the
# validate loop reports. Read-only, ungated, no toolchain needed (bash + awk +
# jq; git for the diff-aware part). Data lives in config/port-checks.json.
#
# Checks (--checks selects a subset; default all):
#   plugin-di          A class with static create(ContainerInterface ...) that
#                      does not implement the matching interface, itself or
#                      through an ancestor: ContainerFactoryPluginInterface
#                      (create($container, array $configuration, ...)),
#                      ContainerDeriverInterface (create($container,
#                      $base_plugin_id)) or ContainerInjectionInterface
#                      (create($container), other parameters optional). The ancestry is READ from
#                      the Drupal root (core + contrib + the subject), so it is
#                      right for the core version installed; a small verified
#                      fallback list covers a missing root. QueueWorkerBase,
#                      BlockBase, FilterBase, ActionBase, ConditionPluginBase and
#                      core PluginBase do NOT implement it.
#   removed-use        A `use` import the port removed while the short name is
#                      still referenced in the file (diff mode only).
#   static-factory     `new self(` inside create() of a non-final class (e.g. a
#                      `new static` -> `new self` edit to silence PHPStan).
#   fapi-callable      A first-class callable `$this->m(...)` or a closure under
#                      a Form/Render API callback key (#ajax 'callback',
#                      #submit, #validate, #element_validate, #process,
#                      #pre_render, #after_build, #value_callback,
#                      #lazy_builder, ...): closures are not serializable.
#   serialization      private/readonly properties (declared or promoted) in a
#                      class using DependencySerializationTrait (forms,
#                      plugins): dropped by __sleep() / not re-initializable by
#                      __wakeup().
#   override-attribute #[\Override] while the declared core range still
#                      includes Drupal 10 (review warning).
#   class-case         services.yml / routing.yml class references and PSR-4
#                      class names whose case differs from the real file.
#
# Diff-aware: when the subject is tracked by git, every finding is attributed —
# "introduced" (on a line the port added/changed vs the pre-port base) or
# "pre-existing" — and the severity comes from the per-check matrix in
# config/port-checks.json (e.g. a readonly property the port added is an error,
# one that was already there a warning). The base is the same one make-patch.sh
# --local uses (git_port_base_ref: the fork point — upstream, else the closest
# merge-base among the remote branches and the nearest tag, else HEAD), or
# --base REF. Untracked files count as added. Without git (or with --no-diff)
# "introduced" is null and the "unknown" severity applies.
#
# Usage:
#   check-port-safety.sh --subject DIR [--base REF] [--no-diff]
#                        [--checks LIST] [--drupal-root DIR] [--core-req STR]
#                        [--json] [-h|--help]
#
# Options:
#   --subject DIR      The module/theme directory. Required.
#   --base REF         Git ref holding the PRE-port code (default: as above).
#   --no-diff          Do not look at git; every finding is "unknown".
#   --checks LIST      Comma-separated subset of the checks above.
#   --drupal-root DIR  Drupal root whose core/contrib classes resolve ancestors
#                      (default: found by walking up from the subject).
#   --core-req STR     Core constraint to judge override-attribute against
#                      (default: the subject's core_version_requirement).
#   --json             Print a JSON report on STDOUT instead of tagged lines:
#                      {tool, subject, drupal_root, base, diff_mode,
#                       core_requirement, checks, ok, errors, warnings,
#                       findings:[{check, severity, file, line, introduced,
#                                  message}]}
#   -h, --help         Show this help.
#
# Output: without --json, one line per finding on STDOUT:
#   [check-id] severity file:line message
# (the same shape explain-deprecations.sh annotates when teed into a log).
# Logs and the summary go to STDERR.
#
# Exit codes: 0 no error findings (warnings allowed) · 1 usage error ·
# 3 at least one error finding (the port/refactor stage is NOT done).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=../lib/php-scan.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/php-scan.sh"

ALL_CHECKS="plugin-di removed-use static-factory fapi-callable serialization override-attribute class-case"
SUBJECT=""
BASE=""
NO_DIFF=0
CHECKS=""
ROOT_OPT=""
CORE_REQ=""
AS_JSON=0

usage() { grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="${2:-}"; shift 2;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --base) BASE="${2:-}"; shift 2;;
    --base=*) BASE="${1#*=}"; shift;;
    --no-diff) NO_DIFF=1; shift;;
    --checks) CHECKS="${2:-}"; shift 2;;
    --checks=*) CHECKS="${1#*=}"; shift;;
    --drupal-root) ROOT_OPT="${2:-}"; shift 2;;
    --drupal-root=*) ROOT_OPT="${1#*=}"; shift;;
    --core-req) CORE_REQ="${2:-}"; shift 2;;
    --core-req=*) CORE_REQ="${1#*=}"; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) usage; exit 0;;
    *) log_err "Unknown argument: $1"; usage >&2; exit 1;;
  esac
done

[[ -n "$SUBJECT" ]] || die "Missing --subject DIR (the module/theme to check)." 1
case "$SUBJECT" in *"<"*">"*) die "--subject looks like an unsubstituted placeholder: '$SUBJECT'." 1;; esac
SUBJECT_ABS="$(cd "$SUBJECT" 2>/dev/null && pwd || true)"
[[ -n "$SUBJECT_ABS" && -d "$SUBJECT_ABS" ]] || die "Subject directory not found: '$SUBJECT'." 1
have_cmd jq || die "jq is required for check-port-safety.sh." 1
CFG="$(plugin_root)/config/port-checks.json"
[[ -f "$CFG" ]] || die "Missing $CFG." 1

if [[ -z "$CHECKS" ]]; then
  CHECKS="$ALL_CHECKS"
else
  CHECKS="$(printf '%s' "$CHECKS" | tr ',' ' ')"
  for c in $CHECKS; do
    case " $ALL_CHECKS " in *" $c "*) ;; *) die "Unknown check '$c'. Valid: ${ALL_CHECKS// /,}" 1;; esac
  done
fi
check_on() { case " $CHECKS " in *" $1 "*) return 0;; esac; return 1; }

# --- Drupal root / docroot (for ancestor resolution) ------------------------
if [[ -n "$ROOT_OPT" ]]; then
  DRUPAL_ROOT="$(cd "$ROOT_OPT" 2>/dev/null && pwd || true)"
  [[ -n "$DRUPAL_ROOT" ]] || die "--drupal-root not found: '$ROOT_OPT'." 1
else
  DRUPAL_ROOT="$(find_drupal_root "$SUBJECT_ABS" 2>/dev/null || true)"
fi
DOCROOT=""
if [[ -n "$DRUPAL_ROOT" ]]; then
  for d in "$DRUPAL_ROOT/web" "$DRUPAL_ROOT/docroot" "$DRUPAL_ROOT"; do
    if [[ -d "$d/core/lib/Drupal" ]]; then DOCROOT="$d"; break; fi
  done
fi

if [[ -z "$CORE_REQ" ]]; then CORE_REQ="$(subject_core_requirement "$SUBJECT_ABS" 2>/dev/null || true)"; fi
CORE_REQ="$(printf '%s' "$CORE_REQ" | tr -d "\"'")"
# The declared range reaches below Drupal 11 when it names an 8/9/10 major.
SPANS_D10=0
if printf '%s' "$CORE_REQ" | grep -qE '(^|[^0-9.])(8|9|10)(\.|[^0-9]|$)'; then SPANS_D10=1; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-portsafety.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/scan" "$TMP/ext" "$TMP/memo" "$TMP/diff"
: > "$TMP/findings.tsv"

# --- Config: severity matrix + fallback ancestry ----------------------------
jq -r '.checks | to_entries[] | [.key, .value.severity.introduced, .value.severity.preexisting, .value.severity.unknown] | @tsv' "$CFG" > "$TMP/severity.tsv"
jq -r '.fallback | to_entries[] | .key as $t | ((.value.yes // [])[] | [$t, "yes", .]), ((.value.no // [])[] | [$t, "no", .]) | join("\t")' "$CFG" > "$TMP/fallback.tsv"
IF_PLUGIN="$(jq -r '.interfaces.plugin_factory' "$CFG")"
IF_INJECT="$(jq -r '.interfaces.container_injection' "$CFG")"
IF_DERIVER="$(jq -r '.interfaces.container_deriver' "$CFG")"
TR_SERIAL="$(jq -r '.interfaces.serialization_trait' "$CFG")"
FAPI_KEYS="$(jq -r '.fapi_callback_keys | join(" ")' "$CFG")"

# --- Git base (diff-aware attribution) ---------------------------------------
REPO=""; BASE_REF=""; DIFF_MODE=0
if [[ "$NO_DIFF" != "1" ]] && have_cmd git; then
  REPO="$(git -C "$SUBJECT_ABS" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$REPO" ]]; then
    if [[ -n "$BASE" ]]; then
      BASE_REF="$(git_port_base_ref "$REPO" "$BASE")" \
        || die "Base '$BASE' not found (tried origin/$BASE and $BASE)." 1
    else
      BASE_REF="$(git_port_base_ref "$REPO" "")"
    fi
    if git -C "$REPO" rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null 2>&1 \
       && [[ -n "$(git -C "$REPO" ls-tree -r --name-only "$BASE_REF" -- "$SUBJECT_ABS" 2>/dev/null | head -n1)" ]]; then
      DIFF_MODE=1
    else
      log_warn "The subject is not in '$BASE_REF' of $REPO; findings cannot be attributed to the port (introduced: null)."
      BASE_REF=""
    fi
  fi
fi

# --- Helpers ----------------------------------------------------------------
rel() { local p="$1"; p="${p#"$SUBJECT_ABS"/}"; printf '%s' "$p"; }
key_of() { printf '%s' "$*" | tr '\\/| ' '____'; }

# diff_info FILE -> prepares $TMP/diff/<key>.{added,removed}; prints the key.
# .added holds the added/changed line numbers (or "ALL" for an untracked file).
diff_info() {
  local f="$1" k; k="$(key_of "$f")"
  if [[ ! -f "$TMP/diff/$k.added" ]]; then
    : > "$TMP/diff/$k.added"; : > "$TMP/diff/$k.removed"
    if [[ "$DIFF_MODE" == "1" ]]; then
      if ! git -C "$REPO" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
        echo ALL > "$TMP/diff/$k.added"
      else
        git -C "$REPO" diff -U0 --no-color "$BASE_REF" -- "$f" 2>/dev/null > "$TMP/diff/$k.patch" || true
        awk '/^@@/ { split($3, a, ","); s = substr(a[1], 2) + 0; n = (a[2] == "" ? 1 : a[2] + 0); for (i = 0; i < n; i++) print s + i }' \
          "$TMP/diff/$k.patch" > "$TMP/diff/$k.added"
        grep -E '^-' "$TMP/diff/$k.patch" | grep -vE '^--- (a/|/dev/null)' | sed 's/^-//' > "$TMP/diff/$k.removed" || true
      fi
    fi
  fi
  printf '%s' "$k"
}
# introduced FILE LINE -> true | false | null
introduced() {
  if [[ "$DIFF_MODE" != "1" ]]; then printf 'null'; return 0; fi
  local k; k="$(diff_info "$1")"
  if grep -qxE "ALL|$2" "$TMP/diff/$k.added"; then printf 'true'; else printf 'false'; fi
  return 0
}
# removed_matches FILE ERE -> 0 when a line the port removed matches.
removed_matches() {
  [[ "$DIFF_MODE" == "1" ]] || return 1
  local k; k="$(diff_info "$1")"
  grep -qE "$2" "$TMP/diff/$k.removed"
}

# add_finding CHECK FILE LINE INTRODUCED MESSAGE [FORCED_SEVERITY]
add_finding() {
  local check="$1" file="$2" line="$3" intro="$4" msg="$5" sev="${6:-}"
  if [[ -z "$sev" ]]; then
    local col=4
    case "$intro" in true) col=2;; false) col=3;; esac
    sev="$(AWKV_c="$check" AWKV_col="$col" awk -F'\t' 'BEGIN { c = ENVIRON["AWKV_c"]; col = ENVIRON["AWKV_col"] } $1 == c { print $col }' "$TMP/severity.tsv")"
    sev="${sev:-warn}"
  fi
  [[ "$sev" == "skip" ]] && return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$check" "$sev" "$(rel "$file")" "$line" "$intro" "$msg" >> "$TMP/findings.tsv"
  return 0
}

# --- Scan the subject --------------------------------------------------------
FILES="$TMP/files.txt"
find "$SUBJECT_ABS" -type f \( -name '*.php' -o -name '*.module' -o -name '*.inc' -o -name '*.install' \
  -o -name '*.theme' -o -name '*.profile' -o -name '*.engine' \) \
  -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null \
  | LC_ALL=C sort > "$FILES"
: > "$TMP/index.tsv"   # fqcn \t file \t scanfile
n=0
while IFS= read -r f; do
  n=$((n + 1))
  php_scan_file "$f" > "$TMP/scan/$n.tsv"
  AWKV_f="$f" AWKV_s="$TMP/scan/$n.tsv" awk -F'\t' 'BEGIN { f = ENVIRON["AWKV_f"]; s = ENVIRON["AWKV_s"] } $1 == "CLASS" { print $4 "\t" f "\t" s }' "$TMP/scan/$n.tsv" >> "$TMP/index.tsv"
done < "$FILES"
SCANNED="$n"

# Extension directories (machine name -> dir) for Drupal\<ext>\ namespaces.
EXTMAP="$TMP/extmap.tsv"
{
  find "$SUBJECT_ABS" -name '*.info.yml' -not -path '*/vendor/*' -not -path '*/node_modules/*' 2>/dev/null
  if [[ -n "$DOCROOT" ]]; then
    for d in core/modules core/profiles core/themes modules profiles themes; do
      [[ -d "$DOCROOT/$d" ]] && find "$DOCROOT/$d" -name '*.info.yml' -not -path '*/tests/*' 2>/dev/null
    done
  fi
} | while IFS= read -r i; do printf '%s\t%s\n' "$(basename "$i" .info.yml)" "$(dirname "$i")"; done > "$EXTMAP"

# class_file FQCN -> path of the file declaring it (subject index first).
class_file() {
  local fq="$1" f ext rest dir
  f="$(AWKV_q="$fq" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } $1 == q { print $2; exit }' "$TMP/index.tsv")"
  if [[ -n "$f" ]]; then printf '%s' "$f"; return 0; fi
  [[ -n "$DOCROOT" ]] || return 0
  case "$fq" in
    Drupal\\Core\\*|Drupal\\Component\\*)
      f="$DOCROOT/core/lib/$(printf '%s' "$fq" | tr '\\' '/').php";;
    Drupal\\*)
      rest="${fq#Drupal\\}"; ext="${rest%%\\*}"; rest="${rest#*\\}"
      dir="$(AWKV_e="$ext" awk -F'\t' 'BEGIN { e = ENVIRON["AWKV_e"] } $1 == e { print $2; exit }' "$EXTMAP")"
      [[ -n "$dir" ]] && f="$dir/src/$(printf '%s' "$rest" | tr '\\' '/').php";;
  esac
  if [[ -n "$f" && -f "$f" ]]; then printf '%s' "$f"; fi
  return 0
}
# class_records FQCN -> its CLASS + TRAIT records ("" when not found).
class_records() {
  local fq="$1" f s
  s="$(AWKV_q="$fq" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } $1 == q { print $3; exit }' "$TMP/index.tsv")"
  if [[ -z "$s" ]]; then
    f="$(class_file "$fq")"
    [[ -n "$f" ]] || return 0
    s="$TMP/ext/$(key_of "$f").tsv"
    [[ -f "$s" ]] || php_scan_file "$f" > "$s"
  fi
  AWKV_q="$fq" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } ($1 == "CLASS" && $4 == q) || ($1 == "TRAIT" && $2 == q)' "$s"
  return 0
}
# chain_has FQCN TARGET [DEPTH] -> yes | no | unknown
# (does FQCN, an ancestor, or an implemented interface — or, for a trait
# TARGET, a used trait — equal TARGET). Memoized; unresolvable Drupal classes
# fall back to config/port-checks.json, then "unknown"; non-Drupal classes
# (PHP, Symfony, ...) never implement a Drupal interface or use a Drupal trait.
chain_has() {
  local fq="$1" target="$2" depth="${3:-0}" memo recs parent impls x r="no" sub
  if [[ "$fq" == "$target" ]]; then echo yes; return 0; fi
  memo="$TMP/memo/$(key_of "$target|$fq")"
  if [[ -f "$memo" ]]; then cat "$memo"; return 0; fi
  if (( depth > 15 )); then echo unknown; return 0; fi
  recs="$(class_records "$fq")"
  if [[ -z "$recs" ]]; then
    r="$(AWKV_t="$target" AWKV_q="$fq" awk -F'\t' 'BEGIN { t = ENVIRON["AWKV_t"]; q = ENVIRON["AWKV_q"] } $1 == t && $3 == q { print $2; exit }' "$TMP/fallback.tsv")"
    if [[ -z "$r" ]]; then
      case "$fq" in Drupal\\*) r="unknown";; *) r="no";; esac
    fi
  else
    parent="$(printf '%s\n' "$recs" | awk -F'\t' '$1 == "CLASS" { print $6; exit }')"
    impls="$(printf '%s\n' "$recs" | awk -F'\t' '$1 == "CLASS" { print $7; exit }' | tr ',' '\n')"
    if [[ "$target" == *Trait ]]; then
      impls="$(printf '%s\n' "$recs" | awk -F'\t' '$1 == "TRAIT" { print $3 }')"
    fi
    for x in $impls $parent; do
      [[ -n "$x" ]] || continue
      sub="$(chain_has "$x" "$target" $((depth + 1)))"
      if [[ "$sub" == "yes" ]]; then r="yes"; break; fi
      if [[ "$sub" == "unknown" ]]; then r="unknown"; fi
    done
  fi
  echo "$r" > "$memo"
  echo "$r"
  return 0
}
# first unresolved Drupal ancestor of FQCN (for "verify manually" messages).
first_parent() {
  class_records "$1" | awk -F'\t' '$1 == "CLASS" { print $6; exit }'
}

# --- Check: plugin-di / static-factory / serialization / override ------------
n=0
while IFS= read -r f; do
  n=$((n + 1)); s="$TMP/scan/$n.tsv"
  [[ -s "$s" ]] || continue

  if check_on plugin-di; then
    while IFS=$'\t' read -r _ _ cls mname np first second; do
      case "$(lc "$mname")" in create) ;; *) continue;; esac
      printf '%s' "$first" | grep -qE 'ContainerInterface|\$container' || continue
      kind="$(AWKV_q="$cls" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } $1 == "CLASS" && $4 == q { print $3; exit }' "$s")"
      [[ "$kind" == "class" ]] || continue
      # The factory kind follows the signature: create($container, array
      # $configuration, $plugin_id, $plugin_definition, ...) is a plugin factory,
      # create($container, $base_plugin_id) a deriver, and create($container)
      # (extra parameters all optional) a ClassResolver factory. Anything else
      # is not a container factory drupilot knows: skipped, never guessed.
      if printf '%s' "$second" | grep -qE '\$configuration([^A-Za-z0-9_]|$)'; then
        target="$IF_PLUGIN"; short="ContainerFactoryPluginInterface"
      elif printf '%s' "$second" | grep -qE '\$base_plugin_id([^A-Za-z0-9_]|$)'; then
        target="$IF_DERIVER"; short="ContainerDeriverInterface"
      elif (( np == 1 )) || printf '%s' "$second" | grep -q '='; then
        target="$IF_INJECT"; short="ContainerInjectionInterface"
      else
        continue
      fi
      cline="$(AWKV_q="$cls" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } $1 == "CLASS" && $4 == q { print $2; exit }' "$s")"
      r="$(chain_has "$cls" "$target")"
      if [[ "$r" == "no" ]]; then
        msg="${cls##*\\} defines create() (${short%Interface} factory) but neither it nor any ancestor implements ${short}: the factory is never called and the constructor gets the wrong arguments (ArgumentCountError)."
        if removed_matches "$f" "$short"; then msg="$msg The port REMOVED '$short' from this file - restore it."; fi
        add_finding plugin-di "$f" "$cline" "$(introduced "$f" "$cline")" "$msg"
      elif [[ "$r" == "unknown" ]]; then
        add_finding plugin-di "$f" "$cline" "$(introduced "$f" "$cline")" \
          "${cls##*\\} defines create() but its ancestry ($(first_parent "$cls")) could not be resolved here; verify it implements ${short} (do not assume a *Base class does)." warn
      fi
    done < <(awk -F'\t' '$1 == "METHOD"' "$s")
  fi

  if check_on static-factory; then
    while IFS=$'\t' read -r _ line cls meth; do
      case "$(lc "$meth")" in create) ;; *) continue;; esac
      mods="$(AWKV_q="$cls" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } $1 == "CLASS" && $4 == q { print $5; exit }' "$s")"
      case ",$mods," in *,final,*) continue;; esac
      msg="create() of non-final ${cls##*\\} uses 'new self(': a subclass gets a parent instance. Keep 'new static(' (do not change it to silence the sandbox PHPStan 'Unsafe usage of new static()'; leave it and note it, or make the class final in Phase 2)."
      if removed_matches "$f" 'new[[:space:]]+static[[:space:]]*\('; then msg="$msg The port replaced 'new static(' here."; fi
      add_finding static-factory "$f" "$line" "$(introduced "$f" "$line")" "$msg"
    done < <(awk -F'\t' '$1 == "NEWSELF"' "$s")
  fi

  if check_on serialization; then
    while IFS=$'\t' read -r cls cline cmods; do
      props="$(AWKV_q="$cls" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } $1 == "PROP" && $3 == q && $4 !~ /static/ && $4 ~ /(private|readonly)/' "$s")"
      ro_class=0; case ",$cmods," in *,readonly,*) ro_class=1;; esac
      [[ -n "$props" || "$ro_class" == "1" ]] || continue
      r="$(chain_has "$cls" "$TR_SERIAL")"
      [[ "$r" == "yes" ]] || continue
      if [[ "$ro_class" == "1" ]]; then
        add_finding serialization "$f" "$cline" "$(introduced "$f" "$cline")" \
          "readonly class ${cls##*\\} uses DependencySerializationTrait: __wakeup() cannot re-initialize its properties ('Cannot initialize readonly property'). Drop readonly."
      fi
      while IFS=$'\t' read -r _ pline _ pmods pname promo hasdef; do
        [[ -n "$pline" ]] || continue
        # A private, non-readonly property WITH an initializer gets its default
        # back on unserialize (e.g. a constant-like limit): not a hazard.
        case ",$pmods," in *,readonly,*) ;; *) [[ "$hasdef" == "1" ]] && continue;; esac
        what="property"; [[ "$promo" == "1" ]] && what="promoted property"
        why=""
        case ",$pmods," in *,readonly,*) why="readonly: __wakeup() cannot re-initialize it ('Cannot initialize readonly property')";; esac
        case ",$pmods," in *,private,*) why="${why:+$why; }private: __sleep() runs in the base-class scope and drops it ('must not be accessed before initialization' after unserialize)";; esac
        add_finding serialization "$f" "$pline" "$(introduced "$f" "$pline")" \
          "${cls##*\\}::\$${pname} is a ${pmods//,/ } ${what} in a class using DependencySerializationTrait - ${why}. Use protected, non-readonly."
      done <<< "$props"
    done < <(awk -F'\t' '$1 == "CLASS" && $3 == "class" { print $4 "\t" $2 "\t" $5 }' "$s")
  fi

  if check_on override-attribute && [[ "$SPANS_D10" == "1" ]]; then
    while IFS=$'\t' read -r _ line cls; do
      add_finding override-attribute "$f" "$line" "$(introduced "$f" "$line")" \
        "#[\\Override] in ${cls##*\\} while core_version_requirement '${CORE_REQ}' still includes Drupal 10: confirm the parent method exists on the LOWEST core you declare (without it PHP 8.3+ fatals at compile time). Phase 1 does not add #[\\Override]."
    done < <(awk -F'\t' '$1 == "OVERRIDE"' "$s")
  fi
done < "$FILES"

# --- Check: removed-use (diff mode) -------------------------------------------
if check_on removed-use && [[ "$DIFF_MODE" == "1" ]]; then
  n=0
  while IFS= read -r f; do
    n=$((n + 1)); s="$TMP/scan/$n.tsv"
    k="$(diff_info "$f")"
    [[ -s "$TMP/diff/$k.removed" ]] || continue
    fns="$(awk -F'\t' '$1 == "NS" { print $2; exit }' "$s")"
    while IFS= read -r ul; do
      fq="$(printf '%s' "$ul" | sed -E 's/^use[[:space:]]+\\?([A-Za-z0-9_\\]+).*/\1/')"
      alias="$(printf '%s' "$ul" | sed -nE 's/.*[[:space:]]as[[:space:]]+([A-Za-z0-9_]+)[[:space:]]*;.*/\1/p')"
      [[ -n "$alias" ]] || alias="${fq##*\\}"
      # Still imported (moved/re-added), or resolvable in the same namespace.
      AWKV_a="$alias" awk -F'\t' 'BEGIN { a = ENVIRON["AWKV_a"] } $1 == "USE" && $2 == a { found = 1 } END { exit !found }' "$s" && continue
      [[ -n "$fns" ]] && AWKV_q="$fns\\$alias" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } $1 == q { found = 1 } END { exit !found }' "$TMP/index.tsv" && continue
      ref="$(AWKV_a="$alias" awk 'BEGIN { a = ENVIRON["AWKV_a"] } 
        /^[[:space:]]*(use|namespace)[[:space:]]/ { next }
        /^[[:space:]]*(\*|\/\/|\/\*)/ && $0 !~ /@(param|return|var|throws|see)/ { next }
        { line = $0
          while (match(line, "(^|[^A-Za-z0-9_\\\\$>:])" a "([^A-Za-z0-9_]|$)")) { print NR; exit }
        }' "$f")"
      [[ -n "$ref" ]] || continue
      add_finding removed-use "$f" "$ref" true \
        "the port removed 'use ${fq};' but '${alias}' is still referenced here (class not found / broken PHPDoc type). Restore the import."
    done < <(grep -E '^use[[:space:]]+[A-Za-z\\]' "$TMP/diff/$k.removed" | grep -vE '^use[[:space:]]+(function|const)[[:space:]]' || true)
  done < "$FILES"
fi

# --- Check: fapi-callable -----------------------------------------------------
if check_on fapi-callable; then
  while IFS= read -r f; do
    while IFS=$'\t' read -r line key; do
      [[ -n "$line" ]] || continue
      add_finding fapi-callable "$f" "$line" "$(introduced "$f" "$line")" \
        "'${key}' gets a first-class callable/closure: closures cannot be serialized, so a cached form (#ajax, form state cache) fatals. Use [\$this, 'method'], [static::class, 'method'], '::method' or a function-name string."
    done < <(AWKV_keys=" $FAPI_KEYS " awk 'BEGIN { keys = ENVIRON["AWKV_keys"] } 
      function lastkey(s,   k, t, best, pos) {
        best = ""
        t = s
        while (match(t, /\[[[:space:]]*["\047]#[A-Za-z_]+["\047][[:space:]]*\]|["\047]#?[A-Za-z_]+["\047][[:space:]]*=>/)) {
          k = substr(t, RSTART, RLENGTH); gsub(/[][]/, "", k); gsub(/["\047]/, "", k); gsub(/=>/, "", k); gsub(/[[:space:]]/, "", k); best = k
          t = substr(t, RSTART + RLENGTH)
        }
        return best
      }
      /^[[:space:]]*(\*|\/\/|\/\*|#[^\[])/ { hist[NR] = ""; next }
      {
        hist[NR] = $0
        if (match($0, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([[:space:]]*\.\.\.[[:space:]]*\)|(^|[^A-Za-z0-9_$>])(static[[:space:]]+)?(function|fn)[[:space:]]*\(|Closure::fromCallable/)) {
          k = lastkey(substr($0, 1, RSTART - 1))
          if (k == "") {
            for (j = NR - 1; j >= NR - 10 && j > 0; j--) {
              if (hist[j] ~ /;[[:space:]]*$/) break
              k = lastkey(hist[j]); if (k != "") break
            }
          }
          if (k != "" && index(keys, " " k " ") > 0) print NR "\t" k
        }
      }' "$f")
  done < "$FILES"
fi

# --- Check: class-case ----------------------------------------------------------
if check_on class-case; then
  # PSR-4: the single class in src/**/X.php must be named X (same case).
  n=0
  while IFS= read -r f; do
    n=$((n + 1)); s="$TMP/scan/$n.tsv"
    case "$f" in */src/*.php) ;; *) continue;; esac
    [[ "$(awk -F'\t' '$1 == "CLASS"' "$s" | wc -l | tr -d ' ')" == "1" ]] || continue
    IFS=$'\t' read -r _ cline _ cfq _ < <(awk -F'\t' '$1 == "CLASS"' "$s")
    base="$(basename "$f" .php)"; cname="${cfq##*\\}"
    if [[ "$cname" != "$base" ]]; then
      add_finding class-case "$f" "$cline" "$(introduced "$f" "$cline")" \
        "declares '${cname}' in ${base}.php: PSR-4 autoloading needs the exact file name (case-sensitive on Linux)."
    fi
  done < "$FILES"
  # services.yml / routing.yml references into this extension.
  while IFS= read -r y; do
    while IFS=$'\t' read -r line val; do
      fq="${val#\\}"; fq="${fq%%::*}"
      case "$fq" in Drupal\\*\\*) ;; *) continue;; esac
      rest="${fq#Drupal\\}"; ext="${rest%%\\*}"; rest="${rest#*\\}"
      dir="$(AWKV_e="$ext" awk -F'\t' 'BEGIN { e = ENVIRON["AWKV_e"] } $1 == e { print $2; exit }' "$EXTMAP")"
      case "$dir" in "$SUBJECT_ABS"|"$SUBJECT_ABS"/*) ;; *) continue;; esac
      relp="$(printf '%s' "$rest" | tr '\\' '/').php"
      [[ -d "$dir/src" ]] || continue
      exact="$(find "$dir/src" -type f -path "$dir/src/$relp" 2>/dev/null | head -n1)"
      [[ -z "$exact" ]] || continue
      real="$(find "$dir/src" -type f -ipath "$dir/src/$relp" 2>/dev/null | head -n1)"
      [[ -n "$real" ]] || continue   # a missing class is metadata hygiene, not a case problem
      add_finding class-case "$y" "$line" "$(introduced "$y" "$line")" \
        "'${fq}' does not match the real file '$(rel "$real")' (case differs): works on a case-insensitive filesystem, fatals on Linux."
    done < <(awk '
      /^[[:space:]]*#/ { next }
      match($0, /^[[:space:]]+(class|_form|_controller|_title_callback):[[:space:]]*/) {
        v = substr($0, RSTART + RLENGTH); gsub(/["\047[:space:]]/, "", v)
        if (v ~ /\\/) print NR "\t" v
      }' "$y")
  done < <(find "$SUBJECT_ABS" \( -name '*.services.yml' -o -name '*.routing.yml' \) \
             -not -path '*/vendor/*' -not -path '*/node_modules/*' 2>/dev/null | LC_ALL=C sort)
fi

# --- Report ---------------------------------------------------------------------
LC_ALL=C sort -t$'\t' -k3,3 -k4,4n -k1,1 -u "$TMP/findings.tsv" -o "$TMP/findings.tsv"
ERRORS="$(awk -F'\t' '$2 == "error"' "$TMP/findings.tsv" | wc -l | tr -d ' ')"
WARNINGS="$(awk -F'\t' '$2 == "warn"' "$TMP/findings.tsv" | wc -l | tr -d ' ')"

log_info "Subject     : $SUBJECT_ABS ($SCANNED PHP file(s))"
log_info "Drupal root : ${DRUPAL_ROOT:-<none - ancestry from the fallback list>}"
if [[ "$DIFF_MODE" == "1" ]]; then
  log_info "Diff base   : $BASE_REF ($REPO)"
else
  log_info "Diff base   : <none - findings not attributed to the port>"
fi
log_info "Core range  : ${CORE_REQ:-<not declared>}"

if [[ "$AS_JSON" == "1" ]]; then
  jq -R -s -c \
    --arg subject "$SUBJECT_ABS" --arg root "$DRUPAL_ROOT" --arg base "$BASE_REF" \
    --argjson diff "$([[ "$DIFF_MODE" == "1" ]] && echo true || echo false)" \
    --arg core "$CORE_REQ" --arg checks "$CHECKS" \
    '(split("\n") | map(select(length > 0) | split("\t")
       | {check: .[0], severity: .[1], file: .[2], line: (.[3] | tonumber? // .[3]),
          introduced: (.[4] | if . == "true" then true elif . == "false" then false else null end),
          message: .[5]})) as $f
     | {tool: "check-port-safety", subject: $subject,
        drupal_root: (if $root == "" then null else $root end),
        base: (if $base == "" then null else $base end), diff_mode: $diff,
        core_requirement: (if $core == "" then null else $core end),
        checks: ($checks | split(" ") | map(select(length > 0))),
        ok: (($f | map(select(.severity == "error")) | length) == 0),
        errors: ($f | map(select(.severity == "error")) | length),
        warnings: ($f | map(select(.severity == "warn")) | length),
        findings: $f}' "$TMP/findings.tsv"
else
  awk -F'\t' '{ printf "[%s] %s %s:%s %s\n", $1, $2, $3, $4, $5 == "true" ? $6 " (introduced by the port)" : $6 }' "$TMP/findings.tsv"
fi

if [[ "$ERRORS" != "0" ]]; then
  log_err "Port-safety: $ERRORS error(s), $WARNINGS warning(s). Fix the errors before the stage is done."
  exit 3
fi
if [[ "$WARNINGS" != "0" ]]; then
  log_warn "Port-safety: 0 errors, $WARNINGS warning(s) to review."
else
  log_ok "Port-safety: clean."
fi
exit 0
