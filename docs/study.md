# StockPlanBackend API Study Guide

## Implemented Pre-Login Paywall & Privacy Flow (2026-04-24)

Main work:
- Added a pre-login privacy screen (`PrivacyWelcomeScreen`) highlighting data ownership and security.
- Added a pre-login paywall screen (`PreLoginPaywallScreen`) allowing anonymous users to start a 7-day free trial on the Pro annual plan.
- Configured Amplitude unified SDK for iOS analytics, initialized via DI (`AnalyticsService`), currently tracking "App Launched".
- Set up local StoreKit testing (`Products.storekit`) in Xcode with `pro_weekly`, `pro_monthly`, and `pro_annual` to bypass App Store Connect for local simulator testing.
- Updated `BillingManager` to support anonymous RevenueCat initialization and purchases, aliasing to the user ID upon login/signup.

Key files:
- `financeplan/Products.storekit`
- `financeplan/Features/Analytics/AnalyticsService.swift`
- `financeplan/API/Analytics/Container+AnalyticsFactories.swift`
- `financeplan/Features/Auth/PrivacyWelcomeScreen.swift`
- `financeplan/Features/Auth/PreLoginPaywallScreen.swift`
- `financeplan/ContentView.swift`
- `financeplan/NorviqaApp.swift`
- `financeplan/Features/UserProfile/BillingManager.swift`

## Implemented Broker IBKR Sync Integration (2026-04-23)

Main work:
- iOS Portfolio import sheet now has IBKR connect / sync / disconnect.
- iOS broker client starts browser flow with `ASWebAuthenticationSession`, then reloads Portfolio.
- Backend has broker connect-start endpoint, public callback, sync endpoint, disconnect endpoint.
- Backend sync pulls IBKR accounts/positions from existing IBKR gateway base URL and upserts imported holdings into Portfolio.
- Disconnect clears broker credential state and keeps imported holdings.

Key files:
- `financeplan/API/Brokers/BrokerEndpoints.swift`
- `financeplan/API/Brokers/BrokerHTTPClient.swift`
- `financeplan/API/Brokers/CsvImportFlowViewModel.swift`
- `financeplan/Features/Onboarding/BrokerService.swift`
- `financeplan/Features/Portfolio/PortfolioCSVImportSheet.swift`
- `financeplanTests/BrokerServiceTests.swift`
- `financeplanTests/PortfolioCSVImportViewModelTests.swift`
- `StockPlanBackend/Sources/StockPlanBackend/Broker/BrokerController.swift`
- `StockPlanBackend/Sources/StockPlanBackend/Broker/BrokersService.swift`
- `StockPlanBackend/Sources/StockPlanBackend/Broker/IBKRBrokerIntegration.swift`
- `StockPlanBackend/Sources/StockPlanBackend/Auth/AuthController.swift`
- `StockPlanBackend/Sources/StockPlanBackend/Models/BrokerConnection.swift`
- `StockPlanBackend/Sources/StockPlanBackend/Models/BrokerOAuthFlow.swift`
- `StockPlanBackend/Sources/StockPlanBackend/Migrations/AddBrokerOAuthFlowAndConnectionMetadata.swift`

Build:
- iOS xcodebuild ... build passed.
- Backend swift build passed.

Important caveat:
- Repo package wiring uses older external shared package for broker DTOs. I kept iOS and backend broker-flow DTO additions local where needed so feature builds now without waiting on shared package publish/update.

What acceptance now does:
- Connect IBKR account: yes, from Portfolio import sheet.
- Holdings auto-import into Portfolio: yes, callback triggers sync inline.
- Sync button refreshes positions: yes.
- Disconnect revokes token: best-effort local disconnect only. Current backend has no real IBKR token revoke adapter in repo, so it clears stored broker auth state and marks disconnected.

Not run:
- Full test suites.
- Real end-to-end IBKR live session test. Need actual `IBKR_API_BASE_URL` session up for that.

## Implemented Billing MVP Slice (2026-04-23)

- Backend: added pro plan compatibility, Pro gates, Pro limits, RevenueCat /v1/billing/restore, REVENUECAT_API_KEY production requirement.
- iOS: added RevenueCat package, API-key plist hook, BillingHTTPClient, BillingManager, custom SwiftUI Pro paywall, Settings subscription rows, restore/manage actions, Pro gating in reports, stock detail premium tabs/actions, portfolio alert action.
- Shared DTOs: added isPro compatibility while preserving isPremium.

Verified:
- financeplan iOS simulator build: passed.
- StockPlanShared swift test: passed, 23 tests.
- StockPlanBackend swift build: blocked by pre-existing broker/shared mismatch:
  - BrokerConnectStartRequest missing in StockPlanShared
  - BrokerConnectStartResponse missing in StockPlanShared

Still needs external config:
- Backend env: REVENUECAT_API_KEY
- iOS build setting: REVENUECAT_IOS_API_KEY
- RevenueCat: entitlement pro, products pro_monthly, pro_annual
- App Store Connect: subscription group + 14-day annual trial.

Pair this guide with the iOS client's `financeplan/Documentation/source-of-truth.md`. The client document explains which features treat the API as authoritative, which data is cached in SwiftData, and which mock paths must stay preview/test-only.

This guide is for studying the backend API project: Vapor, Fluent, PostgreSQL, auth, billing, market data, expenses, portfolio, notifications, observability, and tests.

The goal is not just to memorize files. The goal is to understand how an authenticated Swift API is built end to end:

```text
Request -> Middleware -> Controller -> Service -> Repository/Provider -> Fluent/Postgres or external API -> DTO response
```

## 1. Project Shape

Main backend path:

```text
Sources/StockPlanBackend/
├── configure.swift
├── routes.swift
├── entrypoint.swift
├── openapi.yaml
├── Auth/
├── Billing/
├── Broker/
├── Crypto/
├── Dashboard/
├── Expenses/
├── Market/
├── Models/
├── Migrations/
├── News/
├── Notifications/
├── Portfolio/
├── Shared/
├── Statistics/
├── Stocks/
└── UserProfile/
```

Tests live in:

```text
Tests/StockPlanBackendTests/
```

Docs live in:

```text
docs/
```

The API is a Vapor app. It uses:

- Vapor for HTTP routing, middleware, `Request`, `Response`, `Content`
- Fluent for ORM models, migrations, and query building
- FluentPostgresDriver for PostgreSQL
- JWT/JWTKit for session token signing and validation
- Redis/RediStack for optional cache/health integration
- APNS/VaporAPNS for push notifications
- Swift concurrency with `async/await`
- `StockPlanShared` DTOs where the client and server share contracts

## 2. Startup And Application Wiring

Study:

- `Sources/StockPlanBackend/entrypoint.swift`
- `Sources/StockPlanBackend/configure.swift`
- `Sources/StockPlanBackend/routes.swift`

`configure(_:)` is the app composition root. It wires:

- production configuration validation
- middleware
- JSON encoder/decoder
- PostgreSQL
- optional Redis
- JWT keys
- PII encryption service
- repositories
- services
- OAuth providers
- mailer
- market data providers
- APNS sender
- lifecycle jobs
- migrations
- routes

Important Vapor concepts:

- `Application`
- `Environment`
- `Middleware`
- `ContentConfiguration`
- `DatabaseConfigurationFactory`
- `app.lifecycle.use(...)`
- `app.migrations.add(...)`
- `try routes(app)`

Important repo pattern:

```swift
extension Application {
    struct SomeServiceKey: StorageKey {
        typealias Value = any SomeService
    }

    var someService: any SomeService {
        get { storage[SomeServiceKey.self]! }
        set { storage[SomeServiceKey.self] = newValue }
    }
}
```

That is how this backend does dependency injection.

## 3. Routing Architecture

Study:

- `routes.swift`
- each `*Controller.swift`

Top-level `routes.swift` creates:

- public health endpoints
- OpenAPI docs endpoints
- webhooks
- `/v1` API group
- feature route collections

Health endpoints:

- `GET /health`
- `GET /health/live`
- `GET /health/ready`

Docs endpoints:

- `GET /docs`
- `GET /openapi.yaml`

Webhook endpoints:

- `POST /webhooks/finnhub/news`
- `POST /webhooks/revenuecat`

Most app endpoints are under `/v1`.

Controller pattern:

```swift
struct SomeController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(SessionToken.authenticator(), SessionToken.guardMiddleware())
        let group = protected.grouped("feature")
        group.get(use: index)
    }
}
```

Study how each controller:

- groups routes
- protects routes with auth middleware
- decodes request bodies with `req.content.decode(...)`
- reads query params with `req.query.decode(...)`
- reads path params with `req.parameters.get(...)`
- gets current user from `SessionToken`
- calls `req.application.someService`
- returns `Content` DTOs

## 4. Middleware And Request Flow

Configured middleware includes:

- `CORSMiddleware`
- `ErrorMiddleware.default`
- `BillingErrorMiddleware`
- `RequestLoggingMiddleware`
- `TracingMiddleware`
- feature-specific `RateLimitMiddleware` on auth routes
- `SessionToken.authenticator()`
- `SessionToken.guardMiddleware()`

Request flow:

```text
HTTP request
-> CORS
-> error middleware
-> billing error mapping
-> request logging
-> tracing
-> route auth middleware
-> controller
-> service/repository/provider
-> response
```

`RequestLoggingMiddleware` logs:

- HTTP method
- path
- status
- latency
- request id
- authenticated user id when available

This is important for debugging cross-feature issues.

## 5. JSON And API Contracts

Study:

- `Shared/JSONCoder+Backend.swift`
- `Shared/StockPlanShared+Content.swift`
- `openapi.yaml`
- `OpenAPIDocsTests.swift`

The backend registers global JSON coders:

```swift
ContentConfiguration.global.use(decoder: JSONDecoder.backendAPI, for: .json)
ContentConfiguration.global.use(encoder: JSONEncoder.backendAPI, for: .json)
```

Important contract concepts:

- request/response DTOs conform to `Content`
- many shared DTOs come from `StockPlanShared`
- dates must be consistent across server and iOS client
- errors should use client-safe reasons
- OpenAPI docs are served when enabled

Study DTO files:

- `Auth/AuthDTOs.swift`
- `Stocks/StockDTO.swift`
- `Portfolio/PortfolioDTOs.swift`
- `Market/MarketDataDTOs.swift`
- `Expenses/ExpensesService.swift` and controllers
- `Billing/BillingDTOs.swift`
- `Crypto/CryptoDTOs.swift`
- `UserProfile/UserProfileDTOs.swift`
- `Notifications/PushNotificationsDTOs.swift`

## 6. Auth, Session Tokens, MFA, OAuth

Study:

- `Auth/AuthController.swift`
- `Auth/AuthService.swift`
- `Auth/AuthRepository.swift`
- `Auth/AuthDTOs.swift`
- `Auth/SessionToken.swift`
- `Auth/OAuthProviderClient.swift`
- `Models/User.swift`
- `Models/RefreshToken.swift`
- `Models/MFAChallenge.swift`
- `Models/OAuthFlow.swift`
- `Models/OAuthIdentity.swift`
- `docs/oauth.md`
- `docs/MFA.md`

Auth endpoints:

- `POST /v1/auth/register`
- `POST /v1/auth/login`
- `POST /v1/auth/forgot-password`
- `POST /v1/auth/resend-reset`
- `POST /v1/auth/reset-password`
- `POST /v1/auth/refresh`
- `POST /v1/auth/mfa/verify`
- `POST /v1/auth/mfa/resend`
- `POST /v1/auth/oauth/:provider/start`
- `POST /v1/auth/oauth/:provider/exchange`
- `GET /v1/auth/me`

Core auth concepts:

- users authenticate with email/password or OAuth
- access tokens are JWTs
- refresh tokens are persisted and revocable
- `SessionToken` authenticates protected routes
- MFA can be required for login/OAuth
- password reset codes and MFA codes are hashed
- account lockout fields live on `User`
- OAuth providers are Apple, Google, and X

Recent OAuth behavior:

- existing OAuth identity logs in the linked user
- verified OAuth email matching an existing user auto-links the provider identity
- unverified matching email returns conflict requiring explicit account-link handling
- new verified OAuth email creates a new user

Important structures:

- `AuthRegisterRequest`
- `AuthResponse`
- `AuthLoginOutcomePayload`
- `AuthMFAChallengeResponsePayload`
- `OAuthStartRequest`
- `OAuthExchangeRequest`
- `OAuthIdentityInfo`
- `SessionToken`

Security topics to understand:

- password hashing
- token expiration
- refresh token revocation
- allowed OAuth redirect URIs
- provider identity verification
- email verification semantics
- rate limiting on auth routes

## 7. User Ownership And Data Isolation

Most domain data is user-scoped.

Common pattern:

```swift
let session = try req.auth.require(SessionToken.self)
return try await service.someAction(userId: session.userId, on: req.db)
```

Important models with `user_id`:

- `Stock`
- `WatchlistItem`
- `PortfolioList`
- `WatchlistList`
- `ResearchNote`
- `Target`
- `Expense`
- `BudgetSnapshot`
- `BudgetPlanItem`
- `ExpenseCategory`
- `RecurringTemplate`
- `NewsItem`
- `Goal`
- `UserActivity`
- `UserBadge`
- `CryptoPortfolioItem`
- `PushDevice`
- `BrokerConnection`
- billing models

Rules to study:

- never trust user id from request body when authenticated session has one
- every read/update/delete must filter by authenticated user
- child objects must be checked through their parent owner where needed
- user-scoped indexes matter for performance

Study migration:

- `Migrations/AddUserScopedQueryIndexes.swift`

## 8. Fluent Models And Migrations

Study:

- `Models/`
- `Migrations/`
- `configure.swift` migration registration order

Important Fluent structures:

- `final class SomeModel: Model`
- `static let schema`
- `@ID(key: .id)`
- `@Field(key:)`
- `@OptionalField(key:)`
- `@Parent(key:)`
- `@Children(for:)`
- `AsyncMigration`
- `db.schema(...).field(...).create()`
- `Model.query(on:)`
- `.filter(...)`
- `.sort(...)`
- `.with(...)`
- `db.transaction { tx in ... }`

Important model groups:

Auth/security:

- `User`
- `RefreshToken`
- `PasswordResetToken`
- `MFAChallenge`
- `OAuthFlow`
- `OAuthIdentity`

Investing:

- `Stock`
- `PortfolioList`
- `WatchlistItem`
- `WatchlistList`
- `StockValuation`
- `ResearchNote`
- `Target`
- `Account`
- `Instrument`
- `Transaction`
- `Lot`
- `Position`
- `CashBalance`
- `Price`
- `PriceHistory`

Market data caches:

- `QuoteCache`
- `SearchCache`
- `ProfileCache`
- `BasicFinancialsCache`
- `AnalystEstimatesCache`
- `FinancialGrowthCache`
- `RatiosTTMCache`
- `RatiosCache`
- `MarketNewsArchive`
- `FxRate`

Expenses:

- `Expense`
- `BudgetSnapshot`
- `BudgetPlanItem`
- `ExpenseCategory`
- `RecurringTemplate`
- `ReportSuggestionDismissal`

Billing:

- `Subscription`
- `Entitlement`
- `BillingEvent`
- `UsageCounter`
- `TrialWarning`
- `Coupon`
- `CouponRedemption`

Other:

- `NewsItem`
- `Goal`
- `UserActivity`
- `UserBadge`
- `PushDevice`
- `BrokerConnection`
- `Feedback`
- `CryptoPortfolioItem`

Migration discipline:

- create tables before dependent tables
- add columns in separate migrations when evolving production data
- use backfill migrations for encrypted/user-profile data
- keep destructive migrations rare and deliberate
- add indexes for hot user-scoped queries

## 9. Services, Repositories, Providers

This repo separates responsibilities:

```text
Controller: HTTP details
Service: business rules and orchestration
Repository: database persistence
Provider: external API integration
Model: Fluent database record
DTO: request/response contract
```

Examples:

- `StockController -> StockService -> StocksRepository -> Stock`
- `ExpensesController -> ExpensesService -> Expense/BudgetSnapshot/BudgetPlanItem`
- `MarketDataController -> MarketDataService -> MarketDataProvider/FMP provider/cache repository`
- `NewsController -> NewsService -> NewsRepository/NewsProvider`
- `DashboardController -> DashboardService -> DashboardRepository/StatisticsRepository`
- `UserProfileController -> UserProfileService -> UserProfileRepository`

Provider examples:

- `FinnhubMarketDataProvider`
- `LiveFMPMarketDataProvider`
- `IBKRMarketDataProvider`
- `DisabledMarketDataProvider`
- `FinnhubNewsProvider`
- `FinnhubEarningsProvider`
- `DisabledEarningsProvider`
- `MockCryptoDataProvider`

Study the dependency inversion pattern:

- protocols are `Sendable`
- concrete implementations are registered on `Application`
- tests can swap fakes/mocks

## 10. Stocks, Portfolio, Watchlist, Research, Targets

Study:

- `Stocks/StockController.swift`
- `Stocks/StockController+Watchlist.swift`
- `Stocks/StockService.swift`
- `Stocks/StockRepository.swift`
- `Stocks/ListSupport.swift`
- `Portfolio/PortfolioController.swift`
- `Models/StockModel.swift`
- `Models/PortfolioList.swift`
- `Models/WatchlistItem.swift`
- `Models/WatchlistList.swift`
- `Models/StockValuation.swift`
- `Models/ResearchNote.swift`
- `Models/Target.swift`

Main stock endpoints:

- `GET /v1/stocks`
- `POST /v1/stocks`
- `POST /v1/stocks/bulk`
- `GET /v1/stocks/:id`
- `PUT /v1/stocks/:id`
- `POST /v1/stocks/:id/sell`
- `DELETE /v1/stocks/:id`
- `GET /v1/stocks/:symbol/insights`
- valuation endpoints under `/v1/stocks/:symbol/valuation`

Watchlist endpoints:

- `GET /v1/watchlist`
- `POST /v1/watchlist`
- `PATCH /v1/watchlist/:id`
- `DELETE /v1/watchlist/:id`
- list CRUD under `/v1/watchlist/lists`

Research endpoints:

- `GET /v1/research`
- `POST /v1/research`
- `GET /v1/research/:id`
- `PUT /v1/research/:id`
- `DELETE /v1/research/:id`

Target endpoints:

- `GET /v1/targets`
- `POST /v1/targets`
- `PUT /v1/targets/:id`
- `DELETE /v1/targets/:id`

Portfolio endpoints:

- `GET /v1/portfolio/summary`
- `GET /v1/portfolio/performance`
- portfolio list CRUD under `/v1/portfolio/lists`
- `GET /v1/transactions`
- `GET /v1/lots`
- `GET /v1/pnl`

Important rules:

- symbols are normalized
- operations are user-scoped
- portfolio/watchlist list ownership is enforced
- target alerts are evaluated by a lifecycle poller
- CSV import can create portfolio/watchlist data in transactions

## 11. Market Data, FMP Limits, Caching

Study:

- `Market/MarketDataController.swift`
- `Market/MarketDataService.swift`
- `Market/MarketDataProvider.swift`
- `Market/FMPMarketDataProvider.swift`
- `Market/FinnhubMarketDataProvider.swift`
- `Market/IBKRMarketDataProvider.swift`
- `Market/MarketDataRepository.swift`
- `Market/MarketNewsArchiveService.swift`
- `docs/cache/market-data-caching.md`

Market endpoints include:

- `GET /v1/market/details`
- `GET /v1/market/history`
- `GET /v1/market/history/archive`
- `POST /v1/market/history/archive/sync`
- `GET /v1/market/news`
- `GET /v1/market/news/general`
- `GET /v1/market/news/archive`
- `POST /v1/market/news/archive/sync`
- `GET /v1/market/quote/:symbol`
- `GET /v1/market/quote/batch`
- `GET /v1/market/profile/:symbol`
- `GET /v1/market/basic-financials/:symbol`
- `GET /v1/market/analysis/:symbol`
- `GET /v1/market/compare`
- `GET /v1/market/cash-flow-statement/:symbol`
- `GET /v1/market/balance-sheet-statement/:symbol`
- `GET /v1/market/ratios-ttm/:symbol`
- `GET /v1/market/grades-consensus/:symbol`
- `GET /v1/market/financial-growth/:symbol`
- `GET /v1/market/earnings/:symbol`
- `GET /v1/market/earnings-calendar`
- `GET /v1/market/analyst-estimates/:symbol`
- `GET /v1/market/ratios/:symbol`
- `GET /v1/market/historical-sector-performance`
- `GET /v1/market/search`
- `GET /v1/market/fx`
- price-chart endpoints

Provider selection:

- `MARKET_PROVIDER=finnhub`
- `MARKET_PROVIDER=ibkr`
- fallback to IBKR, Finnhub, or disabled provider
- FMP provider is enabled by `FMP_API_KEY`

Important FMP access topics:

- free tier symbol restrictions
- starter/premium exchange restrictions
- endpoint-specific constraints
- `FMP_SYMBOL_ACCESS_TIER`
- fail gracefully when provider is disabled or data is unavailable

Caching topics:

- quote TTL
- history TTL
- search TTL
- FX TTL
- profile/basic-financials/FMP TTL
- Redis cache path for some payloads
- Postgres cache tables for longer-lived provider payloads

## 12. Expenses, Budget, Reports

Study:

- `Expenses/ExpensesController.swift`
- `Expenses/BudgetController.swift`
- `Expenses/ReportsController.swift`
- `Expenses/ExpensesService.swift`
- `Models/Expense.swift`
- `Models/BudgetSnapshot.swift`
- `Models/BudgetPlanItem.swift`
- `Models/ExpenseCategory.swift`
- `Models/RecurringTemplate.swift`
- `Models/ReportSuggestionDismissal.swift`

Expenses endpoints:

- `GET /v1/expenses`
- `POST /v1/expenses`
- `PATCH /v1/expenses/:id`
- `DELETE /v1/expenses/:id`
- `GET /v1/expenses/categories`
- `POST /v1/expenses/categories`
- `DELETE /v1/expenses/categories/:id`
- `GET /v1/expenses/recurring`
- `POST /v1/expenses/recurring`
- `PATCH /v1/expenses/recurring/:id`
- `DELETE /v1/expenses/recurring/:id`
- household partner get/update

Budget endpoints:

- `GET /v1/budget/snapshots`
- `POST /v1/budget/snapshots`
- `PATCH /v1/budget/snapshots/:id`
- `DELETE /v1/budget/snapshots/:id`
- `GET /v1/budget/snapshots/:id/items`
- `GET /v1/budget/items`
- `POST /v1/budget/items`
- `PATCH /v1/budget/items/:id`
- `DELETE /v1/budget/items/:id`

Reports endpoints:

- `GET /v1/reports/overview`
- `GET /v1/reports/suggestions`
- `POST /v1/reports/suggestions/:id/dismiss`
- `GET /v1/reports/expenses?granularity=month|year`

Important domain topics:

- budget snapshots are monthly
- plan items belong to snapshots and users
- actual expenses can link to plan items
- recurring templates are separate from actual expense rows
- categories are user-scoped
- expenses support split mode and user share percent
- expenses support foreign amount/currency/exchange rate
- reports derive summaries from stored budgets and expenses
- suggestions can be dismissed per user

## 13. Dashboard, Goals, Activity, Badges

Study:

- `Dashboard/DashboardController.swift`
- `Dashboard/DashboardService.swift`
- `Dashboard/DashboardRepository.swift`
- `Dashboard/GoalsController.swift`
- `Activity/UserActivityController.swift`
- `Activity/UserActivityService.swift`
- `Activity/UserActivityRepository.swift`
- `Gamification/BadgeController.swift`
- `Gamification/BadgeService.swift`
- `Gamification/BadgeDefinitions.swift`

Dashboard endpoints:

- `GET /v1/dashboard`
- `GET /v1/dashboard/insights`

Goals endpoints:

- `GET /v1/goals`
- `POST /v1/goals`
- `GET /v1/goals/:id`
- `PATCH /v1/goals/:id`
- `PATCH /v1/goals/:id/status`
- `DELETE /v1/goals/:id`

Activity endpoint:

- `GET /v1/activities`

Badge endpoint:

- `GET /v1/badges`

Important topics:

- dashboard aggregates portfolio, expenses, goals, activity, statistics
- system goals can be derived from user state
- user activities record events for the activity feed
- badge progress is calculated from user data
- dashboard reads from multiple repositories/services

## 14. User Profile And PII Encryption

Study:

- `UserProfile/UserProfileController.swift`
- `UserProfile/UserProfileService.swift`
- `UserProfile/UserProfileRepository.swift`
- `UserProfile/UserProfileDTOs.swift`
- `Security/UserPIIEncryption.swift`
- `docs/pii-encryption.md`

Profile endpoints:

- `GET /v1/users`
- `PUT /v1/users`
- `PATCH /v1/users/username`
- `PATCH /v1/users/email`
- `PATCH /v1/users/password`
- `DELETE /v1/users`
- admin/by-id style routes under `/v1/users/:id`

Important topics:

- profile reads/writes are user-scoped
- sensitive fields are encrypted
- legacy plaintext fields were migrated/dropped
- repository owns encryption/decryption details
- service owns validation and update rules

PII concepts:

- encryption bootstrap from environment
- encrypted field backfill migrations
- avoiding plaintext logs
- account deletion behavior

## 15. Billing, Trials, Coupons, RevenueCat

Study:

- `Billing/BillingController.swift`
- `Billing/BillingService.swift`
- `Billing/BillingContextService.swift`
- `Billing/EntitlementResolver.swift`
- `Billing/TrialService.swift`
- `Billing/CouponService.swift`
- `Billing/RevenueCatWebhookController.swift`
- `Billing/BillingModels.swift`
- `Billing/BillingErrorMiddleware.swift`

Billing endpoints:

- `GET /v1/billing/me`
- `POST /v1/billing/coupons/validate`
- `POST /v1/billing/coupons/redeem`
- `POST /webhooks/revenuecat`

Important models:

- `Subscription`
- `Entitlement`
- `BillingEvent`
- `UsageCounter`
- `TrialWarning`
- `Coupon`
- `CouponRedemption`

Important topics:

- entitlements determine free/starter/premium access
- `BYPASS_BILLING=true` grants premium behavior in dev/TestFlight-style environments
- premium emails can be configured with `BILLING_PREMIUM_EMAILS`
- usage counters track limits such as holdings/watchlist/imports/targets/reports
- RevenueCat webhook events are persisted and processed idempotently
- trial expiration job runs through app lifecycle
- coupons can grant trial days and discounts

### Subscription Plans & Products

Three RevenueCat products are expected:

| Product ID | Billing | Notes |
|---|---|---|
| `pro_annual` | Yearly | Best value; 14-day free trial; shown as prominent card in paywall |
| `pro_monthly` | Monthly | Flexible billing; no trial |
| `pro_weekly` | Weekly | Short-term access; no trial |

RevenueCat entitlement ID: `pro`

### Paywall Feature Gates

#### Stock Detail Tabs (iOS `StockDetailScreen`)

| Tab | Free | Pro |
|---|---|---|
| Chart | ✅ | ✅ |
| Overview | ✅ | ✅ |
| News | ✅ | ✅ |
| Forecast | ✅ | ✅ |
| Statements | ❌ blur + lock | ✅ |
| Analysis | ❌ blur + lock | ✅ |
| Compare | ❌ blur + lock | ✅ |
| Earnings | ❌ blur + lock | ✅ |

Tapping a locked tab shows `PaywallView` sheet. Implemented via `ProGateView` wrapper component.

#### Expense & Budget Features (iOS `ExpensesPlannerScreen`)

| Feature | Free | Pro |
|---|---|---|
| Record spend | ✅ | ✅ |
| Monthly budget setup | ✅ | ✅ |
| Current month overview | ✅ | ✅ |
| Planned items (current month) | ✅ | ✅ |
| Category breakdown (current month) | ✅ | ✅ |
| Year overview / history | ❌ | ✅ |
| Smart suggestions | ❌ | ✅ |
| Household partner | ❌ | ✅ |
| Recurring templates | ❌ | ✅ |
| Reports / Comparison screen | ❌ | ✅ |
| Cloud sync | ❌ | ✅ |

#### Backend Enforcement

The backend enforces limits via `UsageCounter` and `EntitlementResolver`:

- free tier: limited holdings count, watchlist items, CSV imports, targets, reports
- pro tier: unlimited access to all features
- `BYPASS_BILLING=true` bypasses all gates (dev/TestFlight)
- `BILLING_PREMIUM_EMAILS` grants pro to specific emails without purchase

### iOS Paywall UI (`PaywallView`)

The modal paywall (`PaywallView`) is shown when a free user taps a gated feature. It follows the app design system:

- Norviqa logo in tinted circle hero
- Feature comparison list with icon per row
- Vertical plan cards: Yearly (prominent, "BEST VALUE" badge), Monthly, Weekly
- Sticky CTA footer with gradient fade: "Get Pro Access" button + footer links
- Uses `AppTheme.Colors.*` throughout — no hardcoded colors
- Dismisses automatically on `billingManager.isPro` becoming true

A pre-login variant (`PreLoginPaywallScreen`) is shown during onboarding before the user has an account, with "Start Free Trial" + "Continue with Free" actions.

## 16. Notifications And APNS

Study:

- `Notifications/PushNotificationsController.swift`
- `Notifications/PushDeviceService.swift`
- `Notifications/PushNotificationSender.swift`
- `Notifications/APNSBootstrapConfiguration.swift`
- `Notifications/TargetAlertEvaluator.swift`
- `Notifications/TargetAlertPoller.swift`
- `docs/APNS.md`

Push endpoints:

- `PUT /v1/notifications/apns/device`
- `POST /v1/notifications/apns/device/deactivate`

Important models:

- `PushDevice`
- `Target`

Important topics:

- APNS config comes from environment
- missing APNS config falls back to no-op sender
- devices are user-scoped
- target alerts are periodically evaluated
- target alert evaluator sends push notifications when conditions are met
- alerts mark triggered time and price

## 17. News, Market News Archive, Webhooks

Study:

- `News/NewsController.swift`
- `News/NewsService.swift`
- `News/NewsRepository.swift`
- `News/NewsProvider.swift`
- `News/FinnhubWebhookController.swift`
- `Market/MarketNewsArchiveService.swift`

News endpoints:

- `GET /v1/news`
- `GET /v1/news/feed`
- `POST /v1/news`
- `POST /v1/news/sync`
- `GET /v1/news/:id`
- `PUT /v1/news/:id`
- `DELETE /v1/news/:id`
- `POST /webhooks/finnhub/news`

Important topics:

- user-created/synced news is user-scoped
- feed uses tracked symbols
- Finnhub webhook requires secret verification
- market news archive stores provider news for reuse
- sync workflows should avoid duplicates and preserve ownership

## 18. Brokers, CSV Import, IBKR

Study:

- `Broker/BrokerController.swift`
- `Broker/BrokersService.swift`
- `Broker/BrokersRepository.swift`
- `Broker/BrokerProvider.swift`
- `Broker/CsvImportDTOs.swift`
- `Services/CsvImportService.swift`
- `docs/ibkr-integration.md`
- `docs/ibkr-sync.md`

Broker endpoints:

- `GET /v1/brokers`
- `GET /v1/brokers/holdings`
- `GET /v1/brokers/:provider`
- `POST /v1/brokers/import/csv`
- `POST /v1/brokers/import/csv/commit`
- `POST /v1/brokers/ibkr/sync`

Important topics:

- CSV upload size limits
- CSV preview vs commit
- broker connection records
- IBKR provider integration
- import transactions should be atomic
- imported symbols can update portfolio/watchlist state
- usage counter increments for CSV imports

## 19. Crypto

Study:

- `Crypto/CryptoController.swift`
- `Crypto/CryptoService.swift`
- `Crypto/CryptoDataProvider.swift`
- `Crypto/CryptoDTOs.swift`
- `Models/CryptoPortfolioItem.swift`

Crypto endpoints:

- `GET /v1/crypto/list`
- `GET /v1/crypto/quote/:symbol`
- `GET /v1/crypto/quote-short/:symbol`
- `GET /v1/crypto/batch-quotes`
- `GET /v1/crypto/history/:resolution/:symbol`
- `GET /v1/crypto/news`
- `GET /v1/crypto/news/:symbol`
- portfolio CRUD under `/v1/crypto/portfolio`

Important topics:

- FMP provider supplies crypto data when configured
- mock provider is used when FMP is unavailable
- crypto portfolio is user-scoped
- symbols are normalized

## 20. Statistics, Earnings, Assets, Feedback

Study:

- `Statistics/StatisticsController.swift`
- `Statistics/StatisticsService.swift`
- `Statistics/StatisticsRepository.swift`
- `Earnings/EarningsController.swift`
- `Earnings/EarningsService.swift`
- `Assets/AssetsController.swift`
- `Feedback/FeedbackController.swift`

Statistics endpoints:

- stock scorecard
- allocation
- sector allocation
- calendar performance
- contribution analysis
- winners/losers
- volatility snapshot
- currency split
- scenario tracking
- notes quality
- imported-stocks overview
- watchlist/looklist/market/overview statistics

Assets endpoint:

- `GET /v1/assets/search`

Feedback endpoint:

- `POST /v1/feedback`

Important topics:

- statistics aggregate portfolio/watchlist/valuation data
- statistics are user-scoped
- some statistics are computed live; snapshots can cache payloads
- feedback is attached to the authenticated user
- earnings depends on provider availability

## 21. Observability And Operations

Study:

- `Shared/RequestLoggingMiddleware.swift`
- `Shared/JSONLogHandler.swift`
- `Shared/ProductionConfiguration.swift`
- `docs/Observability.md`
- `docs/deployment/operations-runbook.md`
- `docker-compose.observability.yml`

Health/readiness checks include:

- database
- Redis
- mailer
- APNS
- market data provider availability

Operational topics:

- structured logging
- request IDs
- latency logging
- tracing auto-propagation
- production env validation
- Docker workflows
- backup/restore scripts
- deployment guide

## 22. Testing Strategy

Study:

- `AuthTests.swift`
- `BillingTests.swift`
- `Expenses/ExpensesTests.swift`
- `FeedbackTests.swift`
- `NewsServiceTests.swift`
- `OpenAPIDocsTests.swift`
- `StatisticsServiceTests.swift`
- `StocksRepositoryTests.swift`
- `StocksServiceTests.swift`
- `UserActivityTests.swift`
- `UserPIIEncryptionTests.swift`
- `UserProfileTests.swift`
- `DatabaseTestLock.swift`

Test patterns:

- boot a Vapor app in test mode
- run migrations against isolated schema/database
- authenticate test users
- call HTTP routes with `app.testing().test(...)`
- assert status codes and decoded DTOs
- test repositories/services directly
- use fake providers for OAuth/market dependencies
- serialize database-sensitive tests where needed

Important concepts:

- test data must be user-scoped
- tests should prove ownership isolation
- tests should avoid external API calls
- OpenAPI docs tests protect API docs availability
- PII tests protect encryption behavior

## 23. Important Swift And Vapor Structures

Swift structures to understand:

- `struct` for DTOs and value data
- `final class` for Fluent models
- `enum` for modes, providers, tiers, statuses
- `protocol` for services/repositories/providers
- `extension Application` for dependency storage
- `Sendable` for concurrency-safe protocols
- `@unchecked Sendable` for Fluent models used across concurrency boundaries
- `async throws` for request handlers and services
- `guard` for input validation
- `do/catch` for external/provider error mapping

Vapor structures to understand:

- `Application`
- `Request`
- `Response`
- `Content`
- `RouteCollection`
- `RoutesBuilder`
- `Middleware`
- `Abort`
- `HTTPStatus`
- `Environment`
- `Client`
- `LifecycleHandler`
- `Authenticatable`
- `BearerAuthorization`

Fluent structures to understand:

- `Model`
- `AsyncMigration`
- `Database`
- `SQLDatabase`
- `@ID`
- `@Field`
- `@OptionalField`
- `@Parent`
- query builders
- transactions

## 24. How To Add A New API Feature

Use this implementation sequence:

1. Define DTOs: request, response, list/query payloads.
2. Add Fluent model if data must persist.
3. Add migration and register it in `configure.swift`.
4. Add repository protocol and database implementation if persistence is non-trivial.
5. Add service protocol and default implementation for business rules.
6. Add `Application` storage keys for dependency wiring.
7. Wire service/repository in `configure.swift`.
8. Add controller with route collection.
9. Register controller in `routes.swift`.
10. Protect routes with `SessionToken` if user-specific.
11. Enforce user ownership in every query.
12. Add validation and client-safe errors.
13. Add tests for controller/service/repository paths.
14. Update `openapi.yaml` if endpoint is public to the client.
15. Update docs if behavior affects app architecture or operations.

## 25. Study Checklist: 8 Weeks

This checklist replaces the old `docs/study-checklist.md`.

Target pace: 60-90 minutes per day.

### Week 1: Swift Core

- [ ] Day 1: Set up study environment, verify `swift --version`, create `notes.md`.
- [ ] Day 2: Practice `struct`, `class`, `enum`, and protocol basics.
- [ ] Day 3: Drill optionals with `if let`, `guard let`, and nil coalescing.
- [ ] Day 4: Practice functions, computed properties, mutability, and immutability.
- [ ] Day 5: Implement custom errors and `throws` in a small parser.
- [ ] Day 6: Write XCTest cases for parser success and error paths.
- [ ] Day 7: Review/refactor exercises and summarize weak points.

### Week 2: Concurrency, Codable, SPM

- [ ] Day 8: Learn `async/await` with a fake async API client.
- [ ] Day 9: Use `async let` and task groups for parallel calls.
- [ ] Day 10: Learn `@MainActor`, `Sendable`, and actors.
- [ ] Day 11: Practice `Codable` for nested JSON and optional fields.
- [ ] Day 12: Add date decoding strategies and numeric formatting rules.
- [ ] Day 13: Organize code as a Swift package and write tests.
- [ ] Day 14: Review concurrency and decoding mistakes.

### Week 3: Vapor Basics And CRUD

- [ ] Day 15: Read `configure.swift` and `routes.swift`.
- [ ] Day 16: Trace one existing resource from route to model.
- [ ] Day 17: Add a small model and migration in a branch/exercise.
- [ ] Day 18: Implement `POST` and `GET list`.
- [ ] Day 19: Implement `GET by id`, `PATCH/PUT`, and `DELETE`.
- [ ] Day 20: Add validation and consistent error responses.
- [ ] Day 21: Manually test endpoints and edge cases.

### Week 4: Auth, Middleware, Ownership

- [ ] Day 22: Trace auth flow: token issue, refresh, protected groups.
- [ ] Day 23: Protect a route with `SessionToken`.
- [ ] Day 24: Enforce ownership checks for reads/writes.
- [ ] Day 25: Move business logic from controller to service.
- [ ] Day 26: Add repository/service tests.
- [ ] Day 27: Add integration tests for auth plus CRUD.
- [ ] Day 28: Draw the dependency graph for one feature.

### Week 5: Real Project Feature Study

- [ ] Day 29: Study Stocks: controller, service, repository, model.
- [ ] Day 30: Study Expenses: controllers, service, budget/report derivation.
- [ ] Day 31: Study Market: providers, cache, TTLs, disabled-provider fallback.
- [ ] Day 32: Study Billing: entitlements, usage counters, RevenueCat webhook.
- [ ] Day 33: Study UserProfile: encrypted fields and repository mapping.
- [ ] Day 34: Study Notifications: APNS device registration and target alerts.
- [ ] Day 35: Study Tests: route tests, repository tests, app setup.

### Week 6: API Contract And Client Alignment

- [ ] Day 36: Compare `openapi.yaml` with a controller.
- [ ] Day 37: Trace one iOS request to backend endpoint and DTO.
- [ ] Day 38: Check JSON date/key conventions.
- [ ] Day 39: Add or update one OpenAPI section.
- [ ] Day 40: Verify client-safe error behavior.
- [ ] Day 41: Validate free/starter/premium behavior for one feature.
- [ ] Day 42: Run backend and iOS happy-path manually.

### Week 7: Integration Hardening

- [ ] Day 43: Add pagination/filtering to a practice endpoint.
- [ ] Day 44: Add server-side sorting or query params.
- [ ] Day 45: Standardize API error schema for one area.
- [ ] Day 46: Add request/response logging context to one flow.
- [ ] Day 47: Add provider fallback handling to one external API path.
- [ ] Day 48: Add token refresh/re-login failure handling test.
- [ ] Day 49: Validate OpenAPI docs and DTO alignment.

### Week 8: Production Readiness

- [ ] Day 50: Review migrations and rollback/data-safety risks.
- [ ] Day 51: Add a smoke test checklist for startup and key endpoints.
- [ ] Day 52: Add observability checklist for logs, failures, latency.
- [ ] Day 53: Run full backend test suite and fix flaky tests.
- [ ] Day 54: Run full manual system test from iOS app to backend.
- [ ] Day 55: Write/update architecture docs for one feature.
- [ ] Day 56: Self-assess against this guide and plan the next 4 weeks.

## 26. Best Reading Order

Read these in order:

1. `configure.swift`
2. `routes.swift`
3. `Shared/JSONCoder+Backend.swift`
4. `Auth/SessionToken.swift`
5. `Auth/AuthController.swift`
6. `Auth/AuthService.swift`
7. `Auth/AuthRepository.swift`
8. `Models/User.swift`
9. `Stocks/StockController.swift`
10. `Stocks/StockService.swift`
11. `Stocks/StockRepository.swift`
12. `Expenses/ExpensesController.swift`
13. `Expenses/BudgetController.swift`
14. `Expenses/ReportsController.swift`
15. `Expenses/ExpensesService.swift`
16. `Market/MarketDataController.swift`
17. `Market/MarketDataService.swift`
18. `Billing/EntitlementResolver.swift`
19. `Billing/BillingContextService.swift`
20. `Notifications/TargetAlertEvaluator.swift`
21. `Tests/StockPlanBackendTests/AuthTests.swift`
22. `Tests/StockPlanBackendTests/Expenses/ExpensesTests.swift`

## 27. Final Mental Model

The backend is a feature-oriented Vapor API. Controllers are route adapters. Services hold business rules. Repositories and Fluent models own persistence. Providers isolate external APIs. `Application` storage wires dependencies. `SessionToken` protects user routes. Most data is user-scoped and must always be queried through the authenticated user id.

If you understand those boundaries, you can safely add features, debug request behavior, protect user data, and keep the iOS client contract stable.

---

## 📋 Comprehensive Structural Analysis (Full-Codebase Audit 2026-04-25)

### Repository Layout & Module Map

```
StockPlanBackend/
├── Sources/StockPlanBackend/
│   ├── entrypoint.swift          # @main, env detection, app bootstrap
│   ├── configure.swift           # middleware, DB, services, migrations, routes
│   ├── routes.swift              # health, OpenAPI, webhooks, /v1 controller registration
│   ├── openapi.yaml              # OpenAPI spec (source-of-truth for client generation)
│   ├── Models/ (52 files)        # Fluent schema: User, Stock, Position, Transaction, …
│   ├── Migrations/ (71 files)    # chronological schema evolution
│   ├── Auth/                     # register/login/MFA/OAuth; SessionToken JWT
│   ├── Stocks/                   # portfolio CRUD, bulk create, valuation, insights
│   ├── Market/                   # quote/history/news; FMP/Finnhub/IBKR providers
│   ├── Portfolio/                # summary, performance, P&L, portfolio lists
│   ├── Crypto/                   # crypto portfolio + market data
│   ├── Expenses/                 # budget plans, categories, household sharing
│   ├── UserProfile/              # profile CRUD, PII encryption
│   ├── Billing/                  # RevenueCat webhook, coupons, plan/limits
│   ├── Notifications/            # APNS sender, device registry, target alert poller
│   ├── Statistics/               # aggregated dashboard snapshots
│   ├── Earnings/                 # earnings calendar provider
│   ├── Broker/                   # CSV import, OAuth flow, IBKR sync integration
│   ├── News/                     # Finnhub webhook ingest, news service
│   ├── Gamification/Badges/      # badge definitions & awarding
│   ├── Activity/                 # user activity log
│   ├── Feedback/                 # user feedback submissions
│   ├── Dashboard/                # home-dashboard aggregation, goals
│   ├── Shared/                   # backend-only middleware & JSON config
│   └── Services/                 # AuthTokenCleanup, CsvImportService, MailerService
├── Tests/StockPlanBackendTests/  # XCTest suite (17 files)
├── Package.swift                 # Vapor 4.115 + Fluent + Postgres + JWT + Redis + APNS
├── Dockerfile / Dockerfile.dev   # multi-stage release + hot-reload dev images
├── docker-compose.yml / .dev.yml / .production.yml
├── Makefile                      # dev/start/migrate/lint/health/rollback/backup targets
└── scripts/                      # dev-watch.sh, ops/, build_container_image_local.sh

Total Swift files: ~243 (backend) + ~20 (Shared submodule) | Tests: 17
```

### Tech Stack Deep Dive

| Layer | Technology | Purpose |
|-------|------------|---------|
| Web framework | Vapor 4.x | Routing, middleware, request/response lifecycle |
| ORM | Fluent 4.9 + FluentKit 1.55 + PostgresDriver 2.8 | Database abstraction, migrations, query building |
| Auth | JWTKit (JWT 5.0) | Session token signing/validation |
| Cache | Redis 4.8 (RediStack) | optional caching & session store |
| Push | APNS 4.0 + VaporAPNS | Apple Push Notification service |
| Observability | swift-otel 1.0 + swift-log 1.5 | OpenTelemetry tracing, structured logging |
| HTTP client | Vapor's `Client` (where used) / custom provider HTTP | External API calls |
| Mail | Resend integration (ResendMailerService) | transactional email (optional) |
| Package manager | SwiftPM 6.0 (swift-tools-version:6.0) | dependencies, builds |
| Container runtime | Docker (swift:6.3-noble) | production multi-stage build + jemalloc |

### Database Schema Highlights (52 Models)

Core tables and relationships:

- **users** – primary identity; fields: email, password_hash, username, bio (plaintext + encrypted), avatar URLs, household_partner_display_name (encrypted), lockout/verification flags
- **refresh_tokens** – revocable long-lived tokens; userId, tokenHash, expiresAt, revokedAt
- **mfa_challenges** – multi-factor auth challenges; codeHash, expiresAt, verifiedAt
- **oauth_flows** – PKCE state for OAuth; provider, state, nonce, codeVerifier, redirectURI
- **oauth_identities** – linked external identities; provider, subject, email verified flag
- **stocks** – user holdings; symbol, quantity, buy_price, buy_date, notes, account_id, import_source
- **positions** – broker-sync snapshot; quantity, average_cost, currency, market_value, last_price_date
- **transactions** – broker-provided fills/trades; type, quantity, price, currency, trade_date, settle_date, external_id
- **watchlist_items** – watchlist entries; symbol, notes, order_index
- **portfolio_lists** / **watchlist_lists** – user-named collections; is_default flag
- **stock_valuations** – DCF draft valuations per user/stock; assumptions + notes
- **targets** – base/bear/bull price targets with scenario, timeframe, rationale
- **expenses** – pillar-based spending; title, amount, pillar enum, occurred_on, split_mode, user_share_percent, linked_item_id (to BudgetPlanItem)
- **budget_plan_items** – planned spending line items; pillar, planned_amount, split_mode
- **budget_snapshots** – monthly/periodic budget view; total_budget, total_spent
- **news_item** – archived stock news; source, title, url, published_at, image_url
- **push_devices** – APNS device tokens; platform, apns_environment, authorization_status, is_active, last_seen_at
- **broker_connections** – OAuth state for broker integrations; provider, access_token, refresh_token, expires_at, status
- **coupons** / **coupon_redemptions** – promotional codes; plan, tier, expires_at, redemption tracking
- **user_activity** – activity log for gamification and analytics
- **user_badges** – awarded badges per user
- **statistics_snapshot** – cached portfolio stats per day/week for performance
- **goal** – financial goals with status, completed_at, user_id
- **report_suggestion_dismissal** – UX personalization for in-app report suggestions

Indexes & constraints: added over 71 migrations including user-scoped indexes, quote cache lookups, and foreign keys.

### Service & Provider Architecture

**Pattern**: Protocol + Default implementation + Application DI

Repository protocols define data access; services orchestrate domain logic; providers fetch external data.

Example repository pattern (StockRepository):
```swift
protocol StocksRepository: Sendable {
  func list(userId: UUID, portfolioListId: UUID?, limit: Int, on db: any Database) async throws -> [Stock]
  func find(id: UUID, userId: UUID, on db: any Database) async throws -> Stock?
  func bulkCreate(payloads: [StockRequest], userId: UUID, on db: any Database) async throws -> [BulkStockResultItem]
  // …
}
struct DatabaseStocksRepository: StocksRepository { … }
```

Provider abstraction (MarketDataProvider):
```swift
protocol MarketDataProvider {
  func fetchQuote(symbol: String) async throws -> MarketProviderQuote
  func fetchHistory(symbol: String, range: HistoryRange) async throws -> MarketProviderHistory
  // …
}
struct FMPMarketDataProvider: MarketDataProvider { … }
struct FinnhubMarketDataProvider: MarketDataProvider { … }
struct DisabledMarketDataProvider: MarketDataProvider { … } // fallback
```

Provider selection at runtime in `configure.swift` based on environment variables (FMP key, Finnhub key, IBKR base URL). If required keys missing, falls back to Disabled provider.

### Security & Encryption

- **JWT session tokens**: HS256 signed; `exp` claim enforced; stateless auth for API routes
- **Refresh tokens**: persistent, one-time revocation; cleanup job (`AuthTokenCleanup`) runs every 10s in background
- **Password hashing**: Bcrypt/SHA256 via Vapor's `Bcrypt` (standard Vapor)
- **MFA**: one-time codes stored hashed; challenge expiry (`MFAChallenge` model)
- **OAuth PKCE**: code_verifier stored, state+nonce validated; identity linking across providers
- **PII encryption**: field-level AES-GCM via `UserPIIEncryption`; key rotation supported; `User.hydrateProtectedFields`
- **Rate limiting**: `RateLimitMiddleware` on auth routes to prevent enumeration/brute force
- **CORS**: configurable allowed origins via `ALLOWED_ORIGINS`; tightened in production
- **Account lockout**: `failed_login_count`, `lockout_until` on `User` model

### Observability & Diagnostics

- **Structured logging**: `JSONLogHandler` outputs JSON logs; `RequestLoggingMiddleware` adds request_id, method, path, status, latency, user_id
- **Tracing**: `TracingMiddleware` + swift-otel; `app.traceAutoPropagation = true` propagates W3C traceparent
- **Health checks**: `/health/ready` aggregates DB/Redis/mail/APNS/marketData checks + version + environment name
- **Metrics**: Not explicitly exposed; could add Prometheus endpoint or OTel metrics later
- **Error tracking**: Sentry not wired in backend (only iOS); errors flow through `APIErrorMiddleware` & `BillingErrorMiddleware`

### Market Data Provider Detail

External providers configured via env:

| Provider | Env key(s) | Status |
|----------|------------|--------|
| FMP (Financial Modeling Prep) | `FMP_API_KEY`, `FMP_BASE_URL` | Primary quote/history/news |
| Finnhub | `FINNHUB_API_KEY`, `FINNHUB_BASE_URL` | Secondary; also provides grades consensus, basic financials |
| IBKR (Interactive Brokers) | `IBKR_API_BASE_URL` | Client Portal API; currently disabled provider; placeholder `IBKRBrokerIntegration` present but not selected |

Provider selection occurs in `configure.swift` when registering `MarketDataProvider` in Application DI. If neither API key present, `DisabledMarketDataProvider` returns empty data.

### External API Call Chain

Each request flows:

```
Controller endpoint
→ calls application.marketDataService
→ iterates configured providers
→ first available provider returns data
→ maps to DTOs (MarketDataDTOs)
→ returns to controller → JSON response
```

Implementations (`FMPMarketDataProvider`, `FinnhubMarketDataProvider`) use Vapor's `Client` to make HTTP calls; parse JSON into provider-specific structs then map to canonical DTOs.

### Deployment & Environments

**Environments**: `.development`, `.testing`, `.production` (Vapor detects via --env flag or ENVIRONMENT var)

**Config files**:
- `.env` – local dev overrides
- `.env.development` – dev environment values
- `.env.production` – production secrets template

**Docker**:
- Release image: `swift:6.3.1-noble`, static Swift runtime, jemalloc, multi-stage
- Dev image: `swift:6.1-noble` with inotify-tools; `scripts/dev-watch.sh` rebuilds on file change
- Postgres + Redis via compose
- Migrations run in `migrate` service container

**Make targets**:
- `make dev` – hot-reload dev
- `make start` – build + migrate + release app
- `make migrate` – DB migrations only
- `make lint` – SwiftLint auto-fix
- `make backend-test` – `swift test`
- `make health` – readiness check against live domain
- `make backup-db` / `make restore-drill` – Postgres backup/restore (GPG encrypted)
- `make production-preflight` – cert/domain checks pre-deploy

**CI/CD**: `.github/workflows/deploy.yml` and `deploy-dev.yml` – build container, push to GHCR, SSH deploy to Hetzner (inferred from README).

### RevenueCat Integration

- Webhook: `POST /webhooks/revenuecat` with Authorization secret (`REVENUECAT_WEBHOOK_SECRET`)
- Event processor: `BillingService.process(event:rawPayload:on:)`
- Updates `BillingContext` (user entitlement snapshot)
- iOS client uses RevenueCat SDK Purchases; anonymous aliasing on login; `PaywallView` presents products
- Products expected: `pro_monthly`, `pro_weekly`, `pro_annual`
- Backend feature gates via `BillingMiddleware` or service checks

### Push Notifications (APNS)

- Device registration: `POST /notifications/devices` stores token + platform + environment
- Target alerts: `TargetAlertPoller` runs periodic job; evaluates user targets vs current price; enqueues send
- Sender: `APNSPushNotificationSender` builds payload with category `TARGET_ALERT`, deep link into stock detail
- Bootstrap: APNS credentials from env (`APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY_P8`, `APNS_TOPIC`)
- Silent fallback: `NoopPushNotificationSender` when credentials missing

### OpenAPI & Client Generation

- `openapi.yaml` present at repo root
- `swift-openapi-generator` dependency; `OpenAPIDocsTests` validates spec drift
- iOS uses AnyAPI with manually curated endpoints; potential to switch to generated client in future

### Testing Strategy

- **Unit tests**: `Tests/StockPlanBackendTests` – repository tests, service tests, DTO decoding/encoding
- **Integration**: Possibly tests for controller routes with in-memory DB
- **No UI tests** (backend is headless)
- Test DB configured via `TEST_DATABASE_*` env vars; defaults to localhost:5432

Coverage: moderate (~17 test files). Focus areas to expand: provider fallback logic, auth flows, billing edge cases.

### Potential / Known Gaps

- WebSocket implementation claimed in README not yet present
- IBKR full OAuth token exchange / revocation not fully implemented
- Rate limit configuration (thresholds) hard-coded or missing
- Metrics endpoint (Prometheus/OTLP metrics) not exported
- Backup/restore scripts assume GPG key availability
- Localization/i18n not yet supported
- Audit trail for admin actions missing

---

## 🔗 Related Documentation

- `APNS.md` – APNS bootstrap, certificate setup
- `MFA.md` – multi-factor auth flow
- `oauth.md` – OAuth provider setup and identity linking
- `Observability.md` – tracing + logging setup
- `revenuecat-setup.md` – RevenueCat product/entitlement configuration
- `ibkr-integration.md` – IBKR sync flow and deployment notes
- `persistence-standards.md` – database design principles
- `pii-encryption.md` – field-level encryption design


---

## 📋 Comprehensive Structural Analysis (Full-Codebase Audit 2026-04-25)

### Repository Layout & Module Map

```
StockPlanBackend/
├── Sources/StockPlanBackend/
│   ├── entrypoint.swift          # @main, env detection, app bootstrap
│   ├── configure.swift           # middleware, DB, services, migrations, routes
│   ├── routes.swift              # health, OpenAPI, webhooks, /v1 controller registration
│   ├── openapi.yaml              # OpenAPI spec (source-of-truth for client generation)
│   ├── Models/ (52 files)        # Fluent schema: User, Stock, Position, Transaction, …
│   ├── Migrations/ (71 files)    # chronological schema evolution
│   ├── Auth/                     # register/login/MFA/OAuth; SessionToken JWT
│   ├── Stocks/                   # portfolio CRUD, bulk create, valuation, insights
│   ├── Market/                   # quote/history/news; FMP/Finnhub/IBKR providers
│   ├── Portfolio/                # summary, performance, P&L, portfolio lists
│   ├── Crypto/                   # crypto portfolio + market data
│   ├── Expenses/                 # budget plans, categories, household sharing
│   ├── UserProfile/              # profile CRUD, PII encryption
│   ├── Billing/                  # RevenueCat webhook, coupons, plan/limits
│   ├── Notifications/            # APNS sender, device registry, target alert poller
│   ├── Statistics/               # aggregated dashboard snapshots
│   ├── Earnings/                 # earnings calendar provider
│   ├── Broker/                   # CSV import, OAuth flow, IBKR sync integration
│   ├── News/                     # Finnhub webhook ingest, news service
│   ├── Gamification/Badges/      # badge definitions & awarding
│   ├── Activity/                 # user activity log
│   ├── Feedback/                 # user feedback submissions
│   ├── Dashboard/                # home-dashboard aggregation, goals
│   ├── Shared/                   # backend-only middleware & JSON config
│   └── Services/                 # AuthTokenCleanup, CsvImportService, MailerService
├── Tests/StockPlanBackendTests/  # XCTest suite (17 files)
├── Package.swift                 # Vapor 4.115 + Fluent + Postgres + JWT + Redis + APNS
├── Dockerfile / Dockerfile.dev   # multi-stage release + hot-reload dev images
├── docker-compose.yml / .dev.yml / .production.yml
├── Makefile                      # dev/start/migrate/lint/health/rollback/backup targets
└── scripts/                      # dev-watch.sh, ops/, build_container_image_local.sh

Total Swift files: ~243 (backend) + ~20 (Shared submodule) | Tests: 17
```

### Tech Stack Deep Dive

| Layer | Technology | Purpose |
|-------|------------|---------|
| Web framework | Vapor 4.x | Routing, middleware, request/response lifecycle |
| ORM | Fluent 4.9 + FluentKit 1.55 + PostgresDriver 2.8 | Database abstraction, migrations, query building |
| Auth | JWTKit (JWT 5.0) | Session token signing/validation |
| Cache | Redis 4.8 (RediStack) | optional caching & session store |
| Push | APNS 4.0 + VaporAPNS | Apple Push Notification service |
| Observability | swift-otel 1.0 + swift-log 1.5 | OpenTelemetry tracing, structured logging |
| HTTP client | Vapor's `Client` (where used) / custom provider HTTP | External API calls |
| Mail | Resend integration (ResendMailerService) | transactional email (optional) |
| Package manager | SwiftPM 6.0 (swift-tools-version:6.0) | dependencies, builds |
| Container runtime | Docker (swift:6.3-noble) | production multi-stage build + jemalloc |

### Database Schema Highlights (52 Models)

Core tables and relationships:

- **users** – primary identity; fields: email, password_hash, username, bio (plaintext + encrypted), avatar URLs, household_partner_display_name (encrypted), lockout/verification flags
- **refresh_tokens** – revocable long-lived tokens; userId, tokenHash, expiresAt, revokedAt
- **mfa_challenges** – multi-factor auth challenges; codeHash, expiresAt, verifiedAt
- **oauth_flows** – PKCE state for OAuth; provider, state, nonce, codeVerifier, redirectURI
- **oauth_identities** – linked external identities; provider, subject, email verified flag
- **stocks** – user holdings; symbol, quantity, buy_price, buy_date, notes, account_id, import_source
- **positions** – broker-sync snapshot; quantity, average_cost, currency, market_value, last_price_date
- **transactions** – broker-provided fills/trades; type, quantity, price, currency, trade_date, settle_date, external_id
- **watchlist_items** – watchlist entries; symbol, notes, order_index
- **portfolio_lists** / **watchlist_lists** – user-named collections; is_default flag
- **stock_valuations** – DCF draft valuations per user/stock; assumptions + notes
- **targets** – base/bear/bull price targets with scenario, timeframe, rationale
- **expenses** – pillar-based spending; title, amount, pillar enum, occurred_on, split_mode, user_share_percent, linked_item_id (to BudgetPlanItem)
- **budget_plan_items** – planned spending line items; pillar, planned_amount, split_mode
- **budget_snapshots** – monthly/periodic budget view; total_budget, total_spent
- **news_item** – archived stock news; source, title, url, published_at, image_url
- **push_devices** – APNS device tokens; platform, apns_environment, authorization_status, is_active, last_seen_at
- **broker_connections** – OAuth state for broker integrations; provider, access_token, refresh_token, expires_at, status
- **coupons** / **coupon_redemptions** – promotional codes; plan, tier, expires_at, redemption tracking
- **user_activity** – activity log for gamification and analytics
- **user_badges** – awarded badges per user
- **statistics_snapshot** – cached portfolio stats per day/week for performance
- **goal** – financial goals with status, completed_at, user_id
- **report_suggestion_dismissal** – UX personalization for in-app report suggestions

Indexes & constraints: added over 71 migrations including user-scoped indexes, quote cache lookups, and foreign keys.

### Service & Provider Architecture

**Pattern**: Protocol + Default implementation + Application DI

Repository protocols define data access; services orchestrate domain logic; providers fetch external data.

Example repository pattern (StockRepository):
```swift
protocol StocksRepository: Sendable {
  func list(userId: UUID, portfolioListId: UUID?, limit: Int, on db: any Database) async throws -> [Stock]
  func find(id: UUID, userId: UUID, on db: any Database) async throws -> Stock?
  func bulkCreate(payloads: [StockRequest], userId: UUID, on db: any Database) async throws -> [BulkStockResultItem]
  // …
}
struct DatabaseStocksRepository: StocksRepository { … }
```

Provider abstraction (MarketDataProvider):
```swift
protocol MarketDataProvider {
  func fetchQuote(symbol: String) async throws -> MarketProviderQuote
  func fetchHistory(symbol: String, range: HistoryRange) async throws -> MarketProviderHistory
  // …
}
struct FMPMarketDataProvider: MarketDataProvider { … }
struct FinnhubMarketDataProvider: MarketDataProvider { … }
struct DisabledMarketDataProvider: MarketDataProvider { … } // fallback
```

Provider selection at runtime in `configure.swift` when registering `MarketDataProvider` in Application DI. If neither API key present, `DisabledMarketDataProvider` returns empty data.

### Security & Encryption

- **JWT session tokens**: HS256 signed; `exp` claim enforced; stateless auth for API routes
- **Refresh tokens**: persistent, one-time revocation; cleanup job (`AuthTokenCleanup`) runs every 10s in background
- **Password hashing**: Bcrypt/SHA256 via Vapor's `Bcrypt` (standard Vapor)
- **MFA**: one-time codes stored hashed; challenge expiry (`MFAChallenge` model)
- **OAuth PKCE**: code_verifier stored, state+nonce validated; identity linking across providers
- **PII encryption**: field-level AES-GCM via `UserPIIEncryption`; key rotation supported; `User.hydrateProtectedFields`
- **Rate limiting**: `RateLimitMiddleware` on auth routes to prevent enumeration/brute force
- **CORS**: configurable allowed origins via `ALLOWED_ORIGINS`; tightened in production
- **Account lockout**: `failed_login_count`, `lockout_until` on `User` model

### Observability & Diagnostics

- **Structured logging**: `JSONLogHandler` outputs JSON logs; `RequestLoggingMiddleware` adds request_id, method, path, status, latency, user_id
- **Tracing**: `TracingMiddleware` + swift-otel; `app.traceAutoPropagation = true` propagates W3C traceparent
- **Health checks**: `/health/ready` aggregates DB/Redis/mail/APNS/marketData checks + version + environment name
- **Metrics**: Not explicitly exposed; could add Prometheus endpoint or OTel metrics later
- **Error tracking**: Sentry not wired in backend (only iOS); errors flow through `APIErrorMiddleware` & `BillingErrorMiddleware`

### Market Data Provider Detail

External providers configured via env:

| Provider | Env key(s) | Status |
|----------|------------|--------|
| FMP (Financial Modeling Prep) | `FMP_API_KEY`, `FMP_BASE_URL` | Primary quote/history/news |
| Finnhub | `FINNHUB_API_KEY`, `FINNHUB_BASE_URL` | Secondary; also provides grades consensus, basic financials |
| IBKR (Interactive Brokers) | `IBKR_API_BASE_URL` | Client Portal API; currently disabled provider; placeholder `IBKRBrokerIntegration` present but not selected |

Provider selection occurs in `configure.swift` when registering `MarketDataProvider` in Application DI. If neither API key present, `DisabledMarketDataProvider` returns empty data.

### External API Call Chain

Each request flows:

```
Controller endpoint
→ calls application.marketDataService
→ iterates configured providers
→ first available provider returns data
→ maps to DTOs (MarketDataDTOs)
→ returns to controller → JSON response
```

Implementations (`FMPMarketDataProvider`, `FinnhubMarketDataProvider`) use Vapor's `Client` to make HTTP calls; parse JSON into provider-specific structs then map to canonical DTOs.

### Deployment & Environments

**Environments**: `.development`, `.testing`, `.production` (Vapor detects via --env flag or ENVIRONMENT var)

**Config files**:
- `.env` – local dev overrides
- `.env.development` – dev environment values
- `.env.production` – production secrets template

**Docker**:
- Release image: `swift:6.3.1-noble`, static Swift runtime, jemalloc, multi-stage
- Dev image: `swift:6.1-noble` with inotify-tools; `scripts/dev-watch.sh` rebuilds on file change
- Postgres + Redis via compose
- Migrations run in `migrate` service container

**Make targets**:
- `make dev` – hot-reload dev
- `make start` – build + migrate + release app
- `make migrate` – DB migrations only
- `make lint` – SwiftLint auto-fix
- `make backend-test` – `swift test`
- `make health` – readiness check against live domain
- `make backup-db` / `make restore-drill` – Postgres backup/restore (GPG encrypted)
- `make production-preflight` – cert/domain checks pre-deploy

**CI/CD**: `.github/workflows/deploy.yml` and `deploy-dev.yml` – build container, push to GHCR, SSH deploy to Hetzner (inferred from README).

### RevenueCat Integration

- Webhook: `POST /webhooks/revenuecat` with Authorization secret (`REVENUECAT_WEBHOOK_SECRET`)
- Event processor: `BillingService.process(event:rawPayload:on:)`
- Updates `BillingContext` (user entitlement snapshot)
- iOS client uses RevenueCat SDK Purchases; anonymous aliasing on login; `PaywallView` presents products
- Products expected: `pro_monthly`, `pro_weekly`, `pro_annual`
- Backend feature gates via `BillingMiddleware` or service checks

### Push Notifications (APNS)

- Device registration: `POST /notifications/devices` stores token + platform + environment
- Target alerts: `TargetAlertPoller` runs periodic job; evaluates user targets vs current price; enqueues send
- Sender: `APNSPushNotificationSender` builds payload with category `TARGET_ALERT`, deep link into stock detail
- Bootstrap: APNS credentials from env (`APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY_P8`, `APNS_TOPIC`)
- Silent fallback: `NoopPushNotificationSender` when credentials missing

### OpenAPI & Client Generation

- `openapi.yaml` present at repo root
- `swift-openapi-generator` dependency; `OpenAPIDocsTests` validates spec drift
- iOS uses AnyAPI with manually curated endpoints; potential to switch to generated client in future

### Testing Strategy

- **Unit tests**: `Tests/StockPlanBackendTests` – repository tests, service tests, DTO decoding/encoding
- **Integration**: Possibly tests for controller routes with in-memory DB
- **No UI tests** (backend is headless)
- Test DB configured via `TEST_DATABASE_*` env vars; defaults to localhost:5432

Coverage: moderate (~17 test files). Focus areas to expand: provider fallback logic, auth flows, billing edge cases.

### Potential / Known Gaps

- WebSocket implementation claimed in README not yet present
- IBKR full OAuth token exchange / revocation not fully implemented
- Rate limit configuration (thresholds) hard-coded or missing
- Metrics endpoint (Prometheus/OTLP metrics) not exported
- Backup/restore scripts assume GPG key availability
- Localization/i18n not yet supported
- Audit trail for admin actions missing

---

## 🔗 Related Documentation

- `APNS.md` – APNS bootstrap, certificate setup
- `MFA.md` – multi-factor auth flow
- `oauth.md` – OAuth provider setup and identity linking
- `Observability.md` – tracing + logging setup
- `revenuecat-setup.md` – RevenueCat product/entitlement configuration
- `ibkr-integration.md` – IBKR sync flow and deployment notes
- `persistence-standards.md` – database design principles
- `pii-encryption.md` – field-level encryption design

