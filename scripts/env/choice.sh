#!/usr/bin/env bash
# =============================================================================
# drupilot — scripts/env/choice.sh
# Resolve the pre-answer of one tabbed choice, DRUPILOT_CHOICE_<KEY>, against the
# registry in config/choices.json, so a command can skip the tab and apply the
# answer exactly as if the developer had picked it.
#
# The value is read through config_get (environment > the Drupal root's
# .drupilot.json > defaults), so the environment variable is the usual way to
# set it. It is validated against the registry's option set (a comma-separated
# subset for a multi-select); an old value of the setting the choice persists
# (config/migrations.json value_aliases, e.g. CORE_TARGET=keep-d10) is accepted
# as its new name, with a warning. An invalid value, or a value for a fork that must
# stay a human decision ('preanswer': false), is ignored with a warning on
# STDERR and the command asks as usual.
#
# With --persist, a valid answer is also written to .drupilot.json through
# prefs_set, as the tab's answer would be (e.g. CORE_TARGET ->
# DRUPILOT_CORE_TARGET_STRATEGY; for T=11 under its 0.9 name, keep-d10 or
# d11-only, CC-07). An environment variable of that setting still
# wins over the persisted value: the JSON lists it under env_override.
#
# Usage:
#   choice.sh --key KEY [--subject DIR] [--persist] [--json]
#   choice.sh --list [--json]
#     --key KEY      the choice key (e.g. CORE_TARGET), with or without the
#                    DRUPILOT_CHOICE_ prefix
#     --subject DIR  where to look for the Drupal root (.drupilot.json); default
#                    the current directory
#     --persist      write a valid answer to .drupilot.json (prefs_set)
#     --list         print the registry: every key, its command, tab and values
#     --json         JSON on STDOUT (default: the resolved value, or nothing)
#
# Output (--key --json): one object on STDOUT:
#   {key, variable, command, header, preanswer, options, multi, default,
#    set, raw, value, valid, persist: [{key, value}], persisted,
#    env_override: [{key, value}], note}
#   value is the validated answer (normalized: a multi-select keeps the
#   registry's order; a CORE_TARGET answer under its 0.9 name for T=11,
#   keep-d10 or d11-only, CC-07) or null when the tab must be asked.
#
# Exit code: 0 (also when the value is unset or invalid: the command then asks);
#            1 usage error (unknown key, missing argument).
# =============================================================================
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

KEY=""; SUBJECT=""; PERSIST=0; AS_JSON=0; LIST=0; RAW_NORM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY="${2:-}"; shift 2 || die "--key needs a value" 1;;
    --key=*) KEY="${1#*=}"; shift;;
    --subject) SUBJECT="${2:-}"; shift 2 || die "--subject needs a value" 1;;
    --subject=*) SUBJECT="${1#*=}"; shift;;
    --persist) PERSIST=1; shift;;
    --list) LIST=1; shift;;
    --json) AS_JSON=1; shift;;
    -h|--help) print_usage "$0"; exit 0;;
    *) die "Unknown argument: $1 (see --help)" 1;;
  esac
done

have_cmd jq || die "jq is required by choice.sh" 1
REG="$(plugin_root)/config/choices.json"
[[ -r "$REG" ]] || die "Choice registry not found: $REG" 1

if [[ "$LIST" == "1" ]]; then
  if [[ "$AS_JSON" == "1" ]]; then
    jq -c '.choices | to_entries | map({key: .key, variable: ("DRUPILOT_CHOICE_" + .key),
      command: .value.command, header: .value.header,
      preanswer: (.value.preanswer != false), options: (.value.options // []),
      multi: (.value.multi // false), default: (.value.default // null),
      persists: ((.value.persist_key // null) as $k
                 | if $k then [$k] else ((.value.persist_map // {}) | [.[] | keys[]] | unique) end),
      note: (.value.note // null)})' "$REG"
  else
    jq -r '.choices | to_entries[] | "DRUPILOT_CHOICE_\(.key)\t\(.value.command)\t\(.value.header)\t"
      + (if (.value.preanswer != false) then ((.value.options // []) | join("|")) else "(not pre-answerable)" end)' "$REG"
  fi
  exit 0
fi

[[ -n "$KEY" ]] || die "--key or --list is required (see --help)" 1
KEY="${KEY#DRUPILOT_CHOICE_}"
KEY="$(printf '%s' "$KEY" | tr '[:lower:]-' '[:upper:]_')"
ENTRY="$(jq -c --arg k "$KEY" '.choices[$k] // empty' "$REG")"
[[ -n "$ENTRY" ]] || die "Unknown choice key: $KEY (see choice.sh --list)" 1

VAR="DRUPILOT_CHOICE_${KEY}"
ROOT="$(find_drupal_root "${SUBJECT:-$PWD}" 2>/dev/null || true)"
if [[ -n "$ROOT" ]]; then
  RAW="$(DRUPILOT_PROJECT_DIR="$ROOT" config_get "$VAR" "")"
else
  RAW="$(config_get "$VAR" "")"
fi

PREANSWER="$(jq -r '.preanswer != false' <<<"$ENTRY")"
MULTI="$(jq -r '.multi // false' <<<"$ENTRY")"
OPTIONS="$(jq -r '(.options // []) | join(" ")' <<<"$ENTRY")"
PKEY="$(jq -r '.persist_key // empty' <<<"$ENTRY")"
# An old value of the setting the choice persists (a migrations.json
# value_aliases row, e.g. CORE_TARGET keep-d10 -> keep-previous) is accepted
# as its new name, with a warning (CC-07); a choice that only maps its options
# (persist_map, e.g. D10_CHECK's own d11-only) is never renamed.
if [[ -n "$RAW" && -n "$PKEY" && "$MULTI" != "true" ]]; then
  case " $OPTIONS " in
    *" $RAW "*) ;;
    *) value_alias_normalize "$PKEY" "$RAW" "$VAR"; RAW_NORM="$_DRUPILOT_VALUE_ALIAS";;
  esac
fi

VALUE=""; VALID="false"
if [[ -n "$RAW" ]]; then
  if [[ "$PREANSWER" != "true" ]]; then
    log_warn "Ignoring $VAR='$RAW': this choice cannot be pre-answered. $(jq -r '.note // "It stays a human decision."' <<<"$ENTRY")"
  elif [[ "$MULTI" == "true" ]]; then
    bad=""; picked=" "
    for v in $(printf '%s' "$RAW" | tr ',' ' '); do
      case " $OPTIONS " in
        *" $v "*) picked="$picked$v ";;
        *) bad="$bad $v";;
      esac
    done
    if [[ -n "$bad" || "$picked" == " " ]]; then
      log_warn "Ignoring $VAR='$RAW' (allowed: a comma-separated subset of: ${OPTIONS// /, }); the choice will be asked."
    else
      # Normalize: the registry's order, no duplicates.
      for o in $OPTIONS; do
        case "$picked" in *" $o "*) VALUE="${VALUE:+$VALUE,}$o";; esac
      done
      VALID="true"
    fi
  else
    case " $OPTIONS " in
      *" ${RAW_NORM:-$RAW} "*) VALUE="${RAW_NORM:-$RAW}"; VALID="true";;
      *) log_warn "Ignoring $VAR='$RAW' (allowed: ${OPTIONS// /, }); the choice will be asked.";;
    esac
  fi
fi

# For T=11 a renamed value is emitted and persisted under its 0.9 name (CC-07:
# keep-d10, d11-only), which every 0.9 reader understands.
if [[ "$VALID" == "true" && "$PKEY" == "DRUPILOT_CORE_TARGET_STRATEGY" ]]; then
  VALUE="$(strategy_persist_name "$VALUE" "$(DRUPILOT_PROJECT_DIR="${ROOT:-${DRUPILOT_PROJECT_DIR:-}}" resolve_target_major)")"
fi

# What a valid answer persists, and any environment variable that overrides it.
PERSIST_PAIRS="[]"
if [[ "$VALID" == "true" ]]; then
  PV="$VALUE"
  PERSIST_PAIRS="$(jq -c --arg v "$PV" '
    if .persist_key then [{key: .persist_key, value: $v}]
    else ((.persist_map // {})[$v] // {}) | to_entries | map({key: .key, value: .value}) end' <<<"$ENTRY")"
fi

ENV_OVERRIDE="[]"
PERSISTED="null"
n="$(jq 'length' <<<"$PERSIST_PAIRS")"
if [[ "$n" -gt 0 ]]; then
  [[ "$PERSIST" == "1" ]] && PERSISTED="true"
  i=0
  while [[ "$i" -lt "$n" ]]; do
    pk="$(jq -r --argjson i "$i" '.[$i].key' <<<"$PERSIST_PAIRS")"
    pv="$(jq -r --argjson i "$i" '.[$i].value' <<<"$PERSIST_PAIRS")"
    envv="$(printenv "$pk" 2>/dev/null || true)"
    if [[ -n "$envv" && "$(value_alias_legacy "$pk" "$envv")" != "$(value_alias_legacy "$pk" "$pv")" ]]; then
      log_warn "$pk='$envv' is set in the environment and wins over $VAR='$VALUE'."
      ENV_OVERRIDE="$(jq -c --arg k "$pk" --arg v "$envv" '. + [{key: $k, value: $v}]' <<<"$ENV_OVERRIDE")"
    fi
    if [[ "$PERSIST" == "1" ]]; then
      if [[ -n "$ROOT" ]] && DRUPILOT_PROJECT_DIR="$ROOT" prefs_set "$pk" "$pv"; then
        log_ok "Persisted $pk=$pv to $ROOT/.drupilot.json ($VAR)."
      else
        PERSISTED="false"
        log_warn "Could not persist $pk=$pv (no Drupal root yet, or no jq); export it for this run instead."
      fi
    fi
    i=$((i + 1))
  done
fi

if [[ "$VALID" == "true" ]]; then
  log_info "$VAR='$VALUE' pre-answers the \"$(jq -r '.header' <<<"$ENTRY")\" choice."
fi

if [[ "$AS_JSON" == "1" ]]; then
  jq -n -c --arg k "$KEY" --arg var "$VAR" --argjson e "$ENTRY" \
    --arg raw "$RAW" --arg val "$VALUE" --argjson valid "$VALID" \
    --argjson persist "$PERSIST_PAIRS" --argjson persisted "$PERSISTED" \
    --argjson envo "$ENV_OVERRIDE" '
    {key: $k, variable: $var, command: $e.command, header: $e.header,
     preanswer: ($e.preanswer != false), options: ($e.options // []),
     multi: ($e.multi // false), default: ($e.default // null),
     set: ($raw != ""), raw: (if $raw == "" then null else $raw end),
     value: (if $valid then $val else null end), valid: $valid,
     persist: $persist, persisted: $persisted, env_override: $envo,
     note: ($e.note // null)}'
else
  [[ -n "$VALUE" ]] && printf '%s\n' "$VALUE"
fi
exit 0
