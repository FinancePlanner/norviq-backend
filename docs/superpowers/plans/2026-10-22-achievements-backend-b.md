# Achievements — Backend PR B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire achievements into the social layer: evaluation hooks across features, invite redemptions, unlock activity + push, the "show achievements" privacy toggle, friend profile showcase, and the friends activity feed with 🎉 congrats — all behind flags, off by default.

**Architecture:** Hooks never evaluate inline: they enqueue the user in an in-process coalescer that runs `AchievementService.evaluateBestEffort` on a detached task after a short delay, outside any request transaction. `evaluate` writes a `social_activity` row for every non-backfill unlock in the same transaction; the hook path then sends one `achievement_unlocked` push. Feed visibility is decided at read time from current privacy and friendship.

**Tech Stack:** Swift 6, Vapor 4, Fluent/Postgres, Swift Testing on real Postgres (`DatabaseTestLock`).

**Spec:** `docs/superpowers/specs/2026-10-21-achievements-design.md` (PR A plan: `docs/superpowers/plans/2026-10-21-achievements-backend-a.md`).

## Global Constraints

- Branch `feat/achievements-social` off `main` (`11b4fea`), worktree `norviq/.worktrees/norviq-backend-achievements-b`.
- `AchievementService.evaluate` / `evaluateBestEffort` are **never** called inside a caller's `db.transaction`; hooks only enqueue.
- No money in any DTO, push or log. Logs carry ids, keys, error type names only.
- No Postgres enums; no change to norviq-shared, `user_badges`, `BadgeType`, `GET /v1/badges`.
- Push only to devices whose `capabilities_json` contains `achievements_v1`. APNs payload key is `type` (existing `SocialEventPayload` shape); new kinds `achievement_unlocked`, `achievement_congrats`.
- Flags: hooks/activity/unlock push follow `ACHIEVEMENTS_ENABLED`; feed + congrats + friend achievements routes need `SOCIAL_ENABLED && ACHIEVEMENTS_ENABLED && SOCIAL_ACTIVITY_FEED_ENABLED` (default false), 404 when off. `SocialConfigDTO.activityFeed: Bool` added.
- Backfill and legacy unlocks never create activity rows or pushes.
- Tests: stub push via a `PushNotificationSending` recorder (pattern `BoardPushRecorder`, T/BoardNotificationsTests.swift:10); never real keys/network. Any test that calls `setenv`/`unsetenv` must hold `DatabaseTestLock.withLock` (exclusive) — glibc env race (see `ca0c863`).
- Pre-commit/pre-push swiftformat hooks drift locally: lint touched files with `swiftformat --lint <files>`; commit/push with `--no-verify` only after that passes.

## Review Focus

1. A burst of writes for one user (bulk CSV import, 50 expenses) runs `evaluate` once, not 50 times, and never blocks the request — Task 1.
2. A friend who turned `showAchievements` off, blocked the viewer (either way), is suspended, or became a friend *after* the unlock is absent from the feed; performance unlocks are absent when `showReturnPercent` is false — Task 5.
3. Congrats spam: repeated POSTs by one friend → one row, one push; many friends within 10 minutes → at most one push per activity per 10 minutes — Task 5.
4. An old iOS build (no `achievements_v1` capability) never receives the new push kinds — Task 3.
5. `PUT /privacy` from an old client that omits `showAchievements` keeps the stored value — Task 4.

---

## File Structure (under `Sources/StockPlanBackend/` unless noted)

| File | Responsibility |
|---|---|
| `Achievements/AchievementHooks.swift` | per-user coalescing scheduler + `Request`/`Application` helpers |
| `Achievements/AchievementNotifier.swift` | unlock + congrats push composition, capability filter, throttle |
| `Social/SocialActivityModels.swift` | `SocialActivity`, `SocialCongrats`, `SocialInviteRedemption` models |
| `Social/SocialFeedService.swift` | feed query, visibility rules, congrats |
| `Social/SocialFeedController.swift` | `/v1/social/feed` routes, friend achievements route, middleware |
| `Migrations/CreateSocialActivityTables.swift` | new tables + `social_settings.show_achievements` |
| existing files | hook call sites, privacy DTO, profile, catalogue (`social.inviter`), config, openapi |

---

### Task 1: Coalescing hook scheduler

**Files:** Create `Achievements/AchievementHooks.swift`; Test `T/AchievementHooksTests.swift`.

**Interfaces — Produces:**
```swift
actor AchievementHooks {
    static let shared: AchievementHooks
    /// Test seam; production 2s.
    static var delay: Duration   // nonisolated(unsafe), commented as test seam
    /// No-op when ACHIEVEMENTS_ENABLED is off. Coalesces: a user already pending is not re-queued.
    nonisolated func schedule(_ userId: UUID, app: Application)
    /// Tests: await every queued/running evaluation.
    func waitUntilIdle() async
}
extension Request { func scheduleAchievementCheck(for userIds: UUID...) }
```
Run: `Task.detached` per newly pending user → sleep `delay` → remove from pending → `AchievementService.evaluateBestEffort(userId:ctx: AchievementContext(db: app.db, logger: app.logger, app: app, now: Date()))` → `AchievementNotifier.notifyUnlocks(...)` (Task 3; until then nothing). A user scheduled while their evaluation is running is re-queued once after it finishes.

- [ ] **Step 1: failing tests:** `flagOffSchedulesNothing` (flag unset → `waitUntilIdle`, no evaluation row created); `burstCoalesces` (delay 50ms, 20× `schedule(user)` → exactly one `achievement_evaluations.last_evaluated_at` stamp change and the stock unlock present once; count evaluations via a test-only counter `AchievementHooks.evaluationsRun` if needed); `scheduleDuringRunRequeuesOnce`.
- [ ] **Step 2:** run `swift test --filter AchievementHooksTests` → FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** run → PASS.
- [ ] **Step 5:** commit `feat(achievements): coalescing evaluation hooks`.

---

### Task 2: Wire hooks into features + invite redemptions

**Files:** Create `Migrations/CreateSocialActivityTables.swift`, `Social/SocialActivityModels.swift`; modify the call sites below, `Social/SocialService.swift` (`redeemInvite` path), `Achievements/AchievementCatalogue.swift`, `Achievements/AchievementMetrics.swift`, `ConfigureBootstrap.swift`; Test `T/AchievementHookSitesTests.swift`.

**Migration `CreateSocialActivityTables`** (all `.ignoreExisting()` / `IF NOT EXISTS`):
- `social_activity`: id, `actor_id` FK users cascade, `kind` text, `user_achievement_id` FK user_achievements cascade (unique), `created_at`; index `(actor_id, created_at, id)`.
- `social_congrats`: id, `activity_id` FK social_activity cascade, `from_user_id` FK users cascade, `created_at`; UNIQUE(activity_id, from_user_id).
- `social_invite_redemptions`: id, `invite_id` FK social_invites cascade, `inviter_id` FK users cascade, `invitee_id` FK users cascade UNIQUE, `redeemed_at`.
- `ALTER TABLE social_settings ADD COLUMN IF NOT EXISTS show_achievements boolean NOT NULL DEFAULT true`.

**Hook sites** — call `req.scheduleAchievementCheck(for:)` (or `AchievementHooks.shared.schedule(_, app:)` where there is no Request) **after** any transaction closes:
- Inside `Request.reconcileBadges` (BadgeService.swift:298) — covers broker sync/imports, expenses, watchlist import, stock create/bulk, news view.
- Research note create/update (StockController.swift:314, :364); memo bookmark (PositionMemoService.setBookmarked:67 caller); watchlist review (StockController+Watchlist :138, :182); terminal position create (TerminalPositionsController.create:69); rebalance complete (RebalancingController.completePlan:151, only when status becomes completed); retirement upsert (RetirementController.upsertPlan:42, plan owner); goal completed (GoalsController.updateStatus:127, only when completedAt set); contribution create (GoalPlanningController.createContribution:223); recap open (RecapController.opened:64); check-in (GamificationController.checkIn:58); budget streak (reportBudgetStreak:71); bank connection (BankController.exchange:63, BankCallbackController.callback:21 after completion); broker connect (BrokerController.connectIBKRCredentials:120, AuthController IBKR callback :364); article view (ArticlesController.view:173, only `u:` viewers, only when the insert returned a row); AI conversation create (AIAssistantController.createConversation:66, MessagingConversations.create ~:106); PAT create (PersonalAccessTokenController.create:26); OAuth token issue (OAuthServerController.exchangeCode:135); pilot follow (PilotController.createFollow:76, after tx); board post (BoardsController.createPost:265, after tx); board vote → **post author** (BoardsController.vote, beside `BoardNotifier.upvoted` :366); groups create/join/redeem/accept (GroupsController :90/:278/:684/:795, after tx); friend accept → **both users** (SocialService.befriend after its tx — covers accept, reverse-request and invite paths).
- Background: `TargetAlertEvaluator` after a delivered trigger (:91) → schedule the target's user; `ScenarioRunWorker.execute` after completion (:93) → schedule run's user.

**Invite redemptions:** in `SocialController.redeemInvite` (:218) / the service it calls, after befriending succeeds and only if the invitee's `users.created_at` is within **7 days** before now and invitee ≠ inviter: insert `social_invite_redemptions` with ON CONFLICT (invitee_id) DO NOTHING; schedule the inviter. **Catalogue:** add `social.inviter` (category community, tiers 1/3/10 bronze/silver/gold, icon `person.badge.plus`, en "Recruiter" / "Bring friends to Norviq", pt-PT "Recrutador" / "Traz amigos para o Norviq"); metric = count of redemptions with `inviter_id = user`.

- [ ] **Step 1: failing tests** (`withApp` with `ACHIEVEMENTS_ENABLED=1`, `AchievementHooks.delay = .zero`, `await AchievementHooks.shared.waitUntilIdle()` before asserting): expense create → `start.first_budget`/expense metric path evaluated (unlock row exists for a qualifying fixture); research note → `craft.thesis` bronze; check-in → evaluation stamped; board vote by B on A's post → A evaluated (A's `last_evaluated_at` set), B not required; friend accept → both users evaluated; article view by user → evaluated; anonymous view → no evaluation row; invite redeem by a 1-day-old account → redemption row + inviter evaluated + `social.inviter` bronze; redeem by a 30-day-old account → no redemption row; migration runs twice.
- [ ] **Step 2:** run `--filter AchievementHookSitesTests` → FAIL. **Step 3:** implement. **Step 4:** run plus `--filter "AchievementCatalogueTests|SocialRouteTests|BoardsTests|ExpensesTests"` → PASS.
- [ ] **Step 5:** commit `feat(achievements): evaluation hooks across features and invite redemptions`.

---

### Task 3: Activity rows + unlock push

**Files:** Modify `Achievements/AchievementService.swift`; create `Achievements/AchievementNotifier.swift`; modify `Notifications/PushNotificationSender.swift` (new kinds) and wire `AchievementHooks` + `AchievementSweepJob` to the notifier; Test `T/AchievementNotifierTests.swift`.

**Interfaces — Produces:**
- In `evaluate`, for each inserted unlock whose source is `live` or `sweep`: insert `SocialActivity(actorId:, kind: "achievement_unlocked", userAchievementId:)` inside the same transaction (savepoint pattern already used there).
- `enum AchievementNotifier { static func notifyUnlocks(_ unlocks: [UserAchievement], userId: UUID, app: Application) async; static let capability = "achievements_v1" }` — loads the user's active devices containing the capability; one push per call: 1 unlock → title "Achievement unlocked" / body "<title>" (localized by the user's last known language is not tracked → en; acceptable), >1 → "<n> achievements unlocked"; stamps `notified_at` on those rows. Hidden-earned unlocks use the real title. No push when no capable devices.
- Push kinds `achievement_unlocked`, `achievement_congrats` added to the social push kind enum; payload stays `SocialEventPayload{schemaVersion, type}` + `threadID "achievements"`.
- `GET /v1/achievements` path (request-driven evaluate) does **not** push — the client shows its own sheet; it also does not stamp `notified_at`.

- [ ] **Step 1: failing tests:** live unlock via hook → one `social_activity` row, one recorded push with type `achievement_unlocked`, `notified_at` set; device without capability → no push; backfill evaluation → no activity, no push; legacy dual-write → no activity; 3 unlocks in one evaluation → one push "3 achievements unlocked"; GET route evaluation → activity row but no push.
- [ ] **Steps 2–4:** RED, implement, GREEN (`--filter "AchievementNotifierTests|AchievementServiceTests|AchievementSweepJobTests"`).
- [ ] **Step 5:** commit `feat(achievements): activity rows and unlock push`.

---

### Task 4: Privacy toggle + friend profile showcase

**Files:** Modify `Social/SocialModels.swift` (`show_achievements`), `Social/SocialDTOs.swift` (`SocialPrivacySettingsDTO.showAchievements`, `SocialProfileDTO.showcase`), `Social/SocialController.swift` (`updatePrivacy`, `profile`); add friend achievements route in `Social/SocialFeedController.swift`; Test `T/SocialAchievementPrivacyTests.swift`.

**Rules:**
- `showAchievements` default true; DTO `init(from:)` uses `decodeIfPresent ?? true`; `PUT /privacy` keeps the stored value when the field is absent (extend the `SocialFacebookPrivacyProbe` pattern, :118/:253).
- `canSeeAchievements(viewer, owner)` = viewer == owner, OR (achievements flag on AND friends AND not blocked either way AND owner not suspended AND owner.showAchievements). Performance achievements additionally require owner.showReturnPercent (or viewer == owner).
- Profile (`SocialController.profile`, :95): when `canSeeAchievements` → `badgeCount` = number of unlock rows excluding `legacy.*` and performance-hidden ones; `showcase: [AchievementShowcaseEntryDTO]?` = pinned (`showcase_rank` 1…3) else up to 3 highest tier (gold > silver > bronze > "") then most recent; entries `{key, tier, title, iconKey}` localized via `Accept-Language`. Otherwise both nil.
- `GET /v1/social/users/:userId/achievements` (feed flag middleware) → 404 unless `canSeeAchievements`; returns `[AchievementUnlockDTO]` of the owner's visible unlocks, newest first (reuse PR A's DTO).

- [ ] **Step 1: failing tests:** old-client PUT without the field keeps `false`; friend sees badgeCount + showcase (pinned order respected; default order by tier); `showAchievements=false` → nil/nil and route 404; non-friend → 404; blocked either way → 404; performance unlock hidden when owner `showReturnPercent=false`; self always sees own.
- [ ] **Steps 2–4**, **Step 5:** commit `feat(social): achievements privacy, profile showcase and friend list`.

---

### Task 5: Activity feed + congrats

**Files:** Create `Social/SocialFeedService.swift`, `Social/SocialFeedController.swift`; modify `Social/SocialConfiguration.swift` (`activityFeed`), `Social/SocialDTOs.swift` (`SocialConfigDTO.activityFeed`, feed DTOs), `routes.swift`; Test `T/SocialFeedTests.swift`.

**Interfaces — Produces:**
```swift
struct SocialFeedAchievementDTO: Content { let key: String; let tier: String; let title: String; let iconKey: String }
struct SocialFeedItemDTO: Content { let id: UUID; let actor: SocialUserSummaryDTO; let achievement: SocialFeedAchievementDTO; let createdAt: Date; let congratsCount: Int; let viewerCongratulated: Bool }
struct SocialFeedResponseDTO: Content { let items: [SocialFeedItemDTO]; let nextCursor: String? }
struct ActivityFeedEnabledMiddleware: AsyncMiddleware // 404 unless social && achievements && SOCIAL_ACTIVITY_FEED_ENABLED
```
- `GET /v1/social/feed?cursor=&limit=` (default 20, max 50): activity of the viewer's friends (not the viewer), `created_at` within 90 days AND after the friendship's `created_at`; excludes `blockedEitherWay` (blocks + suspended), owners with `showAchievements=false`, performance keys unless owner `showReturnPercent`; keyset on `(created_at desc, id desc)` with `NotificationListCursor`.
- `POST /v1/social/feed/:activityId/congrats` (RateLimit 30/60s, key `ratelimit:social-congrats`): 400 own activity; 404 when the activity is not visible to the viewer under the feed rules; insert ON CONFLICT DO NOTHING → 204 either way. Push `achievement_congrats` to the actor (capability-filtered) only when this insert created the row AND no other congrats on that activity was created in the previous 10 minutes; body "<viewer username> cheered your <title>"; never for a duplicate.
- Config: `SocialConfiguration.activityFeed = enabled && AchievementsConfiguration.enabled && envBool("SOCIAL_ACTIVITY_FEED_ENABLED", false)`; `SocialConfigDTO.activityFeed`.

- [ ] **Step 1: failing tests:** flag off → feed/congrats/friend-achievements 404; feed shows friend unlocks newest first with cursor paging (limit 1 → 2 pages); excludes own, non-friends, unlocks before friendship, >90 days, `showAchievements=false`, blocked either way, suspended, performance without `showReturnPercent`; congrats idempotent (two POSTs → one row, `congratsCount` 1, `viewerCongratulated` true); self 400; non-visible 404; push throttle (A cheers → push; B cheers 1 min later → no push; config DTO exposes `activityFeed`.
- [ ] **Steps 2–4**, **Step 5:** commit `feat(social): friends activity feed and congrats`.

---

### Task 6: OpenAPI, full verification, PR

- [ ] Document every new route/schema in `openapi.yaml` (feed, congrats, friend achievements, `showAchievements`, `SocialProfileDTO.showcase`, `SocialConfigDTO.activityFeed`); `swift test --filter OpenAPIDocsTests` → PASS; commit `docs(openapi): achievements social routes`.
- [ ] `swiftformat --lint` on every touched file → clean.
- [ ] Push the branch (`--no-verify` after lint) and let CI run the full suite (local full runs exhaust this machine's disk). Report CI result verbatim.
- [ ] Open PR "Achievements social layer (flags off)" into `main`; merge only with the user's go-ahead.
