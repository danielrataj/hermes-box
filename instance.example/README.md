# Instance

Template of the `instance/` directory: everything that belongs to one specific
installation. The solution repository is the same for all installations and
knows nothing about this directory (it has it in `.gitignore`).

| File | Contents |
| --- | --- |
| `.env` | installation settings: domain, paths (template: `env.example`) |
| `.sops.yaml` | public keys of those who may decrypt the secrets; the first version is created by `install.sh` |
| `secrets/hermes.enc.yaml` | the agent's secrets, encrypted |
| `secrets/backup.enc.yaml` | the backup password, encrypted |
| `compose.yaml`, `check.d/*.sh`, `notify.sh` | optional: containers, checks and alert delivery of this installation only; see README, Your own additions |

## Recommendation: your own private repository

Turn `instance/` into a git repository and push it to private storage:

```bash
cd instance && git init -b master && git add -A && git commit -m "Instance settings"
```

- You then edit the secrets on your own computer
  (`./sops.sh secrets/hermes.enc.yaml`) and send them with `git push`.
- With `AUTO_DEPLOY=true` enabled, the server fetches and deploys changes in
  this repository the same way as changes to the solution.
- When restoring the server, it is enough to clone the solution, clone this
  repository into it as `instance/`, and run `./install.sh`.

The files in `secrets/` are encrypted, but `.env` contains the domain and
possibly other details of yours. So keep the repository private.
