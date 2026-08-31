# Traefik + Cloudflare Tunnel (Docker Swarm)

Reverse proxy for every service on this host. Publishes them through a
Cloudflare Tunnel (no router ports opened) and issues a **Let's Encrypt
wildcard certificate**, which the mail stack also uses.

```
internet ──> Cloudflare (edge) ──> cloudflared (outbound tunnel) ──> traefik ──> services
                                                                       │
                                        Let's Encrypt (DNS-01) ────────┘
                                                    │
                                        /traefik/acme_volume/acme.json
                                        (the mail stack reads this too)
```

---

## Files

| File | Role |
|---|---|
| `traefik-stack.yml` | main stack: traefik + cloudflared + cert-init |
| `tls.yml` | TLS configuration (Docker config) |
| `bootstrap.sh` | **setup from scratch** — network, dirs, secrets, deploy |
| `check.sh` | verifies services, secrets, token, certificate, IP pin |
| `create-secrets.sh` | creates Docker secrets from local files |
| `update.sh` | redeploy the stack |
| `rotate-password.sh` | change the dashboard password |
| `show-secrets.sh` | print secret contents |
| `example-service.yml` | template for a service behind Traefik |
| `.env.example` | template for the local `.env` (dashboard hostname) |

---

## Quick start

```bash
docker swarm init                 # if swarm isn't running yet
cp .env.example .env              # set DASHBOARD_HOST
# place the credential files (see Step 2)
./bootstrap.sh
./check.sh
```

---

## Step 1 — prerequisites

- Docker Swarm (`docker swarm init`)
- Domain on Cloudflare with active nameservers
- A tunnel created under Zero Trust → Networks → Tunnels
- Cloudflare SSL mode set to **Full (strict)**

---

## Step 2 — credential files

Place these next to `bootstrap.sh`. **None of them are committed** —
`.gitignore` blocks every one.

### `.env` — required

Local settings, also not committed. The deploy scripts (`bootstrap.sh`,
`update.sh`, `rotate-password.sh`) load it before `docker stack deploy`.

```bash
cp .env.example .env    # then set DASHBOARD_HOST
```

### `cf_dns_api_token` — required

API token for the ACME DNS-01 challenge.

1. https://dash.cloudflare.com/profile/api-tokens
   (the page hides behind the profile icon, top right)
2. **Create Token → Create Custom Token**
3. Permissions — **both rows are needed**:

   | Group | Resource | Level |
   |---|---|---|
   | Zone | DNS | **Edit** |
   | Zone | Zone | **Read** |

4. Zone Resources: Include → Specific zone → *your domain*

> **Watch out:** pick **Edit**, not Read — the second row only appears after
> clicking *+ Add more*. Zone:Read alone is not enough; Traefik has to create
> TXT records. Use an **API Token**, not the Global API Key.

```bash
printf '%s' 'YOUR_TOKEN' > ./cf_dns_api_token && chmod 600 ./cf_dns_api_token
```

### `cloudflare_tunnel_token` — required

From Zero Trust → Networks → Tunnels → your tunnel.

```bash
printf '%s' 'TUNNEL_TOKEN' > ./cloudflare_tunnel_token
```

### `traefik_users` — required

Dashboard basic-auth:

```bash
htpasswd -nb admin YOUR_PASSWORD > ./traefik_users     # apache2-utils
```

### `cf_origin_cert` / `cf_origin_key` — optional

A Cloudflare Origin Certificate, as a fallback.

> ⚠️ **Do not set it as `defaultCertificate` in `tls.yml`.** Its SANs
> (`domain` + `*.domain`) cover exactly the names ACME asks for, so Traefik
> treats the certificate as already provided and **never contacts Let's
> Encrypt** — the log says *"No ACME certificate generation required"*. The two
> are mutually exclusive.

---

## Step 3 — run bootstrap

```bash
./bootstrap.sh
```

Idempotent. Does: prerequisite checks → overlay network `traefik_public` →
`/traefik/acme_volume/acme.json` (0600 root) → Docker secrets → deploy.

The first certificate appears after **30–120 s** (TXT propagation).

---

## Step 4 — tunnel routing

Zero Trust → Networks → Tunnels → your tunnel → **Public Hostnames**:

| Subdomain | Domain | Service |
|---|---|---|
| `*` | your.domain | `http://traefik:80` |

The wildcard covers every subdomain — Traefik decides routing from its labels.
This means **adding a service never requires a tunnel change**.

---

## Step 5 — verify

```bash
./check.sh
```

Checks services, secrets, token validity, the certificate in `acme.json`, the
certificate served on :443, and the **ACME endpoint IP pin** (see below).

---

## Adding services

A service must join `traefik_public` and carry labels under `deploy:` — the
`swarm` provider reads `deploy.labels`, not container labels:

```yaml
networks: [traefik_public]
deploy:
  labels:
    - "traefik.enable=true"
    - "traefik.swarm.network=traefik_public"
    - "traefik.http.routers.NAME.rule=Host(`sub.your.domain`)"
    - "traefik.http.routers.NAME.entrypoints=websecure"
    - "traefik.http.services.NAME.loadbalancer.server.port=PORT"
```

Certificates are automatic — the `websecure` entrypoint already sets the
resolver and wildcard, so **don't add `tls.certresolver`** to individual
routers.

---

## Things that are easy to miss

### The ACME IP pin (IPv6)

The ACME endpoint publishes both A and AAAA records. Where IPv6 is unreliable,
lego can dial the AAAA and fail with `connect: network is unreachable` /
`cannot assign requested address`. Disabling IPv6 inside the container is
**not sufficient** — Go still chooses the AAAA.

The fix: `extra_hosts` in `traefik-stack.yml` pins the endpoint to its IPv4
address (Go's resolver reads `/etc/hosts` before DNS, so the AAAA is never
seen).

> **If certificate renewal ever fails, check this first.**
> ```bash
> dig +short A acme-v02.api.letsencrypt.org
> ```
> If the address changed, update `extra_hosts` and redeploy.
> `./check.sh` compares the pin against live DNS automatically.

This becomes unnecessary once Traefik ships lego v5, which can select a network
stack natively (`traefik#13302`).

### Docker configs are immutable

After editing `tls.yml` you **must bump** `name:` in the `configs:` section
(`traefik_tls_config_v4` → `_v5`). Without that, `docker stack deploy` silently
keeps serving the old content.

### Renewal

Traefik renews automatically 30 days before expiry and writes to `acme.json`.
No cron, no restart. The mail stack watches the same file and reloads
Postfix/Dovecot itself.

### cloudflared does not carry mail

The tunnel handles HTTP/HTTPS only. SMTP/IMAP/POP3 **will not pass** through
Cloudflare (except via Spectrum on an Enterprise plan). That's why the mail
stack receives through Email Routing + a Worker rather than the tunnel.

---

## Monitoring

`check.sh` only helps if something runs it. It is executed hourly by
`monitor.sh` in the **mail** repo, which emails you on any state change and
pings a dead-man's switch so that silence is also an alarm.

```cron
0 * * * * /path/to/mail/monitor.sh >/dev/null 2>&1
```

For Traefik specifically this catches the failure that would otherwise go
unnoticed for weeks: the **ACME IP pin drifting out of date**, which stops
certificate renewal silently until the certificate expires and both web and
mail TLS break at once.

See *Monitoring and alerts* in the mail repo README for setup and testing.
If you run this stack without the mail repo, add the equivalent yourself:

```cron
0 * * * * /path/to/traefik/check.sh || <notify-me-somehow>
```

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| "No ACME certificate generation required" | `defaultCertificate` in `tls.yml` covers the same domains — remove it |
| `network is unreachable` / `cannot assign requested address` | ACME IP pin is stale |
| `tls.yml` change has no effect | config `name:` wasn't bumped |
| 502 from Cloudflare | Traefik is serving its self-signed cert (no certificate) |
| New service returns 404 | not on `traefik_public`, or labels aren't under `deploy:` |

```bash
docker service logs -f traefik_traefik      # logs
./check.sh                                  # full diagnostic
```
