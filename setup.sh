#!/usr/bin/env bash
# First-time setup of a new installation, from an empty server to a running
# agent. Asks a few questions, then:
#
#   1. writes instance/.env
#   2. gets the image (pulled or built), creates the user, the data directories and the age key
#   3. creates the first encrypted secrets (including the backup password)
#   4. lets Hermes' own wizard pick the model and provider
#   5. sets up the sign-in for the Webapp
#   6. installs the services and starts everything (./install.sh)
#
# Safe to run again: finished steps are skipped, so a later run adds what was
# skipped the first time (the model, the sign-in) and restarts the
# stack if it changed anything. Everything else about an existing installation
# is updated with ./install.sh.
#
#   ./setup.sh             interactive
#   ./setup.sh --no-start  everything except step 6
#
# Every question can be answered in advance through the environment, which
# also allows an unattended setup (step 4 needs a terminal and is skipped
# without one):
#
#   SETUP_DOMAIN=agent.example.com      public host name of the Webapp
#   SETUP_DATA_DIR=/home/hermes         where all state lives
#   SETUP_MODEL=wizard|skip             run Hermes' model wizard
#   SETUP_WEBAPP_LOGIN=password|skip
#   SETUP_WEBAPP_USER=admin  SETUP_WEBAPP_PASSWORD=...
#   SETUP_AUTO_DEPLOY=yes|no

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$REPO_DIR"

start=1
for arg in "$@"; do
  case "$arg" in
    --no-start) start=0 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf 'setup: %s\n' "$*" >&2; exit 1; }

interactive=0
if [ -t 0 ] && [ -t 1 ]; then interactive=1; fi

# ask <ENV_NAME> <question> [default]: the preset value, else the answer, else the default.
ask() {
  local preset="${!1:-}" answer=""
  if [ -n "$preset" ]; then printf '%s' "$preset"; return; fi
  if [ "$interactive" -eq 1 ]; then
    if [ -n "${3:-}" ]; then read -r -p "$2 [$3]: " answer </dev/tty; else read -r -p "$2: " answer </dev/tty; fi
  fi
  printf '%s' "${answer:-${3:-}}"
}
yes_no() {  # <ENV_NAME> <question> <default yes|no>
  case "$(ask "$1" "$2 (yes/no)" "$3")" in y|Y|yes|YES|true|ano|a) return 0 ;; *) return 1 ;; esac
}

env_get() { sed -n "s/^$1=//p" instance/.env 2>/dev/null | tail -n1; }
# The image to run: a published one named in instance/.env or in release.env
# (written by docker/extract.sh), else the one built here from the Dockerfile.
image_ref() {
  local ref
  ref="$(env_get HERMES_BOX_IMAGE)"
  [ -n "$ref" ] || ref="$(sed -n 's/^HERMES_BOX_IMAGE=//p' "$REPO_DIR/release.env" 2>/dev/null | tail -n1)"
  printf '%s' "${ref:-hermes-agent-local}"
}
# Set KEY=value in instance/.env: replace the line (also a commented-out one) or append.
env_set() {
  local key="$1" value="$2" file=instance/.env tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    !done && ($0 ~ "^" k "=" || $0 ~ "^# *" k "=") { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' "$file" > "$tmp"
  cat "$tmp" > "$file"; rm -f "$tmp"
}

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v docker >/dev/null || die "Docker is not installed (get.sh installs it, see README; or https://docs.docker.com/engine/install/)"

# The few host tools check.sh and the backup use; Docker is the only thing
# that has to be there beforehand.
missing=""
for tool in curl jq openssl python3; do
  command -v "$tool" >/dev/null || missing="$missing $tool"
done
if [ -n "$missing" ]; then
  command -v apt-get >/dev/null || die "not installed:$missing (install them and run ./setup.sh again)"
  say "Installing$missing"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  # shellcheck disable=SC2086  # a list of package names
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing >/dev/null
fi

# ── 1. Settings ──────────────────────────────────────────────────────────────
say "Settings (instance/.env)"
if [ ! -f instance/.env ]; then
  mkdir -p instance/secrets
  cp instance.example/env.example instance/.env
  [ -f instance/README.md ] || cp instance.example/README.md instance/README.md
  chmod 640 instance/.env
  note "created instance/.env"
fi

if [ -z "$(env_get HERMES_DOMAIN)" ]; then
  domain="$(ask SETUP_DOMAIN "Public host name of the Webapp, e.g. agent.example.com")"
  [ -n "$domain" ] || die "a host name is required (SETUP_DOMAIN)"
  case "$domain" in *://*|*/*|*' '*) die "give the bare host name, without https:// or a path" ;; esac
  env_set HERMES_DOMAIN "$domain"
fi
DOMAIN="$(env_get HERMES_DOMAIN)"
note "Webapp: https://$DOMAIN (its DNS record has to point at this server)"

if [ -n "${SETUP_DATA_DIR:-}" ] && [ -z "$(env_get HERMES_DATA_DIR)" ]; then
  env_set HERMES_DATA_DIR "$SETUP_DATA_DIR"
fi
DATA_DIR="$(env_get HERMES_DATA_DIR)"; DATA_DIR="${DATA_DIR:-/home/hermes}"
RUN_UID="$(env_get HERMES_UID)";       RUN_UID="${RUN_UID:-1000}"
RUN_GID="$(env_get HERMES_GID)";       RUN_GID="${RUN_GID:-1000}"
KEY_FILE="$(env_get SOPS_AGE_KEY_FILE)"; KEY_FILE="${KEY_FILE:-/etc/hermes/credentials/age.key}"
note "data: $DATA_DIR"

# A run on a server that is already set up only adds what is still missing.
existing=0
changed=0
if [ -f "$DATA_DIR/.hermes/config.yaml" ] && [ -f instance/secrets/hermes.enc.yaml ] &&
   systemctl is-enabled --quiet hermes-docker.service 2>/dev/null; then
  existing=1
  note "this server is already set up; only the steps skipped so far are offered"
fi
# Hermes writes the chosen model as a top-level "model:" entry. The file alone
# says nothing: this script creates it even when the wizard is skipped.
model_set() { grep -Eqs '^model:' "$DATA_DIR/.hermes/config.yaml"; }

# ── 2. Image, user, directories, age key ─────────────────────────────────────
say "Preparing the server (the first run downloads several GB)"
./install.sh --prepare
IMAGE="$(image_ref)"

# Tools from the image; nothing else is installed on the host.
sops_encrypt() {  # <name>: JSON on stdin -> instance/secrets/<name>.enc.yaml
  local out="instance/secrets/$1.enc.yaml"
  docker run --rm -i --network none -e SOPS_DISABLE_VERSION_CHECK=1 \
    -v "$REPO_DIR/instance:/work:ro" -w /work --entrypoint sops "$IMAGE" \
    encrypt --input-type json --output-type yaml --filename-override "secrets/$1.enc.yaml" /dev/stdin > "$out.new"
  [ -s "$out.new" ] || { rm -f "$out.new"; die "could not encrypt $out"; }
  mv "$out.new" "$out"; chmod 644 "$out"
}
hermes() {  # run the hermes CLI on the data directory; HERMES_TTY=1 attaches the terminal
  local tty=()
  if [ "${HERMES_TTY:-0}" -eq 1 ]; then tty=(-it); fi
  docker run --rm ${tty[@]+"${tty[@]}"} --network "${HERMES_NET:-none}" \
    -u "$RUN_UID:$RUN_GID" -e HERMES_HOME=/opt/data -e HOME=/opt/data -w /opt/hermes \
    -v "$DATA_DIR/.hermes:/opt/data" --entrypoint /opt/hermes/bin/hermes "$IMAGE" "$@"
}
hermes_quiet() { hermes "$@" >/dev/null 2>&1; }

# ── 3. First secrets ─────────────────────────────────────────────────────────
say "Secrets (instance/secrets/, encrypted for this server's key)"
if [ ! -f instance/secrets/hermes.enc.yaml ]; then
  # The agent's secrets start with a harmless marker; add real ones later
  # with ./sops.sh secrets/hermes.enc.yaml (one NAME: value per line).
  python3 -c 'import json,sys; print(json.dumps({"HERMES_INSTANCE": sys.argv[1]}))' "$DOMAIN" | sops_encrypt hermes
  note "created instance/secrets/hermes.enc.yaml"
else
  note "instance/secrets/hermes.enc.yaml exists"
fi
if [ ! -f instance/secrets/backup.enc.yaml ]; then
  [ ! -d "$DATA_DIR/backups/restic-repo" ] ||
    die "a backup repository exists in $DATA_DIR/backups but its password (instance/secrets/backup.enc.yaml) does not; restore that file instead of creating a new password"
  head -c 32 /dev/urandom | base64 | tr -d '\n' |
    python3 -c 'import json,sys; print(json.dumps({"RESTIC_PASSWORD": sys.stdin.read()}))' | sops_encrypt backup
  note "created instance/secrets/backup.enc.yaml (a random backup password)"
else
  note "instance/secrets/backup.enc.yaml exists"
fi

# ── 4. Model and provider (Hermes' own wizard) ───────────────────────────────
say "Model and provider"
if model_set; then
  note "a model is already configured in $DATA_DIR/.hermes/config.yaml"
elif [ "$interactive" -eq 1 ] && [ "$(ask SETUP_MODEL "Run Hermes' model wizard now? (wizard/skip)" wizard)" = wizard ]; then
  note "Hermes' wizard follows; pick a provider and a model."
  HERMES_TTY=1 HERMES_NET=host hermes setup model </dev/tty || note "the wizard did not finish; repeat it later (see README, Model and provider)"
  ! model_set || changed=1
else
  note "skipped; the agent will not answer until a model is configured (see README, Model and provider)"
fi
# Make sure the configuration file exists; install.sh fills in the rest.
[ -f "$DATA_DIR/.hermes/config.yaml" ] || hermes_quiet config set webapp.enabled true ||
  die "could not create $DATA_DIR/.hermes/config.yaml"

# ── 5. Sign-in for the Webapp ────────────────────────────────────────────────
say "Sign-in for the Webapp"
# The user name and password are the only sign-in. A server that used a Nous
# Portal account counts as not set up, and setting the password removes that
# sign-in: Hermes would otherwise offer both. The Nous account itself stays
# logged in, so a model served by Nous Portal keeps working.
drop_nous_login() {
  local env="$DATA_DIR/.hermes/.env" tmp
  if grep -qs '^HERMES_DASHBOARD_OAUTH_CLIENT_ID=' "$env"; then
    tmp="$(mktemp)"
    grep -v '^HERMES_DASHBOARD_OAUTH_CLIENT_ID=' "$env" > "$tmp" || true
    cat "$tmp" > "$env"; rm -f "$tmp"
    note "removed the Nous Portal sign-in"
  fi
  hermes_quiet config unset dashboard.oauth.client_id || true
  rm -f "$DATA_DIR/.hermes/webapp/sign-in-registration.json"
}
if [ -n "$(hermes config get dashboard.basic_auth.username 2>/dev/null | tail -n1)" ]; then
  note "already configured"
else
  login="$(ask SETUP_WEBAPP_LOGIN "Set the user name and password now? (password/skip)" password)"
  case "$login" in
    password)
      user="$(ask SETUP_WEBAPP_USER "User name" admin)"
      password="${SETUP_WEBAPP_PASSWORD:-}"
      if [ -z "$password" ] && [ "$interactive" -eq 1 ]; then
        while :; do
          read -r -s -p "Password (at least 12 characters): " password </dev/tty; echo
          read -r -s -p "Once more: " again </dev/tty; echo
          [ "$password" = "$again" ] && [ "${#password}" -ge 12 ] && break
          echo "    the passwords differ or are too short"
        done
      fi
      [ "${#password}" -ge 12 ] || die "a password of at least 12 characters is required (SETUP_WEBAPP_PASSWORD)"
      # Only the scrypt hash is stored; the password goes in on stdin.
      hash="$(printf '%s' "$password" | docker run --rm -i --network none -w /opt/hermes \
        --entrypoint /opt/hermes/.venv/bin/python "$IMAGE" -c \
        'import sys; from plugins.dashboard_auth.basic import hash_password; print(hash_password(sys.stdin.read()))' 2>/dev/null | tail -n1)"
      unset password again
      case "$hash" in scrypt\$*) ;; *) die "could not hash the password" ;; esac
      hermes_quiet config set dashboard.basic_auth.username "$user"
      hermes_quiet config set dashboard.basic_auth.password_hash "$hash"
      hermes_quiet config set dashboard.basic_auth.secret "$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
      drop_nous_login
      note "sign in at https://$DOMAIN as '$user' with that password"
      changed=1
      ;;
    *)
      note "skipped: without a sign-in Hermes will not serve the Webapp on a public address"
      ;;
  esac
fi

# ── 6. Start ─────────────────────────────────────────────────────────────────
# Only a git checkout can follow its remote; an installation from a published
# image is updated by extracting a newer image (see README).
if [ -d .git ] && [ -z "$(env_get AUTO_DEPLOY)" ] && yes_no SETUP_AUTO_DEPLOY "Deploy new commits from git automatically?" no; then
  env_set AUTO_DEPLOY true
fi

if [ "$start" -eq 0 ]; then
  say "Prepared. Start everything with ./install.sh"
  exit 0
fi

say "Installing the services and starting"
if [ "$existing" -eq 1 ] && [ "$changed" -eq 1 ]; then
  # A running stack reads its configuration only at start.
  ./install.sh --restart
else
  ./install.sh
fi
if [ "$existing" -eq 0 ] || [ "$changed" -eq 1 ]; then sleep 30; fi
if [ "$existing" -eq 0 ]; then
  note "running the first backup"
  systemctl start hermes-backup.service || note "the first backup failed; see journalctl -u hermes-backup"
fi
./check.sh || note "some checks fail right after a start; run ./check.sh again in a few minutes"

say "Done"
note "Webapp:  https://$DOMAIN"
note "Now keep two things somewhere other than this server:"
note "  1. the private key $KEY_FILE (without it the secrets and backups cannot be read)"
note "  2. the directory instance/, best as a private git repository (see instance/README.md)"
