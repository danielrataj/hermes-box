#!/usr/bin/env bash
# Set up or update Hermes on this server. Safe to run again at any time:
# it only adds what is missing and never touches existing data.
#
#   ./install.sh            check, prepare, build, install systemd units;
#                           starts the stack only if it is not running
#   ./install.sh --restart  the same, then restart the stack to apply changes
#   ./install.sh --no-build skip building the image
#   ./install.sh --prepare  stop once the image and the age key exist, before
#                           anything is checked or started (used by setup.sh)
#
# Needs: Docker with the compose plugin and the installation's own settings in
# instance/ (see instance.example/); a first run creates that directory and
# the age key for the secrets. Run as root from the repository directory.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$REPO_DIR"

restart=0
build=1
prepare=0
for arg in "$@"; do
  case "$arg" in
    --restart) restart=1 ;;
    --no-build) build=0 ;;
    --prepare) prepare=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf 'install: %s\n' "$*" >&2; exit 1; }

# Read one KEY=value from instance/.env without executing the file.
env_get() { sed -n "s/^$1=//p" instance/.env | tail -n1; }

# ── 1. Checks ────────────────────────────────────────────────────────────────
say "Checking prerequisites"
[ "$(id -u)" -eq 0 ] || die "run as root"
command -v docker >/dev/null || die "Docker is not installed"
for tool in curl git jq openssl python3; do
  command -v "$tool" >/dev/null || die "$tool is not installed (used by check.sh and the backup)"
done
docker compose version >/dev/null 2>&1 || die "the Docker compose plugin is missing"

# instance/ holds what belongs to this installation only. It is not part of
# this repository; keep it as a private git repository of its own.
if [ ! -d instance ]; then
  cp -r instance.example instance
  mv instance/env.example instance/.env
  chmod 640 instance/.env
  die "created instance/ from instance.example/. Fill in instance/.env and run ./install.sh again (or put your existing instance repository there instead)."
fi
[ -f instance/.env ] || die "instance/.env is missing; see instance.example/"
mkdir -p instance/secrets
# docker compose and the scripts read ./.env.
if [ -e .env ] && [ ! -L .env ]; then
  die ".env is a regular file from the old layout; move it to instance/.env"
fi
ln -sfn instance/.env .env

[ -n "$(env_get HERMES_DOMAIN)" ] || die "HERMES_DOMAIN is empty in instance/.env"
# Signal is optional: it runs when COMPOSE_PROFILES contains "signal".
signal=0
case ",$(env_get COMPOSE_PROFILES)," in *,signal,*) signal=1 ;; esac
if [ "$signal" -eq 1 ] && [ -z "$(env_get SIGNAL_ACCOUNT)" ]; then
  die "COMPOSE_PROFILES enables Signal but SIGNAL_ACCOUNT is empty in instance/.env"
fi
if [ "$signal" -eq 0 ] && [ -n "$(env_get SIGNAL_ACCOUNT)" ]; then
  die "SIGNAL_ACCOUNT is set but Signal is off; add COMPOSE_PROFILES=signal to instance/.env (or clear SIGNAL_ACCOUNT)"
fi

DATA_DIR="$(env_get HERMES_DATA_DIR)";   DATA_DIR="${DATA_DIR:-/home/hermes}"
RUN_UID="$(env_get HERMES_UID)";         RUN_UID="${RUN_UID:-1000}"
RUN_GID="$(env_get HERMES_GID)";         RUN_GID="${RUN_GID:-1000}"
KEY_FILE="$(env_get SOPS_AGE_KEY_FILE)"
KEY_FILE="${KEY_FILE:-/etc/hermes/credentials/age.key}"
DOMAIN="$(env_get HERMES_DOMAIN)"

docker compose config -q || die "compose.yaml or instance/.env is invalid"

if mountpoint -q "$DATA_DIR"; then
  note "data: $DATA_DIR (separate volume)"
else
  note "data: $DATA_DIR (NOT a separate volume; it shares the system disk)"
fi

# ── 2. User and directories ──────────────────────────────────────────────────
say "Preparing user and data directories"
if ! getent group "$RUN_GID" >/dev/null; then
  groupadd -g "$RUN_GID" hermes
  note "created group hermes ($RUN_GID)"
fi
if ! getent passwd "$RUN_UID" >/dev/null; then
  useradd -u "$RUN_UID" -g "$RUN_GID" -d "$DATA_DIR" -M -s /bin/bash hermes
  note "created user hermes ($RUN_UID)"
fi

as_owner() { setpriv --reuid="$RUN_UID" --regid="$RUN_GID" --clear-groups "$@"; }

if [ ! -d "$DATA_DIR" ]; then
  install -d -m 750 -o "$RUN_UID" -g "$RUN_GID" "$DATA_DIR"
  note "created $DATA_DIR"
fi
for dir in .hermes openknowledge projects .config/himalaya .local/bin .local/share/signal-cli; do
  if [ ! -d "$DATA_DIR/$dir" ]; then
    as_owner mkdir -p "$DATA_DIR/$dir"
    note "created $DATA_DIR/$dir"
  fi
done
# The container's ~ is the .hermes directory itself; this keeps `~/.hermes/...`
# in cron jobs and skills working.
if [ ! -e "$DATA_DIR/.hermes/.hermes" ] && [ ! -L "$DATA_DIR/.hermes/.hermes" ]; then
  as_owner ln -s . "$DATA_DIR/.hermes/.hermes"
  note "created symlink $DATA_DIR/.hermes/.hermes -> ."
fi
# ssh in the container looks for known_hosts in its own home, .hermes/.ssh.
# Carry over the hosts a previous host install already trusted; the agent's
# git wrappers use strict host key checking.
if [ ! -f "$DATA_DIR/.hermes/.ssh/known_hosts" ] && [ -f "$DATA_DIR/.ssh/known_hosts" ]; then
  as_owner sh -c "umask 077; mkdir -p '$DATA_DIR/.hermes/.ssh' && cp '$DATA_DIR/.ssh/known_hosts' '$DATA_DIR/.hermes/.ssh/known_hosts'"
  note "copied known_hosts to $DATA_DIR/.hermes/.ssh"
fi

# ── 3. Image ─────────────────────────────────────────────────────────────────
if [ "$build" -eq 1 ]; then
  say "Building the image (first run downloads several GB)"
  docker compose build gateway
  docker compose pull --quiet caddy
  [ "$signal" -eq 0 ] || docker compose pull --quiet signal
fi

# ── 4. Secrets ───────────────────────────────────────────────────────────────
say "Checking secrets"
tool() {  # run sops / age-keygen from the image, offline
  docker run --rm --network none -e SOPS_DISABLE_VERSION_CHECK=1 "$@"
}
if [ ! -s "$KEY_FILE" ]; then
  install -d -m 700 "$(dirname "$KEY_FILE")"
  (umask 077; tool --entrypoint age-keygen hermes-agent-local 2>/dev/null > "$KEY_FILE")
  [ -s "$KEY_FILE" ] || die "could not create the age key $KEY_FILE"
  note "created a new age key: $KEY_FILE"
fi
chmod 600 "$KEY_FILE"
PUBLIC_KEY="$(tool -v "$KEY_FILE:/age.key:ro" --entrypoint age-keygen hermes-agent-local -y /age.key)"
note "this server's public key: $PUBLIC_KEY"

# Recipients for sops; a new installation starts with this server's key only.
if [ ! -f instance/.sops.yaml ] || grep -q 'age1REPLACE' instance/.sops.yaml; then
  cat > instance/.sops.yaml <<EOF
# Who can decrypt the files in secrets/. These are public keys.
# After changing the list: ./sops.sh updatekeys secrets/<file>, run by someone
# who can already decrypt it.
creation_rules:
  - path_regex: secrets/.*\\.enc\\.yaml\$
    age: >-
      $PUBLIC_KEY
EOF
  note "wrote instance/.sops.yaml with this server as the only recipient"
fi

if [ "$prepare" -eq 1 ]; then
  say "Prepared: image, user, directories and the age key are in place"
  exit 0
fi

[ -f instance/secrets/hermes.enc.yaml ] ||
  die "instance/secrets/hermes.enc.yaml is missing. Create it with ./sops.sh secrets/hermes.enc.yaml (one NAME: value per line); see README, Tajné údaje."
for file in instance/secrets/*.enc.yaml; do
  if ! tool -e SOPS_AGE_KEY_FILE=/age.key -v "$KEY_FILE:/age.key:ro" -v "$REPO_DIR/instance/secrets:/instance/secrets:ro" \
       --entrypoint sops hermes-agent-local decrypt "/$file" >/dev/null 2>&1; then
    die "this server cannot decrypt $file. Where you can decrypt it: add the public key above to instance/.sops.yaml, run './sops.sh updatekeys ${file#instance/}', commit, then bring it here and run ./install.sh again."
  fi
done
note "all files in instance/secrets/ decrypt with this server's key"

# ── 5. Settings in Hermes' own config ────────────────────────────────────────
config_changed=0
if [ -f "$DATA_DIR/.hermes/config.yaml" ]; then
  say "Checking settings in config.yaml"
  hermes_config() {
    docker run --rm --network none --entrypoint /opt/hermes/bin/hermes \
      -u "$RUN_UID:$RUN_GID" -e HERMES_HOME=/opt/data -e HOME=/opt/data \
      -v "$DATA_DIR/.hermes:/opt/data" hermes-agent-local config "$@" 2>/dev/null
  }
  want_url="https://$DOMAIN"
  if [ "$(hermes_config get webapp.enabled | tail -n1)" != "true" ]; then
    hermes_config set webapp.enabled true >/dev/null
    note "set webapp.enabled = true"; config_changed=1
  fi
  if [ "$(hermes_config get webapp.public_url | tail -n1)" != "$want_url" ]; then
    hermes_config set webapp.public_url "$want_url" >/dev/null
    note "set webapp.public_url = $want_url"; config_changed=1
  fi
  # Tools and cron scripts must see HOME=/opt/data, not the isolated
  # /opt/data/home: `~/.config/himalaya` and `~/.hermes/...` live there.
  # config.yaml overrides the TERMINAL_HOME_MODE environment variable, so the
  # setting has to be made here.
  if [ "$(hermes_config get terminal.home_mode | tail -n1)" != "real" ]; then
    hermes_config set terminal.home_mode real >/dev/null
    note "set terminal.home_mode = real"; config_changed=1
  fi
  [ "$config_changed" -eq 1 ] || note "already set"
else
  note "no config.yaml in $DATA_DIR/.hermes yet: this is an empty data directory."
  note "Restore the data first, or run ./setup.sh for a first-time setup."
fi

# ── 6. systemd units ─────────────────────────────────────────────────────────
say "Installing systemd units"
units_changed=0
install_unit() {  # <template> <target>
  local rendered
  rendered="$(mktemp)"
  sed -e "s#@REPO_DIR@#$REPO_DIR#g" -e "s#@DATA_DIR@#$DATA_DIR#g" "$1" > "$rendered"
  if ! cmp -s "$rendered" "$2"; then
    install -D -m 644 "$rendered" "$2"
    note "updated $2"; units_changed=1
  fi
  rm -f "$rendered"
}
install_unit server/hermes-docker.service  /etc/systemd/system/hermes-docker.service
install_unit server/hermes-backup.service  /etc/systemd/system/hermes-backup.service
install_unit server/hermes-backup.timer    /etc/systemd/system/hermes-backup.timer
install_unit server/hermes-monitor.service /etc/systemd/system/hermes-monitor.service
install_unit server/hermes-monitor.timer   /etc/systemd/system/hermes-monitor.timer
install_unit server/hermes-deploy.service  /etc/systemd/system/hermes-deploy.service
install_unit server/hermes-deploy.timer    /etc/systemd/system/hermes-deploy.timer
install_unit server/docker-volume.conf     /etc/systemd/system/docker.service.d/hermes-volume.conf
if [ "$units_changed" -eq 1 ]; then systemctl daemon-reload; else note "already up to date"; fi
systemctl enable --quiet hermes-docker.service hermes-backup.timer hermes-monitor.timer
systemctl start hermes-backup.timer hermes-monitor.timer
if [ "$(env_get AUTO_DEPLOY)" = "true" ]; then
  systemctl enable --quiet --now hermes-deploy.timer
  note "automatic deployment from git: on"
else
  systemctl disable --quiet --now hermes-deploy.timer 2>/dev/null || true
  note "automatic deployment from git: off (AUTO_DEPLOY=true in instance/.env turns it on)"
fi

# ── 7. Start ─────────────────────────────────────────────────────────────────
if [ ! -f "$DATA_DIR/.hermes/config.yaml" ]; then
  say "Not starting: the data directory is empty"
elif [ "$restart" -eq 1 ]; then
  say "Restarting the stack"
  systemctl restart hermes-docker.service
elif ! systemctl is-active --quiet hermes-docker.service; then
  say "Starting the stack"
  systemctl start hermes-docker.service
else
  say "The stack is running and was left alone"
  note "apply image, compose or config changes with: ./install.sh --restart"
fi

say "Done"
note "Webapp:    https://$DOMAIN"
note "health:    ./check.sh"
note "status:    systemctl status hermes-docker"
note "logs:      docker logs -f --tail 100 hermes"
