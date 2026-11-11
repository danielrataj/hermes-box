#!/usr/bin/env bash
# One-command installation on an empty server: installs Docker when it is
# missing, takes the files out of the published image and starts the wizard
# (./setup.sh). Nothing has to be on the server beforehand except curl:
#
#   curl -fsSL https://raw.githubusercontent.com/danielrataj/hermes-box/master/get.sh | sudo bash
#
# Options go after `bash -s --`:
#
#   ... | sudo bash -s -- --update     new files from the image, then ./install.sh --restart
#   ... | sudo bash -s -- --no-start   passed on to ./setup.sh
#
# Run on a server that already has an installation, it only starts the wizard
# again (finished steps are skipped); the files change only with --update.
#
# Settings, through the environment (`sudo VAR=value bash`):
#
#   INSTALL_IMAGE=ghcr.io/danielrataj/hermes-box:1   which release, e.g. :1.0.0
#   INSTALL_DIR=/opt/hermes-box                      where the files go
#   SETUP_*                                          answers for ./setup.sh, see its header
#
# Docker is installed with Docker's own script (https://get.docker.com), which
# covers Debian, Ubuntu, Fedora, CentOS, RHEL and their relatives.

set -euo pipefail

# Everything is in a function that is called on the last line: a download cut
# off halfway then runs nothing instead of half of the script.
main() {
  local image="${INSTALL_IMAGE:-ghcr.io/danielrataj/hermes-box:1}"
  local dir="${INSTALL_DIR:-/opt/hermes-box}"
  local update=0 arg
  local -a setup_args=()

  for arg in "$@"; do
    case "$arg" in
      --update) update=1 ;;
      --no-start) setup_args+=("$arg") ;;
      -h|--help) usage; exit 0 ;;
      *) echo "get: unknown option: $arg" >&2; exit 2 ;;
    esac
  done

  [ "$(uname -s)" = Linux ] || die "this installs on a Linux server, not on $(uname -s)"
  [ "$(uname -m)" = x86_64 ] || die "the image is built for x86_64 only, this machine is $(uname -m)"
  [ "$(id -u)" -eq 0 ] || die "run as root: curl ... | sudo bash"
  command -v systemctl >/dev/null || die "systemd is required (the stack runs as systemd units)"
  case "$dir" in /*) ;; *) die "INSTALL_DIR has to be an absolute path" ;; esac

  # ── Docker ────────────────────────────────────────────────────────────────
  if ! command -v docker >/dev/null; then
    say "Installing Docker"
    local script
    script="$(mktemp)"
    fetch https://get.docker.com "$script"
    sh "$script"
    rm -f "$script"
  fi
  if ! docker compose version >/dev/null 2>&1; then
    say "Installing the Docker compose plugin"
    install_compose || die "the Docker compose plugin is missing; install it (https://docs.docker.com/compose/install/linux/) and run this again"
  fi
  systemctl enable --now --quiet docker 2>/dev/null || true
  docker info >/dev/null 2>&1 || die "Docker is installed but not running (systemctl status docker)"
  note "$(docker --version)"

  # ── Files from the image ──────────────────────────────────────────────────
  local existing=0
  [ -f "$dir/instance/.env" ] && existing=1

  if [ "$existing" -eq 1 ] && [ "$update" -eq 0 ]; then
    say "An installation is already in $dir"
    note "its files are left as they are; to update them, run this with --update"
  else
    say "Getting $image"
    mkdir -p "$dir"
    docker pull --quiet "$image" >/dev/null
    docker run --rm --network none -v "$dir:/out" --entrypoint hermes-box-extract "$image" >/dev/null
    note "files are in $dir ($(sed -n 's/^HERMES_BOX_IMAGE=//p' "$dir/release.env" 2>/dev/null | tail -n1))"
  fi

  cd "$dir"
  if [ "$existing" -eq 1 ] && [ "$update" -eq 1 ]; then
    say "Updating the installation"
    exec ./install.sh --restart
  fi

  # ── Wizard ────────────────────────────────────────────────────────────────
  # Piped from curl, stdin is the script itself. The wizard asks its questions
  # on the terminal, so give it the terminal back when there is one.
  if [ ! -t 0 ] && (: </dev/tty) 2>/dev/null; then
    exec ./setup.sh ${setup_args[@]+"${setup_args[@]}"} </dev/tty
  fi
  if [ ! -t 0 ] && [ -z "${SETUP_DOMAIN:-}" ] && [ "$existing" -eq 0 ]; then
    die "no terminal to ask on: set SETUP_DOMAIN (and the other SETUP_* answers), or run: cd $dir && ./setup.sh"
  fi
  exec ./setup.sh ${setup_args[@]+"${setup_args[@]}"}
}

say()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf 'get: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Installs Hermes Agent in Docker on this server.

  curl -fsSL https://raw.githubusercontent.com/danielrataj/hermes-box/master/get.sh | sudo bash

  --update     new files from the image, then ./install.sh --restart
  --no-start   set everything up, do not start the stack

Environment: INSTALL_IMAGE (default ghcr.io/danielrataj/hermes-box:1),
INSTALL_DIR (default /opt/hermes-box), SETUP_* (answers for the wizard).
EOF
}

# fetch <url> <file>: with curl or wget, whichever the server has.
fetch() {
  if command -v curl >/dev/null; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null; then
    wget -qO "$2" "$1"
  else
    die "neither curl nor wget is installed"
  fi
}

# Docker that came from the distribution's own packages has no compose plugin.
# The package is docker-compose-plugin in Docker's repository and
# docker-compose-v2 in Ubuntu's.
install_compose() {
  local package
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
    for package in docker-compose-plugin docker-compose-v2; do
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$package" >/dev/null 2>&1 || continue
      docker compose version >/dev/null 2>&1 && return 0
    done
  elif command -v dnf >/dev/null; then
    dnf install -y -q docker-compose-plugin >/dev/null 2>&1 || true
  elif command -v yum >/dev/null; then
    yum install -y -q docker-compose-plugin >/dev/null 2>&1 || true
  fi
  docker compose version >/dev/null 2>&1
}

main "$@"
