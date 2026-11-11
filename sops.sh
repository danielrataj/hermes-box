#!/usr/bin/env bash
# Run sops from its official image, so that editing the secrets needs only
# Docker and your private age key; nothing is installed on this machine.
#
#   ./sops.sh secrets/hermes.enc.yaml              edit (opens vi)
#   ./sops.sh decrypt secrets/hermes.enc.yaml      print the plain values
#   ./sops.sh updatekeys secrets/hermes.enc.yaml   after changing .sops.yaml
#
# Paths are relative to instance/, where .sops.yaml and secrets/ live. The key is read from SOPS_AGE_KEY_FILE
# or from the place sops itself would look in. The container has no network;
# the plain text exists only inside it and is gone when it exits.
set -euo pipefail

# The digest is the one ghcr.io publishes for this tag (amd64 and arm64).
IMAGE="ghcr.io/getsops/sops:v3.13.3-alpine@sha256:ae501277bf742f1662e0f881f43dd8fd6798b489a8058e921dbf6cda597140ea"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KEY_FILE="${SOPS_AGE_KEY_FILE:-}"
if [ -z "$KEY_FILE" ]; then
  for candidate in "$HOME/Library/Application Support/sops/age/keys.txt" \
                   "${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt"; do
    if [ -f "$candidate" ]; then KEY_FILE="$candidate"; break; fi
  done
fi
if [ ! -r "$KEY_FILE" ]; then
  echo "no age key found; set SOPS_AGE_KEY_FILE (see README, Secrets)" >&2
  exit 1
fi

tty=()
if [ -t 0 ] && [ -t 1 ]; then tty=(-t); fi

# Run as the calling user so that files written on a Linux host stay theirs.
exec docker run --rm -i ${tty[@]+"${tty[@]}"} --network none \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -e SOPS_AGE_KEY_FILE=/age.key -e SOPS_DISABLE_VERSION_CHECK=1 -e EDITOR=vi \
  -v "$KEY_FILE:/age.key:ro" -v "$REPO_DIR/instance:/work" -w /work \
  --entrypoint sops "$IMAGE" "$@"
