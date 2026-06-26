# Market Data Caching Documentation

## Overview
To optimize API usage, reduce latency, and improve system reliability, a multi-layer caching strategy is implemented for high-volume financial data endpoints. This is particularly important for FMP-backed data where free-tier limits and relatively static update frequencies (daily/quarterly) make caching highly effective.

## Affected Endpoints
The following endpoints now benefit from both Redis (Hot) and Postgres (Cold) caching:
- `GET /v1/market/analyst-estimates/{symbol}`
- `GET /v1/market/financial-growth/{symbol}`
- `GET /v1/market/ratios-ttm/{symbol}`
- `GET /v1/market/ratios/{symbol}`

## Multi-Layer Architecture

### 1. Hot Cache (Redis)
- **Purpose:** Sub-millisecond retrieval for active sessions.
- **Implementation:** Data is stored as serialized JSON strings.
- **TTL:** Controlled by `MARKET_TTL_FMP_SECONDS` (default: 24 hours).
- **Key Pattern:** `market:{endpoint}:fmp:{symbol}:{params...}`
  - *Example:* `market:analyst-estimates:fmp:AAPL:annual`

### 2. Cold Cache (Postgres)
- **Purpose:** Persistent storage and source for the hot cache.
- **Implementation:** Dedicated cache tables storing the full provider payload.
- **Schema Tables:**
  - `analyst_estimates_cache`: Keys on `(provider, symbol, period)`.
  - `financial_growth_cache`: Keys on `(provider, symbol, period, limit)`.
  - `ratios_ttm_cache`: Keys on `(provider, symbol)`.
  - `ratios_cache`: Keys on `(provider, symbol, period, limit)`.
- **Validation:** Records are considered "fresh" if `updated_at` is within the configured TTL.

## Request Lifecycle
1. **Redis Search:** If a fresh key exists in Redis, it is returned immediately.
2. **Database Search:** If Redis misses, the system checks the corresponding Postgres table.
   - If a record is found and is **fresh**, it populates Redis and returns.
3. **Upstream Fetch:** If both caches miss or data is stale, a live request is made to the provider (FMP).
4. **Cache Upsert:** On a successful live fetch, the data is saved to Postgres and cached in Redis simultaneously.
5. **Stale Fallback:** If the live fetch fails (e.g., API timeout or limit reached), the system will return the most recent data from the Postgres cache (even if stale) as a fallback, logging a warning.

## Configuration
Caching behavior is tuned via environment variables in `MarketDataCacheConfig`:

| Variable | Description | Default |
| :--- | :--- | :--- |
| `MARKET_TTL_FMP_SECONDS` | TTL for FMP-backed analyst, growth, and ratio data. | `86400` (24h) |
| `MARKET_TTL_QUOTE_SECONDS` | TTL for stock quotes (price + change/percentChange from Finnhub). Short TTL enables "live" polling UIs. | `20` |
| `MARKET_TTL_HISTORY_SECONDS` | TTL for historical price bars. | `86400` (24h) |
| `REDIS_URL` | Redis connection string (required for Hot Cache). | N/A |

**Live prices note:** `QuoteResponse` (and `/v1/market/quote` + batch) already returns `currentPrice`, `change`, `percentChange`, and `timestamp`. Clients can poll the batch endpoint frequently (or use WS in future) to achieve updating ticker-style displays across portfolio lists, watchlists, and details. See iOS PortfolioViewModel + PortfolioRow for example enrichment.

## Data Integrity
To ensure specific requests (e.g., Annual vs Quarterly ratios) do not collide, cache keys and database unique constraints incorporate query parameters:
- **Period-aware:** Different periods (Annual, Quarter, FY) are cached independently.
- **Limit-aware:** Requests for different row limits are cached as separate entries to maintain payload accuracy.
