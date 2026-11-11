#!/usr/bin/env bash
# Deploy new commits from git. Run by hermes-deploy.timer every 5 minutes when
# AUTO_DEPLOY=true in instance/.env; does nothing if there is nothing new.
# Two repositories are watched: this one, and instance/ if it is a git
# repository with a remote (settings and encrypted secrets).
#
#   new commit on a remote branch
#     -> fast-forward the checkout
#     -> validate, build the image if needed, update systemd units (install.sh)
#     -> restart the stack only if what runs in the containers changed
#     -> run check.sh; if it fails, go back to the previous commit and image
#     -> report the result (journal, and Signal if ALERT_SIGNAL_RECIPIENT is set)
#
# A commit that failed is not tried again; push a new one.
# Pause the automation with:  touch deploy/PAUSE   (remove the file to resume)
#
# Whoever can push to the deployed branch runs code as root on this server.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
env_get() { [ -f "$REPO_DIR/.env" ] && sed -n "s/^$1=//p" "$REPO_DIR/.env" | tail -n1 || true; }
# shellcheck source=monitor/notify.sh
. "$REPO_DIR/monitor/notify.sh"

STATE_DIR=/var/lib/hermes-deploy
FAILED="$STATE_DIR/failed-commit"   # do not retry this one
DEPLOYING=/run/hermes-deploying     # tells the monitor to stay quiet
# Changes under these paths alter what runs in the containers.
RESTART_PATHS='^(compose\.yaml|Dockerfile|docker/|caddy/|instance/(\.env|secrets/))'
BUILD_PATHS='^(Dockerfile|docker/)'

host="$(hostname)"
log() { printf 'deploy: %s\n' "$*"; }

webapp_up() {
  case "$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' http://127.0.0.1:9120/ 2>/dev/null)" in
    200|301|302) return 0 ;; *) return 1 ;;
  esac
}

# Restart the stack and wait until the Webapp answers and the checks pass.
restart_and_check() {
  systemctl restart hermes-docker.service || return 1
  local i
  for i in $(seq 1 100); do webapp_up && break; sleep 3; done
  webapp_up || return 1
  sleep 20   # let the gateway connect to Signal
  "$REPO_DIR/check.sh" --quiet
}

# Do not cut off a cron job that is about to start; running turns are drained
# by the gateway itself when it stops.
wait_for_quiet_moment() {
  local data jobs i
  data="$(env_get HERMES_DATA_DIR)"; jobs="${data:-/home/hermes}/.hermes/cron/jobs.json"
  for i in $(seq 1 20); do
    python3 - "$jobs" <<'PY' && return 0
import datetime, json, sys
try:
    jobs = json.load(open(sys.argv[1])).get("jobs", [])
except Exception:
    sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
for job in jobs:
    if not job.get("enabled"):
        continue
    try:
        due = datetime.datetime.fromisoformat(job["next_run_at"])
    except Exception:
        continue
    if -90 <= (due - now).total_seconds() <= 150:
        sys.exit(1)   # a job starts within 2.5 minutes or started just now
PY
    sleep 30
  done
  return 0
}

main() {
  cd "$REPO_DIR" || exit 1
  [ -f deploy/PAUSE ] && exit 0

  local branch old new ibranch iold="" inew="" has_instance=0
  local changed needs_restart=0 needs_build=0 subject short what
  branch="$(git rev-parse --abbrev-ref HEAD)"
  git fetch -q origin "$branch" || { log "git fetch failed"; exit 1; }
  old="$(git rev-parse HEAD)"
  new="$(git rev-parse "origin/$branch")"

  if [ -d instance/.git ] && git -C instance remote get-url origin >/dev/null 2>&1; then
    has_instance=1
    ibranch="$(git -C instance rev-parse --abbrev-ref HEAD)"
    git -C instance fetch -q origin "$ibranch" || { log "git fetch of instance/ failed"; exit 1; }
    iold="$(git -C instance rev-parse HEAD)"
    inew="$(git -C instance rev-parse "origin/$ibranch")"
  fi

  [ "$old" = "$new" ] && [ "$iold" = "$inew" ] && exit 0
  what="$new:$inew"
  [ "$(cat "$FAILED" 2>/dev/null)" = "$what" ] && exit 0

  mkdir -p "$STATE_DIR"
  if [ "$old" != "$new" ]; then
    short="$(git rev-parse --short "$new")"; subject="$(git log -1 --format=%s "$new")"
  else
    short="instance $(git -C instance rev-parse --short "$inew")"; subject="$(git -C instance log -1 --format=%s "$inew")"
  fi

  refuse() {  # nothing was changed yet
    echo "$what" > "$FAILED"
    notify "Hermes on $host: not deploying $short ($subject): $1"
    exit 1
  }
  if ! git diff --quiet || ! git diff --cached --quiet; then
    refuse "the checkout on the server has local changes"
  fi
  git merge-base --is-ancestor "$old" "$new" || refuse "it is not a fast-forward of what is deployed"
  if [ "$has_instance" -eq 1 ]; then
    [ -z "$(git -C instance status --porcelain)" ] || refuse "instance/ on the server has local changes"
    git -C instance merge-base --is-ancestor "$iold" "$inew" || refuse "instance/ is not a fast-forward of what is deployed"
  fi

  changed="$(git diff --name-only "$old" "$new")"
  if [ "$has_instance" -eq 1 ]; then
    changed="$changed
$(git -C instance diff --name-only "$iold" "$inew" | sed 's#^#instance/#')"
  fi
  echo "$changed" | grep -qE "$RESTART_PATHS" && needs_restart=1
  echo "$changed" | grep -qE "$BUILD_PATHS" && needs_build=1
  log "deploying $short ($subject); build=$needs_build restart=$needs_restart"

  touch "$DEPLOYING"
  trap 'rm -f "$DEPLOYING"' EXIT

  rollback() {  # <reason>: return to the previous commits, image and a restart if they changed
    log "rolling back: $1"
    git reset -q --hard "$old"
    [ "$has_instance" -eq 1 ] && git -C instance reset -q --hard "$iold"
    if [ "$needs_build" -eq 1 ] && docker image inspect hermes-agent-local:rollback >/dev/null 2>&1; then
      docker tag hermes-agent-local:rollback hermes-agent-local:latest
    fi
    ./install.sh --no-build >/dev/null 2>&1
    if [ "${restarted:-0}" -eq 1 ]; then
      restart_and_check >/dev/null 2>&1 ||
        { echo "$what" > "$FAILED"
          notify "Hermes on $host: deploying $short FAILED ($1) and the previous version did not come back healthy. Needs attention."
          exit 1; }
    fi
    echo "$what" > "$FAILED"
    notify "Hermes on $host: deploying $short ($subject) FAILED: $1. The previous version keeps running."
    exit 1
  }

  git merge -q --ff-only "$new" || refuse "git could not fast-forward"
  if [ "$has_instance" -eq 1 ]; then
    git -C instance merge -q --ff-only "$inew" || rollback "git could not fast-forward instance/"
  fi
  docker compose config -q 2>/dev/null || rollback "compose.yaml or instance/.env is invalid"

  local out
  if [ "$needs_build" -eq 1 ]; then
    docker tag hermes-agent-local:latest hermes-agent-local:rollback 2>/dev/null
    out="$(./install.sh 2>&1)" || rollback "install.sh: $(echo "$out" | tail -n1)"
  else
    out="$(./install.sh --no-build 2>&1)" || rollback "install.sh: $(echo "$out" | tail -n1)"
  fi

  if [ "$needs_restart" -eq 0 ]; then
    notify "Hermes on $host: deployed $short ($subject). No restart was needed."
    exit 0
  fi

  wait_for_quiet_moment
  local started failures restarted=1
  started="$(date +%s)"
  failures="$(restart_and_check)" || rollback "after the restart: $(echo "${failures:-the Webapp did not come up}" | head -n3 | tr '\n' ' ')"
  notify "Hermes on $host: deployed $short ($subject). Restart took $(( $(date +%s) - started )) s, all checks pass."
}

# Everything runs from main so that bash has read the whole file before the
# pull replaces it.
main "$@"
exit
