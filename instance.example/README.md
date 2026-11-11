# Instance

Vzor adresáře `instance/`: vše, co patří jedné konkrétní instalaci. Repozitář
s řešením je pro všechny instalace stejný a o tomto adresáři nic neví
(má ho v `.gitignore`).

| Soubor | Obsah |
| --- | --- |
| `.env` | nastavení instalace: doména, číslo Signal účtu, cesty (vzor: `env.example`) |
| `.sops.yaml` | veřejné klíče těch, kdo smí rozšifrovat tajné údaje; první verzi vytvoří `install.sh` |
| `secrets/hermes.enc.yaml` | tajné údaje agenta, zašifrované |
| `secrets/backup.enc.yaml` | heslo k zálohám, zašifrované |

## Doporučení: vlastní soukromý repozitář

Udělej z `instance/` git repozitář a pushuj ho do soukromého úložiště:

```bash
cd instance && git init -b master && git add -A && git commit -m "Instance settings"
```

- Tajné údaje pak upravíš na svém počítači (`./sops.sh secrets/hermes.enc.yaml`)
  a pošleš přes `git push`.
- Se zapnutým `AUTO_DEPLOY=true` si server změny v tomto repozitáři stahuje
  a nasazuje stejně jako změny řešení.
- Při obnově serveru stačí naklonovat řešení, do něj tento repozitář jako
  `instance/` a spustit `./install.sh`.

Soubory v `secrets/` jsou zašifrované, ale `.env` obsahuje doménu a telefonní
číslo. Repozitář proto nech soukromý.
