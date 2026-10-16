# Recap Engine (shared + backend) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compute, store and serve a per-user monthly or yearly recap deck: activity facts → investor-personality archetype → ordered slides. Exposed as `/v1/recaps` behind `RECAP_ENABLED`.

**Architecture:**
- The DTOs (`RecapDeck`, `RecapSlide`, `RecapArchetype` with its copy, `RecapShareCard`) live in norviq-shared v5.23.0. Backend, iOS and web all use the same shapes and the same archetype copy.
- Three pure, DB-free units:
  - `RecapPeriod` handles keys, bounds and time zones.
  - `PersonalityClassifier` maps `RecapFacts` to an archetype.
  - `RecapDeckBuilder` maps `RecapFacts` to a `RecapDeck`.
- `RecapFactsCollector` is the only code that reads activity tables.
- `RecapService` handles availability, generate-once and persistence through `RecapRepository`. A thin `RecapController` sits on top.

**Tech Stack:** Swift 6, Vapor 4, Fluent/Postgres, Swift Testing, norviq-shared (`StockPlanShared`).

**Spec:** `docs/superpowers/specs/2026-10-16-recap-design.md`. This is plan 1 of 4: (1) engine, (2) delivery: jobs, push, email, preferences, unsubscribe, (3) web: story, share links, public page, PNG, (4) iOS. `recap_shares`, `recap_email_deliveries`, the jobs and the share endpoints belong to plans 2 and 3, **not here**.

## Global Constraints

**Repositories and branches**
- **Backend:** work in the worktree `~/Work/production/apps/norviq/norviq-backend-recap`, branch `feat/recap`, cut from `origin/main` at 0b3d7bc. Never touch the `norviq-backend` checkout, which is on someone else's `feat/hermes-top-position-symbols` branch.
- **Shared:** work in `~/Work/production/apps/norviq/norviq-shared` on branch `feat/recap-dtos`, cut from `main`. The new tag is **v5.23.0**; the latest is v5.22.0.
  - Until v5.23.0 is pushed, build the backend with `STOCKPLAN_SHARED_PATH=~/Work/production/apps/norviq/norviq-shared`.
  - Do not commit `Package.resolved` while building in path mode.

**Domain rules**
- Period keys: month `YYYY-MM` (`2026-10`), year `YYYY` (`2026`). Kinds are `month` and `year`. Anything else → 404.
- A period is **available** only once it has ended in the user's time zone, its end is at most **13 months** before now, and it starts no earlier than the month or year of the user's `createdAt`. Anything else → 404.
- `year` additionally requires `RECAP_YEARLY_ENABLED=true`. Every route requires `RECAP_ENABLED=true`. When a flag is off, the routes answer **404**, not 403, and leak nothing.
- User time zone: `timeZone` of the user's latest `GamificationCheckIn` (by `localDate` desc). If it is missing or not a valid `TimeZone` identifier, use UTC.
- Generate once: after a recap row exists, it is returned unchanged forever, even if the underlying data changes later.
- Money amounts are always lists of `RecapMoney(amount, currency)`. **Never add amounts across currencies.**
- Slides that are `isPrivate` are growth, dividends and goals. `RecapShareCard` has **no money fields and no name field**.

**Tests and commits**
- Swift Testing. DB tests use the local test Postgres on **:55432** and Redis on **:56379**. Check first:
  `docker ps --format '{{.Names}} {{.Ports}}' | grep -E '55432|56379'` and `df -h`.
  Env: `TEST_DATABASE_PORT=55432 REDIS_URL=redis://localhost:56379`, plus the credentials of whatever container is running (the memory note `norviq-backend-local-test-db` has the docker-inspect line). A worktree has no `.env`; source the main checkout's.
- Run one suite: `TEST_DATABASE_PORT=55432 LOG_LEVEL=warning swift test --filter <Suite>`.
- **Lint before every commit:** `swiftformat <touched files>` then `swiftlint lint`. Never write `allSatisfy(\.x)` inside `#expect`. Never combine `try await` with `==` inside `#expect`; assign to a `let` first.
- **After every commit:** run `git show --stat HEAD`. If the pre-commit hook reformatted unrelated files, restore them and recommit with `--no-verify`.

## Review Focus
1. **A user in `America/Los_Angeles` with a trade at 2026-10-31 23:30 local.** It counts in October, not November, even though it is already November in UTC (Task 2 and Task 5).
2. **Dividends in USD and EUR in the same month.** The slide shows two amounts, never a sum (Task 5).
3. **Two concurrent `GET /v1/recaps/month/2026-10` requests for a recap that doesn't exist yet.** Both return 200 with the same deck, and there is exactly one row (Task 6).
4. **`GET /v1/recaps/month/2026-11` while it is still November in the user's time zone, or `month/2024-01`, or `month/2026-13`.** All → 404, and nothing is generated (Task 6 and Task 7).
5. **A brand-new user with no activity at all opening last month.** They get the missed-you deck (intro, missedYou, outro), not a crash or an empty deck (Task 4 and Task 7).

---

### Task 1: Recap DTOs (norviq-shared v5.23.0)

**Files:**
- Create: `norviq-shared/Sources/StockPlanShared/Recap/RecapDTOs.swift`
- Create: `norviq-shared/Sources/StockPlanShared/Recap/RecapArchetype.swift`
- Test: `norviq-shared/Tests/StockPlanSharedTests/RecapDTOsTests.swift`

**Interfaces:**
- Produces (all `public`, `Codable, Sendable, Equatable`, with explicit public inits; numbers are `Double`, matching the existing DTOs):
  - `enum RecapPeriodKind: String { case month, year }`
  - `struct RecapMoney { amount: Double; currency: String }`
  - `struct RecapTickerStat { symbol: String; touches: Int }`
  - `struct RecapBadge { type: String; tier: String }`
  - `struct RecapGrowth { currency: String; startValue: Double; endValue: Double }`
  - The slide payload structs:
    - `RecapIntroSlide { periodLabel: String; activeDays: Int }`
    - `RecapStreakSlide { longestStreakDays: Int; activeDays: Int }`
    - `RecapTopTickersSlide { tickers: [RecapTickerStat] }`
    - `RecapTradesSlide { tradeCount: Int; buyCount: Int; sellCount: Int; mostTradedSymbol: String? }`
    - `RecapResearchSlide { notesWritten: Int; watchlistAdded: Int; targetsSet: Int; targetsHit: Int }`
    - `RecapGrowthSlide { growth: [RecapGrowth] }`
    - `RecapDividendsSlide { received: [RecapMoney]; paymentCount: Int; payerCount: Int }`
    - `RecapGoalsSlide { contributed: [RecapMoney]; contributionCount: Int }`
    - `RecapBadgesSlide { badges: [RecapBadge]; xpEarned: Int }`
    - `RecapPersonalitySlide { archetype: RecapArchetype }`
    - `RecapMissedYouSlide { bestStreakDays: Int; totalBadges: Int }`
    - `RecapOutroSlide { isFirstChapter: Bool; nextPeriodLabel: String }`
  - `enum RecapSlide` with cases `intro, streak, topTickers, trades, research, growth, dividends, goals, badges, personality, missedYou, outro`, one associated payload each, and `var isPrivate: Bool` (true only for `growth`, `dividends`, `goals`).
    - Coding follows the `ScenarioConfiguration` pattern (`Scenarios/ScenarioDTOs.swift:226`): `{"type": "<case>", "<case>": {payload}}`. JSON keys are snake_case where the case is multi-word (`top_tickers`, `missed_you`). An unknown `type` → `DecodingError`.
  - `struct RecapDeck { kind: RecapPeriodKind; key: String; periodLabel: String; archetype: RecapArchetype?; isFirstChapter: Bool; isMissedYou: Bool; slides: [RecapSlide]; schemaVersion: Int }`
  - `struct RecapResponse { id: UUID; deck: RecapDeck; generatedAt: Date; openedAt: Date?; completedAt: Date? }`
  - `struct RecapSummary { kind: RecapPeriodKind; key: String; periodLabel: String; id: UUID?; generated: Bool; openedAt: Date?; completedAt: Date? }` and `struct RecapListResponse { recaps: [RecapSummary] }`
  - `struct RecapShareCard { kind: RecapPeriodKind; periodLabel: String; archetype: RecapArchetype; longestStreakDays: Int; tickersResearched: Int; badgesEarned: Int }`. It has no money fields and no name.
  - `enum RecapArchetype: String, CaseIterable` with `var title: String` and `var tagline: String`. These are the **draft copy below, which needs Fernando's verdict before prod**:

    | case (raw) | title | tagline |
    |---|---|---|
    | `copycat_strategist` | The Copycat Strategist | You studied the pros and moved with them. |
    | `dividend_farmer` | The Dividend Farmer | You planted shares and harvested payouts. |
    | `saver` | The Saver | Steady deposits, goal by goal. |
    | `comeback_kid` | The Comeback Kid | Slow start, strong finish. |
    | `ticker_hunter` | The Ticker Hunter | No chart went unturned. |
    | `researcher` | The Researcher | Thesis first, trade later. |
    | `disciplined_sizer` | The Disciplined Sizer | Targets set, emotions parked. |
    | `patient_planner` | The Patient Planner | You showed up often and traded rarely. |
    | `steady_builder` | The Steady Builder | Brick by brick, you built the habit. |

- [ ] **Step 1: Write failing tests** in `RecapDTOsTests`:
  - `slideRoundTrip`: every `RecapSlide` case encodes and decodes back equal. Build a sample array covering all 12 cases.
  - `slideWireShape`: encoding `.topTickers(RecapTopTickersSlide(tickers: [RecapTickerStat(symbol: "AAPL", touches: 3)]))` with a plain `JSONEncoder` → the JSON object has `type == "top_tickers"` and a `top_tickers.tickers[0].symbol == "AAPL"` key path.
  - `unknownSlideTypeFails`: `{"type":"confetti"}` → decoding throws.
  - `privacyFlags`: `isPrivate` is true only for `growth`, `dividends`, `goals`.
  - `shareCardHasNoMoneyOrName`: the property labels from `Mirror(reflecting:)` of a sample `RecapShareCard` equal exactly `["kind", "periodLabel", "archetype", "longestStreakDays", "tickersResearched", "badgesEarned"]`.
  - `archetypeCopy`: every `RecapArchetype.allCases` has a non-empty `title` and `tagline`, and there are 9 cases.
- [ ] **Step 2: Run** `swift test --filter RecapDTOsTests` in norviq-shared. Expected: FAIL (types not defined).
- [ ] **Step 3: Implement** both files to match the Interfaces block.
- [ ] **Step 4: Run** `swift test --filter RecapDTOsTests`. Expected: PASS. Then run `swift test`; the whole package stays green.
- [ ] **Step 5: Commit** on `feat/recap-dtos`: `feat(recap): add recap deck, slide and archetype DTOs`. **Do not tag yet.** The tag is cut in Task 8, after the backend has proven the shapes in path mode.

---

### Task 2: RecapPeriod (backend, pure)

**Files:**
- Create: `Sources/StockPlanBackend/Recap/RecapPeriod.swift`
- Test: `Tests/StockPlanBackendTests/RecapPeriodTests.swift`

**Interfaces:**
- Consumes: `RecapPeriodKind` (Task 1).
- Produces: `struct RecapPeriod: Equatable, Sendable`:
  - `static func parse(kind: String, key: String) -> RecapPeriod?`
  - `let kind: RecapPeriodKind`, `let year: Int`, `let month: Int?`, `var key: String`
  - `func bounds(in timeZone: TimeZone) -> (start: Date, end: Date)`. The range is half-open [start, end), with start at local midnight on the 1st.
  - `func localDateRange() -> (first: String, last: String)`, as `yyyy-MM-dd` strings for filtering `GamificationCheckIn.localDate`.
  - `var label: String`: `"October 2026"` / `"2026"`, using an en_US_POSIX month name.
  - `var next: RecapPeriod`
  - `static func lastClosedMonth(now: Date, in: TimeZone) -> RecapPeriod`
  - `static func lastClosedYear(now: Date, in: TimeZone) -> RecapPeriod`
  - `func isAvailable(now: Date, timeZone: TimeZone, userCreatedAt: Date) -> Bool`, following the availability rule in Global Constraints.

- [ ] **Step 1: Write failing tests** (`@Suite("Recap period")`):
  - `parse`:
    - `("month","2026-10")` → year 2026, month 10.
    - `("year","2026")` → year 2026, month nil.
    - nil for `("month","2026-13")`, `("month","2026-1")`, `("week","2026-10")`, `("year","26")`.
  - `boundsRespectTimeZone`: `month 2026-10` in `America/Los_Angeles`:
    - start == `2026-10-01T07:00:00Z`.
    - end == `2026-11-01T07:00:00Z`.
  - `decemberRollsYear`: `month 2026-12`.next == `month 2027-01`. `year 2026`.next == `year 2027`.
  - `availability`. User created `2026-03-10`, zone `Asia/Tokyo`, now `2026-11-01T00:30:00+09:00`:
    - `2026-10` is available.
    - `2026-11` is not available (not ended).
    - `2026-02` is not available (before signup month).
    - `2025-09` is not available (more than 13 months ago).
    - `year 2026` is not available (not ended).
  - `localDateRange`: `month 2026-02` → `("2026-02-01","2026-02-28")`.
- [ ] **Step 2: Run** `swift test --filter RecapPeriodTests`. Expected: FAIL.
- [ ] **Step 3: Implement** with `Calendar(identifier: .gregorian)`, setting `calendar.timeZone` per call.
- [ ] **Step 4: Run** the same filter. Expected: PASS.
- [ ] **Step 5: Lint, then commit** `feat(recap): add RecapPeriod with time-zone bounds and availability`.

---

### Task 3: RecapFacts + PersonalityClassifier (pure)

**Files:**
- Create: `Sources/StockPlanBackend/Recap/RecapFacts.swift`
- Create: `Sources/StockPlanBackend/Recap/PersonalityClassifier.swift`
- Test: `Tests/StockPlanBackendTests/PersonalityClassifierTests.swift`

**Interfaces:**
- Produces `struct RecapFacts: Equatable, Sendable`. Every field has a zero default, so tests write `RecapFacts(activeDays: 12)`:
  - `activeDays: Int`, `activeDaysFirstHalf: Int`, `activeDaysSecondHalf: Int`, `longestStreakDays: Int`
  - `tradeCount: Int`, `buyCount: Int`, `sellCount: Int`, `tradesBySymbol: [String: Int]`
  - `researchTouchesBySymbol: [String: Int]`, built from watchlist adds, research notes, targets, position memos and stocks added
  - `notesWritten: Int`, `watchlistAdded: Int`, `targetsSet: Int`, `targetsHit: Int`
  - `growth: [RecapGrowth]`
  - `dividendsReceived: [RecapMoney]`, `dividendPayments: Int`, `dividendPayers: Int`
  - `goalContributions: [RecapMoney]`, `goalContributionCount: Int`
  - `badgesEarned: [RecapBadge]`, `xpEarned: Int`
  - `pilotFollows: Int`, `boardPosts: Int`, `boardComments: Int`, `aiRequests: Int`, `expensesRecorded: Int`
  - `bestStreakEverDays: Int`, `totalBadgesEver: Int` (for the missed-you slide)
  - `var hasAnyActivity: Bool`: true if `activeDays > 0` or any count above is > 0.
- Produces `enum PersonalityClassifier { static func classify(_ facts: RecapFacts, kind: RecapPeriodKind) -> RecapArchetype }`.
  - Ordered rules, first match wins. Thresholds are written for `month`. For `year`, every threshold is multiplied by **4**, except the ratio in comeback_kid.

  | # | archetype | rule (month) |
  |---|---|---|
  | 1 | copycat_strategist | `pilotFollows >= 2` |
  | 2 | dividend_farmer | `dividendPayments >= 3` |
  | 3 | saver | `goalContributionCount >= 3` |
  | 4 | comeback_kid | `activeDaysSecondHalf >= 5 && activeDaysSecondHalf >= 2 * activeDaysFirstHalf` |
  | 5 | ticker_hunter | `researchTouchesBySymbol.count >= 10` |
  | 6 | researcher | `notesWritten + targetsSet >= 5` |
  | 7 | disciplined_sizer | `targetsSet >= 3` |
  | 8 | patient_planner | `activeDays >= 10 && tradeCount <= 2` |
  | 9 | steady_builder | default |

  - Night Owl is dropped: there are no per-user app-use timestamps (see the spec gap list).

- [ ] **Step 1: Write failing tests** (`@Suite("Personality classifier")`):
  - One `@Test(arguments:)` table with one row per archetype, each with the minimal facts that hit its rule.
  - `firstMatchWins`: `pilotFollows: 2, dividendPayments: 5` → `copycat_strategist`.
  - `yearScalesThresholds`: `dividendPayments: 3` → `dividend_farmer` for `.month`, but `steady_builder` for `.year`. `dividendPayments: 12` with `.year` → `dividend_farmer`.
  - `emptyFactsDefault`: `RecapFacts()` → `steady_builder`.
- [ ] **Step 2: Run** `swift test --filter PersonalityClassifierTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Keep the rule table as a single `static let rules: [(RecapArchetype, (RecapFacts, Int) -> Bool)]`, where the `Int` is the multiplier, so Fernando can reorder it in one place.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Lint, then commit** `feat(recap): add RecapFacts and rule-based PersonalityClassifier`.

---

### Task 4: RecapDeckBuilder (pure)

**Files:**
- Create: `Sources/StockPlanBackend/Recap/RecapDeckBuilder.swift`
- Test: `Tests/StockPlanBackendTests/RecapDeckBuilderTests.swift`

**Interfaces:**
- Consumes: `RecapFacts`, `PersonalityClassifier` (Task 3); `RecapPeriod` (Task 2); DTOs (Task 1).
- Produces:
  - `enum RecapDeckBuilder { static let schemaVersion = 1; static let minFullDeckSlides = 4; static let minFullDeckActiveDays = 7; static func build(facts: RecapFacts, period: RecapPeriod) -> RecapDeck }`

**Middle slides, in canonical order, each with its eligibility rule:**

| slide | eligible when | payload |
|---|---|---|
| streak | `longestStreakDays >= 2` | |
| topTickers | `researchTouchesBySymbol.count >= 3` | top 5 by touches, ties broken by symbol ascending |
| trades | `tradeCount >= 1` | `mostTradedSymbol` = max of `tradesBySymbol`, ties broken by symbol ascending |
| research | `notesWritten + watchlistAdded + targetsSet >= 1` | |
| growth | `!growth.isEmpty` | |
| dividends | `dividendPayments >= 1` | |
| goals | `goalContributionCount >= 1` | |
| badges | `!badgesEarned.isEmpty` | |

**Deck shapes:**
- `!facts.hasAnyActivity`: `[intro, missedYou(bestStreakEverDays, totalBadgesEver), outro(isFirstChapter: false)]`. `isMissedYou = true`, `archetype = nil`.
- Eligible middle slides ≥ `minFullDeckSlides` **and** `activeDays >= minFullDeckActiveDays`: `[intro] + all eligible + [personality(classify), outro(isFirstChapter: false)]`. `archetype` is set.
- Otherwise ("first chapter"): `[intro] + first 2 eligible + [outro(isFirstChapter: true)]`. `isFirstChapter = true`, `archetype = nil`.
- `outro.nextPeriodLabel = period.next.label`. `intro.periodLabel = period.label`.

- [ ] **Step 1: Write failing tests** (`@Suite("Recap deck builder")`):
  - `missedYou`: `RecapFacts(bestStreakEverDays: 9, totalBadgesEver: 2)` → slide types `[intro, missedYou, outro]`, `isMissedYou == true`.
  - `fullDeckOrderAndPersonality`: facts eligible for all 8 middle slides with `activeDays: 20` → types `[intro, streak, topTickers, trades, research, growth, dividends, goals, badges, personality, outro]`, and `archetype != nil`.
  - `firstChapterWhenFewSlides`: only streak + trades eligible, `activeDays: 20` → `[intro, streak, trades, outro]`, `isFirstChapter == true`, `archetype == nil`.
  - `firstChapterWhenFewDays`: 5 eligible slides but `activeDays: 6` → first chapter, with only the first 2 eligible slides.
  - `topTickersCapAndTieBreak`: 7 symbols, where `MSFT` and `AAPL` tie at 4 → 5 entries, with `AAPL` before `MSFT`.
  - `nextLabel`: `month 2026-12` → `outro.nextPeriodLabel == "January 2027"`.
- [ ] **Step 2: Run** `swift test --filter RecapDeckBuilderTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Lint, then commit** `feat(recap): add RecapDeckBuilder with full, first-chapter and missed-you decks`.

---

### Task 5: RecapFactsCollector (DB)

**Files:**
- Create: `Sources/StockPlanBackend/Recap/RecapFactsCollector.swift`
- Create: `Sources/StockPlanBackend/Recap/RecapTimeZoneResolver.swift`
- Test: `Tests/StockPlanBackendTests/RecapFactsCollectorTests.swift`
- Test: `Tests/StockPlanBackendTests/RecapFixtures.swift` (an app wrapper modeled on `TerminalPositionsFixtures.swift:10`; registers a user and returns `(app, token, userId)`)

**Interfaces:**
- Consumes: `RecapPeriod`, `RecapFacts`.
- Produces:
  - `enum RecapTimeZoneResolver { static func timeZone(for userId: UUID, on db: any Database) async throws -> TimeZone }`
  - `enum RecapStreaks { static func longest(localDates: [String]) -> Int }` (pure; counts consecutive calendar days, ignores duplicates)
  - `struct RecapFactsCollector: Sendable { func collect(userId: UUID, period: RecapPeriod, timeZone: TimeZone, on db: any Database) async throws -> RecapFacts }`

**Sources** (the period is `bounds(in: timeZone)`, half-open). Model names come from the exploration:

| fact | source |
|---|---|
| active days, both halves, longest streak | `GamificationCheckIn.localDate` within `localDateRange()`. "Halves": month = days 1–15 vs 16–end; year = Jan–Jun vs Jul–Dec. |
| `bestStreakEverDays` | `RecapStreaks.longest` over all of the user's check-ins |
| trades | `Transaction` joined to `Account.userId` and `Instrument.symbol`, `tradeDate` in range, `type` in `"BUY"`, `"SELL"` |
| research touches | `WatchlistItem.createdAt` (symbol), `ResearchNote.createdAt`, `Target` (created in range), `PositionMemo.createdAt` (`primarySymbol`), `Stock.createdAt` (symbol). Symbols are uppercased. |
| `targetsHit` | `Target.alertTriggeredAt` in range |
| growth | `PortfolioValueSnapshot`: for each currency, sum `marketValue` on the earliest `capturedOn` in range and on the latest. Emitted only if the two dates differ. |
| dividends | `Dividend` via `Account.userId`, `payDate` in range: grouped by currency, payments counted, payers = distinct `instrumentId` |
| goals | `GoalContributionModel.userId`, `occurredAt` in range, grouped by currency (the currency comes from the parent goal; if the goal has no currency field, use the user's base currency or `"USD"` and note it in the commit) |
| badges, XP | `UserBadge.earnedAt` in range; sum of `GamificationXPEvent.points` by `createdAt`. `totalBadgesEver` = count of all badges. |
| social / other | `PilotFollow.createdAt`, `BoardPost` / `BoardCommentRecord` by `authorId` (excluding soft-deleted), `AIAssistantUsage.requestCount` where `monthStart` in range, `Expense` count by `occurredOn` via `\.$user.$id` |

**Not included:** realized P&L. Lot-level accounting edge cases risk stating wrong numbers, which the spec lists as an anti-goal. **`net_worth_snapshots` is never read** (it's global, with no `user_id`).

- [ ] **Step 1: Write failing tests**
  - Pure (`@Suite("Recap streaks")`):
    - `["2026-10-01","2026-10-02","2026-10-02","2026-10-04"]` → 2.
    - `[]` → 0.
    - `["2026-12-31","2027-01-01"]` → 2.
  - DB (`@Suite("Recap facts collector", .serialized)`). Each test seeds rows for its user and also one row in October **for a second user**, and asserts that row is excluded:
    - `timeZoneBoundary`: zone `America/Los_Angeles` (via a check-in). A BUY with `tradeDate` `2026-11-01T06:30:00Z` (Oct 31, 23:30 local) → `tradeCount == 1` for `month 2026-10` and `0` for `2026-11`.
    - `dividendsNeverSummedAcrossCurrencies`: USD 10 + USD 5 + EUR 7 → `dividendsReceived` contains `RecapMoney(15, "USD")` and `RecapMoney(7, "EUR")`, `dividendPayments == 3`.
    - `growthFirstVsLastSnapshot`: two lists, snapshots on Oct 2 and Oct 30 → one `RecapGrowth` with summed start and end values.
    - `researchTouchesUppercase`: watchlist `aapl`, note `AAPL` → `researchTouchesBySymbol["AAPL"] == 2`.
    - `timeZoneFallback`: no check-ins → `RecapTimeZoneResolver` returns UTC. A check-in with `timeZone: "Mars/Base"` → UTC.
- [ ] **Step 2: Run** `swift test --filter RecapStreaks` and `--filter RecapFactsCollector`. Expected: FAIL.
- [ ] **Step 3: Implement.** Use one Fluent query per source. Use joins rather than per-row lookups, and do no N+1 queries.
- [ ] **Step 4: Run both filters.** Expected: PASS.
- [ ] **Step 5: Lint, then commit** `feat(recap): collect period-bounded activity facts per user`.

---

### Task 6: Persistence + RecapService

**Files:**
- Create: `Sources/StockPlanBackend/Migrations/CreateRecaps.swift`
- Create: `Sources/StockPlanBackend/Recap/RecapRecord.swift`
- Create: `Sources/StockPlanBackend/Recap/RecapRepository.swift`
- Create: `Sources/StockPlanBackend/Recap/RecapService.swift`
- Create: `Sources/StockPlanBackend/Recap/Recap+Application.swift`
- Modify: `Sources/StockPlanBackend/ConfigureBootstrap.swift`, appending `app.migrations.add(CreateRecaps())` after line 450
- Test: `Tests/StockPlanBackendTests/RecapServiceTests.swift`

**Interfaces:**
- Consumes: Tasks 2–5.
- Produces:
  - **Table `recaps`:**
    - `id` uuid
    - `user_id` uuid, required, references `users.id` with `onDelete: .cascade`
    - `period_kind` string
    - `period_key` string
    - `payload` string (JSON-encoded `RecapDeck`, the same approach as `market_briefs.payload`)
    - `archetype` string, optional
    - `schema_version` int
    - `generated_at` datetime
    - `opened_at` datetime, optional
    - `completed_at` datetime, optional
    - `.unique(on: "user_id", "period_kind", "period_key")`, plus an index on `user_id`
  - `final class RecapRecord: Model`, with `func deck() throws -> RecapDeck` and `func response() throws -> RecapResponse`.
  - `protocol RecapRepository: Sendable`:
    - `find(userId:kind:key:on:) async throws -> RecapRecord?`
    - `find(id:userId:on:) async throws -> RecapRecord?`
    - `insertOrFetch(_ record: RecapRecord, on:) async throws -> RecapRecord`. On a unique-constraint violation it re-fetches and returns the existing row.
    - `list(userId:on:) async throws -> [RecapRecord]`, newest `generated_at` first.
  - `struct DatabaseRecapRepository: RecapRepository`
  - `app.recapRepository` (pattern: `MarketBrief/MarketBrief+Application.swift`)
  - `struct RecapService: Sendable`:
    - `init(repository: any RecapRepository, collector: RecapFactsCollector = .init(), config: RecapConfig)`
    - `func recap(userId: UUID, period: RecapPeriod, now: Date, on db: any Database) async throws -> RecapResponse?`. Returns nil when the recap isn't available (→ the controller answers 404). Otherwise it returns the stored row, or collects, builds and stores via `insertOrFetch`.
    - `func list(userId: UUID, now: Date, on db: any Database) async throws -> RecapListResponse`. It returns the stored recaps, plus an un-generated entry (`generated: false`, `id: nil`) for `lastClosedMonth` (and for `lastClosedYear` when yearly is enabled) if no row exists for them and they are available. It never generates.
    - `func markOpened(id: UUID, userId: UUID, now: Date, on:) async throws -> Bool` and `markCompleted(...)`. Both set the timestamp only if it is nil, and return false when the recap isn't found or belongs to someone else.
  - `struct RecapConfig: Sendable { let enabled: Bool; let yearlyEnabled: Bool; static func fromEnvironment() -> RecapConfig }`. It reads `RECAP_ENABLED` and `RECAP_YEARLY_ENABLED`; only `"true"` turns a flag on.

- [ ] **Step 1: Write failing tests** (`@Suite("Recap service", .serialized)`, DB):
  - `generatesOnceAndFreezes`: seed one BUY in Oct and call `recap(... 2026-10, now: Nov 2)`. Then add another BUY in Oct and call again → the same `id`, and the deck's trades slide still shows `tradeCount == 1`.
  - `concurrentFirstOpenMakesOneRow`: two `recap` calls run concurrently in `withThrowingTaskGroup` → equal ids, and `RecapRecord.query` count == 1.
  - `unavailableReturnsNil`: Nov while it is still Nov 20 → nil, and no row is written.
  - `yearlyNeedsFlag`: `year 2026`, now `2027-01-02`, `yearlyEnabled: false` → nil; `true` → a deck.
  - `listShowsUngeneratedLastMonth`: a new user created `2026-09-01`, now `2026-11-02` → the list contains `RecapSummary(kind: .month, key: "2026-10", generated: false)` and no row exists afterwards.
  - `markOpenedOwnership`: another user's id → false. Own id → true, and a second call keeps the first timestamp.
- [ ] **Step 2: Run** `swift test --filter RecapServiceTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** For `insertOrFetch`, catch the Postgres unique violation (`PSQLError` code `23505`; look for an existing helper first: `grep -rn "23505\|uniqueViolation" Sources`) and re-fetch.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Lint, then commit** `feat(recap): persist recaps once per user and period`.

---

### Task 7: RecapController, routes, OpenAPI

**Files:**
- Create: `Sources/StockPlanBackend/Recap/RecapController.swift`
- Modify: `Sources/StockPlanBackend/routes.swift`, adding `try api.register(collection: RecapController())` next to line 170
- Modify: `Sources/StockPlanBackend/openapi.yaml`
- Test: `Tests/StockPlanBackendTests/RecapRouteTests.swift`
- Test: `Tests/StockPlanBackendTests/OpenAPIDocsTests.swift`, adding `recapsAreDocumented` after `terminalPositionsAreDocumented` (:399)

**Interfaces:**
- Consumes: `RecapService`, `RecapConfig`, `app.recapRepository` (Task 6).
- Produces the routes. All are grouped `ScopedBearerAuthenticator(), SessionToken.guardMiddleware()`, and the user id comes from `req.auth.require(SessionToken.self).userId`:

  | method + path | scope | success | operationId |
  |---|---|---|---|
  | `GET /v1/recaps` | `.planningRead` | 200 `RecapListResponse` | `listRecaps` |
  | `GET /v1/recaps/:kind/:key` | `.planningRead` | 200 `RecapResponse` | `getRecap` |
  | `POST /v1/recaps/:id/opened` | `.planningWrite` | 204 | `markRecapOpened` |
  | `POST /v1/recaps/:id/completed` | `.planningWrite` | 204 | `markRecapCompleted` |

  - `RECAP_ENABLED` off → 404 on every route.
  - Bad kind or key, or an unavailable period → 404.
  - An unknown or foreign id on opened/completed → 404.
  - Add `extension RecapListResponse: @retroactive Content {}` and the same for `RecapResponse`.
  - OpenAPI schemas: `RecapListResponse`, `RecapSummary`, `RecapResponse`, `RecapDeck`, `RecapSlide` (a `oneOf` with a `type` discriminator), `RecapMoney`, `RecapArchetype` (an enum of the 9 raw values).

- [ ] **Step 1: Write failing tests** (`@Suite("Recap routes", .serialized)`, using `RecapFixtures`, with the env set via `setenv` inside the fixture and restored afterwards):
  - `disabledIs404`: `RECAP_ENABLED` unset → `GET v1/recaps` returns 404.
  - `unauthenticatedIs401`: no token → 401.
  - `brandNewUserGetsMissedYou`: a fresh user whose `createdAt` is forced to last month → `GET v1/recaps/month/<lastMonth>` returns 200, and the slide types are `[intro, missedYou, outro]`.
  - `badKeysAre404`: `month/2026-13`, `week/2026-10`, and the current month → 404.
  - `openedThenCompleted`: GET the deck, POST opened → 204, POST completed → 204; `GET v1/recaps` shows both timestamps.
  - `foreignIdIs404`: user B posts opened on user A's recap id → 404.
  - `recapsAreDocumented` in OpenAPIDocsTests: the operationIds `listRecaps`, `getRecap`, `markRecapOpened`, `markRecapCompleted` and the schema names `    RecapDeck:` and `    RecapSlide:` are present.
- [ ] **Step 2: Run** `swift test --filter RecapRouteTests` and `--filter OpenAPIDocsTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the controller and the OpenAPI additions. Check that the YAML stays valid: `swift build` runs the openapi-generator plugin and fails on invalid YAML.
- [ ] **Step 4: Run both filters, then the full suite** `swift test` (check `df -h` first). Expected: all PASS.
- [ ] **Step 5: Lint, then commit** `feat(recap): expose /v1/recaps behind RECAP_ENABLED`.

---

### Task 8: Release the shared tag, pin the backend, set staging flags

**Files:**
- Modify: `norviq-backend-recap/Package.swift:5-9`, changing `exact: "5.22.0"` to `exact: "5.23.0"`
- Modify: `norviq-backend-recap/Package.resolved` (regenerated, not in path mode)
- Modify (infra repo `~/Work/production/platform/infra`, new branch `feat/recap-flags`):
  - `apps/norviq/api/values-staging.yaml`: `RECAP_ENABLED: "true"`, `RECAP_YEARLY_ENABLED: "true"`
  - `apps/norviq/api/values-production.yaml`: `RECAP_ENABLED: "false"`, `RECAP_YEARLY_ENABLED: "false"`
  - Follow the existing env block format in those files. Never edit `norviq-infra/`.

- [ ] **Step 1: Ask Fernando** before pushing anything (the tag, branches, PRs). Pushing is outward-facing.
- [ ] **Step 2:** In norviq-shared, merge `feat/recap-dtos` via a PR, then tag `v5.23.0` on main and push the tag.
- [ ] **Step 3:** Bump the backend pin, then run `swift package resolve` **without** `STOCKPLAN_SHARED_PATH`. Run `swift build`, then `swift test --filter Recap`. Expected: PASS.
- [ ] **Step 4:** Commit `chore(recap): pin norviq-shared 5.23.0`. Open a backend PR from `feat/recap`, then an infra PR with the flags.
- [ ] **Step 5:** After the merges, deploy to staging (manual dispatch; see the memory note `norviq-deploy-is-manual-dispatch`). Smoke test against staging with a real account:
  - `GET /v1/recaps` → 200 and lists last month.
  - `GET /v1/recaps/month/2026-09` → a deck.
  - Production stays off.

---

## Notes for Fernando (calls made in this plan)

- **No name on the share card.** `User` has no first-name field, only `username`, which may be an email-like handle. The spec said "first name", so this is a change from the spec.
- **Night Owl archetype dropped**, because there are no per-user app-use timestamps.
- **Realized P&L left out of v1.** Lot-level accounting edge cases risk wrong numbers.
- **`StatisticsService` is not reused.** It only supports rolling windows (`1m`, `ytd`, …), not calendar periods.
- **Archetype names, taglines and thresholds are drafts** for your verdict before production.
