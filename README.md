# StockPlanBackend VPS

A personal stock portfolio tracker backend built with Vapor (Swift). This server-side application provides RESTful APIs for managing stock holdings, tracking historical performance, and fetching real-time price data. Designed to pair with a SwiftUI mobile app for a full-stack Swift experience.

## Overview

Norviq enables you to:
- Track holdings and watchlists with buy/sell prices, dates, and notes
- Draft due diligence notes (thesis, risks, catalysts, links)
- Set base, bear, and bull targets with timeframes and rationale
- Fetch current quotes and daily historical prices from external providers
- Calculate portfolio gains/losses and performance metrics
- Store user data securely with JWT authentication
- Sync data across devices for iOS and macOS clients

## Product Name and Marketing Copy

### Product Name
StockPlan

### App Store Subtitle
Track portfolios. Draft DD. Set bull/bear targets.

### Marketing Blurb (Short)
StockPlan is built for active investors who want a clean way to follow positions, write due diligence, and set base/bear/bull targets. Connect your brokers and stay current with up-to-date performance across your watchlist.

### App Store Description (Long)
StockPlan helps active investors stay on top of their portfolios with a clear workflow for research, targets, and tracking. Build and maintain due diligence notes, define base/bear/bull scenarios for each stock, and follow performance across your watchlist in one place.

Key features:
- Portfolio tracking with broker connections
- Due diligence drafts and structured notes
- Base, bear, and bull target scenarios
- Watchlists with current pricing and performance
- Cross-device sync for iOS and macOS

### Onboarding Copy (Suggested)
1. Welcome to StockPlan
Define your investing workflow in one place.
2. Follow Your Stocks
Track positions and watchlists with current pricing.
3. Draft Your Due Diligence
Capture thesis, risks, and catalysts as you research.
4. Set Targets
Create base, bear, and bull scenarios for each stock.
5. Connect Your Brokers
Sync holdings to stay up to date across devices.

Built for deployment on budget VPS instances like Hetzner's CPX11 ($5/month), this backend is optimized for low resource usage while maintaining production-ready performance.

## Features

### Core Features (MVP)
- **Accounts and Auth**: Register/login with JWT for secure multi-device access
- **Portfolio and Watchlist**: CRUD holdings and watchlist entries
- **Due Diligence Notes**: Thesis, risks, catalysts, and reference links per stock
- **Targets**: Base/bear/bull price targets with dates and rationale
- **Market Data**: Quotes and daily history from external APIs with caching
- **Broker Sync v1 (CSV Import)**: Export from your broker, then import the CSV in the app to update holdings/watchlist (read-only; no trading)

### Planned Extensions
- **Real-Time Updates**: WebSocket support for live price streaming
- **Price Alerts**: Push notifications via APNS when stocks hit target prices
- **News Integration**: Pull relevant articles/RSS feeds for tracked stocks
- **Earnings Transcripts**: Attach transcript summaries and key metrics for imported stocks
- **Paper Trading**: Simulate trades without real money to test strategies
- **Advanced Analytics**: CAGR, volatility, Sharpe ratio, attribution
- **Expanded Broker Coverage**: More providers and optional trade execution
- **Automation**: Scheduled tasks for daily refresh and data maintenance

## MVP Strategy: CSV First, Broker API Second

> **Recommended approach**: Implement CSV import before tackling broker API integration.

| Factor | CSV Import | Broker API |
|--------|-----------|------------|
| Complexity | Low - parse standard file | High - OAuth, rate limits, API versioning |
| Dev time | ~1-2 days | ~1-2 weeks |
| Dependencies | None | Broker partnership, API keys, legal review |
| User friction | Manual export/import | One-time auth flow |
| Testing | Local files | Need sandbox/mock |

**Why CSV first?**
1. **Validates the data model** - You'll understand exactly what fields matter before building broker integrations
2. **Delivers value immediately** - Users can start tracking portfolios on day one
3. **Lower risk** - No external API dependencies or breaking changes
4. **Learning opportunity** - Build out the Stock, Watchlist, and Target flows before adding complexity

**Next steps after CSV:**
1. Pick one broker (Interactive Brokers or Alpaca are developer-friendly)
2. Implement OAuth flow
3. Sync holdings on-demand
4. Add scheduled refresh for positions

## Architecture

### Full-Stack Swift Benefits
- **Shared Models**: Use the same `Stock`, `Portfolio`, `User` structs on server and mobile app
- **Type Safety**: Reduce bugs with Swift's strong typing across the entire stack
- **Code Reuse**: Business logic (e.g., portfolio calculations) can be extracted to a shared Swift package

### Shared Models Package (`FinanceShared`)
- Backend DTO contracts are consumed from `https://github.com/FinancePlanner/FinanceShared.git`.
- Current requirement in `Package.swift` is `from: "0.1.0"` for semantic versioned upgrades.
- Shared DTOs are imported through `StockPlanShared` and bridged to Vapor with backend-only `Content` conformances in `Sources/StockPlanBackend/Shared/StockPlanShared+Content.swift`.

If dependency resolution fails with "no versions match 0.1.0", publish and push a tag in `FinanceShared`:

```bash
git tag 0.1.0
git push origin 0.1.0
```

### Tech Stack
- **Server Framework**: Vapor 4.x
- **Database**: PostgreSQL (production) or SQLite (development)
- **Authentication**: JWT tokens via Vapor's JWT package
- **External APIs**: HTTP client for stock data providers
- **Deployment**: Docker on Hetzner VPS with HTTPS (Let's Encrypt)

## API Endpoints

All API routes are versioned under `/v1`.

All data endpoints require authentication. Get a token from auth endpoints and send:
- `Authorization: Bearer <token>`

### Authentication
- `POST /auth/register` - Create new user account
- `POST /auth/login` - Authenticate and receive JWT token

### Stocks
- `GET /stocks` - List all stocks in user's portfolio
- `POST /stocks` - Add a new stock holding
- `GET /stocks/:id` - Get details for a specific holding
- `PUT /stocks/:id` - Update holding (e.g., add notes, adjust buy price)
- `DELETE /stocks/:id` - Remove stock from portfolio

### Watchlist
- `GET /watchlist` - List watchlist entries
- `POST /watchlist` - Add a symbol to watchlist
- `DELETE /watchlist/:id` - Remove from watchlist

### Research (Due Diligence)
- `GET /research` - List due diligence notes
- `GET /research?symbol=:symbol` - List due diligence notes for one symbol
- `POST /research` - Create a new note
- `GET /research/:id` - Get a specific note
- `PUT /research/:id` - Update a note
- `DELETE /research/:id` - Remove a note

### Targets
- `GET /targets?stockId=:id` - List targets for a stock
- `POST /targets` - Create a base/bear/bull target
- `PUT /targets/:id` - Update a target
- `DELETE /targets/:id` - Remove a target

### Broker Connections
- `GET /brokers` - List connected brokers
- `GET /brokers/holdings` - List imported holdings
- `POST /brokers/import/csv` - Import holdings from CSV (Content-Type: text/csv)
- `POST /brokers/import/csv/commit` - Commit CSV import and upsert holdings
- `POST /brokers/ibkr/sync` - Trigger an IBKR sync run (placeholder for broker API phase)

### Market Data
- `GET /v1/market/details?symbol=:symbol` - Stock detail summary used by the iOS stock detail screen
- `GET /v1/market/history?symbol=:symbol` - Stock history list used by the iOS stock detail screen
- `GET /v1/market/news?symbol=:symbol` - Recent stock news used by the iOS stock detail screen
- `GET /v1/market/earnings/:symbol/transcript?date=YYYY-MM-DD` - Earnings call transcript for a specific earnings event. The endpoint also accepts `year` and `quarter` together when the client already knows the fiscal period.
- `GET /v1/history/:symbol` - Fetch historical prices (5/10 year time-series)
- `GET /v1/quote/:symbol` - Get current price for a stock symbol
- `GET /v1/quote/batch?symbols=AAPL,MSFT,...` - Fetch multiple quotes in one call
- `GET /v1/search?q=:query` - Search for stock symbols/companies

Market data configuration:
- `IBKR_API_BASE_URL` is optional for now.
- If it is unset, the backend will not call IBKR. `/v1/market/history` returns an empty list and `/v1/market/details` falls back to the symbol with zeroed pricing fields.
- If you do enable IBKR later, set `IBKR_API_BASE_URL` to the reachable Client Portal API base URL, for example `http://localhost:5000/v1/api` when running the backend on your host.
- Earnings transcripts use the configured FMP provider, are gated by the `earningsText` premium feature, and are cached through the market data cache using the resolved symbol/date or fiscal year/quarter.

### News
- `GET /news` - List saved news items (`?symbol=` supported)
- `GET /news/feed` - User feed filtered to tracked symbols (`?limit=` supported)
- `POST /news` - Create a news item manually
- `POST /news/sync` - Trigger provider sync scaffold
- `GET /news/:newsId` - Get one news item
- `PUT /news/:newsId` - Update one news item
- `DELETE /news/:newsId` - Delete one news item

### Dashboard
- `GET /dashboard` - Aggregated home snapshot (portfolio summary, top holdings, recent news)

### Portfolio Analytics
- `GET /portfolio/summary` - Total value, gains/losses, allocation
- `GET /portfolio/performance` - Historical performance metrics

## Statistics Ideas for the App

- Stock-level scorecard: Position value, cost basis, unrealized PnL, realized PnL, and daily/weekly/monthly change per symbol.
- Stock allocation: Portfolio weight by symbol, concentration ratio (top 5 holdings), and diversification score.
- Sector allocation: Weight and PnL split by sector to see overexposure and which sectors are driving returns.
- Calendar performance: Daily up/down heatmap by month, best/worst day, and streaks of green/red days.
- Contribution analysis: Which stocks contributed most to gains/losses over selected periods.
- Winners vs losers: Count and percentage of profitable positions vs losing positions.
- Volatility snapshot: Price-change dispersion across holdings and simple drawdown view.
- Currency split: Portfolio exposure by currency and FX impact estimate when base currency is not USD.
- Scenario tracking: Base/bear/bull target progress and distance-to-target for each tracked stock.
- Notes quality metrics: Coverage of thesis/risks/catalysts per position to find research gaps.

## Product Improvement Ideas

### Technical & Architecture Improvements
- **Rate Limiting & Abuse Prevention**: Add per-user rate limiting on API endpoints (especially auth and market data) to prevent abuse and protect external API quotas
- **API Versioning**: Prefix all routes with `/v1/` now so breaking changes can be introduced cleanly via `/v2/` later
- **Request Validation Layer**: Centralize input validation beyond what Fluent provides — e.g., symbol format checks, price range sanity, date bounds
- **Background Job System**: Replace ad-hoc scheduled tasks with a proper job queue (e.g., Vapor Queues + Redis) for CSV processing, market data refresh, and IBKR sync
- **Health Check Endpoint**: Add `GET /health` returning app version, uptime, DB connectivity, and Redis status — useful for monitoring and Docker health checks
- **Structured Logging & Observability**: Integrate distributed tracing IDs across requests; emit structured JSON logs for easier log aggregation (ELK, Loki)
- **OpenAPI-Driven Client SDK Generation**: Already generating `openapi.yaml` — publish auto-generated Swift client SDKs for the iOS app to stay in sync
- **Database Connection Pooling Tuning**: Configure connection pool sizes for production workloads and add pool exhaustion alerting

### User Experience & Feature Improvements
- **Onboarding Wizard**: Guided first-run experience — add first stock, set a watchlist, import CSV — to reduce time-to-value
- **Multi-Portfolio Support**: Let users create named portfolios (e.g., "Retirement", "Growth", "Dividend") instead of one flat list
- **Tagging & Filtering**: Allow custom tags on stocks and research notes for flexible organization (e.g., "tech", "dividend", "speculative")
- **Export Capabilities**: Export portfolio data, research notes, and performance reports as PDF or CSV for tax prep or personal records
- **Activity Feed / Audit Log**: Show a timeline of portfolio changes — buys, sells, target hits, price alerts — for accountability and review
- **Collaboration Features**: Share research notes or portfolio snapshots with other users via read-only links
- **Dark Mode API Support**: Provide theme-preference endpoints so the iOS/macOS app can sync theme across devices
- **Offline-First Sync**: Design the API to support conflict resolution for offline edits on the iOS app (last-write-wins or merge strategy)

### Data & Analytics Improvements
- **Dividend Tracking**: Track dividend payments, yield, and DRIP reinvestment to give a complete income picture
- **Benchmark Comparison**: Compare portfolio performance against S&P 500, NASDAQ, or custom benchmarks
- **Risk Metrics Dashboard**: Sharpe ratio, max drawdown, beta, and correlation matrix across holdings
- **Earnings Calendar Integration**: Automatically flag upcoming earnings dates for held stocks
- **AI-Powered Insights** (future): Use an LLM to summarize research notes, generate DD templates, or flag conflicting thesis/target pairs

## Project Structure Review (Actionable)

The current layout is already close to a good vertical-slice setup. To make it easier to scale with paid features, keep moving toward strict domain boundaries:

1. **Domain Folder Standardization**
   - Use one shape per domain: `Controller`, `Service`, `Repository`, `DTO`, `+Application`, and optional `Provider`.
   - Apply this consistently to all domains (`Stocks`, `Market`, `News`, `Statistics`, `Dashboard`, `Broker`).

2. **Keep `Models/` as Persistence-Only**
   - Continue storing Fluent models in `Models/`.
   - Keep API contracts and business view models inside each domain folder, not in `Models/`.

3. **Infrastructure Separation**
   - Move concrete external clients into `Sources/StockPlanBackend/Infrastructure/` (e.g., IBKR client, RSS fetcher, HTTP adapters, Redis helpers).
   - Keep domain services unaware of HTTP details beyond provider protocols.

4. **Background Jobs Boundary**
   - Add `Sources/StockPlanBackend/Jobs/` for async work (`news sync`, `market refresh`, `cache cleanup`).
   - Trigger jobs from routes; keep controllers synchronous and thin.

5. **Tests by Domain**
   - Mirror production folders under tests: `Tests/StockPlanBackendTests/Market`, `.../News`, `.../Dashboard`.
   - Keep unit tests for services/repositories and a smaller set of route integration tests.

6. **API Contract Governance**
   - Treat `openapi.yaml` as part of done criteria for each endpoint change.
   - Add a CI check to fail if routes and OpenAPI drift.

## Monetization Execution (How to Make Paid/Subscription Work)

Use your existing domains to gate value, not basic access:

1. **Free Tier (Acquisition)**
   - Manual stocks + watchlist + basic notes + delayed quote updates.
   - Enough value to build habit and trust.

2. **Pro Tier (Main Revenue)**
   - CSV import automation, richer statistics, dashboard insights, news feed sync, faster refresh cadence.
   - Best fit for individual active investors.

3. **Premium Tier (Power Users)**
   - Multi-portfolio workspaces, advanced analytics, transcript summaries, alerts, and API export access.

4. **Backend Changes to Support Billing**
   - Add `subscriptions` and `entitlements` tables.
   - Add middleware/policies for limits by tier (symbols, refresh frequency, sync jobs, analytics depth).
   - Track usage counters monthly for upgrade prompts.

5. **Conversion Path**
   - In-app upsell moments: after CSV import, after hitting symbol limits, when opening advanced stats/news sync.
   - Offer annual plans with discount to reduce churn.

6. **Positioning**
   - Position StockPlan as a "decision journal + portfolio operating system" instead of only a tracker.
   - Emphasize thesis quality, scenario tracking, and review workflow as the paid differentiator.

---

## Monetization & Revenue Strategy

### Subscription Tiers

| Feature | **Free** | **Pro** ($7.99/mo) | **Premium** ($14.99/mo) |
|---------|----------|---------------------|--------------------------|
| Holdings tracked | Up to 10 | Unlimited | Unlimited |
| Watchlist symbols | Up to 15 | Unlimited | Unlimited |
| Research notes | 5 notes | Unlimited | Unlimited |
| CSV import | 1 per month | Unlimited | Unlimited |
| Market data refresh | End-of-day | 15-min delayed | Near real-time |
| Historical data | 1 year | 5 years | 10 years |
| Portfolios | 1 | 3 | Unlimited |
| Price alerts | — | 10 active | Unlimited |
| Analytics & reports | Basic PnL | Full stats suite | Full + export PDF |
| Benchmark comparison | — | S&P 500 | Custom benchmarks |
| Dividend tracking | — | ✓ | ✓ |
| Priority support | — | — | ✓ |
| API access | — | — | ✓ |

### Revenue Channels

1. **Freemium Subscriptions (Primary)**
   - Free tier with meaningful limits that still deliver value (validates the product)
   - Pro tier for active investors who outgrow the free limits
   - Premium tier for power users, traders, and finance enthusiasts who want everything

2. **Annual Pricing Discount**
   - Pro: $59.99/year (save 37%)
   - Premium: $119.99/year (save 33%)
   - Annual plans reduce churn and improve LTV

3. **One-Time Lifetime Deal** (launch promo)
   - Offer a lifetime Pro access for $99.99 during launch to seed early adopters and reviews
   - Cap at 500 licenses to create urgency

4. **Affiliate / Broker Referrals**
   - Partner with developer-friendly brokers (Interactive Brokers, Alpaca, Webull)
   - Earn referral fees when users open brokerage accounts through StockPlan links
   - Non-intrusive: surface as "Connect a Broker" in settings

5. **Data Export Add-On**
   - Tax-ready export packages ($4.99 one-time per tax year)
   - Generate realized gains/losses reports formatted for Schedule D / Form 8949

6. **B2B / Team Plans** (future)
   - Small fund managers or investment clubs ($29.99/mo per team)
   - Shared portfolios, collaborative research notes, role-based access

### Implementation Notes (Backend)

- **Subscription Management**: Use [RevenueCat](https://www.revenuecat.com/) for App Store subscription handling — it manages receipts, trials, and grace periods with a Swift SDK
- **Entitlement Middleware**: Add a Vapor middleware that reads the user's subscription tier from the DB and enforces feature gates (e.g., max holdings, refresh frequency)
- **Usage Tracking**: Store monthly usage counters (CSV imports, API calls, alerts created) to enforce free-tier limits and surface upgrade prompts
- **Webhook Receiver**: Add a `POST /webhooks/revenuecat` endpoint to receive subscription lifecycle events (new purchase, renewal, cancellation, billing issue)

### Go-to-Market Ideas

- **Product Hunt Launch**: Submit with a compelling tagline — "The stock tracker for investors who actually do research"
- **Finance Subreddits & Communities**: Share on r/investing, r/stocks, r/SwiftUI with a genuine "I built this" post
- **App Store Optimization**: Use the marketing copy already in this README; add screenshots showing DD notes and target scenarios
- **Content Marketing**: Write blog posts about building a full-stack Swift finance app — appeals to both investors and developers
- **Indie Hacker Channels**: Post on IndieHackers, Hacker News (Show HN), and Twitter/X with build-in-public updates
- **TestFlight Beta Program**: Launch a private beta with 100 users to get feedback and App Store reviews ready for day one

---

## CSV Import (MVP): Export from Broker, Import from App

Enable users to keep their StockPlan portfolio in sync by exporting holdings from their broker as a CSV file and importing it directly in the app.

### How it works
1. Export from your broker
   - In your broker platform, export your current positions/holdings as a CSV.
   - Include at minimum: symbol/ticker and quantity (shares).
   - If available, also include: average cost (buy price) and first purchase date.
   - Save the file to your device (Files/iCloud/Downloads).
2. Import from the app
   - In the StockPlan app, go to Settings → Import from Broker (CSV).
   - Select the CSV file. You'll see a quick preview and header mapping.
   - Confirm to upload; the backend validates rows and upserts holdings.

### Accepted CSV format
- Header row required. Header names are case-insensitive; underscores/spaces are ignored.
- Recognized columns (any of the aliases below are accepted):
  - symbol: "symbol", "ticker`
  - shares: "shares", "quantity", "qty`
  - buy_price: "buy_price", "average_cost", "avg_cost", "cost_basis`
  - buy_date: "buy_date", "purchase_date", "opened`
  - notes (optional)
- Dates: YYYY-MM-DD (e.g., 2024-11-15).
- Numbers: use dot as decimal separator (e.g., 1234.56).
- Extra columns are ignored.

Example:

"""
symbol,shares,buy_price,buy_date,notes
AAPL,12,145.30,2023-04-18,Long-term core
MSFT,5,320.00,2024-01-10,
NVDA,2,,,
"""

### Import behavior
- Upsert by (user, symbol):
  - If a holding with the same symbol exists, its shares/buy price/date are updated.
  - If not, a new holding is created.
- Rows with only a symbol (no shares) can be used to populate your watchlist.
- Invalid rows are skipped and reported back with reasons (e.g., missing symbol).

### API (for clients)
- Endpoint: `POST /brokers/import/csv`
- Headers: `Authorization: Bearer <token>`, `Content-Type: text/csv`
- Body: raw CSV content.

cURL example:

"""
curl -X POST \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: text/csv" \
  --data-binary @holdings.csv \
  http://localhost:8080/brokers/import/csv
"""

### Privacy & safety
- Read-only import: no trading or broker credentials required.
- Only the data you upload (symbols, quantities, prices) is processed.

## Getting Started

### Prerequisites
- Swift 5.9+ (included with Xcode 15+)
- PostgreSQL (optional for production) or use SQLite for local development
- External API key (e.g., free tier from Alpha Vantage)

### Installation

1. Clone the repository:
```bash
git clone <repository-url>
cd StockPlanBackend

# FinanceBackend
# dev
# dev
