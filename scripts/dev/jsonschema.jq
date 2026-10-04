# drupilot — scripts/dev/jsonschema.jq
# The structural JSON Schema validator of scripts/dev/schema-check.sh and
# scripts/dev/data-check.sh (developer/CI tools; never a plugin runtime
# dependency). It understands only the keywords drupilot's schemas use:
# type, required, properties, additionalProperties (false or a schema),
# propertyNames, items, enum, const, minimum, minItems, minLength, pattern,
# anyOf and local $defs/$ref. A schema that needs any other keyword must
# extend this file first (ADR 0010). jq 1.6 compatible.
#
# chk($root; $sch; $p): every violation of $sch by the input, one string per
# violation, prefixed with the instance path $p.
# hard($root; $sch; $p): {path, node} for every instance node that a
# subschema annotated "x-drupilot-hard-gate": true describes, the annotation
# read next to a $ref too and inside anyOf branches (data-check.sh requires
# each of them to be verified and never "announced").
# A $ref that does not resolve is a violation, never a silent pass. A pattern's
# final $ matches only at the very end (jq's Oniguruma would also match before
# a trailing newline; JSON Schema's ECMA-262 regexes do not).

def tnames: if type == "number" then (if . == floor then ["number", "integer"] else ["number"] end) else [type] end;
def deref($root): if type == "object" and has("$ref") then $root["$defs"][.["$ref"] | ltrimstr("#/$defs/")] else . end;
def strict_end: if test("[^\\\\]\\$$") then sub("\\$$"; "\\z") else . end;
def chk($root; $sch; $p):
  ($sch | deref($root)) as $s
  | . as $x
  | (if ($sch | type) == "object" and ($sch | has("$ref")) and ($s | type) != "object" then "\($p): unresolved $ref \($sch["$ref"])"
     elif ($s | type) != "object" then empty
     else
       (if $s | has("type") then
          ($s.type | if type == "array" then . else [.] end) as $ts
          | if any($x | tnames[]; . as $t | $ts | index($t) != null) then empty
            else "\($p): \($x | type) is not \($ts | join("|"))" end
        else empty end),
       (if ($s | has("enum")) and (any($s.enum[]; . == $x) | not) then "\($p): \($x | tojson) is not one of \($s.enum | tojson)" else empty end),
       (if ($s | has("const")) and $x != $s.const then "\($p): \($x | tojson) is not \($s.const | tojson)" else empty end),
       (if ($s | has("minimum")) and ($x | type) == "number" and $x < $s.minimum then "\($p): \($x) is below \($s.minimum)" else empty end),
       (if ($s | has("minLength")) and ($x | type) == "string" and ($x | length) < $s.minLength then "\($p): shorter than \($s.minLength)" else empty end),
       (if ($s | has("pattern")) and ($x | type) == "string" and ($x | test($s.pattern | strict_end) | not) then "\($p): \($x | tojson) does not match \($s.pattern)" else empty end),
       (if ($s | has("anyOf")) and (any($s.anyOf[]; . as $b | [$x | chk($root; $b; $p)] | length == 0) | not) then
          "\($p): matches no anyOf branch" else empty end),
       (if ($x | type) == "object" then
          (($s.required // [])[] | select(. as $k | $x | has($k) | not) | "\($p): missing required key \(.)"),
          (($s.properties // {}) | to_entries[] | select(.key as $k | $x | has($k)) | .key as $k | .value as $ps
            | $x[$k] | chk($root; $ps; "\($p).\($k)")),
          (if $s | has("propertyNames") then
             ($x | keys[] | . as $k | chk($root; $s.propertyNames; "\($p) key \($k | tojson)"))
           else empty end),
          (if $s.additionalProperties == false then
             ($x | keys[] | select(. as $k | ($s.properties // {}) | has($k) | not) | "\($p): unexpected key \(.)")
           elif ($s.additionalProperties | type) == "object" then
             ($x | to_entries[] | select(.key as $k | ($s.properties // {}) | has($k) | not) | .key as $k
               | .value | chk($root; $s.additionalProperties; "\($p).\($k)"))
           else empty end)
        else empty end),
       (if ($x | type) == "array" then
          (if ($s | has("minItems")) and ($x | length) < $s.minItems then "\($p): fewer than \($s.minItems) items" else empty end),
          (if $s | has("items") then ($x | to_entries[] | .key as $i | .value | chk($root; $s.items; "\($p)[\($i)]")) else empty end)
        else empty end)
     end);
def hard($root; $sch; $p):
  ($sch | deref($root)) as $s
  | . as $x
  | if ($s | type) != "object" then empty
    else
      (if $s["x-drupilot-hard-gate"] == true or (($sch | type) == "object" and $sch["x-drupilot-hard-gate"] == true)
       then {path: $p, node: $x} else empty end),
      (($s.anyOf // [])[] as $b | $x | hard($root; $b | if type == "object" then del(.["x-drupilot-hard-gate"]) else . end; $p)),
      (if ($x | type) == "object" then
         (($s.properties // {}) | to_entries[] | select(.key as $k | $x | has($k)) | .key as $k | .value as $ps
           | $x[$k] | hard($root; $ps; "\($p).\($k)")),
         (if ($s.additionalProperties | type) == "object" then
            ($x | to_entries[] | select(.key as $k | ($s.properties // {}) | has($k) | not) | .key as $k
              | .value | hard($root; $s.additionalProperties; "\($p).\($k)"))
          else empty end)
       elif ($x | type) == "array" and ($s | has("items")) then
         ($x | to_entries[] | .key as $i | .value | hard($root; $s.items; "\($p)[\($i)]"))
       else empty end)
    end;
