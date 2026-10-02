#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/php-scan.sh
# Shared, dependency-free PHP class heuristics (bash + POSIX awk; no PHP needed,
# so it runs on the host without the toolchain). Sourced by
# scripts/analysis/check-port-safety.sh and scan-signature-changes.sh; meant to
# be reused by any later analysis script that needs class headers, imports,
# methods or ancestry, instead of re-parsing PHP on its own (the class index and
# php_chain_has ancestry resolver are at the end of this file).
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
    parent="$(printf '%s\n' "$recs" | awk -F'\t' '$1 == "CLASS" { print $6; exit }')"
    impls="$(printf '%s\n' "$recs" | awk -F'\t' '$1 == "CLASS" { print $7; exit }' | tr ',' '\n')"
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
  php_class_records "$1" | awk -F'\t' '$1 == "CLASS" { print $6; exit }'
  return 0
}
