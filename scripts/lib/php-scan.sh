#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/php-scan.sh
# Shared, dependency-free PHP class heuristics (bash + POSIX awk; no PHP needed,
# so it runs on the host without the toolchain). Sourced by
# scripts/analysis/check-port-safety.sh; meant to be reused by any later
# analysis script that needs class headers, imports or methods, instead of
# re-parsing PHP on its own.
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
  firstp = ""; secondp = ""
  if (inner == "") return 0
  d = 0; n = 1; first = ""; second = ""
  for (i = 1; i <= length(inner); i++) {
    c = substr(inner, i, 1)
    if (c == "(" || c == "[") d++
    else if (c == ")" || c == "]") d--
    else if (c == "," && d == 0) { n++; continue }
    if (n == 1) first = first c
    else if (n == 2) second = second c
  }
  firstp = trim(first); gsub(/[[:space:]]+/, " ", firstp)
  secondp = trim(second); gsub(/[[:space:]]+/, " ", secondp)
  return n
}
function promoted(text, line,   parts, k, m, p, mods, name, w, wn, j) {
  m = split(text, parts, ",")
  for (k = 1; k <= m; k++) {
    p = trim(parts[k]); sub(/^\(/, "", p); p = trim(p)
    if (p !~ /^(public|protected|private|readonly)[[:space:]]/) continue
    wn = split(p, w, /[[:space:]]+/); mods = ""; name = ""
    for (j = 1; j <= wn; j++) {
      if (w[j] ~ /^(public|protected|private|readonly)$/) mods = mods (mods == "" ? "" : ",") w[j]
      if (name == "" && w[j] ~ /^&?\.{0,3}\$[A-Za-z_]/) { name = w[j]; sub(/^[^$]*\$/, "", name); sub(/[^A-Za-z0-9_].*$/, "", name) }
    }
    if (name != "") print "PROP\t" line "\t" cls "\t" mods "\t" name "\t1\t0"
  }
}
BEGIN { depth = 0; ns = ""; cls = ""; clsdepth = -1; hdr = ""; inhdr = 0; insig = 0; meth = ""; inmeth = 0; inblock = 0; instr = "" }
{
  raw = $0; c = clean(raw); d0 = depth
  opens = count(c, "[{]"); closes = count(c, "[}]")

  if (inhdr) {
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
          insig = 0
          if (index(rest, "{") > 0) { inmeth = 1 } else { meth = "" }
        }
      }
    }
    if (inmeth) {
      if (c ~ /new[[:space:]]+self[[:space:]]*\(/) print "NEWSELF\t" NR "\t" cls "\t" meth
      if (c ~ /new[[:space:]]+static[[:space:]]*\(/) print "NEWSTATIC\t" NR "\t" cls "\t" meth
    }
  }

  depth = d0 + opens - closes
  if (inmeth && depth <= clsdepth + 1) { inmeth = 0; meth = "" }
  if (cls != "" && !inhdr && depth <= clsdepth) { cls = ""; clsdepth = -1; inmeth = 0; insig = 0; meth = "" }
}
' "$f" 2>/dev/null || true
  return 0
}
