# Audit Playbook — Performance & Security

Repeatable procedure for auditing the StockPlan **server** (Vapor 4 / Swift 6) and
**iOS client** (SwiftUI). Run it on demand and before releases. Findings land in
`PERF-BASELINE.md` and `SECURITY-FINDINGS.md` (same directory).

**Principle: verify with evidence, not prior claims.** During the first pass, three
"issues" from old notes were already fixed in the code — don't trust a finding until
you've read the current source. (Tokens are in Keychain; the RevenueCat webhook uses
a constant-time compare; auth endpoints are rate-limited in `AuthController.swift`.)

---

## 0. One-time setup

```bash
brew install k6 gitleaks trivy        # macOS local tooling
# Server stack with slow-query visibility:
cd StockPlanBackend
docker compose -f docker-compose.yml -f docker-compose.perf.yml up -d --build
docker compose run --rm migrate
docker compose exec db psql -U stockplan_user -d stockplan_dev \
  -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
```

CI scanning (gitleaks, Trivy, dependency review, Dependabot) is wired in
`.github/workflows/security-scan.yml` + `.github/dependabot.yml` — no local action
needed beyond reviewing results.

---

## 1. Server performance

1. **Load test** — `./scripts/perf/run.sh` (target `localhost:8090`). Record
   p50/p95/p99 + RPS + error rate per endpoint into `PERF-BASELINE.md`.
2. **Slow queries / N+1** — after the run, read `pg_stat_statements` (query in
   `scripts/perf/README.md`). Rank by total time; high `calls` on near-identical
   queries = N+1. Cross-check:
   - `Portfolio/PortfolioController` (lots/pnl) — confirm `.with()` eager loading
   - `Statistics/StatisticsRepository` — joins vs per-row queries
   - Earnings handlers
3. **Indexes** — confirm hot query columns are indexed in
   `Migrations/Database+Index.swift`. Add migrations where a sequential scan shows
   in `auto_explain` plans (`docker compose logs db`).
4. **Caching** — measure Redis hit ratio under load; validate the dual-tier quote
   path and stale-fallback in `MarketData/MarketDataService.swift`. Confirm
   `quoteBatch()` reuses the HTTP client rather than creating a `Request` per symbol.
5. **DB pool / event loop** — watch for pool exhaustion (extend `BusinessMetrics`).
   Tune the Fluent pool size in `configure.swift` from the numbers, not by guess.
   Confirm no blocking work on the event loop.
6. **External APIs** — confirm timeouts on FMP/Finnhub calls; decide whether a
   circuit breaker is warranted (none today) via fault injection.

## 2. Client performance (iOS)

Follow `StockPlanIOSApp/financeplan/Docs/profiling.md`. In short:
1. Time Profiler + SwiftUI Instruments template; enable `Self._printChanges()` in
   DEBUG. Target `DashboardRoot` (12 `@State`, computed `insightCards`),
   `UnifiedActivityFeed`, `Crypto` sections.
2. Confirm `ForEach` uses stable ids and long lists use `LazyVStack`.
3. Allocations + Network templates: check decode off the main actor
   (`BaseHTTPClient.call()`), `URLSession.shared` timeouts, image caching.
4. Record cold/warm launch + Dashboard time-to-interactive in `PERF-BASELINE.md`.

## 3. Server security

1. **IDOR sweep** — every protected handler must scope by
   `\.$userId == session.userId`. Portfolio is clean; audit Expenses, Goals, Crypto,
   Watchlist, Sharing, Earnings, Activity, Badges, Budget, Reports.
2. **Rate limiting** — `AuthController.swift` rate-limits login/register/forgot/
   reset/refresh/mfa (env-gated). Confirm the gate is on in prod; confirm market
   endpoints covered by `RateLimitMiddleware`.
3. **Security headers** — run `scripts/ops/production_preflight.sh` against the
   stack; confirm HSTS, X-Frame-Options, X-Content-Type-Options, CSP,
   Referrer-Policy are emitted. Add a middleware if any are missing.
4. **Secrets** — review `gitleaks` CI results; confirm `.env*` gitignored;
   confirm `ProductionConfiguration` prod gates (JWT secret, no wildcard origins,
   strong DB creds).
5. **Logging** — confirm `RequestLoggingMiddleware` scrubs bodies/PII and OAuth
   error logs don't leak provider detail.
6. **PII** — review `UserPIIEncryptionService`; document a key-rotation strategy.

## 4. Client security (iOS)

1. **Storage** — tokens in Keychain (confirmed, `AuthService.swift`); entitlement
   cache in UserDefaults (`BillingManager`) must stay non-sensitive.
2. **Log/analytics leakage** — audit `BaseHTTPClient` `requestLogger` params and
   Sentry `enableCaptureFailedRequests`; filter PII.
3. **Transport** — document the certificate-pinning decision (none today).
4. **Secrets** — confirm RevenueCat/PostHog/Sentry keys come from Info.plist build
   config; nothing hardcoded.

## 5. Record results

- Update `PERF-BASELINE.md` with the run's numbers + date + commit SHA.
- Update `SECURITY-FINDINGS.md` with severity, evidence (`file:line`), and status.
- File issues for anything not `RESOLVED`.
