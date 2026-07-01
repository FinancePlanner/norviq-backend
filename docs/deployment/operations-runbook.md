# Operations Runbook (Health, Rollback, Retention)

This runbook covers production operations hardening for the Docker Compose runtime on Hetzner.

## Health gate checks

Validate the API from the server host:

```bash
./scripts/ops/check_health.sh api.stockplan.app
```

or:

```bash
make health DOMAIN=api.stockplan.app
```

The health script checks `/health/ready` first and falls back to `/health` for rollback compatibility with older images.

Expected endpoints:

- `/health`: liveness-compatible legacy endpoint, returns `{"status":"ok"}`.
- `/health/live`: liveness endpoint with no dependency checks.
- `/health/ready`: readiness endpoint with database, Redis, mailer, APNS, and market-data configuration checks.

Before launch and after material production changes, run the full preflight:

```bash
./scripts/ops/production_preflight.sh api.stockplan.app https://www.norviqaapp.com
```

Record the output in the release notes. A passing preflight confirms health, request IDs, production CORS, reverse-proxy security headers, private DB/Redis port exposure, and JSON log shape.

## Edge protocol checks

The public Norviq edge terminates TLS, HTTP/2, and HTTP/3 in the Dockerized gateway Nginx container. Backend app containers continue to speak plain HTTP/1.1 behind the proxy.

Current production shape:

- Gateway container: `gateway-nginx-1`
- Gateway image: `nginx:1.27-alpine`
- Config path: `/opt/gateway/nginx/nginx.conf`
- Public ports: `443/tcp` for HTTPS and HTTP/2, `443/udp` for HTTP/3/QUIC
- API hosts: `api.norviq.org`, `api.norviqa.io`
- Web hosts: `norviq.org`, `www.norviq.org`

Nginx should be built with HTTP/3 support and should listen on QUIC:

```bash
docker exec gateway-nginx-1 nginx -V 2>&1 | grep -- --with-http_v3_module
docker exec gateway-nginx-1 nginx -T 2>/dev/null | grep -Ei 'listen 443|http2 on|quic|Alt-Svc'
ss -ulnp | grep ':443'
ufw status verbose | grep '443/udp'
```

The API block should use modern HTTP/2 syntax:

```nginx
listen 443 quic;
listen 443 ssl;
http2 on;
```

Do not use deprecated `listen 443 ssl http2;` in new gateway config.

The gateway access log should include the negotiated protocol and HTTP/3 marker so operators can distinguish TCP HTTP/2 traffic from QUIC HTTP/3 traffic:

```nginx
log_format edge '$remote_addr - $remote_user [$time_local] $request '
                '$status $body_bytes_sent $http_referer $http_user_agent '
                'host=$host proto=$server_protocol http3=$http3 '
                'request_time=$request_time upstream=$upstream_addr '
                'upstream_status=$upstream_status upstream_time=$upstream_response_time';
access_log /var/log/nginx/access.log edge;
```

Expected log markers are `proto=HTTP/2.0 http3=` for HTTP/2 and `proto=HTTP/3.0 http3=h3` for HTTP/3.

Verify external protocol negotiation after gateway changes:

```bash
curl -sS -o /dev/null \
  -w 'api h2 probe http=%{http_code} version=%{http_version}\n' \
  https://api.norviq.org/health/live

/usr/local/bin/curl-http3 --http3-only -sS -o /dev/null \
  -w 'api h3 probe http=%{http_code} version=%{http_version}\n' \
  https://api.norviq.org/health/live
```

Expected output:

```text
api h2 probe http=200 version=2
api h3 probe http=200 version=3
```

The VPS has `/usr/local/bin/curl-http3`, a Docker-backed wrapper around `alpine/curl-http3:latest`. It exists so operators can force an HTTP/3-only request without replacing the system curl.

## Fast rollback to previous image

Roll back app service to a previous immutable image tag:

```bash
./scripts/ops/rollback_app_image.sh ghcr.io/<owner>/StockPlanBackend:<previous_sha>
```

or:

```bash
make rollback-app APP_IMAGE=ghcr.io/<owner>/StockPlanBackend:<previous_sha>
```

The rollback script updates `.env` (`APP_IMAGE=`), restarts app, and validates `/health`.

## Image cleanup policy

Prune stale server images/layers older than 7 days:

```bash
./scripts/ops/prune_images.sh 168h
```

or:

```bash
make prune-images UNTIL=168h
```

## GHCR retention policy

In GHCR package settings:

1. Keep immutable SHA tags for rollback history.
2. Apply retention to untagged/stale images.
3. Keep `latest` plus recent SHA tags (for example last 30-60 releases).

## Suggested cron on Hetzner host

Run weekly cleanup (example Sunday at 03:15):

```bash
15 3 * * 0 cd ~/StockPlanBackend && ./scripts/ops/prune_images.sh 168h >> /var/log/stockplan-prune.log 2>&1
```

## PostgreSQL backup policy

Create an encrypted backup from the server:

```bash
./scripts/ops/backup_postgres.sh
```

Retention baseline:

- Daily encrypted backups: 14 days.
- Weekly encrypted backups: 8 weeks.
- Monthly encrypted backups: 12 months.

Run a restore drill before launch and quarterly:

```bash
RESTORE_DATABASE_URL=postgres://restore_user:restore_password@restore-host:5432/stockplan_restore \
  ./scripts/ops/restore_drill_postgres.sh backups/stockplan_YYYYMMDD_HHMMSS.sql.gpg
```

Do not test restores against production unless performing an incident recovery.

Restore drill records are appended to `backups/restore-drills.log` with the backup name, target database, operator, result, and basic row-count sanity checks.

Apply retention cleanup with:

```bash
./scripts/ops/backup_retention.sh
```

## Manual user data export

For launch, data export is a support workflow, not a public API:

```bash
DATABASE_URL=postgres://stockplan_user:...@127.0.0.1:5432/stockplan_prod \
  ./scripts/ops/export_user_data.sh user@example.com
```

The export script creates JSONL files for user-owned records, excludes operational secrets, redacts raw billing webhook payloads, and writes a `SHA256SUMS` file for delivery verification.
