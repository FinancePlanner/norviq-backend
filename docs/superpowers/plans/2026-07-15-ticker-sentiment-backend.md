# Ticker Sentiment — Backend + Hermes Implementation Plan (Plan 1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Hermes ticker scraper and the backend poller target the top-N most-popular equities held/watched by users (instead of a static 3-symbol env), and expose that list to the VPS over the tailnet.

**Architecture:** A new repository method computes the top-N distinct equity symbols across all users' holdings + watchlist. A machine-authenticated endpoint serves it to the Hermes VPS cron (which rewrites `scraper_config.json` before scraping). The backend poller uses the same method at sync time instead of a boot-captured env list.

**Tech Stack:** Swift 6 / Vapor 4 / Fluent / Postgres; Python (Hermes scraper); swift-testing.

## Global Constraints

- Equities only: apply `category == .stock` to the `stocks` table; `watchlist_items` has no category and is included as-is (verbatim from spec).
- Cost cap: top-N by distinct-user count, `N` from `HERMES_TRACKED_TICKERS_LIMIT` (default 25).
- `INSIGHTS_SYMBOLS_TOKEN` guards `/v1/insights/tracked-symbols`; unset ⇒ fail-closed (503). Machine auth, NOT user session/scoped auth.
- `HERMES_TRACKED_TICKERS` remains an optional always-include pin list.
- Reads stay Postgres-only; no Hermes call on the request path.
- Symbols normalized uppercase + trimmed, matching `News/NewsRepository.swift:141-146`.
- Tests run with `TEST_DATABASE_PORT=5432 LOG_LEVEL=warning swift test`.

---

### Task 1: `allTrackedSymbols` repository method

**Files:**
- Modify: `Sources/StockPlanBackend/Insights/InsightsRepository.swift` (add to `protocol InsightsRepository` and `DatabaseInsightsRepository`)
- Test: `Tests/StockPlanBackendTests/InsightsServiceTests.swift` (add cases to the existing suite)

**Interfaces:**
- Produces: `func allTrackedSymbols(limit: Int, on db: any Database) async throws -> [String]` on `InsightsRepository`. Returns up to `limit` uppercased symbols, ranked by distinct-user count desc, tie-broken alphabetically. Union of `stocks` (where `category == .stock`) and `watchlist_items` (where `status != "archived"`).

- [ ] **Step 1: Write the failing test**

Add to `InsightsServiceTests` (uses the existing `withApp` + a helper to create users/stocks/watchlist). Create two users, overlapping holdings, one archived watchlist item, one crypto holding; assert ranking, cap, dedup, exclusions.

```swift
@Test("allTrackedSymbols ranks by user-count, caps, excludes archived + non-equity")
func allTrackedSymbolsUnionRankCap() async throws {
    try await withApp { app in
        let repo = DatabaseInsightsRepository()
        let u1 = try await makeUser(email: "s1@example.com", on: app.db)
        let u2 = try await makeUser(email: "s2@example.com", on: app.db)
        // AMD held by both users -> rank 1
        try await makeStock(userId: u1, symbol: "amd", category: .stock, on: app.db)
        try await makeStock(userId: u2, symbol: "AMD", category: .stock, on: app.db)
        // NVDA held by one
        try await makeStock(userId: u1, symbol: "NVDA", category: .stock, on: app.db)
        // BTC is crypto -> excluded from holdings
        try await makeStock(userId: u1, symbol: "BTC", category: .crypto, on: app.db)
        // TSLA watchlisted (active) by one -> included
        try await makeWatchlistItem(userId: u2, symbol: "TSLA", status: "active", on: app.db)
        // AAPL watchlisted but archived -> excluded
        try await makeWatchlistItem(userId: u1, symbol: "AAPL", status: "archived", on: app.db)

        let all = try await repo.allTrackedSymbols(limit: 10, on: app.db)
        #expect(all.first == "AMD")            // most-held
        #expect(all.contains("NVDA"))
        #expect(all.contains("TSLA"))
        #expect(!all.contains("BTC"))          // crypto holding excluded
        #expect(!all.contains("AAPL"))         // archived watchlist excluded

        let capped = try await repo.allTrackedSymbols(limit: 1, on: app.db)
        #expect(capped == ["AMD"])             // cap honored, top-ranked kept
    }
}
```

Add these test helpers to the suite if not already present (mirror `NewsServiceTests`/existing model construction — confirm `Stock` and `WatchlistItem` initializers and the `category` enum case names in `Models/StockModel.swift` and `Models/WatchlistItem.swift` before writing):

```swift
private func makeUser(email: String, on db: any Database) async throws -> UUID {
    let u = User(email: email, passwordHash: "test-hash"); try await u.save(on: db); return try u.requireID()
}
private func makeStock(userId: UUID, symbol: String, category: StockCategory, on db: any Database) async throws {
    // Match the real Stock initializer — verify required fields in Models/StockModel.swift.
    let s = Stock(userId: userId, symbol: symbol, category: category /*, …required fields… */)
    try await s.save(on: db)
}
private func makeWatchlistItem(userId: UUID, symbol: String, status: String, on db: any Database) async throws {
    let w = WatchlistItem(userId: userId, symbol: symbol, status: status /*, …required fields… */)
    try await w.save(on: db)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `TEST_DATABASE_PORT=5432 LOG_LEVEL=warning swift test --filter allTrackedSymbolsUnionRankCap`
Expected: FAIL — `value of type 'DatabaseInsightsRepository' has no member 'allTrackedSymbols'` (compile error).

- [ ] **Step 3: Add the protocol requirement + implementation**

In `InsightsRepository.swift`, add to `protocol InsightsRepository`:

```swift
func allTrackedSymbols(limit: Int, on db: any Database) async throws -> [String]
```

Add to `DatabaseInsightsRepository` (raw SQL for the count/rank; both tables live in the same Postgres). Use `SQLDatabase`:

```swift
func allTrackedSymbols(limit: Int, on db: any Database) async throws -> [String] {
    guard let sql = db as? any SQLDatabase else { return [] }
    let cappedLimit = max(1, min(limit, 200))
    // Distinct (symbol,user) pairs from equity holdings + non-archived watchlist,
    // ranked by how many distinct users track each symbol.
    let rows = try await sql.raw("""
        SELECT symbol, COUNT(DISTINCT user_id) AS holders
        FROM (
            SELECT UPPER(TRIM(symbol)) AS symbol, user_id FROM stocks WHERE category = 'stock'
            UNION
            SELECT UPPER(TRIM(symbol)) AS symbol, user_id FROM watchlist_items WHERE status <> 'archived'
        ) AS tracked
        WHERE symbol <> ''
        GROUP BY symbol
        ORDER BY holders DESC, symbol ASC
        LIMIT \(bind: cappedLimit)
    """).all()
    return try rows.map { try $0.decode(column: "symbol", as: String.self) }
}
```

Note: confirm the `stocks.category` stored value for equities is the string `'stock'` (check the `@Enum`/`@Field` on `Models/StockModel.swift` — if it's an `@Enum`, the column stores the case's raw value; adjust the literal to match, e.g. `'stock'`).

- [ ] **Step 4: Run test to verify it passes**

Run: `TEST_DATABASE_PORT=5432 LOG_LEVEL=warning swift test --filter allTrackedSymbolsUnionRankCap`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/StockPlanBackend/Insights/InsightsRepository.swift Tests/StockPlanBackendTests/InsightsServiceTests.swift
git commit -m "feat(insights): allTrackedSymbols top-N holdings+watchlist union"
```

---

### Task 2: Dynamic symbol list in the poller

**Files:**
- Modify: `Sources/StockPlanBackend/Insights/InsightsService.swift` (`syncTickerPosts`, ~lines 203-231; and `DefaultInsightsService` init)
- Modify: `Sources/StockPlanBackend/configure.swift:239-250`
- Test: `Tests/StockPlanBackendTests/InsightsServiceTests.swift`

**Interfaces:**
- Consumes: `InsightsRepository.allTrackedSymbols(limit:on:)` from Task 1.
- Produces: `DefaultInsightsService` gains `tickerLimit: Int` and `pinnedTickers: [String]` (replacing the fixed `trackedTickers`). `syncTickerPosts` resolves symbols at run time = `pinnedTickers ∪ allTrackedSymbols(limit:)`, deduped, capped at `tickerLimit`.

- [ ] **Step 1: Write the failing test**

Extend the existing sync test (which uses `StubInsightsProvider`). Seed a stock, run `syncFromHermes`, assert the stub was asked for that symbol (add a recorded-symbols set to the stub) and its posts landed.

```swift
@Test("syncTickerPosts pulls symbols from holdings, not a static list")
func syncUsesHoldings() async throws {
    try await withApp { app in
        let u = try await makeUser(email: "h@example.com", on: app.db)
        try await makeStock(userId: u, symbol: "AMD", category: .stock, on: app.db)
        let service = DefaultInsightsService(
            repo: DatabaseInsightsRepository(),
            provider: StubInsightsProvider(),   // returns 1 post for whatever symbol asked
            tickerLimit: 25, pinnedTickers: []
        )
        let req = Request(application: app, on: app.eventLoopGroup.next())
        _ = try await service.syncFromHermes(on: req)
        let posts = try await TickerSentimentPost.query(on: app.db).filter(\.$symbol == "AMD").count()
        #expect(posts >= 1)
    }
}
```

Ensure `StubInsightsProvider.fetchTickerPosts` returns a post whose `symbol` echoes the requested symbol (edit the stub so it isn't hardcoded to AMD).

- [ ] **Step 2: Run test to verify it fails**

Run: `TEST_DATABASE_PORT=5432 LOG_LEVEL=warning swift test --filter syncUsesHoldings`
Expected: FAIL — `DefaultInsightsService` initializer has no `tickerLimit`/`pinnedTickers` params (compile error).

- [ ] **Step 3: Rewire the service**

In `InsightsService.swift`, change stored props and init:

```swift
let tickerLimit: Int
let pinnedTickers: [String]

init(repo: any InsightsRepository = DatabaseInsightsRepository(),
     provider: any InsightsProvider = DisabledInsightsProvider(),
     tickerLimit: Int = 25,
     pinnedTickers: [String] = []) {
    self.repo = repo; self.provider = provider
    self.tickerLimit = max(1, tickerLimit)
    self.pinnedTickers = pinnedTickers.map { $0.uppercased() }
}
```

In `syncTickerPosts(on req:)` replace the `for symbol in trackedTickers` source:

```swift
let dynamic = try await repo.allTrackedSymbols(limit: tickerLimit, on: req.db)
var seen = Set<String>(); var symbols: [String] = []
for s in (pinnedTickers + dynamic) where seen.insert(s).inserted { symbols.append(s) }
symbols = Array(symbols.prefix(tickerLimit))
for symbol in symbols { /* existing per-symbol fetch/insert loop, unchanged */ }
```

In `configure.swift` (lines ~239-250) replace `trackedTickers` wiring:

```swift
let tickerLimit = Environment.get("HERMES_TRACKED_TICKERS_LIMIT").flatMap(Int.init(_:)) ?? 25
let pinnedTickers = (Environment.get("HERMES_TRACKED_TICKERS") ?? "")
    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
app.insightsService = DefaultInsightsService(
    repo: app.insightsRepository, provider: insightsProvider,
    tickerLimit: tickerLimit, pinnedTickers: pinnedTickers)
```

Keep the existing "provider enabled but no symbols" boot warning; it's now informational only.

- [ ] **Step 4: Run tests to verify they pass**

Run: `TEST_DATABASE_PORT=5432 LOG_LEVEL=warning swift test --filter InsightsServiceTests`
Expected: PASS (all existing + new).

- [ ] **Step 5: Commit**

```bash
git add Sources/StockPlanBackend/Insights/InsightsService.swift Sources/StockPlanBackend/configure.swift Tests/StockPlanBackendTests/InsightsServiceTests.swift
git commit -m "feat(insights): poller uses holdings-driven top-N symbols"
```

---

### Task 3: `GET /v1/insights/tracked-symbols` (machine auth)

**Files:**
- Modify: `Sources/StockPlanBackend/Insights/InsightsController.swift`
- Modify: `Sources/StockPlanBackend/Insights/InsightsDTOs.swift` (add response DTO)
- Test: `Tests/StockPlanBackendTests/InsightsServiceTests.swift`

**Interfaces:**
- Consumes: `allTrackedSymbols` (Task 1); `app.insightsService.tickerLimit` or read env directly.
- Produces: `GET /v1/insights/tracked-symbols` → `TrackedSymbolsResponse { symbols: [String], limit: Int }`. Requires header `Authorization: Bearer <INSIGHTS_SYMBOLS_TOKEN>`; missing/wrong/env-unset ⇒ 403 (fail-closed). Registered OUTSIDE the Pro/scoped group (machine call).

- [ ] **Step 1: Write the failing test**

```swift
@Test("tracked-symbols requires the machine token")
func trackedSymbolsAuth() async throws {
    try await withApp { app in
        // env unset in tests -> fail-closed
        try await app.testing().test(.GET, "v1/insights/tracked-symbols", afterResponse: { res async throws in
            #expect(res.status == .forbidden)
        })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `TEST_DATABASE_PORT=5432 LOG_LEVEL=warning swift test --filter trackedSymbolsAuth`
Expected: FAIL — route returns 404 (not registered) rather than 403.

- [ ] **Step 3: Add DTO + route + handler**

In `InsightsDTOs.swift`:

```swift
struct TrackedSymbolsResponse: Content {
    let symbols: [String]
    let limit: Int
}
```

In `InsightsController.swift` `boot`, register on the raw (unauthenticated-by-session) `routes` builder, gating inside the handler with the machine token:

```swift
routes.grouped("insights").get("tracked-symbols", use: trackedSymbols)
```

```swift
@Sendable
func trackedSymbols(req: Request) async throws -> TrackedSymbolsResponse {
    let expected = (Environment.get("INSIGHTS_SYMBOLS_TOKEN") ?? "").trimmingCharacters(in: .whitespaces)
    guard !expected.isEmpty else { throw Abort(.forbidden, reason: "tracked-symbols is disabled (INSIGHTS_SYMBOLS_TOKEN unset).") }
    let presented = req.headers.bearerAuthorization?.token ?? ""
    guard presented == expected else { throw Abort(.forbidden, reason: "Invalid machine token.") }
    let limit = Environment.get("HERMES_TRACKED_TICKERS_LIMIT").flatMap(Int.init(_:)) ?? 25
    let symbols = try await req.application.insightsRepository.allTrackedSymbols(limit: limit, on: req.db)
    return TrackedSymbolsResponse(symbols: symbols, limit: limit)
}
```

Note: `bearerAuthorization` compare here is fine (machine token); constant-time compare is not required for a tailnet-only internal token, but if `ConstantTimeCompare`/`hmac`-style helper already exists in the codebase, prefer it.

- [ ] **Step 4: Run test to verify it passes**

Run: `TEST_DATABASE_PORT=5432 LOG_LEVEL=warning swift test --filter trackedSymbolsAuth`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/StockPlanBackend/Insights/InsightsController.swift Sources/StockPlanBackend/Insights/InsightsDTOs.swift Tests/StockPlanBackendTests/InsightsServiceTests.swift
git commit -m "feat(insights): tracked-symbols endpoint (machine-token gated)"
```

---

### Task 4: Env + OpenAPI + docker wiring

**Files:**
- Modify: `.env.example`, `docker-compose.yml`, `openapi.yaml`
- Test: `Tests/StockPlanBackendTests/OpenAPIDocsTests.swift` (if it asserts path coverage)

**Interfaces:** none new; documents the two envs and the two routes for web codegen.

- [ ] **Step 1: Add envs**

`.env.example` (after the existing HERMES block):
```
HERMES_TRACKED_TICKERS_LIMIT=25
# Machine bearer for GET /v1/insights/tracked-symbols (VPS fetches it over Tailscale). Empty = endpoint disabled.
INSIGHTS_SYMBOLS_TOKEN=
```
`docker-compose.yml` `x-shared_environment`:
```
  HERMES_TRACKED_TICKERS_LIMIT: ${HERMES_TRACKED_TICKERS_LIMIT:-25}
  INSIGHTS_SYMBOLS_TOKEN: ${INSIGHTS_SYMBOLS_TOKEN:-}
```

- [ ] **Step 2: Add OpenAPI paths**

Add `/v1/insights/tickers/{symbol}/sentiment` (GET, Pro) and `/v1/insights/tracked-symbols` (GET) to `openapi.yaml` with response schemas matching `TickerSentimentResponse` and `TrackedSymbolsResponse`. Verify shapes against `InsightsDTOs.swift`.

- [ ] **Step 3: Run the OpenAPI/route tests**

Run: `TEST_DATABASE_PORT=5432 LOG_LEVEL=warning swift test --filter OpenAPIDocsTests`
Expected: PASS (add the paths to any coverage list the test enforces).

- [ ] **Step 4: Full build + test**

Run: `TEST_DATABASE_PORT=5432 LOG_LEVEL=warning swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add .env.example docker-compose.yml openapi.yaml Tests/StockPlanBackendTests/OpenAPIDocsTests.swift
git commit -m "chore(insights): env + openapi for tracked-symbols and ticker sentiment"
```

---

### Task 5: Hermes scraper — refresh symbols from the backend

**Files:**
- Modify: `scripts/hermes/ticker_sentiment_scraper.py` (add a `--refresh-symbols <url>` mode)
- Modify: the `hermes-ticker-sentiment` cron prompt / `scripts/hermes/setup-hermes-agent-jobs.sh` (call the refresh before scraping)
- Test: local dry-run on the VPS

**Interfaces:**
- Consumes: `GET /v1/insights/tracked-symbols` (Task 3) over Tailscale, `Authorization: Bearer $INSIGHTS_SYMBOLS_TOKEN`.
- Produces: rewrites `scraper_config.json` `tickers` from the endpoint; falls back to existing config on failure.

- [ ] **Step 1: Add the refresh function (idempotent, fail-safe)**

In `ticker_sentiment_scraper.py`, add a mode that: reads `BACKEND_INSIGHTS_URL` + `INSIGHTS_SYMBOLS_TOKEN` from env (loaded via the existing `load_env_files`), GETs `/v1/insights/tracked-symbols`, and on success overwrites `scraper_config.json`'s `tickers` list; on any error logs a warning and leaves the file untouched. Cap defensively at 50.

```python
def refresh_symbols(config_path, url, token, timeout=30):
    import urllib.request, json
    try:
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        data = json.loads(urllib.request.urlopen(req, timeout=timeout).read().decode())
        syms = [str(s).upper() for s in (data.get("symbols") or []) if str(s).strip()][:50]
        if not syms:
            LOG.warning("refresh_symbols: empty list, keeping existing config"); return
        cfg = json.loads(open(config_path).read())
        cfg["tickers"] = syms
        open(config_path, "w").write(json.dumps(cfg, indent=2))
        LOG.info("refresh_symbols: wrote %d symbols", len(syms))
    except Exception as e:
        LOG.warning("refresh_symbols failed (%s); keeping existing config", e)
```

Wire a `--refresh-symbols URL` argparse flag that calls it (token from env) then exits, so the cron can run it as a pre-step.

- [ ] **Step 2: Compile-check**

Run: `python3 -m py_compile scripts/hermes/ticker_sentiment_scraper.py`
Expected: no output (success).

- [ ] **Step 3: Update the cron to refresh first**

Edit `setup-hermes-agent-jobs.sh` so the `hermes-ticker-sentiment` prompt begins with a refresh step:
`python3 <pipeline>/scripts/ticker_sentiment_scraper.py --refresh-symbols http://<backend-tailnet-ip>:8080/v1/insights/tracked-symbols` before it reads `scraper_config.json`. Document `BACKEND_INSIGHTS_URL` + reuse of `INSIGHTS_SYMBOLS_TOKEN` (add to `/root/.hermes/.env` on the VPS — user step, not committed).

- [ ] **Step 4: Commit**

```bash
git add scripts/hermes/ticker_sentiment_scraper.py scripts/hermes/setup-hermes-agent-jobs.sh
git commit -m "feat(hermes): refresh scraper symbols from backend tracked-symbols"
```

---

## Deployment / Ops (post-merge, user-run)

- Set `INSIGHTS_SYMBOLS_TOKEN` (same value) in prod `/opt/stockplan/.env.production` and `/root/.hermes/.env` on the VPS; set `BACKEND_INSIGHTS_URL=http://100.89.19.79:8080/v1/insights/tracked-symbols` (backend tailnet IP) on the VPS.
- Deploy the backend image; recreate `prod-app`.
- Re-run `setup-hermes-agent-jobs.sh` (or edit the existing cron) so the ticker job refreshes symbols first.
- Verify: `curl -H "Authorization: Bearer $INSIGHTS_SYMBOLS_TOKEN" http://100.89.19.79:8080/v1/insights/tracked-symbols` returns the top-N; confirm `scraper_config.json` updates after one cron tick.

## Verification (end of plan)

- `TEST_DATABASE_PORT=5432 LOG_LEVEL=warning swift test` all green.
- A user's held symbol appears in `/v1/insights/tracked-symbols`; after a scrape cycle, `/v1/insights/tickers/{symbol}/sentiment` returns posts for it.

## Self-Review Notes

- Spec coverage: dynamic union (Task 1), poller rewire (Task 2), machine endpoint (Task 3), env/openapi (Task 4), Hermes refresh (Task 5). Cost cap = N in Tasks 1-3. Equity caveat encoded in Task 1 SQL. iOS/web are Plans 2 and 3 (depend on Task 4's openapi).
- Verify before coding: exact `Stock`/`WatchlistItem` initializers + the stored `category` raw value (Task 1 SQL literal `'stock'` must match), and whether `InsightsController.boot` uses `routes` or a scoped group (Task 3 registers on the raw builder).
