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

## Ticker + topic ingest (`ticker_sentiment_scraper.py`)

Built. Uses the xAI Agent Tools API (no HTML scraping) — see
`INGEST-SOURCES.md` for the source spec.

- `--mode tickers`: notable X posts per symbol → `ticker_posts` (tweet id as
  dedupe key end-to-end). Timer: every 45 min.
- `--mode topics`: X + news per financial topic → real `fin_event` rows.
  Timer: daily 06:20 UTC.
- `--purge-source manual --yes`: deletes the junk-classified legacy rows.
- Config: `scraper_config.json` (symbols, curated `notable_handles` ≤10,
  caps, model). Keep symbols in sync with backend `HERMES_TRACKED_TICKERS`.
- Requires `XAI_API_KEY` in `/root/.hermes/.env` on the VPS (present; needs
  xAI API credits to actually run).
- Deploy: `./deploy-ticker-scraper.sh` (uploads, installs timers, runs a live
  verification pass).

## Data-quality warning (as of 2026-07-03)

The current `fin_event` store (3,114 events) is junk-classified content — anime
and movie page titles labeled as Retirement/Housing/Crypto — because the ingest
consumed unrelated markdown. Before trusting `/finance/summary` numbers, point
the ingest at real financial sources and re-seed the SQLite store.
