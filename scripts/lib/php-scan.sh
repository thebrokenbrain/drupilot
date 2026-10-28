#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/php-scan.sh
# Shared, dependency-free PHP class heuristics (bash + POSIX awk; no PHP needed,
# so it runs on the host without the toolchain). Sourced by
# scripts/analysis/check-port-safety.sh, scan-signature-changes.sh,
# lint-extension-metadata.sh and convert-attributes.sh; meant to be reused by
# any later analysis script that needs class headers, imports, methods or
# ancestry, instead of re-parsing PHP on its own (the class index and
# php_chain_has ancestry resolver follow php_scan_file; php_method_params,
# php_ctor_params and php_annotation_keys, which read constructor parameters
# and doc-block annotation keys, are at the end of this file).
#
#   php_scan_file FILE  -> TSV records on stdout, one per line:
#     NS        <namespace>
#     USE       <alias> <fqcn> <line>                (top-level imports)
#     CLASS     <line> <kind> <fqcn> <mods> <parent-fqcn> <implements-csv>
#               kind: class|interface|trait|enum; mods: csv of
#               abstract/final/readonly; for an interface the extended
#               interfaces are in <implements-csv>. Names are resolved
#               against the file's namespace and imports.
#     TRAIT     <class-fqcn> <trait-fqcn>            (`use X;` in a class body)
#     METHOD    <line> <class-fqcn> <name> <nparams> <first-param> <second-param>
#     NEWSELF   <line> <class-fqcn> <method>         (`new self(` in a body)
#     NEWSTATIC <line> <class-fqcn> <method>
#     PROP      <line> <class-fqcn> <mods> <name> <promoted:0|1> <default:0|1>
#               mods: csv of public/protected/private/readonly/static/var;
#               default=1 when a declared property has an initializer
#     OVERRIDE  <line> <class-fqcn>                  (#[\Override] attribute)
#     SIG       <line> <class-fqcn> <name> <visibility> <static:0|1> <nparams>
#               <nrequired> <return-type>            (one per METHOD; the
#               return type is "" when undeclared)
#     PCALL     <line> <class-fqcn> <method> <parent-method> <nargs>
#               (`parent::m(...)` inside a method body; nargs is "?" when an
#               argument is unpacked with `...`)
#     FUNC      <line> <name> <nparams> <nrequired> <second-param>
#               (a named function outside any class, e.g. a hook in .module)
#     HOOK      <line> <class-fqcn> <method> <hook> <nparams> <nrequired>
#               (a method carrying a #[Hook('name')] attribute)
#
# It is a line-oriented heuristic, not a PHP parser: comments and string
# contents are stripped before braces are counted, one top-level class per file
# is assumed (nested anonymous classes are ignored), and heredocs are not
# understood. Good enough for Drupal-style code; callers must treat an
# unresolvable fact as "unknown", never guess.
# =============================================================================

# php_scan_file FILE -> TSV records (see header). Never fails the caller.
php_scan_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk '
function clean(s,   out, i, c, nx, n) {
  out = ""; n = length(s); i = 1
  while (i <= n) {
    c = substr(s, i, 1); nx = substr(s, i + 1, 1)
    if (inblock) { if (c == "*" && nx == "/") { inblock = 0; i += 2; continue }; i++; continue }
    if (instr != "") {
      if (c == "\\") { i += 2; continue }
      if (c == instr) { out = out c; instr = "" }
      i++; continue
    }
    if (c == "/" && nx == "*") { inblock = 1; i += 2; continue }
    if (c == "/" && nx == "/") break
    if (c == "#" && nx != "[") break
    if (c == "\047" || c == "\"") { instr = c; out = out c; i++; continue }
    out = out c; i++
  }
  return out
}
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
function res(n,   first, rest, p) {
  n = trim(n)
  if (n == "") return ""
  if (substr(n, 1, 1) == "\\") return substr(n, 2)
  lname = tolower(n)
  if (lname == "self" || lname == "static" || lname == "parent") return n
  p = index(n, "\\")
  if (p > 0) {
    first = substr(n, 1, p - 1); rest = substr(n, p)
    if (first in uses) return uses[first] rest
  } else if (n in uses) return uses[n]
  return (ns == "" ? n : ns "\\" n)
}
function count(s, ch,   t) { t = s; return gsub(ch, "", t) }
function emit_use(stmt, line,   body, prefix, p, q, parts, k, item, alias, fq, m) {
  body = trim(stmt)
  sub(/^use[[:space:]]+/, "", body); sub(/;.*$/, "", body)
  if (body ~ /^(function|const)[[:space:]]/) return
  prefix = ""
  p = index(body, "{")
  if (p > 0) {
    prefix = trim(substr(body, 1, p - 1)); q = index(body, "}")
    body = substr(body, p + 1, (q > 0 ? q : length(body) + 1) - p - 1)
  }
  m = split(body, parts, ",")
  for (k = 1; k <= m; k++) {
    item = trim(parts[k]); if (item == "") continue
    alias = ""
    if (match(item, /[[:space:]]+as[[:space:]]+/)) {
      alias = trim(substr(item, RSTART + RLENGTH)); item = trim(substr(item, 1, RSTART - 1))
    }
    fq = prefix item; sub(/^\\/, "", fq)
    if (alias == "") { alias = fq; sub(/^.*\\/, "", alias) }
    uses[alias] = fq
    print "USE\t" alias "\t" fq "\t" line
  }
}
function parse_header(h, line,   mods, kind, name, parent, impls, t, w, n, i, list, acc, k, parts) {
  h = trim(h); gsub(/[[:space:]]+/, " ", h)
  n = split(h, w, " ")
  mods = ""; kind = ""; name = ""; i = 1
  while (i <= n && (w[i] == "abstract" || w[i] == "final" || w[i] == "readonly")) { mods = mods (mods == "" ? "" : ",") w[i]; i++ }
  kind = w[i]; i++
  name = w[i]; sub(/[^A-Za-z0-9_].*$/, "", name); i++
  parent = ""; impls = ""; acc = ""; list = ""
  for (; i <= n; i++) {
    if (w[i] == "extends" || w[i] == "implements") {
      if (list == "extends") parent = acc; else if (list == "implements") impls = acc
      list = w[i]; acc = ""; continue
    }
    acc = acc w[i]
  }
  if (list == "extends") parent = acc; else if (list == "implements") impls = acc
  if (kind == "interface") { impls = parent; parent = "" }
  t = ""
  k = split(impls, parts, ",")
  for (i = 1; i <= k; i++) if (trim(parts[i]) != "") t = t (t == "" ? "" : ",") res(parts[i])
  cls = (ns == "" ? name : ns "\\" name); clskind = kind
  print "CLASS\t" line "\t" kind "\t" cls "\t" mods "\t" (parent == "" ? "" : res(parent)) "\t" t
}
function nparams(sig,   i, c, d, n, any, inner, first, second) {
  # sig = text from the opening "(" to its matching ")" (inclusive).
  inner = substr(sig, 2, length(sig) - 2)
  inner = trim(inner); sub(/,[[:space:]]*$/, "", inner)
  firstp = ""; secondp = ""; nreq = 0
  if (inner == "") return 0
  d = 0; n = 1; first = ""; second = ""; seg = ""
  for (i = 1; i <= length(inner); i++) {
    c = substr(inner, i, 1)
    if (c == "(" || c == "[") d++
    else if (c == ")" || c == "]") d--
    else if (c == "," && d == 0) { if (seg !~ /=/ && seg !~ /\.\.\./) nreq++; seg = ""; n++; continue }
    seg = seg c
    if (n == 1) first = first c
    else if (n == 2) second = second c
  }
  if (seg !~ /=/ && seg !~ /\.\.\./) nreq++
  firstp = trim(first); gsub(/[[:space:]]+/, " ", firstp)
  secondp = trim(second); gsub(/[[:space:]]+/, " ", secondp)
  return n
}
function nargs(call,   inner, i, c, d, n, seg, spread) {
  # call = text from the opening "(" to its matching ")" (inclusive).
  inner = trim(substr(call, 2, length(call) - 2)); sub(/,[[:space:]]*$/, "", inner)
  if (inner == "") return 0
  d = 0; n = 1; seg = ""; spread = 0
  for (i = 1; i <= length(inner); i++) {
    c = substr(inner, i, 1)
    if (c == "(" || c == "[") d++
    else if (c == ")" || c == "]") d--
    else if (c == "," && d == 0) { if (trim(seg) ~ /^\.\.\./) spread = 1; seg = ""; n++; continue }
    seg = seg c
  }
  if (trim(seg) ~ /^\.\.\./) spread = 1
  return spread ? "?" : n
}
function closing(s,   i, ch, pd) {
  # Position of the ")" that balances the first "(" of s, or 0.
  pd = 0
  for (i = 1; i <= length(s); i++) {
    ch = substr(s, i, 1)
    if (ch == "(") pd++
    else if (ch == ")") { pd--; if (pd == 0) return i }
  }
  return 0
}
function promoted(text, line,   parts, k, m, p, mods, name, w, wn, j) {
  m = split(text, parts, ",")
  for (k = 1; k <= m; k++) {
    p = trim(parts[k]); sub(/^\(/, "", p); p = trim(p)
    if (p !~ /^(public|protected|private|readonly)[[:space:]]/) continue
    wn = split(p, w, /[[:space:]]+/); mods = ""; name = ""
    for (j = 1; j <= wn; j++) {
      if (w[j] ~ /^(public|protected|private|readonly)$/) mods = mods (mods == "" ? "" : ",") w[j]
      if (name == "" && w[j] ~ /^&?(\.\.\.)?\$[A-Za-z_]/) { name = w[j]; sub(/^[^$]*\$/, "", name); sub(/[^A-Za-z0-9_].*$/, "", name) }
    }
    if (name != "") print "PROP\t" line "\t" cls "\t" mods "\t" name "\t1\t0"
  }
}
BEGIN { depth = 0; ns = ""; cls = ""; clsdepth = -1; hdr = ""; inhdr = 0; insig = 0; meth = ""; inmeth = 0; inblock = 0; instr = ""; fsig = 0; pcon = 0; pendhooks = "" }
{
  raw = $0; c = clean(raw); d0 = depth
  opens = count(c, "[{]"); closes = count(c, "[}]")

  # Named functions outside any class (hook implementations in .module/.inc).
  handled = 0
  if (fsig) { fbuf = fbuf " " c; handled = 1 }
  else if (cls == "" && !inhdr && d0 <= 1 && match(c, /^[[:space:]]*function[[:space:]]+&?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/)) {
    t = substr(c, RSTART, RLENGTH); sub(/^[[:space:]]*function[[:space:]]+&?[[:space:]]*/, "", t); sub(/[[:space:]]*\($/, "", t)
    fname = t; fline = NR; fbuf = substr(c, RSTART + RLENGTH - 1); fsig = 1; handled = 1
  }
  if (fsig) {
    endp = closing(fbuf)
    if (endp > 0) {
      n = nparams(substr(fbuf, 1, endp))
      print "FUNC\t" fline "\t" fname "\t" n "\t" nreq "\t" secondp
      fsig = 0
    }
  }

  if (handled) {
    # signature text of a top-level function: nothing else to parse here
  } else if (inhdr) {
    hdr = hdr " " c
    p = index(hdr, "{")
    if (p > 0) { parse_header(substr(hdr, 1, p - 1), hdrline); inhdr = 0; clsdepth = hdrdepth }
  } else if (cls == "" || d0 <= clsdepth) {
    if (match(c, /^[[:space:]]*namespace[[:space:]]+[A-Za-z0-9_\\]+/)) {
      t = substr(c, RSTART, RLENGTH); sub(/^[[:space:]]*namespace[[:space:]]+/, "", t); ns = t; print "NS\t" ns
    } else if (d0 == 0 && c ~ /^[[:space:]]*use[[:space:]]+[A-Za-z\\]/) {
      emit_use(c, NR)
    } else if (c ~ /^[[:space:]]*((abstract|final|readonly)[[:space:]]+)*(class|interface|trait|enum)[[:space:]]+[A-Za-z_]/) {
      hdr = c; hdrline = NR; hdrdepth = d0
      p = index(hdr, "{")
      if (p > 0) { parse_header(substr(hdr, 1, p - 1), hdrline); clsdepth = d0 } else inhdr = 1
    }
  } else {
    body = clsdepth + 1
    if (insig) {
      sig = sig " " c
      if (meth == "__construct") promoted(c, NR)
    } else if (!inmeth && d0 == body) {
      if (c ~ /#\[[[:space:]]*\\?Override[[:space:]]*[](]/) print "OVERRIDE\t" NR "\t" cls
      if (c ~ /#\[/ && match(raw, /(^|[^A-Za-z0-9_])Hook[[:space:]]*\([[:space:]]*(hook[[:space:]]*:[[:space:]]*)?["\047][A-Za-z0-9_]+/)) {
        t = substr(raw, RSTART, RLENGTH); sub(/^.*["\047]/, "", t); pendhooks = pendhooks " " t
      }
      if (c ~ /^[[:space:]]*use[[:space:]]+[A-Za-z\\]/) {
        t = c; sub(/^[[:space:]]*use[[:space:]]+/, "", t); sub(/[;{].*$/, "", t)
        m = split(t, tp, ",")
        for (k = 1; k <= m; k++) if (trim(tp[k]) != "") print "TRAIT\t" cls "\t" res(tp[k])
      } else if (c !~ /(^|[^A-Za-z0-9_])(function|const)[[:space:]]/ && match(c, /^[[:space:]]*((public|protected|private|var|static|readonly)[[:space:]]+)+[^(=;]*\$[A-Za-z_][A-Za-z0-9_]*/)) {
        t = substr(c, RSTART, RLENGTH); wn = split(trim(t), w, /[[:space:]]+/); mods = ""
        for (j = 1; j <= wn; j++) if (w[j] ~ /^(public|protected|private|var|static|readonly)$/) mods = mods (mods == "" ? "" : ",") w[j]
        name = t; sub(/^.*\$/, "", name)
        hasdef = (substr(c, RSTART + RLENGTH) ~ /^[[:space:]]*=/) ? 1 : 0
        print "PROP\t" NR "\t" cls "\t" mods "\t" name "\t0\t" hasdef
      }
      if (match(c, /function[[:space:]]+&?[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/)) {
        t = substr(c, RSTART, RLENGTH); sub(/^function[[:space:]]+&?[[:space:]]*/, "", t); sub(/[[:space:]]*\($/, "", t)
        meth = t; mline = NR; insig = 1
        t = substr(c, 1, RSTART - 1); mvis = "public"; mstatic = 0
        if (t ~ /(^|[[:space:]])private[[:space:]]/) mvis = "private"; else if (t ~ /(^|[[:space:]])protected[[:space:]]/) mvis = "protected"
        if (t ~ /(^|[[:space:]])static[[:space:]]/) mstatic = 1
        sig = substr(c, RSTART + RLENGTH - 1)
        if (meth == "__construct") promoted(sig, NR)
      }
    }
    if (insig) {
      # The signature ends once its parentheses balance; the body starts at "{".
      pd = 0; endp = 0
      for (i = 1; i <= length(sig); i++) {
        ch = substr(sig, i, 1)
        if (ch == "(") pd++
        else if (ch == ")") { pd--; if (pd == 0) { endp = i; break } }
      }
      if (endp > 0) {
        rest = substr(sig, endp + 1)
        if (rest ~ /[{;]/) {
          n = nparams(substr(sig, 1, endp))
          print "METHOD\t" mline "\t" cls "\t" meth "\t" n "\t" firstp "\t" secondp
          rt = rest; sub(/[{;].*$/, "", rt); sub(/^[[:space:]]*:/, "", rt); rt = trim(rt); gsub(/[[:space:]]+/, "", rt)
          print "SIG\t" mline "\t" cls "\t" meth "\t" mvis "\t" mstatic "\t" n "\t" nreq "\t" rt
          k = split(trim(pendhooks), hk, " ")
          for (j = 1; j <= k; j++) print "HOOK\t" mline "\t" cls "\t" meth "\t" hk[j] "\t" n "\t" nreq
          pendhooks = ""
          insig = 0
          if (index(rest, "{") > 0) { inmeth = 1 } else { meth = "" }
        }
      }
    }
    if (inmeth) {
      if (c ~ /new[[:space:]]+self[[:space:]]*\(/) print "NEWSELF\t" NR "\t" cls "\t" meth
      if (c ~ /new[[:space:]]+static[[:space:]]*\(/) print "NEWSTATIC\t" NR "\t" cls "\t" meth
      if (pcon) pcbuf = pcbuf " " c
      else if (match(c, /parent::[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/)) {
        t = substr(c, RSTART, RLENGTH); sub(/^parent::/, "", t); sub(/[[:space:]]*\($/, "", t)
        pcname = t; pcline = NR; pcmeth = meth; pcbuf = substr(c, RSTART + RLENGTH - 1); pcon = 1
      }
      if (pcon) {
        endp = closing(pcbuf)
        if (endp > 0) { print "PCALL\t" pcline "\t" cls "\t" pcmeth "\t" pcname "\t" nargs(substr(pcbuf, 1, endp)); pcon = 0 }
      }
    }
  }

  depth = d0 + opens - closes
  if (inmeth && depth <= clsdepth + 1) { inmeth = 0; meth = ""; pcon = 0 }
  if (cls != "" && !inhdr && depth <= clsdepth) { cls = ""; clsdepth = -1; inmeth = 0; insig = 0; meth = ""; pcon = 0; pendhooks = "" }
}
' "$f" 2>/dev/null || true
  return 0
}

# -----------------------------------------------------------------------------
# Class index + ancestry resolution (shared by check-port-safety.sh and
# scan-signature-changes.sh). A caller sets two globals first:
#   PHPSCAN_DIR     a private work dir (mktemp -d); the helpers keep there
#                   scan/<n>.tsv (one php_scan_file output per subject file),
#                   index.tsv (fqcn \t file \t scanfile), extmap.tsv
#                   (extension machine name \t dir), ext/ (scans of core and
#                   contrib files), memo/ (chain_has answers) and, optionally,
#                   fallback.tsv (target \t yes|no \t fqcn: verified ancestry
#                   used when a class file cannot be read).
#   PHPSCAN_DOCROOT the Drupal docroot holding core/lib (may be empty).
# -----------------------------------------------------------------------------

# php_scan_key STRING -> a file-name-safe key.
php_scan_key() { printf '%s' "$*" | tr '\\/| ' '____'; }

# php_scan_index FILELIST -> scans every file listed (one path per line) into
# $PHPSCAN_DIR/scan/<n>.tsv (n = 1-based line number) and indexes its classes.
php_scan_index() {
  local list="$1" f n=0
  mkdir -p "$PHPSCAN_DIR/scan" "$PHPSCAN_DIR/ext" "$PHPSCAN_DIR/memo"
  : > "$PHPSCAN_DIR/index.tsv"
  while IFS= read -r f; do
    n=$((n + 1))
    php_scan_file "$f" > "$PHPSCAN_DIR/scan/$n.tsv"
    AWKV_f="$f" AWKV_s="$PHPSCAN_DIR/scan/$n.tsv" awk -F'\t' 'BEGIN { f = ENVIRON["AWKV_f"]; s = ENVIRON["AWKV_s"] } $1 == "CLASS" { print $4 "\t" f "\t" s }' "$PHPSCAN_DIR/scan/$n.tsv" >> "$PHPSCAN_DIR/index.tsv"
  done < "$list"
  return 0
}

# php_scan_extmap SUBJECT_DIR -> writes $PHPSCAN_DIR/extmap.tsv for the
# extensions of the subject and, when PHPSCAN_DOCROOT is set, of core/contrib.
php_scan_extmap() {
  local subject="$1" d i
  {
    find "$subject" -name '*.info.yml' -not -path '*/vendor/*' -not -path '*/node_modules/*' 2>/dev/null
    if [[ -n "${PHPSCAN_DOCROOT:-}" ]]; then
      for d in core/modules core/profiles core/themes modules profiles themes; do
        if [[ -d "$PHPSCAN_DOCROOT/$d" ]]; then find "$PHPSCAN_DOCROOT/$d" -name '*.info.yml' -not -path '*/tests/*' 2>/dev/null; fi
      done
    fi
  } | while IFS= read -r i; do printf '%s\t%s\n' "$(basename "$i" .info.yml)" "$(dirname "$i")"; done > "$PHPSCAN_DIR/extmap.tsv"
  return 0
}

# php_class_file FQCN -> path of the file declaring it (subject index first).
php_class_file() {
  local fq="$1" f="" ext rest dir
  f="$(AWKV_q="$fq" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } $1 == q { print $2; exit }' "$PHPSCAN_DIR/index.tsv")"
  if [[ -n "$f" ]]; then printf '%s' "$f"; return 0; fi
  [[ -n "${PHPSCAN_DOCROOT:-}" ]] || return 0
  case "$fq" in
    Drupal\\Core\\*|Drupal\\Component\\*)
      f="$PHPSCAN_DOCROOT/core/lib/$(printf '%s' "$fq" | tr '\\' '/').php";;
    Drupal\\*)
      rest="${fq#Drupal\\}"; ext="${rest%%\\*}"; rest="${rest#*\\}"
      dir="$(AWKV_e="$ext" awk -F'\t' 'BEGIN { e = ENVIRON["AWKV_e"] } $1 == e { print $2; exit }' "$PHPSCAN_DIR/extmap.tsv" 2>/dev/null)"
      if [[ -n "$dir" ]]; then f="$dir/src/$(printf '%s' "$rest" | tr '\\' '/').php"; fi;;
  esac
  if [[ -n "$f" && -f "$f" ]]; then printf '%s' "$f"; fi
  return 0
}

# php_class_records FQCN -> its CLASS + TRAIT records ("" when not found).
php_class_records() {
  local fq="$1" f s
  s="$(AWKV_q="$fq" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } $1 == q { print $3; exit }' "$PHPSCAN_DIR/index.tsv")"
  if [[ -z "$s" ]]; then
    f="$(php_class_file "$fq")"
    [[ -n "$f" ]] || return 0
    s="$PHPSCAN_DIR/ext/$(php_scan_key "$f").tsv"
    [[ -f "$s" ]] || php_scan_file "$f" > "$s"
  fi
  AWKV_q="$fq" awk -F'\t' 'BEGIN { q = ENVIRON["AWKV_q"] } ($1 == "CLASS" && $4 == q) || ($1 == "TRAIT" && $2 == q)' "$s"
  return 0
}

# php_chain_has FQCN TARGET [DEPTH] -> yes | no | unknown
# (does FQCN, an ancestor, or an implemented interface — or, for a trait
# TARGET, a used trait — equal TARGET). Memoized; unresolvable Drupal classes
# fall back to $PHPSCAN_DIR/fallback.tsv, then "unknown"; non-Drupal classes
# (PHP, Symfony, ...) never implement a Drupal interface or use a Drupal trait.
php_chain_has() {
  local fq="$1" target="$2" depth="${3:-0}" memo recs parent impls x r="no" sub
  if [[ "$fq" == "$target" ]]; then echo yes; return 0; fi
  memo="$PHPSCAN_DIR/memo/$(php_scan_key "$target|$fq")"
  if [[ -f "$memo" ]]; then cat "$memo"; return 0; fi
  if (( depth > 15 )); then echo unknown; return 0; fi
  recs="$(php_class_records "$fq")"
  if [[ -z "$recs" ]]; then
    r="$(AWKV_t="$target" AWKV_q="$fq" awk -F'\t' 'BEGIN { t = ENVIRON["AWKV_t"]; q = ENVIRON["AWKV_q"] } $1 == t && $3 == q { print $2; exit }' "$PHPSCAN_DIR/fallback.tsv" 2>/dev/null)"
    if [[ -z "$r" ]]; then
      case "$fq" in Drupal\\*) r="unknown";; *) r="no";; esac
    fi
  else
    parent="$(printf '%s\n' "$recs" | awk -F'\t' '!d && $1 == "CLASS" { print $6; d = 1 }')"
    impls="$(printf '%s\n' "$recs" | awk -F'\t' '!d && $1 == "CLASS" { print $7; d = 1 }' | tr ',' '\n')"
    if [[ "$target" == *Trait ]]; then
      impls="$(printf '%s\n' "$recs" | awk -F'\t' '$1 == "TRAIT" { print $3 }')"
    fi
    for x in $impls $parent; do
      [[ -n "$x" ]] || continue
      sub="$(php_chain_has "$x" "$target" $((depth + 1)))"
      if [[ "$sub" == "yes" ]]; then r="yes"; break; fi
      if [[ "$sub" == "unknown" ]]; then r="unknown"; fi
    done
  fi
  echo "$r" > "$memo"
  echo "$r"
  return 0
}

# php_first_parent FQCN -> the declared parent class (for "verify manually").
php_first_parent() {
  php_class_records "$1" | awk -F'\t' '!d && $1 == "CLASS" { print $6; d = 1 }'
  return 0
}

# php_method_params FILE METHOD -> the parameter names of METHOD's FIRST
# declaration in FILE, one per line without `$`, in order; a variadic
# parameter is printed with a leading `...`. Prints nothing when FILE has no
# such method. Comments, string contents and `#[...]` parameter attributes are
# ignored, so a default value like '$x' is never taken for a parameter.
php_method_params() {
  local f="$1" m="$2"
  [[ -f "$f" ]] || return 0
  AWKV_m="$m" awk '
    BEGIN { m = tolower(ENVIRON["AWKV_m"]); state = 0; buf = "" }
    {
      line = $0
      if (state == 0) {
        l = tolower(line)
        if (match(l, "function[ \t]+&?[ \t]*" m "[ \t]*\\(")) {
          state = 1; buf = substr(line, RSTART + RLENGTH - 1)
        } else next
      } else buf = buf "\n" line
      # Strip comments and strings, then find the closing paren of the list.
      n = length(buf); out = ""; d = 0; instr = ""; inblk = 0; inl = 0; done = 0
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1); nx = substr(buf, i + 1, 1)
        if (inl) { if (c == "\n") inl = 0; continue }
        if (inblk) { if (c == "*" && nx == "/") { inblk = 0; i++ }; continue }
        if (instr != "") { if (c == "\\") { i++; continue }; if (c == instr) instr = ""; continue }
        if (c == "\"" || c == "\047") { instr = c; continue }
        if (c == "/" && nx == "*") { inblk = 1; i++; continue }
        if (c == "/" && nx == "/") { inl = 1; continue }
        if (c == "#" && nx != "[") { inl = 1; continue }
        if (c == "(" || c == "[") d++
        else if (c == ")" || c == "]") { d--; if (d == 0) { done = 1; break } }
        # Parameter attributes #[...] sit at depth 1 followed by `[`: their
        # content is at depth >= 2 and dropped below.
        if (d == 1) out = out c
        else out = out " "
      }
      if (!done) next
      gsub(/#/, " ", out)
      while (match(out, /(\.\.\.[ \t\n]*)?&?[ \t\n]*\$[A-Za-z_][A-Za-z0-9_]*/)) {
        t = substr(out, RSTART, RLENGTH); out = substr(out, RSTART + RLENGTH)
        v = (t ~ /^\.\.\./) ? "..." : ""
        sub(/^.*\$/, "", t)
        print v t
      }
      exit
    }' "$f"
  return 0
}

# php_ctor_params FQCN [DEPTH] -> the constructor parameter names of FQCN (as
# php_method_params), taken from the nearest class of its ancestry that
# declares __construct (php_class_records resolves the parents; set
# PHPSCAN_DIR/PHPSCAN_DOCROOT as for php_chain_has). Prints `?` when the class
# or an ancestor cannot be read, and nothing when no class of the chain declares
# a constructor (it takes no arguments).
php_ctor_params() {
  local fq="$1" depth="${2:-0}" f parent
  if (( depth > 10 )); then echo "?"; return 0; fi
  f="$(php_class_file "$fq")"
  if [[ -z "$f" ]]; then echo "?"; return 0; fi
  if grep -qiE 'function[[:space:]]+__construct[[:space:]]*\(' "$f" 2>/dev/null; then
    php_method_params "$f" __construct
    return 0
  fi
  parent="$(php_first_parent "$fq")"
  [[ -n "$parent" ]] || return 0
  php_ctor_params "$parent" $((depth + 1))
  return 0
}

# php_annotation_keys FILE ANNOTATION -> the top-level keys of the first
# `@ANNOTATION(...)` doc-block tag in FILE, one per line: the `key = value`
# (or `"key" = value`) assignments at nesting depth 1. Keys of nested objects,
# arrays and @Translation(...) arguments are not keys of the plugin annotation.
# Prints nothing for a positional-only tag (`@ViewsField("standard")`).
php_annotation_keys() {
  AWKV_a="$2" awk '
    BEGIN { a = ENVIRON["AWKV_a"]; on = 0; buf = "" }
    {
      line = $0
      if (!on) {
        if (line !~ "^[ \t]*\\*[ \t]*@" a "[ \t]*\\(") next
        sub("^[ \t]*\\*[ \t]*@" a "[ \t]*", "", line); on = 1
      } else {
        if (line ~ /^[ \t]*\*\//) exit
        sub(/^[ \t]*\*[ \t]?/, "", line)
      }
      buf = buf " " line
      n = length(buf); d = 0; instr = 0; qs = 0; prev = ""; done = 0; keys = ""
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        if (instr) {
          if (c != "\"") continue
          if (substr(buf, i + 1, 1) == "\"") { i++; continue }
          instr = 0
          if (qs) {
            k = i + 1; while (k <= n && substr(buf, k, 1) ~ /[ \t]/) k++
            if (substr(buf, k, 1) == "=") keys = keys substr(buf, qs + 1, i - qs - 1) "\n"
          }
          qs = 0; prev = "str"; continue
        }
        if (c == "\"") { instr = 1; qs = (d == 1 && (prev == "(" || prev == ",")) ? i : 0; continue }
        if (c == "(" || c == "{" || c == "[") { d++; prev = c; continue }
        if (c == ")" || c == "}" || c == "]") { d--; prev = c; if (d == 0) { done = 1; break }; continue }
        if (c ~ /[ \t]/) continue
        if (d == 1 && (prev == "(" || prev == ",") && c ~ /[A-Za-z_]/) {
          j = i; while (j <= n && substr(buf, j, 1) ~ /[A-Za-z0-9_]/) j++
          k = j; while (k <= n && substr(buf, k, 1) ~ /[ \t]/) k++
          if (substr(buf, k, 1) == "=") keys = keys substr(buf, i, j - i) "\n"
          i = j - 1; prev = "id"; continue
        }
        prev = c
      }
      if (done) { printf "%s", keys; exit }
    }' "$1"
  return 0
}

# php_code_lines FILE -> FILE's lines with only the PHP code left: comments
# (/* */ across lines, //, and # but not a #[ attribute), the contents of
# '...', "..." and `...` literals (the quotes kept, multi-line ones too), the
# bodies of heredocs and nowdocs, and the inline HTML outside <?php ... ?>
# replaced by spaces. One output line per input line, so a grep on the output
# gives the source's line numbers. A line-oriented tokenizer, not a parser: an
# expression interpolated into a double-quoted string is blanked with it.
# Byte semantics (LC_ALL=C), whatever the file's encoding. Never fails.
php_code_lines() {
  local f="${1:-}"
  [[ -f "$f" ]] || return 0
  LC_ALL=C awk '
function blank(s,   t) { t = s; gsub(/[^\t]/, " ", t); return t }
BEGIN { st = "html"; lbl = "" }
{
  line = $0; n = length(line); i = 1; out = ""
  if (st == "here") {
    t = line; sub(/^[ \t]+/, "", t); k = length(lbl)
    if (substr(t, 1, k) == lbl && (length(t) == k || substr(t, k + 1, 1) !~ /[A-Za-z0-9_]/)) {
      i = n - length(t) + k + 1; out = blank(substr(line, 1, i - 1)); st = "code"
    } else { print ""; next }
  }
  while (i <= n) {
    c = substr(line, i, 1); c2 = substr(line, i, 2)
    if (st == "html") {
      if (c2 == "<?") {
        if (tolower(substr(line, i, 5)) == "<?php") { out = out "     "; i += 5 }
        else if (substr(line, i, 3) == "<?=") { out = out "   "; i += 3 }
        else { out = out "  "; i += 2 }
        st = "code"; continue
      }
      out = out " "; i++; continue
    }
    if (st == "block") {
      if (c2 == "*/") { out = out "  "; i += 2; st = "code" } else { out = out " "; i++ }
      continue
    }
    if (st == "sq" || st == "dq" || st == "bt") {
      q = (st == "sq" ? "\047" : (st == "dq" ? "\"" : "`"))
      if (c == "\\") { out = out "  "; i += 2; continue }
      if (c == q) { out = out c; st = "code" } else { out = out " " }
      i++; continue
    }
    if (c2 == "/*") { out = out "  "; i += 2; st = "block"; continue }
    # A // or # comment runs to the end of the line, or to a ?> (PHP leaves
    # PHP mode there).
    if (c2 == "//" || (c == "#" && substr(line, i + 1, 1) != "[")) {
      p = index(substr(line, i), "?>"); if (p == 0) break
      out = out blank(substr(line, i, p + 1)); i += p + 1; st = "html"; continue
    }
    if (c2 == "?>") { out = out "  "; i += 2; st = "html"; continue }
    if (c == "\047") { out = out c; i++; st = "sq"; continue }
    if (c == "\"") { out = out c; i++; st = "dq"; continue }
    if (c == "`") { out = out c; i++; st = "bt"; continue }
    if (substr(line, i, 3) == "<<<") {
      r = substr(line, i + 3)
      if (match(r, /^[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
        lbl = substr(r, RSTART, RLENGTH); gsub(/[ \t"\047]/, "", lbl)
        out = out "<<<"; st = "here"; break
      }
    }
    out = out c; i++
  }
  print out
}' "$f" 2> /dev/null || true
  return 0
}

# The three scans below read php_code_lines's output (comments and string
# contents blanked, the line numbers kept) as one string: RS is a byte PHP
# code never holds (a file that holds it is still read whole), the lines are
# indexed once with split(), and the candidates are found with index(), so a
# large file costs in step with its size under mawk and BusyBox awk too. A
# file with no candidate is skipped before awk runs.

# php_sort_bool_comparator_lines FILE -> the line of every comparator, passed
# inline to usort(), uasort() or uksort(), that returns a comparison (a bool)
# instead of an int, one line number per finding, in order. PHP 8.0
# deprecated it ("Returning bool from comparison function is deprecated"),
# and Drupal's test runner turns that notice into a failure. FILE is
# php_code_lines's output. A heuristic scan, not a parser: a closure
# (`function`, maybe `static`) or an arrow function written as the second
# argument is followed; a named callback, an array callable or a variable is
# not. A closure's reported line is that of a `return` whose expression has,
# at its top level (outside brackets, and after any outer parentheses are
# stripped), a comparison (<, >, <=, >=, ==, !=, ===, !==, <>), && or ||, or
# is true/false or a negation alone (`!$a`, `!empty($a)`; not `!$a - !$b`),
# and has neither <=> nor a ternary; an arrow function's, the line of its =>.
# A closure or arrow function that declares a return type other than bool is
# skipped (PHP converts what it returns), and so are the returns of a closure
# nested in the comparator.
php_sort_bool_comparator_lines() {
  local f="${1:-}"
  [[ -f "$f" ]] || return 0
  LC_ALL=C grep -q -i -E 'u[ak]?sort' "$f" 2> /dev/null || return 0
  LC_ALL=C awk '
function ws(k) { while (k <= n && substr(buf, k, 1) ~ /[ \t\n\r]/) k++; return k }
function isid(c) { return c ~ /[A-Za-z0-9_$\\]/ }
# shut(k) -> the position of the bracket that closes the one at k (n + 1
# when none does).
function shut(k,   d, ch) {
  d = 0
  for (; k <= n; k++) {
    ch = substr(buf, k, 1)
    if (ch == "(" || ch == "[" || ch == "{") d++
    else if (ch == ")" || ch == "]" || ch == "}") { d--; if (d == 0) return k }
  }
  return n + 1
}
# lineof(k) -> the line of position k (a binary search of the line starts).
function lineof(k,   lo, hi, mid) {
  lo = 1; hi = nl
  while (lo < hi) { mid = int((lo + hi + 1) / 2); if (bs[mid] <= k) lo = mid; else hi = mid - 1 }
  return lo
}
function trim(s) { gsub(/^[ \t\n\r]+|[ \t\n\r]+$/, "", s); return s }
# isbool(e) -> 1 when the expression e reads as a bool (see the header).
function isbool(e,   m, d, k, ch, c2, c3, found, op, neg, ee, dd, kk, cc) {
  e = trim(e)
  # Strip outer parentheses that enclose the whole expression.
  while (substr(e, 1, 1) == "(") {
    m = length(e); dd = 0
    for (kk = 1; kk <= m; kk++) {
      cc = substr(e, kk, 1)
      if (cc == "(" || cc == "[" || cc == "{") dd++
      else if (cc == ")" || cc == "]" || cc == "}") { dd--; if (dd == 0) break }
    }
    if (kk != m) break
    e = trim(substr(e, 2, m - 2))
  }
  ee = tolower(e)
  if (ee == "true" || ee == "false") return 1
  neg = (substr(e, 1, 1) == "!" && substr(e, 2, 1) != "=")
  m = length(e); d = 0; found = 0; op = 0
  for (k = 1; k <= m; k++) {
    ch = substr(e, k, 1)
    if (ch == "(" || ch == "[" || ch == "{") { d++; continue }
    if (ch == ")" || ch == "]" || ch == "}") { d--; continue }
    if (d > 0) continue
    c3 = substr(e, k, 3); c2 = substr(e, k, 2)
    if (c3 == "<=>") return 0
    if (c3 == "===" || c3 == "!==") { found = 1; k += 2; continue }
    if (c3 == "?->") { k += 2; continue }
    if (c2 == "??") { op = 1; k++; continue }
    if (ch == "?") return 0
    if (c2 == "->" || c2 == "=>" || c2 == "::") { k++; continue }
    if (c2 == "<<" || c2 == ">>") { op = 1; k++; continue }
    if (c2 == "==" || c2 == "!=" || c2 == "<>" || c2 == "<=" || c2 == ">=" || c2 == "&&" || c2 == "||") { found = 1; k++; continue }
    if (ch == "<" || ch == ">") { found = 1; continue }
    if (k > 1 && (ch == "+" || ch == "-" || ch == "*" || ch == "/" || ch == "%" || ch == "." || ch == "&" || ch == "|" || ch == "^")) op = 1
  }
  if (found) return 1
  # A leading ! is a bool only when nothing applies to the negated operand
  # after it (!$a - !$b is an int).
  return (neg && !op)
}
# rtype(k, stop) -> the return type declared from k (after a ":") up to the
# position stop, lowercased, without a leading "?"; "" when none is declared.
function rtype(k, stop,   t) {
  k = ws(k)
  if (substr(buf, k, 1) != ":") return ""
  t = tolower(trim(substr(buf, k + 1, stop - k - 1))); sub(/^\?/, "", t)
  return t
}
# A closure: the keyword function ends just before k.
function closure(k,   p, b, e, ch, t, r, x, stop, q) {
  k = ws(k)
  if (substr(buf, k, 1) == "&") k = ws(k + 1)
  if (substr(buf, k, 1) != "(") return
  p = shut(k); k = ws(p + 1)
  if (substr(lb, k, 3) == "use" && !isid(substr(buf, k + 3, 1))) {
    k = ws(k + 3)
    if (substr(buf, k, 1) != "(") return
    k = ws(shut(k) + 1)
  }
  b = index(substr(buf, k, 4096), "{"); if (b == 0) return
  b = k + b - 1
  t = rtype(k, b)
  if (t != "" && t != "bool") return
  e = shut(b)
  # Each return of this body, the bodies of nested closures skipped.
  for (x = b + 1; x < e; x++) {
    ch = substr(lb, x, 1)
    if (ch == "f" && substr(lb, x, 8) == "function" && !isid(substr(buf, x - 1, 1)) && !isid(substr(buf, x + 8, 1))) {
      q = index(substr(buf, x, e - x), "{"); if (q == 0) break
      x = shut(x + q - 1); continue
    }
    if (ch == "r" && substr(lb, x, 6) == "return" && !isid(substr(buf, x - 1, 1)) && !isid(substr(buf, x + 6, 1))) {
      stop = x + 6
      while (stop < e) {
        r = substr(buf, stop, 1)
        if (r == ";") break
        if (r == "(" || r == "[" || r == "{") { stop = shut(stop) + 1; continue }
        stop++
      }
      if (isbool(substr(buf, x + 6, stop - x - 6))) print lineof(x)
      x = stop
    }
  }
}
# An arrow function: the keyword fn ends just before k; its body runs to the
# comma or the parenthesis that ends the argument.
function arrow(k,   p, a, stop, r, t) {
  k = ws(k)
  if (substr(buf, k, 1) == "&") k = ws(k + 1)
  if (substr(buf, k, 1) != "(") return
  p = shut(k); k = p + 1
  a = index(substr(buf, k, 4096), "=>"); if (a == 0) return
  a = k + a - 1
  t = rtype(k, a)
  if (t != "" && t != "bool") return
  stop = a + 2
  while (stop <= n) {
    r = substr(buf, stop, 1)
    if (r == "," || r == ")" || r == "]" || r == "}" || r == ";") break
    if (r == "(" || r == "[" || r == "{") { stop = shut(stop) + 1; continue }
    stop++
  }
  if (isbool(substr(buf, a + 2, stop - a - 2))) print lineof(a)
}
# A call: its first top-level comma starts the comparator.
function call(k,   d, ch) {
  d = 0
  for (; k <= n; k++) {
    ch = substr(buf, k, 1)
    if (ch == "(" || ch == "[" || ch == "{") d++
    else if (ch == ")" || ch == "]" || ch == "}") { d--; if (d == 0) return }
    else if (ch == "," && d == 1) break
  }
  if (k > n) return
  k = ws(k + 1)
  if (substr(lb, k, 6) == "static" && substr(buf, k + 6, 1) ~ /[ \t\n\r]/) k = ws(k + 6)
  if (substr(lb, k, 8) == "function" && !isid(substr(buf, k + 8, 1))) closure(k + 8)
  else if (substr(lb, k, 2) == "fn" && !isid(substr(buf, k + 2, 1))) arrow(k + 2)
}
# find(w) -> follows every call of the function w (lowercase).
function find(w,   pos, p, i, pc, j) {
  pos = 1
  while ((p = index(substr(lb, pos), w)) > 0) {
    i = pos + p - 1; pos = i + length(w)
    pc = (i > 1) ? substr(buf, i - 1, 1) : " "
    if (pc ~ /[A-Za-z0-9_$>:]/ || isid(substr(buf, i + length(w), 1))) continue
    j = ws(i + length(w))
    if (substr(buf, j, 1) == "(") call(j)
  }
}
BEGIN { RS = "\001" }
{ buf = buf (NR > 1 ? "\001" : "") $0 }
END {
  n = length(buf); lb = tolower(buf)
  nl = split(buf, L, "\n"); bs[1] = 1
  for (i = 2; i <= nl; i++) bs[i] = bs[i - 1] + length(L[i - 1]) + 1
  find("usort"); find("uasort"); find("uksort")
}' "$f" 2> /dev/null | LC_ALL=C sort -n -u || true
  return 0
}

# The awk program of php_bc_fallback_calls and php_bc_blank_fallbacks.
_PHP_BC_AWK='
function shut(k,   d, ch) {
  d = 0
  for (; k <= n; k++) {
    ch = substr(buf, k, 1)
    if (ch == "(" || ch == "[" || ch == "{") d++
    else if (ch == ")" || ch == "]" || ch == "}") { d--; if (d == 0) return k }
  }
  return n + 1
}
function lineof(k,   lo, hi, mid) {
  lo = 1; hi = nl
  while (lo < hi) { mid = int((lo + hi + 1) / 2); if (bs[mid] <= k) lo = mid; else hi = mid - 1 }
  return lo
}
function trim(s) { gsub(/^[ \t\n\r]+|[ \t\n\r]+$/, "", s); return s }
function isid(c) { return c ~ /[A-Za-z0-9_$]/ }
# spans() -> sa/sb/sv[1..ns]: the fourth-argument closures and their versions.
function spans(   pos, p, i, j, k, e, d, ch, na, a4, b4, q, l, col, v, t, x) {
  pos = 1; ns = 0
  while ((p = index(substr(lb, pos), "backwardscompatiblecall")) > 0) {
    i = pos + p - 1; pos = i + 23
    # Preceded by DeprecationHelper:: (blanks allowed around ::).
    k = i - 1; while (k > 0 && substr(buf, k, 1) ~ /[ \t\n\r]/) k--
    if (substr(buf, k - 1, 2) != "::") continue
    k -= 2; while (k > 0 && substr(buf, k, 1) ~ /[ \t\n\r]/) k--
    if (k < 17 || substr(lb, k - 16, 17) != "deprecationhelper") continue
    j = i + 23; while (substr(buf, j, 1) ~ /[ \t\n\r]/) j++
    if (substr(buf, j, 1) != "(") continue
    e = shut(j)
    na = 0; d = 0; st[1] = j + 1
    for (x = j; x < e; x++) {
      ch = substr(buf, x, 1)
      if (ch == "(" || ch == "[" || ch == "{") d++
      else if (ch == ")" || ch == "]" || ch == "}") d--
      else if (ch == "," && d == 1) { na++; en[na] = x - 1; st[na + 1] = x + 1 }
    }
    na++; en[na] = e - 1
    if (na < 4) continue
    if (trim(substr(buf, st[1], en[1] - st[1] + 1)) ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*:[^:]/) continue
    a4 = st[4]; while (substr(buf, a4, 1) ~ /[ \t\n\r]/) a4++
    b4 = en[4]; while (b4 > a4 && substr(buf, b4, 1) ~ /[ \t\n\r]/) b4--
    t = tolower(substr(buf, a4, 16)); sub(/^static[ \t\n\r]+/, "", t)
    if (t !~ /^(fn|function)[ \t\n\r(&]/) continue
    # The version: the quoted second argument, read from RAW at its line and
    # column in BLANKED.
    q = st[2]; while (substr(buf, q, 1) ~ /[ \t\n\r]/) q++
    x = en[2]; while (x > q && substr(buf, x, 1) ~ /[ \t\n\r]/) x--
    v = "?"; l = lineof(q)
    if ((substr(buf, q, 1) == "\047" || substr(buf, q, 1) == "\"") && lineof(x) == l) {
      col = q - bs[l] + 1
      t = substr(R[l], col, x - q + 1)
      if (t ~ /^\047[0-9][0-9.]*\047$/ || t ~ /^"[0-9][0-9.]*"$/) v = substr(t, 2, length(t) - 2)
    }
    ns++; sa[ns] = a4; sb[ns] = b4; sv[ns] = v
  }
}
BEGIN { RS = "\001" }
FNR == NR { buf = buf (FNR > 1 ? "\001" : "") $0; next }
{ raw = raw (FNR > 1 ? "\001" : "") $0 }
END {
  n = length(buf); lb = tolower(buf)
  nl = split(buf, L, "\n"); bs[1] = 1
  for (i = 2; i <= nl; i++) bs[i] = bs[i - 1] + length(L[i - 1]) + 1
  split(raw, R, "\n")
  spans()
  # The blank mode: the file with every fallback closure blanked.
  if (ENVIRON["AWKV_MODE"] == "blank") {
    out = buf
    for (s = 1; s <= ns; s++) {
      seg = substr(out, sa[s], sb[s] - sa[s] + 1); gsub(/[^\n]/, " ", seg)
      out = substr(out, 1, sa[s] - 1) seg substr(out, sb[s] + 1)
    }
    printf "%s", out
    exit
  }
  nn = split(ENVIRON["AWKV_N"], N, " ")
  for (z = 1; z <= nn; z++) {
    w = N[z]; if (w == "") continue
    pos = 1
    while ((p = index(substr(lb, pos), w)) > 0) {
      i = pos + p - 1; pos = i + length(w)
      if (isid(substr(buf, i + length(w), 1))) continue
      k = i - 1; pc = (k > 0) ? substr(buf, k, 1) : " "
      if (pc == "\\") { k--; pc = (k > 0) ? substr(buf, k, 1) : " " ; if (pc ~ /[A-Za-z0-9_\\]/) continue }
      else if (isid(pc) || pc == "\\") continue
      # Not a method or a static call, not a declaration nor a new.
      k2 = k; while (k2 > 0 && substr(buf, k2, 1) ~ /[ \t\n\r]/) k2--
      t = substr(lb, (k2 > 8 ? k2 - 7 : 1), (k2 > 8 ? 8 : k2))
      if (substr(buf, k2 - 1, 2) == "->" || substr(buf, k2 - 1, 2) == "::") continue
      if (t ~ /(^|[^a-z0-9_])function$/ || t ~ /(^|[^a-z0-9_])new$/) continue
      j = i + length(w); while (substr(buf, j, 1) ~ /[ \t\n\r]/) j++
      if (substr(buf, j, 1) != "(") continue
      best = 0
      for (s = 1; s <= ns; s++) if (sa[s] <= i && i <= sb[s] && (best == 0 || sb[s] - sa[s] < sb[best] - sa[best])) best = s
      printf "%d\t%s\t%s\n", lineof(i), w, (best ? sv[best] : "-")
    }
  }
}
'

# php_bc_fallback_calls BLANKED RAW NAMES -> "LINE<TAB>NAME<TAB>VERSION" for
# every call of a function of NAMES (space-separated, lowercase) in the file:
# VERSION is the second argument of the innermost
# DeprecationHelper::backwardsCompatibleCall() whose fourth argument, a
# closure or an arrow function written there (`fn`, `function`, maybe
# `static`), holds the call (that fallback runs only on a core older than
# it), "?" when that argument is not a quoted version, "-" when the call is
# in no such fallback. A file with no backwardsCompatibleCall() at all prints
# nothing (none of its calls can be guarded). A call is NAME( not after ->,
# ::, $, a name, `new` or `function` (a declaration); a leading \ (a fully
# qualified call) is fine. BLANKED is php_code_lines's output for RAW: the
# two have the same lines, and a line's code keeps its columns
# (php_code_lines blanks string contents in place and cuts a comment off the
# end), so the version is read from RAW at the line and column of its quotes
# in BLANKED. A first-class callable as the fourth argument itself is created
# before backwardsCompatibleCall() runs: no span. A call with named arguments
# is skipped. A heuristic scan, not a parser.
php_bc_fallback_calls() {
  local b="${1:-}" r="${2:-}" names="${3:-}"
  [[ -f "$b" && -f "$r" && -n "$names" ]] || return 0
  LC_ALL=C grep -q -i 'backwardscompatiblecall' "$b" 2> /dev/null || return 0
  AWKV_N="$names" LC_ALL=C awk "$_PHP_BC_AWK" "$b" "$r" 2> /dev/null || true
  return 0
}

# php_bc_blank_fallbacks BLANKED RAW -> BLANKED with the fallback closure of
# every DeprecationHelper::backwardsCompatibleCall() (the spans
# php_bc_fallback_calls reads) blanked, the lines kept: the code a target
# core runs. BLANKED unchanged when the file has no such call.
php_bc_blank_fallbacks() {
  local b="${1:-}" r="${2:-}"
  [[ -f "$b" && -f "$r" ]] || return 0
  if ! LC_ALL=C grep -q -i 'backwardscompatiblecall' "$b" 2> /dev/null; then cat "$b"; return 0; fi
  AWKV_MODE=blank LC_ALL=C awk "$_PHP_BC_AWK" "$b" "$r" 2> /dev/null || true
  return 0
}

# php_markup_label_lines FILE -> "LINE<TAB>CALL" for every submitForm() whose
# second argument, and every buttonExists() / buttonNotExists() whose first
# argument, is a translated string object ($this->t(...), t(...),
# $this->formatPlural(...), new TranslatableMarkup(...)) rather than a
# string; LINE is the argument's. A (string) cast or a literal is fine. FILE
# is php_code_lines's output. A heuristic scan, not a parser: a method call
# (->) only, the call may span lines.
php_markup_label_lines() {
  local f="${1:-}"
  [[ -f "$f" ]] || return 0
  LC_ALL=C grep -q -i -E 'submitform|button(not)?exists' "$f" 2> /dev/null || return 0
  LC_ALL=C awk '
function shut(k,   d, ch) {
  d = 0
  for (; k <= n; k++) {
    ch = substr(buf, k, 1)
    if (ch == "(" || ch == "[" || ch == "{") d++
    else if (ch == ")" || ch == "]" || ch == "}") { d--; if (d == 0) return k }
  }
  return n + 1
}
function lineof(k,   lo, hi, mid) {
  lo = 1; hi = nl
  while (lo < hi) { mid = int((lo + hi + 1) / 2); if (bs[mid] <= k) lo = mid; else hi = mid - 1 }
  return lo
}
function markup(s) {
  sub(/^[ \t\n\r]+/, "", s)
  return s ~ /^(\$this[ \t\n\r]*->[ \t\n\r]*(t|formatPlural)|\\?t|new[ \t\n\r]+\\?([A-Za-z0-9_]+\\)*TranslatableMarkup)[ \t\n\r]*\(/
}
# scan(w, name, want) -> each ->w( call whose argument want is translated.
function scan(w, name, want,   pos, p, i, j, k, e, d, arg, st, x, ch, a, q) {
  pos = 1
  while ((p = index(substr(lb, pos), w)) > 0) {
    i = pos + p - 1; pos = i + length(w)
    if (substr(buf, i + length(w), 1) ~ /[A-Za-z0-9_]/) continue
    k = i - 1; while (k > 0 && substr(buf, k, 1) ~ /[ \t\n\r]/) k--
    if (k < 2 || substr(buf, k - 1, 2) != "->") continue
    j = i + length(w); while (substr(buf, j, 1) ~ /[ \t\n\r]/) j++
    if (substr(buf, j, 1) != "(") continue
    e = shut(j); d = 0; arg = 1; st = j + 1
    for (x = j; x < e; x++) {
      ch = substr(buf, x, 1)
      if (ch == "(" || ch == "[" || ch == "{") d++
      else if (ch == ")" || ch == "]" || ch == "}") d--
      else if (ch == "," && d == 1) {
        if (arg == want) break
        arg++; st = x + 1
      }
    }
    if (arg != want) continue
    a = substr(buf, st, (x < e ? x : e) - st)
    if (markup(a)) { q = st; while (substr(buf, q, 1) ~ /[ \t\n\r]/) q++; printf "%d\t%s\n", lineof(q), name }
  }
}
BEGIN { RS = "\001" }
{ buf = buf (NR > 1 ? "\001" : "") $0 }
END {
  n = length(buf); lb = tolower(buf)
  nl = split(buf, L, "\n"); bs[1] = 1
  for (i = 2; i <= nl; i++) bs[i] = bs[i - 1] + length(L[i - 1]) + 1
  scan("submitform", "submitForm", 2); scan("buttonexists", "buttonExists", 1); scan("buttonnotexists", "buttonNotExists", 1)
}' "$f" 2> /dev/null | LC_ALL=C sort -n -s -k1,1 || true
  return 0
}

# php_phpunit_hidden_metadata FILE -> "LINE<TAB>LEVEL<TAB>HIDDEN<TAB>TWINS<TAB>
# RELATIVE" for every class or method of a test FILE whose doc-comment carries
# PHPUnit metadata that PHPUnit 10+ ignores. PHPUnit reads the metadata of one
# level (the class, or one method) from its attributes when it has any — an
# attribute naming a class of PHPUnit\Framework\Attributes\, through the
# file's imports — and from its doc-comment only otherwise. LINE is the
# level's first PHPUnit attribute; LEVEL is Class or Class::method; HIDDEN the
# annotations that have no attribute twin at that level and TWINS the
# attribute that carries each one ("; "-separated); RELATIVE, for a class
# whose @coversDefaultClass or @usesDefaultClass is ignored that way, the
# relative @covers ::name / @uses ::name its methods still have (invalid
# without it), each with its line. A @coversDefaultClass with no relative
# @covers is no finding. FILE is the raw source (the doc-comments are read).
# A line-oriented heuristic, not a parser: one class per file, attributes on
# lines of their own.
php_phpunit_hidden_metadata() {
  local f="${1:-}"
  [[ -f "$f" ]] || return 0
  LC_ALL=C grep -q -F '#[' "$f" 2> /dev/null || return 0
  LC_ALL=C awk '
function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
function unq(s) { s = trim(s); sub(/^[\047"]/, "", s); sub(/[\047"]$/, "", s); return s }
function add_import(t,   nm, al) {
  t = trim(t); nm = t; al = t
  if (match(t, /[ \t]+as[ \t]+/)) { nm = trim(substr(t, 1, RSTART - 1)); al = trim(substr(t, RSTART + RLENGTH)) }
  if (nm != "" && al != "") imp[al] = nm
}
# pu(NAME) -> the PHPUnit attribute NAME resolves to (its short name), or "".
function pu(n,   k, p) {
  n = trim(n); sub(/^\\/, "", n)
  if (index(n, PFX "\\") == 1) return substr(n, length(PFX) + 2)
  k = index(n, "\\")
  if (k > 0) { p = substr(n, 1, k - 1); return (p in nsal) ? substr(n, k + 1) : "" }
  return (n in imp) ? imp[n] : ""
}
function add_attr(e, ln,   k, nm, args, s) {
  e = trim(e); if (e == "") return
  k = index(e, "(")
  if (k > 0) { nm = substr(e, 1, k - 1); args = substr(e, k + 1); sub(/\)[ \t\r\n]*$/, "", args) }
  else { nm = e; args = "" }
  s = pu(nm)
  if (s == "") return
  na++; an[na] = tolower(s); aa[na] = trim(args)
  if (al == 0) al = ln
}
# parse_attrs(TEXT, LINE): every attribute of the #[...] groups in TEXT.
function parse_attrs(b, ln,   i, n, c, q, pd, bd, ent) {
  n = length(b); q = ""; pd = 0; bd = 0; ent = ""
  for (i = 1; i <= n; i++) {
    c = substr(b, i, 1)
    if (q != "") { ent = ent c; if (c == "\\") { i++; ent = ent substr(b, i, 1) } else if (c == q) q = ""; continue }
    if (bd == 0) { if (c == "#" && substr(b, i + 1, 1) == "[") { bd = 1; pd = 0; ent = ""; i++ }; continue }
    if (c == "\047" || c == "\"") { q = c; ent = ent c; continue }
    if (c == "(") pd++
    else if (c == ")") pd--
    else if (c == "[") bd++
    else if (c == "]") { bd--; if (bd == 0) { add_attr(ent, ln); ent = ""; continue } }
    if (c == "," && pd == 0 && bd == 1) { add_attr(ent, ln); ent = ""; continue }
    ent = ent c
  }
}
# depth(TEXT) -> the open [ count after TEXT (quoted strings left out).
function depth(s,   t, i, c) {
  t = s; gsub(/\047[^\047]*\047/, "", t); gsub(/"[^"]*"/, "", t)
  for (i = 1; i <= length(t); i++) { c = substr(t, i, 1); if (c == "[") ad++; else if (c == "]") ad-- }
  return ad
}
function doc_line(s,   t, v) {
  t = s; sub(/^[ \t]*\/\*\*/, "", t); sub(/\*\/[ \t\r]*$/, "", t); sub(/^[ \t]*\*?[ \t]*/, "", t)
  if (!match(t, /^@[A-Za-z]+/)) return
  v = trim(substr(t, RLENGTH + 1)); gsub(/\t/, " ", v)
  nd++; dt[nd] = substr(t, 2, RLENGTH - 1); dv[nd] = v; dl[nd] = NR
}
# twin(TAG, VALUE) -> 1 when the attributes of the level carry TAG.
function twin(t, v,   i, x) {
  x = tolower(t)
  for (i = 1; i <= na; i++) {
    if (x == "group" || x == "ticket") { if (an[i] == x && unq(aa[i]) == v) return 1; continue }
    if (x == "covers" || x == "uses") { if (an[i] ~ ("^" x "(class|function|method|trait)$")) return 1; continue }
    if (x == "backupstaticattributes" || x == "backupstaticproperties") { if (an[i] == "backupstaticproperties") return 1; continue }
    if (x == "dataprovider" || x == "depends" || x == "testwith") { if (index(an[i], x) == 1) return 1; continue }
    if (an[i] == x) return 1
  }
  return 0
}
function sugg(t, v,   x) {
  x = tolower(t)
  if (x == "group") return "#[Group(\047" v "\047)]"
  if (x == "ticket") return "#[Ticket(\047" v "\047)]"
  if (x == "dataprovider") return "#[DataProvider(\047" v "\047)]"
  if (x == "depends") return "#[Depends(\047" v "\047)]"
  if (x == "covers") return "#[CoversClass(...)] or #[CoversFunction(...)]"
  if (x == "uses") return "#[UsesClass(...)] or #[UsesFunction(...)]"
  if (x == "testdox") return "#[TestDox(...)]"
  if (x == "testwith") return "#[TestWith(...)]"
  if (x == "backupstaticattributes" || x == "backupstaticproperties") return "#[BackupStaticProperties(...)]"
  return "#[" toupper(substr(t, 1, 1)) substr(t, 2) "]"
}
function level(name, kind,   k, h, w) {
  if (kind == "class") { cls = name; cdc = 0; cline = 0; chid = ""; ctw = "" }
  if (na == 0) {
    if (kind == "method" && cdc) {
      for (k = 1; k <= nd; k++) if ((dt[k] == "covers" || dt[k] == "uses") && dv[k] ~ /^::/)
        rel = rel (rel == "" ? "" : "; ") "@" dt[k] " " dv[k] " (line " dl[k] ")"
    }
    return
  }
  h = ""; w = ""
  for (k = 1; k <= nd; k++) {
    if (kind == "class" && (dt[k] == "coversDefaultClass" || dt[k] == "usesDefaultClass")) { cdc = 1; continue }
    if (!(dt[k] in meta) || twin(dt[k], dv[k])) continue
    h = h (h == "" ? "" : "; ") "@" dt[k] (dv[k] == "" ? "" : " " dv[k])
    w = w (w == "" ? "" : "; ") sugg(dt[k], dv[k])
  }
  if (kind == "class") { cline = al; chid = h; ctw = w; return }
  if (h != "") printf "%d\t%s\t%s\t%s\t\n", al, name, h, w
}
function reset() { nd = 0; na = 0; al = 0 }
BEGIN {
  PFX = "PHPUnit\\Framework\\Attributes"
  n = split("after afterClass backupGlobals backupStaticAttributes backupStaticProperties before beforeClass covers coversNothing dataProvider depends doesNotPerformAssertions excludeGlobalVariableFromBackup excludeStaticPropertyFromBackup group large medium postCondition preCondition preserveGlobalState runClassInSeparateProcess runInSeparateProcess runTestsInSeparateProcesses small test testdox testWith ticket uses", T, " ")
  for (i = 1; i <= n; i++) meta[T[i]] = 1
}
{
  raw = $0; sub(/\r$/, "", raw)
  if (indoc) { doc_line(raw); if (raw ~ /\*\//) indoc = 0; next }
  if (incom) { if (raw ~ /\*\//) incom = 0; next }
  if (inattr) { abuf = abuf "\n" raw; if (depth(raw) <= 0) { inattr = 0; parse_attrs(abuf, aln) }; next }
  if (raw ~ /^[ \t]*\/\*\*/) {
    nd = 0; doc_line(raw); t = raw; sub(/^[ \t]*\/\*\*/, "", t)
    if (t !~ /\*\//) indoc = 1
    next
  }
  if (raw ~ /^[ \t]*\/\*/) { t = raw; sub(/^[ \t]*\/\*/, "", t); if (t !~ /\*\//) incom = 1; next }
  if (raw ~ /^[ \t]*$/ || raw ~ /^[ \t]*\/\// || (raw ~ /^[ \t]*#/ && raw !~ /^[ \t]*#\[/)) next
  if (raw ~ /^[ \t]*#\[/) {
    abuf = raw; aln = NR; ad = 0
    if (depth(raw) <= 0) parse_attrs(abuf, aln); else inattr = 1
    next
  }
  if (!seen && raw ~ /^[ \t]*use[ \t]/) {
    t = raw; sub(/^[ \t]*use[ \t]+/, "", t); sub(/;.*$/, "", t); t = trim(t); sub(/^\\/, "", t)
    if (index(t, PFX "\\{") == 1) { g = substr(t, length(PFX) + 3); sub(/}.*$/, "", g); m = split(g, P, ","); for (i = 1; i <= m; i++) add_import(P[i]) }
    else if (index(t, PFX "\\") == 1) add_import(substr(t, length(PFX) + 2))
    else if (t == PFX) nsal["Attributes"] = 1
    else if (index(t, PFX) == 1 && match(t, /[ \t]+as[ \t]+[A-Za-z0-9_]+$/)) { g = substr(t, RSTART); sub(/^[ \t]+as[ \t]+/, "", g); nsal[g] = 1 }
    reset(); next
  }
  if (raw ~ /^[ \t]*((abstract|final|readonly)[ \t]+)*class[ \t]+[A-Za-z_]/) {
    t = raw; sub(/^[ \t]*((abstract|final|readonly)[ \t]+)*class[ \t]+/, "", t); match(t, /^[A-Za-z_][A-Za-z0-9_]*/)
    seen = 1; level(substr(t, 1, RLENGTH), "class"); reset(); next
  }
  if (seen && raw ~ /function[ \t]+&?[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*\(/) {
    t = raw; sub(/^.*function[ \t]+&?[ \t]*/, "", t); match(t, /^[A-Za-z_][A-Za-z0-9_]*/)
    level(cls "::" substr(t, 1, RLENGTH), "method"); reset(); next
  }
  reset()
}
END { if (cls != "" && (chid != "" || rel != "")) printf "%d\t%s\t%s\t%s\t%s\n", cline, cls, chid, ctw, rel }' "$f" 2> /dev/null | LC_ALL=C sort -n -s -k1,1 || true
  return 0
}

# php_magic_property_lines FILE PROP -> "LINE<TAB>OP" for every access to the
# property PROP through ->, nullsafe ?-> included, that is not a method call:
# OP is set (an assignment to it), unset (inside unset(...)), isset (inside
# isset(...) or empty(...)) or get (a read). $this->PROP is skipped when the
# file declares a property of that name. FILE is php_code_lines's output
# (comments and string contents blanked). A heuristic for a magic property
# PHPStan cannot see (e.g. the deprecated $entity->original): it cannot tell
# an entity from another receiver.
php_magic_property_lines() {
  local f="${1:-}" p="${2:-}"
  [[ -f "$f" && "$p" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
  LC_ALL=C grep -q -F -e "->$p" "$f" 2> /dev/null || return 0
  AWKV_p="$p" LC_ALL=C awk '
BEGIN { p = ENVIRON["AWKV_p"]; re = "(\\?)?->[ \t]*" p }
{ L[NR] = $0; if ($0 ~ ("(public|protected|private|var)[ \t][^;=(]*\\$" p "([^A-Za-z0-9_]|$)")) own = 1 }
END {
  for (n = 1; n <= NR; n++) {
    s = L[n]; off = 0
    while (match(s, re)) {
      st = off + RSTART; en = off + RSTART + RLENGTH
      s = substr(s, RSTART + RLENGTH); off = en - 1
      rest = substr(L[n], en); pre = substr(L[n], 1, st - 1)
      if (rest ~ /^[A-Za-z0-9_]/) continue
      if (rest ~ /^[ \t]*\(/) continue
      if (own && pre ~ /\$this[ \t]*$/) continue
      op = "get"
      if (rest ~ /^[ \t]*(=[^=>]|=$|\?\?=)/) op = "set"
      else if (pre ~ /unset[ \t]*\([^)]*$/) op = "unset"
      else if (pre ~ /(isset|empty)[ \t]*\([^)]*$/) op = "isset"
      printf "%d\t%s\n", n, op
    }
  }
}' "$f" 2> /dev/null || true
  return 0
}
