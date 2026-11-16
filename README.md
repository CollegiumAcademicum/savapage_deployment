# SavaPage Deployment

Deploys [SavaPage](https://www.savapage.org) (web print portal with per-user page accounting) on **pod0** as a rootful Podman container managed by podman compose and systemd. Users sign in with Keycloak (`collegium` realm), upload a document in the browser and print it to a CUPS queue; every job is counted per user and printer.

- **Image:** `ghcr.io/collegiumacademicum/savapage`, built from `image/` (SavaPage + CUPS in one container).
- **Database:** its own role and database `savapage` inside CArtei's Postgres (`cartei_postgres_1`, `cartei-db.service`).
- **Web:** Caddy on pod0 terminates TLS and proxies to `savapage_savapage_1:8631` over `systemd-caddy`.

## Image updates

`.github/workflows/image.yaml` checks <https://download.savapage.org/installer/> every night. It builds only if the newest `*-final-linux-x64.bin` is not on GHCR as `:<version>` yet, so there are no blind rebuilds. A push to `image/` or a manual run always rebuilds. The installer is checked against SavaPage's `sha512sums.txt`.

On pod0, `savapage-update.timer` pulls `:latest` daily at 04:30 and restarts the service. When nothing new was published, the pull is a no-op.

To roll back, pin the tag in `docker-compose.yaml` (e.g. `:1.7.0`) and run `./start.sh`.

## Fresh setup on pod0

Requires `cartei-db.service` to be running and `/tank/savapage` mounted. Like `/tank/caddy`, it is the ZFS dataset `tank/encrypted/pod0/savapage` on pve0, passed through as virtiofs tag `pod0_savapage` and mounted by `tank-savapage.mount`.

```bash
curl -fsSL https://raw.githubusercontent.com/CollegiumAcademicum/savapage_deployment/main/setup.sh | bash
nano /tank/savapage/.env          # fill in all CHANGE_ME values
/tank/savapage/setup.sh           # second run: creates the DB role/database and the schema
cd /tank/savapage && ./start.sh
```

### One-time configuration

1. **Ingress and Caddy:** add `print.ca-hd.de` to ca-ingress (SNI passthrough to pod0). Then append `caddy-snippet.caddy` to `/tank/caddy/Caddyfile` and reload Caddy.
2. **Keycloak client:** in realm `collegium`, create the OIDC client `savapage` (confidential, standard flow). Set the redirect URI to `https://print.ca-hd.de/user?sp-oauth=keycloak` and the web origin to `https://print.ca-hd.de`. Put the client secret into `.env` as `KEYCLOAK_CLIENT_SECRET` and restart. The entrypoint writes `server/ext/savapage-ext-oauth-keycloak.properties` from `.env` on every start.
3. **Admin login:** open `https://print.ca-hd.de/admin` and log in as the built-in `admin` (initial password per the SavaPage manual, *Admin Web App*). Change it immediately.
4. **User source:** go to *Options → User Source → LDAP*. Set Server Type `FreeIPA`, host `ipa.intranet.ca-hd.de`, port 636 with SSL, Base DN `cn=accounts,dc=intranet,dc=ca-hd,dc=de`, and a read-only bind user. Turn on user sync. Keycloak logins map to these users through `keycloak.savapage.usersource=true`.
5. **Printers:** printers must be network-reachable from pod0, since USB printers can't be attached to the VM. Add each one as a CUPS queue in the container (driverless IPP Everywhere works for most current printers):
   ```bash
   podman exec savapage_savapage_1 lpadmin -p <name> -E -v ipp://<printer-ip>/ipp/print -m everywhere
   ```
   SavaPage picks up local CUPS queues automatically as proxy printers. Then set costs and quotas in the Admin Web App.
6. **Close the bypass:** firewall each printer so it only accepts 9100/631/515 from pod0, and turn off WSD/AirPrint on it. Otherwise users can still print without being counted.

## Directory structure

```
/tank/savapage/                 (symlinked as ~/savapage)
├── .env                        # secrets — never commit
├── docker-compose.yaml
├── savapage.service            # systemd unit (installed by setup.sh)
├── savapage-update.{service,timer}
├── setup.sh / start.sh / stop.sh
├── caddy-snippet.caddy         # block for /tank/caddy/Caddyfile
├── custom/                     # CA look: CSS, fonts, logo, login texts
├── image/                      # Dockerfile + entrypoint (built by CI)
└── data/
    ├── server/  → /opt/savapage/server/data  (server.properties, encryption.properties!)
    ├── cups/    → /etc/cups                  (printer queues)
    └── ipa-ca.crt                          # FreeIPA CA for LDAPS, copied by setup.sh
```

`data/server/encryption.properties` is the key for secrets SavaPage stores in the database. Back it up together with the DB, because a DB restore without it is useless.

## Look and feel

`custom/` gives the web apps the Collegium Academicum look. Compose mounts it into `/opt/savapage/server/custom/` (manual ch. 20):

- `web.properties` turns off SavaPage's default background and loads `web/ca.css` in the user, admin and job ticket apps.
- `web/ca.css` overrides the jQuery Mobile swatches with CA teal, Source Sans 3 and the logo on the login page. The font is bundled in `web/fonts/` (OFL), so no requests go to Google.
- `html/*-login*.html` holds the login headings in English and German (`_de`). The user versions also carry a small script that opens the upload page right after login instead of the document preview. SavaPage has no setting for this; it works because the login snippet is inserted with jQuery `.html()`, which runs inline scripts.

After a change, run `git pull && sudo systemctl restart savapage.service` on pod0.

## Common commands

```bash
./start.sh                                   # pull latest image and (re)start
./stop.sh                                    # stop
podman logs -f savapage_savapage_1           # server log
podman exec savapage_savapage_1 lpstat -t    # CUPS queues and jobs
```

## Open points

- **Backups:** CArtei's `backup.sh` dumps only the `cartei` database. Add `savapage` (plus `data/server/encryption.properties`) to it or to a separate timer.
- **Printing from devices (IPP/AirPrint)** isn't exposed. Only the web upload is. If that's wanted, publish port 631 and configure SavaPage's IPP queue.
