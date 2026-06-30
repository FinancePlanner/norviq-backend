# MVP Launch Checklist

This is the backend-owned cross-repo MVP checklist for StockPlan/Norviq. It consolidates the backend, web, and iOS launch gaps into one place so MVP work can stay focused on the shipped product instead of drifting into post-launch features.

## Product Scope

MVP means a reliable finance app that can be launched to TestFlight/App Store and the web with:

- authenticated accounts and session recovery;
- backend-canonical portfolio, watchlist, stock detail, expense, report, billing, profile, export, and support data;
- a working Free/Pro monetization path backed by RevenueCat and backend entitlements;
- production health checks, restore confidence, legal links, account deletion, and support workflows;
- clear empty/error states instead of demo data in signed-in runtime UI.

Do not expand MVP to include a conversational AI assistant, full paper trading, scheduled broker sync, live market data, tax packs, or advanced admin tooling. Those are post-MVP candidates.

## Status Overview

| Area | MVP status | Main remaining work |
| --- | --- | --- |
| Backend | Mostly implemented, needs production verification and contract cleanup | Run production preflight, prove backup/restore, verify RevenueCat/APNS/OAuth/legal/account deletion in production, keep OpenAPI in sync, polish provider/export/dividend edges |
| Web app | High parity with iOS, needs launch polish | Decide browser push/PWA installability, run Lighthouse/manual QA, improve partial-load/error UX, harden trading dashboard behavior, address lint debt |
| iOS app | Core app is built, needs canonical-data and release-readiness checks | Remove any remaining local fallback in Expenses/Reports, confirm empty/error states, add UI smoke coverage/accessibility IDs, replace placeholder trust copy, verify TestFlight/App Store/paywall/legal/account deletion flows |

## MVP Blockers

These items should be closed or explicitly accepted before public MVP launch.

### Backend

- [ ] Run and record the production preflight from `scripts/ops/production_preflight.sh` against the production API and web origin.
- [ ] Verify `/health/live` and `/health/ready` pass in production, including database, Redis, mailer, APNS, market-data configuration, request IDs, CORS, reverse-proxy security headers, and JSON log shape.
- [ ] Prove encrypted PostgreSQL backups can be restored by running `scripts/ops/restore_drill_postgres.sh` against a non-production restore database and recording the result.
- [ ] Confirm production secrets are real, not defaults: `JWT_SECRET`, database credentials, Redis exposure, `PII_ENCRYPTION_KEY`, OAuth provider keys, APNS keys, RevenueCat secret key, and RevenueCat webhook secret.
- [ ] Configure RevenueCat production webhook URL and send a real/test webhook event that returns `200 OK`.
- [ ] Verify `POST /billing/restore` and `GET /billing/me` return correct entitlement state after a sandbox/TestFlight purchase, cancellation, refund/expiration scenario, and restore.
- [ ] Confirm Pro-gated backend endpoints fail closed for free users and remain non-blocking for free MVP workflows.
- [ ] Confirm `OPENAI_API_KEY` absence leaves the server bootable and returns a controlled `503` for AI insight endpoints instead of breaking launch.
- [ ] Verify APNS production credentials and topic with `scripts/ops/check_apns_production.sh`, or explicitly disable push-dependent launch promises.
- [ ] Verify OAuth production redirect URIs for Apple, Google, and X match backend/web configuration; disabled providers must fail clearly.
- [ ] Verify account deletion end-to-end from iOS/web through backend persistence and support audit notes.
- [ ] Confirm live Privacy Policy, Terms of Service, and Investment Disclaimer URLs are published and match the App Store metadata.
- [ ] Re-run OpenAPI docs tests/codegen checks after any final route changes; treat `Sources/StockPlanBackend/openapi.yaml` drift as a launch blocker.
- [ ] Decide whether support-only data export is acceptable for MVP; if yes, verify `scripts/ops/export_user_data.sh` and the support audit-log workflow.
- [ ] Review unfinished or fragile provider surfaces before launch: news provider sync scaffolding, export support workflow, stock projection fallbacks, dividend/IBKR sync polish, and disabled-provider messages.
- [ ] Close or supersede stale backend docs that still claim billing, health, or rate-limit work is not implemented when current code says otherwise.

### Web App

- [ ] Decide browser push scope: defer APNS-only device registration for web, or create a separate browser-push implementation. Do not treat mobile APNS endpoints as a web MVP gap unless browser push is chosen.
- [ ] Run a Lighthouse audit on the deployed web app, including PWA installability if PWA is part of launch positioning.
- [ ] Manually QA desktop and mobile layouts in light and dark mode across auth, onboarding, dashboard, portfolio, stock detail, expenses, reports, settings, billing, export, and support flows.
- [ ] Improve per-section partial-load/error copy on dashboard insights, trading dashboard, expenses, reports, and stock detail so partial API failures do not look like missing data.
- [ ] Harden the trading dashboard where it derives rows from holdings and market data fallbacks; avoid showing misleading simulated trade confidence.
- [ ] Verify web billing routes, RevenueCat web billing redirect, restore, coupon redemption, and Pro gates against the production backend.
- [ ] Verify onboarding fail-closed behavior remains understandable if backend calls fail during signup/import/budget setup.
- [ ] Verify export download proxy and account deletion settings flows with production-like accounts.
- [ ] Resolve or consciously document remaining lint debt, especially opinionated `gocritic` items called out by the parity docs.

### iOS App

- [ ] Remove any remaining Expenses/Reports local summary fallback behavior. Runtime signed-in reports should render backend arrays directly; empty backend responses should show empty states, not locally computed summaries.
- [ ] Confirm SwiftData is only a cache/offline queue for authenticated runtime data and every user-owned row is scoped by `ownerUserId`.
- [ ] Confirm signed-in runtime screens show empty/error states rather than sample holdings, sample expenses, synthetic performance, placeholder testimonials, or preview-only content.
- [ ] Add accessibility identifiers needed for UI smoke tests on Expenses and Reports interactions.
- [ ] Add focused UI smoke coverage for the core Expenses and Reports journey: set salary/month plan, add planned item, record expense, view reports or empty/error states.
- [ ] Verify stock detail projections/comparison/fundamentals tabs are backend-hydrated where marketed, or explicitly position incomplete sections as unavailable/empty for MVP.
- [ ] Replace placeholder testimonials/trust copy in paywalls and onboarding with real, supportable copy.
- [ ] Verify TestFlight build routing: TestFlight uses the dev API, App Store builds use the production API, and no debug fixtures appear in release.
- [ ] Verify RevenueCat iOS API key, App Store subscription products, `pro` entitlement, trial configuration, restore purchases, manage subscription, and cancellation/expiration states.
- [ ] Verify paywall legal links, About legal links, privacy welcome screen, and account deletion flow satisfy App Store review requirements.
- [ ] Verify APNS permissions, device registration, target alert deep links, and earnings notification preferences on a real device or explicitly defer push-dependent claims.
- [ ] Run manual accessibility QA on real devices for Dynamic Type, VoiceOver, contrast, Reduce Motion, and localized tab labels.

## AI Helper Decision

- Product AI helper: post-MVP. Do not build a full conversational in-app assistant for launch.
- Existing backend AI insights can remain only if they are Pro-gated, rate-limited, educational/non-advisory, tested, and non-blocking when `OPENAI_API_KEY` is absent.
- The backend should continue to own all LLM provider calls. Web and iOS must never hold provider API keys or call OpenAI directly.
- Internal AI helpers for maintaining backlog/docs are useful now, but they are not part of the shipped MVP.

## Post-MVP Backlog

These are intentionally not MVP blockers unless a launch promise depends on them.

- Conversational AI assistant/helper as a paid Pro/Premium feature after retention and revenue justify LLM cost.
- Browser push and full PWA installability, if web push becomes a product requirement.
- Expanded broker integrations beyond the lowest-risk launch path.
- Scheduled broker sync and automated portfolio refresh.
- Live or near-real-time market data.
- Price, dividend, earnings, and thesis-review alerts beyond the verified launch set.
- Richer portfolio analytics, risk metrics, benchmark comparison, and scenario planning.
- Tax/report export packs, PDF exports, and accountant-ready files.
- Dividend income projections and DRIP tracking polish.
- Paper trading and trading simulation.
- Support/admin tooling for entitlement repair, refunds, data export, deletion, and incident response.
- Public data export API if the support-only export workflow is not enough.
- Team/family/B2B plans.

## Source Material

This checklist reflects the current docs and code references as of 2026-06-30:

- Backend MVP/production roadmap: `StockPlanBackend/docs/mvp-road.md`
- Backend README and API scope: `StockPlanBackend/README.md`
- Backend RevenueCat setup: `StockPlanBackend/docs/revenuecat-setup.md`
- Backend operations runbook and deployment guide: `StockPlanBackend/docs/deployment/operations-runbook.md`, `StockPlanBackend/docs/deployment/guide.md`
- Backend legal/support docs: `StockPlanBackend/docs/legal/*`, `StockPlanBackend/docs/compliance-support.md`, `StockPlanBackend/docs/support/*`
- Web parity docs: `StockPlanWeb/docs/API-PARITY-GAP.md`, `StockPlanWeb/docs/WEB-PARITY-PLAN.md`
- Web LLM ownership doc: `StockPlanWeb/docs/llm.md`
- iOS MVP and monetization docs: `StockPlanIOSApp/financeplan/financeplan/Documentation/mvp-roadmap.md`, `mvp-features-roadmap.md`, `monetization.md`
- iOS source-of-truth doc: `StockPlanIOSApp/financeplan/financeplan/Documentation/source-of-truth.md`
- Backlog plans for remaining iOS canonical-data and UI smoke coverage: `.hermes/plans/2026-04-23_180042-mvp-remove-local-fallback-from-expenses-reports.md`, `.hermes/plans/2026-04-23_154826-mvp-ui-smoke-tests-for-expenses-planner-and.md`

