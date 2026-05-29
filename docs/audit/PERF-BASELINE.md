# Performance Baseline

Re-run `./scripts/perf/run.sh` and update this table. Compare new runs against the
last committed baseline to catch regressions.

| Run date | Commit | Notes |
|----------|--------|-------|
| _pending_ | _—_ | No baseline captured yet. Run the playbook §1–§2. |

## Server — endpoint latency (from k6)

| Endpoint | VUs | RPS | p50 (ms) | p95 (ms) | p99 (ms) | error % |
|----------|-----|-----|----------|----------|----------|---------|
| `GET /health` | | | | | | |
| `GET /api/hello` | | | | | | |
| `POST /auth/login` | | | | | | |
| `GET /crypto/quote/:symbol` (cache hit) | | | | | | |
| `GET /crypto/quote/:symbol` (cache miss) | | | | | | |
| `GET /statistics/stocks` | | | | | | |
| `GET /expenses` | | | | | | |

## Server — top slow queries (pg_stat_statements)

| Rank | total_ms | mean_ms | calls | query (truncated) | N+1? |
|------|----------|---------|-------|-------------------|------|
| 1 | | | | | |

## Server — resource notes

- Fluent pool size: _(current / tuned)_
- Redis cache hit ratio under load: _%_
- Peak sustained RPS before p95 > 400ms: _—_

## Client — iOS (from Instruments)

| Metric | Value | Target |
|--------|-------|--------|
| Cold launch (s) | | < 2.0 |
| Warm launch (s) | | < 1.0 |
| Dashboard time-to-interactive (s) | | < 1.5 |
| Scroll hitches (main feed) | | 0 |
| Largest main-thread stall (ms) | | < 100 |
