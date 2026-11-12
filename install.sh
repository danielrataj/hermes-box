#!/usr/bin/env bash
# Set up or update Hermes on this server. Safe to run again at any time:
# it only adds what is missing and never touches existing data.
#
#   ./install.sh            check, prepare, build, install systemd units;
#                           starts the stack only if it is not running
#   ./install.sh --restart  the same, then restart the stack to apply changes
#   ./install.sh --no-build skip building (or pulling) the image
#   ./install.sh --prepare  stop once the image and the age key exist, before
#                           anything is checked or started (used by setup.sh)
#
# The image is pulled when a published one is named (release.env, or
# HERMES_BOX_IMAGE in instance/.env) and built from the Dockerfile otherwise.
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
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf 'install: %s\n' "$*" >&2; exit 1; }

# Read one KEY=value from instance/.env without executing the file.
env_get() { sed -n "s/^$1=//p" instance/.env 2>/dev/null | tail -n1; }
# The image to run: a published one named in instance/.env or in release.env
# (written by docker/extract.sh), else the one built here from the Dockerfile.
image_ref() {
  local ref
  ref="$(env_get HERMES_BOX_IMAGE)"
  [ -n "$ref" ] || ref="$(sed -n 's/^HERMES_BOX_IMAGE=//p' "$REPO_DIR/release.env" 2>/dev/null | tail -n1)"
  printf '%s' "${ref:-hermes-agent-local}"
}

# ── 1. Checks ────────────────────────────────────────────────────────────────
say "Checking prerequisites"
[ "$(id -u)" -eq 0 ] || die "run as root"
command -v docker >/dev/null || die "Docker is not installed"
for tool in curl jq openssl python3; do
  command -v "$tool" >/dev/null || die "$tool is not installed (used by check.sh and the backup)"
done
# git is needed only where the installation is a git checkout (automatic
# deployment); one installed from a published image has no .git.
if [ -d .git ]; then
  command -v git >/dev/null || die "git is not installed (used by the automatic deployment)"
fi
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
# An installation may run containers of its own next to these: Compose merges
# compose.override.yaml into compose.yaml by itself, so instance/compose.yaml
# only has to be reachable under that name.
if [ -e compose.override.yaml ] && [ ! -L compose.override.yaml ]; then
  die "compose.override.yaml is a regular file; an installation's own services belong in instance/compose.yaml"
fi
if [ -f instance/compose.yaml ]; then
  ln -sfn instance/compose.yaml compose.override.yaml
else
  rm -f compose.override.yaml
fi

DATA_DIR="$(env_get HERMES_DATA_DIR)";   DATA_DIR="${DATA_DIR:-/home/hermes}"
RUN_UID="$(env_get HERMES_UID)";         RUN_UID="${RUN_UID:-1000}"
RUN_GID="$(env_get HERMES_GID)";         RUN_GID="${RUN_GID:-1000}"
KEY_FILE="$(env_get SOPS_AGE_KEY_FILE)"
KEY_FILE="${KEY_FILE:-/etc/hermes/credentials/age.key}"
DOMAIN="$(env_get HERMES_DOMAIN)"
IMAGE="$(image_ref)"
# compose.yaml reads the image name from the environment.
export HERMES_BOX_IMAGE="$IMAGE"

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
# .hermes/.config/himalaya is where compose mounts the mail configuration
# inside the data mount; Docker would create a missing mount point as root.
for dir in .hermes openknowledge projects .config/himalaya .local/bin .hermes/.config/himalaya; do
  if [ ! -d "$DATA_DIR/$dir" ]; then
    as_owner mkdir -p "$DATA_DIR/$dir"
    note "created $DATA_DIR/$dir"
  fi
done
# Earlier versions left that mount point to Docker; hand it back to the owner.
for dir in .hermes/.config .hermes/.config/himalaya; do
  if [ "$(stat -c %u "$DATA_DIR/$dir")" != "$RUN_UID" ] && ! mountpoint -q "$DATA_DIR/$dir"; then
    chown "$RUN_UID:$RUN_GID" "$DATA_DIR/$dir"
    note "changed the owner of $DATA_DIR/$dir to $RUN_UID"
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
  if [ "$IMAGE" = hermes-agent-local ]; then
    say "Building the image (first run downloads several GB)"
    docker compose build gateway
  else
    say "Pulling the image $IMAGE (first run downloads several GB)"
    docker pull --quiet "$IMAGE" >/dev/null
  fi
  # Caddy and whatever instance/compose.yaml adds; the gateway is done above.
  docker compose pull --quiet --ignore-buildable
fi

# ── 4. Secrets ───────────────────────────────────────────────────────────────
say "Checking secrets"
tool() {  # run sops / age-keygen from the image, offline
  docker run --rm --network none -e SOPS_DISABLE_VERSION_CHECK=1 "$@"
}
if [ ! -s "$KEY_FILE" ]; then
  install -d -m 700 "$(dirname "$KEY_FILE")"
  (umask 077; tool --entrypoint age-keygen "$IMAGE" 2>/dev/null > "$KEY_FILE")
  [ -s "$KEY_FILE" ] || die "could not create the age key $KEY_FILE"
  note "created a new age key: $KEY_FILE"
fi
chmod 600 "$KEY_FILE"
PUBLIC_KEY="$(tool -v "$KEY_FILE:/age.key:ro" --entrypoint age-keygen "$IMAGE" -y /age.key)"
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
  die "instance/secrets/hermes.enc.yaml is missing. Create it with ./sops.sh secrets/hermes.enc.yaml (one NAME: value per line); see README, Secrets."
for file in instance/secrets/*.enc.yaml; do
  if ! tool -e SOPS_AGE_KEY_FILE=/age.key -v "$KEY_FILE:/age.key:ro" -v "$REPO_DIR/instance/secrets:/instance/secrets:ro" \
       --entrypoint sops "$IMAGE" decrypt "/$file" >/dev/null 2>&1; then
    die "this server cannot decrypt $file. Where you can decrypt it: add the public key above to instance/.sops.yaml, run './sops.sh updatekeys ${file#instance/}', commit, then bring it here and run ./install.sh again."
  fi
done
note "all files in instance/secrets/ decrypt with this server's key"

# ── 5. Settings in Hermes' own config ────────────────────────────────────────
config_changed=0
if [ -f "$DATA_DIR/.hermes/config.yaml" ]; then
  say "Checking settings in config.yaml"
  hermes_offline() {  # the hermes CLI against the data directory, offline
    docker run --rm --network none --entrypoint /opt/hermes/bin/hermes \
      -u "$RUN_UID:$RUN_GID" -e HERMES_HOME=/opt/data -e HOME=/opt/data \
      -v "$DATA_DIR/.hermes:/opt/data" "$IMAGE" "$@" 2>/dev/null
  }
  hermes_config() { hermes_offline config "$@"; }
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
  # The browser: the image ships Chromium, so cron jobs can open pages that
  # web_extract cannot read. Without a provider Hermes picks one from whatever
  # keys it finds, and a cloud one would be chosen over the local Chromium;
  # a provider somebody chose on purpose is left alone.
  if ! hermes_config get browser.cloud_provider | tail -n1 | grep -qx '[a-z0-9_-]\{1,\}'; then
    hermes_config set browser.cloud_provider local >/dev/null
    note "set browser.cloud_provider = local"; config_changed=1
  fi
  # browser_exec is offered only to sessions that also have the terminal.
  cron_tools="$(hermes_offline tools list --platform cron || true)"
  for toolset in browser terminal; do
    if ! printf '%s\n' "$cron_tools" | grep -q " enabled  *$toolset "; then
      if hermes_offline tools enable "$toolset" --platform cron >/dev/null; then
        note "enabled the $toolset toolset for cron jobs"; config_changed=1
      else
        note "could not enable the $toolset toolset for cron jobs"
      fi
    fi
  done
  # The Firecrawl in compose.yaml both searches and reads pages. Hermes chooses a
  # backend from the keys it finds only until one is written to config.yaml,
  # so an earlier choice (often a search-only one) would keep web_extract
  # failing. web.search_backend and web.extract_backend take precedence over
  # web.backend and are left alone: that is where to choose something else.
  if [ "$(hermes_config get web.backend | tail -n1)" != "firecrawl" ]; then
    hermes_config set web.backend firecrawl >/dev/null
    note "set web.backend = firecrawl"; config_changed=1
  fi
  for key in web.search_backend web.extract_backend; do
    other="$(hermes_config get "$key" | tail -n1 | grep -x '[a-z0-9_-]\{1,\}' || true)"
    [ -z "$other" ] || [ "$other" = firecrawl ] || note "$key = $other overrides Firecrawl for that half"
  done
  [ "$config_changed" -eq 1 ] || note "already set"
  # The Hermes image leaves pnpm to be installed into the data directory
  # (<data>/.hermes/tools) and complains on every start until it is there:
  # "install out of sync (pnpm: not installed or outdated)". Needs the network.
  hermes_pm() {  # with the network and with stderr, unlike hermes_config
    docker run --rm --init --entrypoint /opt/hermes/bin/hermes \
      -u "$RUN_UID:$RUN_GID" -e HERMES_HOME=/opt/data -e HOME=/opt/data \
      -v "$DATA_DIR/.hermes:/opt/data" "$IMAGE" "$@" 2>&1
  }
  case "$(hermes_pm config get webapp.enabled || true)" in *'out of sync (pnpm'*)
    if hermes_pm pm install pnpm >/dev/null; then
      note "installed pnpm into $DATA_DIR/.hermes/tools"
    else
      note "could not install pnpm; Hermes will keep warning that the install is out of sync"
    fi ;;
  esac
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
  sed -e "s#@REPO_DIR@#$REPO_DIR#g" -e "s#@DATA_DIR@#$DATA_DIR#g" -e "s#@IMAGE@#$IMAGE#g" "$1" > "$rendered"
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
if [ "$(env_get AUTO_DEPLOY)" = "true" ] && [ ! -d .git ]; then
  systemctl disable --quiet --now hermes-deploy.timer 2>/dev/null || true
  note "automatic deployment from git: off (AUTO_DEPLOY=true, but this installation is not a git checkout)"
elif [ "$(env_get AUTO_DEPLOY)" = "true" ]; then
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
