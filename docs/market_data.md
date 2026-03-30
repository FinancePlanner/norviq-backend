# Market Data and Caching Plan (MVP)

Goal
- Replace placeholder market endpoints with real provider-backed data and predictable caching.
- Keep existing API response shapes in `MarketDataDTOs` unchanged.

Current state
- `GET /quote/:symbol` returns placeholder values.
- `GET /history/:symbol` returns empty bars.
- `GET /search` returns empty array.
- `GET /fx` returns fixed `1.0`.

Reference
- `Sources/StockPlanBackend/Market/MarketDataController.swift`
- `Sources/StockPlanBackend/Market/MarketDataDTOs.swift`

## 1) Provider contract (normalize once)

Create a single provider interface for:
- `quote(symbol)`
- `history(symbol, from, to)`
- `search(query)`
- `fx(base, quote)`

Rules
- Pick one provider first (MVP): avoid multi-provider complexity.
- Normalize provider fields to internal domain models, then map to existing API DTOs.
- Keep currency and timestamps explicit (`asOf`, bar date).

## 2) Service layer (controller stays thin)

Add `MarketDataService` between controller and provider:
1. Validate and normalize input (`symbol`, `q`, `pair`).
2. Try cache lookup.
3. On cache miss or stale data, call provider.
4. Persist refreshed values to cache.
5. Return DTO response.

Controller responsibility
- Parse request params only.
- Call service.
- Return DTO.

## 3) Caching model (Postgres first)

MVP cache backend
- Use Postgres first (already in stack and Docker setup).
- Add dedicated quote/search cache tables.
- Reuse `price_history` for daily bars if it matches your provider semantics.

Existing related table
- `price_history` exists with unique `(symbol, date)` and index on `(symbol, date)`.

## 4) Cache key mapping and indexes

Use explicit key mapping so reads are fast and predictable:

Quote cache
- Key: `(provider, symbol)`
- Unique: `(provider, symbol)`
- Index: `(provider, symbol, as_of)`

History cache
- Key: `(provider, symbol, date)`
- Unique: `(provider, symbol, date)`
- Index: `(provider, symbol, date)`

Search cache
- Key: `(provider, normalized_query)`
- Unique: `(provider, normalized_query)`
- Index: `(provider, normalized_query, updated_at)`

FX cache
- Key: `(provider, base, quote, date)`
- Unique: `(provider, base, quote, date)`
- Index: `(provider, base, quote, date)`

Naming convention
- Use migration index names like:
  - `idx_quote_cache_provider_symbol_as_of`
  - `idx_history_cache_provider_symbol_date`
  - `idx_search_cache_provider_query_updated_at`
  - `idx_fx_cache_provider_base_quote_date`

## 5) Freshness policy (TTL)

Start simple, then tune:
- Quotes: 15-30 seconds during market hours, 60-300 seconds outside market hours.
- History daily bars: refresh only missing dates or current trading day.
- Search: 1-24 hours.
- FX daily rates: 1 day for EOD rates; shorter for intraday provider.

## 6) Failure strategy

Behavior
- If provider fails and stale cache exists: return stale cache with metadata/log marker.
- If provider fails and no cache exists: return `503 Service Unavailable`.

Validation
- Reject invalid symbol/query/pair early with `400`.
- Enforce provider timeout and bounded retries.

## 7) Config you will need

Environment variables (example set)
- `MARKET_PROVIDER`
- `FINNHUB_API_KEY`
- `FINNHUB_WEBHOOK_URL`
- `FINNHUB_WEBHOOK_SECRET`
- `IBKR_API_BASE_URL`
- `MARKET_TIMEOUT_MS`
- `MARKET_RETRY_COUNT`
- `MARKET_TTL_QUOTE_SECONDS`
- `MARKET_TTL_HISTORY_SECONDS`
- `MARKET_TTL_SEARCH_SECONDS`
- `MARKET_TTL_FX_SECONDS`

## 8) Observability and tests

Logs/metrics to emit
- `provider`, `symbol`, `endpoint`, `cache_hit`, `stale`, `latency_ms`, `status`.

Tests to add
- Cache hit returns without provider call.
- Cache miss fetches provider then stores cache.
- Stale cache fallback on provider failure.
- Invalid input returns `400`.
- Provider hard failure with empty cache returns `503`.

## 9) Suggested implementation order

1. Quote endpoint with cache.
2. Search endpoint with cache.
3. History endpoint with DB upsert strategy.
4. FX endpoint.
5. Background refresh jobs (optional post-MVP).

## 10) Archive-backed endpoints

The backend now exposes DB-backed archive routes in addition to the compatibility routes used by the iOS app.

History
- `GET /v1/market/history` reads through the backend cache and may call the upstream provider on stale/miss.
- `GET /v1/market/history/archive` reads only archived bars already stored in Postgres.
- `POST /v1/market/history/archive/sync` fetches from the provider, upserts into `price_history`, and returns the archived result.

News
- `GET /v1/market/news` reads through the shared market news archive and refreshes it on stale/miss.
- `GET /v1/market/news/archive` reads only archived news already stored in Postgres.
- `POST /v1/market/news/archive/sync` fetches from the provider, upserts into `market_news_archive`, and returns the archived result.

Why this shape
- Compatibility routes keep the existing iOS client working.
- Archive routes make persistence explicit for admin jobs, backfills, reports, and deterministic reads.
- Shared storage means repeated requests across users do not re-hit Finnhub unnecessarily.

## Redis in Docker Compose and costs

Yes, you can run Redis in your `docker-compose.yml` with no separate managed service fee.

What "no extra cost" means
- Local development: no extra cloud cost, only local machine resources.
- Single VPS (e.g. Hetzner): no extra vendor line item, but Redis uses RAM/CPU; if memory is tight you may need a bigger VPS plan.
- Managed Redis (AWS/Upstash/etc.): extra monthly cost.

Practical recommendation
- MVP: start with Postgres cache only.
- Add Redis when latency or provider call volume justifies it.
