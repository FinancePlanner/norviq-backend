# Follow a Pilot — simulated copy-trading (v1) — Design

Status: approved design, 2026-10-01. Next: implementation plan via writing-plans.

## Context

Goal: let Norviq users "follow" a politician or a 13F fund and have that pilot's trades mirrored automatically, the way Autopilot (joinautopilot.com) does. Users choose the destination: a secondary (hypothetical) portfolio or a watchlist, so they can try a pilot out without touching their main portfolio.

Research findings (2026-10-01):
- Autopilot has **no public or partner API**. The only third-party uses scrape its public pages.
- Autopilot places real trades through an SEC-registered adviser (Autopilot Advisers LLC, CRD 331749).
- If Norviq placed trades automatically in users' real brokerage accounts, it would very likely need to register as an investment adviser.

So v1 is **simulated only**: no real orders, no push alerts. Norviq already pulls congress trades from FMP (`Market/CongressTrades.swift`) and already has hypothetical portfolios (`PortfolioMode.hypothetical`).

Decisions made with the user:
- **Pilots:** politicians and 13F funds, from a curated seed list (about 15 politicians and about 10 funds).
- **Targets:**
  - A hypothetical portfolio, which gets a full simulated ledger.
  - A watchlist, which gets a symbol feed: buys add the symbol, sells set the new status `exited`.
  - Main or actual portfolios are rejected.
- **Sizing:** mirror the pilot's weights. The user chooses starting capital, and Norviq rebalances on each new disclosure or filing.
- **Options:** calls map to the underlying stock. Puts are skipped, because the portfolio can't go short, and the skipped count is shown.
- **Performance history:** a separate `pilot_follow_snapshots` table. `PortfolioSnapshotJob` keeps its "real portfolios only" rule.
- **Clients:** iOS and web.
- **Naming:** never use the "Autopilot" brand in code or UI. Use pilot/follow.

## Phase 0 — Gate (before code)
- Run one curl with the prod FMP key: `/stable/institutional-ownership/extract?cik=0001067983&year=2026&quarter=2`.
  - If it returns holdings, use `FMP13FPilotSource`.
  - Otherwise use `SECEdgar13FPilotSource`. It reads `data.sec.gov` submissions, then `13F-HR` info-table XML. It needs `User-Agent` from env `SEC_EDGAR_USER_AGENT`, ≤10 requests/second, and a `cusip_symbols` cache filled from an FMP CUSIP lookup. Egress is open, so no network policy change is needed.

## Phase 1 — Backend data + jobs (`norviq-backend/Sources/StockPlanBackend/`)

**Models and migrations.** Files: `Models/Pilot*.swift`, `Migrations/CreatePilotTables.swift` and `Migrations/SeedPilots.swift`. Register both migrations in `ConfigureBootstrap.swift`.

| Table | Fields | Notes |
|---|---|---|
| `pilots` | kind (politician/fund), slug, display_name, chamber, bioguide_id, cik, name_aliases jsonb, active, last_ingested_at | |
| `pilot_disclosures` | pilot_id, source_key, symbol, side, instrument (stock/call/put), transaction_date, disclosure_date, amount_min/max, est_value, shares, filing_accession, period, raw jsonb, discovered_at | **unique (pilot_id, source_key)** |
| `pilot_book_versions` | pilot_id, version, computed_at, weights jsonb, skipped_puts | unique (pilot_id, version) |
| `pilot_follows` | user_id, pilot_id, target_kind, portfolio_list_id?, watchlist_list_id?, starting_capital, currency, applied_version, status (active/paused) | |
| `pilot_follow_events` | follow_id, book_version, kind, symbol, qty, price, priced_at, disclosure_ids, note | unique (follow_id, book_version, symbol) |
| `pilot_follow_snapshots` | follow_id, date, value, cash | unique (follow_id, date) |

**Sources.** The protocol `Pilots/PilotDisclosureSource.swift` is named for what it provides, not for a vendor. Implementations:
- `FMPCongressPilotSource`: reuses `CongressTrades` and `amountBounds`, and adds the FMP `*-trades-by-name` endpoints.
- The 13F source chosen at Phase 0.

**Book math.** `Pilots/PilotBookBuilder.swift` is pure code.
- Politicians:
  - A buy adds the range midpoint ("Over $X" counts as X).
  - A partial sale subtracts the midpoint. A full sale zeroes the position.
  - Sales of positions we never saw are ignored.
  - Call buys and sales count as the underlying stock. Puts are skipped and counted.
  - The book uses a 24-month lookback.
- Funds: weight = market value ÷ filing total.

**One write path.** Extract `Portfolio/LedgerTradeRecorder.swift` from `Stocks/StockService.swift:384-470` (the sell path).
- Inside the caller's `db.transaction`, it updates `stocks`, using the weighted-average merge from `DatabaseStocksRepository.create` for buys. It also updates `CashBalance` on the `ManualAccountResolver` account and inserts the `Transaction`.
- Resolve instruments before the transaction, as the sell path already does.
- Refactor `StockService.sell` to use the recorder, with prefix `manual:`. Write characterization tests first.
- Pilot trades use `external_id = pilot:{followId}:v{version}:{symbol}`. The existing unique `(account_id, external_id)` index blocks duplicates, and the rows are read-only.

**Mirror logic.** `Pilots/PilotMirrorService.swift`.
- V = cash + Σ shares × live quote. Target shares = w·V/p, fractional allowed.
- Sells first, then buys capped by cash. Skip trades under max($5, 0.25%·V). Skip and log unpriced symbols.
- **Price = live `MarketDataProvider.quote` when Norviq discovers the disclosure.** `trade_date` = discovery date. The original dates go only in the event note. No historical backfill.
- **Creating a follow**, in one transaction:
  1. Create a new `mode=hypothetical` `PortfolioList`.
  2. Set `CashBalance` to the starting capital.
  3. Apply the latest book version.
- Existing hypothetical portfolios are allowed only if empty. Default or actual portfolios get 422.
- **Watchlist target:**
  - A buy upserts the `WatchlistItem` with a note like "Pelosi bought 2026-09-14".
  - A sell sets `exited` and appends the sell to the note.
  - A re-buy sets the item back to `active`.

**Jobs.** `Pilots/PilotIngestionJob.swift` and `Pilots/PilotMirrorJob.swift`.
- Both copy the `Portfolio/PortfolioSnapshotJob.swift` pattern: `runOnce`/`runOnceAsLeader`, `JobLock`, and a `Request(application:on:)` for FMP.
- Ingestion runs every 6h for congress and daily for 13F. It writes a new book version only when something is new.
- The mirror job applies the latest version to follows that are behind. It also writes the daily `pilot_follow_snapshots`.
- Register both in `configure.swift` behind `envBool("PILOTS_ENABLED", default: false)`.

## Phase 2 — API + shared
- **`norviq-shared`:** add `Sources/StockPlanShared/Pilots/PilotDTOs.swift` (`PilotSummary`, `PilotDetail`, `PilotFollowCreateRequest`, `PilotFollowResponse`, `PilotFollowEvent`, `PilotFollowSnapshot`) and `WatchlistStatus.exited` in `Stocks/StockDTOs.swift:142`.
  - Tag **5.15.0**.
  - Bump the exact pins in `norviq-backend/Package.swift:9` and in both iOS targets (`financeplan` and `financeplan-brand`, `project.pbxproj`), plus `Package.resolved`.
- **Controller:** `Pilots/PilotController.swift`, under `/v1` in the rate-limited group, registered in `routes.swift`. It returns 404 when the flag is off, following the `REBALANCING_ENABLED` pattern in `Rebalancing/RebalancingController.swift:300`.
  - `GET /pilots`
  - `GET /pilots/:slug`
  - `GET|POST /pilot-follows` (POST behind `IdempotencyMiddleware`)
  - `GET|PATCH|DELETE /pilot-follows/:id`: PATCH pauses or resumes. DELETE stops the follow and keeps the portfolio.
  - `GET /pilot-follows/:id/events`
  - `GET /pilot-follows/:id/snapshots`
- **Gating:** add `BillingFeature.pilotFollows` in `Billing/EntitlementResolver.swift`.
  - Free: 1 watchlist follow, and the 10-item watchlist limit still applies.
  - Pro: up to 10 follows, including portfolio follows.
  - Over the limit → `BillingUpgradeRequiredError`.
- Update `openapi.yaml`.

## Phase 3 — iOS (`norviq-ios/financeplan/financeplan/Features/Pilots/`)
- Screens:
  - `PilotsBrowseScreen`
  - `PilotDetailScreen`: weights, recent disclosures, skipped-puts note.
  - `FollowPilotSheet`: target picker, capital, and a disclaimer about lag (45 days for congress, 135 for 13F), simulation and pricing at discovery.
  - `PilotFollowDetailScreen`: event log and snapshot chart.
- Entry points: a "Follow a pilot" row in `PortfolioManagement/PortfolioWorkspaceScreen.swift`, and a "Following X" banner in `PortfolioDetailScreen.swift`.
- Watchlist follows show their feed in the event log, since iOS has no stock watchlist screen.

## Phase 4 — Web (`norviq-web`)
- Run `make generate` from the updated `openapi.yaml`.
- Handlers `internal/handlers/pilots.go` and `pilot_follows.go`, pages `internal/pages/pilots/*.templ`, routes in `internal/server/server.go`.
- Link from `pages/markets/congress.templ` and from the portfolio workspace.

## Phase 5 — Rollout (+ optional MCP)
- Set `PILOTS_ENABLED: "false"` in `~/Work/production/platform/infra/apps/norviq/api/values-{common,staging,production}.yaml`. Never in the archived `norviq-infra/`.
- Order: enable on staging, then production for Pro, then for free users. Deploys are manual dispatch (`-f service=both`).
- Optional MCP: read-only `list_pilots` and `get_pilot_follow` in `norviq-mcp/internal/tools/pilots.go`, plus `catalog_parity_test.go`.

## Verification
- **Backend tests** use swift-testing `@Suite(.serialized)` + `DatabaseTestLock.withSharedAccess` + `Application.make(.testing)`, modeled on `PortfolioSnapshotJobTests.swift`, with a stub `PilotDisclosureSource`. They must show:
  - Book math: brackets, "Over $X", partial and full sales, calls mapped, puts skipped.
  - The same disclosure ingested twice produces one row. Running the mirror twice produces no new transactions.
  - After a rebalance, `stocks` and `transactions` agree, and cash is never negative.
  - Actual and default portfolios are rejected with 422. Free-tier limits are enforced.
  - The `StockService.sell` characterization tests still pass after the refactor.
  - The watchlist feed goes buy → `active`, sell → `exited`, re-buy → `active`.
- **Controller tests** follow `PortfolioShareRouteTests.swift`, and `OpenAPIDocsTests` must pass.
- **Web:** Go tests with `httptest` + `api.NewService` (pattern from `markets_congress_test.go`).
- **End to end on staging** with the flag on:
  1. Follow one politician into a new hypothetical portfolio with $10k, and check that the holdings match the book weights.
  2. Run the ingestion and mirror jobs, and check that the event log and a snapshot row appear.
  3. Follow a fund into a watchlist, and check the items and notes.
  4. Check on both iOS and web.

## Risks
- Name drift: there are no stable politician IDs, so aliases need hand upkeep.
- Mapping calls to the underlying overstates how much exposure the pilot actually has.
- The lag must be visible in the UI.
- Marketing wording like "follow X" needs a compliance read before launch.
- FMP's terms may restrict showing its data in the product.
