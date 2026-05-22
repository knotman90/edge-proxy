# edge-proxy

A single Caddy reverse proxy that fronts every application running on a host.
Reusable across projects: apps don't ship their own edge proxy — they attach
public-facing containers to the shared `edge` Docker network and drop a
Caddyfile site snippet into `sites.d/`.

## Why

- One TLS termination point, one ACME account, one place to look when
  something is misrouted.
- Apps stay isolated: only the containers an app *explicitly* attaches to the
  `edge` network are reachable from the outside. Databases, workers, queues
  stay on the app's own private network.
- Adding a new app to a host is two operations: `up -d` the app, then
  `install-site.sh` its snippet. No reverse-proxy edits, no port juggling.

## Layout

```
docker-compose.yml    # caddy + shared `edge` network
Caddyfile             # global options + `import sites.d/*.caddy`
sites.d/              # per-app snippets land here (gitignored)
.env                  # CADDY_EMAIL, ACME_CA (gitignored)
bin/
  bootstrap.sh        # idempotent `compose up -d`
  install-site.sh     # cp snippet → sites.d/, validate, reload
  uninstall-site.sh   # rm snippet, reload
  reload.sh           # zero-downtime reload
  logs.sh             # tail caddy logs
```

## Initial setup on a host

```bash
git clone <this-repo> ~/edge
cd ~/edge
cp .env.example .env
$EDITOR .env             # set CADDY_EMAIL (real inbox, used by Let's Encrypt)
./bin/bootstrap.sh
```

At this point the proxy is running, owns ports 80/443, and the `edge` Docker
network exists. No site snippets yet, so nothing is served.

## Onboarding an app

An app deploy script should:

1. Run `~/edge/bin/bootstrap.sh` — idempotent. Brings edge up if it's not
   already, no-op otherwise.
2. Bring its own stack up. The app's `docker-compose.yml` must:
   - Declare the `edge` network as `external: true`.
   - Attach its public-facing container(s) to it (and to its own private
     network for internal services).
3. Run `~/edge/bin/install-site.sh <app-name> path/to/site.caddy`. The script
   copies the snippet, validates the merged Caddyfile, and reloads. If
   validation fails the new snippet is reverted and deploy aborts.

App-side example (excerpt from a `docker-compose.yml`):

```yaml
services:
  web:
    image: myapp-web:latest
    networks:
      - internal
      - edge

networks:
  internal:
    driver: bridge
  edge:
    external: true
```

App-side snippet template (`deploy/site.caddy`):

```caddy
${MYAPP_DOMAIN} {
    encode zstd gzip
    reverse_proxy myapp-web:80
}
```

The template may use `${VAR}` references. `install-site.sh` runs `envsubst`
on it at install time using the caller's environment, so what lands in
`sites.d/` is a fully-rendered file with literal values. Caddy never sees
env-var indirection — that keeps `caddy reload` graceful (no container
restart needed when adding apps or rotating domains).

The caller must export the referenced vars before invoking:

```bash
MYAPP_DOMAIN=myapp.example.com ~/edge/bin/install-site.sh myapp deploy/site.caddy
```

If a referenced var is unset, the install aborts loudly before touching
`sites.d/`.

Container names (`myapp-web` above) must be stable for Caddy's DNS lookups to
work, so apps should pin `container_name:` in their compose.

## Email + ACME

`CADDY_EMAIL` is the ACME account contact. Let's Encrypt uses it for
cert-expiry warnings and account recovery. Optional but recommended — leaving
it blank means silent failures if renewals stop working.

For first-time setup or when iterating on snippet structure, flip `ACME_CA`
to the Let's Encrypt staging endpoint to avoid burning production rate limits:

```env
ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory
```

When you switch back to prod, delete the `caddy_data` volume so Caddy
re-fetches certs against the real endpoint:

```bash
docker compose down
docker volume rm edge_caddy_data
docker compose up -d
```

## Operations

- `bin/bootstrap.sh` — bring up (idempotent).
- `bin/install-site.sh <name> <path>` — add/update a site.
- `bin/uninstall-site.sh <name>` — remove a site.
- `bin/reload.sh` — force a reload of the config on disk.
- `bin/logs.sh` — tail Caddy logs.
- `docker compose down` — stop edge (all sites go offline).

## What stays out of this repo

- App-specific site blocks. Those live in the app's repo at
  `deploy/site.caddy` and get copied here at deploy time.
- The actual `.env`. Production values live on the host.

## Real-world example

A live setup hosting two apps (`blink` + `patente-nautica`) on a single
Hetzner CX22 with the box layout below. Sub-resources of each app stay
fully isolated; only the public-facing container of each app joins the
shared `edge` network.

```
host (Hetzner CX22)
├── /home/admin/edge/                  ← this repo, checked out at v0.2.1
│   ├── docker-compose.yml             ← caddy + the shared `edge` network
│   ├── Caddyfile                      ← imports sites.d/*.caddy
│   ├── sites.d/
│   │   ├── blink.caddy                ← installed by app1's deploy script
│   │   └── patente-nautica.caddy      ← installed by app2's deploy script
│   └── .env                           ← CADDY_EMAIL only
│
├── /home/admin/blink/monorepo/        ← app 1 (private repo, deploy keys)
│   ├── docker-compose.yml
│   ├── docker-compose.edge.yml        ← attaches mobile-web + api to edge
│   └── deploy/site.caddy              ← template; installed via envsubst
│
├── /home/admin/nautica-trainer/       ← app 2 (rsynced from laptop)
│   └── infra/
│       ├── compose.yml + compose.edge.yml + compose.build.yml
│       └── deploy/site.caddy
│
├── /mnt/HC_Volume_104514901/          ← Hetzner Volume (separate disk)
│   ├── blink-backups/                 ← pg_dump rotation
│   └── nautica-backups/
│
docker networks:
  edge                                 ← shared; only public-facing containers attach
  blink_backend-network                ← private to blink
  patente-nautica_internal             ← private to nautica
```

DNS via [nip.io](https://nip.io): each app gets a subdomain
(`blink.46-225-27-111.nip.io`, `nautica-trainer.46-225-27-111.nip.io`)
that resolves to the same host IP. Caddy auto-issues per-hostname
Let's Encrypt certs via HTTP-01.

Onboarding a third app on the same host:
1. Define `container_name` on the public-facing service (for stable DNS).
2. Declare the `edge` network as `external: true` in its compose.
3. Drop a `deploy/site.caddy` template using `${MYAPP_DOMAIN}` syntax.
4. App's deploy script: `MYAPP_DOMAIN=foo.<ip>.nip.io ~/edge/bin/install-site.sh myapp deploy/site.caddy`.

No edits to existing apps required. `caddy reload` is graceful.
