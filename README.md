# Hermes Agent v Dockeru

Provoz [Hermes Agenta](https://github.com/NousResearch/hermes-agent) na serveru
v Dockeru: agent se Signalem a cronem, Webapp (Hermes Desktop v prohlížeči,
včetně Bots) na vlastní doméně a denní záloha.

Host potřebuje jen Docker a jeden soukromý klíč; žádná cizí služba pro tajné
údaje není potřeba.

Řešení je rozdělené na dvě části:

- **tento repozitář** – stejný pro každou instalaci, neobsahuje nic osobního,
- **adresář `instance/`** – nastavení a zašifrované tajné údaje jedné
  instalace. Není součástí tohoto repozitáře; vzor a popis je
  v [`instance.example/`](instance.example/README.md).

## Instalace

Potřebuješ server s Linuxem a Dockerem, doménu mířící na jeho adresu
a otevřené porty 80 a 443. Vše se pouští jako root v adresáři repozitáře,
obvykle `/opt/hermes-docker`.

### Nová instalace

```bash
./setup.sh
```

Průvodce se zeptá na pár věcí a provede celé první nastavení:

1. doména Webapp → `instance/.env`,
2. sestavení image, uživatel, datové adresáře, soukromý klíč serveru,
3. první zašifrované tajné údaje včetně náhodného hesla k zálohám,
4. model a poskytovatel: spustí vlastního průvodce Hermes,
5. přihlášení do Webapp: jméno a heslo, nebo účet Nous Portal,
6. volitelně Signal: zobrazí QR kód, který naskenuješ v telefonu
   (Nastavení → Propojená zařízení); agentovi pak píšeš do Poznámek sobě,
7. instalace služeb, start, první záloha a kontrola.

Lze ho pustit znovu; hotové kroky přeskočí. Takto se dá Signal nebo model
doplnit později. Na odpovědi se dá odpovědět předem proměnnými `SETUP_*`
(viz hlavička `setup.sh`), pak běží bez dotazů; kroky 4 a 6 potřebují terminál.

Po instalaci ulož mimo server soukromý klíč
(`/etc/hermes/credentials/age.key`) a adresář `instance/`, nejlépe jako
soukromý git repozitář.

### Existující instalace, obnova, další server

Naklonovat svůj repozitář instance do `instance/` a spustit:

```bash
./install.sh
```

Skript zkontroluje předpoklady, založí uživatele a adresáře, sestaví image,
ověří klíč a tajné údaje, nastaví Webapp v `config.yaml`, nainstaluje systemd
units a stack spustí. Lze ho pouštět opakovaně; existující data nemění. Běžící
stack nechá být, dokud nedostane `--restart`. Na novém serveru vytvoří klíč
a vypíše jeho veřejnou část; tu je potřeba přidat mezi příjemce tajných údajů
(viz Tajné údaje).

### Nastavení v `instance/.env`

| Proměnná | Výchozí | Význam |
| --- | --- | --- |
| `HERMES_DOMAIN` | – | veřejná adresa Webapp; DNS musí mířit na server |
| `SOPS_AGE_KEY_FILE` | `/etc/hermes/credentials/age.key` | soukromý klíč serveru |
| `COMPOSE_PROFILES` | prázdné | `signal` zapne kontejner se Signalem |
| `SIGNAL_ACCOUNT` | prázdné | číslo Signal účtu, mezinárodní formát |
| `ALERT_SIGNAL_RECIPIENT` | prázdné | číslo, kam přijde upozornění na problém |
| `AUTO_DEPLOY` | vypnuto | `true`: server sám nasazuje nové commity |
| `HERMES_DATA_DIR` | `/home/hermes` | kde leží veškerý stav |
| `HERMES_UID`, `HERMES_GID` | `1000` | vlastník dat |
| `HERMES_IMAGE_TAG` | `stable` | `stable-desktop` pro Bot Desktop |

Soubor `.env` v kořeni je jen odkaz na `instance/.env`, který vytváří `install.sh`.

### Nasazení změny

**Automaticky** (`AUTO_DEPLOY=true` v `instance/.env`): stačí `git push`, ať už
do tohoto repozitáře, nebo do repozitáře instance. Server každých
5 minut zkontroluje vzdálenou větev a nový commit nasadí sám
(`deploy/hermes-deploy.sh`):

1. stáhne commit (jen fast-forward), ověří konfiguraci, případně sestaví image
   a aktualizuje units,
2. restartuje stack jen tehdy, když se změnilo něco, co běží v kontejnerech
   (`compose.yaml`, `Dockerfile`, `docker/`, `caddy/`, `instance/.env`,
   `instance/secrets/`); počká, až nezačíná žádný cron job,
3. spustí `check.sh`; když neprojde, vrátí předchozí commit i image,
4. výsledek zapíše do journalu (`journalctl -u hermes-deploy`) a pošle přes
   Signal.

Commit, jehož nasazení selhalo, se znovu nezkouší; oprav ho novým commitem.
Zkusit stejný znovu: `rm /var/lib/hermes-deploy/failed-commit`.

Okamžité spuštění bez čekání na timer: `systemctl start hermes-deploy`.

Pozastavení automatu, třeba při ručních zásazích na serveru:

```bash
touch deploy/PAUSE
```

Kdo může pushnout do nasazované větve, spouští na serveru kód jako root.
Větev na GitHubu chraň a účet měj s dvoufázovým ověřením.

**Ručně:**

```bash
git pull --ff-only && ./install.sh --restart
```

Restart znamená asi minutový výpadek včetně Signalu a webu. Bez `--restart`
se jen sestaví image a aktualizují units.

## Co běží

Dva až tři kontejnery (Signal je volitelný), všechny se síťovým režimem `host`:

| Kontejner | Image | Co dělá | Kde poslouchá |
| --- | --- | --- | --- |
| `hermes` | `hermes-agent-local` (sestavený z `Dockerfile`) | gateway: agent, Signal, cron, sessions, Bots; k tomu Webapp a dashboard | Webapp `127.0.0.1:9120`, dashboard `127.0.0.1:9119` |
| `hermes-signal` | `ghcr.io/asamk/signal-cli:0.14.5` | HTTP démon signal-cli | `127.0.0.1:8080` |
| `hermes-caddy` | `caddy:2.11` | TLS a reverse proxy | `80`, `443` |

- **Webapp** běží na `https://<HERMES_DOMAIN>` za přihlášením přes Nous.
- **Dashboard** (administrace) není zveřejněný. Přístup přes SSH tunel:

  ```bash
  ssh -L 9119:127.0.0.1:9119 <server>
  ```

  a pak <http://127.0.0.1:9119>.

Kontejnery spouští systemd unit `hermes-docker.service` příkazem
`docker compose up`. Kontejner `hermes` má `restart: on-failure:5`, takže ho po
pádu nahodí Docker.

## Soubory

| Soubor | Účel |
| --- | --- |
| `setup.sh` | průvodce první instalací |
| `install.sh` | instalace a nasazení změn |
| `compose.yaml` | definice všech tří kontejnerů |
| `Dockerfile` | oficiální image Hermes + `sops`, `age`, `uv` a `himalaya` |
| `docker/secrets-entrypoint.sh` | při startu rozšifruje tajné údaje do prostředí a do souborů v paměti |
| `sops.sh` | úprava tajných údajů bez instalace `sops` |
| `instance.example/` | vzor adresáře `instance/` |
| `sops.sh` | `sops` z Dockeru, pro úpravu tajných údajů bez instalace |
| `caddy/Caddyfile` | doména → Webapp |
| `backup/hermes-backup.sh` | denní záloha |
| `check.sh` | kontrola stavu celého řešení |
| `monitor/hermes-monitor.sh` | pravidelná kontrola a upozornění |
| `deploy/hermes-deploy.sh` | automatické nasazení nových commitů |
| `server/` | šablony systemd units; instaluje je `install.sh` |

## Data

Veškerý stav je v `HERMES_DATA_DIR`. Image je bezstavový.

| Cesta v datovém adresáři | Obsah | V kontejneru `hermes` |
| --- | --- | --- |
| `.hermes` | config, sessions, cron, skills, profily, `state.db` | `/opt/data` a `/home/hermes/.hermes` |
| `openknowledge` | Obsidian repozitář | `/home/hermes/openknowledge` |
| `projects` | projekty | `/home/hermes/projects` |
| `.config/himalaya` | nastavení pošty (hesla jsou v tajných údajích) | `/opt/data/.config/himalaya` |
| `.local/bin` | pomocné skripty agenta, např. SSH wrapper pro git | `/home/hermes/.local/bin` |
| `.local/share/signal-cli` | registrace a klíče Signalu | jen v `hermes-signal` |
| `backups` | zálohy | není připojeno |

Mimo datový adresář:

- repozitář včetně `instance/`
- soukromý klíč serveru
- Docker volumes `hermes_caddy-data` a `hermes_caddy-config` – certifikáty; při
  ztrátě se vystaví znovu

Tři věci, které nejsou na první pohled vidět:

- Cron joby a skills odkazují na absolutní cesty `/home/hermes/...`. V kontejneru
  proto tyto cesty zůstávají stejné, ať je `HERMES_DATA_DIR` kdekoli.
  Nástroje `write_file` a `patch` smějí zapisovat jen do adresářů
  z `HERMES_WRITE_SAFE_ROOT`. Image povoluje pouze `/opt/data`, proto
  `compose.yaml` přidává i připojení pod `/home/hermes/...`. Nové zapisovatelné
  připojení je potřeba doplnit i tam.
- Domovský adresář nástrojů v kontejneru je `/opt/data`
  (`terminal.home_mode: real` v `config.yaml`; nastavuje ho `install.sh`).
  Hodnota v `config.yaml` má přednost před proměnnou `TERMINAL_HOME_MODE`
  z `compose.yaml`. S výchozím `auto` by skripty v kontejneru dostaly
  `HOME=/opt/data/home` a nenašly by `~/.config/himalaya`. Cesta `~/.hermes/...`
  funguje díky symlinku `.hermes/.hermes -> .`, který vytváří `install.sh`.
  Z toho plyne i `~/.ssh` = `.hermes/.ssh`; `install.sh` tam přenese
  `known_hosts` z původní instalace.
- Docker i `hermes-docker.service` čekají na připojení disku s daty. Když disk
  chybí, Docker vůbec nenastartuje. Je to záměr: jinak by kontejnery naběhly
  nad prázdnými adresáři.

## Tajné údaje

Jsou v `instance/secrets/*.enc.yaml`, zašifrované nástrojem [SOPS](https://getsops.io)
pro klíče [age](https://age-encryption.org). Názvy jsou čitelné, hodnoty ne,
takže soubory patří do gitu (do repozitáře instance). Příkazy níže se pouštějí
v adresáři `instance/`; `./sops.sh` z kořene tohoto repozitáře tam pracuje sám.

- `secrets/hermes.enc.yaml` – vše, co agent dostane (hesla k poště, deploy
  klíče, tokeny). Kontejner `hermes` soubor při startu rozšifruje do paměti;
  na disku ani v `docker inspect` hodnoty nejsou.
  - Jednořádková hodnota je proměnná prostředí `NÁZEV`.
  - Víceřádková hodnota (SSH klíč, JSON) je soubor
    `/run/hermes-secrets/NÁZEV`, čitelný jen pro uživatele agenta; v prostředí
    je jen cesta k němu v `NÁZEV_FILE`. Výpis prostředí po řádcích
    (`printenv | cut -d= -f1`) by jinak druhý a další řádek takové hodnoty
    vypsal celý, a agent takto klíče už odeslal poskytovateli modelu.
- `secrets/backup.enc.yaml` – `RESTIC_PASSWORD`. Čte ho jen zálohovací skript,
  agent ho nikdy nedostane.

Rozšifrovat je umí každý, jehož veřejný klíč je v `instance/.sops.yaml`: server
(soukromý klíč v `/etc/hermes/credentials/age.key`) a kdokoli, kdo údaje
spravuje. Bez klíče nebo souboru kontejner skončí s kódem 78 a nerestartuje se.

**Kopii aspoň jednoho soukromého klíče měj mimo server**, třeba ve správci
hesel. Ztráta všech klíčů znamená ztrátu tajných údajů i přístupu k zálohám.

### Jednorázově na vlastním počítači

```bash
brew install sops age
```

Na macOS hledá `sops` klíč v `~/Library/Application Support/sops/age/keys.txt`
(na Linuxu v `~/.config/sops/age/keys.txt`):

```bash
mkdir -p ~/Library/Application\ Support/sops/age && age-keygen -o ~/Library/Application\ Support/sops/age/keys.txt
```

Jiné umístění lze předat proměnnou `SOPS_AGE_KEY_FILE`.

Vypsaný veřejný klíč (`age1…`) přidat do `.sops.yaml`. Přidat ho mezi příjemce
existujících souborů umí jen někdo, kdo je už rozšifruje (poprvé tedy server).

### Změna nebo přidání hodnoty

```bash
sops secrets/hermes.enc.yaml
```

Otevře editor s rozšifrovaným obsahem a po uložení soubor znovu zašifruje.
Potom commit, push a na serveru `git pull --ff-only && ./install.sh --restart`.

### Bez instalace: `sops` z Dockeru

`./sops.sh` spustí `sops` z jeho oficiálního image, takže stačí Docker a
soukromý klíč. Argumenty jsou stejné jako u `sops`, cesty se píší od kořene
repozitáře:

```bash
./sops.sh secrets/hermes.enc.yaml
```

Editor je `vi`. Kontejner běží bez sítě a rozšifrovaný obsah existuje jen
v něm. Klíč se bere z `SOPS_AGE_KEY_FILE`, jinak z umístění uvedených výše.
Nový klíč skript nevytvoří; k tomu je potřeba `age-keygen`.

### Nový příjemce (další server, další člověk)

Přidat veřejný klíč do `.sops.yaml` a přešifrovat:

```bash
sops updatekeys secrets/hermes.enc.yaml
```

```bash
sops updatekeys secrets/backup.enc.yaml
```

Odebrání příjemce funguje stejně; hodnoty, které už viděl, je navíc potřeba
změnit u jejich zdroje.

## Běžné úkony

Kontrola všeho najednou (služby, kontejnery, Signal, web, certifikát, záloha,
místo na disku); skončí chybou, když něco nesedí:

```bash
./check.sh
```

Stav:

```bash
systemctl status hermes-docker
```

```bash
docker ps
```

Logy agenta (Docker drží nejvýš 5 × 20 MB na kontejner; vlastní logy Hermes
jsou v `.hermes/logs`):

```bash
docker logs -f --tail 100 hermes
```

Restart celého stacku:

```bash
systemctl restart hermes-docker
```

Příkaz `hermes` uvnitř kontejneru, jako uživatel agenta:

```bash
docker exec -it -u 1000:1000 -e HOME=/opt/data hermes hermes --help
```

## Hlídání

`hermes-monitor.timer` pouští každých 10 minut `check.sh` a po selhané záloze
hned. Když se výsledek změní, zapíše to do journalu
(`journalctl -u hermes-monitor`) a pošle zprávu přes Signal na
`ALERT_SIGNAL_RECIPIENT`: jednu, když se něco pokazí, a jednu, když je zase
vše v pořádku.

Zpráva odchází přes místní signal-cli. Když neběží Signal nebo celý server,
nepřijde nic; to pokryje jen kontrola veřejné adresy zvenku (UptimeRobot
a podobné).

## Upgrade Hermes

```bash
docker compose build --pull gateway && ./install.sh --no-build --restart
```

Tag `stable` se posouvá, takže `--pull` stáhne aktuální stabilní verzi. Před
upgradem je dobré pustit zálohu (`systemctl start hermes-backup`).

signal-cli se nikdy nevrací na starší verzi, než která naposledy zapsala data.

## Záloha

`hermes-backup.timer` spouští denně v 03:30 `backup/hermes-backup.sh`:

1. zkopíruje všechny SQLite databáze přes backup API (konzistentní i za běhu),
2. uloží je spolu se stavem Hermes, registrací Signalu, `openknowledge`,
   `projects`, konfigurací nástrojů a tímto repozitářem včetně `instance/`
   a zašifrovaných tajných údajů do restic
   úložiště `<data>/backups/restic-repo`,
3. ponechá 7 denních, 4 týdenní a 3 měsíční snapshoty a ověří úložiště.

Vynechává vše, co si Hermes umí stáhnout nebo sestavit znovu.

Ruční spuštění a výsledek:

```bash
systemctl start hermes-backup && journalctl -u hermes-backup -n 30 --no-pager
```

**Omezení:** úložiště je na stejném disku jako data. Chrání před smazáním,
poškozením souborů a rozbitou databází, ne před ztrátou disku. Kopii mimo
server lze doplnit přes `restic copy`.

Heslo k úložišti je `RESTIC_PASSWORD` v `instance/secrets/backup.enc.yaml`. Soukromý
klíč serveru v záloze není.

### Obnova souborů ze zálohy

Jako root v adresáři repozitáře (cesty pro výchozí `HERMES_DATA_DIR`):

```bash
mkdir -p /restore
```

```bash
export RESTIC_PASSWORD="$(docker run --rm --network none -e SOPS_AGE_KEY_FILE=/age.key -v /etc/hermes/credentials/age.key:/age.key:ro -v "$PWD/instance/secrets:/secrets:ro" --entrypoint sops hermes-agent-local decrypt --extract '["RESTIC_PASSWORD"]' /secrets/backup.enc.yaml)"
```

```bash
docker run --rm -e RESTIC_PASSWORD -e RESTIC_REPOSITORY=/repo -v /home/hermes/backups/restic-repo:/repo -v /restore:/restore restic/restic:0.18.1 restore latest --target /restore
```

Soubory se obnoví do `/restore/<původní cesta>`, databáze do
`/restore/home/hermes/backups/sqlite-dump/<cesta v datech>`. Jiný snapshot než
poslední: místo `latest` jeho ID z příkazu `snapshots`. Před kopírováním zpět
zastavit `hermes-docker`.

## Obnova serveru

Když server zanikne a disk s daty přežije:

1. Nový server, nainstalovat Docker.
2. Připojit disk s daty na `HERMES_DATA_DIR` a zapsat ho do `/etc/fstab`.
   U Hetzner Volume **nespouštět `mkfs`** z jejich návodu, smazalo by data.
3. Postupovat podle kapitoly Instalace; `instance/` naklonovat ze svého
   repozitáře nebo vzít ze zálohy. Soukromý klíč
   buď obnovit z kopie do `/etc/hermes/credentials/age.key`, nebo nechat
   `install.sh` vytvořit nový a přidat ho mezi příjemce.
4. Přesměrovat DNS na novou adresu. Caddy si certifikát vystaví sám.

Když zanikne i disk s daty, data jsou pryč; viz omezení zálohy výše.
