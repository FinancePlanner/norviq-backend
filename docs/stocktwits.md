# Stocktwits: what we use, and what their MCP server is for

Written 2026-09-07, after asking "can we integrate the Stocktwits MCP server
with the app?" The answer is no, and we already have the data anyway. This note
exists so the question does not get re-litigated from scratch.

Stocktwits markets this at **`https://ai.stocktwits.com`** and serves it from
**`https://mcp.stocktwits.com/mcp`**. Those are the same product on two
hostnames — see "Two hostnames, one server" below. If you arrived here from the
marketing page, the rest of this document is the answer.

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

## Two hostnames, one server

The URL you find first is not the one you connect to.

| Host | What it is | MCP endpoint? |
|---|---|---|
| `ai.stocktwits.com` | Marketing and onboarding site — Next.js on Vercel, `application-name: Stocktwits MCP` | **No** |
| `mcp.stocktwits.com/mcp` | The actual Streamable-HTTP MCP server | Yes, behind OAuth |

Verified 2026-09-07, no account needed:

```sh
# The marketing host serves no protocol surface at all — every one of these is 404:
for p in /mcp /sse /api/mcp /docs \
         /.well-known/oauth-protected-resource \
         /.well-known/oauth-authorization-server; do
  curl -sS -o /dev/null -w "%{http_code} $p\n" "https://ai.stocktwits.com$p"
done
```

This matters because it is a re-litigation trap. `ai.stocktwits.com` reads as a
platform front door — its own metadata says "Bring live Stocktwits market
context, sentiment, and visual answers to any MCP-compatible agent" and names
Claude, ChatGPT, Cursor, Codex, OpenClaw and Hermes as targets. Landing there
after this document was written invites asking the integration question a second
time, against what looks like a different and newer offering. It is not
different. The OAuth constraint below is the whole answer for both hostnames.

Their page also advertises "visual answers" and "symbol cards" — capabilities
beyond the `read` / `watch_lists` scopes the server's own metadata declares.
Recorded as their claim, not as something verified here: reading the tool list
requires completing the browser consent, so nobody has enumerated it. It changes
nothing about the conclusion either way, because the blocker is the grant type,
not the tools.

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

As of 2026-09-07 that returns (re-checked later the same day, after the
`ai.stocktwits.com` page was found — identical, `client_credentials` still
absent):

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

Norviq already ships `norviq-mcp` (Go, separate service, 53 registered tools
including `get_insights`; 31 of them are writes, per
`internal/tools/confirmation.go`). Running Stocktwits' server alongside it lets
an agent join the two — "which of my positions are trending on Stocktwits
today?" — with no app code involved.

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

**This got more important on 2026-09-07, not less.** `ActionCatalog` now backs
all three assistant surfaces, so the in-app assistant and Telegram reach 16
actions — six of them destructive — where they previously reached five
proposals. The in-app path is confirmation-gated and a scoped token is held to
`.everyWrite`, so that surface is guarded. But none of those guards live in
`norviq-mcp`: an MCP client acting on a write-scoped PAT is doing what the PAT
authorises. The scope on the token is the only control that applies to the
Stocktwits-plus-Norviq session, which is why it is the one to get right.

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
