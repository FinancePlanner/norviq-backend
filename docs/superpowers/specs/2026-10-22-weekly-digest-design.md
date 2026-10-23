# Norviq weekly digest ("Your money, explained") + sentiment alerts

## Context

Norviq has moat features but no weekly reason to come back. The spec (user's /plan brief, 2026-10-22) asks for a Sunday digest (email + push + in-app card + Telegram) that explains the user's own week, and mid-week push alerts when X sentiment on a holding turns sharply negative. `post-mvp-features.md:41` calls it the "strongest retention lever"; `go-public-activation-plan-v2.2.md:37-38` marks both DO NOT CLAIM. No digest code exists. Success = 30% of recipients open Norviq within 48 h, four straight weeks, read four weeks after phase 2.

## Decisions (user, 2026-10-22)

| Question | Decision |
|---|---|
| AI consent | **Gates the narrative only.** Anyone eligible can opt in; numbers-only without consent. Check `users.ai_data_consent_at` directly (`AIConsent.consentedAt`), NOT `AIConsent.isAllowed` — that returns true for everyone while `AI_CONSENT_ENFORCED` is off in prod. |
| Alert direction | **Negative only.** |
| Sender | **Same `RESEND_FROM_EMAIL` as MFA.** So: per-tick send cap, allowlisted prod rollout, watch Resend bounce/complaint stats before widening. |

## Spec corrections found in the code

1. **Deep links use `financeplan://`**, not `norviq://` (only `financeplan` is in iOS Info.plist). Digest link: `financeplan://digest/<id>`.
2. **Ex-dividend dates have no source.** `PortfolioController.swift:48` hardcodes a placeholder; `dividends` holds only received dividends. Section 5 ships earnings-only; ex-div moves to "Later".
3. **No per-user timezone on `users`.** Store it in `digest_preferences.timezone`, set by the client on PUT (iOS `TimeZone.current.identifier`, web `Intl`); fallback `RecapTimeZoneResolver.timeZone(for:on:)`.
4. **No server-side PostHog.** Add a minimal capture client (below) so `digest_sent` and `app_opened_from_digest` share one `distinct_id`.
5. **Mailer is plain-text only.** `MailMessage`/`ResendEmailPayload` need `html` + `headers`. Recap spec plan 2 (`norviq-backend/docs/superpowers/specs/2026-10-16-recap-design.md:100-126`) designs the same extension, so build it generically here and recap reuses it.
6. **`NotificationEventKind` is a strict enum** (`norviq-shared/.../Automation/WealthAutomationDTOs.swift:709`). Adding a case and writing it to `notification_events` breaks inbox decoding on iOS ≤ 1.4.1. **Digest and alerts do not use `NotificationEventPublisher`.** They get their own push methods. Shared 5.27.0 also adds a tolerant `unknown` fallback, for later.
7. **"Net worth" can't come from `net_worth_snapshots`** (global, no `user_id`). Use `portfolio_value_snapshots` per currency, as `RecapFactsCollector.swift:200-224` does, with no FX conversion. Copy says "Portfolio", not "Net worth", until bank balances are included.
8. **Valuation has no historical pricing** (`PortfolioValuationService` uses `currentPrice`). Weekly movers come from `MarketDataService.history(symbol:from:to:)` / `price_history`: contribution = shares × (close_end − close_start).
9. **`symbol_sentiment_daily` is built once a day** (05 UTC), too coarse for a 15-min poller with a 1-h staleness rule. The 24-h window reads `ticker_sentiment_posts`; the 7-day baseline reads `symbol_sentiment_daily`.
10. **Alert deep link:** `financeplan://stocks/<SYM>` (an existing route that works on old builds) instead of why-moved, which only lists the day's price movers and may not include the symbol.
11. **Shared pin:** backend and iOS are both on exact `5.25.0`; `v5.26.0` (Groups DTOs) exists. The digest DTOs ship as `v5.27.0`, which pulls in the Groups DTOs too, so confirm both repos compile against it.

## Global constraints

- Backend work goes in a worktree off `origin/main` (the main checkout is on `fix/recap-route-flag-flake`, and local `main` is stale). `feat/achievements` touches the same registration points (`ConfigureBootstrap.registerMigrations`, `configure.swift` lifecycle, `routes.swift`, `openapi.yaml`). Whichever lands second rebases.
- Haiku 5.5: no `temperature`/`top_p`/`top_k`/prefill. Tests use stub clients only (`ChatClientStub` in `WhyMovedTests.swift:173`, `AnthropicStubHTTP`).
- Every new env var goes in **both** `values-production.yaml` and `values-staging.yaml` under `platform/infra/apps/norviq/api/`. Helm replaces lists, so `values-common` env is discarded.
- Deploy: staging = `deploy-k3s.yml` dispatch; prod = `promote-norviq.yml` with `service=api`, then web (`both` when web changed). API before web.
- Backend pre-commit swiftformat drift: check the commit stat; use `--no-verify` if the whole repo got reformatted.
- Save the approved plan as `norviq-backend/docs/superpowers/specs/2026-10-22-weekly-digest-design.md` (repo convention) before slice 1.

## Flags (all default off)

`DIGEST_ENABLED`, `DIGEST_EMAIL_ENABLED`, `DIGEST_PUSH_ENABLED`, `DIGEST_NARRATIVE_ENABLED`, `DIGEST_USER_ALLOWLIST` (comma-separated UUIDs; empty = everyone), `DIGEST_MAX_EMAILS_PER_TICK` (default 25), `SENTIMENT_ALERTS_ENABLED`, `SENTIMENT_ALERT_MIN_DROP` (0.35), `SENTIMENT_ALERT_MIN_VOLUME_RATIO` (2.0), `SENTIMENT_ALERT_MAX_AGE_MINUTES` (60), `POSTHOG_PROJECT_TOKEN` / `POSTHOG_HOST` (backend). Read via `envBool` (`ConfigureBootstrap.swift:456`).

---

## Slice 1 — Digest core, numbers-only email (M)

**Data** — `Migrations/CreateDigestTables.swift`, appended to `registerMigrations`. Shape follows `CreateEarningsNotificationPreference.swift`; raw-SQL index as in `AddDailyBoardPosts`.
- `digest_preferences`: `user_id` PK → users cascade, `email_enabled`, `push_enabled`, `telegram_enabled`, `sentiment_alerts_enabled` (added now so the table is created once), `weekday` (ISO, default 7), `local_hour` (default 18), `timezone`, `unsubscribe_token` (random, unique), `created_at`, `updated_at`. No row = never decided (drives the opt-in card).
- `weekly_digests`: as in the spec, plus status `skipped`. Unique `(user_id, period_start)`. `payload` stored as JSONB via `sql.raw` (precedent: `CreatePilotTables`).
- `weekly_digest_deliveries`: `digest_id`, `channel` (email/push/telegram), `status`, `sent_at`, `error`. Unique `(digest_id, channel)`. Claimed **before** sending, so a crash means at most once per channel.
- `sentiment_alerts`: as in the spec (used in slice 3).

**Mail** — `Services/MailerService.swift`: add `htmlBody: String?` and `headers: [String: String]` to `MailMessage`, and `html`/`headers` to `ResendEmailPayload`. Keep existing MFA callers unchanged (defaults nil/empty).

**Code** — new `Digest/` folder:
- `DigestSchedule.swift`: due check and period. Due when local isodow == `weekday` and local hour ≥ `local_hour`, and less than 6 h late (past that, insert as `skipped` so an outage never sends a Monday digest). `period_start` = local Monday, `period_end` = the send date.
- `DigestFactsCollector.swift`:
  - Portfolio change per currency: extract the snapshot-growth helper out of `RecapFactsCollector` and share it.
  - Top 3 movers by absolute contribution, from `MarketDataService.history`.
  - Budget: the two categories furthest over/under, from `BudgetingEngineService.dashboard`.
  - Personal inflation: from `MacroService.personalInflation`, only when its latest month is newer than the one in the user's previous digest payload.
  - Next-week earnings: from `earningsService.getCalendar`, filtered to held symbols.
  - Empty sections are omitted.
- `DigestComposer.swift`: facts → `DigestPayload` (Codable sections, deterministic). Narrative is a nil hook until slice 2.
- `DigestEmailRenderer.swift`: HTML + text bodies. Section links point to `https://norviq.org/digest/<id>?s=<section>&src=email`. Footer has the unsubscribe link. Headers: `List-Unsubscribe: <https://api.norviq.org/v1/digest/unsubscribe?token=…>` and `List-Unsubscribe-Post: List-Unsubscribe=One-Click`.
- `WeeklyDigestJob.swift`: 15-min tick, `BackgroundJobState` + `JobLock.runAsLeader(app, name: "weekly_digest_job")`, skipped under `.testing`.
  - Claim: `INSERT … SELECT FROM digest_preferences … WHERE due AND eligible … ON CONFLICT (user_id, period_start) DO NOTHING RETURNING id LIMIT 25`. Due is computed in SQL with `now() AT TIME ZONE p.timezone` (Postgres handles DST).
  - Eligible: holds ≥1 position or has an active `bank_connections` row, and is in `DIGEST_USER_ALLOWLIST` when that is set.
  - Then compose → status `composed`; claim the email delivery → send → `sent`/`failed`. Per-tick email cap.
- `DigestController.swift`: `GET /v1/digests`, `GET /v1/digests/{id}` (owner only), `GET`/`PUT /v1/digest-preferences`, and public `POST /v1/digest/unsubscribe?token=` (idempotent, sets `email_enabled=false`).
- Operator command `digest-send --user <uuid> [--dry-run]` (pattern: `market-brief-generate`) to render or send one digest on demand.
- `openapi.yaml`, plus registration in `configure.swift`/`routes.swift` behind `DIGEST_ENABLED`.

**Shared** — `norviq-shared/Sources/StockPlanShared/Digest/DigestDTOs.swift` (payload, list item, preferences). Add a tolerant decode for `NotificationEventKind`. Tag `v5.27.0`; bump only the backend now (iOS bumps in slice 2, same release as its UI).

**Web (small)** — public `GET /digest/unsubscribe?token=` page with a confirm button that POSTs to the API (hand-written `DoJSON`, as in `internal/api/dca_capacity.go`). A mail client's GET must never unsubscribe on its own.

**Before prod** — check SPF/DKIM/DMARC for the sending domain in the Resend and Cloudflare dashboards (nothing in the repos). Prod starts with `DIGEST_USER_ALLOWLIST` = internal account only.

## Slice 2 — Narrative, push, in-app card, events (M)

- **Narrative.** `Digest/DigestNarrator.swift`:
  - One call per digest via `AIPlanRouting.client(for:on:)`; prompt in `AIPrompt`, following `WhyMovedService`'s facts-JSON + `json_object` pattern. Facts include highlights from `AIHighlightBuilders`.
  - Returns `{movers:[{symbol, why}]}`, at most 3 sentences per mover.
  - Cap: `AIDailyCap.enforce(…, bucket: "ai_digest_weekly", limit: 1)`.
  - Validator, modelled on `MarketBriefValidator`: reject any sentence containing a number that is not in the facts, and drop it.
  - Any failure, missing consent, or `DIGEST_NARRATIVE_ENABLED=false` gives numbers-only.
  - Store `model`. `token_count` only if the client exposes usage; otherwise leave it nil and rely on the `ai_completion` logs.
- **Push.** Add `sendWeeklyDigest` to `PushNotificationSending` (protocol-extension no-op default, as the newer methods have):
  - category `WEEKLY_DIGEST`, thread `weekly-digest`;
  - payload `{schemaVersion:1, type:"weekly_digest", digestId, deepLink:"financeplan://digest/<id>"}`;
  - body like "Your week: +€412 (+1.8%). NVDA did most of it." Uses the push delivery claim.
- **Server analytics.** `Analytics/PostHogCapture.swift`: fire-and-forget POST to `{POSTHOG_HOST}/i/v0/e/` with `distinct_id` = user UUID string. **Verify** that iOS `PostHogSDK.identify` and web `posthog.js` identify with the same string. Events: `digest_sent` (per channel), `digest_unsubscribed`.
- **iOS** (bump shared to 5.27.0):
  - Routing: `PushNotificationRoute.Kind.weeklyDigest` + parser; register `WEEKLY_DIGEST` in `PushNotificationsAppDelegate`; `handleDeepLink` case for `financeplan://digest/<id>`; `ContentView` switch case; `HomeScreen.onReceive`; `DigestRouter`, mirroring `MarketBriefRouter` and its `openCount` scroll.
  - `Features/Digest/`: `DigestCard`, placed after `MarketBriefCard` in `DashboardContentSection` and hidden when empty; `DigestDetailView`; `DigestOptInCard`, shown when eligible and no preferences row exists, with one toggle per channel (Telegram only if linked) and "Not now" writing an all-off row.
  - Settings: `DigestToggles` in `UserProfileView`'s Alerts section, copying `MarketBriefAlertsToggle`/`MarketBriefAlertsStore` (optimistic update, rollback, `ensurePushOptIn`).
  - Endpoints in `API/Digest/`. PostHog: `app_opened_from_digest` when the route is delivered.
- **Web:**
  - `/digest/{id}` page (signed-in); captures `digest_clicked` + `app_opened_from_digest` via `window.norviqAnalytics.capture` when `src=email`.
  - Lazy home card partial, as `WhyMovedShell` does.
  - Digest toggles in `NotificationsForm` (`internal/pages/settings/sections.templ`).
  - A filtered oapi-codegen config, as `oapi-codegen-market-brief.yaml` does.
- After this slice ships: edit `go-public-activation-plan-v2.2.md` to lift DO NOT CLAIM for the digest only.

## Slice 3 — Sentiment alerts (S–M)

- `Insights/SentimentAlertPoller.swift`: 15-min tick, `JobLock` `"sentiment_alert_poller"`, gated on `SENTIMENT_ALERTS_ENABLED`.
  - Universe: distinct held symbols for users with `push_enabled` and `sentiment_alerts_enabled`.
  - Per symbol:
    - **24 h window:** mean score and post count from `ticker_sentiment_posts`, filtered to the X source. **Verify** the `source` label values.
    - **7-day baseline:** mean score and mean daily `post_count` from `symbol_sentiment_daily`.
    - **Fire when** baseline − current ≥ `MIN_DROP`, count ≥ `MIN_VOLUME_RATIO` × baseline, and current < −0.15 (the negative label).
    - **Skip** when the newest post or the last Hermes sync is older than `MAX_AGE_MINUTES`.
  - Cooldown: no alert for the same (user, symbol) within 72 h, and at most 2 per user per local day (checked on `sentiment_alerts`).
  - Insert the `sentiment_alerts` row first, then push.
- `sendSentimentAlert`: category `SENTIMENT_ALERT`, deep link `financeplan://stocks/<SYM>`. iOS parser and `app.sentiment_alert_opened` event; server `sentiment_alert_sent`.
- Operator command `sentiment-alert-backtest --days 30`: replays the rule over historical posts against current holdings and prints alerts per user per week. **Gate:** ≤ 2/user/week before the flag goes on in prod.
- Lift DO NOT CLAIM for alerts only after this ships.

## Slice 4 — Telegram + MCP (S)

- `Digest/DigestTelegramRenderer.swift`: plain text, split with `TelegramFormat`. Sent via `MessagingLinkService.link` + `TelegramClient.send` when `telegram_enabled`; uses the telegram delivery claim. Check `MessagingPreferenceService` quiet hours.
- `norviq-mcp/internal/tools/digest.go`: `get_weekly_digest` (optional `period_start`), `ReadOnlyHint`. Gated on an existing read scope (no new OAuth scope); hand-written client in `internal/api`, modelled on `get_market_brief`.

---

## Risks to watch

- **Shared MFA sender.** The per-tick cap and allowlist protect it; check Resend complaints and bounces after each widening.
- **Metric noise.** With very few strangers, 30% is anecdotal. Exclude the internal/allowlisted accounts from the PostHog insight; track stranger week-2 return on the demand-hour scoreboard.
- **Haiku trial ($20 cap).** About 3k tokens per user per week is cents for 100 users, but if the cap trips, every call pays one failed request first. Narrative failure must degrade to numbers-only, never block a send.

## Verification

- **Unit:**
  - composer snapshot tests on fixture portfolios (multi-currency, empty budget, no snapshots);
  - `DigestSchedule` across the two DST weekends (Europe/Lisbon 2026-10-25 and 2027-03-28) and a US zone;
  - narrator validator rejects invented numbers;
  - alert thresholds, staleness, 72 h and 2/day cooldowns.
- **Integration (real Postgres via `DatabaseTestLock.withApp`):**
  - two concurrent `runOnce` calls produce one digest and one email;
  - a rerun after a crash between claim and send does not resend;
  - unsubscribe is idempotent;
  - mailer stub `RecordingMailerService` (`AuthTests.swift:1371`) captures `html` and the List-Unsubscribe headers;
  - push recorder captures the `WEEKLY_DIGEST` payload;
  - LLM stubbed via `ChatClientStub`.
- **Snapshot:** rendered email HTML.
- `swift test` in the worktree, `go test ./...` in norviq-web (`GOFLAGS=-mod=mod`) and norviq-mcp, plus an iOS build.
- **Staging:** set the flags in `values-staging.yaml`; seed a user in `norviq-staging`; run `digest-send --user <id>`; confirm the email in a real inbox (Gmail "Unsubscribe" button present), the push on a real device opens the card, and the PostHog events land.
- **Prod:**
  - promote API → web;
  - allowlist the internal account;
  - after one real Sunday, check that `weekly_digest_deliveries` has exactly one row per channel;
  - then clear the allowlist.
