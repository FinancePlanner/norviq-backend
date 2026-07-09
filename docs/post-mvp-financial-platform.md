# Post-MVP Financial Platform

Status: planned (post-MVP). Last updated: 2026-07-03.

This document describes the expansion of StockPlan from a stocks/crypto/expenses tracker into a full financial platform (a "financial command center"), and the data pipeline that powers it: the self-hosted Hermes agent (SuperGrok) feeding the StockPlanBackend over a private Tailscale network.

Index entry lives in `docs/MVP/README.md` under `## Post-MVP Backlog`.

---

## Vision & Scope

Today the product covers: stocks, crypto, expenses, budgets, reports, dashboards. The post-MVP goal is to cover everything financial a household touches — banking and cash flow, debt, housing, retirement, insurance, taxes, savings goals, and net worth — unified by an AI guidance layer that turns raw data into recommendations.

Two data planes feed this:

1. **User-entered / linked data** (existing pattern): accounts, transactions, holdings, manual entries.
2. **Hermes-scraped intelligence** (new): market/topic sentiment from X, notable-account theses per ticker, and research context — collected and extracted by the self-hosted Hermes agent with SuperGrok, then synced into the backend.

The backend remains the single source of truth for anything clients render. Hermes is a private, upstream data producer — never on the client request path.

## Architecture Overview

```
X / web sources
      │  (scraping + SuperGrok extraction)
      ▼
Hermes agent — VPS 78.46.192.73
  /root/.hermes/financial-pipeline/
  ├── raw JSONL (append-only)
  ├── SQLite canonical store (data/finance.sqlite)
  └── finance-api.service (HTTP, tailnet-only bind, bearer token)
      │
      │  Tailscale mesh (no public ports)
      ▼
StockPlanBackend — 168.119.156.43
  HermesSyncJob (poller, every HERMES_SYNC_INTERVAL_SECONDS)
      │  upsert with dedupe keys
      ▼
  Postgres: insight_events / sentiment_snapshots /
            ticker_sentiment_posts / net_worth_snapshots
      │
      ▼
  /v1/insights/*  (SessionToken auth + rate limit)
      │
      ▼
iOS app + Go web app
```

Key decisions (settled):

- **Pull, not push.** The backend polls Hermes on a schedule. Hermes stays a dumb, read-only source; the backend owns retries, dedupe, and persistence. No weekly file exports, no gRPC.
- **Tailscale, not public HTTPS.** The Hermes API binds to the VPS tailnet interface only. No open ports, no TLS/token-rotation burden for a personal service. Public HTTPS + JWT stays reserved for the user-facing StockPlan API.
- **Backend persistence is canonical for clients.** Clients never see Hermes latency or downtime; they read backend Postgres, populated asynchronously.

## Sector Breakdown

Each sector lists: core features, the AI angle, and what Hermes contributes.

### 1. Banking & Cash Flow (priority 1)

- Features: account linking (Plaid or manual), transaction import + smart categorization, bill/subscription tracking with reminders, cash-flow forecasting, low-balance alerts.
- AI angle: "Grocery spending is 18% above your historical average — here's why and how to fix it."
- Hermes: topic sentiment on `savings`/rates context; no per-user data (privacy: user financials never leave the backend).

### 2. Debt & Credit (priority 2)

- Features: card/loan tracking, payoff planner (snowball vs avalanche), interest cost calculators, min-vs-extra payment scenarios.
- AI angle: "An extra $200/month on the highest-interest card saves $X and finishes 14 months earlier."
- Hermes: rate-environment sentiment (topic `debt`, `rates`).

### 3. Housing & Renting (priority 3)

- Renters: rent tracking + reminders, lease expiration alerts, deposit management, rent-vs-buy calculator.
- Homeowners: mortgage tracking (principal/interest/escrow), property value estimates, maintenance log, property tax + insurance tracking, home equity in net worth.
- Investors (later): per-property cash flow, ROI/cap rate, tenant/lease management.
- AI angle: "Housing is 38% of income. Based on location and income growth, here's when buying beats renting."
- Hermes: topic `housing` sentiment + market context snippets.

### 4. Retirement (priority 4)

- Features: 401(k)/IRA/pension tracking, contribution + employer-match monitoring, retirement goal progress, scenario planning (retire at 58/62/65).
- AI angle: "At the current savings rate you retire at 62. Want the 58 scenario?"
- Hermes: topic `retirement` sentiment.

### 5. Savings Goals & Net Worth (priority 5 — foundational glue)

- Features: multiple goals with target dates and progress, full net worth (assets − liabilities) unifying stocks/crypto/cash/property/debt, emergency fund tracker, HYSA rate comparison.
- AI angle: "Emergency fund covers 2.1 months. Plan to reach 6 months in 14 months."
- Hermes: `net_worth_snapshots` for the operator's own aggregate view (personal instance); topic `net_worth` sentiment for content.
- Note: iOS `monetization.md` already tags the combined net-worth view as Premium.

### 6. Insurance (priority 6)

- Features: policy inventory (auto/home/renters/life/health/disability), renewal reminders, coverage gap analysis, premium-vs-coverage history.
- AI angle: "You pay $X above area average for auto insurance — savings opportunities."
- Hermes: topic `insurance` sentiment.

### 7. Taxes (priority 7 — seasonal)

- Features: deduction/credit tracking through the year, estimated payment calculator, document organizer, YoY comparison.
- AI angle: "Current spending pattern likely qualifies for $X additional deductions."
- Hermes: topic `tax` sentiment + rule-change chatter.

### 8. X Sentiment & Ticker Intelligence (flagship Hermes feature)

The differentiator. Two layers:

**Topic sentiment** — daily aggregate sentiment per financial topic (housing, savings, insurance, retirement, net worth, crypto, stocks, expenses), rendered as trend charts and context in dashboards.

**Ticker-level notable-account theses** — the headline product flow:

1. User taps `$AMD` (already on their watchlist/portfolio) in the iOS or web app.
2. Client calls `GET /v1/insights/tickers/AMD/sentiment`.
3. Backend serves cached posts from `ticker_sentiment_posts`: author display name + handle, thesis quote, sentiment label (bullish/bearish/neutral) with score, link to the original X post, posted-at timestamp, plus an aggregate (label, average score, post count) for the window.
4. Entirely server-side driven: Hermes scrapes cashtag search and a curated watchlist of notable accounts, SuperGrok extracts `{symbol, thesis_quote, sentiment, confidence}`, backend syncs and serves. Clients never touch X or Grok.

Bonus ideas parked for later: multi-user/household mode, side-income tracking, subscription optimizer, financial health score, scenario planning ("what if I buy a house in 2 years?").

## Macro & Inflation Context (Nowflation Parity) — Post-MVP Addition

**See dedicated doc**: `docs/POST-MVP.md` (plan of record for the global Nowflation-style feature model)

**Status (2026-07-09)**: backend Phase 2 shipped on `feat/macro-live-data` — live providers
(FRED for the US, Eurostat for PT/EA, IBGE for BR, optional Nowflation enrichment),
vintage-safe persistence, `MacroRefreshJob`, and new `/v1/macro/fed-watch` +
`/v1/macro/items` endpoints alongside the original snapshot/series/top-movers surface.
Needs `FRED_API_KEY` in prod to leave stub fallback (see POST-MVP.md "Operator steps").

Remaining in later phases: global country coverage tiers, "My Inflation" personalization
from expense data, local central-bank/rates context, iOS screen wiring (scaffold exists
in `Features/Macro/`), web country/compare pages, and dashboard context cards.

This fills the cost-of-living / macro backdrop gap globally: US support remains the
deepest first market, while Brazil, Portugal, and Euro Area coverage are the first
non-US official-source implementations.

---

## Phased Roadmap

| Phase | Contents | Depends on |
|-------|----------|------------|
| **A (this round)** | Tailscale mesh + Hermes API hardening (tailnet bind, bearer token); backend `Insights/` domain: provider, poller, 4 tables, `/v1/insights/*` | VPS access |
| **B** | Hermes ticker scraper + `/finance/ticker/{symbol}/posts`; backend ticker sentiment e2e; iOS ticker detail sentiment sheet; web equivalent | A |
| **C** | Net-worth foundation: banking/cash flow, debt, savings goals; net worth dashboard unifying existing stocks/crypto/expenses | A |
| **D** | Housing/renting, retirement, insurance, taxes modules | C |

## Hermes API Contract

Base URL: `http://<hermes tailnet IP>:8780` (Tailscale-only). Auth: `Authorization: Bearer <FINANCE_API_TOKEN>` on all endpoints except `/healthz`.

Existing endpoints (deployed):

| Endpoint | Returns |
|----------|---------|
| `GET /healthz` | liveness |
| `GET /finance/summary?days=N` | totals + recent events |
| `GET /finance/topic/{Topic}?days=N` | topic-filtered events |
| `GET /finance/sentiment?days=N` | sentiment aggregates |
| `GET /finance/net-worth` | latest net-worth snapshot |

New endpoint (Phase B):

`GET /finance/ticker/{symbol}/posts?days=N&limit=M`

```json
{
  "symbol": "AMD",
  "days": 14,
  "posts": [
    {
      "event_id": "…",
      "author": "Display Name",
      "author_handle": "handle",
      "text": "thesis quote…",
      "url": "https://x.com/…/status/…",
      "sentiment": "bullish",
      "sentiment_score": 0.7,
      "confidence": 0.85,
      "posted_at": "2026-07-01T14:03:00Z"
    }
  ]
}
```

`event_id` must be stable (tweet id preferred) — it is the backend's dedupe key.

## Backend Integration Design (summary)

New domain `Sources/StockPlanBackend/Insights/` mirroring `News/`:

- `InsightsProvider.swift` — `HermesInsightsProvider` (Finnhub-style `fetchJSON`, 15 s timeout, bearer header) + `DisabledInsightsProvider` fallback when `HERMES_BASE_URL` unset.
- `HermesSyncJob.swift` — `LifecycleHandler` poller (TargetAlertPoller pattern), interval `HERMES_SYNC_INTERVAL_SECONDS` (default 900 s), overlap guard, never crashes the app.
- Tables: `insight_events`, `sentiment_snapshots`, `ticker_sentiment_posts`, `net_worth_snapshots` — all with unique `dedupe_key` (Hermes event id, fallback hash(url + posted_at)); upsert = insert-missing-only.
- Routes (SessionToken auth + rate limit 60/min): `/v1/insights/summary`, `/v1/insights/topics/:topic`, `/v1/insights/sentiment`, `/v1/insights/net-worth`, `/v1/insights/tickers/:symbol/sentiment`.
- Tracked tickers: `HERMES_TRACKED_TICKERS` env for now; follow-up — derive from distinct symbols across user watchlists/portfolios.
- Readiness: `hermes` entry reports `disabled` / `ok` / `degraded` (last sync older than 3× interval) and never fails overall readiness — Hermes is non-critical.

Env (`.env.example`, docker-compose `x-shared_environment`):

```
HERMES_BASE_URL=http://100.x.y.z:8780   # VPS tailnet IP (MagicDNS not resolvable in-container)
HERMES_API_TOKEN=
HERMES_SYNC_INTERVAL_SECONDS=900
HERMES_TRACKED_TICKERS=AMD,NVDA,AAPL
```

## VPS Runbook

One-time setup on `78.46.192.73` (Hermes VPS) and `168.119.156.43` (backend host):

1. **Credentials hygiene** (do first): install SSH public key on the VPS, verify key login, set `PasswordAuthentication no` in `/etc/ssh/sshd_config`, restart sshd, rotate the root password. The previous password was exposed in a chat session and must be considered burned.
2. **Tailscale** on both machines:
   ```
   curl -fsSL https://tailscale.com/install.sh | sh
   tailscale up --hostname=hermes-vps          # on the VPS
   tailscale up --hostname=stockplan-backend   # on the backend host
   tailscale ping hermes-vps                   # verify from backend host
   ```
3. **Bind Hermes API to tailnet only**: systemd override for `finance-api.service` changing `--host 127.0.0.1` to the VPS tailnet IP (`tailscale ip -4`). Never `0.0.0.0`.
4. **Bearer token**: set `FINANCE_API_TOKEN` in the unit environment; the API rejects requests without `Authorization: Bearer <token>` (exempt `/healthz`). The same value goes in the backend's `HERMES_API_TOKEN`.
5. **Docker → tailnet routing** on the backend host: containers reach `100.64.0.0/10` through the host's `tailscale0` via normal bridge NAT. Verify with `docker exec <app> curl http://<tailnet-ip>:8780/healthz`. If blocked: `iptables -A FORWARD -i docker0 -o tailscale0 -j ACCEPT` plus the established/related reverse rule. Do not use `network_mode: host`.

## Risks & Constraints

- **X scraping ToS / rate limits** — programmatic scraping risks account restriction. Mitigation: low polling cadence (30–60 min), small curated account watchlist, configurable off-switch. Accepted as personal-use risk.
- **SuperGrok cost** — per-ticker extraction multiplies LLM calls. Cap tracked tickers, batch posts per prompt, log token spend on the VPS.
- **Dedupe drift** — if Hermes regenerates event ids, the backend duplicates rows. Mitigation: prefer tweet ids, fallback `hash(url + posted_at)`, unique DB constraints treat violations as skip-and-log, never fatal.
- **Tailscale-in-Docker** — bridge→tailnet forwarding can silently fail on hardened hosts; runbook step 5 verifies explicitly.
- **Poller safety** — sync job must never throw from `didBoot` or block app boot (initial delay ≥ 30 s, all failures logged and swallowed).
- **Privacy boundary** — user financial data never flows to Hermes or Grok. Hermes only produces public-web intelligence; the AI guidance layer over user data remains a separate, backend-owned concern (`OPENAI_API_KEY` path per `docs/MVP/README.md` AI Helper Decision).
