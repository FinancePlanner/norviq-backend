# Terminal Position Sizing: cross-repo contract

Every plan (shared+backend, web, MCP, iOS) uses exactly these names. The spec is `docs/superpowers/specs/2026-10-09-terminal-position-sizing-design.md`.

## norviq-shared v5.21.0 (`Sources/StockPlanShared/TerminalPositions/`)

### TerminalMath.swift
```swift
public struct TerminalScenarioInput: Sendable, Equatable {
    public var terminalShareCount: Double
    public var terminalMarketCap: Double
    public var valueWanted: Double
    public var sharesOwned: Double          // default 0
    public var currentSharePrice: Double?   // optional, manual
    public init(terminalShareCount: Double, terminalMarketCap: Double, valueWanted: Double,
                sharesOwned: Double = 0, currentSharePrice: Double? = nil)
}

public enum TerminalScenarioError: String, Codable, Sendable, Equatable {
    case shareCountNotPositive = "share_count_not_positive"
    case marketCapNotPositive = "market_cap_not_positive"
    case invalidNumber = "invalid_number"   // NaN/inf, or a negative valueWanted/sharesOwned
}

public struct TerminalScenarioResult: Sendable, Equatable {
    public let terminalSharePrice: Double
    public let sharesNeeded: Double
    public let capitalAtTodayPrice: Double?   // nil when there is no currentSharePrice
    public let progress: Double               // 0 when sharesNeeded == 0
    public let sharesStillNeeded: Double
    public let gapValueAtTerminal: Double
}

public enum TerminalMath {
    public static func evaluate(_ input: TerminalScenarioInput) -> Result<TerminalScenarioResult, TerminalScenarioError>
    /// Display-only "round down to whole shares".
    public static func wholeShares(_ shares: Double) -> Double   // floor, never below 0
}

public enum AutobuyMath {
    /// weekly ×52/12, biweekly ×26/12, bimonthly ×6/12 (every two months), monthly ×1,
    /// percentOfContribution → amount (monthly base) × percent, or nil when amount is 0 or percent is nil.
    /// unknown → nil.
    public static func monthlyEquivalent(amount: Double, cadence: AutobuyCadence, percent: Double?) -> Double?
    /// Active rows only; nil equivalents are skipped.
    public static func monthlyTotal(_ items: [(amount: Double, cadence: AutobuyCadence, percent: Double?, active: Bool)]) -> Double
}
```

### TerminalPositionsDTOs.swift
All types are `public struct X: Codable, Sendable, Equatable` with public memberwise inits. Responses also conform to `Identifiable`. Ids are UUID strings and dates are ISO-8601 strings.
```swift
public enum AutobuyCadence: String, Codable, Sendable, CaseIterable {
    case weekly, biweekly, bimonthly, monthly, percentOfContribution, unknown
    // init(from:) maps any unrecognised raw value to .unknown
}

public struct TerminalPositionResponse: Identifiable {
    id: String, ticker: String, sharesOutstanding: Double?, terminalShareCount: Double,
    terminalMarketCap: Double, valueWanted: Double, sharesOwned: Double, currentSharePrice: Double?,
    notes: String?, sortOrder: Int,
    // derived (always recomputed; nil when scenarioError != nil)
    terminalSharePrice: Double?, sharesNeeded: Double?, capitalAtTodayPrice: Double?,
    progress: Double?, sharesStillNeeded: Double?, gapValueAtTerminal: Double?,
    scenarioError: String?,      // TerminalScenarioError raw value
    createdAt: String, updatedAt: String
}
public struct TerminalPositionCreateRequest {
    ticker: String, sharesOutstanding: Double?, terminalShareCount: Double, terminalMarketCap: Double,
    valueWanted: Double, sharesOwned: Double?, currentSharePrice: Double?, notes: String?
}
public struct TerminalPositionUpdateRequest {   // PATCH: only the non-nil fields change
    ticker: String?, sharesOutstanding: Double?, terminalShareCount: Double?, terminalMarketCap: Double?,
    valueWanted: Double?, sharesOwned: Double?, currentSharePrice: Double?, notes: String?,
    clear: [String]?             // any of "sharesOutstanding", "currentSharePrice", "notes" → set to nil
}
public struct TerminalPositionOrderRequest { ids: [String] }       // the full list, in the new order
public struct TerminalPositionsListResponse { currency: String, positions: [TerminalPositionResponse] }

public struct AutobuyResponse: Identifiable {
    id: String, ticker: String?, label: String, amount: Double, cadence: AutobuyCadence,
    percent: Double?, active: Bool, monthlyEquivalent: Double?, createdAt: String, updatedAt: String
}
public struct AutobuyCreateRequest { ticker: String?, label: String, amount: Double, cadence: AutobuyCadence, percent: Double?, active: Bool? }
public struct AutobuyUpdateRequest { ticker: String?, label: String?, amount: Double?, cadence: AutobuyCadence?, percent: Double?, active: Bool?, clear: [String]? }  // clear: "ticker", "percent"
public struct AutobuysListResponse { currency: String, autobuys: [AutobuyResponse], monthlyTotal: Double }

public struct TerminalPositionsSummaryResponse {
    currency: String, positionCount: Int,
    totalValueWanted: Double,            // valid rows only
    totalGapValueAtTerminal: Double,     // Σ gapValueAtTerminal over valid rows
    totalCapitalAtTodayPrice: Double?,   // Σ over rows with a price; nil when none have one
    pricedPositionCount: Int,
    monthlyAutobuyTotal: Double,
    topPositions: [TerminalPositionResponse]   // up to 3 valid rows, highest valueWanted first
}

public struct ShareFactsRequest { ticker: String }
public struct ShareFactsSuggestion { ticker: String, sharesOutstanding: Double?, currentSharePrice: Double?, currency: String?, asOf: String?, sources: [String] }
public struct TerminalScenarioSuggestionRequest { ticker: String, horizonYears: Int? }   // default 10
public struct TerminalScenarioSuggestion { ticker: String, terminalShareCount: Double, terminalMarketCap: Double, horizonYears: Int, rationale: String, sources: [String] }
```

## Backend HTTP API (all under `/v1`, `Authorization: Bearer`)
| Method | Path | Scope | Body → Response |
|---|---|---|---|
| GET | `/v1/terminal-positions[?ticker=AMZN]` | planning:read | → `TerminalPositionsListResponse` (sorted by sortOrder; `ticker` filters case-insensitively) |
| POST | `/v1/terminal-positions` | planning:write | `TerminalPositionCreateRequest` → 201 `TerminalPositionResponse` (appended last) |
| PATCH | `/v1/terminal-positions/:id` | planning:write | `TerminalPositionUpdateRequest` → `TerminalPositionResponse` |
| DELETE | `/v1/terminal-positions/:id` | planning:write | → 204 |
| POST | `/v1/terminal-positions/:id/duplicate` | planning:write | → 201 `TerminalPositionResponse` (placed right after the source) |
| PUT | `/v1/terminal-positions/order` | planning:write | `TerminalPositionOrderRequest` → `TerminalPositionsListResponse` (422 if ids ≠ the user's set) |
| GET | `/v1/terminal-positions/summary` | planning:read | → `TerminalPositionsSummaryResponse` |
| GET | `/v1/autobuys` | planning:read | → `AutobuysListResponse` |
| POST | `/v1/autobuys` | planning:write | `AutobuyCreateRequest` → 201 `AutobuyResponse` |
| PATCH | `/v1/autobuys/:id` | planning:write | `AutobuyUpdateRequest` → `AutobuyResponse` |
| DELETE | `/v1/autobuys/:id` | planning:write | → 204 |
| POST | `/v1/terminal-positions/ai/share-facts` | planning:read + **Pro** | `ShareFactsRequest` → `ShareFactsSuggestion` (403 upgrade_required / 503 AI unavailable / 422 unusable answer) |
| POST | `/v1/terminal-positions/ai/scenario` | planning:read + **Pro** | `TerminalScenarioSuggestionRequest` → `TerminalScenarioSuggestion` (same errors) |

Errors use `Abort` with `reason`:
- 404 when the row is missing or belongs to another user.
- 422 for a bad ticker, a negative valueWanted/sharesOwned/amount, a percent outside 0–1, or a percent cadence without a percent.
- Share count or market cap ≤ 0 is **accepted**. The row then carries `scenarioError` and null derived fields.

The ticker is trimmed, uppercased and must match `^[A-Z0-9.\-]{1,12}$`.

Pro gating uses `BillingFeature.terminalPositionAI` (raw `terminal_position_ai`). Non-Pro users get the existing `BillingUpgradeRequiredError`, which `BillingErrorMiddleware` renders as **HTTP 403** with body `{"success":false,"code":"upgrade_required","error":…,"feature":"terminal_position_ai","plan":…,"requiredPlan":"pro"}`. Clients detect upgrade by `code == "upgrade_required"`, not by status alone, since 403 also means a missing scope.

## Assistant / MCP actions (backend `ActionCatalog`, mirrored by norviq-mcp tools)
| Name | Kind | Input | Notes |
|---|---|---|---|
| `get_terminal_positions` | read | `{}` | list + currency |
| `get_terminal_position` | read | `{ticker}` | first row for the ticker by sortOrder, or "none" |
| `lookup_share_facts` | read, Pro | `{ticker}` | same as the share-facts endpoint; returns a suggestion only |
| `set_terminal_scenario` | **write, destructive:true (always confirm)** | `{ticker, terminalShareCount?, terminalMarketCap?, valueWanted?, sharesOwned?, sharesOutstanding?, currentSharePrice?}` | Updates the first row for the ticker, or creates one (create needs terminalShareCount, terminalMarketCap and valueWanted). The description says assumptions must come from the user or cited sources. |

## Copy (en)
- **Title:** "Terminal position sizing"
- **Subtitle:** "Decide the future market cap and share count. Norviq tells you how many shares that target is."
- **Disclaimer:** "Terminal prices are your assumptions, not forecasts. Not financial advice."
- **pt-PT:**
  - **Title:** "Dimensionamento de posições terminais"
  - **Subtitle:** "Define a capitalização bolsista e o número de ações futuros. O Norviq diz-te quantas ações esse objetivo representa."
  - **Disclaimer:** "Os preços terminais são pressupostos teus, não previsões. Não é aconselhamento financeiro."
