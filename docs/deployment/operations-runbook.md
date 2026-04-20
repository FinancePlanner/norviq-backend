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
BACKUP="stockplan_$(date +%Y%m%d_%H%M%S).sql"
docker compose -f docker-compose.production.yml exec -T db \
  pg_dump -U "${DATABASE_USERNAME:-stockplan_user}" "${DATABASE_NAME:-stockplan_prod}" > "${BACKUP}"
gpg --symmetric --cipher-algo AES256 "${BACKUP}"
rm -f "${BACKUP}"
```

Retention baseline:

- Daily encrypted backups: 14 days.
- Weekly encrypted backups: 8 weeks.
- Monthly encrypted backups: 12 months.

Run a restore drill before launch and quarterly:

```bash
gpg --decrypt stockplan_YYYYMMDD_HHMMSS.sql.gpg > restore.sql
cat restore.sql | docker compose -f docker-compose.production.yml exec -T db \
  psql -U "${DATABASE_USERNAME:-stockplan_user}" "${DATABASE_NAME:-stockplan_prod}"
rm -f restore.sql
```

Do not test restores against production unless performing an incident recovery.
