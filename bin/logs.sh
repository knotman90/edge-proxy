#!/usr/bin/env bash
# Tail edge-caddy logs.
set -euo pipefail
docker logs -f --tail=200 edge-caddy
