# Portfolio-scoped multi-source news

## Personalization

News is always scoped to symbols the user **holds** (`stocks`) or **actively watches** (`watchlist_items` with status ≠ `archived`).

| Path | Behavior |
|------|----------|
| `POST /v1/news/sync` | Per user: fetch only their tracked symbols → upsert `news_items` |
| `GET /v1/news/feed` | Per user: list `news_items` for tracked symbols only |
| `NewsSyncJob` (background) | Global union of all tracked symbols → fetch once → fan out to users who track each symbol |
| `GET /v1/market/news?symbol=` | Shared `market_news_archive` (symbol-scoped, TTL) |

Example: user A holds AMD+NVDA and user B holds HIMS+OSCR. A never receives HIMS/OSCR rows; B never receives AMD/NVDA rows.

## Providers

Configured via `NEWS_PROVIDERS` (comma-separated). Default: `finnhub`.

| Value | Requirements | Notes |
|-------|--------------|--------|
| `finnhub` | `FINNHUB_API_KEY` | Company news API (primary) |
| `jsonfeed` (aliases `rss`, `yahoo`, `yahoo_rss`) | `FEEDS_BASE_URL` (cluster feed aggregator), `NEWS_TICKER_FEEDS`, optional `NEWS_SYMBOL_FEED_TEMPLATE` with `{symbol}` | Reads JSON Feed 1.1 from the shared aggregator, which does the RSS/Atom parsing. Never parses XML here. |

Optional RSS env:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FEEDS_BASE_URL` | _(empty = jsonfeed + ticker disabled)_ | `http://feeds.horus.svc.cluster.local:8080` in the cluster; see `platform/infra/docs/feeds.md` |
| `NEWS_TICKER_FEEDS` | _(empty)_ | Comma-separated curated feed URLs for `fetchGeneral` and the breaking-news ticker |
| `NEWS_SYMBOL_FEED_TEMPLATE` | _(empty = per-symbol disabled)_ | e.g. `https://feeds.finance.yahoo.com/rss/2.0/headline?s={symbol}&region=US&lang=en-US` |
| `NEWS_RSS_MAX_ARTICLES_PER_SYMBOL` | `15` | Cap per symbol per sync |

Multiple providers are merged by `CompositeNewsProvider` (soft-fail per child, dedupe by URL).

## Background job

| Variable | Default | Purpose |
|----------|---------|---------|
| `NEWS_SYNC_JOB_ENABLED` | `true` | Set `false` to skip scheduling |
| `NEWS_SYNC_INTERVAL_SECONDS` | `900` | Tick interval (min 60) |
| `NEWS_SYNC_MAX_SYMBOLS` | `100` | Cap global symbol set (ranked by holder count) |

## Explicit non-goals

- **No HTML scraping** of Seeking Alpha or Investing.com (ToS; see `MacroEnrichmentStubs.swift`).
- Full article body storage is out of scope — headline, summary, source, URL only.
- Seeking Alpha / Investing.com articles may still appear when a licensed aggregator (e.g. Finnhub) returns them with that publisher as `source`.

## Client surfaces (unchanged)

- iOS: portfolio news + stock detail news tab
- Web: `/portfolio/news` + stock news tab
- Pull-to-refresh should call `POST /v1/news/sync`; background job keeps feeds warm without app open

## Breaking-news ticker

`GET /v1/news/ticker` serves curated feeds (`NEWS_TICKER_FEEDS`) plus the
user's own subscriptions (`/v1/news/ticker/feeds`, discovered through the
aggregator's `POST /v1/discover`, max 10 per user) in one aggregator call,
cached 60 s per distinct feed set. `PUT /v1/news/ticker/settings` is the
per-user switch. Headlines only: title, source, time, link. No bodies.

Suggested curated list (verify each through `POST /v1/discover` before
enabling; keep it in config, not code): CNBC Top News and Finance, MarketWatch
Top Stories and Market Pulse, Federal Reserve press releases, ECB press, SEC
press releases, CoinDesk, Yahoo Finance, a Google News finance query. Reuters
and Bloomberg have no public RSS. FT's home feed is keyless but read the terms
before enabling.
