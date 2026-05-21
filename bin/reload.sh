#!/usr/bin/env bash
# Graceful zero-downtime reload of the Caddy config currently on disk.
set -euo pipefail
docker exec edge-caddy caddy reload --config /etc/caddy/Caddyfile
echo "[edge] reloaded"
