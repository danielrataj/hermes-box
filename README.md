# Hermes Agent in Docker

Runs [Hermes Agent](https://github.com/NousResearch/hermes-agent) on a server
in Docker: the agent with cron, the Webapp (Hermes Desktop in the browser,
including Bots) on your own domain, and a daily backup.

The host needs only Docker and one private key; no third-party service for
secrets is required.

The solution is split into two parts:

- **this repository** – the same for every installation, contains nothing
  personal,
- **the `instance/` directory** – the settings and encrypted secrets of one
  installation, and anything else only that installation runs: containers of
  its own, checks, the way alerts are delivered (see
  [Your own additions](#your-own-additions)). It is not part of this
  repository; a template and description are in
  [`instance.example/`](instance.example/README.md).

## Installation

You need a server with Linux (x86_64) and Docker, a domain pointing at its
address, and ports 80 and 443 open. Everything is run as root.

Size: the image is about 5 GB and a fresh installation takes about 9 GB of
disk; an update needs room for a second image for a while, so plan for 40 GB
or more. The agent's container uses about 250 MB of memory when idle. 2 GB of
RAM is a sensible minimum; with 1 GB it runs only with swap.

If Docker is missing, on Debian and Ubuntu:

```bash
curl -fsSL https://get.docker.com | sh
```

To try it out without a domain of your own, use `<address>.sslip.io` as the
host name, for example `203.0.113.7.sslip.io`: it resolves to that address and
gets a certificate like any other name.

### New installation

The published image is enough; nothing is built or cloned. The first command
extracts `compose.yaml`, the scripts and the systemd units from it into
`/opt/hermes-box`, the second starts the wizard:

```bash
docker run --rm -v /opt/hermes-box:/out --entrypoint hermes-box-extract ghcr.io/danielrataj/hermes-box:1
```

```bash
cd /opt/hermes-box && ./setup.sh
```

The `:1` tag is the latest release of the 1 series. The installation remembers
the exact version it received (`release.env`) and does not change by itself;
see [Updating](#updating).

On Debian and Ubuntu the wizard installs a missing `curl`, `jq`, `openssl` and
`python3` by itself.

The wizard asks a few questions and performs the whole initial setup:

1. the Webapp domain → `instance/.env`,
2. user, data directories, the server's private key,
3. the first encrypted secrets, including a random backup password,
4. model and provider: runs Hermes's own wizard,
5. Webapp login: a user name and password, or a Nous Portal account,
6. installation of the services, start, first backup and check.

It can be run again, also on a server that is already running; finished
steps are skipped. This is how the model or the Webapp login is added later;
the stack is restarted when something was added. The questions can be
answered in advance with the `SETUP_*` variables (see the header of
`setup.sh`), in which case it runs without prompting; step 4 needs a terminal
and is skipped without one.

After the installation, store the private key
(`/etc/hermes/credentials/age.key`) and the `instance/` directory off the
server, ideally as a private git repository.

### Model and provider

Until a model is chosen the agent does not answer; `./check.sh` says so in a
`warn` line. An installation that skipped step 4 (an unattended one always
does) gets its model by running the wizard again in a terminal:

```bash
cd /opt/hermes-box && ./setup.sh
```

The same without the wizard around it, for example to change the model later:

```bash
docker exec -it -u 1000:1000 -e HOME=/opt/data hermes hermes setup model
```

```bash
systemctl restart hermes-docker
```

Use `hermes setup model`, not `hermes setup`: the full Hermes setup asks about
much more than the model.

### Existing installation, restore, another server

Extract the files from the image as for a new installation, clone your
instance repository into `/opt/hermes-box/instance/` and run:

```bash
./install.sh
```

The script checks the prerequisites, creates the user and directories, pulls or
builds the image, verifies the key and secrets, configures the Webapp in
`config.yaml`, installs the systemd units and starts the stack. It can be run
repeatedly; it does not change existing data. It leaves a running stack alone
unless it is given `--restart`. On a new server it creates a key and prints its
public part; that has to be added to the recipients of the secrets (see
Secrets).

### Settings in `instance/.env`

| Variable | Default | Meaning |
| --- | --- | --- |
| `HERMES_DOMAIN` | – | public address of the Webapp; DNS must point at the server |
| `SOPS_AGE_KEY_FILE` | `/etc/hermes/credentials/age.key` | the server's private key |
| `BACKUP_EXTRA_PATHS` | empty | further paths in the data directory to back up, separated by spaces |
| `AUTO_DEPLOY` | off | `true`: the server deploys new commits by itself |
| `HERMES_DATA_DIR` | `/home/hermes` | where all state lives |
| `HERMES_UID`, `HERMES_GID` | `1000` | owner of the data |
| `HERMES_BOX_IMAGE` | from `release.env` | an image other than the one the installation came with |
| `HERMES_IMAGE_TAG` | the version in the `Dockerfile` | only when building yourself: another Hermes version, e.g. `v0.23.1-desktop` for Bot Desktop |

The `.env` file in the root is only a link to `instance/.env`, created by
`install.sh`.

### Deploying a change

This applies to an installation from git (see
[Installing from git](#installing-from-git)); an installation from the image is
changed as described in [Updating](#updating).

**Automatically** (`AUTO_DEPLOY=true` in `instance/.env`): a `git push` is
enough, whether to this repository or to the instance repository. Every
5 minutes the server checks the remote branch and deploys a new commit by
itself (`deploy/hermes-deploy.sh`):

1. it fetches the commit (fast-forward only), validates the configuration, and
   if needed builds the image and updates the units,
2. it restarts the stack only when something that runs in the containers has
   changed (`compose.yaml`, `Dockerfile`, `docker/`, `caddy/`, `instance/.env`,
   `instance/compose.yaml`, `instance/secrets/`); it waits until no cron job
   is about to start,
3. it runs `check.sh`; if that fails, it rolls back to the previous commit and
   image,
4. it writes the result to the journal (`journalctl -u hermes-deploy`) and
   hands it to `instance/notify.sh`, if there is one.

A commit whose deployment failed is not retried; fix it with a new commit.
To retry the same one: `rm /var/lib/hermes-deploy/failed-commit`.

To run it immediately without waiting for the timer:
`systemctl start hermes-deploy`.

To pause the automation, for example during manual work on the server:

```bash
touch deploy/PAUSE
```

Whoever can push to the deployed branch runs code on the server as root.
Protect the branch on GitHub and keep two-factor authentication on the account.

**Manually:**

```bash
git pull --ff-only && ./install.sh --restart
```

A restart means about a minute of downtime, including the web.
Without `--restart` only the image is built and the units are updated.

## What runs

Two containers, both with the `host` network mode:

| Container | Image | What it does | Where it listens |
| --- | --- | --- | --- |
| `hermes` | `ghcr.io/danielrataj/hermes-box:<version>`, or `hermes-agent-local` built from the `Dockerfile` | gateway: agent, cron, sessions, Bots; plus the Webapp and dashboard | Webapp `127.0.0.1:9120`, dashboard `127.0.0.1:9119` |
| `hermes-caddy` | `caddy:2.11` | TLS and reverse proxy | `80`, `443` |

- The **Webapp** runs at `https://<HERMES_DOMAIN>` behind a Nous login.
- The **Dashboard** (administration) is not exposed. Access it through an SSH
  tunnel:

  ```bash
  ssh -L 9119:127.0.0.1:9119 <server>
  ```

  and then <http://127.0.0.1:9119>.

The containers are started by the systemd unit `hermes-docker.service` with
`docker compose up`. The `hermes` container has `restart: on-failure:5`, so
Docker brings it back up after a crash.

## Your own additions

What only your installation needs does not belong in this repository. Put it
in `instance/`; these four places are picked up when they exist:

| In `instance/` | What it does |
| --- | --- |
| `compose.yaml` | more containers, or changes to the ones here. `install.sh` links it as `compose.override.yaml`, which Compose merges into `compose.yaml`. Paths are relative to the repository directory; variables come from `instance/.env`. Apply with `./install.sh --restart`. |
| `check.d/*.sh` | one more line in `./check.sh` per script, named after the file: it passes when the script exits 0, and the last line the script printed is shown when it fails. The scripts get `REPO_DIR` and `DATA_DIR`. |
| `notify.sh` | delivery of alerts. Must be executable; gets the message as its only argument. Called by the monitor and by the automatic deployment. |
| `BACKUP_EXTRA_PATHS` in `.env` | paths inside the data directory to add to the backup, for example the state of your own container. |

A messenger daemon the gateway talks to is a typical case: its container goes
into `instance/compose.yaml`, a check that it answers into `instance/check.d/`,
its data into `BACKUP_EXTRA_PATHS`, and `instance/notify.sh` can send the
alerts through it. Create the directory for its data yourself, owned by
`HERMES_UID`; Docker would create a missing one as root.

Everything in `instance/` runs as root on the server, like this repository.

## Files

| File | Purpose |
| --- | --- |
| `setup.sh` | first-installation wizard |
| `install.sh` | installation and deployment of changes |
| `compose.yaml` | definition of the containers |
| `Dockerfile` | the official Hermes image + `sops`, `age`, `uv` and `himalaya`; also carries the files in this table |
| `docker/extract.sh` | extracts the files from the image onto the server (`hermes-box-extract`) |
| `release.env` | only for an installation from the image: which image is running |
| `.github/workflows/image.yml` | image build and check, release on a `v*` tag |
| `docker/secrets-entrypoint.sh` | on start, decrypts the secrets into the environment and into in-memory files |
| `sops.sh` | editing secrets without installing `sops` |
| `instance.example/` | template of the `instance/` directory |
| `sops.sh` | `sops` from Docker, for editing secrets without an installation |
| `caddy/Caddyfile` | domain → Webapp |
| `backup/hermes-backup.sh` | daily backup |
| `check.sh` | health check of the whole solution |
| `monitor/hermes-monitor.sh` | periodic check and alerts |
| `deploy/hermes-deploy.sh` | automatic deployment of new commits |
| `server/` | systemd unit templates; installed by `install.sh` |

## Data

All state is in `HERMES_DATA_DIR`. The image is stateless.

| Path in the data directory | Contents | In the `hermes` container |
| --- | --- | --- |
| `.hermes` | config, sessions, cron, skills, profiles, `state.db` | `/opt/data` and `/home/hermes/.hermes` |
| `openknowledge` | Obsidian repository | `/home/hermes/openknowledge` |
| `projects` | projects | `/home/hermes/projects` |
| `.config/himalaya` | mail settings (the passwords are in the secrets) | `/opt/data/.config/himalaya` |
| `.local/bin` | the agent's helper scripts, e.g. an SSH wrapper for git | `/home/hermes/.local/bin` |
| `backups` | backups | not mounted |

Outside the data directory:

- the repository including `instance/`
- the server's private key
- the Docker volumes `hermes_caddy-data` and `hermes_caddy-config` –
  certificates; if lost, they are issued again

Three things that are not obvious at first sight:

- Cron jobs and skills refer to the absolute paths `/home/hermes/...`. Inside
  the container these paths therefore stay the same wherever `HERMES_DATA_DIR`
  is. The `write_file` and `patch` tools may write only into the directories in
  `HERMES_WRITE_SAFE_ROOT`. The image allows only `/opt/data`, which is why
  `compose.yaml` also adds mounts under `/home/hermes/...`. A new writable
  mount has to be added there as well.
- The home directory of the tools in the container is `/opt/data`
  (`terminal.home_mode: real` in `config.yaml`; set by `install.sh`).
  The value in `config.yaml` takes precedence over the `TERMINAL_HOME_MODE`
  variable from `compose.yaml`. With the default `auto`, scripts in the
  container would get `HOME=/opt/data/home` and would not find
  `~/.config/himalaya`. The path `~/.hermes/...` works thanks to the symlink
  `.hermes/.hermes -> .`, created by `install.sh`. It also follows that
  `~/.ssh` = `.hermes/.ssh`; `install.sh` carries `known_hosts` over there from
  the original installation.
- Both Docker and `hermes-docker.service` wait for the data disk to be mounted.
  When the disk is missing, Docker does not start at all. This is intentional:
  otherwise the containers would come up over empty directories.

## Secrets

They are in `instance/secrets/*.enc.yaml`, encrypted with
[SOPS](https://getsops.io) for [age](https://age-encryption.org) keys. The
names are readable, the values are not, so the files belong in git (in the
instance repository). The commands below are run in the `instance/` directory;
`./sops.sh` from the root of this repository works there by itself.

- `secrets/hermes.enc.yaml` – everything the agent receives (mail passwords,
  deploy keys, tokens). The `hermes` container decrypts the file into memory on
  start; the values are neither on disk nor in `docker inspect`.
  - A single-line value is the environment variable `NAME`.
  - A multi-line value (SSH key, JSON) is the file
    `/run/hermes-secrets/NAME`, readable only by the agent's user; the
    environment holds only the path to it in `NAME_FILE`. Otherwise a
    line-by-line listing of the environment (`printenv | cut -d= -f1`) would
    print the second and following lines of such a value in full, and the agent
    has already sent keys to the model provider this way.
- `secrets/backup.enc.yaml` – `RESTIC_PASSWORD`. Only the backup script reads
  it; the agent never receives it.

Anyone whose public key is in `instance/.sops.yaml` can decrypt them: the
server (private key in `/etc/hermes/credentials/age.key`) and whoever manages
the secrets. Without the key or the file the container exits with code 78 and
does not restart.

**Keep a copy of at least one private key off the server**, for example in a
password manager. Losing all the keys means losing the secrets and access to
the backups.

### Once, on your own computer

```bash
brew install sops age
```

On macOS `sops` looks for the key in
`~/Library/Application Support/sops/age/keys.txt` (on Linux in
`~/.config/sops/age/keys.txt`):

```bash
mkdir -p ~/Library/Application\ Support/sops/age && age-keygen -o ~/Library/Application\ Support/sops/age/keys.txt
```

A different location can be passed in the `SOPS_AGE_KEY_FILE` variable.

Add the printed public key (`age1…`) to `.sops.yaml`. Only someone who can
already decrypt the existing files can add it to their recipients (so the first
time, the server).

### Changing or adding a value

```bash
sops secrets/hermes.enc.yaml
```

This opens an editor with the decrypted contents and re-encrypts the file on
save. Then commit, push, and on the server
`git pull --ff-only && ./install.sh --restart`.

### Without installing: `sops` from Docker

`./sops.sh` runs `sops` from its official image, so Docker and the private key
are enough. The arguments are the same as for `sops`; paths are written
relative to the repository root:

```bash
./sops.sh secrets/hermes.enc.yaml
```

The editor is `vi`. The container runs without network access and the decrypted
contents exist only inside it. The key is taken from `SOPS_AGE_KEY_FILE`,
otherwise from the locations listed above. The script does not create a new
key; that requires `age-keygen`.

### New recipient (another server, another person)

Add the public key to `.sops.yaml` and re-encrypt:

```bash
sops updatekeys secrets/hermes.enc.yaml
```

```bash
sops updatekeys secrets/backup.enc.yaml
```

Removing a recipient works the same way; in addition, the values they have
already seen need to be changed at their source.

## Common tasks

Check everything at once (services, containers, web, certificate, backup,
disk space, your own checks); it exits with an error when something is wrong:

```bash
./check.sh
```

Status:

```bash
systemctl status hermes-docker
```

```bash
docker ps
```

Agent logs (Docker keeps at most 5 × 20 MB per container; Hermes's own logs
are in `.hermes/logs`):

```bash
docker logs -f --tail 100 hermes
```

Restart the whole stack:

```bash
systemctl restart hermes-docker
```

The `hermes` command inside the container, as the agent's user:

```bash
docker exec -it -u 1000:1000 -e HOME=/opt/data hermes hermes --help
```

Without a subcommand, and without a model, `hermes` offers to run its full
setup; decline and see [Model and provider](#model-and-provider).

## Monitoring

`hermes-monitor.timer` runs `check.sh` every 10 minutes, and immediately after
a failed backup. When the result changes, it writes that to the journal
(`journalctl -u hermes-monitor`): one message when something breaks, and one
when everything is fine again.

To be told somewhere else, add `instance/notify.sh` (see
[Your own additions](#your-own-additions)). Whatever that script uses, it runs
on this server: when the whole server is down, nothing arrives; only an
external check of the public address covers that (UptimeRobot and the like).

## Updating

A new version is a new image. Extract the files from it over the existing ones
and deploy:

```bash
docker run --rm -v /opt/hermes-box:/out --entrypoint hermes-box-extract ghcr.io/danielrataj/hermes-box:1
```

```bash
cd /opt/hermes-box && ./install.sh --restart
```

Neither `instance/` nor the data changes. It is a good idea to run a backup
before updating (`systemctl start hermes-backup`).

Going back to a previous version is the same with its exact tag, e.g. `:1.0.0`.
Which version is running: `cat /opt/hermes-box/release.env`.

## Installing from git

For development, and for a server that should follow a branch: clone the
repository instead of extracting it from the image. Without `release.env`,
`install.sh` builds the image itself from the `Dockerfile` (named
`hermes-agent-local`) and `AUTO_DEPLOY` can be enabled.

```bash
git clone https://github.com/danielrataj/hermes-box.git /opt/hermes-box
```

```bash
cd /opt/hermes-box && ./setup.sh
```

## Releasing a new version

The Hermes version is pinned in the `Dockerfile` (`HERMES_IMAGE_TAG`).
Upgrading Hermes is a change of that tag; CI builds and tests the image in
every pull request, so a version the `Dockerfile` does not fit will not pass.

A release is a tag of the form `v1.2.3`:

```bash
git tag v1.2.3 && git push origin v1.2.3
```

CI publishes `ghcr.io/danielrataj/hermes-box:1.2.3` and moves `:1.2` and `:1`.
A tag with a suffix (`v1.2.3-rc.1`) publishes only itself.


## Backup

`hermes-backup.timer` runs `backup/hermes-backup.sh` daily at 03:30:

1. it copies all SQLite databases through the backup API (consistent even while
   running),
2. it stores them, together with the Hermes state, `BACKUP_EXTRA_PATHS`,
   `openknowledge`, `projects`, the tool configuration and this repository
   including `instance/` and the encrypted secrets, in the restic repository
   `<data>/backups/restic-repo`,
3. it keeps 7 daily, 4 weekly and 3 monthly snapshots and verifies the
   repository.

It leaves out everything Hermes can download or build again.

Manual run and result:

```bash
systemctl start hermes-backup && journalctl -u hermes-backup -n 30 --no-pager
```

**Limitation:** the repository is on the same disk as the data. It protects
against deletion, file corruption and a broken database, not against losing the
disk. An off-server copy can be added with `restic copy`.

The repository password is `RESTIC_PASSWORD` in
`instance/secrets/backup.enc.yaml`. The server's private key is not in the
backup.

### Restoring files from a backup

As root in the repository directory (paths for the default `HERMES_DATA_DIR`):

```bash
mkdir -p /restore
```

```bash
export RESTIC_PASSWORD="$(docker run --rm --network none -e SOPS_AGE_KEY_FILE=/age.key -v /etc/hermes/credentials/age.key:/age.key:ro -v "$PWD/instance/secrets:/secrets:ro" --entrypoint sops "$(docker inspect -f '{{.Config.Image}}' hermes)" decrypt --extract '["RESTIC_PASSWORD"]' /secrets/backup.enc.yaml)"
```

```bash
docker run --rm -e RESTIC_PASSWORD -e RESTIC_REPOSITORY=/repo -v /home/hermes/backups/restic-repo:/repo -v /restore:/restore restic/restic:0.18.1 restore latest --target /restore
```

Files are restored to `/restore/<original path>`, databases to
`/restore/home/hermes/backups/sqlite-dump/<path in the data>`. For a snapshot
other than the latest: instead of `latest`, use its ID from the `snapshots`
command. Stop `hermes-docker` before copying anything back.

## Restoring the server

When the server is gone and the data disk survives:

1. New server, install Docker.
2. Mount the data disk at `HERMES_DATA_DIR` and add it to `/etc/fstab`.
   With a Hetzner Volume **do not run `mkfs`** from their instructions; it
   would erase the data.
3. Follow the Installation chapter; clone `instance/` from your repository or
   take it from a backup. Either restore the private key from a copy to
   `/etc/hermes/credentials/age.key`, or let `install.sh` create a new one and
   add it to the recipients.
4. Point DNS at the new address. Caddy issues the certificate by itself.

When the data disk is gone too, the data is lost; see the backup limitation
above.

## Licence

[MIT](LICENSE). Hermes Agent itself, Caddy and the other tools used have their
own licences.
