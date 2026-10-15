# Market Brief (backend) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate two shared market briefs every weekday (08:15 morning brief, 22:30 evening recap, Lisbon time) in en and pt-PT, store them, and serve the latest one at `GET /v1/market/brief`.

**Architecture:**
- Index numbers come from Yahoo's chart API.
- The text comes from an OpenRouter model with web search (`:online`). It is checked against those numbers. If that fails, the existing AI fallback chain writes the brief from in-house facts and the brief is marked `degraded`.
- A leader-locked background job runs on a 5-minute timer and fills each Lisbon time slot once.
- The DTOs live in norviq-shared v5.20.0.

**Tech Stack:** Swift 6, Vapor 4, Fluent/Postgres, Swift Testing, norviq-shared (`StockPlanShared`).

**Spec:** `docs/superpowers/specs/2026-10-08-market-brief-design.md`, read it first.

**Scope:** this is plan 1 of 3. It covers shared + backend + staging infra. Web (plan 2) and iOS (plan 3) are written after this API is on staging.

## Global Constraints

**Repositories and branches**
- Backend work happens in the worktree `~/Work/production/apps/norviq/norviq-backend-market-brief` on branch `feat/market-brief`.
- Never touch `~/Work/production/apps/norviq/norviq-backend`. It holds someone else's uncommitted `feat/articles` work.
- Shared work happens in `~/Work/production/apps/norviq/norviq-shared` on `main`. The new tag is **v5.20.0**.
- Infra work happens only in `~/Work/production/platform/infra`, never in `norviq-infra/`.

**Schedule**
- Morning: Monday–Friday, window **08:15–12:00 Europe/Lisbon**.
- Evening: window **22:30–23:59 Europe/Lisbon**.

**Market data (Yahoo)**
- Use `range=1d&interval=1d`, **never `range=5d`**. With 5d, `chartPreviousClose` is wrong.
- Drop any row whose `regularMarketTime` is more than **18 h** old.
- Languages are exactly `en` and `pt-PT`.
- Number formats:
  - pt-PT: `25.032`, `0,77%`
  - en: `25,032`, `0.77%`
  - Index levels at or above 1000 get 0 decimals. Everything else gets 2.

**LLM output**
- The LLM never sets the tone or any row value.
- An unsourced number token that has a separator must match a fact, or the item is dropped.
- Item length limits: morning items **≤400** characters, evening stories **≤1000**.
- A language with fewer than **3** items left is rejected.

**Configuration and access**
- Env flag `MARKET_BRIEF_ENABLED` (default `false`). Model `MARKET_BRIEF_MODEL` (default `anthropic/claude-haiku-4.5:online`).
- Route: `GET /v1/market/brief` in the `market:read` scope group. Header `Cache-Control: private, max-age=300`.

**Testing and commits**
- Tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`).
- DB-backed tests need the dev Postgres: `docker compose -f docker-compose.dev.yml up -d db`.
- Run backend tests with `LOG_LEVEL=warning swift test --filter <Suite>`.
- Pre-commit hook trap (memory: [[norviq-backend-precommit-swiftformat-drift]]): the hook may reformat unrelated files. After every commit, run `git show --stat HEAD`. If unrelated files changed, restore them and re-commit with `--no-verify`.
- Deploys are manual dispatches (memory: [[norviq-deploy-is-manual-dispatch]]). Merging the backend to `main` deploys nothing. Merging to infra `main` deploys immediately (ArgoCD).

## Review Focus

These inputs are not covered by the spec's own test list. Each line names the task whose tests pin it.
1. **LLM reply wrapped in a ```json fence or a sentence.** Despite `json_object`, it must still parse by taking the outermost `{…}` (Task 5).
2. **Yahoo returns 200 with a null price, or with `chartPreviousClose: 0`.** No row and no NaN/∞ percent (Task 3).
3. **Odd `lang` values (`pt`, `pt-BR`, `PT-pt`, `de`, missing).** Anything starting with `pt` resolves to `pt-PT`; everything else resolves to `en` (Task 4, Task 10).
4. **Two replicas or two ticks race on the same slot.** The unique-key violation is reported as `skippedExisting`, not as a failure that burns retry attempts (Task 9).
5. **Every row is stale (market holiday) or Yahoo is blocked.** The brief still saves with `groups: []` and text only (Task 8).

---

### Task 1: Shared DTOs (norviq-shared v5.20.0)

**Files:**
- Create: `norviq-shared/Sources/StockPlanShared/Market/MarketBriefDTOs.swift`
- Test: `norviq-shared/Tests/StockPlanSharedTests/MarketBriefDTOsTests.swift` (if the test target directory has a different name, put the file next to `CryptoMarketsDTOsTests.swift`)

**Interfaces:**
- Produces: `MarketBriefSlot`, `MarketBriefDirection`, `MarketBriefItemKind`, `MarketBriefQuoteRow`, `MarketBriefQuoteGroup`, `MarketBriefItem`, `MarketBriefResponse` and `MarketBriefResponse.empty(language:enabled:)`, all exactly as below.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import StockPlanShared

struct MarketBriefDTOsTests {
    @Test
    func `slot and enum raw values match the wire format`() {
        #expect(MarketBriefSlot.allCases.map(\.rawValue) == ["morning", "evening"])
        #expect(MarketBriefDirection.down.rawValue == "down")
        #expect(MarketBriefItemKind.earnings.rawValue == "earnings")
    }

    @Test
    func `response round-trips through JSON with camelCase keys`() throws {
        let response = MarketBriefResponse(
            enabled: true,
            tradingDate: "2026-10-08",
            slot: .morning,
            language: "pt-PT",
            greeting: "Bom dia,",
            groups: [
                MarketBriefQuoteGroup(
                    id: "eu_open",
                    title: "Abertura europeia negativa",
                    tone: .down,
                    rows: [MarketBriefQuoteRow(symbol: "^GDAXI", flag: "🇩🇪", name: "DAX", level: "25.032", changePercent: "0,77%", direction: .down)]
                ),
            ],
            items: [MarketBriefItem(kind: .highlight, text: "O tom é risk-off.", tickers: [], sourceUrl: nil)],
            generatedAt: "2026-10-08T07:15:00Z",
            degraded: false
        )
        let data = try JSONEncoder().encode(response)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"tradingDate\""))
        #expect(json.contains("\"changePercent\""))
        #expect(try JSONDecoder().decode(MarketBriefResponse.self, from: data) == response)
    }

    @Test
    func `empty response carries no brief`() {
        let empty = MarketBriefResponse.empty(language: "en", enabled: false)
        #expect(empty.enabled == false)
        #expect(empty.tradingDate == nil)
        #expect(empty.slot == nil)
        #expect(empty.groups.isEmpty)
        #expect(empty.items.isEmpty)
        #expect(empty.degraded == false)
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `cd ~/Work/production/apps/norviq/norviq-shared && swift test --filter MarketBriefDTOsTests`
Expected: compile failure, `cannot find 'MarketBriefResponse' in scope`.

- [ ] **Step 3: Write the DTOs**

```swift
import Foundation

/// Which of the two daily briefs. Morning runs 15 minutes after the European
/// open (08:15 Lisbon); evening runs after the US close (22:30 Lisbon).
public enum MarketBriefSlot: String, Codable, Sendable, CaseIterable, Hashable {
    case morning
    case evening
}

/// Sign of a move. Clients draw 🟢 / 🔴 / ⚪️ from it; the formatted numbers
/// stay unsigned.
public enum MarketBriefDirection: String, Codable, Sendable {
    case up
    case down
    case flat
}

public enum MarketBriefItemKind: String, Codable, Sendable {
    /// Morning 📌 line.
    case highlight
    /// Morning 📍 line: a company reporting today.
    case earnings
    /// Evening numbered story.
    case story
}

/// One index line, e.g. 🇩🇪 DAX → 25.032 → 🔴 0,77%.
public struct MarketBriefQuoteRow: Codable, Sendable, Equatable {
    public let symbol: String
    public let flag: String
    public let name: String
    /// Already formatted for `MarketBriefResponse.language`, e.g. "25.032".
    public let level: String
    /// Unsigned and formatted, e.g. "0,77%". `direction` carries the sign.
    public let changePercent: String
    public let direction: MarketBriefDirection

    public init(
        symbol: String,
        flag: String,
        name: String,
        level: String,
        changePercent: String,
        direction: MarketBriefDirection
    ) {
        self.symbol = symbol
        self.flag = flag
        self.name = name
        self.level = level
        self.changePercent = changePercent
        self.direction = direction
    }
}

/// A headed block of rows, e.g. "Futuros americanos negativos".
public struct MarketBriefQuoteGroup: Codable, Sendable, Equatable {
    /// `eu_open`, `us_futures`, `eu_close` or `us_close`.
    public let id: String
    public let title: String
    /// Worked out on the server from the rows; never written by the model.
    public let tone: MarketBriefDirection
    public let rows: [MarketBriefQuoteRow]

    public init(id: String, title: String, tone: MarketBriefDirection, rows: [MarketBriefQuoteRow]) {
        self.id = id
        self.title = title
        self.tone = tone
        self.rows = rows
    }
}

/// One line of text. Summarised, never copied from a publisher.
public struct MarketBriefItem: Codable, Sendable, Equatable {
    public let kind: MarketBriefItemKind
    public let text: String
    /// Without the "$", e.g. ["NVDA"].
    public let tickers: [String]
    /// The https source the line came from, when it used web search.
    public let sourceUrl: String?

    public init(kind: MarketBriefItemKind, text: String, tickers: [String], sourceUrl: String?) {
        self.kind = kind
        self.text = text
        self.tickers = tickers
        self.sourceUrl = sourceUrl
    }
}

/// `GET /v1/market/brief`. The same for every user; only the language varies.
public struct MarketBriefResponse: Codable, Sendable, Equatable {
    public let enabled: Bool
    /// Lisbon calendar date, `yyyy-MM-dd`. Nil when no brief exists yet.
    public let tradingDate: String?
    public let slot: MarketBriefSlot?
    /// `en` or `pt-PT`.
    public let language: String
    public let greeting: String?
    /// Empty when no market data was fresh (holiday, provider down).
    public let groups: [MarketBriefQuoteGroup]
    public let items: [MarketBriefItem]
    /// ISO 8601. Nil when no brief exists yet.
    public let generatedAt: String?
    /// True when web search was unavailable and the text came from in-house
    /// sources only.
    public let degraded: Bool

    public init(
        enabled: Bool,
        tradingDate: String?,
        slot: MarketBriefSlot?,
        language: String,
        greeting: String?,
        groups: [MarketBriefQuoteGroup],
        items: [MarketBriefItem],
        generatedAt: String?,
        degraded: Bool
    ) {
        self.enabled = enabled
        self.tradingDate = tradingDate
        self.slot = slot
        self.language = language
        self.greeting = greeting
        self.groups = groups
        self.items = items
        self.generatedAt = generatedAt
        self.degraded = degraded
    }

    /// Feature off (`enabled: false`) or on with nothing generated yet.
    public static func empty(language: String, enabled: Bool) -> MarketBriefResponse {
        MarketBriefResponse(
            enabled: enabled,
            tradingDate: nil,
            slot: nil,
            language: language,
            greeting: nil,
            groups: [],
            items: [],
            generatedAt: nil,
            degraded: false
        )
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `swift test --filter MarketBriefDTOsTests`
Expected: 3 tests pass. Then run `swift test` and confirm the whole suite is green.

- [ ] **Step 5: Commit, then tag (ask the user before pushing)**

```bash
git add Sources/StockPlanShared/Market/MarketBriefDTOs.swift Tests/*/MarketBriefDTOsTests.swift
git commit -m "feat(market-brief): add market brief DTOs"
git show --stat HEAD   # only the two files
git tag v5.20.0
# Outward-facing: confirm with the user, then
git push origin main v5.20.0
```

---

### Task 2: Pin shared 5.20.0 and add the slot schedule

**Files:**
- Modify: `Package.swift:9` (`exact: "5.18.0"` → `exact: "5.20.0"`), then let `Package.resolved` update itself.
- Create: `Sources/StockPlanBackend/MarketBrief/MarketBriefSchedule.swift`
- Test: `Tests/StockPlanBackendTests/MarketBriefScheduleTests.swift`

**Interfaces:**
- Consumes: `MarketBriefSlot` (Task 1).
- Produces:
  - `MarketBriefSchedule.Due` (`tradingDate: String`, `slot: MarketBriefSlot`; Hashable, Sendable)
  - `MarketBriefSchedule.dueSlot(now: Date) -> Due?`
  - `MarketBriefSchedule.localDate(_ now: Date) -> String`
  - `MarketBriefSchedule.timeZone`

- [ ] **Step 1: Bump the pin and resolve**

Edit `Package.swift:9` to `exact: "5.20.0"`. Run: `swift package resolve`. Expected: `Package.resolved` now names `5.20.0`.

- [ ] **Step 2: Write the failing test**

```swift
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Market brief schedule")
struct MarketBriefScheduleTests {
    private func at(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    private func due(_ date: String, _ slot: MarketBriefSlot) -> MarketBriefSchedule.Due {
        MarketBriefSchedule.Due(tradingDate: date, slot: slot)
    }

    @Test("Winter (WET, UTC+0): morning opens at 08:15 UTC")
    func winterMorning() throws {
        // Friday 2026-03-27, two days before the clocks go forward.
        #expect(MarketBriefSchedule.dueSlot(now: try at("2026-03-27T08:14:00Z")) == nil)
        #expect(MarketBriefSchedule.dueSlot(now: try at("2026-03-27T08:15:00Z")) == due("2026-03-27", .morning))
    }

    @Test("Summer (WEST, UTC+1): morning opens at 07:15 UTC")
    func summerMorning() throws {
        // Monday 2026-03-30, the first weekday after the change.
        #expect(MarketBriefSchedule.dueSlot(now: try at("2026-03-30T07:14:00Z")) == nil)
        #expect(MarketBriefSchedule.dueSlot(now: try at("2026-03-30T07:15:00Z")) == due("2026-03-30", .morning))
    }

    @Test("Evening either side of the October change")
    func eveningAcrossOctoberChange() throws {
        // Friday 2026-10-23 is still WEST: 22:30 Lisbon is 21:30 UTC.
        #expect(MarketBriefSchedule.dueSlot(now: try at("2026-10-23T21:29:00Z")) == nil)
        #expect(MarketBriefSchedule.dueSlot(now: try at("2026-10-23T21:30:00Z")) == due("2026-10-23", .evening))
        // Monday 2026-10-26 is WET: 08:15 Lisbon is 08:15 UTC.
        #expect(MarketBriefSchedule.dueSlot(now: try at("2026-10-26T08:15:00Z")) == due("2026-10-26", .morning))
    }

    @Test("A late boot still catches the morning; noon closes it")
    func lateBootAndWindowEnd() throws {
        // Wednesday 2026-10-07, WEST. 11:59 Lisbon = 10:59 UTC.
        #expect(MarketBriefSchedule.dueSlot(now: try at("2026-10-07T10:59:00Z")) == due("2026-10-07", .morning))
        #expect(MarketBriefSchedule.dueSlot(now: try at("2026-10-07T11:00:00Z")) == nil)
    }

    @Test("Evening runs to local midnight and belongs to that Lisbon date")
    func eveningUntilMidnight() throws {
        // Thursday 2026-10-08 23:59 Lisbon = 22:59 UTC; Friday 00:00 Lisbon = 23:00 UTC.
        #expect(MarketBriefSchedule.dueSlot(now: try at("2026-10-08T22:59:00Z")) == due("2026-10-08", .evening))
        #expect(MarketBriefSchedule.dueSlot(now: try at("2026-10-08T23:00:00Z")) == nil)
    }

    @Test("Weekends never run")
    func weekend() throws {
        #expect(MarketBriefSchedule.dueSlot(now: try at("2026-10-10T09:00:00Z")) == nil) // Saturday
        #expect(MarketBriefSchedule.dueSlot(now: try at("2026-10-11T21:45:00Z")) == nil) // Sunday
    }

    @Test("localDate uses Lisbon, not UTC")
    func localDate() throws {
        // 23:30 UTC on 2026-10-08 is already 00:30 on the 9th in Lisbon (WEST).
        #expect(MarketBriefSchedule.localDate(try at("2026-10-08T23:30:00Z")) == "2026-10-09")
    }
}
```

- [ ] **Step 3: Run the test and confirm it fails**

Run: `LOG_LEVEL=warning swift test --filter MarketBriefScheduleTests`
Expected: compile failure, `cannot find 'MarketBriefSchedule' in scope`.

- [ ] **Step 4: Write the schedule**

```swift
import Foundation
import StockPlanShared

/// When each brief is due. Pure: the job asks it on every tick.
///
/// Everything is computed in Europe/Lisbon local time, so daylight saving
/// needs no special case: 08:15 Lisbon is 08:15 UTC in winter and 07:15 UTC
/// in summer, and the calendar does that arithmetic.
///
/// Each slot is a window, not an instant, so a pod that boots late (or a
/// tick that fails) still produces the brief on a later tick.
enum MarketBriefSchedule {
    struct Due: Hashable, Sendable {
        /// Lisbon calendar date, `yyyy-MM-dd`.
        let tradingDate: String
        let slot: MarketBriefSlot
    }

    // swiftlint:disable:next force_unwrapping
    static let timeZone = TimeZone(identifier: "Europe/Lisbon")!

    /// Minutes since local midnight. The morning window opens 15 minutes after
    /// the European cash open so the European rows are live, not yesterday's.
    static let morningStart = 8 * 60 + 15
    static let morningEnd = 12 * 60
    static let eveningStart = 22 * 60 + 30
    static let eveningEnd = 24 * 60

    static func dueSlot(now: Date) -> Due? {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard let weekday = parts.weekday, (2 ... 6).contains(weekday),
              let hour = parts.hour, let minute = parts.minute
        else { return nil }
        let minutes = hour * 60 + minute
        if minutes >= morningStart, minutes < morningEnd {
            return Due(tradingDate: localDate(now), slot: .morning)
        }
        if minutes >= eveningStart, minutes < eveningEnd {
            return Due(tradingDate: localDate(now), slot: .evening)
        }
        return nil
    }

    static func localDate(_ now: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return "\(parts.year ?? 0)-\(pad(parts.month ?? 0))-\(pad(parts.day ?? 0))"
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `LOG_LEVEL=warning swift test --filter MarketBriefScheduleTests`
Expected: 7 tests pass. Also run `swift build` to confirm that the jump from 5.18 to 5.20, which pulls in the Articles DTOs from 5.19, builds cleanly.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved Sources/StockPlanBackend/MarketBrief/MarketBriefSchedule.swift Tests/StockPlanBackendTests/MarketBriefScheduleTests.swift
git commit -m "feat(market-brief): pin shared 5.20.0 and add Lisbon slot schedule"
git show --stat HEAD
```

---

### Task 3: Yahoo chart quote provider

**Files:**
- Create: `Sources/StockPlanBackend/MarketBrief/IndexQuoteProvider.swift`
- Test: `Tests/StockPlanBackendTests/YahooChartQuoteProviderTests.swift`

**Interfaces:**
- Produces:
  - `struct IndexQuote: Equatable, Sendable`, with fields `symbol: String`, `price: Double`, `previousClose: Double`, `marketTime: Date` and computed `changePercent: Double`.
  - `protocol IndexQuoteProvider: Sendable`, with `func quotes(symbols: [String], now: Date, on req: Request) async -> [IndexQuote]`. It never throws: failed, missing and stale symbols are simply left out.
  - `struct YahooChartQuoteProvider: IndexQuoteProvider`, with `static func parse(_ data: Data) throws -> IndexQuote?` and `static func isFresh(_ quote: IndexQuote, now: Date) -> Bool`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
@testable import StockPlanBackend
import Testing

@Suite("Yahoo chart quote provider")
struct YahooChartQuoteProviderTests {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    @Test("Reads price, previous close and market time from meta")
    func parsesMeta() throws {
        let json = """
        {"chart":{"result":[{"meta":{"symbol":"^GDAXI","currency":"EUR","regularMarketPrice":24806.97,\
        "chartPreviousClose":25104.36,"regularMarketTime":1791475200}}],"error":null}}
        """
        let quote = try #require(try YahooChartQuoteProvider.parse(data(json)))
        #expect(quote.symbol == "^GDAXI")
        #expect(quote.price == 24806.97)
        #expect(quote.previousClose == 25104.36)
        #expect(quote.marketTime == Date(timeIntervalSince1970: 1_791_475_200))
        #expect(abs(quote.changePercent - -1.1846) < 0.001)
    }

    @Test("Unknown symbol: Yahoo's error envelope yields no quote")
    func errorEnvelope() throws {
        let json = """
        {"chart":{"result":null,"error":{"code":"Not Found","description":"No data found, symbol may be delisted"}}}
        """
        #expect(try YahooChartQuoteProvider.parse(data(json)) == nil)
    }

    @Test("Missing or zero previous close, or missing price, yields no quote (never NaN or infinity)")
    func incompleteMeta() throws {
        let noPrevious = #"{"chart":{"result":[{"meta":{"symbol":"X","regularMarketPrice":10,"regularMarketTime":1}}]}}"#
        let zeroPrevious = #"{"chart":{"result":[{"meta":{"symbol":"X","regularMarketPrice":10,"chartPreviousClose":0,"regularMarketTime":1}}]}}"#
        let nullPrice = #"{"chart":{"result":[{"meta":{"symbol":"X","regularMarketPrice":null,"chartPreviousClose":9,"regularMarketTime":1}}]}}"#
        #expect(try YahooChartQuoteProvider.parse(data(noPrevious)) == nil)
        #expect(try YahooChartQuoteProvider.parse(data(zeroPrevious)) == nil)
        #expect(try YahooChartQuoteProvider.parse(data(nullPrice)) == nil)
    }

    @Test("A non-JSON body (rate-limit HTML page) throws")
    func htmlThrows() {
        #expect(throws: (any Error).self) {
            try YahooChartQuoteProvider.parse(data("<html>Too Many Requests</html>"))
        }
    }

    @Test("Quotes older than 18 hours are stale")
    func freshness() {
        let now = Date(timeIntervalSince1970: 1_791_500_000)
        let fresh = IndexQuote(symbol: "A", price: 1, previousClose: 1, marketTime: now.addingTimeInterval(-17 * 3600))
        let stale = IndexQuote(symbol: "A", price: 1, previousClose: 1, marketTime: now.addingTimeInterval(-19 * 3600))
        #expect(YahooChartQuoteProvider.isFresh(fresh, now: now))
        #expect(!YahooChartQuoteProvider.isFresh(stale, now: now))
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `LOG_LEVEL=warning swift test --filter YahooChartQuoteProviderTests`
Expected: compile failure, `cannot find 'YahooChartQuoteProvider' in scope`.

- [ ] **Step 3: Write the provider**

```swift
import Foundation
import Vapor

struct IndexQuote: Equatable, Sendable {
    let symbol: String
    let price: Double
    let previousClose: Double
    /// When the price was last updated at its exchange.
    let marketTime: Date

    var changePercent: Double {
        (price / previousClose - 1) * 100
    }
}

/// Index, futures, yield and commodity levels for the market brief.
protocol IndexQuoteProvider: Sendable {
    /// Never throws. A symbol that fails, is unknown or is stale is left out,
    /// so one bad row never costs the whole brief.
    func quotes(symbols: [String], now: Date, on req: Request) async -> [IndexQuote]
}

/// Yahoo's public chart endpoint. Unofficial and keyless: it can rate-limit
/// or start demanding a cookie, which is why it sits behind a protocol and
/// why every failure degrades to a missing row.
///
/// `range=1d` is load-bearing. With `range=5d`, `meta.chartPreviousClose` is
/// the close from *before the five-day window*, not yesterday's close, and
/// every percentage is wrong (checked 2026-10-08).
struct YahooChartQuoteProvider: IndexQuoteProvider {
    static let defaultBaseURL = "https://query1.finance.yahoo.com/v8/finance/chart/"
    /// Older than this, the row would show a previous session's move as today's.
    /// It also drops a market that is shut for a holiday.
    static let maxAge: TimeInterval = 18 * 3600
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    let baseURL: String

    init(baseURL: String = Self.defaultBaseURL) {
        self.baseURL = baseURL
    }

    func quotes(symbols: [String], now: Date, on req: Request) async -> [IndexQuote] {
        var result: [IndexQuote] = []
        // Sequential on purpose: about a dozen calls twice a day does not need
        // concurrency, and a burst is what gets an IP throttled.
        for symbol in symbols {
            do {
                guard let quote = try await fetch(symbol, on: req) else {
                    req.logger.warning("market_brief_quote_missing", metadata: ["symbol": .string(symbol)])
                    continue
                }
                guard Self.isFresh(quote, now: now) else {
                    req.logger.info("market_brief_quote_stale", metadata: ["symbol": .string(symbol)])
                    continue
                }
                result.append(quote)
            } catch {
                req.logger.warning(
                    "market_brief_quote_failed",
                    metadata: ["symbol": .string(symbol), "error": .string(String(describing: error))]
                )
            }
        }
        return result
    }

    static func isFresh(_ quote: IndexQuote, now: Date) -> Bool {
        now.timeIntervalSince(quote.marketTime) <= maxAge
    }

    static func parse(_ data: Data) throws -> IndexQuote? {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let meta = envelope.chart.result?.first?.meta,
              let price = meta.regularMarketPrice, price.isFinite, price > 0,
              let previous = meta.chartPreviousClose, previous.isFinite, previous > 0,
              let time = meta.regularMarketTime
        else { return nil }
        return IndexQuote(
            symbol: meta.symbol,
            price: price,
            previousClose: previous,
            marketTime: Date(timeIntervalSince1970: time)
        )
    }

    private func fetch(_ symbol: String, on req: Request) async throws -> IndexQuote? {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? symbol
        let response = try await req.client.get(URI(string: "\(baseURL)\(encoded)?range=1d&interval=1d")) { clientRequest in
            clientRequest.headers.replaceOrAdd(name: .userAgent, value: Self.userAgent)
            clientRequest.headers.replaceOrAdd(name: .accept, value: "application/json")
            clientRequest.timeout = .seconds(8)
        }
        guard let body = response.body else { return nil }
        return try Self.parse(Data(buffer: body))
    }

    private struct Envelope: Decodable {
        let chart: Chart

        struct Chart: Decodable {
            let result: [Result]?
        }

        struct Result: Decodable {
            let meta: Meta
        }

        struct Meta: Decodable {
            let symbol: String
            let regularMarketPrice: Double?
            let chartPreviousClose: Double?
            let regularMarketTime: Double?
        }
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `LOG_LEVEL=warning swift test --filter YahooChartQuoteProviderTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/StockPlanBackend/MarketBrief/IndexQuoteProvider.swift Tests/StockPlanBackendTests/YahooChartQuoteProviderTests.swift
git commit -m "feat(market-brief): Yahoo chart quote provider with freshness guard"
git show --stat HEAD
```

---

### Task 4: Instrument catalog, language and number formatting

**Files:**
- Create: `Sources/StockPlanBackend/MarketBrief/MarketBriefCatalog.swift`
- Create: `Sources/StockPlanBackend/MarketBrief/MarketBriefFormatter.swift`
- Test: `Tests/StockPlanBackendTests/MarketBriefFormatterTests.swift`

**Interfaces:**
- Consumes: `IndexQuote` (Task 3), `MarketBriefSlot`, `MarketBriefDirection`, `MarketBriefQuoteGroup`, `MarketBriefQuoteRow` (Task 1).
- Produces:
  - `enum MarketBriefLanguage: String, CaseIterable, Sendable { case en; case ptPT = "pt-PT" }` with `static func resolve(_ raw: String?) -> MarketBriefLanguage`.
  - `MarketBriefCatalog`, with:
    - `.Instrument` (`symbol`, `flag`, `name`)
    - `.GroupSpec` (`id`, `instruments`)
    - `static func groups(for: MarketBriefSlot) -> [GroupSpec]`
    - `static let context: [Instrument]`
    - `static func instruments(for: MarketBriefSlot) -> [Instrument]`
    - `static func instrument(symbol: String) -> Instrument?`
    - `static func title(groupId: String, tone: MarketBriefDirection, language: MarketBriefLanguage) -> String`
  - `MarketBriefFormatter`, with:
    - `static func number(_: Double, decimals: Int, language: MarketBriefLanguage) -> String`
    - `static func level(_: Double, language:) -> String`
    - `static func percent(_: Double, language:) -> String`
    - `static func direction(_: Double) -> MarketBriefDirection`
    - `static func tone(_: [Double]) -> MarketBriefDirection`
    - `static func groups(slot: MarketBriefSlot, quotes: [IndexQuote], language: MarketBriefLanguage) -> [MarketBriefQuoteGroup]`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Market brief formatting")
struct MarketBriefFormatterTests {
    private let now = Date(timeIntervalSince1970: 1_791_500_000)

    private func quote(_ symbol: String, _ price: Double, _ previous: Double) -> IndexQuote {
        IndexQuote(symbol: symbol, price: price, previousClose: previous, marketTime: now)
    }

    @Test("Index levels: dot thousands in pt-PT, comma thousands in en, no decimals at 1000+")
    func levels() {
        #expect(MarketBriefFormatter.level(25032.36, language: .ptPT) == "25.032")
        #expect(MarketBriefFormatter.level(25032.36, language: .en) == "25,032")
        #expect(MarketBriefFormatter.level(1_234_567, language: .en) == "1,234,567")
        #expect(MarketBriefFormatter.level(7698.4, language: .ptPT) == "7.698")
    }

    @Test("Small levels keep two decimals")
    func smallLevels() {
        #expect(MarketBriefFormatter.level(104.1, language: .ptPT) == "104,10")
        #expect(MarketBriefFormatter.level(104.1, language: .en) == "104.10")
        #expect(MarketBriefFormatter.level(5.231, language: .en) == "5.23")
    }

    @Test("Percent is unsigned; direction carries the sign")
    func percents() {
        #expect(MarketBriefFormatter.percent(-0.774, language: .ptPT) == "0,77%")
        #expect(MarketBriefFormatter.percent(-0.774, language: .en) == "0.77%")
        #expect(MarketBriefFormatter.percent(1.156, language: .ptPT) == "1,16%")
        #expect(MarketBriefFormatter.direction(-0.774) == .down)
        #expect(MarketBriefFormatter.direction(0.006) == .up)
        #expect(MarketBriefFormatter.direction(-0.004) == .flat)
    }

    @Test("Tone is the mean move with a ±0.15 point flat band")
    func tone() {
        #expect(MarketBriefFormatter.tone([-0.77, -0.94, -1.15]) == .down)
        #expect(MarketBriefFormatter.tone([0.4, 0.2]) == .up)
        #expect(MarketBriefFormatter.tone([0.1, -0.1]) == .flat)
        #expect(MarketBriefFormatter.tone([]) == .flat)
    }

    @Test("Morning groups: rows in catalog order, missing instruments skipped, empty groups dropped")
    func morningGroups() {
        let quotes = [quote("NQ=F", 31243, 31403), quote("^GDAXI", 25032, 25226)]
        let groups = MarketBriefFormatter.groups(slot: .morning, quotes: quotes, language: .ptPT)
        #expect(groups.map(\.id) == ["eu_open", "us_futures"])
        #expect(groups[0].rows.map(\.name) == ["DAX"])
        #expect(groups[0].rows[0].level == "25.032")
        #expect(groups[0].rows[0].changePercent == "0,77%")
        #expect(groups[0].rows[0].direction == .down)
        #expect(groups[0].title == "Abertura europeia negativa")
        #expect(groups[1].title == "Futuros americanos negativos")

        let usOnly = MarketBriefFormatter.groups(slot: .morning, quotes: [quote("ES=F", 7830, 7877)], language: .en)
        #expect(usOnly.map(\.id) == ["us_futures"])
        #expect(usOnly[0].title == "US futures lower")
    }

    @Test("Context instruments never become rows")
    func contextNotRows() {
        let groups = MarketBriefFormatter.groups(slot: .morning, quotes: [quote("BZ=F", 104, 100)], language: .en)
        #expect(groups.isEmpty)
    }

    @Test("Language resolution: pt-anything is pt-PT, everything else is en")
    func languageResolution() {
        #expect(MarketBriefLanguage.resolve("pt-PT") == .ptPT)
        #expect(MarketBriefLanguage.resolve("pt") == .ptPT)
        #expect(MarketBriefLanguage.resolve("PT-pt") == .ptPT)
        #expect(MarketBriefLanguage.resolve("pt-BR") == .ptPT)
        #expect(MarketBriefLanguage.resolve("de") == .en)
        #expect(MarketBriefLanguage.resolve(nil) == .en)
        #expect(MarketBriefLanguage.resolve("") == .en)
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `LOG_LEVEL=warning swift test --filter MarketBriefFormatterTests`
Expected: compile failure, `cannot find 'MarketBriefFormatter' in scope`.

- [ ] **Step 3: Write the catalog**

`Sources/StockPlanBackend/MarketBrief/MarketBriefCatalog.swift`:

```swift
import StockPlanShared

/// The two languages a brief is written in. The app has no pt-BR, so any
/// `pt*` request gets European Portuguese.
enum MarketBriefLanguage: String, CaseIterable, Sendable {
    case en
    case ptPT = "pt-PT"

    static func resolve(_ raw: String?) -> MarketBriefLanguage {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), raw.hasPrefix("pt") else {
            return .en
        }
        return .ptPT
    }
}

/// Which symbols the brief shows, in which order, under which heading.
///
/// Yahoo has no European index futures (FDAX=F, FESX=F and FCE=F all 404),
/// which is why the morning brief runs after the European open and shows
/// opening moves of the cash indices.
enum MarketBriefCatalog {
    struct Instrument: Sendable, Equatable {
        let symbol: String
        let flag: String
        let name: String
    }

    struct GroupSpec: Sendable {
        let id: String
        let instruments: [Instrument]
    }

    static let dax = Instrument(symbol: "^GDAXI", flag: "🇩🇪", name: "DAX")
    static let cac = Instrument(symbol: "^FCHI", flag: "🇫🇷", name: "CAC 40")
    static let stoxx = Instrument(symbol: "^STOXX50E", flag: "🇪🇺", name: "Euro Stoxx 50")
    static let nasdaqFutures = Instrument(symbol: "NQ=F", flag: "🇺🇸", name: "Nasdaq 100")
    static let spFutures = Instrument(symbol: "ES=F", flag: "🇺🇸", name: "S&P 500")
    static let nasdaq = Instrument(symbol: "^NDX", flag: "🇺🇸", name: "Nasdaq 100")
    static let sp = Instrument(symbol: "^GSPC", flag: "🇺🇸", name: "S&P 500")
    static let dow = Instrument(symbol: "^DJI", flag: "🇺🇸", name: "Dow Jones")

    /// Facts for the model only; never rendered as rows. ^TNX's price is the
    /// yield in percent.
    static let context: [Instrument] = [
        Instrument(symbol: "^N225", flag: "🇯🇵", name: "Nikkei 225"),
        Instrument(symbol: "^HSI", flag: "🇭🇰", name: "Hang Seng"),
        Instrument(symbol: "BZ=F", flag: "🛢️", name: "Brent crude"),
        Instrument(symbol: "^TNX", flag: "🇺🇸", name: "US 10-year Treasury yield"),
    ]

    static func groups(for slot: MarketBriefSlot) -> [GroupSpec] {
        switch slot {
        case .morning:
            [
                GroupSpec(id: "eu_open", instruments: [dax, cac, stoxx]),
                GroupSpec(id: "us_futures", instruments: [nasdaqFutures, spFutures]),
            ]
        case .evening:
            [
                GroupSpec(id: "eu_close", instruments: [dax, cac, stoxx]),
                GroupSpec(id: "us_close", instruments: [nasdaq, sp, dow]),
            ]
        }
    }

    /// Everything fetched for a slot: its rows plus the context facts.
    static func instruments(for slot: MarketBriefSlot) -> [Instrument] {
        groups(for: slot).flatMap(\.instruments) + context
    }

    static func instrument(symbol: String) -> Instrument? {
        (MarketBriefSlot.allCases.flatMap { groups(for: $0).flatMap(\.instruments) } + context)
            .first { $0.symbol == symbol }
    }

    /// Headings agree in gender and number in Portuguese, hence a table rather
    /// than "<label> <tone word>".
    static func title(groupId: String, tone: MarketBriefDirection, language: MarketBriefLanguage) -> String {
        let entry = titles[groupId]?[tone] ?? (en: groupId, pt: groupId)
        return language == .en ? entry.en : entry.pt
    }

    private static let titles: [String: [MarketBriefDirection: (en: String, pt: String)]] = [
        "eu_open": [
            .up: ("European open higher", "Abertura europeia positiva"),
            .down: ("European open lower", "Abertura europeia negativa"),
            .flat: ("European open mixed", "Abertura europeia mista"),
        ],
        "us_futures": [
            .up: ("US futures higher", "Futuros americanos positivos"),
            .down: ("US futures lower", "Futuros americanos negativos"),
            .flat: ("US futures mixed", "Futuros americanos mistos"),
        ],
        "eu_close": [
            .up: ("Europe closed higher", "Europa fecha em alta"),
            .down: ("Europe closed lower", "Europa fecha em queda"),
            .flat: ("Europe closed mixed", "Europa fecha mista"),
        ],
        "us_close": [
            .up: ("Wall Street closed higher", "Wall Street fecha em alta"),
            .down: ("Wall Street closed lower", "Wall Street fecha em queda"),
            .flat: ("Wall Street closed mixed", "Wall Street fecha mista"),
        ],
    ]
}
```

- [ ] **Step 4: Write the formatter**

`Sources/StockPlanBackend/MarketBrief/MarketBriefFormatter.swift`:

```swift
import Foundation
import StockPlanShared

/// Turns quotes into display rows, formatted on the server so neither client
/// formats numbers.
///
/// Hand-rolled rather than `NumberFormatter`: ICU's pt_PT uses a space as the
/// thousands separator and skips grouping for four-digit numbers ("7698"),
/// but the brief's house style is "7.698", and Linux and Darwin ICU builds
/// do not always agree.
enum MarketBriefFormatter {
    /// Mean moves inside ±0.15 points read as "mixed", not up or down.
    static let toneBand = 0.15

    static func number(_ value: Double, decimals: Int, language: MarketBriefLanguage) -> String {
        let (decimalSeparator, groupingSeparator) = language == .en ? (".", ",") : (",", ".")
        var scale = 1
        for _ in 0 ..< decimals {
            scale *= 10
        }
        let units = Int((abs(value) * Double(scale)).rounded(.toNearestOrAwayFromZero))
        let digits = String(units / scale)
        var grouped = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 {
                grouped += groupingSeparator
            }
            grouped.append(character)
        }
        let sign = value < 0 && units != 0 ? "-" : ""
        guard decimals > 0 else { return sign + grouped }
        let fraction = String(units % scale)
        let padded = String(repeating: "0", count: decimals - fraction.count) + fraction
        return sign + grouped + decimalSeparator + padded
    }

    static func level(_ value: Double, language: MarketBriefLanguage) -> String {
        number(value, decimals: abs(value) >= 1000 ? 0 : 2, language: language)
    }

    static func percent(_ change: Double, language: MarketBriefLanguage) -> String {
        number(abs(change), decimals: 2, language: language) + "%"
    }

    /// Decided on the value as shown (two decimals), so a row never reads
    /// "🔴 0,00%".
    static func direction(_ change: Double) -> MarketBriefDirection {
        let shown = (change * 100).rounded(.toNearestOrAwayFromZero) / 100
        if shown > 0 { return .up }
        if shown < 0 { return .down }
        return .flat
    }

    static func tone(_ changes: [Double]) -> MarketBriefDirection {
        guard !changes.isEmpty else { return .flat }
        let mean = changes.reduce(0, +) / Double(changes.count)
        if mean > toneBand { return .up }
        if mean < -toneBand { return .down }
        return .flat
    }

    static func groups(slot: MarketBriefSlot, quotes: [IndexQuote], language: MarketBriefLanguage) -> [MarketBriefQuoteGroup] {
        let bySymbol = Dictionary(quotes.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        return MarketBriefCatalog.groups(for: slot).compactMap { spec in
            let present = spec.instruments.compactMap { instrument in bySymbol[instrument.symbol].map { (instrument, $0) } }
            guard !present.isEmpty else { return nil }
            let tone = tone(present.map { $0.1.changePercent })
            return MarketBriefQuoteGroup(
                id: spec.id,
                title: MarketBriefCatalog.title(groupId: spec.id, tone: tone, language: language),
                tone: tone,
                rows: present.map { instrument, quote in
                    MarketBriefQuoteRow(
                        symbol: instrument.symbol,
                        flag: instrument.flag,
                        name: instrument.name,
                        level: level(quote.price, language: language),
                        changePercent: percent(quote.changePercent, language: language),
                        direction: direction(quote.changePercent)
                    )
                }
            )
        }
    }
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `LOG_LEVEL=warning swift test --filter MarketBriefFormatterTests`
Expected: 7 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/StockPlanBackend/MarketBrief/MarketBriefCatalog.swift Sources/StockPlanBackend/MarketBrief/MarketBriefFormatter.swift Tests/StockPlanBackendTests/MarketBriefFormatterTests.swift
git commit -m "feat(market-brief): instrument catalog and locale number formatting"
git show --stat HEAD
```

---

### Task 5: Facts, prompt and draft parsing

**Files:**
- Create: `Sources/StockPlanBackend/MarketBrief/MarketBriefFacts.swift`
- Create: `Sources/StockPlanBackend/MarketBrief/MarketBriefPrompt.swift`
- Test: `Tests/StockPlanBackendTests/MarketBriefPromptTests.swift`

**Interfaces:**
- Consumes:
  - `IndexQuote` (Task 3), `MarketBriefCatalog`, `MarketBriefLanguage` (Task 4).
  - `ProviderNewsItem` (`News/NewsProvider.swift:4`): `symbol, headline, source?, url?, summary?, image?, publishedAt: Date`.
  - `EarningsItemResponse` (shared): `date?, epsActual?, epsEstimate?, hour?, quarter?, revenueActual?, revenueEstimate?, symbol?, year?`.
  - `OpenAIMessage(role:content:)` (`AI/OpenAIClient.swift:19`).
- Produces:
  - `struct MarketBriefFacts: Encodable, Sendable, Equatable`, with:
    - `static func build(slot:tradingDate:quotes:news:earnings:now:) -> MarketBriefFacts`
    - `var groundedNumbers: [Double]`
  - `enum MarketBriefNumbers`, with `static func tokens(in: String) -> [[Double]]`.
  - `enum MarketBriefError: Error, Equatable`, with cases `unparseableDraft`, `tooFewItems(language: String, kept: Int)` and `incompleteBrief`.
  - `MarketBriefPrompt.systemPrompt` and `MarketBriefPrompt.messages(facts:webSearch:) throws -> [OpenAIMessage]`.
  - `struct MarketBriefDraft: Decodable, Equatable`, with:
    - nested `Section` (`greeting: String?`, `items: [Item]`) and `Item` (`kind: String`, `text: String`, `tickers: [String]?`, `sourceUrl: String?`)
    - `func section(_: MarketBriefLanguage) -> Section`
    - `static func parse(_ content: String) throws -> MarketBriefDraft`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Market brief facts, prompt and draft")
struct MarketBriefPromptTests {
    private let now = Date(timeIntervalSince1970: 1_791_500_000)

    private func news(_ headline: String, hoursAgo: Double) -> ProviderNewsItem {
        ProviderNewsItem(
            symbol: "", headline: headline, source: "Reuters", url: "https://example.com/\(headline.count)",
            summary: nil, image: nil, publishedAt: now.addingTimeInterval(-hoursAgo * 3600)
        )
    }

    private func facts() -> MarketBriefFacts {
        MarketBriefFacts.build(
            slot: .morning,
            tradingDate: "2026-10-08",
            quotes: [IndexQuote(symbol: "^GDAXI", price: 25032.36, previousClose: 25226.6, marketTime: now)],
            news: [news("German exports fell 0.8% in August", hoursAgo: 2), news("Old story", hoursAgo: 30)],
            earnings: [EarningsItemResponse(date: "2026-10-08", epsEstimate: 2.26, hour: "bmo", symbol: "PEP")],
            now: now
        )
    }

    @Test("Facts round quotes, name them from the catalog and drop news older than 24 h")
    func buildsFacts() {
        let facts = facts()
        #expect(facts.quotes == [MarketBriefFacts.Quote(symbol: "^GDAXI", name: "DAX", price: 25032.36, changePercent: -0.77)])
        #expect(facts.headlines.map(\.title) == ["German exports fell 0.8% in August"])
        #expect(facts.earnings.map(\.symbol) == ["PEP"])
    }

    @Test("Grounded numbers cover quote prices, unsigned moves, earnings and headline figures")
    func groundedNumbers() {
        let grounded = facts().groundedNumbers
        #expect(grounded.contains(25032.36))
        #expect(grounded.contains(0.77))
        #expect(grounded.contains(2.26))
        #expect(grounded.contains(0.8))
    }

    @Test("Number tokens need a separator and are read both ways")
    func numberTokens() {
        let tokens = MarketBriefNumbers.tokens(in: "DAX 25.032, caiu 0,77% em 2027 com 6 clientes")
        #expect(tokens.count == 2)
        #expect(tokens[0].contains(25032))
        #expect(tokens[0].contains(25.032))
        #expect(tokens[1].contains(0.77))
    }

    @Test("Messages carry the fixed system prompt and the facts; web search changes only the user turn")
    func messages() throws {
        let web = try MarketBriefPrompt.messages(facts: facts(), webSearch: true)
        let offline = try MarketBriefPrompt.messages(facts: facts(), webSearch: false)
        #expect(web.count == 2)
        #expect(web[0].role == "system")
        #expect(web[0].content == MarketBriefPrompt.systemPrompt)
        #expect(offline[0].content == MarketBriefPrompt.systemPrompt)
        #expect(web[1].content?.contains("\"tradingDate\":\"2026-10-08\"") == true)
        #expect(web[1].content?.contains("Use web search") == true)
        #expect(offline[1].content?.contains("Web search is unavailable") == true)
    }

    @Test("Draft parsing survives code fences and a leading sentence")
    func parsesFencedDraft() throws {
        let content = """
        Here is the brief:
        ```json
        {"en":{"greeting":"Good morning,","items":[{"kind":"highlight","text":"Risk-off.","tickers":[],"sourceUrl":null}]},
         "pt-PT":{"greeting":"Bom dia,","items":[{"kind":"highlight","text":"Risk-off.","tickers":["$PEP"],"sourceUrl":null}]}}
        ```
        """
        let draft = try MarketBriefDraft.parse(content)
        #expect(draft.section(.en).greeting == "Good morning,")
        #expect(draft.section(.ptPT).items.first?.tickers == ["$PEP"])
    }

    @Test("Draft parsing fails clearly without a JSON object")
    func rejectsNonJSON() {
        #expect(throws: MarketBriefError.unparseableDraft) {
            try MarketBriefDraft.parse("I could not find any news today.")
        }
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `LOG_LEVEL=warning swift test --filter MarketBriefPromptTests`
Expected: compile failure, `cannot find 'MarketBriefFacts' in scope`.

- [ ] **Step 3: Write the facts**

`Sources/StockPlanBackend/MarketBrief/MarketBriefFacts.swift`:

```swift
import Foundation
import StockPlanShared

enum MarketBriefError: Error, Equatable {
    case unparseableDraft
    case tooFewItems(language: String, kept: Int)
    case incompleteBrief
}

/// The "SERVER-SELECTED FACTS" block: everything the model may quote without
/// a source. Same idea as `AIPrompt`'s facts: the server chooses the numbers
/// and the model only writes words around them.
struct MarketBriefFacts: Encodable, Sendable, Equatable {
    struct Quote: Encodable, Sendable, Equatable {
        let symbol: String
        let name: String
        let price: Double
        let changePercent: Double
    }

    struct Headline: Encodable, Sendable, Equatable {
        let title: String
        let source: String?
        let url: String?
        let publishedAt: String
    }

    struct Earnings: Encodable, Sendable, Equatable {
        let symbol: String
        let hour: String?
        let epsEstimate: Double?
        let epsActual: Double?
        let revenueEstimate: Double?
        let revenueActual: Double?
    }

    let slot: MarketBriefSlot
    let tradingDate: String
    let quotes: [Quote]
    let headlines: [Headline]
    let earnings: [Earnings]

    static let maxHeadlines = 25
    static let maxEarnings = 20
    static let headlineMaxAge: TimeInterval = 24 * 3600

    static func build(
        slot: MarketBriefSlot,
        tradingDate: String,
        quotes: [IndexQuote],
        news: [ProviderNewsItem],
        earnings: [EarningsItemResponse],
        now: Date
    ) -> MarketBriefFacts {
        let iso = ISO8601DateFormatter()
        return MarketBriefFacts(
            slot: slot,
            tradingDate: tradingDate,
            quotes: quotes.map { quote in
                Quote(
                    symbol: quote.symbol,
                    name: MarketBriefCatalog.instrument(symbol: quote.symbol)?.name ?? quote.symbol,
                    price: round2(quote.price),
                    changePercent: round2(quote.changePercent)
                )
            },
            headlines: news
                .filter { now.timeIntervalSince($0.publishedAt) <= headlineMaxAge }
                .sorted { $0.publishedAt > $1.publishedAt }
                .prefix(maxHeadlines)
                .map { Headline(title: $0.headline, source: $0.source, url: $0.url, publishedAt: iso.string(from: $0.publishedAt)) },
            earnings: earnings.prefix(maxEarnings).compactMap { item in
                guard let symbol = item.symbol, !symbol.isEmpty else { return nil }
                return Earnings(
                    symbol: symbol,
                    hour: item.hour,
                    epsEstimate: item.epsEstimate,
                    epsActual: item.epsActual,
                    revenueEstimate: item.revenueEstimate,
                    revenueActual: item.revenueActual
                )
            }
        )
    }

    /// Every number an unsourced line may contain.
    var groundedNumbers: [Double] {
        var numbers: [Double] = []
        for quote in quotes {
            numbers += [quote.price, quote.changePercent, abs(quote.changePercent)]
        }
        for item in earnings {
            numbers += [item.epsEstimate, item.epsActual, item.revenueEstimate, item.revenueActual].compactMap(\.self)
        }
        for headline in headlines {
            numbers += MarketBriefNumbers.tokens(in: headline.title).flatMap(\.self)
        }
        return numbers
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded(.toNearestOrAwayFromZero) / 100
    }
}

/// Finds the numbers the grounding check cares about.
enum MarketBriefNumbers {
    /// Only tokens with a separator ("25.032", "0,77", "1,234.5"). Plain
    /// integers (years, counts) are not checked: they are rarely the made-up
    /// part of a market sentence, and checking them would drop most lines.
    static func tokens(in text: String) -> [[Double]] {
        text.matches(of: #/\d+(?:[.,]\d+)+/#).map { readings(String($0.output)) }
    }

    /// Both readings, because the token's language is unknown:
    /// "25.032" is 25.032 in en and 25032 in pt-PT.
    static func readings(_ token: String) -> [Double] {
        let english = Double(token.replacingOccurrences(of: ",", with: ""))
        let portuguese = Double(token.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "."))
        return [english, portuguese].compactMap(\.self)
    }
}
```

- [ ] **Step 4: Write the prompt and draft**

`Sources/StockPlanBackend/MarketBrief/MarketBriefPrompt.swift`:

```swift
import Foundation
import StockPlanShared

/// Fixed system prompt plus a facts turn, in the `AIPrompt` style. The system
/// prompt never varies, so provider-side prompt caching applies.
///
/// One call writes both languages, so en and pt-PT carry the same facts in the
/// same order and the brief costs one completion, not two.
enum MarketBriefPrompt {
    static let systemPrompt = """
    You write Norviq's market brief, a short daily note for retail investors, in two languages at once: \
    English ("en") and European Portuguese ("pt-PT", never Brazilian Portuguese).

    You receive SERVER-SELECTED FACTS as JSON: index quotes (price and changePercent, already computed), \
    recent headlines, and today's earnings calendar.

    Hard rules:
    1. Never write an index level, price, yield or percentage that is not in FACTS, unless you found it in a \
    web source and set that item's "sourceUrl" to the source's https URL.
    2. Every item that uses information from the web has "sourceUrl" set. Items built only from FACTS have \
    "sourceUrl": null.
    3. Write tickers as $TICKER in the text, and list them without "$" in "tickers".
    4. Summarise in your own words. Never copy a headline or an article sentence.
    5. No investment advice, no price targets, no "buy" or "sell".
    6. Both languages carry the same items in the same order with the same facts.
    7. pt-PT writes numbers as 25.032 and 0,77%; en writes 25,032 and 0.77%.

    Slot "morning" (15 minutes after the European open): "greeting" is a short good-morning ("Good morning," / \
    "Bom dia,"). Write 5 to 7 items of kind "highlight": the overall tone, Asia overnight, the US 10-year yield, \
    oil, notable macro data, and what investors watch today. Then 0 to 3 items of kind "earnings", one per \
    notable company reporting today, saying what to watch. Each item is at most 350 characters.

    Slot "evening" (after the US close): "greeting" is one line introducing the recap. Write 5 to 8 items of kind \
    "story": the day's most market-moving stories (companies, macro, and world events that move markets), most \
    important first. Each item is at most 900 characters.

    Reply with only this JSON object and nothing else:
    {"en":{"greeting":string|null,"items":[{"kind":"highlight"|"earnings"|"story","text":string,\
    "tickers":[string],"sourceUrl":string|null}]},"pt-PT":{same shape}}
    """

    static func messages(facts: MarketBriefFacts, webSearch: Bool) throws -> [OpenAIMessage] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let factsJSON = String(decoding: try encoder.encode(facts), as: UTF8.self)
        let research = webSearch
            ? "Use web search for today's market news and cite each source in sourceUrl."
            : "Web search is unavailable. Use only FACTS; every item has sourceUrl null."
        return [
            OpenAIMessage(role: "system", content: systemPrompt),
            OpenAIMessage(role: "user", content: "\(research)\n\nSERVER-SELECTED FACTS:\n\(factsJSON)"),
        ]
    }
}

/// The model's reply, before validation.
struct MarketBriefDraft: Decodable, Equatable {
    struct Section: Decodable, Equatable {
        let greeting: String?
        let items: [Item]
    }

    struct Item: Decodable, Equatable {
        let kind: String
        let text: String
        let tickers: [String]?
        let sourceUrl: String?
    }

    let en: Section
    let ptPT: Section

    enum CodingKeys: String, CodingKey {
        case en
        case ptPT = "pt-PT"
    }

    func section(_ language: MarketBriefLanguage) -> Section {
        language == .en ? en : ptPT
    }

    /// Models wrap JSON in fences or a sentence even under `json_object`, so
    /// take the outermost object. Plain `JSONDecoder`, not the app's
    /// `backendAPI` decoder, so the "pt-PT" key is read as written.
    static func parse(_ content: String) throws -> MarketBriefDraft {
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"),
              start < end
        else { throw MarketBriefError.unparseableDraft }
        do {
            return try JSONDecoder().decode(Self.self, from: Data(content[start ... end].utf8))
        } catch {
            throw MarketBriefError.unparseableDraft
        }
    }
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `LOG_LEVEL=warning swift test --filter MarketBriefPromptTests`
Expected: 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/StockPlanBackend/MarketBrief/MarketBriefFacts.swift Sources/StockPlanBackend/MarketBrief/MarketBriefPrompt.swift Tests/StockPlanBackendTests/MarketBriefPromptTests.swift
git commit -m "feat(market-brief): server-selected facts, prompt and draft parsing"
git show --stat HEAD
```

---

### Task 6: Draft validator (grounding check)

**Files:**
- Create: `Sources/StockPlanBackend/MarketBrief/MarketBriefValidator.swift`
- Test: `Tests/StockPlanBackendTests/MarketBriefValidatorTests.swift`

**Interfaces:**
- Consumes: `MarketBriefDraft.Section`, `MarketBriefNumbers`, `MarketBriefError` (Task 5); `MarketBriefLanguage` (Task 4); `MarketBriefItem`, `MarketBriefItemKind`, `MarketBriefSlot` (Task 1).
- Produces:
  - `MarketBriefValidator.Output` (`greeting: String?`, `items: [MarketBriefItem]`, `dropped: Int`)
  - `static func validate(_ section: MarketBriefDraft.Section, slot: MarketBriefSlot, language: MarketBriefLanguage, grounded: [Double]) throws -> Output`
  - `static func isGrounded(_ text: String, grounded: [Double]) -> Bool`
  - `static let minItems = 3`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing

@Suite("Market brief validator")
struct MarketBriefValidatorTests {
    private func item(_ text: String, kind: String = "highlight", tickers: [String]? = nil, source: String? = nil) -> MarketBriefDraft.Item {
        MarketBriefDraft.Item(kind: kind, text: text, tickers: tickers, sourceUrl: source)
    }

    private func section(_ items: [MarketBriefDraft.Item], greeting: String? = "Bom dia,") -> MarketBriefDraft.Section {
        MarketBriefDraft.Section(greeting: greeting, items: items)
    }

    private let filler = [
        MarketBriefDraft.Item(kind: "highlight", text: "Tom de cautela na Europa.", tickers: nil, sourceUrl: nil),
        MarketBriefDraft.Item(kind: "highlight", text: "Investidores atentos à Fed.", tickers: nil, sourceUrl: nil),
        MarketBriefDraft.Item(kind: "highlight", text: "Petróleo em foco.", tickers: nil, sourceUrl: nil),
    ]

    @Test("An unsourced number that matches a fact is kept, in either number format")
    func groundedNumberKept() throws {
        let output = try MarketBriefValidator.validate(
            section([item("O DAX cai 0,77% para 25.032 pontos.")] + filler),
            slot: .morning, language: .ptPT, grounded: [25032.36, 0.77]
        )
        #expect(output.items.count == 4)
        #expect(output.dropped == 0)
    }

    @Test("An unsourced invented number drops that item only")
    func inventedNumberDropped() throws {
        let output = try MarketBriefValidator.validate(
            section([item("O Brent negoceia perto de 104,50 dólares.")] + filler),
            slot: .morning, language: .ptPT, grounded: [25032.36, 0.77]
        )
        #expect(output.items.count == 3)
        #expect(output.dropped == 1)
    }

    @Test("A sourced number is kept even if it is not in the facts")
    func sourcedNumberKept() throws {
        let output = try MarketBriefValidator.validate(
            section([item("Brent near $104.50.", source: "https://www.reuters.com/markets/oil")] + filler),
            slot: .morning, language: .en, grounded: []
        )
        #expect(output.items.first?.sourceUrl == "https://www.reuters.com/markets/oil")
        #expect(output.dropped == 0)
    }

    @Test("A non-https source does not count as a source")
    func httpSourceIgnored() throws {
        let output = try MarketBriefValidator.validate(
            section([item("Brent near $104.50.", source: "http://example.com/x")] + filler),
            slot: .morning, language: .en, grounded: []
        )
        #expect(output.dropped == 1)
    }

    @Test("Wrong kind for the slot, empty text and over-long text are dropped")
    func shapeRules() throws {
        let long = String(repeating: "a", count: 401)
        let output = try MarketBriefValidator.validate(
            section([item("A story.", kind: "story"), item("   "), item(long)] + filler),
            slot: .morning, language: .en, grounded: []
        )
        #expect(output.items.count == 3)
        #expect(output.dropped == 3)
    }

    @Test("Evening stories may run to 1000 characters")
    func eveningLength() throws {
        let story = String(repeating: "b", count: 950)
        let stories = (0 ..< 3).map { _ in item(story, kind: "story") }
        let output = try MarketBriefValidator.validate(section(stories, greeting: nil), slot: .evening, language: .en, grounded: [])
        #expect(output.items.count == 3)
    }

    @Test("Fewer than three surviving items rejects the language")
    func tooFew() {
        #expect(throws: MarketBriefError.tooFewItems(language: "en", kept: 2)) {
            try MarketBriefValidator.validate(section(Array(filler.prefix(2))), slot: .morning, language: .en, grounded: [])
        }
    }

    @Test("Tickers are uppercased, stripped of $, deduplicated and filtered")
    func tickers() throws {
        let output = try MarketBriefValidator.validate(
            section([item("$NVDA and $BRK.B lead.", tickers: ["$nvda", "NVDA", "BRK.B", "TOOLONGX", "1AB"])] + filler),
            slot: .morning, language: .en, grounded: []
        )
        #expect(output.items[0].tickers == ["NVDA", "BRK.B"])
    }

    @Test("Morning keeps at most 10 items, evening at most 8")
    func itemCaps() throws {
        let many = (0 ..< 12).map { _ in item("Line.") }
        let morning = try MarketBriefValidator.validate(section(many), slot: .morning, language: .en, grounded: [])
        #expect(morning.items.count == 10)
        let stories = (0 ..< 12).map { _ in item("Story.", kind: "story") }
        let evening = try MarketBriefValidator.validate(section(stories), slot: .evening, language: .en, grounded: [])
        #expect(evening.items.count == 8)
    }

    @Test("Blank greeting becomes nil")
    func blankGreeting() throws {
        let output = try MarketBriefValidator.validate(section(filler, greeting: "  "), slot: .morning, language: .en, grounded: [])
        #expect(output.greeting == nil)
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `LOG_LEVEL=warning swift test --filter MarketBriefValidatorTests`
Expected: compile failure, `cannot find 'MarketBriefValidator' in scope`.

- [ ] **Step 3: Write the validator**

```swift
import Foundation
import StockPlanShared

/// Turns a model draft into items we are willing to show.
///
/// The grounding check is a heuristic, not a proof: an unsourced line may
/// only contain separator-bearing numbers that match a server fact. A
/// sourced line is trusted to its source. Lines that fail are dropped, not
/// rewritten, and a language left with fewer than `minItems` lines fails the
/// whole attempt so the generator can fall back.
enum MarketBriefValidator {
    static let minItems = 3
    static let maxGreetingLength = 120

    struct Output: Equatable {
        let greeting: String?
        let items: [MarketBriefItem]
        let dropped: Int
    }

    private struct Limits {
        let maxItems: Int
        let maxLength: Int
        let kinds: Set<MarketBriefItemKind>
    }

    private static func limits(for slot: MarketBriefSlot) -> Limits {
        switch slot {
        case .morning: Limits(maxItems: 10, maxLength: 400, kinds: [.highlight, .earnings])
        case .evening: Limits(maxItems: 8, maxLength: 1000, kinds: [.story])
        }
    }

    static func validate(
        _ section: MarketBriefDraft.Section,
        slot: MarketBriefSlot,
        language: MarketBriefLanguage,
        grounded: [Double]
    ) throws -> Output {
        let limits = limits(for: slot)
        var kept: [MarketBriefItem] = []
        var dropped = 0
        for item in section.items {
            guard kept.count < limits.maxItems else { break }
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let kind = MarketBriefItemKind(rawValue: item.kind),
                  limits.kinds.contains(kind),
                  !text.isEmpty,
                  text.count <= limits.maxLength
            else {
                dropped += 1
                continue
            }
            let source = httpsURL(item.sourceUrl)
            if source == nil, !isGrounded(text, grounded: grounded) {
                dropped += 1
                continue
            }
            kept.append(MarketBriefItem(kind: kind, text: text, tickers: tickers(item.tickers ?? []), sourceUrl: source))
        }
        guard kept.count >= minItems else {
            throw MarketBriefError.tooFewItems(language: language.rawValue, kept: kept.count)
        }
        let greeting = section.greeting?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Output(
            greeting: greeting.flatMap { $0.isEmpty || $0.count > maxGreetingLength ? nil : $0 },
            items: kept,
            dropped: dropped
        )
    }

    /// Every separator-bearing number must match some fact under either
    /// reading, allowing for the model rounding to one decimal (±0.05) or
    /// rounding a level (±0.1%).
    static func isGrounded(_ text: String, grounded: [Double]) -> Bool {
        MarketBriefNumbers.tokens(in: text).allSatisfy { readings in
            readings.contains { reading in
                grounded.contains { fact in abs(fact - reading) <= max(0.051, abs(fact) * 0.001) }
            }
        }
    }

    static func tickers(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.compactMap { value in
            let ticker = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "").uppercased()
            guard ticker.wholeMatch(of: #/[A-Z][A-Z.]{0,5}/#) != nil, seen.insert(ticker).inserted else { return nil }
            return ticker
        }
    }

    static func httpsURL(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: trimmed),
              url.scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return trimmed
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `LOG_LEVEL=warning swift test --filter MarketBriefValidatorTests`
Expected: 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/StockPlanBackend/MarketBrief/MarketBriefValidator.swift Tests/StockPlanBackendTests/MarketBriefValidatorTests.swift
git commit -m "feat(market-brief): validate drafts and drop unsourced invented numbers"
git show --stat HEAD
```

---

### Task 7: Storage: record, migration, repository

**Files:**
- Create: `Sources/StockPlanBackend/Models/MarketBriefRecord.swift`
- Create: `Sources/StockPlanBackend/Migrations/CreateMarketBriefs.swift`
- Create: `Sources/StockPlanBackend/MarketBrief/MarketBriefRepository.swift`
- Modify: `Sources/StockPlanBackend/ConfigureBootstrap.swift:439` (add `app.migrations.add(CreateMarketBriefs())` after `AddSocialFacebookImport()`)
- Create (shared test helpers): `Tests/StockPlanBackendTests/MarketBriefFixtures.swift`
- Test: `Tests/StockPlanBackendTests/MarketBriefRepositoryTests.swift`

**Interfaces:**
- Consumes: `MarketBriefResponse`, `MarketBriefSlot` (Task 1); `MarketBriefError.incompleteBrief` (Task 5).
- Produces:
  - `protocol MarketBriefRepository: Sendable`, with:
    - `exists(tradingDate: String, slot: MarketBriefSlot, on: any Database) async throws -> Bool`
    - `save(_ briefs: [MarketBriefResponse], model: String, generatedAt: Date, on: any Database) async throws`
    - `delete(tradingDate: String, slot: MarketBriefSlot, on: any Database) async throws`
    - `latest(language: String, on: any Database) async throws -> MarketBriefResponse?`
    - `find(tradingDate: String, slot: MarketBriefSlot, language: String, on: any Database) async throws -> MarketBriefResponse?`
  - `struct DatabaseMarketBriefRepository: MarketBriefRepository`.
  - Test helper: `MarketBriefFixtures.response(date:slot:language:degraded:) -> MarketBriefResponse`.
  - Test helper: `MarketBriefFixtures.withApp(_:)`, which boots a configured, migrated app.

- [ ] **Step 1: Write the fixtures and the failing test**

`Tests/StockPlanBackendTests/MarketBriefFixtures.swift`:

```swift
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Vapor
import VaporTesting

enum MarketBriefFixtures {
    static func response(
        date: String = "2026-10-08",
        slot: MarketBriefSlot = .morning,
        language: String = "en",
        degraded: Bool = false
    ) -> MarketBriefResponse {
        MarketBriefResponse(
            enabled: true,
            tradingDate: date,
            slot: slot,
            language: language,
            greeting: language == "en" ? "Good morning," : "Bom dia,",
            groups: [],
            items: [MarketBriefItem(kind: slot == .morning ? .highlight : .story, text: "Line for \(language).", tickers: [], sourceUrl: nil)],
            generatedAt: "2026-10-08T07:15:00Z",
            degraded: degraded
        )
    }

    /// Configured, migrated app inside the shared DB lock, the same shape as
    /// `MarketOwnershipRouteTests.withApp`.
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
}
```

`Tests/StockPlanBackendTests/MarketBriefRepositoryTests.swift`:

```swift
import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Market brief repository", .serialized)
struct MarketBriefRepositoryTests {
    private let repo = DatabaseMarketBriefRepository()

    private func both(_ date: String, _ slot: MarketBriefSlot) -> [MarketBriefResponse] {
        [MarketBriefFixtures.response(date: date, slot: slot, language: "en"),
         MarketBriefFixtures.response(date: date, slot: slot, language: "pt-PT")]
    }

    @Test("Saving both languages makes the slot exist and each language readable")
    func saveAndFind() async throws {
        try await MarketBriefFixtures.withApp { app in
            #expect(try await repo.exists(tradingDate: "2026-10-08", slot: .morning, on: app.db) == false)
            try await repo.save(both("2026-10-08", .morning), model: "m", generatedAt: Date(), on: app.db)
            #expect(try await repo.exists(tradingDate: "2026-10-08", slot: .morning, on: app.db))
            let pt = try await repo.find(tradingDate: "2026-10-08", slot: .morning, language: "pt-PT", on: app.db)
            #expect(pt?.greeting == "Bom dia,")
        }
    }

    @Test("Latest is the most recently generated brief for the language")
    func latest() async throws {
        try await MarketBriefFixtures.withApp { app in
            let morning = Date(timeIntervalSince1970: 1_791_500_000)
            try await repo.save(both("2026-10-08", .morning), model: "m", generatedAt: morning, on: app.db)
            try await repo.save(both("2026-10-08", .evening), model: "m", generatedAt: morning.addingTimeInterval(14 * 3600), on: app.db)
            #expect(try await repo.latest(language: "en", on: app.db)?.slot == .evening)
            #expect(try await repo.latest(language: "pt-PT", on: app.db)?.language == "pt-PT")
            #expect(try await repo.latest(language: "de", on: app.db) == nil)
        }
    }

    @Test("A second save for the same slot violates the unique key")
    func duplicateRejected() async throws {
        try await MarketBriefFixtures.withApp { app in
            try await repo.save(both("2026-10-08", .morning), model: "m", generatedAt: Date(), on: app.db)
            do {
                try await repo.save(both("2026-10-08", .morning), model: "m", generatedAt: Date(), on: app.db)
                Issue.record("expected a unique-key violation")
            } catch {
                #expect((error as? any DatabaseError)?.isConstraintFailure == true)
            }
        }
    }

    @Test("Delete removes both languages of a slot")
    func deleteSlot() async throws {
        try await MarketBriefFixtures.withApp { app in
            try await repo.save(both("2026-10-08", .morning), model: "m", generatedAt: Date(), on: app.db)
            try await repo.delete(tradingDate: "2026-10-08", slot: .morning, on: app.db)
            #expect(try await repo.exists(tradingDate: "2026-10-08", slot: .morning, on: app.db) == false)
        }
    }

    @Test("A brief without a date or slot is refused before touching the database")
    func incompleteRefused() async throws {
        try await MarketBriefFixtures.withApp { app in
            await #expect(throws: MarketBriefError.incompleteBrief) {
                try await repo.save([.empty(language: "en", enabled: true)], model: "m", generatedAt: Date(), on: app.db)
            }
        }
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `docker compose -f docker-compose.dev.yml up -d db && LOG_LEVEL=warning swift test --filter MarketBriefRepositoryTests`
Expected: compile failure, `cannot find 'DatabaseMarketBriefRepository' in scope`.

- [ ] **Step 3: Write the record and the migration**

`Sources/StockPlanBackend/Models/MarketBriefRecord.swift`:

```swift
import Fluent
import Foundation
import Vapor

/// One generated brief in one language. `payload` is the JSON-encoded
/// `MarketBriefResponse`, served as stored. Unique per
/// (trading_date, slot, language), which is also what keeps two replicas
/// from both writing a slot.
final class MarketBriefRecord: Model, @unchecked Sendable {
    static let schema = "market_briefs"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "trading_date")
    var tradingDate: String

    @Field(key: "slot")
    var slot: String

    @Field(key: "language")
    var language: String

    @Field(key: "payload")
    var payload: String

    @Field(key: "model")
    var model: String

    @Field(key: "degraded")
    var degraded: Bool

    @Field(key: "generated_at")
    var generatedAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        tradingDate: String,
        slot: String,
        language: String,
        payload: String,
        model: String,
        degraded: Bool,
        generatedAt: Date
    ) {
        self.id = id
        self.tradingDate = tradingDate
        self.slot = slot
        self.language = language
        self.payload = payload
        self.model = model
        self.degraded = degraded
        self.generatedAt = generatedAt
    }
}
```

`Sources/StockPlanBackend/Migrations/CreateMarketBriefs.swift`:

```swift
import Fluent

struct CreateMarketBriefs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("market_briefs")
            .id()
            .field("trading_date", .string, .required)
            .field("slot", .string, .required)
            .field("language", .string, .required)
            .field("payload", .string, .required)
            .field("model", .string, .required)
            .field("degraded", .bool, .required)
            .field("generated_at", .datetime, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "trading_date", "slot", "language")
            .create()

        try await database.createIndex(on: "market_briefs", columns: ["language", "generated_at"])
    }

    func revert(on database: any Database) async throws {
        try await database.schema("market_briefs").delete()
    }
}
```

In `ConfigureBootstrap.swift`, directly after line 439 (`app.migrations.add(AddSocialFacebookImport())`), add:

```swift
    app.migrations.add(CreateMarketBriefs())
```

- [ ] **Step 4: Write the repository**

`Sources/StockPlanBackend/MarketBrief/MarketBriefRepository.swift`:

```swift
import Fluent
import Foundation
import StockPlanShared

protocol MarketBriefRepository: Sendable {
    func exists(tradingDate: String, slot: MarketBriefSlot, on db: any Database) async throws -> Bool
    /// All languages of one slot in one transaction: a reader never sees en
    /// without pt-PT.
    func save(_ briefs: [MarketBriefResponse], model: String, generatedAt: Date, on db: any Database) async throws
    func delete(tradingDate: String, slot: MarketBriefSlot, on db: any Database) async throws
    func latest(language: String, on db: any Database) async throws -> MarketBriefResponse?
    func find(tradingDate: String, slot: MarketBriefSlot, language: String, on db: any Database) async throws -> MarketBriefResponse?
}

struct DatabaseMarketBriefRepository: MarketBriefRepository {
    func exists(tradingDate: String, slot: MarketBriefSlot, on db: any Database) async throws -> Bool {
        try await MarketBriefRecord.query(on: db)
            .filter(\.$tradingDate == tradingDate)
            .filter(\.$slot == slot.rawValue)
            .count() > 0
    }

    func save(_ briefs: [MarketBriefResponse], model: String, generatedAt: Date, on db: any Database) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let records = try briefs.map { brief in
            guard let tradingDate = brief.tradingDate, let slot = brief.slot else {
                throw MarketBriefError.incompleteBrief
            }
            return MarketBriefRecord(
                tradingDate: tradingDate,
                slot: slot.rawValue,
                language: brief.language,
                payload: String(decoding: try encoder.encode(brief), as: UTF8.self),
                model: model,
                degraded: brief.degraded,
                generatedAt: generatedAt
            )
        }
        try await db.transaction { tx in
            for record in records {
                try await record.save(on: tx)
            }
        }
    }

    func delete(tradingDate: String, slot: MarketBriefSlot, on db: any Database) async throws {
        try await MarketBriefRecord.query(on: db)
            .filter(\.$tradingDate == tradingDate)
            .filter(\.$slot == slot.rawValue)
            .delete()
    }

    func latest(language: String, on db: any Database) async throws -> MarketBriefResponse? {
        try await MarketBriefRecord.query(on: db)
            .filter(\.$language == language)
            .sort(\.$generatedAt, .descending)
            .first()
            .map(decode)
    }

    func find(tradingDate: String, slot: MarketBriefSlot, language: String, on db: any Database) async throws -> MarketBriefResponse? {
        try await MarketBriefRecord.query(on: db)
            .filter(\.$tradingDate == tradingDate)
            .filter(\.$slot == slot.rawValue)
            .filter(\.$language == language)
            .first()
            .map(decode)
    }

    private func decode(_ record: MarketBriefRecord) throws -> MarketBriefResponse {
        try JSONDecoder().decode(MarketBriefResponse.self, from: Data(record.payload.utf8))
    }
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `LOG_LEVEL=warning swift test --filter MarketBriefRepositoryTests`
Expected: 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/StockPlanBackend/Models/MarketBriefRecord.swift Sources/StockPlanBackend/Migrations/CreateMarketBriefs.swift Sources/StockPlanBackend/MarketBrief/MarketBriefRepository.swift Sources/StockPlanBackend/ConfigureBootstrap.swift Tests/StockPlanBackendTests/MarketBriefFixtures.swift Tests/StockPlanBackendTests/MarketBriefRepositoryTests.swift
git commit -m "feat(market-brief): market_briefs table and repository"
git show --stat HEAD
```

---

### Task 8: Generator (quotes → facts → LLM → validate → responses)

**Files:**
- Create: `Sources/StockPlanBackend/MarketBrief/MarketBriefGenerator.swift`
- Modify: `Tests/StockPlanBackendTests/MarketBriefFixtures.swift` (append the stubs)
- Test: `Tests/StockPlanBackendTests/MarketBriefGeneratorTests.swift`

**Interfaces:**
- Consumes:
  - Everything from Tasks 3–6.
  - `OpenAIChatClient.chat(messages:tools:responseFormat:on:)` (`AI/OpenAIClient.swift:207`).
  - `DefaultOpenAIChatClient(apiKey:model:baseURL:maxTokens:timeout:)` (`AI/OpenAIClient.swift:287`).
  - `AIProviderConfiguration.load()` (`.apiKey`, `.baseURL`).
  - `NewsProvider.fetchGeneral(on:)`.
  - `EarningsService.getCalendar(query:on:)` with `EarningsQueryRequest(from:to:)`.
  - `app.openAIChatClient`, `app.earningsService`.
- Produces:
  - `protocol MarketBriefGenerating: Sendable`, with `func generate(_ due: MarketBriefSchedule.Due, on req: Request) async throws -> GeneratedMarketBrief`.
  - `struct GeneratedMarketBrief: Sendable, Equatable` (`responses: [MarketBriefResponse]`, `model: String`).
  - `struct MarketBriefGenerator: MarketBriefGenerating`, plus `static func live(app: Application, news: (any NewsProvider)?) -> MarketBriefGenerator` and `static let defaultModel`.
  - Test stubs: `StubIndexQuoteProvider`, `ScriptedBriefChatClient`, `StubEarningsService`, `MarketBriefFixtures.draftJSON(kind:count:)`, `MarketBriefFixtures.withRequest(_:)`.

- [ ] **Step 1: Append stubs to the fixtures**

Append to `Tests/StockPlanBackendTests/MarketBriefFixtures.swift`:

```swift
struct StubIndexQuoteProvider: IndexQuoteProvider {
    let result: [IndexQuote]

    func quotes(symbols: [String], now _: Date, on _: Request) async -> [IndexQuote] {
        result.filter { symbols.contains($0.symbol) }
    }
}

/// Replies in order; records every message list it was sent.
final class ScriptedBriefChatClient: OpenAIChatClient, @unchecked Sendable {
    enum Reply {
        case content(String)
        case failure(any Error)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [[OpenAIMessage]] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var calls: [[OpenAIMessage]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func chat(messages: [OpenAIMessage], tools _: [OpenAITool], responseFormat _: String?, on _: Request) async throws -> OpenAIMessage {
        lock.lock()
        recorded.append(messages)
        let reply = replies.isEmpty ? Reply.failure(Abort(.badGateway)) : replies.removeFirst()
        lock.unlock()
        switch reply {
        case let .content(text): return OpenAIMessage(role: "assistant", content: text)
        case let .failure(error): throw error
        }
    }
}

struct StubEarningsService: EarningsService {
    var items: [EarningsItemResponse] = []

    func getCalendar(query _: EarningsQueryRequest, on _: Request) async throws -> [EarningsItemResponse] {
        items
    }
}

extension MarketBriefFixtures {
    /// A valid two-language draft with `count` number-free items of `kind`.
    static func draftJSON(kind: String = "highlight", count: Int = 5) -> String {
        let items = (1 ... max(count, 1)).map { index in
            #"{"kind":"\#(kind)","text":"Line \#(index) of the brief.","tickers":[],"sourceUrl":null}"#
        }.joined(separator: ",")
        return #"{"en":{"greeting":"Good morning,","items":[\#(items)]},"pt-PT":{"greeting":"Bom dia,","items":[\#(items)]}}"#
    }

    /// A bare app (no configure, no DB) and a request on it, for code that
    /// only needs `req.logger` and `req.client`.
    static func withRequest(_ body: (Request) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await body(Request(application: app, on: app.eventLoopGroup.next()))
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }
}
```

The `EarningsService` protocol (`Earnings/EarningsService.swift:3`) may have more requirements than `getCalendar`. If the stub does not compile, add the missing members with `fatalError("unused")` bodies.

- [ ] **Step 2: Write the failing test**

`Tests/StockPlanBackendTests/MarketBriefGeneratorTests.swift`:

```swift
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Market brief generator")
struct MarketBriefGeneratorTests {
    private let now = Date(timeIntervalSince1970: 1_791_500_000)
    private let due = MarketBriefSchedule.Due(tradingDate: "2026-10-08", slot: .morning)

    private func generator(
        quotes: [IndexQuote],
        web: ScriptedBriefChatClient?,
        fallback: ScriptedBriefChatClient
    ) -> MarketBriefGenerator {
        MarketBriefGenerator(
            quotes: StubIndexQuoteProvider(result: quotes),
            news: nil,
            earnings: StubEarningsService(),
            webClient: web,
            webModel: "anthropic/claude-haiku-4.5:online",
            fallbackClient: { fallback },
            now: { [now] in now }
        )
    }

    private var dax: IndexQuote {
        IndexQuote(symbol: "^GDAXI", price: 25032.36, previousClose: 25226.6, marketTime: now)
    }

    @Test("Web search success: both languages, formatted rows, not degraded")
    func webSuccess() async throws {
        let web = ScriptedBriefChatClient([.content(MarketBriefFixtures.draftJSON())])
        let fallback = ScriptedBriefChatClient([])
        try await MarketBriefFixtures.withRequest { req in
            let brief = try await generator(quotes: [dax], web: web, fallback: fallback).generate(due, on: req)
            #expect(brief.model == "anthropic/claude-haiku-4.5:online")
            #expect(brief.responses.map(\.language) == ["en", "pt-PT"])
            #expect(brief.responses.allSatisfy { !$0.degraded && $0.items.count == 5 })
            let pt = try #require(brief.responses.last)
            #expect(pt.groups.first?.rows.first?.level == "25.032")
            #expect(pt.greeting == "Bom dia,")
            #expect(pt.tradingDate == "2026-10-08")
            #expect(pt.slot == .morning)
            #expect(fallback.calls.isEmpty)
            #expect(web.calls.first?.last?.content?.contains("Use web search") == true)
        }
    }

    @Test("Web failure falls back to the chain without web search and marks the brief degraded")
    func webFailureFallsBack() async throws {
        let web = ScriptedBriefChatClient([.failure(Abort(.paymentRequired))])
        let fallback = ScriptedBriefChatClient([.content(MarketBriefFixtures.draftJSON())])
        try await MarketBriefFixtures.withRequest { req in
            let brief = try await generator(quotes: [dax], web: web, fallback: fallback).generate(due, on: req)
            #expect(brief.responses.allSatisfy(\.degraded))
            #expect(brief.model == "fallback-chain")
            #expect(fallback.calls.first?.last?.content?.contains("Web search is unavailable") == true)
        }
    }

    @Test("A web draft that fails validation also falls back")
    func invalidWebDraftFallsBack() async throws {
        let web = ScriptedBriefChatClient([.content(MarketBriefFixtures.draftJSON(count: 2))])
        let fallback = ScriptedBriefChatClient([.content(MarketBriefFixtures.draftJSON())])
        try await MarketBriefFixtures.withRequest { req in
            let brief = try await generator(quotes: [dax], web: web, fallback: fallback).generate(due, on: req)
            #expect(brief.responses.allSatisfy(\.degraded))
        }
    }

    @Test("No web client configured goes straight to the fallback")
    func noWebClient() async throws {
        let fallback = ScriptedBriefChatClient([.content(MarketBriefFixtures.draftJSON())])
        try await MarketBriefFixtures.withRequest { req in
            let brief = try await generator(quotes: [dax], web: nil, fallback: fallback).generate(due, on: req)
            #expect(brief.responses.allSatisfy(\.degraded))
            #expect(fallback.calls.count == 1)
        }
    }

    @Test("Both attempts failing throws")
    func bothFail() async throws {
        let web = ScriptedBriefChatClient([.content("no json here")])
        let fallback = ScriptedBriefChatClient([.failure(Abort(.badGateway))])
        try await MarketBriefFixtures.withRequest { req in
            await #expect(throws: (any Error).self) {
                try await generator(quotes: [dax], web: web, fallback: fallback).generate(due, on: req)
            }
        }
    }

    @Test("No fresh quotes (holiday, Yahoo blocked) still produces a text-only brief")
    func noQuotes() async throws {
        let web = ScriptedBriefChatClient([.content(MarketBriefFixtures.draftJSON())])
        try await MarketBriefFixtures.withRequest { req in
            let brief = try await generator(quotes: [], web: web, fallback: ScriptedBriefChatClient([])).generate(due, on: req)
            #expect(brief.responses.allSatisfy { $0.groups.isEmpty && $0.items.count == 5 })
        }
    }
}
```

- [ ] **Step 3: Run the test and confirm it fails**

Run: `LOG_LEVEL=warning swift test --filter MarketBriefGeneratorTests`
Expected: compile failure, `cannot find 'MarketBriefGenerator' in scope`.

- [ ] **Step 4: Write the generator**

```swift
import Foundation
import StockPlanShared
import Vapor

protocol MarketBriefGenerating: Sendable {
    func generate(_ due: MarketBriefSchedule.Due, on req: Request) async throws -> GeneratedMarketBrief
}

struct GeneratedMarketBrief: Sendable, Equatable {
    /// One per `MarketBriefLanguage`, in `allCases` order.
    let responses: [MarketBriefResponse]
    let model: String
}

/// Builds one slot's brief in every language.
///
/// The numbers are fetched and formatted here; the model only writes text.
/// The first attempt uses a dedicated client on an OpenRouter `:online`
/// model (web search). If that call fails or its draft does not validate,
/// the app's ordinary chain writes the brief from the in-house facts alone
/// and it is marked `degraded`.
struct MarketBriefGenerator: MarketBriefGenerating {
    /// `:online` is OpenRouter's switch for web search; another provider would
    /// reject the slug, and the fallback then takes over.
    static let defaultModel = "anthropic/claude-haiku-4.5:online"
    static let fallbackModelLabel = "fallback-chain"

    let quotes: any IndexQuoteProvider
    let news: (any NewsProvider)?
    let earnings: any EarningsService
    let webClient: (any OpenAIChatClient)?
    let webModel: String
    /// Read lazily: `app.openAIChatClient` is set after this is built.
    let fallbackClient: @Sendable () -> any OpenAIChatClient
    let now: @Sendable () -> Date

    func generate(_ due: MarketBriefSchedule.Due, on req: Request) async throws -> GeneratedMarketBrief {
        let at = now()
        let quoteList = await quotes.quotes(
            symbols: MarketBriefCatalog.instruments(for: due.slot).map(\.symbol),
            now: at,
            on: req
        )
        let facts = await MarketBriefFacts.build(
            slot: due.slot,
            tradingDate: due.tradingDate,
            quotes: quoteList,
            news: headlines(on: req),
            earnings: calendar(date: due.tradingDate, on: req),
            now: at
        )

        if let webClient {
            do {
                return try await attempt(
                    webClient, webSearch: true, model: webModel, degraded: false,
                    due: due, facts: facts, quotes: quoteList, at: at, on: req
                )
            } catch {
                req.logger.warning(
                    "market_brief_web_attempt_failed",
                    metadata: ["slot": .string(due.slot.rawValue), "error": .string(String(describing: error))]
                )
            }
        }
        return try await attempt(
            fallbackClient(), webSearch: false, model: Self.fallbackModelLabel, degraded: true,
            due: due, facts: facts, quotes: quoteList, at: at, on: req
        )
    }

    private func attempt(
        _ client: any OpenAIChatClient,
        webSearch: Bool,
        model: String,
        degraded: Bool,
        due: MarketBriefSchedule.Due,
        facts: MarketBriefFacts,
        quotes: [IndexQuote],
        at: Date,
        on req: Request
    ) async throws -> GeneratedMarketBrief {
        let reply = try await client.chat(
            messages: MarketBriefPrompt.messages(facts: facts, webSearch: webSearch),
            tools: [],
            responseFormat: "json_object",
            on: req
        )
        let draft = try MarketBriefDraft.parse(reply.content ?? "")
        let generatedAt = ISO8601DateFormatter().string(from: at)
        let grounded = facts.groundedNumbers
        let responses = try MarketBriefLanguage.allCases.map { language in
            let output = try MarketBriefValidator.validate(
                draft.section(language), slot: due.slot, language: language, grounded: grounded
            )
            if output.dropped > 0 {
                req.logger.info(
                    "market_brief_items_dropped",
                    metadata: ["language": .string(language.rawValue), "dropped": .stringConvertible(output.dropped)]
                )
            }
            return MarketBriefResponse(
                enabled: true,
                tradingDate: due.tradingDate,
                slot: due.slot,
                language: language.rawValue,
                greeting: output.greeting,
                groups: MarketBriefFormatter.groups(slot: due.slot, quotes: quotes, language: language),
                items: output.items,
                generatedAt: generatedAt,
                degraded: degraded
            )
        }
        return GeneratedMarketBrief(responses: responses, model: model)
    }

    private func headlines(on req: Request) async -> [ProviderNewsItem] {
        guard let news else { return [] }
        do {
            return try await news.fetchGeneral(on: req)
        } catch {
            req.logger.warning("market_brief_news_failed", metadata: ["error": .string(String(describing: error))])
            return []
        }
    }

    private func calendar(date: String, on req: Request) async -> [EarningsItemResponse] {
        do {
            return try await earnings.getCalendar(query: EarningsQueryRequest(from: date, to: date), on: req)
        } catch {
            req.logger.warning("market_brief_earnings_failed", metadata: ["error": .string(String(describing: error))])
            return []
        }
    }
}

extension MarketBriefGenerator {
    /// Production wiring. The web client reuses the configured AI key and base
    /// URL with its own model and a longer timeout, since web search adds
    /// latency. No key means no web client, and every run is degraded.
    static func live(app: Application, news: (any NewsProvider)?) -> MarketBriefGenerator {
        let config = AIProviderConfiguration.load()
        let configured = Environment.get("MARKET_BRIEF_MODEL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = configured.isEmpty ? defaultModel : configured
        let webClient: (any OpenAIChatClient)? = config.apiKey.isEmpty || config.baseURL.isEmpty
            ? nil
            : DefaultOpenAIChatClient(
                apiKey: config.apiKey,
                model: model,
                baseURL: config.baseURL,
                maxTokens: 6000,
                timeout: .seconds(90)
            )
        return MarketBriefGenerator(
            quotes: YahooChartQuoteProvider(),
            news: news,
            earnings: app.earningsService,
            webClient: webClient,
            webModel: model,
            fallbackClient: { app.openAIChatClient },
            now: { Date() }
        )
    }
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `LOG_LEVEL=warning swift test --filter MarketBriefGeneratorTests`
Expected: 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/StockPlanBackend/MarketBrief/MarketBriefGenerator.swift Tests/StockPlanBackendTests/MarketBriefFixtures.swift Tests/StockPlanBackendTests/MarketBriefGeneratorTests.swift
git commit -m "feat(market-brief): generator with web-search attempt and degraded fallback"
git show --stat HEAD
```

---

### Task 9: Runner, scheduled job, operator command, wiring

**Files:**
- Create: `Sources/StockPlanBackend/MarketBrief/MarketBriefRunner.swift`
- Create: `Sources/StockPlanBackend/MarketBrief/MarketBriefJob.swift`
- Create: `Sources/StockPlanBackend/MarketBrief/MarketBriefGenerateCommand.swift`
- Create: `Sources/StockPlanBackend/MarketBrief/MarketBrief+Application.swift`
- Modify: `Sources/StockPlanBackend/configure.swift`, between the PILOTS block (ends ~line 499) and the `portfolio-backfill` command (~line 501)
- Modify: `Tests/StockPlanBackendTests/MarketBriefFixtures.swift` (append `StubMarketBriefGenerator`)
- Test: `Tests/StockPlanBackendTests/MarketBriefJobTests.swift`

**Interfaces:**
- Consumes: `MarketBriefGenerating`, `GeneratedMarketBrief` (Task 8); `MarketBriefRepository` (Task 7); `MarketBriefSchedule` (Task 2); `JobLock.runAsLeader`; `BackgroundJobState`; `envBool(_:default:)`.
- Produces:
  - `MarketBriefRunner` (`generator`, `repository`) with `run(_ due:, replace: Bool, on req: Request) async throws -> Outcome`, where `Outcome` is `.skippedExisting` or `.generated(degraded: Bool)`.
  - `MarketBriefJob` with `tick(_ app: Application, now: Date) async` and `static let maxAttemptsPerSlot = 3`.
  - `MarketBriefGenerateCommand`.
  - `app.marketBriefRepository`, `app.marketBriefGenerator`, `app.marketBriefEnabled`.

- [ ] **Step 1: Append the generator stub**

Append to `MarketBriefFixtures.swift`:

```swift
final class StubMarketBriefGenerator: MarketBriefGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var error: (any Error)?

    init(error: (any Error)? = nil) {
        self.error = error
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func generate(_ due: MarketBriefSchedule.Due, on _: Request) async throws -> GeneratedMarketBrief {
        lock.lock()
        count += 1
        lock.unlock()
        if let error { throw error }
        return GeneratedMarketBrief(
            responses: MarketBriefLanguage.allCases.map {
                MarketBriefFixtures.response(date: due.tradingDate, slot: due.slot, language: $0.rawValue)
            },
            model: "stub"
        )
    }
}
```

- [ ] **Step 2: Write the failing test**

`Tests/StockPlanBackendTests/MarketBriefJobTests.swift`:

```swift
import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Market brief runner and job", .serialized)
struct MarketBriefJobTests {
    private let due = MarketBriefSchedule.Due(tradingDate: "2026-10-08", slot: .morning)
    /// Thursday 2026-10-08 08:30 Lisbon (WEST) = 07:30 UTC: inside the morning window.
    private let inWindow = Date(timeIntervalSince1970: 1_791_444_600)
    /// Same day 12:10 UTC = 13:10 Lisbon: no window.
    private let outOfWindow = Date(timeIntervalSince1970: 1_791_461_400)

    private func request(_ app: Application) -> Request {
        Request(application: app, on: app.eventLoopGroup.next())
    }

    @Test("Runner generates once, then skips the existing slot without calling the generator")
    func runnerSkipsExisting() async throws {
        try await MarketBriefFixtures.withApp { app in
            let generator = StubMarketBriefGenerator()
            let runner = MarketBriefRunner(generator: generator, repository: DatabaseMarketBriefRepository())
            #expect(try await runner.run(due, replace: false, on: request(app)) == .generated(degraded: false))
            #expect(try await runner.run(due, replace: false, on: request(app)) == .skippedExisting)
            #expect(generator.calls == 1)
        }
    }

    @Test("Replace regenerates an existing slot")
    func runnerReplace() async throws {
        try await MarketBriefFixtures.withApp { app in
            let generator = StubMarketBriefGenerator()
            let runner = MarketBriefRunner(generator: generator, repository: DatabaseMarketBriefRepository())
            _ = try await runner.run(due, replace: false, on: request(app))
            #expect(try await runner.run(due, replace: true, on: request(app)) == .generated(degraded: false))
            #expect(generator.calls == 2)
        }
    }

    @Test("A replica that loses the insert race reports skippedExisting, not a failure")
    func lostRaceIsSkip() async throws {
        try await MarketBriefFixtures.withApp { app in
            let repo = DatabaseMarketBriefRepository()
            // The other replica wrote the slot after our `exists` check would have run.
            let racing = RacingRepository(inner: repo, otherReplica: {
                try await repo.save(
                    MarketBriefLanguage.allCases.map { MarketBriefFixtures.response(language: $0.rawValue) },
                    model: "other", generatedAt: Date(), on: app.db
                )
            })
            let runner = MarketBriefRunner(generator: StubMarketBriefGenerator(), repository: racing)
            #expect(try await runner.run(due, replace: false, on: request(app)) == .skippedExisting)
        }
    }

    @Test("Tick does nothing outside a window")
    func tickOutsideWindow() async throws {
        try await MarketBriefFixtures.withApp { app in
            let generator = StubMarketBriefGenerator()
            app.marketBriefGenerator = generator
            await MarketBriefJob().tick(app, now: outOfWindow)
            #expect(generator.calls == 0)
        }
    }

    @Test("Tick stops retrying a slot after three failures")
    func tickAttemptCap() async throws {
        try await MarketBriefFixtures.withApp { app in
            let generator = StubMarketBriefGenerator(error: Abort(.badGateway))
            app.marketBriefGenerator = generator
            let job = MarketBriefJob()
            for _ in 0 ..< 5 {
                await job.tick(app, now: inWindow)
            }
            #expect(generator.calls == MarketBriefJob.maxAttemptsPerSlot)
        }
    }

    @Test("Tick in window writes the slot once")
    func tickWrites() async throws {
        try await MarketBriefFixtures.withApp { app in
            let generator = StubMarketBriefGenerator()
            app.marketBriefGenerator = generator
            let job = MarketBriefJob()
            await job.tick(app, now: inWindow)
            await job.tick(app, now: inWindow)
            #expect(generator.calls == 1)
            #expect(try await app.marketBriefRepository.exists(tradingDate: "2026-10-08", slot: .morning, on: app.db))
        }
    }

    @Test("configure registers the operator command and leaves the feature off by default")
    func wiring() async throws {
        try await MarketBriefFixtures.withApp { app in
            #expect(app.marketBriefEnabled == false)
            #expect(app.marketBriefGenerator != nil)
            #expect(app.asyncCommands.commands["market-brief-generate"] != nil)
        }
    }
}

/// Reports "not there" from `exists`, then lets another replica write first.
private struct RacingRepository: MarketBriefRepository {
    let inner: DatabaseMarketBriefRepository
    let otherReplica: @Sendable () async throws -> Void

    func exists(tradingDate _: String, slot _: MarketBriefSlot, on _: any Database) async throws -> Bool {
        try await otherReplica()
        return false
    }

    func save(_ briefs: [MarketBriefResponse], model: String, generatedAt: Date, on db: any Database) async throws {
        try await inner.save(briefs, model: model, generatedAt: generatedAt, on: db)
    }

    func delete(tradingDate: String, slot: MarketBriefSlot, on db: any Database) async throws {
        try await inner.delete(tradingDate: tradingDate, slot: slot, on: db)
    }

    func latest(language: String, on db: any Database) async throws -> MarketBriefResponse? {
        try await inner.latest(language: language, on: db)
    }

    func find(tradingDate: String, slot: MarketBriefSlot, language: String, on db: any Database) async throws -> MarketBriefResponse? {
        try await inner.find(tradingDate: tradingDate, slot: slot, language: language, on: db)
    }
}
```

The timestamps were checked with `date -u -r`: `1791444600` is 2026-10-08T07:30:00Z and `1791461400` is 2026-10-08T12:10:00Z.

- [ ] **Step 3: Run the test and confirm it fails**

Run: `LOG_LEVEL=warning swift test --filter MarketBriefJobTests`
Expected: compile failure, `cannot find 'MarketBriefRunner' in scope`.

- [ ] **Step 4: Write app storage, runner, job and command**

`Sources/StockPlanBackend/MarketBrief/MarketBrief+Application.swift`:

```swift
import Vapor

extension Application {
    private struct MarketBriefRepositoryKey: StorageKey {
        typealias Value = any MarketBriefRepository
    }

    private struct MarketBriefGeneratorKey: StorageKey {
        typealias Value = any MarketBriefGenerating
    }

    private struct MarketBriefEnabledKey: StorageKey {
        typealias Value = Bool
    }

    var marketBriefRepository: any MarketBriefRepository {
        get { storage[MarketBriefRepositoryKey.self] ?? DatabaseMarketBriefRepository() }
        set { storage[MarketBriefRepositoryKey.self] = newValue }
    }

    /// Built on every boot so the operator command works with the flag off.
    var marketBriefGenerator: (any MarketBriefGenerating)? {
        get { storage[MarketBriefGeneratorKey.self] }
        set { storage[MarketBriefGeneratorKey.self] = newValue }
    }

    /// `MARKET_BRIEF_ENABLED`. Gates the scheduled job and what the route
    /// serves. Stored here rather than read per request so tests can flip it.
    var marketBriefEnabled: Bool {
        get { storage[MarketBriefEnabledKey.self] ?? false }
        set { storage[MarketBriefEnabledKey.self] = newValue }
    }
}
```

`Sources/StockPlanBackend/MarketBrief/MarketBriefRunner.swift`:

```swift
import Fluent
import Foundation
import Vapor

/// Fills one slot. Shared by the scheduled job and the operator command.
struct MarketBriefRunner: Sendable {
    enum Outcome: Equatable, Sendable {
        case skippedExisting
        case generated(degraded: Bool)
    }

    let generator: any MarketBriefGenerating
    let repository: any MarketBriefRepository

    func run(_ due: MarketBriefSchedule.Due, replace: Bool, on req: Request) async throws -> Outcome {
        if replace {
            try await repository.delete(tradingDate: due.tradingDate, slot: due.slot, on: req.db)
        } else if try await repository.exists(tradingDate: due.tradingDate, slot: due.slot, on: req.db) {
            return .skippedExisting
        }
        let brief = try await generator.generate(due, on: req)
        do {
            try await repository.save(brief.responses, model: brief.model, generatedAt: Date(), on: req.db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // Another replica (or a manual run) wrote the slot while we were
            // generating. Theirs stands; this is not a failure to retry.
            return .skippedExisting
        }
        return .generated(degraded: brief.responses.contains(where: \.degraded))
    }
}
```

`Sources/StockPlanBackend/MarketBrief/MarketBriefJob.swift`:

```swift
import Foundation
import NIOCore
import StockPlanShared
import Vapor

/// Fills the 08:15 and 22:30 Lisbon slots.
///
/// Same lifecycle shape as `SentimentAggregationJob`: a repeated task, an
/// overlap guard and a shutdown drain, because this codebase has no queue or
/// cron. A five-minute tick asks `MarketBriefSchedule` whether a window is
/// open; the database (unique per slot and language) is the record of what
/// is done, so restarts and extra replicas cost a cheap `exists` query, not a
/// second brief. Failures retry on later ticks, up to
/// `maxAttemptsPerSlot` per slot per process, so a broken provider costs
/// three paid calls rather than one every five minutes until noon.
final class MarketBriefJob: LifecycleHandler, @unchecked Sendable {
    static let maxAttemptsPerSlot = 3

    private let tickIntervalSeconds: Int64
    private let initialDelaySeconds: Int64
    private let state = BackgroundJobState()
    private let attempts = MarketBriefAttempts()

    init(tickIntervalSeconds: Int64 = 300, initialDelaySeconds: Int64 = 60) {
        self.tickIntervalSeconds = max(tickIntervalSeconds, 60)
        self.initialDelaySeconds = max(initialDelaySeconds, 0)
    }

    func didBoot(_ app: Application) throws {
        guard app.environment != .testing else { return }
        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(initialDelaySeconds),
            delay: .seconds(tickIntervalSeconds)
        ) { _ in
            guard self.state.begin() else { return }
            let task = Task {
                defer { self.state.finish() }
                await self.tick(app, now: Date())
            }
            self.state.track(task: task)
        }
        state.set(scheduled: scheduled)
    }

    func shutdown(_: Application) {
        state.stopAcceptingRuns()
    }

    func shutdownAsync(_: Application) async {
        await state.stopAndDrain()
    }

    func tick(_ app: Application, now: Date) async {
        guard let due = MarketBriefSchedule.dueSlot(now: now) else { return }
        guard attempts.failures(for: due) < Self.maxAttemptsPerSlot else { return }
        guard let generator = app.marketBriefGenerator else {
            app.logger.warning("market_brief skipped: no generator configured")
            return
        }
        let runner = MarketBriefRunner(generator: generator, repository: app.marketBriefRepository)
        await JobLock.runAsLeader(app, name: "market_brief_job") {
            let req = Request(application: app, on: app.eventLoopGroup.next())
            do {
                let outcome = try await runner.run(due, replace: false, on: req)
                if case let .generated(degraded) = outcome {
                    app.logger.info("market_brief ok date=\(due.tradingDate) slot=\(due.slot.rawValue) degraded=\(degraded)")
                }
            } catch {
                let failures = self.attempts.recordFailure(for: due)
                app.logger.error(
                    "market_brief failed date=\(due.tradingDate) slot=\(due.slot.rawValue) attempt=\(failures)/\(Self.maxAttemptsPerSlot) error=\(String(describing: error))"
                )
            }
        }
    }
}

/// Per-process failure counts per slot. In-memory on purpose: a restart
/// earning three fresh attempts is fine.
private final class MarketBriefAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [MarketBriefSchedule.Due: Int] = [:]

    func failures(for due: MarketBriefSchedule.Due) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[due] ?? 0
    }

    @discardableResult
    func recordFailure(for due: MarketBriefSchedule.Due) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let next = (counts[due] ?? 0) + 1
        counts[due] = next
        return next
    }
}
```

`Sources/StockPlanBackend/MarketBrief/MarketBriefGenerateCommand.swift`:

```swift
import Foundation
import StockPlanShared
import Vapor

/// Generates one brief now, outside the schedule.
///
///     ./StockPlanBackend market-brief-generate --slot morning [--date 2026-10-08] [--replace]
///
/// Works with `MARKET_BRIEF_ENABLED` off, which is how staging is checked
/// before the job is switched on.
struct MarketBriefGenerateCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "slot", help: "morning or evening")
        var slot: String?

        @Option(name: "date", help: "Lisbon trading date, yyyy-MM-dd (default: today in Lisbon)")
        var date: String?

        @Flag(name: "replace", help: "Delete and regenerate an existing brief for that date and slot.")
        var replace: Bool
    }

    let help = "Generate one market brief now, outside the schedule."

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        guard let raw = signature.slot, let slot = MarketBriefSlot(rawValue: raw) else {
            throw Abort(.badRequest, reason: "--slot must be morning or evening")
        }
        guard let generator = app.marketBriefGenerator else {
            throw Abort(.serviceUnavailable, reason: "market brief generator is not configured")
        }
        let due = MarketBriefSchedule.Due(
            tradingDate: signature.date ?? MarketBriefSchedule.localDate(Date()),
            slot: slot
        )
        let req = Request(application: app, on: app.eventLoopGroup.next())
        let outcome = try await MarketBriefRunner(generator: generator, repository: app.marketBriefRepository)
            .run(due, replace: signature.replace, on: req)
        context.console.print("market-brief \(due.tradingDate) \(slot.rawValue): \(outcome)")
    }
}
```

- [ ] **Step 5: Wire everything up in configure.swift**

Insert between the closing `}` of the `if envBool("PILOTS_ENABLED", …)` block and the `// Operator-triggered reconstruction…` comment:

```swift
    // Market brief: two shared briefs per weekday, 08:15 and 22:30 Lisbon.
    // The generator is built on every boot so the operator command works with
    // the flag off; MARKET_BRIEF_ENABLED gates only the scheduled job and what
    // the route serves. `newsProvider` is the same chain the news feed uses.
    app.marketBriefRepository = DatabaseMarketBriefRepository()
    app.marketBriefGenerator = MarketBriefGenerator.live(app: app, news: newsProvider)
    app.marketBriefEnabled = envBool("MARKET_BRIEF_ENABLED", default: false)
    if app.marketBriefEnabled {
        app.lifecycle.use(MarketBriefJob())
    }
    app.asyncCommands.use(MarketBriefGenerateCommand(), as: "market-brief-generate")
```

- [ ] **Step 6: Run the tests and confirm they pass**

Run: `LOG_LEVEL=warning swift test --filter MarketBriefJobTests`
Expected: 7 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/StockPlanBackend/MarketBrief/ Sources/StockPlanBackend/configure.swift Tests/StockPlanBackendTests/MarketBriefFixtures.swift Tests/StockPlanBackendTests/MarketBriefJobTests.swift
git commit -m "feat(market-brief): scheduled job, runner and market-brief-generate command"
git show --stat HEAD
```

---

### Task 10: Read route and OpenAPI

**Files:**
- Create: `Sources/StockPlanBackend/MarketBrief/MarketBriefController.swift`
- Modify: `Sources/StockPlanBackend/routes.swift:75`, adding the registration after `MarketDataController`
- Modify: `Sources/StockPlanBackend/Shared/StockPlanShared+Content.swift`, adding `extension MarketBriefResponse: @retroactive Content {}` next to the `NewsTickerResponse` line (~385)
- Modify: `Sources/StockPlanBackend/openapi.yaml`: the path goes before `  /v1/news/ticker:` (~line 1879); the schemas go before `    NewsTickerResponse:` (~line 13776)
- Modify: `Tests/StockPlanBackendTests/OpenAPIDocsTests.swift`, adding one test
- Test: `Tests/StockPlanBackendTests/MarketBriefRouteTests.swift`

**Interfaces:**
- Consumes: `app.marketBriefEnabled`, `app.marketBriefRepository` (Task 9); `MarketBriefLanguage.resolve` (Task 4); `ScopedBearerAuthenticator`, `SessionToken.guardMiddleware()`, `ScopeRequirementMiddleware(.marketRead)`.
- Produces: `GET /v1/market/brief?lang=&slot=&date=` returning `MarketBriefResponse`.

- [ ] **Step 1: Write the failing route test**

`Tests/StockPlanBackendTests/MarketBriefRouteTests.swift`:

```swift
import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Market brief route", .serialized)
struct MarketBriefRouteTests {
    private func registerUser(app: Application) async throws -> UUID {
        let id = UUID().uuidString.prefix(8).lowercased()
        let register = StockPlanBackend.AuthRegisterRequest(
            username: "brief_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "brief_\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var token = ""
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            token = try res.content.decode(AuthResponse.self).token
        })
        return try await app.jwt.keys.verify(token, as: SessionToken.self).userId
    }

    /// Same as `MCPTokenAuthTests.mintPAT`: the web's PUBLIC_API_TOKEN is a PAT like this.
    private func mintPAT(app: Application, userId: UUID, scopes: [APIScope]) async throws -> String {
        let raw = OpaqueToken.generate(prefix: OpaqueToken.patPrefix)
        let pat = PersonalAccessToken(
            userId: userId, name: "test", tokenHash: OpaqueToken.sha256Hex(raw),
            scopes: scopes.map(\.rawValue), expiresAt: Date().addingTimeInterval(3600)
        )
        try await pat.save(on: app.db)
        return raw
    }

    private func get(
        _ app: Application, _ path: String, token: String?,
        _ check: @escaping (TestingHTTPResponse) async throws -> Void
    ) async throws {
        try await app.testing().test(.GET, path, beforeRequest: { req in
            if let token { req.headers.bearerAuthorization = BearerAuthorization(token: token) }
        }, afterResponse: check)
    }

    private func seed(_ app: Application) async throws {
        let repo = app.marketBriefRepository
        let morning = Date(timeIntervalSince1970: 1_791_500_000)
        try await repo.save(
            MarketBriefLanguage.allCases.map { MarketBriefFixtures.response(slot: .morning, language: $0.rawValue) },
            model: "m", generatedAt: morning, on: app.db
        )
        try await repo.save(
            MarketBriefLanguage.allCases.map { MarketBriefFixtures.response(slot: .evening, language: $0.rawValue) },
            model: "m", generatedAt: morning.addingTimeInterval(14 * 3600), on: app.db
        )
    }

    @Test("No token is 401; a PAT without market:read is 403")
    func authMatrix() async throws {
        try await MarketBriefFixtures.withApp { app in
            let user = try await registerUser(app: app)
            let wrongScope = try await mintPAT(app: app, userId: user, scopes: [.expensesRead])
            try await get(app, "v1/market/brief", token: nil) { #expect($0.status == .unauthorized) }
            try await get(app, "v1/market/brief", token: wrongScope) { #expect($0.status == .forbidden) }
        }
    }

    @Test("Flag off: 200 with enabled false")
    func disabled() async throws {
        try await MarketBriefFixtures.withApp { app in
            let pat = try await mintPAT(app: app, userId: registerUser(app: app), scopes: [.marketRead])
            try await get(app, "v1/market/brief?lang=pt-PT", token: pat) { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(MarketBriefResponse.self)
                #expect(body.enabled == false)
                #expect(body.language == "pt-PT")
            }
        }
    }

    @Test("Flag on, nothing generated: enabled with no brief")
    func enabledEmpty() async throws {
        try await MarketBriefFixtures.withApp { app in
            app.marketBriefEnabled = true
            let pat = try await mintPAT(app: app, userId: registerUser(app: app), scopes: [.marketRead])
            try await get(app, "v1/market/brief", token: pat) { res in
                let body = try res.content.decode(MarketBriefResponse.self)
                #expect(body.enabled)
                #expect(body.tradingDate == nil)
            }
        }
    }

    @Test("Latest brief per language, unknown language falls back to en, private cache header")
    func latest() async throws {
        try await MarketBriefFixtures.withApp { app in
            app.marketBriefEnabled = true
            try await seed(app)
            let pat = try await mintPAT(app: app, userId: registerUser(app: app), scopes: [.marketRead])
            try await get(app, "v1/market/brief?lang=pt", token: pat) { res in
                #expect(res.headers.first(name: .cacheControl) == "private, max-age=300")
                let body = try res.content.decode(MarketBriefResponse.self)
                #expect(body.slot == .evening)
                #expect(body.language == "pt-PT")
            }
            try await get(app, "v1/market/brief?lang=de", token: pat) { res in
                #expect(try res.content.decode(MarketBriefResponse.self).language == "en")
            }
        }
    }

    @Test("Exact slot and date: found, 404 when missing, 400 on a bad slot or date")
    func exact() async throws {
        try await MarketBriefFixtures.withApp { app in
            app.marketBriefEnabled = true
            try await seed(app)
            let pat = try await mintPAT(app: app, userId: registerUser(app: app), scopes: [.marketRead])
            try await get(app, "v1/market/brief?slot=morning&date=2026-10-08", token: pat) { res in
                #expect(try res.content.decode(MarketBriefResponse.self).slot == .morning)
            }
            try await get(app, "v1/market/brief?slot=morning&date=2026-10-09", token: pat) { #expect($0.status == .notFound) }
            try await get(app, "v1/market/brief?slot=noon&date=2026-10-08", token: pat) { #expect($0.status == .badRequest) }
            try await get(app, "v1/market/brief?slot=morning&date=08-10-2026", token: pat) { #expect($0.status == .badRequest) }
        }
    }
}
```

Use whatever response type the existing `afterResponse` closures take. If `TestingHTTPResponse` is not the name `VaporTesting` exposes in this package version, copy the type from `MCPTokenAuthTests`.

- [ ] **Step 2: Run the test and confirm it fails**

Run: `LOG_LEVEL=warning swift test --filter MarketBriefRouteTests`
Expected: the auth test fails, `404 Not Found` instead of 401/403, because the route does not exist yet.

- [ ] **Step 3: Write the controller and register it**

`Sources/StockPlanBackend/MarketBrief/MarketBriefController.swift`:

```swift
import Foundation
import StockPlanShared
import Vapor

/// `GET /v1/market/brief`. Same for every caller, so it sits in the
/// `market:read` group: iOS calls it with the user's session, and the web
/// calls it with its `PUBLIC_API_TOKEN` personal access token, including for
/// logged-out visitors on the landing page. Nothing is unauthenticated.
struct MarketBriefController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        protected.grouped("market", "brief")
            .grouped(ScopeRequirementMiddleware(.marketRead))
            .get(use: show)
    }

    func show(req: Request) async throws -> Response {
        let language = MarketBriefLanguage.resolve(req.query[String.self, at: "lang"]).rawValue
        let brief: MarketBriefResponse
        if !req.application.marketBriefEnabled {
            brief = .empty(language: language, enabled: false)
        } else if let rawSlot = req.query[String.self, at: "slot"] {
            guard let slot = MarketBriefSlot(rawValue: rawSlot) else {
                throw Abort(.badRequest, reason: "slot must be morning or evening")
            }
            guard let date = req.query[String.self, at: "date"], date.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil else {
                throw Abort(.badRequest, reason: "date must be yyyy-MM-dd when slot is given")
            }
            guard let found = try await req.application.marketBriefRepository.find(
                tradingDate: date, slot: slot, language: language, on: req.db
            ) else {
                throw Abort(.notFound, reason: "No market brief for that date and slot.")
            }
            brief = found
        } else {
            brief = try await req.application.marketBriefRepository.latest(language: language, on: req.db)
                ?? .empty(language: language, enabled: true)
        }
        let response = try await brief.encodeResponse(for: req)
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, max-age=300")
        return response
    }
}
```

In `Shared/StockPlanShared+Content.swift`, next to `extension NewsTickerResponse: @retroactive Content {}`:

```swift
extension MarketBriefResponse: @retroactive Content {}
```

In `routes.swift`, directly after `try api.grouped(marketRateLimit).register(collection: MarketDataController())`:

```swift
    try api.grouped(marketRateLimit).register(collection: MarketBriefController())
```

- [ ] **Step 4: Run the route tests and confirm they pass**

Run: `LOG_LEVEL=warning swift test --filter MarketBriefRouteTests`
Expected: 5 tests pass.

- [ ] **Step 5: Write the failing OpenAPI docs test**

Add to `OpenAPIDocsTests.swift`, inside the existing suite:

```swift
    @Test("Market brief route and schemas are documented")
    func marketBriefIsDocumented() throws {
        let body = try BundledOpenAPISpec.yamlString()
        #expect(body.contains("  /v1/market/brief:"))
        #expect(body.contains("operationId: getMarketBrief"))
        #expect(body.contains("    MarketBriefResponse:"))
        #expect(body.contains("    MarketBriefQuoteGroup:"))
        #expect(body.contains("    MarketBriefQuoteRow:"))
        #expect(body.contains("    MarketBriefItem:"))
    }
```

Run: `LOG_LEVEL=warning swift test --filter OpenAPIDocsTests`
Expected: `marketBriefIsDocumented` fails.

- [ ] **Step 6: Document the route in openapi.yaml**

Insert immediately before the line `  /v1/news/ticker:`:

```yaml
  /v1/market/brief:
    get:
      operationId: getMarketBrief
      tags: [MarketData]
      summary: Latest market brief (morning pre-market or evening recap)
      description: >-
        Shared, non-personalised brief generated twice per weekday (08:15 and
        22:30 Europe/Lisbon). Index rows come from market data; the text is
        model-written and any unsourced number in it was checked against those
        rows. Without `slot` and `date` this returns the newest brief for the
        language, so weekends show Friday's recap. `enabled: false` when the
        feature is off.
      security:
        - bearerAuth: []
      parameters:
        - name: lang
          in: query
          required: false
          description: >-
            `en` or `pt-PT`. Anything starting with `pt` is `pt-PT`; anything
            else is `en`.
          schema:
            type: string
            default: en
        - name: slot
          in: query
          required: false
          description: With `date`, fetch that exact brief instead of the latest.
          schema:
            type: string
            enum: [morning, evening]
        - name: date
          in: query
          required: false
          description: Lisbon trading date, `yyyy-MM-dd`. Required when `slot` is given.
          schema:
            type: string
            format: date
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/MarketBriefResponse'
        '400':
          description: Unknown slot, or slot without a valid date
        '401':
          description: Unauthorized
        '403':
          description: Token lacks the market:read scope
        '404':
          description: No brief for that date and slot
```

Insert immediately before the line `    NewsTickerResponse:`:

```yaml
    MarketBriefQuoteRow:
      type: object
      properties:
        symbol:
          type: string
        flag:
          type: string
        name:
          type: string
        level:
          type: string
          description: Formatted for the response language, for example "25.032" (pt-PT) or "25,032" (en).
        changePercent:
          type: string
          description: Unsigned and formatted, for example "0,77%". `direction` carries the sign.
        direction:
          type: string
          enum: [up, down, flat]
      required: [symbol, flag, name, level, changePercent, direction]
    MarketBriefQuoteGroup:
      type: object
      properties:
        id:
          type: string
          enum: [eu_open, us_futures, eu_close, us_close]
        title:
          type: string
        tone:
          type: string
          enum: [up, down, flat]
        rows:
          type: array
          items:
            $ref: '#/components/schemas/MarketBriefQuoteRow'
      required: [id, title, tone, rows]
    MarketBriefItem:
      type: object
      properties:
        kind:
          type: string
          enum: [highlight, earnings, story]
        text:
          type: string
        tickers:
          type: array
          items:
            type: string
        sourceUrl:
          type: string
          nullable: true
      required: [kind, text, tickers]
    MarketBriefResponse:
      type: object
      properties:
        enabled:
          type: boolean
        tradingDate:
          type: string
          format: date
          nullable: true
        slot:
          type: string
          enum: [morning, evening]
          nullable: true
        language:
          type: string
          enum: [en, pt-PT]
        greeting:
          type: string
          nullable: true
        groups:
          type: array
          items:
            $ref: '#/components/schemas/MarketBriefQuoteGroup'
        items:
          type: array
          items:
            $ref: '#/components/schemas/MarketBriefItem'
        generatedAt:
          type: string
          format: date-time
          nullable: true
        degraded:
          type: boolean
          description: Web search was unavailable; the text came from in-house sources only.
      required: [enabled, language, groups, items, degraded]
```

- [ ] **Step 7: Run the docs check, the feature suites, then everything**

```bash
make backend-openapi-check
LOG_LEVEL=warning swift test --filter "MarketBrief|YahooChart"
make backend-test
```

Expected: all three green. If an unrelated suite fails, run it again on `origin/main`. If it fails there too, report it and carry on.

- [ ] **Step 8: Commit**

```bash
git add Sources/StockPlanBackend/MarketBrief/MarketBriefController.swift Sources/StockPlanBackend/routes.swift Sources/StockPlanBackend/Shared/StockPlanShared+Content.swift Sources/StockPlanBackend/openapi.yaml Tests/StockPlanBackendTests/MarketBriefRouteTests.swift Tests/StockPlanBackendTests/OpenAPIDocsTests.swift
git commit -m "feat(market-brief): GET /v1/market/brief behind market:read, documented"
git show --stat HEAD
```

---

### Task 11: Staging rollout (infra + live check)

Each step here is outward-facing: it opens a PR, merges, deploys or seals a secret. **Ask the user before each one.**

**Files:**
- Modify: `~/Work/production/platform/infra/apps/norviq/api/values-staging.yaml`
- Modify: `~/Work/production/platform/infra/apps/norviq/api/values-production.yaml`
- Possibly modify: `~/Work/production/platform/infra/secrets/norviq/staging/*` (sealed `api-env`)

- [ ] **Step 1: Open the backend PR**

```bash
git push -u origin feat/market-brief
gh pr create --title "feat: market brief (morning pre-market + evening recap)" --body "Implements docs/superpowers/specs/2026-10-08-market-brief-design.md (plan: docs/superpowers/plans/2026-10-08-market-brief-backend.md). Off by default behind MARKET_BRIEF_ENABLED."
```

Wait for CI to pass. If `feat/articles` merged first, rebase and take the higher shared pin (both changes only add types).

- [ ] **Step 2: Add the env vars in the infra repo**

In `values-staging.yaml`, add to the api `env` list, next to the other feature flags:

```yaml
  # Market brief (2026-10-08): two shared briefs per weekday, 08:15 and 22:30
  # Lisbon. Rows from Yahoo's chart API; text from OpenRouter with web search
  # (the `:online` slug). Writing text needs OPENROUTER_API_KEY in api-env;
  # without it every run falls back to a chain with no key and fails, and
  # the card stays empty.
  - name: MARKET_BRIEF_ENABLED
    value: "true"
  - name: MARKET_BRIEF_MODEL
    value: anthropic/claude-haiku-4.5:online
```

In `values-production.yaml`, add the same block with `value: "false"` for `MARKET_BRIEF_ENABLED`. Open an infra PR. Merging it is a deploy, so ask first.

- [ ] **Step 3: Seal OPENROUTER_API_KEY for staging (the user supplies the key)**

`values-staging.yaml:112` says staging's `api-env` has no `OPENROUTER_API_KEY`.
- Follow `secrets/norviq/README.md`. Seal for namespace **`norviq-staging`** and secret name **`api-env`**. A blob sealed for any other namespace silently decrypts to nothing.
- Then confirm the key is there: `KUBECONFIG=~/.kube/maat.yaml kubectl -n norviq-staging get secret api-env -o jsonpath='{.data}' | grep -c OPENROUTER_API_KEY`. Expected output: `1`.

- [ ] **Step 4: Deploy to staging and run one brief by hand**

Dispatch "Deploy to k3s (staging)" (`deploy-k3s.yml`) in norviq-backend on `feat/market-brief`, or on `main` after merge. Then:

```bash
export KUBECONFIG=~/.kube/maat.yaml
kubectl -n norviq-staging get deploy            # find the api deployment name
kubectl -n norviq-staging exec deploy/<api-deployment> -- ./StockPlanBackend market-brief-generate --slot evening
```

Expected: `market-brief <today> evening: generated(degraded: false)`. `degraded: true` means web search failed; read the pod log for `market_brief_web_attempt_failed`.

- [ ] **Step 5: Read the result in both languages**

```bash
curl -s -H "Authorization: Bearer $STAGING_PAT" "https://dev-api.norviq.org/v1/market/brief?lang=pt-PT" | python3 -m json.tool
curl -s -H "Authorization: Bearer $STAGING_PAT" "https://dev-api.norviq.org/v1/market/brief?lang=en" | python3 -m json.tool
```

`$STAGING_PAT` is a staging personal access token with `market:read`.

Check:
- Every row's `level` and `changePercent` matches Yahoo by hand.
- pt-PT uses `25.032` and `0,77%`, and the text is European, not Brazilian, Portuguese.
- No item states a number that is absent from both the rows and its `sourceUrl`.

Then leave the job running for 2–3 weekdays and read each morning and evening brief. Check the `ai_completion` cost lines for the `:online` model.

- [ ] **Step 6: Hand over**

Report to the user:
- staging output samples
- the degraded rate
- the cost per run

Production stays off until web (plan 2) and iOS (plan 3) ship. The production switch is a separate decision: promote with `-f service=both`, then flip `MARKET_BRIEF_ENABLED` in `values-production.yaml`.
