# API Architecture Diagrams

Mermaid diagrams for every feature area of the Norviq backend (`StockPlanBackend`, Swift/Vapor). Route registration lives in `Sources/StockPlanBackend/routes.swift`; the machine-readable contract is `Sources/StockPlanBackend/openapi.yaml` (served at `/openapi.yaml`, Swagger UI at `/docs`).

Conventions used below:

- All application routes are mounted under the global `/v1` prefix unless noted (webhooks, `/share`, `/.well-known`, health, and `/metrics` are mounted at the root).
- **Session auth** = `SessionToken` bearer (first-party iOS/web clients). **Scoped PAT/OAuth** = `ScopedBearerAuthenticator` scopes (e.g. `market:read`) used by MCP and API integrations.
- Controllers query Postgres via Fluent; Redis backs hot caches and rate limits.

## System overview

```mermaid
flowchart LR
    subgraph Clients
        IOS[iOS app<br/>financeplan]
        WEB[Web app<br/>norviq-web]
        MCP[MCP server<br/>norviq-mcp]
        EXT[API / OAuth clients]
    end

    subgraph Backend["StockPlanBackend (Vapor, /v1)"]
        AUTH[Auth & OAuth]
        MARKET[Market data]
        PORT[Portfolio & stocks]
        WEALTH[Wealth: scenarios,<br/>retirement, reporting]
        BANKS[Banking & brokers]
        SPEND[Expenses, budget,<br/>receipts, financing]
        AI[AI chat & insights]
        MACRO[Macro & insights]
        MISC[Users, billing, news,<br/>notifications, export]
    end

    subgraph Stores
        PG[(Postgres<br/>Fluent)]
        REDIS[(Redis<br/>cache + rate limits)]
    end

    subgraph Providers
        FINN[Finnhub]
        IBKR[IBKR]
        FMP[FMP]
        PLAID[Plaid]
        FRED[FRED / Eurostat / IBGE]
        HERMES[Hermes VPS<br/>via Tailscale]
        RC[Stripe / RevenueCat]
        APNS[APNs]
        RESEND[Resend]
    end

    IOS --> Backend
    WEB --> Backend
    MCP --> Backend
    EXT --> AUTH

    Backend --> PG
    Backend --> REDIS
    MARKET --> FINN & IBKR & FMP
    BANKS --> PLAID & IBKR
    MACRO --> FRED
    MACRO --> HERMES
    MISC --> RC & APNS & RESEND
```

## Auth, OAuth 2.1 and personal access tokens

Controllers: `Auth/AuthController.swift`, `Auth/PersonalAccessTokenController.swift`, `OAuth/OAuthServerController.swift`, `OAuth/TokenIntrospectionController.swift`, `OAuth/WellKnownController.swift`.

```mermaid
flowchart LR
    C[Client] -->|register / login / MFA| A["/v1/auth/*"]
    C -->|manage PATs| T["/v1/tokens (session auth)"]
    OC[OAuth client<br/>e.g. MCP] -->|authorize + consent| O["/v1/oauth/*"]
    OC -->|discovery| W["/.well-known/oauth-authorization-server"]
    RS[Resource servers] -->|introspect| I["/v1/oauth/introspect"]

    A --> AC[AuthController] --> DB[(users, sessions, MFA)]
    T --> PC[PersonalAccessTokenController] --> DB
    O --> OS[OAuthServerController] --> DB
    I --> TI[TokenIntrospectionController] --> DB
    AC -->|verification email| RESEND[Resend]
```

## Billing

Controllers: `Billing/BillingController.swift`, `Billing/RevenueCatWebhookController.swift`.

```mermaid
flowchart LR
    C[Client] --> B["/v1/billing/* (session auth)"]
    RC[RevenueCat] -->|signed webhook| W["/webhooks/revenuecat (root)"]

    B --> BC[BillingController] --> ENT[(entitlements, trials)]
    W --> RW[RevenueCatWebhookController] --> ENT
    BC -.->|gates Pro features| GATES[billing middleware across controllers]
```

## Stocks, watchlist, research and targets

Controller: `Stocks/StockController.swift` (+ `StockController+Watchlist.swift`), service `Stocks/StockService.swift`.

```mermaid
flowchart LR
    C[Client] --> S["/v1/stocks CRUD, bulk, sell"]
    C --> WL["/v1/watchlist CRUD, lists, CSV import"]
    C --> R["/v1/research notes"]
    C --> TG["/v1/targets price alerts"]

    S & WL & R & TG --> SC[StockController<br/>session auth]
    SC --> SS[StocksService] --> DB[(stocks, watchlist,<br/>research_notes, targets)]
    SC -->|details enrichment| MDS[MarketDataService]
```

## Market data

Controller: `Market/MarketDataController.swift` (scoped `market:read` for PAT access), service `Market/MarketDataService.swift`, providers under `Market/`.

```mermaid
flowchart LR
    C[Client / MCP] --> Q["/v1/market/quote/:symbol<br/>/v1/market/quote/batch (max 100)"]
    C --> H["/v1/market/history, price-chart,<br/>chart-builder (216 metrics), search, fx"]
    C --> F["/v1/market/profile, financials,<br/>statements, earnings"]

    Q & H & F --> MC[MarketDataController<br/>rate-limited 120/60s]
    MC --> MDS[MarketDataService]
    MDS -->|1: hot cache 20s TTL| REDIS[(Redis)]
    MDS -->|2: persistent cache| PG[(Postgres)]
    MDS -->|3: on miss| SEL{Provider selection}
    SEL -->|FINNHUB_API_KEY| FINN[Finnhub]
    SEL -->|IBKR_API_BASE_URL| IBKR[IBKR]
    SEL -->|fundamentals| FMP[FMP]
    FINNWH[Finnhub webhook] -->|news push| NW["/webhooks/finnhub/news (root)"] --> NDB[(news archive)]
```

## Portfolio and P&L

Controller: `Portfolio/PortfolioController.swift`. `/v1/pnl` joins holdings with cached quotes server-side (shared DTO `PnlBySymbol`).

```mermaid
flowchart LR
    C[Client] --> SUM["/v1/portfolio/summary, performance,<br/>sector-exposure, dividends, lists"]
    C --> PNL["/v1/pnl per-symbol P&L"]
    C --> LOTS["/v1/lots, /v1/transactions"]

    SUM & PNL & LOTS --> PC[PortfolioController<br/>session auth + portfolioAccessService]
    PC --> DB[(stocks, portfolio_lists,<br/>accounts, cash_balances, lots)]
    PNL --> JOIN[group by symbol:<br/>shares, cost basis]
    JOIN --> MDS[MarketDataService.quoteBatch<br/>20s Redis/PG cache]
    JOIN --> OUT[currentPrice, marketValue,<br/>unrealized + day P&L, weightPercent]
```

## Portfolio management, retirement, reporting and wealth automation

Controllers: `Portfolio/PortfolioManagementController.swift`, `Retirement/RetirementController.swift`, `Reporting/AdvancedReportingController.swift`, `Automation/WealthAutomationController.swift`, `Scenarios/ScenarioController.swift`.

```mermaid
flowchart LR
    C[Client] --> PM["/v1/portfolios multi-portfolio,<br/>memberships"]
    C --> RET["/v1/retirement plans"]
    C --> REP["/v1/reporting templates,<br/>schedules, runs"]
    C --> WA["/v1/net-worth-forecasts,<br/>/v1/watchlist/screens,<br/>rebalancing-policy, inbox"]
    C --> SCN["/v1/financial-goals, /v1/scenarios,<br/>scenario-snapshots, scenario-runs,<br/>holding-risk-profiles"]

    PM --> PMC[PortfolioManagementController]
    RET --> RC[RetirementController]
    REP --> ARC[AdvancedReportingController<br/>recurrence + signed download links]
    WA --> WAC[WealthAutomationController]
    SCN --> SC[ScenarioController<br/>SCENARIO_PLANNING_ENABLED flag]
    PMC & RC & ARC & WAC & SC --> DB[(Postgres)]
    SC --> ING[MarketHistoryIngestionJob] --> MDS[MarketDataService]
```

## Brokers (IBKR) and banking (Plaid)

Controllers: `Broker/BrokerController.swift`, `Banking/BankController.swift`, `Banking/PlaidWebhookController.swift`.

```mermaid
flowchart LR
    C[Client] --> BR["/v1/brokers connect, sync<br/>(rate-limited + idempotency keys)"]
    C --> BK["/v1/banks link, accounts,<br/>transactions, import"]
    PLAIDX[Plaid] -->|webhook| PW["/webhooks/plaid (root)"]

    BR --> BC[BrokerController] --> IBKRI[IBKRBrokerIntegration<br/>OAuth + CSV import] --> IBKR[IBKR API]
    BK --> BAC[BankController] --> REG[BankProvider registry] --> PLAID[PlaidProvider<br/>transactions-only]
    PW --> PWC[PlaidWebhookController] --> SYNC[sync job → tx→expense<br/>import with dedupe]
    BC & BAC & SYNC --> DB[(accounts, lots,<br/>bank_transactions)]
```

## Crypto

Controller: `Crypto/CryptoController.swift`.

```mermaid
flowchart LR
    C[Client] --> CR["/v1/crypto quotes + /v1/crypto/portfolio"]
    CR --> CC[CryptoController] --> FMP[FMP crypto data]
    CC --> DB[(crypto holdings)]
```

## Macro / inflation

Controller: `Macro/MacroController.swift` (Nowflation-parity pipeline).

```mermaid
flowchart LR
    C[Client] --> M["/v1/macro series, fed-watch,<br/>items, vintages"]
    M --> MC[MacroController] --> PROV{Provider by region}
    PROV --> FRED[FRED - US]
    PROV --> EURO[Eurostat - EU]
    PROV --> IBGE[IBGE - BR]
    MC --> VDB[(vintage persistence)]
```

## Insights (Hermes sentiment)

Controller: `Insights/InsightsController.swift`; ticker sentiment computed on the Hermes VPS and fetched over Tailscale.

```mermaid
flowchart LR
    C[Client] --> I["/v1/insights/* ticker sentiment<br/>(admin routes token-gated)"]
    I --> IC[InsightsController] --> IS[InsightsService<br/>trackedTickers at boot]
    IS -->|Tailscale| HERMES[Hermes VPS<br/>X/Twitter sentiment]
    IS --> DB[(insights cache)]
```

## News and earnings

Controllers: `News/NewsController.swift`, `Earnings/EarningsController.swift`.

```mermaid
flowchart LR
    C[Client] --> N["/v1/news per-user tracked symbols"]
    C --> E["/v1/earnings calendar + TTS audio"]
    N --> NC[NewsController] --> NR[NewsRepository] --> DB[(news archive)]
    FINN[Finnhub webhook] --> DB
    E --> EC[EarningsController] --> MDS[MarketDataService]
```

## Expenses, budget, receipts and financing

Controllers: `Expenses/ExpensesController.swift`, `Budget/BudgetController.swift`, `Receipts/ReceiptsController.swift`, `Financing/FinancingController.swift`.

```mermaid
flowchart LR
    C[Client] --> EX["/v1/expenses CRUD, CSV import/export"]
    C --> BU["/v1/budget envelopes, drift policy,<br/>reallocation preview"]
    C --> RE["/v1/receipts scan, parse<br/>(rate-limited; OCR driver stubbed)"]
    C --> FI["/v1/financing loan calculators"]

    EX --> EXC[ExpensesController]
    BU --> BUC[BudgetController]
    RE --> REC[ReceiptsController] --> PARSE[shared receipt/QR parser]
    FI --> FIC[FinancingController]
    EXC & BUC & REC --> DB[(expenses, budgets, receipts)]
    BANK[Bank sync job] -->|tx→expense import| DB
```

## Reports and data export

Controllers: `Reports/ReportsController.swift`, `Export/DataExportController.swift`, `Export/ExportFileController.swift`, `Sharing/SharingController.swift`.

```mermaid
flowchart LR
    C[Client] --> RP["/v1/reports summaries"]
    C --> EXP["/v1/api/v3/export async data export"]
    ANY[Anyone with link] --> SH["/share/:token (root)"]

    RP --> RPC[ReportsController] --> DB[(Postgres)]
    EXP --> DEC[DataExportController] --> FILES[export artifacts] --> EFC[ExportFileController<br/>ownership-checked download]
    SH --> SHC[SharingController] --> DB
```

## AI assistant and MCP

Controllers: `AI/AIChatController.swift`, `AI/AIAssistantController.swift` (+ `AIAssistantStreamController.swift` SSE), `AI/AIInsightsController.swift`; tool registry `AI/AIChatToolRegistry.swift`. The MCP server itself lives in the separate `norviq-mcp` repo and calls back with scoped PATs.

```mermaid
flowchart LR
    IOS[iOS chat screen] --> CH["/v1/ai/chat SSE stream"]
    C[Client] --> AS["/v1/ai/assistant/* conversations"]
    C --> AII["/v1/ai/insights"]
    MCPC[MCP clients<br/>Claude etc.] --> MCPS[norviq-mcp server<br/>mcp.norviqa.io]

    CH --> ACC[AIChatController] --> REGY[AIChatToolRegistry] --> MDS[MarketDataService]
    AS --> AAC[AIAssistantController<br/>SSE via AIAssistantStreamController]
    AII --> AIC[AIInsightsController]
    MCPS -->|scoped PAT<br/>market:read, expenses:*| API["/v1/market/*, /v1/expenses/*,<br/>/v1/insights/*"]
    ACC & AAC & AIC --> DB[(conversations)]
```

## Users, notifications, activities, badges, feedback

Controllers: `Users/UserProfileController.swift`, `Notifications/PushNotificationsController.swift`, `Activity/UserActivityController.swift`, `Badges/BadgeController.swift`, `Feedback/FeedbackController.swift`, `Assets/AssetsController.swift`, `Tax/TaxController.swift`, `Dashboard/DashboardController.swift`, `Goals/GoalsController.swift`, `Statistics/StatisticsController.swift`.

```mermaid
flowchart LR
    C[Client] --> U["/v1/users profile, deletion"]
    C --> NO["/v1/notifications/apns tokens,<br/>/v1/notifications/earnings prefs"]
    C --> AC["/v1/activities, /v1/badges, /v1/feedback"]
    C --> AS["/v1/assets search"]
    C --> TX["/v1/tax capital gains calculators"]
    C --> DG["/v1/dashboard, /v1/goals, /v1/statistics"]

    U & NO & AC & AS & TX & DG --> CTRLS[Controllers<br/>session auth] --> DB[(Postgres)]
    NO --> APNS[APNs push]
    TA[TargetAlertEvaluator job] --> MDS[MarketDataService]
    TA --> APNS
```

## Ops endpoints

```mermaid
flowchart LR
    K8S[k3s probes] --> H["/health, /health/live, /health/ready (root)"]
    PROM[Prometheus / Alloy] --> MET["/metrics (root)"]
    DEV[Developers] --> DOCS["/docs Swagger UI + /openapi.yaml<br/>(API_DOCS_ENABLED)"]
    H & MET & DOCS --> APP[Vapor app]
```
