# Sourced by the monitor and deploy scripts; expects REPO_DIR and env_get.
#
# notify <text>: write the text to stdout (the journal) and, when
# ALERT_SIGNAL_RECIPIENT is set in instance/.env, send it to that Signal number through
# the local signal-cli daemon. Never fails the caller.

notify() {
  local recipient
  echo "$1"
  recipient="$(env_get ALERT_SIGNAL_RECIPIENT)"
  [ -n "$recipient" ] || return 0
  jq -n --arg to "$recipient" --arg text "$1" \
      '{jsonrpc: "2.0", id: 1, method: "send", params: {recipient: [$to], message: $text}}' |
    curl -s --max-time 30 -o /dev/null -H 'Content-Type: application/json' \
      -d @- http://127.0.0.1:8080/api/v1/rpc ||
    echo "notify: could not send the Signal message"
  return 0
}
