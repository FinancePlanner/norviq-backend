# Hermes finance API — deploy bundle

Canonical copy of the Hermes finance API server that runs on the VPS
(`78.46.192.73`, systemd unit `finance-api.service`), plus a one-shot deploy
script. Design and roadmap: `docs/post-mvp-financial-platform.md`.

## What the hardened server adds over the original

- `FINANCE_API_TOKEN` bearer auth on every route except `/healthz` and `/`
  (constant-time compare).
- `GET /finance/ticker/{symbol}/posts?days=N&limit=M` backed by a new
  `ticker_posts` SQLite table (created on first use) for notable-account
  X posts per symbol.
- Fixed timestamp format (`+00:00`, previously the invalid `+00:00Z`). The
  backend parses both, so deploy order does not matter.

## Deploy

1. One-time on the VPS: `tailscale up --hostname=hermes-vps`, authenticate via
   the printed URL.
2. From this directory: `./deploy-hermes-api.sh`
   - uploads the server, binds it to the tailnet IP (no more localhost/public),
   - generates a bearer token, installs it via systemd override, restarts,
   - verifies 401 without token / 200 with token,
   - prints the `HERMES_BASE_URL` + `HERMES_API_TOKEN` lines for the backend env.
3. One-time on the backend host (168.119.156.43):
   `curl -fsSL https://tailscale.com/install.sh | sh && tailscale up --hostname=stockplan-backend`
   then add the printed env lines to the backend `.env.production` and restart the app.
4. Verify container → tailnet routing:
   `docker exec <app-container> curl -s http://<tailnet-ip>:8780/healthz`
   If blocked: `iptables -A FORWARD -i docker0 -o tailscale0 -j ACCEPT`
   (plus the ESTABLISHED,RELATED reverse rule).

## Ticker scraper (next Hermes-side job — not yet built)

Populates `ticker_posts`. Outline:
- Config: curated list of notable X accounts + tracked symbols
  (start from `HERMES_TRACKED_TICKERS` in the backend env).
- Poll cashtag search / account timelines every 30–60 min
  (extend `x_link_poller_v2.py`).
- SuperGrok extraction per post → `{symbol, thesis_quote, sentiment
  (bullish|bearish|neutral), sentiment_score, confidence}`.
- Insert with tweet id as `event_id` (dedupe key end-to-end), `posted_at` from
  the tweet, systemd timer.

## Data-quality warning (as of 2026-07-03)

The current `fin_event` store (3,114 events) is junk-classified content — anime
and movie page titles labeled as Retirement/Housing/Crypto — because the ingest
consumed unrelated markdown. Before trusting `/finance/summary` numbers, point
the ingest at real financial sources and re-seed the SQLite store.
