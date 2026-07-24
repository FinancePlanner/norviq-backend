# Hermes pipeline — audited state (2026-07-23)

Ground truth from the live VPS + production cluster, superseding stale notes
in older docs. Read this first when the insights pipeline misbehaves.

## Topology

```
hermes VPS (tailscale hostname: hermes-vps-2)
  ├─ hermes agent (own cron scheduler, ~/.hermes/cron/jobs.json, runs as root)
  │    └─ ticker/topic scrape jobs → JSON drops in
  │       /root/.hermes/financial-pipeline/inbox/ → ingest → finance.sqlite
  ├─ finance-api.service (systemd): finance_api_server.py
  │    binds the tailnet IP, port 8780 — serves /finance/*
  └─ hermes-gateway.service (messaging platform integration)

production k8s (tailscale hostname: stockplan-backend)
  └─ api pod: HermesSyncJob every 15 min pulls /finance/events, /summary,
     /sentiment, /net-worth, /ticker/{sym}/posts → Postgres.
     iOS/web read Postgres only; hermes is never on the request path.
```

## Scheduling — what actually runs

- The systemd timers from `deploy-ticker-scraper.sh`
  (`hermes-ticker-scraper.timer`, `hermes-topic-ingest.timer`) **do not exist
  on the rebuilt VPS**. Scheduling moved to the hermes agent's internal cron
  (`~/.hermes/cron/jobs.json`, executions in `executions.db`); jobs run as
  root and touch `ticker_heartbeat` / `ticker_last_success` in
  `~/.hermes/cron/` on success. Do not "fix" the missing timers — they were
  replaced, not lost. `setup-hermes-agent-jobs.sh` is the current source of
  job definitions.
- Cadence (2026-07-23 decision): keep as-is — ticker scrape roughly hourly,
  topic ingest daily.

## Access

- VPS access details (SSH host/user) live in the private ops notes, not in
  this public repo. Pipeline data lives under
  `/root/.hermes/financial-pipeline/` (root-owned; use sudo).
- The scraper's API key lives only in the VPS env file — it is not in any
  k8s secret. Keep it funded; there is no infra-managed backup.

## The 2026-07 outage (why this doc exists)

Symptom: `/health/ready` → `hermes: "Hermes sync has not completed yet"`,
api logs `hermes_sync failed error=HTTPClientError.connectTimeout` every
15 min; insights stale.

Cause: VPS rebuilds re-register Tailscale and get a NEW 100.x address; the
sealed `HERMES_BASE_URL` still pointed at the previous, now-dead address.

Fix (norviq-infra PR #29): CoreDNS on the cluster now forwards
`tail562587.ts.net` to the Tailscale resolver (`cluster/coredns/custom.yaml`),
and `HERMES_BASE_URL` is sealed as
`http://hermes-vps-2.tail562587.ts.net:8780`.

**Constraint**: rebuilds must re-join the tailnet under the same hostname
(`hermes-vps-2`) or the MagicDNS name changes and prod breaks again. If DNS
ever fails from pods, the stopgap is resealing `HERMES_BASE_URL` with the
current raw tailnet IP (`tailscale ip -4` on the VPS).

## Health checks

```bash
# end-to-end (public):
curl -s https://api.norviq.org/health/ready | jq .checks.hermes

# VPS side:
ssh <hermes-vps> 'systemctl is-active finance-api hermes-gateway; \
  sudo ls -lat /root/.hermes/financial-pipeline/inbox | head -5; \
  sudo cat ~/.hermes/cron/ticker_last_success'

# cluster side:
kubectl logs -n production deploy/api --since=1h | grep hermes_sync
```

Healthy looks like: `hermes_sync ok events=… snapshots=… ticker_posts=…`
every 15 min, inbox files younger than ~2 h, readiness `healthy`.

Note: inbox drops of `{"tickers":[]}` mean the scraper had no tracked
symbols to target — expected while backend sync is down (the tracked-symbols
feed comes from the backend); should self-heal once sync is green.
