#!/bin/sh
# Container entrypoint: decrypt the secrets file, then hand over to the
# image's own entrypoint.
#
# The secrets live in git, encrypted with SOPS for an age key. A secret with a
# one-line value becomes the environment variable NAME. A secret whose value
# spans several lines (an SSH key, a JSON document) is written to
# $SECRETS_DIR/NAME instead, readable only by the agent's user, and the
# environment gets NAME_FILE with that path. The reason: anything that lists
# the environment line by line (`printenv | cut -d= -f1`) prints the second
# and later lines of such a value in full, and the agent has sent keys to its
# model provider that way.
#
# $SECRETS_DIR is a tmpfs (compose.yaml), so nothing is written to disk. The
# image's s6 supervisor must be PID 1, so this script `exec`s it.
# Fails closed: without secrets the container exits instead of starting bare.
set -eu

KEY_FILE=/run/secrets/age_key
SECRETS_FILE="${HERMES_SECRETS_FILE:-/etc/hermes/secrets.enc.yaml}"
SECRETS_DIR=/run/hermes-secrets

[ -r "$KEY_FILE" ]     || { echo "[secrets] $KEY_FILE is missing" >&2; exit 78; }
[ -r "$SECRETS_FILE" ] || { echo "[secrets] $SECRETS_FILE is missing" >&2; exit 78; }
# Plain values must not reach the container's writable layer on disk.
grep -q " $SECRETS_DIR tmpfs " /proc/mounts ||
  { echo "[secrets] $SECRETS_DIR is not a tmpfs; see compose.yaml" >&2; exit 78; }

# One `export NAME='value'` line per secret, safely quoted, so values may
# contain shell metacharacters. Multi-line values go to files, see above.
exports="$(
  SOPS_AGE_KEY_FILE="$KEY_FILE" SOPS_DISABLE_VERSION_CHECK=1 \
    sops decrypt --output-type json "$SECRETS_FILE" |
  SECRETS_DIR="$SECRETS_DIR" /opt/hermes/.venv/bin/python3 -c '
import json, os, re, shlex, sys
directory = os.environ["SECRETS_DIR"]
uid, gid = int(os.environ.get("HERMES_UID", 1000)), int(os.environ.get("HERMES_GID", 1000))
for name, value in json.load(sys.stdin).items():
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        sys.exit(f"[secrets] not a valid variable name: {name!r}")
    value = str(value)
    if "\n" not in value.strip("\n"):
        print(f"export {name}={shlex.quote(value)}")
        continue
    path = os.path.join(directory, name)
    if os.path.lexists(path):  # a restart of the same container
        os.unlink(path)
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400), "w") as handle:
        handle.write(value if value.endswith("\n") else value + "\n")
    os.chown(path, uid, gid)
    print(f"export {name}_FILE={shlex.quote(path)}")
'
)" || { echo "[secrets] could not decrypt $SECRETS_FILE" >&2; exit 78; }
[ -n "$exports" ] || { echo "[secrets] $SECRETS_FILE holds no secrets" >&2; exit 78; }

eval "$exports"
unset exports

exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
