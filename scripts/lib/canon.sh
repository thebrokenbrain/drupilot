#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/lib/canon.sh
# Canonical JSON and its hash (AR-13): the form an upgrade plan is hashed in,
# so the same plan always gives the same .upgrade_plan_hash.
#
# Part of the shared library: scripts/lib/common.sh sources it with the other
# domain libs (never source it alone); see common.sh for the conventions.
# =============================================================================

# canon_json_hashable -> STDIN's JSON in its hashable canonical form: keys
# sorted, compact, without the top-level "meta" (generated_at, versions: what
# changes between two runs that resolve the same plan). One line, LF-ended.
canon_json_hashable() {
  jq -S -c 'if type == "object" then del(.meta) else . end'
}

# sha256_hex -> the bare SHA-256 hex of STDIN's bytes (sha256sum, else shasum
# -a 256). Prints nothing when neither exists: a caller that needs the hash
# fails then.
sha256_hex() {
  local h=""
  if have_cmd sha256sum; then h="$(sha256sum | cut -d' ' -f1)"
  elif have_cmd shasum; then h="$(shasum -a 256 | cut -d' ' -f1)"
  else cat > /dev/null; return 0; fi
  [[ "$h" =~ ^[0-9a-f]{64}$ ]] && printf '%s' "$h"
  return 0
}

# json_hash -> "sha256:<hex>" of STDIN's bytes (sha256_hex); nothing when no
# hasher exists.
json_hash() {
  local h
  h="$(sha256_hex)"
  [[ -n "$h" ]] && printf 'sha256:%s' "$h"
  return 0
}
