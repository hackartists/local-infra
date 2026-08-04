# Mail (Postal) on k3s — mail.biyard.co

Self-hosted SES replacement. Outbound sends directly from the home IP;
inbound flows MX → Postal → HTTP webhook → Redpanda topic `postal.inbound`.

```
outbound: app → Postal (API/SMTP) → worker → internet:25   (egress = home IP)
inbound:  internet → router TCP 25 → 192.168.0.54 (hostPort) → postal-smtp
          → route *@mail.biyard.co → HTTP endpoint
          → mail-bridge (Redpanda Connect, :4195/inbound) → topic postal.inbound
web UI:   https://postal.dev.biyard.co  (k3s ingress, dev-biyard-co-tls)
```

Charts: `k8s/charts/postal` (MariaDB + web/smtp/worker + init Job),
`k8s/charts/mail-bridge`. Both are helmfile releases in ns `infra`, pinned to
`lima-k3s-server` (postal only; bridge floats).

## Credentials

- Admin UI login: `hackartists@gmail.com` / `kubectl -n infra get secret
  postal-secrets -o jsonpath='{.data.admin-password}' | base64 -d`
- App credentials (org `biyard`, server `main`): Secret
  `postal-app-credentials` — `smtp-user`(=`main/smtp`), `smtp-password`,
  `api-key`.
  - SMTP submission: `mail.biyard.co:25` from outside, or
    `192.168.0.54:25` in-LAN (AUTH PLAIN/LOGIN/CRAM-MD5).
  - HTTP API: `POST https://postal.dev.biyard.co/api/v1/send/message` with
    header `X-Server-API-Key: <api-key>`.

## Consuming inbound mail

Events are JSON (Postal HTTPEndpoint format `Hash`, attachments included):
`id, rcpt_to, mail_from, subject, message_id, timestamp, spam_status,
plain_body, html_body, attachments[], …`

```bash
kubectl -n infra exec redpanda-0 -c redpanda -- rpk topic consume postal.inbound --offset start
```

In-cluster consumers use brokers `redpanda-0.redpanda.infra.svc.cluster.local:9093`.

## Fresh-bootstrap secrets (imperative, never committed)

```bash
kubectl -n infra create secret generic postal-secrets \
  --from-literal=db-password="$(openssl rand -hex 16)" \
  --from-literal=mariadb-root-password="$(openssl rand -hex 16)" \
  --from-literal=rails-secret-key="$(openssl rand -hex 64)" \
  --from-literal=admin-password="$(openssl rand -base64 12 | tr -d '=+/')" \
  --from-file=signing.key=<(openssl genrsa 2048)
```

After a truly fresh install (empty DBs) also rerun: `postal make-user`
(admin), and the one-time setup script (org/server/domain/endpoint/route/
credentials — see `docs/superpowers/specs/2026-08-04-postal-mail-design.md`;
the setup was done via `rails runner`, model constants:
route mode `Endpoint`, endpoint encoding `BodyAsJSON` format `Hash`).
A new domain generates a new DKIM key ⇒ update the DKIM TXT record.
`postal-app-credentials` must then be recreated with the new keys.

## arm64 image build (official images are amd64-only)

```bash
git clone https://github.com/postalserver/postal <dir> && git -C <dir> checkout 3.3.7
docker --context lima-docker build -t postal:3.3.7-arm64 <dir>
docker --context lima-docker save postal:3.3.7-arm64 | \
  limactl shell k3s-server -- sudo k3s ctr images import -
```

Bump the tag in `charts/postal/values.yaml` on upgrades.

## DNS (Route53, biyard.co zone Z01931081NPCG088QNZXX)

| name | type | value |
|---|---|---|
| mail.biyard.co | A | 121.131.101.30 (home public IP) |
| mail.biyard.co | MX | `10 mail.biyard.co` |
| mail.biyard.co | TXT | `v=spf1 a mx include:spf.mail.biyard.co ~all` |
| spf.mail.biyard.co | TXT | `v=spf1 ip4:121.131.101.30 ~all` |
| rp.mail.biyard.co | A / MX / TXT(SPF) | same IP / `10 mail.biyard.co` / same SPF |
| psrp.mail.biyard.co | CNAME | rp.mail.biyard.co |
| _dmarc.mail.biyard.co | TXT | `v=DMARC1; p=none` |
| postal-IrnGRS._domainkey.mail.biyard.co | TXT | DKIM public key (from Postal) |

**Home IP change runbook:** update the A records (mail, rp) and the
`spf.mail.biyard.co` TXT ip4:, using the cert-manager Route53 creds
(`kubectl -n cert-manager get secret route53-credentials`). MX targets must
stay A records (no CNAME/DDNS). Then re-run the DNS check:
Postal UI → domain → "Check my records" (or `domain.check_dns(:manual)`).

Router must forward **TCP 25 → 192.168.0.54** (alongside 80/443/1194).

## Gotchas (paid for in blood)

- **Postal SSRF guard**: webhook deliveries to private IPs fail with
  "Destination … is not permitted" unless the host is listed in
  `postal.allowed_request_destinations` (values.yaml
  `allowedRequestDestinations`, includes `mail-bridge.infra.svc`).
- **Rails host authorization** 403s any request whose Host header isn't
  `postal.dev.biyard.co` — readiness probes must send the Host header.
- **Redpanda Connect** service HTTP (:4195, /ping) and the `http_server`
  input share one listener — do NOT set an explicit `address` on the input
  or it fails to bind.
- smtp container listens on 2525; hostPort 25 maps to it (no root needed).
- Deliverability: residential IP without PTR ⇒ large providers may
  spam-folder direct outbound. SPF/DKIM/DMARC all pass; if it ever hurts,
  configure an SMTP relay per-server in Postal (Mail Server → Settings)
  without redeploying.

## Rollback

```bash
helmfile -f k8s/helmfile.yaml destroy -l name=postal
helmfile -f k8s/helmfile.yaml destroy -l name=mail-bridge
```

Remove the router TCP 25 rule and delete the DNS records in the table above
(PVCs `postal-mariadb-data` and the topic remain until deleted explicitly).
