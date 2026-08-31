#!/bin/bash
# ============================================================
# Traefik + Cloudflare Tunnel — one-shot setup from scratch.
#
# Idempotent: safe to re-run. Skips anything already present.
#
# Before running, place these credential files next to this script:
#   cf_dns_api_token         Cloudflare API token, Zone:DNS:Edit + Zone:Zone:Read
#   cf_origin_cert           Cloudflare Origin Certificate  (optional fallback)
#   cf_origin_key            its private key                (optional fallback)
#   cloudflare_tunnel_token  from Zero Trust > Networks > Tunnels
#   traefik_users            htpasswd hash for the dashboard
#
# Usage:  ./bootstrap.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Local, uncommitted settings (DASHBOARD_HOST) used by traefik-stack.yml
set -a; [[ -f "$SCRIPT_DIR/.env" ]] && . "$SCRIPT_DIR/.env"; set +a
STACK_NAME="traefik"
NETWORK="traefik_public"
ACME_DIR="/traefik/acme_volume"

say()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[0;32mOK\033[0m  %s\n' "$*"; }
warn() { printf '    \033[0;33m!!\033[0m  %s\n' "$*"; }
die()  { printf '\n\033[0;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 1. preflight -------------------------------------------------
say "Checking prerequisites"
command -v docker >/dev/null || die "docker is not installed"
docker info 2>/dev/null | grep -q "Swarm: active" || die \
  "Docker Swarm is not active. Run:  docker swarm init"
ok "docker + swarm ready"

# ---------- 2. required credential files ---------------------------------
say "Checking credential files"
REQUIRED=(cf_dns_api_token cloudflare_tunnel_token traefik_users)
OPTIONAL=(cf_origin_cert cf_origin_key)
for f in "${REQUIRED[@]}"; do
  [[ -s "$SCRIPT_DIR/$f" ]] || die "missing or empty: $SCRIPT_DIR/$f  (see README step 3)"
  chmod 600 "$SCRIPT_DIR/$f"
  ok "$f"
done
for f in "${OPTIONAL[@]}"; do
  if [[ -s "$SCRIPT_DIR/$f" ]]; then chmod 600 "$SCRIPT_DIR/$f"; ok "$f (optional)"
  else warn "$f absent — origin-cert fallback disabled (fine; ACME provides the cert)"; fi
done

# ---------- 3. overlay network -------------------------------------------
say "Overlay network '$NETWORK'"
if docker network inspect "$NETWORK" >/dev/null 2>&1; then ok "already exists"
else docker network create --driver overlay --attachable "$NETWORK" >/dev/null; ok "created"; fi

# ---------- 4. acme.json bind path ---------------------------------------
say "ACME storage at $ACME_DIR"
if [[ -f "$ACME_DIR/acme.json" ]]; then ok "already exists"
else
  sudo mkdir -p "$ACME_DIR"
  sudo touch "$ACME_DIR/acme.json"
  ok "created"
fi
sudo chmod 600 "$ACME_DIR/acme.json"
sudo chown root:root "$ACME_DIR/acme.json"
ok "permissions 600 root:root"

# ---------- 5. docker secrets --------------------------------------------
say "Docker secrets"
for f in "${REQUIRED[@]}" "${OPTIONAL[@]}"; do
  [[ -s "$SCRIPT_DIR/$f" ]] || continue
  if docker secret inspect "$f" >/dev/null 2>&1; then ok "$f exists"
  else docker secret create "$f" "$SCRIPT_DIR/$f" >/dev/null && ok "$f created"; fi
done
warn "Swarm secrets are immutable. To change one: remove it from the stack,"
warn "docker secret rm <name>, recreate, redeploy — or use a versioned name."

# ---------- 6. deploy -----------------------------------------------------
say "Deploying stack '$STACK_NAME'"
docker stack deploy -c "$SCRIPT_DIR/traefik-stack.yml" "$STACK_NAME"

say "Done. Verify with:  ./check.sh"
echo "   First certificate issuance takes 30-120s (DNS-01 propagation)."
