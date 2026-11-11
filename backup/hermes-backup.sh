#!/usr/bin/env bash
# Daily backup of the Hermes state with restic. Run by hermes-backup.timer.
#
# By default the repository lives next to the data, in <data>/backups/restic-repo.
# There it protects against deleted or damaged files and a corrupted database,
# NOT against losing the disk itself. For that, copy the repository elsewhere:
# `restic copy` to a second repository.
#
# What is saved: the Hermes state (config, sessions, cron, skills, profiles),
# Signal registration, openknowledge, projects, tool configuration and this
# repository including instance/ (settings and encrypted secrets). Everything Hermes can
# download or rebuild is left out. Not saved: the age key; keep a copy of a
# key that can decrypt instance/secrets/ somewhere else.
#
# The repository password is RESTIC_PASSWORD in instance/secrets/backup.enc.yaml,
# decrypted with the server's age key each run.
#
# SQLite databases are copied through SQLite's backup API first, so the saved
# copy is consistent even while the agent is writing.
#
# Restore: see README, "Obnova souborů ze zálohy".

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# Read one KEY=value from .env without executing the file.
env_get() { [ -f "$REPO_DIR/.env" ] && sed -n "s/^$1=//p" "$REPO_DIR/.env" | tail -n1 || true; }
# The image to run: a published one named in instance/.env or in release.env
# (written by docker/extract.sh), else the one built here from the Dockerfile.
image_ref() {
  local ref
  ref="$(env_get HERMES_BOX_IMAGE)"
  [ -n "$ref" ] || ref="$(sed -n 's/^HERMES_BOX_IMAGE=//p' "$REPO_DIR/release.env" 2>/dev/null | tail -n1)"
  printf '%s' "${ref:-hermes-agent-local}"
}

SRC="$(env_get HERMES_DATA_DIR)"
SRC="${SRC:-/home/hermes}"
DEST="$SRC/backups"
REPO="$DEST/restic-repo"
PASSWORD_FILE="$DEST/restic-password"   # only used before the encrypted secrets existed
KEY_FILE="$(env_get SOPS_AGE_KEY_FILE)"
KEY_FILE="${KEY_FILE:-/etc/hermes/credentials/age.key}"
DUMP="$DEST/sqlite-dump"
CACHE="$DEST/restic-cache"
EXCLUDES="$DEST/excludes.txt"
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic:0.18.1}"
MIN_FREE_KB=$((3 * 1024 * 1024))

# Relative to $SRC.
INCLUDE=(.hermes .local/share/signal-cli .local/bin .config .ssh openknowledge projects)
# Rebuildable or downloadable; relative to $SRC.
SKIP=(.hermes/hermes-agent .hermes/cache .hermes/tools .hermes/installs
      .hermes/node .hermes/venvs .hermes/state-snapshots)

[ -f "$SRC/.hermes/config.yaml" ] || { echo "backup: no Hermes data in $SRC" >&2; exit 1; }
free_kb=$(df --output=avail -k "$SRC" | tail -n1)
[ "$free_kb" -ge "$MIN_FREE_KB" ] || { echo "backup: less than 3 GB free on $SRC" >&2; exit 1; }

umask 077
mkdir -p "$DEST" "$REPO" "$CACHE"

# Repository password: from the encrypted secrets, passed on in the
# environment only. A password file from an older setup still works.
if [ -f "$REPO_DIR/instance/secrets/backup.enc.yaml" ]; then
  RESTIC_PASSWORD="$(docker run --rm --network none \
    -e SOPS_AGE_KEY_FILE=/age.key -e SOPS_DISABLE_VERSION_CHECK=1 \
    -v "$KEY_FILE:/age.key:ro" -v "$REPO_DIR/instance/secrets:/secrets:ro" \
    --entrypoint sops "$(image_ref)" \
    decrypt --extract '["RESTIC_PASSWORD"]' /secrets/backup.enc.yaml)"
  [ -n "$RESTIC_PASSWORD" ] || { echo "backup: RESTIC_PASSWORD is empty" >&2; exit 1; }
  export RESTIC_PASSWORD
  password_args=(-e RESTIC_PASSWORD)
elif [ -s "$PASSWORD_FILE" ]; then
  password_args=(-v "$PASSWORD_FILE:/restic-password:ro" -e RESTIC_PASSWORD_FILE=/restic-password)
else
  echo "backup: instance/secrets/backup.enc.yaml with RESTIC_PASSWORD is missing" >&2
  exit 1
fi

# 1. Consistent copies of every SQLite database; the live files are excluded.
rm -rf "$DUMP"
mkdir -p "$DUMP"
python3 - "$SRC" "$DUMP" "$EXCLUDES" "${INCLUDE[*]}" "${SKIP[*]}" <<'PY'
import os, sqlite3, sys

src, dump, excludes_path, include, skip = sys.argv[1:6]
skip = {os.path.join(src, p) for p in skip.split()}
excludes = sorted(skip)
count = 0
for top in include.split():
    for root, dirs, files in os.walk(os.path.join(src, top)):
        dirs[:] = [d for d in dirs
                   if os.path.join(root, d) not in skip and not os.path.islink(os.path.join(root, d))]
        for name in files:
            path = os.path.join(root, name)
            try:
                if os.path.islink(path):
                    continue
                with open(path, "rb") as fh:
                    if fh.read(16) != b"SQLite format 3\x00":
                        continue
            except OSError:
                continue
            target = os.path.join(dump, os.path.relpath(path, src))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            source = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=60)
            copy = sqlite3.connect(target)
            with copy:
                source.backup(copy)
            copy.close()
            source.close()
            excludes += [path, path + "-wal", path + "-shm"]
            count += 1
# restic reads these as glob patterns; file names may contain [, * or ?.
escape = str.maketrans({c: "\\" + c for c in "\\[]*?"})
with open(excludes_path, "w") as fh:
    fh.write("\n".join(p.translate(escape) for p in excludes) + "\n")
print(f"backup: copied {count} SQLite databases")
PY

# 2. restic, from its official image; the host needs only Docker.
restic() {
  docker run --rm --hostname hermes-agent \
    -v "$SRC:$SRC:ro" \
    -v "$REPO_DIR:$REPO_DIR:ro" \
    -v "$REPO:/repo" \
    -v "$CACHE:/cache" \
    "${password_args[@]}" \
    -e RESTIC_REPOSITORY=/repo \
    -e RESTIC_CACHE_DIR=/cache \
    "$RESTIC_IMAGE" "$@"
}

restic cat config >/dev/null 2>&1 || restic init

paths=("$DUMP" "$REPO_DIR")
for p in "${INCLUDE[@]}"; do
  if [ -e "$SRC/$p" ]; then paths+=("$SRC/$p"); fi
done

restic backup --exclude-file "$EXCLUDES" --tag daily "${paths[@]}"
restic forget --tag daily --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune
restic check

# The copies are in the repository now; do not keep a second 600 MB around.
rm -rf "$DUMP"
# check.sh reads the age of this file.
touch "$DEST/last-success"
echo "backup: done"
