#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

docker secret create cf_origin_cert "$SCRIPT_DIR/cf_origin_cert"
docker secret create cf_origin_key "$SCRIPT_DIR/cf_origin_key"
docker secret create cloudflare_tunnel_token "$SCRIPT_DIR/cloudflare_tunnel_token"
docker secret create traefik_users "$SCRIPT_DIR/traefik_users"

# Cloudflare API token for the ACME DNS-01 challenge.
# Create at: Cloudflare Dashboard -> My Profile -> API Tokens -> Create Token
# Permissions: Zone:DNS:Edit + Zone:Zone:Read, scoped to ryszard-napierala.dev
docker secret create cf_dns_api_token "$SCRIPT_DIR/cf_dns_api_token"
