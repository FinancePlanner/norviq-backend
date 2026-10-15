# Terminal Position Sizing (ships in iOS 1.4.0)

Date: 2026-10-09 · Status: approved design, pending written-spec review · Branch: `feat/terminal-positions`

## Context
Users want to plan positions the way the MattMoney sheet does (screenshots): "If this company reaches market cap D with share count C, how many shares do I need so the position is worth F?" Norviq gets a dense web planning table and an iOS list + editor. Each row is one ticker scenario. Beside it sits a panel of recurring autobuys with a monthly equivalent.
- This is planning math only. It is not a trade recommendation and not a stop-loss sizer.
- Every surface shows the disclaimer: "Terminal prices are your assumptions, not forecasts. Not financial advice."
- Placement: a dashboard summary card and a per-stock card on stock detail (web + iOS).
- AI can fill shares outstanding and current price, suggest a scenario, and act through assistant/MCP tools. AI only ever suggests; the formulas stay deterministic and server-side.

**Decisions (user, 2026-10-09):**
- The 1.4.0 App Store run was cancelled before upload. 1.4.0 ships *with* this feature.
- AI: all three surfaces (per-row fill, scenario suggestion, assistant + MCP tools).
- The table and autobuys are free. Every AI action is Pro.
- Percent cadence: the user enters a monthly base. Monthly equivalent = base × percent. With no base, the row is left out of the total.
- "Bimonthly" means every two months (× 6/12), as specified.

## Formulas: one implementation, shared
`TerminalMath` and `AutobuyMath` live in **norviq-shared** (pure Swift). Backend and iOS run the identical code, and web renders backend-computed values. The derived values below are never stored:
- `terminalSharePrice = terminalMarketCap / terminalShareCount`
- `sharesNeeded = valueWanted * terminalShareCount / terminalMarketCap`
- `capitalAtTodayPrice = sharesNeeded * currentSharePrice` (only when a price exists)
- `progress = sharesNeeded == 0 ? 0 : sharesOwned / sharesNeeded`
- `sharesStillNeeded = max(0, sharesNeeded - sharesOwned)`
- `gapValueAtTerminal = sharesStillNeeded * terminalSharePrice`

Guardrails:
- If the share count or market cap is ≤ 0, the result is `.invalid(reason)`: no division, and the UI shows an inline error.
- Monthly equivalents: weekly × 52/12, biweekly × 26/12, bimonthly × 6/12, monthly × 1, percent → base × percent (nil if base is 0).

Tests: the 4 worked examples (AMZN 909.0909…/1100, VG 62.5/8000, SOFI 85.714…/2916.67, progress 750/1100 = 0.6818…), plus the guardrails and each monthly equivalent.

**Footer note:** "total shares-needed notional at terminal prices" always equals total value wanted, because sharesNeeded × terminalSharePrice = valueWanted. The footer shows these three instead:
- total value wanted
- total still needed at terminal prices (Σ gap)
- total capital at today's price (rows that have a price)

## 1. norviq-shared v5.21.0
- `Sources/StockPlanShared/TerminalPositions/TerminalMath.swift`: math plus `AutobuyMath`.
- `TerminalPositionsDTOs.swift`:
  - Position and autobuy create/update/response types (`<Thing>CreateRequest` / `UpdateRequest` / `Response`).
  - The update requests have all-optional fields, plus `clear: [String]?` for setting nullable fields (`sharesOutstanding`, `currentSharePrice`, `notes`, autobuy `ticker`) back to nil.
  - `AutobuyCadence` covers weekly, biweekly, bimonthly, monthly and percentOfContribution, with an `unknown` fallback for decoding.
  - A position response carries the inputs plus the derived values, which are nil when invalid, and `scenarioError`.
  - `TerminalPositionsSummaryResponse` has currency, the three totals and `monthlyAutobuyTotal`.
  - AI suggestion DTOs: `ShareFactsSuggestion` (sharesOutstanding, currentSharePrice, asOf, sources) and `TerminalScenarioSuggestion` (terminalShareCount, terminalMarketCap, rationale, sources).
- Tests in `Tests/StockPlanSharedTests/` (Swift Testing).

## 2. Backend (`norviq-backend`, new `TerminalPositions/` module, branch off `main`, separate from PR #185)
- **Models and migration:** `terminal_positions` and `autobuys`, exactly the fields in the brief (no derived columns). Index on (user_id, sort_order).
  - Ticker is uppercased and validated. Duplicate tickers are allowed, since a duplicated row is a scenario variant.
  - Negative value wanted or shares owned → 422.
  - Share count or market cap ≤ 0 is *stored*, so a half-finished edit still saves, and the response carries `scenarioError`.
- **Routes:** `/v1`, matching the house convention; the brief's `/api/...` paths map to these.
  - `GET/POST /v1/terminal-positions`
  - `PATCH/DELETE /v1/terminal-positions/:id`
  - `POST /v1/terminal-positions/:id/duplicate`
  - `PUT /v1/terminal-positions/order` (`{ids}`)
  - `GET /v1/terminal-positions/summary`
  - `GET/POST /v1/autobuys` and `PATCH/DELETE /v1/autobuys/:id`
- **Auth:** `ScopedBearerAuthenticator` + `SessionToken.guardMiddleware()`. Reads need `planningRead` and writes need `planningWrite` (`Auth/ScopeContext.swift`). Every row is user-scoped, so another user's row returns 404.
  - Templates to copy: `Dashboard/GoalsController.swift` for routes, `Financing/FinancingController.swift` + `FinancingService.swift` for layering.
  - Idempotency middleware goes on the POST routes.
- **Currency:** resolved from the user's default portfolio `PortfolioList.baseCurrency`, falling back to `MARKET_DEFAULT_CURRENCY`. It is returned in list and summary responses; the model holds plain numbers.
- **AI endpoints (Pro and rate-limited):** add a `BillingFeature.terminalPositionAI` case and check it with `requirePremium`. Also apply `aiRateLimit`.
  - `POST /v1/terminal-positions/ai/share-facts {ticker}` → `ShareFactsSuggestion`
  - `POST /v1/terminal-positions/ai/scenario {ticker, horizonYears?}` → `TerminalScenarioSuggestion`
  - Both reuse the web-search client construction from `MarketBrief/MarketBriefGenerator.live` (OpenRouter `:online`, `json_object`), with a smaller `maxTokens`.
  - Both validate the output: positive finite numbers, plus at least one https source for facts.
  - **Both only suggest and never write.** With no web search available, they return 503 "AI lookup unavailable", with no fallback that could guess numbers.
- **Assistant actions:** new `AI/ActionCatalog+TerminalPositions.swift`, appended to `ActionCatalog.all`.
  - Read-only: `get_terminal_positions`, `get_terminal_position(ticker)`, `lookup_share_facts(ticker)` (Pro).
  - Write: `set_terminal_scenario(ticker, terminalShareCount?, terminalMarketCap?, valueWanted?, sharesOwned?)`. It is flagged `destructive: true` so every surface confirms first: inline `confirm:true` in chat and MCP, an `AIPendingAction` for the assistant and Telegram. The tool description says assumptions must come from the user or cited sources.
- **Extension points, not built:** a `TerminalPositionPrefill` protocol (portfolio shares owned via `stocksRepository`, price via `marketDataService.quote`), left unimplemented in v1.
- **Docs and tests:**
  - `openapi.yaml` paths and schemas, plus an `OpenAPIDocsTests` entry.
  - Swift Testing suites: CRUD + scoping (copy the `MarketBriefRouteTests` / `MCPTokenAuthTests` helpers), guardrails, PATCH `clear`, reorder, duplicate, summary totals, Pro gate (402/upgrade error), AI parsing with a stubbed chat client (no real API calls), and action catalog confirm behaviour.

## 3. Web (`norviq-web`)
- **Client:** oapi-codegen slice `oapi-codegen-terminal.yaml` → `internal/api/terminal`, with a Makefile target chained into `oapi-codegen-local`. Auth via `middleware.BearerEditor` (pattern: `handlers/pilots.go`).
- **Page:**
  - `/terminal` lives in the Portfolio nav group (`internal/nav/nav.go`): `AppHandler.Terminal` → `renderShell`, with templ files in `internal/pages/terminal/`.
  - Page copy: title "Terminal position sizing", subtitle as specified, disclaimer under the table.
- **Table:** the columns specified. The derived columns are read-only.
  - Each edited cell sends `hx-patch` on `change delay:400ms`.
  - The handler re-renders the row and sends OOB updates for the footer, summary and inline errors (pattern: `pages/portfolio/row.templ` `hx-swap-oob`). The server is the only calculator, so the formulas aren't duplicated in JS.
  - Alpine shows compact currency on blur (10T, 1.25B) while the input holds the full number.
  - Progress is a thin bar plus a percent.
  - The "round down to whole shares" toggle is display-only Alpine state.
  - Row actions: duplicate, delete, and reorder via up/down buttons. No drag library exists, so drag-and-drop is left for later.
  - Controls use the `components.Field` / `NativeButton` wrappers, as `check-no-bare-controls.sh` requires.
- **Empty state:** the AMZN sample row, labelled "Sample", with "Use this row" (creates it) and "Dismiss" (cookie). It is never stored as user data.
- **Autobuys side panel:** list plus add/edit form and the monthly equivalent per row, plus the total. The suggested examples (401k 4%, $50 weekly, $275 bimonthly) appear as one-click chips in the empty state only.
- **AI (Pro):**
  - "Fill with AI" per row shows the suggested shares outstanding and price with source links. They are applied only when the user clicks Accept.
  - "Suggest scenario" works the same way for share count and market cap.
  - Non-Pro users see the upgrade prompt.
- **Dashboard and stock pages:**
  - `TerminalSummaryShell` on `/dashboard` (`command_center.templ`): total value wanted, the top 3 rows with progress, and the monthly autobuy total.
  - `/portfolio/{symbol}/terminal` card in the stock overview aside (next to `PressureShell`): that ticker's price, shares needed and progress, or "Add terminal scenario".
- **Formatter:** new shared `internal/format` package covering compact currency with T and code → symbol mapping. It replaces nothing yet.
- **Tests:** handler tests against a fake backend (`news_ticker_test.go` / `pilots_test.go` patterns), nav test, `templ generate`, `GOFLAGS=-mod=mod make test check`.

## 4. MCP (`norviq-mcp`)
- Register `get_terminal_positions`, `get_terminal_position` (ReadOnlyHint) and `set_terminal_scenario`.
- `set_terminal_scenario` is a write tool: add it to `writeToolNames`, and it goes through `confirmMutation`. Clients without elicitation support lose it.
- Run `make catalog-snapshot` so the parity test passes.

## 5. iOS 1.4.0 (`norviq-ios`)
- **Package pin:** StockPlanShared 5.18.0 → 5.21.0 (`project.pbxproj`). This also brings in the 5.19 Articles and 5.20 brief DTOs; the build must stay green.
- **Code:** `Features/TerminalPositions/`, copying the GoalPlanning pattern.
  - `TerminalPositionsServicing` + endpoints + `Container+TerminalPositionsFactories`.
  - An `@Observable` view model.
  - `TerminalPositionsScreen`: the row shows terminal share price and shares needed first, plus a progress bar. Swipe to delete or duplicate, and `onMove` for reorder (the first in the app).
  - `TerminalPositionEditorSheet`: live preview through the shared `TerminalMath` and inline guardrail errors. Large numbers use a value field plus a unit picker (—/M/B/T), parsed with `Utilities/MoneyInputParser`, which handles pt-PT commas. Includes the round-down toggle and the Pro-gated AI buttons (`ProGateView`).
  - Autobuys section with the monthly total.
- **Entry points:**
  - `PortfolioRoot` Planning menu route.
  - `TerminalDashboardCard`, next to `GoalPlanningDashboardCard` in `DashboardRoot`.
  - `StockTerminalCard(symbol:)` in `StockOverviewTab`, self-loading like `StockPressureCard`.
- **Copy:** English plus pt-PT in `Localizable.xcstrings`, with the disclaimer on the screen and the editor.
- **Tests:** XCTest view model tests with a mock service; the maths is already covered in shared.
- **Release notes:** `fastlane/metadata/en-US/release_notes.txt` gets a lead bullet "Terminal position sizing — set a future market cap and share count, see how many shares your target takes (assumptions, not advice)", above the invite and share-card bullets.

## Order and release gates
1. Shared v5.21.0: math and DTOs, with the 4 examples passing.
2. Backend PR. The user merges, then staging deploy (manual dispatch), then promote to production with `-f service=both`.
3. Web PR, then MCP PR (both follow the same merge → staging → promote).
4. iOS PR (pin, feature, notes). Merging to main triggers TestFlight automatically.
5. **Dispatch the 1.4.0 App Store release only after production serves `/v1/terminal-positions`.** The app talks to the production API, so a review build must not hit a 404.
- Sequencing after approval: write the spec to `norviq-backend/docs/superpowers/specs/2026-10-09-terminal-position-sizing-design.md`, then per-repo implementation plans (writing-plans), executed natively like the market brief.

## Verification
- **Shared:** `swift test`, including the four worked examples.
- **Backend:** new suites plus the full suite on Postgres + Redis containers; `make backend-openapi-check`.
- **Staging:** `curl` CRUD and summary with a PAT; the AI endpoints with the staging OpenRouter key, or a check that they return 503 without it.
- **Web:** `templ generate && GOFLAGS=-mod=mod make test check`; manual pass on `/terminal` (edit a cell, see the row and footer update; zero share count shows the inline error; compact formatting on blur; reorder; duplicate; sample row; autobuy totals), the dashboard card and the stock card, in en and pt-PT.
- **iOS:** `make ios-test`; in the simulator, create the AMZN example and see 909.09 / 1,100; owned 750 shows 68.18%; round-down toggle; pt-PT comma input; reorder; dashboard and stock cards.
- **MCP:** parity test, plus a manual `set_terminal_scenario` asking for confirmation.

## Risks
- **Four repos and one App Store review in one push.** It's the biggest feature this cycle. The gate in step 5 prevents a broken review build.
- **AI numbers may be wrong.** They are suggestions with sources, never saved without Accept, and they never write market cap or value wanted.
- **OpenRouter credits.** The AI endpoints 503 if the `:online` call fails. The feature itself works without AI.
- **Supply-side work with the strangers-count at 0** (user rule). It is free and sits on the dashboard, so it can serve as a reason to sign up.
