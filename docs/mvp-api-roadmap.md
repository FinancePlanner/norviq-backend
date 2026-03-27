# MVP API Roadmap

Status snapshot for the backend based on the current investment-tool scope and the financial-plan scope.

## Investment Tool Scope

### Already Done

- [x] Health endpoint and OpenAPI documentation exposure
- [x] Auth API with register/login and JWT-based access
- [x] User profile API
- [x] Portfolio stock CRUD endpoints
- [x] Stock valuation endpoints for bear/base/bull ranges
- [x] Watchlist CRUD endpoints
- [x] Research note CRUD endpoints
- [x] Target CRUD endpoints
- [x] Market data endpoints for stock details, history, and news
- [x] Dashboard home aggregation endpoint
- [x] Portfolio summary and portfolio performance endpoints
- [x] Statistics endpoints for overview, allocation, scenario tracking, notes quality, and related portfolio analytics
- [x] Broker area scaffold with CSV import routes and IBKR sync placeholder
- [x] News endpoints and provider sync scaffold
- [x] Core persistence models and migrations for portfolio/investment data
- [x] Existing backend tests for auth, stocks, user profile, news, OpenAPI docs, and statistics

### Still Missing For MVP

- [ ] API-backed stock projections endpoint for the 5-year bear/base/bull model now mocked in iOS
- [ ] API-backed stock comparison endpoint for 3-symbol metric comparison
- [ ] Endpoint for stock fundamentals data used by the stock detail screen
- [ ] Endpoint for stock earnings data used by the stock detail screen
- [ ] Stable contract for valuation assumptions and future-year projection inputs, not only saved valuation ranges
- [ ] Final production-ready broker import behavior beyond scaffold/placeholder stage
- [ ] End-to-end contract alignment between iOS stock insights screens and backend responses

### Nice To Have After MVP

- [ ] Real-time streaming
- [ ] Alerts
- [ ] Deeper risk analytics
- [ ] Multi-broker expansion
- [ ] Export/tax reporting

## Financial Plan Scope

### Already Done

- [x] Auth and user profile infrastructure that the planning APIs can reuse
- [x] No dedicated financial-planning API routes yet

### Still Missing For MVP

- [ ] Salary endpoint or monthly income snapshot endpoint
- [ ] Monthly budget planner endpoint for a selected month
- [ ] CRUD endpoints for planned budget items under the three pillars
- [ ] CRUD endpoints for recorded expenses / actual spending entries
- [ ] API support for the three pillars: `Fundamentals`, `Future You`, and `Fun`
- [ ] Endpoint to duplicate or roll a monthly plan forward
- [ ] Endpoint returning remaining money after salary allocation
- [ ] Reports aggregation endpoint for month-to-month comparisons
- [ ] Reports aggregation endpoint for year-to-year comparisons
- [ ] Pillar breakdown endpoint for planned vs actual spending
- [ ] Combined reports payload for SwiftUI charts and list views
- [ ] Persistence model and migrations for salary, plans, plan items, and expense activities
- [ ] Tests for expense-planning and reports domains

## Highest-Priority API Work Next

- [ ] Build the Expenses API first
- [ ] Build the Reports API second
- [ ] Build stock insights endpoints for projections and metric comparison
- [ ] Add earnings and fundamentals endpoints for stock details
- [ ] Finish import/sync hardening after the core planner/reporting APIs are real

## Suggested Endpoint Groups To Add Next

### Financial Plan

- [ ] `GET /v1/budget/months/{yyyy-mm}`
- [ ] `PATCH /v1/budget/months/{yyyy-mm}`
- [ ] `POST /v1/budget/months/{yyyy-mm}/items`
- [ ] `PATCH /v1/budget/items/{itemId}`
- [ ] `DELETE /v1/budget/items/{itemId}`
- [ ] `GET /v1/expenses?from=...&to=...`
- [ ] `POST /v1/expenses`
- [ ] `PATCH /v1/expenses/{expenseId}`
- [ ] `DELETE /v1/expenses/{expenseId}`
- [ ] `GET /v1/reports/expenses?from=...&to=...&granularity=month`
- [ ] `GET /v1/reports/expenses?from=...&to=...&granularity=year`

### Stock Insights

- [ ] `GET /v1/stocks/symbol/{symbol}/insights/projections`
- [ ] `GET /v1/stocks/compare?symbols=META,AMD,NVDA`
- [ ] `GET /v1/stocks/symbol/{symbol}/fundamentals`
- [ ] `GET /v1/stocks/symbol/{symbol}/earnings`

## Notes

- The investment backend is materially ahead of the financial-planning backend.
- The iOS app already has client-side Expenses, Reports, stock Projections, and stock Compare screens, so the next backend work should focus on turning those mocked surfaces into real API contracts.
- For the financial-planning scope, the missing work is not polish; it is the core API domain itself.
