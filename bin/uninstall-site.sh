#!/usr/bin/env bash
# Remove a per-app site snippet and reload Caddy.
#
# Usage:
#   uninstall-site.sh <name>
set -euo pipefail

NAME="${1:?usage: uninstall-site.sh <name>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$EDGE_DIR/sites.d/${NAME}.caddy"

log() { echo -e "\033[1;36m[edge]\033[0m $*"; }

if [[ ! -f "$DEST" ]]; then
  log "Snippet ${NAME}.caddy not present — nothing to do"
  exit 0
fi

rm -f "$DEST"
log "Reloading Caddy"
docker exec edge-caddy caddy reload --config /etc/caddy/Caddyfile
log "Site ${NAME} removed"
