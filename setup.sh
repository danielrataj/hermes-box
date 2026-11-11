#!/usr/bin/env bash
# First-time setup of a new installation, from an empty server to a running
# agent. Asks a few questions, then:
#
#   1. writes instance/.env
#   2. builds the image, creates the user, the data directories and the age key
#   3. creates the first encrypted secrets (including the backup password)
#   4. lets Hermes' own wizard pick the model and provider
#   5. sets up the sign-in for the Webapp
#   6. optionally links a Signal account (QR code)
#   7. installs the services and starts everything (./install.sh)
#
# Safe to run again: finished steps are skipped. An existing installation is
# updated with ./install.sh, not with this script.
#
#   ./setup.sh             interactive
#   ./setup.sh --no-start  everything except step 7
#
# Every question can be answered in advance through the environment, which
# also allows an unattended setup (steps 4 and 6 need a terminal and are
# skipped without one):
#
#   SETUP_DOMAIN=agent.example.com      public host name of the Webapp
#   SETUP_DATA_DIR=/home/hermes         where all state lives
#   SETUP_MODEL=wizard|skip             run Hermes' model wizard
#   SETUP_WEBAPP_LOGIN=password|nous|skip
#   SETUP_WEBAPP_USER=admin  SETUP_WEBAPP_PASSWORD=...
#   SETUP_SIGNAL=yes|no
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
command -v docker >/dev/null || die "Docker is not installed (https://docs.docker.com/engine/install/)"

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

if [ -f "$DATA_DIR/.hermes/config.yaml" ] && [ -f instance/secrets/hermes.enc.yaml ] &&
   systemctl is-enabled --quiet hermes-docker.service 2>/dev/null; then
  die "this server is already set up; use ./install.sh to update it"
fi

# ── 2. Image, user, directories, age key ─────────────────────────────────────
say "Preparing the server (the first build downloads several GB)"
./install.sh --prepare

# Tools from the image; nothing else is installed on the host.
sops_encrypt() {  # <name>: JSON on stdin -> instance/secrets/<name>.enc.yaml
  local out="instance/secrets/$1.enc.yaml"
  docker run --rm -i --network none -e SOPS_DISABLE_VERSION_CHECK=1 \
    -v "$REPO_DIR/instance:/work:ro" -w /work --entrypoint sops hermes-agent-local \
    encrypt --input-type json --output-type yaml --filename-override "secrets/$1.enc.yaml" /dev/stdin > "$out.new"
  [ -s "$out.new" ] || { rm -f "$out.new"; die "could not encrypt $out"; }
  mv "$out.new" "$out"; chmod 644 "$out"
}
hermes() {  # run the hermes CLI on the data directory; HERMES_TTY=1 attaches the terminal
  local tty=()
  if [ "${HERMES_TTY:-0}" -eq 1 ]; then tty=(-it); fi
  docker run --rm ${tty[@]+"${tty[@]}"} --network "${HERMES_NET:-none}" \
    -u "$RUN_UID:$RUN_GID" -e HERMES_HOME=/opt/data -e HOME=/opt/data -w /opt/hermes \
    -v "$DATA_DIR/.hermes:/opt/data" --entrypoint /opt/hermes/bin/hermes hermes-agent-local "$@"
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
if [ -f "$DATA_DIR/.hermes/config.yaml" ]; then
  note "Hermes is already configured in $DATA_DIR/.hermes"
elif [ "$interactive" -eq 1 ] && [ "$(ask SETUP_MODEL "Run Hermes' model wizard now? (wizard/skip)" wizard)" = wizard ]; then
  note "Hermes' wizard follows; pick a provider and a model."
  HERMES_TTY=1 HERMES_NET=host hermes setup model </dev/tty || note "the wizard did not finish; repeat it later (see README)"
else
  note "skipped; the agent will not answer until a model is configured (see README)"
fi
# Make sure the configuration file exists; install.sh fills in the rest.
[ -f "$DATA_DIR/.hermes/config.yaml" ] || hermes_quiet config set webapp.enabled true ||
  die "could not create $DATA_DIR/.hermes/config.yaml"

# ── 5. Sign-in for the Webapp ────────────────────────────────────────────────
say "Sign-in for the Webapp"
has_login=0
[ -z "$(hermes config get dashboard.basic_auth.username 2>/dev/null | tail -n1)" ] || has_login=1
grep -qs '^HERMES_DASHBOARD_OAUTH_CLIENT_ID=.' "$DATA_DIR/.hermes/.env" && has_login=1
if [ "$has_login" -eq 1 ]; then
  note "already configured"
else
  login="$(ask SETUP_WEBAPP_LOGIN "How do you want to sign in? password = a user name and password, nous = a Nous Portal account, skip = decide later" password)"
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
        --entrypoint /opt/hermes/.venv/bin/python hermes-agent-local -c \
        'import sys; from plugins.dashboard_auth.basic import hash_password; print(hash_password(sys.stdin.read()))' 2>/dev/null | tail -n1)"
      unset password again
      case "$hash" in scrypt\$*) ;; *) die "could not hash the password" ;; esac
      hermes_quiet config set dashboard.basic_auth.username "$user"
      hermes_quiet config set dashboard.basic_auth.password_hash "$hash"
      hermes_quiet config set dashboard.basic_auth.secret "$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
      note "sign in at https://$DOMAIN as '$user' with that password"
      ;;
    nous)
      [ "$interactive" -eq 1 ] || die "the Nous sign-in needs a terminal; run ./setup.sh interactively"
      hermes_quiet config set webapp.public_url "https://$DOMAIN"
      note "log in to Nous Portal, then this server is registered as your dashboard"
      HERMES_TTY=1 HERMES_NET=host hermes portal </dev/tty || die "the Nous login did not finish"
      HERMES_TTY=1 HERMES_NET=host hermes dashboard register </dev/tty || die "registering with Nous Portal failed"
      ;;
    *)
      note "skipped: without a sign-in Hermes will not serve the Webapp on a public address"
      ;;
  esac
fi

# ── 6. Signal (optional) ─────────────────────────────────────────────────────
say "Signal"
signal_dir="$DATA_DIR/.local/share/signal-cli"
signal_image="$(sed -n 's/^ *image: *\(ghcr\.io\/asamk\/signal-cli[^ ]*\).*/\1/p' compose.yaml | head -n1)"
if [ -n "$(env_get SIGNAL_ACCOUNT)" ]; then
  note "already linked: $(env_get SIGNAL_ACCOUNT)"
elif [ "$interactive" -eq 0 ] && [ "${SETUP_SIGNAL:-no}" != no ]; then
  note "linking Signal needs a terminal (a QR code has to be scanned); run ./setup.sh interactively later"
elif yes_no SETUP_SIGNAL "Link a Signal account, so that you can talk to the agent there?" no; then
  note "On your phone: Signal > Settings > Linked devices > Link new device, then scan:"
  result="$(mktemp)"
  # signal-cli prints the link address, waits for the scan, then the number.
  docker run --rm -u "$RUN_UID:$RUN_GID" -e HOME=/tmp -v "$signal_dir:/var/lib/signal-cli" \
      "$signal_image" link -n "Hermes ($DOMAIN)" 2>&1 |
    while IFS= read -r line; do
      case "$line" in
        sgnl://*|tsdevice:*)
          printf '%s' "$line" | docker run --rm -i --network none --entrypoint /opt/hermes/.venv/bin/python \
            hermes-agent-local -c 'import sys, qrcode; q = qrcode.QRCode(border=2); q.add_data(sys.stdin.read().strip()); q.print_ascii(invert=True)'
          ;;
        *Associated\ with*) printf '%s' "$line" | grep -o '+[0-9]\{6,\}' | head -n1 > "$result" ;;
        *) printf '    %s\n' "$line" ;;
      esac
    done || true
  number="$(cat "$result")"; rm -f "$result"
  [ -n "$number" ] || die "Signal was not linked; run ./setup.sh again to retry"
  env_set COMPOSE_PROFILES signal
  env_set SIGNAL_ACCOUNT "$number"
  [ -n "$(env_get ALERT_SIGNAL_RECIPIENT)" ] || env_set ALERT_SIGNAL_RECIPIENT "$number"
  # Hermes' side: where the daemon is, and who may talk to the agent. As a
  # linked device of your own number you write to it in "Note to Self".
  hermes_env="$DATA_DIR/.hermes/.env"
  for pair in "SIGNAL_HTTP_URL=http://127.0.0.1:8080" "SIGNAL_ACCOUNT=$number" \
              "SIGNAL_ALLOWED_USERS=$number" "SIGNAL_HOME_CHANNEL=$number"; do
    grep -qs "^${pair%%=*}=" "$hermes_env" ||
      setpriv --reuid="$RUN_UID" --regid="$RUN_GID" --clear-groups sh -c "umask 077; printf '%s\n' '$pair' >> '$hermes_env'"
  done
  note "linked $number; write to the agent in Signal's Note to Self"
else
  note "skipped; run ./setup.sh again whenever you want to add it"
fi

# ── 7. Start ─────────────────────────────────────────────────────────────────
if [ -z "$(env_get AUTO_DEPLOY)" ] && yes_no SETUP_AUTO_DEPLOY "Deploy new commits from git automatically?" no; then
  env_set AUTO_DEPLOY true
fi

if [ "$start" -eq 0 ]; then
  say "Prepared. Start everything with ./install.sh"
  exit 0
fi

say "Installing the services and starting"
./install.sh
sleep 30
note "running the first backup"
systemctl start hermes-backup.service || note "the first backup failed; see journalctl -u hermes-backup"
./check.sh || note "some checks fail right after a first start; run ./check.sh again in a few minutes"

say "Done"
note "Webapp:  https://$DOMAIN"
note "Now keep two things somewhere other than this server:"
note "  1. the private key $KEY_FILE (without it the secrets and backups cannot be read)"
note "  2. the directory instance/, best as a private git repository (see instance/README.md)"
