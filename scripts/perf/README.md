# Performance / load testing (k6)

Drives the **local Docker** stack (`docker-compose.yml`, app on `localhost:8090`).
Used to populate `docs/audit/PERF-BASELINE.md` and to size the DB pool.

## Prereqs

```bash
brew install k6
# Start the stack with slow-query visibility (see docker-compose.perf.yml):
docker compose -f docker-compose.yml -f docker-compose.perf.yml up -d --build
docker compose run --rm migrate   # apply migrations
```

## Run

```bash
# All scenarios, default target localhost:8090
./scripts/perf/run.sh

# Override target / load
BASE_URL=http://localhost:8090 VUS=50 DURATION=2m ./scripts/perf/run.sh
```

Each scenario writes a JSON summary to `scripts/perf/out/`. Copy the headline
numbers (p50/p95/p99, RPS, error rate) into `docs/audit/PERF-BASELINE.md`.

## Scenarios

| File | What it exercises |
|------|-------------------|
| `smoke.js` | Public/unauthenticated: `/health`, `/health/ready`, `/api/hello`. Sanity + middleware overhead floor. |
| `auth_flow.js` | `POST /auth/register` + `POST /auth/login`. Measures bcrypt + JWT cost and the auth rate limiter. |
| `api_load.js` | Token-driven protected endpoints: crypto quote (cache hit/miss), statistics, expenses, dashboard aggregate. The real capacity test. |

## Reading slow queries (after a load run)

```bash
docker compose exec db psql -U stockplan_user -d stockplan_dev \
  -c "SELECT calls, round(total_exec_time::numeric,1) AS total_ms, \
      round(mean_exec_time::numeric,2) AS mean_ms, query \
      FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 15;"
```

High `calls` with low `mean_ms` on near-identical queries = N+1. Cross-check the
suspected loops in `Portfolio/PortfolioController`, `Statistics/StatisticsRepository`.
`auto_explain` plans land in the db container logs (`docker compose logs db`).
