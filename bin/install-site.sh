#!/usr/bin/env bash
# Install (or update) a per-app site snippet into the edge proxy, then
# trigger a graceful Caddy reload. No-op if the rendered snippet on disk
# already matches.
#
# Usage:
#   install-site.sh <name> <path-to-template>
#
# The template MAY contain shell-style ${VAR} references — they are
# substituted at install time using envsubst against the caller's
# environment, then the *rendered* snippet (with literal hostnames /
# values) is written to sites.d/<name>.caddy. This means:
#   - Caddy never sees env-var indirection — it just reloads against a
#     plain file, no container restart needed when env changes.
#   - The caller is responsible for exporting the vars the template
#     references before invoking this script:
#
#       BLINK_DOMAIN=blink.example.com install-site.sh blink path/to/site.caddy
#
# Example template (`site.caddy`):
#   ${BLINK_DOMAIN} {
#       reverse_proxy blink-mobile-web:80
#   }
set -euo pipefail

NAME="${1:?usage: install-site.sh <name> <path-to-template>}"
SRC="${2:?usage: install-site.sh <name> <path-to-template>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$EDGE_DIR/sites.d/${NAME}.caddy"
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT

log() { echo -e "\033[1;36m[edge]\033[0m $*"; }

if [[ ! -f "$SRC" ]]; then
  echo "Template not found: $SRC" >&2
  exit 1
fi

if ! command -v envsubst >/dev/null 2>&1; then
  echo "envsubst not found on PATH. Install gettext (apt-get install gettext-base)." >&2
  exit 1
fi

# Render the template. envsubst expands ${VAR}; anything not exported
# collapses to empty string, which we treat as a config error.
envsubst < "$SRC" > "$RENDERED"

# Surface unresolved variables loudly. We strip Caddyfile-style comments
# first (anything from `#` to end-of-line) so references inside doc
# comments don't count as missing vars.
MISSING=()
while IFS= read -r var; do
  if [[ -z "${!var-}" ]]; then
    MISSING+=("$var")
  fi
done < <(sed 's/#.*//' "$SRC" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | sed -E 's/\$\{([A-Za-z0-9_]+)\}/\1/' | sort -u)

if (( ${#MISSING[@]} > 0 )); then
  echo "Template references vars that are not set: ${MISSING[*]}" >&2
  echo "Export them before calling install-site.sh." >&2
  exit 1
fi

if [[ -f "$DEST" ]] && cmp -s "$RENDERED" "$DEST"; then
  log "Snippet ${NAME}.caddy unchanged — skipping reload"
  exit 0
fi

log "Installing snippet ${NAME}.caddy"
cp "$RENDERED" "$DEST"

# Validate inside the running container before reloading. We capture the
# output BEFORE reverting so the actual error is visible — otherwise a
# post-revert validate would report the (now-passing) prior state.
if ! VALIDATE_OUT=$(docker exec edge-caddy caddy validate --config /etc/caddy/Caddyfile 2>&1); then
  echo "Caddy config validation failed — reverting" >&2
  echo "$VALIDATE_OUT" >&2
  rm -f "$DEST"
  exit 1
fi

log "Reloading Caddy"
docker exec edge-caddy caddy reload --config /etc/caddy/Caddyfile

log "Site ${NAME} installed"
