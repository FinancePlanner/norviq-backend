# Norviq — Achievements + Friends Activity Feed

## Context
User wants friends + achievements on web and iOS. Exploration showed most social plumbing already exists:
mutual friends (requests/accept, blocks, reports, privacy), XP + levels, check-in/budget streaks,
friends-only leaderboards, 7 tiered badges (`user_badges`, pull-based `BadgeService`). Gaps: badges cover
few actions, friends can't see them (`SocialProfileDTO.badgeCount` hard-coded nil), no unlock moment, no
friend activity.

**Decisions (user):** keep mutual friend model (no follow). Achievements reward habits/good practice + a few
percent-only performance milestones (never amounts, never trade count). ~45-item catalogue approved.
Friends activity feed with one-tap 🎉 congrats. Backfill pays XP but is excluded from leaderboards.
Achievements work for every user; Social only governs visibility/feed/congrats.

Flag (CLAUDE.md rule): supply-side work while strangers-count is low — user chose to proceed.

## Catalogue (server-side, text keys, en + pt-PT copy)
1. Getting started: first holding/budget/goal (`onboarding_state.first_*_at`), onboarding done (`funnel_completed_at`), bank linked (`bank_connections`), broker connected.
2. Discipline: check-in streak 7/30/100/365 (`gamification_check_ins`); budget streak 3/6/12 mo (`gamification_budget_streaks`); expenses on 30/100/365 distinct days; recap opened 4 weeks running (`recaps.opened_at`).
3. Investor craft: thesis memos 1/10/50 (`position_memos`); research notes; watchlist reviewed (`last_reviewed_at`); target hit (`targets.alert_triggered_at`); position sizing (`terminal_positions`); ≥5 sectors (`StatisticsRepository.sectorAllocation`, exclude Unknown/Other); rebalance executed (`rebalance_plans.completed_at`); held 1 year (`stocks.buy_date`).
4. Planning: retirement plan; scenario run; goal completed (`goals.completed_at`); contributions 10/50/100 (`financial_goal_contributions`).
5. Learning: articles 5/25/100 (distinct `article_views` where `viewer_key='u:<uuid>'`); Muse conversations (`ai_conversations`); MCP connected (PAT/OAuth); followed a Pilot.
6. Community: friends 1/5/20; first board post; post ≥10 upvotes; joined/created group; invited friend who joined (new table).
7. Performance (friends see only if `showReturnPercent`): first positive full calendar year; beat SPY over 12 mo; recovered to high after ≥10% drawdown. Reuse `LeaderboardService` time-weighted return over `portfolio_value_snapshots` (holdings only); SPY from `market_price_bars`.
8. Hidden: Founding Member (first 1,000 accounts by `created_at`) — shows "???" until unlocked.
9. Classic badges: 7 legacy badges copied in as `legacy.<type>`.

## Architecture
**Detection (hybrid):** `AchievementService.evaluate(userId, scopes, ctx(db, logger, app))`, best-effort, called
next to the ~8 existing `reconcileBadges` call sites + new hooks (memo, research note, goal complete/contribution,
rebalance complete, recap open, check-in, board post/vote, group join, friend accept, invite redeem, article view,
AI conversation, PAT/OAuth grant, pilot follow, `TargetAlertPoller`). Plus `AchievementSweepJob`
(LifecycleHandler + `scheduleRepeatedTask` hourly, `JobLock.runAsLeader(app, name: "achievement_sweep")`, daily
cursor pass) for time/perf/diversification. `GET /v1/achievements` evaluates for caller, debounced ~60s.
Idempotent via unique key + `insertIgnoringDuplicate`; XP via `XPService.award` dedupe `achievement:<key>:<tier>`.

**Data model (new migrations, no Postgres enums):**
- `user_achievements`: id, user_id FK cascade, achievement_key text, tier text NOT NULL DEFAULT '', unlocked_at, source (`live|sweep|backfill|legacy_badge`), seen_at?, notified_at?, showcase_rank smallint?. UNIQUE(user_id,key,tier); partial UNIQUE(user_id,showcase_rank); idx(user_id, unlocked_at desc).
- `social_activity`: id, actor_id, kind text, user_achievement_id FK cascade, created_at. idx(actor_id, created_at desc, id).
- `social_congrats`: id, activity_id FK cascade, from_user_id, created_at. UNIQUE(activity_id, from_user_id).
- `social_invite_redemptions`: invite_id, inviter_id, invitee_id UNIQUE, redeemed_at.
- `social_settings.show_achievements` bool default true (`PUT /privacy` uses `decodeIfPresent`, keeps stored value when absent).
- `gamification_xp_events.exclude_from_leaderboard` bool default false; `LeaderboardService` XP metric filters it.

**Backfill:** first sweep after flag on → `source=backfill`, marked seen, no activity row, no push, XP paid with `exclude_from_leaderboard=true`. Legacy badge copy pays no XP (already paid via `badge_earned:`). `user_badges`, `BadgeService`, `GET /v1/badges` untouched (old iOS builds); BadgeService dual-writes legacy key.

**API (session auth; 404 when flag off):**
- `GET /v1/achievements` → summary, categories, `[AchievementDTO]` (key, category, tier, title, description, iconKey, state earned|inProgress|locked|hidden, progress{current,target} — boolean-only for performance, unlockedAt, xp, isPerformance, showcaseRank). Copy chosen by `Accept-Language`.
- `GET /v1/achievements/unseen`, `POST /v1/achievements/seen {ids}`, `PUT /v1/achievements/showcase {items ≤3}`.
- `GET /v1/social/users/:id/achievements` (friends only, privacy-filtered); profile fills `badgeCount` + `showcase` (default: highest tier, then most recent).
- `GET /v1/social/feed?cursor&limit` (keyset on created_at,id; 90-day window; only activity created after friendship; filters blocks either way, suspended, `showAchievements=false`, perf without `showReturnPercent`).
- `POST /v1/social/feed/:activityId/congrats` → idempotent 204, rate-limited; 404 non-friend/blocked; 400 self. Not undoable.
- Config: `ACHIEVEMENTS_ENABLED` (independent of `SOCIAL_ENABLED`); `SOCIAL_ACTIVITY_FEED_ENABLED` requires social + achievements. Expose `achievements` + `activityFeed` in `GET /v1/social/config`; iOS `SocialConfig` decodes both with default false.
- Push: `achievement_unlocked`, `achievement_congrats` via `PushNotificationSender.sendSocialEvent`, only to devices whose `push_devices.capabilities_json` contains `achievements_v1` (old iOS mis-routes unknown kinds to `.targetHit` — `PushNotificationsCoordinator.swift:145`). Congrats pushes collapse per activity.

**DTOs:** app-local (backend + iOS), like Social DTOs. **No norviq-shared change** (pins already differ: backend 5.26.0, iOS 5.25.0).

## Phases (each PR safe alone; work in worktrees off `origin/main` — local backend checkout is on a stale branch)
1. **Backend PR A (flag off):** migrations, catalogue, service, sweep job, self endpoints, legacy copy, XP leaderboard exclusion, `openapi.yaml`, tests. Register in `ConfigureBootstrap.registerMigrations`, `routes.swift`.
2. **Backend PR B (flag off):** hooks across features, invite redemptions, activity/feed/congrats, profile badgeCount/showcase, privacy field, push capability filter.
3. **Web PR** (`RequireAchievements` / `RequireActivityFeed`, 404 when off): `/achievements` page (vigil components, progress bars); `GET /settings` section badges → 302 `/achievements` when on; nav entry (`internal/nav/nav.go`); friend profile showcase (`internal/pages/friends/friends.templ`); Activity tab on `/friends` with HTMX 🎉; privacy toggle; unseen-unlock toast fragment lazy-loaded (`hx-trigger="load"`) from shell; i18n en + pt-PT. Build with `GOFLAGS=-mod=mod`.
4. **iOS PR:** `AchievementsView` replaces `Features/Badges/BadgesView` when flag on; `AchievementUnlockSheet` (GlassCard + AppMotion, static under reduce-motion) driven by `/unseen` on app-active; `SocialSection.activity` in `SocialRoot`; profile showcase in `SocialProfileView`; new push kinds in `PushNotificationsCoordinator`; register `capabilities:["achievements_v1"]`; privacy toggle in `UserProfileView`.
5. **Infra** (`~/Work/production/platform/infra/apps/norviq/api/values-*.yaml`): staging both flags "1"; production "0" explicit. Merge after A+B deployed to staging (manual dispatch; promote with `-f service=both`).

## Critical files
Backend (`norviq-backend/Sources/StockPlanBackend/`): `Gamification/{XPService,BadgeService,BadgeDefinitions,LeaderboardService,GamificationController}.swift`, `Social/{SocialModels,SocialDTOs,SocialService,SocialController,SocialConfiguration}.swift`, `Notifications/PushNotificationSender.swift`, `Shared/JobLock.swift`, `ConfigureBootstrap.swift`, `routes.swift`, `openapi.yaml`.
Web: `internal/server/server.go`, `internal/handlers/{social,settings,settings_data}.go`, `internal/api/social.go`, `internal/middleware/social.go`, `internal/social/`, `internal/pages/friends/*.templ`, `internal/i18n/locales/active.{en,pt-PT}.json`.
iOS (`norviq-ios/financeplan/financeplan/`): `Features/Social/{SocialRoot,SocialProfileView,SocialStore}.swift`, `Features/Badges/BadgesView.swift`, `API/Social/SocialDTOs.swift`, `Features/Notifications/PushNotificationsCoordinator.swift`, `Features/Home/HomeScreen.swift`.

## My calls (check while reading)
- Legacy 7 badges kept as "Classic badges" category, not retired.
- Founding Member = first 1,000 accounts; hidden count shown ("3 hidden").
- Performance uses existing leaderboard TWR (holdings-only), SPY benchmark regardless of currency, full calendar year of snapshots required.
- Invite achievement counts only accounts created after redeeming the link; no backfill.
- Feed: 90-day window; new friends don't see each other's older unlocks.
- Congrats not undoable; pushes collapse per activity.
- Budget streak (client-reported) trusted as-is.
- Expenses = distinct days total, not a streak.
- Default showcase = highest tier, then most recent.

## Verification
- Backend Swift Testing on real Postgres (`DatabaseTestLock`, models `GamificationRouteTests`, `SocialRouteTests`, `BadgeLogicTests`; check `docker ps` for local DB): table-driven catalogue tests per achievement; evaluate twice → one row, one XP event; backfill → no activity/push, XP excluded from leaderboard; feed privacy (blocks both ways, showAchievements off, perf hidden, non-friend 404, suspended); congrats idempotent; `/v1/badges` unchanged; flag off → 404; `OpenAPIDocsTests`. Stub servers only, no real keys.
- Web: `templ generate`, `GOFLAGS=-mod=mod go test ./...`, flag on/off route tests (`social_routes_test.go` pattern), settings redirect.
- iOS: DTO decode with missing new config fields, push routing for new kinds, sheet under reduce-motion; build in Xcode.
- Staging E2E with two accounts: unlock → sheet/toast + push → friend feed → 🎉 → congrats push; privacy toggles hide items.

## After approval
Save this as design spec `norviq-backend/docs/superpowers/specs/2026-10-21-achievements-design.md`, then superpowers:writing-plans for per-PR task plans.
