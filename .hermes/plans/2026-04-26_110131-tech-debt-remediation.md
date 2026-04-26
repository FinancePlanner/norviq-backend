# Tech Debt Remediation Plan — StockPlanBackend

**Generated:** 2026-04-26
**Scope:** Fix 19 findings from TECH_DEBT_AUDIT.md
**Approach:** Phased, risk-ordered (immediate → short-term → medium → long-term)

---

## Goal

Eliminate critical tech debt across architectural decay, performance risk, security gaps, and test coverage gaps in StockPlanBackend. Deliver a more modular, testable, and production-hardened codebase.

---

## Current context

- Stack: Swift + Vapor 4 REST API
- Codebase: 21 modules, ~265 production Swift files, 73 migrations
- Tests: 16 test files (4316 lines) covering only 4 modules (Auth, Billing, Feedback, UserProfile)
- Critical debt: god classes (MarketDataService 2394 lines, AuthService 1045, ExpensesService 1057), 40+ unbounded queries, production config validation gaps
- Deployment: Dockerized VPS; production validation runs on startup

---

## Proposed approach

**Phased remediation** mirroring audit recommendation:
- Phase 0 (Immediate, 1-2 days): Quick wins + fast fixes (F008, F010, F016, F017, F013)
- Phase 1 (Short-term, 1 week): Pagination + configure.swift split + partial MarketDataService extraction
- Phase 2 (Medium-term, 2-4 weeks): Service decompositions (Auth, Expenses), test suite expansion, migration consolidation
- Phase 3 (Long-term, ongoing): Remaining type/contract cleanup, typealias audit, documentation

**Principle:** Each phase produces a deployable state. Never leave build broken mid-phase.

---

## Step-by-step plan

### Phase 0 — Immediate fixes (S effort, critical blocking gaps)

**Objective:** Fix fast, high-severity items that could cause production crashes or security issues.

#### 0.1 — Expand ProductionConfiguration validation (F008)
- **Files**: `Sources/StockPlanBackend/Shared/ProductionConfiguration.swift`
- **Changes**:
  - Add `validateRequiredSecret(_ key: String)` calls for `REDIS_URL`, `FINNHUB_API_KEY`, `FMP_API_KEY`, `IBKR_API_BASE_URL`, `MARKET_PROVIDER`
  - Fail fast on startup with clear error message if missing
- **Verification**: Tests `XCTAssertNoThrow(ProductionConfiguration.validate(for: .production))` with mock env; negative test for missing REDIS_URL
- **Risk**: Low. Additive guards only.
- **Effort**: S (1 file, ~20 LOC)

#### 0.2 — Replace force-try in Finnhub decoder (F010)
- **Files**: `Sources/StockPlanBackend/Market/FinnhubMarketDataProvider.swift`
- **Changes**:
  - At ~line 508: replace `try! decodeNil(forKey: key)` with `try?` + `if let ...` guard returning nil if decoder throws
  - Add structured log at `debug` level for malformed field
- **Verification**: Unit test feeding malformed JSON; ensure provider returns nil without crashing
- **Risk**: Low. Defensive only.
- **Effort**: S (~10 LOC)

#### 0.3 — Tighten CORS (F016)
- **Files**: `Sources/StockPlanBackend/configure.swift`
- **Changes**:
  - Change `app.cors.allowedOrigin = .any(allowedOrigins)` to `app.cors.allowedOrigin = .strict(allowedOrigins)`
  - Confirm `.strict()` enforces exact origin match (not scheme+subdomain wildcard)
- **Verification**: Integration test — send request with mis-typed Origin header; expect 403
- **Risk**: Low. Security hardening.
- **Effort**: S (1 line)

#### 0.4 — Constant-time RevenueCat webhook compare (F017)
- **Files**: `Sources/StockPlanBackend/Billing/RevenueCatWebhookController.swift`
- **Changes**:
  - Replace `provided == configured` with `Crypto.timingSafeCompare(providedData, configuredData)`
  - Import `Crypto` module
- **Verification**: Unit test verifying constant-time comparison doesn't short-circuit
- **Risk**: Low. Standard practice.
- **Effort**: S (few LOC)

#### 0.5 — Validate REDIS_URL at startup (F013)
- **Files**: `Sources/StockPlanBackend/Shared/ProductionConfiguration.swift`
- **Changes**:
  - Add REDIS_URL to `validateRequiredSecret` list
  - Optionally add `RedisURL` format sanity check (must start with `redis://` or `rediss://`)
- **Verification**: Deploy to staging with missing REDIS_URL — verify app exits with clear message
- **Risk**: Low. Fail-fast improvement.
- **Effort**: S

---

### Phase 1 — Short-term (1 week)

**Objective:** Address high-risk performance gaps, reduce configuration sprawl, and kick off MarketDataService decomposition.

#### 1.1 — Introduce pagination on user-list endpoints (F012)

**Scope:** Pick 5-6 highest-volume unbounded queries first, starting with user-scoped data.

**Priority order:**
1. `ExpensesController` / `ExpensesService` — expenses list (line 161 `.all()`)
2. `PortfolioController` — positions list (line 45 `.all()`)
3. `ExportService` — export records list (line 175 `.all()`)
4. `StocksController` — watchlist items (line 288 `.all()`)
5. `AssetsController` — assets/crypto accounts (line 27 `.all()`)

**Implementation pattern:**
```swift
// Before
let expenses = try await Expense.query(on: db).all()

// After
let limit = req.query[Int.self, at: "limit"] ?? 100
let offset = req.query[Int.self, at: "offset"] ?? 0
let expenses = try await Expense.query(on: db)
    .filter(\.$user.$id == user.id)
    .limit(limit)
    .offset(offset)
    .all()
```

**Files to change:**
- `Sources/StockPlanBackend/Expenses/ExpensesService.swift:161`, `.all()` sites (10+ occurrences identified)
- `Sources/StockPlanBackend/Portfolio/PortfolioController.swift` (3-4 occurrences)
- `Sources/StockPlanBackend/Export/ExportService.swift` (4-5 occurrences)
- `Sources/StockPlanBackend/Stocks/StockController.swift` (watchlist/research/targets endpoints)
- `Sources/StockPlanBackend/Assets/AssetsController.swift`
- Add query param parsing (`limit`, `offset`) to affected controller endpoints
- Update OpenAPI spec (`openapi.yaml`) to document `limit`/`offset` parameters for affected endpoints

**Tests:**
- Integration tests verifying pagination returns correct subsets
- Regression tests ensuring existing clients (without params) still work (default limit=100)
- Edge tests: limit=0, limit > max (enforce cap 500), offset beyond data → empty array

**Risk:** Medium. Changes public API. Must ensure backward compatibility (defaults) and review all `.all()` call-sites to avoid introducing regressions.

**Effort estimate:** L (spread across 6 files + tests + spec updates, ~150-200 LOC)

**Verification steps:**
1. Run full test suite (no breakage)
2. Manual API smoke: hit endpoints with/without `limit`/`offset`; verify response counts + total count header
3. Load test with 1000 records; confirm memory stays bounded

---

#### 1.2 — Split `configure.swift` into configurators (F005)

**Files to create (new):**
- `Sources/StockPlanBackend/Shared/configure/MiddlewareConfigurator.swift`
- `Sources/StockPlanBackend/Shared/configure/DatabaseConfigurator.swift`
- `Sources/StockPlanBackend/Shared/configure/RedisConfigurator.swift`
- `Sources/StockPlanBackend/Shared/configure/ExternalServicesConfigurator.swift` (clients: Finnhub, FMP, IBKR, RevenueCat, APNS)
- `Sources/StockPlanBackend/Shared/configure/ObservabilityConfigurator.swift` (logging, metrics, tracing)

**Files to modify:**
- `Sources/StockPlanBackend/configure.swift` — replace inline config with orchestrator: `try await MiddlewareConfigurator.configure(app)`, etc.
- May need to update imports in `configure.swift`

**Pattern for each configurator:**
```swift
public struct MiddlewareConfigurator {
    public static func configure(_ app: Application) async throws {
        // existing middleware setup code extracted from configure.swift
        let allowedOrigins: [String] = Environment.get("ALLOWED_ORIGINS") ...
        app.cors.allowedOrigin = .strict(allowedOrigins)
        // other middleware (error handler, logging, idempotency, rate limiting)
    }
}
```

**Tests:**
- Existing tests should pass unchanged (configure changed internally, external contracts same)
- No new tests needed if behavior unchanged

**Risk:** Low-Medium. Refactor-only, but change-at-scale in critical startup path. Should review each config block carefully.

**Effort:** M (extract ~400 LOC into 5 files, adjust imports, verify no lingering code)

**Verification steps:**
1. `swift run Run` — app starts in dev mode
2. Run full test suite
3. Docker build + container start in production-like env (REDIS_URL set) → no startup errors

---

#### 1.3 — Partial extraction of MarketDataService — Quote subdomain (F001 partial)

**Strategy:** Decompose god class incrementally. Start with lowest-risk, high-value subdomain: `QuoteService` (real-time + cached quotes).

**New files:**
- `Sources/StockPlanBackend/Market/QuoteService.swift` — protocol `QuoteService` + implementation `DefaultQuoteService`
- `Sources/StockPlanBackend/Market/QuoteServiceCaching.swift` — cache keys, TTLs, eviction logic
- (Optionally) `Sources/StockPlanBackend/Market/QuotesDTOs.swift` — move quote-related DTOs from MarketDataDTOs

**Files to modify:**
- `Sources/StockPlanBackend/Market/MarketDataService.swift` — reduce to thin facade delegating to `QuoteService` for quote methods
- `Sources/StockPlanBackend/configure.swift` — update service registration: register `QuoteService.self` as `any MarketDataService` still used by controllers; or gradually migrate controllers to inject `QuoteService` directly for quote endpoints

**Considerations:**
- Keep public protocol surface stable or update call sites (controllers) if conversion change
- Controllers currently depend on `MarketDataService` protocol; moving to smaller services will require controller changes (e.g., StockController, MarketController). That's okay — plan scope "partial" meaning extract internals while keeping facade stable for now. Deeper controller migration deferred to Phase 2.

**Tests:**
- New unit tests for `DefaultQuoteService` — mock providers and cache; verify:
  - Cache hit/miss behavior
  - Provider fallback on cache miss
  - Error propagation
- Regression: existing controller tests should continue to pass

**Risk:** Medium-High. Largest refactor in codebase. Must be done carefully to avoid breaking many endpoints.

**Effort:** L (estimate 200-300 LOC for service + tests)

**Verification steps:**
1. Compile entire project with zero errors
2. Run full test suite (no regressions)
3. Smoke test one quote endpoint (e.g., `/v1/market/quote/:symbol`) — verify response
4. Check logs for cache hit/miss metrics if instrumented

---

### Phase 2 — Medium-term (2-4 weeks)

**Objective:** Continue service decompositions, expand test coverage, consolidate migrations.

#### 2.1 — Decompose AuthService (F003)

**New files:** `RegistrationService`, `LoginService`, `OAuthService`, `MFAService`, `PasswordResetService`

**Files to modify:** `AuthService.swift` → thin orchestrator; `AuthController.swift` → inject new services

**Tests:** New unit tests per service; integration tests for registration/login flows covering success, duplicate email, weak password

**Open question:** Ensure unique email constraint at DB level. Verify migration defines `.unique(on: \.$email)`. Audit before implementation.

**Effort:** M (~200 LOC + tests)

---

#### 2.2 — Decompose ExpensesService (F004)

**New files:** `BudgetService`, `ExpenseService`, `CategoryService`, `RecurringTemplateService`, `ReportService`

**Extract:** Budget calculation logic into pure functions (testable without DB)

**Files to modify:** `ExpensesService.swift` → thin orchestration; controller splits into separate RouteCollections (budget routes, expense routes, etc.)

**Tests:** Unit + integration tests for budgeting logic, recurring template expansion, report generation

**Effort:** M (~250 LOC + tests)

---

#### 2.3 — Expand test coverage (F014)

**Priority modules** (based on audit): Market, Stocks, Expenses, Portfolio, Statistics, Broker, Notifications, Export

**Approach:** Create one test target per module (or one test file per module if staying with single target). Suggested structure:
```
Tests/
  MarketTests/
    MarketDataServiceTests.swift
    FinnhubProviderTests.swift
    ...
  StocksTests/
    StockServiceTests.swift
    ...
  ExpensesTests/
    ...
```

**Strategy:**
- Write tests for service logic *before* deep refactors (test-as-you-go)
- Start with integration tests (full Request -> Response) for critical endpoints, then unit test service internals
- Use `XCTAssertNoThrow` and property-based assertions (response codes, model schema)

**Effort:** L ongoing effort across several sprints

---

#### 2.4 — Consolidate pre-launch migrations (F007)

**Risk assessment:** Run `fluent migrate status` to list all applied migrations. Identify which are pre-launch vs post-launch.

**Action:**
- If safe, create a single "CreateInitialSchema" migration that creates all current tables
- Archive old pre-launch migrations (move to `Migrations/Archive/`) to reduce scaffold churn
- Keep post-launch migrations where schema evolution is still being tracked (for rollback)

**Files to modify:** `Migrations/` directory structure

**Verification:** `fluent migrate status` on fresh DB shows only 1-2 pre-launch migrations

**Effort:** S-M

---

### Phase 3 — Long-term (ongoing)

**Objective:** Address remaining rot and maintain code health.

#### 3.1 — Remove force-unwraps on model IDs (F009)

**Targets:** `DataExportController.swift`, `ExportService.swift`, `StockService.swift`

**Pattern:** Replace `model.id!` with `guard let id = model.id else { throw ... }`

**Tests:** Unit tests ensuring create→ID assignment before save; or use `requireID()` precondition from Fluent

**Effort:** M (spread across 3 files)

---

#### 3.2 — Replace silent `try? await` (F011)

**Audit all 31 occurrences** and replace with explicit `catch` that logs. If truly optional, keep `try?` but add comment explaining why errors are ignored.

**Effort:** L (31 sites)

---

#### 3.3 — Audit excessive typealiases (F019)

**Action:** Review 145 `typealias` lines. Remove redundant ones (e.g., `typealias JSON = [String: Any]` peppered across modules); centralize in Shared module if needed.

**Effort:** M

---

#### 3.4 — Documentation updates (F018)

**Add Swift-DocC comments** to `MarketDataService` protocol methods prior to decomposition. Each method: brief description, cache TTL, error type.

**Effort:** M (20 methods × avg 3 lines)

---

#### 3.5 — Open question investigations (section 6 in audit)

**Assign owners or backlog:**
- Migration consolidation (Q1) → tackled in Phase 2.4
- Unbounded query priority: consult product for which datasets can paginate (Q2)
- Idempotency in dev/staging: decision — keep as-is or enforce Redis in CI (Q3)
- MarketDataService cache invalidation: research WebSocket + admin endpoint or TTL-only (Q4)
- IBKR idempotency: audit sync job to confirm duplicate prevention (Q6)
- Billing entitlement caching: profile if N+1 problem (Q7)
- SwiftLint strict CI: enable in GitHub Actions (Q8)
- API versioning strategy: plan v2 namespace if breaking changes needed (Q9)
- Dependency CVE audit: off-sync `swift package show-dependencies` and GHSA check (Q10)

**Effort:** varies (1-4 tasks could be added to backlog)

---

## Files likely to change

**High-impact refactors** (many downstream callers):
- `Sources/StockPlanBackend/Market/MarketDataService.swift` (decomposed to QuoteService + later HistoryService, FundamentalsService...)
- `Sources/StockPlanBackend/Auth/AuthService.swift`
- `Sources/StockPlanBackend/Expenses/ExpensesService.swift`
- `Sources/StockPlanBackend/Stocks/StockController.swift`
- `Sources/StockPlanBackend/configure.swift`

**New files (suggested):**
- `Sources/StockPlanBackend/Shared/configure/*.swift` (5 configurators)
- `Sources/StockPlanBackend/Market/QuoteService.swift`, `QuoteServiceCaching.swift`
- `Sources/StockPlanBackend/Market/QuotesDTOs.swift` (split from big DTO file)
- `Sources/StockPlanBackend/Auth/RegistrationService.swift`, `LoginService.swift`, `OAuthService.swift`, `MFAService.swift`, `PasswordResetService.swift`
- `Sources/StockPlanBackend/Expenses/BudgetService.swift`, `ExpenseService.swift`, `CategoryService.swift`, `RecurringTemplateService.swift`, `ReportService.swift`
- Per-module test targets under `Tests/`

---

## Tests / validation

**Per-phase validation gates:**

- Phase 0: Full test suite passes; staging deploy succeeds with strict CORS, validated env, constant-time webhook
- Phase 1: Test suite passes + new pagination integration tests pass; load test with 10k records shows stable memory
- Phase 2: New service unit tests ≥ ~70% coverage; integration tests cover success/error paths; migrations consolidate cleanly
- Phase 3: Zero `!` or `try!` crashes in staging; code review confirms removed typealiases and added docs

**Regression guard:** Do not merge any refactor without green full-suite run.

**Test infrastructure:**
- Headers: Postman/OpenAPI client for API smoke
- Performance: `hey` or `wrk` for unbounded endpoint testing pre/post pagination
- Static analysis: Run `swift build` warnings as errors; consider enabling `-warn-as-error` in Package.swift

---

## Risks, tradeoffs, and open questions

### Risks

- **Controller breakage**: Service decomposition changes dependency injection. Controllers must be updated in lockstep. Mitigation: introduce new services first alongside existing facade; migrate one controller at a time.
- **API breaking changes**: Pagination alters response shape. Mitigation: default `limit=100` for current clients; document new params; monitor client adoption.
- **Test coverage lag**: Refactors without tests are dangerous. Mitigation: **write tests before each decomposition** (Phase 1 quote service tests → decompose; test before change).
- **Migration consolidation**: Archiving old migrations risks rollback scenarios if very old DB needs recovery. Mitigation: keep archive in repo; don't delete; only consolidate if confident no rollback needed.

### Tradeoffs

- **Effort vs. impact**: QuoteService extraction (Phase 1.3) is highest effort but delivers high modularity value. Consider doing it after pagination (1.1) to balance risk.
- **Modularity vs. velocity**: Splitting controllers creates more files but improves maintainability. Pace changes across phases to avoid overwhelming merge conflicts.

### Open questions

See "Open questions" section of TECH_DEBT_AUDIT.md (audit lines 62-78). Key ones affecting plan:
- Should dev/staging also enforce Redis? (Q3) — If yes, ProductionConfiguration changes may need to be optional or staged
- Will clients adapt to `limit`/`offset` or do we need cursor-based pagination later? (Q2) — cursor-based may require deeper service changes; offset pagination sufficient initially
- Does unique constraint exist on `User.email`? (Q5) — verify DB migration before AuthService refactor to avoid race conditions during concurrent registration

---

## Concrete deliverables per phase

### Phase 0
- [ ] `ProductionConfiguration.swift` validates REDIS_URL + third-party API keys (F008)
- [ ] Finnhub decoder uses safe try (F010)
- [ ] CORS uses `.strict()` (F016)
- [ ] RevenueCat webhook constant-time compare (F017)
- [ ] REDIS_URL validation added (F013)

### Phase 1
- [ ] Pagination implemented on 6 unbounded endpoints + integration tests + OpenAPI patch
- [ ] `configure.swift` reduced to orchestrator; 5 configurator files in place
- [ ] `QuoteService` extracted; tests added; MarketDataService facade preserved

### Phase 2
- [ ] AuthService split + unit tests
- [ ] ExpensesService split + unit tests
- [ ] Test targets for Market, Stocks, Expenses, Portfolio created; coverage baseline captured
- [ ] Pre-launch migrations consolidated (single schema + archive)

### Phase 3
- [ ] No force-unwrap crashes on model IDs remaining; safety guardrails in place
- [ ] All silent `try?` replaced with logged catch blocks
- [ ] Typealias audit complete; unnecessary ones removed
- [ ] Swift-DocC comments added to MarketDataService protocol

---

## Success criteria

- Build always green; no runtime crashes from `!`/`try!` in production
- All user-list endpoints bounded by `limit` (default 100, max 500)
- Test coverage ≥ 40% across modules (from current ~15%)
- `ProductionConfiguration` validates every secret required to boot without runtime errors
- CI passes with zero warnings/shortcuts (`swift build --warnings-as-errors` recommended)
- Audit findings F008, F010, F012, F014, F016, F017 resolved without regressions

---

*Plan saved to: `.hermes/plans/2026-04-26_114521-tech-debt-remediation.md`*
