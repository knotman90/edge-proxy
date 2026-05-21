#!/usr/bin/env bash
# Install (or update) a per-app site snippet into the edge proxy, then
# trigger a graceful Caddy reload. No-op if the snippet on disk already
# matches the source.
#
# Usage:
#   install-site.sh <name> <path-to-snippet>
#
# Example:
#   install-site.sh blink /home/admin/blink/monorepo/deploy/site.caddy
set -euo pipefail

NAME="${1:?usage: install-site.sh <name> <path-to-snippet>}"
SRC="${2:?usage: install-site.sh <name> <path-to-snippet>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$EDGE_DIR/sites.d/${NAME}.caddy"

log() { echo -e "\033[1;36m[edge]\033[0m $*"; }

if [[ ! -f "$SRC" ]]; then
  echo "Source snippet not found: $SRC" >&2
  exit 1
fi

if [[ -f "$DEST" ]] && cmp -s "$SRC" "$DEST"; then
  log "Snippet ${NAME}.caddy unchanged — skipping reload"
  exit 0
fi

log "Installing snippet ${NAME}.caddy"
cp "$SRC" "$DEST"

# Validate inside the running container before reloading. If validation
# fails we leave the old snippet in place to avoid a broken edge.
if ! docker exec edge-caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
  echo "Caddy config validation failed — reverting" >&2
  rm -f "$DEST"
  docker exec edge-caddy caddy validate --config /etc/caddy/Caddyfile >&2 || true
  exit 1
fi

log "Reloading Caddy"
docker exec edge-caddy caddy reload --config /etc/caddy/Caddyfile

log "Site ${NAME} installed"
