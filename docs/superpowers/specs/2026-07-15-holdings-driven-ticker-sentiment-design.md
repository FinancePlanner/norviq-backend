# Holdings/Watchlist-Driven X Ticker Sentiment — Design

Status: approved design, pre-implementation. Date: 2026-07-15.
Repos: `norviq-backend` (Swift/Vapor), `norviq-ios` (SwiftUI), `norviq-web` (Go/templ), Hermes VPS.

## Context

The Hermes insights pipeline is live end-to-end: the VPS scrapes X for ticker sentiment (SuperGrok agent), the backend polls it over Tailscale into `ticker_sentiment_posts`, and `GET /v1/insights/tickers/{symbol}/sentiment` serves it. But two gaps make it not-yet-a-feature:

1. **No client UI** — nothing renders the sentiment; users never see it.
2. **Static symbol list** — only `AMD,NVDA,AAPL` (a hardcoded env) are ever scraped. A user holding anything else gets nothing.

This spec closes both: the scraped set becomes the union of what users actually hold/watch (cost-capped), and iOS + web get a Pro-gated "Sentiment" tab on the stock detail screen.

## Decisions (locked)

- **Cost cap:** scrape the **top-N most-popular equities** (by count of distinct users holding/watching), N configurable, default 25. Bounds SuperGrok cost predictably on the $35 plan.
- **Gating:** the sentiment tab is **Pro-only** (like analysis/forecast).
- **Scope:** backend + iOS + web this build (web includes OpenAPI client regen).
- **Equities only** for v1 — the X scraper prompt is stock-thesis oriented; crypto sentiment is out of scope.
- **Reads are Postgres-only** — Hermes downtime yields stale-but-served data, never a client error. (Unchanged from current architecture.)

## Architecture & Data Flow

```
users' stocks ∪ watchlist_items (status != 'archived'), category = equity
   │  DISTINCT symbol, ranked by user-count, capped at N
   ▼
backend: InsightsRepository.allTrackedSymbols(limit:)
   │
   ├─► GET /v1/insights/tracked-symbols  (machine bearer, tailnet-only, fail-closed)
   │      ▼
   │   Hermes ticker cron: fetch list → write scraper_config.json → scrape X (SuperGrok)
   │      ▼
   │   SQLite → finance-api (tailnet) → backend poller
   │
   └─► syncTickerPosts (poller): same allTrackedSymbols(limit:) → per-symbol pull → ticker_sentiment_posts
        ▼
GET /v1/insights/tickers/{symbol}/sentiment  (Pro, scoped .insightsRead)
        ▼
iOS Sentiment tab  +  web Sentiment tab
```

A symbol only has data once it enters the top-N. Tapping one outside the set → 200 with empty `posts` → "no sentiment yet" empty state.

## Components

### Backend (`norviq-backend/Sources/StockPlanBackend/`)

- **`Insights/InsightsRepository.swift`** — new `allTrackedSymbols(limit: Int, on db) -> [String]`. `DISTINCT symbol` from `stocks` (holdings) ∪ `watchlist_items` where `status != "archived"`, normalized uppercase/trim, ranked by distinct-user count desc, capped at `limit`. Reuse the union + normalization from `News/NewsRepository.swift:141-216`. **Equity filter caveat:** only `stocks` has a `category` column — apply `category == .stock` there; `watchlist_items` has no category, so its symbols are included as-is. A watched crypto ticker would simply return an empty X-equity search (one wasted call, harmless); a per-symbol equity-vs-crypto classification is out of scope for v1.
- **`Insights/InsightsService.swift`** — `syncTickerPosts` (lines ~203-231): replace the boot-captured `trackedTickers` with `repo.allTrackedSymbols(limit: tickerLimit, on: req.db)` merged with the optional pin list, at sync time.
- **`Insights/InsightsController.swift`** — new `GET tracked-symbols` route returning `{ symbols: [String], limit: Int }`. Guarded by a **machine bearer** (`INSIGHTS_SYMBOLS_TOKEN`), NOT the user session/scoped auth — this is a VPS→backend machine call over the tailnet. Fail-closed when the env is unset (503/403). Existing `/tickers/:symbol/sentiment` read unchanged (Pro, scoped `.insightsRead`).
- **`configure.swift`** — read `HERMES_TRACKED_TICKERS_LIMIT` (default 25) and `INSIGHTS_SYMBOLS_TOKEN`; keep `HERMES_TRACKED_TICKERS` as an optional always-include pin list.
- **`openapi.yaml`** — add `/v1/insights/tickers/{symbol}/sentiment` (and `/v1/insights/tracked-symbols`) so the web client regenerates. Check `OpenAPIDocsTests` for coverage assertions.
- Env additions (`.env.example`, `docker-compose.yml`): `HERMES_TRACKED_TICKERS_LIMIT=25`, `INSIGHTS_SYMBOLS_TOKEN=`.

### Hermes VPS (`scripts/hermes/`)

- The `hermes-ticker-sentiment` cron gains a **pre-step**: `curl` the backend `GET /v1/insights/tracked-symbols` over Tailscale with `INSIGHTS_SYMBOLS_TOKEN`, write the returned symbols into `scraper_config.json` `tickers`, then scrape. On fetch failure, keep the existing `scraper_config.json` (graceful fallback). Implemented as a small helper the cron prompt calls, or folded into `ticker_sentiment_scraper.py` as a `--refresh-symbols <url>` step. `selfheal.sh` unaffected.

### iOS (`norviq-ios/financeplan/financeplan/`)

- **`API/Insights/`** (new, three-file convention): `TickerSentimentEndpoint.swift` (path `/v1/insights/tickers/{symbol}/sentiment`, params `days`/`limit`, decoder `.stockPlanShared`), `InsightsHTTPClient.swift` (wraps `BaseHTTPClient`, typed `getTickerSentiment`), `Container+InsightsFactories.swift` (Factory DI with `apiBaseUrl` + `authTokenProvider`). DTOs in `API/Insights/InsightsDTOs.swift` or FinanceShared.
- **`Features/Stocks/StockInsightsModels.swift`** — add `.sentiment` to `StockDetailTab` (title "Sentiment", `isProOnly = true`).
- **`Features/Stocks/StockDetailsScreen.swift`** — `case .sentiment:` branch in the tab `switch` (~line 216).
- **`Features/Stocks/StockDetailsScreenViewModel.swift`** — `.sentiment` branch in `loadSupplementaryDataIfNeeded` (lazy, mirrors `.earnings`).
- **`Features/Stocks/Detail/StockSentimentTab.swift`** (new) — aggregate header (bullish/bearish/neutral badge + avg score + post count) over a list of post cards (author, `@handle`, verbatim quote, sentiment badge, tap → open X URL). Empty state "No sentiment yet"; Pro-gate via existing pattern. Visual reuse: `Features/Crypto/Cards/MarketSentimentCard.swift`, `StockNewsTab.swift`.
- Localizable strings in `Localizable.xcstrings`.

### Web (`norviq-web/internal/`)

- **Regenerate `api/client.gen.go`** from the updated backend `openapi.yaml` (oapi-codegen) — hard prerequisite; do not hand-write the call.
- **`nav/nav.go`** — add a `sentiment` `NavItem` (ProOnly) in `StockDetailTabs`, add `"sentiment"` to `validStockTabs`.
- **`pages/stock/sentiment.templ`** (new) — `SentimentTab(vm)` mirroring `news.templ`, with `EmptyState` fallback and Pro gating (`@components.ProGateWrap`).
- **`pages/stock/page.templ`** — `case "sentiment": @SentimentTab(vm)` in `TabContent`.
- **`pages/stock/viewmodel.go`** — `SentimentTabVM`.
- **`handlers/stock_detail_tabs_data.go`** — `loadStockSentimentTab` mirroring `loadStockNewsTab` (calls the regenerated client, maps `JSON200` → VM).
- **i18n** — add sentiment copy to `i18n/locales/active.en.json` + `active.pt-PT.json`.

## Error Handling & Edge Cases

- Untracked / no-data symbol → 200 empty `posts` → empty state (both clients).
- Hermes/VPS down → reads still served from Postgres (stale). Readiness `hermes` check already reflects degradation; no client-facing error.
- `tracked-symbols` fetch fails on the VPS → cron falls back to the existing `scraper_config.json`.
- Non-Pro user → paywalled teaser (existing gate components).
- `INSIGHTS_SYMBOLS_TOKEN` unset → tracked-symbols endpoint fail-closed (503).

## Cost Control

- Top-N cap (default 25) → ≤ N SuperGrok X-searches per cycle regardless of userbase.
- Equity-only filter keeps crypto/other assets out of the equity-sentiment scraper.
- Optional pin list (`HERMES_TRACKED_TICKERS`) always included within/above the cap.

## Testing

- **Backend unit** (`Tests/StockPlanBackendTests/InsightsServiceTests.swift` or a new file): `allTrackedSymbols` — union of holdings+watchlist, dedup, `archived` exclusion, equity-only filter, popularity ranking, cap at N; `tracked-symbols` endpoint auth (401/403 without token, 200 with). Existing ticker-sentiment read tests unchanged.
- **iOS**: viewModel test for the `.sentiment` lazy load with a stubbed `InsightsHTTPClient` (fixture posts → rendered aggregate + list).
- **Web**: handler test for `loadStockSentimentTab` (pro-routes test pattern), including the Pro gate.
- **E2E**: add a symbol to a user's watchlist → it appears in `/v1/insights/tracked-symbols` → the VPS cron scrapes it → `/v1/insights/tickers/{symbol}/sentiment` returns posts → renders in iOS + web.

## Out of Scope (future)

- On-demand scrape when a user taps an untracked symbol (empty state suffices for v1).
- Crypto/asset-class sentiment.
- Topic-sentiment and net-worth insight UI (this spec is ticker sentiment only).
- Tiered scrape cadence (single cadence + top-N cap is enough for now).

## Key Reference Files

- Backend union/normalize: `News/NewsRepository.swift:141-216`; sync loop: `Insights/InsightsService.swift:203-231`; ticker source wiring: `configure.swift:239-250`.
- iOS: `Features/Stocks/StockDetailsScreen.swift`, `StockInsightsModels.swift`, `StockDetailsScreenViewModel.swift:412-457`, `API/News/*` (client template), `Features/Stocks/Detail/StockNewsTab.swift`.
- Web: `pages/stock/page.templ:142-165`, `pages/stock/news.templ`, `nav/nav.go:145-163`, `handlers/stock_detail_tabs_data.go:350-377`, `i18n/locales/*`.
