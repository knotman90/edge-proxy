#!/usr/bin/env bash
# Idempotently bring up the edge proxy. Safe to call from any app's deploy
# script — Docker Compose only acts on drift, so calling this when edge is
# already running with the same config is a no-op.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo -e "\033[1;36m[edge]\033[0m $*"; }

cd "$EDGE_DIR"

if [[ ! -f .env ]]; then
  log "No .env found, copying from .env.example (edit it before re-running)"
  cp .env.example .env
fi

# The `edge` network is declared in docker-compose.yml; `up -d` creates it
# if missing. We don't pre-create it because compose owns its lifecycle.
log "Starting edge proxy"
docker compose up -d

log "Edge proxy is up"
