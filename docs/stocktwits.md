# Stocktwits: what we use, and what their MCP server is for

Written 2026-09-07, after asking "can we integrate the Stocktwits MCP server
with the app?" The answer is no, and we already have the data anyway. This note
exists so the question does not get re-litigated from scratch.

## We already consume Stocktwits. Two paths, neither of them MCP

`SentimentSource.stocktwits` is part of the persisted storage contract
(`Insights/SentimentSource.swift`) and sits in `SentimentSource.inexpensive`, so
it feeds the sp500 and trending tiers, not just opt-in symbols.

| Path | Where | How |
|---|---|---|
| Their HTTP API | `Insights/DirectAPIInsightsProvider.swift` | `https://api.stocktwits.com/api/2/streams/symbol/{SYM}.json` — unauthenticated, no key, no env flag, always on |
| Web scrape | `Insights/DeepAPIInsightsProvider.swift` | DeepAPI `/v1/scrape/website` against `stocktwits.com/symbol/{SYM}`, gated on `DEEPAPI_SOCIAL_SCRAPING_ENABLED` |

The direct path is the floor the whole feature degrades to: it needs no key and
no credits, so it keeps working when DeepAPI is dry and Hermes is dead. It reads
the Bullish/Bearish self-tag as a `providedScore` at 0.8 confidence.

See `retail-sentiment.md` for the chain as a whole.

## Their MCP server cannot back the app

`https://mcp.stocktwits.com/mcp`. Verify any time — no account needed:

```sh
curl -sS -i -X POST https://mcp.stocktwits.com/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
# 401 + www-authenticate: ... resource_metadata="https://mcp.stocktwits.com/.well-known/oauth-protected-resource/mcp"

curl -sS https://mcp.stocktwits.com/.well-known/oauth-authorization-server
```

As of 2026-09-07 that returns:

```
grant_types_supported: ["authorization_code", "refresh_token"]
token_endpoint_auth_methods_supported: ["none"]     # public client + PKCE
code_challenge_methods_supported: ["S256"]
registration_endpoint: https://mcp.stocktwits.com/register   # RFC 7591 DCR
scopes_supported: ["read", "watch_lists"]
```

**`client_credentials` is absent.** There is no service-account grant, so the
backend cannot hold one token and serve sentiment to every user. Each token
belongs to one human who completes a browser consent. Two corollaries:

- A per-user "link your Stocktwits account" flow is technically possible, but it
  would need an MCP client this codebase does not have (no MCP SDK, no JSON-RPC
  client, no outbound OAuth — the only `client_credentials` grant in the repo is
  Reddit's, and our RFC 7591 implementation is *inbound*, in
  `Auth/OAuthServer/`). It would also only serve users who have a Stocktwits
  account, to obtain data we already pull keylessly for everyone.
- Sharing one "house" account token across all users would almost certainly
  breach their terms and is a single point of ban. Don't.

A headless agent cannot complete the flow at all: the redirect is
`http://127.0.0.1:<port>/callback`, which only a browser on the same machine can
receive. Hermes hit exactly this and never connected.

## What the MCP server *is* good for: your own sessions

Norviq already ships `norviq-mcp` (Go, separate service, ~70 tools including
`get_insights`). Running Stocktwits' server alongside it lets an agent join the
two — "which of my positions are trending on Stocktwits today?" — with no app
code involved.

### Rebuild checklist (new machine)

```sh
claude mcp add --transport http stocktwits https://mcp.stocktwits.com/mcp
# then: /mcp  -> authorize in a browser on this machine
```

Grant `read`. Skip `watch_lists` unless you actually want an agent touching your
Stocktwits lists — Norviq keeps its own.

### Use a read-only PAT in those sessions

Stocktwits posts are anonymous user-generated text, and `norviq-mcp` in the same
conversation exposes `record_trades`, `sell_position`, `delete_trade`,
`upsert_watchlist_items`. That combination is a prompt-injection path aimed at a
real portfolio.

`tools.Register` in norviq-mcp skips any tool whose scope the principal lacks, so
a read-only PAT means the write tools are never registered and no injected
instruction can reach them. Keep the write-scoped PAT for sessions where
Stocktwits is switched off.

## Operational state as of 2026-09-07

Recorded because it is not visible in the code and both items were live:

- **Hermes produces nothing.** `hermes_sync ticker feed returned nothing:
  symbols_failed=0` every 15 minutes. Its scraper
  (`scripts/hermes/ticker_sentiment_scraper.py`) is not an HTML scraper — it
  calls the xAI API (`api.x.ai/v1/responses`) and its docstring requires
  `XAI_API_KEY` "and available xAI API credits". A 4xx breaks out without retry.
  First thing to check on the VPS is that key and its balance.
- **DeepAPI was down to $0.024.** The same account backs the `deepapi` rung and
  ad-hoc research calls. When it empties, the rung 402s, takes the 6-hour
  cooldown, and coverage narrows to Stocktwits + news with nothing in the UI to
  say so.

Both of those were survivable only *after* the chain stopped treating an empty
answer as success — see `retail-sentiment.md`, "A provider that answers with
nothing".
