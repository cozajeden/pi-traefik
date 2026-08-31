#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Local, uncommitted settings (DASHBOARD_HOST) used by traefik-stack.yml
set -a; [[ -f "$SCRIPT_DIR/.env" ]] && . "$SCRIPT_DIR/.env"; set +a
sudo --preserve-env=DASHBOARD_HOST docker stack deploy -c "$SCRIPT_DIR/traefik-stack.yml" traefik
