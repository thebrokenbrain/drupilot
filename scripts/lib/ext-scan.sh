#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/ext-scan.sh
# Shared, dependency-free scan of a SET of Drupal extensions (bash + POSIX awk
# + jq; no PHP, no YAML parser). Sourced (after common.sh) by
# scripts/analysis/layers.sh and scripts/analysis/lint-extension-metadata.sh,
# so the dependency graph and the "undeclared dependency" findings come from
# ONE implementation.
#
#   ext_scan_json DIR [KNOWN_DIR...] -> one JSON object on stdout:
#     {root, extensions:[{machine, type, name, package, dir, parent, project,
#       core_version_requirement, configure, info_file, test,
#       declared:[{entry, module, source: info|composer,
#                  scope: internal|core|external}],
#       implicit:[{target, scope: internal|core|external, kinds:[...],
#                  optional, always_enabled, declared,
#                  declared_via: info|composer|null,
#                  evidence:["file:line kind token", ...]}],
#       undeclared:[<the implicit entries that are not optional, not
#                    always enabled and not declared in the info.yml>],
#       proposed:["<project>:<module>", ...]}],
#      known:[<machine names of KNOWN_DIR extensions>],
#      services:{id: machine}, routes:{name: machine},
#      plugins:[{machine, type, id, file, has_settings}]}
#     Paths are relative to DIR. Extensions under KNOWN_DIR (e.g. the rest of
#     a monorepo when DIR is one module) only resolve references; they are not
#     reported themselves.
#
# Set EXTSCAN_TESTS=1 to also report extensions under tests/ (test modules);
# their references are never scanned. A caller may set EXTSCAN_CORE_DIR to a
# Drupal core directory (holding modules/) so "core" is read from it instead
# of the built-in list (is_drupal_core_module).
#
# What counts as a reference from an extension to module X (files under its
# own directory, minus nested extensions, tests/, vendor/, node_modules/):
#   class    `Drupal\X\...` in code (PHP family files and *.yml; comments and
#            docblocks are ignored, strings are not)
#   service  `@id` in *.services.yml, `\Drupal::service('id')`,
#            `$container->get('id')` — X is the module DEFINING id in the set
#   route    `Url::fromRoute('r')`, `->setRedirect('r')`, `'route_name' =>`,
#            `route_name:`/`base_route:` in *.links.*.yml — X defines r
#   library  `X/lib` in *.libraries.yml dependencies, `attach_library('X/lib')`,
#            `'library' => ['X/lib']`, a theme's `libraries:`
#   plugin   `createInstance('id')` / `plugin: id` in config — X provides id
#   config   `dependencies: module: [X]` in config/install (config/optional:
#            optional)
# A reference is OPTIONAL when it comes from config/optional, an `@?id`
# argument, a file that also calls `moduleExists('X')`, or a plugin of X's own
# plugin type (`src/Plugin/X/...`, e.g. src/Plugin/views/ -> views,
# src/Plugin/migrate/ -> migrate*: only discovered when X is enabled). A
# reference to an always-enabled core module (system, user, path_alias:
# `required: true` in core) is `always_enabled` and never undeclared. Services, routes and
# plugins that no extension of the set defines are not attributed (core and
# contrib ones would need their sources), so the scan under-reports rather
# than guesses. Line based: exotic YAML (anchors, flow maps) can be missed.
# =============================================================================

# _ext_scan_discover DIR TAG -> TSV rows on stdout:
#   machine type reldir info_rel core_req configure package name test tag
_ext_scan_discover() {
  local dir="$1" tag="$2" tests="${EXTSCAN_TESTS:-0}"
  ( cd "$dir" 2>/dev/null || exit 0
    find . \( ! -path . \( -name .git -o -name vendor -o -name node_modules -o -name .ddev \
        -o -name .drupilot -o -name contrib -o -path '*/core/modules' -o -path '*/core/themes' \
        -o -path '*/core/profiles' -o -path '*/core/tests' -o -name fixtures \) \) -prune \
      -o -type f -name '*.info.yml' -print 2>/dev/null \
      | sed 's|^\./||' | LC_ALL=C sort \
      | while IFS= read -r info; do
          local t=0 d
          case "/$info" in */tests/*) t=1;; esac
          [[ "$t" == "1" && "$tests" != "1" ]] && continue
          d="$(dirname "$info")"
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(basename "$info" .info.yml)" \
            "$(info_yml_value "$info" type)" "$d" "$info" \
            "$(info_yml_value "$info" core_version_requirement)" \
            "$(info_yml_value "$info" configure)" \
            "$(info_yml_value "$info" package)" \
            "$(info_yml_value "$info" name)" "$t" "$tag"
        done )
  return 0
}

# _ext_scan_records DIR EXTTSV -> TSV records on stdout for every source file
# under DIR owned by an extension of EXTTSV (the deepest extension dir that
# contains it):
#   R  owner kind token file:line optional     (a reference)
#   D  owner service|route id                   (a definition)
#   G  owner file module                        (a moduleExists guard)
#   P  owner type id file has_settings          (a plugin definition)
_ext_scan_records() {
  local dir="$1" exttsv="$2"
  ( cd "$dir" 2>/dev/null || exit 0
    find . \( ! -path . \( -name .git -o -name vendor -o -name node_modules -o -name .ddev \
        -o -name .drupilot -o -name contrib -o -name tests -o -name fixtures \
        -o -path '*/core/modules' -o -path '*/core/lib' \) \) -prune \
      -o -type f \( -name '*.php' -o -name '*.module' -o -name '*.inc' -o -name '*.install' \
        -o -name '*.theme' -o -name '*.profile' -o -name '*.engine' -o -name '*.yml' \
        -o -name '*.twig' \) -print 2>/dev/null \
      | sed 's|^\./||' | LC_ALL=C sort | tr '\n' '\000' \
      | xargs -0 awk -v extlist="$exttsv" '
function own(f,   i, best, bl) {
  best = ""; bl = -1
  for (i = 1; i <= ne; i++) if (substr(f, 1, length(ed[i])) == ed[i] && length(ed[i]) > bl) { best = em[i]; bl = length(ed[i]) }
  return best
}
# Strip PHP comments (keeping string contents): /* */ blocks, //, # (not #[).
function clean(s,   out, i, c, nx, n) {
  out = ""; n = length(s); i = 1
  while (i <= n) {
    c = substr(s, i, 1); nx = substr(s, i + 1, 1)
    if (inblock) { if (c == "*" && nx == "/") { inblock = 0; i += 2; continue }; i++; continue }
    if (instr != "") {
      out = out c
      if (c == "\\") { out = out nx; i += 2; continue }
      if (c == instr) instr = ""
      i++; continue
    }
    if (c == "/" && nx == "*") { inblock = 1; i += 2; continue }
    if (c == "/" && nx == "/") break
    if (c == "#" && nx != "[") break
    if (c == "\047" || c == "\"") { instr = c }
    out = out c; i++
  }
  return out
}
function unq(s) { gsub(/["\047]/, "", s); sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function ref(kind, tok, opt) {
  if (owner == "" || tok == "") return
  printf "R\t%s\t%s\t%s\t%s:%d\t%d\n", owner, kind, tok, file, FNR, opt
}
# quoted(s, re) -> every quoted argument of the calls matching re
function calls(s, re, kind, opt,   t, q) {
  while (match(s, re)) {
    t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    q = t; sub(/^[^"\047]*["\047]/, "", q); sub(/["\047].*$/, "", q)
    ref(kind, q, opt)
  }
}
function classes(s,   t) {
  while (match(s, /Drupal\\+[a-z][a-z0-9_]*\\/)) {
    t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    gsub(/Drupal|\\/, "", t); ref("class", t, 0)
  }
}
function libs(s, opt,   t) {
  while (match(s, /["\047][a-z][a-z0-9_]*\/[A-Za-z0-9_.-]+["\047]/)) {
    t = substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH)
    sub(/\/.*$/, "", t); if (t != "core") ref("library", t, opt)
  }
}
function flush(   k) {
  if (pfile != "" && ptype != "" && pid != "") printf "P\t%s\t%s\t%s\t%s\t%d\n", powner, ptype, pid, pfile, psettings
  pfile = ""; ptype = ""; pid = ""; psettings = 0
}
BEGIN {
  ne = 0
  while ((getline line < extlist) > 0) {
    split(line, a, "\t"); ne++; em[ne] = a[1]; ed[ne] = (a[3] == "." ? "" : a[3] "/")
  }
}
FNR == 1 {
  flush()
  file = FILENAME; sub(/^\.\//, "", file); owner = own(file)
  inblock = 0; instr = ""; insvc = 0; svcind = -1; incfg = 0; inmod = 0; indf = 0
  ft = "other"
  if (file ~ /\.(php|module|inc|install|theme|profile|engine)$/) ft = "php"
  else if (file ~ /\.services\.yml$/) ft = "services"
  else if (file ~ /\.routing\.yml$/) ft = "routing"
  else if (file ~ /\.links\.[a-z_]+\.yml$/) ft = "links"
  else if (file ~ /\.libraries\.yml$/) ft = "libraries"
  else if (file ~ /\.info\.yml$/) ft = "info"
  else if (file ~ /(^|\/)config\/install\/[^\/]+\.yml$/) ft = "cfg"
  else if (file ~ /(^|\/)config\/optional\/[^\/]+\.yml$/) ft = "cfgopt"
  else if (file ~ /\.twig$/) ft = "twig"
  if (ft == "php" && file ~ /(^|\/)src\/Plugin\//) { pfile = file; powner = owner }
}
owner == "" { next }
ft == "php" {
  raw = $0
  if (pfile != "") {
    if (ptype == "" && match(raw, /^[ \t]*\*[ \t]*@[A-Z][A-Za-z]*\(/)) { t = substr(raw, RSTART, RLENGTH); sub(/^[^@]*@/, "", t); sub(/\($/, "", t); ptype = t }
    if (ptype == "" && match(raw, /#\[[A-Z][A-Za-z]*\(/)) { t = substr(raw, RSTART + 2, RLENGTH - 3); ptype = t }
    if (pid == "" && match(raw, /^[ \t]*\*[ \t]*id[ \t]*=[ \t]*"[^"]+"/)) { t = substr(raw, RSTART, RLENGTH); sub(/^[^"]*"/, "", t); sub(/"$/, "", t); pid = t }
    if (pid == "" && ptype != "" && match(raw, /(^|[ (,])id:[ \t]*["\047][^"\047]+["\047]/)) { t = substr(raw, RSTART, RLENGTH); sub(/^[^"\047]*["\047]/, "", t); sub(/["\047]$/, "", t); pid = t }
    if (raw ~ /^[ \t]*\*[ \t]*settings[ \t]*=[ \t]*\{/ || raw ~ /(^|[ (,])settings:[ \t]*\[/) psettings = 1
    # defaultConfiguration()/defaultSettings() count only when the body
    # returns a keyed value (a `=>`), not an empty array.
    if (raw ~ /function[ \t]+default(Configuration|Settings)[ \t]*\(/) { indf = 1; dfdepth = 0; dfopen = 0 }
    if (indf) {
      t = raw; o = gsub(/\{/, "{", t); c = gsub(/\}/, "}", t)
      dfdepth += o - c; if (o > 0) dfopen = 1
      if (raw ~ /=>/) psettings = 1
      if (dfopen && dfdepth <= 0) indf = 0
    }
  }
  s = clean(raw)
  if (s ~ /Drupal\\/) classes(s)
  if (s ~ /(Drupal::service|container->get)[ \t]*\(/) calls(s, "(Drupal::service|container->get)[ \t]*\\([ \t]*[\"\047][A-Za-z0-9_.-]+[\"\047]", "service", 0)
  if (s ~ /(fromRoute|setRedirect|redirect|createFromRoute|setRouteName|checkNamedRoute)[ \t]*\(/) calls(s, "(fromRoute|setRedirect|redirect|createFromRoute|setRouteName|checkNamedRoute)[ \t]*\\([ \t]*[\"\047][A-Za-z0-9_.-]+[\"\047]", "route", 0)
  if (s ~ /route_name["\047][ \t]*=>/) calls(s, "route_name[\"\047][ \t]*=>[ \t]*[\"\047][A-Za-z0-9_.-]+[\"\047]", "route", 0)
  if (s ~ /createInstance[ \t]*\(/) calls(s, "createInstance[ \t]*\\([ \t]*[\"\047][A-Za-z0-9_:.-]+[\"\047]", "plugin", 0)
  if (s ~ /librar/) libs(s, 0)
  while (match(s, /moduleExists[ \t]*\([ \t]*["\047][a-z][a-z0-9_]*["\047]/)) {
    t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    sub(/^[^"\047]*["\047]/, "", t); sub(/["\047]$/, "", t)
    printf "G\t%s\t%s\t%s\n", owner, file, t
  }
  next
}
ft == "twig" {
  s = $0
  while (match(s, /attach_library[ \t]*\([ \t]*["\047][a-z][a-z0-9_]*\//)) {
    t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    sub(/^[^"\047]*["\047]/, "", t); sub(/\/$/, "", t); if (t != "core") ref("library", t, 0)
  }
  next
}
# --- YAML family ---
/^[ \t]*#/ { next }
{ y = $0; sub(/[ \t]+#.*$/, "", y) }
y ~ /Drupal\\/ { classes(y) }
ft == "services" {
  if (y ~ /^services:/) { insvc = 1; next }
  if (y ~ /^[^ \t]/) insvc = 0
  if (insvc && y ~ /^[ ]+[^ \t-]/) {
    match(y, /^[ ]+/); ind = RLENGTH
    if (svcind < 0) svcind = ind
    if (ind == svcind) { k = y; sub(/^[ ]+/, "", k); sub(/:.*$/, "", k); k = unq(k); if (k !~ /^_/) printf "D\t%s\tservice\t%s\n", owner, k }
  }
  s = y
  while (match(s, /@\??[A-Za-z0-9_.-]+/)) {
    t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
    opt = (substr(t, 2, 1) == "?") ? 1 : 0; sub(/^@\??/, "", t)
    if (t != "" && t !~ /^@/) ref("service", t, opt)
  }
  next
}
ft == "routing" {
  if (y ~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*:/) { k = y; sub(/:.*$/, "", k); if (k != "route_callbacks") printf "D\t%s\troute\t%s\n", owner, k }
  next
}
ft == "links" {
  if (y ~ /^[ \t]*(route_name|base_route):/) { t = y; sub(/^[^:]*:/, "", t); ref("route", unq(t), 0) }
  next
}
ft == "libraries" || ft == "info" {
  if (y ~ /^[ \t]*-[ \t]*["\047]?[a-z][a-z0-9_]*\/[^ ]/) {
    t = y; sub(/^[ \t]*-[ \t]*/, "", t); t = unq(t); sub(/\/.*$/, "", t)
    if (t != "core") ref("library", t, 0)
  }
  next
}
ft == "cfg" || ft == "cfgopt" {
  o = (ft == "cfgopt") ? 1 : 0
  if (y ~ /^[ \t]*plugin:[ \t]*[^ ]/) { t = y; sub(/^[^:]*:/, "", t); ref("plugin", unq(t), o) }
  if (y ~ /^dependencies:/) { incfg = 1; inmod = 0; next }
  if (y ~ /^[^ \t]/) { incfg = 0; inmod = 0 }
  if (incfg && y ~ /^  [a-z_]+:/) { inmod = (y ~ /^  module:/) ? 1 : 0; next }
  if (incfg && inmod && y ~ /^[ \t]*-[ \t]*[a-z]/) { t = y; sub(/^[ \t]*-[ \t]*/, "", t); ref("config", unq(t), o) }
  next
}
END { flush() }
' 2>/dev/null )
  return 0
}

# _ext_scan_composer DIR EXTTSV -> `machine \t module` for each drupal/*
# requirement (core excluded) in a composer.json next to an extension's info.
_ext_scan_composer() {
  local dir="$1" exttsv="$2" m d
  have_cmd jq || return 0
  # Read with a non-whitespace separator: IFS=<tab> would collapse empty fields.
  while IFS=$'\x1f' read -r m d; do
    [[ -f "$dir/$d/composer.json" ]] || continue
    jq -r '(.require // {}) | keys[]? | select(startswith("drupal/")) | select(startswith("drupal/core") | not) | sub("^drupal/"; "")' \
      "$dir/$d/composer.json" 2>/dev/null | while IFS= read -r p; do printf '%s\t%s\n' "$m" "$p"; done
  done < <(awk -F'\t' '{ print $1 "\037" $3 }' "$exttsv")
  return 0
}

# ext_scan_json DIR [KNOWN_DIR...] -> see the header.
ext_scan_json() {
  local dir="$1"; shift
  local work rc=0 k kd
  have_cmd jq || { printf 'null'; return 1; }
  dir="$(cd "$dir" 2>/dev/null && pwd)" || { printf 'null'; return 1; }
  work="$(mktemp -d "${TMPDIR:-/tmp}/drupilot-extscan.XXXXXX")" || return 1
  _ext_scan_discover "$dir" self > "$work/ext.tsv"
  : > "$work/known.tsv"
  for k in "$@"; do
    kd="$(cd "$k" 2>/dev/null && pwd)" || continue
    [[ "$kd" == "$dir" ]] && continue
    _ext_scan_discover "$kd" known >> "$work/known.tsv"
    # Definitions (services/routes/plugins) of the known extensions.
    _ext_scan_records "$kd" "$work/known.tsv" | awk -F'\t' '$1 == "D" || $1 == "P"' >> "$work/known-rec.tsv"
  done
  [[ -f "$work/known-rec.tsv" ]] || : > "$work/known-rec.tsv"
  _ext_scan_records "$dir" "$work/ext.tsv" > "$work/rec.tsv"
  _ext_scan_composer "$dir" "$work/ext.tsv" > "$work/composer.tsv"
  : > "$work/decl.tsv"
  local m info e
  while IFS=$'\x1f' read -r m info; do
    info_yml_dependencies "$dir/$info" | while IFS= read -r e; do printf '%s\t%s\t%s\n' "$m" "$e" "${e##*:}"; done >> "$work/decl.tsv"
  done < <(awk -F'\t' '{ print $1 "\037" $4 }' "$work/ext.tsv")
  # Core modules: from a real core when given, else the built-in list.
  if [[ -n "${EXTSCAN_CORE_DIR:-}" && -d "${EXTSCAN_CORE_DIR}/modules" ]]; then
    find "${EXTSCAN_CORE_DIR}/modules" -mindepth 2 -maxdepth 2 -name '*.info.yml' 2>/dev/null \
      | sed 's|.*/||; s|\.info\.yml$||' > "$work/core.txt"
  else
    printf '%s\n' $DRUPAL_CORE_MODULES > "$work/core.txt"
  fi
  jq -n --arg root "$dir" \
    --rawfile ext "$work/ext.tsv" --rawfile known "$work/known.tsv" \
    --rawfile rec "$work/rec.tsv" --rawfile krec "$work/known-rec.tsv" \
    --rawfile comp "$work/composer.tsv" --rawfile decl "$work/decl.tsv" \
    --rawfile core "$work/core.txt" '
    def rows($s): $s | split("\n") | map(select(length > 0) | split("\t"));
    (rows($ext) | map({machine: .[0], type: .[1], dir: .[2], info_file: .[3],
        core_version_requirement: (.[4] // ""), configure: (.[5] // ""),
        package: (.[6] // ""), name: (.[7] // ""), test: ((.[8] // "0") == "1")})) as $exts
    | (rows($known) | map(.[0])) as $knownm
    | (rows($rec) + rows($krec)) as $allrec
    | (rows($rec)) as $recs
    | (rows($core) | map(.[0])) as $coremods
    | ($exts | map(.machine)) as $selfm
    | (($selfm + $knownm) | unique) as $setm
    # Core modules that are always enabled (`required: true` in their info.yml
    # on 10.x and 11.x): a dependency on them is never needed.
    | ["system", "user", "path_alias"] as $required
    # parent = the nearest extension whose dir contains this one; project = the
    # top-most one (itself when top-level).
    | ($exts | map(. as $e | {key: .machine, value: (
        [$exts[] | . as $o | select($o.machine != $e.machine and $o.dir != $e.dir and ($o.dir == "." or ($e.dir | startswith($o.dir + "/"))))]
        | sort_by(.dir | length))}) | from_entries) as $anc
    | ($allrec | map(select(.[0] == "D" and .[2] == "service")) | map({key: .[3], value: .[1]}) | from_entries) as $svc
    | ($allrec | map(select(.[0] == "D" and .[2] == "route")) | map({key: .[3], value: .[1]}) | from_entries) as $rte
    | ($allrec | map(select(.[0] == "P")) | map({machine: .[1], type: .[2], id: .[3], file: .[4], has_settings: (.[5] == "1")})) as $plg
    | ($plg | map({key: .id, value: .machine}) | from_entries) as $pmap
    | ($recs | map(select(.[0] == "G")) | map({key: (.[1] + "|" + .[2] + "|" + .[3]), value: true}) | from_entries) as $guards
    | (rows($decl) | map({m: .[0], entry: .[1], module: .[2], source: "info"})) as $dinfo
    | (rows($comp) | map({m: .[0], entry: ("drupal/" + .[1]), module: .[1], source: "composer"})) as $dcomp
    | def projectof($t): if ($anc[$t] // []) | length > 0 then $anc[$t][0].machine else $t end;
      def scope($t): if ($setm | index($t)) != null then "internal" elif ($coremods | index($t)) != null then "core" else "external" end;
      def resolve($kind; $tok):
        if $kind == "class" or $kind == "library" or $kind == "config" then $tok
        elif $kind == "service" then ($svc[$tok] // null)
        elif $kind == "route" then ($rte[$tok] // null)
        elif $kind == "plugin" then ($pmap[$tok] // null)
        else null end;
    {root: $root,
     known: $knownm,
     services: $svc, routes: $rte, plugins: $plg,
     extensions: [ $exts[] | . as $e
       | ($anc[$e.machine] // []) as $a
       | ([$dinfo[] | select(.m == $e.machine) | del(.m)] + [$dcomp[] | select(.m == $e.machine) | del(.m)]
          | map(. + {scope: scope(.module)})) as $declared
       | ([ $recs[] | select(.[0] == "R" and .[1] == $e.machine)
            | (.[4] | split(":")[0]) as $file
            | {kind: .[2], token: .[3], ev: .[4], file: $file, opt: (.[5] == "1"),
               target: resolve(.[2]; .[3])}
            | select(.target != null and .target != "" and .target != $e.machine)
            | ((.file | capture("(^|/)src/Plugin/(?<seg>[^/]+)/") | .seg) // "") as $seg
            | .opt = (.opt or ($guards[$e.machine + "|" + .file + "|" + .target] // false)
                      or ($seg != "" and ($seg == .target or ($seg == "migrate" and (.target | startswith("migrate")))))) ]
          | group_by(.target)
          | map(.[0].target as $t
              | ([$declared[] | select(.module == $t) | .source] | unique) as $via
              | {target: $t, scope: scope($t),
                 kinds: (map(.kind) | unique),
                 optional: (all(.[]; .opt)),
                 always_enabled: (($required | index($t)) != null),
                 declared: (($via | index("info")) != null),
                 declared_via: (if ($via | index("info")) != null then "info" elif ($via | length) > 0 then $via[0] else null end),
                 proposed: (if scope($t) == "internal" then projectof($t) + ":" + $t
                            elif scope($t) == "core" then "drupal:" + $t
                            else $t + ":" + $t end),
                 verify_project: (scope($t) == "external"),
                 evidence: (unique_by([.ev, .kind, .token])
                   | sort_by(.file, (.ev | sub("^.*:"; "") | tonumber? // 0))
                   | map(.ev + " " + .kind + " " + .token) | .[0:5])})) as $impl
       | $e + {parent: (if ($a | length) > 0 then $a[-1].machine else null end),
               project: (if ($a | length) > 0 then $a[0].machine else $e.machine end),
               declared: $declared, implicit: $impl,
               undeclared: [$impl[] | select((.optional | not) and (.declared | not) and (.always_enabled | not))],
               proposed: ([$impl[] | select((.optional | not) and (.declared | not) and (.always_enabled | not)) | .proposed] | unique)} ]}' || rc=$?
  rm -rf "$work"
  return $rc
}
