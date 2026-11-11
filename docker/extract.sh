#!/bin/sh
# Copy the files a server needs around the containers out of the image:
# compose.yaml, the scripts and the systemd unit templates. Used to install
# from a published image and to update such an installation:
#
#   docker run --rm -v /opt/hermes-box:/out --entrypoint hermes-box-extract IMAGE
#
# Files of the same name are replaced. instance/ (settings and encrypted
# secrets) and the data directory are not part of the image and are left alone.
set -eu

SRC=/opt/hermes-box
OUT="${1:-/out}"

grep -q " $OUT " /proc/mounts ||
  { echo "extract: mount the installation directory at $OUT: -v /opt/hermes-box:$OUT" >&2; exit 2; }

cp -R "$SRC/." "$OUT/"

if [ -f "$SRC/release.env" ]; then
  echo "extract: $(sed -n 's/^HERMES_BOX_IMAGE=//p' "$SRC/release.env")"
else
  # A locally built image: there is nothing to pull, the host builds it.
  rm -f "$OUT/release.env"
  echo "extract: a local build without a published name; install.sh will build the image"
fi
if [ -f "$OUT/instance/.env" ]; then
  echo "extract: files updated; apply them with ./install.sh --restart"
else
  echo "extract: files are in place; continue with ./setup.sh"
fi
