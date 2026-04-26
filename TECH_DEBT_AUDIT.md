# Tech Debt Audit — StockPlanBackend
Generated: 2026-04-26

## Executive summary

- **19 findings** across 9 categories (architectural decay, consistency rot, type/contract debt, test debt, dependency/config debt, performance/resource hygiene, error handling/observability, security hygiene, documentation drift)
- Largest debt concentration: `Market/MarketDataService.swift` (2394-line god class) and `Market/MarketDataDTOs.swift` (1494-line DTO dump). High churn + high complexity = maintenance risk.
- Secondary hot spots: `Auth/AuthService.swift` (1045 lines), `Expenses/ExpensesService.swift` (1057 lines), `configure.swift` (443 lines, 45 changes in 6 months).
- Critical gap: Test coverage limited to 4 modules (Auth, Billing, Feedback, UserProfile) out of 21; most core modules (Market, Stocks, Expenses, Portfolio, Statistics, Broker, Notifications, Export, etc.) have no dedicated tests.
- Performance risk: widespread unbounded `.all()` queries (40+ occurrences) on user-scoped data; potential OOM as data grows.
- Configuration validation gap: ProductionConfiguration validates JWT, DB, RevenueCat secrets but omits REDIS_URL and third-party API keys required by middleware and providers.

## Architectural mental model

StockPlanBackend is a Vapor 4 Swift web service providing a REST API for a personal stock portfolio tracker. The backend follows a layered architecture with:

- **Controllers**: Thin route handlers in `StockController`, `AuthController`, `ExpensesController`, etc. Each controller composes injected services.
- **Services**: Business logic layer (`AuthService`, `MarketDataService`, `ExpensesService`, `BillingService`, etc.). Most services are protocol-based (`Sendable`) with default implementations registered in `configure.swift`.
- **Repositories**: Data access using Fluent ORM (`AuthRepository`, `StockRepository`, `UserProfileRepository`, etc.). Most methods take a `Database` parameter.
- **Models**: 52 Fluent model definitions under `Models/` (User, Stock, Position, Transaction, Expense, Target, etc.).
- **DTOs**: Request/response structs for API boundaries. Market data DTOs are co-located with service in a large file; others co-located with controllers.
- **Middleware stack**: CORS, request logging, error handling (APIErrorMiddleware, BillingErrorMiddleware), tracing, idempotency (Redis-backed), rate limiting.
- **External integrations**: Multiple market data providers (Finnhub, FMP, IBKR), OAuth providers (Google, Apple, generic X), RevenueCat for billing, APNS for push notifications.
- **Background jobs**: Several `Task`-based workers (`TrialExpirationJob`, `AuthTokenCleanup`, `TargetAlertPoller`, `WebhookWorker`, `DataExportCleanupJob`) started from `configure.swift`.
- **Migrations**: 73 Fluent migrations under `Migrations/` covering schema evolution from initial launch through ongoing feature additions.
- **OpenAPI**: `openapi.yaml` is source of truth; `OpenAPIGenerator` plugin produces client contracts. High churn on the spec reflects active API evolution.
- **Shared contracts**: `StockPlanShared` package (imported as dependency) holds shared DTOs and types used by iOS client.

The project exhibits signs of rapid feature iteration with minimal upfront modularity. Service boundaries have blurred over time, resulting in god classes. Configuration is centralized but scattered across `configure.swift` and many `Environment.get` calls. Deployments target VPS with Docker; production configuration is validated on startup via `ProductionConfiguration`.

## Findings

| ID | Category | File:Line | Severity | Effort | Description | Recommendation |
|----|----------|-----------|----------|--------|-------------|----------------|
| F001 | Architectural decay | Sources/StockPlanBackend/Market/MarketDataService.swift:1-2394 | Critical | L | 2394-line god class implementing 20+ market data endpoints (quotes, history, FMP fundamentals, DCF, etc.). Violates SRP, extremely hard to test/maintain. | Split domain services: QuoteService, HistoryService, SearchService, FundamentalsService, AnalysisService. Extract cache orchestration. Keep a thin facade controller. |
| F002 | Architectural decay | Sources/StockPlanBackend/Market/MarketDataDTOs.swift:1-1494 | High | M | 1494-line DTO file mixing Quote, Profile, Financials, Ratios, DCF, etc. Makes locating types painful and creates merge conflicts. | Split DTOs by domain into matching files (QuotesDTOs.swift, HistoryDTOs.swift, etc.). Consider grouping related DTOs in subfolders. |
| F003 | Architectural decay | Sources/StockPlanBackend/Auth/AuthService.swift:1-1045 | High | M | Monolithic AuthService (1045 lines) handles register, login, logout, password reset, OAuth orchestration, MFA. Security-critical code should be partitioned for auditability. | Refactor into RegistrationService, LoginService, PasswordResetService, OAuthService, MFAService. Keep a thin AuthController composing them. |
| F004 | Architectural decay | Sources/StockPlanBackend/Expenses/ExpensesService.swift:1-1057 | High | M | ExpensesService (1057 lines) handles budgets, expenses, categories, recurring templates, and reports. Mixed concerns; difficult to reason about business logic. | Split into BudgetService, ExpenseService, CategoryService, RecurringTemplateService, ReportService. Extract budget calculations into pure functions. |
| F005 | Architectural decay | Sources/StockPlanBackend/configure.swift:1-443 | High | L | 443-line configure with 45 commits/6mo churn mixes CORS, middleware, DB, Redis, clients, metrics, tracing. Changes here are high-risk due to coupling. | Extract configurators: MiddlewareConfigurator, DatabaseConfigurator, RedisConfigurator, ExternalServicesConfigurator, ObservabilityConfigurator. Keep configure.swift as orchestration only. |
| F006 | Architectural decay | Sources/StockPlanBackend/Stocks/StockController.swift:1-655 | Medium | M | StockController handles CRUD, watchlist (lists+items), research notes, targets (650+ lines). Violates Single Responsibility; watchlist/targets/research could be separate controllers. | Extract WatchlistController, ResearchController, TargetController into their own RouteCollections. StockController focuses on stock metadata and portfolio integration. |
| F007 | Architectural decay | Sources/StockPlanBackend/Migrations/ (73 files) | Medium | S | 73 migration files accumulate schema history; many small additive migrations clutter history and increase migration runtime. | Consolidate pre-launch schema into single `CreateInitialSchema` migration. Keep post-launch migrations separate for audit trail, but consider merging minor additive migrations that are always applied together. |
| F008 | Consistency rot | Sources/StockPlanBackend/Shared/ProductionConfiguration.swift:4-15 | High | S | ProductionConfiguration validates JWT, DB, RevenueCat, ALLOWED_ORIGINS but does NOT validate REDIS_URL (required by IdempotencyMiddleware), nor third-party API keys (FINNHUB_API_KEY, FMP_API_KEY, IBKR_API_BASE_URL). Missing validation → runtime failures in production. | Add `validateRequiredSecret` calls for MARKET_PROVIDER, FINNHUB_API_KEY, FMP_API_KEY, IBKR_API_BASE_URL, and REDIS_URL. Fail fast on startup. |
| F009 | Type & contract debt | Sources/StockPlanBackend/Export/DataExportController.swift:31,46,75,79; Export/ExportService.swift:37,194; Stocks/StockService.swift:410,419 | High | S | Force-unwrap on model.id (`export.id!`, `account.id!`) in export and stock flows. If model unsaved or ID nil, runtime crash. Export flow has multiple such usages. | Replace with guard let or use `requireID()` pattern. Ensure create→save→use order guarantees ID before these code paths. Add precondition checks in development. |
| F010 | Type & contract debt | Sources/StockPlanBackend/Market/FinnhubMarketDataProvider.swift:508,525 | Medium | S | `try !decodeNil(forKey: key)` force-try inside decoder. If decoder throws (malformed data), the entire provider request crashes. | Replace `try !` with `try?` or proper `do/catch` to handle unexpected decode failures and return nil gracefully. |
| F011 | Type & contract debt | Sources/StockPlanBackend/ (31 occurrences) | Medium | M | Silent error swallowing via `try? await` across codebase: PushNotificationSender deactivation, expense activity recording, market analysis lookup, badge saves. Dropped errors hinder debugging. | Replace `try?` with `try` and explicit `catch` logging. If truly optional, document why ignoring is safe and consider logging at debug level. |
| F012 | Performance & resource hygiene | Sources/StockPlanBackend/Expenses/ExpensesService.swift:161,269,278,356,516,547,610,611,612,819,829,1036; Portfolio/PortfolioController.swift:45,95,130,134,142,174,198,287,323,329; Export/ExportService.swift:175,193,205,226,244; Stocks/StockController.swift:288,404; Assets/AssetsController.swift:27; … 40+ total | High | L | Unbounded `.all()` queries without `limit()` on potentially large user datasets (expenses, transactions, accounts, instruments, watchlist items, research notes, targets). Risk: memory exhaustion, slow responses as data grows. | Introduce pagination on all list endpoints (default limit ~100, max 500). For internal service calls, add optional `limit` parameter and enforce at call-sites. Replace immediate `.all()` with `.limit()` or cursor-based pagination. |
| F013 | Performance & resource hygiene | Sources/StockPlanBackend/Shared/IdempotencyMiddleware.swift:38-42 | Medium | S | IdempotencyMiddleware requires Redis in production; throws on first request if missing. ProductionConfiguration doesn't validate REDIS_URL, allowing deployment that fails at runtime. | Add REDIS_URL validation in ProductionConfiguration.validate(for:) to fail fast on startup. Document Redis as a required dependency. |
| F014 | Test debt | Tests/StockPlanBackendTests/ (16 files for 265 production files) | High | L | Only 4 modules have dedicated tests (Auth, Billing, Feedback, UserProfile). 17/21 modules (Market, Stocks, Expenses, Portfolio, Statistics, Broker, Crypto, Notifications, Export, etc.) have zero tests. Monolithic test file (4316 lines) is hard to navigate. | Add test targets per module. Co-locate unit tests or follow module-per-test-file pattern. Split monolithic `StockPlanBackendTests.swift` into smaller suites (MarketTests, StocksTests, ExpensesTests, etc.). Prioritize coverage for Market, Stocks, Expenses, Portfolio. |
| F015 | Error handling & observability | Sources/StockPlanBackend/Notifications/TargetAlertEvaluator.swift:16-18,34-37,49-52,85-88; PushNotificationSender.swift:97-100 | Medium | S | Catch blocks that only log warnings and swallow without retry or error aggregation (TargetAlertEvaluator, PushNotificationSender). Errors in background jobs may be lost, masking systemic issues. | Surface errors to metrics (increment counter) and structured logs. Consider retry with backoff for transient failures; dead-letter queue for persistent failures. |
| F016 | Security hygiene | Sources/StockPlanBackend/configure.swift:33 | Medium | S | CORS `allowedOrigin: .any(allowedOrigins)` accepts any origin matching allowlist, but comment admits "should be more restricted." A misconfigured ALLOWED_ORIGINS (e.g., wildcard or missing) could allow unintended origins. | Use `.strict(origins:)` instead of `.any()` to enforce exact match. Ensure ProductionConfiguration rejects wildcard origins (already implemented). |
| F017 | Security hygiene | Sources/StockPlanBackend/Billing/RevenueCatWebhookController.swift:38-40 | Low | S | Webhook secret check uses plain string equality (`provided == configured`). Not constant-time; could leak info via timing attack (probabilistic, low risk for short secrets, but non-standard). | Replace with constant-time comparison: `Crypto.timingSafeCompare(provided, configured)`. |
| F018 | Documentation drift | Sources/StockPlanBackend/Market/MarketDataService.swift:7-73 | Medium | M | Protocol `MarketDataService` has 20+ methods but lacks Swift-DocC comments. Implementation details are buried in a 2394-line file. Without docs, consumers must read code to understand caching and error behavior. | Add documentation comments to each protocol method describing parameters, return values, cache TTLs, and possible errors. Consider splitting protocol into smaller documented protocols. |
| F019 | Consistency rot | Sources/StockPlanBackend (145 typealias occurrences) | Low | M | Excessive `typealias` usage (145) suggests over-abstraction or complex generic plumbing. Some may be for `any Service` existentials, but others could be inlined for clarity. | Audit typealiases; keep only if they document intent (e.g., `Any⟨Service⟩` aliases for dependency injection). Remove redundant or unused aliases. |

## Top 5 (if you fix nothing else, fix these)

1. **F001 — Decompose MarketDataService**: The 2394-line god class is the single biggest maintenance hazard. Split into focused services by domain (Quote, History, Fundamentals, etc.). This reduces complexity, enables per-domain testing, and lowers churn impact.
2. **F012 — Eliminate unbounded `.all()` queries**: Performance risk escalates with user data. Introduce pagination (default + max limits) on every user-list endpoint. Service methods should require explicit limit parameters.
3. **F009 — Replace force-unwraps on model IDs**: Crashes in production are unacceptable. Audit Export and StockService flows; use safe optional handling or preconditions that IDs exist after save.
4. **F014 — Expand test coverage**: Only 4 of 21 modules have dedicated tests. Add targeted integration tests first for Market, Stocks, Expenses, and Portfolio (the high-churn, large modules). Split monolithic test file for maintainability.
5. **F008 — Validate all required production env vars**: REDIS_URL and third-party API keys are not validated on startup. Add checks so deployment fails fast with clear error messages rather than failing on first request.

## Quick wins (low effort × medium+ severity)

- [ ] F013: Add REDIS_URL validation in `ProductionConfiguration.validate(for:)` (S, Medium)
- [ ] F017: Switch RevenueCat webhook compare to constant-time (S, Low)
- [ ] F011: Replace `try? await` with explicit `catch` logging at 5 most critical sites (M, Medium)
- [ ] F016: Change CORS `.any()` to `.strict()` (S, Medium)
- [ ] F019: Remove redundant typealiases or document intent (M, Low)
- [ ] F010: Replace `try !` in Finnhub decoder with safe pattern (S, Medium)

## Things that look bad but are actually fine

- **73 migration files**: At first glance, 73 migrations suggest schema chaos. However, they represent incremental feature additions over ~2 years of active development. Consolidating pre-launch migrations is fine, but post-launch migrations are intentionally one-per-change for deployability. Not debt.
- **`any Database` existential types**: Usage of `any Database` (744 matches) is Swift 6's explicit existential syntax. This is correct modern Swift, not a code smell.
- **Large DTOs in MarketDataDTOs.swift**: The sheer number of fields reflects the richness of third-party provider responses (FMP, Finnhub). Consolidating them into per-domain files helps navigation but the size itself is not abnormal.
- **High churn on `openapi.yaml` (34 changes/6mo)**: This reflects active API evolution, not instability. Spec-first design ensures clients stay in sync. Churn is expected during MVP iteration.
- **`ProjectionScenariosTests.swift` (137 lines)**: At first appears to be a tiny test, but it is a specialized suite for valuation projection edge cases; size appropriate.

## Open questions

1. **Migration consolidation**: Are all 73 migrations still required in the codebase, or are some superseded by later changes? Consider running `fluent migrate status` to identify which have been applied and whether any can be archived.
2. **Unbounded queries**: Some `.all()` calls are on small lookup tables (e.g., `Instrument.query`) that may be bounded by design (tens of thousands of instruments max). Which tables are expected to grow unbounded? Prioritize limits on user-scoped data (expenses, transactions, activities).
3. **Idempotency in non-production**: Idempotency middleware is a no-op if Redis missing outside production. Is this intentional to simplify testing? Should dev/staging also enforce Redis to catch config errors earlier?
4. **MarketDataService cache invalidation**: The service caches quotes/history/profile with TTLs. Is there any manual cache busting for real-time updates? If not, explore publish-subscribe via WebSocket or admin endpoint for cache invalidation on user actions (e.g., price updates).
5. **AuthService.register flow**: The `AuthService` register method calls `validatePassword` then `repo.createUser` then sends verification email. Is there a race condition if two registrations occur for same email simultaneously? The `User.email` column is likely unique, but verify unique constraint exists and is enforced at DB level.
6. **IBKR integration reliability**: `IBKRBrokerIntegration.swift` has retry logic (exponential backoff). Are failures idempotent? Verify the broker sync job tracks already-processed transactions to avoid duplicates on retry.
7. **Billing entitlement caching**: `BillingContextService` fetches entitlement on every request? Is the result cached per request or per user session? Could become N+1 if multiple feature gates checked per request.
8. **SwiftLint enforcement**: `.swiftlint.yml` exists but lint errors may not break builds. Consider enabling `--strict` in CI to prevent new warnings.
9. **API versioning**: Routes under `/v1`. Is there a plan for `/v2`? Migration strategy? The current controller structure might make versioning harder; consider versioned namespaces.
10. **Dependency versions**: Package.swift pins minimum versions (from:). Are there known CVEs in dependencies? Manual review recommended: Vapor 4.121.4 (latest?), Fluent 4.9.0, JWT 5.0.0. Consider `swift package show-dependencies --package-path .` and cross-check against GHSA advisories.

## Conclusion

The codebase shows clear signs of MVP-stage iteration with rapid feature development but insufficient modularity, testing, and hardening before scale. Architectural debt is concentrated in Market, Auth, and Expenses services. Performance risk is highest from unbounded queries. Production-readiness gaps include env validation and test coverage.

**Recommended phased remediation:**
1. **Immediate (1-2 days)**: Add missing ProductionConfiguration validations (F008), replace force-try in Finnhub (F010), convert CORS to strict (F016), constant-time webhook compare (F017).
2. **Short-term (1 week)**: Introduce pagination on top 5 unbounded list endpoints (F012 subset), refactor configure.swift into configurators (F005), split MarketDataService into two (F001 partial).
3. **Medium-term (2-4 weeks)**: Continue service decompositions (F003, F004), expand module test coverage (F014), consolidate pre-launch migrations (F007).
4. **Long-term (ongoing)**: Address remaining type/contract issues (F009, F011), clean up typealiases (F019), maintain test suite as features grow.
