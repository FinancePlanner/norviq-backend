# News Providers Plan

This document defines how to extend the News domain from manual CRUD into automated ingestion from external APIs and RSS feeds, while keeping current controller and DTO contracts stable.

## Goal

- Keep existing `NewsService` CRUD behavior.
- Add a provider abstraction to fetch news for tracked symbols.
- Support multiple providers (external API, RSS) without changing controller/DTO contracts.

## Architecture

### 1. Provider Contract

Add a protocol:

```swift
protocol NewsProvider: Sendable {
    var name: String { get }
    func fetch(symbols: [String], on req: Request) async throws -> [ProviderNewsItem]
}
```

Provider DTO:

```swift
struct ProviderNewsItem: Sendable {
    let symbol: String
    let headline: String
    let source: String?
    let url: String?
    let summary: String?
    let publishedAt: Date
}
```

### 2. Provider Implementations

- `ExternalAPINewsProvider`: HTTP JSON integration (API key, rate limits, pagination).
- `RSSNewsProvider`: RSS/Atom feed parser integration.

Both return normalized `ProviderNewsItem` values so the service logic remains provider-agnostic.

### 3. Service Sync Method

Add a method to `NewsService`:

```swift
func syncNews(userId: UUID, on req: Request) async throws -> NewsSyncResponse
```

Sync flow:

1. Resolve user symbols (at least from `stocks` + `watchlist`).
2. Call provider `fetch(symbols:)`.
3. Normalize symbols and content.
4. Upsert into `news_items` (user-scoped).
5. Return summary (`fetched`, `inserted`, `updated`, `skipped`, `provider`).

### 4. Upsert Strategy

Use a deterministic dedupe key:

- Preferred: `(user_id, symbol, url)` when URL exists.
- Fallback: `(user_id, symbol, headline, published_at)`.

Add indexes/constraints in a migration so sync remains fast and idempotent.

## API Trigger

Add endpoint:

- `POST /news/sync` (authenticated)

Behavior:

- Calls `newsService.syncNews(userId:on:)`.
- Returns a sync summary response.

This endpoint enables manual sync from the app. Later, add scheduled sync.

## Scheduling (Later Phase)

After manual sync is stable:

- Add periodic jobs (e.g. every 15-60 minutes during market hours).
- Run per user or batched by symbol universe.
- Enforce provider rate limits and retry/backoff policy.

## Config

Use env vars for provider config:

- `NEWS_PROVIDER` (`external_api` / `rss`)
- `NEWS_API_BASE_URL`
- `NEWS_API_KEY`
- `NEWS_SYNC_TIMEOUT_SECONDS`
- `NEWS_SYNC_MAX_ARTICLES`
- `NEWS_RSS_FEEDS` (comma-separated)

## Observability

Log fields for each sync:

- `user_id`
- `provider`
- `symbols_count`
- `fetched_count`
- `inserted_count`
- `updated_count`
- `skipped_count`
- `latency_ms`
- `status`

## Rollout Order

1. Add `NewsProvider` protocol + one concrete provider.
2. Add `syncNews` in `NewsService`.
3. Add `POST /news/sync`.
4. Add dedupe indexes/constraints.
5. Add service/controller tests for sync.
6. Add optional scheduler after manual sync is validated.

___

About external API/RSS:

  - Yes, this is straightforward.
  - Keep current NewsService CRUD, and add a provider layer:
      1. NewsProvider protocol (fetch(symbols:)).
      2. ExternalAPINewsProvider and/or RSSNewsProvider implementations.
      3. syncNews(userId:) method in service that fetches + upserts NewsItem.
      4. Trigger via endpoint (POST /news/sync) and later scheduler/cron.
  - This lets you switch providers without changing your controller/DTO contracts.
  
    The backend now injects `FinnhubNewsProvider` automatically when `FINNHUB_API_KEY` is configured. If the key is missing, `POST /news/sync` still returns 501 Not Implemented.
