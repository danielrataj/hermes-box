#!/usr/bin/env bash
# Run check.sh and tell someone when the result changes: one message when
# something breaks (or a different thing breaks), one when all is well again.
# Run by hermes-monitor.timer every 10 minutes and right after a failed backup.
#
# Messages go to the journal (journalctl -u hermes-monitor) and, when
# ALERT_SIGNAL_RECIPIENT is set in instance/.env, to that Signal number through the
# local signal-cli daemon. If Signal itself is down that message cannot be
# delivered; an external uptime check of the public address covers that case.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
env_get() { [ -f "$REPO_DIR/.env" ] && sed -n "s/^$1=//p" "$REPO_DIR/.env" | tail -n1 || true; }
# shellcheck source=monitor/notify.sh
. "$REPO_DIR/monitor/notify.sh"

STATE=/run/hermes-monitor.state   # failures reported last time; cleared by a reboot
DEPLOYING=/run/hermes-deploying   # set by deploy/hermes-deploy.sh while it restarts things

# A deployment restarts the stack on purpose and reports its own result.
if [ -n "$(find "$DEPLOYING" -mmin -45 2>/dev/null)" ]; then
  exit 0
fi

failures="$("$REPO_DIR/check.sh" --quiet)"
previous="$(cat "$STATE" 2>/dev/null || true)"

if [ "$failures" = "$previous" ]; then
  exit 0
fi
printf '%s' "$failures" > "$STATE"

host="$(hostname)"
if [ -n "$failures" ]; then
  notify "Hermes on $host has a problem:
$failures"
else
  notify "Hermes on $host is healthy again."
fi
