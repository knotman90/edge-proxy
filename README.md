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
