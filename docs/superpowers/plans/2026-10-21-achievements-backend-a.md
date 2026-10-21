# Achievements — Backend PR A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the achievements engine (tables, catalogue, evaluators, backfill, sweep job, self endpoints) behind `ACHIEVEMENTS_ENABLED`, off by default, with no client-visible change while off.

**Architecture:** Server-side catalogue of text-keyed definitions; `AchievementService.evaluate` measures per-user metrics from existing tables and inserts idempotent unlock rows, paying XP through `XPService.award`. A leader-locked hourly sweep handles time/performance scopes and the first-run backfill. Hooks in other features and all social surfaces come in PR B.

**Tech Stack:** Swift 6, Vapor 4, Fluent/Postgres, Swift Testing on real Postgres (`DatabaseTestLock`).

**Spec:** `docs/superpowers/specs/2026-10-21-achievements-design.md`

## Global Constraints

- Work in this worktree (`feat/achievements`, off `origin/main`). Never in the stale `norviq-backend` checkout.
- No Postgres enums. Keys, tiers, sources are `text`.
- No money in any DTO or log: counts, booleans and percent-free states only. Performance progress is never exposed.
- No change to norviq-shared, `user_badges`, `BadgeType`, or `GET /v1/badges` responses.
- XP event `type` stays `badge_earned` (`XPEventTypeDTO.badgeEarned`) — old iOS clients decode XP history; do not add a new type.
- XP dedupe key: `achievement:<key>:<tier>` (tier `""` → `achievement:<key>:`).
- Tier strings: `bronze`, `silver`, `gold`, or `""` for single-tier.
- XP per tier: bronze 25, silver 50, gold 100 (`XPRules.badge`); single-tier 25; performance 100; hidden 50.
- Copy: en + pt-PT. `Accept-Language` whose first tag starts `pt` → pt-PT, else en.
- Flag: `ACHIEVEMENTS_ENABLED` via `envBool`, default false, independent of `SOCIAL_ENABLED`. Routes 404 when off; sweep no-ops when off.
- Tests use stub servers only, never real API keys. Pre-commit hook may reformat the whole repo (see memory): check `git show --stat` after each commit; use `--no-verify` and restore if it touched unrelated files.

## Review Focus

1. A user who signs up **after** the flag flips gets celebrated (`source=live`, unseen) unlocks, not silent backfill — test in Task 4.
2. GET `/v1/achievements` racing the sweep for the same user yields one row and one XP event per tier — test in Task 4.
3. `Accept-Language` `pt-BR`, `pt`, `PT-pt;q=0.9`, `en-US`, missing → pt, pt, pt, en, en — test in Task 2.
4. Showcase with an unearned tier, more than 3 items, or duplicates → 400; showcase rank survives later evaluations — test in Task 6.
5. Soft-deleted (`deleted_at`) and `ai_generated` board posts, archived retirement plans, and revoked PATs/OAuth tokens never count — test in Task 3.

---

## File Structure (all under `Sources/StockPlanBackend/` unless noted)

| File | Responsibility |
|---|---|
| `Achievements/AchievementsConfiguration.swift` | env flag + `AchievementsEnabledMiddleware` |
| `Achievements/AchievementCatalogue.swift` | definitions, categories, tiers, xp, copy |
| `Achievements/AchievementMetrics.swift` | per-key metric queries (`[String: Int]`) |
| `Achievements/AchievementPerformance.swift` | pure return/benchmark/drawdown math |
| `Achievements/AchievementModels.swift` | `UserAchievement`, `AchievementEvaluation` Fluent models |
| `Achievements/AchievementService.swift` | evaluate, list, unseen, markSeen, showcase |
| `Achievements/AchievementDTOs.swift` | wire types |
| `Achievements/AchievementController.swift` | `/v1/achievements` routes |
| `Achievements/AchievementSweepJob.swift` | hourly leader-locked sweep |
| `Migrations/CreateAchievementTables.swift` | tables, xp column, backfill markers, legacy copy |
| `openapi.yaml` (repo root) | document new routes |
| `Tests/StockPlanBackendTests/Achievement*Tests.swift` | tests |

---

### Task 1: Migration, models, flag, XP leaderboard exclusion

**Files:**
- Create: `Migrations/CreateAchievementTables.swift`, `Achievements/AchievementModels.swift`, `Achievements/AchievementsConfiguration.swift`
- Modify: `ConfigureBootstrap.swift` (append after `CreateGroupsTables()` ~line 454), `Gamification/XPModels.swift`, `Gamification/XPService.swift` (`award`, `awardBestEffort`, `xpByUser` ~218), `Social/SocialConfiguration.swift` + `Social/SocialDTOs.swift` (`SocialConfigDTO.achievements: Bool`)
- Test: `Tests/StockPlanBackendTests/AchievementMigrationTests.swift`

**Interfaces — Produces:**
- `final class UserAchievement: Model` schema `user_achievements`: `id`, `@Parent user_id`, `achievementKey` (`achievement_key`), `tier`, `unlockedAt` (`unlocked_at`), `source`, `seenAt?`, `notifiedAt?`, `showcaseRank: Int?`, `createdAt`.
- `enum AchievementSource: String { case live, sweep, backfill, legacyBadge = "legacy_badge" }`
- `final class AchievementEvaluation: Model` schema `achievement_evaluations`: `userId` (unique), `needsBackfill: Bool`, `lastEvaluatedAt: Date?`, `lastSweptAt: Date?`.
- `struct AchievementsConfiguration { let enabled: Bool; static func fromEnvironment() -> Self }`, `struct AchievementsEnabledMiddleware: AsyncMiddleware`.
- `XPService.award(_:points:to:dedupeKey:excludeFromLeaderboard: Bool = false, on:)`; same param on `awardBestEffort`.
- `GamificationXPEvent.excludeFromLeaderboard: Bool` (`exclude_from_leaderboard`, NOT NULL DEFAULT false).

Migration `CreateAchievementTables.prepare`, in order:
1. `user_achievements` with columns above; `tier` text NOT NULL DEFAULT `''`; `user_id` FK cascade; `.unique(on: "user_id", "achievement_key", "tier")`; raw SQL `CREATE UNIQUE INDEX uq_user_achievements_showcase ON user_achievements (user_id, showcase_rank) WHERE showcase_rank IS NOT NULL`; index `(user_id, unlocked_at)`.
2. `achievement_evaluations` (`user_id` unique FK cascade).
3. `ALTER TABLE gamification_xp_events ADD COLUMN exclude_from_leaderboard boolean NOT NULL DEFAULT false`.
4. `INSERT INTO achievement_evaluations (id, user_id, needs_backfill) SELECT gen_random_uuid(), id, true FROM users` — every existing user is backfilled on first evaluation; users created later have no row and are evaluated live.
5. Legacy copy: `INSERT INTO user_achievements (..., achievement_key, tier, unlocked_at, source, seen_at) SELECT ..., 'legacy.' || badge_type::text, tier::text, earned_at, 'legacy_badge', earned_at FROM user_badges ON CONFLICT DO NOTHING`.
`revert` drops in reverse and drops the column.

- [ ] **Step 1: Write failing tests** in `AchievementMigrationTests` (pattern: `GamificationRouteTests.withApp`):
  - `existingUsersAreMarkedForBackfill`: register a user, run `CreateAchievementTables().revert` then `prepare` → `AchievementEvaluation` for that user has `needsBackfill == true`.
  - `legacyBadgesAreCopied`: insert a `UserBadge(.firstPurchase, .silver, earnedAt: d)` before re-prepare → one `UserAchievement` with key `legacy.first_purchase` (use the enum's raw value), tier `silver`, source `legacy_badge`, `seenAt == d`.
  - `leaderboardIgnoresExcludedXP`: award 100 with `excludeFromLeaderboard: true` and 10 without → `XPService.xpByUser` returns 10; `XPService.summary(...).total == 110`.
  - `configExposesAchievementsFlag`: with `ACHIEVEMENTS_ENABLED=1`, `GET /v1/social/config` JSON has `"achievements": true`; unset → false.
- [ ] **Step 2: Run** `swift test --filter AchievementMigrationTests` → FAIL (types missing).
- [ ] **Step 3: Implement** migration, models, configuration, middleware, XP column/param, `xpByUser` filter `exclude_from_leaderboard == false`, `SocialConfigDTO.achievements`. Register the migration in `registerMigrations`.
- [ ] **Step 4: Run** `swift test --filter "AchievementMigrationTests|GamificationRouteTests|SocialRouteTests"` → PASS.
- [ ] **Step 5: Commit** `feat(achievements): tables, flag and leaderboard-excluded XP`.

---

### Task 2: Catalogue and localized copy

**Files:**
- Create: `Achievements/AchievementCatalogue.swift`
- Test: `Tests/StockPlanBackendTests/AchievementCatalogueTests.swift`

**Interfaces — Produces:**
```swift
enum AchievementCategory: String, CaseIterable { case gettingStarted = "getting_started", discipline, craft, planning, learning, community, performance, hidden, classic }
enum AchievementLanguage { case en, pt; static func from(acceptLanguage: String?) -> Self }
struct AchievementTierSpec { let tier: String; let threshold: Int; let xp: Int }
struct AchievementDefinition {
    let key: String; let category: AchievementCategory; let iconKey: String
    let tiers: [AchievementTierSpec]   // ascending threshold; single-tier = one spec with tier ""
    let sweepOnly: Bool                 // evaluated only by the sweep
    let isPerformance: Bool; let isHidden: Bool
    let copy: [AchievementLanguage: (title: String, description: String)]
}
enum AchievementCatalogue {
    static let all: [AchievementDefinition]
    static func definition(_ key: String) -> AchievementDefinition?
    static func legacyDefinition(for badge: BadgeType) -> AchievementDefinition // key "legacy.<raw>", category .classic, copy from BadgeDefinitions (en) + pt translation
}
```

Catalogue (metric source in parentheses; thresholds are the tier thresholds). Copy text is the implementer's, short and plain, en + pt-PT; titles below are the en titles.

| key | title | tiers | source |
|---|---|---|---|
| `start.first_holding` | First Holding | 1 | `onboarding_state.first_holding_at` set OR ≥1 `stocks` |
| `start.first_budget` | Budget Set | 1 | `first_budget_at` set |
| `start.first_goal` | Goal Setter | 1 | `first_goal_at` set OR ≥1 `goals` |
| `start.onboarded` | All Set Up | 1 | `funnel_completed_at` set |
| `start.bank_linked` | Connected | 1 | ≥1 `bank_connections` |
| `start.broker_linked` | Broker Linked | 1 | ≥1 `broker_connections` |
| `discipline.check_in` | Showing Up | 7/30/100 | longest streak via `XPService.checkInDays` + `longestStreak` |
| `discipline.check_in_year` | Year of Presence | 365 | same metric |
| `discipline.budget_streak` | On Budget | 3/6/12 | `gamification_budget_streaks.best_months` |
| `discipline.expense_days` | Tracker | 30/100/365 | distinct `expenses.occurred_on` |
| `discipline.recap_regular` | Reflective | 4 | longest run of consecutive weekly `recaps` with `opened_at` set (verify the weekly `period_kind` raw value and `period_key` format in `Recap/`) |
| `craft.thesis` | Thesis Writer | 1/10/50 | `research_notes` with non-empty `thesis` |
| `craft.memo_saved` | Memo Keeper | 1 | ≥1 `position_memos` with `bookmarked = true` |
| `craft.watchlist_review` | Reviewer | 1/10/50 | `watchlist_items` with `last_reviewed_at` set |
| `craft.target_hit` | On Target | 1/5/20 | `targets` with `alert_triggered_at` set |
| `craft.position_sizing` | Sized Right | 1 | ≥1 `terminal_positions` |
| `craft.diversified` | Diversified | 5 | distinct known sectors from `StatisticsRepository.sectorAllocation` (exclude Unknown/Other) — **sweepOnly** |
| `craft.rebalanced` | Rebalancer | 1 | `rebalance_plans.created_by_user_id` with `completed_at` set |
| `craft.patient_capital` | Patient Capital | 1 | ≥1 `stocks` with `buy_date ≤ now − 365d` — **sweepOnly** |
| `plan.retirement` | Long View | 1 | ≥1 `retirement_plans` (`owner_user_id`, `archived_at` null) |
| `plan.scenario` | What If | 1/10/50 | `scenario_runs` with `completed_at` set |
| `plan.goal_done` | Goal Getter | 1/3/10 | `goals.completed_at` set |
| `plan.contributions` | Steady Saver | 10/50/100 | `financial_goal_contributions` rows |
| `learn.articles` | Reader | 5/25/100 | distinct `article_views.article_id` where `viewer_key = 'u:' || user_id` |
| `learn.muse` | Curious | 1/10/50 | `ai_conversations` rows |
| `learn.mcp` | Power User | 1 | non-revoked `personal_access_tokens` OR `oauth_tokens` (`revoked_at` null at evaluation; once unlocked it stays) |
| `learn.pilot` | Co-Pilot | 1 | ≥1 `pilot_follows` |
| `social.friends` | Friendly | 1/5/20 | `social_friendships` where `user_id` |
| `social.first_post` | First Words | 1 | `board_posts.author_id`, `deleted_at` null, `ai_generated = false` |
| `social.popular_post` | Crowd Favourite | 10 | max `score` over those posts |
| `social.group` | Part of Something | 1 | ≥1 `group_members` |
| `perf.positive_year` | Green Year | 1 | Task 3 performance — **sweepOnly, isPerformance** |
| `perf.beat_benchmark` | Market Beater | 1 | Task 3 — **sweepOnly, isPerformance** |
| `perf.comeback` | Comeback | 1 | Task 3 — **sweepOnly, isPerformance** |
| `hidden.founding_member` | Founding Member | 1 | user is among first 1,000 by `users.created_at` — **isHidden** |

Tiered XP: tiers listed as three thresholds map to bronze/silver/gold; one threshold → tier `""`.

- [ ] **Step 1: Write failing tests** in `AchievementCatalogueTests` (pure, no DB):
  - `keysAreUnique`, `tiersAscend` (thresholds strictly ascending, tier names ⊂ {"bronze","silver","gold",""}), `everyDefinitionHasBothLanguages` (non-empty en + pt title/description).
  - `xpValues`: `definition("discipline.check_in")!.tiers.map(\.xp) == [25,50,100]`; `perf.comeback` xp `[100]`; `hidden.founding_member` `[50]`; `start.first_holding` `[25]`.
  - `languageParsing`: `from(acceptLanguage:)` for `"pt-BR"`, `"pt"`, `"PT-pt;q=0.9, en;q=0.8"` → `.pt`; `"en-US"`, `nil`, `""` → `.en`.
  - `legacyDefinitionsCoverAllBadgeTypes`: for every `BadgeType.allCases`, key `legacy.\(raw)`, category `.classic`, tiers bronze/silver/gold with thresholds from `BadgeDefinitions`.
- [ ] **Step 2: Run** `swift test --filter AchievementCatalogueTests` → FAIL.
- [ ] **Step 3: Implement** `AchievementCatalogue.swift`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(achievements): catalogue with en and pt-PT copy`.

---

### Task 3: Metrics and performance math

**Files:**
- Create: `Achievements/AchievementMetrics.swift`, `Achievements/AchievementPerformance.swift`
- Test: `Tests/StockPlanBackendTests/AchievementMetricsTests.swift`

**Interfaces:**
- Consumes: `AchievementCatalogue` (Task 2); `XPService.checkInDays`, `XPService.longestStreak(days:)`; `LeaderboardReturns.points(from:listIds:)`, `LeaderboardReturns.Point`; `MarketPriceBarRepository` (find the SPY instrument key used elsewhere); `StatisticsRepository.sectorAllocation`.
- Produces:
```swift
struct AchievementContext { let db: any Database; let logger: Logger; let app: Application; let now: Date }
enum AchievementMetrics {
    /// Metric value per catalogue key, for definitions in scope. Booleans are 0/1.
    static func measure(userId: UUID, keys: Set<String>, ctx: AchievementContext) async throws -> [String: Int]
}
enum AchievementPerformance {
    /// Chain-linked index (starts 1.0) from daily points, flows removed exactly as LeaderboardReturns does.
    static func index(_ points: [LeaderboardReturns.Point]) -> [(day: Date, value: Double)]
    /// True if any fully covered calendar year (first point ≤ Jan 7, last ≥ Dec 24) ended above its start.
    static func hasPositiveYear(_ index: [(day: Date, value: Double)], calendar: Calendar) -> Bool
    /// Trailing 365-day index return > benchmark close-to-close return over the same days. Needs ≥ 330 days of points.
    static func beatBenchmark(_ index: [(day: Date, value: Double)], benchmark: [(day: Date, close: Double)], asOf: Date) -> Bool
    /// A drawdown of ≥ 10% from a running peak, later followed by a new value ≥ that peak.
    static func hasComeback(_ index: [(day: Date, value: Double)]) -> Bool
}
```
Only keys present in `keys` are queried (one query per key; no N+1 across users — the sweep calls per user).

- [ ] **Step 1: Write failing tests:**
  - Pure: `positiveYearNeedsFullCoverage` (Jan 3 → Dec 30 rising → true; Mar 1 → Dec 30 rising → false; full year falling → false); `beatBenchmark` (index +12% vs SPY +8% → true; +5% vs +8% → false; 200 days → false); `comeback` (1.0→0.89→1.01 → true; 1.0→0.92→1.05 → false; 1.0→0.85→0.95 → false); `index` with a buy-in day (reuse the "Buying more is a flow" fixture from `GamificationRouteTests`) stays flat.
  - DB (`withApp`): seed one user with 2 research notes (one empty thesis), 3 board posts (one `deleted_at`, one `ai_generated`, one score 12), one revoked PAT, one archived retirement plan → `measure` returns `craft.thesis 1`, `social.first_post 1`, `social.popular_post 12`, `learn.mcp 0`, `plan.retirement 0`.
  - DB: `foundingMember` — user created first → 1; with `AchievementMetrics.foundingLimit` overridable for tests (`static var` set to 1), a second user → 0.
  - DB: user with zero snapshots → all `perf.*` keys are 0, no throw.
- [ ] **Step 2: Run** `swift test --filter AchievementMetricsTests` → FAIL.
- [ ] **Step 3: Implement** both files. Diversified: call `sectorAllocation` with default options; count names not in `["Unknown","Other",""]`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(achievements): metric queries and performance math`.

---

### Task 4: AchievementService.evaluate (live, backfill, XP, races)

**Files:**
- Create: `Achievements/AchievementService.swift`
- Modify: `Gamification/BadgeService.swift` (~line 107, after `badge.save`) — dual-write the legacy row
- Test: `Tests/StockPlanBackendTests/AchievementServiceTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
```swift
enum AchievementScope { case live, sweep }   // live = !sweepOnly definitions; sweep = all
enum AchievementService {
    /// Returns newly inserted unlocks. Idempotent. Never pays XP twice.
    @discardableResult
    static func evaluate(userId: UUID, scope: AchievementScope, ctx: AchievementContext) async throws -> [UserAchievement]
    /// Hooks call this (PR B). Swallows errors; no-op when flag off.
    static func evaluateBestEffort(userId: UUID, ctx: AchievementContext) async
    static func recordLegacyBadge(userId: UUID, badge: BadgeType, tier: BadgeTier, earnedAt: Date, on db: any Database) async
}
```
Rules:
- Load/insert `AchievementEvaluation`. If `needsBackfill`: force `scope = .sweep`, insert with `source = backfill`, `seenAt = now`, XP `excludeFromLeaderboard: true`, then set `needsBackfill = false`. Otherwise source = `live` (or `sweep` when called by the job), `seenAt = nil`.
- For each definition in scope, for each tier with `metric ≥ threshold` and no existing row → `XPService.insertIgnoringDuplicate`; if inserted, `XPService.award(.badgeEarned, points: tier.xp, dedupeKey: "achievement:\(key):\(tier)", excludeFromLeaderboard:)`. Award directly (not `awardBestEffort`) only when `SocialConfiguration.fromEnvironment().leaderboards`; otherwise skip XP (matches existing gating).
- Update `lastEvaluatedAt` (and `lastSweptAt` when scope is sweep).
- `recordLegacyBadge`: insert `legacy.<raw>`/tier row, `source = legacy_badge`, `seenAt = earnedAt`, no XP. Called from BadgeService after a successful save.

- [ ] **Step 1: Write failing tests:**
  - `backfillIsSilentAndExcluded`: existing user (has evaluation row `needsBackfill = true`) with 1 stock and onboarding `first_holding_at` → evaluate(.live) inserts `start.first_holding` with source `backfill`, `seenAt != nil`; XP event `achievement:start.first_holding:` has `excludeFromLeaderboard == true`; evaluation row now `needsBackfill == false`.
  - `newUserIsLive` (Review Focus 1): register a user **after** migration (no evaluation row), add a stock → evaluate(.live) → source `live`, `seenAt == nil`, XP not excluded.
  - `idempotentUnderRace` (Review Focus 2): `async let a = evaluate(.live)`, `async let b = evaluate(.sweep)` for the same user → exactly one `UserAchievement` per (key,tier) and one XP event per dedupe key.
  - `tiersUnlockIncrementally`: 7-day streak → `discipline.check_in` bronze only; add days to 30 → silver inserted, bronze untouched.
  - `sweepOnlySkippedLive`: user with a stock bought 400 days ago → `.live` does not insert `craft.patient_capital`; `.sweep` does.
  - `noXPWhenLeaderboardsOff`: `SOCIAL_LEADERBOARDS_ENABLED=0` → row inserted, zero XP events.
  - `legacyDualWrite`: `BadgeService` earning a new badge also writes `legacy.<raw>` row with no extra XP event.
- [ ] **Step 2: Run** `swift test --filter AchievementServiceTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test --filter "AchievementServiceTests|BadgeLogicTests"` → PASS.
- [ ] **Step 5: Commit** `feat(achievements): idempotent evaluation with silent backfill`.

---

### Task 5: Sweep job

**Files:**
- Create: `Achievements/AchievementSweepJob.swift`
- Modify: `configure.swift` (~line 420, next to `TargetAlertPoller`)
- Test: `Tests/StockPlanBackendTests/AchievementSweepJobTests.swift`

**Interfaces:**
- Produces: `final class AchievementSweepJob: LifecycleHandler` with `init(intervalSeconds: Int64 = 3600, batchSize: Int = 200)`, `func runOnce(_ app: Application) async`. Mirror `Insights/HermesSyncJob.swift` (`BackgroundJobState`, overlap guard, shutdown drain). Tick: return if flag off; `JobLock.runAsLeader(app, name: "achievement_sweep")`; select up to `batchSize` users with no evaluation row or `last_swept_at` null or older than 24h, ordered by `last_swept_at NULLS FIRST, user_id`; `evaluate(scope: .sweep)` each; per-user errors are logged and skipped. Register only when not `app.environment == .testing` (follow how neighbouring jobs are guarded).

- [ ] **Step 1: Write failing tests:**
  - `runOnceSweepsDueUsers`: 3 users, batchSize 2 → after one `runOnce`, 2 have `lastSweptAt` set; after a second, all 3.
  - `recentlySweptSkipped`: user with `lastSweptAt = now − 1h` is not re-evaluated (row count unchanged after adding a qualifying stock).
  - `flagOffNoop`: `ACHIEVEMENTS_ENABLED=0` → no evaluation rows change.
- [ ] **Step 2: Run** `swift test --filter AchievementSweepJobTests` → FAIL.
- [ ] **Step 3: Implement** and register.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(achievements): hourly leader-locked sweep`.

---

### Task 6: DTOs, controller, routes, OpenAPI

**Files:**
- Create: `Achievements/AchievementDTOs.swift`, `Achievements/AchievementController.swift`
- Modify: `routes.swift` (register next to `BadgeController`), `openapi.yaml`
- Test: `Tests/StockPlanBackendTests/AchievementRouteTests.swift`

**Interfaces — Produces (wire contract consumed by web and iOS):**
```swift
struct AchievementTierDTO: Content { let tier: String; let threshold: Int?; let xp: Int; let unlockId: UUID?; let unlockedAt: Date?; let showcaseRank: Int? }
struct AchievementProgressDTO: Content { let current: Int; let target: Int }
struct AchievementDTO: Content {
    let key: String; let category: String; let title: String; let description: String; let iconKey: String
    let state: String            // "earned" (all tiers) | "inProgress" (some tiers or metric > 0) | "locked" | "hidden"
    let currentTier: String?     // highest earned tier; "" for single-tier earned
    let progress: AchievementProgressDTO?  // toward next tier; nil when maxed, performance, or hidden
    let isPerformance: Bool; let tiers: [AchievementTierDTO]
}
struct AchievementCategoryDTO: Content { let key: String; let title: String }
struct AchievementSummaryDTO: Content { let unlocked: Int; let total: Int; let hiddenRemaining: Int }
struct AchievementsResponseDTO: Content { let summary: AchievementSummaryDTO; let categories: [AchievementCategoryDTO]; let achievements: [AchievementDTO] }
struct AchievementUnlockDTO: Content { let id: UUID; let key: String; let tier: String; let title: String; let description: String; let iconKey: String; let xp: Int; let unlockedAt: Date }
struct AchievementSeenBody: Content { let ids: [UUID] }
struct AchievementShowcaseItem: Content { let key: String; let tier: String }
struct AchievementShowcaseBody: Content { let items: [AchievementShowcaseItem] }
```
Service additions in `AchievementService`: `list(userId:language:ctx:) -> AchievementsResponseDTO`, `unseen(userId:language:on:) -> [AchievementUnlockDTO]` (source live/sweep, `seenAt` nil, oldest first, max 20), `markSeen(userId:ids:on:)` (only the caller's rows), `setShowcase(userId:items:on:) throws -> AchievementsResponseDTO` (clears ranks then sets 1…n in a transaction).

Routes (`SessionToken.authenticator()`, `guardMiddleware()`, `AchievementsEnabledMiddleware()`; writes get `RateLimitMiddleware(limit: 30, interval: 60, keyPrefix: "ratelimit:achievements-write")`):
- `GET /v1/achievements` — runs `evaluate(.live)` first unless `lastEvaluatedAt` < 60s ago; then `list`.
- `GET /v1/achievements/unseen`
- `POST /v1/achievements/seen` → 204
- `PUT /v1/achievements/showcase` → 200 `AchievementsResponseDTO`; 400 when >3 items, duplicates, or any item not earned by caller.

Rules for `list`: hidden + not earned → title/description from a localized "???"/"Keep exploring" pair, `iconKey "lock"`, `tiers` with `threshold: nil`, `state "hidden"`; `classic` category and legacy definitions included only when the user has ≥1 legacy row; `summary.total` counts tiers of non-legacy, non-hidden definitions; `hiddenRemaining` = hidden definitions not earned. Categories ordered as in `AchievementCategory.allCases`, titles localized.

- [ ] **Step 1: Write failing tests:**
  - `flagOff404`: all four routes 404 with `ACHIEVEMENTS_ENABLED` unset.
  - `listShape`: user with 1 stock → `start.first_holding` state `earned`, `currentTier ""`; `discipline.check_in` `locked` with `progress {0,7}`; `hidden.founding_member` earned (first user) shows real title; with `foundingLimit = 0` it shows `"???"` and `state "hidden"`; no `perf.*` progress; no `classic` category.
  - `portuguese`: `Accept-Language: pt-PT` → `start.first_holding` title equals catalogue pt title.
  - `unseenThenSeen`: new user earns 2 → `/unseen` returns 2; POST `/seen` with one id → `/unseen` returns 1; another user's id in body is ignored.
  - `backfilledNotUnseen`: backfilled unlocks never appear in `/unseen`.
  - `showcaseValidation` (Review Focus 4): 4 items → 400; duplicate items → 400; unearned tier → 400; 2 valid items → ranks 1,2; call `GET /v1/achievements` again → ranks unchanged; PUT `[]` clears.
  - `OpenAPIDocsTests` passes with the new paths.
- [ ] **Step 2: Run** `swift test --filter "AchievementRouteTests|OpenAPIDocsTests"` → FAIL.
- [ ] **Step 3: Implement** DTOs, controller, service methods, routes, `openapi.yaml` (new `Achievements` tag; schemas mirror the DTOs).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(achievements): self endpoints and OpenAPI`.

---

### Task 7: Full suite and PR

- [ ] **Step 1:** Check local DB (`docker ps`; see memory `norviq-backend-local-test-db`), then `make backend-test` (or `swift test`) → all PASS. Report failures verbatim; do not mark done on red.
- [ ] **Step 2:** `swift build -c release` → succeeds.
- [ ] **Step 3:** Push `feat/achievements`, open PR "Achievements engine (flag off)" with spec + plan links, noting: flag default off; migration backfills markers + copies legacy badges; no client change; PR B follows. Do not merge or deploy without the user.
