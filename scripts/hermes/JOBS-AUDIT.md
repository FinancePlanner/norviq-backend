# Hermes cron audit — 2026-07-05

91 jobs total on the VPS: 52 enabled, 39 disabled. Estimated **~190 SuperGrok
agent invocations/day**; the cleanup below cuts that to **~20/day (≈90%)**.
Executor: `cleanup-hermes-jobs.sh` (this directory) — prints the plan, deletes
only with `--yes`.

## Top token burners (all AGENT mode = SuperGrok calls)

| Job | Schedule | Runs/day | Verdict |
|---|---|---|---|
| `x-link-ingestor` | every 15 min | **96** | DELETE — duplicate of `x-link-poller` (script mode, free; classification via Nous/OpenRouter) |
| `server-health-monitor` (AGENT variant) | every 30 min | 48 | DELETE — 5 older script/agent variants exist disabled; monitoring needs no LLM (`--no-agent`) |
| `portfolio-threshold-alerts-hourly` | hourly | 24 | DELETE — exact duplicate of `portfolio-threshold-alerts` (script, every 30 min) |
| `Daily Obsidian Vault Pipeline` | daily | 1 | PAUSE — fails every run with "Context length exceeded" (burns a full context daily, delivers nothing) |
| go-news family (6 jobs) | daily | 6 | DELETE 3 — keep `daily-go-news{,-slack,-telegram}`, drop older `go-news-digest` ×3 |
| swift-news family (6 jobs) | daily | 6 | DELETE 3 — keep `daily-swift-news{,-slack,-telegram}`, drop `swift-news-digest` ×3 |

## Broken enabled jobs (error every run) — DELETE

- `crypto-price-checker` — "Blocked: script path resolves outside th…" (every 2 h)
- `weekly-portfolio-strategy-review` — "Script not found"
- `daily-x-content-email` — exit 1 daily
- `weekly-substack-free-email` — exit 1 weekly
- `weekly-substack-paid-email` — exit 2 weekly

## Disabled clutter (39 jobs) — DELETE ALL

April-era experiments, most duplicated 2–5×: `server-resource-monitor` ×7,
`Hermes Server Resource Monitor` ×3, `prod-server-resource-*` ×6,
`hermes-server-resource-*` ×6, `New Server 49.13.165.238` alerts/summaries ×5,
`Stock Alert — Discord/Slack/Telegram` ×3, `stockplan_promo_hourly`,
`daily-ios-swift-job-scraper` + `-slack` (Telegram variant stays, it's enabled
and working), `x-link-poller` (agent variant), `Check production server
resource alerts`, `server-alerts-49-13-165-238`, `server-health-monitor`
script variants ×2.

## Duplicates among enabled — DELETE

- `multi-link-poller` — two identical jobs every 15 min; keep the newer.

## Keep (working, single-purpose)

Morning/Afternoon/Evening Briefing, Investment Brief Morning, Thought Leader
Tracking, Weekly Stress Test, Vault Agent Map Sync, Weekly Earnings Calendar,
ai-cohort-alerts-hourly, ai-market-intelligence, business-daily,
crypto-market-intelligence, daily-go-news ×3, daily-swift-news ×3,
swift-market-intelligence, daily-morning-mashup, daily-stock-news +
personal-reminder, daily-ios-swift-job-scraper-telegram, norma-daily-job-search,
portfolio-threshold-alerts (script), stock-alert-triple, stock-daily,
stock-market-daily-digest, swift-daily, watchlist-will-do,
weekly-intelligence-brief, weekly-substack-newsletter, x-link-poller (script),
youtube-link-saver, multi-link-poller (one), Daily X Brief,
hermes-ticker-sentiment + hermes-topic-sentiment (new, finance pipeline).

## Consolidation candidates (your call — not touched by the script)

These work but overlap; each is a separate daily agent run:

1. **News digests ×3 channels**: `daily-go-news` and `daily-swift-news` run the
   agent 3× (origin/slack/telegram) for identical content. One job with
   multi-target delivery = 4 fewer agent runs/day.
2. **Stock digests overlap**: `daily-stock-news`, `daily-stock-news-personal-reminder`,
   `stock-market-daily-digest`, `stock-daily`, `Investment Brief Morning` — five
   morning stock/market digests. Two would do.
3. `swift-market-intelligence` vs `swift-daily` vs the swift-news family.
4. System crontab (outside hermes cron): anime/media tooling — `trakt_watcher`
   + `traktwrapper` every 5 min, MAL weekly jobs, `whatsapp_bridge_monitor` —
   not SuperGrok burners, but noise for a professional Norviq/LuminaVault box.

## Norviq / LuminaVault refocus (target state)

Keep the box to: finance pipeline (ticker + topic sentiment → Norviq backend),
briefings you actually read, portfolio/stock alerting (script mode), link
ingestion. Everything else is a candidate for the bin. When LuminaVault
integration starts, give it its own `~/.hermes/lumina-pipeline/` mirroring the
financial-pipeline layout (inbox → validate/dedupe script → SQLite → tailnet
API) — the pattern is proven now.
