#!/usr/bin/env bash
# The port-safety check event-dispatch-order (training run module 13,
# log_entity: dispatch(LogEntityEvents::LOG_EVENT, $event) in its login hooks,
# a TypeError from Drupal 10's Symfony 6), Docker-free:
# - a class constant, a string literal, a constant on the line after
#   'dispatch(' and a name alone (dispatch(Events::NAME)) are errors; the event first, new Foo() first, a variable name
#   and a commented call are not.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
PS="$T_REPO/scripts/analysis/check-port-safety.sh"

M="$T_TMP/m"; mkdir -p "$M"
printf 'name: M\ntype: module\ncore_version_requirement: ^10 || ^11\n' > "$M/m.info.yml"
cat > "$M/m.module" <<'PHP'
<?php

function m_user_login($account) {
  $event = new MEvent($account);
  \Drupal::service('event_dispatcher')->dispatch(MEvents::LOGIN, $event);
  \Drupal::service('event_dispatcher')->dispatch('m.login', $event);
  \Drupal::service('event_dispatcher')->dispatch(
    \Drupal\m\MEvents::LOGIN,
    $event
  );
  \Drupal::service('event_dispatcher')->dispatch($event, MEvents::LOGIN);
  \Drupal::service('event_dispatcher')->dispatch(new MEvent($account), 'm.login');
  \Drupal::service('event_dispatcher')->dispatch($name, $event);
  \Drupal::service('event_dispatcher')->dispatch(MEvents::LOGIN);
  \Drupal::service('event_dispatcher')->dispatch(
    MEvents::LOGIN
  );
  // \Drupal::service('event_dispatcher')->dispatch(MEvents::LOGIN, $event);
}
PHP
t_run "$T_SH" "$PS" --subject "$M" --checks event-dispatch-order --json
assert_eq "the three event-name-first calls and the name alone (one line, and with its ) on a later line), errors (exit 3)" \
  "$T_RC|$(jq -c '[.findings[] | [.check, .file, .line, .severity]]' "$T_OUT")" \
  '3|[["event-dispatch-order","m.module",5,"error"],["event-dispatch-order","m.module",6,"error"],["event-dispatch-order","m.module",7,"error"],["event-dispatch-order","m.module",14,"error"],["event-dispatch-order","m.module",15,"error"]]'
assert_match "  the message names the signature and the fix" "$(jq -r '.findings[0].message' "$T_OUT")" \
  "dispatch\(object \\\$event, \?string \\\$eventName = NULL\), so this call throws a TypeError\. Pass the event object first"
t_done
