# Hermes ingest sources — spec

Status: implemented by `ticker_sentiment_scraper.py` (this directory).
Last updated: 2026-07-04.

## Why this spec exists

The current `fin_event` store is junk: the Telegram/X link poller compiled the
whole Obsidian vault, so anime/movie page titles got classified as
Retirement/Housing/Crypto (3,114 events, sentiment ~0, net-worth null). This
spec defines the real sources that replace it.

## Source strategy

**Primary mechanism: xAI Agent Tools API** (`POST https://api.x.ai/v1/chat/completions`
with `search_parameters`). Grok searches X (and optionally news/web) natively
and returns citations. No HTML scraping, no throwaway X accounts, no ToS
gymnastics — one API, one key (`XAI_API_KEY`), and it is the same Grok stack
Hermes already uses.

| Feed | Source | Cadence | Output |
|------|--------|---------|--------|
| Ticker sentiment (flagship) | Agent Tools `x_search`, per tracked symbol, optional curated handle list | every 45 min (config) | `ticker_posts` table → backend `ticker_sentiment_posts` → `/v1/insights/tickers/:symbol/sentiment` |
| Topic pulse (Housing, Savings, Insurance, Retirement, NetWorth, Taxes, Debt, Crypto, Stocks, Expenses) | Agent Tools `x_search` + `web_search`, per topic query | daily | `fin_event` rows (+ append-only `raw_events.jsonl`) → `/finance/summary`, `/finance/sentiment`, backend `insight_events` |
| Manual shares (existing `x_link_poller_v2.py`) | Telegram-shared X links only | as shared | keep, but scope it to explicitly shared links — never re-compile the whole vault into `fin_event` |

RSS feeds (CoinDesk, Calculated Risk, etc.) are a possible later addition;
the Agent Tools `web_search` tool already covers most of that ground with less code.

## Ticker feed details

- Symbols: `scraper_config.json` `tickers` list — keep in sync with backend
  `HERMES_TRACKED_TICKERS`; later, generate from users' watchlists.
- Curated notable accounts: `notable_handles` in config (≤ 10 per request —
  xAI `included_x_handles` limit). Empty list = search all of X.
- Quality gate in the extraction prompt: substantive thesis posts only — skip
  giveaways, bots, engagement bait, pure emoji. Verbatim quotes ≤ 500 chars.
- Dedupe key: tweet status id from the URL (`x-<status_id>`), fallback
  `sha256(handle + text)`. End-to-end stable: SQLite PK → Hermes API
  `event_id` → backend `dedupe_key`.

## Topic feed details

Per-topic search hints live in the config (`topics` map), e.g. Housing →
"housing market, mortgage rates, rent prices, home affordability". Each run
asks for the most substantive recent posts/articles per topic, labels
sentiment, and writes schema-compatible `fin_event` rows
(`source=xai_live_search`, payload `{title, url, summary, author}`,
sentiment `{label, score}`).

## Cost controls

- `max_posts_per_symbol` / `max_items_per_topic` caps (default 10).
- `max_search_results` passed to xAI (default 20).
- Token usage from `response.usage` logged every call; grep
  `journalctl -u hermes-ticker-scraper` for `usage`.
- Default model `grok-4.3`; override with config `model` or `GROK_MODEL` env.

## Junk cleanup (one-time)

The old junk rows all have `source='manual'`. After the topic feed produces
real rows:

```
python3 ticker_sentiment_scraper.py --purge-source manual --yes \
  --db /root/.hermes/financial-pipeline/data/finance.sqlite
```

Backend note: prod already synced 200 junk events into `insight_events`.
After purging on the VPS, clear them once:
`DELETE FROM insight_events WHERE source = 'manual';` (and the neutral
sentiment snapshots re-upsert on the next sync tick).

## Deploy

`./deploy-ticker-scraper.sh` (this directory): uploads scraper + config,
installs `hermes-ticker-scraper.timer` (45 min) and
`hermes-topic-ingest.timer` (daily 06:20 UTC), runs a one-shot verification.
Requires `XAI_API_KEY` in `/root/.hermes/.env` on the VPS (canonical Hermes
env — confirmed present) plus xAI API credits; without credits the timers
install fine and runs start succeeding once topped up.
