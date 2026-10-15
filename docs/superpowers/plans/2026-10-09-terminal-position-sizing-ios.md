# Terminal Position Sizing (iOS 1.4.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship terminal position sizing in Norviq iOS 1.4.0. It adds a list and editor for per-ticker scenarios with a live preview from the shared `TerminalMath`, autobuys with monthly equivalents, Pro AI suggestions, a dashboard card, a stock-detail card, en + pt-PT copy, and the release notes.

**Architecture:** The networking copies the GoalPlanning layering: a `TerminalPositionsServicing` protocol, a service class that refreshes the token once on a 401, and a Factory registration. Requests go through a dedicated `TerminalPositionsHTTPClient` that wraps `BaseHTTPClient`. It needs its own error type to tell a Pro gate (403 + `code: "upgrade_required"`) from a scope 403, a 503 and a 422. This is the same approach as `PilotsHTTPClient`. Screens are SwiftUI. State lives in `@MainActor @Observable` models (list view model, editor model, autobuy editor model, two card models), and XCTest covers each one against a mock service. Every formula comes from `StockPlanShared.TerminalMath` / `AutobuyMath` (v5.21.0), so the app runs the same code as the backend.

**Tech Stack:** Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and complete strict concurrency, SwiftUI on iOS 18, Factory, AnyAPI + the in-repo `BaseHTTPClient`, StockPlanShared 5.21.0, XCTest, String Catalog (`Localizable.xcstrings`), fastlane metadata.

**Spec:** `/Users/fernandocorreiachill/Work/production/apps/norviq/norviq-backend-terminal/docs/superpowers/specs/2026-10-09-terminal-position-sizing-design.md` (section 5 "iOS 1.4.0", "Order and release gates", "Verification")

**Contract (names, endpoints, copy — verbatim):** `/Users/fernandocorreiachill/Work/production/apps/norviq/norviq-backend-terminal/docs/superpowers/plans/2026-10-09-terminal-contract.md`

**Repo / worktree:** `git@github.com:FinancePlanner/norviq-ios.git`. Work happens in a new worktree at `/Users/fernandocorreiachill/Work/production/apps/norviq/norviq-ios/financeplan-terminal` on branch `feat/terminal-positions`, cut from `origin/main` (currently `fba0158`, MARKETING_VERSION 1.4.0). **Every relative path below is relative to that worktree root.** App sources live under `financeplan/`, tests under `financeplanTests/`. Both are `PBXFileSystemSynchronizedRootGroup`s, so a new file is part of the target automatically and no pbxproj edit is needed.

**Test command used throughout** (one suite at a time; add `ENABLE_USER_SCRIPT_SANDBOXING=NO` only if a script phase fails in the sandbox):

```bash
cd /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-ios/financeplan-terminal && \
xcodebuild -project financeplan.xcodeproj -scheme financeplan \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:financeplanTests/<SuiteName> test 2>&1 | grep -E 'error:|Test Case .*(passed|failed)|\*\* TEST' | tail -40
```

## Global Constraints

- StockPlanShared pin: `exactVersion` **5.18.0 → 5.21.0** in `financeplan.xcodeproj/project.pbxproj` (`XCRemoteSwiftPackageReference "norviq-shared"`), and `Package.resolved` must record 5.21.0. The pin also brings in the 5.19 Articles and 5.20 MarketBrief DTOs, and the build must stay green.
- Formulas come only from `StockPlanShared`: `TerminalMath.evaluate`, `TerminalMath.wholeShares`, `AutobuyMath.monthlyEquivalent`, `AutobuyMath.monthlyTotal`. Never re-implement them in the app.
- Endpoints, DTO names and fields are exactly as the contract states, all under `/v1`.
- **Pro gate:** HTTP **403** with body `{"success":false,"code":"upgrade_required",…,"feature":"terminal_position_ai",…}`. Detect it by `code == "upgrade_required"`, never by status alone, because a plain 403 also means a missing scope. There is no 402.
- The table and autobuys are free. Every AI action is Pro.
- AI only suggests. "Fill with AI" can fill only shares outstanding and today's price. "Suggest scenario" can fill only the future share count and market cap. Accept fills the fields and never saves; only Save writes.
- Copy is verbatim from the contract. en: title "Terminal position sizing", subtitle "Decide the future market cap and share count. Norviq tells you how many shares that target is.", disclaimer "Terminal prices are your assumptions, not forecasts. Not financial advice." pt-PT: "Dimensionamento de posições terminais" / "Define a capitalização bolsista e o número de ações futuros. O Norviq diz-te quantas ações esse objetivo representa." / "Os preços terminais são pressupostos teus, não previsões. Não é aconselhamento financeiro."
- The disclaimer appears on the screen and in the editor (and on both cards).
- Big-number fields (future share count, future market cap, value wanted, shares outstanding) are a value field plus a unit picker **—/K/M/B/T**, parsed with `Utilities/MoneyInputParser.parse(_:locale:)`. Do not use `FormTextField`, whose formatter rejects commas.
- Currency is the `currency` field of the API responses. There is no global base currency.
- Percent cadence: monthly equivalent = monthly base (`amount`) × `percent` (0–1 on the wire, typed as 0–100 in the UI). With no base it is nil and left out of the total. Bimonthly means every two months (× 6/12).
- Ticker: trimmed, uppercased, `^[A-Z0-9.\-]{1,12}$`.
- Name types for what they do, never for a vendor. No new dependencies and no paid APIs.
- Tests: XCTest, `@MainActor final class …Tests: XCTestCase`, and **every test method `async`** (see `PilotsStoreTests` for the synchronous-deinit crash this avoids). Use a mock service and no network.
- Strings: the English text is the key. Every new key gets a pt-PT translation in `financeplan/Localizable.xcstrings`, and no orphaned keys are left behind (AGENTS.md).
- Style: SwiftFormat `--indent 2`, SwiftLint via `./scripts/format.sh --skip-install --lint-only` (CI runs it).
- Branch `feat/terminal-positions` off `origin/main` in a worktree. **Merging to `main` triggers a TestFlight build automatically** ("iOS CI" green on main → `release.yml` beta lane). The App Store release is a manual `release.yml` dispatch and happens **only after production serves `/v1/terminal-positions`**. That dispatch is a user-approved step and is never run by this plan.
- Release notes lead bullet (verbatim): `• Terminal position sizing — set a future market cap and share count and see how many shares your target takes (your assumptions, not advice)`

## Review Focus

1. **pt-PT decimal commas and prefill round trips.** In pt-PT, "1,5" with unit B must read as 1.5 billion. Opening a saved row and saving it unchanged in either locale must not send a nudged number. Pinned by `TerminalNumberInputTests.testPrefillNeverChangesTheStoredNumber` (Task 4) and `TerminalPositionEditorModelTests.testUnchangedEditInPortugueseSendsNothing` (Task 7).
2. **A typed or pasted minus sign.** `MoneyInputParser` drops "-", so "-100" would silently become 100. It must be refused with "Can't be negative." Pinned by `TerminalNumberInputTests.testMinusSignIsRefusedNotDropped` (Task 4) and `TerminalPositionEditorModelTests.testTypedMinusIsRefusedNotFlipped` (Task 7).
3. **Reorder races.** A failed or conflicting reorder (422 because another device added or removed a row), or two quick drags, must end in the server's order, never a local order the server doesn't have. Pinned by `testFailedMoveReloadsTheServerOrder` and `testRapidMovesKeepTheLastOrder` (Task 6).
4. **403 upgrade vs 403 scope.** Only a body with `code: "upgrade_required"` may open the paywall. A scope 403 shows a plain message. Pinned by `TerminalPositionsHTTPClientTests.testUpgradeRequiredBodyBecomesUpgradeRequired` / `testPlainForbiddenStaysRejected` (Task 2) and `TerminalPositionEditorModelTests.testPlainForbiddenDoesNotAskForThePaywall` (Task 8).
5. **Backend not deployed yet.** A TestFlight build ships on merge, and before the backend is promoted, production answers 404. In that state the dashboard card and stock card must disappear, and the screen must show one message without crashing. Pinned by `TerminalCardModelsTests.testSummaryNotFoundHidesTheCard` / `testStockCardNotFoundHides` (Tasks 13–14) and `TerminalPositionsViewModelTests.testLoadFailureShowsAMessageAndNoSample` (Task 5).

---

## File Structure

| File | Responsibility |
|---|---|
| `financeplan/API/TerminalPositions/TerminalPositionsEndpoints.swift` | One `Endpoint` per route; JSON bodies via `JSONEncoder.stockPlanShared` |
| `financeplan/API/TerminalPositions/TerminalPositionsHTTPClient.swift` | `BaseHTTPClient` wrapper and its error type (upgrade / rejected / cancelled) |
| `financeplan/API/TerminalPositions/TerminalPositionsService.swift` | `TerminalPositionsServicing` + token-refreshing implementation |
| `financeplan/API/TerminalPositions/Container+TerminalPositionsFactories.swift` | `Container.terminalPositionsService` |
| `financeplan/Features/TerminalPositions/TerminalNumberInput.swift` | `TerminalUnit` and the value + unit field model (parse, prefill) |
| `financeplan/Features/TerminalPositions/TerminalFormat.swift` | Display formatting and `TerminalCopy` (localized title/subtitle/disclaimer) |
| `financeplan/Features/TerminalPositions/TerminalPositionsViewModel.swift` | List state, totals, sample, delete/duplicate/reorder, autobuys list; `TerminalPreferences`, `TerminalPositionsErrorText` |
| `financeplan/Features/TerminalPositions/TerminalPositionEditorModel.swift` | Editor form, live preview, guardrails, create/PATCH requests, AI suggestions |
| `financeplan/Features/TerminalPositions/TerminalPositionEditorSheet.swift` | Editor UI, `TerminalNumberInputField`, `TerminalSourcesList`, `TerminalEditorTarget` |
| `financeplan/Features/TerminalPositions/TerminalPositionsScreen.swift` | The list screen and `TerminalPositionRow` |
| `financeplan/Features/TerminalPositions/AutobuyEditorModel.swift` | Autobuy form, monthly-equivalent preview, requests; `AutobuyCadence.title` |
| `financeplan/Features/TerminalPositions/AutobuyEditorSheet.swift` | Autobuy editor UI, `AutobuyEditorTarget`, `TerminalAutobuysSection`, `AutobuyRow` |
| `financeplan/Features/TerminalPositions/TerminalDashboardCard.swift` | `TerminalSummaryCardModel` + dashboard card |
| `financeplan/Features/TerminalPositions/StockTerminalCard.swift` | `StockTerminalCardModel` + stock-detail card |
| Modify `financeplan/Features/Portfolio/PortfolioRoot.swift` | Route + Planning menu item |
| Modify `financeplan/Features/Home/DashboardRoot.swift` | Card slot + `navigationDestination(isPresented:)` |
| Modify `financeplan/Features/Stocks/Detail/StockOverviewTab.swift` | `StockTerminalCard(symbol:)` after `StockPressureCard` |
| Modify `financeplan/Localizable.xcstrings` | en + pt-PT for every new key |
| Modify `fastlane/metadata/en-US/release_notes.txt` | Lead bullet |
| Tests: `financeplanTests/StockPlanSharedPinTests.swift`, `TerminalPositionsHTTPTestSupport.swift`, `TerminalPositionsHTTPClientTests.swift`, `TerminalPositionsServiceTests.swift`, `TerminalNumberInputTests.swift`, `TerminalPositionsTestSupport.swift`, `TerminalPositionsViewModelTests.swift`, `TerminalPositionEditorModelTests.swift`, `AutobuyEditorModelTests.swift`, `TerminalCardModelsTests.swift` | |

---

### Task 1: Worktree, test baseline and the StockPlanShared 5.21.0 pin

**Files:**
- Modify: `financeplan.xcodeproj/project.pbxproj:1003-1009` (the `norviq-shared` requirement)
- Modify: `financeplan.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (generated)
- Test: `financeplanTests/StockPlanSharedPinTests.swift`

**Interfaces:**
- Consumes: StockPlanShared v5.21.0 (`TerminalScenarioInput`, `TerminalMath`, `AutobuyMath`, the DTOs in the contract).
- Produces: a building app on 5.21.0, plus a baseline list of failing tests at `/tmp/terminal-ios-baseline.txt` that later tasks compare against.

- [ ] **Step 1: Confirm v5.21.0 is tagged**

Run: `git ls-remote --tags https://github.com/FinancePlanner/norviq-shared.git refs/tags/v5.21.0`
Expected: one line ending in `refs/tags/v5.21.0`. If the output is empty, **stop**. The shared release (spec step 1) has not shipped yet, and nothing below compiles without it.

- [ ] **Step 2: Create the worktree**

```bash
cd /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-ios/financeplan
git fetch origin
git worktree add ../financeplan-terminal -b feat/terminal-positions origin/main
cd ../financeplan-terminal && git log --oneline -1
```
Expected: the last line shows `fba0158` or a later main commit. `Config/Secrets.xcconfig` is tracked, so the worktree builds as is.

- [ ] **Step 3: Record the unit-test baseline on untouched main**

```bash
cd /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-ios/financeplan-terminal && \
make ios-test 2>&1 | grep -E "Test Case .*failed" | sort -u > /tmp/terminal-ios-baseline.txt; wc -l /tmp/terminal-ios-baseline.txt
```
Expected: a count, possibly non-zero (earlier sessions saw failures in `StockServiceTests` and `PortfolioViewModelTests`). Any failure later that is **not** in this file was caused by this branch.

- [ ] **Step 4: Write the failing test**

```swift
// financeplanTests/StockPlanSharedPinTests.swift
import StockPlanShared
import XCTest

/// Does not compile below StockPlanShared 5.21.0: the terminal maths ships
/// there, and the app must run the same code as the backend.
@MainActor
final class StockPlanSharedPinTests: XCTestCase {
  func testTerminalMathIsTheSharedImplementation() async {
    let input = TerminalScenarioInput(
      terminalShareCount: 11_000_000_000,
      terminalMarketCap: 10_000_000_000_000,
      valueWanted: 1_000_000,
      sharesOwned: 750
    )
    guard case let .success(result) = TerminalMath.evaluate(input) else {
      return XCTFail("The AMZN worked example must be valid")
    }
    XCTAssertEqual(result.terminalSharePrice, 909.0909, accuracy: 0.0001)
    XCTAssertEqual(result.sharesNeeded, 1_100, accuracy: 0.000001)
    XCTAssertEqual(result.progress, 0.681818, accuracy: 0.000001)
    XCTAssertEqual(
      AutobuyMath.monthlyEquivalent(amount: 50, cadence: .weekly, percent: nil) ?? 0,
      50 * 52 / 12,
      accuracy: 0.000001
    )
  }
}
```

- [ ] **Step 5: Run it to verify it fails**

Run the test command with `<SuiteName>` = `StockPlanSharedPinTests`.
Expected: FAIL to compile with `cannot find 'TerminalScenarioInput' in scope`.

- [ ] **Step 6: Bump the pin and resolve**

```bash
cd /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-ios/financeplan-terminal
sed -i '' '/norviq-shared.git/,/};/ s/version = 5.18.0;/version = 5.21.0;/' financeplan.xcodeproj/project.pbxproj
grep -n -A4 'norviq-shared.git' financeplan.xcodeproj/project.pbxproj
xcodebuild -resolvePackageDependencies -project financeplan.xcodeproj -scheme financeplan 2>&1 | tail -5
grep -n -A6 '"identity" : "norviq-shared"' financeplan.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```
Expected: the pbxproj shows `version = 5.21.0;`. `Package.resolved` shows `"version" : "5.21.0"` with a new `revision`.

- [ ] **Step 7: Build the app and fix any break from 5.19/5.20**

Run: `make ios-build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head -30`
Expected: `** BUILD SUCCEEDED **`. Here is what was checked when this plan was written. Between v5.18.0 and v5.20.0 the public API is additive only: the Articles DTOs, the MarketBrief DTOs, and SwiftFormat re-wrapping of `ScenarioKind`, `RecoveryModel`, `MonteCarloDistribution` and `ScenarioRunState`. None of the new type names (Article*, MarketBrief*, Terminal*, Autobuy*, ShareFacts*) exist in the app. If the build still reports `'X' is ambiguous for type lookup in this context`, qualify the app's own use of that name as `financeplan.X` at each reported line. If it reports `missing argument for parameter` on a shared initializer, add the new argument with the default the DTO documents. Re-run until it succeeds.

- [ ] **Step 8: Run the test to verify it passes**

Run the test command with `StockPlanSharedPinTests`.
Expected: `Test Case '-[financeplanTests.StockPlanSharedPinTests testTerminalMathIsTheSharedImplementation]' passed`.

- [ ] **Step 9: Commit**

```bash
git add financeplan.xcodeproj/project.pbxproj financeplan.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved financeplanTests/StockPlanSharedPinTests.swift
git commit -m "chore(deps): pin StockPlanShared 5.21.0 for terminal position sizing"
```

---

### Task 2: Terminal positions HTTP client and endpoints

**Files:**
- Create: `financeplan/API/TerminalPositions/TerminalPositionsEndpoints.swift`
- Create: `financeplan/API/TerminalPositions/TerminalPositionsHTTPClient.swift`
- Create: `financeplanTests/TerminalPositionsHTTPTestSupport.swift`
- Test: `financeplanTests/TerminalPositionsHTTPClientTests.swift`

**Interfaces:**
- Consumes: `BaseHTTPClient` (`financeplan/API/Base/BaseHTTPClient.swift`), `HTTPClientError`, `HTTPClientSession`, AnyAPI `Endpoint`/`HTTPMethod`/`Parameters`/`EmptyAPIResponse`, and the contract DTOs.
- Produces:
  - `nonisolated struct TerminalPositionsHTTPClient: Sendable` with `init(baseURL: URL, session: any HTTPClientSession = URLSession.shared, authTokenProvider: @escaping @Sendable () async -> String? = { nil })` and methods `list(ticker: String?) -> TerminalPositionsListResponse`, `create(_: TerminalPositionCreateRequest) -> TerminalPositionResponse`, `update(id: String, _: TerminalPositionUpdateRequest) -> TerminalPositionResponse`, `delete(id: String)`, `duplicate(id: String) -> TerminalPositionResponse`, `reorder(ids: [String]) -> TerminalPositionsListResponse`, `summary() -> TerminalPositionsSummaryResponse`, `autobuys() -> AutobuysListResponse`, `createAutobuy(_: AutobuyCreateRequest) -> AutobuyResponse`, `updateAutobuy(id: String, _: AutobuyUpdateRequest) -> AutobuyResponse`, `deleteAutobuy(id: String)`, `shareFacts(ticker: String) -> ShareFactsSuggestion`, `suggestScenario(ticker: String, horizonYears: Int?) -> TerminalScenarioSuggestion` (all `async throws`).
  - `TerminalPositionsHTTPClient.Error` cases: `.invalidResponse`, `.invalidStatus(Int)`, `.unauthorized(String?)`, `.api(String)`, `.rejected(status: Int, message: String?)` (400/403/404/409/422/429/503), `.upgradeRequired(feature: String)`, `.cancelled`; plus `isUnauthorized: Bool`.
  - Test helpers: `TerminalSessionMock`, `terminalHTTPResponse(_:status:json:)`, `terminalJSONBody(_:)`, `TerminalJSON.position`.

- [ ] **Step 1: Write the test support**

```swift
// financeplanTests/TerminalPositionsHTTPTestSupport.swift
import Foundation
@testable import financeplan

/// Answers requests from a closure. Nonisolated: BaseHTTPClient sends requests
/// from a @concurrent context, so the session witness must not be main-actor-bound.
nonisolated final class TerminalSessionMock: HTTPClientSession, @unchecked Sendable {
  var handler: (@Sendable (URLRequest) throws -> (Data, URLResponse))?
  private(set) var requests: [URLRequest] = []

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    guard let handler else {
      fatalError("TerminalSessionMock.handler must be configured before use")
    }
    return try handler(request)
  }
}

nonisolated func terminalHTTPResponse(_ request: URLRequest, status: Int, json: String = "") -> (Data, URLResponse) {
  let url = request.url ?? URL(string: "https://api.example.com")!
  let response = HTTPURLResponse(
    url: url,
    statusCode: status,
    httpVersion: nil,
    headerFields: ["Content-Type": "application/json"]
  )!
  return (Data(json.utf8), response)
}

nonisolated func terminalJSONBody(_ request: URLRequest) -> [String: Any]? {
  guard let body = request.httpBody else { return nil }
  return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
}

enum TerminalJSON {
  /// The backend's camelCase shape for the AMZN worked example, 750 shares owned.
  nonisolated static let position = """
  {"id":"p1","ticker":"AMZN","sharesOutstanding":null,"terminalShareCount":11000000000,\
  "terminalMarketCap":10000000000000,"valueWanted":1000000,"sharesOwned":750,\
  "currentSharePrice":null,"notes":null,"sortOrder":0,"terminalSharePrice":909.0909090909091,\
  "sharesNeeded":1100,"capitalAtTodayPrice":null,"progress":0.6818181818181818,\
  "sharesStillNeeded":350,"gapValueAtTerminal":318181.8181818182,"scenarioError":null,\
  "createdAt":"2026-10-09T10:00:00Z","updatedAt":"2026-10-09T10:00:00Z"}
  """
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// financeplanTests/TerminalPositionsHTTPClientTests.swift
import Foundation
import StockPlanShared
import XCTest
@testable import financeplan

@MainActor
final class TerminalPositionsHTTPClientTests: XCTestCase {
  private func makeClient(_ session: TerminalSessionMock) -> TerminalPositionsHTTPClient {
    TerminalPositionsHTTPClient(
      baseURL: URL(string: "https://api.example.com")!,
      session: session,
      authTokenProvider: { "token-123" }
    )
  }

  func testListSendsTheTickerAsAQueryAndDecodesTheBackendShape() async throws {
    let session = TerminalSessionMock()
    session.handler = { request in
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.url?.path, "/v1/terminal-positions")
      XCTAssertEqual(
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
        [URLQueryItem(name: "ticker", value: "AMZN")]
      )
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
      return terminalHTTPResponse(request, status: 200, json: #"{"currency":"USD","positions":[\#(TerminalJSON.position)]}"#)
    }

    let list = try await makeClient(session).list(ticker: "AMZN")

    XCTAssertEqual(list.currency, "USD")
    XCTAssertEqual(list.positions.first?.ticker, "AMZN")
    XCTAssertEqual(list.positions.first?.sharesNeeded ?? 0, 1_100, accuracy: 0.000001)
    XCTAssertNil(list.positions.first?.scenarioError)
  }

  func testListWithoutATickerSendsNoQuery() async throws {
    let session = TerminalSessionMock()
    session.handler = { request in
      XCTAssertNil(request.url?.query)
      return terminalHTTPResponse(request, status: 200, json: #"{"currency":"EUR","positions":[]}"#)
    }

    let list = try await makeClient(session).list(ticker: nil)

    XCTAssertEqual(list.currency, "EUR")
    XCTAssertEqual(list.positions, [])
  }

  func testUpdateSendsAPatchWithOnlyTheSetFieldsAndClear() async throws {
    let session = TerminalSessionMock()
    session.handler = { request in
      XCTAssertEqual(request.httpMethod, "PATCH")
      XCTAssertEqual(request.url?.path, "/v1/terminal-positions/p1")
      let body = terminalJSONBody(request)
      XCTAssertEqual(body?["value_wanted"] as? Double, 2_000_000)
      XCTAssertEqual(body?["clear"] as? [String], ["notes"])
      XCTAssertEqual(body?.count, 2, "nil fields must be left out, not sent as null")
      return terminalHTTPResponse(request, status: 200, json: TerminalJSON.position)
    }
    let request = TerminalPositionUpdateRequest(
      ticker: nil, sharesOutstanding: nil, terminalShareCount: nil, terminalMarketCap: nil,
      valueWanted: 2_000_000, sharesOwned: nil, currentSharePrice: nil, notes: nil, clear: ["notes"]
    )

    _ = try await makeClient(session).update(id: "p1", request)
  }

  func testDeleteAcceptsAnEmpty204() async throws {
    let session = TerminalSessionMock()
    session.handler = { request in
      XCTAssertEqual(request.httpMethod, "DELETE")
      XCTAssertEqual(request.url?.path, "/v1/terminal-positions/p1")
      return terminalHTTPResponse(request, status: 204)
    }

    try await makeClient(session).delete(id: "p1")
  }

  func testDuplicateAndReorderUseTheirRoutes() async throws {
    let session = TerminalSessionMock()
    session.handler = { request in
      switch (request.httpMethod, request.url?.path) {
      case ("POST", "/v1/terminal-positions/p1/duplicate"):
        return terminalHTTPResponse(request, status: 201, json: TerminalJSON.position)
      case ("PUT", "/v1/terminal-positions/order"):
        XCTAssertEqual(terminalJSONBody(request)?["ids"] as? [String], ["p2", "p1"])
        return terminalHTTPResponse(request, status: 200, json: #"{"currency":"USD","positions":[]}"#)
      default:
        XCTFail("Unexpected \(request.httpMethod ?? "") \(request.url?.path ?? "")")
        return terminalHTTPResponse(request, status: 500)
      }
    }
    let client = makeClient(session)

    _ = try await client.duplicate(id: "p1")
    _ = try await client.reorder(ids: ["p2", "p1"])
  }

  func testScenarioSuggestionOmitsAMissingHorizon() async throws {
    let session = TerminalSessionMock()
    session.handler = { request in
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.url?.path, "/v1/terminal-positions/ai/scenario")
      let body = terminalJSONBody(request)
      XCTAssertEqual(body?["ticker"] as? String, "AMZN")
      XCTAssertNil(body?["horizon_years"])
      return terminalHTTPResponse(request, status: 200, json: """
      {"ticker":"AMZN","terminalShareCount":11000000000,"terminalMarketCap":10000000000000,\
      "horizonYears":10,"rationale":"Cloud and ads keep compounding.","sources":["https://example.com/a"]}
      """)
    }

    let suggestion = try await makeClient(session).suggestScenario(ticker: "AMZN", horizonYears: nil)

    XCTAssertEqual(suggestion.horizonYears, 10)
  }

  func testUpgradeRequiredBodyBecomesUpgradeRequired() async {
    let session = TerminalSessionMock()
    session.handler = { request in
      terminalHTTPResponse(request, status: 403, json: """
      {"success":false,"code":"upgrade_required","error":"Upgrade required. feature=terminal_position_ai plan=free required=pro",\
      "feature":"terminal_position_ai","plan":"free","requiredPlan":"pro"}
      """)
    }

    do {
      _ = try await makeClient(session).shareFacts(ticker: "AMZN")
      XCTFail("Expected an upgrade error")
    } catch {
      XCTAssertEqual(error as? TerminalPositionsHTTPClient.Error, .upgradeRequired(feature: "terminal_position_ai"))
    }
  }

  func testPlainForbiddenStaysRejected() async {
    let session = TerminalSessionMock()
    session.handler = { request in
      terminalHTTPResponse(request, status: 403, json: #"{"error":true,"reason":"Missing scope planning:read"}"#)
    }

    do {
      _ = try await makeClient(session).shareFacts(ticker: "AMZN")
      XCTFail("Expected a rejection")
    } catch {
      XCTAssertEqual(
        error as? TerminalPositionsHTTPClient.Error,
        .rejected(status: 403, message: "Missing scope planning:read")
      )
    }
  }

  func testAIUnavailableKeepsTheStatus() async {
    let session = TerminalSessionMock()
    session.handler = { request in
      terminalHTTPResponse(request, status: 503, json: #"{"error":true,"reason":"AI lookup unavailable"}"#)
    }

    do {
      _ = try await makeClient(session).shareFacts(ticker: "AMZN")
      XCTFail("Expected a rejection")
    } catch {
      XCTAssertEqual(error as? TerminalPositionsHTTPClient.Error, .rejected(status: 503, message: "AI lookup unavailable"))
    }
  }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run the test command with `TerminalPositionsHTTPClientTests`.
Expected: FAIL to compile with `cannot find 'TerminalPositionsHTTPClient' in scope`.

- [ ] **Step 4: Write the endpoints**

```swift
// financeplan/API/TerminalPositions/TerminalPositionsEndpoints.swift
import AnyAPI
import Foundation
import StockPlanShared

// Terminal position sizing. Contract: norviq-backend
// docs/superpowers/plans/2026-10-09-terminal-contract.md. Routes live in the
// backend's TerminalPositions/ module, all under /v1.

/// Encodes a request body the way the rest of the app does: snake_case keys,
/// nil fields left out (a PATCH treats a missing key as "leave it").
private nonisolated func terminalParameters(_ payload: some Encodable) throws -> Parameters {
  let data = try JSONEncoder.stockPlanShared.encode(payload)
  return try JSONSerialization.jsonObject(with: data) as? Parameters ?? [:]
}

nonisolated struct ListTerminalPositionsEndpoint: Endpoint {
  typealias Response = TerminalPositionsListResponse
  let ticker: String?
  var method: HTTPMethod { .get }
  var path: String { "/v1/terminal-positions" }
  var decoder: JSONDecoder { .stockPlanShared }
  func asParameters() throws -> Parameters {
    guard let ticker, !ticker.isEmpty else { return [:] }
    return ["ticker": ticker]
  }
}

nonisolated struct CreateTerminalPositionEndpoint: Endpoint {
  typealias Response = TerminalPositionResponse
  let payload: TerminalPositionCreateRequest
  var method: HTTPMethod { .post }
  var path: String { "/v1/terminal-positions" }
  var decoder: JSONDecoder { .stockPlanShared }
  func asParameters() throws -> Parameters { try terminalParameters(payload) }
}

nonisolated struct UpdateTerminalPositionEndpoint: Endpoint {
  typealias Response = TerminalPositionResponse
  let id: String
  let payload: TerminalPositionUpdateRequest
  var method: HTTPMethod { .patch }
  var path: String { "/v1/terminal-positions/\(id)" }
  var decoder: JSONDecoder { .stockPlanShared }
  func asParameters() throws -> Parameters { try terminalParameters(payload) }
}

nonisolated struct DeleteTerminalPositionEndpoint: Endpoint {
  typealias Response = EmptyAPIResponse
  let id: String
  var method: HTTPMethod { .delete }
  var path: String { "/v1/terminal-positions/\(id)" }
  var decoder: JSONDecoder { .stockPlanShared }
  func asParameters() throws -> Parameters { [:] }
}

nonisolated struct DuplicateTerminalPositionEndpoint: Endpoint {
  typealias Response = TerminalPositionResponse
  let id: String
  var method: HTTPMethod { .post }
  var path: String { "/v1/terminal-positions/\(id)/duplicate" }
  var decoder: JSONDecoder { .stockPlanShared }
  func asParameters() throws -> Parameters { [:] }
}

nonisolated struct ReorderTerminalPositionsEndpoint: Endpoint {
  typealias Response = TerminalPositionsListResponse
  let payload: TerminalPositionOrderRequest
  var method: HTTPMethod { .put }
  var path: String { "/v1/terminal-positions/order" }
  var decoder: JSONDecoder { .stockPlanShared }
  func asParameters() throws -> Parameters { try terminalParameters(payload) }
}

nonisolated struct TerminalPositionsSummaryEndpoint: Endpoint {
  typealias Response = TerminalPositionsSummaryResponse
  var method: HTTPMethod { .get }
  var path: String { "/v1/terminal-positions/summary" }
  var decoder: JSONDecoder { .stockPlanShared }
  func asParameters() throws -> Parameters { [:] }
}

nonisolated struct ListAutobuysEndpoint: Endpoint {
  typealias Response = AutobuysListResponse
  var method: HTTPMethod { .get }
  var path: String { "/v1/autobuys" }
  var decoder: JSONDecoder { .stockPlanShared }
  func asParameters() throws -> Parameters { [:] }
}

nonisolated struct CreateAutobuyEndpoint: Endpoint {
  typealias Response = AutobuyResponse
  let payload: AutobuyCreateRequest
  var method: HTTPMethod { .post }
  var path: String { "/v1/autobuys" }
  var decoder: JSONDecoder { .stockPlanShared }
  func asParameters() throws -> Parameters { try terminalParameters(payload) }
}

nonisolated struct UpdateAutobuyEndpoint: Endpoint {
  typealias Response = AutobuyResponse
  let id: String
  let payload: AutobuyUpdateRequest
  var method: HTTPMethod { .patch }
  var path: String { "/v1/autobuys/\(id)" }
  var decoder: JSONDecoder { .stockPlanShared }
  func asParameters() throws -> Parameters { try terminalParameters(payload) }
}

nonisolated struct DeleteAutobuyEndpoint: Endpoint {
  typealias Response = EmptyAPIResponse
  let id: String
  var method: HTTPMethod { .delete }
  var path: String { "/v1/autobuys/\(id)" }
  var decoder: JSONDecoder { .stockPlanShared }
  func asParameters() throws -> Parameters { [:] }
}

/// Pro. Suggests only; the server never writes from this route.
nonisolated struct ShareFactsEndpoint: Endpoint {
  typealias Response = ShareFactsSuggestion
  let payload: ShareFactsRequest
  var method: HTTPMethod { .post }
  var path: String { "/v1/terminal-positions/ai/share-facts" }
  var decoder: JSONDecoder { .stockPlanShared }
  func asParameters() throws -> Parameters { try terminalParameters(payload) }
}

/// Pro. Suggests only; the server never writes from this route.
nonisolated struct TerminalScenarioSuggestionEndpoint: Endpoint {
  typealias Response = TerminalScenarioSuggestion
  let payload: TerminalScenarioSuggestionRequest
  var method: HTTPMethod { .post }
  var path: String { "/v1/terminal-positions/ai/scenario" }
  var decoder: JSONDecoder { .stockPlanShared }
  func asParameters() throws -> Parameters { try terminalParameters(payload) }
}
```

- [ ] **Step 5: Write the client**

```swift
// financeplan/API/TerminalPositions/TerminalPositionsHTTPClient.swift
import AnyAPI
import Foundation
import OSLog
import StockPlanShared

/// `/v1/terminal-positions` and `/v1/autobuys`.
///
/// It has its own error type instead of `StockHTTPClient.Error`, which turns
/// every 4xx with a body into `.api(message)`. The editor has to tell a Pro
/// gate (403 with `code: "upgrade_required"`) from a missing token scope (a
/// plain 403), an AI outage (503) and an unusable AI answer (422).
nonisolated struct TerminalPositionsHTTPClient: Sendable {
  enum Error: HTTPClientError {
    case invalidResponse
    case invalidStatus(Int)
    case unauthorized(String?)
    case api(String)
    /// A status the screens tell apart, with the server's `reason`.
    case rejected(status: Int, message: String?)
    /// A 403 whose body is the billing `BillingUpgradeRequiredResponse`. Read
    /// from the body's `code`, never from the status: 403 also means a missing scope.
    case upgradeRequired(feature: String)
    /// The request was cancelled (the screen went away). Not a failure to show.
    case cancelled

    nonisolated var errorDescription: String? {
      switch self {
      case .invalidResponse: return "Invalid server response."
      case let .invalidStatus(code): return "Request failed (\(code))."
      case let .unauthorized(message): return message ?? "Your session expired. Please sign in again."
      case let .api(message): return message
      case let .rejected(status, message): return message ?? "Request failed (\(status))."
      case .upgradeRequired: return "This needs Norviq Pro."
      case .cancelled: return "The request was cancelled."
      }
    }

    nonisolated var statusCode: Int? {
      switch self {
      case let .invalidStatus(code): return code
      case let .rejected(status, _): return status
      case .upgradeRequired: return 403
      default: return nil
      }
    }

    nonisolated var isUnauthorized: Bool {
      if case .unauthorized = self { return true }
      return false
    }

    nonisolated static func == (lhs: Error, rhs: Error) -> Bool {
      switch (lhs, rhs) {
      case (.invalidResponse, .invalidResponse): return true
      case let (.invalidStatus(l), .invalidStatus(r)): return l == r
      case let (.unauthorized(l), .unauthorized(r)): return l == r
      case let (.api(l), .api(r)): return l == r
      case let (.rejected(ls, lm), .rejected(rs, rm)): return ls == rs && lm == rm
      case let (.upgradeRequired(l), .upgradeRequired(r)): return l == r
      case (.cancelled, .cancelled): return true
      default: return false
      }
    }

    static func makeInvalidResponse() -> Error { .invalidResponse }
    static func makeInvalidStatus(_ code: Int) -> Error { .invalidStatus(code) }
    static func makeUnauthorized(_ message: String?) -> Error { .unauthorized(message) }
    static func makeAPI(_ message: String) -> Error { .api(message) }

    /// Keeps cancellation recognisable instead of turning it into `.api("cancelled")`.
    static func makeTransport(_ error: Swift.Error) -> Error {
      if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
      return .api((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    static func makeStatus(_ code: Int, message: String?) -> Error {
      if [400, 403, 404, 409, 422, 429, 503].contains(code) { return .rejected(status: code, message: message) }
      if let message, !message.isEmpty { return .api(message) }
      return .invalidStatus(code)
    }

    static func makeStatus(_ code: Int, message: String?, body: Data) -> Error {
      if code == 403,
         let billing = try? JSONDecoder().decode(UpgradeRequiredBody.self, from: body),
         billing.code == "upgrade_required" {
        return .upgradeRequired(feature: billing.feature ?? "terminal_position_ai")
      }
      return makeStatus(code, message: message)
    }
  }

  /// The fields of `BillingUpgradeRequiredResponse` the client reads:
  /// `{"success":false,"code":"upgrade_required","error":…,"feature":…}`.
  nonisolated private struct UpgradeRequiredBody: Decodable {
    let code: String?
    let feature: String?
  }

  private let client: BaseHTTPClient

  init(
    baseURL: URL,
    session: any HTTPClientSession = URLSession.shared,
    authTokenProvider: @escaping @Sendable () async -> String? = { nil }
  ) {
    self.client = BaseHTTPClient(
      baseURL: baseURL,
      session: session,
      authTokenProvider: authTokenProvider,
      logger: Logger(subsystem: Bundle.main.bundleIdentifier ?? "financeplan", category: "TerminalPositionsHTTPClient"),
      decoder: .stockPlanShared
    )
  }

  func list(ticker: String?) async throws -> TerminalPositionsListResponse {
    try await client.call(ListTerminalPositionsEndpoint(ticker: ticker), errorType: Error.self)
  }

  func create(_ request: TerminalPositionCreateRequest) async throws -> TerminalPositionResponse {
    try await client.call(CreateTerminalPositionEndpoint(payload: request), errorType: Error.self)
  }

  func update(id: String, _ request: TerminalPositionUpdateRequest) async throws -> TerminalPositionResponse {
    try await client.call(UpdateTerminalPositionEndpoint(id: id, payload: request), errorType: Error.self)
  }

  func delete(id: String) async throws {
    try await client.callWithoutResponse(DeleteTerminalPositionEndpoint(id: id), errorType: Error.self)
  }

  func duplicate(id: String) async throws -> TerminalPositionResponse {
    try await client.call(DuplicateTerminalPositionEndpoint(id: id), errorType: Error.self)
  }

  func reorder(ids: [String]) async throws -> TerminalPositionsListResponse {
    try await client.call(
      ReorderTerminalPositionsEndpoint(payload: TerminalPositionOrderRequest(ids: ids)),
      errorType: Error.self
    )
  }

  func summary() async throws -> TerminalPositionsSummaryResponse {
    try await client.call(TerminalPositionsSummaryEndpoint(), errorType: Error.self)
  }

  func autobuys() async throws -> AutobuysListResponse {
    try await client.call(ListAutobuysEndpoint(), errorType: Error.self)
  }

  func createAutobuy(_ request: AutobuyCreateRequest) async throws -> AutobuyResponse {
    try await client.call(CreateAutobuyEndpoint(payload: request), errorType: Error.self)
  }

  func updateAutobuy(id: String, _ request: AutobuyUpdateRequest) async throws -> AutobuyResponse {
    try await client.call(UpdateAutobuyEndpoint(id: id, payload: request), errorType: Error.self)
  }

  func deleteAutobuy(id: String) async throws {
    try await client.callWithoutResponse(DeleteAutobuyEndpoint(id: id), errorType: Error.self)
  }

  func shareFacts(ticker: String) async throws -> ShareFactsSuggestion {
    try await client.call(ShareFactsEndpoint(payload: ShareFactsRequest(ticker: ticker)), errorType: Error.self)
  }

  func suggestScenario(ticker: String, horizonYears: Int?) async throws -> TerminalScenarioSuggestion {
    try await client.call(
      TerminalScenarioSuggestionEndpoint(
        payload: TerminalScenarioSuggestionRequest(ticker: ticker, horizonYears: horizonYears)
      ),
      errorType: Error.self
    )
  }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run the test command with `TerminalPositionsHTTPClientTests`.
Expected: all 9 tests pass. If `testUpdateSendsAPatchWithOnlyTheSetFieldsAndClear` fails on `body?.count`, StockPlanShared 5.21.0 encodes nil as `null`. That would break PATCH semantics. Report it to the shared/backend owner instead of loosening the test.

- [ ] **Step 7: Commit**

```bash
git add financeplan/API/TerminalPositions/TerminalPositionsEndpoints.swift financeplan/API/TerminalPositions/TerminalPositionsHTTPClient.swift financeplanTests/TerminalPositionsHTTPTestSupport.swift financeplanTests/TerminalPositionsHTTPClientTests.swift
git commit -m "feat(terminal): add terminal positions HTTP client and endpoints"
```

---

### Task 3: Service with token refresh, and the Factory registration

**Files:**
- Create: `financeplan/API/TerminalPositions/TerminalPositionsService.swift`
- Create: `financeplan/API/TerminalPositions/Container+TerminalPositionsFactories.swift`
- Test: `financeplanTests/TerminalPositionsServiceTests.swift`

**Interfaces:**
- Consumes: `TerminalPositionsHTTPClient` (Task 2), `AppEnvironmentManager`, `AuthSessionManaging` (`validAccessToken()`, `refreshAccessToken()`, `invalidateSession()`), `AuthSessionError.notAuthenticated`.
- Produces:
  ```swift
  protocol TerminalPositionsServicing: Sendable {
    func list(ticker: String?) async throws -> TerminalPositionsListResponse
    func create(_ request: TerminalPositionCreateRequest) async throws -> TerminalPositionResponse
    func update(id: String, _ request: TerminalPositionUpdateRequest) async throws -> TerminalPositionResponse
    func delete(id: String) async throws
    func duplicate(id: String) async throws -> TerminalPositionResponse
    func reorder(ids: [String]) async throws -> TerminalPositionsListResponse
    func summary() async throws -> TerminalPositionsSummaryResponse
    func autobuys() async throws -> AutobuysListResponse
    func createAutobuy(_ request: AutobuyCreateRequest) async throws -> AutobuyResponse
    func updateAutobuy(id: String, _ request: AutobuyUpdateRequest) async throws -> AutobuyResponse
    func deleteAutobuy(id: String) async throws
    func shareFacts(ticker: String) async throws -> ShareFactsSuggestion
    func suggestScenario(ticker: String, horizonYears: Int?) async throws -> TerminalScenarioSuggestion
  }
  ```
  `final class TerminalPositionsService(environmentManager:authSessionManager:session:)` and `Container.shared.terminalPositionsService()`.

- [ ] **Step 1: Write the failing tests**

```swift
// financeplanTests/TerminalPositionsServiceTests.swift
import Foundation
import StockPlanShared
import XCTest
@testable import financeplan

@MainActor
final class TerminalPositionsServiceTests: XCTestCase {
  private final class AuthMock: AuthSessionManaging, @unchecked Sendable {
    var validToken: String? = "old"
    var refreshedToken: String? = "new"
    private(set) var refreshCalls = 0
    private(set) var invalidateCalls = 0

    func restoreSessionIfNeeded() async -> Bool { true }
    func validAccessToken() async throws -> String? { validToken }
    func refreshAccessToken() async throws -> String? {
      refreshCalls += 1
      return refreshedToken
    }
    func logout() async {}
    func invalidateSession() async { invalidateCalls += 1 }
  }

  private func makeService(_ session: TerminalSessionMock, auth: AuthMock) -> TerminalPositionsService {
    TerminalPositionsService(environmentManager: AppEnvironmentManager(), authSessionManager: auth, session: session)
  }

  func testRefreshesTheTokenOnceAfterA401() async throws {
    let session = TerminalSessionMock()
    session.handler = { request in
      if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
        return terminalHTTPResponse(request, status: 401, json: #"{"error":true,"reason":"expired"}"#)
      }
      return terminalHTTPResponse(request, status: 200, json: #"{"currency":"USD","positions":[]}"#)
    }
    let auth = AuthMock()

    let list = try await makeService(session, auth: auth).list(ticker: nil)

    XCTAssertEqual(list.positions, [])
    XCTAssertEqual(auth.refreshCalls, 1)
    XCTAssertEqual(auth.invalidateCalls, 0)
  }

  func testInvalidatesTheSessionWhenTheRefreshedTokenIsAlsoRejected() async {
    let session = TerminalSessionMock()
    session.handler = { request in
      terminalHTTPResponse(request, status: 401, json: #"{"error":true,"reason":"expired"}"#)
    }
    let auth = AuthMock()

    do {
      _ = try await makeService(session, auth: auth).summary()
      XCTFail("Expected unauthorized")
    } catch {
      XCTAssertTrue((error as? TerminalPositionsHTTPClient.Error)?.isUnauthorized ?? false)
    }
    XCTAssertEqual(auth.refreshCalls, 1)
    XCTAssertEqual(auth.invalidateCalls, 1)
  }

  func testNoTokenFailsWithoutARequest() async {
    let session = TerminalSessionMock()
    session.handler = { request in terminalHTTPResponse(request, status: 200) }
    let auth = AuthMock()
    auth.validToken = nil

    do {
      _ = try await makeService(session, auth: auth).autobuys()
      XCTFail("Expected notAuthenticated")
    } catch {
      XCTAssertTrue(session.requests.isEmpty)
    }
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the test command with `TerminalPositionsServiceTests`.
Expected: FAIL to compile with `cannot find 'TerminalPositionsService' in scope`.

- [ ] **Step 3: Write the service**

```swift
// financeplan/API/TerminalPositions/TerminalPositionsService.swift
import Foundation
import StockPlanShared

protocol TerminalPositionsServicing: Sendable {
  func list(ticker: String?) async throws -> TerminalPositionsListResponse
  func create(_ request: TerminalPositionCreateRequest) async throws -> TerminalPositionResponse
  func update(id: String, _ request: TerminalPositionUpdateRequest) async throws -> TerminalPositionResponse
  func delete(id: String) async throws
  func duplicate(id: String) async throws -> TerminalPositionResponse
  func reorder(ids: [String]) async throws -> TerminalPositionsListResponse
  func summary() async throws -> TerminalPositionsSummaryResponse
  func autobuys() async throws -> AutobuysListResponse
  func createAutobuy(_ request: AutobuyCreateRequest) async throws -> AutobuyResponse
  func updateAutobuy(id: String, _ request: AutobuyUpdateRequest) async throws -> AutobuyResponse
  func deleteAutobuy(id: String) async throws
  /// Pro. A suggestion with sources; nothing is written.
  func shareFacts(ticker: String) async throws -> ShareFactsSuggestion
  /// Pro. A suggestion with sources; nothing is written.
  func suggestScenario(ticker: String, horizonYears: Int?) async throws -> TerminalScenarioSuggestion
}

final class TerminalPositionsService: TerminalPositionsServicing, Sendable {
  private let environmentManager: AppEnvironmentManager
  private let authSessionManager: AuthSessionManaging
  private let session: any HTTPClientSession

  init(
    environmentManager: AppEnvironmentManager,
    authSessionManager: AuthSessionManaging,
    session: any HTTPClientSession = URLSession.shared
  ) {
    self.environmentManager = environmentManager
    self.authSessionManager = authSessionManager
    self.session = session
  }

  func list(ticker: String?) async throws -> TerminalPositionsListResponse {
    try await authenticated { try await $0.list(ticker: ticker) }
  }

  func create(_ request: TerminalPositionCreateRequest) async throws -> TerminalPositionResponse {
    try await authenticated { try await $0.create(request) }
  }

  func update(id: String, _ request: TerminalPositionUpdateRequest) async throws -> TerminalPositionResponse {
    try await authenticated { try await $0.update(id: id, request) }
  }

  func delete(id: String) async throws {
    try await authenticated { try await $0.delete(id: id) }
  }

  func duplicate(id: String) async throws -> TerminalPositionResponse {
    try await authenticated { try await $0.duplicate(id: id) }
  }

  func reorder(ids: [String]) async throws -> TerminalPositionsListResponse {
    try await authenticated { try await $0.reorder(ids: ids) }
  }

  func summary() async throws -> TerminalPositionsSummaryResponse {
    try await authenticated { try await $0.summary() }
  }

  func autobuys() async throws -> AutobuysListResponse {
    try await authenticated { try await $0.autobuys() }
  }

  func createAutobuy(_ request: AutobuyCreateRequest) async throws -> AutobuyResponse {
    try await authenticated { try await $0.createAutobuy(request) }
  }

  func updateAutobuy(id: String, _ request: AutobuyUpdateRequest) async throws -> AutobuyResponse {
    try await authenticated { try await $0.updateAutobuy(id: id, request) }
  }

  func deleteAutobuy(id: String) async throws {
    try await authenticated { try await $0.deleteAutobuy(id: id) }
  }

  func shareFacts(ticker: String) async throws -> ShareFactsSuggestion {
    try await authenticated { try await $0.shareFacts(ticker: ticker) }
  }

  func suggestScenario(ticker: String, horizonYears: Int?) async throws -> TerminalScenarioSuggestion {
    try await authenticated { try await $0.suggestScenario(ticker: ticker, horizonYears: horizonYears) }
  }

  private func authenticated<T: Sendable>(
    _ operation: (TerminalPositionsHTTPClient) async throws -> T
  ) async throws -> T {
    do {
      return try await operation(client())
    } catch let error as TerminalPositionsHTTPClient.Error where error.isUnauthorized {
      do {
        return try await operation(client(forceRefresh: true))
      } catch let retry as TerminalPositionsHTTPClient.Error where retry.isUnauthorized {
        await authSessionManager.invalidateSession()
        throw retry
      }
    }
  }

  private func client(forceRefresh: Bool = false) async throws -> TerminalPositionsHTTPClient {
    let token = forceRefresh
      ? try await authSessionManager.refreshAccessToken()
      : try await authSessionManager.validAccessToken()
    guard let token, !token.isEmpty else { throw AuthSessionError.notAuthenticated }
    return TerminalPositionsHTTPClient(
      baseURL: environmentManager.current.apiBaseUrl,
      session: session,
      authTokenProvider: { token }
    )
  }
}
```

```swift
// financeplan/API/TerminalPositions/Container+TerminalPositionsFactories.swift
import Factory

extension Container {
  var terminalPositionsService: Factory<any TerminalPositionsServicing> {
    self { @MainActor in
      TerminalPositionsService(
        environmentManager: self.appEnvironment(),
        authSessionManager: self.authSessionManager()
      )
    }
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the test command with `TerminalPositionsServiceTests`.
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add financeplan/API/TerminalPositions/TerminalPositionsService.swift financeplan/API/TerminalPositions/Container+TerminalPositionsFactories.swift financeplanTests/TerminalPositionsServiceTests.swift
git commit -m "feat(terminal): add terminal positions service with token refresh"
```

---

### Task 4: Value + unit number input, display formatting and copy

**Files:**
- Create: `financeplan/Features/TerminalPositions/TerminalNumberInput.swift`
- Create: `financeplan/Features/TerminalPositions/TerminalFormat.swift`
- Test: `financeplanTests/TerminalNumberInputTests.swift`

**Interfaces:**
- Consumes: `MoneyInputParser.parse(_:locale:)`, `StockMetricFormatter.currencyText(_:code:decimals:locale:)`, `StockMetricFormatter.compactStatementCurrency(_:code:locale:)`, `StockMetricFormatter.compactNumber(_:locale:)`, `TerminalMath.wholeShares`.
- Produces:
  - `enum TerminalUnit: String, CaseIterable, Identifiable { case none, thousand, million, billion, trillion; var multiplier: Double; var symbol: String }`
  - `struct TerminalNumberInput: Equatable { var text: String; var unit: TerminalUnit; enum Reading: Equatable { case empty, invalid, negative, value(Double) }; init(text: String = "", unit: TerminalUnit = .none); init(value: Double?, usesUnits: Bool = true, locale: Locale = .current); func reading(locale: Locale = .current) -> Reading; func value(locale: Locale = .current) -> Double? }`
  - `enum TerminalFormat { static func money(_:currency:locale:) -> String; static func price(_:currency:locale:) -> String; static func shares(_:roundDown:locale:) -> String; static func count(_:locale:) -> String; static func progress(_:locale:) -> String }`
  - `enum TerminalCopy { static var title: String; static var subtitle: String; static var disclaimer: String }` (localized)

- [ ] **Step 1: Write the failing tests**

```swift
// financeplanTests/TerminalNumberInputTests.swift
import Foundation
import XCTest
@testable import financeplan

@MainActor
final class TerminalNumberInputTests: XCTestCase {
  private let english = Locale(identifier: "en_US")
  private let portuguese = Locale(identifier: "pt_PT")

  func testUnitMultipliesTheTypedValue() async {
    XCTAssertEqual(TerminalNumberInput(text: "11", unit: .billion).value(locale: english), 11_000_000_000)
    XCTAssertEqual(TerminalNumberInput(text: "10", unit: .trillion).value(locale: english), 10_000_000_000_000)
    XCTAssertEqual(TerminalNumberInput(text: "250", unit: .thousand).value(locale: english), 250_000)
    XCTAssertEqual(TerminalNumberInput(text: "1100").value(locale: english), 1_100)
  }

  func testPortugueseCommaIsADecimalMark() async {
    XCTAssertEqual(TerminalNumberInput(text: "1,5", unit: .billion).value(locale: portuguese), 1_500_000_000)
    XCTAssertEqual(TerminalNumberInput(text: "2,75", unit: .million).value(locale: portuguese), 2_750_000)
    XCTAssertEqual(TerminalNumberInput(text: "1,500").value(locale: english), 1_500)
  }

  func testMinusSignIsRefusedNotDropped() async {
    XCTAssertEqual(TerminalNumberInput(text: "-100").reading(locale: english), .negative)
    XCTAssertEqual(TerminalNumberInput(text: "\u{2212}100", unit: .million).reading(locale: english), .negative)
    XCTAssertNil(TerminalNumberInput(text: "-100").value(locale: english))
  }

  func testEmptyAndUnreadableText() async {
    XCTAssertEqual(TerminalNumberInput(text: "   ").reading(locale: english), .empty)
    XCTAssertEqual(TerminalNumberInput(text: "abc").reading(locale: english), .invalid)
  }

  func testPrefillPicksTheLargestUnitThatReadsBackExactly() async {
    XCTAssertEqual(TerminalNumberInput(value: 11_000_000_000, locale: english), TerminalNumberInput(text: "11", unit: .billion))
    XCTAssertEqual(TerminalNumberInput(value: 10_000_000_000_000, locale: english), TerminalNumberInput(text: "10", unit: .trillion))
    XCTAssertEqual(TerminalNumberInput(value: 1_500_000_000, locale: portuguese), TerminalNumberInput(text: "1,5", unit: .billion))
    XCTAssertEqual(TerminalNumberInput(value: 220.5, usesUnits: false, locale: english), TerminalNumberInput(text: "220.5"))
    XCTAssertEqual(TerminalNumberInput(value: 4_500, usesUnits: false, locale: english), TerminalNumberInput(text: "4500"))
    XCTAssertEqual(TerminalNumberInput(value: nil, locale: english), TerminalNumberInput())
  }

  func testPrefillNeverChangesTheStoredNumber() async {
    for locale in [english, portuguese] {
      for value in [1_234_567.891, 909.090909, 62.5, 2_916.67, 10_600_000_000, 0.000001, 1_100] {
        XCTAssertEqual(
          TerminalNumberInput(value: value, locale: locale).value(locale: locale),
          value,
          "\(value) in \(locale.identifier)"
        )
      }
    }
  }

  func testDisplayFormats() async {
    XCTAssertEqual(TerminalFormat.price(10_000_000_000_000 / 11_000_000_000, currency: "USD", locale: english), "$909.09")
    XCTAssertEqual(TerminalFormat.shares(1_099.6, roundDown: false, locale: english), "1,099.6")
    XCTAssertEqual(TerminalFormat.shares(1_099.6, roundDown: true, locale: english), "1,099")
    XCTAssertEqual(TerminalFormat.progress(750.0 / 1_100.0, locale: english), "68.18%")
    XCTAssertEqual(TerminalFormat.money(1_000_000, currency: "USD", locale: english), "$1.0M")
    XCTAssertEqual(TerminalFormat.money(10_000_000_000_000, currency: "USD", locale: english), "$10.00T")
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the test command with `TerminalNumberInputTests`.
Expected: FAIL to compile with `cannot find 'TerminalNumberInput' in scope`.

- [ ] **Step 3: Write the input model**

```swift
// financeplan/Features/TerminalPositions/TerminalNumberInput.swift
import Foundation

/// The unit menu next to a big-number field: share counts and market caps run
/// to billions and trillions, which nobody should type out in full.
enum TerminalUnit: String, CaseIterable, Identifiable {
  case none, thousand, million, billion, trillion

  var id: String { rawValue }

  var multiplier: Double {
    switch self {
    case .none: 1
    case .thousand: 1_000
    case .million: 1_000_000
    case .billion: 1_000_000_000
    case .trillion: 1_000_000_000_000
    }
  }

  /// Menu label. The same suffixes as the web table's compact numbers (10T, 1.25B).
  var symbol: String {
    switch self {
    case .none: "—"
    case .thousand: "K"
    case .million: "M"
    case .billion: "B"
    case .trillion: "T"
    }
  }
}

/// What the user typed into one number field, plus its unit.
struct TerminalNumberInput: Equatable {
  enum Reading: Equatable {
    case empty
    case invalid
    /// `MoneyInputParser` drops a minus sign, so "-100" would read as 100.
    /// It is reported here instead of being flipped.
    case negative
    case value(Double)
  }

  var text: String
  var unit: TerminalUnit

  init(text: String = "", unit: TerminalUnit = .none) {
    self.text = text
    self.unit = unit
  }

  /// Prefills a field from a stored number. With `usesUnits`, it picks the
  /// largest unit whose text reads back to exactly `value`. That way, opening
  /// a row and saving it never nudges a number.
  init(value: Double?, usesUnits: Bool = true, locale: Locale = .current) {
    guard let value, value.isFinite else {
      self.init()
      return
    }
    let candidates: [TerminalUnit] = usesUnits ? TerminalUnit.allCases.reversed() : [.none]
    for unit in candidates where unit == .none || abs(value) >= unit.multiplier {
      let candidate = TerminalNumberInput(text: Self.format(value / unit.multiplier, locale: locale), unit: unit)
      if case let .value(read) = candidate.reading(locale: locale), read == value {
        self = candidate
        return
      }
    }
    self.init(text: Self.format(value, locale: locale), unit: .none)
  }

  func reading(locale: Locale = .current) -> Reading {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .empty }
    if trimmed.contains("-") || trimmed.contains("\u{2212}") { return .negative }
    guard let parsed = MoneyInputParser.parse(trimmed, locale: locale), parsed.isFinite else { return .invalid }
    return .value(parsed * unit.multiplier)
  }

  func value(locale: Locale = .current) -> Double? {
    if case let .value(value) = reading(locale: locale) { return value }
    return nil
  }

  private static func format(_ value: Double, locale: Locale) -> String {
    value.formatted(.number.precision(.fractionLength(0...6)).grouping(.never).locale(locale))
  }
}
```

- [ ] **Step 4: Write the formatting and copy**

```swift
// financeplan/Features/TerminalPositions/TerminalFormat.swift
import Foundation
import StockPlanShared

/// Display formatting for terminal positions. Amounts use the API's `currency`;
/// the app has no global base currency.
enum TerminalFormat {
  /// Compact for big amounts ($10.00T, $1.0M), whole units below a million.
  static func money(_ value: Double, currency: String, locale: Locale = .current) -> String {
    StockMetricFormatter.compactStatementCurrency(value, code: currency, locale: locale)
  }

  /// A per-share price, always two decimals.
  static func price(_ value: Double, currency: String, locale: Locale = .current) -> String {
    StockMetricFormatter.currencyText(value, code: currency, decimals: 2, locale: locale)
  }

  /// Shares, optionally rounded down to whole shares (display only, never stored).
  static func shares(_ value: Double, roundDown: Bool, locale: Locale = .current) -> String {
    if roundDown {
      return TerminalMath.wholeShares(value).formatted(.number.precision(.fractionLength(0)).locale(locale))
    }
    return value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
  }

  /// A share count such as 10.6B.
  static func count(_ value: Double, locale: Locale = .current) -> String {
    StockMetricFormatter.compactNumber(value, locale: locale)
  }

  static func progress(_ fraction: Double, locale: Locale = .current) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0...2)).locale(locale))
  }
}

/// Contract copy. Computed so a language switch takes effect without a relaunch.
enum TerminalCopy {
  static var title: String { String(localized: "Terminal position sizing") }
  static var subtitle: String {
    String(localized: "Decide the future market cap and share count. Norviq tells you how many shares that target is.")
  }
  static var disclaimer: String {
    String(localized: "Terminal prices are your assumptions, not forecasts. Not financial advice.")
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the test command with `TerminalNumberInputTests`.
Expected: 7 tests pass.

- [ ] **Step 6: Commit**

```bash
git add financeplan/Features/TerminalPositions/TerminalNumberInput.swift financeplan/Features/TerminalPositions/TerminalFormat.swift financeplanTests/TerminalNumberInputTests.swift
git commit -m "feat(terminal): add value+unit number input and display formatting"
```

---

### Task 5: List view model — load, totals, sample row

**Files:**
- Create: `financeplan/Features/TerminalPositions/TerminalPositionsViewModel.swift`
- Create: `financeplanTests/TerminalPositionsTestSupport.swift`
- Test: `financeplanTests/TerminalPositionsViewModelTests.swift`

**Interfaces:**
- Consumes: `TerminalPositionsServicing` (Task 3), `TerminalPositionsHTTPClient.Error` (Task 2), `TerminalMath`.
- Produces:
  - `enum TerminalPreferences { static let roundDownKey = "terminalPositions.roundDownShares"; static let sampleDismissedKey = "terminalPositions.sampleDismissed" }`
  - `enum TerminalPositionsErrorText { static func isCancellation(_ error: Error) -> Bool; static func message(for error: Error, fallback: String, notFound: String? = nil) -> String? }`
  - `@MainActor @Observable final class TerminalPositionsViewModel` with `init(service:defaults:)`, `positions`, `autobuys`, `currency`, `monthlyAutobuyTotal`, `hasLoaded`, `isSampleDismissed`, `isLoading`, `errorMessage`, `showsSample`, `totals: Totals`, `load()`, `reloadAutobuys()`, `useSample()`, `dismissSample()`, `static let sampleRequest`, `static var samplePreview: TerminalScenarioResult?`. (Task 6 adds the mutations and Task 11 adds `deleteAutobuy`.)
  - Test support: `MockTerminalPositionsService` and `.fixture(...)` builders on every DTO.

- [ ] **Step 1: Write the test support**

```swift
// financeplanTests/TerminalPositionsTestSupport.swift
import Foundation
import StockPlanShared
@testable import financeplan

final class MockTerminalPositionsService: TerminalPositionsServicing, @unchecked Sendable {
  var listResult: Result<TerminalPositionsListResponse, Error> = .success(.fixture())
  var createResult: Result<TerminalPositionResponse, Error> = .success(.fixture(id: "created"))
  var updateResult: Result<TerminalPositionResponse, Error> = .success(.fixture())
  var deleteError: Error?
  var duplicateResult: Result<TerminalPositionResponse, Error> = .success(.fixture(id: "copy"))
  var reorderError: Error?
  var summaryResult: Result<TerminalPositionsSummaryResponse, Error> = .success(.fixture())
  var autobuysResult: Result<AutobuysListResponse, Error> = .success(.fixture())
  var createAutobuyResult: Result<AutobuyResponse, Error> = .success(.fixture(id: "new-autobuy"))
  var updateAutobuyResult: Result<AutobuyResponse, Error> = .success(.fixture())
  var deleteAutobuyError: Error?
  var shareFactsResult: Result<ShareFactsSuggestion, Error> = .success(.fixture())
  var scenarioResult: Result<TerminalScenarioSuggestion, Error> = .success(.fixture())

  private(set) var listTickers: [String?] = []
  private(set) var createRequests: [TerminalPositionCreateRequest] = []
  private(set) var updateIds: [String] = []
  private(set) var updateRequests: [TerminalPositionUpdateRequest] = []
  private(set) var deletedIds: [String] = []
  private(set) var duplicatedIds: [String] = []
  private(set) var reorderedIds: [[String]] = []
  private(set) var summaryCalls = 0
  private(set) var autobuysCalls = 0
  private(set) var createAutobuyRequests: [AutobuyCreateRequest] = []
  private(set) var updateAutobuyIds: [String] = []
  private(set) var updateAutobuyRequests: [AutobuyUpdateRequest] = []
  private(set) var deletedAutobuyIds: [String] = []
  private(set) var shareFactsTickers: [String] = []
  private(set) var scenarioTickers: [String] = []

  func list(ticker: String?) async throws -> TerminalPositionsListResponse {
    listTickers.append(ticker)
    return try listResult.get()
  }

  func create(_ request: TerminalPositionCreateRequest) async throws -> TerminalPositionResponse {
    createRequests.append(request)
    return try createResult.get()
  }

  func update(id: String, _ request: TerminalPositionUpdateRequest) async throws -> TerminalPositionResponse {
    updateIds.append(id)
    updateRequests.append(request)
    return try updateResult.get()
  }

  func delete(id: String) async throws {
    if let deleteError { throw deleteError }
    deletedIds.append(id)
  }

  func duplicate(id: String) async throws -> TerminalPositionResponse {
    duplicatedIds.append(id)
    return try duplicateResult.get()
  }

  /// Echoes the rows from `listResult` in the order asked for.
  func reorder(ids: [String]) async throws -> TerminalPositionsListResponse {
    reorderedIds.append(ids)
    if let reorderError { throw reorderError }
    let known = (try? listResult.get())?.positions ?? []
    return TerminalPositionsListResponse(
      currency: "USD",
      positions: ids.compactMap { id in known.first { $0.id == id } }
    )
  }

  func summary() async throws -> TerminalPositionsSummaryResponse {
    summaryCalls += 1
    return try summaryResult.get()
  }

  func autobuys() async throws -> AutobuysListResponse {
    autobuysCalls += 1
    return try autobuysResult.get()
  }

  func createAutobuy(_ request: AutobuyCreateRequest) async throws -> AutobuyResponse {
    createAutobuyRequests.append(request)
    return try createAutobuyResult.get()
  }

  func updateAutobuy(id: String, _ request: AutobuyUpdateRequest) async throws -> AutobuyResponse {
    updateAutobuyIds.append(id)
    updateAutobuyRequests.append(request)
    return try updateAutobuyResult.get()
  }

  func deleteAutobuy(id: String) async throws {
    if let deleteAutobuyError { throw deleteAutobuyError }
    deletedAutobuyIds.append(id)
  }

  func shareFacts(ticker: String) async throws -> ShareFactsSuggestion {
    shareFactsTickers.append(ticker)
    return try shareFactsResult.get()
  }

  func suggestScenario(ticker: String, horizonYears: Int?) async throws -> TerminalScenarioSuggestion {
    scenarioTickers.append(ticker)
    return try scenarioResult.get()
  }
}

extension TerminalPositionResponse {
  /// Derived fields come from the shared maths, exactly as the backend fills them.
  static func fixture(
    id: String = "p1",
    ticker: String = "AMZN",
    terminalShareCount: Double = 11_000_000_000,
    terminalMarketCap: Double = 10_000_000_000_000,
    valueWanted: Double = 1_000_000,
    sharesOwned: Double = 0,
    currentSharePrice: Double? = nil,
    sharesOutstanding: Double? = nil,
    notes: String? = nil,
    sortOrder: Int = 0
  ) -> TerminalPositionResponse {
    let outcome = TerminalMath.evaluate(TerminalScenarioInput(
      terminalShareCount: terminalShareCount,
      terminalMarketCap: terminalMarketCap,
      valueWanted: valueWanted,
      sharesOwned: sharesOwned,
      currentSharePrice: currentSharePrice
    ))
    var result: TerminalScenarioResult?
    var scenarioError: String?
    switch outcome {
    case let .success(value): result = value
    case let .failure(error): scenarioError = error.rawValue
    }
    return TerminalPositionResponse(
      id: id, ticker: ticker, sharesOutstanding: sharesOutstanding,
      terminalShareCount: terminalShareCount, terminalMarketCap: terminalMarketCap,
      valueWanted: valueWanted, sharesOwned: sharesOwned, currentSharePrice: currentSharePrice,
      notes: notes, sortOrder: sortOrder,
      terminalSharePrice: result?.terminalSharePrice, sharesNeeded: result?.sharesNeeded,
      capitalAtTodayPrice: result?.capitalAtTodayPrice, progress: result?.progress,
      sharesStillNeeded: result?.sharesStillNeeded, gapValueAtTerminal: result?.gapValueAtTerminal,
      scenarioError: scenarioError,
      createdAt: "2026-10-09T10:00:00Z", updatedAt: "2026-10-09T10:00:00Z"
    )
  }
}

extension TerminalPositionsListResponse {
  static func fixture(_ positions: [TerminalPositionResponse] = [.fixture()], currency: String = "USD") -> TerminalPositionsListResponse {
    TerminalPositionsListResponse(currency: currency, positions: positions)
  }
}

extension AutobuyResponse {
  static func fixture(
    id: String = "a1",
    ticker: String? = nil,
    label: String = "401k",
    amount: Double = 5_000,
    cadence: AutobuyCadence = .percentOfContribution,
    percent: Double? = 0.04,
    active: Bool = true
  ) -> AutobuyResponse {
    AutobuyResponse(
      id: id, ticker: ticker, label: label, amount: amount, cadence: cadence, percent: percent, active: active,
      monthlyEquivalent: AutobuyMath.monthlyEquivalent(amount: amount, cadence: cadence, percent: percent),
      createdAt: "2026-10-09T10:00:00Z", updatedAt: "2026-10-09T10:00:00Z"
    )
  }
}

extension AutobuysListResponse {
  static func fixture(_ autobuys: [AutobuyResponse] = [], currency: String = "USD") -> AutobuysListResponse {
    AutobuysListResponse(
      currency: currency,
      autobuys: autobuys,
      monthlyTotal: AutobuyMath.monthlyTotal(
        autobuys.map { (amount: $0.amount, cadence: $0.cadence, percent: $0.percent, active: $0.active) }
      )
    )
  }
}

extension TerminalPositionsSummaryResponse {
  static func fixture(
    _ positions: [TerminalPositionResponse] = [.fixture()],
    monthlyAutobuyTotal: Double = 0,
    currency: String = "USD"
  ) -> TerminalPositionsSummaryResponse {
    let valid = positions.filter { $0.scenarioError == nil }
    let priced = valid.compactMap(\.capitalAtTodayPrice)
    return TerminalPositionsSummaryResponse(
      currency: currency,
      positionCount: positions.count,
      totalValueWanted: valid.reduce(0) { $0 + $1.valueWanted },
      totalGapValueAtTerminal: valid.reduce(0) { $0 + ($1.gapValueAtTerminal ?? 0) },
      totalCapitalAtTodayPrice: priced.isEmpty ? nil : priced.reduce(0, +),
      pricedPositionCount: priced.count,
      monthlyAutobuyTotal: monthlyAutobuyTotal,
      topPositions: Array(valid.sorted { $0.valueWanted > $1.valueWanted }.prefix(3))
    )
  }
}

extension ShareFactsSuggestion {
  static func fixture(currency: String? = "USD") -> ShareFactsSuggestion {
    ShareFactsSuggestion(
      ticker: "AMZN", sharesOutstanding: 10_600_000_000, currentSharePrice: 220.5,
      currency: currency, asOf: "2026-10-08", sources: ["https://example.com/amzn-10q"]
    )
  }
}

extension TerminalScenarioSuggestion {
  static func fixture() -> TerminalScenarioSuggestion {
    TerminalScenarioSuggestion(
      ticker: "AMZN", terminalShareCount: 12_000_000_000, terminalMarketCap: 8_000_000_000_000,
      horizonYears: 10, rationale: "Cloud and ads keep compounding.", sources: ["https://example.com/amzn-outlook"]
    )
  }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
// financeplanTests/TerminalPositionsViewModelTests.swift
import Foundation
import StockPlanShared
import XCTest
@testable import financeplan

// Every test is `async`, even those that await nothing: see PilotsStoreTests
// for the synchronous-deinit crash this avoids.
@MainActor
final class TerminalPositionsViewModelTests: XCTestCase {
  private func makeModel(
    _ service: MockTerminalPositionsService = MockTerminalPositionsService(),
    defaults: UserDefaults? = nil
  ) -> (TerminalPositionsViewModel, MockTerminalPositionsService, UserDefaults) {
    let defaults = defaults ?? UserDefaults(suiteName: "TerminalPositionsViewModelTests-\(UUID().uuidString)")!
    return (TerminalPositionsViewModel(service: service, defaults: defaults), service, defaults)
  }

  func testLoadShowsPositionsCurrencyAndAutobuyTotal() async {
    let service = MockTerminalPositionsService()
    service.listResult = .success(.fixture([.fixture()], currency: "EUR"))
    service.autobuysResult = .success(.fixture([.fixture(amount: 50, cadence: .weekly, percent: nil)], currency: "EUR"))
    let (model, _, _) = makeModel(service)

    await model.load()

    XCTAssertEqual(model.positions.map(\.id), ["p1"])
    XCTAssertEqual(model.currency, "EUR")
    XCTAssertEqual(model.autobuys.count, 1)
    XCTAssertEqual(model.monthlyAutobuyTotal, 50 * 52 / 12, accuracy: 0.000001)
    XCTAssertTrue(model.hasLoaded)
    XCTAssertNil(model.errorMessage)
  }

  func testTotalsSkipInvalidRowsAndCountOnlyPricedCapital() async {
    let service = MockTerminalPositionsService()
    service.listResult = .success(.fixture([
      .fixture(id: "a", sharesOwned: 750, currentSharePrice: 200),
      .fixture(id: "b", ticker: "BAD", terminalShareCount: 0),
      .fixture(id: "c", ticker: "VG", terminalShareCount: 16_000_000, terminalMarketCap: 1_000_000_000, valueWanted: 500_000),
    ]))
    let (model, _, _) = makeModel(service)

    await model.load()

    let totals = model.totals
    XCTAssertEqual(totals.valueWanted, 1_500_000, accuracy: 0.001)
    XCTAssertEqual(totals.gapValueAtTerminal, 350 * (10_000_000_000_000 / 11_000_000_000) + 500_000, accuracy: 0.001)
    XCTAssertEqual(totals.capitalAtTodayPrice ?? 0, 1_100 * 200, accuracy: 0.001)
  }

  func testLoadFailureShowsAMessageAndNoSample() async {
    let service = MockTerminalPositionsService()
    service.listResult = .failure(TerminalPositionsHTTPClient.Error.rejected(status: 404, message: "Not Found"))
    let (model, _, _) = makeModel(service)

    await model.load()

    XCTAssertEqual(model.errorMessage, "Terminal positions are unavailable right now.")
    XCTAssertFalse(model.hasLoaded)
    XCTAssertFalse(model.showsSample)
  }

  func testCancelledLoadShowsNoError() async {
    let service = MockTerminalPositionsService()
    service.listResult = .failure(TerminalPositionsHTTPClient.Error.cancelled)
    service.autobuysResult = .failure(CancellationError())
    let (model, _, _) = makeModel(service)

    await model.load()

    XCTAssertNil(model.errorMessage)
  }

  func testAutobuysFailureStillShowsPositions() async {
    let service = MockTerminalPositionsService()
    service.autobuysResult = .failure(TerminalPositionsHTTPClient.Error.invalidStatus(500))
    let (model, _, _) = makeModel(service)

    await model.load()

    XCTAssertEqual(model.positions.count, 1)
    XCTAssertEqual(model.errorMessage, "Autobuys are unavailable right now.")
  }

  func testEmptyListShowsTheSampleUntilDismissedAndRemembersIt() async {
    let service = MockTerminalPositionsService()
    service.listResult = .success(.fixture([]))
    let (model, _, defaults) = makeModel(service)

    await model.load()
    XCTAssertTrue(model.showsSample)

    model.dismissSample()
    XCTAssertFalse(model.showsSample)

    let (reopened, _, _) = makeModel(service, defaults: defaults)
    await reopened.load()
    XCTAssertFalse(reopened.showsSample)
  }

  func testUsingTheSampleCreatesTheAMZNRow() async {
    let service = MockTerminalPositionsService()
    service.listResult = .success(.fixture([]))
    service.createResult = .success(.fixture(id: "sample"))
    let (model, _, _) = makeModel(service)
    await model.load()

    await model.useSample()

    XCTAssertEqual(service.createRequests, [TerminalPositionsViewModel.sampleRequest])
    XCTAssertEqual(TerminalPositionsViewModel.sampleRequest.ticker, "AMZN")
    XCTAssertEqual(model.positions.map(\.id), ["sample"])
    XCTAssertFalse(model.showsSample)
  }

  func testSamplePreviewMatchesTheWorkedExample() async {
    let preview = TerminalPositionsViewModel.samplePreview
    XCTAssertEqual(preview?.terminalSharePrice ?? 0, 909.0909, accuracy: 0.0001)
    XCTAssertEqual(preview?.sharesNeeded ?? 0, 1_100, accuracy: 0.000001)
  }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run the test command with `TerminalPositionsViewModelTests`.
Expected: FAIL to compile with `cannot find 'TerminalPositionsViewModel' in scope`.

- [ ] **Step 4: Write the view model**

```swift
// financeplan/Features/TerminalPositions/TerminalPositionsViewModel.swift
import Foundation
import Observation
import StockPlanShared
import SwiftUI

enum TerminalPreferences {
  /// Display-only "round down to whole shares", shared by the screen, editor and cards.
  static let roundDownKey = "terminalPositions.roundDownShares"
  static let sampleDismissedKey = "terminalPositions.sampleDismissed"
}

/// What a terminal-positions surface shows for a failed request.
enum TerminalPositionsErrorText {
  static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if case .cancelled? = error as? TerminalPositionsHTTPClient.Error { return true }
    return false
  }

  /// Nil means show nothing (the screen went away mid-request). A 422 shows the
  /// server's reason, which is written for people ("Ticker is invalid").
  static func message(for error: Error, fallback: String, notFound: String? = nil) -> String? {
    if isCancellation(error) { return nil }
    switch error as? TerminalPositionsHTTPClient.Error {
    case .rejected(status: 422, message: let message?)? where !message.isEmpty:
      return message
    case .rejected(status: 404, message: _)? where notFound != nil:
      return notFound
    default:
      return fallback
    }
  }
}

@MainActor @Observable
final class TerminalPositionsViewModel {
  /// Footer totals over valid rows. "Total shares-needed notional at terminal
  /// prices" is left out on purpose: it always equals total value wanted.
  struct Totals: Equatable {
    let valueWanted: Double
    let gapValueAtTerminal: Double
    /// Nil when no valid row has today's price.
    let capitalAtTodayPrice: Double?
  }

  /// The empty-state example: a 10T cap on 11B shares is 909.09 a share, so
  /// 1M takes 1,100 shares. It is only stored when the user taps "Use AMZN sample".
  static let sampleRequest = TerminalPositionCreateRequest(
    ticker: "AMZN",
    sharesOutstanding: nil,
    terminalShareCount: 11_000_000_000,
    terminalMarketCap: 10_000_000_000_000,
    valueWanted: 1_000_000,
    sharesOwned: nil,
    currentSharePrice: nil,
    notes: nil
  )

  static var samplePreview: TerminalScenarioResult? {
    let input = TerminalScenarioInput(
      terminalShareCount: sampleRequest.terminalShareCount,
      terminalMarketCap: sampleRequest.terminalMarketCap,
      valueWanted: sampleRequest.valueWanted
    )
    if case let .success(result) = TerminalMath.evaluate(input) { return result }
    return nil
  }

  private(set) var positions: [TerminalPositionResponse] = []
  private(set) var autobuys: [AutobuyResponse] = []
  private(set) var currency = "USD"
  private(set) var monthlyAutobuyTotal: Double = 0
  private(set) var hasLoaded = false
  private(set) var isSampleDismissed: Bool
  var isLoading = false
  var errorMessage: String?

  private let service: any TerminalPositionsServicing
  private let defaults: UserDefaults

  init(service: any TerminalPositionsServicing, defaults: UserDefaults = .standard) {
    self.service = service
    self.defaults = defaults
    isSampleDismissed = defaults.bool(forKey: TerminalPreferences.sampleDismissedKey)
  }

  var showsSample: Bool { hasLoaded && positions.isEmpty && !isSampleDismissed }

  var totals: Totals {
    let valid = positions.filter { $0.scenarioError == nil }
    let priced = valid.compactMap(\.capitalAtTodayPrice)
    return Totals(
      valueWanted: valid.reduce(0) { $0 + $1.valueWanted },
      gapValueAtTerminal: valid.reduce(0) { $0 + ($1.gapValueAtTerminal ?? 0) },
      capitalAtTodayPrice: priced.isEmpty ? nil : priced.reduce(0, +)
    )
  }

  func load() async {
    isLoading = true
    defer { isLoading = false }
    async let listRequest = service.list(ticker: nil)
    async let autobuysRequest = service.autobuys()
    do {
      let list = try await listRequest
      positions = list.positions
      currency = list.currency
      hasLoaded = true
    } catch {
      show(error, fallback: String(localized: "Terminal positions are unavailable right now."))
    }
    do {
      apply(try await autobuysRequest)
    } catch {
      show(error, fallback: String(localized: "Autobuys are unavailable right now."))
    }
  }

  func reloadAutobuys() async {
    do {
      apply(try await service.autobuys())
    } catch {
      show(error, fallback: String(localized: "Autobuys are unavailable right now."))
    }
  }

  func useSample() async {
    do {
      positions.append(try await service.create(Self.sampleRequest))
    } catch {
      show(error, fallback: String(localized: "The sample could not be added."))
    }
  }

  func dismissSample() {
    defaults.set(true, forKey: TerminalPreferences.sampleDismissedKey)
    isSampleDismissed = true
  }

  private func apply(_ list: AutobuysListResponse) {
    autobuys = list.autobuys
    monthlyAutobuyTotal = list.monthlyTotal
  }

  private func show(_ error: Error, fallback: String, notFound: String? = nil) {
    if let message = TerminalPositionsErrorText.message(for: error, fallback: fallback, notFound: notFound) {
      errorMessage = message
    }
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the test command with `TerminalPositionsViewModelTests`.
Expected: 8 tests pass.

- [ ] **Step 6: Commit**

```bash
git add financeplan/Features/TerminalPositions/TerminalPositionsViewModel.swift financeplanTests/TerminalPositionsTestSupport.swift financeplanTests/TerminalPositionsViewModelTests.swift
git commit -m "feat(terminal): add positions view model with totals and sample row"
```

---

### Task 6: List view model — delete, duplicate, reorder, saved rows

**Files:**
- Modify: `financeplan/Features/TerminalPositions/TerminalPositionsViewModel.swift`
- Test: `financeplanTests/TerminalPositionsViewModelTests.swift` (append)

**Interfaces:**
- Consumes: Task 5's view model and mock.
- Produces: `func saved(_ position: TerminalPositionResponse)`, `func delete(_ position: TerminalPositionResponse) async`, `func duplicate(_ position: TerminalPositionResponse) async`, `@discardableResult func move(fromOffsets: IndexSet, toOffset: Int) -> Task<Void, Never>?`.

- [ ] **Step 1: Write the failing tests** (append inside `TerminalPositionsViewModelTests`)

```swift
  private func loadedModel(ids: [String]) async -> (TerminalPositionsViewModel, MockTerminalPositionsService) {
    let service = MockTerminalPositionsService()
    service.listResult = .success(.fixture(ids.enumerated().map { .fixture(id: $1, sortOrder: $0) }))
    let (model, _, _) = makeModel(service)
    await model.load()
    return (model, service)
  }

  func testDeleteRemovesTheRowAndCallsTheService() async {
    let (model, service) = await loadedModel(ids: ["a", "b"])

    await model.delete(model.positions[0])

    XCTAssertEqual(model.positions.map(\.id), ["b"])
    XCTAssertEqual(service.deletedIds, ["a"])
  }

  func testFailedDeletePutsTheRowBackInPlace() async {
    let (model, service) = await loadedModel(ids: ["a", "b", "c"])
    service.deleteError = TerminalPositionsHTTPClient.Error.invalidStatus(500)

    await model.delete(model.positions[1])

    XCTAssertEqual(model.positions.map(\.id), ["a", "b", "c"])
    XCTAssertEqual(model.errorMessage, "The row could not be deleted.")
  }

  func testDeletingARowAlreadyGoneElsewhereStaysDeleted() async {
    let (model, service) = await loadedModel(ids: ["a", "b"])
    service.deleteError = TerminalPositionsHTTPClient.Error.rejected(status: 404, message: nil)

    await model.delete(model.positions[0])

    XCTAssertEqual(model.positions.map(\.id), ["b"])
    XCTAssertNil(model.errorMessage)
  }

  func testDuplicateInsertsTheCopyRightAfterTheSource() async {
    let (model, service) = await loadedModel(ids: ["a", "b"])
    service.duplicateResult = .success(.fixture(id: "a-copy"))

    await model.duplicate(model.positions[0])

    XCTAssertEqual(service.duplicatedIds, ["a"])
    XCTAssertEqual(model.positions.map(\.id), ["a", "a-copy", "b"])
  }

  func testMoveReordersLocallyAtOnceAndSendsTheFullIdList() async {
    let (model, service) = await loadedModel(ids: ["a", "b", "c"])

    let task = model.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
    XCTAssertEqual(model.positions.map(\.id), ["c", "a", "b"], "the list must move before the request returns")
    await task?.value

    XCTAssertEqual(service.reorderedIds, [["c", "a", "b"]])
    XCTAssertEqual(model.positions.map(\.id), ["c", "a", "b"])
  }

  func testNoOpMoveSendsNothing() async {
    let (model, service) = await loadedModel(ids: ["a", "b"])

    let task = model.move(fromOffsets: IndexSet(integer: 0), toOffset: 1)

    XCTAssertNil(task)
    XCTAssertTrue(service.reorderedIds.isEmpty)
  }

  func testFailedMoveReloadsTheServerOrder() async {
    let (model, service) = await loadedModel(ids: ["a", "b", "c"])
    service.reorderError = TerminalPositionsHTTPClient.Error.rejected(status: 422, message: "ids must match")

    await model.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)?.value

    XCTAssertEqual(model.positions.map(\.id), ["a", "b", "c"])
    XCTAssertEqual(service.listTickers.count, 2, "initial load plus the reload")
    XCTAssertEqual(model.errorMessage, "The new order could not be saved.")
  }

  func testRapidMovesKeepTheLastOrder() async {
    let (model, service) = await loadedModel(ids: ["a", "b", "c"])

    let first = model.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
    let second = model.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
    await first?.value
    await second?.value

    XCTAssertEqual(service.reorderedIds, [["c", "a", "b"], ["b", "c", "a"]])
    XCTAssertEqual(model.positions.map(\.id), ["b", "c", "a"])
  }

  func testSavedReplacesAnEditedRowAndAppendsANewOne() async {
    let (model, _) = await loadedModel(ids: ["a", "b"])

    model.saved(.fixture(id: "a", valueWanted: 2_000_000))
    model.saved(.fixture(id: "z"))

    XCTAssertEqual(model.positions.map(\.id), ["a", "b", "z"])
    XCTAssertEqual(model.positions[0].valueWanted, 2_000_000)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the test command with `TerminalPositionsViewModelTests`.
Expected: FAIL to compile with `value of type 'TerminalPositionsViewModel' has no member 'delete'`.

- [ ] **Step 3: Add the mutations** (insert before `private func apply(_ list: AutobuysListResponse)`, and add the two stored properties next to `private let defaults`)

```swift
  private var reorderTask: Task<Void, Never>?
  private var reorderGeneration = 0
```

```swift
  /// The editor's result: replaces the row it edited, or appends a new one.
  func saved(_ position: TerminalPositionResponse) {
    if let index = positions.firstIndex(where: { $0.id == position.id }) {
      positions[index] = position
    } else {
      positions.append(position)
    }
  }

  func delete(_ position: TerminalPositionResponse) async {
    guard let index = positions.firstIndex(where: { $0.id == position.id }) else { return }
    positions.remove(at: index)
    do {
      try await service.delete(id: position.id)
    } catch {
      // Already deleted on another device: the row is gone either way.
      if case .rejected(status: 404, message: _)? = error as? TerminalPositionsHTTPClient.Error { return }
      positions.insert(position, at: min(index, positions.count))
      show(error, fallback: String(localized: "The row could not be deleted."))
    }
  }

  func duplicate(_ position: TerminalPositionResponse) async {
    do {
      let copy = try await service.duplicate(id: position.id)
      let index = positions.firstIndex(where: { $0.id == position.id }).map { $0 + 1 } ?? positions.count
      positions.insert(copy, at: index)
    } catch {
      show(
        error,
        fallback: String(localized: "The row could not be duplicated."),
        notFound: String(localized: "That row no longer exists. Pull to refresh.")
      )
    }
  }

  /// Moves the rows at once (SwiftUI expects `onMove` to change the data
  /// synchronously), then saves the full order. Saves run one after another.
  /// Only the newest one applies the server's answer, and if the newest fails,
  /// the list reloads, so it never shows an order the server doesn't have.
  @discardableResult
  func move(fromOffsets source: IndexSet, toOffset destination: Int) -> Task<Void, Never>? {
    let before = positions.map(\.id)
    positions.move(fromOffsets: source, toOffset: destination)
    let ids = positions.map(\.id)
    guard ids != before else { return nil }
    reorderGeneration += 1
    let generation = reorderGeneration
    let previous = reorderTask
    let task = Task {
      await previous?.value
      await commitOrder(ids, generation: generation)
    }
    reorderTask = task
    return task
  }

  private func commitOrder(_ ids: [String], generation: Int) async {
    do {
      let list = try await service.reorder(ids: ids)
      guard generation == reorderGeneration else { return }
      positions = list.positions
    } catch {
      guard generation == reorderGeneration, !TerminalPositionsErrorText.isCancellation(error) else { return }
      errorMessage = String(localized: "The new order could not be saved.")
      await load()
    }
  }
```

The reload in `commitOrder` calls `load()`, which sets `errorMessage` only on failure, so the order message survives a successful reload.

- [ ] **Step 4: Run the tests to verify they pass**

Run the test command with `TerminalPositionsViewModelTests`.
Expected: 17 tests pass.

- [ ] **Step 5: Commit**

```bash
git add financeplan/Features/TerminalPositions/TerminalPositionsViewModel.swift financeplanTests/TerminalPositionsViewModelTests.swift
git commit -m "feat(terminal): delete, duplicate and reorder terminal positions"
```

---

### Task 7: Editor model — form, live preview, guardrails, save

**Files:**
- Create: `financeplan/Features/TerminalPositions/TerminalPositionEditorModel.swift`
- Test: `financeplanTests/TerminalPositionEditorModelTests.swift`

**Interfaces:**
- Consumes: `TerminalNumberInput` (Task 4), `TerminalPositionsServicing` (Task 3), `TerminalPositionsErrorText` (Task 5), `TerminalMath.evaluate`.
- Produces:
  - `@MainActor @Observable final class TerminalPositionEditorModel` with `init(position: TerminalPositionResponse? = nil, ticker: String? = nil, currency: String, service: any TerminalPositionsServicing, locale: Locale = .current)`.
  - `enum Field { case ticker, terminalShareCount, terminalMarketCap, valueWanted, sharesOwned, sharesOutstanding, currentSharePrice }`.
  - `struct Inputs: Equatable { ticker, terminalShareCount, terminalMarketCap, valueWanted, sharesOwned, sharesOutstanding, currentSharePrice: TerminalNumberInput…, notes: String }` and `var inputs: Inputs`.
  - `original`, `currency`, `isEditing`, `isSaving`, `errorMessage`, `normalizedTicker`, `isTickerValid`, `problem(for:) -> String?`, `preview: Result<TerminalScenarioResult, TerminalScenarioError>?`, `previewResult`, `canSave`, `makeCreateRequest()`, `makeUpdateRequest()`, `save() async -> TerminalPositionResponse?`, `static func text(for: TerminalScenarioError) -> String`, `static func text(forRaw: String) -> String`.

- [ ] **Step 1: Write the failing tests**

```swift
// financeplanTests/TerminalPositionEditorModelTests.swift
import Foundation
import StockPlanShared
import XCTest
@testable import financeplan

@MainActor
final class TerminalPositionEditorModelTests: XCTestCase {
  private let english = Locale(identifier: "en_US")
  private let portuguese = Locale(identifier: "pt_PT")

  private func filledModel(
    _ service: MockTerminalPositionsService = MockTerminalPositionsService(),
    locale: Locale? = nil
  ) -> TerminalPositionEditorModel {
    let model = TerminalPositionEditorModel(ticker: "amzn ", currency: "USD", service: service, locale: locale ?? english)
    model.inputs.terminalShareCount = TerminalNumberInput(text: "11", unit: .billion)
    model.inputs.terminalMarketCap = TerminalNumberInput(text: "10", unit: .trillion)
    model.inputs.valueWanted = TerminalNumberInput(text: "1", unit: .million)
    model.inputs.sharesOwned = TerminalNumberInput(text: "750")
    return model
  }

  func testNewPositionPrefillsTheTickerAndHasNoPreview() async {
    let model = TerminalPositionEditorModel(ticker: "amzn", currency: "USD", service: MockTerminalPositionsService(), locale: english)

    XCTAssertEqual(model.inputs.ticker, "AMZN")
    XCTAssertNil(model.preview)
    XCTAssertFalse(model.canSave)
    XCTAssertFalse(model.isEditing)
  }

  func testLivePreviewMatchesTheAMZNWorkedExample() async {
    let model = filledModel()

    let result = model.previewResult
    XCTAssertEqual(result?.terminalSharePrice ?? 0, 909.0909, accuracy: 0.0001)
    XCTAssertEqual(result?.sharesNeeded ?? 0, 1_100, accuracy: 0.000001)
    XCTAssertEqual(result?.progress ?? 0, 0.681818, accuracy: 0.000001)
    XCTAssertNil(result?.capitalAtTodayPrice)
    XCTAssertTrue(model.canSave)
  }

  func testPortugueseCommaInputIsReadAsADecimal() async {
    let model = filledModel(locale: portuguese)
    model.inputs.terminalMarketCap = TerminalNumberInput(text: "1,5", unit: .trillion)
    model.inputs.valueWanted = TerminalNumberInput(text: "2,5", unit: .million)

    XCTAssertEqual(model.makeCreateRequest()?.terminalMarketCap, 1_500_000_000_000)
    XCTAssertEqual(model.makeCreateRequest()?.valueWanted, 2_500_000)
  }

  func testZeroShareCountShowsTheGuardrailAndBlocksSave() async {
    let model = filledModel()
    model.inputs.terminalShareCount = TerminalNumberInput(text: "0")

    XCTAssertEqual(model.problem(for: .terminalShareCount), "Share count must be above zero.")
    XCTAssertEqual(model.preview, .failure(.shareCountNotPositive))
    XCTAssertFalse(model.canSave)
  }

  func testZeroMarketCapShowsTheGuardrail() async {
    let model = filledModel()
    model.inputs.terminalMarketCap = TerminalNumberInput(text: "0", unit: .trillion)

    XCTAssertEqual(model.problem(for: .terminalMarketCap), "Market cap must be above zero.")
    XCTAssertEqual(model.preview, .failure(.marketCapNotPositive))
  }

  func testTypedMinusIsRefusedNotFlipped() async {
    let model = filledModel()
    model.inputs.valueWanted = TerminalNumberInput(text: "-100")

    XCTAssertEqual(model.problem(for: .valueWanted), "Can't be negative.")
    XCTAssertNil(model.preview)
    XCTAssertFalse(model.canSave)
  }

  func testInvalidTickerBlocksSave() async {
    let model = filledModel()
    model.inputs.ticker = "AMZN!"

    XCTAssertEqual(model.problem(for: .ticker), "Use 1–12 letters, digits, dots or dashes.")
    XCTAssertFalse(model.canSave)
  }

  func testCreateSendsParsedValuesAndLeavesEmptyOptionalsOut() async {
    let service = MockTerminalPositionsService()
    let model = filledModel(service)

    let saved = await model.save()

    XCTAssertEqual(saved?.id, "created")
    XCTAssertEqual(service.createRequests, [TerminalPositionCreateRequest(
      ticker: "AMZN", sharesOutstanding: nil, terminalShareCount: 11_000_000_000,
      terminalMarketCap: 10_000_000_000_000, valueWanted: 1_000_000, sharesOwned: 750,
      currentSharePrice: nil, notes: nil
    )])
  }

  func testEditingSendsOnlyChangedFieldsAndClearsEmptiedOptionals() async {
    let service = MockTerminalPositionsService()
    let original = TerminalPositionResponse.fixture(currentSharePrice: 200, sharesOutstanding: 10_600_000_000, notes: "old")
    let model = TerminalPositionEditorModel(position: original, currency: "USD", service: service, locale: english)
    model.inputs.valueWanted = TerminalNumberInput(text: "2", unit: .million)
    model.inputs.currentSharePrice = TerminalNumberInput()
    model.inputs.notes = "  "

    _ = await model.save()

    XCTAssertEqual(service.updateIds, ["p1"])
    XCTAssertEqual(service.updateRequests, [TerminalPositionUpdateRequest(
      ticker: nil, sharesOutstanding: nil, terminalShareCount: nil, terminalMarketCap: nil,
      valueWanted: 2_000_000, sharesOwned: nil, currentSharePrice: nil, notes: nil,
      clear: ["currentSharePrice", "notes"]
    )])
  }

  func testUnchangedEditSavesWithoutARequest() async {
    let service = MockTerminalPositionsService()
    let original = TerminalPositionResponse.fixture(sharesOwned: 750)
    let model = TerminalPositionEditorModel(position: original, currency: "USD", service: service, locale: english)

    let saved = await model.save()

    XCTAssertEqual(saved, original)
    XCTAssertTrue(service.updateRequests.isEmpty)
  }

  func testUnchangedEditInPortugueseSendsNothing() async {
    let service = MockTerminalPositionsService()
    let original = TerminalPositionResponse.fixture(valueWanted: 1_234_567.891, currentSharePrice: 220.123)
    let model = TerminalPositionEditorModel(position: original, currency: "EUR", service: service, locale: portuguese)

    XCTAssertTrue(model.canSave)
    _ = await model.save()

    XCTAssertTrue(service.updateRequests.isEmpty)
  }

  func testServerReasonIsShownOn422() async {
    let service = MockTerminalPositionsService()
    service.createResult = .failure(TerminalPositionsHTTPClient.Error.rejected(status: 422, message: "Ticker is invalid"))
    let model = filledModel(service)

    let saved = await model.save()

    XCTAssertNil(saved)
    XCTAssertEqual(model.errorMessage, "Ticker is invalid")
  }

  func testRowErrorTextReadsTheRawScenarioError() async {
    XCTAssertEqual(
      TerminalPositionEditorModel.text(forRaw: "share_count_not_positive"),
      "Share count must be above zero."
    )
    XCTAssertEqual(
      TerminalPositionEditorModel.text(forRaw: "something_new"),
      "This scenario needs a positive share count and market cap."
    )
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the test command with `TerminalPositionEditorModelTests`.
Expected: FAIL to compile with `cannot find 'TerminalPositionEditorModel' in scope`.

- [ ] **Step 3: Write the editor model**

```swift
// financeplan/Features/TerminalPositions/TerminalPositionEditorModel.swift
import Foundation
import Observation
import StockPlanShared

@MainActor @Observable
final class TerminalPositionEditorModel {
  enum Field: Hashable {
    case ticker, terminalShareCount, terminalMarketCap, valueWanted, sharesOwned, sharesOutstanding, currentSharePrice
  }

  /// Everything the form holds. An edit is compared with what was loaded by
  /// typed text, not by floating point, so an untouched field is never re-sent.
  struct Inputs: Equatable {
    var ticker: String
    var terminalShareCount: TerminalNumberInput
    var terminalMarketCap: TerminalNumberInput
    var valueWanted: TerminalNumberInput
    var sharesOwned: TerminalNumberInput
    var sharesOutstanding: TerminalNumberInput
    var currentSharePrice: TerminalNumberInput
    var notes: String
  }

  private struct Values {
    let ticker: String
    let terminalShareCount: Double
    let terminalMarketCap: Double
    let valueWanted: Double
    let sharesOwned: Double?
    let sharesOutstanding: Double?
    let currentSharePrice: Double?
    let notes: String?
  }

  private static let noChanges = TerminalPositionUpdateRequest(
    ticker: nil, sharesOutstanding: nil, terminalShareCount: nil, terminalMarketCap: nil,
    valueWanted: nil, sharesOwned: nil, currentSharePrice: nil, notes: nil, clear: nil
  )

  let original: TerminalPositionResponse?
  let currency: String
  var inputs: Inputs
  var isSaving = false
  var errorMessage: String?

  private let initialInputs: Inputs
  private let service: any TerminalPositionsServicing
  private let locale: Locale

  init(
    position: TerminalPositionResponse? = nil,
    ticker: String? = nil,
    currency: String,
    service: any TerminalPositionsServicing,
    locale: Locale = .current
  ) {
    original = position
    self.currency = currency
    self.service = service
    self.locale = locale
    let inputs = Inputs(
      ticker: position?.ticker ?? ticker?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "",
      terminalShareCount: TerminalNumberInput(value: position?.terminalShareCount, locale: locale),
      terminalMarketCap: TerminalNumberInput(value: position?.terminalMarketCap, locale: locale),
      valueWanted: TerminalNumberInput(value: position?.valueWanted, locale: locale),
      sharesOwned: TerminalNumberInput(value: position.map(\.sharesOwned), usesUnits: false, locale: locale),
      sharesOutstanding: TerminalNumberInput(value: position?.sharesOutstanding, locale: locale),
      currentSharePrice: TerminalNumberInput(value: position?.currentSharePrice, usesUnits: false, locale: locale),
      notes: position?.notes ?? ""
    )
    self.inputs = inputs
    initialInputs = inputs
  }

  var isEditing: Bool { original != nil }

  var normalizedTicker: String { inputs.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }

  var isTickerValid: Bool {
    normalizedTicker.range(of: #"^[A-Z0-9.\-]{1,12}$"#, options: .regularExpression) != nil
  }

  func problem(for field: Field) -> String? {
    switch field {
    case .ticker:
      return inputs.ticker.isEmpty || isTickerValid ? nil : String(localized: "Use 1–12 letters, digits, dots or dashes.")
    case .terminalShareCount:
      return positiveProblem(inputs.terminalShareCount, message: String(localized: "Share count must be above zero."))
    case .terminalMarketCap:
      return positiveProblem(inputs.terminalMarketCap, message: String(localized: "Market cap must be above zero."))
    case .valueWanted:
      return nonNegativeProblem(inputs.valueWanted)
    case .sharesOwned:
      return nonNegativeProblem(inputs.sharesOwned)
    case .sharesOutstanding:
      return nonNegativeProblem(inputs.sharesOutstanding)
    case .currentSharePrice:
      return nonNegativeProblem(inputs.currentSharePrice)
    }
  }

  /// The shared maths on what is typed now. Nil until the three required
  /// fields read as numbers.
  var preview: Result<TerminalScenarioResult, TerminalScenarioError>? {
    guard let shareCount = inputs.terminalShareCount.value(locale: locale),
          let marketCap = inputs.terminalMarketCap.value(locale: locale),
          let valueWanted = inputs.valueWanted.value(locale: locale),
          let sharesOwned = optionalValue(inputs.sharesOwned),
          let price = optionalValue(inputs.currentSharePrice)
    else { return nil }
    return TerminalMath.evaluate(TerminalScenarioInput(
      terminalShareCount: shareCount,
      terminalMarketCap: marketCap,
      valueWanted: valueWanted,
      sharesOwned: sharesOwned ?? 0,
      currentSharePrice: price
    ))
  }

  var previewResult: TerminalScenarioResult? {
    if case let .success(result)? = preview { return result }
    return nil
  }

  var canSave: Bool { !isSaving && values() != nil }

  static func text(for error: TerminalScenarioError) -> String {
    switch error {
    case .shareCountNotPositive: String(localized: "Share count must be above zero.")
    case .marketCapNotPositive: String(localized: "Market cap must be above zero.")
    case .invalidNumber: String(localized: "These numbers can't be used. Check for negatives.")
    }
  }

  /// For a row's `scenarioError`, which may carry a raw value newer than this build.
  static func text(forRaw raw: String) -> String {
    TerminalScenarioError(rawValue: raw).map { text(for: $0) }
      ?? String(localized: "This scenario needs a positive share count and market cap.")
  }

  func makeCreateRequest() -> TerminalPositionCreateRequest? {
    guard let values = values() else { return nil }
    return TerminalPositionCreateRequest(
      ticker: values.ticker,
      sharesOutstanding: values.sharesOutstanding,
      terminalShareCount: values.terminalShareCount,
      terminalMarketCap: values.terminalMarketCap,
      valueWanted: values.valueWanted,
      sharesOwned: values.sharesOwned,
      currentSharePrice: values.currentSharePrice,
      notes: values.notes
    )
  }

  /// Only the fields the user touched. A cleared optional goes in `clear`,
  /// because the PATCH reads a missing key as "leave it".
  func makeUpdateRequest() -> TerminalPositionUpdateRequest? {
    guard let original, let values = values() else { return nil }
    let start = initialInputs
    var clear: [String] = []

    func changed<T>(_ keyPath: KeyPath<Inputs, TerminalNumberInput>, _ value: T) -> T? {
      inputs[keyPath: keyPath] == start[keyPath: keyPath] ? nil : value
    }

    func optional(_ keyPath: KeyPath<Inputs, TerminalNumberInput>, _ value: Double?, key: String) -> Double? {
      guard inputs[keyPath: keyPath] != start[keyPath: keyPath] else { return nil }
      if value == nil { clear.append(key) }
      return value
    }

    let sharesOutstanding = optional(\.sharesOutstanding, values.sharesOutstanding, key: "sharesOutstanding")
    let currentSharePrice = optional(\.currentSharePrice, values.currentSharePrice, key: "currentSharePrice")
    var notes: String?
    if inputs.notes != start.notes {
      if let newNotes = values.notes { notes = newNotes } else { clear.append("notes") }
    }

    return TerminalPositionUpdateRequest(
      ticker: values.ticker == original.ticker ? nil : values.ticker,
      sharesOutstanding: sharesOutstanding,
      terminalShareCount: changed(\.terminalShareCount, values.terminalShareCount),
      terminalMarketCap: changed(\.terminalMarketCap, values.terminalMarketCap),
      valueWanted: changed(\.valueWanted, values.valueWanted),
      sharesOwned: changed(\.sharesOwned, values.sharesOwned ?? 0),
      currentSharePrice: currentSharePrice,
      notes: notes,
      clear: clear.isEmpty ? nil : clear
    )
  }

  func save() async -> TerminalPositionResponse? {
    guard canSave else { return nil }
    isSaving = true
    defer { isSaving = false }
    do {
      if let original {
        guard let request = makeUpdateRequest() else { return nil }
        if request == Self.noChanges { return original }
        return try await service.update(id: original.id, request)
      }
      guard let request = makeCreateRequest() else { return nil }
      return try await service.create(request)
    } catch {
      errorMessage = TerminalPositionsErrorText.message(
        for: error,
        fallback: String(localized: "The position could not be saved."),
        notFound: String(localized: "This row was deleted on another device.")
      )
      return nil
    }
  }

  // MARK: - Private

  /// Every field read, the ticker valid and the scenario valid; otherwise nil.
  private func values() -> Values? {
    guard isTickerValid,
          previewResult != nil,
          let shareCount = inputs.terminalShareCount.value(locale: locale),
          let marketCap = inputs.terminalMarketCap.value(locale: locale),
          let valueWanted = inputs.valueWanted.value(locale: locale),
          let sharesOwned = optionalValue(inputs.sharesOwned),
          let sharesOutstanding = optionalValue(inputs.sharesOutstanding),
          let price = optionalValue(inputs.currentSharePrice)
    else { return nil }
    let notes = inputs.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    return Values(
      ticker: normalizedTicker,
      terminalShareCount: shareCount,
      terminalMarketCap: marketCap,
      valueWanted: valueWanted,
      sharesOwned: sharesOwned,
      sharesOutstanding: sharesOutstanding,
      currentSharePrice: price,
      notes: notes.isEmpty ? nil : notes
    )
  }

  /// `.some(nil)` for an empty optional field; nil when it can't be read.
  private func optionalValue(_ input: TerminalNumberInput) -> Double?? {
    switch input.reading(locale: locale) {
    case .empty: .some(nil)
    case let .value(value): .some(value)
    case .invalid, .negative: nil
    }
  }

  private func positiveProblem(_ input: TerminalNumberInput, message: String) -> String? {
    switch input.reading(locale: locale) {
    case .empty: nil
    case .invalid: String(localized: "Enter a number.")
    case .negative: message
    case let .value(value): value > 0 ? nil : message
    }
  }

  private func nonNegativeProblem(_ input: TerminalNumberInput) -> String? {
    switch input.reading(locale: locale) {
    case .empty, .value: nil
    case .invalid: String(localized: "Enter a number.")
    case .negative: String(localized: "Can't be negative.")
    }
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the test command with `TerminalPositionEditorModelTests`.
Expected: 13 tests pass.

- [ ] **Step 5: Commit**

```bash
git add financeplan/Features/TerminalPositions/TerminalPositionEditorModel.swift financeplanTests/TerminalPositionEditorModelTests.swift
git commit -m "feat(terminal): add editor model with live preview and guardrails"
```

---

### Task 8: Editor model — AI fill and scenario suggestion (Pro)

**Files:**
- Modify: `financeplan/Features/TerminalPositions/TerminalPositionEditorModel.swift`
- Test: `financeplanTests/TerminalPositionEditorModelTests.swift` (append)

**Interfaces:**
- Consumes: `service.shareFacts(ticker:)`, `service.suggestScenario(ticker:horizonYears:)`, `TerminalPositionsHTTPClient.Error.upgradeRequired` / `.rejected`.
- Produces on `TerminalPositionEditorModel`: `shareFacts: ShareFactsSuggestion?`, `scenarioSuggestion: TerminalScenarioSuggestion?`, `isFetchingShareFacts`, `isFetchingScenario`, `aiMessage: String?`, `needsUpgrade: Bool`, `fillWithAI() async`, `suggestScenario() async`, `acceptShareFacts()`, `acceptScenario()`, `dismissShareFacts()`, `dismissScenario()`, `shareFactsCurrencyNote: String?`.

- [ ] **Step 1: Write the failing tests** (append inside `TerminalPositionEditorModelTests`)

```swift
  func testFillWithAINeedsATicker() async {
    let service = MockTerminalPositionsService()
    let model = TerminalPositionEditorModel(currency: "USD", service: service, locale: english)

    await model.fillWithAI()

    XCTAssertEqual(model.aiMessage, "Enter a ticker first.")
    XCTAssertTrue(service.shareFactsTickers.isEmpty)
  }

  func testFillWithAIShowsTheSuggestionWithoutTouchingTheForm() async {
    let service = MockTerminalPositionsService()
    let model = filledModel(service)
    let before = model.inputs

    await model.fillWithAI()

    XCTAssertEqual(service.shareFactsTickers, ["AMZN"])
    XCTAssertEqual(model.shareFacts, .fixture())
    XCTAssertEqual(model.inputs, before)
  }

  func testAcceptingShareFactsFillsOnlySharesOutstandingAndPriceAndNeverSaves() async {
    let service = MockTerminalPositionsService()
    let model = filledModel(service)
    let marketCapBefore = model.inputs.terminalMarketCap
    let valueWantedBefore = model.inputs.valueWanted
    await model.fillWithAI()

    model.acceptShareFacts()

    XCTAssertEqual(model.inputs.sharesOutstanding.value(locale: english), 10_600_000_000)
    XCTAssertEqual(model.inputs.currentSharePrice.value(locale: english), 220.5)
    XCTAssertEqual(model.inputs.terminalMarketCap, marketCapBefore)
    XCTAssertEqual(model.inputs.valueWanted, valueWantedBefore)
    XCTAssertNil(model.shareFacts)
    XCTAssertTrue(service.createRequests.isEmpty)
    XCTAssertTrue(service.updateRequests.isEmpty)
  }

  func testAcceptingAScenarioFillsShareCountAndMarketCapOnly() async {
    let service = MockTerminalPositionsService()
    let model = filledModel(service)
    let valueWantedBefore = model.inputs.valueWanted
    await model.suggestScenario()

    model.acceptScenario()

    XCTAssertEqual(service.scenarioTickers, ["AMZN"])
    XCTAssertEqual(model.inputs.terminalShareCount.value(locale: english), 12_000_000_000)
    XCTAssertEqual(model.inputs.terminalMarketCap.value(locale: english), 8_000_000_000_000)
    XCTAssertEqual(model.inputs.valueWanted, valueWantedBefore)
    XCTAssertNil(model.scenarioSuggestion)
    XCTAssertTrue(service.createRequests.isEmpty)
  }

  func testUpgradeRequiredAsksForThePaywall() async {
    let service = MockTerminalPositionsService()
    service.shareFactsResult = .failure(TerminalPositionsHTTPClient.Error.upgradeRequired(feature: "terminal_position_ai"))
    let model = filledModel(service)

    await model.fillWithAI()

    XCTAssertTrue(model.needsUpgrade)
    XCTAssertNil(model.aiMessage)
  }

  func testPlainForbiddenDoesNotAskForThePaywall() async {
    let service = MockTerminalPositionsService()
    service.scenarioResult = .failure(TerminalPositionsHTTPClient.Error.rejected(status: 403, message: "Missing scope"))
    let model = filledModel(service)

    await model.suggestScenario()

    XCTAssertFalse(model.needsUpgrade)
    XCTAssertEqual(model.aiMessage, "The AI lookup failed. Try again.")
  }

  func testAIUnavailableSaysManualEntryStillWorks() async {
    let service = MockTerminalPositionsService()
    service.shareFactsResult = .failure(TerminalPositionsHTTPClient.Error.rejected(status: 503, message: "AI lookup unavailable"))
    let model = filledModel(service)

    await model.fillWithAI()

    XCTAssertEqual(model.aiMessage, "AI lookup is unavailable right now. You can still enter the numbers yourself.")
  }

  func testUnusableAIAnswerIsExplained() async {
    let service = MockTerminalPositionsService()
    service.scenarioResult = .failure(TerminalPositionsHTTPClient.Error.rejected(status: 422, message: "no sources"))
    let model = filledModel(service)

    await model.suggestScenario()

    XCTAssertEqual(model.aiMessage, "The AI couldn't find usable numbers for this ticker.")
  }

  func testCurrencyMismatchIsCalledOut() async {
    let service = MockTerminalPositionsService()
    service.shareFactsResult = .success(.fixture(currency: "eur"))
    let model = filledModel(service)

    await model.fillWithAI()

    XCTAssertEqual(model.shareFactsCurrencyNote, "This price is in EUR; your plan uses USD.")
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the test command with `TerminalPositionEditorModelTests`.
Expected: FAIL to compile with `value of type 'TerminalPositionEditorModel' has no member 'fillWithAI'`.

- [ ] **Step 3: Add the AI state** (next to `var errorMessage: String?`)

```swift
  private(set) var shareFacts: ShareFactsSuggestion?
  private(set) var scenarioSuggestion: TerminalScenarioSuggestion?
  private(set) var isFetchingShareFacts = false
  private(set) var isFetchingScenario = false
  private(set) var aiMessage: String?
  /// Set when the server answers with the Pro gate; the sheet shows the paywall.
  var needsUpgrade = false
```

- [ ] **Step 4: Add the AI actions** (before `// MARK: - Private`)

```swift
  // MARK: - AI (Pro). Suggestions only: Accept fills fields, Save writes.

  func fillWithAI() async {
    guard isTickerValid else {
      aiMessage = String(localized: "Enter a ticker first.")
      return
    }
    aiMessage = nil
    isFetchingShareFacts = true
    defer { isFetchingShareFacts = false }
    do {
      shareFacts = try await service.shareFacts(ticker: normalizedTicker)
    } catch {
      handleAIError(error)
    }
  }

  func suggestScenario() async {
    guard isTickerValid else {
      aiMessage = String(localized: "Enter a ticker first.")
      return
    }
    aiMessage = nil
    isFetchingScenario = true
    defer { isFetchingScenario = false }
    do {
      scenarioSuggestion = try await service.suggestScenario(ticker: normalizedTicker, horizonYears: nil)
    } catch {
      handleAIError(error)
    }
  }

  /// Fills shares outstanding and today's price, never the market cap or the
  /// value wanted, and never saves.
  func acceptShareFacts() {
    guard let facts = shareFacts else { return }
    if let shares = facts.sharesOutstanding {
      inputs.sharesOutstanding = TerminalNumberInput(value: shares, locale: locale)
    }
    if let price = facts.currentSharePrice {
      inputs.currentSharePrice = TerminalNumberInput(value: price, usesUnits: false, locale: locale)
    }
    shareFacts = nil
  }

  /// Fills the future share count and market cap. Never saves.
  func acceptScenario() {
    guard let suggestion = scenarioSuggestion else { return }
    inputs.terminalShareCount = TerminalNumberInput(value: suggestion.terminalShareCount, locale: locale)
    inputs.terminalMarketCap = TerminalNumberInput(value: suggestion.terminalMarketCap, locale: locale)
    scenarioSuggestion = nil
  }

  func dismissShareFacts() { shareFacts = nil }

  func dismissScenario() { scenarioSuggestion = nil }

  /// The lookup can quote a listing in another currency than the plan's.
  var shareFactsCurrencyNote: String? {
    guard let suggested = shareFacts?.currency?.uppercased(), !suggested.isEmpty,
          suggested != currency.uppercased()
    else { return nil }
    let planCurrency = currency.uppercased()
    return String(localized: "This price is in \(suggested); your plan uses \(planCurrency).")
  }

  private func handleAIError(_ error: Error) {
    if TerminalPositionsErrorText.isCancellation(error) { return }
    switch error as? TerminalPositionsHTTPClient.Error {
    case .upgradeRequired?:
      needsUpgrade = true
    case .rejected(status: 503, message: _)?:
      aiMessage = String(localized: "AI lookup is unavailable right now. You can still enter the numbers yourself.")
    case .rejected(status: 422, message: _)?:
      aiMessage = String(localized: "The AI couldn't find usable numbers for this ticker.")
    case .rejected(status: 429, message: _)?:
      aiMessage = String(localized: "Too many AI lookups. Try again in a minute.")
    default:
      aiMessage = String(localized: "The AI lookup failed. Try again.")
    }
  }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the test command with `TerminalPositionEditorModelTests`.
Expected: 22 tests pass.

- [ ] **Step 6: Commit**

```bash
git add financeplan/Features/TerminalPositions/TerminalPositionEditorModel.swift financeplanTests/TerminalPositionEditorModelTests.swift
git commit -m "feat(terminal): AI fill and scenario suggestions in the editor (Pro)"
```

---

### Task 9: Editor sheet UI

**Files:**
- Create: `financeplan/Features/TerminalPositions/TerminalPositionEditorSheet.swift`

**Interfaces:**
- Consumes: `TerminalPositionEditorModel` (Tasks 7–8), `TerminalFormat`/`TerminalCopy`/`TerminalNumberInput` (Task 4), `TerminalPreferences` (Task 5), `Container.billingManager` (`BillingManager.isPro`), `PaywallView(billingManager:)`.
- Produces:
  - `enum TerminalEditorTarget: Identifiable { case new(ticker: String?); case edit(TerminalPositionResponse); var position: TerminalPositionResponse?; var ticker: String? }`
  - `struct TerminalPositionEditorSheet: View` with `init(target: TerminalEditorTarget, currency: String, onSaved: @escaping (TerminalPositionResponse) -> Void)`
  - `struct TerminalNumberInputField: View` (`title: LocalizedStringKey`, `@Binding input: TerminalNumberInput`, `showsUnit: Bool = false`, `problem: String? = nil`)
  - `struct TerminalSourcesList: View` (`sources: [String]`)

The model behind this sheet is fully tested. This task's check is a green build plus a simulator pass.

- [ ] **Step 1: Write the sheet**

```swift
// financeplan/Features/TerminalPositions/TerminalPositionEditorSheet.swift
import Factory
import StockPlanShared
import SwiftUI

enum TerminalEditorTarget: Identifiable {
  case new(ticker: String?)
  case edit(TerminalPositionResponse)

  var id: String {
    switch self {
    case let .new(ticker): "new-\(ticker ?? "")"
    case let .edit(position): position.id
    }
  }

  var position: TerminalPositionResponse? {
    if case let .edit(position) = self { return position }
    return nil
  }

  var ticker: String? {
    if case let .new(ticker) = self { return ticker }
    return nil
  }
}

/// A number field with an optional K/M/B/T unit menu. Built on `TerminalNumberInput`
/// (MoneyInputParser underneath) rather than `FormTextField`, whose formatter
/// rejects the comma a pt-PT keypad types.
struct TerminalNumberInputField: View {
  let title: LocalizedStringKey
  @Binding var input: TerminalNumberInput
  var showsUnit = false
  var problem: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        TextField(text: $input.text, prompt: Text(verbatim: "0")) { Text(title) }
          .keyboardType(.decimalPad)
          .monospacedDigit()
        if showsUnit {
          Picker(selection: $input.unit) {
            ForEach(TerminalUnit.allCases) { unit in
              Text(verbatim: unit.symbol).tag(unit)
            }
          } label: {
            Text("Unit")
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .fixedSize()
        }
      }
      if let problem {
        Text(problem)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }
}

struct TerminalSourcesList: View {
  let sources: [String]

  var body: some View {
    if !sources.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("Sources")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        ForEach(sources, id: \.self) { source in
          if let url = URL(string: source), url.scheme == "https" {
            Link(url.host() ?? source, destination: url)
              .font(.caption)
          } else {
            Text(verbatim: source)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }
}

struct TerminalPositionEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  @InjectedObservable(\Container.billingManager) private var billingManager
  @AppStorage(TerminalPreferences.roundDownKey) private var roundDown = false
  @State private var model: TerminalPositionEditorModel
  @State private var isPaywallPresented = false
  private let onSaved: (TerminalPositionResponse) -> Void

  init(target: TerminalEditorTarget, currency: String, onSaved: @escaping (TerminalPositionResponse) -> Void) {
    _model = State(initialValue: TerminalPositionEditorModel(
      position: target.position,
      ticker: target.ticker,
      currency: currency,
      service: Container.shared.terminalPositionsService()
    ))
    self.onSaved = onSaved
  }

  var body: some View {
    NavigationStack {
      Form {
        tickerSection
        scenarioSection
        holdingSection
        previewSection
        aiSection
        Section("Notes") {
          TextField("Why this scenario?", text: $model.inputs.notes, axis: .vertical)
            .lineLimit(2...6)
        }
      }
      .navigationTitle(model.isEditing ? LocalizedStringKey("Edit position") : LocalizedStringKey("New position"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: dismiss.callAsFunction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { Task { await save() } }
            .disabled(!model.canSave)
        }
      }
      .alert("Terminal position sizing", isPresented: errorBinding) {
        Button("OK", role: .cancel) { model.errorMessage = nil }
      } message: {
        Text(model.errorMessage ?? "")
      }
      .sheet(isPresented: $isPaywallPresented) {
        PaywallView(billingManager: billingManager)
      }
      .onChange(of: model.needsUpgrade) { _, needsUpgrade in
        guard needsUpgrade else { return }
        model.needsUpgrade = false
        isPaywallPresented = true
      }
    }
  }

  private var errorBinding: Binding<Bool> {
    Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
  }

  private var tickerSection: some View {
    Section {
      TextField("Ticker", text: $model.inputs.ticker)
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
      if let problem = model.problem(for: .ticker) {
        problemText(problem)
      }
    } header: {
      Text("Company")
    }
  }

  private var scenarioSection: some View {
    Section {
      TerminalNumberInputField(
        title: "Future share count",
        input: $model.inputs.terminalShareCount,
        showsUnit: true,
        problem: model.problem(for: .terminalShareCount)
      )
      TerminalNumberInputField(
        title: "Future market cap",
        input: $model.inputs.terminalMarketCap,
        showsUnit: true,
        problem: model.problem(for: .terminalMarketCap)
      )
      TerminalNumberInputField(
        title: "Value wanted",
        input: $model.inputs.valueWanted,
        showsUnit: true,
        problem: model.problem(for: .valueWanted)
      )
    } header: {
      Text("Your scenario")
    } footer: {
      Text("K, M, B and T are thousands, millions, billions and trillions.")
    }
  }

  private var holdingSection: some View {
    Section {
      TerminalNumberInputField(
        title: "Shares owned",
        input: $model.inputs.sharesOwned,
        problem: model.problem(for: .sharesOwned)
      )
      TerminalNumberInputField(
        title: "Today's share price (optional)",
        input: $model.inputs.currentSharePrice,
        problem: model.problem(for: .currentSharePrice)
      )
      TerminalNumberInputField(
        title: "Shares outstanding today (optional)",
        input: $model.inputs.sharesOutstanding,
        showsUnit: true,
        problem: model.problem(for: .sharesOutstanding)
      )
    } header: {
      Text("Where you are now")
    }
  }

  private var previewSection: some View {
    Section {
      if let result = model.previewResult {
        LabeledContent("Terminal share price") {
          Text(TerminalFormat.price(result.terminalSharePrice, currency: model.currency))
        }
        LabeledContent("Shares needed") {
          Text(TerminalFormat.shares(result.sharesNeeded, roundDown: roundDown))
        }
        LabeledContent("Progress") {
          Text(TerminalFormat.progress(result.progress))
        }
        ProgressView(value: min(max(result.progress, 0), 1))
        LabeledContent("Still needed") {
          Text(TerminalFormat.shares(result.sharesStillNeeded, roundDown: roundDown))
        }
        LabeledContent("Gap at terminal price") {
          Text(TerminalFormat.money(result.gapValueAtTerminal, currency: model.currency))
        }
        if let capital = result.capitalAtTodayPrice {
          LabeledContent("Cost at today's price") {
            Text(TerminalFormat.money(capital, currency: model.currency))
          }
        }
        Toggle("Round down to whole shares", isOn: $roundDown)
      } else if case let .failure(error)? = model.preview {
        problemText(TerminalPositionEditorModel.text(for: error))
      } else {
        Text("Enter share count, market cap and value wanted to see the result.")
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Result")
    } footer: {
      Text(TerminalCopy.disclaimer)
    }
  }

  private var aiSection: some View {
    Section {
      if billingManager.isPro {
        aiButtons
      } else {
        Button {
          isPaywallPresented = true
        } label: {
          Label("Unlock AI fill with Pro", systemImage: "lock.fill")
        }
      }
      if let message = model.aiMessage {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      if let facts = model.shareFacts {
        shareFactsCard(facts)
      }
      if let suggestion = model.scenarioSuggestion {
        scenarioCard(suggestion)
      }
    } header: {
      Text("AI assist")
    } footer: {
      Text("Suggestions come with sources and are never saved until you tap Save.")
    }
  }

  private var aiButtons: some View {
    HStack {
      Button {
        Task { await model.fillWithAI() }
      } label: {
        Label("Fill with AI", systemImage: "sparkles")
      }
      .disabled(model.isFetchingShareFacts)
      Spacer()
      Button {
        Task { await model.suggestScenario() }
      } label: {
        Label("Suggest scenario", systemImage: "wand.and.stars")
      }
      .disabled(model.isFetchingScenario)
    }
    .buttonStyle(.bordered)
    .overlay {
      if model.isFetchingShareFacts || model.isFetchingScenario {
        ProgressView()
      }
    }
  }

  private func shareFactsCard(_ facts: ShareFactsSuggestion) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("AI suggestion")
        .font(.subheadline.weight(.semibold))
      if let shares = facts.sharesOutstanding {
        LabeledContent("Shares outstanding") { Text(TerminalFormat.count(shares)) }
      }
      if let price = facts.currentSharePrice {
        LabeledContent("Share price") {
          Text(TerminalFormat.price(price, currency: facts.currency ?? model.currency))
        }
      }
      if let asOf = facts.asOf {
        Text("As of \(asOf)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let note = model.shareFactsCurrencyNote {
        Text(note)
          .font(.caption)
          .foregroundStyle(.orange)
      }
      TerminalSourcesList(sources: facts.sources)
      HStack {
        Button("Accept") { model.acceptShareFacts() }
          .buttonStyle(.borderedProminent)
        Button("Dismiss") { model.dismissShareFacts() }
          .buttonStyle(.bordered)
      }
    }
  }

  private func scenarioCard(_ suggestion: TerminalScenarioSuggestion) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("AI scenario")
        .font(.subheadline.weight(.semibold))
      LabeledContent("Future share count") { Text(TerminalFormat.count(suggestion.terminalShareCount)) }
      LabeledContent("Future market cap") {
        Text(TerminalFormat.money(suggestion.terminalMarketCap, currency: model.currency))
      }
      Text("Horizon: \(suggestion.horizonYears) years")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(verbatim: suggestion.rationale)
        .font(.footnote)
      TerminalSourcesList(sources: suggestion.sources)
      HStack {
        Button("Accept") { model.acceptScenario() }
          .buttonStyle(.borderedProminent)
        Button("Dismiss") { model.dismissScenario() }
          .buttonStyle(.bordered)
      }
    }
  }

  private func problemText(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.red)
  }

  private func save() async {
    guard let saved = await model.save() else { return }
    onSaved(saved)
    dismiss()
  }
}
```

- [ ] **Step 2: Build**

Run: `make ios-build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Re-run the editor model suite (no regressions)**

Run the test command with `TerminalPositionEditorModelTests`.
Expected: 22 tests pass.

- [ ] **Step 4: Commit**

```bash
git add financeplan/Features/TerminalPositions/TerminalPositionEditorSheet.swift
git commit -m "feat(terminal): add terminal position editor sheet"
```

---

### Task 10: Positions screen, row, and the Planning menu route

**Files:**
- Create: `financeplan/Features/TerminalPositions/TerminalPositionsScreen.swift`
- Modify: `financeplan/Features/Portfolio/PortfolioRoot.swift:8-18` (enum), `:37-61` (destination), `:111-120` (Planning menu)

**Interfaces:**
- Consumes: `TerminalPositionsViewModel` (Tasks 5–6), `TerminalPositionEditorSheet` / `TerminalEditorTarget` (Task 9), `TerminalFormat` / `TerminalCopy` (Task 4).
- Produces: `struct TerminalPositionsScreen: View` (no init arguments; pushed onto an existing `NavigationStack`), `struct TerminalPositionRow: View` (`position`, `currency`, `roundDown`), and `PortfolioRootRoute.terminalPositions`.

- [ ] **Step 1: Write the screen**

```swift
// financeplan/Features/TerminalPositions/TerminalPositionsScreen.swift
import Factory
import StockPlanShared
import SwiftUI

struct TerminalPositionsScreen: View {
  @State private var model = TerminalPositionsViewModel(service: Container.shared.terminalPositionsService())
  @AppStorage(TerminalPreferences.roundDownKey) private var roundDown = false
  @State private var editorTarget: TerminalEditorTarget?

  var body: some View {
    List {
      headerSection
      if model.positions.isEmpty {
        if model.showsSample {
          sampleSection
        } else if model.hasLoaded {
          Section {
            Text("No positions yet. Tap + to add your first scenario.")
              .foregroundStyle(.secondary)
          }
        }
      } else {
        positionsSection
        totalsSection
      }
    }
    .vigilListChrome()
    .vigilScreenBackground()
    .navigationTitle("Terminal positions")
    .vigilInlineNavigationBar()
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        if model.positions.count > 1 {
          EditButton()
        }
        Button("Add position", systemImage: "plus") { editorTarget = .new(ticker: nil) }
      }
    }
    .overlay {
      if model.isLoading && !model.hasLoaded {
        ProgressView()
      }
    }
    .task { await model.load() }
    .refreshable { await model.load() }
    .sheet(item: $editorTarget) { target in
      TerminalPositionEditorSheet(target: target, currency: model.currency) { model.saved($0) }
    }
    .alert("Terminal position sizing", isPresented: errorBinding) {
      Button("OK", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  private var errorBinding: Binding<Bool> {
    Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
  }

  private var headerSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 6) {
        Text("Terminal position sizing")
          .font(.title2.bold())
        Text("Decide the future market cap and share count. Norviq tells you how many shares that target is.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Toggle("Round down to whole shares", isOn: $roundDown)
    } footer: {
      Text(TerminalCopy.disclaimer)
    }
  }

  private var positionsSection: some View {
    Section {
      ForEach(model.positions) { position in
        Button {
          editorTarget = .edit(position)
        } label: {
          TerminalPositionRow(position: position, currency: model.currency, roundDown: roundDown)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
          Button("Delete", role: .destructive) {
            Task { await model.delete(position) }
          }
        }
        .swipeActions(edge: .leading) {
          Button("Duplicate", systemImage: "plus.square.on.square") {
            Task { await model.duplicate(position) }
          }
          .tint(.blue)
        }
      }
      .onMove { source, destination in
        _ = model.move(fromOffsets: source, toOffset: destination)
      }
    } header: {
      Text("Positions")
    }
  }

  private var totalsSection: some View {
    let totals = model.totals
    return Section {
      LabeledContent("Total value wanted") {
        Text(TerminalFormat.money(totals.valueWanted, currency: model.currency)).monospacedDigit()
      }
      LabeledContent("Still needed at terminal prices") {
        Text(TerminalFormat.money(totals.gapValueAtTerminal, currency: model.currency)).monospacedDigit()
      }
      if let capital = totals.capitalAtTodayPrice {
        LabeledContent("Capital at today's prices") {
          Text(TerminalFormat.money(capital, currency: model.currency)).monospacedDigit()
        }
      }
    } header: {
      Text("Totals")
    }
  }

  private var sampleSection: some View {
    Section {
      if let preview = TerminalPositionsViewModel.samplePreview {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(verbatim: TerminalPositionsViewModel.sampleRequest.ticker)
              .font(.headline)
            Text("Sample")
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 8)
              .padding(.vertical, 2)
              .background(.secondary.opacity(0.15), in: Capsule())
            Spacer()
            Text(TerminalFormat.price(preview.terminalSharePrice, currency: model.currency))
              .font(.headline.monospacedDigit())
          }
          LabeledContent("Shares needed") {
            Text(TerminalFormat.shares(preview.sharesNeeded, roundDown: roundDown))
          }
        }
      }
      HStack {
        Button("Use AMZN sample") { Task { await model.useSample() } }
          .buttonStyle(.borderedProminent)
        Button("Dismiss") { model.dismissSample() }
          .buttonStyle(.bordered)
      }
    } header: {
      Text("Get started")
    }
  }
}

/// Terminal share price and shares needed come first; they are the answer.
struct TerminalPositionRow: View {
  let position: TerminalPositionResponse
  let currency: String
  let roundDown: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: position.ticker)
          .font(.headline)
        Spacer()
        if let price = position.terminalSharePrice {
          Text(TerminalFormat.price(price, currency: currency))
            .font(.headline.monospacedDigit())
        }
      }
      if let error = position.scenarioError {
        Label(TerminalPositionEditorModel.text(forRaw: error), systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      } else if let needed = position.sharesNeeded {
        LabeledContent("Shares needed") {
          Text(TerminalFormat.shares(needed, roundDown: roundDown)).monospacedDigit()
        }
        .font(.subheadline)
        ProgressView(value: min(max(position.progress ?? 0, 0), 1))
        HStack {
          Text(TerminalFormat.progress(position.progress ?? 0))
          Spacer()
          if let still = position.sharesStillNeeded, still > 0 {
            Text("Still needed: \(TerminalFormat.shares(still, roundDown: roundDown))")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}
```

- [ ] **Step 2: Add the route.** In `financeplan/Features/Portfolio/PortfolioRoot.swift`, replace

```swift
  case rebalancingRules
  case notifications
}
```

with

```swift
  case rebalancingRules
  case notifications
  case terminalPositions
}
```

- [ ] **Step 3: Add the destination.** Replace

```swift
        case .notifications:
          NotificationInboxScreen()
        }
```

with

```swift
        case .notifications:
          NotificationInboxScreen()
        // Free, like Grow and Retire: only the AI suggestions inside are Pro.
        case .terminalPositions:
          TerminalPositionsScreen()
        }
```

- [ ] **Step 4: Add the Planning menu item.** Replace

```swift
            NavigationLink(value: PortfolioRootRoute.retire) {
              Label("Retire", systemImage: "beach.umbrella")
            }
          }
          .accessibilityLabel("Open planning")
```

with

```swift
            NavigationLink(value: PortfolioRootRoute.retire) {
              Label("Retire", systemImage: "beach.umbrella")
            }
            NavigationLink(value: PortfolioRootRoute.terminalPositions) {
              Label("Terminal position sizing", systemImage: "scope")
            }
          }
          .accessibilityLabel("Open planning")
```

- [ ] **Step 5: Build and run the view model suite**

Run: `make ios-build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head -20`, then the test command with `TerminalPositionsViewModelTests`.
Expected: `** BUILD SUCCEEDED **`; 17 tests pass.

- [ ] **Step 6: Simulator check (against staging)**

Launch the app in the iPhone 17 simulator against the staging environment, once the backend's staging deploy serves `/v1/terminal-positions`. Go to Portfolio → Planning (target icon) → Terminal position sizing, then:
- The empty state shows the AMZN sample at $909.09 and 1,100 shares. "Use AMZN sample" creates the row, and "Dismiss" hides the sample for good.
- Edit the AMZN row and set Shares owned to 750: progress shows 68.18% and "Still needed: 350".
- Swipe right to duplicate (the copy lands under the source). Swipe left to delete. Long-press and drag, or use Edit, to reorder, then pull to refresh: the order holds.
- Set the future share count to 0: the row shows "Share count must be above zero." and Save is disabled.

- [ ] **Step 7: Commit**

```bash
git add financeplan/Features/TerminalPositions/TerminalPositionsScreen.swift financeplan/Features/Portfolio/PortfolioRoot.swift
git commit -m "feat(terminal): add terminal positions screen and Planning menu route"
```

---

### Task 11: Autobuy editor model and autobuy list actions

**Files:**
- Create: `financeplan/Features/TerminalPositions/AutobuyEditorModel.swift`
- Modify: `financeplan/Features/TerminalPositions/TerminalPositionsViewModel.swift` (add `deleteAutobuy`)
- Test: `financeplanTests/AutobuyEditorModelTests.swift`

**Interfaces:**
- Consumes: `TerminalNumberInput` (Task 4), `AutobuyMath.monthlyEquivalent`, `TerminalPositionsServicing.createAutobuy/updateAutobuy/deleteAutobuy`, `TerminalPositionsErrorText`.
- Produces:
  - `extension AutobuyCadence { var title: String }`
  - `@MainActor @Observable final class AutobuyEditorModel` with `init(autobuy: AutobuyResponse? = nil, currency: String, service: any TerminalPositionsServicing, locale: Locale = .current)`, `struct Inputs: Equatable { label, ticker: String; amount: TerminalNumberInput; cadence: AutobuyCadence; percent: TerminalNumberInput; active: Bool }`, `static let cadences: [AutobuyCadence]`, `inputs`, `original`, `currency`, `isEditing`, `isPercentCadence`, `percentFraction`, `monthlyEquivalent`, `tickerProblem`, `amountProblem`, `percentProblem`, `canSave`, `makeCreateRequest()`, `makeUpdateRequest()`, `save() async -> AutobuyResponse?`, `isSaving`, `errorMessage`.
  - `TerminalPositionsViewModel.deleteAutobuy(_ autobuy: AutobuyResponse) async`

- [ ] **Step 1: Write the failing tests**

```swift
// financeplanTests/AutobuyEditorModelTests.swift
import Foundation
import StockPlanShared
import XCTest
@testable import financeplan

@MainActor
final class AutobuyEditorModelTests: XCTestCase {
  private let english = Locale(identifier: "en_US")

  private func newModel(_ service: MockTerminalPositionsService = MockTerminalPositionsService()) -> AutobuyEditorModel {
    let model = AutobuyEditorModel(currency: "USD", service: service, locale: english)
    model.inputs.label = "Weekly AMZN"
    return model
  }

  func testWeeklyPreviewUsesTheSharedMonthlyEquivalent() async {
    let model = newModel()
    model.inputs.cadence = .weekly
    model.inputs.amount = TerminalNumberInput(text: "50")

    XCTAssertEqual(model.monthlyEquivalent ?? 0, 50 * 52 / 12, accuracy: 0.000001)
    XCTAssertTrue(model.canSave)
  }

  func testBimonthlyIsEveryTwoMonths() async {
    let model = newModel()
    model.inputs.cadence = .bimonthly
    model.inputs.amount = TerminalNumberInput(text: "275")

    XCTAssertEqual(model.monthlyEquivalent ?? 0, 275 * 6 / 12, accuracy: 0.000001)
  }

  func testPercentCadenceNeedsAPercentAndUsesTheMonthlyBase() async {
    let service = MockTerminalPositionsService()
    let model = newModel(service)
    model.inputs.cadence = .percentOfContribution
    model.inputs.amount = TerminalNumberInput(text: "5000")

    XCTAssertFalse(model.canSave)
    XCTAssertNil(model.percentProblem, "an empty percent is not an error yet, just not saveable")

    model.inputs.percent = TerminalNumberInput(text: "4")
    XCTAssertEqual(model.monthlyEquivalent ?? 0, 200, accuracy: 0.000001)
    XCTAssertTrue(model.canSave)

    _ = await model.save()
    XCTAssertEqual(service.createAutobuyRequests, [AutobuyCreateRequest(
      ticker: nil, label: "Weekly AMZN", amount: 5_000, cadence: .percentOfContribution, percent: 0.04, active: true
    )])
  }

  func testPercentAboveOneHundredIsRefused() async {
    let model = newModel()
    model.inputs.cadence = .percentOfContribution
    model.inputs.amount = TerminalNumberInput(text: "5000")
    model.inputs.percent = TerminalNumberInput(text: "150")

    XCTAssertEqual(model.percentProblem, "Enter a percent between 0 and 100.")
    XCTAssertFalse(model.canSave)
  }

  func testNoMonthlyBaseMeansNoMonthlyEquivalent() async {
    let model = newModel()
    model.inputs.cadence = .percentOfContribution
    model.inputs.amount = TerminalNumberInput(text: "0")
    model.inputs.percent = TerminalNumberInput(text: "4")

    XCTAssertNil(model.monthlyEquivalent)
  }

  func testLabelIsRequiredAndNegativeAmountsAreRefused() async {
    let model = AutobuyEditorModel(currency: "USD", service: MockTerminalPositionsService(), locale: english)
    model.inputs.amount = TerminalNumberInput(text: "50")
    XCTAssertFalse(model.canSave)

    model.inputs.label = "DCA"
    model.inputs.amount = TerminalNumberInput(text: "-50")
    XCTAssertEqual(model.amountProblem, "Can't be negative.")
    XCTAssertFalse(model.canSave)
  }

  func testCreateUppercasesTheTickerAndLeavesAnEmptyOneOut() async {
    let service = MockTerminalPositionsService()
    let model = newModel(service)
    model.inputs.ticker = " amzn "
    model.inputs.amount = TerminalNumberInput(text: "50")
    model.inputs.cadence = .weekly

    _ = await model.save()

    XCTAssertEqual(service.createAutobuyRequests.first?.ticker, "AMZN")
    XCTAssertNil(service.createAutobuyRequests.first?.percent)
  }

  func testSwitchingAwayFromPercentClearsIt() async {
    let service = MockTerminalPositionsService()
    let model = AutobuyEditorModel(autobuy: .fixture(), currency: "USD", service: service, locale: english)
    model.inputs.cadence = .monthly

    _ = await model.save()

    XCTAssertEqual(service.updateAutobuyIds, ["a1"])
    XCTAssertEqual(service.updateAutobuyRequests, [AutobuyUpdateRequest(
      ticker: nil, label: nil, amount: nil, cadence: .monthly, percent: nil, active: nil, clear: ["percent"]
    )])
  }

  func testEmptyingTheTickerClearsIt() async {
    let service = MockTerminalPositionsService()
    let model = AutobuyEditorModel(
      autobuy: .fixture(ticker: "VOO", amount: 50, cadence: .weekly, percent: nil),
      currency: "USD", service: service, locale: english
    )
    model.inputs.ticker = ""

    _ = await model.save()

    XCTAssertEqual(service.updateAutobuyRequests, [AutobuyUpdateRequest(
      ticker: nil, label: nil, amount: nil, cadence: nil, percent: nil, active: nil, clear: ["ticker"]
    )])
  }

  func testUnchangedAutobuySavesWithoutARequest() async {
    let service = MockTerminalPositionsService()
    let autobuy = AutobuyResponse.fixture()
    let model = AutobuyEditorModel(autobuy: autobuy, currency: "USD", service: service, locale: english)

    let saved = await model.save()

    XCTAssertEqual(saved, autobuy)
    XCTAssertTrue(service.updateAutobuyRequests.isEmpty)
  }

  func testDeletingAnAutobuyReloadsTheTotal() async {
    let service = MockTerminalPositionsService()
    service.autobuysResult = .success(.fixture([.fixture(id: "a1"), .fixture(id: "a2", amount: 50, cadence: .weekly, percent: nil)]))
    let model = TerminalPositionsViewModel(
      service: service,
      defaults: UserDefaults(suiteName: "AutobuyEditorModelTests-\(UUID().uuidString)")!
    )
    await model.load()
    service.autobuysResult = .success(.fixture([.fixture(id: "a2", amount: 50, cadence: .weekly, percent: nil)]))

    await model.deleteAutobuy(model.autobuys[0])

    XCTAssertEqual(service.deletedAutobuyIds, ["a1"])
    XCTAssertEqual(model.autobuys.map(\.id), ["a2"])
    XCTAssertEqual(model.monthlyAutobuyTotal, 50 * 52 / 12, accuracy: 0.000001)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the test command with `AutobuyEditorModelTests`.
Expected: FAIL to compile with `cannot find 'AutobuyEditorModel' in scope`.

- [ ] **Step 3: Write the autobuy editor model**

```swift
// financeplan/Features/TerminalPositions/AutobuyEditorModel.swift
import Foundation
import Observation
import StockPlanShared

extension AutobuyCadence {
  var title: String {
    switch self {
    case .weekly: String(localized: "Weekly")
    case .biweekly: String(localized: "Every two weeks")
    case .bimonthly: String(localized: "Every two months")
    case .monthly: String(localized: "Monthly")
    case .percentOfContribution: String(localized: "Percent of a monthly base")
    case .unknown: String(localized: "Other")
    }
  }
}

@MainActor @Observable
final class AutobuyEditorModel {
  struct Inputs: Equatable {
    var label: String
    var ticker: String
    /// For percent cadence this is the monthly base the percent applies to.
    var amount: TerminalNumberInput
    var cadence: AutobuyCadence
    /// Typed as 0–100; sent as 0–1.
    var percent: TerminalNumberInput
    var active: Bool
  }

  /// `.unknown` is a decoding fallback, never a choice.
  static let cadences: [AutobuyCadence] = [.weekly, .biweekly, .bimonthly, .monthly, .percentOfContribution]

  private static let noChanges = AutobuyUpdateRequest(
    ticker: nil, label: nil, amount: nil, cadence: nil, percent: nil, active: nil, clear: nil
  )

  let original: AutobuyResponse?
  let currency: String
  var inputs: Inputs
  var isSaving = false
  var errorMessage: String?

  private let initialInputs: Inputs
  private let service: any TerminalPositionsServicing
  private let locale: Locale

  init(
    autobuy: AutobuyResponse? = nil,
    currency: String,
    service: any TerminalPositionsServicing,
    locale: Locale = .current
  ) {
    original = autobuy
    self.currency = currency
    self.service = service
    self.locale = locale
    let inputs = Inputs(
      label: autobuy?.label ?? "",
      ticker: autobuy?.ticker ?? "",
      amount: TerminalNumberInput(value: autobuy?.amount, usesUnits: false, locale: locale),
      cadence: autobuy?.cadence ?? .monthly,
      percent: TerminalNumberInput(value: autobuy?.percent.map { $0 * 100 }, usesUnits: false, locale: locale),
      active: autobuy?.active ?? true
    )
    self.inputs = inputs
    initialInputs = inputs
  }

  var isEditing: Bool { original != nil }

  var isPercentCadence: Bool { inputs.cadence == .percentOfContribution }

  var percentFraction: Double? {
    guard let percent = inputs.percent.value(locale: locale), percent <= 100 else { return nil }
    return percent / 100
  }

  var monthlyEquivalent: Double? {
    guard let amount = inputs.amount.value(locale: locale) else { return nil }
    return AutobuyMath.monthlyEquivalent(
      amount: amount,
      cadence: inputs.cadence,
      percent: isPercentCadence ? percentFraction : nil
    )
  }

  private var trimmedLabel: String { inputs.label.trimmingCharacters(in: .whitespacesAndNewlines) }

  private var normalizedTicker: String? {
    let ticker = inputs.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return ticker.isEmpty ? nil : ticker
  }

  var tickerProblem: String? {
    guard let ticker = normalizedTicker else { return nil }
    return ticker.range(of: #"^[A-Z0-9.\-]{1,12}$"#, options: .regularExpression) == nil
      ? String(localized: "Use 1–12 letters, digits, dots or dashes.")
      : nil
  }

  var amountProblem: String? {
    switch inputs.amount.reading(locale: locale) {
    case .empty, .value: nil
    case .invalid: String(localized: "Enter a number.")
    case .negative: String(localized: "Can't be negative.")
    }
  }

  var percentProblem: String? {
    guard isPercentCadence else { return nil }
    switch inputs.percent.reading(locale: locale) {
    case .empty: return nil
    case .invalid, .negative: return String(localized: "Enter a percent between 0 and 100.")
    case let .value(percent): return percent <= 100 ? nil : String(localized: "Enter a percent between 0 and 100.")
    }
  }

  var canSave: Bool {
    !isSaving
      && !trimmedLabel.isEmpty
      && tickerProblem == nil
      && inputs.amount.value(locale: locale) != nil
      && (!isPercentCadence || percentFraction != nil)
  }

  func makeCreateRequest() -> AutobuyCreateRequest? {
    guard canSave, let amount = inputs.amount.value(locale: locale) else { return nil }
    return AutobuyCreateRequest(
      ticker: normalizedTicker,
      label: trimmedLabel,
      amount: amount,
      cadence: inputs.cadence,
      percent: isPercentCadence ? percentFraction : nil,
      active: inputs.active
    )
  }

  /// Only the fields the user touched. A cleared ticker goes in `clear`, and so
  /// does a percent left behind when the cadence moves away from percent.
  func makeUpdateRequest() -> AutobuyUpdateRequest? {
    guard let original, canSave, let amount = inputs.amount.value(locale: locale) else { return nil }
    let start = initialInputs
    var clear: [String] = []

    var ticker: String?
    if inputs.ticker != start.ticker {
      if let newTicker = normalizedTicker { ticker = newTicker } else { clear.append("ticker") }
    }

    var percent: Double?
    if isPercentCadence {
      if inputs.percent != start.percent || inputs.cadence != start.cadence { percent = percentFraction }
    } else if original.percent != nil {
      clear.append("percent")
    }

    return AutobuyUpdateRequest(
      ticker: ticker,
      label: trimmedLabel == original.label ? nil : trimmedLabel,
      amount: inputs.amount == start.amount ? nil : amount,
      cadence: inputs.cadence == start.cadence ? nil : inputs.cadence,
      percent: percent,
      active: inputs.active == start.active ? nil : inputs.active,
      clear: clear.isEmpty ? nil : clear
    )
  }

  func save() async -> AutobuyResponse? {
    guard canSave else { return nil }
    isSaving = true
    defer { isSaving = false }
    do {
      if let original {
        guard let request = makeUpdateRequest() else { return nil }
        if request == Self.noChanges { return original }
        return try await service.updateAutobuy(id: original.id, request)
      }
      guard let request = makeCreateRequest() else { return nil }
      return try await service.createAutobuy(request)
    } catch {
      errorMessage = TerminalPositionsErrorText.message(
        for: error,
        fallback: String(localized: "The autobuy could not be saved."),
        notFound: String(localized: "This autobuy was deleted on another device.")
      )
      return nil
    }
  }
}
```

- [ ] **Step 4: Add `deleteAutobuy`** to `TerminalPositionsViewModel` (after `reloadAutobuys()`)

```swift
  func deleteAutobuy(_ autobuy: AutobuyResponse) async {
    do {
      try await service.deleteAutobuy(id: autobuy.id)
      await reloadAutobuys()
    } catch {
      if case .rejected(status: 404, message: _)? = error as? TerminalPositionsHTTPClient.Error {
        await reloadAutobuys()
        return
      }
      show(error, fallback: String(localized: "The autobuy could not be deleted."))
    }
  }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the test command with `AutobuyEditorModelTests`.
Expected: 11 tests pass.

- [ ] **Step 6: Commit**

```bash
git add financeplan/Features/TerminalPositions/AutobuyEditorModel.swift financeplan/Features/TerminalPositions/TerminalPositionsViewModel.swift financeplanTests/AutobuyEditorModelTests.swift
git commit -m "feat(terminal): add autobuy editor model with monthly equivalents"
```

---

### Task 12: Autobuys UI on the screen

**Files:**
- Create: `financeplan/Features/TerminalPositions/AutobuyEditorSheet.swift`
- Modify: `financeplan/Features/TerminalPositions/TerminalPositionsScreen.swift`

**Interfaces:**
- Consumes: `AutobuyEditorModel` / `AutobuyCadence.title` (Task 11), `TerminalPositionsViewModel.autobuys`, `.monthlyAutobuyTotal`, `.reloadAutobuys()`, `.deleteAutobuy(_:)`, `TerminalNumberInputField` (Task 9).
- Produces: `enum AutobuyEditorTarget: Identifiable { case new; case edit(AutobuyResponse); var autobuy: AutobuyResponse? }`, `struct AutobuyEditorSheet: View` (`init(target:currency:onSaved:)`), `struct TerminalAutobuysSection: View` (`model`, `onEdit`, `onAdd`), `struct AutobuyRow: View`.

- [ ] **Step 1: Write the autobuy UI**

```swift
// financeplan/Features/TerminalPositions/AutobuyEditorSheet.swift
import Factory
import StockPlanShared
import SwiftUI

enum AutobuyEditorTarget: Identifiable {
  case new
  case edit(AutobuyResponse)

  var id: String {
    switch self {
    case .new: "new"
    case let .edit(autobuy): autobuy.id
    }
  }

  var autobuy: AutobuyResponse? {
    if case let .edit(autobuy) = self { return autobuy }
    return nil
  }
}

struct AutobuyEditorSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: AutobuyEditorModel
  private let onSaved: (AutobuyResponse) -> Void

  init(target: AutobuyEditorTarget, currency: String, onSaved: @escaping (AutobuyResponse) -> Void) {
    _model = State(initialValue: AutobuyEditorModel(
      autobuy: target.autobuy,
      currency: currency,
      service: Container.shared.terminalPositionsService()
    ))
    self.onSaved = onSaved
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Label", text: $model.inputs.label, prompt: Text("e.g. 401k contribution"))
          TextField("Ticker (optional)", text: $model.inputs.ticker)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
          if let problem = model.tickerProblem {
            Text(problem).font(.caption).foregroundStyle(.red)
          }
          Toggle("Active", isOn: $model.inputs.active)
        }
        Section {
          Picker("Cadence", selection: $model.inputs.cadence) {
            ForEach(AutobuyEditorModel.cadences, id: \.self) { cadence in
              Text(cadence.title).tag(cadence)
            }
          }
          TerminalNumberInputField(
            title: model.isPercentCadence ? "Monthly base" : "Amount",
            input: $model.inputs.amount,
            problem: model.amountProblem
          )
          if model.isPercentCadence {
            TerminalNumberInputField(
              title: "Percent",
              input: $model.inputs.percent,
              problem: model.percentProblem
            )
          }
        } footer: {
          if let monthly = model.monthlyEquivalent {
            Text("Monthly equivalent: \(TerminalFormat.money(monthly, currency: model.currency))")
          }
        }
      }
      .navigationTitle(model.isEditing ? LocalizedStringKey("Edit autobuy") : LocalizedStringKey("New autobuy"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: dismiss.callAsFunction)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { Task { await save() } }
            .disabled(!model.canSave)
        }
      }
      .alert("Autobuys", isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )) {
        Button("OK", role: .cancel) { model.errorMessage = nil }
      } message: {
        Text(model.errorMessage ?? "")
      }
    }
  }

  private func save() async {
    guard let saved = await model.save() else { return }
    onSaved(saved)
    dismiss()
  }
}

struct TerminalAutobuysSection: View {
  let model: TerminalPositionsViewModel
  let onEdit: (AutobuyResponse) -> Void
  let onAdd: () -> Void

  var body: some View {
    Section {
      ForEach(model.autobuys) { autobuy in
        Button {
          onEdit(autobuy)
        } label: {
          AutobuyRow(autobuy: autobuy, currency: model.currency)
        }
        .buttonStyle(.plain)
        // A cadence this build doesn't know can't be edited without losing it.
        .disabled(autobuy.cadence == .unknown)
        .swipeActions {
          Button("Delete", role: .destructive) {
            Task { await model.deleteAutobuy(autobuy) }
          }
        }
      }
      Button(action: onAdd) {
        Label("Add autobuy", systemImage: "plus")
      }
      if !model.autobuys.isEmpty {
        LabeledContent("Monthly total") {
          Text(TerminalFormat.money(model.monthlyAutobuyTotal, currency: model.currency)).monospacedDigit()
        }
      }
    } header: {
      Text("Autobuys")
    }
  }
}

struct AutobuyRow: View {
  let autobuy: AutobuyResponse
  let currency: String

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(verbatim: autobuy.label)
            .font(.body.weight(.semibold))
          if let ticker = autobuy.ticker {
            Text(verbatim: ticker)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(verbatim: detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if let monthly = autobuy.monthlyEquivalent {
        Text("\(TerminalFormat.money(monthly, currency: currency)) a month")
          .font(.subheadline.monospacedDigit())
      } else if autobuy.cadence == .percentOfContribution {
        Text("Add a monthly base")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
    .opacity(autobuy.active ? 1 : 0.5)
    .contentShape(Rectangle())
  }

  private var detail: String {
    if autobuy.cadence == .percentOfContribution, let percent = autobuy.percent {
      return "\(autobuy.cadence.title) · \(percent.formatted(.percent.precision(.fractionLength(0...2))))"
    }
    return "\(autobuy.cadence.title) · \(TerminalFormat.money(autobuy.amount, currency: currency))"
  }
}
```

- [ ] **Step 2: Wire it into the screen.** In `TerminalPositionsScreen.swift`, replace

```swift
  @State private var editorTarget: TerminalEditorTarget?
```

with

```swift
  @State private var editorTarget: TerminalEditorTarget?
  @State private var autobuyTarget: AutobuyEditorTarget?
```

then replace

```swift
      } else {
        positionsSection
        totalsSection
      }
    }
```

with

```swift
      } else {
        positionsSection
        totalsSection
      }
      TerminalAutobuysSection(
        model: model,
        onEdit: { autobuyTarget = .edit($0) },
        onAdd: { autobuyTarget = .new }
      )
    }
```

then replace

```swift
    .sheet(item: $editorTarget) { target in
      TerminalPositionEditorSheet(target: target, currency: model.currency) { model.saved($0) }
    }
```

with

```swift
    .sheet(item: $editorTarget) { target in
      TerminalPositionEditorSheet(target: target, currency: model.currency) { model.saved($0) }
    }
    .sheet(item: $autobuyTarget) { target in
      AutobuyEditorSheet(target: target, currency: model.currency) { _ in
        Task { await model.reloadAutobuys() }
      }
    }
```

- [ ] **Step 3: Build and run the autobuy suite**

Run: `make ios-build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head -20`, then the test command with `AutobuyEditorModelTests`.
Expected: `** BUILD SUCCEEDED **`; 11 tests pass.

- [ ] **Step 4: Simulator check (staging)**

Add three autobuys: "401k" (percent, monthly base 5000, 4) shows "$200 a month"; "$50 weekly" shows "$217 a month"; "$275 every two months" shows "$138 a month". The monthly total is the sum of the active rows. Toggling one inactive dims it and drops it from the total after save.

- [ ] **Step 5: Commit**

```bash
git add financeplan/Features/TerminalPositions/AutobuyEditorSheet.swift financeplan/Features/TerminalPositions/TerminalPositionsScreen.swift
git commit -m "feat(terminal): add autobuys section and editor"
```

---

### Task 13: Dashboard summary card

**Files:**
- Create: `financeplan/Features/TerminalPositions/TerminalDashboardCard.swift`
- Modify: `financeplan/Features/Home/DashboardRoot.swift:33`, `:124`, `:144-146`, `:390`, `:448-452`
- Test: `financeplanTests/TerminalCardModelsTests.swift`

**Interfaces:**
- Consumes: `service.summary()`, `TerminalPositionsErrorText.isCancellation`, `TerminalFormat`, `TerminalCopy`, `TerminalPreferences`, `TerminalPositionsScreen` (Task 10).
- Produces: `@MainActor @Observable final class TerminalSummaryCardModel { enum State: Equatable { case loading, hidden, empty, summary(TerminalPositionsSummaryResponse) }; private(set) var state; init(service:); func load() async }` and `struct TerminalDashboardCard: View` (`init(action: @escaping () -> Void)`).

- [ ] **Step 1: Write the failing tests**

```swift
// financeplanTests/TerminalCardModelsTests.swift
import Foundation
import StockPlanShared
import XCTest
@testable import financeplan

@MainActor
final class TerminalCardModelsTests: XCTestCase {
  func testSummaryWithRowsShowsTheSummary() async {
    let service = MockTerminalPositionsService()
    let summary = TerminalPositionsSummaryResponse.fixture([.fixture(), .fixture(id: "p2", valueWanted: 2_000_000)], monthlyAutobuyTotal: 417)
    service.summaryResult = .success(summary)
    let model = TerminalSummaryCardModel(service: service)

    await model.load()

    XCTAssertEqual(model.state, .summary(summary))
  }

  func testSummaryWithNoRowsShowsTheCompactPrompt() async {
    let service = MockTerminalPositionsService()
    service.summaryResult = .success(.fixture([]))
    let model = TerminalSummaryCardModel(service: service)

    await model.load()

    XCTAssertEqual(model.state, .empty)
  }

  func testSummaryNotFoundHidesTheCard() async {
    let service = MockTerminalPositionsService()
    service.summaryResult = .failure(TerminalPositionsHTTPClient.Error.rejected(status: 404, message: "Not Found"))
    let model = TerminalSummaryCardModel(service: service)

    await model.load()

    XCTAssertEqual(model.state, .hidden)
  }

  func testCancelledSummaryKeepsLoading() async {
    let service = MockTerminalPositionsService()
    service.summaryResult = .failure(TerminalPositionsHTTPClient.Error.cancelled)
    let model = TerminalSummaryCardModel(service: service)

    await model.load()

    XCTAssertEqual(model.state, .loading)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the test command with `TerminalCardModelsTests`.
Expected: FAIL to compile with `cannot find 'TerminalSummaryCardModel' in scope`.

- [ ] **Step 3: Write the card**

```swift
// financeplan/Features/TerminalPositions/TerminalDashboardCard.swift
import Factory
import Observation
import StockPlanShared
import SwiftUI

@MainActor @Observable
final class TerminalSummaryCardModel {
  enum State: Equatable {
    case loading
    /// The request failed: no card at all (also covers a backend without the route yet).
    case hidden
    /// No rows: a compact prompt instead of an empty summary.
    case empty
    case summary(TerminalPositionsSummaryResponse)
  }

  private(set) var state: State = .loading
  private let service: any TerminalPositionsServicing

  init(service: any TerminalPositionsServicing) {
    self.service = service
  }

  func load() async {
    do {
      let summary = try await service.summary()
      state = summary.positionCount == 0 ? .empty : .summary(summary)
    } catch {
      guard !TerminalPositionsErrorText.isCancellation(error) else { return }
      // A refresh failure keeps what was shown; only a first failure hides the card.
      if case .loading = state { state = .hidden }
    }
  }
}

struct TerminalDashboardCard: View {
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage(TerminalPreferences.roundDownKey) private var roundDown = false
  @State private var model = TerminalSummaryCardModel(service: Container.shared.terminalPositionsService())
  let action: () -> Void

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        card { prompt }
          .redacted(reason: .placeholder)
      case .hidden:
        EmptyView()
      case .empty:
        card { prompt }
      case let .summary(summary):
        card { summaryContent(summary) }
      }
    }
    .task { await model.load() }
  }

  private var prompt: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label("Plan a terminal position", systemImage: "scope")
        .font(.headline)
      Text("Set a future market cap and see how many shares your target takes.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
    }
  }

  private func summaryContent(_ summary: TerminalPositionsSummaryResponse) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Terminal positions", systemImage: "scope")
        .font(.headline)
      Text("Value wanted: \(TerminalFormat.money(summary.totalValueWanted, currency: summary.currency))")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      ForEach(summary.topPositions) { position in
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(verbatim: position.ticker)
              .font(.subheadline.weight(.semibold))
            Spacer()
            if let needed = position.sharesNeeded {
              Text(TerminalFormat.shares(needed, roundDown: roundDown))
                .font(.subheadline.monospacedDigit())
            }
          }
          ProgressView(value: min(max(position.progress ?? 0, 0), 1))
            .tint(AppTheme.Colors.tint(for: colorScheme))
        }
      }
      if summary.monthlyAutobuyTotal > 0 {
        Text("Autobuys: \(TerminalFormat.money(summary.monthlyAutobuyTotal, currency: summary.currency)) a month")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text(TerminalCopy.disclaimer)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }

  private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 16) {
        content()
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .foregroundStyle(.tertiary)
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        AppTheme.Colors.cardBackground(for: colorScheme),
        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
      )
    }
    .buttonStyle(.plain)
    .accessibilityHint(Text("Open terminal positions"))
  }
}
```

- [ ] **Step 4: Wire the dashboard.** In `financeplan/Features/Home/DashboardRoot.swift`:

Replace `  @State private var isGoalPlanningPresented = false` with

```swift
  @State private var isGoalPlanningPresented = false
  @State private var isTerminalPositionsPresented = false
```

Replace `              onGoalPlanningTap: { isGoalPlanningPresented = true }` with

```swift
              onGoalPlanningTap: { isGoalPlanningPresented = true },
              onTerminalPositionsTap: { isTerminalPositionsPresented = true }
```

Replace

```swift
      .navigationDestination(isPresented: $isChartBuilderPresented) {
        ChartBuilderStandaloneScreen()
      }
```

with

```swift
      .navigationDestination(isPresented: $isChartBuilderPresented) {
        ChartBuilderStandaloneScreen()
      }
      .navigationDestination(isPresented: $isTerminalPositionsPresented) {
        TerminalPositionsScreen()
      }
```

Replace `  let onGoalPlanningTap: () -> Void` with

```swift
  let onGoalPlanningTap: () -> Void
  let onTerminalPositionsTap: () -> Void
```

Replace

```swift
      GoalPlanningDashboardCard(action: onGoalPlanningTap)
        .guidedTarget(.goalCard, in: .dashboard)
        .id(DashboardRoot.goalCardScrollID)

      ChartBuilderDashboardCard(onOpen: onChartBuilderTap)
```

with

```swift
      GoalPlanningDashboardCard(action: onGoalPlanningTap)
        .guidedTarget(.goalCard, in: .dashboard)
        .id(DashboardRoot.goalCardScrollID)

      TerminalDashboardCard(action: onTerminalPositionsTap)

      ChartBuilderDashboardCard(onOpen: onChartBuilderTap)
```

- [ ] **Step 5: Run the tests and build**

Run the test command with `TerminalCardModelsTests`, then `make ios-build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head -20`.
Expected: 4 tests pass; `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add financeplan/Features/TerminalPositions/TerminalDashboardCard.swift financeplan/Features/Home/DashboardRoot.swift financeplanTests/TerminalCardModelsTests.swift
git commit -m "feat(terminal): add terminal positions dashboard card"
```

---

### Task 14: Stock detail card

**Files:**
- Create: `financeplan/Features/TerminalPositions/StockTerminalCard.swift`
- Modify: `financeplan/Features/Stocks/Detail/StockOverviewTab.swift:27`
- Test: `financeplanTests/TerminalCardModelsTests.swift` (append)

**Interfaces:**
- Consumes: `service.list(ticker:)`, `TerminalPositionEditorSheet` / `TerminalEditorTarget` (Task 9), `GlassCard`, `TerminalFormat`, `TerminalCopy`, `TerminalPreferences`.
- Produces: `@MainActor @Observable final class StockTerminalCardModel { enum State: Equatable { case loading, hidden, empty(currency: String), position(TerminalPositionResponse, currency: String) }; private(set) var state; var currency: String; init(service: = Container.shared.terminalPositionsService()); func load(symbol: String) async; func saved(_:) }` and `struct StockTerminalCard: View` (`symbol: String`).

- [ ] **Step 1: Write the failing tests** (append inside `TerminalCardModelsTests`)

```swift
  func testStockCardFiltersByTheSymbolAndShowsTheFirstRow() async {
    let service = MockTerminalPositionsService()
    service.listResult = .success(.fixture([.fixture(id: "first"), .fixture(id: "second")], currency: "EUR"))
    let model = StockTerminalCardModel(service: service)

    await model.load(symbol: "AMZN")

    XCTAssertEqual(service.listTickers, ["AMZN"])
    XCTAssertEqual(model.state, .position(.fixture(id: "first"), currency: "EUR"))
  }

  func testStockCardWithNoRowOffersToAddOne() async {
    let service = MockTerminalPositionsService()
    service.listResult = .success(.fixture([], currency: "USD"))
    let model = StockTerminalCardModel(service: service)

    await model.load(symbol: "NVDA")

    XCTAssertEqual(model.state, .empty(currency: "USD"))
  }

  func testStockCardNotFoundHides() async {
    let service = MockTerminalPositionsService()
    service.listResult = .failure(TerminalPositionsHTTPClient.Error.rejected(status: 404, message: "Not Found"))
    let model = StockTerminalCardModel(service: service)

    await model.load(symbol: "AMZN")

    XCTAssertEqual(model.state, .hidden)
  }

  func testSavingFromTheStockCardShowsTheNewRow() async {
    let service = MockTerminalPositionsService()
    service.listResult = .success(.fixture([], currency: "GBP"))
    let model = StockTerminalCardModel(service: service)
    await model.load(symbol: "AMZN")

    model.saved(.fixture(id: "new"))

    XCTAssertEqual(model.state, .position(.fixture(id: "new"), currency: "GBP"))
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the test command with `TerminalCardModelsTests`.
Expected: FAIL to compile with `cannot find 'StockTerminalCardModel' in scope`.

- [ ] **Step 3: Write the card**

```swift
// financeplan/Features/TerminalPositions/StockTerminalCard.swift
import Factory
import Observation
import StockPlanShared
import SwiftUI

@MainActor @Observable
final class StockTerminalCardModel {
  enum State: Equatable {
    case loading
    /// Failure collapses the card instead of erroring the stock tab.
    case hidden
    case empty(currency: String)
    case position(TerminalPositionResponse, currency: String)
  }

  private(set) var state: State = .loading
  private let service: any TerminalPositionsServicing

  init(service: any TerminalPositionsServicing = Container.shared.terminalPositionsService()) {
    self.service = service
  }

  var currency: String {
    switch state {
    case let .empty(currency), let .position(_, currency): currency
    case .loading, .hidden: "USD"
    }
  }

  func load(symbol: String) async {
    do {
      let list = try await service.list(ticker: symbol)
      state = list.positions.first.map { .position($0, currency: list.currency) } ?? .empty(currency: list.currency)
    } catch {
      guard !TerminalPositionsErrorText.isCancellation(error) else { return }
      state = .hidden
    }
  }

  func saved(_ position: TerminalPositionResponse) {
    state = .position(position, currency: currency)
  }
}

/// That ticker's first terminal scenario on the stock overview tab, or a way
/// to add one. Self-loading like `StockPressureCard`.
struct StockTerminalCard: View {
  let symbol: String
  @AppStorage(TerminalPreferences.roundDownKey) private var roundDown = false
  @State private var model = StockTerminalCardModel()
  @State private var editorTarget: TerminalEditorTarget?

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        GlassCard {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Checking your terminal scenario…")
              .typography(.small)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      case .hidden:
        EmptyView()
      case .empty:
        GlassCard {
          VStack(alignment: .leading, spacing: 10) {
            Text("Terminal scenario")
              .typography(.small, weight: .semibold)
            Button {
              editorTarget = .new(ticker: symbol)
            } label: {
              Label("Add terminal scenario", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      case let .position(position, currency):
        GlassCard { content(position, currency: currency) }
      }
    }
    .task(id: symbol) { await model.load(symbol: symbol) }
    .sheet(item: $editorTarget) { target in
      TerminalPositionEditorSheet(target: target, currency: model.currency) { model.saved($0) }
    }
  }

  private func content(_ position: TerminalPositionResponse, currency: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Terminal scenario")
          .typography(.small, weight: .semibold)
        Spacer()
        Button("Edit") { editorTarget = .edit(position) }
          .font(.caption.weight(.semibold))
      }
      if let error = position.scenarioError {
        Label(TerminalPositionEditorModel.text(forRaw: error), systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      } else {
        if let price = position.terminalSharePrice {
          LabeledContent("Terminal share price") {
            Text(TerminalFormat.price(price, currency: currency)).monospacedDigit()
          }
        }
        if let needed = position.sharesNeeded {
          LabeledContent("Shares needed") {
            Text(TerminalFormat.shares(needed, roundDown: roundDown)).monospacedDigit()
          }
        }
        ProgressView(value: min(max(position.progress ?? 0, 0), 1))
        Text(TerminalFormat.progress(position.progress ?? 0))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text(TerminalCopy.disclaimer)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }
}
```

- [ ] **Step 4: Place it on the overview tab.** In `financeplan/Features/Stocks/Detail/StockOverviewTab.swift`, replace

```swift
            StockPressureCard(symbol: symbol)
```

with

```swift
            StockPressureCard(symbol: symbol)

            StockTerminalCard(symbol: symbol)
```

- [ ] **Step 5: Run the tests and build**

Run the test command with `TerminalCardModelsTests`, then `make ios-build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head -20`.
Expected: 8 tests pass; `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add financeplan/Features/TerminalPositions/StockTerminalCard.swift financeplan/Features/Stocks/Detail/StockOverviewTab.swift financeplanTests/TerminalCardModelsTests.swift
git commit -m "feat(terminal): add terminal scenario card on stock detail"
```

---

### Task 15: English and pt-PT strings

**Files:**
- Modify: `financeplan/Localizable.xcstrings`

**Interfaces:**
- Consumes: every key introduced in Tasks 4–14 (English text is the key).
- Produces: an `en` + `pt-PT` `stringUnit` for each key. Existing translations are kept. The file keeps Xcode's exact formatting (`" : "` separators, expanded empty objects, no trailing newline). This was verified to round-trip byte-for-byte on the current catalog.

- [ ] **Step 1: Write the failing check**

```bash
cd /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-ios/financeplan-terminal && python3 - <<'PY'
import json, re, sys
from pathlib import Path
strings = json.loads(Path("financeplan/Localizable.xcstrings").read_text())["strings"]
pattern = re.compile(r'(?:String\(localized: |Text\(|Button\(|Label\(|Section\(|LabeledContent\(|Toggle\(|TextField\(|LocalizedStringKey\(|title: |\.alert\(|\.navigationTitle\()"((?:[^"\\]|\\.)*)"')
keys = set()
for path in Path("financeplan/Features/TerminalPositions").glob("*.swift"):
    for key in pattern.findall(path.read_text()):
        if "\\(" not in key:
            keys.add(key)
keys |= {"Terminal position sizing", "Monthly base", "Amount", "This price is in %@; your plan uses %@.",
         "Still needed: %@", "As of %@", "Horizon: %lld years", "Monthly equivalent: %@", "%@ a month",
         "Value wanted: %@", "Autobuys: %@ a month"}
missing = sorted(k for k in keys if "pt-PT" not in strings.get(k, {}).get("localizations", {}))
print("missing pt-PT:", len(missing))
for k in missing: print("  ", k)
sys.exit(1 if missing else 0)
PY
```
Expected: FAIL (exit 1) with a non-zero `missing pt-PT:` count.

- [ ] **Step 2: Add the translations**

```bash
cd /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-ios/financeplan-terminal && python3 - <<'PY'
import json, re
from pathlib import Path

# English key -> pt-PT, or key -> (en value, pt-PT) where the en value needs positional specifiers.
TRANSLATIONS = {
    # Contract copy (verbatim)
    "Terminal position sizing": "Dimensionamento de posições terminais",
    "Decide the future market cap and share count. Norviq tells you how many shares that target is.":
        "Define a capitalização bolsista e o número de ações futuros. O Norviq diz-te quantas ações esse objetivo representa.",
    "Terminal prices are your assumptions, not forecasts. Not financial advice.":
        "Os preços terminais são pressupostos teus, não previsões. Não é aconselhamento financeiro.",
    # Screen
    "Terminal positions": "Posições terminais",
    "Round down to whole shares": "Arredondar para ações inteiras",
    "No positions yet. Tap + to add your first scenario.": "Ainda não tens posições. Toca em + para adicionares o teu primeiro cenário.",
    "Add position": "Adicionar posição",
    "Positions": "Posições",
    "Delete": "Eliminar",
    "Duplicate": "Duplicar",
    "Totals": "Totais",
    "Total value wanted": "Valor total pretendido",
    "Still needed at terminal prices": "Ainda em falta a preços terminais",
    "Capital at today's prices": "Capital aos preços de hoje",
    "Get started": "Começar",
    "Sample": "Exemplo",
    "Use AMZN sample": "Usar exemplo AMZN",
    "Dismiss": "Ignorar",
    "Shares needed": "Ações necessárias",
    "Still needed: %@": "Ainda em falta: %@",
    "OK": "OK",
    # View model messages
    "Terminal positions are unavailable right now.": "As posições terminais não estão disponíveis de momento.",
    "Autobuys are unavailable right now.": "As compras automáticas não estão disponíveis de momento.",
    "The sample could not be added.": "Não foi possível adicionar o exemplo.",
    "The row could not be deleted.": "Não foi possível eliminar a linha.",
    "The row could not be duplicated.": "Não foi possível duplicar a linha.",
    "That row no longer exists. Pull to refresh.": "Essa linha já não existe. Puxa para atualizar.",
    "The new order could not be saved.": "Não foi possível guardar a nova ordem.",
    "The autobuy could not be deleted.": "Não foi possível eliminar a compra automática.",
    # Editor
    "Edit position": "Editar posição",
    "New position": "Nova posição",
    "Cancel": "Cancelar",
    "Save": "Guardar",
    "Company": "Empresa",
    "Ticker": "Ticker",
    "Use 1–12 letters, digits, dots or dashes.": "Usa 1–12 letras, dígitos, pontos ou hífenes.",
    "Your scenario": "O teu cenário",
    "Future share count": "Número de ações futuro",
    "Future market cap": "Capitalização bolsista futura",
    "Value wanted": "Valor pretendido",
    "K, M, B and T are thousands, millions, billions and trillions.": "K, M, B e T são milhares, milhões, mil milhões e biliões.",
    "Unit": "Unidade",
    "Where you are now": "Onde estás agora",
    "Shares owned": "Ações que tens",
    "Today's share price (optional)": "Preço da ação hoje (opcional)",
    "Shares outstanding today (optional)": "Ações em circulação hoje (opcional)",
    "Result": "Resultado",
    "Terminal share price": "Preço terminal por ação",
    "Progress": "Progresso",
    "Still needed": "Ainda em falta",
    "Gap at terminal price": "Diferença ao preço terminal",
    "Cost at today's price": "Custo ao preço de hoje",
    "Enter share count, market cap and value wanted to see the result.":
        "Introduz o número de ações, a capitalização bolsista e o valor pretendido para veres o resultado.",
    "Share count must be above zero.": "O número de ações tem de ser superior a zero.",
    "Market cap must be above zero.": "A capitalização bolsista tem de ser superior a zero.",
    "These numbers can't be used. Check for negatives.": "Estes números não podem ser usados. Verifica se há valores negativos.",
    "This scenario needs a positive share count and market cap.":
        "Este cenário precisa de um número de ações e de uma capitalização bolsista positivos.",
    "Enter a number.": "Introduz um número.",
    "Can't be negative.": "Não pode ser negativo.",
    "The position could not be saved.": "Não foi possível guardar a posição.",
    "This row was deleted on another device.": "Esta linha foi eliminada noutro dispositivo.",
    "Notes": "Notas",
    "Why this scenario?": "Porquê este cenário?",
    # AI
    "AI assist": "Assistência IA",
    "Unlock AI fill with Pro": "Desbloqueia o preenchimento com IA no Pro",
    "Fill with AI": "Preencher com IA",
    "Suggest scenario": "Sugerir cenário",
    "Suggestions come with sources and are never saved until you tap Save.":
        "As sugestões incluem fontes e nunca são guardadas até tocares em Guardar.",
    "AI suggestion": "Sugestão da IA",
    "AI scenario": "Cenário da IA",
    "Shares outstanding": "Ações em circulação",
    "Share price": "Preço da ação",
    "As of %@": "Em %@",
    "Sources": "Fontes",
    "Accept": "Aceitar",
    "Horizon: %lld years": "Horizonte: %lld anos",
    "Enter a ticker first.": "Introduz primeiro um ticker.",
    "This price is in %@; your plan uses %@.":
        ("This price is in %1$@; your plan uses %2$@.", "Este preço está em %1$@; o teu plano usa %2$@."),
    "AI lookup is unavailable right now. You can still enter the numbers yourself.":
        "A pesquisa com IA não está disponível de momento. Podes introduzir os números manualmente.",
    "The AI couldn't find usable numbers for this ticker.": "A IA não encontrou números utilizáveis para este ticker.",
    "Too many AI lookups. Try again in a minute.": "Demasiadas pesquisas com IA. Tenta novamente daqui a um minuto.",
    "The AI lookup failed. Try again.": "A pesquisa com IA falhou. Tenta novamente.",
    # Autobuys
    "Autobuys": "Compras automáticas",
    "Add autobuy": "Adicionar compra automática",
    "Monthly total": "Total mensal",
    "%@ a month": "%@ por mês",
    "Add a monthly base": "Adiciona uma base mensal",
    "Edit autobuy": "Editar compra automática",
    "New autobuy": "Nova compra automática",
    "Label": "Nome",
    "e.g. 401k contribution": "ex.: contribuição para a reforma",
    "Ticker (optional)": "Ticker (opcional)",
    "Active": "Ativa",
    "Cadence": "Frequência",
    "Amount": "Montante",
    "Monthly base": "Base mensal",
    "Percent": "Percentagem",
    "Monthly equivalent: %@": "Equivalente mensal: %@",
    "Weekly": "Semanal",
    "Every two weeks": "De duas em duas semanas",
    "Every two months": "De dois em dois meses",
    "Monthly": "Mensal",
    "Percent of a monthly base": "Percentagem de uma base mensal",
    "Other": "Outro",
    "Enter a percent between 0 and 100.": "Introduz uma percentagem entre 0 e 100.",
    "The autobuy could not be saved.": "Não foi possível guardar a compra automática.",
    "This autobuy was deleted on another device.": "Esta compra automática foi eliminada noutro dispositivo.",
    # Cards
    "Plan a terminal position": "Planeia uma posição terminal",
    "Set a future market cap and see how many shares your target takes.":
        "Define uma capitalização bolsista futura e vê quantas ações o teu objetivo exige.",
    "Value wanted: %@": "Valor pretendido: %@",
    "Autobuys: %@ a month": "Compras automáticas: %@ por mês",
    "Open terminal positions": "Abrir posições terminais",
    "Terminal scenario": "Cenário terminal",
    "Add terminal scenario": "Adicionar cenário terminal",
    "Checking your terminal scenario…": "A verificar o teu cenário terminal…",
    "Edit": "Editar",
}

path = Path("financeplan/Localizable.xcstrings")
data = json.loads(path.read_text())
strings = data["strings"]
added, kept = [], []
for key, value in TRANSLATIONS.items():
    en, pt = value if isinstance(value, tuple) else (key, value)
    localizations = strings.setdefault(key, {}).setdefault("localizations", {})
    localizations.setdefault("en", {"stringUnit": {"state": "translated", "value": en}})
    if "pt-PT" in localizations:
        kept.append(key)
    else:
        localizations["pt-PT"] = {"stringUnit": {"state": "translated", "value": pt}}
        added.append(key)

out = json.dumps(data, ensure_ascii=False, indent=2, separators=(",", " : "))
out = re.sub(r'^( *)(.*) : \{\}(,?)$', lambda m: m[1] + m[2] + " : {\n\n" + m[1] + "}" + m[3], out, flags=re.M)
path.write_text(out)  # Xcode writes no trailing newline
print(f"added pt-PT for {len(added)} keys; kept existing pt-PT for {len(kept)}: {kept}")
PY
```

- [ ] **Step 3: Re-run the check from Step 1**

Expected: `missing pt-PT: 0` and exit 0. If a key is listed, add it to `TRANSLATIONS` in Step 2 with a pt-PT translation and re-run both steps.

- [ ] **Step 4: Check the diff is additive and builds**

Run: `git diff --stat financeplan/Localizable.xcstrings && git diff financeplan/Localizable.xcstrings | grep -c '^-[^-]'`, then `make ios-build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head -5`.
Expected: the second command prints a small number, made up only of the `{}`/`},` lines of pre-existing keys that gained `localizations`. `** BUILD SUCCEEDED **`.

- [ ] **Step 5: pt-PT simulator check**

Switch the app language to Português (Settings in the app). Open Terminal position sizing and confirm the title, subtitle and disclaimer read exactly as in Global Constraints. In the editor, type "1,5" with unit B: the preview treats it as 1.5 billion.

- [ ] **Step 6: Commit**

```bash
git add financeplan/Localizable.xcstrings
git commit -m "feat(terminal): English and pt-PT strings for terminal position sizing"
```

---

### Task 16: Release notes

**Files:**
- Modify: `fastlane/metadata/en-US/release_notes.txt`

**Interfaces:**
- Consumes: the lead bullet in Global Constraints.
- Produces: 1.4.0 "What's New" that leads with the feature.

- [ ] **Step 1: Write the failing check**

Run: `head -3 fastlane/metadata/en-US/release_notes.txt | grep -c "Terminal position sizing"`
Expected: `0`.

- [ ] **Step 2: Replace the file's contents**

```text
What's new in Norviq:

• Terminal position sizing — set a future market cap and share count and see how many shares your target takes (your assumptions, not advice)
• Invite friends by text message or Messenger
• Portfolio share cards stay readable when your phone is in dark mode
• Stability improvements

Norviq is an intelligence and organization tool. Not financial advice.
```

- [ ] **Step 3: Re-run the check**

Run: `head -3 fastlane/metadata/en-US/release_notes.txt | grep -c "Terminal position sizing" && wc -c fastlane/metadata/en-US/release_notes.txt`
Expected: `1`, and a byte count under 4000 (App Store limit).

- [ ] **Step 4: Commit**

```bash
git add fastlane/metadata/en-US/release_notes.txt
git commit -m "chore(release): lead 1.4.0 notes with terminal position sizing"
```

---

### Task 17: Full verification and pull request

**Files:**
- None (verification and PR only)

**Interfaces:**
- Consumes: everything above, plus `/tmp/terminal-ios-baseline.txt` (Task 1).
- Produces: a green branch and an open PR against `main`. **Merging that PR triggers a TestFlight build automatically** ("iOS CI" green on main → `release.yml` beta lane). The merge is the user's.

- [ ] **Step 1: Full unit suite against the baseline**

```bash
cd /Users/fernandocorreiachill/Work/production/apps/norviq/norviq-ios/financeplan-terminal && \
make ios-test 2>&1 | grep -E "Test Case .*failed" | sort -u > /tmp/terminal-ios-after.txt; \
comm -13 /tmp/terminal-ios-baseline.txt /tmp/terminal-ios-after.txt
```
Expected: no output (no failure that wasn't already on main). Any line printed is a regression from this branch: fix it before going on.

- [ ] **Step 2: Lint as CI does**

Run: `./scripts/format.sh --skip-install --lint-only`
Expected: exit 0 with no error-level violations in `financeplan/Features/TerminalPositions`, `financeplan/API/TerminalPositions` or the new tests.

- [ ] **Step 3: Simulator pass (spec "Verification → iOS")**

Against staging:
- Create the AMZN example and see 909.09 / 1,100.
- Set owned to 750 and see 68.18%.
- The round-down toggle changes shares to whole numbers everywhere: screen, editor and both cards.
- pt-PT comma input works.
- Reorder survives a pull-to-refresh.
- The dashboard card shows the total value wanted, the top 3 rows and the autobuy monthly total, and tapping it opens the screen.
- On stock detail for AMZN, the card shows price, shares needed and progress. For a ticker with no row it shows "Add terminal scenario", which opens the editor prefilled with that ticker.
- As a free user, "Unlock AI fill with Pro" opens the paywall. As Pro, "Fill with AI" shows sources, and Accept fills only shares outstanding and price without saving.

- [ ] **Step 4: Push and open the PR**

```bash
git push -u origin feat/terminal-positions
gh pr create --repo FinancePlanner/norviq-ios --base main --head feat/terminal-positions \
  --title "feat: terminal position sizing (iOS 1.4.0)" \
  --body "$(cat <<'EOF'
Terminal position sizing for 1.4.0.

- Pins StockPlanShared 5.21.0 (TerminalMath/AutobuyMath + DTOs; also 5.19 Articles and 5.20 MarketBrief DTOs, no app changes needed).
- Portfolio → Planning → Terminal position sizing: list (terminal price and shares needed first, progress, still needed), swipe duplicate/delete, drag reorder (PUT order), AMZN sample empty state, totals, autobuys with monthly equivalents.
- Editor with a live preview from the shared TerminalMath, inline guardrails, value + K/M/B/T unit fields parsed with MoneyInputParser (pt-PT commas), round-down display toggle, optional price and notes.
- Pro AI: "Fill with AI" (shares outstanding + price, with sources) and "Suggest scenario" (share count + market cap). Accept fills fields; only Save writes. Upgrade is detected by 403 + code "upgrade_required".
- Dashboard summary card and a stock-detail card; both hide if the backend route is missing.
- en + pt-PT strings; release notes lead with the feature.

Spec: norviq-backend docs/superpowers/specs/2026-10-09-terminal-position-sizing-design.md
Contract: norviq-backend docs/superpowers/plans/2026-10-09-terminal-contract.md

Merging to main triggers a TestFlight build automatically. TestFlight talks to production, so merge once production serves /v1/terminal-positions (backend promoted with -f service=both). The App Store release is a separate manual dispatch and happens only after that.
EOF
)"
```
Expected: a PR URL. Hand it to the user to review and merge. Do not merge it yourself.

---

### Task 18: Release gate — no App Store dispatch from this plan

**Files:**
- None

**Interfaces:**
- Consumes: the merged PR (TestFlight build from the beta lane) and a production backend.
- Produces: a go/no-go statement for the user. **This plan never dispatches the App Store release.**

- [ ] **Step 1: Check whether production serves the route**

Run: `curl -s -o /dev/null -w '%{http_code}\n' https://api.norviq.org/v1/terminal-positions`
Expected: `401` (the route exists and needs a token). A `404` means the backend has not been promoted to production. In that case, tell the user the App Store release must wait. TestFlight builds will show the screen's "unavailable" message, and both cards stay hidden.

- [ ] **Step 2: Confirm the TestFlight build**

Run: `gh run list --repo FinancePlanner/norviq-ios --workflow release.yml --limit 3`
Expected: a successful `beta` run for the merge commit on `main`.

- [ ] **Step 3: Stop and report**

Tell the user three things. First, the TestFlight build status. Second, the `curl` result. Third, that the 1.4.0 App Store release (`release.yml`, `workflow_dispatch`, lane `release`, gated by the `app-store` environment reviewer) is theirs to dispatch, and only once Step 1 returns `401`. **Do not run `gh workflow run release.yml`.**

---

## Self-Review

**Spec coverage (section 5 + release gates):**

| Spec item | Task |
|---|---|
| Pin 5.18.0 → 5.21.0, build stays green with 5.19/5.20 DTOs | 1 |
| Servicing + endpoints + Container factory (GoalPlanning pattern) | 2, 3 |
| `@Observable` view model | 5, 6 |
| Row shows terminal price + shares needed first, progress bar | 10 |
| Swipe delete/duplicate, `onMove` reorder (first in the app) | 6, 10 |
| Editor live preview via shared `TerminalMath`, inline guardrails | 7, 9 |
| Value + unit picker, `MoneyInputParser`, pt-PT commas | 4, 7, 9 |
| Round-down toggle | 4, 9, 10 |
| Pro AI buttons (`ProGateView`/paywall), Accept never saves | 8, 9 |
| Autobuys section with monthly total | 11, 12 |
| PortfolioRoot Planning menu route | 10 |
| `TerminalDashboardCard` next to `GoalPlanningDashboardCard` | 13 |
| `StockTerminalCard(symbol:)` self-loading in `StockOverviewTab` | 14 |
| en + pt-PT copy, disclaimer on screen and editor | 4, 9, 10, 15 |
| XCTest VM tests with a mock service | 5–8, 11, 13, 14 |
| Release notes lead bullet | 16 |
| iOS PR; merge → TestFlight | 17 |
| App Store dispatch only after production serves `/v1/terminal-positions` | 18 |

**Placeholder scan:** no TBD/TODO. Every code step carries its code. Task 1 Step 7 gives concrete fixes for the only two break shapes possible in an additive shared release.

**Type consistency:** `TerminalPositionsServicing` method names match across Tasks 3, 5 (mock), 6, 7, 8, 11, 13 and 14. `TerminalEditorTarget` (Task 9) is used in Tasks 10 and 14. `TerminalPreferences.roundDownKey` is used in Tasks 9, 10, 13 and 14. `TerminalPositionsErrorText.message(for:fallback:notFound:)` and `.isCancellation(_:)` are used in Tasks 6, 7, 8, 11, 13 and 14.

## Assumptions the contract leaves open

- The DTO memberwise initializers take their parameters in the order the contract lists the fields. The fixtures in `TerminalPositionsTestSupport.swift` are the one place to adjust if 5.21.0 differs.
- The shared request DTOs use synthesized `Encodable`, so nil fields are omitted and not sent as `null`. Task 2 pins this, because PATCH semantics depend on it.
- The AMZN sample values (11B shares, $10T cap, $1M wanted, nothing owned) are derived from the spec's 909.0909…/1,100 example. The contract does not define the sample row, so web should use the same numbers.
- `positionCount == 0` decides the dashboard's compact prompt even when autobuys exist.
- AI requests omit `horizonYears` and let the server default of 10 apply. There is no horizon picker in v1.
