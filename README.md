# StockPlanBackend

A personal stock portfolio tracker backend built with Vapor (Swift). This server-side application provides RESTful APIs for managing stock holdings, tracking historical performance, and fetching real-time price data. Designed to pair with a SwiftUI mobile app for a full-stack Swift experience.

## Overview

StockPlanBackend enables you to:
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

### Tech Stack
- **Server Framework**: Vapor 4.x
- **Database**: PostgreSQL (production) or SQLite (development)
- **Authentication**: JWT tokens via Vapor's JWT package
- **External APIs**: HTTP client for stock data providers
- **Deployment**: Docker on Hetzner VPS with HTTPS (Let's Encrypt)

## API Endpoints

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
- `GET /history/:symbol` - Fetch historical prices (5/10 year time-series)
- `GET /quote/:symbol` - Get current price for a stock symbol
- `GET /search?q=:query` - Search for stock symbols/companies

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
