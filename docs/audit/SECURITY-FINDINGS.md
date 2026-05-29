# Security Findings

Status from the planning-phase static pass (2026-05-29). Re-verify each against
current source before acting — several prior notes were already stale.

Severity: 🔴 high · 🟠 medium · 🟡 low · ✅ verified-good
Status: `RESOLVED` · `OPEN` · `VERIFY` (needs a live check) · `ACCEPTED` (documented risk)

## Server

| # | Sev | Finding | Evidence | Status |
|---|-----|---------|----------|--------|
| S1 | ✅ | RevenueCat webhook uses constant-time secret compare (body unsigned by design) | `Billing/RevenueCatWebhookController.swift:48-59` | RESOLVED |
| S2 | ✅ | Auth endpoints rate-limited (login/register/forgot/reset/refresh/mfa) | `Auth/AuthController.swift:37-44` | VERIFY (confirm env gate on in prod) |
| S3 | ✅ | Prod config gates: JWT secret required, no wildcard origins, strong DB creds | `Shared/ProductionConfiguration.swift` | RESOLVED |
| S4 | ✅ | SQL-injection safe (Fluent ORM; raw SQL only in schema create) | — | RESOLVED |
| S5 | 🟠 | Security headers (HSTS/CSP/X-Frame/nosniff/Referrer-Policy) — confirm emitted | `production_preflight.sh` checks them; verify live | VERIFY |
| S6 | 🟠 | No CI secret/image/dependency scanning (now added — confirm green) | `.github/workflows/security-scan.yml` | OPEN |
| S7 | 🟠 | IDOR sweep incomplete — ~15 controllers beyond Portfolio unaudited | Expenses/Goals/Crypto/Watchlist/Sharing/Earnings | OPEN |
| S8 | 🟡 | Request logging may include sensitive bodies/PII | `RequestLoggingMiddleware` | VERIFY |
| S9 | 🟡 | No circuit breaker on FMP/Finnhub — cascade risk | `MarketData/MarketDataService.swift` | ACCEPTED? |
| S10 | 🟡 | PII key-rotation strategy undocumented | `UserPIIEncryptionService` | OPEN |

## Client (iOS)

| # | Sev | Finding | Evidence | Status |
|---|-----|---------|----------|--------|
| C1 | ✅ | Auth tokens stored in Keychain (not UserDefaults); legacy migration ran | `Features/Auth/AuthService.swift:225-243` | RESOLVED |
| C2 | ✅ | No hardcoded secrets; RevenueCat/PostHog/Sentry keys from Info.plist | `BillingManager`, `NorviqaApp.swift` | RESOLVED |
| C3 | 🟠 | Request-param logging + Sentry `enableCaptureFailedRequests` may capture PII | `BaseHTTPClient` `requestLogger`, `NorviqaApp.swift` | OPEN |
| C4 | 🟡 | No certificate pinning | default `URLSession.shared` | ACCEPTED (document) |
| C5 | 🟡 | Entitlement cache in UserDefaults — confirm non-sensitive | `Features/UserProfile/BillingManager.swift` | VERIFY |

## Production-readiness verdict (static pass)

**Server:** architecturally production-grade, already deployed (Hetzner/Traefik/TLS).
No verified hard blocker. Close S5–S7 + S8 for an evidence-backed sign-off.

**Client:** production-ready, in App Store review. Polish only; address C3.

Final sign-off requires running the playbook (load test + live header check + CI
scan results).
