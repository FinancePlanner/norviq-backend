# IBKR Integration Decision Note

Purpose
- Capture the product and technical recommendation for IBKR in this project.
- Clarify when `IBKR_API_BASE_URL` should be used and when it should stay optional.

## Short answer

Recommendation
- Do not make IBKR mandatory.
- Keep `IBKR_API_BASE_URL` optional.
- Treat IBKR as one possible broker and market data integration, not as the foundation of the product.

Why
- The core product value is portfolio tracking, notes, valuations, and imports.
- Users may want to add stocks manually, by CSV, or via broker APIs.
- Requiring IBKR for basic stock workflows adds friction, operational complexity, and market data entitlement issues too early.

## Product view

The product should separate three concerns:

1. Holdings source of truth
- Manual entry
- CSV import
- Broker API import

2. Market/reference data
- Quote
- History
- Symbol/company lookup

3. News and research discovery
- RSS feeds
- News APIs
- User-authored notes

These should not be tightly coupled.

Example
- A user should still be able to add `AAPL`, `MSFT`, or `ZETA`, write research notes, and set bear/base/bull valuation ranges even if no broker is connected and no live market data provider is configured.

## Should IBKR always be used for stock data?

Usually no.

IBKR is a good option when:
- You already use IBKR personally and want one integration for your own workflow.
- You plan to import holdings from IBKR accounts.
- You need broker-linked data and are willing to run the supporting infrastructure.

IBKR is a poor mandatory default when:
- The app should work for users with no broker connection.
- Holdings may come from manual entry or CSV.
- You want simple local development and low operational burden.
- You do not want market data access to depend on brokerage entitlements and live authenticated sessions.

Business downside of making IBKR mandatory
- Harder onboarding
- More support burden
- More runtime fragility
- Dependency on IBKR account state, subscriptions, and session health

## Should RSS be used for stock data?

No, not for quotes or history.

Use RSS for:
- News
- Headlines
- Research discovery
- Watchlist/company updates

Do not use RSS for:
- Real-time quotes
- Historical price bars
- Reliable symbol lookup
- Price-dependent portfolio analytics

RSS is useful as a content layer, not as a core market data system.

## Recommended strategy for this product

Phase 1
- Manual stock entry works without any external market provider.
- CSV import works without any external market provider.
- Bear/base/bull valuation ranges are stored entirely in the backend database.
- RSS/news is optional and additive.

Phase 2
- Add broker imports as optional integrations.
- Add one market data provider behind the `MarketDataProvider` abstraction.
- Keep graceful fallback behavior when no provider is configured.

Phase 3
- Add IBKR as an explicit integration for:
  - holdings import
  - optional market data
  - optional sync jobs

## What `IBKR_API_BASE_URL` should mean

`IBKR_API_BASE_URL` should only be used when IBKR market data is intentionally enabled.

It should not be assumed in every environment.

Expected behavior
- If `IBKR_API_BASE_URL` is unset:
  - the app still works
  - stock holdings still load
  - valuations still work
  - market compatibility endpoints degrade gracefully

- If `IBKR_API_BASE_URL` is set:
  - the backend may call the IBKR Web API for quote/history/search/fx
  - failures should remain isolated to market data features

## About `extrange/ibkr-docker`

Repository
- https://github.com/extrange/ibkr-docker

Use it as:
- infrastructure for an IBKR gateway/session if you decide to support IBKR later

Do not treat it as:
- the required basis of the app
- the only way to fetch stock information

It may be useful operationally, but it should stay behind an optional integration boundary.

## Decision

Current decision
- Keep IBKR optional.
- Do not require `IBKR_API_BASE_URL` by default.
- Use manual entry, CSV, and optional broker APIs for portfolio ingestion.
- Use RSS for news only.
- Keep market data provider integration abstract and replaceable.

## References

- IBKR Web API docs: https://ibkrcampus.com/campus/ibkr-api-page/webapi-doc/
- IBKR market data lesson: https://ibkrcampus.com/campus/trading-lessons/requesting-market-data/
- `extrange/ibkr-docker`: https://github.com/extrange/ibkr-docker
