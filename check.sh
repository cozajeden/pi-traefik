#!/bin/bash
# ============================================================
# Traefik health check — verifies every moving part.
# Read-only: changes nothing.
#   ./check.sh
# ============================================================
set -uo pipefail

DOMAIN="${DOMAIN:-ryszard-napierala.dev}"
ACME_JSON="/traefik/acme_volume/acme.json"
FAIL=0

hdr()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
pass() { printf '  \033[0;32m PASS\033[0m  %s\n' "$*"; }
fail() { printf '  \033[0;31m FAIL\033[0m  %s\n' "$*"; FAIL=1; }
note() { printf '        %s\n' "$*"; }

hdr "Swarm services"
for svc in traefik_traefik traefik_cloudflared; do
  R=$(docker service ls --filter "name=$svc" --format '{{.Replicas}}' 2>/dev/null)
  [[ "$R" == "1/1" ]] && pass "$svc $R" || fail "$svc ${R:-missing}"
done

hdr "Docker secrets"
for s in cf_dns_api_token cloudflare_tunnel_token traefik_users; do
  docker secret inspect "$s" >/dev/null 2>&1 && pass "$s" || fail "$s missing"
done

hdr "Cloudflare API token"
TOK_FILE="$(cd "$(dirname "$0")" && pwd)/cf_dns_api_token"
if [[ -s "$TOK_FILE" ]]; then
  T=$(cat "$TOK_FILE")
  S=$(curl -sS -H "Authorization: Bearer $T" \
      https://api.cloudflare.com/client/v4/user/tokens/verify 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["status"])' 2>/dev/null)
  [[ "$S" == "active" ]] && pass "token active" || fail "token not active (got: ${S:-error})"
else
  note "cf_dns_api_token not present locally (fine if only the secret exists)"
fi

hdr "Certificate in acme.json"
if sudo test -s "$ACME_JSON"; then
  OUT=$(sudo python3 -c "
import json
d=json.load(open('$ACME_JSON'))
cs=d.get('letsencrypt',{}).get('Certificates') or []
print(len(cs))
for c in cs: print(c['domain']['main'], c['domain'].get('sans'))
" 2>/dev/null)
  N=$(echo "$OUT" | head -1)
  [[ "$N" -ge 1 ]] && pass "$N certificate(s) stored" || fail "acme.json holds no certificates"
  echo "$OUT" | tail -n +2 | sed 's/^/        /'
else
  fail "$ACME_JSON missing or empty"
fi

hdr "Served certificate (SNI: $DOMAIN)"
ISS=$(echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null \
      | openssl x509 -noout -issuer -enddate 2>/dev/null)
if grep -qi "let's encrypt" <<<"$ISS"; then
  pass "Let's Encrypt"; sed 's/^/        /' <<<"$ISS"
else
  fail "not a Let's Encrypt cert"; sed 's/^/        /' <<<"${ISS:-no response}"
fi

hdr "ACME endpoint pin (IPv6 workaround)"
PIN=$(grep -oE 'acme-v02\.api\.letsencrypt\.org:[0-9.]+' traefik-stack.yml 2>/dev/null | cut -d: -f2)
LIVE=$(curl -sS "https://cloudflare-dns.com/dns-query?name=acme-v02.api.letsencrypt.org&type=A" \
       -H "accept: application/dns-json" 2>/dev/null \
       | python3 -c 'import json,sys; print([a["data"] for a in json.load(sys.stdin).get("Answer",[]) if a["type"]==1][0])' 2>/dev/null)
if [[ -n "$PIN" && -n "$LIVE" ]]; then
  [[ "$PIN" == "$LIVE" ]] && pass "pin $PIN matches live DNS" \
    || { fail "pin $PIN != live $LIVE — renewals will break"; note "fix: update extra_hosts in traefik-stack.yml, then redeploy"; }
else
  note "could not compare (pin=${PIN:-none} live=${LIVE:-none})"
fi

hdr "Result"
[[ $FAIL -eq 0 ]] && echo "  All checks passed." || echo "  Some checks FAILED (see above)."
exit $FAIL
