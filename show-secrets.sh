#!/bin/bash

for secret in cf_origin_cert cf_origin_key cloudflare_tunnel_token traefik_users; do
  echo "=== $secret ==="
  docker service create --quiet --name "show_${secret}" --secret "$secret" --restart-condition=none alpine cat /run/secrets/"$secret"
  sleep 2
  docker service logs "show_${secret}" 2>/dev/null
  docker service rm "show_${secret}" > /dev/null 2>&1
  echo
done
