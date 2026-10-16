# Norviq Recap — monthly recap + yearly "Wrapped"

## Context

Fernando wants a Spotify-Wrapped-style, animated recap of what each user did in
Norviq: a **yearly** year-in-review plus a **monthly** recap built on the same
engine. Flagged per CLAUDE.md as a new idea / engagement polish while the
strangers-count may be low; Fernando chose to proceed (2026-10-16).

Exploration showed Norviq already stores enough timestamped per-user data to
compute recaps with **no new tracking**. What's missing is an aggregation
layer, a story-style UI on iOS and web, and a delivery pipeline (push, home
card, email).

## Decisions made by Fernando

| Topic | Decision |
|---|---|
| Hero / shareable slide | **Investor personality** archetype |
| Platforms | **iOS and web at once**; backend computes once, both render |
| Personality logic | **Fixed rules**, 8–12 hand-written archetypes, no LLM |
| Money figures | **Shown on private slides only**; share image never carries $ or % |
| Thin data | **Shorter recap**: slides lacking data are skipped; below a minimum → short "Your first chapter" deck |
| Cadence | **Yearly + monthly** |
| Monthly delivery | **Push + home card + email** |
| Email default | **On for everyone**, one-click unsubscribe (Fernando accepted the EU consent grey area; see Risks) |
| Yearly window | **Full calendar year**, released **Jan 1** (open through Jan 31 — my call) |
| Monthly recipients | **Everyone**; inactive users get a "we missed you" recap |
| Sharing | **Image + public link** (`norviq.org/r/{token}` with link preview) |

## Goals / non-goals / anti-goals

- Goals: delight + a reason to come back on the 1st of each month; one
  shareable card per recap that markets Norviq without leaking finances.
- Non-goals: new event tracking, LLM-written copy, social leaderboards in the
  recap, Android.
- Anti-goals (failure even if it works): share card exposing money; a recap that
  states wrong numbers; duplicate pushes/emails; email without unsubscribe;
  slides that feel like a dashboard instead of a story.

## Design

### 1. Backend — `Recap/` module (Swift, `norviq-backend/Sources/StockPlanBackend/Recap/`)

- **`RecapPeriod`**: `.month(year, month)` | `.year(year)`. `User` has no time
  zone field (my call): use the user's latest `gamification_check_ins.time_zone`,
  fallback UTC. No new user column.
- **`RecapFactsCollector`** — one query per source, period-bounded. Sources
  (all existing tables):
  - Holdings/trades: `stocks`, `transactions` (via `accounts.user_id`), `lots`,
    `lot_disposals` → trades count, most-traded tickers, realized P&L (private).
  - Value: `portfolio_value_snapshots` (has `user_id`) → start-vs-end growth (private).
    **Not** `net_worth_snapshots` — it is a global Hermes feed with no `user_id`
    (`Migrations/CreateNetWorthSnapshot.swift:7-12`); using it would leak one
    person's net worth to everyone.
  - Income: `dividends` → total received (private), dividend payers count.
  - Research: `watchlist_items`, `research_notes`, `targets`, `position_memos` → top researched tickers, theses written, targets hit.
  - Habits: `gamification_check_ins` (longest streak, active days), `gamification_xp_events`, `user_badges` (earned in period).
  - Other: `expenses` + `financial_goal_contributions` (saved toward goals), `pilot_follows`, `board_posts`/`board_comments`, `ai_usage_monthly`.
  - Reuse `Statistics/StatisticsController` service logic (`getWinnersVsLosers`, `getSectorGains`) where it already computes per-period — call the service layer, not HTTP.
- **`RecapFacts`** — plain struct of numbers. Testable without DB.
- **`PersonalityClassifier`** — pure function `RecapFacts -> Archetype`.
  Ordered rule table, first match wins, with a default ("The Steady Builder").
  Draft archetypes (names/copy are Fernando's verdict): Patient Planner, Ticker
  Hunter, Dividend Farmer, Researcher, Disciplined Sizer, Copycat Strategist
  (pilots), Saver, Comeback Kid, Night Owl (if timestamps allow), Steady Builder.
- **`RecapDeckBuilder`** — `RecapFacts -> [Slide]`. Each slide type has an
  eligibility predicate; ineligible slides are dropped. If fewer than
  `minFullDeckSlides` (builder's call, start at 4) remain or user has < 7
  active days in period → "first chapter" deck (intro, 1–2 available slides,
  teaser "see you next month/year").
- **Persistence** — table `recaps`: `id, user_id, period_kind, period_key
  ("2026-10" / "2026"), payload jsonb (deck), archetype, schema_version,
  generated_at, opened_at, completed_at`. Unique `(user_id, period_kind,
  period_key)`. Stored so numbers are stable once seen and delivery is
  idempotent.
- **Email delivery claim** `recap_email_deliveries`: unique `(recap_id)` —
  insert before sending, so replicas/restarts never double-send. Push already
  has its own delivery claim inside `publishAndPush`; reuse it, no extra table.
- **Endpoints** (register in `routes.swift` on `v1`, auth required):
  - `GET /v1/recaps` — available recaps (for home card + archive).
  - `GET /v1/recaps/{kind}/{key}` — deck; generates on demand if missing and period closed (or yearly window open).
  - `POST /v1/recaps/{id}/opened`, `/completed` — progress for card dismissal.
  - `POST /v1/recaps/{id}/share` → creates/returns a share token;
    `DELETE /v1/recaps/{id}/share` revokes it.
  - `GET /v1/public/recap-shares/{token}` (no auth, rate-limited) → returns
    only `RecapShareCard`, 404 if revoked.
- **Money-free share card by construction**: `RecapShareCard` DTO built only
  from archetype + non-money stats (streak, tickers researched, badges) + the
  user's display first name (no email, no surname). It has no money fields, so
  a leak is a compile error, not a review miss. The public endpoint can only
  serialize this type.
- **Share links** table `recap_shares`: `token` (128-bit random, url-safe),
  `recap_id`, `created_at`, `revoked_at`. One active token per recap. Tokens are
  created only when the user taps Share (never pre-made).
- **Jobs** (`LifecycleHandler` + `scheduleRepeatedTask`, like `MarketBriefJob`
  / `AIAssistantRetentionJob`):
  - `MonthlyRecapJob`: hourly tick; for **all** users whose local time is past
    the 1st 09:00, generate last month's recap, then deliver push → card →
    email. Users with zero activity get a "we missed you" deck (intro, last
    known streak/badges, one nudge slide). Email sends are throttled (batch
    size + pause) to protect Resend domain reputation.
  - Yearly: on **Jan 1** the same tick generates `period_kind=year` for the
    full previous calendar year. That day sends **one combined** push/email
    ("Your 2026 Wrapped + December recap"), not two. Window closes Jan 31; after
    that the recap is still in the archive, but the home card goes away.
- **Push**: `NotificationEventPublisher.publishAndPush` (`Notifications/`), deep
  link `financeplan://recap/{kind}/{key}` (the only registered scheme —
  `Info.plist:60`, `AssistantPushRouting.swift:17`; same as market brief
  pushes). Route it in `PushNotificationsCoordinator`.
  - `NotificationEventKind` is a shared enum (`WealthAutomationDTOs.swift:709`):
    adding a `recap` case could break decoding of the notification list on old
    iOS builds. Builder must check the decoder; if it isn't tolerant, make it
    tolerant (unknown → `.other`) in the iOS release first, and enable recap
    pushes only after adoption.
- **Email**: `MailerService` (Resend) is plain text only, no custom headers
  (`Services/MailerService.swift:89-93`) → extend `MailMessage` with optional
  `htmlBody` + `headers`. Jobs build their own `Request`, so no app-scoped path
  needed. Link to web recap, **one-click unsubscribe** (signed token,
  `List-Unsubscribe` + `List-Unsubscribe-Post` headers). Backfill: no rows needed
  if "missing preference row = defaults (push on, email on)".
- **Preferences**: `recap_notification_preferences` (push, email), copying
  `CreateMarketBriefNotificationPreferences` + its service. Email default
  **on**; unsubscribe flips `email=false` without login.
- **Flags** (env, set in `platform/infra/apps/norviq/api/values-*.yaml`):
  `RECAP_ENABLED`, `RECAP_MONTHLY_DELIVERY_ENABLED`, `RECAP_EMAIL_ENABLED`,
  `RECAP_YEARLY_ENABLED`. Staging on first, prod off until Fernando flips.

### 2. Shared DTOs — `norviq-shared/Sources/StockPlanShared/Recap/RecapDTOs.swift`

`RecapDeckDTO { period, archetype, slides: [RecapSlideDTO], isFirstChapter }`.
`RecapSlideDTO` = tagged enum (`intro`, `topTickers`, `streak`, `trades`,
`growth`, `dividends`, `research`, `badges`, `goals`, `personality`, `outro`),
each with typed payload + `isPrivate` flag. New shared version; bump the exact
pin in **both** backend and iOS (they're often on different pins). Update
`openapi.yaml` and regen `norviq-web/internal/api/client.gen.go` (oapi-codegen).

### 3. iOS — `norviq-ios/financeplan/financeplan/Features/Recap/`

- `RecapStoryView`: full-screen, story progress bars on top, tap left/right,
  long-press pause, auto-advance ~5 s, swipe down to dismiss.
- One SwiftUI view per slide type; animations from `AppMotion` tokens
  (`AppMotion.swift`) and `AppTransition` (as in
  `OnboardingQuestionnaireFlow.swift`): count-up numbers, staggered ticker
  reveals, archetype reveal. Respect Reduce Motion (cross-fade only).
- Share: `RecapShareCardView` rendered via `Utilities/ChartExporter.swift`
  (`ImageRenderer`), same as `MarketBriefShareMenu.cardImage()`. Story-size
  1080×1920 image + public link (from `POST /share`) in the share sheet.
  "Stop sharing" in the recap's menu calls `DELETE /share`.
- Entry: home card from `GET /v1/recaps`; deep link from push; archive list in profile.
- PostHog events via `AnalyticsService`: `recap_opened`, `recap_slide_viewed`,
  `recap_completed`, `recap_shared`.

### 4. Web — `norviq-web`

- Route `/recap/{kind}/{key}` (chi), templ page, one `<section>` per slide;
  CSS keyframes + small vanilla JS for progress bars/tap zones/auto-advance; HTMX
  not needed inside the story. `prefers-reduced-motion` honored.
- Share PNG: new `internal/sharecard/recap.go` (pattern:
  `internal/sharecard/brief.go`). The Swift backend has no image library, so
  all server-side PNGs come from web. Share bar via `internal/server/assets/share.js`.
- **Public page** `/r/{token}` — public route next to the market brief ones
  (`internal/server/server.go:225-228`, handler pattern
  `internal/handlers/market_brief_page.go`): archetype card + "Get your own
  Norviq recap" CTA, Open Graph/Twitter tags pointing at `/r/{token}/og.png`,
  `noindex`, short cache. Revoked → friendly 404.
- Dashboard card linking to latest unopened recap.
- Same PostHog events via `internal/server/assets/posthog.js`.

### 5. Visual design (Fernando keeps the verdict)

Agents draft 2–3 visual directions for the slide deck (palette, type, motion)
as clickable HTML prototypes using fixture decks (full, first-chapter, money
slides). Fernando picks one before platform UI work starts.

## Rollout order

0. Commit this design as
   `docs/superpowers/specs/2026-10-16-recap-design.md`, then
   `superpowers:writing-plans` → task-level plan.
1. **Visual direction** prototypes → Fernando picks.
2. **Backend engine + shared DTOs + web story + share/public page** → staging
   with fixture users.
3. **iOS** story view + tolerant `NotificationEventKind` decoding → TestFlight
   → App Store. Must be live before recap pushes go to iOS.
4. **Monthly recaps** (first real one: Nov 1 → October on staging; prod on
   Dec 1 for November once iOS has shipped).
5. **Yearly Wrapped** Jan 1, 2027 (full 2026) + December monthly, one combined push.

Deploys are manual dispatch (staging, then promote with `-f service=both`).
Infra flags in `~/Work/production/platform/infra` only, never `norviq-infra/`.

## Risks (accepted by Fernando, flagged once)

- **Email on by default to everyone, including inactive users**: EU ePrivacy
  consent grey area + spam complaints can hurt Resend domain reputation, which
  also carries MFA emails. Mitigations: one-click unsubscribe, throttling,
  separate `RECAP_EMAIL_ENABLED` kill switch. Worth a look by the same
  compliance read that is pending for pilots.
- **Public share links**: a privacy-policy line is needed ("shared recap pages
  are public until you stop sharing"). Content is money-free by type.
- Engagement polish while the strangers count is low (CLAUDE.md flag, Fernando
  chose to proceed).

## Left to the builder

Exact slide eligibility thresholds, archetype rule ordering (draft for
review), job tick interval, PNG layout details, test fixtures.

## Verification

- Unit: `PersonalityClassifier` (table-driven per archetype), `RecapDeckBuilder`
  (thin-data → first chapter, ineligible slides dropped), period boundaries in
  non-UTC time zones, `RecapShareCard` has no money fields.
- DB tests against `norviq-test-pg` on :55432: facts collector over seeded
  user; unique constraint stops double email when job runs twice concurrently;
  Jan 1 sends one combined push, not two; revoked token → 404; public endpoint
  JSON contains no money keys.
- Web: `go test ./...` (with `GOFLAGS=-mod=mod`), templ render test, golden PNG for share card.
- iOS: snapshot/preview of each slide with fixture decks; Reduce Motion path.
- E2E on staging: seed a user, trigger job for Oct, confirm one push, one
  email (Resend test inbox) with working unsubscribe, card shows, deck opens on
  web + iOS TestFlight, share PNG has no $ / %.
