# Terminal Position Sizing (shared + backend) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Terminal Position Sizing to norviq-shared (formulas + DTOs, v5.21.0) and norviq-backend: CRUD for per-ticker terminal scenarios and autobuys, a summary endpoint, Pro-gated AI suggestions (shares outstanding / price, scenario), and assistant/MCP catalog actions.

**Architecture:**
- The formulas live once, in `StockPlanShared.TerminalMath`. The backend and iOS call the same code; derived values are never stored.
- `TerminalPositionsService` holds the validation and persistence rules. Two thin controllers sit on top of it, plus a third controller for the AI routes, which needs the AI rate limit.
- `TerminalAIAdvisor` sends one web-search chat call per suggestion and validates the JSON it gets back. It only suggests, never writes.
- `ActionCatalog+TerminalPositions` exposes four actions to the assistant and MCP. The write action is `destructive`, so every surface asks for confirmation.

**Tech Stack:** Swift 6, Vapor 4, Fluent/Postgres, Swift Testing, norviq-shared (`StockPlanShared`).

**Spec:** `docs/superpowers/specs/2026-10-09-terminal-position-sizing-design.md`. The contract (exact names): `docs/superpowers/plans/2026-10-09-terminal-contract.md`.

## Global Constraints

**Repositories and branches**
- **Backend:** work in the worktree `~/Work/production/apps/norviq/norviq-backend-terminal`, branch `feat/terminal-positions`, cut from `origin/main` at b203c11. Never touch the `norviq-backend` checkout (someone else's `feat/articles` work) or `norviq-backend-market-brief` (PR #185).
- **Shared:** work in `~/Work/production/apps/norviq/norviq-shared` on branch `feat/terminal-positions-dtos`. The new tag is **v5.21.0**; the latest pushed tag is v5.20.0.
  - Until v5.21.0 is pushed, build the backend with `STOCKPLAN_SHARED_PATH=~/Work/production/apps/norviq/norviq-shared`.
  - Do not commit `Package.resolved` while building in path mode.

**Formulas** (only these; never stored):
- `terminalSharePrice = terminalMarketCap / terminalShareCount`
- `sharesNeeded = valueWanted * terminalShareCount / terminalMarketCap`
- `capitalAtTodayPrice = sharesNeeded * currentSharePrice` (only when the price is > 0)
- `progress = sharesNeeded == 0 ? 0 : sharesOwned / sharesNeeded`
- `sharesStillNeeded = max(0, sharesNeeded - sharesOwned)`
- `gapValueAtTerminal = sharesStillNeeded * terminalSharePrice`

**Guardrails**
- Share count ≤ 0 → `share_count_not_positive`. Market cap ≤ 0 → `market_cap_not_positive`. A non-finite number, or a negative valueWanted or sharesOwned, → `invalid_number`. In all three cases nothing is divided.
- Rows with share count or market cap ≤ 0 are stored. The response then carries `scenarioError` and nil derived fields.
- Negative valueWanted, sharesOwned or amount → 422. A percent outside (0, 1] → 422. The percentOfContribution cadence without a percent → 422.

**Monthly equivalents**
- weekly × 52/12, biweekly × 26/12, bimonthly × 6/12, monthly × 1
- percentOfContribution → `amount` (the monthly base) × percent. It is nil when amount is 0 or percent is nil.

**Tickers:** trimmed, uppercased, and must match `^[A-Z0-9.\-]{1,12}$`. Duplicate tickers are allowed.

**Auth and gating**
- Reads need `planning:read` and writes need `planning:write`. All routes are under `/v1`.
- The AI routes need `planning:read` plus Pro (`BillingFeature.terminalPositionAI`), which `BillingErrorMiddleware` turns into a **403** with `code: "upgrade_required"`.
- No web client → 503 "AI lookup unavailable". An unusable answer → 422.

**Rules for the AI**
- It never writes data.
- It sends no sampling parameters (Haiku 5.5 rule).
- No test calls a real API.

**Tests and commits**
- Tests use Swift Testing. DB tests need Postgres on 127.0.0.1:55443 (`TEST_DATABASE_PORT=55443`), plus Redis on 127.0.0.1:56380 (`REDIS_URL`) for the full suite:
  `docker run -d --name tps-test-pg -p 127.0.0.1:55443:5432 -e POSTGRES_USER=vapor_username -e POSTGRES_PASSWORD=vapor_password -e POSTGRES_DB=vapor_database postgres:18-alpine`
  `docker run -d --name tps-test-redis -p 127.0.0.1:56380:6379 redis:7-alpine`
  Remove both containers at the end.
- **Lint before every commit.** CI runs `swiftformat --lint .` and `swiftlint lint`. Run `swiftformat` on the files you touched. Inside `#expect`, never use `allSatisfy(\.x)`, because it won't compile; write a closure with a named parameter (`{ row in row.x }`), which swiftformat's preferKeyPath leaves alone.
- **Swift 6 test rules**
  - `NSLock.lock()` is unavailable in async functions, so lock inside a synchronous helper.
  - Inside `#expect`, do not combine `try await` with an `==` comparison; assign the value to a `let` first.
- **After every commit:** run `git show --stat HEAD`. The pre-commit hook may reformat unrelated files; if it did, restore them and recommit with `--no-verify`.

## Review Focus
1. **A PATCH that sends only `clear: ["currentSharePrice"]` with no other fields.** The price must become nil and nothing else may change; an unknown `clear` name → 422 (Task 4).
2. **A reorder list with a missing, duplicated or foreign id.** → 422, and no sortOrder changes (Task 4).
3. **A duplicate in the middle of the list.** The copy lands right after the source and every later row shifts down by one, with no sortOrder collisions (Task 4).
4. **An AI reply with numbers but no https source, or a negative or zero share count.** → 422 "no usable, sourced numbers", never a suggestion (Task 6).
5. **`set_terminal_scenario` on a ticker with no row and only `valueWanted` given.** → an error payload; nothing is created, and it must not crash (Task 7).

---

### Task 1: TerminalMath + AutobuyMath (norviq-shared)

**Files:**
- Create: `norviq-shared/Sources/StockPlanShared/TerminalPositions/TerminalMath.swift`
- Test: `norviq-shared/Tests/StockPlanSharedTests/TerminalMathTests.swift`

**Interfaces:**
- Produces:
  - `TerminalScenarioInput`, `TerminalScenarioError`, `TerminalScenarioResult`
  - `TerminalMath.evaluate(_:) -> Result<TerminalScenarioResult, TerminalScenarioError>`, `TerminalMath.wholeShares(_:)`
  - `AutobuyCadence` (CaseIterable, decodes unknown raw values as `.unknown`)
  - `AutobuyMath.monthlyEquivalent(amount:cadence:percent:) -> Double?`, `AutobuyMath.monthlyTotal(_:) -> Double`

- [ ] **Step 1: Create the branch and write the failing test**

```bash
cd ~/Work/production/apps/norviq/norviq-shared && git fetch -q origin && git switch -c feat/terminal-positions-dtos origin/main
```

`Tests/StockPlanSharedTests/TerminalMathTests.swift`:

```swift
import Foundation
import Testing
@testable import StockPlanShared

struct TerminalMathTests {
    private func success(_ input: TerminalScenarioInput) throws -> TerminalScenarioResult {
        try TerminalMath.evaluate(input).get()
    }

    @Test
    func `AMZN: 10T cap on 11B shares is 909.09 and a 1M target needs 1100 shares`() throws {
        let result = try success(TerminalScenarioInput(
            terminalShareCount: 11_000_000_000, terminalMarketCap: 10_000_000_000_000, valueWanted: 1_000_000
        ))
        #expect(abs(result.terminalSharePrice - 909.090909090909) < 1e-9)
        #expect(abs(result.sharesNeeded - 1100) < 1e-9)
    }

    @Test
    func `VG: 12.5B cap on 200M shares is 62.5 and a 500k target needs 8000 shares`() throws {
        let result = try success(TerminalScenarioInput(
            terminalShareCount: 200_000_000, terminalMarketCap: 12_500_000_000, valueWanted: 500_000
        ))
        #expect(abs(result.terminalSharePrice - 62.5) < 1e-12)
        #expect(abs(result.sharesNeeded - 8000) < 1e-9)
    }

    @Test
    func `SOFI: 150B cap on 1.75B shares is 85.714 and a 250k target needs 2916.67 shares`() throws {
        let result = try success(TerminalScenarioInput(
            terminalShareCount: 1_750_000_000, terminalMarketCap: 150_000_000_000, valueWanted: 250_000
        ))
        #expect(abs(result.terminalSharePrice - 85.71428571) < 1e-8)
        #expect(abs(result.sharesNeeded - 2916.6667) < 1e-4)
    }

    @Test
    func `Owning 750 of 1100 needed is 68.18% progress, 350 still needed`() throws {
        let result = try success(TerminalScenarioInput(
            terminalShareCount: 11_000_000_000, terminalMarketCap: 10_000_000_000_000,
            valueWanted: 1_000_000, sharesOwned: 750, currentSharePrice: 200
        ))
        #expect(abs(result.progress - 0.681818181818) < 1e-9)
        #expect(abs(result.sharesStillNeeded - 350) < 1e-9)
        #expect(abs(result.gapValueAtTerminal - 350 * 909.090909090909) < 1e-6)
        #expect(abs((result.capitalAtTodayPrice ?? 0) - 220_000) < 1e-6)
    }

    @Test
    func `Owning more than needed caps still-needed at zero`() throws {
        let result = try success(TerminalScenarioInput(
            terminalShareCount: 200_000_000, terminalMarketCap: 12_500_000_000, valueWanted: 500_000, sharesOwned: 9000
        ))
        #expect(result.sharesStillNeeded == 0)
        #expect(result.gapValueAtTerminal == 0)
        #expect(result.progress > 1)
    }

    @Test
    func `A zero target needs zero shares and reports zero progress`() throws {
        let result = try success(TerminalScenarioInput(
            terminalShareCount: 200_000_000, terminalMarketCap: 12_500_000_000, valueWanted: 0, sharesOwned: 10
        ))
        #expect(result.sharesNeeded == 0)
        #expect(result.progress == 0)
    }

    @Test
    func `No current price means no capital at today's price`() throws {
        let result = try success(TerminalScenarioInput(
            terminalShareCount: 200_000_000, terminalMarketCap: 12_500_000_000, valueWanted: 500_000
        ))
        #expect(result.capitalAtTodayPrice == nil)
    }

    @Test
    func `Guardrails: non-positive share count or market cap never divides`() {
        #expect(TerminalMath.evaluate(TerminalScenarioInput(
            terminalShareCount: 0, terminalMarketCap: 1, valueWanted: 1
        )) == .failure(.shareCountNotPositive))
        #expect(TerminalMath.evaluate(TerminalScenarioInput(
            terminalShareCount: 1, terminalMarketCap: -5, valueWanted: 1
        )) == .failure(.marketCapNotPositive))
        #expect(TerminalMath.evaluate(TerminalScenarioInput(
            terminalShareCount: .nan, terminalMarketCap: 1, valueWanted: 1
        )) == .failure(.invalidNumber))
        #expect(TerminalMath.evaluate(TerminalScenarioInput(
            terminalShareCount: 1, terminalMarketCap: 1, valueWanted: -1
        )) == .failure(.invalidNumber))
    }

    @Test
    func `Round down to whole shares is display-only floor`() {
        #expect(TerminalMath.wholeShares(2916.6667) == 2916)
        #expect(TerminalMath.wholeShares(-3) == 0)
        #expect(TerminalMath.wholeShares(.infinity) == 0)
    }

    @Test
    func `Monthly equivalents follow the cadence`() {
        #expect(abs((AutobuyMath.monthlyEquivalent(amount: 50, cadence: .weekly, percent: nil) ?? 0) - 216.6666667) < 1e-6)
        #expect(abs((AutobuyMath.monthlyEquivalent(amount: 100, cadence: .biweekly, percent: nil) ?? 0) - 216.6666667) < 1e-6)
        #expect(AutobuyMath.monthlyEquivalent(amount: 275, cadence: .bimonthly, percent: nil) == 137.5)
        #expect(AutobuyMath.monthlyEquivalent(amount: 300, cadence: .monthly, percent: nil) == 300)
        #expect(AutobuyMath.monthlyEquivalent(amount: 5000, cadence: .percentOfContribution, percent: 0.04) == 200)
        #expect(AutobuyMath.monthlyEquivalent(amount: 0, cadence: .percentOfContribution, percent: 0.04) == nil)
        #expect(AutobuyMath.monthlyEquivalent(amount: 5000, cadence: .percentOfContribution, percent: nil) == nil)
        #expect(AutobuyMath.monthlyEquivalent(amount: 50, cadence: .unknown, percent: nil) == nil)
    }

    @Test
    func `Monthly total counts active rows with a known equivalent`() {
        let total = AutobuyMath.monthlyTotal([
            (amount: 50, cadence: .weekly, percent: nil, active: true),
            (amount: 275, cadence: .bimonthly, percent: nil, active: true),
            (amount: 1000, cadence: .monthly, percent: nil, active: false),
            (amount: 0, cadence: .percentOfContribution, percent: 0.04, active: true),
        ])
        #expect(abs(total - (216.6666667 + 137.5)) < 1e-6)
    }

    @Test
    func `Unknown cadence strings decode as unknown`() throws {
        let decoded = try JSONDecoder().decode([AutobuyCadence].self, from: Data(#"["weekly","fortnightly"]"#.utf8))
        #expect(decoded == [.weekly, .unknown])
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter TerminalMathTests`
Expected: compile failure, `cannot find 'TerminalScenarioInput' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/StockPlanShared/TerminalPositions/TerminalMath.swift`:

```swift
import Foundation

/// One terminal scenario's inputs. Every number is a user assumption except
/// `currentSharePrice`, which is optional and manual in v1.
public struct TerminalScenarioInput: Sendable, Equatable {
    public var terminalShareCount: Double
    public var terminalMarketCap: Double
    public var valueWanted: Double
    public var sharesOwned: Double
    public var currentSharePrice: Double?

    public init(
        terminalShareCount: Double,
        terminalMarketCap: Double,
        valueWanted: Double,
        sharesOwned: Double = 0,
        currentSharePrice: Double? = nil
    ) {
        self.terminalShareCount = terminalShareCount
        self.terminalMarketCap = terminalMarketCap
        self.valueWanted = valueWanted
        self.sharesOwned = sharesOwned
        self.currentSharePrice = currentSharePrice
    }
}

/// Why a scenario cannot be evaluated. Raw values travel to clients as
/// `scenarioError`, which they show as an inline error.
public enum TerminalScenarioError: String, Codable, Sendable, Equatable, Error {
    case shareCountNotPositive = "share_count_not_positive"
    case marketCapNotPositive = "market_cap_not_positive"
    case invalidNumber = "invalid_number"
}

public struct TerminalScenarioResult: Sendable, Equatable {
    public let terminalSharePrice: Double
    public let sharesNeeded: Double
    public let capitalAtTodayPrice: Double?
    public let progress: Double
    public let sharesStillNeeded: Double
    public let gapValueAtTerminal: Double

    public init(
        terminalSharePrice: Double,
        sharesNeeded: Double,
        capitalAtTodayPrice: Double?,
        progress: Double,
        sharesStillNeeded: Double,
        gapValueAtTerminal: Double
    ) {
        self.terminalSharePrice = terminalSharePrice
        self.sharesNeeded = sharesNeeded
        self.capitalAtTodayPrice = capitalAtTodayPrice
        self.progress = progress
        self.sharesStillNeeded = sharesStillNeeded
        self.gapValueAtTerminal = gapValueAtTerminal
    }
}

/// Terminal position sizing: "if the company reaches market cap D with share
/// count C, how many shares make my position worth F?" Planning math only —
/// not a trade recommendation and not a stop-loss sizer. These are the only
/// formulas; every surface (backend, iOS, web via the backend) uses them.
public enum TerminalMath {
    public static func evaluate(_ input: TerminalScenarioInput) -> Result<TerminalScenarioResult, TerminalScenarioError> {
        let numbers = [input.terminalShareCount, input.terminalMarketCap, input.valueWanted, input.sharesOwned]
            + [input.currentSharePrice].compactMap(\.self)
        guard numbers.allSatisfy(\.isFinite) else { return .failure(.invalidNumber) }
        guard input.terminalShareCount > 0 else { return .failure(.shareCountNotPositive) }
        guard input.terminalMarketCap > 0 else { return .failure(.marketCapNotPositive) }
        guard input.valueWanted >= 0, input.sharesOwned >= 0 else { return .failure(.invalidNumber) }

        let terminalSharePrice = input.terminalMarketCap / input.terminalShareCount
        let sharesNeeded = input.valueWanted * input.terminalShareCount / input.terminalMarketCap
        let sharesStillNeeded = max(0, sharesNeeded - input.sharesOwned)
        let capital = input.currentSharePrice.flatMap { $0 > 0 ? sharesNeeded * $0 : nil }
        return .success(TerminalScenarioResult(
            terminalSharePrice: terminalSharePrice,
            sharesNeeded: sharesNeeded,
            capitalAtTodayPrice: capital,
            progress: sharesNeeded == 0 ? 0 : input.sharesOwned / sharesNeeded,
            sharesStillNeeded: sharesStillNeeded,
            gapValueAtTerminal: sharesStillNeeded * terminalSharePrice
        ))
    }

    /// "Round down to whole shares" — a display toggle; the stored target is unchanged.
    public static func wholeShares(_ shares: Double) -> Double {
        guard shares.isFinite, shares > 0 else { return 0 }
        return shares.rounded(.down)
    }
}

/// How often an autobuy runs. `bimonthly` means every two months.
public enum AutobuyCadence: String, Codable, Sendable, CaseIterable {
    case weekly
    case biweekly
    case bimonthly
    case monthly
    case percentOfContribution
    case unknown

    /// A cadence added later must not break decoding on clients already shipped.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AutobuyCadence(rawValue: raw) ?? .unknown
    }
}

public enum AutobuyMath {
    /// weekly ×52/12, biweekly ×26/12, bimonthly ×6/12, monthly ×1;
    /// percentOfContribution uses `amount` as the monthly base: base × percent.
    public static func monthlyEquivalent(amount: Double, cadence: AutobuyCadence, percent: Double?) -> Double? {
        guard amount.isFinite, amount >= 0 else { return nil }
        switch cadence {
        case .weekly: return amount * 52 / 12
        case .biweekly: return amount * 26 / 12
        case .bimonthly: return amount * 6 / 12
        case .monthly: return amount
        case .percentOfContribution:
            guard let percent, percent.isFinite, percent > 0, amount > 0 else { return nil }
            return amount * percent
        case .unknown: return nil
        }
    }

    /// Active rows only; rows without a monthly equivalent are skipped.
    public static func monthlyTotal(
        _ items: [(amount: Double, cadence: AutobuyCadence, percent: Double?, active: Bool)]
    ) -> Double {
        items.reduce(0) { total, item in
            guard item.active, let monthly = monthlyEquivalent(amount: item.amount, cadence: item.cadence, percent: item.percent) else {
                return total
            }
            return total + monthly
        }
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --filter TerminalMathTests`
Expected: 12 tests pass.

- [ ] **Step 5: Lint and commit**

```bash
swiftformat Sources/StockPlanShared/TerminalPositions Tests/StockPlanSharedTests/TerminalMathTests.swift && swiftformat --lint . 2>&1 | tail -1
git add Sources/StockPlanShared/TerminalPositions/TerminalMath.swift Tests/StockPlanSharedTests/TerminalMathTests.swift
git commit -m "feat(terminal-positions): TerminalMath and AutobuyMath with worked examples"
git show --stat HEAD
```

---

### Task 2: Terminal position DTOs (norviq-shared) + tag v5.21.0

**Files:**
- Create: `norviq-shared/Sources/StockPlanShared/TerminalPositions/TerminalPositionsDTOs.swift`
- Test: `norviq-shared/Tests/StockPlanSharedTests/TerminalPositionsDTOsTests.swift`

**Interfaces:**
- Consumes: `AutobuyCadence` (Task 1).
- Produces, all exactly as in the contract:
  - `TerminalPositionResponse`, `TerminalPositionCreateRequest`, `TerminalPositionUpdateRequest`, `TerminalPositionOrderRequest`, `TerminalPositionsListResponse`
  - `AutobuyResponse`, `AutobuyCreateRequest`, `AutobuyUpdateRequest`, `AutobuysListResponse`
  - `TerminalPositionsSummaryResponse`
  - `ShareFactsRequest`, `ShareFactsSuggestion`, `TerminalScenarioSuggestionRequest`, `TerminalScenarioSuggestion`
  - Optional init parameters default to `nil`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import StockPlanShared

struct TerminalPositionsDTOsTests {
    @Test
    func `position response round-trips with camelCase keys and nil derived fields`() throws {
        let response = TerminalPositionResponse(
            id: "6F9619FF-8B86-D011-B42D-00C04FC964FF", ticker: "VG", sharesOutstanding: 2_600_000_000,
            terminalShareCount: 0, terminalMarketCap: 12_500_000_000, valueWanted: 500_000, sharesOwned: 0,
            currentSharePrice: nil, notes: nil, sortOrder: 2,
            terminalSharePrice: nil, sharesNeeded: nil, capitalAtTodayPrice: nil, progress: nil,
            sharesStillNeeded: nil, gapValueAtTerminal: nil, scenarioError: "share_count_not_positive",
            createdAt: "2026-10-09T08:00:00Z", updatedAt: "2026-10-09T08:00:00Z"
        )
        let data = try JSONEncoder().encode(response)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"terminalShareCount\""))
        #expect(json.contains("\"scenarioError\":\"share_count_not_positive\""))
        #expect(try JSONDecoder().decode(TerminalPositionResponse.self, from: data) == response)
    }

    @Test
    func `update request carries only the fields being changed plus clear`() throws {
        let update = TerminalPositionUpdateRequest(valueWanted: 750_000, clear: ["currentSharePrice"])
        let json = try #require(String(data: JSONEncoder().encode(update), encoding: .utf8))
        #expect(json.contains("\"valueWanted\":750000"))
        #expect(json.contains("\"clear\":[\"currentSharePrice\"]"))
        #expect(!json.contains("\"ticker\""))
    }

    @Test
    func `autobuy response decodes an unknown cadence without failing`() throws {
        let json = #"{"id":"a","ticker":null,"label":"401k","amount":5000,"cadence":"quarterly","percent":0.04,"active":true,"monthlyEquivalent":null,"createdAt":"x","updatedAt":"x"}"#
        let decoded = try JSONDecoder().decode(AutobuyResponse.self, from: Data(json.utf8))
        #expect(decoded.cadence == .unknown)
    }

    @Test
    func `summary and suggestions round-trip`() throws {
        let summary = TerminalPositionsSummaryResponse(
            currency: "EUR", positionCount: 2, totalValueWanted: 1_500_000, totalGapValueAtTerminal: 318_181.8,
            totalCapitalAtTodayPrice: nil, pricedPositionCount: 0, monthlyAutobuyTotal: 354.17, topPositions: []
        )
        #expect(try JSONDecoder().decode(TerminalPositionsSummaryResponse.self, from: JSONEncoder().encode(summary)) == summary)
        let facts = ShareFactsSuggestion(
            ticker: "AMZN", sharesOutstanding: 10_600_000_000, currentSharePrice: 221.3,
            currency: "USD", asOf: "2026-09-30", sources: ["https://www.sec.gov/x"]
        )
        #expect(try JSONDecoder().decode(ShareFactsSuggestion.self, from: JSONEncoder().encode(facts)) == facts)
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `swift test --filter TerminalPositionsDTOsTests`
Expected: compile failure, `cannot find 'TerminalPositionResponse' in scope`.

- [ ] **Step 3: Write the DTOs**

`Sources/StockPlanShared/TerminalPositions/TerminalPositionsDTOs.swift`:

```swift
import Foundation

/// One terminal scenario row. Inputs are stored; the derived fields are
/// recomputed by `TerminalMath` on every read and are nil when
/// `scenarioError` is set.
public struct TerminalPositionResponse: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let ticker: String
    public let sharesOutstanding: Double?
    public let terminalShareCount: Double
    public let terminalMarketCap: Double
    public let valueWanted: Double
    public let sharesOwned: Double
    public let currentSharePrice: Double?
    public let notes: String?
    public let sortOrder: Int
    public let terminalSharePrice: Double?
    public let sharesNeeded: Double?
    public let capitalAtTodayPrice: Double?
    public let progress: Double?
    public let sharesStillNeeded: Double?
    public let gapValueAtTerminal: Double?
    /// `TerminalScenarioError` raw value.
    public let scenarioError: String?
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        ticker: String,
        sharesOutstanding: Double?,
        terminalShareCount: Double,
        terminalMarketCap: Double,
        valueWanted: Double,
        sharesOwned: Double,
        currentSharePrice: Double?,
        notes: String?,
        sortOrder: Int,
        terminalSharePrice: Double?,
        sharesNeeded: Double?,
        capitalAtTodayPrice: Double?,
        progress: Double?,
        sharesStillNeeded: Double?,
        gapValueAtTerminal: Double?,
        scenarioError: String?,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.ticker = ticker
        self.sharesOutstanding = sharesOutstanding
        self.terminalShareCount = terminalShareCount
        self.terminalMarketCap = terminalMarketCap
        self.valueWanted = valueWanted
        self.sharesOwned = sharesOwned
        self.currentSharePrice = currentSharePrice
        self.notes = notes
        self.sortOrder = sortOrder
        self.terminalSharePrice = terminalSharePrice
        self.sharesNeeded = sharesNeeded
        self.capitalAtTodayPrice = capitalAtTodayPrice
        self.progress = progress
        self.sharesStillNeeded = sharesStillNeeded
        self.gapValueAtTerminal = gapValueAtTerminal
        self.scenarioError = scenarioError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TerminalPositionCreateRequest: Codable, Sendable, Equatable {
    public let ticker: String
    public let sharesOutstanding: Double?
    public let terminalShareCount: Double
    public let terminalMarketCap: Double
    public let valueWanted: Double
    public let sharesOwned: Double?
    public let currentSharePrice: Double?
    public let notes: String?

    public init(
        ticker: String,
        sharesOutstanding: Double? = nil,
        terminalShareCount: Double,
        terminalMarketCap: Double,
        valueWanted: Double,
        sharesOwned: Double? = nil,
        currentSharePrice: Double? = nil,
        notes: String? = nil
    ) {
        self.ticker = ticker
        self.sharesOutstanding = sharesOutstanding
        self.terminalShareCount = terminalShareCount
        self.terminalMarketCap = terminalMarketCap
        self.valueWanted = valueWanted
        self.sharesOwned = sharesOwned
        self.currentSharePrice = currentSharePrice
        self.notes = notes
    }
}

/// PATCH body: only non-nil fields change. `clear` sets nullable fields back
/// to nil: "sharesOutstanding", "currentSharePrice", "notes".
public struct TerminalPositionUpdateRequest: Codable, Sendable, Equatable {
    public let ticker: String?
    public let sharesOutstanding: Double?
    public let terminalShareCount: Double?
    public let terminalMarketCap: Double?
    public let valueWanted: Double?
    public let sharesOwned: Double?
    public let currentSharePrice: Double?
    public let notes: String?
    public let clear: [String]?

    public init(
        ticker: String? = nil,
        sharesOutstanding: Double? = nil,
        terminalShareCount: Double? = nil,
        terminalMarketCap: Double? = nil,
        valueWanted: Double? = nil,
        sharesOwned: Double? = nil,
        currentSharePrice: Double? = nil,
        notes: String? = nil,
        clear: [String]? = nil
    ) {
        self.ticker = ticker
        self.sharesOutstanding = sharesOutstanding
        self.terminalShareCount = terminalShareCount
        self.terminalMarketCap = terminalMarketCap
        self.valueWanted = valueWanted
        self.sharesOwned = sharesOwned
        self.currentSharePrice = currentSharePrice
        self.notes = notes
        self.clear = clear
    }
}

/// Every position id, in the new order.
public struct TerminalPositionOrderRequest: Codable, Sendable, Equatable {
    public let ids: [String]

    public init(ids: [String]) {
        self.ids = ids
    }
}

public struct TerminalPositionsListResponse: Codable, Sendable, Equatable {
    public let currency: String
    public let positions: [TerminalPositionResponse]

    public init(currency: String, positions: [TerminalPositionResponse]) {
        self.currency = currency
        self.positions = positions
    }
}

public struct AutobuyResponse: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let ticker: String?
    public let label: String
    /// For `percentOfContribution`, the monthly base the percent applies to.
    public let amount: Double
    public let cadence: AutobuyCadence
    public let percent: Double?
    public let active: Bool
    public let monthlyEquivalent: Double?
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        ticker: String?,
        label: String,
        amount: Double,
        cadence: AutobuyCadence,
        percent: Double?,
        active: Bool,
        monthlyEquivalent: Double?,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.ticker = ticker
        self.label = label
        self.amount = amount
        self.cadence = cadence
        self.percent = percent
        self.active = active
        self.monthlyEquivalent = monthlyEquivalent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AutobuyCreateRequest: Codable, Sendable, Equatable {
    public let ticker: String?
    public let label: String
    public let amount: Double
    public let cadence: AutobuyCadence
    public let percent: Double?
    public let active: Bool?

    public init(
        ticker: String? = nil,
        label: String,
        amount: Double,
        cadence: AutobuyCadence,
        percent: Double? = nil,
        active: Bool? = nil
    ) {
        self.ticker = ticker
        self.label = label
        self.amount = amount
        self.cadence = cadence
        self.percent = percent
        self.active = active
    }
}

/// PATCH body; `clear` accepts "ticker" and "percent".
public struct AutobuyUpdateRequest: Codable, Sendable, Equatable {
    public let ticker: String?
    public let label: String?
    public let amount: Double?
    public let cadence: AutobuyCadence?
    public let percent: Double?
    public let active: Bool?
    public let clear: [String]?

    public init(
        ticker: String? = nil,
        label: String? = nil,
        amount: Double? = nil,
        cadence: AutobuyCadence? = nil,
        percent: Double? = nil,
        active: Bool? = nil,
        clear: [String]? = nil
    ) {
        self.ticker = ticker
        self.label = label
        self.amount = amount
        self.cadence = cadence
        self.percent = percent
        self.active = active
        self.clear = clear
    }
}

public struct AutobuysListResponse: Codable, Sendable, Equatable {
    public let currency: String
    public let autobuys: [AutobuyResponse]
    public let monthlyTotal: Double

    public init(currency: String, autobuys: [AutobuyResponse], monthlyTotal: Double) {
        self.currency = currency
        self.autobuys = autobuys
        self.monthlyTotal = monthlyTotal
    }
}

/// Totals over valid rows. "Total shares-needed notional at terminal prices"
/// is not a field: it always equals `totalValueWanted` by construction.
public struct TerminalPositionsSummaryResponse: Codable, Sendable, Equatable {
    public let currency: String
    public let positionCount: Int
    public let totalValueWanted: Double
    public let totalGapValueAtTerminal: Double
    public let totalCapitalAtTodayPrice: Double?
    public let pricedPositionCount: Int
    public let monthlyAutobuyTotal: Double
    /// Up to three valid rows, highest `valueWanted` first.
    public let topPositions: [TerminalPositionResponse]

    public init(
        currency: String,
        positionCount: Int,
        totalValueWanted: Double,
        totalGapValueAtTerminal: Double,
        totalCapitalAtTodayPrice: Double?,
        pricedPositionCount: Int,
        monthlyAutobuyTotal: Double,
        topPositions: [TerminalPositionResponse]
    ) {
        self.currency = currency
        self.positionCount = positionCount
        self.totalValueWanted = totalValueWanted
        self.totalGapValueAtTerminal = totalGapValueAtTerminal
        self.totalCapitalAtTodayPrice = totalCapitalAtTodayPrice
        self.pricedPositionCount = pricedPositionCount
        self.monthlyAutobuyTotal = monthlyAutobuyTotal
        self.topPositions = topPositions
    }
}

public struct ShareFactsRequest: Codable, Sendable, Equatable {
    public let ticker: String

    public init(ticker: String) {
        self.ticker = ticker
    }
}

/// AI suggestion with sources. Never saved until the user accepts it.
public struct ShareFactsSuggestion: Codable, Sendable, Equatable {
    public let ticker: String
    public let sharesOutstanding: Double?
    public let currentSharePrice: Double?
    public let currency: String?
    public let asOf: String?
    public let sources: [String]

    public init(
        ticker: String,
        sharesOutstanding: Double?,
        currentSharePrice: Double?,
        currency: String?,
        asOf: String?,
        sources: [String]
    ) {
        self.ticker = ticker
        self.sharesOutstanding = sharesOutstanding
        self.currentSharePrice = currentSharePrice
        self.currency = currency
        self.asOf = asOf
        self.sources = sources
    }
}

public struct TerminalScenarioSuggestionRequest: Codable, Sendable, Equatable {
    public let ticker: String
    /// Defaults to 10 on the server.
    public let horizonYears: Int?

    public init(ticker: String, horizonYears: Int? = nil) {
        self.ticker = ticker
        self.horizonYears = horizonYears
    }
}

/// AI-proposed terminal assumptions with a short rationale and sources.
public struct TerminalScenarioSuggestion: Codable, Sendable, Equatable {
    public let ticker: String
    public let terminalShareCount: Double
    public let terminalMarketCap: Double
    public let horizonYears: Int
    public let rationale: String
    public let sources: [String]

    public init(
        ticker: String,
        terminalShareCount: Double,
        terminalMarketCap: Double,
        horizonYears: Int,
        rationale: String,
        sources: [String]
    ) {
        self.ticker = ticker
        self.terminalShareCount = terminalShareCount
        self.terminalMarketCap = terminalMarketCap
        self.horizonYears = horizonYears
        self.rationale = rationale
        self.sources = sources
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --filter "TerminalPositionsDTOsTests|TerminalMathTests"`, then `swift test`.
Expected: 16 new tests pass and the whole suite is green.

- [ ] **Step 5: Lint, commit and tag locally**

```bash
swiftformat Sources/StockPlanShared/TerminalPositions Tests/StockPlanSharedTests/TerminalPositionsDTOsTests.swift && swiftformat --lint . 2>&1 | tail -1
git add Sources/StockPlanShared/TerminalPositions/TerminalPositionsDTOs.swift Tests/StockPlanSharedTests/TerminalPositionsDTOsTests.swift
git commit -m "feat(terminal-positions): terminal position, autobuy and AI suggestion DTOs"
git show --stat HEAD
git tag v5.21.0
```

Pushing the branch and tag is outward-facing. Do it only when the user has approved the release push: `git switch main && git merge --ff-only feat/terminal-positions-dtos && git push origin main v5.21.0`.

---

### Task 3: Pin shared 5.21.0, records, migration

**Files:**
- Modify: `Package.swift:9` (`exact: "5.18.0"` → `exact: "5.21.0"`)
- Create: `Sources/StockPlanBackend/Models/TerminalPositionRecord.swift`
- Create: `Sources/StockPlanBackend/Models/AutobuyRecord.swift`
- Create: `Sources/StockPlanBackend/Migrations/CreateTerminalPositions.swift`
- Modify: `Sources/StockPlanBackend/ConfigureBootstrap.swift`, adding `app.migrations.add(CreateTerminalPositions())` after `app.migrations.add(AddSocialFacebookImport())`
- Create: `Tests/StockPlanBackendTests/TerminalPositionsFixtures.swift`
- Test: `Tests/StockPlanBackendTests/TerminalPositionRecordTests.swift`

**Interfaces:**
- Consumes: shared Tasks 1–2.
- Produces:
  - `TerminalPositionRecord` (fields as in the spec, plus `static func owned(by:on:)` and `func toResponse() -> TerminalPositionResponse`).
  - `AutobuyRecord` (with `owned(by:on:)`, `cadenceValue: AutobuyCadence`, `toResponse()`).
  - Test helpers: `TerminalFixtures.withApp(_:)` and `TerminalFixtures.registerUser(app:) -> (token: String, userId: UUID)`.

- [ ] **Step 1: Pin the package and write the fixtures plus a failing test**

```bash
cd ~/Work/production/apps/norviq/norviq-backend-terminal
sed -i '' 's/exact: "5.18.0")/exact: "5.21.0")/' Package.swift && grep -n 'exact: "5' Package.swift
export STOCKPLAN_SHARED_PATH=~/Work/production/apps/norviq/norviq-shared TEST_DATABASE_PORT=55443
```

`Tests/StockPlanBackendTests/TerminalPositionsFixtures.swift`:

```swift
import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Vapor
import VaporTesting

enum TerminalFixtures {
    /// Configured, migrated app inside the shared DB lock.
    static func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                try await test(app)
                try await app.autoRevert()
                try await app.asyncShutdown()
            } catch {
                try? await app.autoRevert()
                try? await app.asyncShutdown()
                throw error
            }
        }
    }

    static func registerUser(app: Application) async throws -> (token: String, userId: UUID) {
        let id = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "tps_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "tps_\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            token = try res.content.decode(AuthResponse.self).token
        })
        let userId = try await app.jwt.keys.verify(token, as: SessionToken.self).userId
        return (token, userId)
    }

    static func amzn() -> TerminalPositionCreateRequest {
        TerminalPositionCreateRequest(
            ticker: "amzn", sharesOutstanding: 10_600_000_000, terminalShareCount: 11_000_000_000,
            terminalMarketCap: 10_000_000_000_000, valueWanted: 1_000_000, sharesOwned: 750
        )
    }

    static func vg() -> TerminalPositionCreateRequest {
        TerminalPositionCreateRequest(
            ticker: "VG", terminalShareCount: 200_000_000, terminalMarketCap: 12_500_000_000, valueWanted: 500_000
        )
    }
}
```

`Tests/StockPlanBackendTests/TerminalPositionRecordTests.swift`:

```swift
import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Terminal position records", .serialized)
struct TerminalPositionRecordTests {
    @Test("A stored row round-trips and recomputes its derived fields on read")
    func roundTrip() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let record = TerminalPositionRecord(
                userId: user.userId, ticker: "AMZN", sharesOutstanding: 10_600_000_000,
                terminalShareCount: 11_000_000_000, terminalMarketCap: 10_000_000_000_000,
                valueWanted: 1_000_000, sharesOwned: 750, currentSharePrice: nil, notes: nil, sortOrder: 0
            )
            try await record.save(on: app.db)
            let loaded = try #require(try await TerminalPositionRecord.owned(by: user.userId, on: app.db).first())
            let response = loaded.toResponse()
            #expect(response.ticker == "AMZN")
            #expect(abs((response.sharesNeeded ?? 0) - 1100) < 1e-9)
            #expect(abs((response.progress ?? 0) - 0.681818181818) < 1e-9)
            #expect(response.scenarioError == nil)
        }
    }

    @Test("An invalid scenario is stored and reported, with no derived numbers")
    func invalidScenario() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let record = TerminalPositionRecord(
                userId: user.userId, ticker: "VG", sharesOutstanding: nil, terminalShareCount: 0,
                terminalMarketCap: 12_500_000_000, valueWanted: 500_000, sharesOwned: 0,
                currentSharePrice: nil, notes: nil, sortOrder: 0
            )
            try await record.save(on: app.db)
            let response = record.toResponse()
            #expect(response.scenarioError == "share_count_not_positive")
            #expect(response.sharesNeeded == nil)
            #expect(response.terminalSharePrice == nil)
        }
    }

    @Test("Autobuy rows report their monthly equivalent")
    func autobuy() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let row = AutobuyRecord(
                userId: user.userId, ticker: "AMZN", label: "AMZN", amount: 275, cadence: .bimonthly,
                percent: nil, active: true
            )
            try await row.save(on: app.db)
            #expect(row.toResponse().monthlyEquivalent == 137.5)
            #expect(row.cadenceValue == .bimonthly)
        }
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

```bash
docker run -d --name tps-test-pg -p 127.0.0.1:55443:5432 -e POSTGRES_USER=vapor_username -e POSTGRES_PASSWORD=vapor_password -e POSTGRES_DB=vapor_database postgres:18-alpine
LOG_LEVEL=warning swift test --filter TerminalPositionRecordTests
```

Expected: compile failure, `cannot find 'TerminalPositionRecord' in scope`.

- [ ] **Step 3: Write the records and migration**

`Sources/StockPlanBackend/Models/TerminalPositionRecord.swift`:

```swift
import Fluent
import Foundation
import StockPlanShared
import Vapor

/// One terminal scenario. Stores the user's assumptions only; every derived
/// number comes from `TerminalMath` at read time.
final class TerminalPositionRecord: Model, @unchecked Sendable {
    static let schema = "terminal_positions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "ticker")
    var ticker: String

    @OptionalField(key: "shares_outstanding")
    var sharesOutstanding: Double?

    @Field(key: "terminal_share_count")
    var terminalShareCount: Double

    @Field(key: "terminal_market_cap")
    var terminalMarketCap: Double

    @Field(key: "value_wanted")
    var valueWanted: Double

    @Field(key: "shares_owned")
    var sharesOwned: Double

    @OptionalField(key: "current_share_price")
    var currentSharePrice: Double?

    @OptionalField(key: "notes")
    var notes: String?

    @Field(key: "sort_order")
    var sortOrder: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        ticker: String,
        sharesOutstanding: Double?,
        terminalShareCount: Double,
        terminalMarketCap: Double,
        valueWanted: Double,
        sharesOwned: Double,
        currentSharePrice: Double?,
        notes: String?,
        sortOrder: Int
    ) {
        self.id = id
        self.userId = userId
        self.ticker = ticker
        self.sharesOutstanding = sharesOutstanding
        self.terminalShareCount = terminalShareCount
        self.terminalMarketCap = terminalMarketCap
        self.valueWanted = valueWanted
        self.sharesOwned = sharesOwned
        self.currentSharePrice = currentSharePrice
        self.notes = notes
        self.sortOrder = sortOrder
    }

    static func owned(by userId: UUID, on db: any Database) -> QueryBuilder<TerminalPositionRecord> {
        TerminalPositionRecord.query(on: db).filter(\.$userId == userId)
    }

    func toResponse() -> TerminalPositionResponse {
        let evaluation = TerminalMath.evaluate(TerminalScenarioInput(
            terminalShareCount: terminalShareCount,
            terminalMarketCap: terminalMarketCap,
            valueWanted: valueWanted,
            sharesOwned: sharesOwned,
            currentSharePrice: currentSharePrice
        ))
        let result = try? evaluation.get()
        let scenarioError: String? = if case let .failure(error) = evaluation { error.rawValue } else { nil }
        let iso = ISO8601DateFormatter()
        return TerminalPositionResponse(
            id: id?.uuidString ?? "",
            ticker: ticker,
            sharesOutstanding: sharesOutstanding,
            terminalShareCount: terminalShareCount,
            terminalMarketCap: terminalMarketCap,
            valueWanted: valueWanted,
            sharesOwned: sharesOwned,
            currentSharePrice: currentSharePrice,
            notes: notes,
            sortOrder: sortOrder,
            terminalSharePrice: result?.terminalSharePrice,
            sharesNeeded: result?.sharesNeeded,
            capitalAtTodayPrice: result?.capitalAtTodayPrice,
            progress: result?.progress,
            sharesStillNeeded: result?.sharesStillNeeded,
            gapValueAtTerminal: result?.gapValueAtTerminal,
            scenarioError: scenarioError,
            createdAt: iso.string(from: createdAt ?? Date()),
            updatedAt: iso.string(from: updatedAt ?? createdAt ?? Date())
        )
    }
}
```

`Sources/StockPlanBackend/Models/AutobuyRecord.swift`:

```swift
import Fluent
import Foundation
import StockPlanShared
import Vapor

/// A recurring buy that funds terminal targets. `amount` is the monthly base
/// when the cadence is `percentOfContribution`.
final class AutobuyRecord: Model, @unchecked Sendable {
    static let schema = "autobuys"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @OptionalField(key: "ticker")
    var ticker: String?

    @Field(key: "label")
    var label: String

    @Field(key: "amount")
    var amount: Double

    @Field(key: "cadence")
    var cadence: String

    @OptionalField(key: "percent")
    var percent: Double?

    @Field(key: "active")
    var active: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        ticker: String?,
        label: String,
        amount: Double,
        cadence: AutobuyCadence,
        percent: Double?,
        active: Bool
    ) {
        self.id = id
        self.userId = userId
        self.ticker = ticker
        self.label = label
        self.amount = amount
        self.cadence = cadence.rawValue
        self.percent = percent
        self.active = active
    }

    static func owned(by userId: UUID, on db: any Database) -> QueryBuilder<AutobuyRecord> {
        AutobuyRecord.query(on: db).filter(\.$userId == userId)
    }

    var cadenceValue: AutobuyCadence {
        AutobuyCadence(rawValue: cadence) ?? .unknown
    }

    var monthlyEquivalent: Double? {
        AutobuyMath.monthlyEquivalent(amount: amount, cadence: cadenceValue, percent: percent)
    }

    func toResponse() -> AutobuyResponse {
        let iso = ISO8601DateFormatter()
        return AutobuyResponse(
            id: id?.uuidString ?? "",
            ticker: ticker,
            label: label,
            amount: amount,
            cadence: cadenceValue,
            percent: percent,
            active: active,
            monthlyEquivalent: monthlyEquivalent,
            createdAt: iso.string(from: createdAt ?? Date()),
            updatedAt: iso.string(from: updatedAt ?? createdAt ?? Date())
        )
    }
}
```

`Sources/StockPlanBackend/Migrations/CreateTerminalPositions.swift`:

```swift
import Fluent

struct CreateTerminalPositions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("terminal_positions")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("ticker", .string, .required)
            .field("shares_outstanding", .double)
            .field("terminal_share_count", .double, .required)
            .field("terminal_market_cap", .double, .required)
            .field("value_wanted", .double, .required)
            .field("shares_owned", .double, .required)
            .field("current_share_price", .double)
            .field("notes", .string)
            .field("sort_order", .int, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
        try await database.createIndex(on: "terminal_positions", columns: ["user_id", "sort_order"])

        try await database.schema("autobuys")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("ticker", .string)
            .field("label", .string, .required)
            .field("amount", .double, .required)
            .field("cadence", .string, .required)
            .field("percent", .double)
            .field("active", .bool, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
        try await database.createIndex(on: "autobuys", columns: ["user_id"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("autobuys").delete()
        try await database.schema("terminal_positions").delete()
    }
}
```

Register it in `ConfigureBootstrap.swift`, right after `app.migrations.add(AddSocialFacebookImport())`:

```swift
    app.migrations.add(CreateTerminalPositions())
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `LOG_LEVEL=warning swift test --filter TerminalPositionRecordTests`
Expected: 3 tests pass.

- [ ] **Step 5: Lint and commit (leave `Package.resolved` out)**

```bash
swiftformat Sources/StockPlanBackend/Models/TerminalPositionRecord.swift Sources/StockPlanBackend/Models/AutobuyRecord.swift Sources/StockPlanBackend/Migrations/CreateTerminalPositions.swift Tests/StockPlanBackendTests/TerminalPositions*.swift Tests/StockPlanBackendTests/TerminalPositionRecordTests.swift
git add Package.swift Sources/StockPlanBackend/Models/TerminalPositionRecord.swift Sources/StockPlanBackend/Models/AutobuyRecord.swift Sources/StockPlanBackend/Migrations/CreateTerminalPositions.swift Sources/StockPlanBackend/ConfigureBootstrap.swift Tests/StockPlanBackendTests/TerminalPositionsFixtures.swift Tests/StockPlanBackendTests/TerminalPositionRecordTests.swift
git commit -m "feat(terminal-positions): records and migration; pin shared 5.21.0"
git show --stat HEAD
```

---

### Task 4: TerminalPositionsService (validation, CRUD, reorder, duplicate, summary, upsert)

**Files:**
- Create: `Sources/StockPlanBackend/TerminalPositions/TerminalPositionsService.swift`
- Create: `Sources/StockPlanBackend/TerminalPositions/TerminalPositionPrefill.swift` (an extension-point protocol only)
- Test: `Tests/StockPlanBackendTests/TerminalPositionsServiceTests.swift`

**Interfaces:**
- Consumes: the records (Task 3) and the DTOs (Task 2).
- Produces `TerminalPositionsService`. All methods are `async throws`, take `on db: any Database`, and throw `Abort` 404 or 422.
  - Positions: `list(userId:ticker:)`, `create(userId:_:)`, `update(userId:id:_:)`, `delete(userId:id:)`, `duplicate(userId:id:)`, `reorder(userId:ids:)`
  - Autobuys: `listAutobuys(userId:)`, `createAutobuy(userId:_:)`, `updateAutobuy(userId:id:_:)`, `deleteAutobuy(userId:id:)`
  - Other: `currency(userId:)`, `summary(userId:)`, and `upsertScenario(userId:ticker:fields:)` with `ScenarioFields`
  - Static: `normalisedTicker(_:) throws -> String`

- [ ] **Step 1: Write the failing test**

```swift
import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Terminal positions service", .serialized)
struct TerminalPositionsServiceTests {
    private let service = TerminalPositionsService()

    private func status(of body: () async throws -> some Any) async -> HTTPResponseStatus? {
        do {
            _ = try await body()
            return nil
        } catch let abort as any AbortError {
            return abort.status
        } catch {
            return .internalServerError
        }
    }

    @Test("Create normalises the ticker and appends to the end")
    func createAppends() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let first = try await service.create(userId: user.userId, TerminalFixtures.amzn(), on: app.db)
            let second = try await service.create(userId: user.userId, TerminalFixtures.vg(), on: app.db)
            #expect(first.ticker == "AMZN")
            #expect(first.sortOrder == 0)
            #expect(second.sortOrder == 1)
        }
    }

    @Test("Bad tickers and negative money are 422; a zero share count is stored with scenarioError")
    func validation() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let badTicker = TerminalPositionCreateRequest(ticker: "  $$ ", terminalShareCount: 1, terminalMarketCap: 1, valueWanted: 1)
            let negative = TerminalPositionCreateRequest(ticker: "VG", terminalShareCount: 1, terminalMarketCap: 1, valueWanted: -1)
            let badTickerStatus = await status { try await service.create(userId: user.userId, badTicker, on: app.db) }
            let negativeStatus = await status { try await service.create(userId: user.userId, negative, on: app.db) }
            #expect(badTickerStatus == .unprocessableEntity)
            #expect(negativeStatus == .unprocessableEntity)

            let zero = TerminalPositionCreateRequest(ticker: "VG", terminalShareCount: 0, terminalMarketCap: 12_500_000_000, valueWanted: 500_000)
            let stored = try await service.create(userId: user.userId, zero, on: app.db)
            #expect(stored.toResponse().scenarioError == "share_count_not_positive")
        }
    }

    @Test("PATCH changes only sent fields; clear nils nullable fields; unknown clear is 422")
    func patchAndClear() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let created = try await service.create(userId: user.userId, TerminalPositionCreateRequest(
                ticker: "AMZN", terminalShareCount: 11_000_000_000, terminalMarketCap: 10_000_000_000_000,
                valueWanted: 1_000_000, currentSharePrice: 200, notes: "base case"
            ), on: app.db)
            let id = try created.requireID()

            let cleared = try await service.update(userId: user.userId, id: id, TerminalPositionUpdateRequest(clear: ["currentSharePrice"]), on: app.db)
            #expect(cleared.currentSharePrice == nil)
            #expect(cleared.notes == "base case")
            #expect(cleared.valueWanted == 1_000_000)

            let changed = try await service.update(userId: user.userId, id: id, TerminalPositionUpdateRequest(valueWanted: 2_000_000), on: app.db)
            #expect(changed.valueWanted == 2_000_000)
            #expect(changed.terminalShareCount == 11_000_000_000)

            let unknown = await status {
                try await service.update(userId: user.userId, id: id, TerminalPositionUpdateRequest(clear: ["valueWanted"]), on: app.db)
            }
            #expect(unknown == .unprocessableEntity)
        }
    }

    @Test("Another user's row is 404 for update, delete and duplicate")
    func scoping() async throws {
        try await TerminalFixtures.withApp { app in
            let owner = try await TerminalFixtures.registerUser(app: app)
            let other = try await TerminalFixtures.registerUser(app: app)
            let row = try await service.create(userId: owner.userId, TerminalFixtures.vg(), on: app.db)
            let id = try row.requireID()
            let update = await status { try await service.update(userId: other.userId, id: id, TerminalPositionUpdateRequest(valueWanted: 1), on: app.db) }
            let delete = await status { try await service.delete(userId: other.userId, id: id, on: app.db) }
            let duplicate = await status { try await service.duplicate(userId: other.userId, id: id, on: app.db) }
            #expect(update == .notFound)
            #expect(delete == .notFound)
            #expect(duplicate == .notFound)
        }
    }

    @Test("Duplicate lands right after its source and shifts later rows")
    func duplicatePlacement() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let a = try await service.create(userId: user.userId, TerminalFixtures.amzn(), on: app.db)
            _ = try await service.create(userId: user.userId, TerminalFixtures.vg(), on: app.db)
            _ = try await service.duplicate(userId: user.userId, id: a.requireID(), on: app.db)
            let rows = try await service.list(userId: user.userId, on: app.db)
            #expect(rows.map(\.ticker) == ["AMZN", "AMZN", "VG"])
            #expect(rows.map(\.sortOrder) == [0, 1, 2])
        }
    }

    @Test("Reorder needs every id exactly once; a bad list changes nothing")
    func reorder() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let a = try await service.create(userId: user.userId, TerminalFixtures.amzn(), on: app.db)
            let b = try await service.create(userId: user.userId, TerminalFixtures.vg(), on: app.db)
            let ids = try [b.requireID().uuidString, a.requireID().uuidString]
            let reordered = try await service.reorder(userId: user.userId, ids: ids, on: app.db)
            #expect(reordered.map(\.ticker) == ["VG", "AMZN"])

            let missing = await status { try await service.reorder(userId: user.userId, ids: [ids[0]], on: app.db) }
            let duplicated = await status { try await service.reorder(userId: user.userId, ids: [ids[0], ids[0]], on: app.db) }
            let foreign = await status { try await service.reorder(userId: user.userId, ids: [ids[0], UUID().uuidString], on: app.db) }
            #expect(missing == .unprocessableEntity)
            #expect(duplicated == .unprocessableEntity)
            #expect(foreign == .unprocessableEntity)
            let after = try await service.list(userId: user.userId, on: app.db)
            #expect(after.map(\.ticker) == ["VG", "AMZN"])
        }
    }

    @Test("Autobuy validation: percent cadence needs a percent in (0, 1]; unknown cadence rejected")
    func autobuyValidation() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let noPercent = await status {
                try await service.createAutobuy(userId: user.userId, AutobuyCreateRequest(label: "401k", amount: 5000, cadence: .percentOfContribution), on: app.db)
            }
            let tooBig = await status {
                try await service.createAutobuy(userId: user.userId, AutobuyCreateRequest(label: "401k", amount: 5000, cadence: .percentOfContribution, percent: 4), on: app.db)
            }
            let unknown = await status {
                try await service.createAutobuy(userId: user.userId, AutobuyCreateRequest(label: "x", amount: 1, cadence: .unknown), on: app.db)
            }
            #expect(noPercent == .unprocessableEntity)
            #expect(tooBig == .unprocessableEntity)
            #expect(unknown == .unprocessableEntity)
            let ok = try await service.createAutobuy(
                userId: user.userId,
                AutobuyCreateRequest(label: "401k Contributions", amount: 5000, cadence: .percentOfContribution, percent: 0.04),
                on: app.db
            )
            #expect(ok.monthlyEquivalent == 200)
        }
    }

    @Test("Summary totals valid rows, prices and active autobuys, in the default portfolio's currency")
    func summary() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let portfolio = try await PortfolioList.query(on: app.db)
                .filter(\.$userId == user.userId).filter(\.$isDefault == true).first()
                ?? PortfolioList(userId: user.userId, name: "Main", isDefault: true)
            portfolio.baseCurrency = "EUR"
            try await portfolio.save(on: app.db)

            _ = try await service.create(userId: user.userId, TerminalPositionCreateRequest(
                ticker: "AMZN", terminalShareCount: 11_000_000_000, terminalMarketCap: 10_000_000_000_000,
                valueWanted: 1_000_000, sharesOwned: 750, currentSharePrice: 200
            ), on: app.db)
            _ = try await service.create(userId: user.userId, TerminalFixtures.vg(), on: app.db)
            _ = try await service.create(userId: user.userId, TerminalPositionCreateRequest(
                ticker: "BAD", terminalShareCount: 0, terminalMarketCap: 1, valueWanted: 99
            ), on: app.db)
            _ = try await service.createAutobuy(userId: user.userId, AutobuyCreateRequest(label: "AMZN", amount: 275, cadence: .bimonthly), on: app.db)
            _ = try await service.createAutobuy(userId: user.userId, AutobuyCreateRequest(label: "Paused", amount: 999, cadence: .monthly, active: false), on: app.db)

            let summary = try await service.summary(userId: user.userId, on: app.db)
            #expect(summary.currency == "EUR")
            #expect(summary.positionCount == 3)
            #expect(summary.totalValueWanted == 1_500_000)
            let expectedGap = 350 * (10_000_000_000_000.0 / 11_000_000_000) + 500_000
            #expect(abs(summary.totalGapValueAtTerminal - expectedGap) < 1e-3)
            #expect(abs((summary.totalCapitalAtTodayPrice ?? 0) - 220_000) < 1e-6)
            #expect(summary.pricedPositionCount == 1)
            #expect(summary.monthlyAutobuyTotal == 137.5)
            #expect(summary.topPositions.map(\.ticker) == ["AMZN", "VG"])
        }
    }

    @Test("upsertScenario updates the first row for a ticker, creates when complete, errors when not")
    func upsert() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let incomplete = await status {
                try await service.upsertScenario(
                    userId: user.userId, ticker: "SOFI",
                    fields: .init(valueWanted: 250_000), on: app.db
                )
            }
            #expect(incomplete == .unprocessableEntity)
            #expect(try await service.list(userId: user.userId, on: app.db).isEmpty)

            let created = try await service.upsertScenario(
                userId: user.userId, ticker: "sofi",
                fields: .init(terminalShareCount: 1_750_000_000, terminalMarketCap: 150_000_000_000, valueWanted: 250_000),
                on: app.db
            )
            let updated = try await service.upsertScenario(
                userId: user.userId, ticker: "SOFI", fields: .init(sharesOwned: 1000), on: app.db
            )
            #expect(try updated.requireID() == created.requireID())
            #expect(abs((updated.toResponse().progress ?? 0) - 0.3428571429) < 1e-9)
        }
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `LOG_LEVEL=warning swift test --filter TerminalPositionsServiceTests`
Expected: compile failure, `cannot find 'TerminalPositionsService' in scope`.

- [ ] **Step 3: Write the service and the prefill extension point**

`Sources/StockPlanBackend/TerminalPositions/TerminalPositionsService.swift`:

```swift
import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Rules and persistence for terminal position sizing. Stateless; the
/// controllers, the action catalog and the tests all go through this.
///
/// Share count and market cap are user assumptions and may be saved as zero
/// or negative mid-edit: the row then reports `scenarioError` instead of
/// numbers. Everything else that would make the maths meaningless is a 422.
struct TerminalPositionsService: Sendable {
    static let clearablePositionFields: Set<String> = ["sharesOutstanding", "currentSharePrice", "notes"]
    static let clearableAutobuyFields: Set<String> = ["ticker", "percent"]
    static let maxNotesLength = 1000
    static let maxLabelLength = 80

    /// Fields `set_terminal_scenario` may write. All optional; a new row needs
    /// share count, market cap and value wanted.
    struct ScenarioFields: Sendable, Equatable {
        var terminalShareCount: Double?
        var terminalMarketCap: Double?
        var valueWanted: Double?
        var sharesOwned: Double?
        var sharesOutstanding: Double?
        var currentSharePrice: Double?

        init(
            terminalShareCount: Double? = nil,
            terminalMarketCap: Double? = nil,
            valueWanted: Double? = nil,
            sharesOwned: Double? = nil,
            sharesOutstanding: Double? = nil,
            currentSharePrice: Double? = nil
        ) {
            self.terminalShareCount = terminalShareCount
            self.terminalMarketCap = terminalMarketCap
            self.valueWanted = valueWanted
            self.sharesOwned = sharesOwned
            self.sharesOutstanding = sharesOutstanding
            self.currentSharePrice = currentSharePrice
        }
    }

    // MARK: - Validation

    static func normalisedTicker(_ raw: String) throws -> String {
        let ticker = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ticker.wholeMatch(of: #/[A-Z0-9.\-]{1,12}/#) != nil else {
            throw Abort(.unprocessableEntity, reason: "ticker must be 1-12 letters, digits, '.' or '-'")
        }
        return ticker
    }

    static func finite(_ value: Double, _ field: String) throws -> Double {
        guard value.isFinite else { throw Abort(.unprocessableEntity, reason: "\(field) must be a number") }
        return value
    }

    static func nonNegative(_ value: Double, _ field: String) throws -> Double {
        guard try finite(value, field) >= 0 else {
            throw Abort(.unprocessableEntity, reason: "\(field) must be zero or more")
        }
        return value
    }

    static func positive(_ value: Double, _ field: String) throws -> Double {
        guard try finite(value, field) > 0 else {
            throw Abort(.unprocessableEntity, reason: "\(field) must be greater than zero")
        }
        return value
    }

    static func notes(_ raw: String?) throws -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.count <= maxNotesLength else {
            throw Abort(.unprocessableEntity, reason: "notes must be \(maxNotesLength) characters or fewer")
        }
        return trimmed
    }

    static func label(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLabelLength else {
            throw Abort(.unprocessableEntity, reason: "label must be 1-\(maxLabelLength) characters")
        }
        return trimmed
    }

    static func clearFields(_ raw: [String]?, allowed: Set<String>) throws -> Set<String> {
        let requested = Set(raw ?? [])
        let unknown = requested.subtracting(allowed)
        guard unknown.isEmpty else {
            throw Abort(.unprocessableEntity, reason: "cannot clear: \(unknown.sorted().joined(separator: ", "))")
        }
        return requested
    }

    static func validatedPercent(_ percent: Double?, cadence: AutobuyCadence) throws -> Double? {
        guard cadence != .unknown else { throw Abort(.unprocessableEntity, reason: "unknown cadence") }
        if let percent {
            guard percent.isFinite, percent > 0, percent <= 1 else {
                throw Abort(.unprocessableEntity, reason: "percent must be between 0 and 1 (0.04 = 4%)")
            }
        }
        if cadence == .percentOfContribution, percent == nil {
            throw Abort(.unprocessableEntity, reason: "percentOfContribution needs a percent")
        }
        return percent
    }

    // MARK: - Positions

    func list(userId: UUID, ticker: String? = nil, on db: any Database) async throws -> [TerminalPositionRecord] {
        var query = TerminalPositionRecord.owned(by: userId, on: db)
        if let ticker = ticker?.trimmingCharacters(in: .whitespacesAndNewlines), !ticker.isEmpty {
            query = query.filter(\.$ticker == ticker.uppercased())
        }
        return try await query.sort(\.$sortOrder).sort(\.$createdAt).all()
    }

    func find(userId: UUID, id: UUID, on db: any Database) async throws -> TerminalPositionRecord {
        guard let row = try await TerminalPositionRecord.owned(by: userId, on: db).filter(\.$id == id).first() else {
            throw Abort(.notFound, reason: "Terminal position not found.")
        }
        return row
    }

    func create(userId: UUID, _ input: TerminalPositionCreateRequest, on db: any Database) async throws -> TerminalPositionRecord {
        let last = try await TerminalPositionRecord.owned(by: userId, on: db).sort(\.$sortOrder, .descending).first()
        let record = try TerminalPositionRecord(
            userId: userId,
            ticker: Self.normalisedTicker(input.ticker),
            sharesOutstanding: input.sharesOutstanding.map { try Self.positive($0, "sharesOutstanding") },
            terminalShareCount: Self.finite(input.terminalShareCount, "terminalShareCount"),
            terminalMarketCap: Self.finite(input.terminalMarketCap, "terminalMarketCap"),
            valueWanted: Self.nonNegative(input.valueWanted, "valueWanted"),
            sharesOwned: Self.nonNegative(input.sharesOwned ?? 0, "sharesOwned"),
            currentSharePrice: input.currentSharePrice.map { try Self.positive($0, "currentSharePrice") },
            notes: Self.notes(input.notes),
            sortOrder: (last?.sortOrder ?? -1) + 1
        )
        try await record.save(on: db)
        return record
    }

    func update(
        userId: UUID,
        id: UUID,
        _ input: TerminalPositionUpdateRequest,
        on db: any Database
    ) async throws -> TerminalPositionRecord {
        let record = try await find(userId: userId, id: id, on: db)
        let clear = try Self.clearFields(input.clear, allowed: Self.clearablePositionFields)
        if let ticker = input.ticker { record.ticker = try Self.normalisedTicker(ticker) }
        if let value = input.sharesOutstanding { record.sharesOutstanding = try Self.positive(value, "sharesOutstanding") }
        if let value = input.terminalShareCount { record.terminalShareCount = try Self.finite(value, "terminalShareCount") }
        if let value = input.terminalMarketCap { record.terminalMarketCap = try Self.finite(value, "terminalMarketCap") }
        if let value = input.valueWanted { record.valueWanted = try Self.nonNegative(value, "valueWanted") }
        if let value = input.sharesOwned { record.sharesOwned = try Self.nonNegative(value, "sharesOwned") }
        if let value = input.currentSharePrice { record.currentSharePrice = try Self.positive(value, "currentSharePrice") }
        if input.notes != nil { record.notes = try Self.notes(input.notes) }
        if clear.contains("sharesOutstanding") { record.sharesOutstanding = nil }
        if clear.contains("currentSharePrice") { record.currentSharePrice = nil }
        if clear.contains("notes") { record.notes = nil }
        try await record.save(on: db)
        return record
    }

    func delete(userId: UUID, id: UUID, on db: any Database) async throws {
        try await find(userId: userId, id: id, on: db).delete(on: db)
    }

    /// The copy goes right after its source; later rows shift down by one.
    func duplicate(userId: UUID, id: UUID, on db: any Database) async throws -> TerminalPositionRecord {
        let source = try await find(userId: userId, id: id, on: db)
        let copy = TerminalPositionRecord(
            userId: userId,
            ticker: source.ticker,
            sharesOutstanding: source.sharesOutstanding,
            terminalShareCount: source.terminalShareCount,
            terminalMarketCap: source.terminalMarketCap,
            valueWanted: source.valueWanted,
            sharesOwned: source.sharesOwned,
            currentSharePrice: source.currentSharePrice,
            notes: source.notes,
            sortOrder: source.sortOrder + 1
        )
        try await db.transaction { tx in
            let later = try await TerminalPositionRecord.owned(by: userId, on: tx)
                .filter(\.$sortOrder > source.sortOrder)
                .all()
            for row in later {
                row.sortOrder += 1
                try await row.save(on: tx)
            }
            try await copy.save(on: tx)
        }
        return copy
    }

    func reorder(userId: UUID, ids: [String], on db: any Database) async throws -> [TerminalPositionRecord] {
        let uuids = try ids.map { raw in
            guard let id = UUID(uuidString: raw) else { throw Abort(.unprocessableEntity, reason: "invalid id \(raw)") }
            return id
        }
        let rows = try await TerminalPositionRecord.owned(by: userId, on: db).all()
        let owned = Set(rows.compactMap(\.id))
        guard uuids.count == rows.count, Set(uuids).count == uuids.count, Set(uuids) == owned else {
            throw Abort(.unprocessableEntity, reason: "ids must list every terminal position exactly once")
        }
        try await db.transaction { tx in
            for (index, id) in uuids.enumerated() {
                guard let row = rows.first(where: { $0.id == id }) else { continue }
                row.sortOrder = index
                try await row.save(on: tx)
            }
        }
        return try await list(userId: userId, on: db)
    }

    /// Assistant/MCP write: update the first row for the ticker, or create one.
    func upsertScenario(
        userId: UUID,
        ticker raw: String,
        fields: ScenarioFields,
        on db: any Database
    ) async throws -> TerminalPositionRecord {
        let ticker = try Self.normalisedTicker(raw)
        if let existing = try await list(userId: userId, ticker: ticker, on: db).first {
            return try await update(
                userId: userId,
                id: existing.requireID(),
                TerminalPositionUpdateRequest(
                    sharesOutstanding: fields.sharesOutstanding,
                    terminalShareCount: fields.terminalShareCount,
                    terminalMarketCap: fields.terminalMarketCap,
                    valueWanted: fields.valueWanted,
                    sharesOwned: fields.sharesOwned,
                    currentSharePrice: fields.currentSharePrice
                ),
                on: db
            )
        }
        guard let count = fields.terminalShareCount, let cap = fields.terminalMarketCap, let value = fields.valueWanted else {
            throw Abort(
                .unprocessableEntity,
                reason: "a new scenario needs terminalShareCount, terminalMarketCap and valueWanted"
            )
        }
        return try await create(
            userId: userId,
            TerminalPositionCreateRequest(
                ticker: ticker,
                sharesOutstanding: fields.sharesOutstanding,
                terminalShareCount: count,
                terminalMarketCap: cap,
                valueWanted: value,
                sharesOwned: fields.sharesOwned,
                currentSharePrice: fields.currentSharePrice
            ),
            on: db
        )
    }

    // MARK: - Autobuys

    func listAutobuys(userId: UUID, on db: any Database) async throws -> [AutobuyRecord] {
        try await AutobuyRecord.owned(by: userId, on: db).sort(\.$createdAt).all()
    }

    func findAutobuy(userId: UUID, id: UUID, on db: any Database) async throws -> AutobuyRecord {
        guard let row = try await AutobuyRecord.owned(by: userId, on: db).filter(\.$id == id).first() else {
            throw Abort(.notFound, reason: "Autobuy not found.")
        }
        return row
    }

    func createAutobuy(userId: UUID, _ input: AutobuyCreateRequest, on db: any Database) async throws -> AutobuyRecord {
        let record = try AutobuyRecord(
            userId: userId,
            ticker: input.ticker.map { try Self.normalisedTicker($0) },
            label: Self.label(input.label),
            amount: Self.nonNegative(input.amount, "amount"),
            cadence: input.cadence,
            percent: Self.validatedPercent(input.percent, cadence: input.cadence),
            active: input.active ?? true
        )
        try await record.save(on: db)
        return record
    }

    func updateAutobuy(userId: UUID, id: UUID, _ input: AutobuyUpdateRequest, on db: any Database) async throws -> AutobuyRecord {
        let record = try await findAutobuy(userId: userId, id: id, on: db)
        let clear = try Self.clearFields(input.clear, allowed: Self.clearableAutobuyFields)
        if let ticker = input.ticker { record.ticker = try Self.normalisedTicker(ticker) }
        if let label = input.label { record.label = try Self.label(label) }
        if let amount = input.amount { record.amount = try Self.nonNegative(amount, "amount") }
        if let cadence = input.cadence { record.cadence = cadence.rawValue }
        if let percent = input.percent { record.percent = percent }
        if let active = input.active { record.active = active }
        if clear.contains("ticker") { record.ticker = nil }
        if clear.contains("percent") { record.percent = nil }
        record.percent = try Self.validatedPercent(record.percent, cadence: record.cadenceValue)
        try await record.save(on: db)
        return record
    }

    func deleteAutobuy(userId: UUID, id: UUID, on db: any Database) async throws {
        try await findAutobuy(userId: userId, id: id, on: db).delete(on: db)
    }

    static func monthlyTotal(_ rows: [AutobuyRecord]) -> Double {
        AutobuyMath.monthlyTotal(rows.map { (amount: $0.amount, cadence: $0.cadenceValue, percent: $0.percent, active: $0.active) })
    }

    // MARK: - Currency and summary

    /// There is no user-level currency: use the default portfolio's, then any
    /// portfolio's, then the deployment default.
    func currency(userId: UUID, on db: any Database) async throws -> String {
        if let preferred = try await PortfolioList.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$isDefault == true)
            .first()
        {
            return preferred.baseCurrency
        }
        if let any = try await PortfolioList.query(on: db).filter(\.$userId == userId).first() {
            return any.baseCurrency
        }
        return Environment.get("MARKET_DEFAULT_CURRENCY") ?? "USD"
    }

    func summary(userId: UUID, on db: any Database) async throws -> TerminalPositionsSummaryResponse {
        let positions = try await list(userId: userId, on: db).map { $0.toResponse() }
        let valid = positions.filter { $0.scenarioError == nil }
        let priced = valid.compactMap(\.capitalAtTodayPrice)
        let autobuys = try await listAutobuys(userId: userId, on: db)
        return try await TerminalPositionsSummaryResponse(
            currency: currency(userId: userId, on: db),
            positionCount: positions.count,
            totalValueWanted: valid.reduce(0) { $0 + $1.valueWanted },
            totalGapValueAtTerminal: valid.reduce(0) { $0 + ($1.gapValueAtTerminal ?? 0) },
            totalCapitalAtTodayPrice: priced.isEmpty ? nil : priced.reduce(0, +),
            pricedPositionCount: priced.count,
            monthlyAutobuyTotal: Self.monthlyTotal(autobuys),
            topPositions: Array(valid.sorted { $0.valueWanted > $1.valueWanted }.prefix(3))
        )
    }
}
```

`Sources/StockPlanBackend/TerminalPositions/TerminalPositionPrefill.swift`:

```swift
import Foundation
import Vapor

/// Extension point, not implemented in v1: fill `sharesOwned` from the user's
/// holdings (`stocksRepository`) and `currentSharePrice` from
/// `marketDataService.quote`. Prefill must only ever propose values; the user
/// confirms them, exactly like the AI suggestions.
protocol TerminalPositionPrefill: Sendable {
    func sharesOwned(userId: UUID, ticker: String, on req: Request) async throws -> Double?
    func currentSharePrice(ticker: String, on req: Request) async throws -> Double?
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `LOG_LEVEL=warning swift test --filter TerminalPositionsServiceTests`
Expected: 9 tests pass. If `summary`'s first `#expect` sees "USD", registration created the default portfolio after our save. Fix it by re-querying the default before saving (the test already looks it up first), not by changing the service.

- [ ] **Step 5: Lint and commit**

```bash
swiftformat Sources/StockPlanBackend/TerminalPositions Tests/StockPlanBackendTests/TerminalPositionsServiceTests.swift
git add Sources/StockPlanBackend/TerminalPositions Tests/StockPlanBackendTests/TerminalPositionsServiceTests.swift
git commit -m "feat(terminal-positions): service with validation, reorder, duplicate, summary and upsert"
git show --stat HEAD
```

---

### Task 5: HTTP routes (positions, autobuys, summary)

**Files:**
- Create: `Sources/StockPlanBackend/TerminalPositions/TerminalPositionsController.swift`
- Modify: `Sources/StockPlanBackend/routes.swift`: after `try api.register(collection: GoalsController())` (~:166), add `try api.register(collection: TerminalPositionsController())`
- Test: `Tests/StockPlanBackendTests/TerminalPositionsRouteTests.swift`

**Interfaces:**
- Consumes: `TerminalPositionsService` (Task 4).
- Produces the routes in the contract table, except the AI routes (Task 6).

- [ ] **Step 1: Write the failing test**

```swift
import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Terminal positions routes", .serialized)
struct TerminalPositionsRouteTests {
    private func mintPAT(app: Application, userId: UUID, scopes: [APIScope]) async throws -> String {
        let raw = OpaqueToken.generate(prefix: OpaqueToken.patPrefix)
        let pat = PersonalAccessToken(
            userId: userId, name: "test", tokenHash: OpaqueToken.sha256Hex(raw),
            scopes: scopes.map(\.rawValue), expiresAt: Date().addingTimeInterval(3600)
        )
        try await pat.save(on: app.db)
        return raw
    }

    private func send(
        _ app: Application, _ method: HTTPMethod, _ path: String, token: String?,
        body: (some Encodable & Sendable)? = String?.none,
        _ check: @escaping (TestingHTTPResponse) async throws -> Void
    ) async throws {
        try await app.testing().test(method, path, beforeRequest: { req in
            if let token { req.headers.bearerAuthorization = BearerAuthorization(token: token) }
            if let body { try req.content.encode(body, as: .json) }
        }, afterResponse: check)
    }

    @Test("No token is 401; a PAT without planning scopes is 403")
    func authMatrix() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let wrong = try await mintPAT(app: app, userId: user.userId, scopes: [.expensesRead])
            try await send(app, .GET, "v1/terminal-positions", token: nil) { res in
                #expect(res.status == .unauthorized)
            }
            try await send(app, .GET, "v1/terminal-positions", token: wrong) { res in
                #expect(res.status == .forbidden)
            }
            try await send(app, .GET, "v1/autobuys", token: wrong) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Create, list with ticker filter, patch, duplicate, reorder, summary, delete")
    func lifecycle() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            var createdId = ""
            try await send(app, .POST, "v1/terminal-positions", token: user.token, body: TerminalFixtures.amzn()) { res in
                #expect(res.status == .created)
                let body = try res.content.decode(TerminalPositionResponse.self)
                createdId = body.id
                #expect(body.ticker == "AMZN")
                #expect(abs((body.sharesNeeded ?? 0) - 1100) < 1e-9)
            }
            try await send(app, .POST, "v1/terminal-positions", token: user.token, body: TerminalFixtures.vg()) { res in
                #expect(res.status == .created)
            }
            try await send(app, .GET, "v1/terminal-positions?ticker=amzn", token: user.token) { res in
                let body = try res.content.decode(TerminalPositionsListResponse.self)
                #expect(body.positions.map(\.ticker) == ["AMZN"])
                #expect(!body.currency.isEmpty)
            }
            try await send(app, .PATCH, "v1/terminal-positions/\(createdId)", token: user.token,
                           body: TerminalPositionUpdateRequest(terminalShareCount: 0)) { res in
                let body = try res.content.decode(TerminalPositionResponse.self)
                #expect(body.scenarioError == "share_count_not_positive")
                #expect(body.sharesNeeded == nil)
            }
            try await send(app, .POST, "v1/terminal-positions/\(createdId)/duplicate", token: user.token) { res in
                #expect(res.status == .created)
            }
            var ids: [String] = []
            try await send(app, .GET, "v1/terminal-positions", token: user.token) { res in
                ids = try res.content.decode(TerminalPositionsListResponse.self).positions.map(\.id)
            }
            #expect(ids.count == 3)
            try await send(app, .PUT, "v1/terminal-positions/order", token: user.token,
                           body: TerminalPositionOrderRequest(ids: ids.reversed())) { res in
                let body = try res.content.decode(TerminalPositionsListResponse.self)
                #expect(body.positions.map(\.id) == ids.reversed())
            }
            try await send(app, .GET, "v1/terminal-positions/summary", token: user.token) { res in
                let body = try res.content.decode(TerminalPositionsSummaryResponse.self)
                #expect(body.positionCount == 3)
            }
            try await send(app, .DELETE, "v1/terminal-positions/\(createdId)", token: user.token) { res in
                #expect(res.status == .noContent)
            }
        }
    }

    @Test("Another user's row is 404 over HTTP")
    func otherUser() async throws {
        try await TerminalFixtures.withApp { app in
            let owner = try await TerminalFixtures.registerUser(app: app)
            let other = try await TerminalFixtures.registerUser(app: app)
            var id = ""
            try await send(app, .POST, "v1/terminal-positions", token: owner.token, body: TerminalFixtures.vg()) { res in
                id = try res.content.decode(TerminalPositionResponse.self).id
            }
            try await send(app, .DELETE, "v1/terminal-positions/\(id)", token: other.token) { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("Autobuys CRUD returns monthly equivalents and a total")
    func autobuys() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            var id = ""
            try await send(app, .POST, "v1/autobuys", token: user.token,
                           body: AutobuyCreateRequest(label: "Beat the SPY", amount: 50, cadence: .weekly)) { res in
                #expect(res.status == .created)
                id = try res.content.decode(AutobuyResponse.self).id
            }
            try await send(app, .PATCH, "v1/autobuys/\(id)", token: user.token,
                           body: AutobuyUpdateRequest(cadence: .monthly)) { res in
                let body = try res.content.decode(AutobuyResponse.self)
                #expect(body.monthlyEquivalent == 50)
            }
            try await send(app, .GET, "v1/autobuys", token: user.token) { res in
                let body = try res.content.decode(AutobuysListResponse.self)
                #expect(body.monthlyTotal == 50)
            }
            try await send(app, .DELETE, "v1/autobuys/\(id)", token: user.token) { res in
                #expect(res.status == .noContent)
            }
        }
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `LOG_LEVEL=warning swift test --filter TerminalPositionsRouteTests`
Expected: the authMatrix test fails with 404 instead of 401/403, because the routes don't exist yet. If `send`'s generic `body` default does not compile, replace it with two overloads (with and without a body).

- [ ] **Step 3: Write the controller and register it**

`Sources/StockPlanBackend/TerminalPositions/TerminalPositionsController.swift`:

```swift
import Fluent
import Foundation
import StockPlanShared
import Vapor

extension TerminalPositionResponse: @retroactive Content {}
extension TerminalPositionCreateRequest: @retroactive Content {}
extension TerminalPositionUpdateRequest: @retroactive Content {}
extension TerminalPositionOrderRequest: @retroactive Content {}
extension TerminalPositionsListResponse: @retroactive Content {}
extension TerminalPositionsSummaryResponse: @retroactive Content {}
extension AutobuyResponse: @retroactive Content {}
extension AutobuyCreateRequest: @retroactive Content {}
extension AutobuyUpdateRequest: @retroactive Content {}
extension AutobuysListResponse: @retroactive Content {}

/// `/v1/terminal-positions` and `/v1/autobuys`. User-scoped; free for every
/// plan. AI suggestions live in `TerminalPositionsAIController`.
struct TerminalPositionsController: RouteCollection {
    private let service = TerminalPositionsService()

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())

        let positions = protected.grouped("terminal-positions")
        let readPositions = positions.grouped(ScopeRequirementMiddleware(.planningRead))
        let writePositions = positions.grouped(ScopeRequirementMiddleware(.planningWrite))
        readPositions.get(use: index)
        readPositions.get("summary", use: summary)
        writePositions.post(use: create)
        writePositions.put("order", use: reorder)
        writePositions.patch(":id", use: update)
        writePositions.delete(":id", use: delete)
        writePositions.post(":id", "duplicate", use: duplicate)

        let autobuys = protected.grouped("autobuys")
        autobuys.grouped(ScopeRequirementMiddleware(.planningRead)).get(use: listAutobuys)
        let writeAutobuys = autobuys.grouped(ScopeRequirementMiddleware(.planningWrite))
        writeAutobuys.post(use: createAutobuy)
        writeAutobuys.patch(":id", use: updateAutobuy)
        writeAutobuys.delete(":id", use: deleteAutobuy)
    }

    private func userId(_ req: Request) throws -> UUID {
        try req.auth.require(SessionToken.self).userId
    }

    private func id(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest, reason: "invalid id") }
        return id
    }

    @Sendable
    func index(req: Request) async throws -> TerminalPositionsListResponse {
        let user = try userId(req)
        let rows = try await service.list(userId: user, ticker: req.query[String.self, at: "ticker"], on: req.db)
        return try await TerminalPositionsListResponse(
            currency: service.currency(userId: user, on: req.db),
            positions: rows.map { $0.toResponse() }
        )
    }

    @Sendable
    func summary(req: Request) async throws -> TerminalPositionsSummaryResponse {
        try await service.summary(userId: userId(req), on: req.db)
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let input = try req.content.decode(TerminalPositionCreateRequest.self)
        let row = try await service.create(userId: userId(req), input, on: req.db)
        return try await row.toResponse().encodeResponse(status: .created, for: req)
    }

    @Sendable
    func update(req: Request) async throws -> TerminalPositionResponse {
        let input = try req.content.decode(TerminalPositionUpdateRequest.self)
        return try await service.update(userId: userId(req), id: id(req), input, on: req.db).toResponse()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        try await service.delete(userId: userId(req), id: id(req), on: req.db)
        return .noContent
    }

    @Sendable
    func duplicate(req: Request) async throws -> Response {
        let row = try await service.duplicate(userId: userId(req), id: id(req), on: req.db)
        return try await row.toResponse().encodeResponse(status: .created, for: req)
    }

    @Sendable
    func reorder(req: Request) async throws -> TerminalPositionsListResponse {
        let user = try userId(req)
        let input = try req.content.decode(TerminalPositionOrderRequest.self)
        let rows = try await service.reorder(userId: user, ids: input.ids, on: req.db)
        return try await TerminalPositionsListResponse(
            currency: service.currency(userId: user, on: req.db),
            positions: rows.map { $0.toResponse() }
        )
    }

    @Sendable
    func listAutobuys(req: Request) async throws -> AutobuysListResponse {
        let user = try userId(req)
        let rows = try await service.listAutobuys(userId: user, on: req.db)
        return try await AutobuysListResponse(
            currency: service.currency(userId: user, on: req.db),
            autobuys: rows.map { $0.toResponse() },
            monthlyTotal: TerminalPositionsService.monthlyTotal(rows)
        )
    }

    @Sendable
    func createAutobuy(req: Request) async throws -> Response {
        let input = try req.content.decode(AutobuyCreateRequest.self)
        let row = try await service.createAutobuy(userId: userId(req), input, on: req.db)
        return try await row.toResponse().encodeResponse(status: .created, for: req)
    }

    @Sendable
    func updateAutobuy(req: Request) async throws -> AutobuyResponse {
        let input = try req.content.decode(AutobuyUpdateRequest.self)
        return try await service.updateAutobuy(userId: userId(req), id: id(req), input, on: req.db).toResponse()
    }

    @Sendable
    func deleteAutobuy(req: Request) async throws -> HTTPStatus {
        try await service.deleteAutobuy(userId: userId(req), id: id(req), on: req.db)
        return .noContent
    }
}
```

In `routes.swift`, directly after `try api.register(collection: GoalsController())`:

```swift
    try api.register(collection: TerminalPositionsController())
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `LOG_LEVEL=warning swift test --filter TerminalPositionsRouteTests`
Expected: 4 tests pass.

- [ ] **Step 5: Lint and commit**

```bash
swiftformat Sources/StockPlanBackend/TerminalPositions Tests/StockPlanBackendTests/TerminalPositionsRouteTests.swift
git add Sources/StockPlanBackend/TerminalPositions/TerminalPositionsController.swift Sources/StockPlanBackend/routes.swift Tests/StockPlanBackendTests/TerminalPositionsRouteTests.swift
git commit -m "feat(terminal-positions): CRUD, reorder, duplicate and summary routes"
git show --stat HEAD
```

---

### Task 6: Pro AI suggestions (share facts, scenario)

**Files:**
- Modify: `Sources/StockPlanBackend/Billing/EntitlementResolver.swift`:
  - Add `case terminalPositionAI = "terminal_position_ai"` after `case goalPlanning = "goal_planning"`.
  - Add `.terminalPositionAI` to the three exhaustive lists that end in `.goalPlanning:` (the `limit(for:)`, `usageValue(for:in:)` and `setUsageValue(for:in:value:)` switches), right after `.goalPlanning`.
- Modify: `Sources/StockPlanBackend/Billing/BillingContextService.swift`: in `BillingFeatureDescriptor.all`, after the `.goalPlanning` line, add `.init(feature: .terminalPositionAI, title: "AI terminal scenario research", proOnly: true),`
- Create: `Sources/StockPlanBackend/TerminalPositions/TerminalAIAdvisor.swift`
- Create: `Sources/StockPlanBackend/TerminalPositions/TerminalPositionsAIController.swift`
- Create: `Sources/StockPlanBackend/TerminalPositions/TerminalPositions+Application.swift`
- Modify: `Sources/StockPlanBackend/configure.swift`: after `app.asyncCommands.use(PortfolioBackfillCommand(), as: "portfolio-backfill")`, add `app.terminalAIClient = TerminalAIAdvisor.liveClient()`
- Modify: `Sources/StockPlanBackend/routes.swift`: after `try api.grouped(aiRateLimit).register(collection: AIAssistantController())`, add `try api.grouped(aiRateLimit).register(collection: TerminalPositionsAIController())`
- Test: `Tests/StockPlanBackendTests/TerminalAIAdvisorTests.swift`

**Interfaces:**
- Consumes: `OpenAIChatClient`, `OpenAIMessage`, `DefaultOpenAIChatClient`, `AIProviderConfiguration.load()`, `req.usageCounterService.requirePremium(_:userId:on:)`.
- Produces:
  - `app.terminalAIClient: (any OpenAIChatClient)?`
  - `TerminalAIAdvisor(client:)` with `shareFacts(ticker:on:)`, `scenario(ticker:horizonYears:on:)`, `static parseShareFacts(_:ticker:)`, `static parseScenario(_:ticker:horizonYears:)` and `static liveClient()`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// Replies in order. Locking happens in a synchronous helper (NSLock is
/// unavailable in async code under Swift 6).
final class ScriptedTerminalChatClient: OpenAIChatClient, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<String, any Error>]

    init(_ replies: [Result<String, any Error>]) {
        self.replies = replies
    }

    func chat(messages _: [OpenAIMessage], tools _: [OpenAITool], responseFormat _: String?, on _: Request) async throws -> OpenAIMessage {
        try OpenAIMessage(role: "assistant", content: next().get())
    }

    private func next() -> Result<String, any Error> {
        lock.lock()
        defer { lock.unlock() }
        return replies.isEmpty ? .failure(Abort(.badGateway)) : replies.removeFirst()
    }
}

@Suite("Terminal AI advisor", .serialized)
struct TerminalAIAdvisorTests {
    private let factsJSON = #"""
    Sure:
    ```json
    {"sharesOutstanding": 10600000000, "currentSharePrice": 221.3, "currency": "usd", "asOf": "2026-09-30",
     "sources": ["https://www.sec.gov/amzn-10q", "http://insecure.example"]}
    ```
    """#

    @Test("Share facts parse from a fenced reply; only https sources survive")
    func parsesFacts() throws {
        let facts = try TerminalAIAdvisor.parseShareFacts(factsJSON, ticker: "AMZN")
        #expect(facts.sharesOutstanding == 10_600_000_000)
        #expect(facts.currentSharePrice == 221.3)
        #expect(facts.currency == "USD")
        #expect(facts.sources == ["https://www.sec.gov/amzn-10q"])
    }

    @Test("Numbers without an https source, or non-positive numbers, are unusable")
    func rejectsUnsourcedOrBad() {
        let unsourced = #"{"sharesOutstanding": 1000, "currentSharePrice": 10, "sources": []}"#
        let negative = #"{"sharesOutstanding": -5, "currentSharePrice": 0, "sources": ["https://x.example"]}"#
        #expect(throws: (any Error).self) { try TerminalAIAdvisor.parseShareFacts(unsourced, ticker: "X") }
        #expect(throws: (any Error).self) { try TerminalAIAdvisor.parseShareFacts(negative, ticker: "X") }
        #expect(throws: (any Error).self) { try TerminalAIAdvisor.parseShareFacts("no json", ticker: "X") }
    }

    @Test("Scenario parses; zero share count or empty rationale is unusable")
    func parsesScenario() throws {
        let good = #"{"terminalShareCount": 1750000000, "terminalMarketCap": 150000000000, "rationale": "Consensus growth.", "sources": ["https://a.example"]}"#
        let scenario = try TerminalAIAdvisor.parseScenario(good, ticker: "SOFI", horizonYears: 10)
        #expect(scenario.terminalShareCount == 1_750_000_000)
        #expect(scenario.horizonYears == 10)
        let zero = #"{"terminalShareCount": 0, "terminalMarketCap": 1, "rationale": "x", "sources": ["https://a.example"]}"#
        let empty = #"{"terminalShareCount": 1, "terminalMarketCap": 1, "rationale": " ", "sources": ["https://a.example"]}"#
        #expect(throws: (any Error).self) { try TerminalAIAdvisor.parseScenario(zero, ticker: "X", horizonYears: 10) }
        #expect(throws: (any Error).self) { try TerminalAIAdvisor.parseScenario(empty, ticker: "X", horizonYears: 10) }
    }

    // MARK: - Endpoint

    /// Exclusive lock: BYPASS_BILLING is process-wide (same pattern as MCPTokenAuthTests).
    private func withApp(pro: Bool, _ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            let previous = getenv("BYPASS_BILLING").map { String(cString: $0) }
            setenv("BYPASS_BILLING", pro ? "true" : "false", 1)
            defer {
                if let previous { setenv("BYPASS_BILLING", previous, 1) } else { unsetenv("BYPASS_BILLING") }
            }
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

    private func post(_ app: Application, token: String, _ check: @escaping (TestingHTTPResponse) async throws -> Void) async throws {
        try await app.testing().test(.POST, "v1/terminal-positions/ai/share-facts", beforeRequest: { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(ShareFactsRequest(ticker: "amzn"), as: .json)
        }, afterResponse: check)
    }

    @Test("Free users get 403 upgrade_required")
    func freeIsUpgrade() async throws {
        try await withApp(pro: false) { app in
            app.terminalAIClient = ScriptedTerminalChatClient([.success(factsJSON)])
            let user = try await TerminalFixtures.registerUser(app: app)
            try await post(app, token: user.token) { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("upgrade_required"))
            }
        }
    }

    @Test("Pro gets a sourced suggestion; no client or a failing client is 503")
    func proPaths() async throws {
        try await withApp(pro: true) { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            app.terminalAIClient = ScriptedTerminalChatClient([.success(factsJSON)])
            try await post(app, token: user.token) { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(ShareFactsSuggestion.self)
                #expect(body.ticker == "AMZN")
                #expect(body.sharesOutstanding == 10_600_000_000)
            }
            app.terminalAIClient = ScriptedTerminalChatClient([.failure(Abort(.paymentRequired))])
            try await post(app, token: user.token) { res in
                #expect(res.status == .serviceUnavailable)
            }
            app.terminalAIClient = nil
            try await post(app, token: user.token) { res in
                #expect(res.status == .serviceUnavailable)
            }
        }
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `LOG_LEVEL=warning swift test --filter TerminalAIAdvisorTests`
Expected: compile failure, `cannot find 'TerminalAIAdvisor' in scope`.

- [ ] **Step 3: Edit the billing feature list**

Make the edits to `EntitlementResolver.swift` and `BillingContextService.swift` listed under **Files**.

Verify: `grep -c "terminalPositionAI" Sources/StockPlanBackend/Billing/EntitlementResolver.swift` → `4`.

- [ ] **Step 4: Write the advisor, app storage and controller**

`Sources/StockPlanBackend/TerminalPositions/TerminalPositions+Application.swift`:

```swift
import Vapor

extension Application {
    private struct TerminalAIClientKey: StorageKey {
        typealias Value = any OpenAIChatClient
    }

    /// Web-search chat client for terminal suggestions; nil when no AI key is
    /// configured (the AI routes then answer 503). Tests replace it.
    var terminalAIClient: (any OpenAIChatClient)? {
        get { storage[TerminalAIClientKey.self] }
        set { storage[TerminalAIClientKey.self] = newValue }
    }
}
```

`Sources/StockPlanBackend/TerminalPositions/TerminalAIAdvisor.swift`:

```swift
import Foundation
import StockPlanShared
import Vapor

/// AI suggestions for terminal position sizing. One web-search chat call per
/// suggestion, strict JSON, validated before it reaches the user. It never
/// writes: the user accepts a suggestion in the UI, which then PATCHes.
///
/// No sampling parameters are sent (Haiku 5.5 rejects them), and there is no
/// fallback without web search — a guessed share count is worse than none.
struct TerminalAIAdvisor: Sendable {
    /// OpenRouter's `:online` slug turns on web search.
    static let defaultModel = "anthropic/claude-haiku-4.5:online"
    static let defaultHorizonYears = 10

    let client: any OpenAIChatClient

    static func liveClient() -> (any OpenAIChatClient)? {
        let config = AIProviderConfiguration.load()
        guard !config.apiKey.isEmpty, !config.baseURL.isEmpty else { return nil }
        let configured = Environment.get("TERMINAL_AI_MODEL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DefaultOpenAIChatClient(
            apiKey: config.apiKey,
            model: configured.isEmpty ? defaultModel : configured,
            baseURL: config.baseURL,
            maxTokens: 1200,
            timeout: .seconds(60)
        )
    }

    static let shareFactsPrompt = """
    You look up public company share data with web search. Reply with only a JSON object:
    {"sharesOutstanding": number|null, "currentSharePrice": number|null, "currency": "ISO code"|null, \
    "asOf": "YYYY-MM-DD"|null, "sources": ["https://..."]}
    sharesOutstanding is the latest total shares outstanding from the most recent filing (10-Q, 10-K, \
    or the exchange/regulator equivalent), as a plain number, not in millions. currentSharePrice is the \
    latest price. Every number must come from a source you list; if you cannot find one, use null. \
    Never estimate.
    """

    static let scenarioPrompt = """
    You help an investor sketch ONE terminal scenario for a stock with web search. Reply with only a JSON object:
    {"terminalShareCount": number, "terminalMarketCap": number, "rationale": string, "sources": ["https://..."]}
    terminalShareCount is the share count you expect at the horizon given the dilution or buyback trend in \
    filings. terminalMarketCap is a market cap at the horizon grounded in published analyst ranges or the \
    company's historical growth, in the company's reporting currency, as a plain number. rationale is 1-3 \
    sentences naming what the numbers rest on. This is an assumption to be edited by the user, not a forecast \
    or advice.
    """

    func shareFacts(ticker: String, on req: Request) async throws -> ShareFactsSuggestion {
        let content = try await ask(system: Self.shareFactsPrompt, user: "Ticker: \(ticker)", on: req)
        return try Self.parseShareFacts(content, ticker: ticker)
    }

    func scenario(ticker: String, horizonYears: Int?, on req: Request) async throws -> TerminalScenarioSuggestion {
        let horizon = min(max(horizonYears ?? Self.defaultHorizonYears, 1), 30)
        let content = try await ask(
            system: Self.scenarioPrompt,
            user: "Ticker: \(ticker). Horizon: \(horizon) years.",
            on: req
        )
        return try Self.parseScenario(content, ticker: ticker, horizonYears: horizon)
    }

    private func ask(system: String, user: String, on req: Request) async throws -> String {
        do {
            let reply = try await client.chat(
                messages: [OpenAIMessage(role: "system", content: system), OpenAIMessage(role: "user", content: user)],
                tools: [],
                responseFormat: "json_object",
                on: req
            )
            return reply.content ?? ""
        } catch {
            req.logger.warning("terminal_ai_failed", metadata: ["error": .string(String(describing: error))])
            throw Abort(.serviceUnavailable, reason: "AI lookup unavailable. Try again later or enter the numbers yourself.")
        }
    }

    // MARK: - Parsing

    static let unusable = Abort(
        .unprocessableEntity,
        reason: "The AI answer had no usable, sourced numbers. Try again or enter them yourself."
    )

    static func parseShareFacts(_ content: String, ticker: String) throws -> ShareFactsSuggestion {
        struct Wire: Decodable {
            let sharesOutstanding: Double?
            let currentSharePrice: Double?
            let currency: String?
            let asOf: String?
            let sources: [String]?
        }
        let wire = try decodeObject(Wire.self, from: content)
        if let shares = wire.sharesOutstanding, !(shares.isFinite && shares > 0) { throw unusable }
        if let price = wire.currentSharePrice, !(price.isFinite && price > 0) { throw unusable }
        let sources = httpsSources(wire.sources)
        guard wire.sharesOutstanding != nil || wire.currentSharePrice != nil, !sources.isEmpty else { throw unusable }
        let currency = wire.currency?.trimmingCharacters(in: .whitespaces).uppercased()
        return ShareFactsSuggestion(
            ticker: ticker,
            sharesOutstanding: wire.sharesOutstanding,
            currentSharePrice: wire.currentSharePrice,
            currency: currency.flatMap { $0.count == 3 ? $0 : nil },
            asOf: wire.asOf,
            sources: sources
        )
    }

    static func parseScenario(_ content: String, ticker: String, horizonYears: Int) throws -> TerminalScenarioSuggestion {
        struct Wire: Decodable {
            let terminalShareCount: Double
            let terminalMarketCap: Double
            let rationale: String
            let sources: [String]?
        }
        let wire = try decodeObject(Wire.self, from: content)
        let rationale = wire.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        let sources = httpsSources(wire.sources)
        guard wire.terminalShareCount.isFinite, wire.terminalShareCount > 0,
              wire.terminalMarketCap.isFinite, wire.terminalMarketCap > 0,
              !rationale.isEmpty, rationale.count <= 600, !sources.isEmpty
        else { throw unusable }
        return TerminalScenarioSuggestion(
            ticker: ticker,
            terminalShareCount: wire.terminalShareCount,
            terminalMarketCap: wire.terminalMarketCap,
            horizonYears: horizonYears,
            rationale: rationale,
            sources: sources
        )
    }

    /// Models wrap JSON in fences or prose even under `json_object`: take the
    /// outermost object. Plain `JSONDecoder` so keys are read as written.
    private static func decodeObject<T: Decodable>(_: T.Type, from content: String) throws -> T {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end else {
            throw unusable
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(content[start ... end].utf8))
        } catch {
            throw unusable
        }
    }

    private static func httpsSources(_ raw: [String]?) -> [String] {
        (raw ?? []).compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), url.scheme == "https", url.host?.isEmpty == false else { return nil }
            return trimmed
        }
    }
}
```

`Sources/StockPlanBackend/TerminalPositions/TerminalPositionsAIController.swift`:

```swift
import Foundation
import StockPlanShared
import Vapor

extension ShareFactsRequest: @retroactive Content {}
extension ShareFactsSuggestion: @retroactive Content {}
extension TerminalScenarioSuggestionRequest: @retroactive Content {}
extension TerminalScenarioSuggestion: @retroactive Content {}

/// Pro-only AI suggestions. Registered under the AI rate limit. Suggestions
/// are returned, never stored.
struct TerminalPositionsAIController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let ai = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
            .grouped("terminal-positions", "ai")
            .grouped(ScopeRequirementMiddleware(.planningRead))
        ai.post("share-facts", use: shareFacts)
        ai.post("scenario", use: scenario)
    }

    private func advisor(_ req: Request) async throws -> TerminalAIAdvisor {
        let userId = try req.auth.require(SessionToken.self).userId
        try await req.usageCounterService.requirePremium(.terminalPositionAI, userId: userId, on: req.db)
        guard let client = req.application.terminalAIClient else {
            throw Abort(.serviceUnavailable, reason: "AI lookup unavailable. Try again later or enter the numbers yourself.")
        }
        return TerminalAIAdvisor(client: client)
    }

    @Sendable
    func shareFacts(req: Request) async throws -> ShareFactsSuggestion {
        let advisor = try await advisor(req)
        let input = try req.content.decode(ShareFactsRequest.self)
        return try await advisor.shareFacts(ticker: TerminalPositionsService.normalisedTicker(input.ticker), on: req)
    }

    @Sendable
    func scenario(req: Request) async throws -> TerminalScenarioSuggestion {
        let advisor = try await advisor(req)
        let input = try req.content.decode(TerminalScenarioSuggestionRequest.self)
        return try await advisor.scenario(
            ticker: TerminalPositionsService.normalisedTicker(input.ticker),
            horizonYears: input.horizonYears,
            on: req
        )
    }
}
```

Then the `configure.swift` and `routes.swift` edits listed under **Files**.

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `LOG_LEVEL=warning swift test --filter "TerminalAIAdvisorTests|BillingContext|Entitlement"`
Expected: 5 advisor tests pass, and the existing billing tests stay green.

- [ ] **Step 6: Lint and commit**

```bash
swiftformat Sources/StockPlanBackend/TerminalPositions Sources/StockPlanBackend/Billing/EntitlementResolver.swift Sources/StockPlanBackend/Billing/BillingContextService.swift Tests/StockPlanBackendTests/TerminalAIAdvisorTests.swift
git add Sources/StockPlanBackend/TerminalPositions Sources/StockPlanBackend/Billing Sources/StockPlanBackend/configure.swift Sources/StockPlanBackend/routes.swift Tests/StockPlanBackendTests/TerminalAIAdvisorTests.swift
git commit -m "feat(terminal-positions): Pro AI share-facts and scenario suggestions"
git show --stat HEAD
```

---

### Task 7: Assistant / MCP catalog actions

**Files:**
- Create: `Sources/StockPlanBackend/AI/ActionCatalog+TerminalPositions.swift`
- Modify: `Sources/StockPlanBackend/AI/ActionCatalog.swift` (`all` → append `+ terminalPositionActions`)
- Modify: `Sources/StockPlanBackend/AI/ActionCatalog+Summaries.swift` (`summaryCopy` and `completionCopy` cases)
- Test: `Tests/StockPlanBackendTests/TerminalPositionActionsTests.swift`

**Interfaces:**
- Consumes: `TerminalPositionsService` (Task 4), `TerminalAIAdvisor` and `app.terminalAIClient` (Task 6), `ActionDefinition`, `ActionArguments`, `AIToolContext`, `ActionCatalog.disposition(name:arguments:mode:)`.
- Produces: the catalog actions `get_terminal_positions`, `get_terminal_position`, `lookup_share_facts` and `set_terminal_scenario` (destructive).

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Terminal position actions", .serialized)
struct TerminalPositionActionsTests {
    @Test("set_terminal_scenario always needs confirmation; reads run")
    func confirmation() {
        let args = ActionArguments(["ticker": "AMZN", "valueWanted": 1_000_000])
        for mode in [ActionConfirmationMode.inline, .deferred(requiring: .destructiveOnly), .deferred(requiring: .everyWrite)] {
            guard case .needsConfirmation = ActionCatalog.disposition(name: "set_terminal_scenario", arguments: args, mode: mode) else {
                Issue.record("set_terminal_scenario ran without confirmation in \(mode)")
                continue
            }
        }
        guard case .run = ActionCatalog.disposition(name: "get_terminal_positions", arguments: ActionArguments([:]), mode: .deferred(requiring: .everyWrite)) else {
            Issue.record("get_terminal_positions should run")
            return
        }
    }

    @Test("The confirmation summary names the ticker and the values")
    func summary() {
        let summary = ActionCatalog.confirmationSummary(
            name: "set_terminal_scenario",
            arguments: ActionArguments(["ticker": "amzn", "terminalMarketCap": 10_000_000_000_000, "valueWanted": 1_000_000])
        )
        #expect(summary.contains("AMZN"))
        #expect(summary.contains("10000000000000"))
        #expect(ActionCatalog.hasCopy(for: "lookup_share_facts"))
    }

    @Test("Handlers: incomplete create is an error payload; complete create and read work")
    func handlers() async throws {
        try await TerminalFixtures.withApp { app in
            let user = try await TerminalFixtures.registerUser(app: app)
            let req = Request(application: app, on: app.eventLoopGroup.next())
            let context = AIToolContext(userId: user.userId)
            let set = try #require(ActionCatalog.definition(named: "set_terminal_scenario"))
            let incomplete = try await set.handler(context, ActionArguments(["ticker": "SOFI", "valueWanted": 250_000]), req)
            #expect(incomplete.contains("\"error\""))

            let created = try await set.handler(context, ActionArguments([
                "ticker": "SOFI", "terminalShareCount": 1_750_000_000, "terminalMarketCap": 150_000_000_000, "valueWanted": 250_000,
            ]), req)
            #expect(created.contains("\"ticker\":\"SOFI\""))

            let get = try #require(ActionCatalog.definition(named: "get_terminal_position"))
            let read = try await get.handler(context, ActionArguments(["ticker": "sofi"]), req)
            #expect(read.contains("sharesNeeded"))
            let none = try await get.handler(context, ActionArguments(["ticker": "NVDA"]), req)
            #expect(none.contains("none"))
        }
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `LOG_LEVEL=warning swift test --filter TerminalPositionActionsTests`
Expected: the `confirmation` test fails: `set_terminal_scenario` is unknown.

- [ ] **Step 3: Write the actions, wire them into `all`, and add the copy**

`Sources/StockPlanBackend/AI/ActionCatalog+TerminalPositions.swift`:

```swift
import Foundation
import StockPlanShared
import Vapor

extension ActionCatalog {
    /// Terminal position sizing for the assistant, Telegram and MCP. Planning
    /// math, not advice. The model never computes the derived numbers: Norviq
    /// returns them. `set_terminal_scenario` is destructive so every surface
    /// confirms before an agent changes a user's assumptions.
    static var terminalPositionActions: [ActionDefinition] {
        let service = TerminalPositionsService()
        let ticker = OpenAIParameter(type: "string", description: "Ticker symbol, e.g. AMZN.")
        let number: (String) -> OpenAIParameter = { OpenAIParameter(type: "number", description: $0) }
        return [
            ActionDefinition(
                "get_terminal_positions",
                "List the user's terminal position scenarios with Norviq-computed terminal share price, shares needed and progress. Assumptions, not forecasts; not financial advice.",
                readOnly: true
            ) { context, _, req in
                let rows = try await service.list(userId: context.userId, on: req.db)
                return try await encode(TerminalPositionsListResponse(
                    currency: service.currency(userId: context.userId, on: req.db),
                    positions: rows.map { $0.toResponse() }
                ))
            },

            ActionDefinition(
                "get_terminal_position",
                "Read the user's terminal scenario for one ticker (the first row for that ticker), with Norviq-computed numbers.",
                properties: ["ticker": ticker],
                required: ["ticker"],
                readOnly: true
            ) { context, args, req in
                guard let raw = args.string("ticker"), let symbol = try? TerminalPositionsService.normalisedTicker(raw) else {
                    return errorPayload("ticker is required")
                }
                guard let row = try await service.list(userId: context.userId, ticker: symbol, on: req.db).first else {
                    return statusPayload("none")
                }
                return try encode(row.toResponse())
            },

            ActionDefinition(
                "lookup_share_facts",
                "Look up a ticker's latest shares outstanding and share price with web search. Returns a sourced suggestion only and never changes the user's data. Requires Norviq Pro.",
                properties: ["ticker": ticker],
                required: ["ticker"],
                readOnly: true
            ) { context, args, req in
                guard let raw = args.string("ticker"), let symbol = try? TerminalPositionsService.normalisedTicker(raw) else {
                    return errorPayload("ticker is required")
                }
                do {
                    try await req.usageCounterService.requirePremium(.terminalPositionAI, userId: context.userId, on: req.db)
                } catch {
                    return errorPayload("lookup_share_facts needs Norviq Pro")
                }
                guard let client = req.application.terminalAIClient else { return errorPayload("AI lookup unavailable") }
                do {
                    return try await encode(TerminalAIAdvisor(client: client).shareFacts(ticker: symbol, on: req))
                } catch let abort as any AbortError {
                    return errorPayload(abort.reason)
                }
            },

            ActionDefinition(
                "set_terminal_scenario",
                """
                Create or update the user's terminal scenario for a ticker (updates the first row for that ticker). \
                Only use numbers the user stated or that come from a cited source; never invent a market cap or a value \
                wanted. Do not compute derived values yourself: Norviq computes terminal share price = terminalMarketCap / \
                terminalShareCount and shares needed = valueWanted × terminalShareCount / terminalMarketCap. A new scenario \
                needs terminalShareCount, terminalMarketCap and valueWanted. Planning math, not financial advice.
                """,
                properties: [
                    "ticker": ticker,
                    "terminalShareCount": number("Assumed future share count, including dilution."),
                    "terminalMarketCap": number("Assumed future market cap in the user's currency."),
                    "valueWanted": number("What the user wants the position to be worth at the terminal scenario."),
                    "sharesOwned": number("Shares the user already owns."),
                    "sharesOutstanding": number("Current shares outstanding (reference only)."),
                    "currentSharePrice": number("Current share price, if known."),
                ],
                required: ["ticker"],
                destructive: true
            ) { context, args, req in
                guard let raw = args.string("ticker") else { return errorPayload("ticker is required") }
                let fields = TerminalPositionsService.ScenarioFields(
                    terminalShareCount: args.double("terminalShareCount"),
                    terminalMarketCap: args.double("terminalMarketCap"),
                    valueWanted: args.double("valueWanted"),
                    sharesOwned: args.double("sharesOwned"),
                    sharesOutstanding: args.double("sharesOutstanding"),
                    currentSharePrice: args.double("currentSharePrice")
                )
                do {
                    let row = try await service.upsertScenario(userId: context.userId, ticker: raw, fields: fields, on: req.db)
                    return try encode(row.toResponse())
                } catch let abort as any AbortError {
                    return errorPayload(abort.reason)
                }
            },
        ]
    }
}
```

In `ActionCatalog.swift`, change `all` to:

```swift
        expenseActions + watchlistActions + transactionActions + positionActions + goalActions + terminalPositionActions
```

In `ActionCatalog+Summaries.swift` `summaryCopy`, add these cases before `default:`:

```swift
        case "get_terminal_positions":
            return "Read your terminal position scenarios."
        case "get_terminal_position":
            return "Read your terminal scenario for \(terminalTicker(args))."
        case "lookup_share_facts":
            return "Look up shares outstanding and price for \(terminalTicker(args)) with web search."
        case "set_terminal_scenario":
            return "Set the terminal scenario for \(terminalTicker(args))\(terminalFields(args))."
```

In `completionCopy`, add before `default:`:

```swift
        case "get_terminal_positions", "get_terminal_position", "lookup_share_facts": "Done."
        case "set_terminal_scenario": "Terminal scenario saved."
```

Add these helpers next to `symbol(_:)`. The destructive-summary test passes `symbol`, not `ticker`, so the ticker falls back to it:

```swift
    private static func terminalTicker(_ args: ActionArguments) -> String {
        (args.string("ticker") ?? args.string("symbol"))?.uppercased() ?? "(no ticker)"
    }

    private static func terminalFields(_ args: ActionArguments) -> String {
        let parts = [
            ("share count", "terminalShareCount"), ("market cap", "terminalMarketCap"), ("value wanted", "valueWanted"),
            ("shares owned", "sharesOwned"), ("shares outstanding", "sharesOutstanding"), ("current price", "currentSharePrice"),
        ].compactMap { label, key in args.double(key).map { "\(label) \(number($0))" } }
        return parts.isEmpty ? "" : ": " + parts.joined(separator: ", ")
    }
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `LOG_LEVEL=warning swift test --filter "TerminalPositionActionsTests|ActionCatalogTests"`
Expected: 3 new tests pass, and all existing `ActionCatalogTests` pass, including copy, destructive summaries, unique names and no collisions with read tools.

- [ ] **Step 5: Lint and commit**

```bash
swiftformat Sources/StockPlanBackend/AI/ActionCatalog+TerminalPositions.swift Sources/StockPlanBackend/AI/ActionCatalog.swift Sources/StockPlanBackend/AI/ActionCatalog+Summaries.swift Tests/StockPlanBackendTests/TerminalPositionActionsTests.swift
git add Sources/StockPlanBackend/AI Tests/StockPlanBackendTests/TerminalPositionActionsTests.swift
git commit -m "feat(terminal-positions): assistant and MCP catalog actions with confirm-before-write"
git show --stat HEAD
```

---

### Task 8: OpenAPI documentation

**Files:**
- Modify: `Sources/StockPlanBackend/openapi.yaml`: the paths go before the line `  /v1/goals:`; the schemas go before the line `    GoalResponse:`
- Modify: `Tests/StockPlanBackendTests/OpenAPIDocsTests.swift` (one test inside the suite)

**Interfaces:**
- Produces the operationIds the web plan consumes: `listTerminalPositions`, `createTerminalPosition`, `updateTerminalPosition`, `deleteTerminalPosition`, `duplicateTerminalPosition`, `reorderTerminalPositions`, `getTerminalPositionsSummary`, `listAutobuys`, `createAutobuy`, `updateAutobuy`, `deleteAutobuy`, `suggestTerminalShareFacts`, `suggestTerminalScenario`.

- [ ] **Step 1: Write the failing test**

Append inside `struct OpenAPIDocsTests`:

```swift
    @Test("Terminal position routes and schemas are documented")
    func terminalPositionsAreDocumented() throws {
        let body = try BundledOpenAPISpec.yamlString()
        for operation in [
            "listTerminalPositions", "createTerminalPosition", "updateTerminalPosition", "deleteTerminalPosition",
            "duplicateTerminalPosition", "reorderTerminalPositions", "getTerminalPositionsSummary",
            "listAutobuys", "createAutobuy", "updateAutobuy", "deleteAutobuy",
            "suggestTerminalShareFacts", "suggestTerminalScenario",
        ] {
            #expect(body.contains("operationId: \(operation)"), "missing \(operation)")
        }
        for schema in [
            "TerminalPositionResponse", "TerminalPositionCreateRequest", "TerminalPositionUpdateRequest",
            "TerminalPositionOrderRequest", "TerminalPositionsListResponse", "TerminalPositionsSummaryResponse",
            "AutobuyResponse", "AutobuyCreateRequest", "AutobuyUpdateRequest", "AutobuysListResponse",
            "ShareFactsRequest", "ShareFactsSuggestion", "TerminalScenarioSuggestionRequest", "TerminalScenarioSuggestion",
        ] {
            #expect(body.contains("    \(schema):"), "missing schema \(schema)")
        }
    }
```

Run: `make backend-openapi-check`. Expected: `terminalPositionsAreDocumented` fails.

- [ ] **Step 2: Add the paths**

Insert immediately before `  /v1/goals:`:

```yaml
  /v1/terminal-positions:
    get:
      operationId: listTerminalPositions
      tags: [TerminalPositions]
      summary: List terminal position scenarios
      description: >-
        The user's terminal scenarios in display order. Derived fields (terminal
        share price, shares needed, progress, still needed) are recomputed on
        every read and are null when `scenarioError` is set. Planning math, not
        financial advice.
      security:
        - bearerAuth: []
      parameters:
        - name: ticker
          in: query
          required: false
          description: Only rows for this ticker (case-insensitive).
          schema: { type: string }
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema: { $ref: '#/components/schemas/TerminalPositionsListResponse' }
        '401': { description: Unauthorized }
        '403': { description: Token lacks planning:read }
    post:
      operationId: createTerminalPosition
      tags: [TerminalPositions]
      summary: Create a terminal position scenario
      description: >-
        Appends a row. A share count or market cap of zero or less is stored and
        reported through `scenarioError`; negative value wanted or shares owned
        is 422.
      security:
        - bearerAuth: []
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: '#/components/schemas/TerminalPositionCreateRequest' }
      responses:
        '201':
          description: Created
          content:
            application/json:
              schema: { $ref: '#/components/schemas/TerminalPositionResponse' }
        '401': { description: Unauthorized }
        '403': { description: Token lacks planning:write }
        '422': { description: Invalid ticker or numbers }
  /v1/terminal-positions/summary:
    get:
      operationId: getTerminalPositionsSummary
      tags: [TerminalPositions]
      summary: Totals for the dashboard and the table footer
      description: >-
        Totals over valid rows plus the monthly autobuy total. "Shares-needed
        notional at terminal prices" equals totalValueWanted by construction, so
        it is not a separate field.
      security:
        - bearerAuth: []
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema: { $ref: '#/components/schemas/TerminalPositionsSummaryResponse' }
        '401': { description: Unauthorized }
  /v1/terminal-positions/order:
    put:
      operationId: reorderTerminalPositions
      tags: [TerminalPositions]
      summary: Reorder terminal positions
      security:
        - bearerAuth: []
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: '#/components/schemas/TerminalPositionOrderRequest' }
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema: { $ref: '#/components/schemas/TerminalPositionsListResponse' }
        '422': { description: ids must list every position exactly once }
  /v1/terminal-positions/{id}:
    parameters:
      - name: id
        in: path
        required: true
        schema: { type: string, format: uuid }
    patch:
      operationId: updateTerminalPosition
      tags: [TerminalPositions]
      summary: Update a terminal position (only the fields sent change)
      security:
        - bearerAuth: []
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: '#/components/schemas/TerminalPositionUpdateRequest' }
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema: { $ref: '#/components/schemas/TerminalPositionResponse' }
        '404': { description: Not found }
        '422': { description: Invalid field or unknown clear name }
    delete:
      operationId: deleteTerminalPosition
      tags: [TerminalPositions]
      summary: Delete a terminal position
      security:
        - bearerAuth: []
      responses:
        '204': { description: Deleted }
        '404': { description: Not found }
  /v1/terminal-positions/{id}/duplicate:
    parameters:
      - name: id
        in: path
        required: true
        schema: { type: string, format: uuid }
    post:
      operationId: duplicateTerminalPosition
      tags: [TerminalPositions]
      summary: Duplicate a terminal position right after itself
      security:
        - bearerAuth: []
      responses:
        '201':
          description: Created
          content:
            application/json:
              schema: { $ref: '#/components/schemas/TerminalPositionResponse' }
        '404': { description: Not found }
  /v1/terminal-positions/ai/share-facts:
    post:
      operationId: suggestTerminalShareFacts
      tags: [TerminalPositions]
      summary: AI suggestion for shares outstanding and current price (Pro)
      description: >-
        Web-search suggestion with https sources. Never stored; the client
        applies it only when the user accepts. 403 with code upgrade_required
        for non-Pro users.
      security:
        - bearerAuth: []
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: '#/components/schemas/ShareFactsRequest' }
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema: { $ref: '#/components/schemas/ShareFactsSuggestion' }
        '403': { description: Upgrade required (code upgrade_required) or missing scope }
        '422': { description: No usable, sourced numbers }
        '503': { description: AI lookup unavailable }
  /v1/terminal-positions/ai/scenario:
    post:
      operationId: suggestTerminalScenario
      tags: [TerminalPositions]
      summary: AI suggestion for terminal share count and market cap (Pro)
      security:
        - bearerAuth: []
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: '#/components/schemas/TerminalScenarioSuggestionRequest' }
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema: { $ref: '#/components/schemas/TerminalScenarioSuggestion' }
        '403': { description: Upgrade required (code upgrade_required) or missing scope }
        '422': { description: No usable, sourced numbers }
        '503': { description: AI lookup unavailable }
  /v1/autobuys:
    get:
      operationId: listAutobuys
      tags: [TerminalPositions]
      summary: List recurring autobuys with monthly equivalents
      security:
        - bearerAuth: []
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema: { $ref: '#/components/schemas/AutobuysListResponse' }
    post:
      operationId: createAutobuy
      tags: [TerminalPositions]
      summary: Create a recurring autobuy
      security:
        - bearerAuth: []
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: '#/components/schemas/AutobuyCreateRequest' }
      responses:
        '201':
          description: Created
          content:
            application/json:
              schema: { $ref: '#/components/schemas/AutobuyResponse' }
        '422': { description: Invalid amount, cadence or percent }
  /v1/autobuys/{id}:
    parameters:
      - name: id
        in: path
        required: true
        schema: { type: string, format: uuid }
    patch:
      operationId: updateAutobuy
      tags: [TerminalPositions]
      summary: Update an autobuy
      security:
        - bearerAuth: []
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: '#/components/schemas/AutobuyUpdateRequest' }
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema: { $ref: '#/components/schemas/AutobuyResponse' }
        '404': { description: Not found }
    delete:
      operationId: deleteAutobuy
      tags: [TerminalPositions]
      summary: Delete an autobuy
      security:
        - bearerAuth: []
      responses:
        '204': { description: Deleted }
        '404': { description: Not found }
```

- [ ] **Step 3: Add the schemas**

Insert immediately before `    GoalResponse:`:

```yaml
    TerminalPositionResponse:
      type: object
      properties:
        id: { type: string, format: uuid }
        ticker: { type: string }
        sharesOutstanding: { type: number, nullable: true }
        terminalShareCount: { type: number }
        terminalMarketCap: { type: number }
        valueWanted: { type: number }
        sharesOwned: { type: number }
        currentSharePrice: { type: number, nullable: true }
        notes: { type: string, nullable: true }
        sortOrder: { type: integer }
        terminalSharePrice: { type: number, nullable: true }
        sharesNeeded: { type: number, nullable: true }
        capitalAtTodayPrice: { type: number, nullable: true }
        progress: { type: number, nullable: true }
        sharesStillNeeded: { type: number, nullable: true }
        gapValueAtTerminal: { type: number, nullable: true }
        scenarioError:
          type: string
          nullable: true
          enum: [share_count_not_positive, market_cap_not_positive, invalid_number]
        createdAt: { type: string, format: date-time }
        updatedAt: { type: string, format: date-time }
      required: [id, ticker, terminalShareCount, terminalMarketCap, valueWanted, sharesOwned, sortOrder, createdAt, updatedAt]
    TerminalPositionCreateRequest:
      type: object
      properties:
        ticker: { type: string }
        sharesOutstanding: { type: number, nullable: true }
        terminalShareCount: { type: number }
        terminalMarketCap: { type: number }
        valueWanted: { type: number }
        sharesOwned: { type: number, nullable: true }
        currentSharePrice: { type: number, nullable: true }
        notes: { type: string, nullable: true }
      required: [ticker, terminalShareCount, terminalMarketCap, valueWanted]
    TerminalPositionUpdateRequest:
      type: object
      properties:
        ticker: { type: string }
        sharesOutstanding: { type: number }
        terminalShareCount: { type: number }
        terminalMarketCap: { type: number }
        valueWanted: { type: number }
        sharesOwned: { type: number }
        currentSharePrice: { type: number }
        notes: { type: string }
        clear:
          type: array
          items: { type: string, enum: [sharesOutstanding, currentSharePrice, notes] }
    TerminalPositionOrderRequest:
      type: object
      properties:
        ids:
          type: array
          items: { type: string, format: uuid }
      required: [ids]
    TerminalPositionsListResponse:
      type: object
      properties:
        currency: { type: string }
        positions:
          type: array
          items: { $ref: '#/components/schemas/TerminalPositionResponse' }
      required: [currency, positions]
    TerminalPositionsSummaryResponse:
      type: object
      properties:
        currency: { type: string }
        positionCount: { type: integer }
        totalValueWanted: { type: number }
        totalGapValueAtTerminal: { type: number }
        totalCapitalAtTodayPrice: { type: number, nullable: true }
        pricedPositionCount: { type: integer }
        monthlyAutobuyTotal: { type: number }
        topPositions:
          type: array
          items: { $ref: '#/components/schemas/TerminalPositionResponse' }
      required: [currency, positionCount, totalValueWanted, totalGapValueAtTerminal, pricedPositionCount, monthlyAutobuyTotal, topPositions]
    AutobuyResponse:
      type: object
      properties:
        id: { type: string, format: uuid }
        ticker: { type: string, nullable: true }
        label: { type: string }
        amount: { type: number }
        cadence: { type: string, enum: [weekly, biweekly, bimonthly, monthly, percentOfContribution, unknown] }
        percent: { type: number, nullable: true }
        active: { type: boolean }
        monthlyEquivalent: { type: number, nullable: true }
        createdAt: { type: string, format: date-time }
        updatedAt: { type: string, format: date-time }
      required: [id, label, amount, cadence, active, createdAt, updatedAt]
    AutobuyCreateRequest:
      type: object
      properties:
        ticker: { type: string, nullable: true }
        label: { type: string }
        amount: { type: number }
        cadence: { type: string, enum: [weekly, biweekly, bimonthly, monthly, percentOfContribution] }
        percent: { type: number, nullable: true }
        active: { type: boolean, nullable: true }
      required: [label, amount, cadence]
    AutobuyUpdateRequest:
      type: object
      properties:
        ticker: { type: string }
        label: { type: string }
        amount: { type: number }
        cadence: { type: string, enum: [weekly, biweekly, bimonthly, monthly, percentOfContribution] }
        percent: { type: number }
        active: { type: boolean }
        clear:
          type: array
          items: { type: string, enum: [ticker, percent] }
    AutobuysListResponse:
      type: object
      properties:
        currency: { type: string }
        autobuys:
          type: array
          items: { $ref: '#/components/schemas/AutobuyResponse' }
        monthlyTotal: { type: number }
      required: [currency, autobuys, monthlyTotal]
    ShareFactsRequest:
      type: object
      properties:
        ticker: { type: string }
      required: [ticker]
    ShareFactsSuggestion:
      type: object
      properties:
        ticker: { type: string }
        sharesOutstanding: { type: number, nullable: true }
        currentSharePrice: { type: number, nullable: true }
        currency: { type: string, nullable: true }
        asOf: { type: string, nullable: true }
        sources:
          type: array
          items: { type: string }
      required: [ticker, sources]
    TerminalScenarioSuggestionRequest:
      type: object
      properties:
        ticker: { type: string }
        horizonYears: { type: integer, nullable: true }
      required: [ticker]
    TerminalScenarioSuggestion:
      type: object
      properties:
        ticker: { type: string }
        terminalShareCount: { type: number }
        terminalMarketCap: { type: number }
        horizonYears: { type: integer }
        rationale: { type: string }
        sources:
          type: array
          items: { type: string }
      required: [ticker, terminalShareCount, terminalMarketCap, horizonYears, rationale, sources]
```

- [ ] **Step 4: Run the docs check and parse the YAML**

```bash
make backend-openapi-check
ruby -ryaml -rdate -e 'd=YAML.load_file("Sources/StockPlanBackend/openapi.yaml", permitted_classes: [Date, Time]); p d["paths"].key?("/v1/terminal-positions"), d["components"]["schemas"].key?("TerminalScenarioSuggestion")'
```

Expected: the check passes and the Ruby line prints `true` twice.

- [ ] **Step 5: Commit**

```bash
git add Sources/StockPlanBackend/openapi.yaml Tests/StockPlanBackendTests/OpenAPIDocsTests.swift
git commit -m "docs(terminal-positions): OpenAPI paths and schemas"
git show --stat HEAD
```

---

### Task 9: Full verification and hand-off

- [ ] **Step 1: Run the feature suites and the full suite on Postgres and Redis**

```bash
docker run -d --name tps-test-redis -p 127.0.0.1:56380:6379 redis:7-alpine
export STOCKPLAN_SHARED_PATH=~/Work/production/apps/norviq/norviq-shared TEST_DATABASE_PORT=55443 REDIS_URL=redis://127.0.0.1:56380
LOG_LEVEL=warning swift test --filter "Terminal|ActionCatalog|OpenAPIDocs"
LOG_LEVEL=warning swift test > .superpowers/full.log 2>&1; tail -3 .superpowers/full.log
```

Expected: everything passes. The full suite takes about an hour; if the OS kills it under memory pressure, rerun it once.

- [ ] **Step 2: Lint the whole repo the way CI does**

Run: `swiftformat --lint . 2>&1 | tail -1 && swiftlint lint --quiet | grep -c " error: "`
Expected: `0/... files require formatting` and `0` errors.

- [ ] **Step 3: Hand-off (outward-facing steps, user-approved)**

1. Push shared `main` + v5.21.0. Then run `unset STOCKPLAN_SHARED_PATH && swift package resolve`, and commit `Package.resolved` with "chore(terminal-positions): resolve norviq-shared 5.21.0".
2. `git rebase origin/main`, rerun the feature suites, `git push -u origin feat/terminal-positions` and open the PR. The user merges it.
3. Deploy: dispatch "Deploy to k3s (staging)", check staging, then run `promote-norviq.yml -f service=both`. The iOS 1.4.0 App Store release waits for production to serve `/v1/terminal-positions`.
4. Remove the test containers: `docker rm -f tps-test-pg tps-test-redis`.
