# Pilot Follows — Backend + Shared Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Users can follow a curated politician or 13F fund. Norviq then mirrors that pilot's trades as simulated trades into a hypothetical portfolio, or as a symbol feed into a watchlist. This plan delivers the work through a flag-gated `/v1` API.

**Architecture:**
- Sources (FMP congress, FMP 13F) feed `pilot_disclosures`.
- `PilotIngestionService` turns disclosures into versioned target weights (`pilot_book_versions`).
- `PilotMirrorService` rebalances each follow to the latest version through `LedgerTradeRecorder`. The recorder is the one write path that keeps `stocks`, `cash_balances` and `transactions` in step.
- Two `LifecycleHandler` jobs drive ingestion and mirroring. `PilotController` exposes the API behind `PILOTS_ENABLED`.

**Tech Stack:** Swift 6, Vapor 4, Fluent and raw-SQL migrations on Postgres, swift-testing, and the `StockPlanShared` package.

**Spec:** `docs/superpowers/specs/2026-10-01-pilot-follow-design.md`. Read it before starting.

**Out of scope here:** iOS, web, MCP and production rollout. Each gets its own plan once this API is merged.

## Global Constraints

- Simulated only. Nothing in this plan places a real order or calls a broker.
- Never write "Autopilot" in code, identifiers, copy or commit messages. Use pilot/follow.
- Targets: only `mode = 'hypothetical'` portfolios that are not `is_default`, not archived and have no holdings, plus watchlists. Anything else → HTTP 422.
- Simulated trades are priced with the live quote when Norviq applies the book. `trade_date` = application date. Never use historical prices.
- Pilot transactions use `external_id = "pilot:{followId}:v{version}:{symbol}"`. That prefix is not `manual:`, so the existing `requireManualTransaction` makes them read-only.
- Gating: Free = 1 follow, watchlist target only. Pro = up to 10 follows. Over the limit → `BillingUpgradeRequiredError(feature: .pilotFollows, …)`.
- Feature flag: `envBool("PILOTS_ENABLED", default: false)`. When off, the controller returns 404 and the jobs are not registered.
- Shared package: additive changes only. Develop against it with `STOCKPLAN_SHARED_PATH`, and tag it only in Task 13.
- Work in the worktree `norviq-backend-pilots` (branch `feat/pilot-follow`). Shared changes go in a new worktree `norviq-shared-pilots` (branch `feat/pilot-dtos`). Never touch `norviq-backend` (`feat/boards`) or `norviq-shared` (`feat/boards-dtos`); both have uncommitted work in progress.
- **Data sources are free-only (decided 2026-10-01).** FMP is on the free tier: only `/stable/senate-latest` and `/stable/house-latest`, `page=0`, `limit` ≤ 25, with roughly 250 requests a day across the whole app. Fetch each chamber at most once per ingestion run. 13F comes from SEC EDGAR, which needs a `User-Agent` (env `SEC_EDGAR_USER_AGENT`, default `Norviq ops@norviq.org`) and allows ≤ 10 requests/s. Map CUSIPs through OpenFIGI without a key: ≤ 10 jobs per request, ≤ 25 requests/min, with results cached in `cusip_symbols`.
- Test command: `$TEST_ENV swift test --filter <Suite>`, run from `norviq-backend-pilots/`, where `TEST_ENV="LOG_LEVEL=warning STOCKPLAN_SHARED_PATH=../norviq-shared-pilots TEST_DATABASE_USERNAME=stockplan_user TEST_DATABASE_PASSWORD=stockplan_password TEST_DATABASE_NAME=stockplan_dev"`. Before running, Postgres and Redis must be up: `docker compose up -d db redis` in this worktree. Use `env $TEST_ENV swift test …` in a shell, or prefix the vars inline.

## Review Focus

1. **A politician sells a stock we never saw them buy** (bought before the 24-month window). Expected: ignored, with no negative exposure and no crash. Test: Task 4, `sellOfUnseenPositionIgnored`.
2. **A quote is unavailable for a held or target symbol.** Expected: that symbol is left untouched, the rest of the rebalance proceeds, and a `skipped_unpriced` event is logged. Test: Task 8, `unpricedSymbolLeftAlone`.
3. **The mirror job runs twice for the same version, or two pods race.** Expected: exactly one set of trades. Test: Task 8, `applyIsIdempotent`.
4. **A free user's watchlist follow would push the watchlist past 10 items.** Expected: the highest-weight symbols are added up to the limit, and the rest are logged as `skipped_limit`. Test: Task 8, `watchlistRespectsItemLimit`.
5. **The user follows into a hypothetical portfolio that already has holdings, or into their main portfolio.** Expected: 422 and nothing written. Test: Task 9, `rejectsNonEmptyAndActualTargets`.

---

## File Map

| File | Responsibility |
|---|---|
| `norviq-shared-pilots/Sources/StockPlanShared/Pilots/PilotDTOs.swift` | Wire DTOs |
| `norviq-shared-pilots/Sources/StockPlanShared/Stocks/StockDTOs.swift` | `WatchlistStatus.exited` |
| `Sources/StockPlanBackend/Migrations/CreatePilotTables.swift` | 6 tables |
| `Sources/StockPlanBackend/Migrations/SeedPilots.swift` | Curated pilots |
| `Sources/StockPlanBackend/Models/PilotModels.swift` | Fluent models + enums |
| `Sources/StockPlanBackend/Pilots/PilotDisclosureSource.swift` | Protocol + `PilotDisclosureInput` |
| `Sources/StockPlanBackend/Pilots/FMPCongressPilotSource.swift` | Congress source |
| `Sources/StockPlanBackend/Pilots/EDGAR13FParser.swift` | Parse EDGAR submissions, index and info table |
| `Sources/StockPlanBackend/Pilots/CusipSymbolResolver.swift` | OpenFIGI CUSIP→ticker + `cusip_symbols` cache |
| `Sources/StockPlanBackend/Pilots/SECEdgar13FPilotSource.swift` | 13F source |
| `Sources/StockPlanBackend/Pilots/PilotBookBuilder.swift` | Pure weight math |
| `Sources/StockPlanBackend/Pilots/PilotIngestionService.swift` | Upsert disclosures, write versions |
| `Sources/StockPlanBackend/Portfolio/LedgerTradeRecorder.swift` | One write path for stocks + cash + transactions |
| `Sources/StockPlanBackend/Pilots/PilotRebalancePlanner.swift` | Pure order planning |
| `Sources/StockPlanBackend/Pilots/PilotMirrorService.swift` | Apply a version to a follow |
| `Sources/StockPlanBackend/Pilots/PilotFollowService.swift` | Create, validate and gate follows |
| `Sources/StockPlanBackend/Pilots/PilotJobs.swift` | Ingestion + mirror jobs |
| `Sources/StockPlanBackend/Pilots/PilotController.swift` | Routes |
| Modify `Stocks/StockService.swift:384-494` | `sell` delegates to the recorder |
| Modify `Market/CongressTrades.swift` | `FMPCongressTrade.senateID` |
| Modify `Billing/EntitlementResolver.swift:103` | `BillingFeature.pilotFollows` |
| Modify `ConfigureBootstrap.swift:430`, `configure.swift:~470`, `routes.swift:~108`, `openapi.yaml` | Registration |
| Tests in `Tests/StockPlanBackendTests/Pilot*.swift`, `LedgerTradeRecorderTests.swift` | |

---

### Task 1: Gate — confirm FMP data shapes and the 13F plan tier

> **Done 2026-10-01 (controller).** FMP is on the free tier: by-name, by-symbol and 13F are restricted, and only the latest feeds work (page 0, ≤ 25 rows, `senateID` = bioguide). Saved `Fixtures/pilots/{house,senate}-latest.json`. The user chose free-only sources, so Tasks 5, 6, 10 and 11 are amended accordingly.

There is no product code in this task. It decides whether Task 6's 13F source is viable, and it records real payloads as test fixtures.

**Files:**
- Create: `Tests/StockPlanBackendTests/Fixtures/pilots/senate-by-name.json`
- Create: `Tests/StockPlanBackendTests/Fixtures/pilots/house-by-name.json`
- Create: `Tests/StockPlanBackendTests/Fixtures/pilots/13f-extract.json`

- [ ] **Step 1: Ask the user for the FMP key.** It is a SealedSecret in the `norviq` namespace, and reading a production secret needs their go-ahead. The command, once approved:

```bash
export FMP_API_KEY=$(KUBECONFIG=~/.kube/maat.yaml kubectl -n norviq get secret norviq-api-secrets -o jsonpath='{.data.FMP_API_KEY}' | base64 -d)
```
(If the secret name differs, list them with `kubectl -n norviq get secrets` and pick the one holding `FMP_API_KEY`.)

- [ ] **Step 2: Fetch the three samples.**

```bash
mkdir -p Tests/StockPlanBackendTests/Fixtures/pilots
curl -s "https://financialmodelingprep.com/stable/senate-trades-by-name?name=Tuberville&apikey=$FMP_API_KEY" | jq '.[0:5]' > Tests/StockPlanBackendTests/Fixtures/pilots/senate-by-name.json
curl -s "https://financialmodelingprep.com/stable/house-trades-by-name?name=Pelosi&apikey=$FMP_API_KEY" | jq '.[0:8]' > Tests/StockPlanBackendTests/Fixtures/pilots/house-by-name.json
curl -s "https://financialmodelingprep.com/stable/institutional-ownership/extract?cik=0001067983&year=2026&quarter=2&apikey=$FMP_API_KEY" | jq '.[0:5]' > Tests/StockPlanBackendTests/Fixtures/pilots/13f-extract.json
head -c 600 Tests/StockPlanBackendTests/Fixtures/pilots/*.json
```

- [ ] **Step 3: Decide.**
  - **Congress:** each congress file must be a JSON array whose objects carry `firstName`, `lastName`, `symbol`, `type`, `amount` and `assetType`.
  - **13F, success:** the 13F file must be an array of objects with a ticker (`symbol`), `shares`, `value`, `putCallShare` and a CUSIP field.
  - **13F, failure:** an error object, `[]` or a "Premium" message means the plan tier is too low. In that case, **stop after Task 12 without Task 6's 13F source**. Fund pilots get seeded `active = false`. Tell the user the SEC EDGAR source needs its own plan.
  - **Different field names:** if any field name differs from the `CodingKeys` in Tasks 5–6, update those keys to match the fixture. The fixture is the truth.
  - **Secrets:** strip `apikey` from anything saved. The files contain only response bodies.

- [ ] **Step 4: Commit**

```bash
git add Tests/StockPlanBackendTests/Fixtures/pilots
git commit -m "test(pilots): record FMP congress and 13F response fixtures"
```

---

### Task 2: Shared DTOs + `WatchlistStatus.exited`

**Files:**
- Create: `../norviq-shared-pilots/Sources/StockPlanShared/Pilots/PilotDTOs.swift`
- Modify: `../norviq-shared-pilots/Sources/StockPlanShared/Stocks/StockDTOs.swift:142-148`
- Test: `../norviq-shared-pilots/Tests/StockPlanSharedTests/PilotDTOsTests.swift`

**Interfaces:**
- Produces:
  - Enums: `PilotKind`, `PilotFollowTargetKind`, `PilotFollowStatus`.
  - Structs: `PilotSummary`, `PilotWeight`, `PilotDisclosureItem`, `PilotDetail`, `PilotFollowCreateRequest`, `PilotFollowUpdateRequest`, `PilotFollowResponse`, `PilotFollowEventResponse`, `PilotFollowSnapshotResponse`.
  - `WatchlistStatus.exited`.

- [ ] **Step 1: Create the worktree.**

```bash
cd /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-shared
git fetch origin main -q
git worktree add -b feat/pilot-dtos ../norviq-shared-pilots origin/main
cd ../norviq-shared-pilots
```

- [ ] **Step 2: Write the failing test.**

```swift
import Foundation
import StockPlanShared
import Testing

@Suite("PilotDTOs")
struct PilotDTOsTests {
    @Test("follow request round-trips with camelCase keys")
    func createRequestRoundTrip() throws {
        let request = PilotFollowCreateRequest(
            pilotSlug: "nancy-pelosi",
            targetKind: .portfolio,
            portfolioListId: nil,
            watchlistListId: nil,
            startingCapital: 10_000
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"pilotSlug\":\"nancy-pelosi\""))
        #expect(json.contains("\"targetKind\":\"portfolio\""))
        #expect(try JSONDecoder().decode(PilotFollowCreateRequest.self, from: data) == request)
    }

    @Test("watchlist status decodes exited")
    func exitedStatus() throws {
        let decoded = try JSONDecoder().decode([WatchlistStatus].self, from: Data("[\"exited\"]".utf8))
        #expect(decoded == [.exited])
    }
}
```

- [ ] **Step 3: Run it and confirm it fails.** Run `swift test --filter PilotDTOsTests`. Expected: a compile failure, because `PilotFollowCreateRequest` is undefined.

- [ ] **Step 4: Add `case exited` after `case archived`** in `Stocks/StockDTOs.swift`:

```swift
public enum WatchlistStatus: String, Codable, Sendable, CaseIterable {
    case active
    case researching
    case waiting
    case ready
    case archived
    /// The pilot this item was mirrored from has sold it. Set only by pilot follows.
    case exited
}
```

- [ ] **Step 5: Write `Pilots/PilotDTOs.swift`.**

```swift
import Foundation

public enum PilotKind: String, Codable, Sendable, CaseIterable {
    case politician
    case fund
}

public enum PilotFollowTargetKind: String, Codable, Sendable, CaseIterable {
    case portfolio
    case watchlist
}

public enum PilotFollowStatus: String, Codable, Sendable, CaseIterable {
    case active
    case paused
}

public struct PilotSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { slug }
    public let slug: String
    public let displayName: String
    public let kind: PilotKind
    /// `senate` or `house` for politicians; nil for funds.
    public let chamber: String?
    /// ISO-8601 time of the latest book version; nil before the first ingestion.
    public let updatedAt: String?
    public let holdingsCount: Int

    public init(slug: String, displayName: String, kind: PilotKind, chamber: String?, updatedAt: String?, holdingsCount: Int) {
        self.slug = slug
        self.displayName = displayName
        self.kind = kind
        self.chamber = chamber
        self.updatedAt = updatedAt
        self.holdingsCount = holdingsCount
    }
}

public struct PilotWeight: Codable, Sendable, Equatable {
    public let symbol: String
    /// 0...1. Weights in a book sum to 1.
    public let weight: Double

    public init(symbol: String, weight: Double) {
        self.symbol = symbol
        self.weight = weight
    }
}

public struct PilotDisclosureItem: Codable, Sendable, Equatable {
    public let symbol: String
    /// `buy`, `sell`, `sell_full` or `hold`.
    public let side: String
    /// `stock`, `call` or `put`.
    public let instrument: String
    public let transactionDate: String?
    public let disclosureDate: String?
    public let amountMin: Double?
    public let amountMax: Double?
    /// 13F period such as `2026Q2`; nil for politicians.
    public let period: String?

    public init(symbol: String, side: String, instrument: String, transactionDate: String?, disclosureDate: String?, amountMin: Double?, amountMax: Double?, period: String?) {
        self.symbol = symbol
        self.side = side
        self.instrument = instrument
        self.transactionDate = transactionDate
        self.disclosureDate = disclosureDate
        self.amountMin = amountMin
        self.amountMax = amountMax
        self.period = period
    }
}

public struct PilotDetail: Codable, Sendable, Equatable {
    public let pilot: PilotSummary
    public let weights: [PilotWeight]
    /// Put trades in the window. They are not mirrored because a portfolio cannot go short.
    public let skippedPuts: Int
    public let recentDisclosures: [PilotDisclosureItem]
    /// Plain-language reporting-lag and pricing disclaimer for this pilot kind.
    public let lagNote: String

    public init(pilot: PilotSummary, weights: [PilotWeight], skippedPuts: Int, recentDisclosures: [PilotDisclosureItem], lagNote: String) {
        self.pilot = pilot
        self.weights = weights
        self.skippedPuts = skippedPuts
        self.recentDisclosures = recentDisclosures
        self.lagNote = lagNote
    }
}

public struct PilotFollowCreateRequest: Codable, Sendable, Equatable {
    public let pilotSlug: String
    public let targetKind: PilotFollowTargetKind
    /// An existing empty hypothetical portfolio. Nil creates a new one.
    public let portfolioListId: String?
    /// An existing watchlist. Nil creates a new one.
    public let watchlistListId: String?
    /// Required for portfolio targets; ignored for watchlists.
    public let startingCapital: Double?

    public init(pilotSlug: String, targetKind: PilotFollowTargetKind, portfolioListId: String?, watchlistListId: String?, startingCapital: Double?) {
        self.pilotSlug = pilotSlug
        self.targetKind = targetKind
        self.portfolioListId = portfolioListId
        self.watchlistListId = watchlistListId
        self.startingCapital = startingCapital
    }
}

public struct PilotFollowUpdateRequest: Codable, Sendable, Equatable {
    public let status: PilotFollowStatus

    public init(status: PilotFollowStatus) {
        self.status = status
    }
}

public struct PilotFollowResponse: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let pilot: PilotSummary
    public let targetKind: PilotFollowTargetKind
    public let portfolioListId: String?
    public let watchlistListId: String?
    public let startingCapital: Double?
    public let currency: String
    public let status: PilotFollowStatus
    /// 0 until the first book version has been applied.
    public let appliedVersion: Int
    public let createdAt: String

    public init(id: String, pilot: PilotSummary, targetKind: PilotFollowTargetKind, portfolioListId: String?, watchlistListId: String?, startingCapital: Double?, currency: String, status: PilotFollowStatus, appliedVersion: Int, createdAt: String) {
        self.id = id
        self.pilot = pilot
        self.targetKind = targetKind
        self.portfolioListId = portfolioListId
        self.watchlistListId = watchlistListId
        self.startingCapital = startingCapital
        self.currency = currency
        self.status = status
        self.appliedVersion = appliedVersion
        self.createdAt = createdAt
    }
}

public struct PilotFollowEventResponse: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let bookVersion: Int
    /// `buy`, `sell`, `watch_added`, `watch_exited`, `skipped_unpriced` or `skipped_limit`.
    public let kind: String
    public let symbol: String
    public let quantity: Double?
    public let price: Double?
    public let pricedAt: String
    public let note: String?

    public init(id: String, bookVersion: Int, kind: String, symbol: String, quantity: Double?, price: Double?, pricedAt: String, note: String?) {
        self.id = id
        self.bookVersion = bookVersion
        self.kind = kind
        self.symbol = symbol
        self.quantity = quantity
        self.price = price
        self.pricedAt = pricedAt
        self.note = note
    }
}

public struct PilotFollowSnapshotResponse: Codable, Sendable, Equatable {
    /// `yyyy-MM-dd`.
    public let date: String
    public let value: Double
    public let cash: Double

    public init(date: String, value: Double, cash: Double) {
        self.date = date
        self.value = value
        self.cash = cash
    }
}
```

- [ ] **Step 6: Run the tests and confirm they pass.** Run `swift test --filter PilotDTOsTests`. Expected: 2 passed.

- [ ] **Step 7: Check the backend still compiles against the new case.** `WatchlistStatus` is decoded strictly, so look for exhaustive switches.

```bash
cd ../norviq-backend-pilots && STOCKPLAN_SHARED_PATH=../norviq-shared-pilots swift build 2>&1 | grep -E "error|warning: switch" | head
```
Expected: no errors. If a `switch` over `WatchlistStatus` is non-exhaustive, add `case .exited:` with the same handling as `.archived`.

- [ ] **Step 8: Commit** (in `norviq-shared-pilots`).

```bash
git add Sources/StockPlanShared/Pilots/PilotDTOs.swift Sources/StockPlanShared/Stocks/StockDTOs.swift Tests/StockPlanSharedTests/PilotDTOsTests.swift
git commit -m "feat(pilots): add pilot follow DTOs and WatchlistStatus.exited"
```

---

### Task 3: Tables, models and the billing feature

**Files:**
- Create: `Sources/StockPlanBackend/Migrations/CreatePilotTables.swift`
- Create: `Sources/StockPlanBackend/Models/PilotModels.swift`
- Modify: `Sources/StockPlanBackend/ConfigureBootstrap.swift:430` (after `CreateSocialTables()`)
- Modify: `Sources/StockPlanBackend/Billing/EntitlementResolver.swift:103`
- Test: `Tests/StockPlanBackendTests/PilotSchemaTests.swift`

**Interfaces:**
- Produces:
  - Models: `Pilot`, `PilotDisclosureRecord`, `PilotBookVersion`, `PilotFollow`, `PilotFollowEvent`, `PilotFollowSnapshot` (fields below).
  - Enums: `PilotTradeSide` (`buy`, `sell`, `sellFull = "sell_full"`, `hold`) and `PilotInstrumentKind` (`stock`, `call`, `put`).
  - `BillingFeature.pilotFollows`.

- [ ] **Step 1: Write the failing test.**

```swift
import Fluent
import Foundation
import SQLKit
@testable import StockPlanBackend
import Testing
import Vapor

@Suite("Pilot schema", .serialized)
struct PilotSchemaTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    @Test("a disclosure source_key is unique per pilot")
    func disclosureUnique() async throws {
        try await withApp { app in
            let pilot = Pilot(kind: .politician, slug: "test-\(UUID().uuidString.prefix(6))", displayName: "Test", chamber: "house", nameAliases: ["Test Person"])
            try await pilot.create(on: app.db)
            let first = PilotDisclosureRecord(pilotId: try pilot.requireID(), sourceKey: "k1", symbol: "AAPL", side: .buy, instrument: .stock)
            try await first.create(on: app.db)
            let dupe = PilotDisclosureRecord(pilotId: try pilot.requireID(), sourceKey: "k1", symbol: "AAPL", side: .buy, instrument: .stock)
            await #expect(throws: (any Error).self) { try await dupe.create(on: app.db) }
        }
    }

    @Test("book weights round-trip as JSON")
    func bookWeights() async throws {
        try await withApp { app in
            let pilot = Pilot(kind: .fund, slug: "fund-\(UUID().uuidString.prefix(6))", displayName: "Fund", cik: "0000000001")
            try await pilot.create(on: app.db)
            let version = PilotBookVersion(pilotId: try pilot.requireID(), version: 1, computedAt: Date(), weights: ["AAPL": 0.6, "KO": 0.4], skippedPuts: 2)
            try await version.create(on: app.db)
            let loaded = try #require(try await PilotBookVersion.find(version.requireID(), on: app.db))
            #expect(loaded.weights == ["AAPL": 0.6, "KO": 0.4])
            #expect(loaded.skippedPuts == 2)
        }
    }
}
```

- [ ] **Step 2: Run it and confirm it fails.** Run `LOG_LEVEL=warning STOCKPLAN_SHARED_PATH=../norviq-shared-pilots swift test --filter PilotSchemaTests`. Expected: a compile failure, because `Pilot` is undefined.

- [ ] **Step 3: Write the migration.** This follows the raw-SQL style of `Migrations/CreateOnboardingState.swift`.

```swift
import Fluent
import FluentSQL

/// Pilot follows: curated pilots, their disclosures, versioned target weights,
/// user follows, and what each follow did. Spec: docs/superpowers/specs/2026-10-01-pilot-follow-design.md.
struct CreatePilotTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS pilots (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            kind TEXT NOT NULL CHECK (kind IN ('politician', 'fund')),
            slug TEXT NOT NULL UNIQUE,
            display_name TEXT NOT NULL,
            chamber TEXT,
            bioguide_id TEXT,
            cik TEXT,
            name_aliases JSONB NOT NULL DEFAULT '[]',
            active BOOLEAN NOT NULL DEFAULT TRUE,
            last_ingested_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ DEFAULT NOW(),
            updated_at TIMESTAMPTZ
        )
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS pilot_disclosures (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            pilot_id UUID NOT NULL REFERENCES pilots(id) ON DELETE CASCADE,
            source_key TEXT NOT NULL,
            symbol TEXT NOT NULL,
            side TEXT NOT NULL,
            instrument TEXT NOT NULL,
            transaction_date TEXT,
            disclosure_date TEXT,
            amount_min DOUBLE PRECISION,
            amount_max DOUBLE PRECISION,
            shares DOUBLE PRECISION,
            market_value DOUBLE PRECISION,
            period TEXT,
            raw JSONB,
            discovered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (pilot_id, source_key)
        )
        """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS pilot_disclosures_pilot_date ON pilot_disclosures (pilot_id, transaction_date)").run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS pilot_book_versions (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            pilot_id UUID NOT NULL REFERENCES pilots(id) ON DELETE CASCADE,
            version INT NOT NULL,
            computed_at TIMESTAMPTZ NOT NULL,
            weights JSONB NOT NULL,
            skipped_puts INT NOT NULL DEFAULT 0,
            UNIQUE (pilot_id, version)
        )
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS pilot_follows (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            pilot_id UUID NOT NULL REFERENCES pilots(id) ON DELETE CASCADE,
            target_kind TEXT NOT NULL CHECK (target_kind IN ('portfolio', 'watchlist')),
            portfolio_list_id UUID REFERENCES portfolio_lists(id) ON DELETE CASCADE,
            watchlist_list_id UUID REFERENCES watchlist_lists(id) ON DELETE CASCADE,
            starting_capital DOUBLE PRECISION,
            currency TEXT NOT NULL DEFAULT 'USD',
            applied_version INT NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused')),
            created_at TIMESTAMPTZ DEFAULT NOW(),
            updated_at TIMESTAMPTZ,
            CHECK (
                (target_kind = 'portfolio' AND portfolio_list_id IS NOT NULL AND watchlist_list_id IS NULL)
                OR (target_kind = 'watchlist' AND watchlist_list_id IS NOT NULL AND portfolio_list_id IS NULL)
            )
        )
        """).run()
        try await sql.raw("""
        CREATE UNIQUE INDEX IF NOT EXISTS pilot_follows_target_unique
            ON pilot_follows (user_id, pilot_id, COALESCE(portfolio_list_id, watchlist_list_id))
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS pilot_follow_events (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            follow_id UUID NOT NULL REFERENCES pilot_follows(id) ON DELETE CASCADE,
            book_version INT NOT NULL,
            kind TEXT NOT NULL,
            symbol TEXT NOT NULL,
            quantity DOUBLE PRECISION,
            price DOUBLE PRECISION,
            priced_at TIMESTAMPTZ NOT NULL,
            note TEXT,
            created_at TIMESTAMPTZ DEFAULT NOW(),
            UNIQUE (follow_id, book_version, symbol)
        )
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS pilot_follow_snapshots (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            follow_id UUID NOT NULL REFERENCES pilot_follows(id) ON DELETE CASCADE,
            captured_on TIMESTAMPTZ NOT NULL,
            value DOUBLE PRECISION NOT NULL,
            cash DOUBLE PRECISION NOT NULL,
            created_at TIMESTAMPTZ DEFAULT NOW(),
            UNIQUE (follow_id, captured_on)
        )
        """).run()
        // CUSIP → ticker, resolved through OpenFIGI. EDGAR 13F filings carry
        // CUSIPs only. symbol NULL = looked up, no listed ticker; not retried.
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS cusip_symbols (
            cusip TEXT PRIMARY KEY,
            symbol TEXT,
            resolved_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        for table in ["cusip_symbols", "pilot_follow_snapshots", "pilot_follow_events", "pilot_follows", "pilot_book_versions", "pilot_disclosures", "pilots"] {
            try await sql.raw("DROP TABLE IF EXISTS \(unsafeRaw: table)").run()
        }
    }
}
```

- [ ] **Step 4: Write `Models/PilotModels.swift`.**

```swift
import Fluent
import Foundation
import StockPlanShared
import Vapor

enum PilotTradeSide: String, Codable, Sendable {
    case buy
    case sell
    /// "Sale (Full)": the pilot no longer holds the position.
    case sellFull = "sell_full"
    /// A 13F holding row: a position at period end, not a trade.
    case hold
}

enum PilotInstrumentKind: String, Codable, Sendable {
    case stock
    case call
    case put
}

final class Pilot: Model, @unchecked Sendable {
    static let schema = "pilots"

    @ID(key: .id) var id: UUID?
    @Field(key: "kind") var kind: String
    @Field(key: "slug") var slug: String
    @Field(key: "display_name") var displayName: String
    @OptionalField(key: "chamber") var chamber: String?
    @OptionalField(key: "bioguide_id") var bioguideId: String?
    @OptionalField(key: "cik") var cik: String?
    @Field(key: "name_aliases") var nameAliases: [String]
    @Field(key: "active") var active: Bool
    @OptionalField(key: "last_ingested_at") var lastIngestedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, kind: PilotKind, slug: String, displayName: String, chamber: String? = nil, bioguideId: String? = nil, cik: String? = nil, nameAliases: [String] = [], active: Bool = true) {
        self.id = id
        self.kind = kind.rawValue
        self.slug = slug
        self.displayName = displayName
        self.chamber = chamber
        self.bioguideId = bioguideId
        self.cik = cik
        self.nameAliases = nameAliases
        self.active = active
    }

    var pilotKind: PilotKind { PilotKind(rawValue: kind) ?? .politician }
}

final class PilotDisclosureRecord: Model, @unchecked Sendable {
    static let schema = "pilot_disclosures"

    @ID(key: .id) var id: UUID?
    @Field(key: "pilot_id") var pilotId: UUID
    @Field(key: "source_key") var sourceKey: String
    @Field(key: "symbol") var symbol: String
    @Field(key: "side") var side: String
    @Field(key: "instrument") var instrument: String
    @OptionalField(key: "transaction_date") var transactionDate: String?
    @OptionalField(key: "disclosure_date") var disclosureDate: String?
    @OptionalField(key: "amount_min") var amountMin: Double?
    @OptionalField(key: "amount_max") var amountMax: Double?
    @OptionalField(key: "shares") var shares: Double?
    @OptionalField(key: "market_value") var marketValue: Double?
    @OptionalField(key: "period") var period: String?
    @Field(key: "discovered_at") var discoveredAt: Date

    init() {}

    init(id: UUID? = nil, pilotId: UUID, sourceKey: String, symbol: String, side: PilotTradeSide, instrument: PilotInstrumentKind, transactionDate: String? = nil, disclosureDate: String? = nil, amountMin: Double? = nil, amountMax: Double? = nil, shares: Double? = nil, marketValue: Double? = nil, period: String? = nil, discoveredAt: Date = Date()) {
        self.id = id
        self.pilotId = pilotId
        self.sourceKey = sourceKey
        self.symbol = symbol
        self.side = side.rawValue
        self.instrument = instrument.rawValue
        self.transactionDate = transactionDate
        self.disclosureDate = disclosureDate
        self.amountMin = amountMin
        self.amountMax = amountMax
        self.shares = shares
        self.marketValue = marketValue
        self.period = period
        self.discoveredAt = discoveredAt
    }
}

final class PilotBookVersion: Model, @unchecked Sendable {
    static let schema = "pilot_book_versions"

    @ID(key: .id) var id: UUID?
    @Field(key: "pilot_id") var pilotId: UUID
    @Field(key: "version") var version: Int
    @Field(key: "computed_at") var computedAt: Date
    @Field(key: "weights") var weights: [String: Double]
    @Field(key: "skipped_puts") var skippedPuts: Int

    init() {}

    init(id: UUID? = nil, pilotId: UUID, version: Int, computedAt: Date, weights: [String: Double], skippedPuts: Int) {
        self.id = id
        self.pilotId = pilotId
        self.version = version
        self.computedAt = computedAt
        self.weights = weights
        self.skippedPuts = skippedPuts
    }
}

final class PilotFollow: Model, @unchecked Sendable {
    static let schema = "pilot_follows"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "pilot_id") var pilotId: UUID
    @Field(key: "target_kind") var targetKind: String
    @OptionalField(key: "portfolio_list_id") var portfolioListId: UUID?
    @OptionalField(key: "watchlist_list_id") var watchlistListId: UUID?
    @OptionalField(key: "starting_capital") var startingCapital: Double?
    @Field(key: "currency") var currency: String
    @Field(key: "applied_version") var appliedVersion: Int
    @Field(key: "status") var status: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, userId: UUID, pilotId: UUID, targetKind: PilotFollowTargetKind, portfolioListId: UUID? = nil, watchlistListId: UUID? = nil, startingCapital: Double? = nil, currency: String = "USD") {
        self.id = id
        self.userId = userId
        self.pilotId = pilotId
        self.targetKind = targetKind.rawValue
        self.portfolioListId = portfolioListId
        self.watchlistListId = watchlistListId
        self.startingCapital = startingCapital
        self.currency = currency
        self.appliedVersion = 0
        self.status = PilotFollowStatus.active.rawValue
    }

    var target: PilotFollowTargetKind { PilotFollowTargetKind(rawValue: targetKind) ?? .portfolio }
}

final class PilotFollowEvent: Model, @unchecked Sendable {
    static let schema = "pilot_follow_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "follow_id") var followId: UUID
    @Field(key: "book_version") var bookVersion: Int
    @Field(key: "kind") var kind: String
    @Field(key: "symbol") var symbol: String
    @OptionalField(key: "quantity") var quantity: Double?
    @OptionalField(key: "price") var price: Double?
    @Field(key: "priced_at") var pricedAt: Date
    @OptionalField(key: "note") var note: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID? = nil, followId: UUID, bookVersion: Int, kind: String, symbol: String, quantity: Double? = nil, price: Double? = nil, pricedAt: Date, note: String? = nil) {
        self.id = id
        self.followId = followId
        self.bookVersion = bookVersion
        self.kind = kind
        self.symbol = symbol
        self.quantity = quantity
        self.price = price
        self.pricedAt = pricedAt
        self.note = note
    }
}

final class PilotFollowSnapshot: Model, @unchecked Sendable {
    static let schema = "pilot_follow_snapshots"

    @ID(key: .id) var id: UUID?
    @Field(key: "follow_id") var followId: UUID
    @Field(key: "captured_on") var capturedOn: Date
    @Field(key: "value") var value: Double
    @Field(key: "cash") var cash: Double

    init() {}

    init(id: UUID? = nil, followId: UUID, capturedOn: Date, value: Double, cash: Double) {
        self.id = id
        self.followId = followId
        self.capturedOn = capturedOn
        self.value = value
        self.cash = cash
    }
}
```

- [ ] **Step 5: Register the migration.** In `ConfigureBootstrap.swift`, after line 430 `app.migrations.add(CreateSocialTables())`, add:

```swift
    app.migrations.add(CreatePilotTables())
```

- [ ] **Step 6: Add the billing feature.** In `Billing/EntitlementResolver.swift` `enum BillingFeature`, add `case pilotFollows = "pilot_follows"`. Then build:

```bash
STOCKPLAN_SHARED_PATH=../norviq-shared-pilots swift build 2>&1 | grep "error:" | head
```
Every `switch` the compiler reports as non-exhaustive over `BillingFeature` gets `case .pilotFollows:` returning `nil` (no numeric limit; it is enforced in `PilotFollowService`).

- [ ] **Step 7: Run the tests and confirm they pass.** Run `LOG_LEVEL=warning STOCKPLAN_SHARED_PATH=../norviq-shared-pilots swift test --filter PilotSchemaTests`. Expected: 2 passed.

- [ ] **Step 8: Commit**

```bash
git add Sources/StockPlanBackend/Migrations/CreatePilotTables.swift Sources/StockPlanBackend/Models/PilotModels.swift Sources/StockPlanBackend/ConfigureBootstrap.swift Sources/StockPlanBackend/Billing Tests/StockPlanBackendTests/PilotSchemaTests.swift
git commit -m "feat(pilots): tables and models for pilots, disclosures, books and follows"
```

---

### Task 4: `PilotBookBuilder` — weights from disclosures

**Files:**
- Create: `Sources/StockPlanBackend/Pilots/PilotBookBuilder.swift`
- Test: `Tests/StockPlanBackendTests/PilotBookBuilderTests.swift`

**Interfaces:**
- Consumes: `PilotTradeSide`, `PilotInstrumentKind` (Task 3).
- Produces:

```swift
struct PilotBookEntry: Sendable, Equatable {
    let symbol: String; let side: PilotTradeSide; let instrument: PilotInstrumentKind
    let transactionDate: String?; let amountMin: Double?; let amountMax: Double?
    let marketValue: Double?; let period: String?
}
struct PilotBook: Sendable, Equatable { let weights: [String: Double]; let skippedPuts: Int }
enum PilotBookBuilder {
    static func politicianBook(_ entries: [PilotBookEntry], asOf: Date, lookbackMonths: Int = 24) -> PilotBook
    static func fundBook(_ entries: [PilotBookEntry]) -> PilotBook
    static func estimatedValue(min: Double?, max: Double?) -> Double?
}
```

- [ ] **Step 1: Write the failing tests.**

```swift
import Foundation
@testable import StockPlanBackend
import Testing

@Suite("PilotBookBuilder")
struct PilotBookBuilderTests {
    // 2026-10-01T00:00:00Z
    private let asOf = Date(timeIntervalSince1970: 1_790_812_800)

    private func trade(_ symbol: String, _ side: PilotTradeSide, _ min: Double?, _ max: Double?, date: String = "2026-06-01", instrument: PilotInstrumentKind = .stock) -> PilotBookEntry {
        PilotBookEntry(symbol: symbol, side: side, instrument: instrument, transactionDate: date, amountMin: min, amountMax: max, marketValue: nil, period: nil)
    }

    @Test("bracket midpoint; 'Over $X' counts as X")
    func estimatedValue() {
        #expect(PilotBookBuilder.estimatedValue(min: 1_001, max: 15_000) == 8_000.5)
        #expect(PilotBookBuilder.estimatedValue(min: 5_000_000, max: nil) == 5_000_000)
        #expect(PilotBookBuilder.estimatedValue(min: nil, max: 1_000) == 1_000)
        #expect(PilotBookBuilder.estimatedValue(min: nil, max: nil) == nil)
    }

    @Test("buys accumulate into normalized weights")
    func buysAccumulate() {
        let book = PilotBookBuilder.politicianBook([
            trade("AAPL", .buy, 15_000, 15_000),
            trade("MSFT", .buy, 5_000, 5_000),
        ], asOf: asOf)
        #expect(book.weights == ["AAPL": 0.75, "MSFT": 0.25])
    }

    @Test("partial sale subtracts midpoint; full sale zeroes")
    func sales() {
        let book = PilotBookBuilder.politicianBook([
            trade("AAPL", .buy, 20_000, 20_000, date: "2026-01-01"),
            trade("AAPL", .sell, 10_000, 10_000, date: "2026-02-01"),
            trade("MSFT", .buy, 10_000, 10_000, date: "2026-01-01"),
            trade("NVDA", .buy, 10_000, 10_000, date: "2026-01-01"),
            trade("NVDA", .sellFull, 1_001, 15_000, date: "2026-03-01"),
        ], asOf: asOf)
        #expect(book.weights == ["AAPL": 0.5, "MSFT": 0.5])
    }

    @Test("a sale of a position never seen is ignored")
    func sellOfUnseenPositionIgnored() {
        let book = PilotBookBuilder.politicianBook([
            trade("TSLA", .sell, 50_000, 100_000),
            trade("AAPL", .buy, 1_000, 1_000),
        ], asOf: asOf)
        #expect(book.weights == ["AAPL": 1.0])
    }

    @Test("calls map to the underlying; puts are skipped and counted")
    func options() {
        let book = PilotBookBuilder.politicianBook([
            trade("NVDA", .buy, 1_000, 1_000, instrument: .call),
            trade("AAPL", .buy, 1_000, 1_000),
            trade("SPY", .buy, 50_000, 50_000, instrument: .put),
        ], asOf: asOf)
        #expect(book.weights == ["NVDA": 0.5, "AAPL": 0.5])
        #expect(book.skippedPuts == 1)
    }

    @Test("trades older than the lookback are ignored; order is by transaction date")
    func lookback() {
        let book = PilotBookBuilder.politicianBook([
            trade("AAPL", .sellFull, 1, 1, date: "2026-05-01"),
            trade("AAPL", .buy, 10_000, 10_000, date: "2026-04-01"),
            trade("KO", .buy, 10_000, 10_000, date: "2024-01-01"),
            trade("MSFT", .buy, 10_000, 10_000, date: "2026-04-01"),
        ], asOf: asOf)
        #expect(book.weights == ["MSFT": 1.0])
    }

    @Test("fund book uses the latest period's market values")
    func fundBook() {
        func hold(_ s: String, _ v: Double, _ p: String) -> PilotBookEntry {
            PilotBookEntry(symbol: s, side: .hold, instrument: .stock, transactionDate: nil, amountMin: nil, amountMax: nil, marketValue: v, period: p)
        }
        let book = PilotBookBuilder.fundBook([
            hold("AAPL", 300, "2026Q2"), hold("KO", 100, "2026Q2"), hold("OXY", 999, "2026Q1"),
        ])
        #expect(book.weights == ["AAPL": 0.75, "KO": 0.25])
    }

    @Test("empty input gives an empty book")
    func empty() {
        #expect(PilotBookBuilder.politicianBook([], asOf: asOf) == PilotBook(weights: [:], skippedPuts: 0))
        #expect(PilotBookBuilder.fundBook([]) == PilotBook(weights: [:], skippedPuts: 0))
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail.** Run `swift test --filter PilotBookBuilderTests`. Expected: compile failure.

- [ ] **Step 3: Implement.**

```swift
import Foundation

struct PilotBookEntry: Sendable, Equatable {
    let symbol: String
    let side: PilotTradeSide
    let instrument: PilotInstrumentKind
    let transactionDate: String?
    let amountMin: Double?
    let amountMax: Double?
    let marketValue: Double?
    let period: String?
}

struct PilotBook: Sendable, Equatable {
    let weights: [String: Double]
    let skippedPuts: Int
}

/// Turns a pilot's disclosures into target weights. Pure: no I/O, no clock.
///
/// Politicians disclose dollar brackets, not positions, so exposure is an
/// estimate: buys add the bracket midpoint, partial sales subtract it, and a
/// full sale zeroes the position. Calls count as the underlying. Puts are
/// bearish and a mirrored portfolio cannot go short, so they are counted and
/// left out.
enum PilotBookBuilder {
    static func estimatedValue(min: Double?, max: Double?) -> Double? {
        switch (min, max) {
        case let (lo?, hi?): (lo + hi) / 2
        case let (lo?, nil): lo
        case let (nil, hi?): hi
        case (nil, nil): nil
        }
    }

    static func politicianBook(_ entries: [PilotBookEntry], asOf: Date, lookbackMonths: Int = 24) -> PilotBook {
        let cutoff = cutoffDate(asOf: asOf, months: lookbackMonths)
        let ordered = entries
            .filter { ($0.transactionDate ?? "") >= cutoff }
            .sorted { ($0.transactionDate ?? "") < ($1.transactionDate ?? "") }

        var exposure: [String: Double] = [:]
        var skippedPuts = 0
        for entry in ordered {
            if entry.instrument == .put {
                skippedPuts += 1
                continue
            }
            switch entry.side {
            case .buy:
                guard let value = estimatedValue(min: entry.amountMin, max: entry.amountMax) else { continue }
                exposure[entry.symbol, default: 0] += value
            case .sell:
                guard let current = exposure[entry.symbol],
                      let value = estimatedValue(min: entry.amountMin, max: entry.amountMax) else { continue }
                exposure[entry.symbol] = Swift.max(0, current - value)
            case .sellFull:
                exposure[entry.symbol] = nil
            case .hold:
                continue
            }
        }
        return PilotBook(weights: normalize(exposure), skippedPuts: skippedPuts)
    }

    static func fundBook(_ entries: [PilotBookEntry]) -> PilotBook {
        let holds = entries.filter { $0.side == .hold && $0.period != nil }
        guard let latest = holds.compactMap(\.period).max() else {
            return PilotBook(weights: [:], skippedPuts: 0)
        }
        var exposure: [String: Double] = [:]
        for entry in holds where entry.period == latest {
            exposure[entry.symbol, default: 0] += entry.marketValue ?? 0
        }
        return PilotBook(weights: normalize(exposure), skippedPuts: 0)
    }

    private static func normalize(_ exposure: [String: Double]) -> [String: Double] {
        let positive = exposure.filter { $0.value > 0 }
        let total = positive.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return positive.mapValues { $0 / total }
    }

    /// `yyyy-MM-dd`, compared as a string against FMP's dates.
    private static func cutoffDate(asOf: Date, months: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let cutoff = calendar.date(byAdding: .month, value: -months, to: asOf) ?? asOf
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: cutoff)
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass.** Run `swift test --filter PilotBookBuilderTests`. Expected: 7 passed. Weight comparisons above use exact binary fractions (0.75, 0.5, 0.25), so `==` is safe.

- [ ] **Step 5: Commit**

```bash
git add Sources/StockPlanBackend/Pilots/PilotBookBuilder.swift Tests/StockPlanBackendTests/PilotBookBuilderTests.swift
git commit -m "feat(pilots): estimate pilot target weights from disclosures"
```

---

### Task 5: Source protocol + congress source (FMP free "latest" feed)

> Amended 2026-10-01 after Task 1. Norviq's FMP plan is the free tier. The by-name and by-symbol congress endpoints are restricted. Only `/stable/senate-latest` and `/stable/house-latest` work, with `page=0` and `limit` ≤ 25. Rows carry `senateID`, a bioguide ID (e.g. `H001082`). Politician books are therefore built only from trades Norviq has seen since launch.

**Files:**
- Create: `Sources/StockPlanBackend/Pilots/PilotDisclosureSource.swift`
- Create: `Sources/StockPlanBackend/Pilots/FMPCongressPilotSource.swift`
- Modify: `Sources/StockPlanBackend/Market/CongressTrades.swift`: add `var senateID: String? = nil` as the **last** property of `FMPCongressTrade`. Being last with a default keeps every existing memberwise call compiling.
- Commit: `Tests/StockPlanBackendTests/Fixtures/pilots/{house,senate}-latest.json`. These were recorded in Task 1 and already exist, uncommitted, in the worktree.
- Test: `Tests/StockPlanBackendTests/FMPCongressPilotSourceTests.swift`

**Interfaces:**
- Consumes:
  - `FMPCongressTrade` and `CongressTrades.amountBounds(from:)` (`Market/CongressTrades.swift:108`)
  - The existing `FMPMarketDataProvider.latestSenateTrades(limit:on:)` and `latestHouseTrades(limit:on:)`, wired in Task 11.
  - The enums from Task 3.
- Produces:

```swift
struct PilotSourceIdentity: Sendable { let kind: PilotKind; let chamber: String?; let bioguideId: String?; let aliases: [String]; let cik: String?; init(_ pilot: Pilot) }
struct PilotDisclosureInput: Sendable, Equatable { sourceKey, symbol, side, instrument, transactionDate, disclosureDate, amountMin, amountMax, shares, marketValue, period }
protocol PilotDisclosureSource: Sendable { func disclosures(for pilot: PilotSourceIdentity) async throws -> [PilotDisclosureInput] }
struct FMPCongressPilotSource: PilotDisclosureSource {
    static let feedLimit = 25
    init(ttl: TimeInterval = 600, now: @escaping @Sendable () -> Date = Date.init, fetch: @escaping @Sendable (_ chamber: String) async throws -> [FMPCongressTrade])
}
```

- [ ] **Step 1: Write the failing tests.**

```swift
import Foundation
@testable import StockPlanBackend
import Testing

@Suite("FMPCongressPilotSource")
struct FMPCongressPilotSourceTests {
    private func row(first: String = "Nancy", last: String = "Pelosi", id: String? = "P000197", symbol: String? = "NVDA", type: String = "Purchase", amount: String = "$1,000,001 - $5,000,000", assetType: String? = "Stock", description: String? = nil) -> FMPCongressTrade {
        FMPCongressTrade(symbol: symbol, disclosureDate: "2026-07-01", transactionDate: "2026-06-20", firstName: first, lastName: last, office: nil, district: "CA11", state: "CA", party: "Democrat", owner: "Spouse", assetDescription: description, assetType: assetType, type: type, amount: amount, link: "https://example.test/\(symbol ?? "x")", senateID: id)
    }

    private let pelosi = PilotSourceIdentity(kind: .politician, chamber: "house", bioguideId: "P000197", aliases: ["Nancy Pelosi"], cik: nil)

    private func source(_ rows: [FMPCongressTrade]) -> FMPCongressPilotSource {
        FMPCongressPilotSource { _ in rows }
    }

    @Test("maps purchase, partial sale and full sale; drops exchanges")
    func sides() async throws {
        let out = try await source([
            row(type: "Purchase"),
            row(symbol: "AAPL", type: "Sale (Partial)"),
            row(symbol: "MSFT", type: "Sale (Full)"),
            row(symbol: "KO", type: "Exchange"),
        ]).disclosures(for: pelosi)
        #expect(out.map(\.symbol) == ["NVDA", "AAPL", "MSFT"])
        #expect(out.map(\.side) == [.buy, .sell, .sellFull])
        #expect(out[0].amountMin == 1_000_001)
        #expect(out[0].amountMax == 5_000_000)
    }

    @Test("options: calls and puts detected; bonds and funds dropped")
    func instruments() async throws {
        let out = try await source([
            row(assetType: "Stock Option", description: "NVIDIA Corp - Call options; strike $120"),
            row(symbol: "SPY", assetType: "Stock Option", description: "SPDR S&P 500 Put"),
            row(symbol: "T 4 1/2", assetType: "Corporate Bond"),
            row(symbol: "VFIAX", assetType: "Mutual Fund"),
            row(symbol: "QQQ", assetType: "ETF"),
        ]).disclosures(for: pelosi)
        #expect(out.map(\.symbol) == ["NVDA", "SPY", "QQQ"])
        #expect(out.map(\.instrument) == [.call, .put, .stock])
    }

    @Test("matches by bioguide id; falls back to exact alias when the id is missing")
    func matching() async throws {
        let out = try await source([
            row(first: "Paul", last: "Pelosi", id: "X000001", symbol: "AAA"),
            row(first: "Nancy", last: "Pelosi", id: nil, symbol: "BBB"),
            row(first: "N.", last: "Pelosi", id: "P000197", symbol: "CCC"),
            row(symbol: nil),
        ]).disclosures(for: pelosi)
        #expect(out.map(\.symbol) == ["BBB", "CCC"])
    }

    @Test("the feed is fetched once per chamber within the TTL, across pilots")
    func memoized() async throws {
        let calls = Counter()
        let src = FMPCongressPilotSource { chamber in
            await calls.increment(chamber)
            return []
        }
        let other = PilotSourceIdentity(kind: .politician, chamber: "house", bioguideId: "H001082", aliases: ["Kevin Hern"], cik: nil)
        _ = try await src.disclosures(for: pelosi)
        _ = try await src.disclosures(for: other)
        #expect(await calls.counts == ["house": 1])
    }

    @Test("source key is stable across calls and distinct per row")
    func sourceKey() async throws {
        let src = source([row(), row(symbol: "AAPL")])
        let a = try await src.disclosures(for: pelosi)
        let b = try await src.disclosures(for: pelosi)
        #expect(a.map(\.sourceKey) == b.map(\.sourceKey))
        #expect(Set(a.map(\.sourceKey)).count == 2)
    }

    @Test("decodes the recorded FMP fixtures, senateID included")
    func fixtures() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pilots")
        for name in ["house-latest.json", "senate-latest.json"] {
            let rows = try JSONDecoder().decode([FMPCongressTrade].self, from: Data(contentsOf: dir.appendingPathComponent(name)))
            #expect(rows.count == 25)
            #expect(rows.allSatisfy { $0.senateID?.isEmpty == false })
        }
    }
}

private actor Counter {
    var counts: [String: Int] = [:]
    func increment(_ key: String) { counts[key, default: 0] += 1 }
}
```

- [ ] **Step 2: Run the tests and confirm they fail.** Run `$TEST_ENV swift test --filter FMPCongressPilotSourceTests`. Expected: compile failure.

- [ ] **Step 3: Add the bioguide ID to the wire model.** In `Market/CongressTrades.swift`, append the following to `FMPCongressTrade` after `let link: String?`:

```swift
    /// Bioguide ID of the member (e.g. `P000197`). FMP names it `senateID` on
    /// both chambers' feeds. The only stable identity the feed carries.
    var senateID: String? = nil
```

- [ ] **Step 4: Write `PilotDisclosureSource.swift`.**

```swift
import Foundation
import StockPlanShared

/// Who a source should fetch for. Built from a `Pilot` row.
struct PilotSourceIdentity: Sendable {
    let kind: PilotKind
    /// `senate` or `house`; nil for funds.
    let chamber: String?
    /// Bioguide ID, e.g. `P000197`. The primary match for congress rows.
    let bioguideId: String?
    /// Exact "First Last" spellings, used only when a row has no bioguide ID.
    let aliases: [String]
    let cik: String?

    init(kind: PilotKind, chamber: String?, bioguideId: String?, aliases: [String], cik: String?) {
        self.kind = kind
        self.chamber = chamber
        self.bioguideId = bioguideId
        self.aliases = aliases
        self.cik = cik
    }

    init(_ pilot: Pilot) {
        self.init(kind: pilot.pilotKind, chamber: pilot.chamber, bioguideId: pilot.bioguideId, aliases: pilot.nameAliases, cik: pilot.cik)
    }
}

/// One disclosed trade or 13F holding, normalized. `sourceKey` is unique per
/// pilot and stable across fetches: it is what makes ingestion idempotent.
struct PilotDisclosureInput: Sendable, Equatable {
    let sourceKey: String
    let symbol: String
    let side: PilotTradeSide
    let instrument: PilotInstrumentKind
    let transactionDate: String?
    let disclosureDate: String?
    let amountMin: Double?
    let amountMax: Double?
    let shares: Double?
    let marketValue: Double?
    let period: String?
}

/// Supplies a pilot's disclosures. Named for what it provides, not for a
/// vendor, so switching data provider is a new conformer, not a rename.
protocol PilotDisclosureSource: Sendable {
    func disclosures(for pilot: PilotSourceIdentity) async throws -> [PilotDisclosureInput]
}
```

- [ ] **Step 5: Write `FMPCongressPilotSource.swift`.**

```swift
import Crypto
import Foundation

/// Congressional disclosures from FMP's free "latest" feeds.
///
/// The free plan returns only the newest 25 rows per chamber (page 0), so
/// there is no history to search. Each ingestion run reads the feed once per
/// chamber and hands each pilot its own rows. The memo keeps 15 pilots from
/// costing 15 requests against a 250-request daily budget.
struct FMPCongressPilotSource: PilotDisclosureSource {
    typealias Fetch = @Sendable (_ chamber: String) async throws -> [FMPCongressTrade]

    static let feedLimit = 25

    private let fetch: Fetch
    private let memo: FeedMemo

    init(ttl: TimeInterval = 600, now: @escaping @Sendable () -> Date = Date.init, fetch: @escaping Fetch) {
        self.fetch = fetch
        self.memo = FeedMemo(ttl: ttl, now: now)
    }

    func disclosures(for pilot: PilotSourceIdentity) async throws -> [PilotDisclosureInput] {
        guard let chamber = pilot.chamber else { return [] }
        let rows = try await memo.rows(chamber: chamber, fetch: fetch)
        let aliases = Set(pilot.aliases.map(Self.normalizedName))
        var seen = Set<String>()
        var out: [PilotDisclosureInput] = []
        for wire in rows where Self.matches(wire, bioguideId: pilot.bioguideId, aliases: aliases) {
            guard let input = Self.input(from: wire, chamber: chamber), seen.insert(input.sourceKey).inserted else { continue }
            out.append(input)
        }
        return out
    }

    /// Bioguide ID when the row has one; otherwise an exact "First Last" alias.
    static func matches(_ wire: FMPCongressTrade, bioguideId: String?, aliases: Set<String>) -> Bool {
        if let id = wire.senateID?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
            return id.caseInsensitiveCompare(bioguideId ?? "") == .orderedSame
        }
        return aliases.contains(normalizedName("\(wire.firstName ?? "") \(wire.lastName ?? "")"))
    }

    static func input(from wire: FMPCongressTrade, chamber: String) -> PilotDisclosureInput? {
        guard let symbol = wire.symbol?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !symbol.isEmpty,
              let side = side(from: wire.type),
              let instrument = instrument(assetType: wire.assetType, description: wire.assetDescription)
        else { return nil }
        let bounds = CongressTrades.amountBounds(from: wire.amount)
        let keyMaterial = [chamber, wire.senateID ?? "", wire.firstName ?? "", wire.lastName ?? "", wire.owner ?? "", symbol,
                           wire.transactionDate ?? "", wire.type ?? "", wire.amount ?? "", wire.link ?? ""]
            .joined(separator: "|")
        let key = SHA256.hash(data: Data(keyMaterial.utf8)).map { String(format: "%02x", $0) }.joined()
        return PilotDisclosureInput(
            sourceKey: key,
            symbol: symbol,
            side: side,
            instrument: instrument,
            transactionDate: wire.transactionDate,
            disclosureDate: wire.disclosureDate,
            amountMin: bounds.min,
            amountMax: bounds.max,
            shares: nil,
            marketValue: nil,
            period: nil
        )
    }

    /// Purchase → buy; "Sale (Full)" → sellFull; any other sale → sell.
    /// Exchanges and unknown types carry no direction and are dropped.
    static func side(from raw: String?) -> PilotTradeSide? {
        guard let lowered = raw?.lowercased() else { return nil }
        if lowered.contains("purchase") { return .buy }
        if lowered.contains("sale") { return lowered.contains("full") ? .sellFull : .sell }
        return nil
    }

    /// Stocks and ETFs pass through; options become call or put. Bonds,
    /// mutual funds and anything else are dropped. A missing asset type is
    /// treated as stock, because the feed omits it for plain equity rows.
    static func instrument(assetType: String?, description: String?) -> PilotInstrumentKind? {
        let type = assetType?.lowercased() ?? ""
        if type.contains("option") {
            return (description?.lowercased().contains("put") ?? false) ? .put : .call
        }
        if type.isEmpty || type == "stock" || type.contains("etf") || type.contains("equity") || type.contains("common") {
            return .stock
        }
        return nil
    }

    static func normalizedName(_ raw: String) -> String {
        raw.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Per-chamber cache of the feed for one ingestion run.
private actor FeedMemo {
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [String: (at: Date, rows: [FMPCongressTrade])] = [:]

    init(ttl: TimeInterval, now: @escaping @Sendable () -> Date) {
        self.ttl = ttl
        self.now = now
    }

    func rows(chamber: String, fetch: FMPCongressPilotSource.Fetch) async throws -> [FMPCongressTrade] {
        if let hit = cache[chamber], now().timeIntervalSince(hit.at) < ttl {
            return hit.rows
        }
        let rows = try await fetch(chamber)
        cache[chamber] = (now(), rows)
        return rows
    }
}
```

- [ ] **Step 6: Run the tests and confirm they pass.** Run `$TEST_ENV swift test --filter FMPCongressPilotSourceTests` and `$TEST_ENV swift test --filter Congress`. The second covers the existing congress tests, which must still compile and pass with the new property. Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/StockPlanBackend/Pilots/PilotDisclosureSource.swift Sources/StockPlanBackend/Pilots/FMPCongressPilotSource.swift Sources/StockPlanBackend/Market/CongressTrades.swift Tests/StockPlanBackendTests/FMPCongressPilotSourceTests.swift Tests/StockPlanBackendTests/Fixtures/pilots/house-latest.json Tests/StockPlanBackendTests/Fixtures/pilots/senate-latest.json
git commit -m "feat(pilots): congressional disclosure source over FMP latest feeds"
```

---

### Task 6: 13F source over SEC EDGAR + OpenFIGI

> Amended 2026-10-01 after Task 1. FMP's 13F endpoint is restricted on the free plan. EDGAR is free, needs no key and requires a `User-Agent`. EDGAR reports CUSIPs, not tickers, so tickers are resolved through OpenFIGI's free mapping API and cached in `cusip_symbols` (created in Task 3).

**Files:**
- Create: `Sources/StockPlanBackend/Pilots/EDGAR13FParser.swift`: pure parsing of submissions JSON, the filing index and the info-table XML.
- Create: `Sources/StockPlanBackend/Pilots/CusipSymbolResolver.swift`: OpenFIGI calls and the `cusip_symbols` cache.
- Create: `Sources/StockPlanBackend/Pilots/SECEdgar13FPilotSource.swift`
- Create fixtures: `Tests/StockPlanBackendTests/Fixtures/pilots/edgar/{submissions.json,index.json,infotable.xml,openfigi.json}`
- Test: `Tests/StockPlanBackendTests/SECEdgar13FPilotSourceTests.swift`

**Interfaces:**
- Consumes: `PilotDisclosureSource`, `PilotSourceIdentity` and `PilotDisclosureInput` (Task 5), plus the `cusip_symbols` table (Task 3).
- Produces:

```swift
struct EDGARFilingRef: Sendable, Equatable { let accession: String; let reportDate: String; var period: String { get } }  // "2026-06-30" → "2026Q2"
struct EDGAR13FHolding: Sendable, Equatable { let cusip: String; let value: Double; let shares: Double }
enum EDGAR13FParser {
    static func latest13F(submissions: Data) throws -> EDGARFilingRef?
    static func infoTableName(index: Data) throws -> String?
    static func holdings(infoTable: Data) throws -> [EDGAR13FHolding]   // SH only, no puts/calls, summed per CUSIP
}
typealias CusipResolve = @Sendable (_ cusips: [String]) async throws -> [String: String]
struct CusipSymbolResolver: Sendable {
    static let batchSize = 10
    init(post: @escaping @Sendable (_ body: Data) async throws -> Data, pause: @escaping @Sendable () async -> Void)
    func resolve(_ cusips: [String], on db: any Database) async throws -> [String: String]
}
struct SECEdgar13FPilotSource: PilotDisclosureSource {
    init(get: @escaping @Sendable (_ url: String) async throws -> Data, resolve: @escaping CusipResolve)
}
```

- [ ] **Step 1: Record the fixtures from EDGAR (Berkshire, CIK 0001067983) and OpenFIGI.** The project's context-mode hook blocks curl output to stdout, so always write with `-o`.

```bash
D=Tests/StockPlanBackendTests/Fixtures/pilots/edgar; mkdir -p $D
UA="Norviq ops@norviq.org"
curl -s -A "$UA" -o /tmp/sub.json https://data.sec.gov/submissions/CIK0001067983.json
# Trim to the shape the parser reads: the first 40 recent filings.
jq '{cik, name, filings: {recent: (.filings.recent | {form: .form[0:40], accessionNumber: .accessionNumber[0:40], reportDate: .reportDate[0:40], filingDate: .filingDate[0:40]})}}' /tmp/sub.json > $D/submissions.json
ACC=$(jq -r '.filings.recent as $r | [range(0; $r.form|length)] | map(select($r.form[.]=="13F-HR")) | .[0] | $r.accessionNumber[.]' $D/submissions.json)
ACCN=${ACC//-/}
curl -s -A "$UA" -o $D/index.json "https://www.sec.gov/Archives/edgar/data/1067983/$ACCN/index.json"
INFO=$(jq -r '.directory.item[].name | select(endswith(".xml") and . != "primary_doc.xml")' $D/index.json | head -1)
curl -s -A "$UA" -o $D/infotable.xml "https://www.sec.gov/Archives/edgar/data/1067983/$ACCN/$INFO"
curl -s -o $D/openfigi.json -H 'Content-Type: application/json' -X POST https://api.openfigi.com/v3/mapping \
  -d '[{"idType":"ID_CUSIP","idValue":"037833100","exchCode":"US"},{"idType":"ID_CUSIP","idValue":"191216100","exchCode":"US"},{"idType":"ID_CUSIP","idValue":"000000000","exchCode":"US"}]'
echo "$ACC $INFO"; grep -c "<.*infoTable>" $D/infotable.xml; head -c 300 $D/openfigi.json
```
Expected:
- An accession and an `.xml` name are printed.
- The info table has at least 20 entries.
- `openfigi.json` is a 3-element array: tickers `AAPL` and `KO`, then an element with `"warning"` (or `"error"`).
- If the XML uses a namespace prefix (`<ns1:infoTable>`), the parser handles that (see Step 3).

- [ ] **Step 2: Write the failing tests.**

```swift
import Fluent
import Foundation
@testable import StockPlanBackend
import Testing
import Vapor

@Suite("SECEdgar13FPilotSource", .serialized)
struct SECEdgar13FPilotSourceTests {
    private let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pilots/edgar")
    private func fixture(_ name: String) throws -> Data { try Data(contentsOf: dir.appendingPathComponent(name)) }

    // withApp: copy verbatim from PilotSchemaTests (Task 3).

    @Test("finds the latest 13F-HR and its period")
    func latestFiling() throws {
        let ref = try #require(try EDGAR13FParser.latest13F(submissions: fixture("submissions.json")))
        #expect(ref.accession.count == 20)
        #expect(ref.period.range(of: #"^\d{4}Q[1-4]$"#, options: .regularExpression) != nil)
    }

    @Test("period from report date")
    func period() {
        #expect(EDGARFilingRef(accession: "x", reportDate: "2026-06-30").period == "2026Q2")
        #expect(EDGARFilingRef(accession: "x", reportDate: "2025-12-31").period == "2025Q4")
    }

    @Test("picks the information table, not primary_doc.xml")
    func infoTable() throws {
        let name = try #require(try EDGAR13FParser.infoTableName(index: fixture("index.json")))
        #expect(name.hasSuffix(".xml"))
        #expect(name != "primary_doc.xml")
    }

    @Test("parses the real info table: positive values, unique CUSIPs")
    func realHoldings() throws {
        let rows = try EDGAR13FParser.holdings(infoTable: fixture("infotable.xml"))
        #expect(rows.count >= 20)
        #expect(Set(rows.map(\.cusip)).count == rows.count)
        #expect(rows.allSatisfy { $0.value > 0 && $0.shares > 0 && $0.cusip.count == 9 })
    }

    @Test("skips options and principal-amount rows; sums split rows; strips namespace prefixes")
    func filtering() throws {
        let xml = """
        <?xml version="1.0"?>
        <ns1:informationTable xmlns:ns1="http://www.sec.gov/edgar/document/thirteenf/informationtable">
          <ns1:infoTable><ns1:cusip>037833100</ns1:cusip><ns1:value>600</ns1:value><ns1:shrsOrPrnAmt><ns1:sshPrnamt>3</ns1:sshPrnamt><ns1:sshPrnamtType>SH</ns1:sshPrnamtType></ns1:shrsOrPrnAmt></ns1:infoTable>
          <ns1:infoTable><ns1:cusip>037833100</ns1:cusip><ns1:value>400</ns1:value><ns1:shrsOrPrnAmt><ns1:sshPrnamt>2</ns1:sshPrnamt><ns1:sshPrnamtType>SH</ns1:sshPrnamtType></ns1:shrsOrPrnAmt></ns1:infoTable>
          <ns1:infoTable><ns1:cusip>78462F103</ns1:cusip><ns1:value>50</ns1:value><ns1:shrsOrPrnAmt><ns1:sshPrnamt>1</ns1:sshPrnamt><ns1:sshPrnamtType>SH</ns1:sshPrnamtType></ns1:shrsOrPrnAmt><ns1:putCall>Put</ns1:putCall></ns1:infoTable>
          <ns1:infoTable><ns1:cusip>912828ZZ1</ns1:cusip><ns1:value>70</ns1:value><ns1:shrsOrPrnAmt><ns1:sshPrnamt>70</ns1:sshPrnamt><ns1:sshPrnamtType>PRN</ns1:sshPrnamtType></ns1:shrsOrPrnAmt></ns1:infoTable>
        </ns1:informationTable>
        """
        let rows = try EDGAR13FParser.holdings(infoTable: Data(xml.utf8))
        #expect(rows == [EDGAR13FHolding(cusip: "037833100", value: 1_000, shares: 5)])
    }

    @Test("source: maps holdings through the resolver; unresolved CUSIPs dropped")
    func source() async throws {
        let src = SECEdgar13FPilotSource(
            get: { url in
                if url.contains("submissions") { return try fixture("submissions.json") }
                if url.hasSuffix("index.json") { return try fixture("index.json") }
                return try fixture("infotable.xml")
            },
            resolve: { cusips in Dictionary(uniqueKeysWithValues: cusips.prefix(3).map { ($0, "T\($0.prefix(3))") }) }
        )
        let out = try await src.disclosures(for: PilotSourceIdentity(kind: .fund, chamber: nil, bioguideId: nil, aliases: [], cik: "0001067983"))
        #expect(out.count == 3)
        #expect(out.allSatisfy { $0.side == .hold && $0.instrument == .stock && $0.marketValue ?? 0 > 0 })
        #expect(out.allSatisfy { $0.sourceKey.hasPrefix(out[0].period! + "|") })
    }

    @Test("resolver: batches of 10, caches hits and misses, never asks twice")
    func resolver() async throws {
        try await withApp { app in
            let posts = PostLog()
            let figi = try fixture("openfigi.json")
            let resolver = CusipSymbolResolver(
                post: { body in
                    await posts.record(body)
                    return figi
                },
                pause: {}
            )
            let cusips = ["037833100", "191216100", "000000000"]
            let first = try await resolver.resolve(cusips, on: app.db)
            #expect(first == ["037833100": "AAPL", "191216100": "KO"])
            let second = try await resolver.resolve(cusips, on: app.db)
            #expect(second == first)
            #expect(await posts.count == 1)
        }
    }
}

private actor PostLog {
    var count = 0
    func record(_: Data) { count += 1 }
}
```

- [ ] **Step 3: Run the tests and confirm they fail.** Run `$TEST_ENV swift test --filter SECEdgar13FPilotSourceTests`. Expected: compile failure.

- [ ] **Step 4: Write `EDGAR13FParser.swift`.**

```swift
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct EDGARFilingRef: Sendable, Equatable {
    let accession: String
    /// `yyyy-MM-dd`, the quarter end the filing reports.
    let reportDate: String

    /// `2026-06-30` → `2026Q2`.
    var period: String {
        let parts = reportDate.split(separator: "-")
        guard parts.count >= 2, let month = Int(parts[1]) else { return reportDate }
        return "\(parts[0])Q\((month - 1) / 3 + 1)"
    }
}

struct EDGAR13FHolding: Sendable, Equatable {
    let cusip: String
    /// US dollars (EDGAR reports whole dollars since 2023-01-03).
    let value: Double
    let shares: Double
}

/// Pure parsing of the three EDGAR documents a 13F lookup needs.
enum EDGAR13FParser {
    private struct Submissions: Decodable {
        struct Filings: Decodable { let recent: Recent }
        struct Recent: Decodable {
            let form: [String]
            let accessionNumber: [String]
            let reportDate: [String]
        }
        let filings: Filings
    }

    private struct Index: Decodable {
        struct Directory: Decodable { let item: [Item] }
        struct Item: Decodable { let name: String }
        let directory: Directory
    }

    /// The newest original 13F-HR. Amendments (13F-HR/A) are ignored in v1:
    /// many restate only part of a filing, and reading one as the whole book
    /// would empty positions the fund still holds.
    static func latest13F(submissions: Data) throws -> EDGARFilingRef? {
        let recent = try JSONDecoder().decode(Submissions.self, from: submissions).filings.recent
        for i in recent.form.indices where recent.form[i] == "13F-HR" {
            guard i < recent.accessionNumber.count, i < recent.reportDate.count else { continue }
            return EDGARFilingRef(accession: recent.accessionNumber[i], reportDate: recent.reportDate[i])
        }
        return nil
    }

    static func infoTableName(index: Data) throws -> String? {
        try JSONDecoder().decode(Index.self, from: index).directory.item
            .map(\.name)
            .first { $0.lowercased().hasSuffix(".xml") && $0.lowercased() != "primary_doc.xml" }
    }

    /// Share positions only: rows with `putCall` (options) or a `PRN`
    /// (principal amount, i.e. debt) type are skipped. Funds often split one
    /// security across several rows by manager; those are summed per CUSIP.
    static func holdings(infoTable: Data) throws -> [EDGAR13FHolding] {
        let delegate = InfoTableDelegate()
        let parser = XMLParser(data: infoTable)
        parser.delegate = delegate
        guard parser.parse() else {
            throw Abort(.badGateway, reason: "EDGAR information table did not parse: \(parser.parserError.map(String.init(describing:)) ?? "unknown")")
        }
        var totals: [String: (value: Double, shares: Double)] = [:]
        var order: [String] = []
        for row in delegate.rows where row.putCall == nil && row.type == "SH" {
            guard let value = Double(row.value), let shares = Double(row.shares), value > 0, shares > 0 else { continue }
            if totals[row.cusip] == nil { order.append(row.cusip) }
            totals[row.cusip, default: (0, 0)].value += value
            totals[row.cusip, default: (0, 0)].shares += shares
        }
        return order.map { EDGAR13FHolding(cusip: $0, value: totals[$0]!.value, shares: totals[$0]!.shares) }
    }
}

private final class InfoTableDelegate: NSObject, XMLParserDelegate {
    struct Row {
        var cusip = ""
        var value = ""
        var shares = ""
        var type = ""
        var putCall: String?
    }

    private(set) var rows: [Row] = []
    private var current: Row?
    private var text = ""

    /// `ns1:infoTable` → `infoTable`. EDGAR files use both prefixed and bare names.
    private func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes _: [String: String] = [:]) {
        if local(elementName) == "infoTable" { current = Row() }
        text = ""
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local(elementName) {
        case "cusip": current?.cusip = value.uppercased()
        case "value": current?.value = value
        case "sshPrnamt": current?.shares = value
        case "sshPrnamtType": current?.type = value.uppercased()
        case "putCall": current?.putCall = value.isEmpty ? nil : value
        case "infoTable":
            if let row = current { rows.append(row) }
            current = nil
        default: break
        }
        text = ""
    }
}
```
(`Abort` needs `import Vapor` at the top of the file. Add it.)

- [ ] **Step 5: Write `CusipSymbolResolver.swift`.**

```swift
import Fluent
import Foundation
import SQLKit

/// CUSIP → US ticker through OpenFIGI's free mapping API, cached forever in
/// `cusip_symbols`. A CUSIP OpenFIGI cannot map is cached as NULL, so it is
/// not asked again. Unauthenticated OpenFIGI allows 10 jobs per request and
/// 25 requests a minute, so `pause` runs between batches (2.5 s in production).
struct CusipSymbolResolver: Sendable {
    static let batchSize = 10

    private let post: @Sendable (_ body: Data) async throws -> Data
    private let pause: @Sendable () async -> Void

    init(post: @escaping @Sendable (_ body: Data) async throws -> Data, pause: @escaping @Sendable () async -> Void) {
        self.post = post
        self.pause = pause
    }

    private struct Job: Encodable {
        let idType = "ID_CUSIP"
        let idValue: String
        let exchCode = "US"
    }

    private struct Result: Decodable {
        struct Match: Decodable { let ticker: String? }
        let data: [Match]?
    }

    func resolve(_ cusips: [String], on db: any Database) async throws -> [String: String] {
        guard let sql = db as? any SQLDatabase else { return [:] }
        let wanted = Array(Set(cusips)).sorted()
        guard !wanted.isEmpty else { return [:] }

        struct Cached: Decodable { let cusip: String; let symbol: String? }
        let cached = try await sql.raw("SELECT cusip, symbol FROM cusip_symbols WHERE cusip = ANY(\(bind: wanted))").all(decoding: Cached.self)
        var out: [String: String] = [:]
        var known = Set<String>()
        for row in cached {
            known.insert(row.cusip)
            if let symbol = row.symbol { out[row.cusip] = symbol }
        }

        let missing = wanted.filter { !known.contains($0) }
        for (index, start) in stride(from: 0, to: missing.count, by: Self.batchSize).enumerated() {
            if index > 0 { await pause() }
            let batch = Array(missing[start ..< min(start + Self.batchSize, missing.count)])
            let response = try await post(try JSONEncoder().encode(batch.map { Job(idValue: $0) }))
            let results = try JSONDecoder().decode([Result].self, from: response)
            for (cusip, result) in zip(batch, results) {
                let ticker = result.data?.compactMap(\.ticker).first?.uppercased()
                if let ticker { out[cusip] = ticker }
                try await sql.raw("""
                INSERT INTO cusip_symbols (cusip, symbol) VALUES (\(bind: cusip), \(bind: ticker))
                ON CONFLICT (cusip) DO NOTHING
                """).run()
            }
        }
        return out
    }
}
```

- [ ] **Step 6: Write `SECEdgar13FPilotSource.swift`.**

```swift
import Foundation

/// A fund's latest 13F holdings from SEC EDGAR. Free, no key. EDGAR requires a
/// descriptive User-Agent and at most 10 requests a second; the caller's `get`
/// sets the header. One lookup is three requests.
struct SECEdgar13FPilotSource: PilotDisclosureSource {
    typealias Get = @Sendable (_ url: String) async throws -> Data

    private let get: Get
    private let resolve: CusipResolve

    init(get: @escaping Get, resolve: @escaping CusipResolve) {
        self.get = get
        self.resolve = resolve
    }

    func disclosures(for pilot: PilotSourceIdentity) async throws -> [PilotDisclosureInput] {
        guard let rawCik = pilot.cik, let cikNumber = Int(rawCik) else { return [] }
        let padded = String(format: "%010d", cikNumber)
        guard let filing = try EDGAR13FParser.latest13F(submissions: try await get("https://data.sec.gov/submissions/CIK\(padded).json")) else {
            return []
        }
        let folder = "https://www.sec.gov/Archives/edgar/data/\(cikNumber)/\(filing.accession.replacingOccurrences(of: "-", with: ""))"
        guard let table = try EDGAR13FParser.infoTableName(index: try await get("\(folder)/index.json")) else { return [] }
        let holdings = try EDGAR13FParser.holdings(infoTable: try await get("\(folder)/\(table)"))
        let symbols = try await resolve(holdings.map(\.cusip))
        let period = filing.period
        return holdings.compactMap { holding in
            guard let symbol = symbols[holding.cusip] else { return nil }
            return PilotDisclosureInput(
                sourceKey: "\(period)|\(holding.cusip)",
                symbol: symbol,
                side: .hold,
                instrument: .stock,
                transactionDate: nil,
                disclosureDate: nil,
                amountMin: nil,
                amountMax: nil,
                shares: holding.shares,
                marketValue: holding.value,
                period: period
            )
        }
    }
}
```
`CusipResolve` is declared in `CusipSymbolResolver.swift`:

```swift
typealias CusipResolve = @Sendable (_ cusips: [String]) async throws -> [String: String]
```

- [ ] **Step 7: Run the tests and confirm they pass.** Run `$TEST_ENV swift test --filter SECEdgar13FPilotSourceTests`. Expected: 7 passed. If `realHoldings` fails because the fixture uses a different element casing, fix the parser's `local(_:)` matching, not the test.

- [ ] **Step 8: Commit**

```bash
git add Sources/StockPlanBackend/Pilots/EDGAR13FParser.swift Sources/StockPlanBackend/Pilots/CusipSymbolResolver.swift Sources/StockPlanBackend/Pilots/SECEdgar13FPilotSource.swift Tests/StockPlanBackendTests/SECEdgar13FPilotSourceTests.swift Tests/StockPlanBackendTests/Fixtures/pilots/edgar
git commit -m "feat(pilots): 13F holdings from SEC EDGAR with OpenFIGI ticker mapping"
```

---

### Task 7: `LedgerTradeRecorder` — one write path; `StockService.sell` moves onto it

**Files:**
- Create: `Sources/StockPlanBackend/Portfolio/LedgerTradeRecorder.swift`
- Modify: `Sources/StockPlanBackend/Stocks/StockService.swift:420-478` (the body of `db.transaction` in `sell`)
- Test: `Tests/StockPlanBackendTests/LedgerTradeRecorderTests.swift`

**Interfaces:**
- Consumes:
  - `ManualAccountResolver.findOrCreate(userId:portfolioId:on:)` (`Portfolio/ManualAccountResolver.swift:14`)
  - `CashBalance(accountId:currency:balance:asOf:)`
  - `Transaction(accountId:instrumentId:externalId:type:quantity:price:currency:tradeDate:)`
  - `Stock`
- Produces:

```swift
enum LedgerTradeSide: Sendable { case buy, sell }
struct LedgerTrade: Sendable, Equatable {
    let symbol: String; let side: LedgerTradeSide; let quantity: Double; let price: Double
    let tradeDate: Date; let instrumentId: UUID?; let externalId: String
    /// Sell from this exact row. Nil: the single row for `symbol` in the portfolio.
    let stockId: UUID?
}
struct LedgerTradeResult: Sendable, Equatable { let symbol: String; let remainingShares: Double }
enum LedgerTradeRecorderError: Error, Equatable { case holdingNotFound(String), insufficientShares(String), insufficientCash(String) }
struct LedgerTradeRecorder: Sendable {
    /// Call inside the caller's `db.transaction`.
    func record(_ trades: [LedgerTrade], userId: UUID, portfolioId: UUID, sourceProvider: String?, on db: any Database) async throws -> [LedgerTradeResult]
}
```

- [ ] **Step 1: Write a characterization test that pins today's sell behavior.** It covers three things the existing `sellCreditsCashAndPortfolioReflectsIt` doesn't check: the `manual:` Transaction, cash, and full-sale delete. Add it to `LedgerTradeRecorderTests.swift`:

```swift
import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("LedgerTradeRecorder", .serialized)
struct LedgerTradeRecorderTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func makeUser(on db: any Database) async throws -> UUID {
        let id = UUID()
        try await User(id: id, email: "ledger_\(id.uuidString.prefix(8).lowercased())@example.com", passwordHash: "x").create(on: db)
        return id
    }

    private func makeInstrument(_ symbol: String, on db: any Database) async throws -> UUID {
        let instrument = Instrument(conid: "test:\(symbol):\(UUID().uuidString.prefix(6))", symbol: symbol, exchange: "TEST", currency: "USD")
        try await instrument.create(on: db)
        return try instrument.requireID()
    }

    private func cash(userId: UUID, listId: UUID, on db: any Database) async throws -> Double {
        let account = try await ManualAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: db)
        return try await CashBalance.query(on: db).filter(\.$accountId == account.requireID()).all().reduce(0) { $0 + $1.balance }
    }

    @Test("sell endpoint: partial sale writes a manual transaction and credits cash; full sale deletes the row")
    func sellCharacterization() async throws {
        try await withApp { app in
            // Register through the API so the sell runs through the real controller.
            let suffix = UUID().uuidString.prefix(8).lowercased()
            var auth: AuthResponse?
            try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
                try req.content.encode(StockPlanBackend.AuthRegisterRequest(username: "ledger_\(suffix)", password: "Password123!", confirmPassword: "Password123!", email: "ledger+\(suffix)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)))
            }, afterResponse: { res async throws in auth = try res.content.decode(AuthResponse.self) })
            let token = try #require(auth).token
            let userId = try #require(auth).userId

            var stock: StockResponse?
            try await app.testing().test(.POST, "v1/stocks", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(StockRequest(symbol: "AAPL", shares: 5, buyPrice: 100, buyDate: "2026-01-02", notes: nil))
            }, afterResponse: { res async throws in stock = try res.content.decode(StockResponse.self) })
            let created = try #require(stock)

            try await app.testing().test(.POST, "v1/stocks/id/\(created.id)/sell", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(SellStockRequest(sharesToSell: 2, sellPrice: 150, sellDate: "2026-04-10"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(StockResponse.self).shares == 3)
            })
            let row = try #require(try await Stock.query(on: app.db).filter(\.$userId == userId).first())
            #expect(try await cash(userId: userId, listId: row.portfolioListId, on: app.db) == 300)
            let account = try await ManualAccountResolver.findOrCreate(userId: userId, portfolioId: row.portfolioListId, on: app.db)
            let sells = try await Transaction.query(on: app.db).filter(\.$accountId == account.requireID()).all()
            // The instrument may not resolve in the test environment; when it does, the row must be a manual sell.
            for sell in sells {
                #expect(sell.externalId?.hasPrefix("manual:") == true)
                #expect(sell.type == "sell")
                #expect(sell.quantity == 2)
            }

            try await app.testing().test(.POST, "v1/stocks/id/\(created.id)/sell", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(SellStockRequest(sharesToSell: 3, sellPrice: 100, sellDate: "2026-04-11"))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(StockResponse.self).shares == 0)
            })
            #expect(try await Stock.query(on: app.db).filter(\.$userId == userId).count() == 0)
            #expect(try await cash(userId: userId, listId: row.portfolioListId, on: app.db) == 600)
        }
    }
}
```

- [ ] **Step 2: Run it against the unchanged code and confirm it PASSES.** Run `swift test --filter LedgerTradeRecorderTests/sellCharacterization`. Expected: PASS. It pins current behavior. If it fails, fix the test until it describes today's behavior. Do not change product code.

- [ ] **Step 3: Add failing recorder tests** to the same suite:

```swift
    private func makeHypothetical(userId: UUID, on db: any Database) async throws -> UUID {
        let list = PortfolioList(userId: userId, name: "Sim \(UUID().uuidString.prefix(6))", mode: "hypothetical")
        try await list.create(on: db)
        return try list.requireID()
    }

    @Test("buy creates a row, merges weighted average on a second buy, debits cash, writes transactions")
    func buyMerges() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let listId = try await makeHypothetical(userId: userId, on: app.db)
            let aapl = try await makeInstrument("AAPL", on: app.db)
            let account = try await ManualAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: app.db)
            try await CashBalance(accountId: account.requireID(), currency: account.baseCurrency, balance: 1_000, asOf: Date()).create(on: app.db)

            let recorder = LedgerTradeRecorder()
            let day = Date(timeIntervalSince1970: 1_790_812_800)
            _ = try await app.db.transaction { db in
                try await recorder.record([
                    LedgerTrade(symbol: "AAPL", side: .buy, quantity: 2, price: 100, tradeDate: day, instrumentId: aapl, externalId: "pilot:f:v1:AAPL", stockId: nil),
                ], userId: userId, portfolioId: listId, sourceProvider: "pilot", on: db)
            }
            let results = try await app.db.transaction { db in
                try await recorder.record([
                    LedgerTrade(symbol: "AAPL", side: .buy, quantity: 2, price: 200, tradeDate: day, instrumentId: aapl, externalId: "pilot:f:v2:AAPL", stockId: nil),
                ], userId: userId, portfolioId: listId, sourceProvider: "pilot", on: db)
            }
            #expect(results == [LedgerTradeResult(symbol: "AAPL", remainingShares: 4)])
            let rows = try await Stock.query(on: app.db).filter(\.$portfolioListId == listId).all()
            #expect(rows.count == 1)
            #expect(rows.first?.buyPrice == 150)
            #expect(rows.first?.sourceProvider == "pilot")
            #expect(try await cash(userId: userId, listId: listId, on: app.db) == 400)
            #expect(try await Transaction.query(on: app.db).filter(\.$accountId == account.requireID()).count() == 2)
        }
    }

    @Test("buy beyond available cash throws and writes nothing")
    func insufficientCash() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let listId = try await makeHypothetical(userId: userId, on: app.db)
            let recorder = LedgerTradeRecorder()
            await #expect(throws: LedgerTradeRecorderError.insufficientCash("AAPL")) {
                try await app.db.transaction { db in
                    try await recorder.record([
                        LedgerTrade(symbol: "AAPL", side: .buy, quantity: 1, price: 10, tradeDate: Date(), instrumentId: nil, externalId: "x", stockId: nil),
                    ], userId: userId, portfolioId: listId, sourceProvider: "pilot", on: db)
                }
            }
            #expect(try await Stock.query(on: app.db).filter(\.$portfolioListId == listId).count() == 0)
        }
    }

    @Test("the same external id twice is rejected by the database")
    func duplicateExternalId() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let listId = try await makeHypothetical(userId: userId, on: app.db)
            let aapl = try await makeInstrument("AAPL", on: app.db)
            let account = try await ManualAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: app.db)
            try await CashBalance(accountId: account.requireID(), currency: account.baseCurrency, balance: 1_000, asOf: Date()).create(on: app.db)
            let trade = LedgerTrade(symbol: "AAPL", side: .buy, quantity: 1, price: 10, tradeDate: Date(), instrumentId: aapl, externalId: "pilot:f:v1:AAPL", stockId: nil)
            let recorder = LedgerTradeRecorder()
            _ = try await app.db.transaction { db in try await recorder.record([trade], userId: userId, portfolioId: listId, sourceProvider: "pilot", on: db) }
            await #expect(throws: (any Error).self) {
                try await app.db.transaction { db in try await recorder.record([trade], userId: userId, portfolioId: listId, sourceProvider: "pilot", on: db) }
            }
            #expect(try await cash(userId: userId, listId: listId, on: app.db) == 990)
        }
    }
```

- [ ] **Step 4: Run the tests and confirm they fail.** Run `swift test --filter LedgerTradeRecorderTests`. Expected: compile failure, because `LedgerTradeRecorder` is undefined.

- [ ] **Step 5: Implement `Portfolio/LedgerTradeRecorder.swift`.**

```swift
import Fluent
import Foundation

enum LedgerTradeSide: Sendable {
    case buy
    case sell
}

struct LedgerTrade: Sendable, Equatable {
    let symbol: String
    let side: LedgerTradeSide
    let quantity: Double
    let price: Double
    let tradeDate: Date
    /// Nil when the instrument could not be resolved. The share and cash
    /// changes still happen; only the Transaction row is skipped, as in the
    /// manual sell path.
    let instrumentId: UUID?
    let externalId: String
    /// Sell from this exact row. Nil: the single row for `symbol` in the portfolio.
    let stockId: UUID?
}

struct LedgerTradeResult: Sendable, Equatable {
    let symbol: String
    let remainingShares: Double
}

enum LedgerTradeRecorderError: Error, Equatable {
    case holdingNotFound(String)
    case insufficientShares(String)
    case insufficientCash(String)
}

/// The one place a trade changes a portfolio. It keeps `stocks`, the
/// manual account's `cash_balances` and `transactions` in step.
///
/// Holdings live in two stores that nothing else links, so a buy that touched
/// only one of them would show up in either the summary or the P&L, not both.
/// The caller owns the database transaction: any throw here rolls back every
/// trade in the batch.
struct LedgerTradeRecorder: Sendable {
    private static let epsilon = 1e-9
    private static let cashTolerance = 0.005

    func record(
        _ trades: [LedgerTrade],
        userId: UUID,
        portfolioId: UUID,
        sourceProvider: String?,
        on db: any Database
    ) async throws -> [LedgerTradeResult] {
        let account = try await ManualAccountResolver.findOrCreate(userId: userId, portfolioId: portfolioId, on: db)
        let accountId = try account.requireID()
        let cash = try await cashRow(accountId: accountId, currency: account.baseCurrency, on: db)

        var results: [LedgerTradeResult] = []
        for trade in trades {
            let remaining: Double
            switch trade.side {
            case .sell:
                remaining = try await applySell(trade, userId: userId, portfolioId: portfolioId, on: db)
                cash.balance += trade.quantity * trade.price
            case .buy:
                let cost = trade.quantity * trade.price
                guard cash.balance + Self.cashTolerance >= cost else {
                    throw LedgerTradeRecorderError.insufficientCash(trade.symbol)
                }
                remaining = try await applyBuy(trade, userId: userId, portfolioId: portfolioId, sourceProvider: sourceProvider, on: db)
                cash.balance -= cost
            }
            if let instrumentId = trade.instrumentId {
                try await Transaction(
                    accountId: accountId,
                    instrumentId: instrumentId,
                    externalId: trade.externalId,
                    type: trade.side == .buy ? TransactionType.buy.rawValue : TransactionType.sell.rawValue,
                    quantity: trade.quantity,
                    price: trade.price,
                    currency: account.baseCurrency,
                    tradeDate: trade.tradeDate
                ).save(on: db)
            }
            results.append(LedgerTradeResult(symbol: trade.symbol, remainingShares: remaining))
        }
        cash.asOf = Date()
        try await cash.save(on: db)
        return results
    }

    private func cashRow(accountId: UUID, currency: String, on db: any Database) async throws -> CashBalance {
        if let existing = try await CashBalance.query(on: db)
            .filter(\.$accountId == accountId)
            .filter(\.$currency == currency)
            .first()
        {
            return existing
        }
        return CashBalance(accountId: accountId, currency: currency, balance: 0, asOf: Date())
    }

    private func applySell(_ trade: LedgerTrade, userId: UUID, portfolioId: UUID, on db: any Database) async throws -> Double {
        var query = Stock.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$portfolioListId == portfolioId)
        if let stockId = trade.stockId {
            query = query.filter(\.$id == stockId)
        } else {
            query = query.filter(\.$symbol == trade.symbol)
        }
        guard let stock = try await query.first() else {
            throw LedgerTradeRecorderError.holdingNotFound(trade.symbol)
        }
        guard trade.quantity <= stock.shares + Self.epsilon else {
            throw LedgerTradeRecorderError.insufficientShares(trade.symbol)
        }
        if stock.shares - trade.quantity <= Self.epsilon {
            try await stock.delete(on: db)
            return 0
        }
        stock.shares -= trade.quantity
        try await stock.save(on: db)
        return stock.shares
    }

    /// Merges into an existing row the way `DatabaseStocksRepository.create`
    /// does: shares add, cost basis becomes the weighted average, and the
    /// earliest buy date is kept.
    private func applyBuy(_ trade: LedgerTrade, userId: UUID, portfolioId: UUID, sourceProvider: String?, on db: any Database) async throws -> Double {
        if let existing = try await Stock.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$portfolioListId == portfolioId)
            .filter(\.$symbol == trade.symbol)
            .first()
        {
            let total = existing.shares + trade.quantity
            existing.buyPrice = (existing.shares * existing.buyPrice + trade.quantity * trade.price) / total
            existing.shares = total
            existing.buyDate = min(existing.buyDate, trade.tradeDate)
            try await existing.save(on: db)
            return total
        }
        try await Stock(
            userId: userId,
            portfolioListId: portfolioId,
            symbol: trade.symbol,
            shares: trade.quantity,
            buyPrice: trade.price,
            buyDate: trade.tradeDate,
            sourceProvider: sourceProvider
        ).create(on: db)
        return trade.quantity
    }
}
```

- [ ] **Step 6: Move `StockService.sell` onto the recorder.** Replace steps 1–4 inside `return try await db.transaction { transactionDB in` (`StockService.swift:420-478`) with the code below. Keep step 5 (activity) and the `return` unchanged.

```swift
        return try await db.transaction { transactionDB in
            // Shares, cash and the Transaction row move together through the
            // one ledger write path; see LedgerTradeRecorder.
            let results = try await LedgerTradeRecorder().record(
                [LedgerTrade(
                    symbol: stock.symbol,
                    side: .sell,
                    quantity: payload.sharesToSell,
                    price: payload.sellPrice,
                    tradeDate: tradeDate,
                    instrumentId: sellInstrumentId,
                    externalId: TransactionService.manualExternalIDPrefix + UUID().uuidString.lowercased(),
                    stockId: id
                )],
                userId: userId,
                portfolioId: stock.portfolioListId,
                sourceProvider: nil,
                on: transactionDB
            )
            stock.shares = results.first?.remainingShares ?? 0
```
(The old code at step 1 called `repo.delete(id:userId:on:)`. Check that `DatabaseStocksRepository.delete` does nothing besides deleting the row. If it also syncs `usageCounterService` holdings counts, call that same sync after the transaction when `stock.shares == 0`, mirroring the `delete` endpoint at `StockService.swift:373-380`.)

- [ ] **Step 7: Run the tests and confirm they pass.** Run `swift test --filter LedgerTradeRecorderTests`, then `swift test --filter StockPlanBackendTests/sellCreditsCashAndPortfolioReflectsIt`. Expected: all pass, including the unchanged characterization test.

- [ ] **Step 8: Commit**

```bash
git add Sources/StockPlanBackend/Portfolio/LedgerTradeRecorder.swift Sources/StockPlanBackend/Stocks/StockService.swift Tests/StockPlanBackendTests/LedgerTradeRecorderTests.swift
git commit -m "refactor(portfolio): one ledger write path for shares, cash and transactions

StockService.sell now records through LedgerTradeRecorder, which pilot
follows will share. Behaviour is pinned by a characterization test."
```

---

### Task 8: Rebalance planner + mirror service

**Files:**
- Create: `Sources/StockPlanBackend/Pilots/PilotRebalancePlanner.swift`
- Create: `Sources/StockPlanBackend/Pilots/PilotMirrorService.swift`
- Test: `Tests/StockPlanBackendTests/PilotRebalancePlannerTests.swift`
- Test: `Tests/StockPlanBackendTests/PilotMirrorServiceTests.swift`

**Interfaces:**
- Consumes:
  - `LedgerTradeRecorder` and `LedgerTrade` (Task 7)
  - the models from Task 3
  - `WatchlistStatus.exited` (Task 2)
  - `UsageCounterService.enforceResourceLimit(_:userId:currentCount:adding:on:)` (see `Stocks/WatchlistService.swift:84`)
- Produces:

```swift
struct PilotOrder: Sendable, Equatable { let symbol: String; let side: LedgerTradeSide; let quantity: Double; let price: Double }
struct PilotRebalancePlan: Sendable, Equatable { let orders: [PilotOrder]; let unpriced: [String] }
enum PilotRebalancePlanner {
    static func plan(weights: [String: Double], holdings: [String: Double], cash: Double, prices: [String: Double]) -> PilotRebalancePlan
}
typealias PilotQuoteFetcher = @Sendable (_ symbol: String) async throws -> Double
typealias PilotInstrumentResolver = @Sendable (_ symbol: String) async -> UUID?
typealias PilotWatchlistLimit = @Sendable (_ userId: UUID, _ currentCount: Int, _ db: any Database) async throws -> Void
struct PilotMirrorService: Sendable {
    init(quote: @escaping PilotQuoteFetcher, instrument: @escaping PilotInstrumentResolver, watchlistLimit: @escaping PilotWatchlistLimit)
    /// Applies `version` to `follow`. Returns false when another run already applied it.
    func apply(follow: PilotFollow, pilot: Pilot, version: PilotBookVersion, previous: PilotBookVersion?, now: Date, on db: any Database) async throws -> Bool
}
```

- [ ] **Step 1: Write the failing planner tests.**

```swift
@testable import StockPlanBackend
import Testing

@Suite("PilotRebalancePlanner")
struct PilotRebalancePlannerTests {
    @Test("from cash: buys target weights")
    func fromCash() {
        let plan = PilotRebalancePlanner.plan(weights: ["AAPL": 0.5, "MSFT": 0.5], holdings: [:], cash: 10_000, prices: ["AAPL": 100, "MSFT": 250])
        #expect(plan.orders == [
            PilotOrder(symbol: "AAPL", side: .buy, quantity: 50, price: 100),
            PilotOrder(symbol: "MSFT", side: .buy, quantity: 20, price: 250),
        ])
    }

    @Test("sells come first, and a dropped symbol is sold out")
    func sellsFirst() {
        let plan = PilotRebalancePlanner.plan(weights: ["MSFT": 1.0], holdings: ["AAPL": 10], cash: 0, prices: ["AAPL": 100, "MSFT": 100])
        #expect(plan.orders == [
            PilotOrder(symbol: "AAPL", side: .sell, quantity: 10, price: 100),
            PilotOrder(symbol: "MSFT", side: .buy, quantity: 10, price: 100),
        ])
    }

    @Test("trades below max($5, 0.25% of value) are skipped")
    func threshold() {
        let plan = PilotRebalancePlanner.plan(weights: ["AAPL": 1.0], holdings: ["AAPL": 99.99], cash: 1, prices: ["AAPL": 100])
        #expect(plan.orders.isEmpty)
    }

    @Test("an unpriced symbol is left alone and reported")
    func unpricedSymbolLeftAlone() {
        let plan = PilotRebalancePlanner.plan(weights: ["AAPL": 0.5, "ZZZZ": 0.5], holdings: ["OLD": 5], cash: 1_000, prices: ["AAPL": 100])
        #expect(plan.unpriced.sorted() == ["OLD", "ZZZZ"])
        #expect(plan.orders == [PilotOrder(symbol: "AAPL", side: .buy, quantity: 5, price: 100)])
    }

    @Test("buys never spend more than the cash available")
    func cashCap() {
        let plan = PilotRebalancePlanner.plan(weights: ["AAPL": 1.0], holdings: [:], cash: 100, prices: ["AAPL": 30])
        let spent = plan.orders.filter { $0.side == .buy }.reduce(0.0) { $0 + $1.quantity * $1.price }
        #expect(spent <= 100 + 1e-6)
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail.** Run `swift test --filter PilotRebalancePlannerTests`. Expected: compile failure.

- [ ] **Step 3: Implement the planner.**

```swift
import Foundation

struct PilotOrder: Sendable, Equatable {
    let symbol: String
    let side: LedgerTradeSide
    let quantity: Double
    let price: Double
}

struct PilotRebalancePlan: Sendable, Equatable {
    let orders: [PilotOrder]
    /// Held or target symbols with no price. They are not traded: selling or
    /// sizing blind would be a guess.
    let unpriced: [String]
}

/// Orders that move a portfolio onto target weights. Pure.
///
/// V = cash + priced holdings. Target shares = weight × V ÷ price, with
/// fractional shares allowed. Sells come first so their proceeds fund the
/// buys, and buys are capped at the cash on hand. Moves smaller than
/// max($5, 0.25% of V) are skipped, so that rounding noise does not churn
/// the event log.
enum PilotRebalancePlanner {
    static func plan(weights: [String: Double], holdings: [String: Double], cash: Double, prices: [String: Double]) -> PilotRebalancePlan {
        let symbols = Set(weights.keys).union(holdings.keys)
        let unpriced = symbols.filter { (prices[$0] ?? 0) <= 0 }.sorted()
        let priced = symbols.subtracting(unpriced)

        let value = cash + priced.reduce(0.0) { $0 + (holdings[$1] ?? 0) * prices[$1]! }
        guard value > 0 else { return PilotRebalancePlan(orders: [], unpriced: unpriced) }
        let threshold = max(5, value * 0.0025)

        var sells: [PilotOrder] = []
        var buys: [PilotOrder] = []
        for symbol in priced.sorted() {
            let price = prices[symbol]!
            let current = holdings[symbol] ?? 0
            let target = (weights[symbol] ?? 0) * value / price
            let delta = target - current
            guard abs(delta) * price >= threshold else { continue }
            if delta < 0 {
                // Selling everything when the target is zero avoids dust positions.
                let quantity = target == 0 ? current : -delta
                sells.append(PilotOrder(symbol: symbol, side: .sell, quantity: round6(quantity), price: price))
            } else {
                buys.append(PilotOrder(symbol: symbol, side: .buy, quantity: delta, price: price))
            }
        }

        var available = cash + sells.reduce(0.0) { $0 + $1.quantity * $1.price }
        var cappedBuys: [PilotOrder] = []
        for buy in buys {
            let affordable = min(buy.quantity, floor6(available / buy.price))
            guard affordable * buy.price >= threshold else { continue }
            cappedBuys.append(PilotOrder(symbol: buy.symbol, side: .buy, quantity: round6(affordable), price: buy.price))
            available -= round6(affordable) * buy.price
        }
        return PilotRebalancePlan(orders: sells + cappedBuys, unpriced: unpriced)
    }

    private static func round6(_ x: Double) -> Double { (x * 1_000_000).rounded() / 1_000_000 }
    private static func floor6(_ x: Double) -> Double { (x * 1_000_000).rounded(.down) / 1_000_000 }
}
```

- [ ] **Step 4: Run the planner tests and confirm they pass.** Run `swift test --filter PilotRebalancePlannerTests`. Expected: 5 passed.

- [ ] **Step 5: Write the failing mirror-service tests.** They use the `withApp`, `makeUser` and `makeHypothetical` helpers, copied from Task 7 into this file.

```swift
import Fluent
import Foundation
import SQLKit
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("PilotMirrorService", .serialized)
struct PilotMirrorServiceTests {
    // withApp / makeUser / makeHypothetical: copy verbatim from LedgerTradeRecorderTests.

    private let now = Date(timeIntervalSince1970: 1_790_812_800)

    private func makePilot(on db: any Database) async throws -> Pilot {
        let pilot = Pilot(kind: .politician, slug: "p-\(UUID().uuidString.prefix(6))", displayName: "Test Pilot", chamber: "house", nameAliases: ["Test Pilot"])
        try await pilot.create(on: db)
        return pilot
    }

    private func version(_ pilot: Pilot, _ v: Int, _ weights: [String: Double], on db: any Database) async throws -> PilotBookVersion {
        let row = PilotBookVersion(pilotId: try pilot.requireID(), version: v, computedAt: now, weights: weights, skippedPuts: 0)
        try await row.create(on: db)
        return row
    }

    private func service(prices: [String: Double], limit: PilotWatchlistLimit? = nil) -> PilotMirrorService {
        PilotMirrorService(
            quote: { symbol in
                guard let price = prices[symbol] else { throw Abort(.badGateway) }
                return price
            },
            instrument: { _ in nil },
            watchlistLimit: limit ?? { _, _, _ in }
        )
    }

    private func portfolioFollow(userId: UUID, pilot: Pilot, cash: Double, on db: any Database) async throws -> PilotFollow {
        let listId = try await makeHypothetical(userId: userId, on: db)
        let account = try await ManualAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: db)
        try await CashBalance(accountId: account.requireID(), currency: account.baseCurrency, balance: cash, asOf: now).create(on: db)
        let follow = PilotFollow(userId: userId, pilotId: try pilot.requireID(), targetKind: .portfolio, portfolioListId: listId, startingCapital: cash)
        try await follow.create(on: db)
        return follow
    }

    @Test("portfolio follow buys the book and records events and applied_version")
    func appliesBook() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let follow = try await portfolioFollow(userId: userId, pilot: pilot, cash: 10_000, on: app.db)
            let v1 = try await version(pilot, 1, ["AAPL": 0.5, "MSFT": 0.5], on: app.db)
            let applied = try await service(prices: ["AAPL": 100, "MSFT": 250]).apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db)
            #expect(applied)
            let stocks = try await Stock.query(on: app.db).filter(\.$portfolioListId == follow.portfolioListId!).sort(\.$symbol).all()
            #expect(stocks.map(\.symbol) == ["AAPL", "MSFT"])
            #expect(stocks.map(\.shares) == [50, 20])
            let events = try await PilotFollowEvent.query(on: app.db).filter(\.$followId == follow.requireID()).all()
            #expect(Set(events.map(\.kind)) == ["buy"])
            #expect(try await PilotFollow.find(follow.requireID(), on: app.db)?.appliedVersion == 1)
        }
    }

    @Test("applying the same version twice changes nothing the second time")
    func applyIsIdempotent() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let follow = try await portfolioFollow(userId: userId, pilot: pilot, cash: 10_000, on: app.db)
            let v1 = try await version(pilot, 1, ["AAPL": 1.0], on: app.db)
            let svc = service(prices: ["AAPL": 100])
            #expect(try await svc.apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db))
            let stale = try #require(try await PilotFollow.find(follow.requireID(), on: app.db))
            stale.appliedVersion = 0 // simulate a second pod holding a stale copy
            #expect(try await svc.apply(follow: stale, pilot: pilot, version: v1, previous: nil, now: now, on: app.db) == false)
            let stock = try #require(try await Stock.query(on: app.db).filter(\.$portfolioListId == follow.portfolioListId!).first())
            #expect(stock.shares == 100)
        }
    }

    @Test("an unpriced target is skipped with an event; priced symbols still trade")
    func unpricedSymbolLeftAlone() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let follow = try await portfolioFollow(userId: userId, pilot: pilot, cash: 1_000, on: app.db)
            let v1 = try await version(pilot, 1, ["AAPL": 0.5, "ZZZZ": 0.5], on: app.db)
            _ = try await service(prices: ["AAPL": 100]).apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db)
            let events = try await PilotFollowEvent.query(on: app.db).filter(\.$followId == follow.requireID()).all()
            #expect(events.contains { $0.kind == "skipped_unpriced" && $0.symbol == "ZZZZ" })
            #expect(events.contains { $0.kind == "buy" && $0.symbol == "AAPL" })
        }
    }

    @Test("watchlist follow: added, exited, re-added")
    func watchlistFeed() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let list = WatchlistList(userId: userId, name: "Feed \(UUID().uuidString.prefix(4))")
            try await list.create(on: app.db)
            let follow = PilotFollow(userId: userId, pilotId: try pilot.requireID(), targetKind: .watchlist, watchlistListId: try list.requireID())
            try await follow.create(on: app.db)
            try await PilotDisclosureRecord(pilotId: try pilot.requireID(), sourceKey: "a", symbol: "NVDA", side: .buy, instrument: .stock, transactionDate: "2026-09-14").create(on: app.db)

            let svc = service(prices: [:])
            let v1 = try await version(pilot, 1, ["NVDA": 1.0], on: app.db)
            _ = try await svc.apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db)
            var item = try #require(try await WatchlistItem.query(on: app.db).filter(\.$watchlistListId == list.requireID()).first())
            #expect(item.status == WatchlistStatus.active.rawValue)
            #expect(item.note == "Test Pilot bought 2026-09-14")

            let v2 = try await version(pilot, 2, ["AAPL": 1.0], on: app.db)
            let reloaded = try #require(try await PilotFollow.find(follow.requireID(), on: app.db))
            _ = try await svc.apply(follow: reloaded, pilot: pilot, version: v2, previous: v1, now: now, on: app.db)
            item = try #require(try await WatchlistItem.find(item.requireID(), on: app.db))
            #expect(item.status == WatchlistStatus.exited.rawValue)

            let v3 = try await version(pilot, 3, ["NVDA": 1.0], on: app.db)
            let again = try #require(try await PilotFollow.find(follow.requireID(), on: app.db))
            _ = try await svc.apply(follow: again, pilot: pilot, version: v3, previous: v2, now: now, on: app.db)
            item = try #require(try await WatchlistItem.find(item.requireID(), on: app.db))
            #expect(item.status == WatchlistStatus.active.rawValue)
        }
    }

    @Test("watchlist follow stops at the item limit, highest weight first")
    func watchlistRespectsItemLimit() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let list = WatchlistList(userId: userId, name: "Feed \(UUID().uuidString.prefix(4))")
            try await list.create(on: app.db)
            let follow = PilotFollow(userId: userId, pilotId: try pilot.requireID(), targetKind: .watchlist, watchlistListId: try list.requireID())
            try await follow.create(on: app.db)
            let limited = service(prices: [:]) { _, current, _ in
                if current >= 2 { throw BillingUpgradeRequiredError(feature: .watchlistItems, plan: "free", limit: 2, current: current) }
            }
            let v1 = try await version(pilot, 1, ["A": 0.5, "B": 0.3, "C": 0.2], on: app.db)
            _ = try await limited.apply(follow: follow, pilot: pilot, version: v1, previous: nil, now: now, on: app.db)
            let symbols = try await WatchlistItem.query(on: app.db).filter(\.$watchlistListId == list.requireID()).all().map(\.symbol).sorted()
            #expect(symbols == ["A", "B"])
            let events = try await PilotFollowEvent.query(on: app.db).filter(\.$followId == follow.requireID()).all()
            #expect(events.contains { $0.kind == "skipped_limit" && $0.symbol == "C" })
        }
    }
}
```
(Check the `WatchlistList` initializer in `Models/WatchlistList.swift` and match its argument labels. The tests assume `WatchlistList(userId:name:)`.)

- [ ] **Step 6: Run the tests and confirm they fail.** Run `swift test --filter PilotMirrorServiceTests`. Expected: compile failure.

- [ ] **Step 7: Implement `PilotMirrorService.swift`.**

```swift
import Fluent
import Foundation
import SQLKit
import StockPlanShared
import Vapor

typealias PilotQuoteFetcher = @Sendable (_ symbol: String) async throws -> Double
typealias PilotInstrumentResolver = @Sendable (_ symbol: String) async -> UUID?
typealias PilotWatchlistLimit = @Sendable (_ userId: UUID, _ currentCount: Int, _ db: any Database) async throws -> Void

/// Applies a pilot's book version to one follow.
///
/// Prices are live quotes taken now, when Norviq applies the book. They are
/// never the pilot's historical trade price: the disclosure arrived weeks
/// later, and pretending the follower bought on the original date would
/// overstate what copying the pilot returns.
struct PilotMirrorService: Sendable {
    private let quote: PilotQuoteFetcher
    private let instrument: PilotInstrumentResolver
    private let watchlistLimit: PilotWatchlistLimit
    private let recorder = LedgerTradeRecorder()

    init(quote: @escaping PilotQuoteFetcher, instrument: @escaping PilotInstrumentResolver, watchlistLimit: @escaping PilotWatchlistLimit) {
        self.quote = quote
        self.instrument = instrument
        self.watchlistLimit = watchlistLimit
    }

    func apply(follow: PilotFollow, pilot: Pilot, version: PilotBookVersion, previous: PilotBookVersion?, now: Date, on db: any Database) async throws -> Bool {
        switch follow.target {
        case .portfolio:
            return try await applyPortfolio(follow: follow, version: version, now: now, on: db)
        case .watchlist:
            return try await applyWatchlist(follow: follow, pilot: pilot, version: version, previous: previous, now: now, on: db)
        }
    }

    // MARK: - Portfolio

    private func applyPortfolio(follow: PilotFollow, version: PilotBookVersion, now: Date, on db: any Database) async throws -> Bool {
        guard let listId = follow.portfolioListId else { return false }
        let followId = try follow.requireID()

        let stocks = try await Stock.query(on: db)
            .filter(\.$userId == follow.userId)
            .filter(\.$portfolioListId == listId)
            .all()
        let holdings = stocks.reduce(into: [String: Double]()) { $0[$1.symbol, default: 0] += $1.shares }
        let account = try await ManualAccountResolver.findOrCreate(userId: follow.userId, portfolioId: listId, on: db)
        let cash = try await CashBalance.query(on: db)
            .filter(\.$accountId == account.requireID())
            .all()
            .reduce(0.0) { $0 + $1.balance }

        // Quotes and instruments resolve before the transaction opens: both may
        // reach the network, and a failure inside db.transaction poisons it.
        var prices: [String: Double] = [:]
        for symbol in Set(version.weights.keys).union(holdings.keys) {
            if let price = try? await quote(symbol), price > 0 { prices[symbol] = price }
        }
        let plan = PilotRebalancePlanner.plan(weights: version.weights, holdings: holdings, cash: cash, prices: prices)
        var instruments: [String: UUID] = [:]
        for order in plan.orders {
            if let id = await instrument(order.symbol) { instruments[order.symbol] = id }
        }

        return try await db.transaction { tx in
            guard try await claim(followId: followId, version: version.version, on: tx) else { return false }
            let trades = plan.orders.map { order in
                LedgerTrade(
                    symbol: order.symbol,
                    side: order.side,
                    quantity: order.quantity,
                    price: order.price,
                    tradeDate: now,
                    instrumentId: instruments[order.symbol],
                    externalId: "pilot:\(followId.uuidString.lowercased()):v\(version.version):\(order.symbol)",
                    stockId: nil
                )
            }
            _ = try await recorder.record(trades, userId: follow.userId, portfolioId: listId, sourceProvider: "pilot", on: tx)
            for order in plan.orders {
                try await PilotFollowEvent(followId: followId, bookVersion: version.version, kind: order.side == .buy ? "buy" : "sell", symbol: order.symbol, quantity: order.quantity, price: order.price, pricedAt: now).create(on: tx)
            }
            for symbol in plan.unpriced {
                try await PilotFollowEvent(followId: followId, bookVersion: version.version, kind: "skipped_unpriced", symbol: symbol, pricedAt: now, note: "No price available; left unchanged.").create(on: tx)
            }
            return true
        }
    }

    // MARK: - Watchlist

    private func applyWatchlist(follow: PilotFollow, pilot: Pilot, version: PilotBookVersion, previous: PilotBookVersion?, now: Date, on db: any Database) async throws -> Bool {
        guard let listId = follow.watchlistListId else { return false }
        let followId = try follow.requireID()
        let before = Set(previous?.weights.keys.map { $0 } ?? [])
        let added = version.weights.filter { !before.contains($0.key) }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        let exited = before.subtracting(version.weights.keys).sorted()

        return try await db.transaction { tx in
            guard try await claim(followId: followId, version: version.version, on: tx) else { return false }
            for symbol in added {
                let note = try await activityNote(pilot: pilot, symbol: symbol, bought: true, on: tx)
                if let existing = try await WatchlistItem.query(on: tx).filter(\.$watchlistListId == listId).filter(\.$symbol == symbol).first() {
                    existing.status = WatchlistStatus.active.rawValue
                    existing.note = note
                    try await existing.save(on: tx)
                } else {
                    let count = try await WatchlistItem.query(on: tx).filter(\.$userId == follow.userId).count()
                    do {
                        try await watchlistLimit(follow.userId, count, tx)
                    } catch is BillingUpgradeRequiredError {
                        try await PilotFollowEvent(followId: followId, bookVersion: version.version, kind: "skipped_limit", symbol: symbol, pricedAt: now, note: "Watchlist item limit reached.").create(on: tx)
                        continue
                    }
                    try await WatchlistItem(userId: follow.userId, watchlistListId: listId, symbol: symbol, note: note, status: .active).create(on: tx)
                }
                try await PilotFollowEvent(followId: followId, bookVersion: version.version, kind: "watch_added", symbol: symbol, pricedAt: now, note: note).create(on: tx)
            }
            for symbol in exited {
                guard let item = try await WatchlistItem.query(on: tx).filter(\.$watchlistListId == listId).filter(\.$symbol == symbol).first() else { continue }
                let note = try await activityNote(pilot: pilot, symbol: symbol, bought: false, on: tx)
                item.status = WatchlistStatus.exited.rawValue
                item.note = [item.note, note].compactMap(\.self).joined(separator: " · ")
                try await item.save(on: tx)
                try await PilotFollowEvent(followId: followId, bookVersion: version.version, kind: "watch_exited", symbol: symbol, pricedAt: now, note: note).create(on: tx)
            }
            return true
        }
    }

    /// "Nancy Pelosi bought 2026-09-14" or, for funds, "Berkshire Hathaway held in 2026Q2".
    private func activityNote(pilot: Pilot, symbol: String, bought: Bool, on db: any Database) async throws -> String {
        let latest = try await PilotDisclosureRecord.query(on: db)
            .filter(\.$pilotId == pilot.requireID())
            .filter(\.$symbol == symbol)
            .sort(\.$transactionDate, .descending)
            .sort(\.$period, .descending)
            .first()
        if pilot.pilotKind == .fund {
            let period = latest?.period ?? "the latest filing"
            return bought ? "\(pilot.displayName) held in \(period)" : "\(pilot.displayName) no longer held after \(period)"
        }
        let date = latest?.transactionDate ?? "recently"
        return "\(pilot.displayName) \(bought ? "bought" : "sold") \(date)"
    }

    /// Moves `applied_version` forward inside the caller's transaction. False
    /// when another run already applied this version or a later one; the
    /// caller then writes nothing. This is the idempotency guard between pods.
    private func claim(followId: UUID, version: Int, on db: any Database) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else { return false }
        let rows = try await sql.raw("""
        UPDATE pilot_follows SET applied_version = \(bind: version), updated_at = NOW()
        WHERE id = \(bind: followId) AND applied_version < \(bind: version)
        RETURNING id
        """).all()
        return !rows.isEmpty
    }
}
```

- [ ] **Step 8: Run the tests and confirm they pass.** Run `swift test --filter PilotMirrorServiceTests` and `swift test --filter PilotRebalancePlannerTests`. Expected: all pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/StockPlanBackend/Pilots/PilotRebalancePlanner.swift Sources/StockPlanBackend/Pilots/PilotMirrorService.swift Tests/StockPlanBackendTests/PilotRebalancePlannerTests.swift Tests/StockPlanBackendTests/PilotMirrorServiceTests.swift
git commit -m "feat(pilots): rebalance follows onto a pilot's book through the ledger"
```

---

### Task 9: `PilotFollowService` — create, validate, gate

**Files:**
- Create: `Sources/StockPlanBackend/Pilots/PilotFollowService.swift`
- Test: `Tests/StockPlanBackendTests/PilotFollowServiceTests.swift`

**Interfaces:**
- Consumes:
  - `PilotMirrorService` (Task 8)
  - `EntitlementSnapshot` (`isPro`, `level`)
  - `BillingUpgradeRequiredError(feature:plan:limit:current:)`
  - `PilotFollowCreateRequest` (Task 2)
- Produces:

```swift
struct PilotFollowService: Sendable {
    init(mirror: PilotMirrorService)
    static let proFollowLimit = 10
    static let freeFollowLimit = 1
    func create(_ request: PilotFollowCreateRequest, userId: UUID, entitlement: EntitlementSnapshot, now: Date, on db: any Database) async throws -> PilotFollow
}
```

- [ ] **Step 1: Write the failing tests.** Copy the `withApp`, `makeUser` and `makePilot` helpers from Task 8, plus a `PilotMirrorService` whose quote always returns 100.

```swift
    private func entitlement(_ userId: UUID, pro: Bool) -> EntitlementSnapshot {
        EntitlementSnapshot(userId: userId, level: pro ? "pro" : "free")
    }

    private func seededPilot(on db: any Database) async throws -> Pilot {
        let pilot = try await makePilot(on: db)
        try await PilotBookVersion(pilotId: try pilot.requireID(), version: 1, computedAt: now, weights: ["AAPL": 1.0], skippedPuts: 0).create(on: db)
        return pilot
    }

    private var followService: PilotFollowService {
        PilotFollowService(mirror: PilotMirrorService(quote: { _ in 100 }, instrument: { _ in nil }, watchlistLimit: { _, _, _ in }))
    }

    @Test("pro: portfolio follow creates a hypothetical portfolio funded with starting capital and applies the book")
    func createsPortfolio() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await seededPilot(on: app.db)
            let follow = try await followService.create(
                PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .portfolio, portfolioListId: nil, watchlistListId: nil, startingCapital: 10_000),
                userId: userId, entitlement: entitlement(userId, pro: true), now: now, on: app.db)
            let list = try #require(try await PortfolioList.find(follow.portfolioListId, on: app.db))
            #expect(list.mode == "hypothetical")
            #expect(list.isDefault == false)
            #expect(try await PilotFollow.find(follow.requireID(), on: app.db)?.appliedVersion == 1)
            #expect(try await Stock.query(on: app.db).filter(\.$portfolioListId == list.requireID()).first()?.shares == 100)
        }
    }

    @Test("free: portfolio target is refused; one watchlist follow allowed, second refused")
    func freeGating() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await seededPilot(on: app.db)
            let other = try await seededPilot(on: app.db)
            let free = entitlement(userId, pro: false)
            await #expect(throws: BillingUpgradeRequiredError.self) {
                try await followService.create(PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .portfolio, portfolioListId: nil, watchlistListId: nil, startingCapital: 1_000), userId: userId, entitlement: free, now: now, on: app.db)
            }
            _ = try await followService.create(PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .watchlist, portfolioListId: nil, watchlistListId: nil, startingCapital: nil), userId: userId, entitlement: free, now: now, on: app.db)
            await #expect(throws: BillingUpgradeRequiredError.self) {
                try await followService.create(PilotFollowCreateRequest(pilotSlug: other.slug, targetKind: .watchlist, portfolioListId: nil, watchlistListId: nil, startingCapital: nil), userId: userId, entitlement: free, now: now, on: app.db)
            }
        }
    }

    @Test("actual, default and non-empty portfolios are rejected with 422 and nothing is written")
    func rejectsNonEmptyAndActualTargets() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await seededPilot(on: app.db)
            let pro = entitlement(userId, pro: true)
            let actual = PortfolioList(userId: userId, name: "Main", isDefault: true, mode: "actual")
            try await actual.create(on: app.db)
            let busy = PortfolioList(userId: userId, name: "Busy", mode: "hypothetical")
            try await busy.create(on: app.db)
            try await Stock(userId: userId, portfolioListId: busy.requireID(), symbol: "KO", shares: 1, buyPrice: 1, buyDate: now).create(on: app.db)

            for target in [actual, busy] {
                do {
                    _ = try await followService.create(PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .portfolio, portfolioListId: try target.requireID().uuidString, watchlistListId: nil, startingCapital: 1_000), userId: userId, entitlement: pro, now: now, on: app.db)
                    Issue.record("expected 422 for \(target.name)")
                } catch let error as Abort {
                    #expect(error.status == .unprocessableEntity)
                }
            }
            #expect(try await PilotFollow.query(on: app.db).filter(\.$userId == userId).count() == 0)
        }
    }

    @Test("missing or non-positive starting capital is a 400 for portfolio targets")
    func capitalValidation() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await seededPilot(on: app.db)
            do {
                _ = try await followService.create(PilotFollowCreateRequest(pilotSlug: pilot.slug, targetKind: .portfolio, portfolioListId: nil, watchlistListId: nil, startingCapital: 0), userId: userId, entitlement: entitlement(userId, pro: true), now: now, on: app.db)
                Issue.record("expected 400")
            } catch let error as Abort {
                #expect(error.status == .badRequest)
            }
        }
    }
```

- [ ] **Step 2: Run the tests and confirm they fail.** Run `swift test --filter PilotFollowServiceTests`. Expected: compile failure. If `EntitlementSnapshot` has more stored properties than `userId`/`level`, build it the way `EntitlementResolver.resolve` does.

- [ ] **Step 3: Implement.**

```swift
import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Creates follows. A follow never touches a real portfolio: portfolio targets
/// must be hypothetical, not the default, and empty. Anything else would mix
/// simulated trades into numbers the user relies on.
struct PilotFollowService: Sendable {
    static let proFollowLimit = 10
    static let freeFollowLimit = 1
    static let maxStartingCapital = 10_000_000.0
    /// The Pro portfolio limit enforced by PortfolioManagementController.create.
    static let proPortfolioLimit = 25

    private let mirror: PilotMirrorService

    init(mirror: PilotMirrorService) {
        self.mirror = mirror
    }

    func create(_ request: PilotFollowCreateRequest, userId: UUID, entitlement: EntitlementSnapshot, now: Date, on db: any Database) async throws -> PilotFollow {
        guard let pilot = try await Pilot.query(on: db).filter(\.$slug == request.pilotSlug).filter(\.$active == true).first() else {
            throw Abort(.notFound, reason: "Pilot not found.")
        }
        let pilotId = try pilot.requireID()
        guard let latest = try await PilotBookVersion.query(on: db).filter(\.$pilotId == pilotId).sort(\.$version, .descending).first() else {
            throw Abort(.conflict, reason: "This pilot has no disclosures yet. Try again later.")
        }

        let existing = try await PilotFollow.query(on: db).filter(\.$userId == userId).count()
        let limit = entitlement.isPro ? Self.proFollowLimit : Self.freeFollowLimit
        if request.targetKind == .portfolio, !entitlement.isPro {
            throw BillingUpgradeRequiredError(feature: .pilotFollows, plan: entitlement.level)
        }
        guard existing < limit else {
            throw BillingUpgradeRequiredError(feature: .pilotFollows, plan: entitlement.level, limit: limit, current: existing)
        }

        let follow: PilotFollow = try await db.transaction { tx in
            switch request.targetKind {
            case .portfolio:
                guard let capital = request.startingCapital, capital > 0, capital <= Self.maxStartingCapital else {
                    throw Abort(.badRequest, reason: "Starting capital must be between 0 and 10,000,000.")
                }
                let listId = try await portfolioTarget(request.portfolioListId, pilot: pilot, userId: userId, on: tx)
                let account = try await ManualAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: tx)
                try await CashBalance(accountId: account.requireID(), currency: account.baseCurrency, balance: capital, asOf: now).create(on: tx)
                let follow = PilotFollow(userId: userId, pilotId: pilotId, targetKind: .portfolio, portfolioListId: listId, startingCapital: capital, currency: account.baseCurrency)
                try await follow.create(on: tx)
                return follow
            case .watchlist:
                let listId = try await watchlistTarget(request.watchlistListId, pilot: pilot, userId: userId, on: tx)
                let follow = PilotFollow(userId: userId, pilotId: pilotId, targetKind: .watchlist, watchlistListId: listId)
                try await follow.create(on: tx)
                return follow
            }
        }

        // Applied after the commit: quotes reach the network and must not run
        // inside the transaction. If this fails, the follow stays at version 0
        // and the mirror job catches it up on its next tick.
        do {
            _ = try await mirror.apply(follow: follow, pilot: pilot, version: latest, previous: nil, now: now, on: db)
            follow.appliedVersion = latest.version
        } catch {
            db.logger.warning("pilot_follow initial apply failed follow_id=\(follow.id?.uuidString ?? "?") error=\(error)")
        }
        return follow
    }

    private func portfolioTarget(_ rawId: String?, pilot: Pilot, userId: UUID, on db: any Database) async throws -> UUID {
        if let rawId {
            guard let id = UUID(uuidString: rawId),
                  let list = try await PortfolioList.query(on: db).filter(\.$id == id).filter(\.$userId == userId).first()
            else { throw Abort(.notFound, reason: "Portfolio not found.") }
            guard list.mode == PortfolioMode.hypothetical.rawValue, !list.isDefault, list.archivedAt == nil else {
                throw Abort(.unprocessableEntity, reason: "Pilots can only be followed into a hypothetical portfolio, never your main or a real one.")
            }
            let held = try await Stock.query(on: db).filter(\.$portfolioListId == id).count()
            guard held == 0 else {
                throw Abort(.unprocessableEntity, reason: "Choose an empty hypothetical portfolio, or let Norviq create one.")
            }
            return id
        }
        let count = try await PortfolioList.query(on: db).filter(\.$userId == userId).filter(\.$archivedAt == nil).count()
        guard count < Self.proPortfolioLimit else {
            throw BillingUpgradeRequiredError(feature: .portfolioLists, plan: "pro", limit: Self.proPortfolioLimit, current: count)
        }
        let list = PortfolioList(userId: userId, name: try await uniqueName("\(pilot.displayName) copy", userId: userId, on: db), mode: PortfolioMode.hypothetical.rawValue)
        try await list.create(on: db)
        return try list.requireID()
    }

    private func watchlistTarget(_ rawId: String?, pilot: Pilot, userId: UUID, on db: any Database) async throws -> UUID {
        if let rawId {
            guard let id = UUID(uuidString: rawId),
                  try await WatchlistList.query(on: db).filter(\.$id == id).filter(\.$userId == userId).first() != nil
            else { throw Abort(.notFound, reason: "Watchlist not found.") }
            return id
        }
        let list = WatchlistList(userId: userId, name: "\(pilot.displayName) feed")
        try await list.create(on: db)
        return try list.requireID()
    }

    /// Portfolio names are unique per user; "X copy", then "X copy 2", and so on.
    private func uniqueName(_ base: String, userId: UUID, on db: any Database) async throws -> String {
        let taken = Set(try await PortfolioList.query(on: db).filter(\.$userId == userId).all().map(\.name))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
```
(Watchlist names may also be unique per user. If `WatchlistList` has a unique `(user_id, name)` index, reuse `uniqueName`'s approach against `WatchlistList`.)

- [ ] **Step 4: Run the tests and confirm they pass.** Run `swift test --filter PilotFollowServiceTests`. Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/StockPlanBackend/Pilots/PilotFollowService.swift Tests/StockPlanBackendTests/PilotFollowServiceTests.swift
git commit -m "feat(pilots): create follows into hypothetical portfolios or watchlists, with gating"
```

---

### Task 10: Ingestion service + seed list

**Files:**
- Create: `Sources/StockPlanBackend/Pilots/PilotIngestionService.swift`
- Create: `Sources/StockPlanBackend/Migrations/SeedPilots.swift`
- Modify: `Sources/StockPlanBackend/ConfigureBootstrap.swift` (after `CreatePilotTables()`)
- Test: `Tests/StockPlanBackendTests/PilotIngestionServiceTests.swift`

**Interfaces:**
- Consumes: `PilotDisclosureSource` and `PilotSourceIdentity` (Task 5), `PilotBookBuilder` (Task 4), models (Task 3).
- Produces:

```swift
enum PilotIngestOutcome: Equatable { case unchanged, newVersion(Int) }
struct PilotIngestionService: Sendable {
    init(politicians: any PilotDisclosureSource, funds: (any PilotDisclosureSource)?)
    func ingest(pilot: Pilot, now: Date, on db: any Database) async throws -> PilotIngestOutcome
}
```

- [ ] **Step 1: Write the failing tests.** Copy the `withApp` and `makePilot` helpers from Task 8.

```swift
    private struct StubSource: PilotDisclosureSource {
        let rows: [PilotDisclosureInput]
        func disclosures(for _: PilotSourceIdentity) async throws -> [PilotDisclosureInput] { rows }
    }

    private func buy(_ key: String, _ symbol: String, _ amount: Double) -> PilotDisclosureInput {
        PilotDisclosureInput(sourceKey: key, symbol: symbol, side: .buy, instrument: .stock, transactionDate: "2026-06-01", disclosureDate: "2026-07-01", amountMin: amount, amountMax: amount, shares: nil, marketValue: nil, period: nil)
    }

    @Test("first ingest writes version 1; the same rows again write nothing")
    func idempotent() async throws {
        try await withApp { app in
            let pilot = try await makePilot(on: app.db)
            let service = PilotIngestionService(politicians: StubSource(rows: [buy("a", "AAPL", 1_000), buy("b", "MSFT", 3_000)]), funds: nil)
            #expect(try await service.ingest(pilot: pilot, now: now, on: app.db) == .newVersion(1))
            #expect(try await service.ingest(pilot: pilot, now: now, on: app.db) == .unchanged)
            #expect(try await PilotDisclosureRecord.query(on: app.db).filter(\.$pilotId == pilot.requireID()).count() == 2)
            let v1 = try #require(try await PilotBookVersion.query(on: app.db).filter(\.$pilotId == pilot.requireID()).first())
            #expect(v1.weights == ["AAPL": 0.25, "MSFT": 0.75])
        }
    }

    @Test("a new disclosure writes the next version")
    func newVersion() async throws {
        try await withApp { app in
            let pilot = try await makePilot(on: app.db)
            _ = try await PilotIngestionService(politicians: StubSource(rows: [buy("a", "AAPL", 1_000)]), funds: nil).ingest(pilot: pilot, now: now, on: app.db)
            let outcome = try await PilotIngestionService(politicians: StubSource(rows: [buy("a", "AAPL", 1_000), buy("c", "KO", 1_000)]), funds: nil).ingest(pilot: pilot, now: now, on: app.db)
            #expect(outcome == .newVersion(2))
        }
    }
```

- [ ] **Step 2: Run the tests and confirm they fail.** Run `swift test --filter PilotIngestionServiceTests`. Expected: compile failure.

- [ ] **Step 3: Implement `PilotIngestionService.swift`.**

```swift
import Fluent
import Foundation
import SQLKit
import StockPlanShared

enum PilotIngestOutcome: Equatable {
    case unchanged
    case newVersion(Int)
}

/// Pulls a pilot's disclosures, stores the new ones, and writes a new book
/// version only when something was new. Re-running on unchanged data is a
/// no-op, guaranteed by unique (pilot_id, source_key).
struct PilotIngestionService: Sendable {
    private let politicians: any PilotDisclosureSource
    private let funds: (any PilotDisclosureSource)?

    init(politicians: any PilotDisclosureSource, funds: (any PilotDisclosureSource)?) {
        self.politicians = politicians
        self.funds = funds
    }

    func ingest(pilot: Pilot, now: Date, on db: any Database) async throws -> PilotIngestOutcome {
        let pilotId = try pilot.requireID()
        let source: (any PilotDisclosureSource)? = pilot.pilotKind == .politician ? politicians : funds
        guard let source, let sql = db as? any SQLDatabase else { return .unchanged }

        let rows = try await source.disclosures(for: PilotSourceIdentity(pilot))
        var inserted = 0
        for row in rows {
            let result = try await sql.raw("""
            INSERT INTO pilot_disclosures (pilot_id, source_key, symbol, side, instrument, transaction_date, disclosure_date,
                                           amount_min, amount_max, shares, market_value, period, discovered_at)
            VALUES (\(bind: pilotId), \(bind: row.sourceKey), \(bind: row.symbol), \(bind: row.side.rawValue), \(bind: row.instrument.rawValue),
                    \(bind: row.transactionDate), \(bind: row.disclosureDate), \(bind: row.amountMin), \(bind: row.amountMax),
                    \(bind: row.shares), \(bind: row.marketValue), \(bind: row.period), \(bind: now))
            ON CONFLICT (pilot_id, source_key) DO NOTHING
            RETURNING id
            """).all()
            inserted += result.count
        }

        pilot.lastIngestedAt = now
        try await pilot.save(on: db)

        let latest = try await PilotBookVersion.query(on: db).filter(\.$pilotId == pilotId).sort(\.$version, .descending).first()
        guard inserted > 0 || latest == nil else { return .unchanged }

        let entries = try await PilotDisclosureRecord.query(on: db).filter(\.$pilotId == pilotId).all().compactMap { record -> PilotBookEntry? in
            guard let side = PilotTradeSide(rawValue: record.side), let instrument = PilotInstrumentKind(rawValue: record.instrument) else { return nil }
            return PilotBookEntry(symbol: record.symbol, side: side, instrument: instrument, transactionDate: record.transactionDate, amountMin: record.amountMin, amountMax: record.amountMax, marketValue: record.marketValue, period: record.period)
        }
        let book = pilot.pilotKind == .politician
            ? PilotBookBuilder.politicianBook(entries, asOf: now)
            : PilotBookBuilder.fundBook(entries)
        guard !book.weights.isEmpty else { return .unchanged }

        let next = (latest?.version ?? 0) + 1
        try await PilotBookVersion(pilotId: pilotId, version: next, computedAt: now, weights: book.weights, skippedPuts: book.skippedPuts).create(on: db)
        return .newVersion(next)
    }
}
```

- [ ] **Step 4: Write `SeedPilots.swift`.** This is the curated v1 list. Politicians are matched by bioguide ID, the `senateID` field on FMP rows. Before committing, run both checks below and correct any row that doesn't match.

**Check the bioguide IDs** against the official legislator list:

```bash
curl -s -o /tmp/leg-current.yaml https://raw.githubusercontent.com/unitedstates/congress-legislators/main/legislators-current.yaml
curl -s -o /tmp/leg-hist.yaml https://raw.githubusercontent.com/unitedstates/congress-legislators/main/legislators-historical.yaml
for id in P000197 C001120 G000583 K000389 M001157 G000596 H001082 G000599 M001217 W000797 T000278 M001190 C001047 W000802 S001217; do
  printf "%s " $id; grep -h -A4 "bioguide: $id" /tmp/leg-current.yaml /tmp/leg-hist.yaml | grep -m1 "official_full" || echo MISSING
done
```

**Check the CIKs** on `https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=<cik>&type=13F-HR`. Each must list 13F-HR filings under the expected name. Use `curl -s -A "Norviq ops@norviq.org" -o /tmp/cik.html …` and grep the company name.

```swift
import Fluent
import FluentSQL

/// The curated v1 pilots. Politicians are matched by bioguide ID (FMP's
/// `senateID`); aliases are a fallback for rows that arrive without one.
/// Funds are 13F filers small enough to map through unauthenticated OpenFIGI.
struct SeedPilots: AsyncMigration {
    private struct Row {
        let kind, slug, name: String
        let chamber, bioguide, cik: String?
        let aliases: [String]
    }

    private static func politician(_ slug: String, _ name: String, _ chamber: String, _ bioguide: String, _ aliases: [String]) -> Row {
        Row(kind: "politician", slug: slug, name: name, chamber: chamber, bioguide: bioguide, cik: nil, aliases: aliases)
    }

    private static func fund(_ slug: String, _ name: String, _ cik: String) -> Row {
        Row(kind: "fund", slug: slug, name: name, chamber: nil, bioguide: nil, cik: cik, aliases: [])
    }

    private static let rows: [Row] = [
        politician("nancy-pelosi", "Nancy Pelosi", "house", "P000197", ["Nancy Pelosi"]),
        politician("dan-crenshaw", "Dan Crenshaw", "house", "C001120", ["Daniel Crenshaw", "Dan Crenshaw"]),
        politician("josh-gottheimer", "Josh Gottheimer", "house", "G000583", ["Josh Gottheimer", "Joshua Gottheimer"]),
        politician("ro-khanna", "Ro Khanna", "house", "K000389", ["Ro Khanna", "Rohit Khanna"]),
        politician("michael-mccaul", "Michael McCaul", "house", "M001157", ["Michael McCaul", "Michael T. McCaul"]),
        politician("marjorie-taylor-greene", "Marjorie Taylor Greene", "house", "G000596", ["Marjorie Taylor Greene", "Marjorie Greene"]),
        politician("kevin-hern", "Kevin Hern", "house", "H001082", ["Kevin Hern"]),
        politician("daniel-goldman", "Daniel Goldman", "house", "G000599", ["Daniel Goldman", "Dan Goldman"]),
        politician("jared-moskowitz", "Jared Moskowitz", "house", "M001217", ["Jared Moskowitz"]),
        politician("debbie-wasserman-schultz", "Debbie Wasserman Schultz", "house", "W000797", ["Debbie Wasserman Schultz"]),
        politician("tommy-tuberville", "Tommy Tuberville", "senate", "T000278", ["Tommy Tuberville", "Thomas Tuberville"]),
        politician("markwayne-mullin", "Markwayne Mullin", "senate", "M001190", ["Markwayne Mullin"]),
        politician("shelley-moore-capito", "Shelley Moore Capito", "senate", "C001047", ["Shelley Moore Capito", "Shelley Capito"]),
        politician("sheldon-whitehouse", "Sheldon Whitehouse", "senate", "W000802", ["Sheldon Whitehouse"]),
        politician("rick-scott", "Rick Scott", "senate", "S001217", ["Rick Scott", "Richard Scott"]),
        fund("berkshire-hathaway", "Berkshire Hathaway", "0001067983"),
        fund("pershing-square", "Pershing Square", "0001336528"),
        fund("scion-asset-management", "Scion Asset Management", "0001649339"),
        fund("appaloosa", "Appaloosa Management", "0001656456"),
        fund("duquesne-family-office", "Duquesne Family Office", "0001536411"),
        fund("third-point", "Third Point", "0001040273"),
        fund("baupost", "Baupost Group", "0001061768"),
        fund("himalaya-capital", "Himalaya Capital", "0001709323"),
    ]

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        for row in Self.rows {
            let aliases = String(data: try JSONEncoder().encode(row.aliases), encoding: .utf8) ?? "[]"
            try await sql.raw("""
            INSERT INTO pilots (kind, slug, display_name, chamber, bioguide_id, cik, name_aliases)
            VALUES (\(bind: row.kind), \(bind: row.slug), \(bind: row.name), \(bind: row.chamber), \(bind: row.bioguide), \(bind: row.cik), \(bind: aliases)::jsonb)
            ON CONFLICT (slug) DO NOTHING
            """).run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        let slugs = Self.rows.map(\.slug)
        try await sql.raw("DELETE FROM pilots WHERE slug = ANY(\(bind: slugs))").run()
    }
}
```
Register it after `CreatePilotTables()`: `app.migrations.add(SeedPilots())`.

- [ ] **Step 5: Run the tests and confirm they pass.** Run `swift test --filter PilotIngestionServiceTests` and `swift test --filter PilotSchemaTests`. Expected: all pass. The seed must not break the schema tests, because their slugs use random suffixes.

- [ ] **Step 6: Commit**

```bash
git add Sources/StockPlanBackend/Pilots/PilotIngestionService.swift Sources/StockPlanBackend/Migrations/SeedPilots.swift Sources/StockPlanBackend/ConfigureBootstrap.swift Tests/StockPlanBackendTests/PilotIngestionServiceTests.swift
git commit -m "feat(pilots): ingest disclosures into versioned books; seed curated pilots"
```

---

### Task 11: Jobs — ingestion, mirroring and follow snapshots

**Files:**
- Create: `Sources/StockPlanBackend/Pilots/PilotJobs.swift`
- Modify: `Sources/StockPlanBackend/configure.swift` (after the `PortfolioSnapshotJob` registration, ~line 463)
- Test: `Tests/StockPlanBackendTests/PilotJobsTests.swift`

**Interfaces:**
- Consumes:
  - `PilotIngestionService` (Task 10), `PilotMirrorService` (Task 8)
  - `PortfolioSnapshotValuator.value(userId:portfolioListId:asOf:pricing:on:)` and `PortfolioSnapshotValuator.startOfDay(_:)`
  - `BackgroundJobState`, `JobLock.runAsLeader(_:name:_:)`
  - `app.marketDataService.quote(symbol:on:)`, `app.marketDataService.fmpProvider`
  - `CsvPortfolioImportService().manualEntryInstrument(symbol:on:db:)`
  - `app.usageCounterService.enforceResourceLimit`
- Produces:

```swift
final class PilotIngestionJob: LifecycleHandler { static let fundRefreshSeconds: TimeInterval; init(intervalSeconds: Int64 = 3_600); func runOnceAsLeader(_ app: Application, service: PilotIngestionService) async }
final class PilotMirrorJob: LifecycleHandler { init(intervalSeconds: Int64 = 3_600); func runOnceAsLeader(_ app: Application, mirror: PilotMirrorService, now: Date) async }
enum PilotWiring { static func ingestion(_ app: Application) -> PilotIngestionService?; static func mirror(_ app: Application) -> PilotMirrorService }
```

- [ ] **Step 1: Write the failing test.** Copy the `withApp`, `makeUser`, `makePilot` and `makeHypothetical` helpers.

```swift
    @Test("mirror job catches a lagging follow up to the latest version and writes one snapshot per day")
    func catchUpAndSnapshot() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let listId = try await makeHypothetical(userId: userId, on: app.db)
            let account = try await ManualAccountResolver.findOrCreate(userId: userId, portfolioId: listId, on: app.db)
            try await CashBalance(accountId: account.requireID(), currency: account.baseCurrency, balance: 1_000, asOf: now).create(on: app.db)
            let follow = PilotFollow(userId: userId, pilotId: try pilot.requireID(), targetKind: .portfolio, portfolioListId: listId, startingCapital: 1_000)
            try await follow.create(on: app.db)
            try await PilotBookVersion(pilotId: try pilot.requireID(), version: 1, computedAt: now, weights: ["AAPL": 1.0], skippedPuts: 0).create(on: app.db)
            try await PilotBookVersion(pilotId: try pilot.requireID(), version: 2, computedAt: now, weights: ["MSFT": 1.0], skippedPuts: 0).create(on: app.db)

            let mirror = PilotMirrorService(quote: { _ in 100 }, instrument: { _ in nil }, watchlistLimit: { _, _, _ in })
            let job = PilotMirrorJob()
            await job.runOnceAsLeader(app, mirror: mirror, now: now)
            await job.runOnceAsLeader(app, mirror: mirror, now: now)

            #expect(try await PilotFollow.find(follow.requireID(), on: app.db)?.appliedVersion == 2)
            let symbols = try await Stock.query(on: app.db).filter(\.$portfolioListId == listId).all().map(\.symbol)
            #expect(symbols == ["MSFT"])
            #expect(try await PilotFollowSnapshot.query(on: app.db).filter(\.$followId == follow.requireID()).count() == 1)
        }
    }

    @Test("ingestion job reads a fund at most once a day; politicians every run")
    func fundCadence() async throws {
        try await withApp { app in
            let fund = Pilot(kind: .fund, slug: "f-\(UUID().uuidString.prefix(6))", displayName: "Fund", cik: "0000000001")
            fund.lastIngestedAt = Date().addingTimeInterval(-3_600)
            try await fund.create(on: app.db)
            let politician = try await makePilot(on: app.db)
            let calls = CallLog()
            let stub = CountingSource(log: calls)
            await PilotIngestionJob().runOnceAsLeader(app, service: PilotIngestionService(politicians: stub, funds: stub))
            let seen = await calls.slugsSeen
            // Seeded pilots are active too; assert on this test's fund by CIK.
            #expect(seen.contains("politician"))
            #expect(!seen.contains("0000000001"))
            _ = politician
        }
    }

    @Test("paused follows are not mirrored")
    func pausedSkipped() async throws {
        try await withApp { app in
            let userId = try await makeUser(on: app.db)
            let pilot = try await makePilot(on: app.db)
            let listId = try await makeHypothetical(userId: userId, on: app.db)
            let follow = PilotFollow(userId: userId, pilotId: try pilot.requireID(), targetKind: .portfolio, portfolioListId: listId, startingCapital: 1_000)
            follow.status = PilotFollowStatus.paused.rawValue
            try await follow.create(on: app.db)
            try await PilotBookVersion(pilotId: try pilot.requireID(), version: 1, computedAt: now, weights: ["AAPL": 1.0], skippedPuts: 0).create(on: app.db)
            await PilotMirrorJob().runOnceAsLeader(app, mirror: PilotMirrorService(quote: { _ in 100 }, instrument: { _ in nil }, watchlistLimit: { _, _, _ in }), now: now)
            #expect(try await PilotFollow.find(follow.requireID(), on: app.db)?.appliedVersion == 0)
        }
    }
```

Helpers for `fundCadence` (same file, file scope):

```swift
private actor CallLog {
    var slugsSeen: [String] = []
    func record(_ kind: String) { slugsSeen.append(kind) }
}

private struct CountingSource: PilotDisclosureSource {
    let log: CallLog
    func disclosures(for pilot: PilotSourceIdentity) async throws -> [PilotDisclosureInput] {
        await log.record(pilot.cik ?? pilot.kind.rawValue)
        return []
    }
}
```
- [ ] **Step 2: Run the tests and confirm they fail.** Run `swift test --filter PilotJobsTests`. Expected: compile failure.

- [ ] **Step 3: Implement `PilotJobs.swift`.** This copies the scheduling shape of `Portfolio/PortfolioSnapshotJob.swift:19-55`.

```swift
import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Builds the live services from the app's configured providers.
enum PilotWiring {
    static func request(_ app: Application) -> Request {
        Request(application: app, on: app.eventLoopGroup.next())
    }

    /// Free sources only: FMP's latest congress feeds (page 0, 25 rows) and
    /// SEC EDGAR 13F filings with OpenFIGI CUSIP mapping.
    static func ingestion(_ app: Application) -> PilotIngestionService? {
        guard let fmp = app.marketDataService.fmpProvider else { return nil }
        let congress = FMPCongressPilotSource { chamber in
            let req = request(app)
            return chamber == "senate"
                ? try await fmp.latestSenateTrades(limit: FMPCongressPilotSource.feedLimit, on: req)
                : try await fmp.latestHouseTrades(limit: FMPCongressPilotSource.feedLimit, on: req)
        }
        let userAgent = Environment.get("SEC_EDGAR_USER_AGENT") ?? "Norviq ops@norviq.org"
        let resolver = CusipSymbolResolver(
            post: { body in
                let response = try await app.client.post("https://api.openfigi.com/v3/mapping") { req in
                    req.headers.replaceOrAdd(name: .contentType, value: "application/json")
                    req.body = ByteBuffer(data: body)
                    req.timeout = .seconds(30)
                }
                guard response.status == .ok, let buffer = response.body else {
                    throw Abort(.badGateway, reason: "OpenFIGI returned \(response.status.code)")
                }
                return Data(buffer: buffer)
            },
            pause: { try? await Task.sleep(nanoseconds: 2_500_000_000) }
        )
        let funds = SECEdgar13FPilotSource(
            get: { url in
                let response = try await app.client.get(URI(string: url)) { req in
                    req.headers.replaceOrAdd(name: .userAgent, value: userAgent)
                    req.timeout = .seconds(30)
                }
                guard response.status == .ok, let buffer = response.body else {
                    throw Abort(.badGateway, reason: "EDGAR returned \(response.status.code) for \(url)")
                }
                return Data(buffer: buffer)
            },
            resolve: { cusips in try await resolver.resolve(cusips, on: app.db) }
        )
        return PilotIngestionService(politicians: congress, funds: funds)
    }

    static func mirror(_ app: Application) -> PilotMirrorService {
        PilotMirrorService(
            quote: { symbol in try await app.marketDataService.quote(symbol: symbol, on: request(app)).currentPrice },
            instrument: { symbol in
                try? await CsvPortfolioImportService().manualEntryInstrument(symbol: symbol, on: request(app), db: app.db).id
            },
            watchlistLimit: { userId, current, db in
                try await app.usageCounterService.enforceResourceLimit(.watchlistItems, userId: userId, currentCount: current, adding: 1, on: db)
            }
        )
    }
}

/// Pulls disclosures for every active pilot. Hourly, because the free congress
/// feed shows only the newest 25 rows per chamber and older rows scroll off.
/// Funds file quarterly, so each fund is read at most once a day.
final class PilotIngestionJob: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let state = BackgroundJobState()

    static let fundRefreshSeconds: TimeInterval = 86_400

    init(intervalSeconds: Int64 = 3_600) {
        self.intervalSeconds = max(900, intervalSeconds)
    }

    func didBoot(_ app: Application) throws {
        let scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: .seconds(240), delay: .seconds(intervalSeconds)) { _ in
            guard self.state.begin() else { return }
            let task = Task {
                defer { self.state.finish() }
                guard let service = PilotWiring.ingestion(app) else { return }
                _ = await JobLock.runAsLeader(app, name: "pilot_ingestion_job") {
                    await self.runOnceAsLeader(app, service: service)
                }
            }
            self.state.track(task: task)
        }
        state.set(scheduled: scheduled)
    }

    func shutdown(_: Application) { state.stopAcceptingRuns() }
    func shutdownAsync(_: Application) async { await state.stopAndDrain() }

    func runOnceAsLeader(_ app: Application, service: PilotIngestionService) async {
        do {
            let pilots = try await Pilot.query(on: app.db).filter(\.$active == true).all()
            let now = Date()
            for pilot in pilots where !Task.isCancelled {
                if pilot.pilotKind == .fund, let last = pilot.lastIngestedAt,
                   now.timeIntervalSince(last) < Self.fundRefreshSeconds {
                    continue
                }
                do {
                    let outcome = try await service.ingest(pilot: pilot, now: now, on: app.db)
                    if case let .newVersion(v) = outcome {
                        app.logger.info("pilot_ingestion new_version", metadata: ["pilot": .string(pilot.slug), "version": .stringConvertible(v)])
                    }
                } catch {
                    app.logger.warning("pilot_ingestion failed", metadata: ["pilot": .string(pilot.slug), "error": .string(String(reflecting: error))])
                }
            }
        } catch {
            app.logger.error("pilot_ingestion run failed", metadata: ["error": .string(String(reflecting: error))])
        }
    }
}

/// Brings every active follow up to its pilot's latest book, then records one
/// value snapshot per follow per day. It applies only the latest version, never
/// the ones in between: rebalancing works from current holdings, so skipping
/// a version loses nothing.
final class PilotMirrorJob: LifecycleHandler, @unchecked Sendable {
    private let intervalSeconds: Int64
    private let state = BackgroundJobState()

    init(intervalSeconds: Int64 = 3_600) {
        self.intervalSeconds = max(300, intervalSeconds)
    }

    func didBoot(_ app: Application) throws {
        let scheduled = app.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: .seconds(300), delay: .seconds(intervalSeconds)) { _ in
            guard self.state.begin() else { return }
            let task = Task {
                defer { self.state.finish() }
                let mirror = PilotWiring.mirror(app)
                _ = await JobLock.runAsLeader(app, name: "pilot_mirror_job") {
                    await self.runOnceAsLeader(app, mirror: mirror, now: Date())
                }
            }
            self.state.track(task: task)
        }
        state.set(scheduled: scheduled)
    }

    func shutdown(_: Application) { state.stopAcceptingRuns() }
    func shutdownAsync(_: Application) async { await state.stopAndDrain() }

    func runOnceAsLeader(_ app: Application, mirror: PilotMirrorService, now: Date) async {
        do {
            let follows = try await PilotFollow.query(on: app.db).filter(\.$status == PilotFollowStatus.active.rawValue).all()
            for follow in follows where !Task.isCancelled {
                do {
                    try await catchUp(follow, mirror: mirror, now: now, on: app.db)
                    if follow.target == .portfolio {
                        try await snapshot(follow, now: now, on: app.db)
                    }
                } catch {
                    app.logger.warning("pilot_mirror failed", metadata: ["follow_id": .string(follow.id?.uuidString ?? "?"), "error": .string(String(reflecting: error))])
                }
            }
        } catch {
            app.logger.error("pilot_mirror run failed", metadata: ["error": .string(String(reflecting: error))])
        }
    }

    private func catchUp(_ follow: PilotFollow, mirror: PilotMirrorService, now: Date, on db: any Database) async throws {
        guard let pilot = try await Pilot.find(follow.pilotId, on: db),
              let latest = try await PilotBookVersion.query(on: db).filter(\.$pilotId == follow.pilotId).sort(\.$version, .descending).first(),
              latest.version > follow.appliedVersion
        else { return }
        let previous = follow.appliedVersion > 0
            ? try await PilotBookVersion.query(on: db).filter(\.$pilotId == follow.pilotId).filter(\.$version == follow.appliedVersion).first()
            : nil
        if try await mirror.apply(follow: follow, pilot: pilot, version: latest, previous: previous, now: now, on: db) {
            follow.appliedVersion = latest.version
        }
    }

    /// One row per follow per day. Kept apart from portfolio_value_snapshots
    /// on purpose: that table holds only real portfolios.
    private func snapshot(_ follow: PilotFollow, now: Date, on db: any Database) async throws {
        guard let listId = follow.portfolioListId else { return }
        let day = PortfolioSnapshotValuator.startOfDay(now)
        let exists = try await PilotFollowSnapshot.query(on: db).filter(\.$followId == follow.requireID()).filter(\.$capturedOn == day).first()
        guard exists == nil else { return }
        let valuation = try await PortfolioSnapshotValuator().value(userId: follow.userId, portfolioListId: listId, asOf: now, pricing: .live, on: db)
        try await PilotFollowSnapshot(followId: follow.requireID(), capturedOn: day, value: valuation.totalValue, cash: valuation.cashBalance).create(on: db)
    }
}
```

- [ ] **Step 4: Register the jobs behind the flag.** In `configure.swift`, after the `PortfolioSnapshotJob` block:

```swift
    // Pilot follows: simulated copy-trading of curated politicians and 13F
    // funds. Off unless PILOTS_ENABLED; the controller 404s too.
    if envBool("PILOTS_ENABLED", default: false) {
        app.lifecycle.use(PilotIngestionJob(
            intervalSeconds: Environment.get("PILOT_INGESTION_INTERVAL_SECONDS").flatMap(Int64.init) ?? 3_600
        ))
        app.lifecycle.use(PilotMirrorJob(
            intervalSeconds: Environment.get("PILOT_MIRROR_INTERVAL_SECONDS").flatMap(Int64.init) ?? 3_600
        ))
    }
```

- [ ] **Step 5: Run the tests and confirm they pass.** Run `swift test --filter PilotJobsTests`. Expected: 2 passed. The snapshot test needs `PortfolioSnapshotValuator.value` to succeed with no stored bars: it values holdings from `latestQuotes`, so an absent quote gives a cash-only value. That's fine; the test asserts only the row count.

- [ ] **Step 6: Commit**

```bash
git add Sources/StockPlanBackend/Pilots/PilotJobs.swift Sources/StockPlanBackend/configure.swift Tests/StockPlanBackendTests/PilotJobsTests.swift
git commit -m "feat(pilots): ingestion and mirror jobs behind PILOTS_ENABLED"
```

---

### Task 12: `PilotController` + routes + OpenAPI

**Files:**
- Create: `Sources/StockPlanBackend/Pilots/PilotController.swift`
- Modify: `Sources/StockPlanBackend/routes.swift:~108`
- Modify: `Sources/StockPlanBackend/Shared/StockPlanShared+Content.swift` (Content conformances)
- Modify: `Sources/StockPlanBackend/openapi.yaml`
- Test: `Tests/StockPlanBackendTests/PilotControllerTests.swift`

**Interfaces:**
- Consumes: everything above, plus `req.entitlementResolver.resolve(userId:on:)` and `SessionToken`, as in `Portfolio/PortfolioManagementController.swift:13-15,52`.
- Produces:
  - `GET /v1/pilots` → `[PilotSummary]`
  - `GET /v1/pilots/:slug` → `PilotDetail`
  - `GET /v1/pilot-follows` → `[PilotFollowResponse]`
  - `POST /v1/pilot-follows` → `PilotFollowResponse` (201)
  - `GET /v1/pilot-follows/:id` → `PilotFollowResponse`
  - `PATCH /v1/pilot-follows/:id` → `PilotFollowResponse`
  - `DELETE /v1/pilot-follows/:id` → 204
  - `GET /v1/pilot-follows/:id/events` → `[PilotFollowEventResponse]`
  - `GET /v1/pilot-follows/:id/snapshots` → `[PilotFollowSnapshotResponse]`

- [ ] **Step 1: Write the failing tests.** Registration and login follow `InsightsServiceTests.registerTestUser` (copy it). Set the flag for the suite.

```swift
@Suite("PilotController", .serialized)
struct PilotControllerTests {
    // withApp + registerTestUser copied from InsightsServiceTests.

    @Test("flag off: 404")
    func flagOff() async throws {
        unsetenv("PILOTS_ENABLED")
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)
            try await app.testing().test(.GET, "v1/pilots", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("flag on: list pilots, follow into a watchlist, read events, pause, delete")
    func lifecycle() async throws {
        setenv("PILOTS_ENABLED", "true", 1)
        defer { unsetenv("PILOTS_ENABLED") }
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let pilot = try #require(try await Pilot.query(on: app.db).filter(\.$slug == "nancy-pelosi").first())
            try await PilotBookVersion(pilotId: pilot.requireID(), version: 1, computedAt: Date(), weights: ["NVDA": 1.0], skippedPuts: 0).create(on: app.db)

            try await app.testing().test(.GET, "v1/pilots", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res in
                #expect(res.status == .ok)
                let pilots = try res.content.decode([PilotSummary].self)
                #expect(pilots.contains { $0.slug == "nancy-pelosi" && $0.holdingsCount == 1 })
            }
            try await app.testing().test(.GET, "v1/pilots/nancy-pelosi", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res in
                let detail = try res.content.decode(PilotDetail.self)
                #expect(detail.weights == [PilotWeight(symbol: "NVDA", weight: 1.0)])
                #expect(detail.lagNote.contains("45 days"))
            }

            var created: PilotFollowResponse?
            try await app.testing().test(.POST, "v1/pilot-follows", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(PilotFollowCreateRequest(pilotSlug: "nancy-pelosi", targetKind: .watchlist, portfolioListId: nil, watchlistListId: nil, startingCapital: nil))
            }) { res in
                #expect(res.status == .created)
                created = try res.content.decode(PilotFollowResponse.self)
            }
            let follow = try #require(created)
            #expect(follow.appliedVersion == 1)

            try await app.testing().test(.GET, "v1/pilot-follows/\(follow.id)/events", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res in
                let events = try res.content.decode([PilotFollowEventResponse].self)
                #expect(events.map(\.kind) == ["watch_added"])
            }
            try await app.testing().test(.PATCH, "v1/pilot-follows/\(follow.id)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(PilotFollowUpdateRequest(status: .paused))
            }) { res in
                #expect(try res.content.decode(PilotFollowResponse.self).status == .paused)
            }
            try await app.testing().test(.DELETE, "v1/pilot-follows/\(follow.id)", beforeRequest: { $0.headers.bearerAuthorization = .init(token: token) }) { res in
                #expect(res.status == .noContent)
            }
            // Deleting the follow keeps what it wrote.
            #expect(try await WatchlistItem.query(on: app.db).filter(\.$userId == userId).count() == 1)
        }
    }

    @Test("another user's follow is a 404")
    func ownership() async throws {
        setenv("PILOTS_ENABLED", "true", 1)
        defer { unsetenv("PILOTS_ENABLED") }
        try await withApp { app in
            let (_, ownerId) = try await registerTestUser(app: app)
            let (intruder, _) = try await registerTestUser(app: app)
            let pilot = try #require(try await Pilot.query(on: app.db).filter(\.$slug == "nancy-pelosi").first())
            let list = WatchlistList(userId: ownerId, name: "Owner feed")
            try await list.create(on: app.db)
            let follow = PilotFollow(userId: ownerId, pilotId: try pilot.requireID(), targetKind: .watchlist, watchlistListId: try list.requireID())
            try await follow.create(on: app.db)
            try await app.testing().test(.GET, "v1/pilot-follows/\(follow.requireID())", beforeRequest: { $0.headers.bearerAuthorization = .init(token: intruder) }) { res in
                #expect(res.status == .notFound)
            }
        }
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail.** Run `swift test --filter PilotControllerTests`. Expected: compile failure.

- [ ] **Step 3: Add the Content conformances** in `Shared/StockPlanShared+Content.swift`, matching the existing `extension PortfolioListResponse: @retroactive Content {}` lines:

```swift
extension PilotSummary: @retroactive Content {}
extension PilotDetail: @retroactive Content {}
extension PilotFollowCreateRequest: @retroactive Content {}
extension PilotFollowUpdateRequest: @retroactive Content {}
extension PilotFollowResponse: @retroactive Content {}
extension PilotFollowEventResponse: @retroactive Content {}
extension PilotFollowSnapshotResponse: @retroactive Content {}
```

- [ ] **Step 4: Implement the controller.**

```swift
import Fluent
import Foundation
import StockPlanShared
import Vapor

struct PilotController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = protected.grouped(ScopeRequirementMiddleware(.portfolioRead))
        let write = protected.grouped(ScopeRequirementMiddleware(.portfolioWrite))
        read.get("pilots", use: listPilots)
        read.get("pilots", ":slug", use: pilotDetail)
        read.get("pilot-follows", use: listFollows)
        read.get("pilot-follows", ":followId", use: getFollow)
        read.get("pilot-follows", ":followId", "events", use: events)
        read.get("pilot-follows", ":followId", "snapshots", use: snapshots)
        write.post("pilot-follows", use: createFollow)
        write.patch("pilot-follows", ":followId", use: updateFollow)
        write.delete("pilot-follows", ":followId", use: deleteFollow)
    }

    @Sendable
    func listPilots(req: Request) async throws -> [PilotSummary] {
        try requireEnabled()
        let pilots = try await Pilot.query(on: req.db).filter(\.$active == true).sort(\.$displayName).all()
        var out: [PilotSummary] = []
        for pilot in pilots {
            out.append(try await summary(pilot, on: req.db))
        }
        return out
    }

    @Sendable
    func pilotDetail(req: Request) async throws -> PilotDetail {
        try requireEnabled()
        guard let slug = req.parameters.get("slug"),
              let pilot = try await Pilot.query(on: req.db).filter(\.$slug == slug).filter(\.$active == true).first()
        else { throw Abort(.notFound, reason: "Pilot not found.") }
        let latest = try await latestVersion(pilot, on: req.db)
        let recent = try await PilotDisclosureRecord.query(on: req.db)
            .filter(\.$pilotId == pilot.requireID())
            .sort(\.$transactionDate, .descending)
            .sort(\.$discoveredAt, .descending)
            .limit(25)
            .all()
        return PilotDetail(
            pilot: try await summary(pilot, on: req.db),
            weights: (latest?.weights ?? [:]).sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { PilotWeight(symbol: $0.key, weight: $0.value) },
            skippedPuts: latest?.skippedPuts ?? 0,
            recentDisclosures: recent.map {
                PilotDisclosureItem(symbol: $0.symbol, side: $0.side, instrument: $0.instrument, transactionDate: $0.transactionDate, disclosureDate: $0.disclosureDate, amountMin: $0.amountMin, amountMax: $0.amountMax, period: $0.period)
            },
            lagNote: Self.lagNote(for: pilot.pilotKind)
        )
    }

    @Sendable
    func listFollows(req: Request) async throws -> [PilotFollowResponse] {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        let follows = try await PilotFollow.query(on: req.db).filter(\.$userId == session.userId).sort(\.$createdAt, .descending).all()
        var out: [PilotFollowResponse] = []
        for follow in follows {
            out.append(try await response(follow, on: req.db))
        }
        return out
    }

    @Sendable
    func getFollow(req: Request) async throws -> PilotFollowResponse {
        try requireEnabled()
        return try await response(try await ownedFollow(req), on: req.db)
    }

    @Sendable
    func createFollow(req: Request) async throws -> Response {
        try requireEnabled()
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(PilotFollowCreateRequest.self)
        let entitlement = try await req.entitlementResolver.resolve(userId: session.userId, on: req.db)
        let follow = try await PilotFollowService(mirror: PilotWiring.mirror(req.application))
            .create(payload, userId: session.userId, entitlement: entitlement, now: Date(), on: req.db)
        return try await response(follow, on: req.db).encodeResponse(status: .created, for: req)
    }

    @Sendable
    func updateFollow(req: Request) async throws -> PilotFollowResponse {
        try requireEnabled()
        let follow = try await ownedFollow(req)
        let payload = try req.content.decode(PilotFollowUpdateRequest.self)
        follow.status = payload.status.rawValue
        try await follow.save(on: req.db)
        return try await response(follow, on: req.db)
    }

    /// Stops the follow. The portfolio or watchlist it wrote to is kept: those
    /// are the user's now.
    @Sendable
    func deleteFollow(req: Request) async throws -> HTTPStatus {
        try requireEnabled()
        try await ownedFollow(req).delete(on: req.db)
        return .noContent
    }

    @Sendable
    func events(req: Request) async throws -> [PilotFollowEventResponse] {
        try requireEnabled()
        let follow = try await ownedFollow(req)
        return try await PilotFollowEvent.query(on: req.db)
            .filter(\.$followId == follow.requireID())
            .sort(\.$bookVersion, .descending)
            .sort(\.$symbol)
            .limit(500)
            .all()
            .map {
                PilotFollowEventResponse(id: try $0.requireID().uuidString, bookVersion: $0.bookVersion, kind: $0.kind, symbol: $0.symbol, quantity: $0.quantity, price: $0.price, pricedAt: Self.iso($0.pricedAt), note: $0.note)
            }
    }

    @Sendable
    func snapshots(req: Request) async throws -> [PilotFollowSnapshotResponse] {
        try requireEnabled()
        let follow = try await ownedFollow(req)
        return try await PilotFollowSnapshot.query(on: req.db)
            .filter(\.$followId == follow.requireID())
            .sort(\.$capturedOn)
            .all()
            .map { PilotFollowSnapshotResponse(date: Self.day($0.capturedOn), value: $0.value, cash: $0.cash) }
    }

    // MARK: - Helpers

    static func lagNote(for kind: PilotKind) -> String {
        switch kind {
        case .politician:
            "Congressional trades are disclosed up to 45 days after they happen. Simulated trades are priced when Norviq sees the disclosure, not on the original trade date. No real money is invested."
        case .fund:
            "13F filings arrive up to 135 days after the positions they report. Simulated trades are priced when Norviq sees the filing. No real money is invested."
        }
    }

    private func requireEnabled() throws {
        guard envBool("PILOTS_ENABLED", default: false) else { throw Abort(.notFound) }
    }

    private func ownedFollow(_ req: Request) async throws -> PilotFollow {
        let session = try req.auth.require(SessionToken.self)
        guard let raw = req.parameters.get("followId"), let id = UUID(uuidString: raw),
              let follow = try await PilotFollow.query(on: req.db).filter(\.$id == id).filter(\.$userId == session.userId).first()
        else { throw Abort(.notFound, reason: "Follow not found.") }
        return follow
    }

    private func latestVersion(_ pilot: Pilot, on db: any Database) async throws -> PilotBookVersion? {
        try await PilotBookVersion.query(on: db).filter(\.$pilotId == pilot.requireID()).sort(\.$version, .descending).first()
    }

    private func summary(_ pilot: Pilot, on db: any Database) async throws -> PilotSummary {
        let latest = try await latestVersion(pilot, on: db)
        return PilotSummary(slug: pilot.slug, displayName: pilot.displayName, kind: pilot.pilotKind, chamber: pilot.chamber, updatedAt: latest.map { Self.iso($0.computedAt) }, holdingsCount: latest?.weights.count ?? 0)
    }

    private func response(_ follow: PilotFollow, on db: any Database) async throws -> PilotFollowResponse {
        guard let pilot = try await Pilot.find(follow.pilotId, on: db) else { throw Abort(.notFound, reason: "Pilot not found.") }
        return PilotFollowResponse(
            id: try follow.requireID().uuidString,
            pilot: try await summary(pilot, on: db),
            targetKind: follow.target,
            portfolioListId: follow.portfolioListId?.uuidString,
            watchlistListId: follow.watchlistListId?.uuidString,
            startingCapital: follow.startingCapital,
            currency: follow.currency,
            status: PilotFollowStatus(rawValue: follow.status) ?? .active,
            appliedVersion: follow.appliedVersion,
            createdAt: Self.iso(follow.createdAt ?? Date())
        )
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 5: Register the routes.** In `routes.swift`, after the `BrokerController` registration (~line 107):

```swift
    // Pilot follows write simulated trades; rate limit and dedupe retried POSTs.
    let pilotRateLimit = RateLimitMiddleware(limit: 30, interval: 60, keyPrefix: "ratelimit:pilots")
    try api.grouped(pilotRateLimit, IdempotencyMiddleware(keyPrefix: "idempotency:pilots"))
        .register(collection: PilotController())
```

- [ ] **Step 6: Document the API in OpenAPI.** In `openapi.yaml`:
  - Add a `Pilots` tag next to `Watchlist` (line ~20).
  - Add the 9 paths above, with `operationId`s `listPilots`, `getPilot`, `listPilotFollows`, `createPilotFollow`, `getPilotFollow`, `updatePilotFollow`, `deletePilotFollow`, `listPilotFollowEvents`, `listPilotFollowSnapshots`.
  - Add schemas for every DTO in Task 2, plus `exited` in the `WatchlistStatus` enum.
  - Copy the structure of the existing `/v1/watchlist` path block (~line 1085). Mark the `createPilotFollow` responses `201`, `403` (BillingUpgradeRequired), `404`, `409` and `422`.
  - Then run:

```bash
LOG_LEVEL=warning STOCKPLAN_SHARED_PATH=../norviq-shared-pilots swift test --filter OpenAPIDocsTests
```
Expected: pass.

- [ ] **Step 7: Run the controller tests and confirm they pass.** Run `swift test --filter PilotControllerTests`. Expected: 3 passed.

- [ ] **Step 8: Run the full suite.**

```bash
LOG_LEVEL=warning STOCKPLAN_SHARED_PATH=../norviq-shared-pilots swift test 2>&1 | tail -20
```
Expected: no new failures compared to `origin/main`. If unrelated tests already fail on main, record their names in the PR description.

- [ ] **Step 9: Commit**

```bash
git add Sources/StockPlanBackend/Pilots/PilotController.swift Sources/StockPlanBackend/routes.swift Sources/StockPlanBackend/Shared/StockPlanShared+Content.swift Sources/StockPlanBackend/openapi.yaml Tests/StockPlanBackendTests/PilotControllerTests.swift
git commit -m "feat(pilots): /v1/pilots and /v1/pilot-follows API behind PILOTS_ENABLED"
```

---

### Task 13: Release shared, pin the backend, add the flag to infra

These steps are outward-facing: tagging, pushing and infra PRs. **Confirm with the user before each push.**

**Files:**
- Modify: `Package.swift:9`
- Modify: `Package.resolved`
- Modify: `~/Work/production/platform/infra/apps/norviq/api/values-common.yaml`
- Modify: `~/Work/production/platform/infra/apps/norviq/api/values-staging.yaml`
- Modify: `~/Work/production/platform/infra/apps/norviq/api/values-production.yaml`

- [ ] **Step 1: Pick the version.** Run:

```bash
git -C ../norviq-shared fetch --tags -q && git -C ../norviq-shared tag --sort=-v:refname | head -3
```
The release is the next minor after the highest tag: **5.15.0** if `v5.14.0` is still the latest. The in-progress `feat/boards-dtos` branch may claim 5.15.0 first; in that case, use the next free minor.

- [ ] **Step 2: Open the shared PR, and after the user approves, tag.**

```bash
cd ../norviq-shared-pilots
git push -u origin feat/pilot-dtos
gh pr create --title "feat(pilots): pilot follow DTOs and WatchlistStatus.exited" --body "Additive. Backs norviq-backend feat/pilot-follow."
# after merge, on main:
git -C ../norviq-shared fetch origin main && git -C ../norviq-shared tag v5.15.0 origin/main && git -C ../norviq-shared push origin v5.15.0
```

- [ ] **Step 3: Pin the backend to the tag.**

```bash
cd ../norviq-backend-pilots
sed -i '' 's/exact: "5.14.0"/exact: "5.15.0"/' Package.swift
swift package resolve
LOG_LEVEL=warning swift test --filter Pilot
git add Package.swift Package.resolved
git commit -m "chore(deps): pin norviq-shared 5.15.0 for pilot follows"
```
Expected: the `Pilot*` suites pass without `STOCKPLAN_SHARED_PATH`.

- [ ] **Step 4: Add the infra flag, off everywhere.** Work in `~/Work/production/platform/infra` on a new branch. Never use the archived `norviq-infra/`. Under the `env` block of each values file, following the style of the `REBALANCING_*` keys already there:

```yaml
  PILOTS_ENABLED: "false"
```
Then commit:

```bash
git -C ~/Work/production/platform/infra checkout -b norviq/pilots-flag
git -C ~/Work/production/platform/infra commit -am "norviq: add PILOTS_ENABLED (off)"
```
Merging infra `main` deploys through ArgoCD. Open a PR and let the user merge it.

- [ ] **Step 5: Open the backend PR.**

```bash
git push -u origin feat/pilot-follow
gh pr create --title "feat(pilots): simulated pilot follows (backend)" --body "$(cat <<'EOF'
Follow a curated politician or 13F fund. Norviq mirrors that pilot's trades
as simulated trades into a hypothetical portfolio, or as a watchlist symbol feed.
No real orders. Off behind PILOTS_ENABLED.

Spec: docs/superpowers/specs/2026-10-01-pilot-follow-design.md
Plan: docs/superpowers/plans/2026-10-01-pilot-follow-backend.md
EOF
)"
```
Note: the branch was created tracking `origin/main`, so push with `-u origin feat/pilot-follow` as shown. Never use a bare `git push`.

---

## Next plans (not in this one)
- **iOS:** `Features/Pilots/` screens, plus the `financeplan` and `financeplan-brand` pin bumps to the shared tag.
- **Web:** `make generate`, `pilots.go`, `pilot_follows.go`, templ pages.
- **Rollout:** staging on, E2E on staging, production for Pro, then free users. Deploys are manual dispatch with `-f service=both`.
- **Optional MCP:** read-only tools.
