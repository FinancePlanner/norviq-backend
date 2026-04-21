# MVP Production And Monetisation Roadmap

## Verdict

The API and server are not yet production-ready for monetisation, but they have a strong product backend foundation. The missing layer is not more portfolio functionality. It is the commercial control plane: subscriptions, entitlements, usage limits, billing event handling, operational safety, and compliance boundaries.

The backend already includes:

- Authenticated `/v1` API routes.
- JWT access tokens and refresh tokens.
- MFA support with production defaults.
- OAuth provider hooks for Apple, Google, and X.
- Redis-backed auth rate limits for register, login, and MFA flows.
- PostgreSQL migrations.
- PII encryption for profile fields.
- APNS device registration and target alert polling.
- Market-data provider abstraction, caching, and stale fallback behavior.
- OpenAPI docs.
- Backend tests for auth, profile, expenses, feedback, news, stocks, statistics, activity, and PII encryption.

The main gap is that every authenticated user is currently treated as equally entitled. For paid plans, the server must know who paid, what they paid for, when access expires, and which expensive or premium workflows they can use.

## Current Strengths

### API Foundation

- Routes are grouped under `/v1`.
- Auth-protected controllers are already used across core product areas.
- The backend has portfolio, stocks, watchlists, broker CSV import, expenses, reports, goals, activity, badges, crypto, news, market data, earnings, feedback, profile, and push-notification surfaces.
- OpenAPI documentation is bundled and served.

### Auth And Account Safety

- Register, login, refresh, password reset, OAuth, MFA, and current-user flows exist.
- Login failures lock accounts after repeated attempts.
- MFA is enabled by default in production.
- Refresh tokens are persisted and rotated.
- Expired auth tokens are cleaned up by a lifecycle task.

### Data And Infra

- PostgreSQL and Redis are configured.
- PII encryption is required in production.
- Market data is cached in Redis and PostgreSQL.
- Background lifecycle tasks exist for auth cleanup and target alert polling.

## Production Gaps

### 1. Subscription State

Add durable server-side billing state. The app client must not be the source of truth for premium access.

Add models and migrations for:

- `Subscription`
- `Entitlement`
- `BillingEvent`
- `UsageCounter`

Recommended `Subscription` fields:

- `id`
- `user_id`
- `provider` (`revenuecat`, `app_store`, `stripe` later if needed)
- `provider_customer_id`
- `provider_original_transaction_id`
- `product_id`
- `plan`
- `status`
- `period_started_at`
- `period_ends_at`
- `trial_ends_at`
- `grace_period_ends_at`
- `cancelled_at`
- `created_at`
- `updated_at`

Recommended entitlement states:

- `free`
- `premium`
- `premium_ai` later
- `team` later

Recommended subscription statuses:

- `active`
- `trialing`
- `grace_period`
- `billing_issue`
- `cancelled`
- `expired`
- `refunded`

### 2. RevenueCat Webhook

The README already points toward RevenueCat. Add:

- `POST /webhooks/revenuecat`
- Webhook signature verification.
- Idempotency by provider event ID.
- Raw event persistence for audit/debugging.
- Mapping from RevenueCat app user ID to backend user ID.
- Entitlement updates on purchase, renewal, cancellation, billing issue, expiration, refund, and transfer events.

Do not unlock premium solely because the iOS client says StoreKit purchased. The server should only trust verified provider state.

### 3. Entitlement Middleware

Add a middleware or route guard that resolves the current user's entitlement and enforces product gates.

Gate these at launch:

- CSV and broker import.
- Unlimited holdings.
- Unlimited watchlists.
- Advanced stock research.
- Peer comparison.
- Multi-year projections.
- Full reports.
- Multiple saved valuation cases.
- Target alerts.
- Earnings text.
- Export/share workflows.

Keep these free:

- Account creation.
- Basic manual portfolio creation.
- Limited holdings.
- Limited watchlist.
- Lightweight expenses planner.
- Basic dashboard.
- Limited stock comparison.

### 4. Usage Limits

Free tiers need measurable limits. Add monthly counters and hard limits for expensive or premium actions.

Suggested counters:

- `portfolio_count`
- `holding_count`
- `watchlist_item_count`
- `valuation_case_count`
- `csv_import_count`
- `target_alert_count`
- `market_refresh_count`
- `report_generation_count`
- `advanced_research_request_count`
- `earnings_request_count`

Usage should reset per billing period for subscription-linked limits, or monthly calendar periods for free users.

### 5. Billing Context API

Add an authenticated billing endpoint:

- `GET /v1/billing/me`

Return:

- Current plan.
- Subscription status.
- Whether the user is in trial, grace period, billing issue, or cancelled-but-still-active state.
- Renewal or expiration date.
- Feature flags.
- Usage counters.
- Usage limits.
- Upgrade reasons for blocked actions.

The iOS paywall and settings screen should consume this response instead of hardcoding plan rules.

### 6. Production Config Hardening

Required before production:

- Fail boot in production if `JWT_SECRET` is missing or still using a development fallback.
- Require explicit production `ALLOWED_ORIGINS`.
- Add security headers at the reverse proxy layer.
- Ensure production database credentials are not the docker-compose defaults.
- Confirm Redis is private and not exposed publicly.
- Document required environment variables for production.

### 7. Health And Observability

The current health route is useful as a basic liveness check, but production needs deeper readiness.

Add:

- `GET /health/live`
- `GET /health/ready`

Readiness should check:

- Database connectivity.
- Redis connectivity when configured.
- Migration state.
- App version/build SHA.
- Market provider configuration.
- Mailer configuration when MFA is enabled.
- APNS configuration when alerts are enabled.

Add:

- Structured JSON logs in production.
- Server-side Sentry or OpenTelemetry.
- Request IDs in logs and responses.
- Uptime monitoring.
- Alerts for 5xx spikes, database failures, Redis failures, webhook failures, and billing sync errors.

### 8. Backup And Recovery

Add an operations runbook for:

- Daily PostgreSQL backups.
- Backup encryption.
- Backup retention.
- Restore drills.
- Migration rollback policy.
- Incident response.
- Manual entitlement repair.

For a finance-adjacent app, recovery confidence is part of product trust.

### 9. Compliance And Trust

Add explicit support for:

- Account deletion.
- Data export.
- Privacy policy.
- Terms of service.
- Investment disclaimer.
- Data retention policy.
- Billing support/refund escalation flow.
- Audit trail for subscription state changes.

Position the app as planning and research support, not financial advice.

## Monetisation Recommendation

Launch with:

- `Free`
- `Premium Monthly`
- `Premium Yearly`

Do not launch with weekly or lifetime plans.

Weekly subscriptions often attract low-intent churn and can make a serious finance product feel less trustworthy. Lifetime plans are risky because the product has recurring costs: market data, email, push notifications, storage, support, and possible future AI or voice processing.

If a lifetime offer is ever used, make it a limited founder plan, price it high, and scope it clearly.

## Suggested Pricing Test

Initial pricing to test:

- `EUR 11.99/month`
- `EUR 89.99/year` to `EUR 99.99/year`
- 7-day or 14-day free trial on annual

The annual plan should be the highlighted default on the paywall.

## Free Plan

Free should drive activation and trust.

Suggested free limits:

- 1 portfolio.
- Limited holdings.
- Limited watchlist items.
- Manual expense planning.
- Basic dashboard.
- Basic or delayed news.
- 1 saved valuation case.
- Limited stock comparison.

## Premium Plan

Premium should unlock the workflows with ongoing value and ongoing server cost.

Suggested premium features:

- Portfolio import.
- Unlimited holdings and watchlists.
- Full expense planner and reports.
- Bear, base, and bull valuation cases.
- Fair value tracking.
- Peer comparison.
- Multi-year projections.
- Earnings text.
- Target alerts.
- Social sharing/export.

## Premium Plus AI Later

Only add a higher tier if AI or voice features create meaningful marginal cost.

Potential premium-plus features:

- Voice earnings.
- AI summaries.
- More alerts.
- Expanded saved valuation cases.
- Export packs.
- Heavy research automation.

Do not add this complexity until retention and conversion data justify it.

## Implementation Order

### Phase 1: Billing Core

- Create billing models and migrations. Implemented with `Subscription`, `Entitlement`, `BillingEvent`, and `UsageCounter`.
- Add `BillingService`. Implemented for RevenueCat webhook event processing.
- Add RevenueCat webhook endpoint. Implemented as `POST /webhooks/revenuecat`.
- Verify webhook signatures. Implemented using `Authorization` matched against `REVENUECAT_WEBHOOK_SECRET`.
- Persist raw webhook events. Implemented as raw payload text on `billing_events`.
- Update subscription and entitlement state idempotently. Implemented with duplicate provider event detection.
- Add tests for purchase, renewal, expiration, refund, cancellation, billing issue, and duplicate webhook events. Covered in `BillingTests`.

### Phase 2: Entitlement And Usage

- Add `EntitlementResolver`. Implemented with free fallback and premium detection.
- Add `EntitlementMiddleware` or per-route guards. Implemented with per-route guards at create/import/report entry points.
- Add `UsageCounterService`. Implemented with monthly counter reset for action counters and resource count sync.
- Enforce free limits. Implemented for portfolio lists, holdings, watchlist items, saved valuation cases, CSV imports, target alerts, and report generation.
- Gate premium-only launch surfaces. Implemented for advanced stock insights, peer comparison, and earnings detail.
- Return clear `402 Payment Required` or `403 Forbidden` responses with upgrade metadata. Implemented with `402 Payment Required` and feature/plan/limit/current metadata in the error reason.
- Add tests for free and premium access paths. Covered in `BillingTests` for free holding limits, premium holding bypass, CSV monthly limits, and premium-only advanced route blocking.

### Phase 3: Billing API For Client

- Add `GET /v1/billing/me`. Implemented as an authenticated billing context endpoint.
- Return plan, status, feature flags, counters, limits, and renewal state. Implemented with plan, entitlement, subscription state, feature availability, usage, limits, and renewal/expiration dates.
- Add app-facing error payloads for blocked premium actions. Implemented for billing upgrade-required failures with stable JSON payloads.
- Keep plan rules server-owned. Implemented through `BillingPlanLimits`, `BillingContextService`, and server-generated feature availability.

Remaining MVP work:

- Mirror the backend billing DTOs into the shared API package when the iOS client is wired to this endpoint.
- Add iOS client consumption in paywall, settings, usage meters, and upgrade prompts.
- Confirm product IDs and display copy against the final RevenueCat product setup.

### Phase 4: Production Hardening

- Require `JWT_SECRET` in production. Implemented as a production boot check.
- Require explicit production CORS origins. Implemented as a production boot check.
- Add readiness checks. Implemented with `/health/live` and `/health/ready`.
- Add structured logging. Implemented with `LOG_FORMAT=json` and request metadata logging.
- Add server-side OpenTelemetry path. Implemented with `swift-otel`, OTel Collector, Jaeger, Grafana, baseline dashboard provisioning, and alert contact/rule provisioning.
- Add deployment environment documentation. Production env requirements are documented in the deployment guide and `.env.production`.
- Add backup/restore runbook. Expanded in the operations runbook with backup, restore-drill, retention, and production preflight scripts.

Remaining MVP work:

- Confirm the checklist items against the deployed production environment, not just local boot checks.
- Confirm production database credentials are rotated away from Docker/development defaults.
- Confirm Redis is private and not exposed publicly in the deployed network.
- Confirm reverse-proxy security headers beyond HSTS are present in the deployed Nginx config.
- Wire Swift server telemetry into the OpenTelemetry path rather than only providing collector infrastructure. Implemented with `swift-otel` behind `OBS_TRACES_ENABLED`.
- Add alerting for 5xx spikes, database failures, Redis failures, billing webhook failures, and repeated entitlement update failures. Baseline Grafana email/Slack alert provisioning is in place; production alert firing still needs to be validated.
- Verify production migration execution is run as the documented manual `migrate` service step during deployment.
- Run and record a restore drill from a real PostgreSQL backup. Scripts are present; the first real production drill must still be executed and recorded.

### Phase 5: Compliance And Support

- Document account deletion behavior. Covered in `docs/compliance-support.md`.
- Add data export support workflow. Covered as a support workflow, not an API, in `docs/compliance-support.md`.
- Add privacy, terms, and investment disclaimer requirements. Covered in `docs/compliance-support.md`.
- Add internal support procedures for entitlement repair and refund investigation. Covered at workflow level in `docs/compliance-support.md`.

Remaining MVP work:

- Turn the documented privacy, terms, and investment disclaimer requirements into published customer-facing documents. Draft Markdown source documents are now in `docs/legal`.
- Decide whether data export is a manual support workflow for launch or a self-service API. Launch default is manual support workflow.
- If export stays manual for launch, define the exact operator command/query pack and secure delivery channel. Implemented with `scripts/ops/export_user_data.sh` and compliance runbook notes.
- Add an internal audit trail procedure for manual entitlement changes and data export requests. Implemented in `docs/support/audit-log.md`.
- Define refund investigation handoff between RevenueCat/App Store records and backend `billing_events`. Implemented in `docs/support/refund-investigation.md`.
- Decide whether account deletion should hard-delete all records or retain billing/audit records required for tax, fraud, or support. Launch default is hard-delete user-owned data with narrow billing/audit retention.

## Minimum Viable Production Checklist

- [x] Production env fails boot without `JWT_SECRET`.
- [x] Production env fails boot without PII encryption keys.
- [x] Production CORS origins are explicit.
- [x] Database migrations have a controlled deployment step documented through the production `migrate` service.
- [x] RevenueCat webhook is implemented and verified.
- [x] Billing events are idempotent.
- [x] Entitlements are persisted server-side.
- [x] Initial premium and usage-limit gates are enforced server-side.
- [x] Free usage limits are enforced server-side.
- [x] Advanced research, peer comparison, and earnings detail require premium server-side.
- [x] `GET /v1/billing/me` exists.
- [x] Health readiness checks DB and Redis.
- [x] Server telemetry is wired to OpenTelemetry when enabled.
- [ ] PostgreSQL backups are automated and restore-tested in production.
- [x] Privacy policy, terms, and investment disclaimer source docs are ready.
- [x] Account deletion and data export paths are defined at workflow/API level.

## Recommended First Premium Gates

Start with gates that are easy to explain and easy to enforce:

1. CSV portfolio import.
2. More than one portfolio.
3. Holdings above the free limit.
4. Watchlist items above the free limit.
5. More than one saved valuation case.
6. Full reports.
7. Advanced stock research and peer comparison.
8. Target alerts above the free limit.

Avoid gating basic onboarding too aggressively. Users should experience value before being asked to pay.
