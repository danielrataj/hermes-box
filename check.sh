#!/usr/bin/env bash
# Health check of the whole setup. Prints one line per check and exits 1 if
# anything failed. Run as root from anywhere:
#
#   ./check.sh            all lines
#   ./check.sh --quiet    only failures (used by monitor/hermes-monitor.sh)

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
env_get() { [ -f "$REPO_DIR/.env" ] && sed -n "s/^$1=//p" "$REPO_DIR/.env" | tail -n1 || true; }

DATA_DIR="$(env_get HERMES_DATA_DIR)"; DATA_DIR="${DATA_DIR:-/home/hermes}"
DOMAIN="$(env_get HERMES_DOMAIN)"
quiet=0; [ "${1:-}" = "--quiet" ] && quiet=1
failed=0

ok()   { [ "$quiet" -eq 1 ] || printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failed=1; }
# Worth knowing, but not a failure: no alert, exit code unchanged.
warn() { [ "$quiet" -eq 1 ] || printf 'warn  %s\n' "$1"; }
# check <name> <command...>: passes when the command succeeds
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name"; fi; }

http_code() { curl -s -o /dev/null --max-time 15 -w '%{http_code}' "$1" 2>/dev/null; }
is_up()     { case "$(http_code "$1")" in 200|301|302) return 0 ;; *) return 1 ;; esac; }

# ── Data ─────────────────────────────────────────────────────────────────────
check "data directory holds Hermes data ($DATA_DIR)" test -f "$DATA_DIR/.hermes/config.yaml"
for path in / "$DATA_DIR"; do
  used="$(df --output=pcent "$path" | tail -n1 | tr -dc 0-9)"
  if [ "${used:-100}" -lt 85 ]; then ok "disk $path ${used}% full"; else fail "disk $path ${used}% full"; fi
done

# ── Services ─────────────────────────────────────────────────────────────────
check "hermes-docker.service is active" systemctl is-active --quiet hermes-docker.service
check "hermes-backup.timer is active"   systemctl is-active --quiet hermes-backup.timer
for name in hermes hermes-caddy; do
  state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
  if [ "$state" = running ]; then ok "container $name is running"; else fail "container $name is $state"; fi
done
health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' hermes 2>/dev/null || echo missing)"
case "$health" in
  healthy|starting|none) ok "container hermes health: $health" ;;
  *) fail "container hermes health: $health" ;;
esac
restarts="$(docker inspect -f '{{.RestartCount}}' hermes 2>/dev/null || echo 0)"
if [ "$restarts" -eq 0 ]; then ok "container hermes has not crashed"
else fail "container hermes was restarted ${restarts}x after a crash"; fi

# ── Agent ────────────────────────────────────────────────────────────────────
if grep -Eqs '^model:' "$DATA_DIR/.hermes/config.yaml"; then ok "a model is configured"
else warn "no model is configured: the agent will not answer (see README, Model and provider)"; fi
check "Webapp answers on 127.0.0.1:9120" is_up http://127.0.0.1:9120/
exposed="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(9119|9120)$' | grep -v -E '^(127\.|\[::1\]|\[::ffff:127\.)' | tr '\n' ' ')"
if [ -z "$exposed" ]; then ok "dashboard and Webapp listen on loopback only"
else fail "listening on a public address: $exposed"; fi

# ── Public ───────────────────────────────────────────────────────────────────
if [ -n "$DOMAIN" ]; then
  check "https://$DOMAIN answers" is_up "https://$DOMAIN/"
  cert_ok() {
    echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null |
      openssl x509 -noout -checkend $((14 * 86400))
  }
  check "certificate is valid for at least 14 more days" cert_ok
fi

# ── Backup ───────────────────────────────────────────────────────────────────
result="$(systemctl show hermes-backup.service -p Result --value 2>/dev/null)"
if [ "$result" = success ]; then ok "last backup run did not fail"; else fail "last backup run: $result"; fi
stamp="$DATA_DIR/backups/last-success"
if [ -f "$stamp" ]; then
  age_h=$(( ( $(date +%s) - $(stat -c %Y "$stamp") ) / 3600 ))
  if [ "$age_h" -lt 26 ]; then ok "last successful backup ${age_h} h ago"
  else fail "last successful backup ${age_h} h ago"; fi
else
  fail "no successful backup recorded yet"
fi

# ── The installation's own checks ────────────────────────────────────────────
# Every instance/check.d/*.sh is one check, named after its file: it passes
# when the script exits 0; the last line it printed is shown with a failure.
for script in "$REPO_DIR"/instance/check.d/*.sh; do
  [ -f "$script" ] || continue
  name="$(basename "$script" .sh)"
  if output="$(REPO_DIR="$REPO_DIR" DATA_DIR="$DATA_DIR" bash "$script" 2>&1)"; then ok "$name"
  else fail "$name: $(printf '%s' "$output" | tail -n1)"; fi
done

[ "$quiet" -eq 1 ] || { [ "$failed" -eq 0 ] && echo "all checks passed" || echo "some checks FAILED"; }
exit "$failed"
